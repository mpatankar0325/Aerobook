// DatabaseManager+LogbookProfile.swift
// AeroBook — Services group
//
// Adds the LogbookProfile model and all supporting types (ColumnDefinition,
// CrossCheckRule, CapturePhase) plus the logbook_profiles SQLite table,
// CRUD operations, and first-launch seeding of the Jeppesen pre-built profile.
//
// Architecture notes:
//   • All write operations run on dbQueue (serial background queue) and
//     call back on the main thread — same pattern as DatabaseManager+Profile.swift.
//   • Columns and cross-check rules are stored as JSON blobs (TEXT columns)
//     so the table schema never needs to change when adding new logbook types.
//   • LogbookProfile and all nested types are Codable so JSONEncoder /
//     JSONDecoder can round-trip the entire profile without any custom logic.

import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to a function pointer) that Swift
// cannot import automatically. This typesafe equivalent is the standard
// workaround used throughout the AeroBook SQLite layer.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Supporting Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Physical layout of a logbook page as seen by the scanner.
public enum PageLayout: String, Codable, CaseIterable {
    /// Two half-pages visible side-by-side (e.g. Jeppesen Pilot Logbook).
    case landscapeSpread
    /// A single upright page (e.g. some ASA formats).
    case portraitSingle
}

/// Primitive type of data stored in one scanner capture strip.
/// Drives OCR mode selection and post-capture validation.
public enum ColumnDataType: String, Codable, CaseIterable {
    /// A decimal hours value encoded as two adjacent H and t cells (H.t).
    case decimalHours
    /// A whole-number count (e.g. approaches, takeoffs, landings).
    case integer
    /// Free-form text (e.g. aircraft ident, route identifiers).
    case text
    /// Never OCR'd — raw image stored, pilot enters text manually if needed.
    case imageOnly
}

/// Role of a cell within an H+t split-cell pair.
/// Every decimalHours column produces exactly two ColumnDefinitions that
/// share a pairId — one with role .hours and one with role .tenths.
public enum PairRole: String, Codable, CaseIterable {
    /// The left (integer hours) cell of an H+t pair. Valid range: 0–9.
    case hours
    /// The right (tenths of an hour) cell of an H+t pair. Valid range: 0–9.
    case tenths
    /// Not part of an H+t pair (integer, text, or imageOnly columns).
    case none
}

/// The 5-phase capture order used by the scanner.
/// Phases are ordered by confidence value: highest-value columns first so
/// row alignment is proved early and cross-checks run before low-reliability
/// text OCR is attempted.
public enum CapturePhase: Int, Codable, CaseIterable {
    /// Phase 1 — Total Duration (H+t) + Date. Establishes row count and identity.
    case phase1Anchor       = 1
    /// Phase 2 — Dual Received, PIC, Category SE. Enables the 5-way cross-check.
    case phase2CrossCheck   = 2
    /// Phase 3 — Remaining time columns (XC, Night, Inst, Sim, CFI, ME, etc.).
    case phase3TimeColumns  = 3
    /// Phase 4 — Text and count columns (Type, Ident, From, To, App, T/O, LDG).
    case phase4TextAndCounts = 4
    /// Phase 5 — Remarks image. Captured raw; never passed to OCR.
    case phase5ImageOnly    = 5
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CrossCheckRule supporting types
// ─────────────────────────────────────────────────────────────────────────────

/// Comparison operator applied across the fields listed in a CrossCheckRule.
public enum CrossCheckOperator: String, Codable, CaseIterable {
    /// All field values must be numerically equal after OCR.
    case allEqual
    /// The sum of all field values must equal a target (encoded in description).
    case sumEquals
    /// field[0] must be ≤ field[1] (e.g. XC ≤ Total).
    case lte
    /// If field[0] > 0 then at least one of field[1…] must also be > 0.
    case gtZeroRequires
}

/// Qualitative confidence used by the review engine to decide auto-accept vs flag.
public enum CrossCheckConfidence: String, Codable, CaseIterable {
    /// On pass → all participating fields are auto-accepted; pilot never sees them.
    case high
    /// On pass → fields accepted silently; on fail → flag but don't block commit.
    case medium
    /// On fail → advisory flag only; pilot may still commit without correcting.
    case low
}

/// Action taken by the review engine when a rule fails.
public enum CrossCheckOnFail: String, Codable, CaseIterable {
    /// Highlight only the specific cells that violate the rule.
    case flagFields
    /// Highlight the entire flight row as needing attention.
    case flagRow
    /// Prevent commit until the pilot resolves the conflict.
    case block
    /// Treat the row as blank — do not commit it.
    case skipRow
}

/// When the rule is evaluated. `.ifBlank` skips the rule when a named
/// column is blank (used to make rules conditional on optional columns).
public enum CrossCheckApplicability: Codable, Equatable {
    /// Always evaluate this rule, regardless of field contents.
    case always
    /// Skip this rule if the specified columnId is blank or zero.
    case ifBlank(String)

