// DatabaseManager+Profile.swift — AeroBook
//
// FAA Medical expiry rules (14 CFR 61.23):
//   Class 1  age < 40  → 12 calendar months
//   Class 1  age ≥ 40  → 6 calendar months
//   Class 2  any age   → 12 calendar months
//   Class 3  age < 40  → 60 calendar months
//   Class 3  age ≥ 40  → 24 calendar months
//   BasicMed            → 24 calendar months from AOPA course
//   None                → N/A

import Foundation
import SQLite3

// MARK: - Models

struct AircraftRecord: Identifiable, Equatable {
    var id: String { registration }
    var registration: String
    var make: String
    var model: String
    var year: Int
    var engineType: String
    var category: String
    var aircraftClass: String
    var isComplex: Bool
    var isHighPerf: Bool
    var isTAA: Bool
    var notes: String
}

struct InstructorRecord: Identifiable, Equatable {
    var id: Int64
    var name: String
    var certificateNumber: String
    var ratings: [String]           // e.g. ["CFI", "CFII"] — stored as comma-separated in DB
    var notes: String
    var usedForManualEntry: Bool    // when true, pre-fills CFI field in manual flight entry
                                    // scanner uses ALL instructors regardless of this flag
}

// MARK: - Simulator Model

/// FAA simulator device types (14 CFR Part 61 / AC 61-136):
///   FFS  — Full Flight Simulator (Level A–D, highest fidelity)
///   FTD  — Flight Training Device (Level 1–7)
///   ATD  — Aviation Training Device (generic legacy term)
///   BATD — Basic Aviation Training Device
///   AATD — Advanced Aviation Training Device
struct SimulatorRecord: Identifiable, Equatable {
    var id: Int64                   // autoincrement PK
    var name: String                // user-assigned name, e.g. "Redbird TD2" or "Club Frasca 141"
    var deviceType: String          // "FFS", "FTD", "BATD", "AATD", "ATD", "PCATDx"
    var approvalLevel: String       // e.g. "Level D", "Level 6", "FAA Approved", "Non-certified"
    var make: String                // manufacturer, e.g. "Redbird", "Frasca", "Elite"
    var model: String               // device model, e.g. "TD2", "141", "PCATD"
    var aircraftSimulated: String   // e.g. "C172", "PA-28" — what the sim represents
    var location: String            // e.g. "KCDW Flight School"
    var notes: String
}

// MARK: - FAA Medical Rules


struct FAAMedical {

    enum MedicalType: String, CaseIterable {
        case standard1 = "Standard 1"
        case standard2 = "Standard 2"
        case standard3 = "Standard 3"
        case basicMed  = "BasicMed"
        case none      = "None"

        var displayName: String { rawValue }

        var classNumber: Int? {
            switch self {
            case .standard1: return 1
            case .standard2: return 2
            case .standard3: return 3
            default: return nil
            }
        }
    }

    static func expiryDate(examDate: Date, type: MedicalType, dateOfBirth: Date?) -> Date? {
        let cal = Calendar.current
        switch type {
        case .none:
            return nil
        case .basicMed:
            return cal.date(byAdding: .month, value: 24, to: examDate)
        case .standard1:
            let months: Int
            if let dob = dateOfBirth {
                let age = cal.dateComponents([.year], from: dob, to: examDate).year ?? 0
                months = age >= 40 ? 6 : 12
            } else { months = 6 }
            return cal.date(byAdding: .month, value: months, to: examDate)
        case .standard2:
            return cal.date(byAdding: .month, value: 12, to: examDate)
        case .standard3:
            let months: Int
            if let dob = dateOfBirth {
                let age = cal.dateComponents([.year], from: dob, to: examDate).year ?? 0
                months = age >= 40 ? 24 : 60
            } else { months = 24 }
            return cal.date(byAdding: .month, value: months, to: examDate)
        }
    }

