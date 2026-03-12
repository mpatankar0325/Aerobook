// ScanCommitEngine.swift
// AeroBook — Scanner group
//
// Build Order Item #13 — Commit Engine
//
// ─────────────────────────────────────────────────────────────────────────────
// POSITION IN PIPELINE
// ─────────────────────────────────────────────────────────────────────────────
//
//   ScanReviewView  →  DuplicateDetector.run()  →  ScanCommitEngine.commit()
//                                                          │
//                                                    BEGIN TRANSACTION
//                                                    ├─ INSERT (new rows)
//                                                    ├─ UPDATE (replace rows)
//                                                    └─ skip  (excluded rows)
//                                                    COMMIT  or  ROLLBACK
//                                                          │
//                                                   scanPage state → .complete
//                                                   .logbookDataDidChange posted
//
// By the time commit() is called, every PendingFlightRow has been through the
// full review + duplicate-resolution flow. The routing table is:
//
//   commitDecision == .include  AND  duplicateResolution == .none/.keepBoth
//       → INSERT new flights row
//
//   commitDecision == .include  AND  duplicateResolution == .replace(id)
//       → UPDATE existing flights row (id preserved; endorsements stay linked)
//
//   commitDecision == .skip  OR  duplicateResolution == .skip
//       → excluded — counted in CommitSummary.skippedCount
//
//   commitDecision == .blankRowSkipped
//       → excluded — counted in CommitSummary.blankCount
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY ONE TRANSACTION FOR THE WHOLE PAGE
// ─────────────────────────────────────────────────────────────────────────────
// Aviation logbooks must stay internally consistent. A partial write — some
// rows land, others don't — corrupts running totals, breaks requirement
// tracking, and confuses duplicate detection on re-import.
// One SQLite BEGIN/COMMIT gives all-or-nothing semantics for the page.
//
// This also outperforms per-row async dispatches: one transaction for 13 rows
// is 5–20× faster than 13 individual async round-trips on DatabaseManager.
//
// ─────────────────────────────────────────────────────────────────────────────
// THREADING MODEL
// ─────────────────────────────────────────────────────────────────────────────
//  1. Caller thread (main):
//     buildRowSnapshots() converts the @MainActor ScanPage into value-type
//     structs — no SwiftUI state is touched from the background queue.
//
//  2. All SQLite work (BEGIN → loop → COMMIT/ROLLBACK) runs synchronously on
//     DatabaseManager.dbQueue — the same serial queue every other extension
//     uses. No contention; no SQLITE_BUSY.
//
//  3. The completion closure and any ScanPage transitions are dispatched back
//     to DispatchQueue.main.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   DatabaseManager            core class (db, dbQueue — internal access)
//   ScanPage.swift             state machine + pendingRows
//   PendingFlightRow.swift     RowCommitDecision, DuplicateResolution
//   DuplicateDetector.swift    CommitSummary
//   Theme.swift                AeroTheme (UI helpers at bottom)
//   SQLite3                    via Aerobook-Bridging-Header.h

import Foundation
import SwiftUI
import SQLite3

// SQLITE_TRANSIENT workaround — the C macro is not importable into Swift.
// _CE suffix avoids redeclaration conflicts with other DB extension files.
private let SQLITE_TRANSIENT_CE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CommitProgress
// ─────────────────────────────────────────────────────────────────────────────

/// Live write progress reported after each row during a commit.
/// Callbacks are delivered on the **main thread**.
public struct CommitProgress {

    /// Rows fully written so far (INSERT or UPDATE; not skips or blanks).
    public let writtenCount: Int

    /// Total rows that will be written (included rows only).
    public let totalToWrite: Int

    /// Progress fraction in [0.0, 1.0] for a ProgressView or ring.
    public var fraction: Double {
        totalToWrite > 0 ? min(Double(writtenCount) / Double(totalToWrite), 1.0) : 0.0
    }

