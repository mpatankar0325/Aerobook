// DatabaseManager+DuplicateDetector.swift
// AeroBook — Scanner group
//
// Build Order Item #11 — Duplicate Detector (DB layer)
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Adds duplicate-detection and conflict-resolution DB operations to the
// DatabaseManager. Called by DuplicateDetector (the coordinator) after the
// ScanReviewView hands off a fully-reviewed ScanPage for commit.
//
// The detection strategy matches the strategy doc:
//   PRIMARY KEY:  date + aircraft_ident + total_time (all three must match)
//   SECONDARY:    date + aircraft_ident only          (looser — returns candidates)
//
// A flight qualifies as a "definite duplicate" only when all three primary keys
// match within the configured tolerance (total_time within ±0.05 hours — one
// tenths-digit rounding error). When only date + ident match, the row is a
// "candidate duplicate" and the pilot sees the existing record's details before
// deciding.
//
// The replace operation is a single atomic UPDATE — it never deletes the
// existing row ID so that any foreign-key references (endorsements, signatures)
// remain valid.
//
// ─────────────────────────────────────────────────────────────────────────────
// THREADING
// ─────────────────────────────────────────────────────────────────────────────
//   All writes run on dbQueue (serial background queue), callback on main thread.
//   Reads (lookupDuplicates) may be called from any thread; they run synchronously
//   on the caller's thread using the shared SQLite connection (WAL mode is safe
//   for concurrent readers).
//
// ─────────────────────────────────────────────────────────────────────────────
// SCHEMA NOTE — no migration needed
// ─────────────────────────────────────────────────────────────────────────────
//   This extension does NOT add any new tables or columns.
//   All queries target the existing `flights` table whose schema is established
//   by DatabaseManager.migrateSchema(). The flights table columns used here are:
//     id INTEGER PRIMARY KEY AUTOINCREMENT
//     date TEXT          — "yyyy-MM-dd"
//     aircraft_ident TEXT
//     aircraft_type  TEXT
//     route TEXT
//     total_time REAL
//     pic REAL, sic REAL, solo REAL, dual_received REAL, dual_given REAL,
//     cross_country REAL, night REAL, instrument_actual REAL,
//     instrument_simulated REAL, landings_day INTEGER, landings_night INTEGER,
//     approaches_count INTEGER, holds_count INTEGER,
//     remarks TEXT, is_legacy_import INTEGER, legacy_signature_path TEXT
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   DatabaseManager (core class with `db`, `dbQueue`, `SQLITE_TRANSIENT`)
//   DuplicateMatch  (defined in DuplicateDetector.swift — consumed here)
//   SQLite3 (via bridging header)

import Foundation
import SQLite3

// SQLITE_TRANSIENT is the standard workaround for the C macro Swift can't import.
private let SQLITE_TRANSIENT_DD = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DuplicateMatch
// ─────────────────────────────────────────────────────────────────────────────

/// A flight record from the existing logbook that matches a pending scan row.
/// Passed to DuplicateResolutionSheet for display and pilot decision-making.
public struct DuplicateMatch {

    /// SQLite row id of the existing flight record.
    public let existingId: Int64

    // MARK: Key fields (always populated)

    /// Date string in "yyyy-MM-dd" format.
    public let date: String

    /// Aircraft identifier (e.g. "N12345").
    public let aircraftIdent: String

    /// Aircraft type (e.g. "C172").
    public let aircraftType: String

    /// Total flight time in decimal hours.
    public let totalTime: Double

    // MARK: Supplementary display fields

    public let route:               String
    public let pic:                 Double
    public let dualReceived:        Double
    public let crossCountry:        Double
    public let night:               Double
    public let instrumentActual:    Double
    public let instrumentSimulated: Double
    public let landingsDay:         Int
    public let landingsNight:       Int
    public let remarks:             String

    // MARK: Match quality

    /// True when date + ident + total_time all match within tolerance.
    /// False when only date + ident match (candidate — pilot must confirm).
    public let isDefiniteMatch: Bool