    static func ruleDescription(type: MedicalType, dateOfBirth: Date?) -> String {
        switch type {
        case .none:
            return "No medical required"
        case .basicMed:
            return "Valid 24 months from AOPA online course completion"
        case .standard1:
            if let dob = dateOfBirth {
                let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
                return age >= 40 ? "Class 1 · 6 months (age \(age) ≥ 40)" : "Class 1 · 12 months (age \(age) < 40)"
            }
            return "Class 1 · 6 months (≥40) or 12 months (<40) — add birthdate for exact rule"
        case .standard2:
            return "Class 2 · 12 months (all ages)"
        case .standard3:
            if let dob = dateOfBirth {
                let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
                return age >= 40 ? "Class 3 · 24 months (age \(age) ≥ 40)" : "Class 3 · 60 months (age \(age) < 40)"
            }
            return "Class 3 · 24 months (≥40) or 60 months (<40) — add birthdate for exact rule"
        }
    }
}

// MARK: - DatabaseManager Extension

extension DatabaseManager {

    // MARK: - Schema Migration

    func migrateProfileAndAircraft() {

        // user_profile new columns
        let profileColumns: [(String, String)] = [
            ("country_code",      "TEXT DEFAULT 'US'"),
            ("home_airport",      "TEXT DEFAULT ''"),
            ("home_airport_name", "TEXT DEFAULT ''"),
            ("timezone_id",       "TEXT DEFAULT 'America/New_York'"),
            ("app_tier",          "TEXT DEFAULT 'student'"),
            ("medical_expiry",    "TEXT DEFAULT ''"),
            ("date_of_birth",     "TEXT DEFAULT ''"),
        ]
        for (col, def) in profileColumns {
            var stmt: OpaquePointer?
            let sql = "ALTER TABLE user_profile ADD COLUMN \(col) \(def);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK { sqlite3_step(stmt) }
            sqlite3_finalize(stmt)
        }

        // aircraft_registry — create with registration PK if not exists
        runSQL("""
        CREATE TABLE IF NOT EXISTS aircraft_registry_new (
            registration    TEXT PRIMARY KEY,
            make            TEXT DEFAULT '',
            model           TEXT DEFAULT '',
            year            INTEGER DEFAULT 0,
            engine_type     TEXT DEFAULT 'Piston',
            category        TEXT DEFAULT 'Airplane',
            aircraft_class  TEXT DEFAULT 'ASEL',
            is_complex      INTEGER DEFAULT 0,
            is_high_perf    INTEGER DEFAULT 0,
            is_taa          INTEGER DEFAULT 0,
            notes           TEXT DEFAULT '',
            last_updated    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )
        """)

        // If old table has n_number column, copy rows then replace
        if columnExists(table: "aircraft_registry", column: "n_number") {
            runSQL("""
            INSERT OR IGNORE INTO aircraft_registry_new
                (registration, make, model, year, engine_type,
                 category, aircraft_class, is_complex, is_high_perf, is_taa)
            SELECT
                COALESCE(NULLIF(n_number,''), 'UNKNOWN'),
                COALESCE(make,''), COALESCE(model,''), COALESCE(year,0),
                COALESCE(engine_type,'Piston'), COALESCE(category,'Airplane'),
                COALESCE(aircraft_class,'ASEL'),
                COALESCE(is_complex,0), COALESCE(is_high_perf,0), COALESCE(is_taa,0)
            FROM aircraft_registry
            """)
            runSQL("DROP TABLE aircraft_registry")
            runSQL("ALTER TABLE aircraft_registry_new RENAME TO aircraft_registry")
        } else {
            // No n_number column — either already migrated or fresh install.
            // Ensure aircraft_registry itself exists (fresh install case).
            runSQL("""
            CREATE TABLE IF NOT EXISTS aircraft_registry (
                registration    TEXT PRIMARY KEY,
                make            TEXT DEFAULT '',
                model           TEXT DEFAULT '',
                year            INTEGER DEFAULT 0,
                engine_type     TEXT DEFAULT 'Piston',
                category        TEXT DEFAULT 'Airplane',
                aircraft_class  TEXT DEFAULT 'ASEL',
                is_complex      INTEGER DEFAULT 0,
                is_high_perf    INTEGER DEFAULT 0,
                is_taa          INTEGER DEFAULT 0,
                notes           TEXT DEFAULT '',
                last_updated    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
            )
            """)
            runSQL("DROP TABLE IF EXISTS aircraft_registry_new")
        }

        // scan_instructors
        runSQL("""
        CREATE TABLE IF NOT EXISTS scan_instructors (
            id                      INTEGER PRIMARY KEY AUTOINCREMENT,
            name                    TEXT NOT NULL DEFAULT '',
            certificate_number      TEXT DEFAULT '',
            ratings                 TEXT DEFAULT 'CFI',
            notes                   TEXT DEFAULT '',
            used_for_manual_entry   INTEGER DEFAULT 0,
            created_at              TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )
        """)
        // Migrate old column names if needed
        runSQL("ALTER TABLE scan_instructors ADD COLUMN ratings TEXT DEFAULT 'CFI';")
        runSQL("UPDATE scan_instructors SET ratings = rating WHERE ratings IS NULL OR ratings = '' AND rating IS NOT NULL;")
        runSQL("ALTER TABLE scan_instructors ADD COLUMN used_for_manual_entry INTEGER DEFAULT 0;")

        // sim_devices table
        runSQL("""
        CREATE TABLE IF NOT EXISTS sim_devices (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            name                TEXT NOT NULL DEFAULT '',
            device_type         TEXT DEFAULT 'BATD',
            approval_level      TEXT DEFAULT 'FAA Approved',
            make                TEXT DEFAULT '',
            model               TEXT DEFAULT '',
            aircraft_simulated  TEXT DEFAULT '',
            location            TEXT DEFAULT '',
            notes               TEXT DEFAULT '',
            last_updated        TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        )
        """)
    }

