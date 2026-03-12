import Foundation
import SQLite3
import CryptoKit

extension Notification.Name {
    static let logbookDataDidChange = Notification.Name("logbookDataDidChange")
}

/**
 * AeroBook DatabaseManager
 * A 100% Local-First Swift service using the system's built-in libsqlite3.
 * No external dependencies required.
 */
// File-scope constant — accessible inside dbQueue.async closures without `self`
// Internal (not private) — needed by DatabaseManager extensions in other files
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class DatabaseManager {
    static let shared = DatabaseManager()
    
    var db: OpaquePointer? // TODO: revert to private once OCR pipeline is stable
    // Internal (not private) — needed by DatabaseManager extensions in other files
    let dbQueue = DispatchQueue(label: "com.aerobook.dbQueue", qos: .userInitiated)
    
    // SQLITE_TRANSIENT tells SQLite to copy the string immediately so Swift ARC
    // can free the original without a use-after-free crash.
    // Declared as a file-level constant (not an instance property) so closures
    // can reference it without capturing `self`, avoiding the
    // "explicit use of 'self'" compiler error in dbQueue.async closures.
    // unsafeBitCast from -1 is the canonical way to get SQLITE_TRANSIENT in Swift
    // (the C macro expands to (sqlite3_destructor_type)-1).
    
    private init() {
        setupDatabase()
    }
    
    private func setupDatabase() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        if !fileManager.fileExists(atPath: appSupportURL.path) {
            try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        let dbURL = appSupportURL.appendingPathComponent("aerobook.sqlite")
        
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("Error opening database")
            return
        }
        
        // WAL mode: allows concurrent reads while a write is in progress.
        // Without this, a background addFlightsBatch write holds an exclusive
        // lock and synchronous fetchFlightsByDateRange returns SQLITE_BUSY → empty.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        
        createTables()
    }
    
    private func createTables() {
        let createFlightsTable = """
        CREATE TABLE IF NOT EXISTS flights (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT,
            aircraft_type TEXT,
            aircraft_ident TEXT,
            aircraft_category TEXT,
            aircraft_class TEXT,
            route TEXT,
            total_time REAL,
            pic REAL,
            sic REAL,
            solo REAL,
            dual_received REAL,
            dual_given REAL,
            cross_country REAL,
            night REAL,
            instrument_actual REAL,
            instrument_simulated REAL,
            flight_sim REAL DEFAULT 0.0,
            takeoffs INTEGER DEFAULT 0,
            landings_day INTEGER,
            landings_night INTEGER,
            approaches_count INTEGER DEFAULT 0,
            holds_count INTEGER DEFAULT 0,
            nav_tracking INTEGER DEFAULT 0,
            remarks TEXT,
            signature_blob TEXT,
            signature_hash TEXT,
            cfi_name TEXT,
            cfi_certificate TEXT,
            is_signed INTEGER DEFAULT 0,
            is_legacy_import INTEGER DEFAULT 0,
            legacy_signature_path TEXT,
            is_verified INTEGER DEFAULT 0,
            verified_at TEXT DEFAULT ''
        );
        """
        
        let createUserProfileTable = """
        CREATE TABLE IF NOT EXISTS user_profile (
            id INTEGER PRIMARY KEY DEFAULT 1,
            pilot_name TEXT,
            medical_date TEXT,
            medical_class INTEGER,
            medical_type TEXT DEFAULT 'Class 3',
            certificate_number TEXT,
            pilot_certificate TEXT,
            ftn TEXT
        );
        """
        
        let createEndorsementsTable = """
        CREATE TABLE IF NOT EXISTS endorsements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            template_id TEXT,
            title TEXT,
            text TEXT,
            date TEXT,
            instructor_name TEXT,
            instructor_certificate TEXT,
            signature_blob TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        
        execute(sql: createFlightsTable)
        execute(sql: createUserProfileTable)
        execute(sql: createEndorsementsTable)
        
        migrateSchema()
        
        // Native SQLite View for Dashboard Stats
        let createStatsView = """
        CREATE VIEW IF NOT EXISTS v_dashboard_stats AS
        SELECT 
            SUM(total_time) as total,
            SUM(pic) as pic,
            SUM(cross_country) as xc,
            SUM(instrument_actual) as inst_actual,
            SUM(instrument_simulated) as inst_simulated
        FROM flights;
        """
        execute(sql: createStatsView)
        
        // Seed user profile if empty
        execute(sql: "INSERT OR IGNORE INTO user_profile (id, pilot_name, medical_class) VALUES (1, 'Pilot Name', 1);")
    }
    
    private func execute(sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error executing SQL: \(sql)")
            }
        } else {
            print("Error preparing SQL: \(sql)")
        }
        sqlite3_finalize(statement)
    }
    
    private func migrateSchema() {
        // Add missing columns — failure means already exists, which is fine.
        let columnsToAdd: [(String, String, String)] = [
            ("flights",      "is_verified",     "INTEGER DEFAULT 0"),
            ("flights",      "verified_at",     "TEXT DEFAULT ''"),
            ("flights",      "approaches_count", "INTEGER DEFAULT 0"),
            ("flights",      "holds_count",      "INTEGER DEFAULT 0"),
            ("flights",      "nav_tracking",     "INTEGER DEFAULT 0"),
            ("flights",      "flight_sim",       "REAL DEFAULT 0.0"),
            ("flights",      "takeoffs",         "INTEGER DEFAULT 0"),
            ("flights",      "created_at",       "TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))"),
            ("user_profile", "medical_type",     "TEXT DEFAULT 'Class 3'"),
            ("user_profile", "pilot_certificate","TEXT"),
            ("user_profile", "ftn",              "TEXT")
        ]
        for (table, column, colType) in columnsToAdd {
            let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(colType);"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK { sqlite3_step(statement) }
            sqlite3_finalize(statement)
        }

        // Profile extension — adds country_code, date_of_birth, aircraft_registry,
        // scan_instructors. Safe to call every launch (all ops are idempotent).
        migrateProfileAndAircraft()
    }

    // MARK: - Last Saved Timestamp

    /// Returns the date of the most recently inserted flight row.
    ///
    /// Three crash sources fixed vs the original:
    ///  1. Serial queue deadlock — `addFlight` completion posts `logbookDataDidChange`
    ///     on main; if any observer calls this back on `dbQueue` it deadlocks.
    ///     Fixed: this is a read-only query, runs on whatever thread calls it
    ///     (SQLite in serialized mode is safe; we never write here).
    ///  2. NULL crash — `created_at` is NULL for rows that existed before the
    ///     migration added the column. `String(cString:)` on a null pointer is
    ///     undefined behaviour → EXC_BREAKPOINT. Fixed: COALESCE to `date`, plus
    ///     explicit nil-guard on the raw pointer before constructing the String.
    ///  3. Wrong date formatter — SQLite strftime produces "2026-03-01T19:32:38Z"
    ///     (no milliseconds). ISO8601DateFormatter with .withInternetDateTime
    ///     requires milliseconds and silently returns nil. Fixed: try multiple formats.
    func fetchLastFlightSavedAt() -> Date? {
        // COALESCE: use created_at when present, plain flight date otherwise
        let sql = """
            SELECT COALESCE(NULLIF(created_at,''), date)
            FROM flights
            ORDER BY id DESC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return nil }

        // Explicit nil-guard: sqlite3_column_text returns NULL pointer for SQL NULL
        guard let rawPtr = sqlite3_column_text(statement, 0) else { return nil }
        let raw = String(cString: rawPtr)
        guard !raw.isEmpty else { return nil }

        // Try every format SQLite or the importer may produce
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in [
            "yyyy-MM-dd'T'HH:mm:ssZ",      // SQLite strftime default with Z
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",  // with milliseconds
            "yyyy-MM-dd'T'HH:mm:ss",       // no timezone
            "yyyy-MM-dd",                  // plain flight date fallback
        ] {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }
    
    // MARK: - CRUD Operations
    
    func addFlight(_ flightData: [String: Any], completion: @escaping (Int64?) -> Void) {
        dbQueue.async {
            let sql = """
            INSERT INTO flights (
                date, aircraft_type, aircraft_ident, aircraft_category, aircraft_class,
                route, total_time, pic, sic, solo, dual_received, dual_given,
                cross_country, night, instrument_actual, instrument_simulated,
                flight_sim, takeoffs, landings_day, landings_night, approaches_count, 
                holds_count, nav_tracking, remarks, is_legacy_import, legacy_signature_path
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1,  (flightData["date"]                as? String ?? ""), -1, sqliteTransient)
                sqlite3_bind_text(statement, 2,  (flightData["aircraft_type"]       as? String ?? ""), -1, sqliteTransient)
                sqlite3_bind_text(statement, 3,  (flightData["aircraft_ident"]      as? String ?? ""), -1, sqliteTransient)
                sqlite3_bind_text(statement, 4,  (flightData["aircraft_category"]   as? String ?? "Airplane"), -1, sqliteTransient)
                sqlite3_bind_text(statement, 5,  (flightData["aircraft_class"]      as? String ?? "SEL"), -1, sqliteTransient)
                sqlite3_bind_text(statement, 6,  (flightData["route"]               as? String ?? ""), -1, sqliteTransient)
                sqlite3_bind_double(statement, 7,  (flightData["total_time"]        as? Double ?? 0.0))
                sqlite3_bind_double(statement, 8,  (flightData["pic"]               as? Double ?? 0.0))
                sqlite3_bind_double(statement, 9,  (flightData["sic"]               as? Double ?? 0.0))
                sqlite3_bind_double(statement, 10, (flightData["solo"]              as? Double ?? 0.0))
                sqlite3_bind_double(statement, 11, (flightData["dual_received"]     as? Double ?? 0.0))
                sqlite3_bind_double(statement, 12, (flightData["dual_given"]        as? Double ?? 0.0))
                sqlite3_bind_double(statement, 13, (flightData["cross_country"]     as? Double ?? 0.0))
                sqlite3_bind_double(statement, 14, (flightData["night"]             as? Double ?? 0.0))
                sqlite3_bind_double(statement, 15, (flightData["instrument_actual"] as? Double ?? 0.0))
                sqlite3_bind_double(statement, 16, (flightData["instrument_simulated"] as? Double ?? 0.0))
                sqlite3_bind_double(statement, 17, (flightData["flight_sim"]        as? Double ?? 0.0))
                sqlite3_bind_int(statement, 18, Int32(flightData["takeoffs"]        as? Int ?? 0))
                sqlite3_bind_int(statement, 19, Int32(flightData["landings_day"]    as? Int ?? 0))
                sqlite3_bind_int(statement, 20, Int32(flightData["landings_night"]  as? Int ?? 0))
                sqlite3_bind_int(statement, 21, Int32(flightData["approaches_count"] as? Int ?? 0))
                sqlite3_bind_int(statement, 22, Int32(flightData["holds_count"]     as? Int ?? 0))
                sqlite3_bind_int(statement, 23, (flightData["nav_tracking"]         as? Bool ?? false) ? 1 : 0)
                sqlite3_bind_text(statement, 24, (flightData["remarks"]             as? String ?? ""), -1, sqliteTransient)
                // Accept both Int (1/0) and Bool for is_legacy_import
                let isLegacy: Int32 = {
                    if let b = flightData["is_legacy_import"] as? Bool   { return b ? 1 : 0 }
                    if let i = flightData["is_legacy_import"] as? Int    { return Int32(i) }
                    if let i = flightData["is_legacy_import"] as? Int32  { return i }
                    return 0
                }()
                sqlite3_bind_int(statement, 25, isLegacy)
                sqlite3_bind_text(statement, 26, (flightData["legacy_signature_path"] as? String ?? ""), -1, sqliteTransient)
                
                if sqlite3_step(statement) == SQLITE_DONE {
                    let rowId = sqlite3_last_insert_rowid(self.db)
                    // Post notification on main thread AFTER the write is committed
                    // so any observer calling fetchFlights() sees the new row.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                        completion(rowId)
                    }
                } else {
                    let error = String(cString: sqlite3_errmsg(self.db))
                    print("Error adding flight: \(error)")
                    DispatchQueue.main.async { completion(nil) }
                }
            }
            sqlite3_finalize(statement)
        }
    }
    
    func fetchFlightsByDateRange(start: Date, end: Date) -> [[String: Any]] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let startStr = df.string(from: start)
        let endStr   = df.string(from: end)

        // IMPORTANT: Use an explicit named column list — NEVER SELECT *.
        // SELECT * with hardcoded column indices breaks whenever the schema is
        // migrated (ALTER TABLE appends columns, shifting all subsequent indices).
        // Named SELECT pins every column to a known result position regardless of
        // the physical order in the table.
        let sql = """
            SELECT
                id,
                date, aircraft_type, aircraft_ident, aircraft_category, aircraft_class,
                route, total_time, pic, sic, solo, dual_received, dual_given,
                cross_country, night, instrument_actual, instrument_simulated, flight_sim,
                takeoffs, landings_day, landings_night,
                approaches_count, holds_count, nav_tracking,
                remarks, is_signed, is_legacy_import,
                COALESCE(is_verified, 0)  AS is_verified,
                COALESCE(verified_at, '') AS verified_at
            FROM flights
            WHERE date >= ? AND date <= ?
            ORDER BY date DESC;
            """
        //  Result col#  →  field
        //   0  id
        //   1  date              (TEXT, may be NULL → guard below)
        //   2  aircraft_type
        //   3  aircraft_ident
        //   4  aircraft_category
        //   5  aircraft_class
        //   6  route
        //   7  total_time
        //   8  pic
        //   9  sic
        //  10  solo
        //  11  dual_received
        //  12  dual_given
        //  13  cross_country
        //  14  night
        //  15  instrument_actual
        //  16  instrument_simulated
        //  17  flight_sim
        //  18  takeoffs
        //  19  landings_day
        //  20  landings_night
        //  21  approaches_count
        //  22  holds_count
        //  23  nav_tracking
        //  24  remarks
        //  25  is_signed
        //  26  is_legacy_import
        //  27  is_verified        (COALESCE → never NULL)
        //  28  verified_at        (COALESCE → never NULL)

        var results: [[String: Any]] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("[DB] fetchFlightsByDateRange: prepare failed — \(String(cString: sqlite3_errmsg(db)))")
            return results
        }
        sqlite3_bind_text(statement, 1, startStr, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, endStr,   -1, sqliteTransient)

        // Safe text helper — returns "" for NULL columns instead of crashing
        func txt(_ col: Int32) -> String {
            sqlite3_column_text(statement, col).map { String(cString: $0) } ?? ""
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            var f: [String: Any] = [:]
            f["id"]                   = sqlite3_column_int64(statement, 0)
            f["date"]                 = txt(1)
            f["aircraft_type"]        = txt(2)
            f["aircraft_ident"]       = txt(3)
            f["aircraft_category"]    = txt(4)
            f["aircraft_class"]       = txt(5)
            f["route"]                = txt(6)
            f["total_time"]           = sqlite3_column_double(statement, 7)
            f["pic"]                  = sqlite3_column_double(statement, 8)
            f["sic"]                  = sqlite3_column_double(statement, 9)
            f["solo"]                 = sqlite3_column_double(statement, 10)
            f["dual_received"]        = sqlite3_column_double(statement, 11)
            f["dual_given"]           = sqlite3_column_double(statement, 12)
            f["cross_country"]        = sqlite3_column_double(statement, 13)
            f["night"]                = sqlite3_column_double(statement, 14)
            f["instrument_actual"]    = sqlite3_column_double(statement, 15)
            f["instrument_simulated"] = sqlite3_column_double(statement, 16)
            f["flight_sim"]           = sqlite3_column_double(statement, 17)
            f["takeoffs"]             = Int(sqlite3_column_int(statement, 18))
            f["landings_day"]         = Int(sqlite3_column_int(statement, 19))
            f["landings_night"]       = Int(sqlite3_column_int(statement, 20))
            f["approaches_count"]     = Int(sqlite3_column_int(statement, 21))
            f["holds_count"]          = Int(sqlite3_column_int(statement, 22))
            f["nav_tracking"]         = sqlite3_column_int(statement, 23) != 0
            f["remarks"]              = txt(24)
            f["is_signed"]            = sqlite3_column_int(statement, 25) != 0
            f["is_legacy_import"]     = sqlite3_column_int(statement, 26) != 0
            f["is_verified"]          = sqlite3_column_int(statement, 27) != 0
            f["verified_at"]          = txt(28)
            results.append(f)
        }
        return results
    }
    
    func fetchFlight(id flightId: Int64) -> [String: Any]? {
        let sql = """
            SELECT id, date, aircraft_ident, total_time,
                   COALESCE(signature_hash,'') AS signature_hash, is_signed
            FROM flights WHERE id = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, flightId)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return [
            "id":             sqlite3_column_int64(statement, 0),
            "date":           sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
            "aircraft_ident": sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
            "total_time":     sqlite3_column_double(statement, 3),
            "signature_hash": sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
            "is_signed":      sqlite3_column_int(statement, 5) != 0
        ]
    }
    
    func signFlight(id flightId: Int64, signature: String, hash: String, name: String, certificate: String, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            let sql = "UPDATE flights SET signature_blob = ?, signature_hash = ?, cfi_name = ?, cfi_certificate = ?, is_signed = 1 WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, signature,   -1, nil)
                sqlite3_bind_text(statement, 2, hash,        -1, nil)
                sqlite3_bind_text(statement, 3, name,        -1, nil)
                sqlite3_bind_text(statement, 4, certificate, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 5, flightId)
                
                let success = sqlite3_step(statement) == SQLITE_DONE
                DispatchQueue.main.async { completion(success) }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
            sqlite3_finalize(statement)
        }
    }
    
    func verifyIntegrity(id flightId: Int64, currentData: String) -> Bool {
        guard let flight = fetchFlight(id: flightId),
              let storedHash = flight["signature_hash"] as? String,
              let isSigned   = flight["is_signed"] as? Bool,
              isSigned else { return true }
        
        guard let data = currentData.data(using: .utf8) else { return false }
        let currentHash = SHA256.hash(data: data)
        let currentHashString = currentHash.compactMap { String(format: "%02x", $0) }.joined()
        return currentHashString == storedHash
    }

    // MARK: - Update Flight

    /// Updates all editable fields of an existing flight row.
    /// Preserves signature/signing columns — those can only be changed via signFlight().
    /// Posts logbookDataDidChange on success so all observers refresh.
    func updateFlight(_ flightData: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let flightId = flightData["id"] as? Int64 else {
            completion(false); return
        }
        dbQueue.async {
            let sql = """
            UPDATE flights SET
                date                 = ?,
                aircraft_type        = ?,
                aircraft_ident       = ?,
                aircraft_category    = ?,
                aircraft_class       = ?,
                route                = ?,
                total_time           = ?,
                pic                  = ?,
                sic                  = ?,
                solo                 = ?,
                dual_received        = ?,
                dual_given           = ?,
                cross_country        = ?,
                night                = ?,
                instrument_actual    = ?,
                instrument_simulated = ?,
                flight_sim           = ?,
                takeoffs             = ?,
                landings_day         = ?,
                landings_night       = ?,
                approaches_count     = ?,
                holds_count          = ?,
                nav_tracking         = ?,
                remarks              = ?,
                is_verified          = ?,
                verified_at          = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_text(statement,  1,  (flightData["date"]                    as? String ?? ""), -1, sqliteTransient)
            sqlite3_bind_text(statement,  2,  (flightData["aircraft_type"]           as? String ?? ""), -1, sqliteTransient)
            sqlite3_bind_text(statement,  3,  (flightData["aircraft_ident"]          as? String ?? ""), -1, sqliteTransient)
            sqlite3_bind_text(statement,  4,  (flightData["aircraft_category"]       as? String ?? "Airplane"), -1, sqliteTransient)
            sqlite3_bind_text(statement,  5,  (flightData["aircraft_class"]          as? String ?? "SEL"), -1, sqliteTransient)
            sqlite3_bind_text(statement,  6,  (flightData["route"]                   as? String ?? ""), -1, sqliteTransient)
            sqlite3_bind_double(statement, 7,  (flightData["total_time"]             as? Double ?? 0.0))
            sqlite3_bind_double(statement, 8,  (flightData["pic"]                    as? Double ?? 0.0))
            sqlite3_bind_double(statement, 9,  (flightData["sic"]                    as? Double ?? 0.0))
            sqlite3_bind_double(statement, 10, (flightData["solo"]                   as? Double ?? 0.0))
            sqlite3_bind_double(statement, 11, (flightData["dual_received"]          as? Double ?? 0.0))
            sqlite3_bind_double(statement, 12, (flightData["dual_given"]             as? Double ?? 0.0))
            sqlite3_bind_double(statement, 13, (flightData["cross_country"]          as? Double ?? 0.0))
            sqlite3_bind_double(statement, 14, (flightData["night"]                  as? Double ?? 0.0))
            sqlite3_bind_double(statement, 15, (flightData["instrument_actual"]      as? Double ?? 0.0))
            sqlite3_bind_double(statement, 16, (flightData["instrument_simulated"]   as? Double ?? 0.0))
            sqlite3_bind_double(statement, 17, (flightData["flight_sim"]             as? Double ?? 0.0))
            sqlite3_bind_int(statement,   18,  Int32(flightData["takeoffs"]          as? Int ?? 0))
            sqlite3_bind_int(statement,   19,  Int32(flightData["landings_day"]      as? Int ?? 0))
            sqlite3_bind_int(statement,   20,  Int32(flightData["landings_night"]    as? Int ?? 0))
            sqlite3_bind_int(statement,   21,  Int32(flightData["approaches_count"]  as? Int ?? 0))
            sqlite3_bind_int(statement,   22,  Int32(flightData["holds_count"]       as? Int ?? 0))
            sqlite3_bind_int(statement,   23,  (flightData["nav_tracking"]           as? Bool ?? false) ? 1 : 0)
            sqlite3_bind_text(statement,  24,  (flightData["remarks"]                as? String ?? ""), -1, sqliteTransient)
            let isVerified: Int32 = (flightData["is_verified"] as? Bool ?? false) ? 1 : 0
            sqlite3_bind_int(statement,   25,  isVerified)
            let verifiedAt = flightData["verified_at"] as? String ?? ""
            sqlite3_bind_text(statement,  26,  verifiedAt, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 27,  flightId)

            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            DispatchQueue.main.async {
                if success {
                    NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                }
                completion(success)
            }
        }
    }

    // MARK: - Delete Flight

    /// Hard-deletes a flight row by id. Signed flights can still be deleted
    /// (the calling UI should warn the user first).
    func deleteFlight(id flightId: Int64, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            let sql = "DELETE FROM flights WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_int64(statement, 1, flightId)
            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            DispatchQueue.main.async {
                if success {
                    NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                }
                completion(success)
            }
        }
    }

    // MARK: - Mark Flight Verified

    func markFlightVerified(id flightId: Int64, completion: @escaping (Bool) -> Void) {
        let df = ISO8601DateFormatter()
        let now = df.string(from: Date())
        dbQueue.async {
            let sql = "UPDATE flights SET is_verified = 1, verified_at = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement); DispatchQueue.main.async { completion(false) }; return
            }
            sqlite3_bind_text(statement,  1, now, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, flightId)
            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            DispatchQueue.main.async {
                if success { NotificationCenter.default.post(name: .logbookDataDidChange, object: nil) }
                completion(success)
            }
        }
    }

    // MARK: - Mark All Flights Verified (bulk)

    func markAllFlightsVerified(completion: @escaping (Int) -> Void) {
        let df = ISO8601DateFormatter()
        let now = df.string(from: Date())
        dbQueue.async {
            let sql = "UPDATE flights SET is_verified = 1, verified_at = ? WHERE is_verified = 0 OR is_verified IS NULL;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement); DispatchQueue.main.async { completion(0) }; return
            }
            sqlite3_bind_text(statement, 1, now, -1, sqliteTransient)
            let _ = sqlite3_step(statement)
            let changed = Int(sqlite3_changes(self.db))
            sqlite3_finalize(statement)
            DispatchQueue.main.async {
                if changed > 0 { NotificationCenter.default.post(name: .logbookDataDidChange, object: nil) }
                completion(changed)
            }
        }
    }
    
    // MARK: - IACRA Assistant Logic
    
    struct IACRATotals {
        let total: Double
        let pic: Double
        let solo: Double
        let dualReceived: Double
        let crossCountry: Double
        let xcPic: Double
        let xcSolo: Double
        let night: Double
        let nightInst: Double
        let instrument: Double
        let instrumentInst: Double
        let instrumentActual: Double
        let instrumentSimulated: Double
    }
    
    func fetchIACRATotals() -> IACRATotals {
        let sql = """
        SELECT 
            total, pic, xc, inst_actual, inst_simulated,
            (SELECT SUM(solo) FROM flights),
            (SELECT SUM(dual_received) FROM flights),
            (SELECT SUM(CASE WHEN pic > 0 THEN cross_country ELSE 0 END) FROM flights),
            (SELECT SUM(CASE WHEN solo > 0 THEN cross_country ELSE 0 END) FROM flights),
            (SELECT SUM(night) FROM flights),
            (SELECT SUM(CASE WHEN night > 0 THEN dual_received ELSE 0 END) FROM flights),
            (SELECT SUM(instrument_actual + instrument_simulated) FROM flights),
            (SELECT SUM(CASE WHEN (instrument_actual + instrument_simulated) > 0 THEN dual_received ELSE 0 END) FROM flights)
        FROM v_dashboard_stats;
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                let totals = IACRATotals(
                    total:              sqlite3_column_double(statement, 0),
                    pic:                sqlite3_column_double(statement, 1),
                    solo:               sqlite3_column_double(statement, 5),
                    dualReceived:       sqlite3_column_double(statement, 6),
                    crossCountry:       sqlite3_column_double(statement, 2),
                    xcPic:              sqlite3_column_double(statement, 7),
                    xcSolo:             sqlite3_column_double(statement, 8),
                    night:              sqlite3_column_double(statement, 9),
                    nightInst:          sqlite3_column_double(statement, 10),
                    instrument:         sqlite3_column_double(statement, 11),
                    instrumentInst:     sqlite3_column_double(statement, 12),
                    instrumentActual:   sqlite3_column_double(statement, 3),
                    instrumentSimulated:sqlite3_column_double(statement, 4)
                )
                sqlite3_finalize(statement)
                return totals
            }
        }
        sqlite3_finalize(statement)
        return IACRATotals(total: 0, pic: 0, solo: 0, dualReceived: 0,
                           crossCountry: 0, xcPic: 0, xcSolo: 0,
                           night: 0, nightInst: 0, instrument: 0,
                           instrumentInst: 0, instrumentActual: 0, instrumentSimulated: 0)
    }
    
    // MARK: - IACRA By Category

    struct IACRACategoryRow {
        let category:           String
        var total:              Double = 0
        var instructionReceived:Double = 0
        var solo:               Double = 0
        var pic:                Double = 0
        var sic:                Double = 0
        var xcTotal:            Double = 0   // total XC time
        var xcInstruction:      Double = 0   // dual received on XC flights
        var xcSolo:             Double = 0   // solo on XC flights
        var xcPicSic:           Double = 0   // pic+sic on XC flights
        var instrument:         Double = 0
        var nightTotal:         Double = 0   // night flight time
        var nightInstruction:   Double = 0   // dual received on night flights
        var nightLdgs:          Int    = 0
        var nightPicSic:        Double = 0
        var nightLdgsPicSic:    Int    = 0
        var classes: [String: ClassBreakdown] = [:]
    }

    struct ClassBreakdown {
        var total:              Double = 0   // FIX: total_time per class was missing
        var pic:                Double = 0
        var sic:                Double = 0
        var instructionReceived:Double = 0
    }

    // FIX: Normalizes the raw aircraft_class string stored in the DB to the
    // canonical key used in classesByCategory. LogbookImporter writes "ASEL"/"AMEL"
    // but classesByCategory keys are "SEL"/"MEL" — causing all class totals to be 0.
    private func normalizeAircraftClass(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ASEL", "SEL", "A-SEL", "SINGLE-ENGINE LAND", "SINGLE ENGINE LAND": return "SEL"
        case "AMEL", "MEL", "A-MEL", "MULTI-ENGINE LAND",  "MULTI ENGINE LAND":  return "MEL"
        case "ASES", "SES", "A-SES", "SINGLE-ENGINE SEA",  "SINGLE ENGINE SEA":  return "SES"
        case "AMES", "MES", "A-MES", "MULTI-ENGINE SEA",   "MULTI ENGINE SEA":   return "MES"
        case "HELICOPTER":                                                          return "Helicopter"
        case "GYROPLANE":                                                           return "Gyroplane"
        case "BALLOON":                                                             return "Balloon"
        case "AIRSHIP":                                                             return "Airship"
        case "SE":                                                                  return "SE"
        case "ME":                                                                  return "ME"
        default:                                                                    return raw
        }
    }

    func fetchIACRAByCategory() -> [IACRACategoryRow] {
        let allCategories = ["Airplane", "Rotorcraft", "Powered Lift",
                             "Glider", "Lighter-than-air", "FFS", "FTD", "ATD"]
        let classesByCategory: [String: [String]] = [
            "Airplane":         ["SEL", "MEL", "SES", "MES"],
            "Rotorcraft":       ["Helicopter", "Gyroplane"],
            "Lighter-than-air": ["Balloon", "Airship"],
            "FFS":              ["SE", "ME", "Helicopter"]
        ]

        // Pre-build result map with empty class slots
        var data: [String: IACRACategoryRow] = [:]
        for cat in allCategories {
            var row = IACRACategoryRow(category: cat)
            classesByCategory[cat]?.forEach { row.classes[$0] = ClassBreakdown() }
            data[cat] = row
        }

        // FIX: fetch takeoffs + night_pic_sic too; use correct column order
        let sql = """
        SELECT aircraft_category, aircraft_class,
               total_time, dual_received, solo, pic, sic,
               cross_country, instrument_actual, instrument_simulated,
               night, landings_night
        FROM flights;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return allCategories.compactMap { data[$0] }
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            // Null-safe reads
            let catRaw = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let clsRaw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""

            // Map unknown categories to Airplane rather than silently dropping the row
            let cat = allCategories.contains(catRaw) ? catRaw : "Airplane"
            guard data[cat] != nil else { continue }

            let totalTime  = sqlite3_column_double(statement, 2)
            let dualRecv   = sqlite3_column_double(statement, 3)
            let solo       = sqlite3_column_double(statement, 4)
            let pic        = sqlite3_column_double(statement, 5)
            let sic        = sqlite3_column_double(statement, 6)
            let xc         = sqlite3_column_double(statement, 7)
            let instActual = sqlite3_column_double(statement, 8)
            let instSim    = sqlite3_column_double(statement, 9)
            let night      = sqlite3_column_double(statement, 10)
            let nightLdgs  = Int(sqlite3_column_int(statement, 11))

            // ── Category row totals ──────────────────────────────────────────
            data[cat]!.total               += totalTime
            data[cat]!.instructionReceived += dualRecv
            data[cat]!.solo                += solo
            data[cat]!.pic                 += pic
            data[cat]!.sic                 += sic
            data[cat]!.instrument          += (instActual + instSim)

            // ── Cross Country (FAA: time logged as XC) ───────────────────────
            // xcTotal: the actual XC hours for this flight
            // xcInstruction / xcSolo / xcPicSic: piloting-role hours on XC flights
            if xc > 0 {
                data[cat]!.xcTotal       += xc
                data[cat]!.xcInstruction += dualRecv
                data[cat]!.xcSolo        += solo
                data[cat]!.xcPicSic      += (pic + sic)
            }

            // ── Night ────────────────────────────────────────────────────────
            if night > 0 {
                data[cat]!.nightTotal       += night
                data[cat]!.nightInstruction += dualRecv
                data[cat]!.nightLdgs        += nightLdgs
                data[cat]!.nightPicSic      += (pic + sic)
                if pic > 0 || sic > 0 {
                    data[cat]!.nightLdgsPicSic += nightLdgs
                }
            }

            // ── Class breakdown ──────────────────────────────────────────────
            // FIX: normalize "ASEL" → "SEL", "AMEL" → "MEL", etc. before lookup.
            // Without this, LogbookImporter-imported flights (which store "ASEL"/"AMEL")
            // never match the classesByCategory keys and class totals stay at 0.
            let cls = normalizeAircraftClass(clsRaw)
            if data[cat]!.classes[cls] != nil {
                data[cat]!.classes[cls]!.total              += totalTime   // FIX: was missing
                data[cat]!.classes[cls]!.pic                += pic
                data[cat]!.classes[cls]!.sic                += sic
                data[cat]!.classes[cls]!.instructionReceived += dualRecv
            }
        }

        sqlite3_finalize(statement)
        return allCategories.compactMap { data[$0] }
    }

    // MARK: - Endorsements CRUD

    struct EndorsementRecord: Identifiable {
        let id:                   Int64
        var templateId:           String
        var title:                String
        var text:                 String
        var date:                 String
        var instructorName:       String
        var instructorCertificate:String
        var signatureBlob:        String   // base64 PNG or ""
        var createdAt:            String
    }

    func fetchEndorsements() -> [EndorsementRecord] {
        let sql = """
        SELECT id, template_id, title, text, date,
               instructor_name, instructor_certificate,
               signature_blob, created_at
        FROM endorsements
        ORDER BY date DESC;
        """
        var statement: OpaquePointer?
        var results: [EndorsementRecord] = []

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return results
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(EndorsementRecord(
                id:                    sqlite3_column_int64(statement, 0),
                templateId:            sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                title:                 sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                text:                  sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                date:                  sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                instructorName:        sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "",
                instructorCertificate: sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "",
                signatureBlob:         sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "",
                createdAt:             sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
            ))
        }

        sqlite3_finalize(statement)
        return results
    }

    func addEndorsement(
        templateId:            String,
        title:                 String,
        text:                  String,
        date:                  String,
        instructorName:        String,
        instructorCertificate: String,
        signatureBlob:         String,
        completion:            @escaping (Int64?) -> Void
    ) {
        dbQueue.async {
            let sql = """
            INSERT INTO endorsements
                (template_id, title, text, date,
                 instructor_name, instructor_certificate, signature_blob)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(nil) }
                return
            }

            sqlite3_bind_text(statement, 1, templateId,            -1, nil)
            sqlite3_bind_text(statement, 2, title,                 -1, nil)
            sqlite3_bind_text(statement, 3, text,                  -1, nil)
            sqlite3_bind_text(statement, 4, date,                  -1, nil)
            sqlite3_bind_text(statement, 5, instructorName,        -1, nil)
            sqlite3_bind_text(statement, 6, instructorCertificate, -1, sqliteTransient)
            sqlite3_bind_text(statement, 7, signatureBlob,         -1, nil)

            if sqlite3_step(statement) == SQLITE_DONE {
                let newId = sqlite3_last_insert_rowid(self.db)
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(newId) }
            } else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func deleteEndorsement(id: Int64, completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            let sql = "DELETE FROM endorsements WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_int64(statement, 1, id)
            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            DispatchQueue.main.async { completion(success) }
        }
    }

    func updateEndorsementSignature(
        id:                    Int64,
        signatureBlob:         String,
        instructorName:        String,
        instructorCertificate: String,
        completion:            @escaping (Bool) -> Void
    ) {
        dbQueue.async {
            let sql = """
            UPDATE endorsements
            SET signature_blob = ?, instructor_name = ?, instructor_certificate = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_text(statement, 1, signatureBlob,         -1, nil)
            sqlite3_bind_text(statement, 2, instructorName,        -1, nil)
            sqlite3_bind_text(statement, 3, instructorCertificate, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 4, id)
            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            DispatchQueue.main.async { completion(success) }
        }
    }

    // MARK: - User Profile
    
    func fetchUserProfile() -> [String: Any] {
        let sql = "SELECT * FROM user_profile WHERE id = 1;"
        var statement: OpaquePointer?
        var profile: [String: Any] = [:]
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                profile["pilot_name"] = String(cString: sqlite3_column_text(statement, 1))
                if let medicalDate = sqlite3_column_text(statement, 2) {
                    profile["medical_date"] = String(cString: medicalDate)
                }
                profile["medical_class"] = Int(sqlite3_column_int(statement, 3))
                if let medicalType = sqlite3_column_text(statement, 4) {
                    profile["medical_type"] = String(cString: medicalType)
                }
                if let certNum = sqlite3_column_text(statement, 5) {
                    profile["certificate_number"] = String(cString: certNum)
                }
                if let pilotCert = sqlite3_column_text(statement, 6) {
                    profile["pilot_certificate"] = String(cString: pilotCert)
                }
                if let ftn = sqlite3_column_text(statement, 7) {
                    profile["ftn"] = String(cString: ftn)
                }
            }
        }
        sqlite3_finalize(statement)
        return profile
    }
    
    func updateUserProfile(name: String, medicalDate: String, medicalClass: Int, medicalType: String, certNum: String, pilotCert: String, ftn: String) {
        let sql = "UPDATE user_profile SET pilot_name = ?, medical_date = ?, medical_class = ?, medical_type = ?, certificate_number = ?, pilot_certificate = ?, ftn = ? WHERE id = 1;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, name,        -1, nil)
            sqlite3_bind_text(statement, 2, medicalDate, -1, sqliteTransient)
            sqlite3_bind_int(statement,  3, Int32(medicalClass))
            sqlite3_bind_text(statement, 4, medicalType, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, certNum,     -1, nil)
            sqlite3_bind_text(statement, 6, pilotCert,   -1, nil)
            sqlite3_bind_text(statement, 7, ftn,         -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
            }
        }
        sqlite3_finalize(statement)
    }
    // MARK: - Reset All Data

    /// Permanently deletes ALL flights, endorsements, and resets the user profile.
    /// Posts logbookDataDidChange so every observer (Dashboard, Logbook, etc.) refreshes.
    func resetAllData(completion: @escaping (Bool) -> Void) {
        dbQueue.async {
            var success = true

            // Delete all flight records
            let sqls = [
                "DELETE FROM flights;",
                "DELETE FROM endorsements;",
                // Reset the profile row back to defaults (keep the row id=1)
                "UPDATE user_profile SET pilot_name='Pilot Name', medical_date='', medical_class=1, medical_type='Class 3', certificate_number='', pilot_certificate='', ftn='' WHERE id=1;",
                // Reset SQLite auto-increment counters
                "DELETE FROM sqlite_sequence WHERE name='flights';",
                "DELETE FROM sqlite_sequence WHERE name='endorsements';"
            ]

            for sql in sqls {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) != SQLITE_DONE { success = false }
                } else {
                    success = false
                }
                sqlite3_finalize(stmt)
            }

            DispatchQueue.main.async {
                // Broadcast change so Dashboard, Logbook, and all views reload
                NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                completion(success)
            }
        }
    }

    // MARK: - Flight Totals (simple, correct SUM queries)

    struct FlightTotals {
        var totalTime:           Double = 0
        var pic:                 Double = 0
        var sic:                 Double = 0
        var solo:                Double = 0
        var dualReceived:        Double = 0
        var dualGiven:           Double = 0
        var crossCountry:        Double = 0
        var night:               Double = 0
        var instrumentActual:    Double = 0
        var instrumentSimulated: Double = 0
        var flightSim:           Double = 0
        var takeoffs:            Int    = 0
        var landingsDay:         Int    = 0
        var landingsNight:       Int    = 0
        var approachesCount:     Int    = 0
        var totalFlights:        Int    = 0
    }

    /// Returns accurate aggregate totals by summing every column individually.
    /// Use this anywhere a running total is needed (Dashboard, Export, IACRA, etc.)
    func fetchFlightTotals() -> FlightTotals {
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(total_time),           0),
            COALESCE(SUM(pic),                  0),
            COALESCE(SUM(sic),                  0),
            COALESCE(SUM(solo),                 0),
            COALESCE(SUM(dual_received),        0),
            COALESCE(SUM(dual_given),           0),
            COALESCE(SUM(cross_country),        0),
            COALESCE(SUM(night),                0),
            COALESCE(SUM(instrument_actual),    0),
            COALESCE(SUM(instrument_simulated), 0),
            COALESCE(SUM(flight_sim),           0),
            COALESCE(SUM(takeoffs),             0),
            COALESCE(SUM(landings_day),         0),
            COALESCE(SUM(landings_night),       0),
            COALESCE(SUM(approaches_count),     0)
        FROM flights;
        """
        var stmt: OpaquePointer?
        var t = FlightTotals()
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW
        else { sqlite3_finalize(stmt); return t }

        t.totalFlights        = Int(sqlite3_column_int(stmt,  0))
        t.totalTime           = sqlite3_column_double(stmt,   1)
        t.pic                 = sqlite3_column_double(stmt,   2)
        t.sic                 = sqlite3_column_double(stmt,   3)
        t.solo                = sqlite3_column_double(stmt,   4)
        t.dualReceived        = sqlite3_column_double(stmt,   5)
        t.dualGiven           = sqlite3_column_double(stmt,   6)
        t.crossCountry        = sqlite3_column_double(stmt,   7)
        t.night               = sqlite3_column_double(stmt,   8)
        t.instrumentActual    = sqlite3_column_double(stmt,   9)
        t.instrumentSimulated = sqlite3_column_double(stmt,  10)
        t.flightSim           = sqlite3_column_double(stmt,  11)
        t.takeoffs            = Int(sqlite3_column_int(stmt, 12))
        t.landingsDay         = Int(sqlite3_column_int(stmt, 13))
        t.landingsNight       = Int(sqlite3_column_int(stmt, 14))
        t.approachesCount     = Int(sqlite3_column_int(stmt, 15))

        sqlite3_finalize(stmt)
        return t
    }

    // MARK: - Batch Import (single transaction, one notification)

    /// Inserts multiple flights in a single SQLite transaction.
    /// Much faster than calling addFlight() in a loop and fires only ONE
    /// logbookDataDidChange notification, preventing UI thrashing mid-import.
    func addFlightsBatch(_ flights: [[String: Any]],
                         progress: ((Int, Int) -> Void)? = nil,
                         completion: @escaping (_ inserted: Int, _ failed: Int) -> Void) {
        dbQueue.async {
            let sql = """
            INSERT INTO flights (
                date, aircraft_type, aircraft_ident, aircraft_category, aircraft_class,
                route, total_time, pic, sic, solo, dual_received, dual_given,
                cross_country, night, instrument_actual, instrument_simulated,
                flight_sim, takeoffs, landings_day, landings_night, approaches_count,
                holds_count, nav_tracking, remarks, is_legacy_import, legacy_signature_path
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            // Wrap everything in a transaction — 100× faster than autocommit per row
            sqlite3_exec(self.db, "BEGIN TRANSACTION;", nil, nil, nil)

            var inserted = 0
            var failed   = 0
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                DispatchQueue.main.async { completion(0, flights.count) }
                return
            }

            for (i, fd) in flights.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                let isLegacy: Int32 = {
                    if let b = fd["is_legacy_import"] as? Bool  { return b ? 1 : 0 }
                    if let v = fd["is_legacy_import"] as? Int   { return Int32(v) }
                    if let v = fd["is_legacy_import"] as? Int32 { return v }
                    return 0
                }()

                sqlite3_bind_text(stmt,  1, fd["date"]                 as? String ?? "", -1, sqliteTransient)
                sqlite3_bind_text(stmt,  2, fd["aircraft_type"]        as? String ?? "", -1, sqliteTransient)
                sqlite3_bind_text(stmt,  3, fd["aircraft_ident"]       as? String ?? "", -1, sqliteTransient)
                sqlite3_bind_text(stmt,  4, fd["aircraft_category"]    as? String ?? "Airplane", -1, sqliteTransient)
                sqlite3_bind_text(stmt,  5, fd["aircraft_class"]       as? String ?? "ASEL", -1, sqliteTransient)
                sqlite3_bind_text(stmt,  6, fd["route"]                as? String ?? "", -1, sqliteTransient)
                sqlite3_bind_double(stmt, 7,  fd["total_time"]         as? Double ?? 0)
                sqlite3_bind_double(stmt, 8,  fd["pic"]                as? Double ?? 0)
                sqlite3_bind_double(stmt, 9,  fd["sic"]                as? Double ?? 0)
                sqlite3_bind_double(stmt, 10, fd["solo"]               as? Double ?? 0)
                sqlite3_bind_double(stmt, 11, fd["dual_received"]      as? Double ?? 0)
                sqlite3_bind_double(stmt, 12, fd["dual_given"]         as? Double ?? 0)
                sqlite3_bind_double(stmt, 13, fd["cross_country"]      as? Double ?? 0)
                sqlite3_bind_double(stmt, 14, fd["night"]              as? Double ?? 0)
                sqlite3_bind_double(stmt, 15, fd["instrument_actual"]  as? Double ?? 0)
                sqlite3_bind_double(stmt, 16, fd["instrument_simulated"] as? Double ?? 0)
                sqlite3_bind_double(stmt, 17, fd["flight_sim"]         as? Double ?? 0)
                sqlite3_bind_int(stmt,   18, Int32(fd["takeoffs"]      as? Int ?? 0))
                sqlite3_bind_int(stmt,   19, Int32(fd["landings_day"]  as? Int ?? 0))
                sqlite3_bind_int(stmt,   20, Int32(fd["landings_night"] as? Int ?? 0))
                sqlite3_bind_int(stmt,   21, Int32(fd["approaches_count"] as? Int ?? 0))
                sqlite3_bind_int(stmt,   22, Int32(fd["holds_count"]   as? Int ?? 0))
                sqlite3_bind_int(stmt,   23, (fd["nav_tracking"] as? Bool ?? false) ? 1 : 0)
                sqlite3_bind_text(stmt,  24, fd["remarks"]             as? String ?? "", -1, sqliteTransient)
                sqlite3_bind_int(stmt,   25, isLegacy)
                sqlite3_bind_text(stmt,  26, fd["legacy_signature_path"] as? String ?? "", -1, sqliteTransient)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    inserted += 1
                } else {
                    failed += 1
                }

                // Report progress to UI without firing data-change notifications
                if let progress = progress {
                    let capturedI = i + 1
                    let total     = flights.count
                    DispatchQueue.main.async { progress(capturedI, total) }
                }
            }

            sqlite3_finalize(stmt)

            if failed == 0 {
                sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
            } else {
                // Partial success: commit what worked rather than rolling back everything
                sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
            }

            DispatchQueue.main.async {
                // Single notification for the entire batch
                NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
                completion(inserted, failed)
            }
        }
    }

}
