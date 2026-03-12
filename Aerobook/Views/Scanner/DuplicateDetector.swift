// DuplicateDetector.swift
// AeroBook — Scanner group
//
// Build Order Item #11 — Duplicate Detector
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Runs between ScanReviewView's "Commit Page" action and the actual DB write.
// For each PendingFlightRow with commitDecision == .include it:
//
//   1. Queries the flights table for date + aircraft_ident matches.
//   2. If no match → calls addFlight() immediately (no interruption).
//   3. If a definite match (date + ident + total_time within ±0.05 hrs) →
//      presents DuplicateResolutionSheet with Skip / Replace / Keep Both.
//   4. If a candidate match (date + ident only) →
//      presents DuplicateResolutionSheet with the same three choices.
//
// Rows are processed sequentially so the pilot reviews one conflict at a time.
// Rows the pilot skips during review are recorded in the ScanPage with
// DuplicateResolution.skip so the review table can show a final summary.
//
// After all rows are processed, a completion handler is called with the
// CommitSummary (counts of inserted / replaced / skipped rows).
//
// ─────────────────────────────────────────────────────────────────────────────
// ARCHITECTURE
// ─────────────────────────────────────────────────────────────────────────────
//
//   ScanReviewView
//       │
//       │ onCommit closure calls:
//       ▼
//   DuplicateDetector.run(scanPage:completion:)           ← coordinator
//       │
//       ├─ no conflict → DatabaseManager.addFlight()
//       │
//       └─ conflict → presents DuplicateResolutionSheet  ← SwiftUI sheet
//                         │
//                         ├─ Skip      → mark row .skip, move to next
//                         ├─ Replace   → DatabaseManager.replaceFlight()
//                         └─ Keep Both → DatabaseManager.addFlight()
//
// ─────────────────────────────────────────────────────────────────────────────
// USAGE (from ScanReviewView)
// ─────────────────────────────────────────────────────────────────────────────
//
//   // In the view that owns the scan session:
//   @State private var duplicateDetector = DuplicateDetector()
//
//   // Called when "Commit Page" is confirmed:
//   duplicateDetector.run(scanPage: scanPage) { summary in
//       // summary.insertedCount, summary.replacedCount, summary.skippedCount
//       scanPage.didCommitSuccessfully()
//       showCommitSummary(summary)
//   }
//
//   // In the view body, attach the sheet presenter:
//   .sheet(item: $duplicateDetector.pendingResolution) { ctx in
//       DuplicateResolutionSheet(context: ctx)
//   }
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   DatabaseManager+DuplicateDetector.swift  (DB queries + mutations)
//   ScanPage, PendingFlightRow               (ScanPage.swift)
//   DuplicateResolution, DuplicateMatch      (PendingFlightRow.swift, DB ext.)
//   AeroTheme                                (Theme.swift)

import SwiftUI
import Foundation
import Combine
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CommitSummary
// ─────────────────────────────────────────────────────────────────────────────

/// Final tally of what happened during the commit run.
/// Shown to the pilot in a confirmation banner after all rows are processed.
public struct CommitSummary {
    /// Rows written to the DB as new entries.
    public var insertedCount:  Int = 0
    /// Rows that replaced an existing entry (pilot chose Replace).
    public var replacedCount:  Int = 0
    /// Rows the pilot explicitly skipped (or chose Skip on conflict).
    public var skippedCount:   Int = 0
    /// Rows that were blank (auto-detected, not pilot-initiated).
    public var blankCount:     Int = 0
    /// Any DB errors encountered (normally empty).
    public var errors:         [String] = []

    public var totalProcessed: Int { insertedCount + replacedCount + skippedCount + blankCount }
    public var hadErrors: Bool { !errors.isEmpty }

    public init(
        insertedCount: Int = 0,
        replacedCount: Int = 0,
        skippedCount:  Int = 0,
        blankCount:    Int = 0,
        errors:        [String] = []
    ) {
        self.insertedCount = insertedCount
        self.replacedCount = replacedCount
        self.skippedCount  = skippedCount
        self.blankCount    = blankCount
        self.errors        = errors
    }