    // Codable conformance — stored as {"type":"always"} or {"type":"ifBlank","columnId":"..."}
    enum CodingKeys: String, CodingKey { case type, columnId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "ifBlank" {
            let id = try container.decode(String.self, forKey: .columnId)
            self = .ifBlank(id)
        } else {
            self = .always
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try container.encode("always", forKey: .type)
        case .ifBlank(let id):
            try container.encode("ifBlank", forKey: .type)
            try container.encode(id, forKey: .columnId)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Core Model Types
// ─────────────────────────────────────────────────────────────────────────────

/// One physical capture strip in the logbook.
/// A single logical column that uses H+t split cells produces TWO
/// ColumnDefinitions sharing the same `pairId` (one `.hours`, one `.tenths`).
/// The scanner reads `captureOrder` to know which strip to point the ROI at next.
public struct ColumnDefinition: Codable, Identifiable {
    public var id: String { columnId }

    /// Stable machine-readable identifier (e.g. "total_duration_hours").
    /// Used as the foreign key inside CrossCheckRule.fields arrays.
    public let columnId: String

    /// Top-level header text printed on the physical logbook page (e.g. "Total Duration").
    public let groupLabel: String

    /// Second header row beneath the group label (e.g. "of Flight"). Empty string if absent.
    public let subLabel: String

    /// Third header row showing the cell unit (e.g. "H" or "t"). Empty string if not a split cell.
    public let unitLabel: String

    /// Data type driving OCR mode and post-capture validation logic.
    public let dataType: ColumnDataType

    /// Links this cell to its H+t partner. Both definitions share the same pairId string.
    /// nil for non-pair columns (integer, text, imageOnly).
    public let pairId: String?

    /// Which half of the H+t pair this cell represents. `.none` for non-pair columns.
    public let pairRole: PairRole

    /// Property name on the Flight model / DB row dictionary this column writes to.
    /// Scanner code uses this string to route the OCR result into the correct field.
    public let flightField: String

    /// Left-to-right strip capture sequence. 1 = first strip captured in Phase 1.
    /// The scanner presents strips in ascending captureOrder within each phase.
    public let captureOrder: Int

    /// If false, a blank cell is acceptable (e.g. Multi Engine columns for student pilots,
    /// Remarks image, Flight Sim). The scanner skips validation for optional blank cells.
    public let isRequired: Bool

    /// Hard OCR sanity bounds. Any OCR result outside this range is immediately flagged
    /// before cross-check rules run. nil = no range check (free-form text columns).
    public let validationRange: ClosedRange<Int>?

    /// Value written when the cell is blank and isRequired is false.
    /// "0" for all numeric columns; "" for text columns.
    public let defaultValue: String

    // ClosedRange<Int> is not Codable natively — encode as lower+upper bounds.
    enum CodingKeys: String, CodingKey {
        case columnId, groupLabel, subLabel, unitLabel, dataType, pairId, pairRole
        case flightField, captureOrder, isRequired
        case validationRangeLower, validationRangeUpper
        case defaultValue
    }

    public init(
        columnId: String,
        groupLabel: String,
        subLabel: String = "",
        unitLabel: String = "",
        dataType: ColumnDataType,
        pairId: String? = nil,
        pairRole: PairRole = .none,
        flightField: String,
        captureOrder: Int,
        isRequired: Bool = true,
        validationRange: ClosedRange<Int>? = nil,
        defaultValue: String = "0"
    ) {
        self.columnId        = columnId
        self.groupLabel      = groupLabel
        self.subLabel        = subLabel
        self.unitLabel       = unitLabel
        self.dataType        = dataType
        self.pairId          = pairId
        self.pairRole        = pairRole
        self.flightField     = flightField
        self.captureOrder    = captureOrder
        self.isRequired      = isRequired
        self.validationRange = validationRange
        self.defaultValue    = defaultValue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columnId      = try c.decode(String.self,          forKey: .columnId)
        groupLabel    = try c.decode(String.self,          forKey: .groupLabel)
        subLabel      = try c.decode(String.self,          forKey: .subLabel)
        unitLabel     = try c.decode(String.self,          forKey: .unitLabel)
        dataType      = try c.decode(ColumnDataType.self,  forKey: .dataType)
        pairId        = try c.decodeIfPresent(String.self, forKey: .pairId)
        pairRole      = try c.decode(PairRole.self,        forKey: .pairRole)
        flightField   = try c.decode(String.self,          forKey: .flightField)
        captureOrder  = try c.decode(Int.self,             forKey: .captureOrder)
        isRequired    = try c.decode(Bool.self,            forKey: .isRequired)
        defaultValue  = try c.decode(String.self,          forKey: .defaultValue)
        if let lo = try c.decodeIfPresent(Int.self, forKey: .validationRangeLower),
           let hi = try c.decodeIfPresent(Int.self, forKey: .validationRangeUpper) {
            validationRange = lo...hi
        } else {
            validationRange = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(columnId,     forKey: .columnId)
        try c.encode(groupLabel,   forKey: .groupLabel)
        try c.encode(subLabel,     forKey: .subLabel)
        try c.encode(unitLabel,    forKey: .unitLabel)
        try c.encode(dataType,     forKey: .dataType)
        try c.encodeIfPresent(pairId, forKey: .pairId)
        try c.encode(pairRole,     forKey: .pairRole)
        try c.encode(flightField,  forKey: .flightField)
        try c.encode(captureOrder, forKey: .captureOrder)
        try c.encode(isRequired,   forKey: .isRequired)
        try c.encode(defaultValue, forKey: .defaultValue)
        if let r = validationRange {
            try c.encode(r.lowerBound, forKey: .validationRangeLower)
            try c.encode(r.upperBound, forKey: .validationRangeUpper)
        }
    }
}

/// A single cross-check validation rule stored as profile data — not hardcoded logic.
/// The generic rule engine interprets these structs at review time.
/// Adding new logbook support requires only a new profile with different rules.
public struct CrossCheckRule: Codable, Identifiable {
    public var id: String { ruleId }

    /// Stable machine-readable identifier (e.g. "student_5way_match").
    public let ruleId: String

    /// Human-readable explanation shown in the review UI when the rule fails.
    public let description: String

    /// columnId values of the cells involved in the check.
    /// Interpretation depends on `operator`: for allEqual all must match;
    /// for lte field[0] ≤ field[1]; for gtZeroRequires field[0] > 0 → any of field[1…] > 0.
    public let fields: [String]

    /// The comparison applied across `fields`.
    public let `operator`: CrossCheckOperator

    /// How much confidence to assign to a passing result.
    public let confidence: CrossCheckConfidence

    /// What the review engine does when this rule fails.
    public let onFail: CrossCheckOnFail

    /// Whether the rule always runs or only when a specified field is non-blank.
    public let applicability: CrossCheckApplicability
}

/// The top-level profile struct that describes one logbook format.
/// One instance lives in the DB per logbook type.
/// All scanner, OCR, and cross-check code reads this struct — no hardcoded formats.
public struct LogbookProfile: Codable, Identifiable {
    /// UUID primary key stored as TEXT in SQLite.
    public let id: UUID

    /// Display name shown in the logbook picker (e.g. "Jeppesen Pilot Logbook").
    public let name: String

    /// Publisher name used for pre-built profile matching (e.g. "Jeppesen").
    public let publisher: String

    /// Number of handwritten data rows per page (user-confirmed on first scan).
    /// Default 13 for Jeppesen Pilot Logbook.
    public let dataRowCount: Int

    /// Number of totals rows at the bottom of each page that are always skipped.
    /// Default 3 (Totals This Page / Brought Forward / Totals to Date).
    public let totalsRowCount: Int

    /// Number of header rows above the first data entry row.
    /// Default 3 for Jeppesen (Group → Sub → H/t unit).
    public let headerLevels: Int

    /// Physical page orientation the scanner expects.
    public let pageLayout: PageLayout

    /// Ordered array of every physical capture strip in the logbook.
    /// Sorted ascending by captureOrder for scanner presentation.
    public var columns: [ColumnDefinition]

    /// Validation rules run after all desired phases are captured.
    public var crossCheckRules: [CrossCheckRule]

    /// Timestamp when the profile was first created.
    public let createdAt: Date

    /// true = shipped with app (read-only). false = user-customised copy.
    public let isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        publisher: String,
        dataRowCount: Int,
        totalsRowCount: Int,
        headerLevels: Int,
        pageLayout: PageLayout,
        columns: [ColumnDefinition],
        crossCheckRules: [CrossCheckRule],
        createdAt: Date = Date(),
        isBuiltIn: Bool
    ) {
        self.id             = id
        self.name           = name
        self.publisher      = publisher
        self.dataRowCount   = dataRowCount
        self.totalsRowCount = totalsRowCount
        self.headerLevels   = headerLevels
        self.pageLayout     = pageLayout
        self.columns        = columns
        self.crossCheckRules = crossCheckRules
        self.createdAt      = createdAt
        self.isBuiltIn      = isBuiltIn
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DatabaseManager Extension
// ─────────────────────────────────────────────────────────────────────────────

extension DatabaseManager {

    // MARK: Schema

    /// Creates the logbook_profiles table if it does not already exist.
    /// Called from the existing migrateSchema() chain — no other callers needed.
    func createLogbookProfilesTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS logbook_profiles (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL,
            publisher    TEXT NOT NULL DEFAULT '',
            data_row_count    INTEGER NOT NULL DEFAULT 13,
            totals_row_count  INTEGER NOT NULL DEFAULT 3,
            header_levels     INTEGER NOT NULL DEFAULT 3,
            page_layout  TEXT NOT NULL DEFAULT 'landscapeSpread',
            is_built_in  INTEGER NOT NULL DEFAULT 0,
            created_at   REAL NOT NULL,
            columns_json TEXT NOT NULL DEFAULT '[]',
            rules_json   TEXT NOT NULL DEFAULT '[]'
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(db))
            print("[AeroBook] createLogbookProfilesTable error: \(err)")
        }
    }

    // MARK: First-Launch Seed

    /// Seeds the Jeppesen pre-built profile on first launch.
    /// Must be called after createLogbookProfilesTable() has run.
    /// If any profile already exists in the table this is a no-op.
    func seedBuiltInProfilesIfNeeded() {
        let count = queryInt("SELECT COUNT(*) FROM logbook_profiles")
        guard count == 0 else { return }
        let profile = LogbookProfile.jeppesenPilotLogbook
        saveProfile(profile) { result in
            switch result {
            case .success:
                print("[AeroBook] Jeppesen pre-built profile seeded successfully.")
            case .failure(let error):
                print("[AeroBook] Failed to seed Jeppesen profile: \(error)")
            }
        }
    }

    // MARK: CRUD — Reads (synchronous, called from background or main)

    /// Returns all stored logbook profiles, ordered by creation date ascending.
    /// Safe to call from any thread — reads directly on the calling thread using
    /// the shared SQLite connection (DatabaseManager serialises access via dbQueue
    /// for writes; reads here are fine because SQLite is in WAL mode).
    func fetchAllProfiles() -> [LogbookProfile] {
        let sql = "SELECT id, name, publisher, data_row_count, totals_row_count, header_levels, page_layout, is_built_in, created_at, columns_json, rules_json FROM logbook_profiles ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        var profiles: [LogbookProfile] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[AeroBook] fetchAllProfiles prepare error: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = profileFromStatement(stmt) { profiles.append(p) }
        }
        return profiles
    }

    /// Returns a single profile by UUID, or nil if not found.
    func fetchProfile(id: UUID) -> LogbookProfile? {
        let sql = "SELECT id, name, publisher, data_row_count, totals_row_count, header_levels, page_layout, is_built_in, created_at, columns_json, rules_json FROM logbook_profiles WHERE id = ?;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return profileFromStatement(stmt)
        }
        return nil
    }

