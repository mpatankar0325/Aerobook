// PendingFlightRow.swift
// AeroBook — Scanner group
//
// Represents one assembled flight entry row during the review phase.
// A PendingFlightRow is constructed by the H+t pair combiner after OCR
// completes for all desired phases. It holds the resolved field values,
// per-cell review state (auto-accepted / flagged / corrected), and the
// pilot's commit decision (include / skip / duplicate-resolved).
//
// Lifecycle:
//   1. ScanPage.pendingRows is populated by the cross-check engine after
//      Phase 1+2 minimum (or after all desired phases complete).
//   2. The review table reads PendingFlightRow to render the green/amber grid.
//   3. The pilot corrects flagged cells — mutations flow back into
//      fieldValues and cellStates via ScanPage update methods.
//   4. The commit engine reads rows where commitDecision == .include and
//      writes them to the flights table in a single DB transaction.
//
// Nothing in this file touches the database.

import Foundation
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CellReviewState
// ─────────────────────────────────────────────────────────────────────────────

/// The review state of one field (cell) within a PendingFlightRow.
/// Drives the colour coding and interaction in the review table.
public enum CellReviewState: Equatable {

    /// The column has not been captured yet in this scan session.
    /// Shown as a grey "not scanned" placeholder in the review table.
    case notScanned

    /// OCR ran and a high-confidence cross-check rule passed for this field.
    /// No pilot action needed. Shown with subtle green background.
    case autoAccepted

    /// OCR ran; no cross-check rule flagged this field; confidence is
    /// acceptable. Awaiting pilot review or will be silently accepted on commit.
    case pendingReview

    /// A cross-check rule failed, or OCR confidence was below 0.5.
    /// Shown with amber background and warning icon. Pilot must resolve
    /// before the commit button enables (unless the row is skipped).
    case flagged(reason: String)

    /// Pilot opened the correction sheet and confirmed or edited this value.
    /// Shown with a subtle blue badge. Treated as accepted for commit.
    case correctedByPilot

    /// Convenience: this cell state does not block commit.
    public var isResolved: Bool {
        switch self {
        case .flagged: return false
        default:       return true
        }
    }

