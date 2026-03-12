// LogbookImportEngine.swift
// Aerobook
//
// Low-level CSV + XLSX parsing engine.  using zip and xml which is prone to errors, replace it with easy logics.
// Public types (LogbookImportFormat, ParsedFlightRecord, LogbookImportResult,
// LogbookImportService) live in LogbookImportService.swift — NOT here.

import Foundation
import SwiftUI
import Combine

// MARK: ═══════════════════════════════════════════════════════════════════
// MARK: - EngineImportFormat  (internal to LogbookImportEngine)
// ═══════════════════════════════════════════════════════════════════════

enum EngineImportFormat: String, CaseIterable {
    case foreFlight  = "ForeFlight"
    case logTenPro   = "LogTen Pro"
    case jeppesen    = "Jeppesen/ASA"
    case garminPilot = "Garmin Pilot"
    case csv         = "Generic CSV"
    case excel       = "Excel / XLSX"

    static func detect(headers: [String]) -> EngineImportFormat {
        let lower = headers.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("flight_flightdate") })                          { return .logTenPro   }
        if lower.contains(where: { $0.contains("aircraftid") && !$0.contains("identifier") })  { return .foreFlight  }
        if lower.contains(where: { $0.contains("aircraftidentifier") })                         { return .garminPilot }
        if lower.contains(where: { $0.contains("flight date") || $0.contains("dual received") }) { return .jeppesen  }
        return .csv
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════
// MARK: - EngineFlightRow  (internal untyped row from the CSV parser)
// ═══════════════════════════════════════════════════════════════════════

struct EngineFlightRow: Identifiable {
    let id        = UUID()
    var fields:   [String: String]
    var warnings: [String] = []
    var isSelected = true
}

// MARK: ═══════════════════════════════════════════════════════════════════
// MARK: - Column aliases  (100+ column name variations → DB field names)
// ═══════════════════════════════════════════════════════════════════════

private let columnAliases: [String: [String]] = [
    "date": [
        "date","flight date","flightdate","flight_flightdate","departure date",
        "log date","fly date","date of flight",
    ],
    "aircraft_type": [
        "aircraft type","aircrafttype","type","make/model","aircraft make","model",
        "type/model","flight_aircrafttype","plane type",
    ],
    "aircraft_ident": [
        "aircraft ident","aircraftid","aircraftidentifier","n-number","tail number",
        "registration","ident","flight_selectedaircraftid","tailnumber","n number",
        "aircraft registration",
    ],
    "aircraft_category": [
        "aircraft category","category","category and class","flight_aircraftcategory",
    ],
    "aircraft_class": [
        "aircraft class","class","flight_aircraftclass",
    ],
    "route": [
        "route","route of flight","from/to","departure/arrival","flight route",
        "flight_route","dep/arr","waypoints",
    ],
    "total_time": [
        "total time","totaltime","total flight time","flight time","duration",
        "flight_totaltime","total hrs","total hours","ttime","tot time",
        "total duration","flightduration",
    ],
    "pic": [
        "pic","pilot in command","pic time","pictime","flight_pic",
        "pic hours","pilot in command time","command time","p1",
    ],
    "sic": [
        "sic","second in command","sictime","flight_sic","co-pilot","copilot",
        "second in command time","p2",
    ],
    "solo": [
        "solo","solo time","flight_solo","solo flight time","solo hours",
    ],
    "dual_received": [
        "dual received","dual rcvd","dual","dualreceived","flight_dualreceived",
        "instruction received","dual instruction","dual rcv","dual rec",
    ],
    "dual_given": [
        "dual given","dual instruction given","cfi time","flight_dualgiventime",
        "instruction given","dual given time","cfi hours","instructional",
    ],
    "cross_country": [
        "cross country","crosscountry","xc","x-c","cross-country","flight_crosscountry",
        "cc","xcountry","cross cty","xctry",
    ],
    "night": [
        "night","night time","nighttime","flight_night","night hours","night flight",
    ],
    "instrument_actual": [
        "actual instrument","instrument","instrument actual","actualinstrument",
        "flight_instrumenttime","ifr actual","actual ifr","instrument time",
        "actual instrument time","inst actual","iac",
    ],
    "instrument_simulated": [
        "simulated instrument","hood","foggles","instrument simulated",
        "simulated ifr","flight_simulatedinstrumenttime","sim inst",
        "simulated instrument time",
    ],
    "landings_day": [
        "day landings","day ldg","landings day","day l/o","dayland",
        "flight_daylandingsfullstop","day to","day tko","day t/o",
        "day ldgs","d ldg","full stop day","daytakeoffs",
    ],
    "landings_night": [
        "night landings","night ldg","landings night","night l/o","nightland",
        "flight_nightlandingsfullstop","night to","night tko","night t/o",
        "night ldgs","n ldg","full stop night","nighttakeoffs",
    ],
    "approaches_count": [
        "approaches","approach","instrument approaches","number of approaches",
        "ifr approaches","app count","flight_instrumentapproaches","appr","apprs",
    ],
    "holds_count": [
        "holds","holding","holding procedures","number of holds","flight_holds",
    ],
    "remarks": [
        "remarks","notes","comments","flight remarks","flight_remarks","memo",
        "description","flight notes","comment",
    ],
]