    // MARK: - Private helpers

    private func runSQL(_ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK { sqlite3_step(stmt) }
        sqlite3_finalize(stmt)
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name='\(column)';"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - FullProfile

    struct FullProfile {
        var pilotName:        String = ""
        var ftn:              String = ""
        var pilotCertificate: String = ""
        var certificateNumber:String = ""
        var medicalType:      String = "Standard 3"
        var medicalClass:     Int    = 3
        var medicalDate:      String = ""
        var medicalExpiry:    String = ""
        var dateOfBirth:      String = ""
        var countryCode:      String = "US"
        var homeAirport:      String = ""
        var homeAirportName:  String = ""
        var timezoneId:       String = "America/New_York"
        var appTier:          String = "student"
    }

    func fetchFullProfile() -> FullProfile {
        let sql = """
        SELECT
            COALESCE(pilot_name,''),
            COALESCE(ftn,''),
            COALESCE(pilot_certificate,''),
            COALESCE(certificate_number,''),
            COALESCE(medical_type,'Standard 3'),
            COALESCE(medical_class,3),
            COALESCE(medical_date,''),
            COALESCE(medical_expiry,''),
            COALESCE(date_of_birth,''),
            COALESCE(country_code,'US'),
            COALESCE(home_airport,''),
            COALESCE(home_airport_name,''),
            COALESCE(timezone_id,'America/New_York'),
            COALESCE(app_tier,'student')
        FROM user_profile WHERE id = 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var p = FullProfile()
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return p }

        func txt(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        p.pilotName         = txt(0)
        p.ftn               = txt(1)
        p.pilotCertificate  = txt(2)
        p.certificateNumber = txt(3)
        p.medicalType       = txt(4)
        p.medicalClass      = Int(sqlite3_column_int(stmt, 5))
        p.medicalDate       = txt(6)
        p.medicalExpiry     = txt(7)
        p.dateOfBirth       = txt(8)
        p.countryCode       = txt(9)
        p.homeAirport       = txt(10)
        p.homeAirportName   = txt(11)
        p.timezoneId        = txt(12)
        p.appTier           = txt(13)
        return p
    }

    func updateFullProfile(_ p: FullProfile, completion: ((Bool) -> Void)? = nil) {
        let medClass: Int
        switch FAAMedical.MedicalType(rawValue: p.medicalType) {
        case .standard1: medClass = 1
        case .standard2: medClass = 2
        default:         medClass = 3
        }
        dbQueue.async {
            // Guarantee the seed row exists before updating
            self.runSQL("INSERT OR IGNORE INTO user_profile (id, pilot_name, medical_class) VALUES (1, \'\', 3);")

            let sql = """
            UPDATE user_profile SET
                pilot_name          = ?,
                ftn                 = ?,
                pilot_certificate   = ?,
                certificate_number  = ?,
                medical_type        = ?,
                medical_class       = ?,
                medical_date        = ?,
                medical_expiry      = ?,
                date_of_birth       = ?,
                country_code        = ?,
                home_airport        = ?,
                home_airport_name   = ?,
                timezone_id         = ?,
                app_tier            = ?
            WHERE id = 1;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[Profile] prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            sqlite3_bind_text(stmt,  1, p.pilotName,         -1, sqliteTransient)
            sqlite3_bind_text(stmt,  2, p.ftn,               -1, sqliteTransient)
            sqlite3_bind_text(stmt,  3, p.pilotCertificate,  -1, sqliteTransient)
            sqlite3_bind_text(stmt,  4, p.certificateNumber, -1, sqliteTransient)
            sqlite3_bind_text(stmt,  5, p.medicalType,       -1, sqliteTransient)
            sqlite3_bind_int(stmt,   6, Int32(medClass))
            sqlite3_bind_text(stmt,  7, p.medicalDate,       -1, sqliteTransient)
            sqlite3_bind_text(stmt,  8, p.medicalExpiry,     -1, sqliteTransient)
            sqlite3_bind_text(stmt,  9, p.dateOfBirth,       -1, sqliteTransient)
            sqlite3_bind_text(stmt, 10, p.countryCode,       -1, sqliteTransient)
            sqlite3_bind_text(stmt, 11, p.homeAirport,       -1, sqliteTransient)
            sqlite3_bind_text(stmt, 12, p.homeAirportName,   -1, sqliteTransient)
            sqlite3_bind_text(stmt, 13, p.timezoneId,        -1, sqliteTransient)
            sqlite3_bind_text(stmt, 14, p.appTier,           -1, sqliteTransient)
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            if !ok { print("[Profile] update failed: \(String(cString: sqlite3_errmsg(self.db)))") }
            DispatchQueue.main.async {
                if ok { NotificationCenter.default.post(name: .logbookDataDidChange, object: nil) }
                completion?(ok)
            }
        }
    }

