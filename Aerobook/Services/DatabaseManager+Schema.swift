// DatabaseManager+Schema.swift — AeroBook
// SQLite Schema v3 — Normalized, encrypted-at-rest, audit-ready
// Drop into your project alongside DatabaseManager.swift
// This file documents the full schema design and adds missing columns via migration.

/*
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ AEROBOOK SQLITE SCHEMA v3                                                   │
 │ 100% local · WAL mode · AES-256 via SQLCipher (optional) · no cloud sync   │
 ├────────────────────────┬────────────────┬───────────────────────────────────┤
 │ TABLE                  │ PURPOSE        │ NOTES                             │
 ├────────────────────────┼────────────────┼───────────────────────────────────┤
 │ flights                │ Core logbook   │ One row per flight entry          │
 │ ocr_scan_sessions      │ Scan audit log │ Tracks each scan event            │
 │ ocr_raw_observations   │ Raw Vision data│ For debugging / reprocessing      │
 │ user_profile           │ Pilot identity │ Single row (id=1)                 │
 │ endorsements           │ CFI sign-offs  │ Links to flights optionally       │
 │ aircraft_registry      │ Aircraft cache │ Pre-populated from FAA N-number   │
 │ v_dashboard_stats      │ VIEW           │ Aggregated totals for Dashboard   │
 │ v_currency             │ VIEW           │ FAR currency computation          │
 └────────────────────────┴────────────────┴───────────────────────────────────┘

 COLUMN NAMING CONVENTION
 ─────────────────────────
 • snake_case throughout
 • Boolean: INTEGER (0/1) — SQLite has no BOOL type
 • Time in decimal hours: REAL (e.g. 1.5 = 1h30m)
 • Dates: TEXT in ISO-8601 format "YYYY-MM-DD" for full dates, "MM/DD" for legacy scan imports
 • Blobs: TEXT base64 encoded (signature images < 50KB)
 • Foreign keys enforced via PRAGMA foreign_keys = ON
*/

import Foundation
import SQLite3

extension DatabaseManager {
    
    // MARK: - Schema v3 DDL
    
