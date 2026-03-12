// ColumnStrip.swift
// AeroBook — Scanner group
//
// Represents one captured vertical strip of the logbook page.
// Each ColumnStrip corresponds to exactly one ColumnDefinition from the
// active LogbookProfile. When the camera captures the strip, the raw
// UIImage is stored here alongside per-row OCR results once the quality
// gate and OCR engine have run.
//
// Lifecycle:
//   1. ScanPage allocates one ColumnStrip per profile column at init.
//   2. The camera + ROI overlay writes rawImage when capture fires.
//   3. The image quality gate writes qualityResult (pass/fail + reasons).
//   4. The OCR engine writes cellResults[0…dataRowCount-1].
//   5. The H+t pair combiner reads sibling strips via pairId to produce
//      combined decimal values that are written into PendingFlightRow.
//
// Nothing in this file touches the database.

import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OCRCellResult
// ─────────────────────────────────────────────────────────────────────────────

/// The raw result of running the OCR engine on a single cell within a strip.
/// One instance per data row per column — stored in ColumnStrip.cellResults.
///
/// The OCR engine produces a raw string and a Vision confidence score.
/// Post-processing (O→0 substitution, range clamping, pair combining) happens
/// downstream; this struct stores only what OCR returned before any correction.
public struct OCRCellResult {

    /// Zero-based index into the page's data rows (0 = top data row, dataRowCount-1 = last).
    public let rowIndex: Int

    /// Raw string returned by the Vision framework. Never nil — blank cells
    /// produce an empty string "". Leading/trailing whitespace is trimmed.
    public let rawText: String

    /// Vision recognition confidence in [0.0, 1.0].
    /// 1.0 = highest confidence. Used by the cross-check engine to weight
    /// auto-accept decisions. A score below 0.5 on a required field triggers
    /// a forced review flag regardless of cross-check rule outcome.
    public let confidence: Float

    /// Cropped UIImage of just this cell, extracted from the strip by the
    /// row-line detector. Stored so the review table correction sheet can
    /// show the pilot their original handwriting alongside the OCR result.
    /// nil only before the row-line detector has run.
    public let cellImage: UIImage?

    /// true once the pilot has manually corrected this cell's value in the
    /// review UI. Corrected cells are never auto-overwritten by re-runs.
    public var wasManuallyCorrected: Bool

    /// The value the pilot typed when correcting (replaces rawText downstream).
    /// nil if the pilot has not corrected this cell.
    public var correctedText: String?

    /// The resolved value used by all downstream logic: correctedText if set,
    /// otherwise rawText. Blank-cell defaultValue substitution happens in
    /// PendingFlightRow, not here.
    public var resolvedText: String {
        correctedText ?? rawText
    }