// MARK: ═══════════════════════════════════════════════════════════════════
// MARK: - LogbookImportEngine  (CSV + XLSX parsing core)
// ═══════════════════════════════════════════════════════════════════════

final class LogbookImportEngine {

    static let shared = LogbookImportEngine()
    private init() {}

    // MARK: - Parse file

    func parseFile(url: URL,
                   format: EngineImportFormat? = nil
    ) throws -> (rows: [EngineFlightRow], detectedFormat: EngineImportFormat) {
        let ext  = url.pathExtension.lowercased()
        let text: String

        if ext == "xlsx" || ext == "xls" {
            text = try extractTextFromXLSX(url: url)
        } else {
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: url, encoding: .isoLatin1)
            }
        }
        return try parseCSVText(text, format: format)
    }

    // MARK: - Parse CSV text

    func parseCSVText(
        _ text: String,
        format: EngineImportFormat? = nil
    ) throws -> (rows: [EngineFlightRow], detectedFormat: EngineImportFormat) {

        let lines = text.components(separatedBy: .newlines)
            .map    { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw ImportEngineError.emptyFile }

        // ── Detect double-row header (Jeppesen / ASA style) ──────────
        let firstFields  = parseCSVLine(lines[0])
        let secondFields = lines.count > 1 ? parseCSVLine(lines[1]) : []
        var headerIndex  = 0

        if lines.count > 1 {
            let firstCount  = firstFields.filter  { !$0.isEmpty }.count
            let secondCount = secondFields.filter { !$0.isEmpty }.count
            if secondCount > firstCount * 2 && secondCount > 5 {
                headerIndex = 1
            }
        }

        let rawHeaders = parseCSVLine(lines[headerIndex])
        let dataLines  = Array(lines.dropFirst(headerIndex + 1))
        let detected   = format ?? EngineImportFormat.detect(headers: rawHeaders)
        let mapping    = buildMapping(headers: rawHeaders, format: detected)

        // ── Build rows ────────────────────────────────────────────────
        var rows: [EngineFlightRow] = []

        for line in dataLines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let cols = parseCSVLine(line)
            var row  = EngineFlightRow(fields: [:])

            for (idx, header) in rawHeaders.enumerated() {
                guard idx < cols.count else { continue }
                let value = cols[idx]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                guard let target = mapping[header] else { continue }

                if target == "route_from" {
                    let existing = row.fields["route"] ?? ""
                    row.fields["route"] = existing.isEmpty ? value : "\(value)-\(existing)"
                } else if target == "route_to" {
                    let existing = row.fields["route"] ?? ""
                    row.fields["route"] = existing.isEmpty ? value : "\(existing)-\(value)"
                } else {
                    row.fields[target] = value
                }
            }

            if let raw = row.fields["date"] {
                row.fields["date"] = normalizeDate(raw)
            }

            if row.fields["date"]?.isEmpty ?? true {
                row.warnings.append("Missing date")
            }
            if (Double(row.fields["total_time"] ?? "") ?? 0) == 0 {
                row.warnings.append("Total time is zero")
            }

            rows.append(row)
        }

        return (rows, detected)
    }

    // MARK: - Column mapping

    private func buildMapping(headers: [String],
                              format: EngineImportFormat) -> [String: String] {
        var map: [String: String] = [:]
        for header in headers {
            let norm = normalize(header)
            if let target = matchAlias(norm) {
                map[header] = target
            } else {
                switch format {
                case .foreFlight:
                    if let t = foreflightSpecific(header) { map[header] = t }
                case .logTenPro:
                    if let t = logtenSpecific(header)     { map[header] = t }
                default: break
                }
            }
        }
        return map
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func matchAlias(_ normalized: String) -> String? {
        for (field, aliases) in columnAliases {
            if aliases.contains(where: { $0.lowercased() == normalized }) { return field }
        }
        for (field, aliases) in columnAliases {
            if aliases.contains(where: {
                normalized.contains($0.lowercased()) || $0.lowercased().contains(normalized)
            }) { return field }
        }
        return nil
    }

    private func foreflightSpecific(_ h: String) -> String? {
        switch h.lowercased() {
        case "from", "departureiata":   return "route_from"
        case "to",   "destinationiata": return "route_to"
        default:                        return nil
        }
    }

    private func logtenSpecific(_ h: String) -> String? {
        switch h.lowercased() {
        case "flight_fromicao": return "route_from"
        case "flight_toicao":   return "route_to"
        default:                return nil
        }
    }

    // MARK: - Date normalizer

    func normalizeDate(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return clean }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "M/d/yyyy", "d/M/yyyy",
            "MM-dd-yyyy", "dd-MM-yyyy", "M/d/yy",    "dd-MMM-yyyy",
            "MMM dd, yyyy", "dd MMM yyyy", "MM/dd/yy", "yyyy/MM/dd",
        ]
        let output = DateFormatter()
        output.dateFormat = "yyyy-MM-dd"
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: clean) { return output.string(from: d) }
        }
        return clean
    }

    // MARK: - RFC-4180 CSV line parser

    func parseCSVLine(_ line: String) -> [String] {
        var result:   [String] = []
        var current:  String   = ""
        var inQuotes: Bool     = false
        let chars = Array(line)
        var i     = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\""); i += 2; continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                result.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        result.append(current)
        return result
    }

    // MARK: - XLSX extraction (pure Swift, no external packages)

    private func extractTextFromXLSX(url: URL) throws -> String {
        let fm   = FileManager.default
        let tmp  = fm.temporaryDirectory
            .appendingPathComponent("aerobook_xlsx_\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let zipURL = tmp.appendingPathComponent("wb.zip")
        try fm.copyItem(at: url, to: zipURL)

        let zipData = try Data(contentsOf: zipURL)
        let entries = parseZIPEntries(data: zipData)

        var sharedStrings: [String] = []
        if let ssEntry = entries.first(where: { $0.name.hasSuffix("sharedStrings.xml") }),
           let ssData  = extractZIPEntry(ssEntry, from: zipData) {
            sharedStrings = parseSharedStrings(String(data: ssData, encoding: .utf8) ?? "")
        }

        guard let shEntry = entries.first(where: {
                  $0.name.contains("worksheets/sheet1.xml") ||
                  ($0.name.contains("worksheets/") && $0.name.hasSuffix(".xml"))
              }),
              let shData  = extractZIPEntry(shEntry, from: zipData),
              let shXML   = String(data: shData, encoding: .utf8)
        else { throw ImportEngineError.xlsxParsingFailed }

        return parseSheetXML(shXML, sharedStrings: sharedStrings)
    }

    private struct ZIPEntry {
        let name: String; let offset: Int
        let compressedSize: Int; let compression: UInt16
    }

    private func parseZIPEntries(data: Data) -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var i = 0
        while i + 30 < data.count {
            guard data[i]==0x50, data[i+1]==0x4B,
                  data[i+2]==0x03, data[i+3]==0x04 else { i += 1; continue }

            let comp  = readU16(data, i + 8)
            let cSize = Int(readU32(data, i + 18))
            let fnLen = Int(readU16(data, i + 26))
            let exLen = Int(readU16(data, i + 28))
            guard i + 30 + fnLen <= data.count else { break }

            let name   = String(data: data.subdata(in: (i+30)..<(i+30+fnLen)),
                                encoding: .utf8) ?? ""
            let offset = i + 30 + fnLen + exLen
            entries.append(ZIPEntry(name: name, offset: offset,
                                    compressedSize: cSize, compression: comp))
            i += 30 + fnLen + exLen + cSize
        }
        return entries
    }

    private func extractZIPEntry(_ entry: ZIPEntry, from data: Data) -> Data? {
        guard entry.offset + entry.compressedSize <= data.count else { return nil }
        let slice = data.subdata(in: entry.offset ..< (entry.offset + entry.compressedSize))
        if entry.compression == 0 { return slice }
        return try? (slice as NSData).decompressed(using: .zlib) as Data?
    }

    private func readU16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o+1]) << 8
    }
    private func readU32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }

    private func parseSharedStrings(_ xml: String) -> [String] {
        var strings:   [String] = []
        var remaining = xml
        while let si    = remaining.range(of: "<si>"),
              let siEnd = remaining.range(of: "</si>") {
            var block = String(remaining[si.upperBound ..< siEnd.lowerBound])
            var text  = ""
            while let t    = block.range(of: "<t"),
                  let tCl  = block.range(of: ">",    range: t.upperBound ..< block.endIndex),
                  let tEnd = block.range(of: "</t>", range: tCl.upperBound ..< block.endIndex) {
                text  += String(block[tCl.upperBound ..< tEnd.lowerBound])
                block  = String(block[tEnd.upperBound...])
            }
            strings.append(text.xmlUnescaped)
            remaining = String(remaining[siEnd.upperBound...])
        }
        return strings
    }

    private func parseSheetXML(_ xml: String, sharedStrings: [String]) -> String {
        var csvRows:   [[String]] = []
        var remaining = xml
        while let rowS = remaining.range(of: "<row ") ?? remaining.range(of: "<row>"),
              let rowE = remaining.range(of: "</row>") {
            var block = String(remaining[rowS.upperBound ..< rowE.lowerBound])
            var cells: [(col: Int, val: String)] = []
            while let cS = block.range(of: "<c ") ?? block.range(of: "<c>"),
                  let cE = block.range(of: "</c>", range: cS.upperBound ..< block.endIndex) {
                let cellXML = String(block[cS.lowerBound ..< cE.upperBound])
                cells.append((cellColumnIndex(cellXML), cellValue(cellXML, sharedStrings)))
                block = String(block[cE.upperBound...])
            }
            csvRows.append(cells.map { $0.val })
            remaining = String(remaining[rowE.upperBound...])
        }
        return csvRows.map { row in
            row.map { v in
                v.contains(",") || v.contains("\"") || v.contains("\n")
                    ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : v
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private func cellColumnIndex(_ xml: String) -> Int {
        guard let rR = xml.range(of: "r=\""),
              let rE = xml.range(of: "\"", range: rR.upperBound ..< xml.endIndex)
        else { return 0 }
        var idx = 0
        for c in xml[rR.upperBound ..< rE.lowerBound].unicodeScalars {
            guard c.value >= 65, c.value <= 90 else { break }
            idx = idx * 26 + Int(c.value - 64)
        }
        return max(0, idx - 1)
    }

    private func cellValue(_ xml: String, _ ss: [String]) -> String {
        let shared = xml.contains("t=\"s\"")
        guard let vS  = xml.range(of: "<v>"),
              let vE  = xml.range(of: "</v>", range: vS.upperBound ..< xml.endIndex)
        else { return "" }
        let raw = String(xml[vS.upperBound ..< vE.lowerBound])
        if shared, let i = Int(raw), i < ss.count { return ss[i] }
        return raw.xmlUnescaped
    }
}

// MARK: - String XML unescape helper

private extension String {
    var xmlUnescaped: String {
        self
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

// MARK: - Import engine errors

enum ImportEngineError: LocalizedError {
    case emptyFile
    case xlsxParsingFailed
    case noMappableColumns

    var errorDescription: String? {
        switch self {
        case .emptyFile:         return "The file appears to be empty."
        case .xlsxParsingFailed: return "Could not read the XLSX file. Try re-saving as CSV from Excel."
        case .noMappableColumns: return "No recognisable logbook columns found in this file."
        }
    }
}
