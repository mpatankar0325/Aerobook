// DateColumnParser.swift
// AeroBook — Scanner/DateScanner/Engine group
//
// Build Order: Date Scanner Step 2 — DateColumnParser
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// The single source of truth for converting a raw OCR string into a resolved
// Date? using the active DateFormatHint.
//
// Responsibilities:
//   1. Pre-process raw text before any parse attempt:
//        • trim whitespace
//        • replace O (capital-oh) → 0 (zero)
//        • replace l (lowercase-L) → 1 (one)
//   2. Detect empty / whitespace-only input and return nil without setting
//      parseFailedOnNonEmpty (carry-forward candidate, not an error).
//   3. Attempt a format-specific parse using the hint's inputFormat.
//   4. Validate numeric ranges (month 1–12, day 1–31).
//   5. Apply month rollover detection for .dayOnly cells: if parsedDay is
//      strictly less than the day component of hint.lastResolvedDate, propose
//      month+1 (and year+1 if the current inferred month is 12).
//   6. Assemble a Date using Calendar(identifier: .gregorian) with
//      hint.contextYear as the year for all formats that do not carry an
//      explicit year.
//   7. Set parseFailedOnNonEmpty = true when a non-empty string cannot be
//      parsed, so callers can apply a confidence penalty.
//
// ─────────────────────────────────────────────────────────────────────────────
// LOCKED DECISIONS (Date Scanner tracker, Step 2)
// ─────────────────────────────────────────────────────────────────────────────
//   • Pre-processing: trim → O→0 → l→1, in that order, before any regex.
//   • Month rollover: if parsedDay < hint.lastResolvedDate.day → propose
//     month+1 (year+1 if month==12). Proposal is best-effort — if the result
//     is still a valid date it is used; otherwise the rollover is silently
//     abandoned and the original resolved date is returned.
//   • Empty rawText (after trim) = carry-forward candidate; returns nil,
//     parseFailedOnNonEmpty stays false.
//   • Failed parse on non-empty text = returns nil + parseFailedOnNonEmpty = true.
//   • .mSlashDSlashYY: year from cell text takes precedence over contextYear.
//     Two-digit year maps: 00–99 → 2000–2099 (pilots scan modern logbooks).
//   • .mmmD month abbreviations: case-insensitive, English only, first 3 chars.
//   • .dayOnly requires hint.lastResolvedDate != nil to supply month;
//     returns nil + parseFailedOnNonEmpty = true if lastResolvedDate is nil.
//   • No UIKit. No SwiftUI. Foundation only.
//   • All date assembly via Calendar(identifier: .gregorian).date(from:).
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   • DateFormatHint.swift (Step 1) — DateFormatHint, DateInputFormat
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ParseResult
// ─────────────────────────────────────────────────────────────────────────────

/// The output contract for a single DateColumnParser.parse(_:) call.
///
/// Callers inspect `resolvedDate` for the result and `parseFailedOnNonEmpty`
/// to decide whether to apply a confidence penalty in the OCR pipeline.
///
/// - `resolvedDate`:           Non-nil when a valid `Date` was assembled.
///                             Nil on empty input *or* on parse failure.
/// - `parseFailedOnNonEmpty`:  `true` only when the input was non-empty after
///                             pre-processing and no valid date could be formed.
///                             `false` for empty input (carry-forward candidate)
///                             and for successful parses.
/// - `monthRolledOver`:        `true` when month-rollover was detected and applied.
///                             Informational — callers may want to log or annotate.
public struct DateParseResult: Equatable, Sendable {

    /// The successfully resolved date, or `nil`.
    public let resolvedDate: Date?

    /// `true` when the raw text was non-empty but could not be parsed.
    /// Use this to apply a confidence penalty (e.g. ×0.4) in OCREngine.
    public let parseFailedOnNonEmpty: Bool

    /// `true` when month rollover was detected and the returned date uses
    /// the next month (or next year) rather than the naïvely parsed month.
    public let monthRolledOver: Bool

    // Designated init (public so callers can inspect in tests)
    public init(
        resolvedDate:        Date?,
        parseFailedOnNonEmpty: Bool,
        monthRolledOver:     Bool = false
    ) {
        self.resolvedDate          = resolvedDate
        self.parseFailedOnNonEmpty = parseFailedOnNonEmpty
        self.monthRolledOver       = monthRolledOver
    }