    /// Convenience: show amber highlight in review table.
    public var needsAttention: Bool {
        if case .flagged = self { return true }
        return false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DuplicateResolution
// ─────────────────────────────────────────────────────────────────────────────

/// The pilot's choice when the commit engine finds an existing flight record
/// that matches this row's date + aircraftIdent + totalTime.
public enum DuplicateResolution: Equatable {

    /// No duplicate was detected, or detection has not run yet.
    case none

    /// A matching record was found — awaiting the pilot's decision.
    case pendingResolution(existingFlightId: Int64)

    /// Pilot chose not to write this row; existing record is unchanged.
    case skip

    /// Pilot chose to overwrite the existing record with this row's data.
    case replace(existingFlightId: Int64)

    /// Pilot confirmed both records are genuinely distinct; write a new row.
    case keepBoth
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowCommitDecision
// ─────────────────────────────────────────────────────────────────────────────

/// The pilot's commit decision for this row as a whole.
public enum RowCommitDecision: Equatable {

    /// Default state. Row will be included in the commit unless the pilot
    /// skips it or it is detected as blank.
    case include

    /// Pilot tapped "Skip this row" in the review table.
    /// Row is excluded from the DB transaction regardless of field states.
    case skip

    /// blank_row_detection rule fired — Total Duration is blank or zero.
    /// Row is excluded automatically; the pilot is not asked to review it.
    case blankRowSkipped
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PendingFlightRow
// ─────────────────────────────────────────────────────────────────────────────

/// One assembled flight entry held in memory during the review phase.
///
/// `fieldValues` is a flat dictionary from flightField string → resolved value
/// (String). The commit engine converts these strings to their final types
/// (Double, Int, String) when writing to SQLite. Using String throughout keeps
/// the model simple and makes the correction sheet trivial — the pilot always
/// edits a string.
///
/// `cellStates` parallels fieldValues but keyed by columnId (not flightField)
/// because multiple ColumnDefinitions can share a flightField (H+t pairs) and
/// we need independent review state per physical cell.
public final class PendingFlightRow: Identifiable {

    // MARK: Identity

    /// Stable identifier for this row within the current ScanPage.
    public let id: UUID = UUID()

    /// Zero-based page row index (0 = top data row on the scanned page).
    /// Used to correlate back to ColumnStrip.cellResults[rowIndex].
    public let rowIndex: Int

    // MARK: Field Values

    /// Resolved field values keyed by flightField string (e.g. "total_time",
    /// "date", "pic"). These are the values that will be written to the DB.
    ///
    /// For H+t pairs the value is the combined decimal string (e.g. "1.3" from
    /// H=1, t=3). The H+t pair combiner writes this after joining both cells.
    ///
    /// For imageOnly columns the value is the temporary file path of the
    /// captured cell image (written by the image capture step, not OCR).
    public var fieldValues: [String: String]

    // MARK: Per-Cell Review State

    /// Review state keyed by columnId (e.g. "total_duration_hours").
    /// One entry per ColumnDefinition that has been captured for this row.
    /// Columns not yet captured are absent from this dictionary — the review
    /// table treats absent columns as .notScanned.
    public var cellStates: [String: CellReviewState]

    // MARK: Cross-Check Flags

    /// columnId values that were flagged by one or more cross-check rules.
    /// Populated by the cross-check engine after OCR completes.
    /// Cleared per-columnId when the pilot corrects the cell.
    public var crossCheckFlags: Set<String>

    /// ruleIds of rules that failed for this row. Used by the review table
    /// to display rule descriptions in the correction bottom sheet.
    public var failedRuleIds: Set<String>

    // MARK: Commit Decision

    /// Whether this row will be written to the database on commit.
    public var commitDecision: RowCommitDecision

    /// Duplicate detection result, populated at commit time (after review).
    public var duplicateResolution: DuplicateResolution

    // MARK: Init

    public init(
        rowIndex: Int,
        fieldValues: [String: String] = [:],
        cellStates: [String: CellReviewState] = [:],
        crossCheckFlags: Set<String> = [],
        failedRuleIds: Set<String> = [],
        commitDecision: RowCommitDecision = .include,
        duplicateResolution: DuplicateResolution = .none
    ) {
        self.rowIndex            = rowIndex
        self.fieldValues         = fieldValues
        self.cellStates          = cellStates
        self.crossCheckFlags     = crossCheckFlags
        self.failedRuleIds       = failedRuleIds
        self.commitDecision      = commitDecision
        self.duplicateResolution = duplicateResolution
    }

    // MARK: Convenience

    /// true if every captured cell is in a resolved state (not .flagged).
    /// The commit button enables only when all included rows return true here.
    public var isFullyResolved: Bool {
        commitDecision != .include || cellStates.values.allSatisfy { $0.isResolved }
    }

    /// true if any cell is currently flagged and needs pilot attention.
    public var hasPendingFlags: Bool {
        cellStates.values.contains { $0.needsAttention }
    }

    /// Returns the resolved value for a flightField, or nil if not yet captured.
    public func value(for flightField: String) -> String? {
        fieldValues[flightField]
    }

    /// Returns the review state for a columnId, defaulting to .notScanned.
    public func state(for columnId: String) -> CellReviewState {
        cellStates[columnId] ?? .notScanned
    }

    /// Applies a pilot correction: updates the field value, clears the flag,
    /// and marks the cell as corrected. Clears the cross-check flag for the
    /// columnId so the cross-check engine can re-evaluate the row.
    ///
    /// - Parameters:
    ///   - value: The corrected string value entered by the pilot.
    ///   - columnId: The columnId whose cell state to update.
    ///   - flightField: The flightField key to update in fieldValues.
    public func applyCorrection(value: String, columnId: String, flightField: String) {
        fieldValues[flightField]   = value
        cellStates[columnId]       = .correctedByPilot
        crossCheckFlags.remove(columnId)
    }

    /// Marks the row as skipped by the pilot. Clears any pending flags so the
    /// commit button is not blocked by a row the pilot has chosen to exclude.
    public func markSkipped() {
        commitDecision = .skip
        // Clear all flags — skipped rows must not block the commit button.
        for key in cellStates.keys {
            if case .flagged = cellStates[key] {
                cellStates[key] = .pendingReview
            }
        }
    }
}
