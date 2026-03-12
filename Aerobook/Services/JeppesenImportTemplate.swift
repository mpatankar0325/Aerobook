// JeppesenImportTemplate.swift
// Aerobook
//
// Dedicated Jeppesen Professional Pilot Logbook import template.
// Handles the exact double-row merged-cell header layout of the
// attached Logbook_App_V1.xlsx (and any Jeppesen-compatible CSV/XLSX).
//
// Column map (25 columns, A–Y):
//  A    Date
//  B    Aircraft Type
//  C    Aircraft Ident
//  D    Route FROM
//  E    Route TO
//  F    NR INST APP
//  G    REMARKS & ENDORSEMENTS
//  H    NR T/O  (day takeoffs)
//  I    NR LDG  (day landings)
//  J    Night T/O
//  K    Night LDG
//  L    AIRCRAFT CATEGORY — SINGLE-ENGINE LAND
//  M    AIRCRAFT CATEGORY — MULTI-ENGINE LAND
//  N    AIRCRAFT CATEGORY — AND CLASS (other / helicopter)
//  O    CONDITIONS — NIGHT
//  P    CONDITIONS — ACTUAL INSTRUMENT
//  Q    CONDITIONS — SIMULATED INSTRUMENT (HOOD)
//  R-S  FLIGHT SIMULATOR (merged, use R)
//  T    TYPE OF PILOTING — CROSS COUNTRY
//  U    TYPE OF PILOTING — AS FLIGHT INSTRUCTOR
//  V    TYPE OF PILOTING — DUAL RECEIVED
//  W    TYPE OF PILOTING — SOLO
//  X    TYPE OF PILOTING — PILOT IN COMMAND (INC. SOLO)
//  Y    TOTAL DURATION OF FLIGHT

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import Compression

// MARK: - Column Definition (flexible / user-editable)

/// One column in the Jeppesen template.
/// The app stores `columnIndex` (0-based) so users can remap
/// any column on-the-fly without touching code.
struct JeppesenColumn: Identifiable, Codable, Equatable {
    var id: String          // matches DatabaseManager field key
    var label: String       // human label shown in the mapping UI
    var groupLabel: String  // section header (matches Jeppesen group)
    var columnIndex: Int    // 0-based column position in the file
    var isEnabled: Bool     // user can disable a column entirely
    var isMandatory: Bool   // cannot be disabled (date, total_time)
}

// MARK: - Jeppesen Template

/// Factory for the canonical 25-column Jeppesen layout.
/// Add / reorder columns here — the parser and UI follow automatically.
struct JeppesenTemplate {

    // MARK: Default 25-column Jeppesen layout
    static let defaultColumns: [JeppesenColumn] = [
        // ── Core ──────────────────────────────────────────────────────
        .init(id: "date",                  label: "Date",                   groupLabel: "Core",                columnIndex: 0,  isEnabled: true, isMandatory: true),
        .init(id: "aircraft_type",         label: "Aircraft Type",          groupLabel: "Core",                columnIndex: 1,  isEnabled: true, isMandatory: false),
        .init(id: "aircraft_ident",        label: "Aircraft Ident",         groupLabel: "Core",                columnIndex: 2,  isEnabled: true, isMandatory: false),
        // ── Route ─────────────────────────────────────────────────────
        .init(id: "route_from",            label: "Route FROM",             groupLabel: "Route of Flight",     columnIndex: 3,  isEnabled: true, isMandatory: false),
        .init(id: "route_to",              label: "Route TO",               groupLabel: "Route of Flight",     columnIndex: 4,  isEnabled: true, isMandatory: false),
        // ── Approaches / Remarks ───────────────────────────────────────
        .init(id: "approaches_count",      label: "NR Inst App",            groupLabel: "Approaches",          columnIndex: 5,  isEnabled: true, isMandatory: false),
        .init(id: "remarks",               label: "Remarks & Endorsements", groupLabel: "Remarks",             columnIndex: 6,  isEnabled: true, isMandatory: false),
        // ── Takeoffs & Landings ────────────────────────────────────────
        .init(id: "takeoffs",              label: "NR T/O (Day)",           groupLabel: "Takeoffs & Landings", columnIndex: 7,  isEnabled: true, isMandatory: false),
        .init(id: "landings_day",          label: "NR LDG (Day)",           groupLabel: "Takeoffs & Landings", columnIndex: 8,  isEnabled: true, isMandatory: false),
        .init(id: "takeoffs_night",        label: "Night T/O",              groupLabel: "Takeoffs & Landings", columnIndex: 9,  isEnabled: true, isMandatory: false),
        .init(id: "landings_night",        label: "Night LDG",              groupLabel: "Takeoffs & Landings", columnIndex: 10, isEnabled: true, isMandatory: false),
        // ── Aircraft Category & Class ──────────────────────────────────
        .init(id: "sel",                   label: "Single-Engine Land",     groupLabel: "Aircraft Category",   columnIndex: 11, isEnabled: true, isMandatory: false),
        .init(id: "mel",                   label: "Multi-Engine Land",      groupLabel: "Aircraft Category",   columnIndex: 12, isEnabled: true, isMandatory: false),
        .init(id: "other_class",           label: "Other / And Class",      groupLabel: "Aircraft Category",   columnIndex: 13, isEnabled: true, isMandatory: false),
        // ── Conditions of Flight ───────────────────────────────────────
        .init(id: "night",                 label: "Night",                  groupLabel: "Conditions of Flight",columnIndex: 14, isEnabled: true, isMandatory: false),
        .init(id: "instrument_actual",     label: "Actual Instrument",      groupLabel: "Conditions of Flight",columnIndex: 15, isEnabled: true, isMandatory: false),
        .init(id: "instrument_simulated",  label: "Simulated Inst (Hood)",  groupLabel: "Conditions of Flight",columnIndex: 16, isEnabled: true, isMandatory: false),
        // ── Flight Simulator ──────────────────────────────────────────
        .init(id: "flight_sim",            label: "Flight Simulator",       groupLabel: "Flight Simulator",    columnIndex: 17, isEnabled: true, isMandatory: false),
        // ── Type of Piloting Time ──────────────────────────────────────
        .init(id: "cross_country",         label: "Cross Country",          groupLabel: "Type of Piloting Time",columnIndex: 19, isEnabled: true, isMandatory: false),
        .init(id: "dual_given",            label: "As Flight Instructor",   groupLabel: "Type of Piloting Time",columnIndex: 20, isEnabled: true, isMandatory: false),
        .init(id: "dual_received",         label: "Dual Received",          groupLabel: "Type of Piloting Time",columnIndex: 21, isEnabled: true, isMandatory: false),
        .init(id: "solo",                  label: "Solo",                   groupLabel: "Type of Piloting Time",columnIndex: 22, isEnabled: true, isMandatory: false),
        .init(id: "pic",                   label: "PIC (inc. Solo)",        groupLabel: "Type of Piloting Time",columnIndex: 23, isEnabled: true, isMandatory: false),
        // ── Total ─────────────────────────────────────────────────────
        .init(id: "total_time",            label: "Total Duration",         groupLabel: "Total",               columnIndex: 24, isEnabled: true, isMandatory: true),
    ]