    public init(
        rowIndex: Int,
        rawText: String,
        confidence: Float,
        cellImage: UIImage? = nil,
        wasManuallyCorrected: Bool = false,
        correctedText: String? = nil
    ) {
        self.rowIndex             = rowIndex
        self.rawText              = rawText
        self.confidence           = confidence
        self.cellImage            = cellImage
        self.wasManuallyCorrected = wasManuallyCorrected
        self.correctedText        = correctedText
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - StripQualityResult
// ─────────────────────────────────────────────────────────────────────────────

/// Result of running the image quality gate on a captured strip image.
/// Produced by the ImageQualityGate (Build Item #4) before OCR is attempted.
/// Stored on ColumnStrip so the review UI can surface per-strip quality warnings.
public struct StripQualityResult {

    /// Overall pass/fail gate decision. false → OCR must not run; pilot must retake.
    public let isAcceptable: Bool

    /// Laplacian variance blur score in [0.0, 1.0]. Below 0.35 = too blurry.
    public let blurScore: Float

    /// Mean pixel intensity in [0.0, 1.0]. Below 0.15 = underexposed; above 0.92 = washed out.
    public let contrastScore: Float

    /// Number of horizontal row lines detected in the strip. Should equal
    /// profile.dataRowCount + profile.totalsRowCount + 1 (header separator).
    public let detectedRowLineCount: Int

    /// Human-readable failure reasons shown to the pilot on retake prompt.
    /// Empty array when isAcceptable is true.
    public let failureReasons: [String]

    /// Convenience: strip passed all quality checks with no warnings.
    public var isClean: Bool { isAcceptable && failureReasons.isEmpty }

    public init(
        isAcceptable: Bool,
        blurScore: Float,
        contrastScore: Float,
        detectedRowLineCount: Int,
        failureReasons: [String] = []
    ) {
        self.isAcceptable         = isAcceptable
        self.blurScore            = blurScore
        self.contrastScore        = contrastScore
        self.detectedRowLineCount = detectedRowLineCount
        self.failureReasons       = failureReasons
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - StripCaptureState
// ─────────────────────────────────────────────────────────────────────────────

/// The capture lifecycle state of a single ColumnStrip within a ScanPage.
/// Drives the scanner UI: which strip is highlighted in the phase map,
/// what buttons are visible, and what the progress indicator shows.
public enum StripCaptureState: Equatable {

    /// No capture attempted yet. Default state at ScanPage creation.
    case pending

    /// The ROI camera overlay is currently live for this strip.
    case capturing

    /// Image captured; quality gate and OCR are running on a background thread.
    case processing

    /// OCR complete. cellResults populated. May contain flagged cells.
    case complete

    /// Quality gate failed or OCR error. rawImage is nil or discarded.
    /// Pilot must retake. failureReasons explains why.
    case failed(reasons: [String])

    /// Pilot explicitly skipped this strip (only allowed for non-required columns).
    case skipped
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ColumnStrip
// ─────────────────────────────────────────────────────────────────────────────

/// One vertical strip of a logbook page, corresponding to exactly one
/// ColumnDefinition in the active LogbookProfile.
///
/// The strip is the atomic unit of scanner capture. The camera ROI overlay
/// shows one strip at a time; the pilot aligns the physical column under the
/// cutout and taps Capture. This struct holds everything about that capture
/// from raw pixels through to OCR results.
///
/// Reference equality is intentional — ScanPage holds ColumnStrip instances
/// by reference so OCR results can be mutated in-place without copying the
/// full ScanPage. Use a class, not a struct.
public final class ColumnStrip {

    // MARK: Identity

    /// The ColumnDefinition this strip captures.
    /// Provides columnId, groupLabel, dataType, captureOrder, pairId, etc.
    public let definition: ColumnDefinition

    // MARK: Capture State

    /// Current lifecycle state. Mutated by the camera + OCR pipeline.
    public var captureState: StripCaptureState = .pending

    // MARK: Raw Image

    /// The full strip UIImage as captured by the ROI camera overlay.
    /// Set when captureState transitions to .processing.
    /// Retained in memory for the lifetime of the ScanPage so the review
    /// table correction sheet can display cell crops alongside OCR results.
    /// Discarded when the ScanPage is deallocated (nothing written to disk).
    public var rawImage: UIImage?

    // MARK: Quality Gate

    /// Result written by ImageQualityGate after rawImage is set.
    /// nil until the quality gate has run.
    public var qualityResult: StripQualityResult?

    /// Convenience: quality gate has run and the strip passed.
    public var passedQualityGate: Bool {
        qualityResult?.isAcceptable == true
    }

    // MARK: OCR Results

    /// Per-row OCR results, keyed by rowIndex (0-based).
    /// Populated by the OCR engine after the quality gate passes.
    /// Count equals ScanPage.activeRowCount when fully populated.
    ///
    /// Stored as a dictionary (not array) so partial population is natural —
    /// if OCR fails on row 3 but succeeds on rows 0-2 and 4-12, missing
    /// entries are detected and flagged individually rather than crashing.
    public var cellResults: [Int: OCRCellResult] = [:]

    /// true when cellResults contains an entry for every row index
    /// in 0..<ScanPage.activeRowCount.
    public var isFullyOCRd: Bool {
        guard case .complete = captureState else { return false }
        return !cellResults.isEmpty
    }

    // MARK: Init

    public init(definition: ColumnDefinition) {
        self.definition = definition
    }

    // MARK: Convenience Accessors

    /// Returns the OCRCellResult for a given row, or nil if not yet captured.
    public func result(forRow rowIndex: Int) -> OCRCellResult? {
        cellResults[rowIndex]
    }

    /// Returns the resolved text for a given row.
    /// Falls back to the column's defaultValue if no result exists yet.
    public func resolvedText(forRow rowIndex: Int) -> String {
        cellResults[rowIndex]?.resolvedText ?? definition.defaultValue
    }

    /// true if any cell in this strip has been manually corrected by the pilot.
    public var hasManualCorrections: Bool {
        cellResults.values.contains { $0.wasManuallyCorrected }
    }

    /// All rows in this strip that are currently flagged (confidence < 0.5
    /// or marked as needing correction). Used by the review table to tally
    /// amber cells.
    public var flaggedRowIndices: [Int] {
        cellResults.compactMap { (rowIndex, result) in
            result.confidence < 0.5 && !result.wasManuallyCorrected ? rowIndex : nil
        }.sorted()
    }
}
