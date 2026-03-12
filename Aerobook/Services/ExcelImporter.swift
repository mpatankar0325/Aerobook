// ExcelImporter.swift
// AeroBook
//
// Parses Logbook_App_V1.xlsx (and any compatible Jeppesen/ASA-style workbook)
// using the CoreXLSX library (SPM: https://github.com/CoreOffice/CoreXLSX 0.14.x).
//
// ── TYPES ──────────────────────────────────────────────────────────────────
// ParsedFlightRecord, LogbookImportResult, LogbookImportFormat are declared
// ONLY in ImportModels.swift.  Do NOT re-declare them here.
// ───────────────────────────────────────────────────────────────────────────

import Foundation
import CoreXLSX

// MARK: - Import Error

enum ExcelImportError: LocalizedError {
    case fileAccessDenied
    case cannotOpenWorkbook(String)
    case noSheetsFound
    case insufficientRows
    case noDataRows

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied:
            return "AeroBook cannot access this file. Please use the document picker and select a local file."
        case .cannotOpenWorkbook(let detail):
            return "Could not open workbook: \(detail)"
        case .noSheetsFound:
            return "The selected file contains no worksheets."
        case .insufficientRows:
            return "The file appears to have no data rows beneath the header."
        case .noDataRows:
            return "No valid flight entries were found after skipping the header rows."
        }
    }
}

// MARK: - ExcelImporter

enum ExcelImporter {

    // MARK: Public API

    static func parse(url: URL) throws -> LogbookImportResult {

        let localURL = try copyToTemp(url: url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        guard let file = XLSXFile(filepath: localURL.path) else {
            throw ExcelImportError.cannotOpenWorkbook(localURL.lastPathComponent)
        }

        let paths = try file.parseWorksheetPaths()
        guard let firstPath = paths.first else { throw ExcelImportError.noSheetsFound }
        let worksheet = try file.parseWorksheet(at: firstPath)

        // nil when the workbook has no shared strings table (all inline / numeric)
        let strings = try? file.parseSharedStrings()

        let allRows = worksheet.data?.rows ?? []
        guard allRows.count >= 3 else { throw ExcelImportError.insufficientRows }

        let sortedRows = allRows.sorted { $0.reference < $1.reference }

        // Build merged double-row header (rows 1 + 2)
        let h1 = cellTextByCol(sortedRows[0], strings: strings)
        let h2 = cellTextByCol(sortedRows[1], strings: strings)

        let colCount = max(
            (sortedRows[0].cells.compactMap { colIndex(of: $0.reference) }.max() ?? 0) + 1,
            (sortedRows[1].cells.compactMap { colIndex(of: $0.reference) }.max() ?? 0) + 1
        )

        var mergedHeaders: [Int: String] = [:]
        for col in 0..<colCount {
            let top = h1[col] ?? ""
            let bot = h2[col] ?? ""
            let combined: String
            switch (top.isEmpty, bot.isEmpty) {
            case (true,  true):  combined = ""
            case (false, true):  combined = top
            case (true,  false): combined = bot
            case (false, false): combined = "\(top) \(bot)"
            }
            mergedHeaders[col] = normaliseHeader(combined)
        }

        let dataRows = Array(sortedRows.dropFirst(2))
        guard !dataRows.isEmpty else { throw ExcelImportError.noDataRows }

        var staged: [[String: String]] = []
        for row in dataRows {
            let cellValues = cellTextByCol(row, strings: strings)
            guard cellValues.values.contains(where: { !$0.isEmpty }) else { continue }
            var record: [String: String] = [:]
            for (col, dbKey) in mergedHeaders {
                guard !dbKey.isEmpty, dbKey != "_skip" else { continue }
                record[dbKey] = cellValues[col] ?? ""
            }
            staged.append(record)
        }

        guard !staged.isEmpty else { throw ExcelImportError.noDataRows }

        var records: [ParsedFlightRecord] = []
        var globalWarnings: [String] = []
        var skipped = 0

        for dict in staged {
            let (record, rowWarnings) = buildRecord(from: dict)
            if record.date.isEmpty && record.totalTime == 0 && record.aircraftIdent.isEmpty {
                skipped += 1; continue
            }
            var r = record
            r.importWarnings = rowWarnings
            records.append(r)
        }

        guard !records.isEmpty else { throw ExcelImportError.noDataRows }

        printPreview(records)

        return LogbookImportResult(
            records:        records,
            warnings:       globalWarnings,
            skippedCount:   skipped,
            detectedFormat: .excel
        )
    }

    // MARK: Header Normalisation

    private static func normaliseHeader(_ raw: String) -> String {
        let c = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespaces)

        guard !c.isEmpty else { return "_skip" }

        switch true {
        case c == "date" || c.contains("flight date"):
            return "date"
        case c.contains("aircraft type") || (c.contains("make") && c.contains("model")):
            return "aircraft_type"
        case c.contains("aircraft ident") || c.contains("tail") || c.contains("registration"):
            return "aircraft_ident"
        case c.contains("route") && c.contains("from"), c == "from":
            return "route_from"
        case c == "to":
            return "route_to"
        case c.contains("route"):
            return "route"
        case c.contains("inst app") || c.contains("approaches") || c == "nr inst app":
            return "approaches_count"
        case c.contains("remark") || c.contains("endorsement"):
            return "remarks"
        case (c.contains("t/o") && !c.contains("night")) || c == "nr t/o" || c == "takeoffs":
            return "takeoffs"
        case (c.contains("ldg") && !c.contains("night")) || c == "nr ldg" || c == "landings day":
            return "landings_day"
        case c.contains("night") && (c.contains("ldg") || c.contains("landing")):
            return "landings_night"
        case c.contains("night") && c.contains("t/o"):
            return "_skip"
        case c.contains("single") && c.contains("engine"):
            return "_sel_hours"
        case c.contains("multi") && c.contains("engine"):
            return "_mel_hours"
        case c.contains("and class"),
             c.contains("aircraft category") && !c.contains("single") && !c.contains("multi"):
            return "_skip"
        case c.contains("night") && !c.contains("t/o") && !c.contains("ldg") && !c.contains("landing"):
            return "night"
        case c.contains("actual") && c.contains("instrument"):
            return "instrument_actual"
        case c.contains("simulated") || c.contains("hood"):
            return "instrument_simulated"
        case c.contains("flight sim") || c.contains("simulator") || c.contains("ftd"):
            return "flight_sim"
        case c.contains("cross") && c.contains("country"):
            return "cross_country"
        case c.contains("flight instructor") || c.contains("as flight") ||
             c.contains("dual given") || c.contains("cfi"):
            return "dual_given"
        case c.contains("dual") && c.contains("received"):
            return "dual_received"
        case c == "solo" || c.contains("solo time"):
            return "solo"
        case c.contains("pilot in command") || c.contains("p.i.c") || c == "pic":
            return "pic"
        case c.contains("total") && (c.contains("duration") || c.contains("flight") || c.contains("time")):
            return "total_time"
        default:
            return "_skip"
        }
    }

