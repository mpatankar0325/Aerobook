// HTPairCombiner.swift
// AeroBook — Scanner group
//
// Build Order Item #9 — H+t Pair Combiner.
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Reads OCRCellResult values from sibling ColumnStrips (same pairId, one with
// pairRole .hours and one with pairRole .tenths), combines them into a single
// decimal value  H.t  (e.g. H=3, t=7 → "3.7"), validates each digit, then
// writes the combined value into ScanPage.pendingRows via updatePendingRow.
//
// This is the ONLY component that knows about the H+t encoding rule.
// Everything downstream (cross-check engine, review table, commit engine)
// works exclusively with the combined decimal string — it never sees raw H or t.
//
// ─────────────────────────────────────────────────────────────────────────────
// LOCKED RULES (Section 2 + Section 12, Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
//   • H+t pairs are atomic — an error on EITHER half flags the WHOLE pair.
//   • H is a single digit 0–9. H ≥ 10 is always an OCR error.
//   • t is a single digit 0–9. t ≥ 10 is always an OCR error.
//   • O→0 substitution was already applied by OCREngine before rawText was set.
//     The combiner treats rawText as clean (digits only), but applies a
//     second-pass O→0 guard in case the caller bypassed OCREngine.
//   • A blank H cell with a non-blank t cell (or vice versa) is a flagged
//     inconsistency — the pair is incomplete.
//   • Both blank on a non-required pair column → combined value = "0.0",
//     confidence = 1.0 (blank is the expected value for e.g. Multi Engine on
//     a student logbook — this is correct, not suspicious).
//   • Both blank on a required pair column → combined value = "",
//     confidence = 0.0 → flagged for mandatory review.
//
// ─────────────────────────────────────────────────────────────────────────────
// COMBINATION FORMULA
// ─────────────────────────────────────────────────────────────────────────────
//   combinedDecimalString = "\(H).\(t)"     e.g. "3.7"
//   combinedFloat         = Float(H) + Float(t) / 10.0
//
//   The string representation is what gets written into fieldValues (for the
//   commit engine and review table). The Float is provided as a convenience
//   for the cross-check engine (which compares numeric values).
//
// ─────────────────────────────────────────────────────────────────────────────
// COMPOSITE CONFIDENCE FOR PAIRS
// ─────────────────────────────────────────────────────────────────────────────
//   pairConfidence = min(hConfidence, tConfidence)
//
//   Using the minimum (not the average) means the weaker half drives the
//   pair's overall confidence. If either digit was uncertain, the whole pair
//   is uncertain. This is conservative and correct — a pilot cannot verify
//   one digit and trust the other without seeing both in context.
//
// ─────────────────────────────────────────────────────────────────────────────
// THREADING
// ─────────────────────────────────────────────────────────────────────────────
//   • The synchronous combineAll() is designed to run on a background queue
//     (called by CrossCheckEngine which runs off main).
//   • combineAllAsync() wraps it with DispatchQueue.global(qos:) and delivers
//     on the main thread.
//   • All ScanPage mutation (updatePendingRow) is @MainActor — callers must
//     dispatch to main before calling it. The async entry point handles this.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   • ColumnStrip, OCRCellResult, StripCaptureState   (ColumnStrip.swift)
//   • ColumnDefinition, PairRole, ColumnDataType       (DatabaseManager+LogbookProfile.swift)
//   • ScanPage, PendingFlightRow, CellReviewState      (ScanPage.swift + PendingFlightRow.swift)
//   • No Vision, no SQLite, no SwiftUI                 — pure data combination

import Foundation
import UIKit
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PairCombineResult
// ─────────────────────────────────────────────────────────────────────────────

/// The outcome of combining one H+t pair for one row.
///
/// Used by the cross-check engine to read combined numeric values without
/// re-parsing the string stored in PendingFlightRow.fieldValues.
public struct PairCombineResult {

    // MARK: Identity

    /// The pairId that produced this result (e.g. "total_duration").
    public let pairId: String

    /// The flightField both cells map to (e.g. "total_time").
    public let flightField: String

    /// Zero-based row index within the page (0 = topmost data row).
    public let rowIndex: Int

    // MARK: Combined Value

    /// The combined decimal string written into PendingFlightRow.fieldValues.
    /// Format: "H.t" (e.g. "3.7", "0.0", "9.5").
    /// Empty string "" when the pair is flagged and no value can be derived.
    public let combinedString: String

    /// Numeric representation of combinedString.
    /// nil when either digit is invalid or the pair is flagged with no value.
    public let combinedFloat: Float?

    // MARK: Component Values

    /// The H digit resolved from OCR. nil if H was invalid or absent.
    public let hoursDigit: Int?

    /// The t digit resolved from OCR. nil if t was invalid or absent.
    public let tenthsDigit: Int?

    // MARK: Confidence

    /// Composite pair confidence = min(hConfidence, tConfidence).
    /// 0.0 when either cell is missing, 1.0 for blank non-required pairs.
    public let pairConfidence: Float

    // MARK: Error State

    /// true when this pair has a validation error and the row should be flagged.
    public let isValid: Bool

    /// Human-readable reason displayed in the review table correction sheet.
    /// nil when isValid is true.
    public let flagReason: String?

    /// The columnId of the H strip (for cellStates keying).
    public let hoursColumnId: String

    /// The columnId of the t strip (for cellStates keying).
    public let tenthsColumnId: String
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PageCombineResult
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregated output for one full page (all pairs, all rows).
/// Handed to the cross-check engine as its primary input.
public struct PageCombineResult {

    /// All pair results for this page, ordered by pairId then rowIndex.
    public let pairResults: [PairCombineResult]

    /// Total pairs processed (pairCount × activeRowCount).
    public let totalPairsProcessed: Int

    /// Number of pairs that were flagged (isValid == false).
    public let flaggedPairCount: Int

    /// Wall-clock processing time in milliseconds.
    public let processingTimeMs: Double

    /// Convenience: all results for a specific pairId across all rows.
    public func results(forPairId pairId: String) -> [PairCombineResult] {
        pairResults.filter { $0.pairId == pairId }
    }

    /// Convenience: the result for a specific pairId and rowIndex, or nil.
    public func result(forPairId pairId: String, rowIndex: Int) -> PairCombineResult? {
        pairResults.first { $0.pairId == pairId && $0.rowIndex == rowIndex }
    }

    /// Convenience: the combined Float for a flightField + rowIndex, or nil.
    /// Used by the cross-check engine for numeric comparisons.
    public func combinedFloat(forFlightField flightField: String, rowIndex: Int) -> Float? {
        pairResults.first { $0.flightField == flightField && $0.rowIndex == rowIndex }?.combinedFloat
    }

    /// Convenience: all unique pairIds that appear in this result set.
    public var distinctPairIds: Set<String> {
        Set(pairResults.map(\.pairId))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HTPairCombiner
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless namespace. All entry points are static.
///
/// Primary call site (from CrossCheckEngine or ScanPage coordinator):
/// ```swift
/// HTPairCombiner.combineAllAsync(scanPage: scanPage) { pageResult in
///     // pageResult is on the main thread
///     // ScanPage.pendingRows already updated with combined values
///     CrossCheckEngine.run(on: scanPage, combineResult: pageResult)
/// }
/// ```
public enum HTPairCombiner {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Async Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// Combines all H+t pairs for a full page asynchronously.
    ///
    /// Processing runs on a background queue. ScanPage mutations
    /// (updatePendingRow) are dispatched to the main thread before delivery.
    ///
    /// - Parameters:
    ///   - scanPage:   The live ScanPage whose strips contain OCR results.
    ///   - completion: Called on the **main thread** with the page result.
    public static func combineAllAsync(
        scanPage:   ScanPage,
        completion: @escaping (PageCombineResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pageResult = combineAll(scanPage: scanPage)

            // Apply all updates on the main thread
            DispatchQueue.main.async {
                applyToScanPage(pageResult: pageResult, scanPage: scanPage)
                completion(pageResult)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Synchronous Combination (runs on background queue)
    // ─────────────────────────────────────────────────────────────────────────

    /// Synchronous — must be called from a background queue.
    /// Prefer `combineAllAsync` at all call sites; this is exposed for unit tests.
    ///
    /// Does NOT mutate ScanPage. Returns PageCombineResult only.
    /// Call `applyToScanPage` on the main thread to write results.
    public static func combineAll(scanPage: ScanPage) -> PageCombineResult {
        let wallStart = Date()

        // Build a map of pairId → [ColumnStrip] from the profile's columns.
        // We only process decimalHours columns (the others have pairRole .none).
        let pairGroups = pairStripGroups(from: scanPage)

        var allResults: [PairCombineResult] = []

        for (pairId, pairStrips) in pairGroups {
            guard let hStrip = pairStrips.first(where: { $0.definition.pairRole == .hours }),
                  let tStrip = pairStrips.first(where: { $0.definition.pairRole == .tenths }) else {
                // Malformed profile — pairId has only one strip. Skip and log.
                print("[AeroBook] HTPairCombiner: pairId \"\(pairId)\" is missing H or t strip — skipping.")
                continue
            }

            for rowIndex in 0..<scanPage.activeRowCount {
                let result = combinePair(
                    pairId:    pairId,
                    hStrip:    hStrip,
                    tStrip:    tStrip,
                    rowIndex:  rowIndex
                )
                allResults.append(result)
            }
        }

        // Sort for stable ordering: pairId alphabetically, then rowIndex
        allResults.sort {
            $0.pairId < $1.pairId || ($0.pairId == $1.pairId && $0.rowIndex < $1.rowIndex)
        }

        let elapsed   = Date().timeIntervalSince(wallStart) * 1000
        let flagCount = allResults.filter { !$0.isValid }.count

        return PageCombineResult(
            pairResults:          allResults,
            totalPairsProcessed:  allResults.count,
            flaggedPairCount:     flagCount,
            processingTimeMs:     elapsed
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Single-Pair Combination
    // ─────────────────────────────────────────────────────────────────────────

    /// Combines the H and t OCRCellResults for one row of one pair.
    ///
    /// Validation rules (all locked per Section 2 + 12):
    ///   1. Both cells must be captured (strip .complete or .skipped).
    ///   2. Both digits must be 0–9 after O→0 normalisation.
    ///   3. H ≥ 10 or t ≥ 10 is always an OCR error.
    ///   4. One blank + one non-blank = inconsistency → flagged.
    ///   5. Both blank on non-required → "0.0", confidence 1.0 (expected).
    ///   6. Both blank on required → "", confidence 0.0 → flagged.
    static func combinePair(
        pairId:   String,
        hStrip:   ColumnStrip,
        tStrip:   ColumnStrip,
        rowIndex: Int
    ) -> PairCombineResult {

        let hDef       = hStrip.definition
        let tDef       = tStrip.definition
        let flightField = hDef.flightField   // both halves share the same flightField
        let isRequired  = hDef.isRequired    // both halves share the same isRequired

        // ── Check strip availability ────────────────────────────────────────
        // A not-yet-captured strip means OCR hasn't run — treat as missing.
        let hCaptured = hStrip.captureState == .complete || hStrip.captureState == .skipped
        let tCaptured = tStrip.captureState == .complete || tStrip.captureState == .skipped

        if !hCaptured || !tCaptured {
            let missing = [!hCaptured ? "H" : nil, !tCaptured ? "t" : nil]
                .compactMap { $0 }.joined(separator: " and ")
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "\(missing) strip not yet captured for this pair."
            )
        }

        // ── Resolve raw text from OCR results ───────────────────────────────
        // resolvedText returns correctedText ?? rawText — picks up pilot corrections.
        // Falls back to defaultValue ("0") if no OCR result exists for this row.
        let hRaw = normalize(hStrip.resolvedText(forRow: rowIndex))
        let tRaw = normalize(tStrip.resolvedText(forRow: rowIndex))

        let hEmpty = hRaw.isEmpty
        let tEmpty = tRaw.isEmpty

        // ── Retrieve confidence scores ───────────────────────────────────────
        let hConf = hStrip.cellResults[rowIndex]?.confidence ?? 0.0
        let tConf = tStrip.cellResults[rowIndex]?.confidence ?? 0.0

        // ── Both blank ───────────────────────────────────────────────────────
        if hEmpty && tEmpty {
            if !isRequired {
                // Expected blank (e.g. Multi Engine on student logbook)
                return PairCombineResult(
                    pairId:         pairId,
                    flightField:    flightField,
                    rowIndex:       rowIndex,
                    combinedString: "0.0",
                    combinedFloat:  0.0,
                    hoursDigit:     0,
                    tenthsDigit:    0,
                    pairConfidence: 1.0,   // blank on non-required = fully confident
                    isValid:        true,
                    flagReason:     nil,
                    hoursColumnId:  hDef.columnId,
                    tenthsColumnId: tDef.columnId
                )
            } else {
                // Required pair is completely missing — flag
                return flaggedResult(
                    pairId:         pairId,
                    flightField:    flightField,
                    rowIndex:       rowIndex,
                    hoursColumnId:  hDef.columnId,
                    tenthsColumnId: tDef.columnId,
                    reason:         "Both H and t cells are blank for required field \"\(flightField)\"."
                )
            }
        }

        // ── One blank, one non-blank ─────────────────────────────────────────
        // H+t pairs are atomic — partial data is an error regardless of isRequired.
        if hEmpty != tEmpty {
            let presentSide  = hEmpty ? "t=\(tRaw)" : "H=\(hRaw)"
            let absentSide   = hEmpty ? "H" : "t"
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "Incomplete pair: \(presentSide) present but \(absentSide) is blank."
            )
        }

        // ── Parse both digits ────────────────────────────────────────────────
        guard let hDigit = parseDigit(hRaw) else {
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "H cell \"\(hRaw)\" is not a single digit 0-9.",
                hoursDigit:     nil,
                tenthsDigit:    parseDigit(tRaw),
                hConf:          hConf,
                tConf:          tConf
            )
        }

        guard let tDigit = parseDigit(tRaw) else {
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "t cell \"\(tRaw)\" is not a single digit 0-9.",
                hoursDigit:     hDigit,
                tenthsDigit:    nil,
                hConf:          hConf,
                tConf:          tConf
            )
        }

        // ── Range check: H ≥ 10 or t ≥ 10 is always an OCR error ────────────
        // (Per spec Section 2 — these are single-digit cells 0–9.)
        if hDigit > 9 {
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "H value \(hDigit) is out of range (must be 0–9). OCR error — retap to correct.",
                hoursDigit:     hDigit,
                tenthsDigit:    tDigit,
                hConf:          hConf,
                tConf:          tConf
            )
        }
        if tDigit > 9 {
            return flaggedResult(
                pairId:         pairId,
                flightField:    flightField,
                rowIndex:       rowIndex,
                hoursColumnId:  hDef.columnId,
                tenthsColumnId: tDef.columnId,
                reason:         "t value \(tDigit) is out of range (must be 0–9). OCR error — retap to correct.",
                hoursDigit:     hDigit,
                tenthsDigit:    tDigit,
                hConf:          hConf,
                tConf:          tConf
            )
        }

        // ── Valid pair ───────────────────────────────────────────────────────
        let combined = Float(hDigit) + Float(tDigit) / 10.0

        // Pair confidence = min of the two halves (conservative — see file header).
        let pairConf = min(hConf, tConf)

        return PairCombineResult(
            pairId:         pairId,
            flightField:    flightField,
            rowIndex:       rowIndex,
            combinedString: "\(hDigit).\(tDigit)",
            combinedFloat:  combined,
            hoursDigit:     hDigit,
            tenthsDigit:    tDigit,
            pairConfidence: pairConf,
            isValid:        true,
            flagReason:     nil,
            hoursColumnId:  hDef.columnId,
            tenthsColumnId: tDef.columnId
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: ScanPage Mutation (must run on main thread)
    // ─────────────────────────────────────────────────────────────────────────

    /// Writes all PairCombineResults into ScanPage.pendingRows via
    /// updatePendingRow and applyCrossCheckResult.
    ///
    /// Called on the **main thread** from combineAllAsync after combination completes.
    /// Can also be called directly from a cross-check engine step that runs on main.
    ///
    /// For each pair result:
    ///   • Updates fieldValues[flightField] with the combinedString.
    ///   • Sets cellStates for both H and t columnIds.
    ///   • For invalid pairs: marks both cells as .flagged with the reason.
    ///   • For valid pairs with low confidence: marks both as .pendingReview.
    ///   • For valid pairs with high confidence: marks both as .pendingReview
    ///     (autoAccepted upgrade happens in the cross-check engine, not here).
    ///
    /// - Parameters:
    ///   - pageResult: The PageCombineResult produced by combineAll().
    ///   - scanPage:   The live ScanPage to mutate.
    @MainActor
    public static func applyToScanPage(
        pageResult: PageCombineResult,
        scanPage:   ScanPage
    ) {
        let flagThreshold: Float = 0.50

        for result in pageResult.pairResults {

            // Field value — always written, even for invalid pairs so the
            // review table shows the best-effort string rather than blank.
            let displayValue = result.combinedString.isEmpty
                ? (result.isValid ? "0.0" : "")
                : result.combinedString

            var newFieldValues: [String: String] = [
                result.flightField: displayValue
            ]

            // Cell state for both H and t columns
            var newCellStates: [String: CellReviewState] = [:]

            if result.isValid {
                let reason = result.flagReason  // nil for valid results
                _ = reason   // suppress unused warning

                if result.pairConfidence < flagThreshold {
                    // Low combined confidence — pilot should verify
                    let lowConfReason = "Low OCR confidence (\(String(format: "%.0f%%", result.pairConfidence * 100))). Tap to verify."
                    newCellStates[result.hoursColumnId]  = .flagged(reason: lowConfReason)
                    newCellStates[result.tenthsColumnId] = .flagged(reason: lowConfReason)
                } else {
                    // Acceptable confidence — pending review (cross-check engine
                    // will upgrade to .autoAccepted if a high-confidence rule passes)
                    newCellStates[result.hoursColumnId]  = .pendingReview
                    newCellStates[result.tenthsColumnId] = .pendingReview
                }
            } else {
                // Invalid pair — flag both halves with the same reason
                let reason = result.flagReason ?? "H+t pair validation failed."
                newCellStates[result.hoursColumnId]  = .flagged(reason: reason)
                newCellStates[result.tenthsColumnId] = .flagged(reason: reason)
            }

            scanPage.updatePendingRow(
                fieldValues: newFieldValues,
                cellStates:  newCellStates,
                forRowIndex: result.rowIndex
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Single Pair Re-combine (for live correction in review table)
    // ─────────────────────────────────────────────────────────────────────────

    /// Re-combines a single H+t pair after the pilot has corrected one or both
    /// halves in the review table correction sheet.
    ///
    /// Called from the review table when a pilot taps "Done" after editing a cell.
    /// Runs synchronously on the main thread (correction sheet interactions are
    /// always on main, and the combination is O(1) per pair).
    ///
    /// - Parameters:
    ///   - pairId:   The pairId of the pair to re-combine.
    ///   - scanPage: The live ScanPage (strips and pendingRows).
    /// - Returns: The updated PairCombineResult, or nil if the pairId is not found.
    @discardableResult
    @MainActor
    public static func recombinePair(
        pairId:   String,
        rowIndex: Int,
        scanPage: ScanPage
    ) -> PairCombineResult? {

        // Find the two strips for this pairId
        let pairStrips = scanPage.profile.columns
            .filter { $0.pairId == pairId && $0.dataType == .decimalHours }
            .compactMap { scanPage.strip(for: $0.columnId) }

        guard let hStrip = pairStrips.first(where: { $0.definition.pairRole == .hours }),
              let tStrip = pairStrips.first(where: { $0.definition.pairRole == .tenths }) else {
            return nil
        }

        let result = combinePair(pairId: pairId, hStrip: hStrip, tStrip: tStrip, rowIndex: rowIndex)

        // Apply this single result to the ScanPage
        applyToScanPage(
            pageResult: PageCombineResult(
                pairResults:         [result],
                totalPairsProcessed: 1,
                flaggedPairCount:    result.isValid ? 0 : 1,
                processingTimeMs:    0
            ),
            scanPage: scanPage
        )

        return result
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Private Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Groups ColumnStrips by their pairId, returning only decimalHours pairs.
    /// Keys that have fewer than 2 strips are skipped (malformed profile).
    private static func pairStripGroups(from scanPage: ScanPage) -> [String: [ColumnStrip]] {
        var groups: [String: [ColumnStrip]] = [:]

        for column in scanPage.profile.columns
            where column.dataType == .decimalHours {
            guard let pid = column.pairId else { continue }
            if let strip = scanPage.strip(for: column.columnId) {
                groups[pid, default: []].append(strip)
            }
        }

        // Remove any group that doesn't have exactly H + t (malformed profile guard)
        return groups.filter { _, strips in
            strips.contains { $0.definition.pairRole == .hours } &&
            strips.contains { $0.definition.pairRole == .tenths }
        }
    }

    /// Trims whitespace and applies a second-pass O→0 normalisation.
    /// OCREngine already applies O→0, but this guard handles cases where
    /// a pilot correction or a manual test bypassed OCREngine.
    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
    }

    /// Parses a normalised string as a single integer.
    /// Returns nil if the string is not a valid non-negative integer string,
    /// or if the integer > 99 (obviously not a single digit — OCR artefact).
    private static func parseDigit(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        // Only digits allowed — any alpha character means OCR confusion
        guard text.allSatisfy({ $0.isNumber }) else { return nil }
        guard let value = Int(text), value >= 0, value <= 99 else { return nil }
        return value
    }

    /// Convenience builder for a flagged PairCombineResult.
    private static func flaggedResult(
        pairId:         String,
        flightField:    String,
        rowIndex:       Int,
        hoursColumnId:  String,
        tenthsColumnId: String,
        reason:         String,
        hoursDigit:     Int?  = nil,
        tenthsDigit:    Int?  = nil,
        hConf:          Float = 0.0,
        tConf:          Float = 0.0
    ) -> PairCombineResult {
        PairCombineResult(
            pairId:         pairId,
            flightField:    flightField,
            rowIndex:       rowIndex,
            combinedString: "",
            combinedFloat:  nil,
            hoursDigit:     hoursDigit,
            tenthsDigit:    tenthsDigit,
            pairConfidence: min(hConf, tConf),
            isValid:        false,
            flagReason:     reason,
            hoursColumnId:  hoursColumnId,
            tenthsColumnId: tenthsColumnId
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PairCombineResult Diagnostics
// ─────────────────────────────────────────────────────────────────────────────

public extension PairCombineResult {

    /// Human-readable one-liner for debug logs.
    var debugDescription: String {
        if isValid {
            return "[HTPair] \(pairId) row\(rowIndex) → \(combinedString) " +
                   "(H=\(hoursDigit ?? -1), t=\(tenthsDigit ?? -1), conf=\(String(format: "%.2f", pairConfidence)))"
        } else {
            return "[HTPair] \(pairId) row\(rowIndex) → FLAGGED: \(flagReason ?? "unknown")"
        }
    }

    /// true when both digits are known and within spec.
    var hasValidDigits: Bool {
        guard let h = hoursDigit, let t = tenthsDigit else { return false }
        return h <= 9 && t <= 9
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PageCombineResult Diagnostics
// ─────────────────────────────────────────────────────────────────────────────

public extension PageCombineResult {

    /// Human-readable summary for debug logs.
    var debugDescription: String {
        "[HTPairCombiner] \(totalPairsProcessed) pairs processed, " +
        "\(flaggedPairCount) flagged | " +
        String(format: "%.1f ms", processingTimeMs)
    }

    /// All flagged results — for cross-check engine pre-filter.
    var flaggedResults: [PairCombineResult] {
        pairResults.filter { !$0.isValid }
    }

    /// All valid results.
    var validResults: [PairCombineResult] {
        pairResults.filter { $0.isValid }
    }

    /// All unique flightFields present in valid results.
    var capturedFlightFields: Set<String> {
        Set(validResults.map(\.flightField))
    }

    /// The totalTime values for each row (for blank_row_detection rule).
    /// Returns a Float per rowIndex for rows where totalTime is captured.
    func totalTimes(flightField: String = "total_time") -> [Int: Float] {
        var map: [Int: Float] = [:]
        for r in pairResults where r.flightField == flightField {
            map[r.rowIndex] = r.combinedFloat ?? 0.0
        }
        return map
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanPage Convenience Extension
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience extension on ScanPage that wraps HTPairCombiner.combineAllAsync
/// and applies results in one call.
///
/// Typical usage in the scanner coordinator after all desired phases are captured:
/// ```swift
/// scanPage.combineHTpairs { pageResult in
///     // pendingRows already updated
///     // Now run cross-check engine:
///     CrossCheckEngine.run(on: scanPage, combineResult: pageResult)
/// }
/// ```
public extension ScanPage {

    /// Combines all H+t pairs and writes results into pendingRows.
    /// Calls completion on the main thread with the full PageCombineResult.
    func combineHTpairs(
        completion: @escaping (PageCombineResult) -> Void
    ) {
        HTPairCombiner.combineAllAsync(scanPage: self, completion: completion)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pilot Correction Integration
// ─────────────────────────────────────────────────────────────────────────────

/// Extension bridging the review table correction sheet to the pair combiner.
///
/// When a pilot corrects an H or t cell in the review table, the correction
/// sheet calls applyPilotCorrection on ScanPage (which updates the strip's
/// OCRCellResult.correctedText). The review table must then trigger a
/// re-combine so the paired value in fieldValues stays in sync.
///
/// The review table calls:
/// ```swift
/// scanPage.applyPilotCorrection(
///     value: correctedValue,
///     columnId: columnId,
///     flightField: flightField,
///     rowIndex: rowIndex
/// )
/// // Then immediately:
/// if let pairId = definition.pairId {
///     HTPairCombiner.recombinePair(pairId: pairId, rowIndex: rowIndex, scanPage: scanPage)
/// }
/// ```
/// This extension adds nothing new — it is documentation only, providing
/// the exact call sequence for the review table (Build Item #11) author.
public extension HTPairCombiner {

    // Documentation only — see comment block above.
    // The actual method is recombinePair(pairId:rowIndex:scanPage:) defined above.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Debug Overlay (SwiftUI, #if DEBUG)
// ─────────────────────────────────────────────────────────────────────────────
//
// Renders a compact table of all pair combination results for a page.
// Intended for use in development and TestFlight diagnostic sessions.
// Excluded from production builds.

#if DEBUG
import SwiftUI

/// A compact debug overlay showing all H+t pair combination results for one page.
/// Displayed as a scrollable list — one row per pairId per row index.
///
/// Usage:
///   HTPairDebugView(pageResult: combineResult)
public struct HTPairDebugView: View {

    public let pageResult: PageCombineResult

    public init(pageResult: PageCombineResult) {
        self.pageResult = pageResult
    }

    public var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Label("Pairs processed", systemImage: "number")
                        Spacer()
                        Text("\(pageResult.totalPairsProcessed)")
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Flagged", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Text("\(pageResult.flaggedPairCount)")
                            .foregroundStyle(pageResult.flaggedPairCount > 0 ? Color.orange : Color.green)
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Time", systemImage: "clock")
                        Spacer()
                        Text(String(format: "%.1f ms", pageResult.processingTimeMs))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Summary")
                }

                // Group by pairId
                let pairIds = Array(pageResult.distinctPairIds).sorted()
                ForEach(pairIds, id: \.self) { pairId in
                    let results = pageResult.results(forPairId: pairId)
                    Section {
                        ForEach(results, id: \.rowIndex) { r in
                            HStack(spacing: 12) {
                                // Row index badge
                                Text("R\(r.rowIndex + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(r.isValid ? Color.teal : Color.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                // Combined value
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.combinedString.isEmpty ? "—" : r.combinedString)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(r.isValid ? .primary : Color.orange)

                                    if let reason = r.flagReason {
                                        Text(reason)
                                            .font(.caption2)
                                            .foregroundStyle(Color.orange)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                // Confidence badge
                                Text(String(format: "%.0f%%", r.pairConfidence * 100))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(confidenceColor(r.pairConfidence))
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(pairId.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }
            }
            .navigationTitle("H+t Pair Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func confidenceColor(_ conf: Float) -> Color {
        if conf >= 0.85 { return .green }
        if conf >= 0.50 { return .orange }
        return .red
    }
}

#Preview("H+t Pair Debug") {
    HTPairDebugView(pageResult: PageCombineResult(
        pairResults: [
            PairCombineResult(
                pairId: "total_duration", flightField: "total_time", rowIndex: 0,
                combinedString: "1.5", combinedFloat: 1.5,
                hoursDigit: 1, tenthsDigit: 5, pairConfidence: 0.93,
                isValid: true, flagReason: nil,
                hoursColumnId: "total_duration_hours",
                tenthsColumnId: "total_duration_tenths"
            ),
            PairCombineResult(
                pairId: "total_duration", flightField: "total_time", rowIndex: 1,
                combinedString: "", combinedFloat: nil,
                hoursDigit: nil, tenthsDigit: 8, pairConfidence: 0.40,
                isValid: false, flagReason: "H cell \"O\" is not a single digit 0–9.",
                hoursColumnId: "total_duration_hours",
                tenthsColumnId: "total_duration_tenths"
            ),
            PairCombineResult(
                pairId: "pic", flightField: "pic", rowIndex: 0,
                combinedString: "1.5", combinedFloat: 1.5,
                hoursDigit: 1, tenthsDigit: 5, pairConfidence: 0.89,
                isValid: true, flagReason: nil,
                hoursColumnId: "pic_hours",
                tenthsColumnId: "pic_tenths"
            ),
        ],
        totalPairsProcessed: 3,
        flaggedPairCount: 1,
        processingTimeMs: 0.8
    ))
}
#endif
