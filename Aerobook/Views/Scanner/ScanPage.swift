// ScanPage.swift
// AeroBook — Scanner group
//
// The top-level in-memory model for a single page scan session.
// One ScanPage is created when the pilot taps "Start Scan" and is
// discarded (never persisted) when the session ends — whether by
// a successful commit, a cancel, or the app being backgrounded.
//
// Ownership:
//   • ScanPage owns its ColumnStrip instances (one per profile column).
//   • ScanPage owns its PendingFlightRow instances (one per active data row).
//   • Nothing in ScanPage touches SQLite — that is the commit engine's job.
//
// Threading:
//   • ScanPage is created and read on the main thread by the scanner UI.
//   • OCR processing mutates ColumnStrip.cellResults on a background thread.
//     Callers must dispatch back to main before reading strips for UI updates.
//   • ScanPage is marked @MainActor so SwiftUI views can observe it directly
//     via @StateObject / @ObservedObject without additional dispatching.
//
// Sections 3, 7, and 8 of the AeroBook Scanner Architecture document are
// the authoritative specification for all types in this file.

import Foundation
import UIKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PageScanState
// ─────────────────────────────────────────────────────────────────────────────

/// The state machine for the overall page scan session (Section 7).
/// The scanner UI drives transitions; ScanPage validates them.
///
///  idle → capturing → processing → reviewing → committing → complete
///                  ↗                                        ↘
///            error ←──────────────────────────────────────── (retry → capturing)
public enum PageScanState: Equatable {

    /// No scan in progress. Initial state and state after a completed scan.
    case idle

    /// ROI camera overlay is live. The pilot is aligning a strip under the cutout.
    /// Associated value: the columnId currently being captured.
    case capturing(columnId: String)

    /// Image captured; quality gate and OCR are running on a background thread.
    /// Associated value: the columnId being processed.
    case processing(columnId: String)

    /// All desired phases captured. Review table is visible.
    /// Pilot is reviewing and correcting cells.
    case reviewing

    /// Pilot tapped "Commit Page". Duplicate check is running or DB write is
    /// in progress. UI shows a progress indicator.
    case committing

    /// All approved rows written to the DB successfully.
    /// A confirmation banner is shown; the pilot can start the next page.
    case complete

    /// OCR failed or quality gate rejected the strip.
    /// Pilot taps "Retry Capture" to return to .capturing for the same column.
    case error(columnId: String, reasons: [String])
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PageScanPhaseProgress
// ─────────────────────────────────────────────────────────────────────────────

/// Summarises capture progress per phase for the phase-map UI component.
public struct PageScanPhaseProgress {

    /// Phase number 1–5.
    public let phase: CapturePhase

    /// Total strips belonging to this phase.
    public let totalStrips: Int

    /// Strips in state .complete for this phase.
    public let completedStrips: Int

    /// Strips in state .failed or .error for this phase.
    public let failedStrips: Int

    /// All strips in this phase are .complete or .skipped.
    public var isPhaseComplete: Bool { completedStrips + skippedStrips == totalStrips }

    /// Strips in state .skipped.
    public var skippedStrips: Int { totalStrips - completedStrips - failedStrips - pendingStrips }

    /// Strips still in .pending or .capturing or .processing state.
    public var pendingStrips: Int

