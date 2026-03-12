// CrossCheckEngine.swift
// AeroBook — Scanner group
//
// Build Order Item #10 — Cross-check Engine.
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Evaluates every CrossCheckRule in a LogbookProfile against all rows of a
// ScanPage after the H+t pair combiner has resolved decimal values. Produces
// one RuleEvalResult per rule per row, then applies CellReviewState changes
// (autoAccepted / flagged) to ScanPage.pendingRows via the ScanPage API.
//
// This is the ONLY component that reads CrossCheckRule.operator and decides
// pass/fail logic. The rules themselves are data — the engine is generic.
// Adding a new logbook type or a new validation rule requires only a new
// CrossCheckRule in the profile. No code changes needed.
//
// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR SEMANTICS (Section 3 + 4, Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
//
//   .allEqual
//     All resolved numeric values across the rule's fields must be equal.
//     Special handling for "date" fields: checked for non-blank presence only.
//     For blank_row_detection: combined total_duration == 0.0 → row is blank.
//
//   .lte  (less-than-or-equal)
//     The LAST field group (the "ceiling") must be ≥ all preceding field groups.
//     For multi-component rules (total_gte_components), each preceding group is
//     independently compared to the ceiling. A violation on any one component
//     flags only that component, not all fields.
//
//   .gtZeroRequires
//     field[0] group (the "trigger") value > 0 implies at least one field[1+]
//     group must also be > 0. If the trigger ≤ 0, rule always passes.
//     For sim_exclusive the semantics invert: trigger > 0 requires ALL others = 0.
//     The engine detects sim_exclusive by ruleId and applies inverted logic.
//
//   .sumEquals — reserved for future rules; engine skeleton present.
//
// ─────────────────────────────────────────────────────────────────────────────
// APPLICABILITY SEMANTICS
// ─────────────────────────────────────────────────────────────────────────────
//   .always          — rule evaluates for every row.
//   .ifBlank(colId)  — SKIP the rule if the named columnId's resolved value
//                      is blank ("") or zero ("0" / "0.0"). This means the
//                      column whose columnId is given is NOT present/non-zero,
//                      and the rule is not relevant for this row.
//                      Example: approach_requires_instrument uses
//                      .ifBlank("approaches_count") which skips the rule when
//                      no approaches were flown — the rule only fires when
//                      approaches_count > 0.
//
// ─────────────────────────────────────────────────────────────────────────────
// VALUE RESOLUTION PATH
// ─────────────────────────────────────────────────────────────────────────────
//   CrossCheckRule.fields contains columnId strings (e.g. "total_duration_hours").
//   The engine resolves each columnId through this chain:
//
//     columnId → ColumnDefinition → pairId (if decimalHours) → flightField
//         → PendingFlightRow.fieldValues[flightField] → parse Float
//
//   For H+t pairs: the combined decimal string "3.7" → Float 3.7 is available
//   in both PendingFlightRow.fieldValues AND PageCombineResult.combinedFloat.
//   The engine reads from PendingFlightRow.fieldValues for consistency (pilot
//   corrections update fieldValues but not PageCombineResult).
//
//   For integer columns: fieldValues["approaches_count"] = "3" → Float 3.0.
//   For text columns (date): presence check only (non-blank = passes).
//
// ─────────────────────────────────────────────────────────────────────────────
// PASS/FAIL → CELLREVIEWSTATE MAPPING
// ─────────────────────────────────────────────────────────────────────────────
//   Rule passes, confidence .high   → all participating columnIds → .autoAccepted
//   Rule passes, confidence .medium  → no state change (leave as .pendingReview)
//   Rule passes, confidence .low     → no state change
//
//   Rule fails, onFail .flagFields  → violating columnIds only → .flagged(reason)
//   Rule fails, onFail .flagRow     → ALL columnIds in rule → .flagged(reason)
//   Rule fails, onFail .block       → ALL columnIds → .flagged(reason) [blocks commit]
//   Rule fails, onFail .skipRow     → commitDecision = .blankRowSkipped (blank_row_detection)
//
// ─────────────────────────────────────────────────────────────────────────────
// RE-EVALUATION ON PILOT CORRECTION
// ─────────────────────────────────────────────────────────────────────────────
//   After a pilot corrects a cell in the review table, the review table calls
//   CrossCheckEngine.runRow(rowIndex:scanPage:combineResult:) to re-evaluate
//   only the rules that involve the corrected columnId. This is O(rules) not
//   O(rows × rules) and keeps the correction sheet snappy.
//
// ─────────────────────────────────────────────────────────────────────────────
// THREADING
// ─────────────────────────────────────────────────────────────────────────────
//   runAsync()   — background queue (.userInitiated), delivers on main thread.
//   run()        — synchronous, caller must be off main.
//   runRow()     — @MainActor synchronous, for use in review table corrections.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   CrossCheckRule, CrossCheckOperator, CrossCheckConfidence,
//   CrossCheckOnFail, CrossCheckApplicability, ColumnDefinition, LogbookProfile
//                                          (DatabaseManager+LogbookProfile.swift)
//   ScanPage, PendingFlightRow, CellReviewState
//                                          (ScanPage.swift + PendingFlightRow.swift)
//   PageCombineResult, PairCombineResult   (HTPairCombiner.swift)
//   No Vision, no SQLite, no SwiftUI       — pure evaluation logic + #if DEBUG view

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RuleEvalResult
// ─────────────────────────────────────────────────────────────────────────────

/// The result of evaluating one CrossCheckRule against one flight row.
public struct RuleEvalResult {

    // MARK: Identity

    /// The rule that was evaluated.
    public let rule: CrossCheckRule

    /// Zero-based page row index this result applies to.
    public let rowIndex: Int

    // MARK: Outcome

    /// Whether the rule passed for this row.
    public let passed: Bool

    /// Whether the rule was skipped due to applicability (.ifBlank condition met).
    public let skipped: Bool

