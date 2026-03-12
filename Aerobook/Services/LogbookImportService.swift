// LogbookImportService.swift
// AeroBook
//
// CSV import pipeline for all text-based logbook formats:
//   ForeFlight · LogTen Pro · Jeppesen CSV · ASA CSV · Garmin Pilot · Generic CSV
//
// ── TYPE DECLARATIONS ──────────────────────────────────────────────────────
// LogbookImportFormat, ParsedFlightRecord, LogbookImportResult are declared
// ONLY in ImportModels.swift.  Do NOT re-declare them here.
//
// ── XLSX ───────────────────────────────────────────────────────────────────
// .xlsx / .xls files are handled exclusively by ExcelImporter (CoreXLSX).
// parseFile() throws .unsupportedFileType for those extensions so that
// ImportView.handleFilePicked() can route them to ExcelImporter.parse().
// ───────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Import Error

enum LogbookImportError: LocalizedError {
    case unsupportedFileType
    case emptyFile
    case noDataRows
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Use the 'Excel / XLSX' format option to import .xlsx files."
        case .emptyFile:
            return "The selected file appears to be empty."
        case .noDataRows:
            return "No flight data rows were found in the file."
        case .parseFailure(let msg):
            return "Parse error: \(msg)"
        }
    }
}

// MARK: - Logbook Import Service

final class LogbookImportService {

    static let shared = LogbookImportService()
    private init() {}

    // MARK: - Public API