    // MARK: Record Builder

    private static func buildRecord(from dict: [String: String]) -> (ParsedFlightRecord, [String]) {
        var r = ParsedFlightRecord()
        var warnings: [String] = []

        r.date = normaliseDate(dict["date"] ?? "")
        r.aircraftType  = (dict["aircraft_type"]  ?? "").trimmingCharacters(in: .whitespaces)
        r.aircraftIdent = (dict["aircraft_ident"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()

        let from = (dict["route_from"] ?? "").trimmingCharacters(in: .whitespaces)
        let to   = (dict["route_to"]   ?? "").trimmingCharacters(in: .whitespaces)
        r.routeFrom = from
        r.routeTo   = to
        r.route = (!from.isEmpty || !to.isEmpty)
            ? [from, to].filter { !$0.isEmpty }.joined(separator: " - ")
            : (dict["route"] ?? "").trimmingCharacters(in: .whitespaces)

        let selHours = parseDouble(dict["_sel_hours"])
        let melHours = parseDouble(dict["_mel_hours"])
        if melHours > 0      { r.aircraftClass = "AMEL"; r.aircraftCategory = "Airplane" }
        else if selHours > 0 { r.aircraftClass = "ASEL"; r.aircraftCategory = "Airplane" }

        r.totalTime           = parseDouble(dict["total_time"])
        r.pic                 = parseDouble(dict["pic"])
        r.sic                 = parseDouble(dict["sic"])
        r.solo                = parseDouble(dict["solo"])
        r.dualReceived        = parseDouble(dict["dual_received"])
        r.dualGiven           = parseDouble(dict["dual_given"])
        r.crossCountry        = parseDouble(dict["cross_country"])
        r.night               = parseDouble(dict["night"])
        r.instrumentActual    = parseDouble(dict["instrument_actual"])
        r.instrumentSimulated = parseDouble(dict["instrument_simulated"])
        r.flightSim           = parseDouble(dict["flight_sim"])

        if r.totalTime == 0 {
            let inferred = r.pic + r.sic + r.dualReceived
            if inferred > 0 {
                r.totalTime = inferred
                warnings.append("Total time inferred from PIC + SIC + Dual (\(String(format: "%.1f", inferred))h)")
            }
        }

        r.landingsDay     = parseInt(dict["landings_day"])
        r.landingsNight   = parseInt(dict["landings_night"])
        r.approachesCount = parseInt(dict["approaches_count"])
        r.takeoffs        = parseInt(dict["takeoffs"])
        r.remarks         = (dict["remarks"] ?? "").trimmingCharacters(in: .whitespaces)

        if r.date.isEmpty   { warnings.append("No date found for this row") }
        if r.totalTime == 0 { warnings.append("No flight time found") }
        if r.totalTime > 0 && r.pic == 0 && r.dualReceived == 0 && r.solo == 0 {
            warnings.append("No piloting time type (PIC / Dual / Solo) recorded")
        }
        return (r, warnings)
    }

    // MARK: CoreXLSX Cell Helpers

    private static func cellTextByCol(_ row: Row, strings: SharedStrings?) -> [Int: String] {
        var result: [Int: String] = [:]
        for cell in row.cells {
            guard let col = colIndex(of: cell.reference) else { continue }
            result[col] = cellString(cell, strings: strings)
        }
        return result
    }

    private static func colIndex(of reference: CellReference) -> Int? {
        let letters = reference.column.value.uppercased()
        guard !letters.isEmpty else { return nil }
        var index = 0
        for char in letters {
            guard let ascii = char.asciiValue else { return nil }
            index = index * 26 + Int(ascii - 65) + 1
        }
        return index - 1
    }

    /// Convert a CoreXLSX Cell to a plain String.
    ///
    /// CoreXLSX 0.14 CellType cases that actually exist:
    ///   .sharedString  — integer index into SharedStrings table
    ///   .formula       — formula; .value holds the cached result string
    ///   .number        — plain numeric
    ///   .date          — ISO date string
    ///   .error         — formula error (#REF! etc.)
    ///   nil            — numeric / formula result (no explicit type attr)
    ///
    /// Notes:
    ///   • `.inlineString` and `.boolean` are NOT cases in CoreXLSX 0.14.
    ///   • `Cell.stringValue(_: SharedStrings) -> String?` is a METHOD that
    ///     takes a NON-OPTIONAL SharedStrings argument.  It handles inlineStr
    ///     cells internally.  We must not call it with `if let` on the method
    ///     reference — we must call it with a real SharedStrings value and
    ///     then optional-bind the String? result.
    private static func cellString(_ cell: Cell, strings: SharedStrings?) -> String {

        // ── Shared string ─────────────────────────────────────────────────────
        if cell.type == .sharedString {
            guard let raw = cell.value,
                  let idx = Int(raw),
                  let ss  = strings,
                  idx < ss.items.count
            else { return cell.value ?? "" }
            let item = ss.items[idx]
            return item.text ?? item.richText.map { $0.text ?? "" }.joined()
        }

        // Inline string: CoreXLSX 0.14 exposes these via `cell.inlineString`,
                // a plain Optional<XSSFRichString> property. We avoid cell.stringValue(_:)
                // entirely — its signature varies across patch versions and has caused
                // repeated "extraneous argument label" compiler errors.
                if let inline = cell.inlineString {
                    // Before (broken)
                    //return inline.text ?? inline.richText.map { $0.text ?? "" }.joined()

                    // After (fixed)
                    return inline.text ?? ""
                }
        
        // ── Numeric / date serial / formula result ────────────────────────────
        guard let raw = cell.value, !raw.isEmpty else { return "" }

        // Excel date serials for 2000–2030 are roughly 36526–47482.
        // A single flight's hours are always < 25, so anything > 1000 is a date.
        if let serial = Double(raw), serial > 1000 {
            return excelSerialToDateString(serial) ?? raw
        }

        return raw
    }

    // MARK: Value Parsers

    private static func parseDouble(_ raw: String?) -> Double {
        guard let s = raw?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty, s != "-", s != "–" else { return 0 }
        if let v = Double(s) { return v }
        if s.contains(":") {
            let parts = s.components(separatedBy: ":").compactMap { Double($0) }
            if parts.count == 2 { return parts[0] + parts[1] / 60.0 }
        }
        return 0
    }

    private static func parseInt(_ raw: String?) -> Int {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        if let d = Double(s) { return Int(d) }
        return Int(s.filter { $0.isNumber }) ?? 0
    }

    private static func normaliseDate(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return s }
        let formats = [
            "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
            "dd-MM-yyyy", "d-M-yyyy", "dd.MM.yyyy",
            "MMM d, yyyy", "MMM dd, yyyy", "dd MMM yyyy", "yyyy/MM/dd"
        ]
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        let writer = DateFormatter(); writer.dateFormat = "yyyy-MM-dd"
        for fmt in formats {
            parser.dateFormat = fmt
            if let d = parser.date(from: s) { return writer.string(from: d) }
        }
        return s
    }

    private static func excelSerialToDateString(_ serial: Double) -> String? {
        // Excel epoch: Dec 31 1899.  Unix epoch: Jan 1 1970.  Offset = 25569 days.
        // Excel has a 1900 leap-year bug — correct by subtracting 1 for serials > 59.
        let corrected = serial > 59 ? serial - 1 : serial
        let date = Date(timeIntervalSince1970: (corrected - 25569) * 86400)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    // MARK: Security-Scoped Resource / Temp Copy

    private static func copyToTemp(url: URL) throws -> URL {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            throw ExcelImportError.fileAccessDenied
        }
        return tmp
    }

    // MARK: Console Preview

    private static func printPreview(_ records: [ParsedFlightRecord]) {
        let n = min(3, records.count)
        print("\n=== ExcelImporter: first \(n) of \(records.count) flights ===")
        for (i, r) in records.prefix(n).enumerated() {
            print("[\(i+1)] \(r.date)  \(r.aircraftIdent) [\(r.aircraftType)]  route=\(r.route)" +
                  "  total=\(String(format:"%.1f",r.totalTime))h" +
                  (r.importWarnings.isEmpty ? "" : "  ⚠ \(r.importWarnings.joined(separator:", "))"))
        }
        print("===\n")
    }
}