    /// Human-readable explanation of the failure, shown in the correction sheet.
    /// nil when passed == true or skipped == true.
    public let failReason: String?

    // MARK: Affected ColumnIds

    /// columnIds to mark .autoAccepted when passed and confidence == .high.
    /// Empty when passed == false or confidence != .high.
    public let autoAcceptedColumnIds: Set<String>

    /// columnIds to mark .flagged when passed == false.
    /// Derived from onFail semantics: .flagFields = specific violators only,
    /// .flagRow = all rule fields, .block = all rule fields.
    /// Empty when passed == true.
    public let flaggedColumnIds: Set<String>

    // MARK: Convenience

    /// true when this result should cause any ScanPage mutation.
    public var requiresStateUpdate: Bool {
        !skipped && (!autoAcceptedColumnIds.isEmpty || !flaggedColumnIds.isEmpty)
    }

    /// Human-readable one-liner for debug logs.
    public var debugDescription: String {
        if skipped {
            return "[CrossCheck] \(rule.ruleId) row\(rowIndex) → SKIPPED (applicability)"
        }
        let outcome = passed ? "PASS" : "FAIL"
        let columns = passed
            ? (autoAcceptedColumnIds.isEmpty ? "—" : autoAcceptedColumnIds.sorted().joined(separator: ", "))
            : flaggedColumnIds.sorted().joined(separator: ", ")
        return "[CrossCheck] \(rule.ruleId) row\(rowIndex) → \(outcome) | \(columns)"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PageEvalResult
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregated evaluation output for a full page (all rules × all rows).
/// Passed to the review table as its data source.
public struct PageEvalResult {

    /// All individual rule results, ordered by rowIndex then rule captureOrder.
    public let ruleResults: [RuleEvalResult]

    /// Number of rows where at least one rule failed.
    public let rowsWithFailures: Int

    /// Number of rows auto-accepted in full (zero failures, at least one high pass).
    public let rowsAutoAccepted: Int

    /// Number of rows treated as blank and skipped.
    public let blankRowsSkipped: Int

    /// Wall-clock processing time in milliseconds.
    public let processingTimeMs: Double

    // MARK: Convenience Queries

    /// All results for a specific row index.
    public func results(forRowIndex rowIndex: Int) -> [RuleEvalResult] {
        ruleResults.filter { $0.rowIndex == rowIndex }
    }

    /// All results for a specific ruleId across all rows.
    public func results(forRuleId ruleId: String) -> [RuleEvalResult] {
        ruleResults.filter { $0.rule.ruleId == ruleId }
    }

    /// All failed results (not skipped).
    public var failedResults: [RuleEvalResult] {
        ruleResults.filter { !$0.passed && !$0.skipped }
    }

    /// All passed + not skipped results with .high confidence (produced auto-accepts).
    public var highConfidencePasses: [RuleEvalResult] {
        ruleResults.filter { $0.passed && !$0.skipped && $0.rule.confidence == .high }
    }

    /// Summary description for debug logs.
    public var debugDescription: String {
        "[CrossCheckEngine] \(ruleResults.count) evaluations | " +
        "\(rowsWithFailures) rows with failures | " +
        "\(rowsAutoAccepted) rows auto-accepted | " +
        "\(blankRowsSkipped) blank rows skipped | " +
        String(format: "%.1f ms", processingTimeMs)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CrossCheckEngine
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless namespace. All entry points are static.
///
/// Primary async call site (after HTPairCombiner completes):
/// ```swift
/// scanPage.combineHTpairs { pageResult in
///     CrossCheckEngine.runAsync(scanPage: scanPage, combineResult: pageResult) { evalResult in
///         // evalResult is on the main thread
///         // ScanPage.pendingRows already updated with autoAccepted / flagged states
///         scanPage.transitionToReview()
///     }
/// }
/// ```
public enum CrossCheckEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Async Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// Evaluates all rules for a full page asynchronously.
    ///
    /// Processing runs on a background queue. ScanPage mutations are dispatched
    /// to the main thread before the completion handler is called.
    ///
    /// - Parameters:
    ///   - scanPage:      The live ScanPage with OCR results and combined pair values.
    ///   - combineResult: Output from HTPairCombiner.combineAll(). May be nil if
    ///                    the page has only text/integer columns (no H+t pairs).
    ///   - completion:    Called on the **main thread** with the full PageEvalResult.
    public static func runAsync(
        scanPage:      ScanPage,
        combineResult: PageCombineResult?,
        completion:    @escaping (PageEvalResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let evalResult = run(scanPage: scanPage, combineResult: combineResult)

            DispatchQueue.main.async {
                applyToScanPage(evalResult: evalResult, scanPage: scanPage)
                completion(evalResult)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Synchronous Full-Page Evaluation
    // ─────────────────────────────────────────────────────────────────────────

    /// Evaluates all rules for all rows synchronously.
    /// Must be called from a background queue. Prefer `runAsync` at all call sites.
    /// Exposed for unit tests.
    ///
    /// Does NOT mutate ScanPage. Returns PageEvalResult only.
    /// Call `applyToScanPage` on the main thread to write results.
    public static func run(
        scanPage:      ScanPage,
        combineResult: PageCombineResult?
    ) -> PageEvalResult {
        let wallStart = Date()

        // Build column lookup: columnId → ColumnDefinition (O(1) lookup in hot path)
        let columnMap = buildColumnMap(profile: scanPage.profile)

        var allResults: [RuleEvalResult] = []

        for rowIndex in 0..<scanPage.activeRowCount {
            let row = scanPage.pendingRows[rowIndex]

            for rule in scanPage.profile.crossCheckRules {
                let result = evaluateRule(
                    rule:          rule,
                    rowIndex:      rowIndex,
                    row:           row,
                    columnMap:     columnMap,
                    combineResult: combineResult
                )
                allResults.append(result)
            }
        }

        // Compute summary statistics
        let failedRows    = Set(allResults.filter { !$0.passed && !$0.skipped }.map(\.rowIndex))
        let blankRows     = Set(allResults.filter { $0.rule.ruleId == "blank_row_detection" && !$0.passed && !$0.skipped }.map(\.rowIndex))
        let autoAccRows   = Set(allResults.filter { !$0.skipped }.map(\.rowIndex))
            .subtracting(failedRows)
            .filter { ri in allResults.filter { $0.rowIndex == ri && $0.passed && $0.rule.confidence == .high && !$0.skipped }.isEmpty == false }

        let elapsed = Date().timeIntervalSince(wallStart) * 1000

        return PageEvalResult(
            ruleResults:       allResults,
            rowsWithFailures:  failedRows.count,
            rowsAutoAccepted:  autoAccRows.count,
            blankRowsSkipped:  blankRows.count,
            processingTimeMs:  elapsed
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Per-Row Re-evaluation (for live corrections in review table)
    // ─────────────────────────────────────────────────────────────────────────

    /// Re-evaluates only the rules that include a specific columnId.
    /// Called from the review table after a pilot corrects a cell.
    /// Runs synchronously on the main thread — O(rules) per call.
    ///
    /// Usage in review table correction sheet:
    /// ```swift
    /// scanPage.applyPilotCorrection(value: newValue, columnId: columnId,
    ///                               flightField: flightField, forRowIndex: rowIndex)
    /// if let pairId = definition.pairId {
    ///     HTPairCombiner.recombinePair(pairId: pairId, rowIndex: rowIndex, scanPage: scanPage)
    /// }
    /// CrossCheckEngine.runRow(rowIndex: rowIndex, correctedColumnId: columnId,
    ///                         scanPage: scanPage, combineResult: latestCombineResult)
    /// ```
    ///
    /// - Parameters:
    ///   - rowIndex:          The row that was corrected.
    ///   - correctedColumnId: The columnId whose value changed.
    ///   - scanPage:          The live ScanPage (pendingRows already updated by applyPilotCorrection).
    ///   - combineResult:     The most recent PageCombineResult (updated by recombinePair if H+t).
    @discardableResult
    @MainActor
    public static func runRow(
        rowIndex:          Int,
        correctedColumnId: String,
        scanPage:          ScanPage,
        combineResult:     PageCombineResult?
    ) -> [RuleEvalResult] {
        guard rowIndex < scanPage.pendingRows.count else { return [] }

        let columnMap = buildColumnMap(profile: scanPage.profile)
        let row       = scanPage.pendingRows[rowIndex]

        // Only re-run rules that reference the corrected columnId
        let affectedRules = scanPage.profile.crossCheckRules.filter {
            $0.fields.contains(correctedColumnId)
        }

        var results: [RuleEvalResult] = []

        for rule in affectedRules {
            let result = evaluateRule(
                rule:          rule,
                rowIndex:      rowIndex,
                row:           row,
                columnMap:     columnMap,
                combineResult: combineResult
            )
            results.append(result)

            // Apply immediately — we're already on main
            applyRuleResult(result, scanPage: scanPage)
        }

        return results
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: ScanPage Mutation (must run on main thread / @MainActor)
    // ─────────────────────────────────────────────────────────────────────────

    /// Applies all RuleEvalResults to ScanPage.pendingRows.
    /// Called on the main thread from runAsync after evaluation completes.
    @MainActor
    public static func applyToScanPage(
        evalResult: PageEvalResult,
        scanPage:   ScanPage
    ) {
        // Group by rowIndex and accumulate across all rules before writing,
        // so a single applyCrossCheckResult call handles the full row state.
        // This prevents a .flagged from an early rule being overwritten by
        // .autoAccepted from a later rule in the same row.

        struct RowAccumulator {
            var autoAccepted:  Set<String> = []
            var flagged:       Set<String> = []
            var failedRuleIds: Set<String> = []
            var failReasons:   [String]    = []
        }

        var rowAccumulators: [Int: RowAccumulator] = [:]

        for result in evalResult.ruleResults {
            guard result.requiresStateUpdate else { continue }

            var acc = rowAccumulators[result.rowIndex] ?? RowAccumulator()

            if result.passed {
                // Only promote to autoAccepted if confidence is .high
                if result.rule.confidence == .high {
                    // Don't auto-accept a columnId that was already flagged by another rule
                    let safeAutoAccept = result.autoAcceptedColumnIds.subtracting(acc.flagged)
                    acc.autoAccepted.formUnion(safeAutoAccept)
                }
            } else {
                // Flagged columns take priority — remove from autoAccepted if present
                acc.autoAccepted.subtract(result.flaggedColumnIds)
                acc.flagged.formUnion(result.flaggedColumnIds)
                acc.failedRuleIds.insert(result.rule.ruleId)
                if let reason = result.failReason {
                    acc.failReasons.append(reason)
                }
            }

            rowAccumulators[result.rowIndex] = acc
        }

        // Write each row's accumulated state in one shot
        for (rowIndex, acc) in rowAccumulators {
            let combinedReason = acc.failReasons.joined(separator: "; ")

            scanPage.applyCrossCheckResult(
                flaggedColumnIds:      acc.flagged,
                autoAcceptedColumnIds: acc.autoAccepted,
                failedRuleIds:         acc.failedRuleIds,
                reason:                combinedReason.isEmpty ? "Cross-check failed." : combinedReason,
                forRowIndex:           rowIndex
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Single-Result Application (for runRow live corrections)
    // ─────────────────────────────────────────────────────────────────────────

    @MainActor
    private static func applyRuleResult(
        _ result: RuleEvalResult,
        scanPage: ScanPage
    ) {
        guard result.requiresStateUpdate else { return }

        let reason = result.failReason ?? "Cross-check failed."

        scanPage.applyCrossCheckResult(
            flaggedColumnIds:      result.flaggedColumnIds,
            autoAcceptedColumnIds: result.passed && result.rule.confidence == .high
                ? result.autoAcceptedColumnIds : [],
            failedRuleIds:         result.passed ? [] : [result.rule.ruleId],
            reason:                reason,
            forRowIndex:           result.rowIndex
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Core Rule Evaluation (private)
    // ─────────────────────────────────────────────────────────────────────────

    private static func evaluateRule(
        rule:          CrossCheckRule,
        rowIndex:      Int,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?
    ) -> RuleEvalResult {

        // ── Applicability gate ──────────────────────────────────────────────
        if case .ifBlank(let gateColumnId) = rule.applicability {
            let gateValue = resolveValue(
                columnId:      gateColumnId,
                row:           row,
                columnMap:     columnMap,
                combineResult: combineResult,
                rowIndex:      rowIndex
            )
            if isBlankOrZero(gateValue) {
                return RuleEvalResult(
                    rule:                rule,
                    rowIndex:            rowIndex,
                    passed:              true,
                    skipped:             true,
                    failReason:          nil,
                    autoAcceptedColumnIds: [],
                    flaggedColumnIds:    []
                )
            }
        }

        // ── Dispatch to operator handler ────────────────────────────────────
        switch rule.`operator` {
        case .allEqual:
            return evaluateAllEqual(
                rule: rule, rowIndex: rowIndex, row: row,
                columnMap: columnMap, combineResult: combineResult
            )
        case .lte:
            return evaluateLte(
                rule: rule, rowIndex: rowIndex, row: row,
                columnMap: columnMap, combineResult: combineResult
            )
        case .gtZeroRequires:
            return evaluateGtZeroRequires(
                rule: rule, rowIndex: rowIndex, row: row,
                columnMap: columnMap, combineResult: combineResult
            )
        case .sumEquals:
            // Reserved for future rules — always passes without mutation.
            return RuleEvalResult(
                rule: rule, rowIndex: rowIndex, passed: true, skipped: true,
                failReason: nil, autoAcceptedColumnIds: [], flaggedColumnIds: []
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: .allEqual Operator
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Standard case (e.g. student_5way_match):
    //   Group H+t columnIds by pairId, resolve each group to a combined Float.
    //   Compare all floats for equality within tolerance.
    //   Text columns (date): non-blank presence check — treated as equal to a
    //   sentinel "present" value. If date is blank, the rule fails.
    //
    // Blank row detection (ruleId == "blank_row_detection"):
    //   The two fields are total_duration_hours + total_duration_tenths.
    //   Both blank or combined == 0.0 → row is blank → onFail .skipRow.
    //   Combined > 0 → row has content → rule passes, no auto-accept needed.

    private static func evaluateAllEqual(
        rule:          CrossCheckRule,
        rowIndex:      Int,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?
    ) -> RuleEvalResult {

        // ── blank_row_detection ─────────────────────────────────────────────
        if rule.ruleId == "blank_row_detection" {
            return evaluateBlankRowDetection(
                rule: rule, rowIndex: rowIndex, row: row,
                columnMap: columnMap, combineResult: combineResult
            )
        }

        // ── Standard allEqual ────────────────────────────────────────────────
        // Resolve each field to a (columnId, resolvedValue, isTextPresenceCheck) tuple
        let fieldGroups = resolveFieldGroups(
            rule: rule, row: row, columnMap: columnMap,
            combineResult: combineResult, rowIndex: rowIndex
        )

        // Separate text-presence fields from numeric fields
        let textFields    = fieldGroups.filter { $0.isTextPresence }
        let numericGroups = fieldGroups.filter { !$0.isTextPresence }

        // Text fields: must be non-blank
        var failingColumnIds: Set<String> = []

        for tf in textFields {
            if tf.resolvedFloat == nil && (tf.resolvedString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failingColumnIds.insert(tf.columnId)
            }
        }

        // Numeric fields: all values must be equal within tolerance
        let numericValues = numericGroups.compactMap { $0.resolvedFloat }

        if numericValues.count < numericGroups.count {
            // At least one numeric field couldn't be resolved — flag those columns
            for ng in numericGroups where ng.resolvedFloat == nil {
                failingColumnIds.insert(ng.columnId)
            }
        } else if !numericValues.isEmpty {
            // Check all values equal the first
            let reference = numericValues[0]
            for (i, value) in numericValues.enumerated() {
                if !areEqual(value, reference) {
                    failingColumnIds.insert(numericGroups[i].columnId)
                }
            }
        }

        if failingColumnIds.isEmpty {
            // All fields pass
            let allColumnIds = Set(fieldGroups.map(\.columnId))
            return passResult(
                rule:          rule,
                rowIndex:      rowIndex,
                allColumnIds:  allColumnIds
            )
        } else {
            return failResult(
                rule:             rule,
                rowIndex:         rowIndex,
                violatingIds:     failingColumnIds,
                allColumnIds:     Set(fieldGroups.map(\.columnId)),
                reason:           buildFailReason(rule: rule, violatingIds: failingColumnIds, columnMap: columnMap)
            )
        }
    }

    private static func evaluateBlankRowDetection(
        rule:          CrossCheckRule,
        rowIndex:      Int,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?
    ) -> RuleEvalResult {

        // Resolve total_duration combined value
        let totalFlightField = "total_time"
        let totalString      = row.fieldValues[totalFlightField] ?? ""
        let totalFloat       = parseFloat(totalString)

        // Blank or zero total → row is empty, apply .skipRow
        let isBlank = totalString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || (totalFloat != nil && areEqual(totalFloat!, 0.0))

        if isBlank {
            // Rule "fails" — blank_row_detection onFail == .skipRow
            // Pass empty flaggedColumnIds; ScanPage.applyCrossCheckResult
            // detects "blank_row_detection" in failedRuleIds and sets .blankRowSkipped
            return RuleEvalResult(
                rule:                  rule,
                rowIndex:              rowIndex,
                passed:                false,
                skipped:               false,
                failReason:            "Row \(rowIndex + 1) has no Total Duration — treated as blank.",
                autoAcceptedColumnIds: [],
                flaggedColumnIds:      []   // intentionally empty — ScanPage handles skipRow
            )
        }

        // Non-blank row — rule passes; this is not a high-confidence auto-accept
        // (the 5-way match handles that). Return no column state changes.
        return RuleEvalResult(
            rule:                  rule,
            rowIndex:              rowIndex,
            passed:                true,
            skipped:               false,
            failReason:            nil,
            autoAcceptedColumnIds: [],
            flaggedColumnIds:      []
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: .lte Operator
    // ─────────────────────────────────────────────────────────────────────────
    //
    // The LAST field group is the ceiling (e.g. Total Duration).
    // All preceding field groups must each be ≤ ceiling.
    //
    // total_gte_components:
    //   fields = [night_H, night_t, inst_actual_H, inst_actual_t, inst_sim_H, inst_sim_t,
    //             total_H, total_t]
    //   → groups = [night, inst_actual, inst_sim, total]
    //   → last group = total (ceiling)
    //   → check: night ≤ total, inst_actual ≤ total, inst_sim ≤ total
    //   → flag only the component that exceeds total, not total itself
    //
    // xc_lte_total:
    //   fields = [xc_H, xc_t, total_H, total_t]
    //   → groups = [xc, total]
    //   → check: xc ≤ total
    //   → flag xc if violated

    private static func evaluateLte(
        rule:          CrossCheckRule,
        rowIndex:      Int,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?
    ) -> RuleEvalResult {

        let fieldGroups = resolveFieldGroups(
            rule: rule, row: row, columnMap: columnMap,
            combineResult: combineResult, rowIndex: rowIndex
        )

        guard fieldGroups.count >= 2 else {
            // Degenerate rule — skip
            return RuleEvalResult(
                rule: rule, rowIndex: rowIndex, passed: true, skipped: true,
                failReason: nil, autoAcceptedColumnIds: [], flaggedColumnIds: []
            )
        }

        // The ceiling is the LAST logical group (last pairId group or last single column)
        // We need to group by pairId to get logical groups, then the last is the ceiling
        let logicalGroups = buildLogicalGroups(fieldGroups: fieldGroups, columnMap: columnMap)
        guard let ceilingGroup = logicalGroups.last else {
            return RuleEvalResult(
                rule: rule, rowIndex: rowIndex, passed: true, skipped: true,
                failReason: nil, autoAcceptedColumnIds: [], flaggedColumnIds: []
            )
        }

        guard let ceilingValue = ceilingGroup.combinedFloat else {
            // Ceiling value unresolvable — skip rule, don't flag arbitrarily
            return RuleEvalResult(
                rule: rule, rowIndex: rowIndex, passed: true, skipped: true,
                failReason: nil, autoAcceptedColumnIds: [], flaggedColumnIds: []
            )
        }

        var failingColumnIds: Set<String> = []
        let componentGroups = logicalGroups.dropLast()

        for group in componentGroups {
            guard let componentValue = group.combinedFloat else { continue }
            if !isLessThanOrEqual(componentValue, ceilingValue) {
                // Component exceeds ceiling — flag only the component, not the ceiling
                for colId in group.columnIds {
                    failingColumnIds.insert(colId)
                }
            }
        }

        if failingColumnIds.isEmpty {
            let allColumnIds = Set(fieldGroups.map(\.columnId))
            return passResult(rule: rule, rowIndex: rowIndex, allColumnIds: allColumnIds)
        } else {
            return failResult(
                rule:         rule,
                rowIndex:     rowIndex,
                violatingIds: failingColumnIds,
                allColumnIds: Set(fieldGroups.map(\.columnId)),
                reason:       buildFailReason(rule: rule, violatingIds: failingColumnIds, columnMap: columnMap)
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: .gtZeroRequires Operator
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Standard: trigger (first logical group) > 0 → at least one non-trigger > 0
    //   cfi_requires_aircraft:     dual_given > 0 → (cat_se OR cat_me) > 0
    //   approach_requires_instrument: approaches > 0 → (inst_actual OR inst_sim) > 0
    //
    // Inverted (sim_exclusive): trigger > 0 → ALL non-trigger groups == 0
    //   sim_exclusive: flight_sim > 0 → cat_se == 0 AND cat_me == 0
    //
    // The inversion is detected by ruleId == "sim_exclusive".

    private static func evaluateGtZeroRequires(
        rule:          CrossCheckRule,
        rowIndex:      Int,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?
    ) -> RuleEvalResult {

        let fieldGroups    = resolveFieldGroups(
            rule: rule, row: row, columnMap: columnMap,
            combineResult: combineResult, rowIndex: rowIndex
        )
        let logicalGroups  = buildLogicalGroups(fieldGroups: fieldGroups, columnMap: columnMap)

        guard let triggerGroup = logicalGroups.first else {
            return RuleEvalResult(
                rule: rule, rowIndex: rowIndex, passed: true, skipped: true,
                failReason: nil, autoAcceptedColumnIds: [], flaggedColumnIds: []
            )
        }

        let triggerValue   = triggerGroup.combinedFloat ?? 0.0
        let dependentGroups = Array(logicalGroups.dropFirst())

        // Trigger is zero or negative → rule trivially passes for all operators
        guard triggerValue > 0 else {
            let allColumnIds = Set(fieldGroups.map(\.columnId))
            return passResult(rule: rule, rowIndex: rowIndex, allColumnIds: allColumnIds)
        }

        let isInverted = rule.ruleId == "sim_exclusive"
        var failingColumnIds: Set<String> = []

        if isInverted {
            // sim_exclusive: trigger > 0 → all dependents must be 0
            for group in dependentGroups {
                let val = group.combinedFloat ?? 0.0
                if val > 0 {
                    for colId in group.columnIds { failingColumnIds.insert(colId) }
                }
            }
        } else {
            // Standard: trigger > 0 → at least one dependent > 0
            let anyDependentNonZero = dependentGroups.contains {
                ($0.combinedFloat ?? 0.0) > 0
            }
            if !anyDependentNonZero {
                // All dependents are zero — flag the trigger (not the dependents,
                // since we can't know which dependent *should* have a value)
                for colId in triggerGroup.columnIds { failingColumnIds.insert(colId) }
            }
        }

        if failingColumnIds.isEmpty {
            let allColumnIds = Set(fieldGroups.map(\.columnId))
            return passResult(rule: rule, rowIndex: rowIndex, allColumnIds: allColumnIds)
        } else {
            return failResult(
                rule:         rule,
                rowIndex:     rowIndex,
                violatingIds: failingColumnIds,
                allColumnIds: Set(fieldGroups.map(\.columnId)),
                reason:       buildFailReason(rule: rule, violatingIds: failingColumnIds, columnMap: columnMap)
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Result Builders
    // ─────────────────────────────────────────────────────────────────────────

    private static func passResult(
        rule:         CrossCheckRule,
        rowIndex:     Int,
        allColumnIds: Set<String>
    ) -> RuleEvalResult {
        let autoAccepted: Set<String> = rule.confidence == .high ? allColumnIds : []
        return RuleEvalResult(
            rule:                  rule,
            rowIndex:              rowIndex,
            passed:                true,
            skipped:               false,
            failReason:            nil,
            autoAcceptedColumnIds: autoAccepted,
            flaggedColumnIds:      []
        )
    }

    private static func failResult(
        rule:         CrossCheckRule,
        rowIndex:     Int,
        violatingIds: Set<String>,
        allColumnIds: Set<String>,
        reason:       String
    ) -> RuleEvalResult {
        // Determine which columnIds to flag based on onFail
        let flagged: Set<String>
        switch rule.onFail {
        case .flagFields:
            flagged = violatingIds
        case .flagRow, .block:
            flagged = allColumnIds
        case .skipRow:
            // blank_row_detection — ScanPage handles the skip; no cell flags
            flagged = []
        }

        return RuleEvalResult(
            rule:                  rule,
            rowIndex:              rowIndex,
            passed:                false,
            skipped:               false,
            failReason:            reason,
            autoAcceptedColumnIds: [],
            flaggedColumnIds:      flagged
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Value Resolution Infrastructure
    // ─────────────────────────────────────────────────────────────────────────

    /// A resolved field ready for numeric comparison.
    private struct ResolvedField {
        let columnId:       String
        let resolvedFloat:  Float?
        let resolvedString: String?
        /// true for text/date columns — comparison is presence check, not equality.
        let isTextPresence: Bool
    }

    /// A logical group of columnIds that resolve to one combined value.
    /// For H+t pairs: two columnIds → one combinedFloat.
    /// For single columns: one columnId → one combinedFloat.
    private struct LogicalGroup {
        let columnIds:    [String]
        let combinedFloat: Float?
    }

    /// Resolves all fields in a CrossCheckRule to ResolvedField values.
    private static func resolveFieldGroups(
        rule:          CrossCheckRule,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?,
        rowIndex:      Int
    ) -> [ResolvedField] {
        rule.fields.compactMap { columnId in
            let value = resolveValue(
                columnId:      columnId,
                row:           row,
                columnMap:     columnMap,
                combineResult: combineResult,
                rowIndex:      rowIndex
            )
            guard let def = columnMap[columnId] else { return nil }
            let isText = (def.dataType == .text || def.dataType == .imageOnly)
            return ResolvedField(
                columnId:       columnId,
                resolvedFloat:  isText ? nil : parseFloat(value),
                resolvedString: isText ? value : nil,
                isTextPresence: isText
            )
        }
    }

    /// Groups ResolvedFields into LogicalGroups by pairId (H+t → one group).
    /// Single-column fields each get their own group.
    private static func buildLogicalGroups(
        fieldGroups: [ResolvedField],
        columnMap:   [String: ColumnDefinition]
    ) -> [LogicalGroup] {
        var seenPairIds: Set<String> = []
        var pairOrder:   [String] = []           // preserves encounter order
        var pairMap:     [String: [ResolvedField]] = [:]
        var singles:     [ResolvedField] = []

        // Partition by pairId, maintaining encounter order
        for field in fieldGroups {
            if let def = columnMap[field.columnId],
               let pid = def.pairId,
               def.dataType == .decimalHours {
                if !seenPairIds.contains(pid) {
                    seenPairIds.insert(pid)
                    pairOrder.append(pid)
                }
                pairMap[pid, default: []].append(field)
            } else {
                singles.append(field)
            }
        }

        // Build pair groups — use sum of H.t value from resolved floats
        // H field (hours) value + t field (tenths) value / 10 = combined
        // But HTPairCombiner already wrote the combined string to fieldValues,
        // so both H and t fields resolve to single-digit floats, not decimals.
        // We need to combine them here: take max field value as H, min as t,
        // and compute H + t/10. HOWEVER the safer approach is:
        // Both H and t resolve via flightField to the same combined string (e.g. "3.7").
        // So resolvedFloat for both is identical (both → "3.7" → 3.7).
        // We can use either — just take the first.
        var result: [LogicalGroup] = []

        for pid in pairOrder {
            let pairFields = pairMap[pid] ?? []
            // Both H and t map to the same flightField → same combined float
            let combinedFloat = pairFields.first?.resolvedFloat
            let ids = pairFields.map(\.columnId)
            result.append(LogicalGroup(columnIds: ids, combinedFloat: combinedFloat))
        }

        // Append singles
        for single in singles {
            result.append(LogicalGroup(columnIds: [single.columnId], combinedFloat: single.resolvedFloat))
        }

        return result
    }

    /// Resolves a columnId to its string value by:
    ///   1. Finding the ColumnDefinition to get the flightField.
    ///   2. Reading PendingFlightRow.fieldValues[flightField].
    ///   3. Falling back to ColumnDefinition.defaultValue.
    private static func resolveValue(
        columnId:      String,
        row:           PendingFlightRow,
        columnMap:     [String: ColumnDefinition],
        combineResult: PageCombineResult?,
        rowIndex:      Int
    ) -> String {
        guard let def = columnMap[columnId] else { return "" }

        // Integer and text columns: read directly from fieldValues
        if def.dataType == .integer || def.dataType == .text || def.dataType == .imageOnly {
            return row.fieldValues[def.flightField] ?? def.defaultValue
        }

        // decimalHours: HTPairCombiner wrote the combined string to fieldValues
        // under the flightField key (e.g. "total_time" → "3.7")
        if let combined = row.fieldValues[def.flightField], !combined.isEmpty {
            return combined
        }

        // Fallback: ask PageCombineResult if available
        if let combineResult = combineResult,
           let combinedFloat = combineResult.combinedFloat(forFlightField: def.flightField, rowIndex: rowIndex) {
            return String(format: "%g", combinedFloat)
        }

        return def.defaultValue
    }

    /// Builds a human-readable failure reason for the correction sheet.
    private static func buildFailReason(
        rule:           CrossCheckRule,
        violatingIds:   Set<String>,
        columnMap:      [String: ColumnDefinition]
    ) -> String {
        let labels = violatingIds
            .compactMap { columnMap[$0] }
            .map { [$0.groupLabel, $0.subLabel, $0.unitLabel].filter { !$0.isEmpty }.joined(separator: " ") }
            .sorted()
        let fieldList = labels.isEmpty ? "unknown fields" : labels.joined(separator: ", ")
        return "\(rule.description) — check: \(fieldList)."
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Numeric Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Floating-point equality tolerance.
    /// 0.05 covers H+t rounding: "3.7" parsed as Float may differ by 0.001.
    /// Any two H.t values that differ by ≥ 0.1 (one tenths digit) are genuinely different.
    private static let equalityTolerance: Float = 0.05

    private static func areEqual(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) < equalityTolerance
    }

    private static func isLessThanOrEqual(_ a: Float, _ b: Float) -> Bool {
        a <= b + equalityTolerance
    }

    private static func parseFloat(_ text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Float(trimmed)
    }

    private static func isBlankOrZero(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if let f = Float(trimmed) { return f <= 0 }
        return false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Column Map Builder
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds a columnId → ColumnDefinition dictionary for O(1) lookup.
    private static func buildColumnMap(profile: LogbookProfile) -> [String: ColumnDefinition] {
        Dictionary(uniqueKeysWithValues: profile.columns.map { ($0.columnId, $0) })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanPage Convenience Extension
// ─────────────────────────────────────────────────────────────────────────────

/// Wires HTPairCombiner → CrossCheckEngine in a single call.
///
/// Typical usage after the final strip is captured:
/// ```swift
/// scanPage.runCrossChecks { evalResult in
///     // pendingRows are fully updated with autoAccepted / flagged states
///     scanPage.transitionToReview()
/// }
/// ```
public extension ScanPage {

    /// Combines H+t pairs then runs all cross-check rules.
    /// Delivers on the main thread with both results.
    func runCrossChecks(
        completion: @escaping (_ eval: PageEvalResult, _ combine: PageCombineResult) -> Void
    ) {
        HTPairCombiner.combineAllAsync(scanPage: self) { combineResult in
            CrossCheckEngine.runAsync(
                scanPage:      self,
                combineResult: combineResult
            ) { evalResult in
                completion(evalResult, combineResult)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Rule Result Summary for Review Table
// ─────────────────────────────────────────────────────────────────────────────

/// Per-row summary used by the review table to populate its data model.
public struct RowCheckSummary {

    /// Zero-based row index.
    public let rowIndex: Int

    /// true if all rules either passed or were skipped for this row.
    public let allRulesPassed: Bool

    /// true if any high-confidence rule passed (row eligible for auto-accept).
    public let hasHighConfidencePass: Bool

    /// true if the row was detected as blank (blank_row_detection fired).
    public let isBlankRow: Bool

    /// Human-readable descriptions of all failed rules, for the review sheet.
    public let failDescriptions: [String]

    /// All columnIds that should be auto-accepted (high-confidence passes).
    public let autoAcceptedColumnIds: Set<String>

    /// All columnIds that are flagged (failed rules).
    public let flaggedColumnIds: Set<String>
}

public extension PageEvalResult {

    /// Builds a RowCheckSummary for each row — convenience for the review table.
    var rowSummaries: [RowCheckSummary] {
        let rowIndices = Set(ruleResults.map(\.rowIndex)).sorted()
        return rowIndices.map { ri in
            let rowResults = ruleResults.filter { $0.rowIndex == ri }

            let allPassed    = rowResults.allSatisfy { $0.passed || $0.skipped }
            let hasHighPass  = rowResults.contains { $0.passed && !$0.skipped && $0.rule.confidence == .high }
            let isBlank      = rowResults.contains { $0.rule.ruleId == "blank_row_detection" && !$0.passed }
            let fails        = rowResults.filter { !$0.passed && !$0.skipped }.compactMap(\.failReason)
            let autoAccepted = rowResults
                .filter { $0.passed && $0.rule.confidence == .high && !$0.skipped }
                .reduce(into: Set<String>()) { $0.formUnion($1.autoAcceptedColumnIds) }
            let flagged      = rowResults
                .filter { !$0.passed && !$0.skipped }
                .reduce(into: Set<String>()) { $0.formUnion($1.flaggedColumnIds) }

            return RowCheckSummary(
                rowIndex:              ri,
                allRulesPassed:        allPassed,
                hasHighConfidencePass: hasHighPass,
                isBlankRow:            isBlank,
                failDescriptions:      fails,
                autoAcceptedColumnIds: autoAccepted,
                flaggedColumnIds:      flagged
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Debug View (#if DEBUG)
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG
import SwiftUI

/// Scrollable debug table showing all rule evaluations for a page.
/// One section per row, one cell per rule.
///
/// Usage:
///   CrossCheckDebugView(evalResult: pageEvalResult)
public struct CrossCheckDebugView: View {

    public let evalResult: PageEvalResult

    public init(evalResult: PageEvalResult) {
        self.evalResult = evalResult
    }

    public var body: some View {
        NavigationView {
            List {
                // Summary banner
                Section {
                    summaryRow("Evaluations", "\(evalResult.ruleResults.count)", .primary)
                    summaryRow("Rows with failures", "\(evalResult.rowsWithFailures)",
                               evalResult.rowsWithFailures > 0 ? AeroTheme.statusAmber : AeroTheme.statusGreen)
                    summaryRow("Auto-accepted rows", "\(evalResult.rowsAutoAccepted)", AeroTheme.statusGreen)
                    summaryRow("Blank rows skipped", "\(evalResult.blankRowsSkipped)", AeroTheme.neutral500)
                    summaryRow("Time", String(format: "%.1f ms", evalResult.processingTimeMs), .secondary)
                } header: { Text("Summary") }

                // Per-row sections
                let summaries = evalResult.rowSummaries
                ForEach(summaries, id: \.rowIndex) { summary in
                    Section {
                        ForEach(evalResult.results(forRowIndex: summary.rowIndex),
                                id: \.rule.ruleId) { result in
                            ruleCell(result)
                        }
                    } header: {
                        rowHeader(summary)
                    }
                }
            }
            .navigationTitle("Cross-check Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.neutral700)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func rowHeader(_ summary: RowCheckSummary) -> some View {
        HStack(spacing: 6) {
            Text("Row \(summary.rowIndex + 1)")
                .font(.system(size: 12, weight: .semibold))

            if summary.isBlankRow {
                badge("BLANK", AeroTheme.neutral500)
            } else if summary.allRulesPassed && summary.hasHighConfidencePass {
                badge("AUTO-ACCEPTED", AeroTheme.statusGreen)
            } else if !summary.allRulesPassed {
                badge("\(summary.flaggedColumnIds.count) FLAGS", AeroTheme.statusAmber)
            } else {
                badge("PENDING", AeroTheme.sky400)
            }
        }
    }

    @ViewBuilder
    private func ruleCell(_ result: RuleEvalResult) -> some View {
        HStack(spacing: 10) {
            // Pass/fail/skip indicator
            Image(systemName: result.skipped ? "minus.circle" :
                              result.passed  ? "checkmark.circle.fill" :
                                              "exclamationmark.triangle.fill")
                .foregroundStyle(result.skipped ? AeroTheme.neutral400 :
                                 result.passed  ? AeroTheme.statusGreen :
                                                  AeroTheme.statusAmber)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.rule.ruleId)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(AeroTheme.neutral800)

                if let reason = result.failReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(AeroTheme.statusAmber)
                        .lineLimit(2)
                } else if result.skipped {
                    Text("Skipped — applicability condition not met")
                        .font(.caption2)
                        .foregroundStyle(AeroTheme.neutral400)
                }
            }

            Spacer()

            // Confidence badge
            confidenceBadge(result.rule.confidence)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func badge(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: CrossCheckConfidence) -> some View {
        let (label, color): (String, Color) = switch confidence {
        case .high:   ("HIGH",   AeroTheme.statusGreen)
        case .medium: ("MED",    AeroTheme.sky400)
        case .low:    ("LOW",    AeroTheme.neutral400)
        }
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private var AeroTheme: _AeroThemeProxy { _AeroThemeProxy() }
}

/// Proxy to access AeroTheme static colours in a #if DEBUG context without
/// importing the entire module — resolves in the same target.
private struct _AeroThemeProxy {
    var statusGreen: Color  { Color.statusGreen }
    var statusAmber: Color  { Color.statusAmber }
    var sky400:      Color  { Color.sky400 }
    var neutral800:  Color  { Color.neutral800 }
    var neutral700:  Color  { Color.neutral700 }
    var neutral500:  Color  { Color.neutral500 }
    var neutral400:  Color  { Color.neutral400 }
}

#Preview("Cross-check Debug") {
    CrossCheckDebugView(evalResult: PageEvalResult(
        ruleResults: [
            RuleEvalResult(
                rule: CrossCheckRule(
                    ruleId: "student_5way_match",
                    description: "Date; SE = Dual = PIC = Total",
                    fields: ["date", "category_se_hours", "dual_received_hours",
                             "pic_hours", "total_duration_hours"],
                    operator: .allEqual,
                    confidence: .high,
                    onFail: .flagFields,
                    applicability: .always
                ),
                rowIndex: 0, passed: true, skipped: false, failReason: nil,
                autoAcceptedColumnIds: ["category_se_hours", "dual_received_hours",
                                        "pic_hours", "total_duration_hours"],
                flaggedColumnIds: []
            ),
            RuleEvalResult(
                rule: CrossCheckRule(
                    ruleId: "xc_lte_total",
                    description: "Cross Country ≤ Total Duration",
                    fields: ["cross_country_hours", "cross_country_tenths",
                             "total_duration_hours", "total_duration_tenths"],
                    operator: .lte,
                    confidence: .medium,
                    onFail: .flagFields,
                    applicability: .always
                ),
                rowIndex: 1, passed: false, skipped: false,
                failReason: "Cross Country ≤ Total Duration — check: Cross Country.",
                autoAcceptedColumnIds: [],
                flaggedColumnIds: ["cross_country_hours", "cross_country_tenths"]
            ),
        ],
        rowsWithFailures: 1,
        rowsAutoAccepted: 0,
        blankRowsSkipped: 0,
        processingTimeMs: 1.2
    ))
}
#endif