    // MARK: - Aircraft CRUD

    func fetchAllAircraft() -> [AircraftRecord] {
        let sql = """
        SELECT registration, make, model, year, engine_type,
               category, aircraft_class, is_complex, is_high_perf, is_taa,
               COALESCE(notes,'')
        FROM aircraft_registry ORDER BY registration ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [AircraftRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        func txt(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(AircraftRecord(
                registration: txt(0), make: txt(1), model: txt(2),
                year:         Int(sqlite3_column_int(stmt, 3)),
                engineType:   txt(4), category: txt(5), aircraftClass: txt(6),
                isComplex:    sqlite3_column_int(stmt, 7) != 0,
                isHighPerf:   sqlite3_column_int(stmt, 8) != 0,
                isTAA:        sqlite3_column_int(stmt, 9) != 0,
                notes:        txt(10)
            ))
        }
        return results
    }

    /// Save aircraft using DELETE + INSERT to support all SQLite versions.
    func saveAircraft(_ aircraft: AircraftRecord, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            // Step 1: delete existing row (no-op if new registration)
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "DELETE FROM aircraft_registry WHERE registration = ?;",
                                  -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, aircraft.registration, -1, sqliteTransient)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            // Step 2: insert
            let sql = """
            INSERT INTO aircraft_registry
                (registration, make, model, year, engine_type,
                 category, aircraft_class, is_complex, is_high_perf, is_taa, notes, last_updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
            """
            var ins: OpaquePointer?
            defer { sqlite3_finalize(ins) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &ins, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(ins,  1, aircraft.registration,  -1, sqliteTransient)
            sqlite3_bind_text(ins,  2, aircraft.make,          -1, sqliteTransient)
            sqlite3_bind_text(ins,  3, aircraft.model,         -1, sqliteTransient)
            sqlite3_bind_int(ins,   4, Int32(aircraft.year))
            sqlite3_bind_text(ins,  5, aircraft.engineType,    -1, sqliteTransient)
            sqlite3_bind_text(ins,  6, aircraft.category,      -1, sqliteTransient)
            sqlite3_bind_text(ins,  7, aircraft.aircraftClass, -1, sqliteTransient)
            sqlite3_bind_int(ins,   8, aircraft.isComplex  ? 1 : 0)
            sqlite3_bind_int(ins,   9, aircraft.isHighPerf ? 1 : 0)
            sqlite3_bind_int(ins,  10, aircraft.isTAA      ? 1 : 0)
            sqlite3_bind_text(ins, 11, aircraft.notes,         -1, sqliteTransient)
            let ok = sqlite3_step(ins) == SQLITE_DONE
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func deleteAircraft(registration: String, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db,
                "DELETE FROM aircraft_registry WHERE registration = ?;",
                -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(stmt, 1, registration, -1, sqliteTransient)
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Rename registration (PK change) — deletes old row and inserts updated one atomically.
    /// Also updates aircraft_ident in flights table so logbook history stays consistent.
    func renameAircraft(oldRegistration: String, updated: AircraftRecord,
                        completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            self.runSQL("BEGIN;")

            // 1. Insert new row
            let ins = """
            INSERT INTO aircraft_registry
                (registration, make, model, year, engine_type,
                 category, aircraft_class, is_complex, is_high_perf, is_taa, notes, last_updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
            """
            var insStmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, ins, -1, &insStmt, nil) == SQLITE_OK else {
                self.runSQL("ROLLBACK;")
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(insStmt,  1, updated.registration,  -1, sqliteTransient)
            sqlite3_bind_text(insStmt,  2, updated.make,          -1, sqliteTransient)
            sqlite3_bind_text(insStmt,  3, updated.model,         -1, sqliteTransient)
            sqlite3_bind_int(insStmt,   4, Int32(updated.year))
            sqlite3_bind_text(insStmt,  5, updated.engineType,    -1, sqliteTransient)
            sqlite3_bind_text(insStmt,  6, updated.category,      -1, sqliteTransient)
            sqlite3_bind_text(insStmt,  7, updated.aircraftClass, -1, sqliteTransient)
            sqlite3_bind_int(insStmt,   8, updated.isComplex  ? 1 : 0)
            sqlite3_bind_int(insStmt,   9, updated.isHighPerf ? 1 : 0)
            sqlite3_bind_int(insStmt,  10, updated.isTAA      ? 1 : 0)
            sqlite3_bind_text(insStmt, 11, updated.notes,         -1, sqliteTransient)
            let insOk = sqlite3_step(insStmt) == SQLITE_DONE
            sqlite3_finalize(insStmt)

            guard insOk else {
                self.runSQL("ROLLBACK;")
                DispatchQueue.main.async { completion(false) }; return
            }

            // 2. Update flight records so history stays linked to new registration
            let upd = "UPDATE flights SET aircraft_ident = ? WHERE aircraft_ident = ?;"
            var updStmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, upd, -1, &updStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(updStmt, 1, updated.registration, -1, sqliteTransient)
                sqlite3_bind_text(updStmt, 2, oldRegistration,      -1, sqliteTransient)
                sqlite3_step(updStmt)
            }
            sqlite3_finalize(updStmt)

            // 3. Delete old row
            let del = "DELETE FROM aircraft_registry WHERE registration = ?;"
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, del, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, oldRegistration, -1, sqliteTransient)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            self.runSQL("COMMIT;")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                completion(true)
            }
        }
    }

    // MARK: - Instructors CRUD

    func fetchAllInstructors() -> [InstructorRecord] {
        let sql = """
        SELECT id, name, certificate_number,
               COALESCE(ratings, COALESCE(rating, 'CFI')),
               COALESCE(notes,''),
               COALESCE(used_for_manual_entry, 0)
        FROM scan_instructors ORDER BY name ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [InstructorRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        func txt(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ratingsRaw = txt(3)
            let ratingsArr = ratingsRaw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            results.append(InstructorRecord(
                id: sqlite3_column_int64(stmt, 0),
                name: txt(1), certificateNumber: txt(2),
                ratings: ratingsArr.isEmpty ? ["CFI"] : ratingsArr,
                notes: txt(4),
                usedForManualEntry: sqlite3_column_int(stmt, 5) != 0
            ))
        }
        return results
    }

    func saveInstructor(_ instructor: InstructorRecord, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            let isNew = instructor.id == 0
            let ratingsStr = instructor.ratings.joined(separator: ",")
            let sql = isNew
                ? "INSERT INTO scan_instructors (name,certificate_number,ratings,notes,used_for_manual_entry) VALUES (?,?,?,?,?);"
                : "UPDATE scan_instructors SET name=?,certificate_number=?,ratings=?,notes=?,used_for_manual_entry=? WHERE id=?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(stmt, 1, instructor.name,              -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, instructor.certificateNumber, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, ratingsStr,                   -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, instructor.notes,             -1, sqliteTransient)
            sqlite3_bind_int(stmt,  5, instructor.usedForManualEntry ? 1 : 0)
            if !isNew { sqlite3_bind_int64(stmt, 6, instructor.id) }
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            if !ok { print("[Instructor] save failed: \(String(cString: sqlite3_errmsg(self.db)))") }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func deleteInstructor(id: Int64, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db,
                "DELETE FROM scan_instructors WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_int64(stmt, 1, id)
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Simulator CRUD

    func fetchAllSimulators() -> [SimulatorRecord] {
        let sql = """
        SELECT id, name, device_type, approval_level, make, model,
               COALESCE(aircraft_simulated,''), COALESCE(location,''), COALESCE(notes,'')
        FROM sim_devices ORDER BY name ASC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [SimulatorRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        func txt(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(SimulatorRecord(
                id:                sqlite3_column_int64(stmt, 0),
                name:              txt(1),
                deviceType:        txt(2),
                approvalLevel:     txt(3),
                make:              txt(4),
                model:             txt(5),
                aircraftSimulated: txt(6),
                location:          txt(7),
                notes:             txt(8)
            ))
        }
        return results
    }

    func saveSimulator(_ sim: SimulatorRecord, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            let isNew = sim.id == 0
            let sql = isNew
                ? """
                  INSERT INTO sim_devices
                      (name, device_type, approval_level, make, model,
                       aircraft_simulated, location, notes, last_updated)
                  VALUES (?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
                  """
                : """
                  UPDATE sim_devices SET
                      name=?, device_type=?, approval_level=?, make=?, model=?,
                      aircraft_simulated=?, location=?, notes=?,
                      last_updated=strftime('%Y-%m-%dT%H:%M:%SZ','now')
                  WHERE id=?;
                  """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[Sim] prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(stmt, 1, sim.name,              -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, sim.deviceType,        -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, sim.approvalLevel,     -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, sim.make,              -1, sqliteTransient)
            sqlite3_bind_text(stmt, 5, sim.model,             -1, sqliteTransient)
            sqlite3_bind_text(stmt, 6, sim.aircraftSimulated, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 7, sim.location,          -1, sqliteTransient)
            sqlite3_bind_text(stmt, 8, sim.notes,             -1, sqliteTransient)
            if !isNew { sqlite3_bind_int64(stmt, 9, sim.id) }
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            if !ok { print("[Sim] save failed: \(String(cString: sqlite3_errmsg(self.db)))") }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func deleteSimulator(id: Int64, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db,
                "DELETE FROM sim_devices WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else {
                DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_int64(stmt, 1, id)
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