    /// Parse a CSV/text logbook file.
    /// For .xlsx/.xls, throws `.unsupportedFileType` — caller must use ExcelImporter instead.
    func parseFile(at url: URL, format: LogbookImportFormat) throws -> LogbookImportResult {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xls":
            throw LogbookImportError.unsupportedFileType
        default:
            return try parseCSV(at: url, format: format)
        }
    }

    /// Commit approved records to the database using a single transaction.
    func commitRecords(_ records: [ParsedFlightRecord],
                       completion: @escaping (_ inserted: Int, _ failed: Int) -> Void) {
        let approved = records.filter { $0.isSelected }
        guard !approved.isEmpty else { completion(0, 0); return }

        let dicts = approved.map { recordToFlightData($0) }
        DatabaseManager.shared.addFlightsBatch(dicts) { inserted, failed in
            completion(inserted, failed)
        }
    }

    // MARK: - CSV Parser

    private func parseCSV(at url: URL, format: LogbookImportFormat) throws -> LogbookImportResult {
        let raw: String
        do {
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                raw = utf8
            } else {
                raw = try String(contentsOf: url, encoding: .isoLatin1)
            }
        } catch {
            throw LogbookImportError.parseFailure(error.localizedDescription)
        }

        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogbookImportError.emptyFile
        }

        var lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .controlCharacters) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { throw LogbookImportError.noDataRows }

        // ForeFlight CSVs start with a "ForeFlight Logbook Import" preamble
        if lines.first?.hasPrefix("ForeFlight") == true { lines.removeFirst() }

        let (headers, dataStartIndex) = detectHeaders(lines: lines, format: format)
        guard dataStartIndex < lines.count else { throw LogbookImportError.noDataRows }

        let dataLines = Array(lines[dataStartIndex...])
        guard !dataLines.isEmpty else { throw LogbookImportError.noDataRows }

        var records:        [ParsedFlightRecord] = []
        var globalWarnings: [String]             = []
        var skipped = 0

        for line in dataLines {
            let cells = parseCSVLine(line)
            guard cells.count > 3 else { skipped += 1; continue }

            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < cells.count {
                row[header] = cells[i]
            }

            let (record, warnings) = buildRecord(from: row, sourceFormat: format.rawValue)

            if record.date.isEmpty && record.totalTime == 0 {
                skipped += 1; continue
            }

            var r = record
            r.importWarnings = warnings
            records.append(r)
        }

        guard !records.isEmpty else { throw LogbookImportError.noDataRows }

        return LogbookImportResult(
            records:        records,
            warnings:       globalWarnings,
            skippedCount:   skipped,
            detectedFormat: format
        )
    }

    // MARK: - Header Detection

    private func detectHeaders(lines: [String],
                                format: LogbookImportFormat) -> ([String], Int) {
        let keywords = ["date", "aircraft", "ident", "tail", "route", "total",
                        "pic", "dual", "night", "cross", "instrument", "remark",
                        "landing", "approach", "from", "to", "registration"]

        for i in 0..<min(5, lines.count) {
            let lower      = lines[i].lowercased()
            let matchCount = keywords.filter { lower.contains($0) }.count
            guard matchCount >= 2 else { continue }

            if i + 1 < lines.count {
                let nextLower  = lines[i + 1].lowercased()
                let nextMatch  = keywords.filter { nextLower.contains($0) }.count
                let nextCells  = parseCSVLine(lines[i + 1])
                let emptyCells = nextCells.filter {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty
                }.count

                if nextMatch >= 1 || emptyCells < nextCells.count / 2 {
                    let merged     = mergeDoubleHeaders(parseCSVLine(lines[i]),
                                                        parseCSVLine(lines[i + 1]))
                    let normalised = merged.map { normalizeColumnKey($0) }
                    return (normalised, i + 2)
                }
            }

            let normalised = parseCSVLine(lines[i]).map { normalizeColumnKey($0) }
            return (normalised, i + 1)
        }

        let normalised = parseCSVLine(lines[0]).map { normalizeColumnKey($0) }
        return (normalised, 1)
    }

    // MARK: - Double-Row Header Merge

    private func mergeDoubleHeaders(_ row1: [String], _ row2: [String]) -> [String] {
        (0..<max(row1.count, row2.count)).map { i in
            let top = i < row1.count ? row1[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let bot = i < row2.count ? row2[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            switch (top.isEmpty, bot.isEmpty) {
            case (true,  true):  return "col_\(i)"
            case (false, true):  return top
            case (true,  false): return bot
            case (false, false): return "\(top) \(bot)"
            }
        }
    }

    // MARK: - Column Key Normalizer

    func normalizeColumnKey(_ raw: String) -> String {
        let c = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")  // BOM

        if c == "date" || c.contains("flight date") || c.contains("date of flight") { return "date" }

        if c.contains("aircraft type") || c.contains("make and model") ||
           c.contains("make/model") || c.contains("type of aircraft") ||
           (c.contains("type") && !c.contains("total") && !c.contains("piloting")) { return "aircraft_type" }
        if c.contains("aircraft ident") || c.contains("tail number") ||
           c.contains("tail no") || c.contains("registration") ||
           c == "ident" || c == "n-number" || c == "n number" { return "aircraft_ident" }
        if c.contains("aircraft category") || c == "category" { return "aircraft_category" }
        if c.contains("aircraft class") || c == "class"       { return "aircraft_class" }

        if c == "route" || c.contains("route of flight") || c.contains("airports") { return "route" }
        if c == "from" || c.contains("departure") || c.contains("origin") ||
           c.contains("dept airport") || c.contains("from airport") { return "route_from" }
        if (c == "to" || c.contains("destination") || c.contains("dest airport") ||
            c.contains("to airport")) && !c.contains("total") { return "route_to" }

        if c == "total" || c == "total time" || c == "total flight time" ||
           c == "total flight duration" || c == "duration" ||
           c.contains("total time of flight") || c == "flight time" ||
           c.contains("total duration") { return "total_time" }

        if c == "pic" || c == "p.i.c" || c == "p.i.c." ||
           c.contains("pilot in command") || c.contains("pilot-in-command") { return "pic" }
        if c == "sic" || c == "s.i.c" || c == "co-pilot" ||
           c.contains("second in command") || c.contains("second-in-command") { return "sic" }
        if c == "solo" || c.contains("solo time") || c.contains("solo flight") { return "solo" }
        if c.contains("dual rec") || c == "dual received" || c == "dual recv" || c == "student" { return "dual_received" }
        if c.contains("as instructor") || c == "dual given" || c.contains("cfi time") ||
           c.contains("flight instructor") || c == "instructor" { return "dual_given" }
        if c.contains("cross country") || c.contains("cross-country") ||
           c == "xc" || c == "x/c" || c == "cc" { return "cross_country" }

        if c == "night" || c.contains("night time") || c.contains("conditions night") ||
           c == "night flying" { return "night" }
        if c == "actual instrument" || c.contains("actual inst") || c == "imc" ||
           c.contains("instrument actual") || c.contains("conditions actual") || c == "actual" { return "instrument_actual" }
        if c.contains("simulated inst") || c.contains("hood") || c == "sim inst" ||
           c.contains("instrument sim") || c == "foggles" || c == "sim imc" ||
           c.contains("conditions sim") { return "instrument_simulated" }
        if c == "instrument" || c.contains("instrument time") { return "instrument_actual" }

        if c.contains("flight sim") || c.contains("simulator") || c == "ftd" ||
           c == "pcatd" || c == "atd" || c == "ffs" || c == "sim" ||
           c.contains("ground trainer") || c.contains("ground training") { return "flight_sim" }

        if (c.contains("landing") || c.contains("ldg")) && c.contains("night") { return "landings_night" }
        if c.contains("landing") || c == "ldg" || c == "ldgs" || c == "landings" { return "landings_day" }
        if c.contains("takeoff") || c.contains("take-off") || c.contains("take off") ||
           c == "t/o" || (c == "to" && c.count == 2) { return "takeoffs" }
        if c.contains("approach") || c == "app" || c == "apps" || c == "iap" { return "approaches_count" }
        if c.contains("hold") { return "holds_count" }

        if c == "remarks" || c.contains("comment") || c.contains("lesson") ||
           c.contains("note") || c == "endorsement" { return "remarks" }
        if c.contains("instructor name") || c.contains("cfi name") { return "instructor_name" }

        return c.replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Record Builder

    private func buildRecord(from row: [String: String],
                              sourceFormat: String) -> (ParsedFlightRecord, [String]) {
        var r        = ParsedFlightRecord()
        var warnings = [String]()
        r.sourceFormat = sourceFormat

        r.date = normaliseDate(row["date"] ?? row["date_of_flight"] ?? "")

        r.aircraftType  = row["aircraft_type"] ?? row["aircraft"] ?? ""
        r.aircraftIdent = (row["aircraft_ident"] ?? row["registration"] ?? row["tail_number"] ?? "").uppercased()
        r.aircraftCategory = row["aircraft_category"] ?? "Airplane"
        r.aircraftClass    = row["aircraft_class"]    ?? "SEL"

        let from = row["route_from"] ?? ""
        let to   = row["route_to"]   ?? ""
        r.routeFrom = from
        r.routeTo   = to
        r.route = !from.isEmpty || !to.isEmpty
            ? [from, to].filter { !$0.isEmpty }.joined(separator: " - ")
            : row["route"] ?? ""

        r.totalTime           = parseHours(row["total_time"] ?? row["total"] ?? row["flight_time"] ?? row["duration"])
        r.pic                 = parseHours(row["pic"] ?? row["pilot_in_command"])
        r.sic                 = parseHours(row["sic"] ?? row["second_in_command"] ?? row["co-pilot"])
        r.solo                = parseHours(row["solo"])
        r.dualReceived        = parseHours(row["dual_received"] ?? row["dual_recv"] ?? row["student"])
        r.dualGiven           = parseHours(row["dual_given"] ?? row["as_instructor"] ?? row["instructor"] ?? row["cfi_time"])
        r.crossCountry        = parseHours(row["cross_country"] ?? row["xc"] ?? row["x/c"])
        r.night               = parseHours(row["night"] ?? row["night_time"] ?? row["conditions_night"])
        r.instrumentActual    = parseHours(row["instrument_actual"] ?? row["actual_instrument"] ?? row["imc"] ?? row["actual"] ?? row["instrument"])
        r.instrumentSimulated = parseHours(row["instrument_simulated"] ?? row["simulated_instrument"] ?? row["hood"] ?? row["sim_imc"] ?? row["foggles"])
        r.flightSim           = parseHours(row["flight_sim"] ?? row["simulator"] ?? row["ftd"] ?? row["ground_trainer"])

        if r.totalTime == 0 {
            let inferred = r.pic + r.sic + r.dualReceived
            if inferred > 0 {
                r.totalTime = inferred
                warnings.append("Total time inferred from PIC + SIC + Dual (\(String(format: "%.1f", inferred))h)")
            }
        }

        r.landingsDay     = parseInt(row["landings_day"]    ?? row["ldg"] ?? row["landings"])
        r.landingsNight   = parseInt(row["landings_night"])
        r.approachesCount = parseInt(row["approaches_count"] ?? row["approaches"] ?? row["app"])
        r.holdsCount      = parseInt(row["holds_count"]     ?? row["holds"])
        r.takeoffs        = parseInt(row["takeoffs"]        ?? row["take-offs"])
        r.remarks         = row["remarks"] ?? row["comments"] ?? row["lesson"] ?? ""

        if r.date.isEmpty   { warnings.append("No flight date found") }
        if r.totalTime == 0 { warnings.append("No flight time found") }
        if r.totalTime > 0 && r.pic == 0 && r.dualReceived == 0 && r.solo == 0 {
            warnings.append("No piloting time type assigned (PIC/Dual/Solo)")
        }
        return (r, warnings)
    }

    // MARK: - Hour Parser

    func parseHours(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "-", raw != "--", raw != "N/A" else { return 0 }
        if raw.contains(":") {
            let parts = raw.components(separatedBy: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { return parts[0] + parts[1] / 60 }
            if parts.count == 3 { return parts[0] + parts[1] / 60 + parts[2] / 3600 }
        }
        if let v = Double(raw) { return v }
        let tokens = raw.split(separator: " ").compactMap { Double($0) }
        if tokens.count == 2 { return tokens[0] + tokens[1] / 10 }
        return Double(raw.filter { $0.isNumber || $0 == "." }) ?? 0
    }

    // MARK: - Int Parser

    private func parseInt(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        if let d = Double(raw) { return Int(d) }
        return Int(raw.filter { $0.isNumber }) ?? 0
    }

    // MARK: - Date Normaliser

    func normaliseDate(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return s }
        let fmts = [
            "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy",
            "yyyy/MM/dd", "dd-MM-yyyy", "d-M-yyyy",
            "dd.MM.yyyy", "d.M.yyyy", "dd MMM yyyy", "d MMM yyyy",
            "MMM d, yyyy", "MMM dd, yyyy", "MM-dd-yyyy"
        ]
        let df  = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let out = DateFormatter(); out.dateFormat = "yyyy-MM-dd"
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return out.string(from: d) }
        }
        return s
    }

    // MARK: - RFC 4180 CSV Line Parser

    func parseCSVLine(_ line: String) -> [String] {
        var result   = [String]()
        var current  = ""
        var inQuotes = false
        let chars    = Array(line)
        var i        = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { current.append("\""); i += 2; continue }
                    inQuotes = false
                } else { current.append(ch) }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":  result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                default:   current.append(ch)
                }
            }
            i += 1
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    // MARK: - Record → Database Dictionary

    private func recordToFlightData(_ r: ParsedFlightRecord) -> [String: Any] {
        [
            "date":                  r.date,
            "aircraft_type":         r.aircraftType,
            "aircraft_ident":        r.aircraftIdent,
            "aircraft_category":     r.aircraftCategory,
            "aircraft_class":        r.aircraftClass,
            "route":                 r.route,
            "total_time":            r.totalTime,
            "pic":                   r.pic,
            "sic":                   r.sic,
            "solo":                  r.solo,
            "dual_received":         r.dualReceived,
            "dual_given":            r.dualGiven,
            "cross_country":         r.crossCountry,
            "night":                 r.night,
            "instrument_actual":     r.instrumentActual,
            "instrument_simulated":  r.instrumentSimulated,
            "flight_sim":            r.flightSim,
            "takeoffs":              r.takeoffs,
            "landings_day":          r.landingsDay,
            "landings_night":        r.landingsNight,
            "approaches_count":      r.approachesCount,
            "holds_count":           r.holdsCount,
            "nav_tracking":          false,
            "remarks":               r.remarks,
            "is_legacy_import":      true,
            "legacy_signature_path": ""
        ]
    }
}
