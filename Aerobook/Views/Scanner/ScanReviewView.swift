// ScanReviewView.swift
// AeroBook — Scanner group
//
// Build Order Item #10 — Review Table UI
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Full-page horizontally-scrollable review table rendered after CrossCheckEngine
// completes. Displays every PendingFlightRow as a table row where each cell is
// colour-coded by its CellReviewState:
//
//   .autoAccepted    → subtle green background  (✓ auto-verified)
//   .pendingReview   → white/neutral background  (awaiting review)
//   .flagged         → amber background + ⚠ icon (requires correction)
//   .correctedByPilot→ sky-blue background + ✎   (pilot-corrected)
//   .notScanned      → light grey / hatched       (not captured in this session)
//
// Tapping any cell opens the CellCorrectionSheet bottom sheet which shows:
//   • Cropped cell image from OCRCellResult.cellImage (if available)
//   • Raw OCR text vs current resolved value
//   • Editable text field pre-filled with current value
//   • Cross-check failure reasons (if any rules failed for this cell)
//   • Confirm / Skip Row / Cancel actions
//
// After the pilot corrects a cell, CrossCheckEngine.runRow() re-evaluates only
// the rules involving that columnId so the table updates immediately.
//
// The Commit Page button activates only when ScanPage.isReadyToCommit == true
// (no flagged cells remain in any included row).
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   ScanPage, PendingFlightRow, CellReviewState         (ScanPage.swift, PendingFlightRow.swift)
//   ColumnStrip, OCRCellResult                          (ColumnStrip.swift)
//   CrossCheckEngine, PageEvalResult, RuleEvalResult    (CrossCheckEngine.swift)
//   HTPairCombiner, PageCombineResult                   (HTPairCombiner.swift)
//   AeroTheme, AeroField, aeroPrimaryButton()           (Theme.swift)
//   ColumnDefinition, LogbookProfile                    (DatabaseManager+LogbookProfile.swift)

import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanReviewView
// ─────────────────────────────────────────────────────────────────────────────

/// Full-page scan review table. Present modally or push onto a NavigationStack.
///
/// Usage:
/// ```swift
/// ScanReviewView(
///     scanPage: scanPage,
///     evalResult: pageEvalResult,
///     combineResult: pageCombineResult,
///     onCommit: { /* navigate away, reset scanner */ },
///     onCancel: { /* dismiss */ }
/// )
/// ```
public struct ScanReviewView: View {

    // MARK: Inputs

    @ObservedObject var scanPage: ScanPage

    /// Full evaluation result produced by CrossCheckEngine.runAsync().
    /// Held for per-row re-evaluation after pilot corrections.
    let evalResult: PageEvalResult

    /// Combine result from HTPairCombiner — passed to CrossCheckEngine.runRow().
    /// May be nil if no H+t pairs exist in the profile.
    let combineResult: PageCombineResult?

    /// Called after scanPage.didCommitSuccessfully().
    let onCommit: () -> Void

    /// Called when the pilot taps Cancel / Discard.
    let onCancel: () -> Void

    // MARK: Local State

    /// The (rowIndex, columnId) pair currently open in the correction sheet.
    @State private var activeCorrectionTarget: CorrectionTarget? = nil

    /// Whether the discard-confirmation alert is showing.
    @State private var showDiscardAlert = false

    /// Whether the commit confirmation is showing (last review before write).
    @State private var showCommitConfirm = false

    /// Horizontal scroll offset — tracked for column header pinning.
    @State private var headerScrollOffset: CGFloat = 0

    /// Columns that should appear in the review table (excludes imageOnly cols).
    private var visibleColumns: [ColumnDefinition] {
        scanPage.profile.columns
            .filter { $0.dataType != .imageOnly }
            .sorted { $0.captureOrder < $1.captureOrder }
    }

    // MARK: Layout Constants

    private let rowIndexColWidth:  CGFloat = 36
    private let dateColWidth:      CGFloat = 84
    private let textColWidth:      CGFloat = 72
    private let hourColWidth:      CGFloat = 52
    private let intColWidth:       CGFloat = 44
    private let rowHeight:         CGFloat = 44
    private let headerHeight:      CGFloat = 52

    // MARK: Body