    /// Groups of columns for the mapping UI
    static var columnGroups: [String] {
        var seen = Set<String>()
        return defaultColumns.compactMap { col in
            seen.insert(col.groupLabel).inserted ? col.groupLabel : nil
        }
    }

    /// Persist a custom column layout to UserDefaults
    static func save(_ columns: [JeppesenColumn]) {
        if let data = try? JSONEncoder().encode(columns) {
            UserDefaults.standard.set(data, forKey: "jeppesen_column_map_v2")
        }
    }

    /// Load persisted layout, falling back to default
    static func load() -> [JeppesenColumn] {
        guard let data   = UserDefaults.standard.data(forKey: "jeppesen_column_map_v2"),
              let loaded = try? JSONDecoder().decode([JeppesenColumn].self, from: data)
        else { return defaultColumns }
        return loaded
    }
}

// MARK: - Parsed Row

struct JeppesenParsedRow: Identifiable {
    var id            = UUID()
    // Core
    var date:               String  = ""
    var aircraftType:       String  = ""
    var aircraftIdent:      String  = ""
    // Route
    var routeFrom:          String  = ""
    var routeTo:            String  = ""
    var route:              String  = ""     // combined
    // Approaches / Remarks
    var approachesCount:    Int     = 0
    var remarks:            String  = ""
    // Takeoffs & Landings
    var takeoffs:           Int     = 0
    var landingsDay:        Int     = 0
    var takeoffsNight:      Int     = 0
    var landingsNight:      Int     = 0
    // Category (used to derive aircraftCategory / aircraftClass)
    var sel:                Double  = 0      // Single-Engine Land
    var mel:                Double  = 0      // Multi-Engine Land
    var otherClass:         Double  = 0      // helicopter / other
    // Conditions
    var night:              Double  = 0
    var instrumentActual:   Double  = 0
    var instrumentSimulated:Double  = 0
    var flightSim:          Double  = 0
    // Piloting time
    var crossCountry:       Double  = 0
    var dualGiven:          Double  = 0
    var dualReceived:       Double  = 0
    var solo:               Double  = 0
    var pic:                Double  = 0
    var totalTime:          Double  = 0
    // Review state
    var isSelected:         Bool    = true
    var warnings:           [String] = []

    // Derived category for DB
    var aircraftCategory: String {
        if mel > 0 { return "Airplane" }
        if sel > 0 { return "Airplane" }
        if otherClass > 0 { return "Rotorcraft" }
        return "Airplane"
    }
    var aircraftClass: String {
        if mel > 0 { return "AMEL" }
        if sel > 0 { return "ASEL" }
        if otherClass > 0 { return "Helicopter" }
        return "ASEL"
    }

    // Map to DatabaseManager.addFlight() dictionary
    func toDatabaseDict() -> [String: Any] {
        let r = [routeFrom, routeTo].filter { !$0.isEmpty }.joined(separator: " - ")
        return [
            "date":                 date,
            "aircraft_type":        aircraftType,
            "aircraft_ident":       aircraftIdent,
            "aircraft_category":    aircraftCategory,
            "aircraft_class":       aircraftClass,
            "route":                route.isEmpty ? r : route,
            "total_time":           totalTime,
            "pic":                  pic,
            "sic":                  0.0,
            "solo":                 solo,
            "dual_received":        dualReceived,
            "dual_given":           dualGiven,
            "cross_country":        crossCountry,
            "night":                night,
            "instrument_actual":    instrumentActual,
            "instrument_simulated": instrumentSimulated,
            "flight_sim":           flightSim,
            "takeoffs":             takeoffs,
            "landings_day":         landingsDay,
            "landings_night":       landingsNight,
            "approaches_count":     approachesCount,
            "holds_count":          0,
            "nav_tracking":         false,
            "remarks":              remarks,
            "is_legacy_import":     1,
            "legacy_signature_path": ""
        ]
    }
}

// MARK: - Import Result

struct JeppesenImportResult {
    var rows:           [JeppesenParsedRow]
    var totalParsed:    Int
    var skippedRows:    Int
    var warnings:       [String]
}

// MARK: - Parser Engine

final class JeppesenParser {

    static let shared = JeppesenParser()
    private init() {}

    /// Parse a CSV or XLSX file using the provided column map.
    func parse(fileURL: URL,
               columns: [JeppesenColumn]) throws -> JeppesenImportResult {

        let ext = fileURL.pathExtension.lowercased()
        let text: String

        guard fileURL.startAccessingSecurityScopedResource() else {
            throw JeppesenParseError.securityDenied
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        if ext == "xlsx" || ext == "xls" {
            text = try extractXLSXText(url: fileURL)
        } else {
            if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: fileURL, encoding: .isoLatin1)
            }
        }

