// DateFormatHint.swift
// AeroBook — Scanner/DateScanner/Model group
//
// Build Order: Date Scanner Step 1 — DateFormatHint model
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Defines the two root types consumed by every stage of the date scanner
// pipeline:
//
//   DateInputFormat  — enum describing how dates are physically written in a
//                      specific paper logbook column. Seven cases, one for
//                      each distinct handwriting pattern the scanner must
//                      parse. Each case exposes a displayName for the picker
//                      UI so pilots can correct the auto-detected format.
//
//   DateFormatHint   — value-type bundle passed through the scanner pipeline.
//                      Carries the resolved format, the known context year,
//                      and optional carry-forward state for blank-row
//                      resolution. No month context is ever stored here —
//                      month is derived from the raw cell text on each row.
//
// ─────────────────────────────────────────────────────────────────────────────
// LOCKED DECISIONS (Date Scanner tracker, Step 1)
// ─────────────────────────────────────────────────────────────────────────────
//   • No contextMonth field. Month is never declared upfront; it is always
//     parsed from the raw OCR text on each individual row.
//   • DateFormatHint fields: inputFormat, contextYear, anchorDate,
//     lastResolvedDate. Nothing else.
//   • DateInputFormat has exactly 7 cases: mSlashD, mmSlashDD, mDashD,
//     mDotD, mmmD, mSlashDSlashYY, dayOnly.
//   • monthIsExplicit returns false ONLY for .dayOnly.
//   • Codable throughout — DateFormatHint is persisted as a JSON blob inside
//     the active ScanPage session so it survives backgrounding.
//   • No UIKit. No SwiftUI. Foundation only.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   • Nothing. This is the root node of the date scanner dependency graph.
//     Every other date scanner type imports this file; this file imports
//     nothing from AeroBook.
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DateInputFormat
// ─────────────────────────────────────────────────────────────────────────────

/// Describes how dates are physically written in a scanned logbook column.
///
/// The enum drives two separate concerns:
///   1. **Parsing** — DateResolver uses the case to select the correct regex
///      and carry-forward strategy for each OCR'd cell string.
///   2. **Picker UI** — `displayName` is shown in the format-correction picker
///      that appears when the scanner auto-detects an unexpected format.
///
/// All cases except `.dayOnly` carry explicit month information.
/// `.dayOnly` relies on the pipeline's carry-forward state (lastResolvedDate)
/// to infer the month; see `monthIsExplicit`.
///
/// **Codable conformance** is synthesised automatically because all associated
/// values are either absent or Codable primitives. The raw string value is
/// used as the Codable key so that stored format strings are human-readable
/// in debug exports.
public enum DateInputFormat: String, Codable, CaseIterable, Sendable {

    // ── Slash-separated numeric ───────────────────────────────────────────

    /// Single-digit or leading-zero month and single-digit day: `1/4`, `12/9`.
    /// The most common Jeppesen format. Covers M/D and MM/D patterns.
    case mSlashD = "mSlashD"

    /// Zero-padded two-digit month and two-digit day: `01/04`, `12/09`.
    /// Used by some ASA and FAA-standard logbooks that enforce consistent width.
    case mmSlashDD = "mmSlashDD"

    // ── Dash-separated numeric ────────────────────────────────────────────

    /// Dash separator, unpadded digits: `1-4`, `12-9`.
    /// Common in older European-format logbooks imported via CSV.
    case mDashD = "mDashD"

    // ── Dot-separated numeric ─────────────────────────────────────────────

    /// Dot separator, unpadded digits: `1.4`, `12.9`.
    /// Used by some international logbooks and some ForeFlight CSV exports.
    case mDotD = "mDotD"

    // ── Abbreviated month name + day ──────────────────────────────────────

    /// Three-letter abbreviated month name followed by space and day: `Jan 4`, `Dec 12`.
    /// Common in handwritten Jeppesen logbooks where pilots write the month
    /// abbreviation rather than a number. Case-insensitive during parsing;
    /// displayName uses title case.
    case mmmD = "mmmD"

    // ── Full date including year ──────────────────────────────────────────

    /// Slash-separated with two-digit year: `1/4/24`, `12/9/23`.
    /// The only format that carries an explicit year in the cell text. When
    /// this case is active, DateResolver ignores contextYear for those rows
    /// and derives the year directly from the OCR'd text. contextYear is
    /// still used as a fallback when the cell's year digits are ambiguous.
    case mSlashDSlashYY = "mSlashDSlashYY"

    // ── Day-only ──────────────────────────────────────────────────────────

    /// A bare day number with no month or year: `4`, `12`.
    /// Requires carry-forward: month is inferred from `DateFormatHint.lastResolvedDate`.
    /// The pipeline must flag a carry-forward failure if lastResolvedDate is
    /// nil and the first cell in the column uses this format.
    case dayOnly = "dayOnly"

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Display Name (picker label)
    // ─────────────────────────────────────────────────────────────────────