    static let schemaV3: String = """
    
    -- ══════════════════════════════════════════════════════════════════════
    -- CORE FLIGHTS TABLE
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS flights (
        -- Identity
        id                      INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at              TEXT    DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at              TEXT    DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    
        -- Flight Basics
        date                    TEXT    NOT NULL,       -- "YYYY-MM-DD" or "MM/DD" for legacy
        aircraft_type           TEXT    DEFAULT '',     -- "C172", "SR22", "B737"
        aircraft_ident          TEXT    DEFAULT '',     -- "N12345"
        aircraft_category       TEXT    DEFAULT 'Airplane', -- Airplane/Rotorcraft/Glider/LTA/PPC/Weight-Shift
        aircraft_class          TEXT    DEFAULT 'ASEL',    -- ASEL/AMEL/ASES/AMES/Helicopter/Gyroplane
        aircraft_complex        INTEGER DEFAULT 0,         -- bool: has retract + flaps + CSP
        aircraft_high_perf      INTEGER DEFAULT 0,         -- bool: >200hp
        aircraft_turbine        INTEGER DEFAULT 0,         -- bool: turbine engine
        aircraft_taa            INTEGER DEFAULT 0,         -- bool: technically advanced
    
        -- Route
        route                   TEXT    DEFAULT '',     -- "KCDW-KTEB-KCDW"
        route_from              TEXT    DEFAULT '',
        route_to                TEXT    DEFAULT '',
        departure_time          TEXT    DEFAULT '',     -- "HH:MM" local or Zulu
        arrival_time            TEXT    DEFAULT '',
    
        -- Conditions of Flight (FAR 61 currency-relevant)
        total_time              REAL    DEFAULT 0.0,    -- decimal hours
        pic                     REAL    DEFAULT 0.0,
        sic                     REAL    DEFAULT 0.0,
        solo                    REAL    DEFAULT 0.0,
        dual_received           REAL    DEFAULT 0.0,
        dual_given              REAL    DEFAULT 0.0,   -- CFI column
        cross_country           REAL    DEFAULT 0.0,
        night                   REAL    DEFAULT 0.0,
        instrument_actual       REAL    DEFAULT 0.0,
        instrument_simulated    REAL    DEFAULT 0.0,
        flight_sim              REAL    DEFAULT 0.0,   -- FTD/PCATD/ATD hours
    
        -- Category & Class (Jeppesen / FAA split columns)
        single_engine           REAL    DEFAULT 0.0,
        multi_engine            REAL    DEFAULT 0.0,
        turbine_time            REAL    DEFAULT 0.0,
        
        -- Counts
        takeoffs_day            INTEGER DEFAULT 0,
        takeoffs_night          INTEGER DEFAULT 0,
        landings_day            INTEGER DEFAULT 0,
        landings_night          INTEGER DEFAULT 0,
        approaches_count        INTEGER DEFAULT 0,
        holds_count             INTEGER DEFAULT 0,
        nav_tracking            INTEGER DEFAULT 0,     -- bool: logged for IFR currency
    
        -- Remarks & Endorsements
        remarks                 TEXT    DEFAULT '',
        cfi_name                TEXT    DEFAULT '',
        cfi_certificate         TEXT    DEFAULT '',
        is_signed               INTEGER DEFAULT 0,
        signature_blob          TEXT    DEFAULT '',    -- base64 PNG
        signature_hash          TEXT    DEFAULT '',    -- SHA-256 for tamper detection
    
        -- Import Provenance
        is_legacy_import        INTEGER DEFAULT 0,
        legacy_signature_path   TEXT    DEFAULT '',
        import_source           TEXT    DEFAULT '',    -- 'jeppesen_scan','csv','foreflight','logten'
        ocr_session_id          INTEGER DEFAULT NULL REFERENCES ocr_scan_sessions(id),
    
        -- Verification
        is_verified             INTEGER DEFAULT 0,
        verified_at             TEXT    DEFAULT '',
        verified_by             TEXT    DEFAULT '',
    
        -- Soft delete
        is_deleted              INTEGER DEFAULT 0,
        deleted_at              TEXT    DEFAULT ''
    );
    
    -- Performance indexes
    CREATE INDEX IF NOT EXISTS idx_flights_date          ON flights(date);
    CREATE INDEX IF NOT EXISTS idx_flights_ident         ON flights(aircraft_ident);
    CREATE INDEX IF NOT EXISTS idx_flights_pic           ON flights(pic);
    CREATE INDEX IF NOT EXISTS idx_flights_night         ON flights(night);
    CREATE INDEX IF NOT EXISTS idx_flights_instrument    ON flights(instrument_actual);
    CREATE INDEX IF NOT EXISTS idx_flights_deleted       ON flights(is_deleted);
    CREATE INDEX IF NOT EXISTS idx_flights_ocr_session   ON flights(ocr_session_id);
    
    -- ══════════════════════════════════════════════════════════════════════
    -- OCR SCAN SESSIONS
    -- Tracks every scan event for audit trail and re-processing
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS ocr_scan_sessions (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at          TEXT    DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        
        logbook_format      TEXT    DEFAULT 'jeppesen', -- 'jeppesen','asa','custom','unknown'
        page_image_path     TEXT    DEFAULT '',          -- path to saved scan image (local only)
        
        -- Results
        raw_observation_count   INTEGER DEFAULT 0,
        header_rows_skipped     INTEGER DEFAULT 0,
        rows_extracted          INTEGER DEFAULT 0,
        rows_committed          INTEGER DEFAULT 0,
        rows_rejected           INTEGER DEFAULT 0,
        processing_time_ms      REAL    DEFAULT 0,
        
        -- Quality
        avg_confidence          REAL    DEFAULT 0,
        tilt_detected_degrees   REAL    DEFAULT 0,
        
        -- Status: 'processing' | 'review' | 'committed' | 'discarded'
        status              TEXT    DEFAULT 'processing',
        
        -- Column calibration snapshot (JSON)
        column_map_json     TEXT    DEFAULT ''
    );
    
    -- ══════════════════════════════════════════════════════════════════════
    -- OCR RAW OBSERVATIONS (debug / reprocessing table)
    -- Each row is one VNRecognizedTextObservation from a session
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS ocr_raw_observations (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id      INTEGER NOT NULL REFERENCES ocr_scan_sessions(id) ON DELETE CASCADE,
        
        raw_text        TEXT    NOT NULL,
        confidence      REAL    NOT NULL,
        
        -- Normalized Vision bounding box (0…1, origin bottom-left)
        bbox_x          REAL    DEFAULT 0,
        bbox_y          REAL    DEFAULT 0,
        bbox_w          REAL    DEFAULT 0,
        bbox_h          REAL    DEFAULT 0,
        
        -- Mapped result
        assigned_column TEXT    DEFAULT '',    -- column key it was mapped to
        mapped_value    TEXT    DEFAULT '',    -- parsed value (may differ from raw)
        flight_row_idx  INTEGER DEFAULT -1    -- which data row it belongs to (-1 = header)
    );
    
    CREATE INDEX IF NOT EXISTS idx_obs_session ON ocr_raw_observations(session_id);
    
    -- ══════════════════════════════════════════════════════════════════════
    -- USER PROFILE
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS user_profile (
        id                  INTEGER PRIMARY KEY DEFAULT 1,
        pilot_name          TEXT    DEFAULT '',
        pilot_certificate   TEXT    DEFAULT '',    -- 'Student','Private','Commercial','ATP'
        certificate_number  TEXT    DEFAULT '',
        ftn                 TEXT    DEFAULT '',    -- FAA Tracking Number
        
        medical_class       INTEGER DEFAULT 3,     -- 1, 2, or 3
        medical_type        TEXT    DEFAULT 'Class 3',
        medical_date        TEXT    DEFAULT '',
        medical_expiry      TEXT    DEFAULT '',
        
        home_airport        TEXT    DEFAULT '',
        timezone_id         TEXT    DEFAULT 'America/New_York',
        
        -- Monetization tier: 'student','pilot','instructor','professional','airline'
        app_tier            TEXT    DEFAULT 'student'
    );
    
    INSERT OR IGNORE INTO user_profile (id, pilot_name) VALUES (1, 'Pilot Name');
    
    -- ══════════════════════════════════════════════════════════════════════
    -- ENDORSEMENTS
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS endorsements (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at          TEXT    DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        template_id         TEXT    DEFAULT '',
        title               TEXT    DEFAULT '',
        text                TEXT    DEFAULT '',
        date                TEXT    DEFAULT '',
        instructor_name     TEXT    DEFAULT '',
        instructor_certificate TEXT DEFAULT '',
        signature_blob      TEXT    DEFAULT '',
        linked_flight_id    INTEGER DEFAULT NULL REFERENCES flights(id)
    );
    
    -- ══════════════════════════════════════════════════════════════════════
    -- AIRCRAFT REGISTRY CACHE
    -- ══════════════════════════════════════════════════════════════════════
    CREATE TABLE IF NOT EXISTS aircraft_registry (
        n_number        TEXT    PRIMARY KEY,
        make            TEXT    DEFAULT '',
        model           TEXT    DEFAULT '',
        year            INTEGER DEFAULT 0,
        engine_type     TEXT    DEFAULT '',       -- 'Reciprocating','Turboprop','Jet'
        category        TEXT    DEFAULT 'Airplane',
        aircraft_class  TEXT    DEFAULT 'ASEL',
        is_complex      INTEGER DEFAULT 0,
        is_high_perf    INTEGER DEFAULT 0,
        is_taa          INTEGER DEFAULT 0,
        last_fetched    TEXT    DEFAULT ''
    );
    
    -- ══════════════════════════════════════════════════════════════════════
    -- VIEWS
    -- ══════════════════════════════════════════════════════════════════════
    
    -- Dashboard aggregate stats (active flights only)
    CREATE VIEW IF NOT EXISTS v_dashboard_stats AS
    SELECT
        COUNT(*)                            AS total_flights,
        COALESCE(SUM(total_time),        0) AS total_time,
        COALESCE(SUM(pic),               0) AS pic,
        COALESCE(SUM(sic),               0) AS sic,
        COALESCE(SUM(solo),              0) AS solo,
        COALESCE(SUM(dual_received),     0) AS dual_received,
        COALESCE(SUM(dual_given),        0) AS dual_given,
        COALESCE(SUM(cross_country),     0) AS cross_country,
        COALESCE(SUM(night),             0) AS night,
        COALESCE(SUM(instrument_actual), 0) AS instrument_actual,
        COALESCE(SUM(instrument_simulated),0) AS instrument_simulated,
        COALESCE(SUM(flight_sim),        0) AS flight_sim,
        COALESCE(SUM(takeoffs_day),      0) AS takeoffs_day,
        COALESCE(SUM(landings_day),      0) AS landings_day,
        COALESCE(SUM(landings_night),    0) AS landings_night,
        COALESCE(SUM(approaches_count),  0) AS approaches_count
    FROM flights
    WHERE is_deleted = 0;
    
    -- FAR 61.57 Currency Helper View
    -- Returns flight counts in last 90 days for day/night currency
    CREATE VIEW IF NOT EXISTS v_currency AS
    SELECT
        -- Day currency (3 T&L in 90 days in category/class)
        SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                 THEN landings_day ELSE 0 END) AS landings_day_90,
        SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                  AND landings_night > 0
                 THEN landings_night ELSE 0 END) AS landings_night_90,
        -- Night currency (3 T&L between 1hr after sunset and 1hr before sunrise)
        SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                 THEN night ELSE 0 END) AS night_hours_90,
        -- IFR currency (6 approaches + holds in 6 months)
        SUM(CASE WHEN julianday('now') - julianday(date) <= 180
                 THEN approaches_count ELSE 0 END) AS approaches_180,
        SUM(CASE WHEN julianday('now') - julianday(date) <= 180
                 THEN holds_count ELSE 0 END) AS holds_180
    FROM flights
    WHERE is_deleted = 0
      AND date >= date('now', '-180 days');
    
    """
    