        return try parseCSVText(text, columns: columns)
    }

    // MARK: CSV text → rows

    func parseCSVText(_ text: String,
                      columns: [JeppesenColumn]) throws -> JeppesenImportResult {

        let allLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard allLines.count >= 3 else { throw JeppesenParseError.emptyFile }

        // ── Skip double-row Jeppesen header (rows 1 & 2) ─────────────
        // Detect: if row 1 col-count < row 2 col-count * 0.5, row 1 is
        // a group-label row.  Always skip the top two rows for Jeppesen.
        let headerFields0 = parseCSVLine(allLines[0])
        let headerFields1 = allLines.count > 1 ? parseCSVLine(allLines[1]) : []
        let dataStartIndex: Int

        let row0NonEmpty = headerFields0.filter { !$0.isEmpty }.count
        let row1NonEmpty = headerFields1.filter { !$0.isEmpty }.count

        if row1NonEmpty > row0NonEmpty {
            // Classic Jeppesen double-header: skip both
            dataStartIndex = 2
        } else {
            // Single header
            dataStartIndex = 1
        }

        let dataLines = Array(allLines[dataStartIndex...])

        // ── Build column-index lookup ─────────────────────────────────
        let colMap: [String: Int] = Dictionary(
            uniqueKeysWithValues: columns
                .filter { $0.isEnabled }
                .map { ($0.id, $0.columnIndex) }
        )

        // ── Parse data rows ───────────────────────────────────────────
        var rows: [JeppesenParsedRow] = []
        var warnings: [String] = []
        var skipped = 0
        let globalWarningLimit = 20

        for (lineIdx, line) in dataLines.enumerated() {
            let fields = parseCSVLine(line)

            // Skip separator / totally blank rows
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                skipped += 1; continue
            }

            var row = JeppesenParsedRow()
            var rowWarnings: [String] = []

            func str(_ key: String) -> String {
                guard let idx = colMap[key], idx < fields.count else { return "" }
                let v = fields[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return (v == "nan" || v == "None" || v == "NULL") ? "" : v
            }
            func dbl(_ key: String) -> Double {
                Double(str(key).replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            func int_(_ key: String) -> Int {
                Int(Double(str(key)) ?? 0)
            }

            // Date — try many formats, normalise to yyyy-MM-dd
            let rawDate = str("date")
            row.date = normalizeDate(rawDate)
            if row.date.isEmpty {
                if warnings.count < globalWarningLimit {
                    warnings.append("Row \(dataStartIndex + lineIdx + 1): unparseable date \"\(rawDate)\"")
                }
                rowWarnings.append("Date unrecognised")
            }

            row.aircraftType  = str("aircraft_type")
            row.aircraftIdent = str("aircraft_ident")
            row.routeFrom     = str("route_from").trimmingCharacters(in: .whitespaces)
            row.routeTo       = str("route_to").trimmingCharacters(in: .whitespaces)
            row.route         = [row.routeFrom, row.routeTo]
                .filter { !$0.isEmpty }.joined(separator: " - ")

            row.approachesCount     = int_("approaches_count")
            row.remarks             = str("remarks")
            row.takeoffs            = int_("takeoffs")
            row.landingsDay         = int_("landings_day")
            row.takeoffsNight       = int_("takeoffs_night")
            row.landingsNight       = int_("landings_night")

            row.sel                 = dbl("sel")
            row.mel                 = dbl("mel")
            row.otherClass          = dbl("other_class")

            row.night               = dbl("night")
            row.instrumentActual    = dbl("instrument_actual")
            row.instrumentSimulated = dbl("instrument_simulated")
            row.flightSim           = dbl("flight_sim")

            row.crossCountry        = dbl("cross_country")
            row.dualGiven           = dbl("dual_given")
            row.dualReceived        = dbl("dual_received")
            row.solo                = dbl("solo")
            row.pic                 = dbl("pic")
            row.totalTime           = dbl("total_time")

            // Auto-derive totalTime from category columns if missing
            if row.totalTime == 0 {
                let derived = max(row.sel + row.mel + row.otherClass, row.flightSim)
                if derived > 0 {
                    row.totalTime = derived
                    rowWarnings.append("Total time derived from category columns")
                }
            }

            // Skip rows with no date AND no flight time (page totals / blank rows)
            if row.date.isEmpty && row.totalTime == 0 {
                skipped += 1; continue
            }

            if row.totalTime == 0 && warnings.count < globalWarningLimit {
                rowWarnings.append("Total time is zero")
            }

            row.warnings = rowWarnings
            rows.append(row)
        }

        if rows.isEmpty { throw JeppesenParseError.noRecordsParsed }

        return JeppesenImportResult(
            rows:        rows,
            totalParsed: rows.count + skipped,
            skippedRows: skipped,
            warnings:    warnings
        )
    }

    // MARK: - Date normaliser (14 formats)

    private func normalizeDate(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // Strip time component "2021-03-08 00:00:00" → "2021-03-08"
        let clean = s.count > 10 && s.contains(" ") ? String(s.prefix(10)) : s

        let formats = [
            "yyyy-MM-dd","MM/dd/yyyy","dd/MM/yyyy","M/d/yyyy","d/M/yyyy",
            "MM-dd-yyyy","dd-MM-yyyy","M/d/yy","d/M/yy",
            "dd-MMM-yyyy","MMM dd, yyyy","dd MMM yyyy","MM/dd/yy","yyyy/MM/dd"
        ]
        let df  = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let out = DateFormatter(); out.dateFormat = "yyyy-MM-dd"
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: clean) { return out.string(from: d) }
        }
        return clean   // return as-is, flagged in warnings
    }

    // MARK: - RFC-4180 CSV line parser

    func parseCSVLine(_ line: String) -> [String] {
        var result:   [String] = []
        var current   = ""
        var inQuotes  = false
        let chars     = Array(line)
        var i         = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i+1] == "\"" {
                    current.append("\""); i += 2; continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                result.append(current); current = ""
            } else { current.append(c) }
            i += 1
        }
        result.append(current)
        return result
    }

    // MARK: - XLSX → CSV extractor (robust, column-position-aware)

    func extractXLSXText(url: URL) throws -> String {
        let zipData = try Data(contentsOf: url)

        // ── 1. Index all ZIP local-file entries ───────────────────────
        var entries: [String: (offset: Int, cSize: Int, uSize: Int, method: UInt16)] = [:]
        var pos = 0
        while pos + 30 <= zipData.count {
            // Local file header signature
            guard zipData[pos]   == 0x50, zipData[pos+1] == 0x4B,
                  zipData[pos+2] == 0x03, zipData[pos+3] == 0x04
            else { pos += 1; continue }

            let method = readU16(zipData, pos + 8)
            let cSize  = Int(readU32(zipData, pos + 18))
            let uSize  = Int(readU32(zipData, pos + 22))
            let fnLen  = Int(readU16(zipData, pos + 26))
            let exLen  = Int(readU16(zipData, pos + 28))

            guard pos + 30 + fnLen <= zipData.count else { break }
            let nameData = zipData.subdata(in: (pos + 30)..<(pos + 30 + fnLen))
            let name     = String(data: nameData, encoding: .utf8) ?? ""
            let dataOff  = pos + 30 + fnLen + exLen

            if dataOff + cSize <= zipData.count {
                entries[name] = (dataOff, cSize, uSize, method)
            }
            pos = dataOff + cSize
        }

        guard !entries.isEmpty else { throw JeppesenParseError.xlsxReadFailed }

        // ── 2. Decompress a named entry (raw Deflate, method 8) ───────
        func decompress(_ name: String) -> Data? {
            guard let e = entries[name] else { return nil }
            let slice = zipData.subdata(in: e.offset..<(e.offset + e.cSize))
            if e.method == 0 { return slice }   // stored – no compression

            // XLSX ZIP entries use raw Deflate (RFC 1951) — no zlib header/trailer.
            // COMPRESSION_ZLIB requires a standard zlib stream (RFC 1950), so we
            // prepend the 2-byte zlib header (0x78 0x9C = default compression) and
            // append a dummy 4-byte Adler-32 checksum. This tricks the decoder into
            // accepting the data while still decompressing the payload correctly.
            var wrapped = Data([0x78, 0x9C])   // zlib header
            wrapped.append(slice)
            wrapped.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // dummy Adler-32

            let uSize = e.uSize > 0 ? e.uSize : slice.count * 10
            var dst   = Data(count: uSize + 64)

            let written: Int = dst.withUnsafeMutableBytes { dstBuf in
                wrapped.withUnsafeBytes { srcBuf in
                    guard let dstPtr = dstBuf.baseAddress,
                          let srcPtr = srcBuf.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstPtr.assumingMemoryBound(to: UInt8.self), uSize + 64,
                        srcPtr.assumingMemoryBound(to: UInt8.self), wrapped.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }

            guard written > 0 else { return nil }
            return dst.prefix(written)
        }

        // Helper: find entry by suffix (handles xl/ prefix variations)
        func findEntry(suffix: String) -> String? {
            entries.keys.first(where: { $0.hasSuffix(suffix) })
        }

        // ── 3. Shared strings ─────────────────────────────────────────
        var sharedStrings: [String] = []
        if let ssKey  = findEntry(suffix: "sharedStrings.xml"),
           let ssData = decompress(ssKey),
           let ssXML  = String(data: ssData, encoding: .utf8) {
            sharedStrings = parseSharedStrings(ssXML)
        }

        // ── 4. Date style indices (so we know which numFmt = date) ────
        var dateStyleIndices = Set<Int>()
        if let styKey  = findEntry(suffix: "styles.xml"),
           let styData = decompress(styKey),
           let styXML  = String(data: styData, encoding: .utf8) {
            dateStyleIndices = parseDateStyleIndices(styXML)
        }

        // ── 5. Sheet1 XML ─────────────────────────────────────────────
        // Try xl/worksheets/sheet1.xml first, then any worksheet
        let sheetKey = findEntry(suffix: "worksheets/sheet1.xml")
                    ?? entries.keys.first(where: {
                           $0.contains("worksheets/") && $0.hasSuffix(".xml")
                       })

        guard let sk   = sheetKey,
              let shData = decompress(sk),
              let shXML  = String(data: shData, encoding: .utf8)
        else { throw JeppesenParseError.xlsxReadFailed }

        // ── 6. Sheet XML → column-position-aware CSV ──────────────────
        return sheetXMLtoCSV(shXML, shared: sharedStrings, dateStyles: dateStyleIndices)
    }

    // MARK: ZIP helpers
    private func readU16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o+1]) << 8
    }
    private func readU32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }

    // MARK: Shared strings parser
    private func parseSharedStrings(_ xml: String) -> [String] {
        var out: [String] = []
        var rem = xml[xml.startIndex...]
        while let siStart = rem.range(of: "<si>") ?? rem.range(of: "<si "),
              let siEnd   = rem.range(of: "</si>") {
            let block = rem[siStart.upperBound..<siEnd.lowerBound]
            var text  = ""
            // Collect all <t>…</t> runs (handles rich text with <rPr>)
            var scan = block[block.startIndex...]
            while let tOpen = scan.range(of: "<t"),
                  let tGT   = scan.range(of: ">",    range: tOpen.upperBound..<scan.endIndex),
                  let tClose = scan.range(of: "</t>", range: tGT.upperBound..<scan.endIndex) {
                // Check xml:space="preserve" — value is always inside <t>…</t>
                text += String(scan[tGT.upperBound..<tClose.lowerBound])
                scan  = scan[tClose.upperBound...]
            }
            out.append(xmlDecode(text))
            rem = rem[siEnd.upperBound...]
        }
        return out
    }

    // MARK: Date style detection
    // Built-in date numFmtIds: 14–17, 22, 164+ (custom with d/m/y)
    private func parseDateStyleIndices(_ xml: String) -> Set<Int> {
        // Collect numFmtId for each xf in cellXfs
        let builtinDateFmts: Set<Int> = [14,15,16,17,18,19,20,21,22,45,46,47]
        var customDateFmts:  Set<Int> = []

        // Parse <numFmt> elements for custom formats containing date tokens
        var rem = xml[xml.startIndex...]
        while let s = rem.range(of: "<numFmt "), let e = rem.range(of: "/>", range: s.upperBound..<rem.endIndex) {
            let tag = String(rem[s.lowerBound..<e.upperBound])
            if let fid = attrInt(tag, "numFmtId"),
               let fmt = attrStr(tag, "formatCode") {
                let low = fmt.lowercased()
                if low.contains("y") || low.contains("d") || (low.contains("m") && !low.contains("h")) {
                    customDateFmts.insert(fid)
                }
            }
            rem = rem[e.upperBound...]
        }

        let allDateFmts = builtinDateFmts.union(customDateFmts)

        // Now map xf index → numFmtId inside <cellXfs>
        var result = Set<Int>()
        if let cxStart = xml.range(of: "<cellXfs"),
           let cxEnd   = xml.range(of: "</cellXfs>") {
            let block = String(xml[cxStart.lowerBound..<cxEnd.upperBound])
            var xfIdx = 0
            var scan  = block[block.startIndex...]
            while let s = scan.range(of: "<xf ") {
                if let e = scan.range(of: "/>",    range: s.upperBound..<scan.endIndex)
                        ?? scan.range(of: "</xf>", range: s.upperBound..<scan.endIndex) {
                    let tag = String(scan[s.lowerBound..<e.upperBound])
                    if let fid = attrInt(tag, "numFmtId"), allDateFmts.contains(fid) {
                        result.insert(xfIdx)
                    }
                    xfIdx += 1
                    scan = scan[e.upperBound...]
                } else { break }
            }
        }
        return result
    }

    private func attrStr(_ tag: String, _ attr: String) -> String? {
        guard let r = tag.range(of: "\(attr)=\"") else { return nil }
        let start = r.upperBound
        guard let end = tag.range(of: "\"", range: start..<tag.endIndex) else { return nil }
        return String(tag[start..<end.lowerBound])
    }
    private func attrInt(_ tag: String, _ attr: String) -> Int? {
        guard let s = attrStr(tag, attr) else { return nil }
        return Int(s)
    }

    // MARK: Sheet XML → CSV (column-position-aware, handles sparse rows)
    private func sheetXMLtoCSV(_ xml: String,
                                shared: [String],
                                dateStyles: Set<Int>) -> String {
        var csvLines: [String] = []
        var rem = xml[xml.startIndex...]

        while let rowStart = rem.range(of: "<row ") ?? rem.range(of: "<row>"),
              let rowEnd   = rem.range(of: "</row>") {

            let rowBlock = rem[rowStart.lowerBound..<rowEnd.upperBound]
            // Collect cells: [(colIndex, value)]
            var cells: [(Int, String)] = []
            var cellScan = rowBlock[rowBlock.startIndex...]

            while let cStart = cellScan.range(of: "<c "),
                  let cEnd   = cellScan.range(of: "</c>", range: cStart.upperBound..<cellScan.endIndex) {
                let cellXML = String(cellScan[cStart.lowerBound..<cEnd.upperBound])
                let col     = xlColIndex(cellXML)     // 0-based column position
                let val     = xlCellValue(cellXML, shared: shared, dateStyles: dateStyles)
                cells.append((col, val))
                cellScan = cellScan[cEnd.upperBound...]
            }

            // Place values at correct column positions (fills gaps with "")
            if !cells.isEmpty {
                let maxCol = cells.map { $0.0 }.max() ?? 0
                var row    = Array(repeating: "", count: maxCol + 1)
                for (col, val) in cells where col <= maxCol { row[col] = val }
                csvLines.append(csvEscape(row))
            }

            rem = rem[rowEnd.upperBound...]
        }

        return csvLines.joined(separator: "\n")
    }

    /// Parse column letter(s) from cell reference like "A1", "BC23" → 0-based index
    private func xlColIndex(_ cellXML: String) -> Int {
        // r="XY123" — extract alpha prefix only
        guard let rRange = cellXML.range(of: "r=\"") else { return 0 }
        var col = 0
        for ch in cellXML[rRange.upperBound...].unicodeScalars {
            let v = ch.value
            guard v >= 65, v <= 90 else { break }   // A-Z only; stop at digit
            col = col * 26 + Int(v - 64)
        }
        return max(0, col - 1)
    }

    /// Extract typed cell value
    private func xlCellValue(_ xml: String, shared: [String], dateStyles: Set<Int>) -> String {
        // Cell type: s=sharedString, b=bool, e=error, inlineStr, (none)=number
        let isShared = xml.contains("t=\"s\"")
        let isInline = xml.contains("t=\"inlineStr\"")
        let isBool   = xml.contains("t=\"b\"")

        // Style index for date detection
        let styleIdx: Int? = {
            guard let s = attrStr(xml, "s") else { return nil }
            return Int(s)
        }()
        let isDateStyle = styleIdx.map { dateStyles.contains($0) } ?? false

        // Detect DATE() formula — Excel stores dates as serial numbers with a DATE formula
        let hasDateFormula = xml.contains("<f>DATE(") || xml.contains("<f t=") && xml.contains("DATE(")

        // <v> value
        var raw = ""
        if let vs = xml.range(of: "<v>"),
           let ve = xml.range(of: "</v>", range: vs.upperBound..<xml.endIndex) {
            raw = String(xml[vs.upperBound..<ve.lowerBound])
        }

        // <is><t> inline string
        if isInline {
            if let ts = xml.range(of: "<t>"),
               let te = xml.range(of: "</t>", range: ts.upperBound..<xml.endIndex) {
                return xmlDecode(String(xml[ts.upperBound..<te.lowerBound]))
            }
            return ""
        }

        if raw.isEmpty { return "" }

        if isShared, let idx = Int(raw), idx < shared.count { return shared[idx] }
        if isBool   { return raw == "1" ? "TRUE" : "FALSE" }

        // Date: style-based OR formula-based detection
        // Valid Excel date serials for years 1900–2100 ≈ 1–73050
        if let serial = Double(raw), serial >= 1, serial <= 73050 {
            if isDateStyle || hasDateFormula {
                return excelSerialToISO(serial)
            }
        }

        return xmlDecode(raw)
    }

    private func csvEscape(_ fields: [String]) -> String {
        fields.map { v -> String in
            if v.contains(",") || v.contains("\"") || v.contains("\n") {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }.joined(separator: ",")
    }

    private func excelSerialToISO(_ serial: Double) -> String {
        // Verified against actual data: serial 44263 → 2021-03-08 ✓
        // Excel epoch: 1899-12-31 (unix -2_209_075_200)
        // Excel leap-year bug: serials > 60 are off by 1 (pretends 1900 was a leap year)
        let adjusted = serial > 60 ? serial - 1 : serial
        let epoch    = Date(timeIntervalSince1970: -2_209_075_200)  // 1899-12-31 UTC
        let date     = epoch.addingTimeInterval(adjusted * 86_400)
        let fmt      = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone   = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private func xmlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
    }
}