    // MARK: CRUD — Writes (async on dbQueue, callback on main thread)

    /// Inserts or replaces a LogbookProfile in the database.
    /// - Parameters:
    ///   - profile: The profile to persist (INSERT OR REPLACE semantics on id).
    ///   - completion: Called on the main thread with `.success` or `.failure`.
    func saveProfile(_ profile: LogbookProfile, completion: @escaping (Result<Void, Error>) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970

            do {
                let columnsData = try encoder.encode(profile.columns)
                let rulesData   = try encoder.encode(profile.crossCheckRules)

                guard let columnsJson = String(data: columnsData, encoding: .utf8),
                      let rulesJson   = String(data: rulesData,   encoding: .utf8) else {
                    throw NSError(domain: "AeroBook", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "JSON serialisation produced non-UTF8 data"])
                }

                let sql = """
                INSERT OR REPLACE INTO logbook_profiles
                    (id, name, publisher, data_row_count, totals_row_count, header_levels, page_layout, is_built_in, created_at, columns_json, rules_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw NSError(domain: "AeroBook", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.db))])
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt,  1, profile.id.uuidString,          -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt,  2, profile.name,                   -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt,  3, profile.publisher,              -1, SQLITE_TRANSIENT)
                sqlite3_bind_int( stmt,  4, Int32(profile.dataRowCount))
                sqlite3_bind_int( stmt,  5, Int32(profile.totalsRowCount))
                sqlite3_bind_int( stmt,  6, Int32(profile.headerLevels))
                sqlite3_bind_text(stmt,  7, profile.pageLayout.rawValue,    -1, SQLITE_TRANSIENT)
                sqlite3_bind_int( stmt,  8, profile.isBuiltIn ? 1 : 0)
                sqlite3_bind_double(stmt, 9, profile.createdAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 10, columnsJson,                    -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 11, rulesJson,                      -1, SQLITE_TRANSIENT)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw NSError(domain: "AeroBook", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.db))])
                }

                DispatchQueue.main.async { completion(.success(())) }

            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Permanently deletes a profile by UUID.
    /// Built-in profiles can be deleted by this call — the caller is responsible
    /// for guarding against accidental deletion of built-in profiles in the UI.
    /// - Parameters:
    ///   - id: UUID of the profile to remove.
    ///   - completion: Called on the main thread with `.success` or `.failure`.
    func deleteProfile(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else { return }

            let sql = "DELETE FROM logbook_profiles WHERE id = ?;"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(self.db))
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "AeroBook", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: err])))
                }
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_DONE {
                DispatchQueue.main.async { completion(.success(())) }
            } else {
                let err = String(cString: sqlite3_errmsg(self.db))
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "AeroBook", code: -2,
                                               userInfo: [NSLocalizedDescriptionKey: err])))
                }
            }
        }
    }

    // MARK: Private Helpers

    /// Deserialises one SQLite row into a LogbookProfile.
    /// Column order must match the SELECT statement in fetchAllProfiles / fetchProfile.
    private func profileFromStatement(_ stmt: OpaquePointer?) -> LogbookProfile? {
        guard let stmt = stmt else { return nil }

        guard let idStr  = sqlite3_column_text(stmt, 0).flatMap({ String(cString: $0) }),
              let id     = UUID(uuidString: idStr),
              let name   = sqlite3_column_text(stmt, 1).flatMap({ String(cString: $0) }) else {
            return nil
        }

        let publisher     = sqlite3_column_text(stmt, 2).flatMap({ String(cString: $0) }) ?? ""
        let dataRowCount  = Int(sqlite3_column_int(stmt, 3))
        let totalsRowCount = Int(sqlite3_column_int(stmt, 4))
        let headerLevels  = Int(sqlite3_column_int(stmt, 5))
        let layoutRaw     = sqlite3_column_text(stmt, 6).flatMap({ String(cString: $0) }) ?? "landscapeSpread"
        let pageLayout    = PageLayout(rawValue: layoutRaw) ?? .landscapeSpread
        let isBuiltIn     = sqlite3_column_int(stmt, 7) != 0
        let createdAtTs   = sqlite3_column_double(stmt, 8)
        let createdAt     = Date(timeIntervalSince1970: createdAtTs)

        let columnsJson   = sqlite3_column_text(stmt, 9).flatMap({ String(cString: $0) }) ?? "[]"
        let rulesJson     = sqlite3_column_text(stmt, 10).flatMap({ String(cString: $0) }) ?? "[]"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let columns: [ColumnDefinition]
        let rules: [CrossCheckRule]

        do {
            columns = try decoder.decode([ColumnDefinition].self,
                                         from: Data(columnsJson.utf8))
            rules   = try decoder.decode([CrossCheckRule].self,
                                         from: Data(rulesJson.utf8))
        } catch {
            print("[AeroBook] profileFromStatement JSON decode error: \(error)")
            return nil
        }

        return LogbookProfile(
            id:             id,
            name:           name,
            publisher:      publisher,
            dataRowCount:   dataRowCount,
            totalsRowCount: totalsRowCount,
            headerLevels:   headerLevels,
            pageLayout:     pageLayout,
            columns:        columns,
            crossCheckRules: rules,
            createdAt:      createdAt,
            isBuiltIn:      isBuiltIn
        )
    }

    /// Convenience helper — returns the Int result of a single-value SELECT.
    private func queryInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