    /// Human-readable description of why this was flagged as a duplicate.
    public var matchDescription: String {
        isDefiniteMatch
            ? "Exact match: date, aircraft, and total time are identical."
            : "Partial match: same date and aircraft, different total time (\(String(format: "%.1f", totalTime)) hrs existing)."
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DatabaseManager Extension
// ─────────────────────────────────────────────────────────────────────────────

extension DatabaseManager {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Duplicate Lookup (synchronous read)
    // ─────────────────────────────────────────────────────────────────────────

    /// Looks up existing flights that may conflict with a pending scan row.
    ///
    /// Runs synchronously on the calling thread. Safe to call from a background
    /// queue (DatabaseManager opens SQLite in WAL mode which allows concurrent readers).
    ///
    /// Strategy:
    ///   1. Query by date + aircraft_ident.
    ///   2. For each candidate, compute isDefiniteMatch by comparing total_time
    ///      within ±0.05 hours (handles tenths-digit OCR rounding).
    ///   3. Definite matches are sorted first; candidates follow.
    ///
    /// - Parameters:
    ///   - date:          Flight date string "yyyy-MM-dd".
    ///   - aircraftIdent: Aircraft tail number / ident.
    ///   - totalTime:     Resolved total flight time from OCR (decimal hours).
    ///
    /// - Returns: Array of DuplicateMatch, empty when no conflicts found.
    func lookupDuplicates(
        date:         String,
        aircraftIdent: String,
        totalTime:     Double
    ) -> [DuplicateMatch] {
        let sql = """
            SELECT id, date, aircraft_ident, aircraft_type, route,
                   total_time, pic, dual_received, cross_country,
                   night, instrument_actual, instrument_simulated,
                   landings_day, landings_night, remarks
            FROM flights
            WHERE date = ? AND aircraft_ident = ?
            ORDER BY total_time ASC;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            print("[DuplicateDetector] lookupDuplicates prepare error: \(err)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, date,          -1, SQLITE_TRANSIENT_DD)
        sqlite3_bind_text(stmt, 2, aircraftIdent, -1, SQLITE_TRANSIENT_DD)

        var matches: [DuplicateMatch] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let match = duplicateMatchFromStatement(stmt, incomingTotalTime: totalTime) else {
                continue
            }
            matches.append(match)
        }

        // Definite matches first — the UI always shows the most likely conflict at the top.
        return matches.sorted { $0.isDefiniteMatch && !$1.isDefiniteMatch }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Replace Existing Flight (async write)
    // ─────────────────────────────────────────────────────────────────────────

    /// Overwrites an existing flight record with new field values from a scan row.
    ///
    /// Uses UPDATE (not DELETE + INSERT) so the `id` primary key is preserved.
    /// Any associated signatures, endorsements, or navigation logs that reference
    /// this flight's id remain valid after the update.
    ///
    /// - Parameters:
    ///   - existingId: The SQLite row id of the record to overwrite.
    ///   - newValues:  Field dictionary in the same format as addFlight() accepts.
    ///   - completion: Called on the main thread — true on success, false on error.
    func replaceFlight(
        existingId: Int64,
        newValues:  [String: Any],
        completion: @escaping (Bool) -> Void
    ) {
        dbQueue.async { [weak self] in
            guard let self = self else { return }

            let sql = """
                UPDATE flights SET
                    date                  = ?,
                    aircraft_ident        = ?,
                    aircraft_type         = ?,
                    aircraft_category     = ?,
                    aircraft_class        = ?,
                    route                 = ?,
                    total_time            = ?,
                    pic                   = ?,
                    sic                   = ?,
                    solo                  = ?,
                    dual_received         = ?,
                    dual_given            = ?,
                    cross_country         = ?,
                    night                 = ?,
                    instrument_actual     = ?,
                    instrument_simulated  = ?,
                    landings_day          = ?,
                    landings_night        = ?,
                    approaches_count      = ?,
                    holds_count           = ?,
                    remarks               = ?,
                    is_legacy_import      = 0
                WHERE id = ?;
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(self.db))
                print("[DuplicateDetector] replaceFlight prepare error: \(err)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            defer { sqlite3_finalize(stmt) }

            self.bindFlightFields(stmt: stmt, values: newValues, startIndex: 1)
            sqlite3_bind_int64(stmt, 22, existingId)

            let ok = sqlite3_step(stmt) == SQLITE_DONE
            if !ok {
                let err = String(cString: sqlite3_errmsg(self.db))
                print("[DuplicateDetector] replaceFlight step error: \(err)")
            }

            DispatchQueue.main.async { completion(ok) }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Fetch Full Existing Flight (for side-by-side display)
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns all fields of an existing flight by id.
    /// Used by DuplicateResolutionSheet to build a side-by-side comparison table.
    /// Synchronous — call from background or main (WAL reader-safe).
    ///
    /// - Parameter id: The SQLite row id.
    /// - Returns: Field dictionary identical in structure to addFlight() input, or nil.
    func fetchFlightForComparison(id: Int64) -> [String: Any]? {
        let sql = """
            SELECT id, date, aircraft_ident, aircraft_type, aircraft_category,
                   aircraft_class, route, total_time, pic, sic, solo,
                   dual_received, dual_given, cross_country, night,
                   instrument_actual, instrument_simulated,
                   landings_day, landings_night, approaches_count, holds_count,
                   remarks
            FROM flights WHERE id = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return flightDictFromStatement(stmt)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Private Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func duplicateMatchFromStatement(
        _ stmt: OpaquePointer?,
        incomingTotalTime: Double
    ) -> DuplicateMatch? {
        guard let stmt = stmt else { return nil }

        let rowId       = sqlite3_column_int64(stmt, 0)
        let date        = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
        let ident       = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
        let acType      = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
        let route       = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
        let totalTime   = sqlite3_column_double(stmt, 5)
        let pic         = sqlite3_column_double(stmt, 6)
        let dualRx      = sqlite3_column_double(stmt, 7)
        let xc          = sqlite3_column_double(stmt, 8)
        let night       = sqlite3_column_double(stmt, 9)
        let instActual  = sqlite3_column_double(stmt, 10)
        let instSim     = sqlite3_column_double(stmt, 11)
        let ldgDay      = Int(sqlite3_column_int(stmt, 12))
        let ldgNight    = Int(sqlite3_column_int(stmt, 13))
        let remarks     = sqlite3_column_text(stmt, 14).flatMap { String(cString: $0) } ?? ""

        // Definite match: total_time within ±0.05 hrs (half a tenths digit)
        let timeDelta   = abs(totalTime - incomingTotalTime)
        let isDefinite  = timeDelta <= 0.05

        return DuplicateMatch(
            existingId:           rowId,
            date:                 date,
            aircraftIdent:        ident,
            aircraftType:         acType,
            totalTime:            totalTime,
            route:                route,
            pic:                  pic,
            dualReceived:         dualRx,
            crossCountry:         xc,
            night:                night,
            instrumentActual:     instActual,
            instrumentSimulated:  instSim,
            landingsDay:          ldgDay,
            landingsNight:        ldgNight,
            remarks:              remarks,
            isDefiniteMatch:      isDefinite
        )
    }

    /// Binds the standard flight field dictionary to a prepared statement
    /// starting at `startIndex`. Column order matches replaceFlight SQL above.
    private func bindFlightFields(
        stmt:       OpaquePointer?,
        values:     [String: Any],
        startIndex: Int32
    ) {
        func str(_ key: String) -> String  { values[key] as? String ?? "" }
        func dbl(_ key: String) -> Double  { values[key] as? Double ?? 0.0 }
        func int(_ key: String) -> Int32   { Int32(values[key] as? Int ?? 0) }

        var i = startIndex
        sqlite3_bind_text  (stmt, i, str("date"),                 -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_text  (stmt, i, str("aircraft_ident"),       -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_text  (stmt, i, str("aircraft_type"),        -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_text  (stmt, i, str("aircraft_category"),    -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_text  (stmt, i, str("aircraft_class"),       -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_text  (stmt, i, str("route"),                -1, SQLITE_TRANSIENT_DD); i += 1
        sqlite3_bind_double(stmt, i, dbl("total_time"));                                    i += 1
        sqlite3_bind_double(stmt, i, dbl("pic"));                                           i += 1
        sqlite3_bind_double(stmt, i, dbl("sic"));                                           i += 1
        sqlite3_bind_double(stmt, i, dbl("solo"));                                          i += 1
        sqlite3_bind_double(stmt, i, dbl("dual_received"));                                 i += 1
        sqlite3_bind_double(stmt, i, dbl("dual_given"));                                    i += 1
        sqlite3_bind_double(stmt, i, dbl("cross_country"));                                 i += 1
        sqlite3_bind_double(stmt, i, dbl("night"));                                         i += 1
        sqlite3_bind_double(stmt, i, dbl("instrument_actual"));                             i += 1
        sqlite3_bind_double(stmt, i, dbl("instrument_simulated"));                          i += 1
        sqlite3_bind_int   (stmt, i, int("landings_day"));                                  i += 1
        sqlite3_bind_int   (stmt, i, int("landings_night"));                                i += 1
        sqlite3_bind_int   (stmt, i, int("approaches_count"));                              i += 1
        sqlite3_bind_int   (stmt, i, int("holds_count"));                                   i += 1
        sqlite3_bind_text  (stmt, i, str("remarks"),              -1, SQLITE_TRANSIENT_DD); i += 1
    }

    /// Reads a full flight row from a prepared statement into a [String: Any] dict.
    /// Column order must match fetchFlightForComparison SELECT.
    private func flightDictFromStatement(_ stmt: OpaquePointer?) -> [String: Any]? {
        guard let stmt = stmt else { return nil }
        return [
            "id":                   sqlite3_column_int64(stmt, 0),
            "date":                 sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? "",
            "aircraft_ident":       sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? "",
            "aircraft_type":        sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? "",
            "aircraft_category":    sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? "",
            "aircraft_class":       sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? "",
            "route":                sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "",
            "total_time":           sqlite3_column_double(stmt, 7),
            "pic":                  sqlite3_column_double(stmt, 8),
            "sic":                  sqlite3_column_double(stmt, 9),
            "solo":                 sqlite3_column_double(stmt, 10),
            "dual_received":        sqlite3_column_double(stmt, 11),
            "dual_given":           sqlite3_column_double(stmt, 12),
            "cross_country":        sqlite3_column_double(stmt, 13),
            "night":                sqlite3_column_double(stmt, 14),
            "instrument_actual":    sqlite3_column_double(stmt, 15),
            "instrument_simulated": sqlite3_column_double(stmt, 16),
            "landings_day":         Int(sqlite3_column_int(stmt, 17)),
            "landings_night":       Int(sqlite3_column_int(stmt, 18)),
            "approaches_count":     Int(sqlite3_column_int(stmt, 19)),
            "holds_count":          Int(sqlite3_column_int(stmt, 20)),
            "remarks":              sqlite3_column_text(stmt, 21).flatMap { String(cString: $0) } ?? ""
        ]
    }
}