// MARK: - Parse Errors

enum JeppesenParseError: LocalizedError {
    case securityDenied, emptyFile, noRecordsParsed, xlsxReadFailed
    var errorDescription: String? {
        switch self {
        case .securityDenied:   return "Cannot access the selected file."
        case .emptyFile:        return "The file appears to be empty."
        case .noRecordsParsed:  return "No flight records could be parsed."
        case .xlsxReadFailed:   return "Could not read the XLSX file. Try saving as CSV."
        }
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════════
// MARK: - SwiftUI: Jeppesen Import View
// ═══════════════════════════════════════════════════════════════════════════

struct JeppesenImportView: View {

    // Column map (loaded from UserDefaults, editable)
    @State private var columns: [JeppesenColumn] = JeppesenTemplate.load()

    // File picking
    @State private var showFilePicker   = false
    @State private var isProcessing     = false
    @State private var parseResult: JeppesenImportResult?
    @State private var showReview       = false
    @State private var errorMessage: String?
    @State private var commitResult: (inserted: Int, failed: Int)?

    // Column mapping editor
    @State private var showColumnEditor = false

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        AeroPageHeader(
                            title: "Jeppesen Import",
                            subtitle: "FAA Pilot Logbook · Double-row header · 25 columns"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // Drop zone
                        dropZone
                            .padding(.horizontal)

                        // Banners
                        if let done = commitResult {
                            commitBanner(inserted: done.inserted, failed: done.failed)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if let err = errorMessage {
                            errorBanner(err)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Column mapping card
                        columnMapCard
                            .padding(.horizontal)

                        // Format info card
                        formatInfoCard
                            .padding(.horizontal)

                        Color.clear.frame(height: 24)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .animation(.spring(response: 0.35), value: commitResult != nil)
            .animation(.spring(response: 0.35), value: errorMessage)
            .sheet(isPresented: $showFilePicker) {
                JeppesenDocumentPicker { url in handleFilePicked(url) }
            }
            .sheet(isPresented: $showReview, onDismiss: { parseResult = nil }) {
                if let result = parseResult {
                    JeppesenReviewView(result: result) { approved in
                        commitRows(approved)
                    }
                }
            }
            .sheet(isPresented: $showColumnEditor) {
                JeppesenColumnEditorView(columns: $columns)
            }
        }
    }

    // MARK: Drop Zone
    private var dropZone: some View {
        Button(action: { showFilePicker = true }) {
            VStack(spacing: 20) {
                if isProcessing {
                    VStack(spacing: 12) {
                        ProgressView().scaleEffect(1.4).tint(AeroTheme.brandPrimary)
                        Text("Parsing Jeppesen logbook…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }.frame(height: 100)
                } else {
                    ZStack {
                        Circle().fill(Color(red:0.01,green:0.49,blue:0.95).opacity(0.1))
                            .frame(width: 80, height: 80)
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color(red:0.01,green:0.49,blue:0.95))
                    }
                    VStack(spacing: 5) {
                        Text("Select Jeppesen Logbook")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("CSV or XLSX · Double-row header auto-detected")
                            .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(["CSV","XLSX","XLS"], id: \.self) { ext in
                            Text(ext)
                                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color(red:0.01,green:0.49,blue:0.95).opacity(0.09))
                                .foregroundStyle(Color(red:0.01,green:0.49,blue:0.95))
                                .cornerRadius(5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusXl)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusXl)
                .strokeBorder(Color(red:0.01,green:0.49,blue:0.95).opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6,4])))
            .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isProcessing)
    }

    // MARK: Column Map Card
    private var columnMapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Column Mapping", systemImage: "table.fill")
                    .font(.system(size: 11, weight: .bold)).tracking(1.1)
                    .foregroundStyle(AeroTheme.brandPrimary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { showColumnEditor = true }) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.brandPrimary)
                }
            }