    // Convenience factory: successful parse
    static func success(_ date: Date, rolledOver: Bool = false) -> DateParseResult {
        DateParseResult(resolvedDate: date, parseFailedOnNonEmpty: false, monthRolledOver: rolledOver)
    }

    // Convenience factory: empty cell (carry-forward candidate, not an error)
    static let emptyInput = DateParseResult(resolvedDate: nil, parseFailedOnNonEmpty: false)

    // Convenience factory: non-empty text that failed to parse
    static let failed = DateParseResult(resolvedDate: nil, parseFailedOnNonEmpty: true)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DateColumnParser
// ─────────────────────────────────────────────────────────────────────────────

/// Converts a raw OCR string into a `DateParseResult` using the rules encoded
/// in the `DateFormatHint` passed at initialisation time.
///
/// Create one parser per OCR column pass (or reuse the same instance across
/// rows by updating the hint via `withHint(_:)`).
///
///     let parser = DateColumnParser(hint: hint)
///     let result = parser.parse("1/5")
///     if let date = result.resolvedDate { /* use date */ }
///     if result.parseFailedOnNonEmpty { /* apply confidence penalty */ }
///
/// `DateColumnParser` is a value type. To update the hint mid-column (e.g.
/// after the pilot corrects the format), call `withHint(_:)` which returns a
/// new instance.
public struct DateColumnParser: Sendable {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Stored properties
    // ─────────────────────────────────────────────────────────────────────

    /// The format hint that governs parsing for the current column / page.
    public let hint: DateFormatHint

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Private constants
    // ─────────────────────────────────────────────────────────────────────

    /// Gregorian calendar, no time zone, used for all date assembly.
    /// Declared as a local constant inside methods to remain Sendable-safe.
    private static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// Three-letter month abbreviations in English (index 0 = January).
    private static let monthAbbreviations: [String] = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Initialiser
    // ─────────────────────────────────────────────────────────────────────