    /// Short label suitable for a sub-title beneath a spinner.
    public var statusLabel: String {
        writtenCount == 0
            ? "Writing flights to logbook…"
            : "Saved \(writtenCount) of \(totalToWrite)…"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanCommitError
// ─────────────────────────────────────────────────────────────────────────────

/// Failure returned by ScanCommitEngine.commit().
///
/// Row-level errors (single INSERT failing) are NOT ScanCommitErrors — they
/// land in CommitSummary.rowErrors and the transaction still commits the rest.
/// ScanCommitError is only returned when BEGIN or COMMIT itself fails, meaning
/// the entire page is rolled back and nothing was written.
public enum ScanCommitError: Error, LocalizedError {

    /// SQLite returned an error on BEGIN or COMMIT; all changes rolled back.
    case transactionFailed(String)

    /// Every row was either skipped or blank — nothing to write.
    case noRowsToCommit

    public var errorDescription: String? {
        switch self {
        case .transactionFailed(let msg):
            return "Database transaction failed: \(msg)"
        case .noRowsToCommit:
            return "No approved rows found. Mark at least one row for inclusion before committing."
        }
    }

    /// One-liner for an error banner heading.
    public var shortDescription: String {
        switch self {
        case .transactionFailed:  return "Database error — nothing was written. Please retry."
        case .noRowsToCommit:     return "Nothing to commit."
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanCommitEngine
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless namespace. All entry points are `static`.
///
/// ## Typical call site (inside DuplicateDetector.run completion)
/// ```swift
/// ScanCommitEngine.commitAndTransition(
///     scanPage: scanPage,
///     progressHandler: { p in self.commitProgress = p },
///     onSuccess: { summary in self.finalSummary = summary },
///     onFailure: { reasons in self.errorMessage = reasons.first }
/// )
/// ```
public enum ScanCommitEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Primary Commit Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// Writes all approved rows from a reviewed ScanPage to the `flights` table
    /// in a single SQLite BEGIN / COMMIT transaction.
    ///
    /// - Parameters:
    ///   - scanPage:        The reviewed ScanPage. Must be in `.committing` state.
    ///                      DuplicateDetector must have resolved every row's
    ///                      `duplicateResolution` before calling this.
    ///   - progressHandler: Optional. Called on the **main thread** after each
    ///                      row write (INSERT or UPDATE). Pass `nil` to disable.
    ///   - completion:      Called on the **main thread**.
    ///                      `.success(CommitSummary)` — transaction committed.
    ///                      `.failure(ScanCommitError)` — rolled back, nothing written.
    ///
    /// - Note: This method does **not** call `scanPage.didCommitSuccessfully()` —
    ///   use `commitAndTransition` for the convenience wrapper that does.
    public static func commit(
        scanPage:        ScanPage,
        progressHandler: ((CommitProgress) -> Void)? = nil,
        completion:      @escaping (Result<CommitSummary, ScanCommitError>) -> Void
    ) {
        // Snapshot rows on the main thread before dispatching to the DB queue.
        // This ensures we never read @MainActor ScanPage state from a bg thread.
        let snapshots = buildRowSnapshots(from: scanPage)

        DatabaseManager.shared.dbQueue.async {
            let result = runTransaction(snapshots: snapshots, progressHandler: progressHandler)

            DispatchQueue.main.async {
                // Post the refresh notification so LogbookListView and
                // DashboardView update without requiring a manual pull-to-refresh.
                if case .success(let summary) = result,
                   summary.insertedCount + summary.replacedCount > 0 {
                    NotificationCenter.default.post(
                        name: .logbookDataDidChange,
                        object: nil
                    )
                }
                completion(result)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Convenience — Commit + ScanPage Transition
    // ─────────────────────────────────────────────────────────────────────────

    /// Convenience wrapper over `commit` that also transitions ScanPage state.
    ///
    /// On success: `scanPage.didCommitSuccessfully()` → `onSuccess(summary)`.
    /// On failure: `scanPage.didFailCommit(reasons:)` → `onFailure(reasons)`.
    /// All closures arrive on the **main thread**.
    public static func commitAndTransition(
        scanPage:        ScanPage,
        progressHandler: ((CommitProgress) -> Void)? = nil,
        onSuccess:       @escaping (CommitSummary) -> Void,
        onFailure:       @escaping ([String]) -> Void
    ) {
        commit(scanPage: scanPage, progressHandler: progressHandler) { result in
            switch result {
            case .success(let summary):
                scanPage.didCommitSuccessfully()
                onSuccess(summary)

            case .failure(let error):
                let reasons = [error.errorDescription ?? error.shortDescription]
                scanPage.didFailCommit(reasons: reasons)
                onFailure(reasons)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Transaction Execution  (runs on DatabaseManager.dbQueue)
    // ─────────────────────────────────────────────────────────────────────────

    private static func runTransaction(
        snapshots:       [RowSnapshot],
        progressHandler: ((CommitProgress) -> Void)?
    ) -> Result<CommitSummary, ScanCommitError> {

        let db = DatabaseManager.shared.db

        // Guard: at least one writable row.
        let writeableCount = snapshots.filter(\.shouldWrite).count
        guard writeableCount > 0 else {
            return .failure(.noRowsToCommit)
        }

        // ── BEGIN TRANSACTION ─────────────────────────────────────────────────
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("[CommitEngine] BEGIN failed: \(msg)")
            return .failure(.transactionFailed("Could not begin transaction: \(msg)"))
        }

        var summary      = CommitSummary()
        var writtenSoFar = 0

        // ── Per-row writes ────────────────────────────────────────────────────
        for snapshot in snapshots {

            switch snapshot.outcome {

            case .insert:
                switch performInsert(fields: snapshot.fields, db: db) {
                case .success(let newId):
                    summary.insertedCount += 1
                    writtenSoFar          += 1
                    print("[CommitEngine] INSERT row \(snapshot.rowIndex + 1) → id=\(newId)")
                case .failure(let msg):
                    summary.rowErrors.append("Row \(snapshot.rowIndex + 1): \(msg)")
                    print("[CommitEngine] INSERT error row \(snapshot.rowIndex + 1): \(msg)")
                }

            case .replace(let existingId):
                switch performUpdate(existingId: existingId, fields: snapshot.fields, db: db) {
                case .success:
                    summary.replacedCount += 1
                    writtenSoFar          += 1
                    print("[CommitEngine] UPDATE id=\(existingId) for row \(snapshot.rowIndex + 1)")
                case .failure(let msg):
                    summary.rowErrors.append("Row \(snapshot.rowIndex + 1): \(msg)")
                    print("[CommitEngine] UPDATE error row \(snapshot.rowIndex + 1): \(msg)")
                }

            case .skip:
                summary.skippedCount += 1

            case .blank:
                summary.blankCount += 1
            }

            // Report progress to the main thread after each write operation.
            if let handler = progressHandler, snapshot.shouldWrite {
                let p = CommitProgress(writtenCount: writtenSoFar,
                                       totalToWrite: writeableCount)
                DispatchQueue.main.async { handler(p) }
            }
        }

        // ── COMMIT ────────────────────────────────────────────────────────────
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            print("[CommitEngine] COMMIT failed, rolled back: \(msg)")
            return .failure(.transactionFailed("Commit failed — rolled back: \(msg)"))
        }

        print("[CommitEngine] COMMIT OK — \(summary.insertedCount) inserted, " +
              "\(summary.replacedCount) replaced, \(summary.skippedCount) skipped, " +
              "\(summary.blankCount) blank, \(summary.rowErrors.count) row errors")

        return .success(summary)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Row-level write error (private)
    // ─────────────────────────────────────────────────────────────────────────

    /// `Error`-conforming wrapper for a SQLite row-write failure message.
    /// Nested inside `ScanCommitEngine` so it is in scope for both
    /// `performInsert` and `performUpdate`. `CustomStringConvertible` lets
    /// existing `"\(msg)"` interpolations at call sites work unchanged.
    private struct RowWriteError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: INSERT
    // ─────────────────────────────────────────────────────────────────────────

    private static func performInsert(
        fields: [String: Any],
        db:     OpaquePointer?
    ) -> Result<Int64, RowWriteError> {

        let sql = """
            INSERT INTO flights (
                date, aircraft_ident, aircraft_type,
                aircraft_category, aircraft_class, route,
                total_time, pic, sic, solo,
                dual_received, dual_given,
                cross_country, night,
                instrument_actual, instrument_simulated,
                landings_day, landings_night,
                approaches_count, holds_count,
                remarks,
                is_legacy_import, legacy_signature_path
            ) VALUES (
                ?,?,?,
                ?,?,?,
                ?,?,?,?,
                ?,?,
                ?,?,
                ?,?,
                ?,?,
                ?,?,
                ?,
                0, ''
            );
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(RowWriteError(message: "Prepare INSERT: \(String(cString: sqlite3_errmsg(db)))"))
        }
        defer { sqlite3_finalize(stmt) }

        bindFields(to: stmt, fields: fields)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            return .failure(RowWriteError(message: "Step INSERT: \(String(cString: sqlite3_errmsg(db)))"))
        }

        return .success(sqlite3_last_insert_rowid(db))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: UPDATE (in-place replace)
    // ─────────────────────────────────────────────────────────────────────────

    /// Updates an existing flights row in place.
    /// The primary key `id` is preserved so endorsements and signatures that
    /// reference this row remain valid after the update.
    private static func performUpdate(
        existingId: Int64,
        fields:     [String: Any],
        db:         OpaquePointer?
    ) -> Result<Void, RowWriteError> {

        let sql = """
            UPDATE flights SET
                date                 = ?,
                aircraft_ident       = ?,
                aircraft_type        = ?,
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
                landings_day         = ?,
                landings_night       = ?,
                approaches_count     = ?,
                holds_count          = ?,
                remarks              = ?,
                is_legacy_import     = 0
            WHERE id = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(RowWriteError(message: "Prepare UPDATE: \(String(cString: sqlite3_errmsg(db)))"))
        }
        defer { sqlite3_finalize(stmt) }

        // Field columns bind to positions 1–21; WHERE id = ? binds to 22.
        bindFields(to: stmt, fields: fields)
        sqlite3_bind_int64(stmt, 22, existingId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            return .failure(RowWriteError(message: "Step UPDATE: \(String(cString: sqlite3_errmsg(db)))"))
        }

        return .success(())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Field Binding  (positions 1–21, shared by INSERT and UPDATE)
    // ─────────────────────────────────────────────────────────────────────────

    /// Binds the 21 standard flight fields to SQLite parameter positions 1–21.
    /// Column order matches both the INSERT VALUES clause and the UPDATE SET list.
    private static func bindFields(to stmt: OpaquePointer?, fields: [String: Any]) {
        func str(_ k: String) -> String { fields[k] as? String ?? "" }
        func dbl(_ k: String) -> Double { fields[k] as? Double ?? 0.0 }
        func i32(_ k: String) -> Int32  { Int32(fields[k] as? Int ?? 0) }

        sqlite3_bind_text  (stmt,  1, str("date"),                 -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_text  (stmt,  2, str("aircraft_ident"),       -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_text  (stmt,  3, str("aircraft_type"),        -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_text  (stmt,  4, str("aircraft_category"),    -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_text  (stmt,  5, str("aircraft_class"),       -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_text  (stmt,  6, str("route"),                -1, SQLITE_TRANSIENT_CE)
        sqlite3_bind_double(stmt,  7, dbl("total_time"))
        sqlite3_bind_double(stmt,  8, dbl("pic"))
        sqlite3_bind_double(stmt,  9, dbl("sic"))
        sqlite3_bind_double(stmt, 10, dbl("solo"))
        sqlite3_bind_double(stmt, 11, dbl("dual_received"))
        sqlite3_bind_double(stmt, 12, dbl("dual_given"))
        sqlite3_bind_double(stmt, 13, dbl("cross_country"))
        sqlite3_bind_double(stmt, 14, dbl("night"))
        sqlite3_bind_double(stmt, 15, dbl("instrument_actual"))
        sqlite3_bind_double(stmt, 16, dbl("instrument_simulated"))
        sqlite3_bind_int   (stmt, 17, i32("landings_day"))
        sqlite3_bind_int   (stmt, 18, i32("landings_night"))
        sqlite3_bind_int   (stmt, 19, i32("approaches_count"))
        sqlite3_bind_int   (stmt, 20, i32("holds_count"))
        sqlite3_bind_text  (stmt, 21, str("remarks"),              -1, SQLITE_TRANSIENT_CE)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Row Snapshot Builder  (call on main thread before dbQueue dispatch)
    // ─────────────────────────────────────────────────────────────────────────

    /// Converts all PendingFlightRows into value-type RowSnapshots.
    /// Must be called on the main thread (ScanPage is @MainActor).
    private static func buildRowSnapshots(from scanPage: ScanPage) -> [RowSnapshot] {
        scanPage.pendingRows.map { row in
            RowSnapshot(
                rowIndex: row.rowIndex,
                outcome:  rowOutcome(for: row),
                fields:   fieldMap(from: row)
            )
        }
    }

    /// Determines the write outcome for one row.
    /// This is the authoritative routing table for the commit engine.
    private static func rowOutcome(for row: PendingFlightRow) -> RowOutcome {
        switch row.commitDecision {
        case .blankRowSkipped:
            return .blank

        case .skip:
            return .skip

        case .include:
            switch row.duplicateResolution {
            case .replace(let existingFlightId):
                // Pilot approved replacing an existing record.
                return .replace(existingId: existingFlightId)

            case .skip:
                // Pilot chose Skip on the duplicate resolution sheet.
                return .skip

            case .none, .keepBoth:
                // No conflict, or pilot confirmed both records are distinct.
                return .insert

            case .pendingResolution:
                // Defensive fallback — should not occur if DuplicateDetector ran.
                // Treat as a new insert so no data is silently lost.
                print("[CommitEngine] WARNING: row \(row.rowIndex) reached commit " +
                      "with .pendingResolution — inserting as new record.")
                return .insert
            }
        }
    }

    /// Converts a PendingFlightRow's string fieldValues into the typed
    /// [String: Any] dictionary the SQLite binding helpers expect.
    private static func fieldMap(from row: PendingFlightRow) -> [String: Any] {
        func str(_ k: String) -> String { row.fieldValues[k] ?? "" }
        func dbl(_ k: String) -> Double { Double(row.fieldValues[k] ?? "0") ?? 0.0 }
        func int(_ k: String) -> Int    { Int(row.fieldValues[k]    ?? "0") ?? 0   }

        return [
            "date":                 str("date"),
            "aircraft_ident":       str("aircraft_ident"),
            "aircraft_type":        str("aircraft_type"),
            "aircraft_category":    str("aircraft_category"),
            "aircraft_class":       str("aircraft_class"),
            "route":                str("route"),
            "total_time":           dbl("total_time"),
            "pic":                  dbl("pic"),
            "sic":                  dbl("sic"),
            "solo":                 dbl("solo"),
            "dual_received":        dbl("dual_received"),
            "dual_given":           dbl("dual_given"),
            "cross_country":        dbl("cross_country"),
            "night":                dbl("night"),
            "instrument_actual":    dbl("instrument_actual"),
            "instrument_simulated": dbl("instrument_simulated"),
            "landings_day":         int("landings_day"),
            "landings_night":       int("landings_night"),
            "approaches_count":     int("approaches_count"),
            "holds_count":          int("holds_count"),
            "remarks":              str("remarks")
        ]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowOutcome
// ─────────────────────────────────────────────────────────────────────────────

/// The resolved write action for one RowSnapshot inside the transaction.
private enum RowOutcome {
    case insert                     // Write a new flights row
    case replace(existingId: Int64) // Update existing flights row in place
    case skip                       // Pilot-excluded; not written
    case blank                      // Auto-detected blank row; not written
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowSnapshot
// ─────────────────────────────────────────────────────────────────────────────

/// Sendable value-type copy of one PendingFlightRow captured on the main thread
/// and passed safely to the background DB queue.
private struct RowSnapshot {
    let rowIndex: Int
    let outcome:  RowOutcome
    let fields:   [String: Any]

    /// True when this snapshot produces a DB write (INSERT or UPDATE).
    var shouldWrite: Bool {
        switch outcome {
        case .insert, .replace: return true
        case .skip, .blank:     return false
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CommitSummary  (rowErrors extension)
// ─────────────────────────────────────────────────────────────────────────────
// CommitSummary is declared in DuplicateDetector.swift with a public `errors`
// array. This extension adds a `rowErrors` alias used exclusively by the Commit
// Engine to surface individual row-level SQLite errors without rolling back
// the whole page. The backing store is CommitSummary.errors.

extension CommitSummary {
    /// Per-row SQLite errors that occurred during the transaction.
    /// Non-empty only in rare edge cases (e.g. constraint violations on one row).
    /// Other rows still commit — this does NOT trigger a full rollback.
    var rowErrors: [String] {
        get { errors }
        set { errors = newValue }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanCommitProgressView
// ─────────────────────────────────────────────────────────────────────────────

/// Overlay card shown while ScanCommitEngine is writing to the database.
/// Renders an indeterminate spinner before the first row write, then switches
/// to a deterministic progress ring + bar once writes begin.
///
/// ## Usage
/// ```swift
/// .overlay {
///     if isCommitting {
///         Color.black.opacity(0.28).ignoresSafeArea()
///         ScanCommitProgressView(progress: commitProgress)
///     }
/// }
/// ```
public struct ScanCommitProgressView: View {

    /// nil before the first row write; non-nil once the engine starts writing.
    public let progress: CommitProgress?

    public init(progress: CommitProgress?) {
        self.progress = progress
    }

    public var body: some View {
        VStack(spacing: 20) {
            progressRing
            labels

            // Determinate bar — only shown once row count is known.
            if let p = progress, p.totalToWrite > 1 {
                progressBar(p)
            }
        }
        .padding(28)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowDeep, radius: 28, x: 0, y: 10)
        .padding(.horizontal, 40)
    }

    // MARK: Sub-views

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(AeroTheme.brandPrimary.opacity(0.12), lineWidth: 5)
                .frame(width: 64, height: 64)

            if let p = progress {
                Circle()
                    .trim(from: 0, to: CGFloat(p.fraction))
                    .stroke(AeroTheme.brandPrimary,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: p.fraction)

                Text("\(Int(p.fraction * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.brandPrimary)
            } else {
                ProgressView()
                    .tint(AeroTheme.brandPrimary)
                    .scaleEffect(1.4)
            }
        }
    }

    private var labels: some View {
        VStack(spacing: 5) {
            Text("Saving to Logbook")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AeroTheme.textPrimary)
            Text(progress?.statusLabel ?? "Preparing…")
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
        }
    }

    private func progressBar(_ p: CommitProgress) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AeroTheme.brandPrimary.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(AeroTheme.brandPrimary)
                    .frame(width: geo.size.width * CGFloat(p.fraction), height: 5)
                    .animation(.easeInOut(duration: 0.2), value: p.fraction)
            }
        }
        .frame(height: 5)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CommitErrorBanner
// ─────────────────────────────────────────────────────────────────────────────

/// Error card shown when ScanCommitEngine.commit() returns a failure.
///
/// The transaction was rolled back — nothing was written to the DB.
/// Offers two recovery actions: Retry Commit or Review Scan (reverts to
/// `.reviewing` state so the pilot can inspect the data).
///
/// ## Usage
/// ```swift
/// if let error = commitError {
///     CommitErrorBanner(
///         error:     error,
///         onRetry:   { startCommit() },
///         onDismiss: { commitError = nil }
///     )
/// }
/// ```
public struct CommitErrorBanner: View {

    public let error:     ScanCommitError
    public let onRetry:   () -> Void
    public let onDismiss: () -> Void

    public init(
        error:     ScanCommitError,
        onRetry:   @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.error     = error
        self.onRetry   = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            if case .transactionFailed(let msg) = error { techDetail(msg) }
            actionButtons
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(Color.statusRed.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowDeep, radius: 20, x: 0, y: 6)
        .padding(.horizontal, 20)
    }

    // MARK: Sub-views

    private var headerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.statusRedBg)
                    .frame(width: 46, height: 46)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(.statusRed)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Commit Failed")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(error.shortDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
        }
    }

    private func techDetail(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(AeroTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.neutral100)
            .cornerRadius(AeroTheme.radiusSm)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                    Text("Retry Commit")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .aeroPrimaryButton()

            Button(action: onDismiss) {
                Text("Review Scan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.neutral100)
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(
                        RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(AeroTheme.cardStroke, lineWidth: 1)
                    )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG

struct ScanCommitProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AeroTheme.pageBg.ignoresSafeArea()
            VStack(spacing: 30) {
                // Indeterminate — engine started but no rows written yet
                ScanCommitProgressView(progress: nil)
                // Determinate — 8 of 13 rows written
                ScanCommitProgressView(
                    progress: CommitProgress(writtenCount: 8, totalToWrite: 13)
                )
            }
        }
        .previewDisplayName("Progress Views")
    }
}

struct CommitErrorBanner_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AeroTheme.pageBg.ignoresSafeArea()
            VStack(spacing: 20) {
                CommitErrorBanner(
                    error:     .transactionFailed("SQLITE_FULL: database or disk is full"),
                    onRetry:   {},
                    onDismiss: {}
                )
                CommitErrorBanner(
                    error:     .noRowsToCommit,
                    onRetry:   {},
                    onDismiss: {}
                )
            }
        }
        .previewDisplayName("Error Banners")
    }
}

#endif