            // Quick column summary chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(columns.filter { $0.isEnabled }) { col in
                        HStack(spacing: 4) {
                            Text("Col \(col.columnIndex + 1)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(AeroTheme.textTertiary)
                            Text(col.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AeroTheme.textPrimary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(col.isMandatory
                                    ? AeroTheme.brandPrimary.opacity(0.1)
                                    : AeroTheme.cardBg)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(AeroTheme.cardStroke, lineWidth: 1))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
    }

    // MARK: Format Info Card
    private var formatInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Jeppesen Layout", systemImage: "info.circle.fill")
                .font(.system(size: 11, weight: .bold)).tracking(1.1)
                .foregroundStyle(AeroTheme.brandPrimary)
                .textCase(.uppercase)

            let groups: [(String, String)] = [
                ("Columns A–C",   "Date · Aircraft Type · Aircraft Ident"),
                ("Columns D–E",   "Route of Flight (FROM / TO)"),
                ("Columns F–K",   "Approaches · Remarks · T/O · LDG (Day & Night)"),
                ("Columns L–N",   "Aircraft Category: SEL · MEL · Other"),
                ("Columns O–Q",   "Conditions: Night · Actual Inst · Sim Inst"),
                ("Columns R–S",   "Flight Simulator"),
                ("Columns T–X",   "Piloting Time: XC · CFI · Dual · Solo · PIC"),
                ("Column Y",      "Total Duration of Flight"),
            ]

            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { idx, grp in
                    HStack(alignment: .top, spacing: 10) {
                        Text(grp.0)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .frame(width: 100, alignment: .leading)
                        Text(grp.1)
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    if idx < groups.count - 1 {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
            .background(AeroTheme.pageBg)
            .cornerRadius(AeroTheme.radiusMd)
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
    }

    // MARK: Banners
    private func commitBanner(inserted: Int, failed: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24)).foregroundStyle(.statusGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(inserted) flights imported")
                    .font(.system(size: 14, weight: .bold))
                if failed > 0 {
                    Text("\(failed) rows failed — check format")
                        .font(.system(size: 12)).foregroundStyle(.red.opacity(0.8))
                }
            }
            Spacer()
            Button(action: { withAnimation { commitResult = nil } }) {
                Image(systemName: "xmark").foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(16)
        .background(Color.green.opacity(0.07))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.green.opacity(0.2), lineWidth: 1))
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22)).foregroundStyle(.red)
            Text(msg).font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary).lineLimit(3)
            Spacer()
            Button(action: { withAnimation { errorMessage = nil } }) {
                Image(systemName: "xmark").foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.07))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.red.opacity(0.2), lineWidth: 1))
    }

    // MARK: Logic
    private func handleFilePicked(_ url: URL) {
        isProcessing = true
        errorMessage = nil
        commitResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try JeppesenParser.shared.parse(fileURL: url, columns: columns)
                DispatchQueue.main.async {
                    isProcessing = false
                    parseResult  = result
                    showReview   = true
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func commitRows(_ rows: [JeppesenParsedRow]) {
        let selected = rows.filter { $0.isSelected }
        var inserted = 0; var failed = 0
        let group = DispatchGroup()
        for row in selected {
            group.enter()
            DatabaseManager.shared.addFlight(row.toDatabaseDict()) { rowId in
                if rowId != nil { inserted += 1 } else { failed += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            withAnimation { commitResult = (inserted, failed) }
            NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
        }
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════════
// MARK: - Review View (row-by-row approve / edit before insert)
// ═══════════════════════════════════════════════════════════════════════════

struct JeppesenReviewView: View {

    @Environment(\.dismiss) private var dismiss
    let result:   JeppesenImportResult
    let onCommit: ([JeppesenParsedRow]) -> Void

    @State private var rows: [JeppesenParsedRow]
    @State private var searchText = ""
    @State private var filterWarnings = false
    @State private var editingRow: JeppesenParsedRow?

    init(result: JeppesenImportResult, onCommit: @escaping ([JeppesenParsedRow]) -> Void) {
        self.result   = result
        self.onCommit = onCommit
        _rows = State(initialValue: result.rows)
    }

    private var filteredRows: [JeppesenParsedRow] {
        rows.filter { row in
            let matchesSearch = searchText.isEmpty ||
                row.date.contains(searchText) ||
                row.aircraftType.localizedCaseInsensitiveContains(searchText) ||
                row.aircraftIdent.localizedCaseInsensitiveContains(searchText) ||
                row.remarks.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = !filterWarnings || !row.warnings.isEmpty
            return matchesSearch && matchesFilter
        }
    }

    private var selectedCount: Int { rows.filter { $0.isSelected }.count }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Stats bar
                    statsBar.padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()

                    // Search + filter
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 13))
                                .foregroundStyle(AeroTheme.textTertiary)
                            TextField("Search date, aircraft, remarks…", text: $searchText)
                                .font(.system(size: 13))
                        }
                        .padding(10)
                        .background(AeroTheme.cardBg)
                        .cornerRadius(9)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AeroTheme.cardStroke))

                        Button(action: { filterWarnings.toggle() }) {
                            Image(systemName: filterWarnings ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                .font(.system(size: 16))
                                .foregroundStyle(filterWarnings ? .orange : AeroTheme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    // Row list
                    List {
                        ForEach(filteredRows.indices, id: \.self) { idx in
                            let row = filteredRows[idx]
                            JeppesenRowCard(row: row,
                                           onToggle: { toggle(row) },
                                           onEdit:   { editingRow = findRow(row) })
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .background(AeroTheme.pageBg)

                    // Commit bar
                    commitBar
                }
            }
            .navigationTitle("Review \(result.rows.count) Flights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select All")   { setAll(true)  }
                        Button("Deselect All") { setAll(false) }
                        Divider()
                        Button("Select Warnings Only") { selectWarningsOnly() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $editingRow) { row in
                JeppesenRowEditView(row: row) { updated in applyEdit(updated) }
            }
        }
    }

    // Stats bar
    private var statsBar: some View {
        HStack(spacing: 0) {
            statCell(value: "\(result.totalParsed)", label: "Parsed")
            statCell(value: "\(result.skippedRows)", label: "Skipped")
            statCell(value: "\(rows.filter { !$0.warnings.isEmpty }.count)", label: "Warnings")
            statCell(value: "\(selectedCount)", label: "Selected", highlight: true)
        }
    }

    private func statCell(value: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .light, design: .rounded))
                .foregroundStyle(highlight ? AeroTheme.brandPrimary : AeroTheme.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AeroTheme.textTertiary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    // Commit bar
    private var commitBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: {
                onCommit(rows)
                dismiss()
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Import \(selectedCount) Flight\(selectedCount == 1 ? "" : "s")")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(selectedCount > 0 ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                .cornerRadius(14)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .disabled(selectedCount == 0)
            .buttonStyle(PlainButtonStyle())
        }
        .background(AeroTheme.cardBg)
    }

    // Helpers
    private func toggle(_ row: JeppesenParsedRow) {
        if let i = rows.firstIndex(where: { $0.id == row.id }) {
            rows[i].isSelected.toggle()
        }
    }
    private func setAll(_ v: Bool) { for i in rows.indices { rows[i].isSelected = v } }
    private func selectWarningsOnly() {
        for i in rows.indices { rows[i].isSelected = !rows[i].warnings.isEmpty }
    }
    private func findRow(_ row: JeppesenParsedRow) -> JeppesenParsedRow? {
        rows.first { $0.id == row.id }
    }
    private func applyEdit(_ updated: JeppesenParsedRow) {
        if let i = rows.firstIndex(where: { $0.id == updated.id }) {
            rows[i] = updated
        }
    }
}