    public var body: some View {
        ZStack(alignment: .bottom) {
            AeroTheme.pageBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Navigation Bar ──────────────────────────────────────────
                reviewNavBar

                // ── Summary Banner ──────────────────────────────────────────
                summaryBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // ── Scrollable Table ────────────────────────────────────────
                reviewTable
                    .padding(.bottom, 100) // clearance for commit button
            }

            // ── Commit Button ──────────────────────────────────────────────
            commitBar
        }
        // ── Cell Correction Sheet ──────────────────────────────────────────
        .sheet(item: $activeCorrectionTarget) { target in
            CellCorrectionSheet(
                scanPage:      scanPage,
                rowIndex:      target.rowIndex,
                columnId:      target.columnId,
                combineResult: combineResult,
                onConfirm: { correctedValue in
                    applyCorrection(value: correctedValue, target: target)
                },
                onSkipRow: {
                    scanPage.skipRow(at: target.rowIndex)
                    activeCorrectionTarget = nil
                },
                onDismiss: {
                    activeCorrectionTarget = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // ── Discard Alert ──────────────────────────────────────────────────
        .alert("Discard Scan?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { onCancel() }
            Button("Keep Reviewing", role: .cancel) {}
        } message: {
            Text("All scanned data for this page will be lost. This cannot be undone.")
        }
        // ── Commit Confirm Alert ───────────────────────────────────────────
        .alert("Commit \(scanPage.includedRowCount) Flight\(scanPage.includedRowCount == 1 ? "" : "s")?",
               isPresented: $showCommitConfirm) {
            Button("Commit") {
                scanPage.beginCommit()
                onCommit()
            }
            Button("Review Again", role: .cancel) {}
        } message: {
            Text("\(scanPage.includedRowCount) rows will be saved to your logbook." +
                 (scanPage.skippedRowCount > 0
                  ? " \(scanPage.skippedRowCount) blank or skipped rows will not be saved."
                  : ""))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Sub-Views
    // ─────────────────────────────────────────────────────────────────────────

    // MARK: Navigation Bar

    private var reviewNavBar: some View {
        HStack(spacing: 12) {
            Button {
                showDiscardAlert = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                    Text("Discard")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(AeroTheme.textSecondary)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("Review Scan")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                if let pageNum = scanPage.pageNumber {
                    Text("Page \(pageNum)")
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }

            Spacer()

            // Phase progress pills
            HStack(spacing: 4) {
                ForEach(scanPage.phaseProgress, id: \.phase) { progress in
                    phasePill(progress: progress)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AeroTheme.cardBg)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AeroTheme.cardStroke),
            alignment: .bottom
        )
    }

    private func phasePill(progress: PageScanPhaseProgress) -> some View {
        let color: Color = progress.isPhaseComplete
            ? .statusGreen
            : (progress.failedStrips > 0 ? .statusRed : .statusAmber)
        let label = "P\(progress.phase.rawValue)"
        return Text(label)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(progress.isPhaseComplete ? .white : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(progress.isPhaseComplete
                        ? color
                        : color.opacity(0.15))
            .cornerRadius(4)
    }

    // MARK: Summary Banner

    private var summaryBanner: some View {
        let flagCount   = scanPage.totalFlaggedCellCount
        let autoCount   = scanPage.pendingRows
            .filter { $0.commitDecision == .include }
            .reduce(0) { total, row in
                total + row.cellStates.values.filter { $0 == .autoAccepted }.count
            }
        let blankCount  = scanPage.pendingRows.filter { $0.commitDecision == .blankRowSkipped }.count
        let includeCount = scanPage.includedRowCount

        return HStack(spacing: 0) {
            bannerStat(value: "\(includeCount)",
                       label: "Rows",
                       icon: "checkmark.circle.fill",
                       color: .statusGreen)
            Divider().frame(height: 32)
            bannerStat(value: "\(autoCount)",
                       label: "Auto-OK",
                       icon: "bolt.fill",
                       color: .sky500)
            Divider().frame(height: 32)
            bannerStat(value: "\(flagCount)",
                       label: "Need Review",
                       icon: flagCount > 0 ? "exclamationmark.triangle.fill" : "checkmark",
                       color: flagCount > 0 ? .statusAmber : .statusGreen)
            if blankCount > 0 {
                Divider().frame(height: 32)
                bannerStat(value: "\(blankCount)",
                           label: "Blank",
                           icon: "minus.circle",
                           color: .neutral400)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
    }

    private func bannerStat(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AeroTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Review Table

    private var reviewTable: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    // Sticky Column Header Row
                    columnHeaderRow

                    // Data Rows
                    ForEach(scanPage.pendingRows) { row in
                        reviewDataRow(row: row)
                        Divider()
                            .background(AeroTheme.cardStroke)
                    }
                }
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.cardStroke, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Column Header Row

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            // Row # cell
            headerCell(text: "#", width: rowIndexColWidth, isFirst: true)

            ForEach(visibleColumns) { col in
                headerCell(
                    text: col.groupLabel + (col.unitLabel.isEmpty ? "" : " (\(col.unitLabel))"),
                    width: columnWidth(for: col),
                    isFirst: false
                )
            }
        }
        .frame(height: headerHeight)
        .background(AeroTheme.brandDark)
    }

    private func headerCell(text: String, width: CGFloat, isFirst: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: width, height: headerHeight)
            .padding(.horizontal, 2)
            .overlay(
                Rectangle()
                    .frame(width: isFirst ? 0 : 1)
                    .foregroundStyle(.white.opacity(0.15)),
                alignment: .leading
            )
    }

    // MARK: Data Row

    private func reviewDataRow(row: PendingFlightRow) -> some View {
        let isSkipped = row.commitDecision != .include

        return HStack(spacing: 0) {
            // Row index cell
            rowIndexCell(rowIndex: row.rowIndex, isSkipped: isSkipped)

            // Field cells
            ForEach(visibleColumns) { col in
                reviewCell(row: row, column: col, isSkipped: isSkipped)
            }
        }
        .frame(height: rowHeight)
        .background(isSkipped
                    ? Color.neutral100.opacity(0.5)
                    : Color.white)
        .opacity(isSkipped ? 0.5 : 1.0)
    }

    private func rowIndexCell(rowIndex: Int, isSkipped: Bool) -> some View {
        Text("\(rowIndex + 1)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(isSkipped ? AeroTheme.textTertiary : AeroTheme.textSecondary)
            .frame(width: rowIndexColWidth, height: rowHeight)
            .background(AeroTheme.brandDark.opacity(0.04))
            .overlay(
                Rectangle()
                    .frame(width: 1)
                    .foregroundStyle(AeroTheme.cardStroke),
                alignment: .trailing
            )
    }

    private func reviewCell(row: PendingFlightRow, column: ColumnDefinition, isSkipped: Bool) -> some View {
        let state      = row.cellStates[column.columnId] ?? .notScanned
        let value      = resolvedDisplayValue(row: row, column: column)
        let width      = columnWidth(for: column)

        return Button {
            if !isSkipped {
                activeCorrectionTarget = CorrectionTarget(
                    rowIndex:  row.rowIndex,
                    columnId:  column.columnId
                )
            }
        } label: {
            ZStack {
                cellBackground(state: state, isSkipped: isSkipped)

                HStack(spacing: 3) {
                    Text(value.isEmpty ? "—" : value)
                        .font(.system(size: 12, weight: value.isEmpty ? .regular : .medium,
                                      design: column.dataType == .decimalHours ? .monospaced : .default))
                        .foregroundStyle(cellTextColor(state: state, isEmpty: value.isEmpty))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .center)

                    cellStateIcon(state: state)
                }
                .padding(.horizontal, 4)
            }
            .frame(width: width, height: rowHeight)
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(AeroTheme.cardStroke),
            alignment: .leading
        )
        .disabled(isSkipped || state == .notScanned)
    }

    // MARK: Commit Bar

    private var commitBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Flag count badge
                if scanPage.totalFlaggedCellCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.statusAmber)
                        Text("\(scanPage.totalFlaggedCellCount) cell\(scanPage.totalFlaggedCellCount == 1 ? "" : "s") need review")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.statusGreen)
                        Text("All cells verified")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.statusGreen)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    showCommitConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                        Text("Commit Page")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .aeroPrimaryButton()
                .frame(width: 160)
                .disabled(!scanPage.isReadyToCommit)
                .opacity(scanPage.isReadyToCommit ? 1.0 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AeroTheme.cardBg)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: -4)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Cell Helpers
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func cellBackground(state: CellReviewState, isSkipped: Bool) -> some View {
        if isSkipped {
            Color.neutral100.opacity(0.3)
        } else {
            switch state {
            case .autoAccepted:
                Color.statusGreenBg
            case .flagged:
                Color.statusAmberBg
            case .correctedByPilot:
                Color.sky100
            case .pendingReview:
                Color.white
            case .notScanned:
                Color(red: 240/255, green: 240/255, blue: 245/255)
            }
        }
    }

    private func cellTextColor(state: CellReviewState, isEmpty: Bool) -> Color {
        if isEmpty { return AeroTheme.textTertiary }
        switch state {
        case .autoAccepted:     return .statusGreen
        case .flagged:          return .statusAmber
        case .correctedByPilot: return .sky600
        case .pendingReview:    return AeroTheme.textPrimary
        case .notScanned:       return AeroTheme.textTertiary
        }
    }

    @ViewBuilder
    private func cellStateIcon(state: CellReviewState) -> some View {
        switch state {
        case .autoAccepted:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.statusGreen)
        case .flagged:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.statusAmber)
        case .correctedByPilot:
            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.sky500)
        case .pendingReview, .notScanned:
            EmptyView()
        }
    }

    private func columnWidth(for column: ColumnDefinition) -> CGFloat {
        switch column.dataType {
        case .decimalHours: return hourColWidth
        case .integer:      return intColWidth
        case .text:
            if column.flightField == "date"    { return dateColWidth }
            return textColWidth
        case .imageOnly:    return 0
        }
    }

    private func resolvedDisplayValue(row: PendingFlightRow, column: ColumnDefinition) -> String {
        row.fieldValues[column.flightField] ?? ""
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Correction Logic
    // ─────────────────────────────────────────────────────────────────────────

    private func applyCorrection(value: String, target: CorrectionTarget) {
        // Find the flightField for this columnId
        guard let colDef = scanPage.profile.columns.first(where: { $0.columnId == target.columnId })
        else { return }

        // Write the correction into ScanPage
        scanPage.applyPilotCorrection(
            value:       value,
            columnId:    target.columnId,
            flightField: colDef.flightField,
            forRowIndex: target.rowIndex
        )

        // Re-run cross-check rules that involve this columnId
        CrossCheckEngine.runRow(
            rowIndex:          target.rowIndex,
            correctedColumnId: target.columnId,
            scanPage:          scanPage,
            combineResult:     combineResult
        )

        activeCorrectionTarget = nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CorrectionTarget
// ─────────────────────────────────────────────────────────────────────────────

/// Identifies the cell currently open in the correction bottom sheet.
private struct CorrectionTarget: Identifiable {
    let rowIndex: Int
    let columnId: String
    var id: String { "\(rowIndex):\(columnId)" }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CellCorrectionSheet
// ─────────────────────────────────────────────────────────────────────────────

/// Bottom sheet for reviewing and correcting a single cell value.
///
/// Shows:
///   • Cropped cell image from OCRCellResult.cellImage (with fallback placeholder)
///   • Column label + OCR confidence score
///   • Raw OCR text (strikethrough if corrected)
///   • Editable text field pre-filled with the current resolved value
///   • All cross-check rule failure reasons for this cell
///   • Confirm / Skip Row / Cancel action buttons
private struct CellCorrectionSheet: View {

    // MARK: Inputs

    @ObservedObject var scanPage: ScanPage
    let rowIndex:      Int
    let columnId:      String
    let combineResult: PageCombineResult?
    let onConfirm:     (String) -> Void
    let onSkipRow:     () -> Void
    let onDismiss:     () -> Void

    // MARK: Local State

    @State private var editedValue: String = ""
    @FocusState private var fieldFocused: Bool

    // MARK: Derived

    private var column: ColumnDefinition? {
        scanPage.profile.columns.first { $0.columnId == columnId }
    }

    private var row: PendingFlightRow? {
        guard rowIndex < scanPage.pendingRows.count else { return nil }
        return scanPage.pendingRows[rowIndex]
    }

    private var cellReviewState: CellReviewState {
        row?.cellStates[columnId] ?? .notScanned
    }

    private var ocrResult: OCRCellResult? {
        scanPage.strip(for: columnId)?.cellResults[rowIndex]
    }

    private var cellImage: UIImage? {
        ocrResult?.cellImage
    }

    private var rawOCRText: String {
        ocrResult?.rawText ?? ""
    }

    private var ocrConfidence: Float {
        ocrResult?.confidence ?? 0.0
    }

    private var currentValue: String {
        guard let row = row, let col = column else { return "" }
        return row.fieldValues[col.flightField] ?? ""
    }

    private var flagReasons: [String] {
        // Gather failure reason from the cell review state directly
        if case .flagged(let reason) = cellReviewState {
            return [reason]
        }
        return []
    }

    private var failedRuleDescriptions: [String] {
        guard let row = row else { return [] }
        return row.failedRuleIds.compactMap { ruleId in
            let rule = scanPage.profile.crossCheckRules.first { $0.ruleId == ruleId }
            guard let rule = rule else { return nil }
            // Only surface rules that involve this columnId
            guard rule.fields.contains(columnId) else { return nil }
            return rule.description
        }
    }

    private var keyboardType: UIKeyboardType {
        switch column?.dataType {
        case .decimalHours: return .decimalPad
        case .integer:      return .numberPad
        default:            return .default
        }
    }

    // MARK: Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Cell Image + OCR Info ──────────────────────────────
                    cellImageSection
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    Divider()
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)

                    // ── Edit Field ─────────────────────────────────────────
                    editSection
                        .padding(.horizontal, 20)

                    // ── Cross-check Failures ───────────────────────────────
                    if !failedRuleDescriptions.isEmpty {
                        Divider()
                            .padding(.vertical, 16)
                            .padding(.horizontal, 20)
                        crossCheckSection
                            .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 24)

                    // ── Actions ────────────────────────────────────────────
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
            .background(AeroTheme.pageBg.ignoresSafeArea())
            .navigationTitle(column?.groupLabel ?? "Correct Cell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onDismiss)
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }
        }
        .onAppear {
            editedValue = currentValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                fieldFocused = true
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Cell Image Section
    // ─────────────────────────────────────────────────────────────────────────

    private var cellImageSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Cell image (cropped OCR cell)
            cellImageView
                .frame(width: 110, height: 76)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cellStateColor.opacity(0.4), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)

            // OCR Info
            VStack(alignment: .leading, spacing: 8) {
                // State badge
                cellStateBadge

                // Column detail
                if let col = column {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(col.groupLabel)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)
                        if !col.subLabel.isEmpty {
                            Text(col.subLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(AeroTheme.textSecondary)
                        }
                        Text("Row \(rowIndex + 1)")
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }

                // OCR confidence
                ocrConfidenceBar
            }
        }
    }

    @ViewBuilder
    private var cellImageView: some View {
        if let img = cellImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .clipped()
                .background(Color.black)
        } else {
            ZStack {
                Color.neutral100
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(AeroTheme.textTertiary)
                    Text("No image")
                        .font(.system(size: 10))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
            }
        }
    }

    private var cellStateBadge: some View {
        Group {
            switch cellReviewState {
            case .autoAccepted:
                badgeView(label: "AUTO-ACCEPTED", color: .statusGreen, icon: "checkmark.circle.fill")
            case .flagged:
                badgeView(label: "NEEDS REVIEW", color: .statusAmber, icon: "exclamationmark.triangle.fill")
            case .correctedByPilot:
                badgeView(label: "CORRECTED", color: .sky500, icon: "pencil.circle.fill")
            case .pendingReview:
                badgeView(label: "PENDING", color: .neutral400, icon: "clock")
            case .notScanned:
                badgeView(label: "NOT SCANNED", color: .neutral400, icon: "minus.circle")
            }
        }
    }

    private func badgeView(label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 9, weight: .black))
                .tracking(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private var ocrConfidenceBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("OCR Confidence")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AeroTheme.textTertiary)
                Spacer()
                Text("\(Int(ocrConfidence * 100))%")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(confidenceColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.neutral200)
                        .frame(height: 4)
                    Capsule()
                        .fill(confidenceColor)
                        .frame(width: geo.size.width * CGFloat(ocrConfidence), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private var confidenceColor: Color {
        if ocrConfidence >= 0.8 { return .statusGreen }
        if ocrConfidence >= 0.5 { return .statusAmber }
        return .statusRed
    }

    private var cellStateColor: Color {
        switch cellReviewState {
        case .autoAccepted:     return .statusGreen
        case .flagged:          return .statusAmber
        case .correctedByPilot: return .sky500
        default:                return .neutral300
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Edit Section
    // ─────────────────────────────────────────────────────────────────────────

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Raw OCR value display
            if !rawOCRText.isEmpty && rawOCRText != currentValue {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                    Text("OCR read:")
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                    Text(rawOCRText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .strikethrough(rawOCRText != editedValue, color: .statusRed.opacity(0.6))
                }
            }

            // Edit field
            VStack(alignment: .leading, spacing: 6) {
                Text("Corrected Value")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AeroTheme.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: fieldIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                        .frame(width: 20)

                    TextField(column?.groupLabel ?? "Value", text: $editedValue)
                        .keyboardType(keyboardType)
                        .autocorrectionDisabled()
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AeroTheme.textPrimary)
                        .focused($fieldFocused)

                    // Quick-clear button
                    if !editedValue.isEmpty {
                        Button {
                            editedValue = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(AeroTheme.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(AeroTheme.fieldBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(fieldFocused
                                ? AeroTheme.brandPrimary
                                : AeroTheme.fieldStroke,
                                lineWidth: fieldFocused ? 2 : 1)
                )
            }

            // Validation hint
            if let col = column, let range = col.validationRange {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                    Text("Valid range: \(range.lowerBound)–\(range.upperBound)")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
            }
        }
    }

    private var fieldIcon: String {
        switch column?.dataType {
        case .decimalHours: return "clock"
        case .integer:      return "number"
        case .text:         return "character.cursor.ibeam"
        default:            return "pencil"
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Cross-check Section
    // ─────────────────────────────────────────────────────────────────────────

    private var crossCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.statusAmber)
                Text("Validation Issues")
                    .font(.system(size: 12, weight: .bold))
                    .aeroSectionHeader()
            }

            VStack(spacing: 6) {
                ForEach(flagReasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.statusAmber)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(failedRuleDescriptions, id: \.self) { desc in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.statusAmber.opacity(0.6))
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(Color.statusAmberBg)
            .cornerRadius(AeroTheme.radiusSm)
            .overlay(
                RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                    .stroke(Color.statusAmber.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Action Buttons
    // ─────────────────────────────────────────────────────────────────────────

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Primary: Confirm correction
            Button {
                onConfirm(editedValue)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                    Text("Confirm Value")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .aeroPrimaryButton()

            // Secondary: Skip this flight row
            Button {
                onSkipRow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                    Text("Skip This Row")
                        .font(.system(size: 14, weight: .medium))
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
        }
    }
}



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG

/// Minimal preview harness that builds a ScanPage with mock data so Xcode Previews
/// can render ScanReviewView without needing a real scan session.
struct ScanReviewView_Previews: PreviewProvider {

    static var previews: some View {
        let profile = LogbookProfile.jeppesenPilotLogbook
        let page    = ScanPage(profile: profile, activeRowCount: 5, pageNumber: 12)

        // Populate mock data for 5 rows
        for i in 0..<5 {
            let row = page.pendingRows[i]
            row.fieldValues["date"]                    = "2024-0\(i+1)-15"
            row.fieldValues["aircraft_type"]           = "C172"
            row.fieldValues["aircraft_ident"]          = "N1234\(i)"
            row.fieldValues["route_from"]              = "KSFO"
            row.fieldValues["route_to"]                = "KOAK"
            row.fieldValues["total_time"]              = String(format: "%.1f", Double(i) * 0.7 + 1.2)
            row.fieldValues["pic"]                     = String(format: "%.1f", Double(i) * 0.5 + 0.5)
            row.fieldValues["dual_received"]           = "0.0"
            row.fieldValues["cross_country"]           = String(format: "%.1f", Double(i) * 0.3)

            switch i % 4 {
            case 0:
                row.cellStates["total_duration_hours"] = .autoAccepted
                row.cellStates["date"]                 = .autoAccepted
            case 1:
                row.cellStates["total_duration_hours"] = .flagged(reason: "Total time exceeds component sum")
                row.cellStates["pic_hours"]            = .flagged(reason: "Total time exceeds component sum")
                row.crossCheckFlags.insert("total_duration_hours")
            case 2:
                row.cellStates["total_duration_hours"] = .correctedByPilot
                row.cellStates["date"]                 = .pendingReview
            default:
                row.cellStates["total_duration_hours"] = .pendingReview
            }
        }

        // Blank-row detection: mark last row as blank
        page.pendingRows[4].commitDecision = .blankRowSkipped

        // Mock PageEvalResult (empty)
        let mockEval = PageEvalResult(
            ruleResults:      [],
            rowsWithFailures: 1,
            rowsAutoAccepted: 2,
            blankRowsSkipped: 1,
            processingTimeMs: 12.3
        )

        return NavigationView {
            ScanReviewView(
                scanPage:      page,
                evalResult:    mockEval,
                combineResult: nil,
                onCommit:      { print("Commit tapped") },
                onCancel:      { print("Cancel tapped") }
            )
        }
        .preferredColorScheme(.light)
    }
}

#endif