    /// Human-readable label shown in the format-correction picker.
    ///
    /// The label uses a concrete example so pilots can visually match what
    /// they see in their logbook without knowing the enum name.
    public var displayName: String {
        switch self {
        case .mSlashD:       return "M/D  (e.g. 1/4 or 12/9)"
        case .mmSlashDD:     return "MM/DD  (e.g. 01/04)"
        case .mDashD:        return "M-D  (e.g. 1-4 or 12-9)"
        case .mDotD:         return "M.D  (e.g. 1.4 or 12.9)"
        case .mmmD:          return "Mon D  (e.g. Jan 4 or Dec 12)"
        case .mSlashDSlashYY: return "M/D/YY  (e.g. 1/4/24)"
        case .dayOnly:       return "D only  (e.g. 4 or 12)"
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Month explicitness
    // ─────────────────────────────────────────────────────────────────────

    /// Returns `true` when the format always carries an explicit month in
    /// the cell text, so the parser never needs carry-forward to resolve the month.
    ///
    /// Returns `false` only for `.dayOnly`, which carries no month and relies
    /// entirely on `DateFormatHint.lastResolvedDate` to supply the month context.
    ///
    /// Down-pipeline consumers (DateResolver, DateCarryForwardEngine) check this
    /// flag before attempting month inference to avoid silently assigning a wrong
    /// month when carry-forward state is stale.
    public var monthIsExplicit: Bool {
        switch self {
        case .dayOnly: return false
        default:       return true
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DateFormatHint
// ─────────────────────────────────────────────────────────────────────────────

/// Immutable value-type bundle that travels through the date scanner pipeline.
///
/// A `DateFormatHint` is created once per scan session (or once per page if
/// the detected format changes) and threaded through every stage:
///
///   DateFormatDetector  →  DateResolver  →  DateCarryForwardEngine
///                                               │
///                                          updated copies
///
/// Because `DateFormatHint` is a `struct`, each stage produces a new copy
/// with `lastResolvedDate` updated — there is no shared mutable state.
///
/// **Fields:**
///
/// - `inputFormat`       — The `DateInputFormat` case that applies to the
///                         cells in this column for this page. Set by
///                         DateFormatDetector from the first non-blank cell;
///                         overridable by the pilot via the picker.
///
/// - `contextYear`       — The four-digit year known to apply to this page
///                         (e.g. 2023). Supplied by the pilot at the start of
///                         the scan session and used for all rows where the
///                         cell text does not carry an explicit year.
///                         **Never derived from OCR alone** — a pilot must
///                         confirm or correct it before scanning begins.
///
/// - `anchorDate`        — Optional first fully-resolved date on this page.
///                         Set by DateResolver when the first non-blank date
///                         cell is successfully parsed. Used by the cross-check
///                         engine to validate that subsequent dates are
///                         plausible (e.g., no date should jump >30 days
///                         forward within a single logbook page).
///                         `nil` until the first date is resolved.
///
/// - `lastResolvedDate`  — Optional most-recently-resolved date on this page.
///                         Updated by DateCarryForwardEngine after each
///                         successful row. Consumed by the carry-forward logic
///                         for `.dayOnly` cells and for blank date cells that
///                         inherit the previous row's date.
///                         `nil` until at least one date on the page is resolved.
///
/// **No contextMonth field.** Month is always parsed from the raw cell text.
/// For `.dayOnly` cells, month comes from `lastResolvedDate`. There is no
/// separate "declared month" concept in this pipeline.
///
/// **Codable.** `Date` fields are encoded as ISO 8601 double-precision
/// timestamps by the default `JSONEncoder` / `JSONDecoder` used by ScanPage.
public struct DateFormatHint: Codable, Equatable, Sendable {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Stored properties
    // ─────────────────────────────────────────────────────────────────────

    /// The date writing pattern used in this logbook's date column.
    public let inputFormat: DateInputFormat

    /// The four-digit calendar year that applies to all cells on this page
    /// unless a cell's text carries its own year (`.mSlashDSlashYY`).
    ///
    /// Valid range: 1900 ... 2100 (enforced by the designated initialiser).
    public let contextYear: Int

    /// The first successfully-resolved `Date` on this page.
    ///
    /// `nil` until DateResolver succeeds on the first non-blank cell.
    /// Once set it does not change — it is the page's temporal anchor.
    public let anchorDate: Date?

    /// The most recently resolved `Date` on this page.
    ///
    /// Updated row-by-row by DateCarryForwardEngine. Used as the month
    /// source for `.dayOnly` cells and as the date for blank cells that
    /// should inherit the prior row's value.
    ///
    /// `nil` until at least one date on the page resolves successfully.
    public let lastResolvedDate: Date?

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Designated initialiser
    // ─────────────────────────────────────────────────────────────────────

    /// Creates a new `DateFormatHint`.
    ///
    /// - Parameters:
    ///   - inputFormat:       The detected or pilot-confirmed date format.
    ///   - contextYear:       The four-digit year for the page (1900–2100).
    ///   - anchorDate:        First resolved date, or `nil` if not yet known.
    ///   - lastResolvedDate:  Most recent resolved date, or `nil` if not yet known.
    ///
    /// - Precondition: `contextYear` must be in the range 1900...2100.
    ///   The precondition is checked only in DEBUG builds so there is no
    ///   runtime cost in production.
    public init(
        inputFormat:      DateInputFormat,
        contextYear:      Int,
        anchorDate:       Date? = nil,
        lastResolvedDate: Date? = nil
    ) {
        precondition(
            (1900...2100).contains(contextYear),
            "DateFormatHint.contextYear must be in 1900...2100, got \(contextYear)."
        )
        self.inputFormat      = inputFormat
        self.contextYear      = contextYear
        self.anchorDate       = anchorDate
        self.lastResolvedDate = lastResolvedDate
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Functional update helpers
    // ─────────────────────────────────────────────────────────────────────

    /// Returns a copy of the hint with `anchorDate` set to `date`.
    ///
    /// Call this the first time DateResolver successfully resolves a date
    /// on the page. `anchorDate` is write-once by convention — passing an
    /// already-set `anchorDate` through this method is a logic error; the
    /// method asserts in DEBUG builds.
    public func settingAnchorDate(_ date: Date) -> DateFormatHint {
        assert(anchorDate == nil, "anchorDate already set — do not overwrite the page anchor.")
        return DateFormatHint(
            inputFormat:      inputFormat,
            contextYear:      contextYear,
            anchorDate:       date,
            lastResolvedDate: lastResolvedDate ?? date
        )
    }

    /// Returns a copy of the hint with `lastResolvedDate` updated to `date`.
    ///
    /// Called by DateCarryForwardEngine after each successfully resolved row.
    /// `anchorDate` is preserved unchanged.
    public func advancingLastResolved(to date: Date) -> DateFormatHint {
        DateFormatHint(
            inputFormat:      inputFormat,
            contextYear:      contextYear,
            anchorDate:       anchorDate,
            lastResolvedDate: date
        )
    }

    /// Returns a copy of the hint with `inputFormat` replaced.
    ///
    /// Called when the pilot corrects the auto-detected format in the picker.
    /// Year and carry-forward state are preserved — only the format changes.
    public func withFormat(_ format: DateInputFormat) -> DateFormatHint {
        DateFormatHint(
            inputFormat:      format,
            contextYear:      contextYear,
            anchorDate:       anchorDate,
            lastResolvedDate: lastResolvedDate
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Computed convenience
    // ─────────────────────────────────────────────────────────────────────

    /// `true` when the active format always carries an explicit month.
    /// Delegates directly to `DateInputFormat.monthIsExplicit`.
    public var monthIsExplicit: Bool {
        inputFormat.monthIsExplicit
    }

    /// `true` once the first date on this page has been successfully resolved.
    public var hasAnchor: Bool {
        anchorDate != nil
    }

    /// `true` once at least one date has been resolved (may differ from
    /// `hasAnchor` if resolution fails on the first attempt).
    public var hasCarryForwardState: Bool {
        lastResolvedDate != nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CustomStringConvertible (debug-friendly description)
// ─────────────────────────────────────────────────────────────────────────────

extension DateFormatHint: CustomStringConvertible {

    /// One-line summary for log output. Not intended for UI.
    public var description: String {
        let anchor = anchorDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let last   = lastResolvedDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        return "DateFormatHint(format: \(inputFormat.rawValue), year: \(contextYear), "
             + "anchor: \(anchor), last: \(last))"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DEBUG self-test
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG
/// Runs a suite of compile-time-safe assertions against the two types defined
/// in this file. Called from the app's DEBUG launch path (e.g. AppDelegate or
/// a TestHost target) to catch regressions early.
///
/// All assertions use `precondition` so failures appear as hard crashes in
/// DEBUG builds and are eliminated entirely in RELEASE builds.
public enum DateFormatHintSelfTest {

    public static func run() {

        // ── DateInputFormat: case count ───────────────────────────────────
        let allCases = DateInputFormat.allCases
        precondition(
            allCases.count == 7,
            "Expected 7 DateInputFormat cases, found \(allCases.count)."
        )

        // ── DateInputFormat: monthIsExplicit ──────────────────────────────
        for fmt in allCases {
            if fmt == .dayOnly {
                precondition(
                    !fmt.monthIsExplicit,
                    ".dayOnly must return monthIsExplicit = false."
                )
            } else {
                precondition(
                    fmt.monthIsExplicit,
                    "\(fmt.rawValue) must return monthIsExplicit = true."
                )
            }
        }

        // ── DateInputFormat: displayName non-empty ────────────────────────
        for fmt in allCases {
            precondition(
                !fmt.displayName.isEmpty,
                "\(fmt.rawValue).displayName must not be empty."
            )
        }

        // ── DateInputFormat: Codable round-trip ───────────────────────────
        for fmt in allCases {
            guard
                let encoded = try? JSONEncoder().encode(fmt),
                let decoded = try? JSONDecoder().decode(DateInputFormat.self, from: encoded)
            else {
                preconditionFailure("\(fmt.rawValue) failed Codable round-trip.")
            }
            precondition(
                decoded == fmt,
                "\(fmt.rawValue) decoded to a different case after round-trip."
            )
        }

        // ── DateFormatHint: basic construction ────────────────────────────
        let hint = DateFormatHint(inputFormat: .mSlashD, contextYear: 2024)
        precondition(hint.contextYear  == 2024,       "contextYear not stored correctly.")
        precondition(hint.inputFormat  == .mSlashD,   "inputFormat not stored correctly.")
        precondition(hint.anchorDate   == nil,         "anchorDate should be nil on init.")
        precondition(hint.lastResolvedDate == nil,     "lastResolvedDate should be nil on init.")
        precondition(hint.monthIsExplicit,             "mSlashD must have monthIsExplicit = true.")
        precondition(!hint.hasAnchor,                  "hasAnchor must be false before anchor is set.")
        precondition(!hint.hasCarryForwardState,       "hasCarryForwardState must be false on init.")

        // ── DateFormatHint: dayOnly monthIsExplicit = false ───────────────
        let dayOnlyHint = DateFormatHint(inputFormat: .dayOnly, contextYear: 2024)
        precondition(
            !dayOnlyHint.monthIsExplicit,
            "dayOnly hint must have monthIsExplicit = false."
        )

        // ── DateFormatHint: settingAnchorDate ─────────────────────────────
        let anchor = Date(timeIntervalSince1970: 1_700_000_000) // ~Nov 2023
        let hinted = hint.settingAnchorDate(anchor)
        precondition(hinted.anchorDate       == anchor, "anchorDate not set by settingAnchorDate.")
        precondition(hinted.lastResolvedDate == anchor, "lastResolvedDate should equal anchor on first set.")
        precondition(hinted.contextYear      == hint.contextYear, "contextYear must be preserved.")
        precondition(hint.anchorDate         == nil,   "Original hint must be unchanged (value semantics).")

        // ── DateFormatHint: advancingLastResolved ─────────────────────────
        let later = Date(timeIntervalSince1970: 1_700_086_400) // anchor + 1 day
        let advanced = hinted.advancingLastResolved(to: later)
        precondition(advanced.lastResolvedDate == later,  "lastResolvedDate not updated.")
        precondition(advanced.anchorDate       == anchor, "anchorDate must not change on advance.")
        precondition(hinted.lastResolvedDate   == anchor, "Original hinted must be unchanged (value semantics).")

        // ── DateFormatHint: withFormat ────────────────────────────────────
        let reformatted = hinted.withFormat(.mmmD)
        precondition(reformatted.inputFormat      == .mmmD,  "inputFormat not updated by withFormat.")
        precondition(reformatted.contextYear      == 2024,   "contextYear must be preserved by withFormat.")
        precondition(reformatted.anchorDate       == anchor, "anchorDate must be preserved by withFormat.")
        precondition(hinted.inputFormat           == .mSlashD, "Original hint must be unchanged (value semantics).")

        // ── DateFormatHint: Codable round-trip ────────────────────────────
        guard
            let data    = try? JSONEncoder().encode(advanced),
            let decoded = try? JSONDecoder().decode(DateFormatHint.self, from: data)
        else {
            preconditionFailure("DateFormatHint Codable round-trip encoding/decoding failed.")
        }
        precondition(decoded.inputFormat      == advanced.inputFormat,      "inputFormat mismatch after round-trip.")
        precondition(decoded.contextYear      == advanced.contextYear,      "contextYear mismatch after round-trip.")
        precondition(decoded.anchorDate       == advanced.anchorDate,       "anchorDate mismatch after round-trip.")
        precondition(decoded.lastResolvedDate == advanced.lastResolvedDate, "lastResolvedDate mismatch after round-trip.")

        // ── DateFormatHint: contextYear range guard ───────────────────────
        // A valid year at each boundary must not crash.
        _ = DateFormatHint(inputFormat: .mSlashD, contextYear: 1900)
        _ = DateFormatHint(inputFormat: .mSlashD, contextYear: 2100)

        // All assertions passed.
    }
}
#endif