// MARK: - Row Card

struct JeppesenRowCard: View {
    let row:      JeppesenParsedRow
    let onToggle: () -> Void
    let onEdit:   () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button(action: onToggle) {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(row.isSelected ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
            }
            .buttonStyle(PlainButtonStyle())

            // Content
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(row.date)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text("·")
                        .foregroundStyle(AeroTheme.textTertiary)
                    Text(row.aircraftType + " " + row.aircraftIdent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AeroTheme.textSecondary)
                    Spacer()
                    // Total time badge
                    Text(String(format: "%.1fh", row.totalTime))
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AeroTheme.brandPrimary.opacity(0.1))
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .cornerRadius(6)
                }

                // Route
                if !row.route.isEmpty {
                    Text(row.route)
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }

                // Time chips
                let chips: [(String, Double)] = [
                    ("PIC", row.pic), ("Dual", row.dualReceived),
                    ("Solo", row.solo), ("XC", row.crossCountry),
                    ("Night", row.night), ("Sim", row.instrumentSimulated)
                ].filter { $0.1 > 0 }

                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(chips, id: \.0) { chip in
                                Text("\(chip.0) \(String(format: "%.1f", chip.1))")
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(AeroTheme.pageBg)
                                    .foregroundStyle(AeroTheme.textSecondary)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }

                // Remarks
                if !row.remarks.isEmpty {
                    Text(row.remarks)
                        .font(.system(size: 10))
                        .foregroundStyle(AeroTheme.textTertiary)
                        .lineLimit(1)
                }

                // Warning chips
                if !row.warnings.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                        Text(row.warnings.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
        .background(row.isSelected ? AeroTheme.cardBg : AeroTheme.cardBg.opacity(0.5))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(row.isSelected
                    ? AeroTheme.brandPrimary.opacity(0.2)
                    : AeroTheme.cardStroke, lineWidth: 1))
        .opacity(row.isSelected ? 1 : 0.55)
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════════
// MARK: - Row Edit View (full field editor, no JSON)
// ═══════════════════════════════════════════════════════════════════════════