    /// Creates a parser configured for the given hint.
    public init(hint: DateFormatHint) {
        self.hint = hint
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Functional update
    // ─────────────────────────────────────────────────────────────────────

    /// Returns a new `DateColumnParser` with the hint replaced.
    ///
    /// Used when the pilot changes the format mid-column in the review UI.
    public func withHint(_ newHint: DateFormatHint) -> DateColumnParser {
        DateColumnParser(hint: newHint)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Main entry point
    // ─────────────────────────────────────────────────────────────────────

    /// Parses `rawText` and returns a `DateParseResult`.
    ///
    /// **Pre-processing** (applied before any format-specific logic):
    ///   1. Trim leading / trailing whitespace and newlines.
    ///   2. Replace every capital-O with the digit 0.
    ///   3. Replace every lowercase-L with the digit 1.
    ///
    /// **Empty detection**: if the processed string is empty, returns
    /// `DateParseResult.emptyInput` without penalty.
    ///
    /// **Format dispatch**: delegates to a private method for each
    /// `DateInputFormat` case.
    ///
    /// **Month rollover**: applied after a successful parse for `.dayOnly`
    /// cells (see `applyRolloverIfNeeded`).
    ///
    /// - Parameter rawText: The raw string from the OCR engine's date cell.
    /// - Returns: A `DateParseResult` with resolved date and diagnostic flags.
    public func parse(_ rawText: String) -> DateParseResult {
        // ── Step 1: Pre-process ──────────────────────────────────────────
        let processed = preProcess(rawText)

        // ── Step 2: Empty-input guard ────────────────────────────────────
        guard !processed.isEmpty else {
            return .emptyInput
        }

        // ── Step 3: Format-specific parse ────────────────────────────────
        switch hint.inputFormat {
        case .mSlashD:
            return parseSeparated(processed, separator: "/", forceTwoDigitDay: false)

        case .mmSlashDD:
            return parseSeparated(processed, separator: "/", forceTwoDigitDay: true)

        case .mDashD:
            return parseSeparated(processed, separator: "-", forceTwoDigitDay: false)

        case .mDotD:
            return parseSeparated(processed, separator: ".", forceTwoDigitDay: false)

        case .mmmD:
            return parseMonthAbbrevDay(processed)

        case .mSlashDSlashYY:
            return parseSlashWithYear(processed)

        case .dayOnly:
            return parseDayOnly(processed)
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Pre-processing
    // ─────────────────────────────────────────────────────────────────────

    /// Applies the three mandatory pre-processing corrections in order:
    ///   1. Whitespace trim.
    ///   2. Capital-O → digit 0.
    ///   3. Lowercase-l → digit 1.
    private func preProcess(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "O", with: "0")   // capital-O → zero
            .replacingOccurrences(of: "l", with: "1")   // lowercase-L → one
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Format parsers
    // ─────────────────────────────────────────────────────────────────────

    /// Handles `mSlashD`, `mmSlashDD`, `mDashD`, and `mDotD`.
    ///
    /// Splits on `separator`, interprets the two components as (month, day),
    /// validates ranges, then assembles a Date using `hint.contextYear`.
    ///
    /// `forceTwoDigitDay` is set for `.mmSlashDD` to gate on the padded format;
    /// single-digit components are still accepted as many pilots omit padding.
    private func parseSeparated(
        _ text: String,
        separator: String,
        forceTwoDigitDay: Bool
    ) -> DateParseResult {
        let parts = text.components(separatedBy: separator)
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day   = Int(parts[1]),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return .failed
        }

        return assembleDateResult(
            year:  hint.contextYear,
            month: month,
            day:   day,
            applyRollover: false   // month is explicit; no rollover needed
        )
    }

    /// Handles `.mmmD` — three-letter abbreviated month name + space + day.
    ///
    /// Examples: "Jan 4", "DEC 12", "feb 3"
    /// The month token is matched case-insensitively against the 12 English
    /// abbreviations. The day token is the integer after the space.
    private func parseMonthAbbrevDay(_ text: String) -> DateParseResult {
        // Split on one or more whitespace characters
        let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count == 2 else { return .failed }

        let monthToken = parts[0].lowercased().prefix(3)
        guard
            let monthIndex = Self.monthAbbreviations.firstIndex(of: String(monthToken)),
            let day = Int(parts[1]),
            (1...31).contains(day)
        else {
            return .failed
        }

        let month = monthIndex + 1   // 1-based
        return assembleDateResult(
            year:  hint.contextYear,
            month: month,
            day:   day,
            applyRollover: false
        )
    }

    /// Handles `.mSlashDSlashYY` — e.g. "1/4/24", "12/9/23".
    ///
    /// Year is taken from the cell text. Two-digit year maps directly into
    /// the 2000–2099 century. `hint.contextYear` is **not** used for the year
    /// when the cell carries an explicit year, but it is preserved in the
    /// hint itself for carry-forward use by downstream stages.
    private func parseSlashWithYear(_ text: String) -> DateParseResult {
        let parts = text.components(separatedBy: "/")
        guard parts.count == 3,
              let month    = Int(parts[0]),
              let day      = Int(parts[1]),
              let yearRaw  = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...99).contains(yearRaw)
        else {
            return .failed
        }

        let year = 2000 + yearRaw   // modern logbooks: 00–99 → 2000–2099
        return assembleDateResult(
            year:  year,
            month: month,
            day:   day,
            applyRollover: false
        )
    }

    /// Handles `.dayOnly` — bare day number, no month or year in the cell.
    ///
    /// Requires `hint.lastResolvedDate != nil` to supply the month context.
    /// Returns `.failed` (with `parseFailedOnNonEmpty = true`) when the carry-
    /// forward state is absent, so the caller can flag this cell for review.
    ///
    /// **Rollover**: if the parsed day is strictly less than the day of
    /// `lastResolvedDate`, month rollover is applied (see
    /// `applyRolloverIfNeeded`).
    private func parseDayOnly(_ text: String) -> DateParseResult {
        guard let day = Int(text), (1...31).contains(day) else {
            return .failed
        }

        // .dayOnly requires carry-forward state for the month
        guard let lastDate = hint.lastResolvedDate else {
            // No carry-forward state yet — cannot resolve month.
            // parseFailedOnNonEmpty = true so the caller applies a confidence penalty.
            return .failed
        }

        let cal      = Self.gregorian
        let lastDay  = cal.component(.day,   from: lastDate)
        let lastMon  = cal.component(.month, from: lastDate)
        let lastYear = cal.component(.year,  from: lastDate)

        return assembleDateResult(
            year:          lastYear,
            month:         lastMon,
            day:           day,
            applyRollover: day < lastDay   // rollover candidate
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Date assembly + rollover
    // ─────────────────────────────────────────────────────────────────────

    /// Assembles a `Date` from components and optionally applies month rollover.
    ///
    /// **Rollover logic** (only when `applyRollover == true`):
    ///   If the assembled day is strictly less than the day in
    ///   `hint.lastResolvedDate`, the parser proposes moving to the next
    ///   month (and next year if the current month is December).
    ///   The proposal is accepted only if Calendar can assemble a valid date
    ///   from the rolled-over components; otherwise the original date is used.
    ///
    /// Returns `.failed` if `Calendar.date(from:)` returns nil for the
    /// base components (invalid date like Feb 30).
    private func assembleDateResult(
        year: Int,
        month: Int,
        day: Int,
        applyRollover: Bool
    ) -> DateParseResult {
        let cal = Self.gregorian

        var comps        = DateComponents()
        comps.year       = year
        comps.month      = month
        comps.day        = day
        comps.hour       = 0
        comps.minute     = 0
        comps.second     = 0

        guard let baseDate = cal.date(from: comps) else {
            // Calendar rejected the components (e.g., Feb 30) — parse failure.
            return .failed
        }

        guard applyRollover else {
            return .success(baseDate)
        }

        // ── Rollover proposal ─────────────────────────────────────────────
        let (rolledMonth, rolledYear): (Int, Int) = {
            if month == 12 {
                return (1, year + 1)
            } else {
                return (month + 1, year)
            }
        }()

        var rolledComps        = DateComponents()
        rolledComps.year       = rolledYear
        rolledComps.month      = rolledMonth
        rolledComps.day        = day
        rolledComps.hour       = 0
        rolledComps.minute     = 0
        rolledComps.second     = 0

        if let rolledDate = cal.date(from: rolledComps) {
            return .success(rolledDate, rolledOver: true)
        } else {
            // Rolled-over date is invalid (e.g., month+1 doesn't have that day).
            // Fall back to the original base date.
            return .success(baseDate, rolledOver: false)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DEBUG self-test
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG
/// Runs compile-time-safe assertions covering every `DateInputFormat` case,
/// pre-processing corrections, rollover detection, and edge-case guards.
///
/// Call from the app's DEBUG launch path before scanning begins.
/// All failures surface as hard crashes in DEBUG; eliminated in RELEASE.
public enum DateColumnParserSelfTest {

    public static func run() {

        // Helper: extract (year, month, day) from a Date
        func ymd(_ date: Date) -> (Int, Int, Int) {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(secondsFromGMT: 0)!
            return (
                c.component(.year,  from: date),
                c.component(.month, from: date),
                c.component(.day,   from: date)
            )
        }

        // Helper: build a Date at UTC midnight
        func makeDate(year: Int, month: Int, day: Int) -> Date {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(secondsFromGMT: 0)!
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return c.date(from: comps)!
        }

        // ── mSlashD: basic parse ──────────────────────────────────────────
        let hintSlashD = DateFormatHint(inputFormat: .mSlashD, contextYear: 2024)
        let parserSlashD = DateColumnParser(hint: hintSlashD)

        let r1 = parserSlashD.parse("1/5")
        precondition(r1.resolvedDate != nil,          "mSlashD '1/5' must resolve")
        precondition(!r1.parseFailedOnNonEmpty,       "mSlashD '1/5' must not set failed flag")
        let (y1, m1, d1) = ymd(r1.resolvedDate!)
        precondition(y1 == 2024, "mSlashD year should be contextYear 2024")
        precondition(m1 == 1,    "mSlashD month should be 1")
        precondition(d1 == 5,    "mSlashD day should be 5")

        // ── mSlashD: O→0 pre-processing — "O/5" becomes "0/5", month 0 is invalid → failed
        let r2 = parserSlashD.parse("O/5")
        precondition(r2.resolvedDate == nil,    "mSlashD 'O/5' → '0/5', month 0 is out of range → nil")
        precondition(r2.parseFailedOnNonEmpty,  "mSlashD 'O/5' must set failed flag (month 0 invalid)")

        // O→0 on a multi-char token: "1O/5" → "10/5"
        let r2b = parserSlashD.parse("1O/5")   // "10/5" after correction
        precondition(r2b.resolvedDate != nil, "mSlashD '1O/5' must resolve to 10/5 after O→0")
        let (_, m2b, d2b) = ymd(r2b.resolvedDate!)
        precondition(m2b == 10, "mSlashD '1O/5' corrected month should be 10")
        precondition(d2b == 5,  "mSlashD '1O/5' corrected day should be 5")

        // ── mSlashD: l→1 pre-processing correction ───────────────────────
        let r3 = parserSlashD.parse("l/5")     // lowercase-L → "1/5"
        precondition(r3.resolvedDate != nil,    "mSlashD 'l/5' must resolve after l→1 correction")
        let (_, m3, _) = ymd(r3.resolvedDate!)
        precondition(m3 == 1, "mSlashD 'l/5' corrected month should be 1")

        // ── mSlashD: invalid month 13 → nil ──────────────────────────────
        let r4 = parserSlashD.parse("13/5")
        precondition(r4.resolvedDate == nil,    "mSlashD month 13 must return nil")
        precondition(r4.parseFailedOnNonEmpty,  "mSlashD month 13 must set failed flag")

        // ── mSlashD: empty string → carry-forward, no failed flag ─────────
        let r5 = parserSlashD.parse("")
        precondition(r5.resolvedDate == nil,    "empty string must return nil")
        precondition(!r5.parseFailedOnNonEmpty, "empty string must NOT set failed flag")

        // ── mSlashD: whitespace-only → treat as empty ────────────────────
        let r6 = parserSlashD.parse("   ")
        precondition(r6.resolvedDate == nil,    "whitespace-only must return nil")
        precondition(!r6.parseFailedOnNonEmpty, "whitespace-only must NOT set failed flag")

        // ── mmSlashDD: zero-padded ────────────────────────────────────────
        let hintMM = DateFormatHint(inputFormat: .mmSlashDD, contextYear: 2023)
        let parserMM = DateColumnParser(hint: hintMM)

        let r7 = parserMM.parse("01/04")
        precondition(r7.resolvedDate != nil, "mmSlashDD '01/04' must resolve")
        let (y7, m7, d7) = ymd(r7.resolvedDate!)
        precondition(y7 == 2023 && m7 == 1 && d7 == 4, "mmSlashDD components wrong")

        // ── mDashD ───────────────────────────────────────────────────────
        let hintDash = DateFormatHint(inputFormat: .mDashD, contextYear: 2022)
        let parserDash = DateColumnParser(hint: hintDash)

        let r8 = parserDash.parse("3-14")
        precondition(r8.resolvedDate != nil, "mDashD '3-14' must resolve")
        let (_, m8, d8) = ymd(r8.resolvedDate!)
        precondition(m8 == 3 && d8 == 14, "mDashD components wrong")

        // ── mDotD ────────────────────────────────────────────────────────
        let hintDot = DateFormatHint(inputFormat: .mDotD, contextYear: 2021)
        let parserDot = DateColumnParser(hint: hintDot)

        let r9 = parserDot.parse("12.9")
        precondition(r9.resolvedDate != nil, "mDotD '12.9' must resolve")
        let (_, m9, d9) = ymd(r9.resolvedDate!)
        precondition(m9 == 12 && d9 == 9, "mDotD components wrong")

        // ── mmmD: case-insensitive month abbreviation ────────────────────
        let hintMMM = DateFormatHint(inputFormat: .mmmD, contextYear: 2024)
        let parserMMM = DateColumnParser(hint: hintMMM)

        let r10 = parserMMM.parse("Jan 4")
        precondition(r10.resolvedDate != nil, "mmmD 'Jan 4' must resolve")
        let (_, m10, d10) = ymd(r10.resolvedDate!)
        precondition(m10 == 1 && d10 == 4, "mmmD 'Jan 4' components wrong")

        let r11 = parserMMM.parse("DEC 12")
        precondition(r11.resolvedDate != nil, "mmmD 'DEC 12' must resolve")
        let (_, m11, d11) = ymd(r11.resolvedDate!)
        precondition(m11 == 12 && d11 == 12, "mmmD 'DEC 12' components wrong")

        let r12 = parserMMM.parse("feb 3")
        precondition(r12.resolvedDate != nil, "mmmD 'feb 3' must resolve")
        let (_, m12, _) = ymd(r12.resolvedDate!)
        precondition(m12 == 2, "mmmD 'feb 3' month should be 2")

        // ── mSlashDSlashYY: year from cell, ignores contextYear ───────────
        let hintYY = DateFormatHint(inputFormat: .mSlashDSlashYY, contextYear: 2020)
        let parserYY = DateColumnParser(hint: hintYY)

        let r13 = parserYY.parse("1/4/24")
        precondition(r13.resolvedDate != nil, "mSlashDSlashYY '1/4/24' must resolve")
        let (y13, m13, d13) = ymd(r13.resolvedDate!)
        precondition(y13 == 2024, "mSlashDSlashYY year from cell should be 2024, not contextYear 2020")
        precondition(m13 == 1 && d13 == 4, "mSlashDSlashYY month/day wrong")

        let r14 = parserYY.parse("12/9/23")
        precondition(r14.resolvedDate != nil, "mSlashDSlashYY '12/9/23' must resolve")
        let (y14, m14, d14) = ymd(r14.resolvedDate!)
        precondition(y14 == 2023 && m14 == 12 && d14 == 9, "mSlashDSlashYY '12/9/23' components wrong")

        // ── dayOnly: nil when no lastResolvedDate ─────────────────────────
        let hintDayOnly = DateFormatHint(inputFormat: .dayOnly, contextYear: 2024)
        let parserDayOnly = DateColumnParser(hint: hintDayOnly)

        let r15 = parserDayOnly.parse("5")
        precondition(r15.resolvedDate == nil,    "dayOnly without carry-forward state must return nil")
        precondition(r15.parseFailedOnNonEmpty,  "dayOnly without state must set failed flag")

        // ── dayOnly: resolves when lastResolvedDate is set ────────────────
        let anchor = makeDate(year: 2024, month: 3, day: 10)
        let hintDayOnlyWithState = DateFormatHint(
            inputFormat:      .dayOnly,
            contextYear:      2024,
            anchorDate:       anchor,
            lastResolvedDate: anchor
        )
        let parserDayOnlyState = DateColumnParser(hint: hintDayOnlyWithState)

        let r16 = parserDayOnlyState.parse("15")  // day 15 > last day 10 → no rollover
        precondition(r16.resolvedDate != nil,    "dayOnly '15' with state must resolve")
        precondition(!r16.monthRolledOver,       "dayOnly '15' should not roll over (15 > 10)")
        let (y16, m16, d16) = ymd(r16.resolvedDate!)
        precondition(y16 == 2024 && m16 == 3 && d16 == 15, "dayOnly '15' components wrong")

        // ── dayOnly: month rollover when parsedDay < lastResolvedDay ──────
        let r17 = parserDayOnlyState.parse("3")   // day 3 < last day 10 → rollover to April
        precondition(r17.resolvedDate != nil,   "dayOnly '3' with rollover must resolve")
        precondition(r17.monthRolledOver,        "dayOnly '3' (< lastDay 10) must trigger rollover")
        let (y17, m17, d17) = ymd(r17.resolvedDate!)
        precondition(y17 == 2024 && m17 == 4 && d17 == 3, "dayOnly rollover should be April 3 2024")

        // ── dayOnly: year rollover when month is December ─────────────────
        let decDate = makeDate(year: 2024, month: 12, day: 20)
        let hintDec = DateFormatHint(
            inputFormat:      .dayOnly,
            contextYear:      2024,
            anchorDate:       decDate,
            lastResolvedDate: decDate
        )
        let parserDec = DateColumnParser(hint: hintDec)

        let r18 = parserDec.parse("5")   // day 5 < last day 20 in December → Jan 2025
        precondition(r18.resolvedDate != nil,  "dayOnly Dec→Jan rollover must resolve")
        precondition(r18.monthRolledOver,       "dayOnly Dec→Jan must flag monthRolledOver")
        let (y18, m18, d18) = ymd(r18.resolvedDate!)
        precondition(y18 == 2025 && m18 == 1 && d18 == 5,
                     "dayOnly Dec→Jan rollover should produce Jan 5 2025, got \(y18)/\(m18)/\(d18)")

        // ── mSlashD: invalid day 0 → nil ─────────────────────────────────
        let r19 = parserSlashD.parse("1/0")
        precondition(r19.resolvedDate == nil,   "day 0 must return nil")
        precondition(r19.parseFailedOnNonEmpty, "day 0 must set failed flag")

        // ── mSlashD: day 32 → nil ─────────────────────────────────────────
        let r20 = parserSlashD.parse("1/32")
        precondition(r20.resolvedDate == nil,   "day 32 must return nil")
        precondition(r20.parseFailedOnNonEmpty, "day 32 must set failed flag")

        // ── withHint returns new parser with updated hint ─────────────────
        let updatedParser = parserSlashD.withHint(hintDash)
        precondition(updatedParser.hint.inputFormat == .mDashD,
                     "withHint must update inputFormat")
        precondition(parserSlashD.hint.inputFormat == .mSlashD,
                     "withHint must preserve original parser (value semantics)")

        // All assertions passed.
    }
}
#endif