    public var summaryLine: String {
        var parts: [String] = []
        if insertedCount  > 0 { parts.append("\(insertedCount) added") }
        if replacedCount  > 0 { parts.append("\(replacedCount) replaced") }
        if skippedCount   > 0 { parts.append("\(skippedCount) skipped") }
        if blankCount     > 0 { parts.append("\(blankCount) blank") }
        return parts.isEmpty ? "No flights processed." : parts.joined(separator: " · ")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ResolutionContext
// ─────────────────────────────────────────────────────────────────────────────

/// All information the DuplicateResolutionSheet needs to render one conflict.
/// Conforms to Identifiable so it can drive `.sheet(item:)` directly.
public struct ResolutionContext: Identifiable {
    public let id: UUID = UUID()

    /// The pending row being committed.
    public let pendingRow: PendingFlightRow

    /// The field values built from pendingRow (ready for addFlight / replaceFlight).
    public let incomingFields: [String: Any]

    /// All matching records found in the DB (definite matches first).
    public let matches: [DuplicateMatch]

    /// Called when the pilot makes a choice.
    public let onChoice: (PilotChoice) -> Void

    public enum PilotChoice {
        /// Do not write this row. Mark as skipped.
        case skip
        /// Overwrite the specified existing record.
        case replace(existingId: Int64)
        /// Write a new record even though a duplicate exists.
        case keepBoth
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DuplicateDetector
// ─────────────────────────────────────────────────────────────────────────────

/// Coordinator that drives the sequential per-row commit + duplicate-check loop.
///
/// Instantiate once per scan session. Reuse is safe but not necessary.
/// `@Observable` so SwiftUI views can bind to `pendingResolution` without
/// wrapping in ObservableObject boilerplate.
@MainActor
public final class DuplicateDetector: ObservableObject {

    // MARK: Published State

    /// Non-nil when a conflict requires pilot resolution. Drive a `.sheet(item:)`.
    @Published public var pendingResolution: ResolutionContext? = nil

    // MARK: Private State

    private var rowQueue:   [PendingFlightRow] = []
    private var fieldMaps:  [[String: Any]]    = []
    private var summary:    CommitSummary      = CommitSummary()
    private var completion: ((CommitSummary) -> Void)? = nil
    private var scanPage:   ScanPage?          = nil

    // MARK: Entry Point

    /// Begins the commit-and-deduplicate run for all included rows.
    ///
    /// - Parameters:
    ///   - scanPage:    The reviewed ScanPage. Rows with `.include` decision are processed.
    ///   - completion:  Called on the main thread when every row has been handled.
    public func run(
        scanPage:   ScanPage,
        completion: @escaping (CommitSummary) -> Void
    ) {
        self.scanPage   = scanPage
        self.completion = completion
        self.summary    = CommitSummary()

        // Build the queue: only rows the pilot approved for inclusion.
        let includedRows = scanPage.pendingRows.filter { $0.commitDecision == .include }
        let blankRows    = scanPage.pendingRows.filter { $0.commitDecision == .blankRowSkipped }
        summary.blankCount = blankRows.count

        // Convert each PendingFlightRow → [String: Any] for the DB layer.
        rowQueue  = includedRows
        fieldMaps = includedRows.map { buildFieldMap(from: $0) }

        guard !rowQueue.isEmpty else {
            completion(summary)
            return
        }

        processNextRow()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Sequential Processing Loop
    // ─────────────────────────────────────────────────────────────────────────

    private func processNextRow() {
        guard !rowQueue.isEmpty else {
            // All rows processed — notify caller.
            let finalSummary = summary
            completion?(finalSummary)
            completion = nil
            return
        }

        let row    = rowQueue.removeFirst()
        let fields = fieldMaps.removeFirst()

        // Blank-row guard (double-check; should already be excluded by run())
        guard row.commitDecision == .include else {
            summary.skippedCount += 1
            processNextRow()
            return
        }

        // Extract the three primary duplicate-detection keys.
        let date         = fields["date"]          as? String ?? ""
        let aircraftIdent = fields["aircraft_ident"] as? String ?? ""
        let totalTime    = fields["total_time"]    as? Double ?? 0.0

        // Run the DB lookup on a background thread to keep UI snappy.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let matches = DatabaseManager.shared.lookupDuplicates(
                date:          date,
                aircraftIdent: aircraftIdent,
                totalTime:     totalTime
            )

            DispatchQueue.main.async {
                if matches.isEmpty {
                    // No conflict — write immediately.
                    self.insertRow(row: row, fields: fields)
                } else {
                    // Conflict — present resolution sheet.
                    self.presentResolution(row: row, fields: fields, matches: matches)
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Conflict Resolution Presentation
    // ─────────────────────────────────────────────────────────────────────────

    private func presentResolution(
        row:     PendingFlightRow,
        fields:  [String: Any],
        matches: [DuplicateMatch]
    ) {
        pendingResolution = ResolutionContext(
            pendingRow:     row,
            incomingFields: fields,
            matches:        matches,
            onChoice: { [weak self] choice in
                guard let self = self else { return }
                self.pendingResolution = nil

                switch choice {
                case .skip:
                    self.scanPage?.setDuplicateResolution(.skip, forRowIndex: row.rowIndex)
                    self.summary.skippedCount += 1
                    self.processNextRow()

                case .replace(let existingId):
                    self.scanPage?.setDuplicateResolution(
                        .replace(existingFlightId: existingId),
                        forRowIndex: row.rowIndex
                    )
                    self.replaceRow(existingId: existingId, fields: fields, row: row)

                case .keepBoth:
                    self.scanPage?.setDuplicateResolution(.keepBoth, forRowIndex: row.rowIndex)
                    self.insertRow(row: row, fields: fields)
                }
            }
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: DB Write Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func insertRow(row: PendingFlightRow, fields: [String: Any]) {
        DatabaseManager.shared.addFlight(fields) { [weak self] rowId in
            guard let self = self else { return }
            if rowId != nil {
                self.summary.insertedCount += 1
            } else {
                self.summary.errors.append("Insert failed for row \(row.rowIndex + 1)")
            }
            self.processNextRow()
        }
    }

    private func replaceRow(existingId: Int64, fields: [String: Any], row: PendingFlightRow) {
        DatabaseManager.shared.replaceFlight(existingId: existingId, newValues: fields) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.summary.replacedCount += 1
            } else {
                self.summary.errors.append("Replace failed for row \(row.rowIndex + 1)")
            }
            self.processNextRow()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Field Map Builder
    // ─────────────────────────────────────────────────────────────────────────

    /// Converts a PendingFlightRow's fieldValues into the [String: Any] format
    /// accepted by DatabaseManager.addFlight() / replaceFlight().
    private func buildFieldMap(from row: PendingFlightRow) -> [String: Any] {
        func str(_ key: String) -> String { row.fieldValues[key] ?? "" }
        func dbl(_ key: String) -> Double { Double(row.fieldValues[key] ?? "0") ?? 0.0 }
        func int(_ key: String) -> Int    { Int(row.fieldValues[key]    ?? "0") ?? 0 }

        return [
            "date":                  str("date"),
            "aircraft_ident":        str("aircraft_ident"),
            "aircraft_type":         str("aircraft_type"),
            "aircraft_category":     str("aircraft_category"),
            "aircraft_class":        str("aircraft_class"),
            "route":                 str("route"),
            "total_time":            dbl("total_time"),
            "pic":                   dbl("pic"),
            "sic":                   dbl("sic"),
            "solo":                  dbl("solo"),
            "dual_received":         dbl("dual_received"),
            "dual_given":            dbl("dual_given"),
            "cross_country":         dbl("cross_country"),
            "night":                 dbl("night"),
            "instrument_actual":     dbl("instrument_actual"),
            "instrument_simulated":  dbl("instrument_simulated"),
            "landings_day":          int("landings_day"),
            "landings_night":        int("landings_night"),
            "approaches_count":      int("approaches_count"),
            "holds_count":           int("holds_count"),
            "remarks":               str("remarks"),
            "is_legacy_import":      false,
            "legacy_signature_path": ""
        ]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DuplicateResolutionSheet
// ─────────────────────────────────────────────────────────────────────────────

/// Bottom sheet presenting a duplicate conflict and three resolution choices.
///
/// Layout (top → bottom):
///   • Header: conflict type badge + match count
///   • Incoming flight card (data from the scan)
///   • Existing flight card(s) (data from the DB) — scrollable if multiple
///   • Side-by-side field diff table
///   • Action buttons: Skip / Replace / Keep Both
///
/// Sheet height: .large detent so the full comparison table is visible.
public struct DuplicateResolutionSheet: View {

    let context: ResolutionContext
    @Environment(\.dismiss) private var dismiss

    /// Which existing match the pilot is reviewing (when multiple candidates).
    @State private var selectedMatchIndex: Int = 0

    /// Whether a write is in progress (shows progress indicator on buttons).
    @State private var isProcessing: Bool = false

    private var primaryMatch: DuplicateMatch? {
        context.matches.indices.contains(selectedMatchIndex)
            ? context.matches[selectedMatchIndex]
            : context.matches.first
    }

    public var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // ── Conflict Banner ────────────────────────────────
                        conflictBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        // ── Match Picker (multiple candidates only) ────────
                        if context.matches.count > 1 {
                            matchPicker
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                        }

                        // ── Comparison Cards ───────────────────────────────
                        comparisonSection
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)

                        // ── Field Diff Table ───────────────────────────────
                        diffTable
                            .padding(.horizontal, 20)
                            .padding(.bottom, 120) // clearance for action buttons
                    }
                }

                // ── Action Buttons ─────────────────────────────────────────
                actionBar
            }
            .navigationTitle("Duplicate Found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        context.onChoice(.skip)
                    }
                    .foregroundStyle(AeroTheme.textSecondary)
                    .disabled(isProcessing)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isProcessing)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Conflict Banner
    // ─────────────────────────────────────────────────────────────────────────

    private var conflictBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.statusAmberBg)
                    .frame(width: 52, height: 52)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.statusAmber)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(primaryMatch?.isDefiniteMatch ?? true ? "Exact Duplicate" : "Possible Duplicate")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AeroTheme.textPrimary)

                    Text(primaryMatch?.isDefiniteMatch ?? true ? "EXACT" : "CANDIDATE")
                        .font(.system(size: 9, weight: .black))
                        .tracking(0.8)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(primaryMatch?.isDefiniteMatch ?? true
                                    ? Color.statusRedBg
                                    : Color.statusAmberBg)
                        .foregroundStyle(primaryMatch?.isDefiniteMatch ?? true
                                         ? .statusRed
                                         : .statusAmber)
                        .cornerRadius(5)
                }

                Text(primaryMatch?.matchDescription ?? "A matching flight was found in your logbook.")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if context.matches.count > 1 {
                    Text("\(context.matches.count) matching records found")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.statusAmber)
                }
            }
        }
        .padding(16)
        .background(Color.statusAmberBg.opacity(0.6))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(Color.statusAmber.opacity(0.25), lineWidth: 1)
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Match Picker
    // ─────────────────────────────────────────────────────────────────────────

    private var matchPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(context.matches.indices, id: \.self) { idx in
                    let match = context.matches[idx]
                    Button {
                        selectedMatchIndex = idx
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.isDefiniteMatch ? "Exact" : "Candidate")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(match.isDefiniteMatch ? .statusRed : .statusAmber)
                            Text("\(String(format: "%.1f", match.totalTime)) hrs")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AeroTheme.textPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(selectedMatchIndex == idx
                                    ? AeroTheme.brandPrimary.opacity(0.1)
                                    : AeroTheme.cardBg)
                        .cornerRadius(AeroTheme.radiusSm)
                        .overlay(
                            RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                                .stroke(selectedMatchIndex == idx
                                        ? AeroTheme.brandPrimary
                                        : AeroTheme.cardStroke,
                                        lineWidth: selectedMatchIndex == idx ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Comparison Section
    // ─────────────────────────────────────────────────────────────────────────

    private var comparisonSection: some View {
        HStack(alignment: .top, spacing: 12) {
            // Incoming (scanned)
            flightCard(
                title:     "Incoming (Scanned)",
                titleColor: .sky600,
                icon:       "camera.fill",
                date:       context.incomingFields["date"]          as? String ?? "—",
                ident:      context.incomingFields["aircraft_ident"] as? String ?? "—",
                acType:     context.incomingFields["aircraft_type"]  as? String ?? "—",
                route:      context.incomingFields["route"]          as? String ?? "—",
                totalTime:  context.incomingFields["total_time"]    as? Double ?? 0,
                pic:        context.incomingFields["pic"]           as? Double ?? 0,
                remarks:    context.incomingFields["remarks"]        as? String ?? ""
            )

            // Existing (in DB)
            if let match = primaryMatch {
                flightCard(
                    title:     "Existing (In Logbook)",
                    titleColor: .neutral600,
                    icon:       "book.closed.fill",
                    date:       match.date,
                    ident:      match.aircraftIdent,
                    acType:     match.aircraftType,
                    route:      match.route,
                    totalTime:  match.totalTime,
                    pic:        match.pic,
                    remarks:    match.remarks
                )
            }
        }
    }

    private func flightCard(
        title: String, titleColor: Color, icon: String,
        date: String, ident: String, acType: String,
        route: String, totalTime: Double, pic: Double, remarks: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(titleColor)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(titleColor)
            }

            Divider()

            // Fields
            cardRow(label: "Date",    value: date)
            cardRow(label: "Ident",   value: ident)
            cardRow(label: "Type",    value: acType)
            cardRow(label: "Route",   value: route.isEmpty ? "—" : route)
            cardRow(label: "Total",   value: String(format: "%.1f hrs", totalTime))
            cardRow(label: "PIC",     value: String(format: "%.1f hrs", pic))
            if !remarks.isEmpty {
                cardRow(label: "Remarks", value: remarks)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
    }

    private func cardRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(AeroTheme.textTertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AeroTheme.textPrimary)
                .lineLimit(2)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Diff Table
    // ─────────────────────────────────────────────────────────────────────────

    private var diffTable: some View {
        guard let match = primaryMatch else { return AnyView(EmptyView()) }

        let rows: [(label: String, incoming: String, existing: String, isDifferent: Bool)] = [
            diffRow("Total Time",  dbl("total_time"),       match.totalTime),
            diffRow("PIC",         dbl("pic"),              match.pic),
            diffRow("Dual Rx",     dbl("dual_received"),    match.dualReceived),
            diffRow("XC",          dbl("cross_country"),    match.crossCountry),
            diffRow("Night",       dbl("night"),            match.night),
            diffRow("Inst Act",    dbl("instrument_actual"), match.instrumentActual),
            diffRow("Inst Sim",    dbl("instrument_simulated"), match.instrumentSimulated),
            diffRowInt("LDG Day",  int("landings_day"),     match.landingsDay),
            diffRowInt("LDG Night", int("landings_night"),  match.landingsNight),
        ].filter { $0.isDifferent || $0.label == "Total Time" } // always show total, others only if different

        if rows.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.brandPrimary)
                    Text("Field Differences")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .textCase(.uppercase)
                }

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Field")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Incoming")
                            .frame(width: 80, alignment: .trailing)
                        Text("Existing")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AeroTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AeroTheme.brandDark.opacity(0.06))

                    ForEach(rows.indices, id: \.self) { idx in
                        let row = rows[idx]
                        HStack {
                            Text(row.label)
                                .font(.system(size: 13))
                                .foregroundStyle(AeroTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.incoming)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(row.isDifferent ? .sky600 : AeroTheme.textPrimary)
                                .frame(width: 80, alignment: .trailing)
                            Text(row.existing)
                                .font(.system(size: 13, weight: row.isDifferent ? .semibold : .regular,
                                              design: .monospaced))
                                .foregroundStyle(row.isDifferent ? .statusAmber : AeroTheme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(idx % 2 == 0 ? Color.clear : AeroTheme.pageBg)
                        if idx < rows.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.cardStroke, lineWidth: 1)
                )
            }
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Action Bar
    // ─────────────────────────────────────────────────────────────────────────

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 10) {
                // Row 1: Replace (primary — most common intentional choice)
                if let match = primaryMatch {
                    Button {
                        withAnimation { isProcessing = true }
                        context.onChoice(.replace(existingId: match.existingId))
                    } label: {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 15))
                            }
                            Text("Replace Existing")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .aeroPrimaryButton()
                    .disabled(isProcessing)
                }

                // Row 2: Keep Both + Skip side by side
                HStack(spacing: 10) {
                    Button {
                        withAnimation { isProcessing = true }
                        context.onChoice(.keepBoth)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14))
                            Text("Keep Both")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AeroTheme.brandPrimary.opacity(0.08))
                        .cornerRadius(AeroTheme.radiusMd)
                        .overlay(
                            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                .stroke(AeroTheme.brandPrimary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .disabled(isProcessing)

                    Button {
                        context.onChoice(.skip)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 14))
                            Text("Skip This Row")
                                .font(.system(size: 14, weight: .semibold))
                        }
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
                    .disabled(isProcessing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(AeroTheme.cardBg)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: -4)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Diff Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func dbl(_ key: String) -> Double {
        context.incomingFields[key] as? Double ?? 0.0
    }
    private func int(_ key: String) -> Int {
        context.incomingFields[key] as? Int ?? 0
    }

    private func diffRow(
        _ label: String, _ incoming: Double, _ existing: Double
    ) -> (label: String, incoming: String, existing: String, isDifferent: Bool) {
        let diff = abs(incoming - existing) > 0.049
        return (
            label:       label,
            incoming:    String(format: "%.1f", incoming),
            existing:    String(format: "%.1f", existing),
            isDifferent: diff
        )
    }

    private func diffRowInt(
        _ label: String, _ incoming: Int, _ existing: Int
    ) -> (label: String, incoming: String, existing: String, isDifferent: Bool) {
        return (
            label:       label,
            incoming:    "\(incoming)",
            existing:    "\(existing)",
            isDifferent: incoming != existing
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CommitSummaryBanner
// ─────────────────────────────────────────────────────────────────────────────

/// Inline banner shown after all rows have been committed.
/// Embed this in the ScanReviewView or any parent view that drives the commit flow.
///
/// Usage:
/// ```swift
/// if let summary = finalSummary {
///     CommitSummaryBanner(summary: summary, onDismiss: { finalSummary = nil })
/// }
/// ```
public struct CommitSummaryBanner: View {

    let summary:   CommitSummary
    let onDismiss: () -> Void

    public var body: some View {
        VStack(spacing: 14) {
            // Icon + title
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(summary.hadErrors ? Color.statusAmberBg : Color.statusGreenBg)
                        .frame(width: 48, height: 48)
                    Image(systemName: summary.hadErrors
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(summary.hadErrors ? .statusAmber : .statusGreen)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.hadErrors ? "Commit Completed with Warnings" : "Page Committed!")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text(summary.summaryLine)
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
                Spacer()
            }

            // Stat row
            HStack(spacing: 0) {
                statCell(value: summary.insertedCount, label: "Added",    color: .statusGreen)
                Divider().frame(height: 32)
                statCell(value: summary.replacedCount, label: "Replaced", color: .sky500)
                Divider().frame(height: 32)
                statCell(value: summary.skippedCount,  label: "Skipped",  color: .neutral400)
                if summary.blankCount > 0 {
                    Divider().frame(height: 32)
                    statCell(value: summary.blankCount, label: "Blank",   color: .neutral300)
                }
            }
            .background(AeroTheme.pageBg)
            .cornerRadius(AeroTheme.radiusSm)

            // Error list (rare)
            if summary.hadErrors {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.errors, id: \.self) { err in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.statusRed)
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(AeroTheme.textSecondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.statusRedBg)
                .cornerRadius(AeroTheme.radiusSm)
            }

            // Dismiss
            Button {
                onDismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .bold))
            }
            .aeroPrimaryButton()
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowDeep, radius: 24, x: 0, y: 8)
        .padding(.horizontal, 20)
    }

    private func statCell(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(value > 0 ? color : AeroTheme.textTertiary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AeroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG

struct DuplicateResolutionSheet_Previews: PreviewProvider {

    static var previews: some View {
        let match = DuplicateMatch(
            existingId:           42,
            date:                 "2024-03-15",
            aircraftIdent:        "N12345",
            aircraftType:         "C172",
            totalTime:            1.3,
            route:                "KSFO-KOAK",
            pic:                  1.3,
            dualReceived:         0.0,
            crossCountry:         0.8,
            night:                0.0,
            instrumentActual:     0.0,
            instrumentSimulated:  0.0,
            landingsDay:          2,
            landingsNight:        0,
            remarks:              "Pattern work",
            isDefiniteMatch:      true
        )

        let incomingFields: [String: Any] = [
            "date":                  "2024-03-15",
            "aircraft_ident":        "N12345",
            "aircraft_type":         "C172",
            "aircraft_category":     "Airplane",
            "aircraft_class":        "Single Engine Land",
            "route":                 "KSFO-KOAK",
            "total_time":            1.4,
            "pic":                   1.4,
            "sic":                   0.0,
            "solo":                  0.0,
            "dual_received":         0.0,
            "dual_given":            0.0,
            "cross_country":         0.8,
            "night":                 0.0,
            "instrument_actual":     0.0,
            "instrument_simulated":  0.0,
            "landings_day":          2,
            "landings_night":        0,
            "approaches_count":      0,
            "holds_count":           0,
            "remarks":               "Pattern work — corrected total"
        ]

        let mockRow = PendingFlightRow(rowIndex: 0, fieldValues: [:])

        let context = ResolutionContext(
            pendingRow:     mockRow,
            incomingFields: incomingFields,
            matches:        [match],
            onChoice:       { choice in print("Pilot chose: \(choice)") }
        )

        return DuplicateResolutionSheet(context: context)
    }
}

struct CommitSummaryBanner_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            AeroTheme.pageBg.ignoresSafeArea()
            CommitSummaryBanner(
                summary: CommitSummary(
                    insertedCount: 11,
                    replacedCount: 1,
                    skippedCount:  1,
                    blankCount:    3,
                    errors:        []
                ),
                onDismiss: {}
            )
        }
    }
}

#endif