struct JeppesenRowEditView: View {

    @Environment(\.dismiss) private var dismiss
    @State var row: JeppesenParsedRow
    let onSave: (JeppesenParsedRow) -> Void

    var body: some View {
        NavigationView {
            Form {
                // ── Core ─────────────────────────────────────────────
                Section("Core") {
                    LabeledContent("Date") {
                        TextField("yyyy-MM-dd", text: $row.date)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Aircraft Type") {
                        TextField("C172", text: $row.aircraftType)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Aircraft Ident") {
                        TextField("N12345", text: $row.aircraftIdent)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // ── Route ─────────────────────────────────────────────
                Section("Route of Flight") {
                    LabeledContent("From") {
                        TextField("KCDW", text: $row.routeFrom)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("To") {
                        TextField("KMMU", text: $row.routeTo)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // ── Takeoffs & Landings ────────────────────────────────
                Section("Takeoffs & Landings") {
                    intField("Day T/O",    value: $row.takeoffs)
                    intField("Day LDG",    value: $row.landingsDay)
                    intField("Night T/O",  value: $row.takeoffsNight)
                    intField("Night LDG",  value: $row.landingsNight)
                    intField("Approaches", value: $row.approachesCount)
                }

                // ── Aircraft Category ──────────────────────────────────
                Section("Aircraft Category") {
                    dblField("Single-Engine Land (SEL)", value: $row.sel)
                    dblField("Multi-Engine Land (MEL)",  value: $row.mel)
                    dblField("Other / Class",             value: $row.otherClass)
                }

                // ── Conditions ────────────────────────────────────────
                Section("Conditions of Flight") {
                    dblField("Night",                value: $row.night)
                    dblField("Actual Instrument",    value: $row.instrumentActual)
                    dblField("Simulated Inst (Hood)",value: $row.instrumentSimulated)
                    dblField("Flight Simulator",     value: $row.flightSim)
                }

                // ── Type of Piloting Time ──────────────────────────────
                Section("Type of Piloting Time") {
                    dblField("Cross Country",     value: $row.crossCountry)
                    dblField("As CFI",            value: $row.dualGiven)
                    dblField("Dual Received",     value: $row.dualReceived)
                    dblField("Solo",              value: $row.solo)
                    dblField("PIC (inc. Solo)",   value: $row.pic)
                }

                // ── Total ─────────────────────────────────────────────
                Section("Total") {
                    dblField("Total Duration", value: $row.totalTime)
                }

                // ── Remarks ───────────────────────────────────────────
                Section("Remarks") {
                    TextField("Remarks / Endorsements", text: $row.remarks, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Re-compute route string
                        row.route = [row.routeFrom, row.routeTo]
                            .filter { !$0.isEmpty }.joined(separator: " - ")
                        onSave(row)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func dblField(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField("0.0", value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func intField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════════
// MARK: - Column Editor (drag-to-reorder, enable/disable, remap index)
// ═══════════════════════════════════════════════════════════════════════════

struct JeppesenColumnEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Binding var columns: [JeppesenColumn]
    @State private var localCols: [JeppesenColumn] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(JeppesenTemplate.columnGroups, id: \.self) { group in
                    Section(group) {
                        ForEach($localCols.filter { $0.groupLabel.wrappedValue == group }) { $col in
                            HStack(spacing: 12) {
                                // Enable toggle (mandatory cols always on)
                                Toggle("", isOn: col.isMandatory
                                       ? .constant(true)
                                       : $col.isEnabled)
                                .labelsHidden()
                                .tint(AeroTheme.brandPrimary)
                                .disabled(col.isMandatory)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(col.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(col.isEnabled
                                                         ? AeroTheme.textPrimary
                                                         : AeroTheme.textTertiary)
                                    Text("Column \(col.columnIndex + 1) (\(columnLetter(col.columnIndex)))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(AeroTheme.textTertiary)
                                }

                                Spacer()

                                // Column index stepper (remap on-the-fly)
                                Stepper("", value: $col.columnIndex, in: 0...99)
                                    .labelsHidden()
                                    .disabled(!col.isEnabled && !col.isMandatory)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Reset section
                Section {
                    Button(role: .destructive, action: {
                        localCols = JeppesenTemplate.defaultColumns
                    }) {
                        Label("Reset to Jeppesen Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Column Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        columns = localCols
                        JeppesenTemplate.save(localCols)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .onAppear { localCols = columns }
    }

    private func columnLetter(_ idx: Int) -> String {
        idx < 26
            ? String(UnicodeScalar(65 + idx)!)
            : "\(String(UnicodeScalar(65 + (idx / 26) - 1)!))\(String(UnicodeScalar(65 + (idx % 26))!))"
    }
}

// MARK: ═══════════════════════════════════════════════════════════════════════
// MARK: - Document Picker
// ═══════════════════════════════════════════════════════════════════════════

struct JeppesenDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.commaSeparatedText, .spreadsheet, .plainText, .data]
        if let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") { types.append(xlsx) }
        if let xls  = UTType("com.microsoft.excel.xls")               { types.append(xls) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: JeppesenDocumentPicker
        init(_ p: JeppesenDocumentPicker) { parent = p }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    // Already defined in app — declared here only if not globally visible
    // static let logbookDataDidChange = Notification.Name("logbookDataDidChange")
}

// MARK: - Preview

#Preview {
    JeppesenImportView()
}