    public init(phase: CapturePhase, totalStrips: Int, completedStrips: Int,
                failedStrips: Int, pendingStrips: Int) {
        self.phase            = phase
        self.totalStrips      = totalStrips
        self.completedStrips  = completedStrips
        self.failedStrips     = failedStrips
        self.pendingStrips    = pendingStrips
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanPage
// ─────────────────────────────────────────────────────────────────────────────

/// The top-level in-memory model for one page scan session.
///
/// Create one instance when the pilot starts scanning. Discard it when the
/// session ends (commit, cancel, or background). Never persist a ScanPage —
/// the only output that survives session end is the DB write performed by
/// the commit engine from the approved PendingFlightRows.
@MainActor
public final class ScanPage: ObservableObject {

    // MARK: Profile & Geometry

    /// The logbook profile driving all column and rule logic for this scan.
    public let profile: LogbookProfile

    /// The number of data rows the pilot confirmed for this page.
    /// Normally equals profile.dataRowCount (13 for Jeppesen).
    /// May be less on the last partial page of a logbook.
    /// Must not be changed after ScanPage is initialised.
    public let activeRowCount: Int

    /// Page number within the logbook (display only — not persisted).
    /// Shown in the review table header so the pilot knows which page they scanned.
    public let pageNumber: Int?

    /// Timestamp when the pilot tapped "Start Scan".
    public let startedAt: Date

    // MARK: State Machine

    /// Current scan session state. Published so SwiftUI scanner views update automatically.
    @Published public private(set) var scanState: PageScanState = .idle

    // MARK: Strips

    /// All ColumnStrips for this page, one per profile column, in captureOrder.
    /// Allocated at init; mutated in-place as each strip is captured and OCR'd.
    /// Ordered ascending by ColumnDefinition.captureOrder.
    public let strips: [ColumnStrip]

    /// Lookup by columnId. Populated at init from `strips`.
    private let stripByColumnId: [String: ColumnStrip]

    // MARK: Pending Rows

    /// Assembled flight rows produced after OCR completes for Phase 1+2 minimum.
    /// Count equals activeRowCount. Rows are added in rowIndex order.
    /// Published so the review table rebuilds when the cross-check engine
    /// updates cell states.
    @Published public private(set) var pendingRows: [PendingFlightRow]

    // MARK: Commit Stats

    /// Number of rows the pilot approved for inclusion at last review.
    /// Computed from pendingRows on demand — not stored separately.
    public var includedRowCount: Int {
        pendingRows.filter { $0.commitDecision == .include }.count
    }

    /// Number of rows that will be skipped (blank detection or pilot skip).
    public var skippedRowCount: Int {
        pendingRows.filter { $0.commitDecision != .include }.count
    }

    /// true when all included rows are fully resolved and the commit button may enable.
    public var isReadyToCommit: Bool {
        guard case .reviewing = scanState else { return false }
        return pendingRows
            .filter { $0.commitDecision == .include }
            .allSatisfy { $0.isFullyResolved }
    }

    // MARK: Init

    /// Creates a new ScanPage for the given profile and row count.
    ///
    /// - Parameters:
    ///   - profile: The active LogbookProfile. All column and rule logic derives from this.
    ///   - activeRowCount: Number of data rows on this page (pilot-confirmed).
    ///                     Defaults to profile.dataRowCount.
    ///   - pageNumber: Optional display-only page number shown in the review header.
    public init(
        profile: LogbookProfile,
        activeRowCount: Int? = nil,
        pageNumber: Int? = nil
    ) {
        self.profile        = profile
        self.activeRowCount = activeRowCount ?? profile.dataRowCount
        self.pageNumber     = pageNumber
        self.startedAt      = Date()

        // Allocate strips in captureOrder — this is the sequence the scanner UI walks.
        let sortedColumns = profile.columns.sorted { $0.captureOrder < $1.captureOrder }
        let allocatedStrips = sortedColumns.map { ColumnStrip(definition: $0) }
        self.strips = allocatedStrips

        // Build columnId → strip lookup for O(1) access.
        var lookup: [String: ColumnStrip] = [:]
        for strip in allocatedStrips {
            lookup[strip.definition.columnId] = strip
        }
        self.stripByColumnId = lookup

        // Allocate pending rows — one per data row, empty until OCR populates them.
        self.pendingRows = (0..<(activeRowCount ?? profile.dataRowCount)).map {
            PendingFlightRow(rowIndex: $0)
        }
    }

    // MARK: State Transitions

    /// Transitions the scan session to .capturing for a given column.
    /// Safe to call from the scanner UI when the pilot taps the next strip button.
    ///
    /// - Parameter columnId: The columnId of the strip about to be captured.
    public func beginCapture(for columnId: String) {
        guard let strip = stripByColumnId[columnId] else {
            assertionFailure("beginCapture called with unknown columnId: \(columnId)")
            return
        }
        strip.captureState = .capturing
        scanState = .capturing(columnId: columnId)
    }

    /// Called by the camera layer when an image has been captured for a strip.
    /// Transitions to .processing and stores the raw image on the strip.
    ///
    /// - Parameters:
    ///   - image: The UIImage captured by the ROI camera overlay.
    ///   - columnId: The columnId of the strip that was captured.
    public func didCapture(image: UIImage, for columnId: String) {
        guard let strip = stripByColumnId[columnId] else { return }
        strip.rawImage     = image
        strip.captureState = .processing
        scanState          = .processing(columnId: columnId)
    }

    /// Called by the OCR pipeline when all cell results for a strip are ready.
    /// Transitions the strip to .complete and updates scanState accordingly.
    /// If all Phase 1+2 strips are now complete, transitions session to .reviewing.
    ///
    /// - Parameters:
    ///   - results: Array of OCRCellResult, one per active data row.
    ///   - qualityResult: The image quality report from the gate.
    ///   - columnId: The columnId of the completed strip.
    public func didCompleteOCR(
        results: [OCRCellResult],
        qualityResult: StripQualityResult,
        for columnId: String
    ) {
        guard let strip = stripByColumnId[columnId] else { return }

        strip.qualityResult = qualityResult
        for result in results {
            strip.cellResults[result.rowIndex] = result
        }
        strip.captureState = .complete
        scanState = .idle   // Return to idle; scanner UI picks next strip.
    }

    /// Called by the image quality gate or OCR engine when processing fails.
    /// Transitions the strip and session to .error so the pilot can retake.
    ///
    /// - Parameters:
    ///   - reasons: Human-readable failure reasons for the retake prompt.
    ///   - columnId: The columnId of the failed strip.
    public func didFailProcessing(reasons: [String], for columnId: String) {
        guard let strip = stripByColumnId[columnId] else { return }
        strip.captureState = .failed(reasons: reasons)
        strip.rawImage     = nil   // Discard bad image immediately.
        scanState          = .error(columnId: columnId, reasons: reasons)
    }

    /// Pilot tapped "Retry Capture" after a strip failure.
    /// Resets strip state and transitions back to .capturing.
    ///
    /// - Parameter columnId: The columnId to retry.
    public func retryCapture(for columnId: String) {
        guard let strip = stripByColumnId[columnId] else { return }
        strip.captureState = .pending
        strip.rawImage     = nil
        strip.qualityResult = nil
        strip.cellResults.removeAll()
        beginCapture(for: columnId)
    }

    /// Pilot skipped a non-required strip (e.g. Multi Engine for a student).
    /// Only valid for strips whose ColumnDefinition.isRequired == false.
    ///
    /// - Parameter columnId: The columnId to skip.
    public func skipStrip(for columnId: String) {
        guard let strip = stripByColumnId[columnId],
              !strip.definition.isRequired else { return }
        strip.captureState = .skipped
        // Write defaultValue into all pending rows for this column's flightField.
        let field = strip.definition.flightField
        let defaultVal = strip.definition.defaultValue
        for row in pendingRows {
            if row.fieldValues[field] == nil {
                row.fieldValues[field] = defaultVal
                row.cellStates[strip.definition.columnId] = .autoAccepted
            }
        }
    }

    /// Transitions the session into the review phase.
    /// Called by the cross-check engine after it has populated all cellStates.
    /// Requires at minimum Phase 1+2 strips to be complete.
    public func transitionToReview() {
        guard phase1And2Complete else {
            assertionFailure("Cannot enter review: Phase 1+2 not complete.")
            return
        }
        scanState = .reviewing
    }

    /// Transitions the session to .committing when the pilot taps "Commit Page".
    /// Only valid when isReadyToCommit is true.
    public func beginCommit() {
        guard isReadyToCommit else { return }
        scanState = .committing
    }

    /// Called by the commit engine when all DB writes succeed.
    public func didCommitSuccessfully() {
        scanState = .complete
    }

    /// Called by the commit engine if the DB transaction fails.
    public func didFailCommit(reasons: [String]) {
        // Roll back to reviewing so the pilot can try again.
        scanState = .reviewing
    }

    // MARK: PendingRow Mutations (called by cross-check engine and review UI)

    /// Writes assembled field values into a pending row after the H+t pair
    /// combiner has resolved all captured strips for that row.
    ///
    /// - Parameters:
    ///   - fieldValues: Dictionary of flightField → resolved string value.
    ///   - cellStates: Dictionary of columnId → initial CellReviewState.
    ///   - rowIndex: The zero-based row index to update.
    public func updatePendingRow(
        fieldValues: [String: String],
        cellStates: [String: CellReviewState],
        forRowIndex rowIndex: Int
    ) {
        guard rowIndex < pendingRows.count else { return }
        let row = pendingRows[rowIndex]
        for (field, value) in fieldValues {
            row.fieldValues[field] = value
        }
        for (columnId, state) in cellStates {
            row.cellStates[columnId] = state
        }
    }

    /// Applies a cross-check engine result to a pending row.
    /// Sets flagged/autoAccepted states for each participating columnId.
    ///
    /// - Parameters:
    ///   - flaggedColumnIds: columnIds whose cells should be marked .flagged.
    ///   - autoAcceptedColumnIds: columnIds whose cells should be marked .autoAccepted.
    ///   - failedRuleIds: ruleIds of rules that failed (for review sheet display).
    ///   - rowIndex: The zero-based row index to update.
    public func applyCrossCheckResult(
        flaggedColumnIds: Set<String>,
        autoAcceptedColumnIds: Set<String>,
        failedRuleIds: Set<String>,
        reason: String,
        forRowIndex rowIndex: Int
    ) {
        guard rowIndex < pendingRows.count else { return }
        let row = pendingRows[rowIndex]

        for columnId in autoAcceptedColumnIds {
            // Don't downgrade a pilot correction to autoAccepted.
            if row.cellStates[columnId] != .correctedByPilot {
                row.cellStates[columnId] = .autoAccepted
            }
        }
        for columnId in flaggedColumnIds {
            // Don't override a pilot correction with a flag.
            if row.cellStates[columnId] != .correctedByPilot {
                row.cellStates[columnId] = .flagged(reason: reason)
                row.crossCheckFlags.insert(columnId)
            }
        }
        row.failedRuleIds.formUnion(failedRuleIds)

        // blank_row_detection: if onFail is .skipRow, mark the row automatically.
        // The cross-check engine passes an empty flaggedColumnIds set in this case.
        if failedRuleIds.contains("blank_row_detection") {
            row.commitDecision = .blankRowSkipped
        }
    }

    /// Applies a pilot correction from the review table correction sheet.
    ///
    /// - Parameters:
    ///   - value: The corrected string entered by the pilot.
    ///   - columnId: The columnId of the corrected cell.
    ///   - flightField: The flightField key to update.
    ///   - rowIndex: The zero-based row index.
    public func applyPilotCorrection(
        value: String,
        columnId: String,
        flightField: String,
        forRowIndex rowIndex: Int
    ) {
        guard rowIndex < pendingRows.count else { return }
        pendingRows[rowIndex].applyCorrection(
            value: value,
            columnId: columnId,
            flightField: flightField
        )
        // Also update the strip's OCRCellResult so the correction is visible
        // if the pilot reopens the correction sheet.
        if let strip = stripByColumnId[columnId],
           var result = strip.cellResults[rowIndex] {
            result = OCRCellResult(
                rowIndex:             rowIndex,
                rawText:              result.rawText,
                confidence:           result.confidence,
                cellImage:            result.cellImage,
                wasManuallyCorrected: true,
                correctedText:        value
            )
            strip.cellResults[rowIndex] = result
        }
    }

    /// Marks a pending row as pilot-skipped.
    ///
    /// - Parameter rowIndex: The zero-based row index to skip.
    public func skipRow(at rowIndex: Int) {
        guard rowIndex < pendingRows.count else { return }
        pendingRows[rowIndex].markSkipped()
    }

    /// Records the duplicate detection outcome for a row.
    ///
    /// - Parameters:
    ///   - resolution: The pilot's duplicate resolution choice.
    ///   - rowIndex: The zero-based row index.
    public func setDuplicateResolution(
        _ resolution: DuplicateResolution,
        forRowIndex rowIndex: Int
    ) {
        guard rowIndex < pendingRows.count else { return }
        pendingRows[rowIndex].duplicateResolution = resolution
        // A .skip resolution means this row is excluded from the transaction.
        if resolution == .skip {
            pendingRows[rowIndex].commitDecision = .skip
        }
    }

    // MARK: Strip Accessors

    /// Returns the ColumnStrip for a given columnId, or nil if not found.
    public func strip(for columnId: String) -> ColumnStrip? {
        stripByColumnId[columnId]
    }

    /// Returns all strips belonging to a given capture phase, in captureOrder.
    public func strips(for phase: CapturePhase) -> [ColumnStrip] {
        strips.filter {
            capturePhase(for: $0.definition) == phase
        }
    }

    /// Returns the next strip that should be captured: the first strip in
    /// captureOrder whose state is .pending. nil when all strips are done.
    public var nextPendingStrip: ColumnStrip? {
        strips.first { $0.captureState == .pending }
    }

    // MARK: Phase Progress

    /// Returns progress summary for each of the 5 capture phases.
    /// Used by the phase-map UI to show lane completion status.
    public var phaseProgress: [PageScanPhaseProgress] {
        CapturePhase.allCases.map { phase in
            let phaseStrips = strips(for: phase)
            let completed   = phaseStrips.filter { $0.captureState == .complete  }.count
            let failed      = phaseStrips.filter {
                if case .failed = $0.captureState { return true }
                return false
            }.count
            let pending = phaseStrips.filter {
                $0.captureState == .pending ||
                $0.captureState == .capturing ||
                $0.captureState == .processing
            }.count
            return PageScanPhaseProgress(
                phase:            phase,
                totalStrips:      phaseStrips.count,
                completedStrips:  completed,
                failedStrips:     failed,
                pendingStrips:    pending
            )
        }
    }

    /// true when all Phase 1 and Phase 2 strips are in state .complete.
    /// The minimum requirement before the session may enter .reviewing.
    public var phase1And2Complete: Bool {
        [CapturePhase.phase1Anchor, .phase2CrossCheck].allSatisfy { phase in
            strips(for: phase).allSatisfy { $0.captureState == .complete }
        }
    }

    // MARK: Diagnostics

    /// Total number of flagged cells across all pending rows.
    /// Displayed in the review table header ("3 items need your attention").
    public var totalFlaggedCellCount: Int {
        pendingRows
            .filter { $0.commitDecision == .include }
            .reduce(0) { $0 + $1.cellStates.values.filter { $0.needsAttention }.count }
    }

    /// Summary description for debugging and logging. Not shown in UI.
    public var debugDescription: String {
        "ScanPage(profile:\(profile.name) rows:\(activeRowCount) " +
        "state:\(scanState) " +
        "strips:\(strips.filter { $0.captureState == .complete }.count)/\(strips.count) " +
        "flags:\(totalFlaggedCellCount))"
    }

    // MARK: Private Helpers

    /// Derives the CapturePhase for a ColumnDefinition using the captureOrder
    /// ranges defined in the Jeppesen profile.
    /// Ranges: Phase1 = 1–3, Phase2 = 4–9, Phase3 = 10–27, Phase4 = 28–34, Phase5 = 35.
    /// For non-Jeppesen profiles the phase boundaries may differ; the scanner UI
    /// uses profile.columns sorted by captureOrder and groups them by CapturePhase
    /// via the ColumnDefinition's groupLabel conventions. This helper is used only
    /// internally for phaseProgress computation.
    private func capturePhase(for column: ColumnDefinition) -> CapturePhase {
        // captureOrder phase boundaries are stored in the profile's column array.
        // For now, derive phase from captureOrder using Jeppesen conventions.
        // When a generic phase tag is added to ColumnDefinition this helper
        // is replaced by column.phase directly.
        switch column.captureOrder {
        case 1...3:   return .phase1Anchor
        case 4...9:   return .phase2CrossCheck
        case 10...27: return .phase3TimeColumns
        case 28...34: return .phase4TextAndCounts
        default:      return .phase5ImageOnly
        }
    }
}