    // MARK: - Migration to v3
    
    func migrateToV3() {
        // New columns added in v3 — failures mean column already exists, which is fine
        let newColumns: [(table: String, column: String, type: String)] = [
            // flights
            ("flights", "single_engine",        "REAL DEFAULT 0.0"),
            ("flights", "multi_engine",          "REAL DEFAULT 0.0"),
            ("flights", "turbine_time",          "REAL DEFAULT 0.0"),
            ("flights", "takeoffs_day",          "INTEGER DEFAULT 0"),
            ("flights", "takeoffs_night",        "INTEGER DEFAULT 0"),
            ("flights", "landings_night",        "INTEGER DEFAULT 0"),
            ("flights", "departure_time",        "TEXT DEFAULT ''"),
            ("flights", "arrival_time",          "TEXT DEFAULT ''"),
            ("flights", "route_from",            "TEXT DEFAULT ''"),
            ("flights", "route_to",              "TEXT DEFAULT ''"),
            ("flights", "aircraft_complex",      "INTEGER DEFAULT 0"),
            ("flights", "aircraft_high_perf",    "INTEGER DEFAULT 0"),
            ("flights", "aircraft_turbine",      "INTEGER DEFAULT 0"),
            ("flights", "aircraft_taa",          "INTEGER DEFAULT 0"),
            ("flights", "import_source",         "TEXT DEFAULT ''"),
            ("flights", "ocr_session_id",        "INTEGER DEFAULT NULL"),
            ("flights", "is_deleted",            "INTEGER DEFAULT 0"),
            ("flights", "deleted_at",            "TEXT DEFAULT ''"),
            ("flights", "updated_at",            "TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))"),
            // user_profile
            ("user_profile", "medical_expiry",   "TEXT DEFAULT ''"),
            ("user_profile", "home_airport",     "TEXT DEFAULT ''"),
            ("user_profile", "timezone_id",      "TEXT DEFAULT 'America/New_York'"),
            ("user_profile", "app_tier",         "TEXT DEFAULT 'student'"),
        ]
        
        for (table, column, colType) in newColumns {
            let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(colType);"
            var stmt: OpaquePointer?
            // Ignore errors — column likely already exists
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        
        // Create new tables if missing
        createScanSessionsTable()
        createAircraftRegistryTable()
        
        // Re-create views (safe because of IF NOT EXISTS)
        createOrReplaceCurrencyView()
    }
    
    // MARK: - New Table Creation Helpers
    
    private func createScanSessionsTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS ocr_scan_sessions (
            id                      INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at              TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
            logbook_format          TEXT DEFAULT 'jeppesen',
            page_image_path         TEXT DEFAULT '',
            raw_observation_count   INTEGER DEFAULT 0,
            header_rows_skipped     INTEGER DEFAULT 0,
            rows_extracted          INTEGER DEFAULT 0,
            rows_committed          INTEGER DEFAULT 0,
            rows_rejected           INTEGER DEFAULT 0,
            processing_time_ms      REAL DEFAULT 0,
            avg_confidence          REAL DEFAULT 0,
            tilt_detected_degrees   REAL DEFAULT 0,
            status                  TEXT DEFAULT 'processing',
            column_map_json         TEXT DEFAULT ''
        );
        
        CREATE TABLE IF NOT EXISTS ocr_raw_observations (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id      INTEGER NOT NULL,
            raw_text        TEXT NOT NULL,
            confidence      REAL NOT NULL,
            bbox_x          REAL DEFAULT 0,
            bbox_y          REAL DEFAULT 0,
            bbox_w          REAL DEFAULT 0,
            bbox_h          REAL DEFAULT 0,
            assigned_column TEXT DEFAULT '',
            mapped_value    TEXT DEFAULT '',
            flight_row_idx  INTEGER DEFAULT -1
        );
        CREATE INDEX IF NOT EXISTS idx_obs_session ON ocr_raw_observations(session_id);
        """
        
        sql.components(separatedBy: ";").forEach { statement in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, trimmed + ";", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
    
    private func createAircraftRegistryTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS aircraft_registry (
            n_number        TEXT PRIMARY KEY,
            make            TEXT DEFAULT '',
            model           TEXT DEFAULT '',
            year            INTEGER DEFAULT 0,
            engine_type     TEXT DEFAULT '',
            category        TEXT DEFAULT 'Airplane',
            aircraft_class  TEXT DEFAULT 'ASEL',
            is_complex      INTEGER DEFAULT 0,
            is_high_perf    INTEGER DEFAULT 0,
            is_taa          INTEGER DEFAULT 0,
            last_fetched    TEXT DEFAULT ''
        );
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK { sqlite3_step(stmt) }
        sqlite3_finalize(stmt)
    }
    
    private func createOrReplaceCurrencyView() {
        // DROP first since CREATE VIEW doesn't support OR REPLACE on all SQLite versions
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DROP VIEW IF EXISTS v_currency;", -1, &stmt, nil)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
        
        let sql = """
        CREATE VIEW v_currency AS
        SELECT
            SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                     THEN landings_day ELSE 0 END)  AS landings_day_90,
            SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                     THEN landings_night ELSE 0 END) AS landings_night_90,
            SUM(CASE WHEN julianday('now') - julianday(date) <= 90
                     THEN night ELSE 0 END)          AS night_hours_90,
            SUM(CASE WHEN julianday('now') - julianday(date) <= 180
                     THEN approaches_count ELSE 0 END) AS approaches_180,
            SUM(CASE WHEN julianday('now') - julianday(date) <= 180
                     THEN holds_count ELSE 0 END)    AS holds_180
        FROM flights
        WHERE is_deleted = 0
          AND date >= date('now', '-180 days');
        """
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt2, nil) == SQLITE_OK { sqlite3_step(stmt2) }
        sqlite3_finalize(stmt2)
    }
}
    
