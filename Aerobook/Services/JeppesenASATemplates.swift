// JeppesenASATemplates.swift
// AeroBook
//
// Format-specific column templates for Jeppesen, ASA, ForeFlight, and LogTen Pro.
//
// ── TYPE DECLARATIONS ──────────────────────────────────────────────────────
// All types used here (LogbookImportFormat, ParsedFlightRecord, etc.) are
// declared in ImportModels.swift.  Do NOT re-declare them here.
//
// `canonicalColumnAliases` is also declared in ImportModels.swift and is
// accessible here because it is a module-level let constant.
// ───────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Jeppesen Logbook Template

/// Column definitions for the official Jeppesen Student/Private Pilot Logbook
/// Matches the double-row header structure found in Logbook_App_V1.xlsx
///
/// Row 0 headers (groups):
///   Date | Aircraft Type | Aircraft Ident | Route of Flight | | NR INST APP |
///   REMARKS AND ENDORSEMENTS | NR T/O | NR LDG | Night T/O | Night LDG |
///   AIRCRAFT CATEGORY | | | CONDITIONS OF FLIGHT | | |
///   FLIGHT SIMULATOR | | TYPE OF PILOTING TIME | | | | | TOTAL DURATION OF FLIGHT
///
/// Row 1 headers (sub-columns):
///   | | | FROM | TO | | | | | | |
///   SINGLE-ENGINE LAND | MULTI-ENGINE LAND | AND CLASS |
///   NIGHT | ACTUAL INSTRUMENT | SIMULATED INSTRUMENT (HOOD) | |
///   | CROSS COUNTRY | AS FLIGHT INSTRUCTOR | DUAL RECEIVED | SOLO |
///   PILOT IN COMMAND (INC. SOLO) |

struct JeppesenASATemplate {
    static let name = "Jeppesen"
    static let isDoubleRowHeader = true

    /// Column index → canonical field name mapping (0-based, from Logbook_App_V1.xlsx)
    static let columnMap: [Int: String] = [
        0:  "date",
        1:  "aircraft_type",
        2:  "aircraft_ident",
        3:  "route_from",
        4:  "route_to",
        5:  "approaches_count",
        6:  "remarks",
        7:  "takeoffs_day",
        8:  "landings_day",
        9:  "takeoffs_night",
        10: "landings_night",
        11: "sel",
        12: "mel",
        13: "other_class",
        14: "night",
        15: "instrument_actual",
        16: "instrument_simulated",
        17: "sim",
        18: "sim_type",
        19: "cross_country",
        20: "dual_given",
        21: "dual_received",
        22: "solo",
        23: "pic",
        24: "total_time",
    ]

    /// Human-readable label for each column (used in review UI)
    static let columnLabels: [Int: String] = [
        0:  "Date",
        1:  "Aircraft Type",
        2:  "Aircraft N#",
        3:  "From",
        4:  "To",
        5:  "Inst. Approaches",
        6:  "Remarks",
        7:  "T/O",
        8:  "Ldg",
        9:  "Night T/O",
        10: "Night Ldg",
        11: "SE Land",
        12: "ME Land",
        13: "Other Class",
        14: "Night",
        15: "Actual Inst.",
        16: "Sim. Inst.",
        17: "Sim Time",
        18: "Sim Type",
        19: "Cross Country",
        20: "CFI Time",
        21: "Dual Rcvd",
        22: "Solo",
        23: "PIC",
        24: "Total Time",
    ]

    /// Parse a single data row (array of strings, 0-based) into a ParsedFlightRecord.
    ///
    /// Uses the fields `routeFrom`, `routeTo`, `takeoffsDay`, `takeoffsNight` that are
    /// declared on ParsedFlightRecord in ImportModels.swift.
    static func parseRow(_ fields: [String]) -> ParsedFlightRecord {
        var r = ParsedFlightRecord()

        r.date          = cleanDateString(fields[safe: 0] ?? "")
        r.aircraftType  = clean(fields[safe: 1] ?? "")
        r.aircraftIdent = clean(fields[safe: 2] ?? "")

        // Route: col3 can contain "KCDW - LOC" style full route from OCR
        let rawFrom = clean(fields[safe: 3] ?? "")
        let rawTo   = clean(fields[safe: 4] ?? "")

        if rawFrom.contains(" - ") && rawTo.isEmpty {
            let parts   = rawFrom.components(separatedBy: " - ")
            r.routeFrom = parts.first ?? rawFrom
            r.routeTo   = parts.dropFirst().joined(separator: " - ")
        } else {
            r.routeFrom = rawFrom
            r.routeTo   = rawTo
        }
        r.route = [r.routeFrom, r.routeTo].filter { !$0.isEmpty }.joined(separator: " - ")

        r.approachesCount  = intField(fields, 5)
        r.remarks          = clean(fields[safe: 6] ?? "")
        r.takeoffsDay      = intField(fields, 7)    // NR T/O  (day)
        r.landingsDay      = intField(fields, 8)    // NR LDG  (day)
        r.takeoffsNight    = intField(fields, 9)    // Night T/O
        r.landingsNight    = intField(fields, 10)   // Night LDG

        let sel        = dblField(fields, 11)   // SE Land time
        let mel        = dblField(fields, 12)   // ME Land time
        let otherClass = dblField(fields, 13)   // Other category (helo, glider…)

        r.night               = dblField(fields, 14)
        r.instrumentActual    = dblField(fields, 15)
        r.instrumentSimulated = dblField(fields, 16)
        let simTime           = dblField(fields, 17)
        // col 18 = sim type (text) — skip

        r.crossCountry  = dblField(fields, 19)
        r.dualGiven     = dblField(fields, 20)
        r.dualReceived  = dblField(fields, 21)
        r.solo          = dblField(fields, 22)
        r.pic           = dblField(fields, 23)
        r.totalTime     = dblField(fields, 24)

        // Derive category / class from category time columns
        if sel > 0 {
            r.aircraftCategory = "Airplane"
            r.aircraftClass    = "ASEL"
        } else if mel > 0 {
            r.aircraftCategory = "Airplane"
            r.aircraftClass    = "AMEL"
        } else if otherClass > 0 {
            let t = r.aircraftType.uppercased()
            if t.contains("R22") || t.contains("R44") || t.contains("BELL") || t.contains("EC") {
                r.aircraftCategory = "Rotorcraft"
                r.aircraftClass    = "Helicopter"
            } else {
                r.aircraftCategory = "Airplane"
                r.aircraftClass    = "ASES"
            }
        } else if simTime > 0 {
            r.aircraftCategory = "Simulator"
            r.aircraftClass    = "FSTD"
        }

        // If total time is missing, derive from category time columns
        if r.totalTime == 0 {
            let categoryTotal = sel + mel + otherClass
            r.totalTime = categoryTotal > 0 ? categoryTotal : simTime
        }

        return r
    }

    // MARK: - Helpers

    private static func dblField(_ f: [String], _ i: Int) -> Double {
        guard let s = f[safe: i], !s.isEmpty, s != "nan", s != "None", s != "NULL" else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func intField(_ f: [String], _ i: Int) -> Int {
        Int(dblField(f, i))
    }

    private static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t == "nan" || t == "None" || t == "NULL") ? "" : t
    }

    private static func cleanDateString(_ s: String) -> String {
        // Excel dates come as "2021-03-08 00:00:00"
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 10 { return String(trimmed.prefix(10)) }
        return trimmed
    }
}

// MARK: - ASA Logbook Template

/// Column definitions for the ASA Standard Pilot Logbook (FAR/AIM Edition)

struct ASATemplate {
    static let name = "ASA"
    static let isDoubleRowHeader = true

    /// ASA-specific aliases that extend the canonical ones
    static let additionalAliases: [String: [String]] = [
        "aircraft_type":        ["make & model", "aircraft make & model", "make/model"],
        "aircraft_ident":       ["n number", "aircraft id", "identification"],
        "route_from":           ["departure", "dep airport", "dep"],
        "route_to":             ["arrival", "arr airport", "dest"],
        "night":                ["conditions of flight night", "night conditions"],
        "instrument_actual":    ["actual", "act inst", "ifr conditions"],
        "instrument_simulated": ["simulated", "sim inst", "hood"],
        "cross_country":        ["x-country", "x/c"],
        "dual_received":        ["dual received", "dual rcv", "dual rec'd"],
        "solo":                 ["solo", "student solo"],
        "pic":                  ["pic", "p.i.c", "pilot in command"],
        "sic":                  ["sic", "s.i.c", "second in command", "copilot"],
        "landings_day":         ["day landings", "ldg day", "# ldg day"],
        "landings_night":       ["night landings", "ldg night", "# ldg night"],
        "approaches_count":     ["# inst appr", "no of inst appr", "inst approaches", "approaches"],
        "total_time":           ["total duration", "total time", "block time", "total", "hours"],
        "remarks":              ["remarks & endorsements", "remarks and endorsements", "notes"],
    ]

    static let row0Fingerprints: [String] = [
        "conditions of flight",
        "type of piloting time",
        "no. of inst. appr",
        "asa"
    ]

    static let row1Fingerprints: [String] = [
        "actual inst",
        "simulated inst",
        "cross country",
        "dual received",
        "pilot in command"
    ]

    static func detect(row0: String, row1: String) -> Bool {
        let r0 = row0.lowercased()
        let r1 = row1.lowercased()
        let row0Hits = row0Fingerprints.filter { r0.contains($0) }.count
        let row1Hits = row1Fingerprints.filter { r1.contains($0) }.count
        return row0Hits >= 2 || row1Hits >= 3
    }
}

// MARK: - ForeFlight Template

struct ForeFlightTemplate {
    static let name = "ForeFlight"
    static let isDoubleRowHeader = false

    static let aliases: [String: [String]] = [
        "date":                 ["date"],
        "aircraft_type":        ["aircraft type", "aircraft model"],
        "aircraft_ident":       ["tail number", "aircraft ident"],
        "route_from":           ["from"],
        "route_to":             ["to"],
        "route":                ["route"],
        "total_time":           ["total time", "total flight time"],
        "pic":                  ["pic"],
        "sic":                  ["sic"],
        "night":                ["night"],
        "instrument_actual":    ["actual instrument", "instrument"],
        "instrument_simulated": ["simulated instrument", "simulated"],
        "cross_country":        ["cross country", "xc"],
        "dual_received":        ["dual received", "dual"],
        "dual_given":           ["dual given", "flight instructor"],
        "solo":                 ["solo"],
        "landings_day":         ["day landings", "landings"],
        "landings_night":       ["night landings"],
        "approaches_count":     ["approaches"],
        "holds_count":          ["holds"],
        "remarks":              ["remarks", "comments"],
    ]

    static func findHeaderRow(in lines: [String]) -> Int {
        for (i, line) in lines.enumerated() {
            if line.lowercased().contains("date") && line.contains(",") { return i }
        }
        return 0
    }
}

// MARK: - LogTen Pro Template

struct LogTenProTemplate {
    static let name = "LogTen Pro"
    static let isDoubleRowHeader = false

    static let aliases: [String: [String]] = [
        "date":                 ["flight_flightdate", "date"],
        "aircraft_type":        ["aircraft_aircrafttype", "aircraft type"],
        "aircraft_ident":       ["aircraft_registration", "tail number"],
        "route_from":           ["flightplan_departure", "from"],
        "route_to":             ["flightplan_destination", "to"],
        "total_time":           ["flight_totaltime", "total time"],
        "pic":                  ["flight_pictime", "pic"],
        "sic":                  ["flight_sictime", "sic"],
        "night":                ["flight_nighttime", "night"],
        "instrument_actual":    ["flight_actualinstrumenttime", "actual instrument"],
        "instrument_simulated": ["flight_simulatedinstrumenttime", "simulated instrument"],
        "cross_country":        ["flight_crosscountrytime", "cross country"],
        "dual_received":        ["flight_dualreceivedtime", "dual received"],
        "dual_given":           ["flight_dualgiventime", "dual given"],
        "solo":                 ["flight_solotime", "solo"],
        "landings_day":         ["flight_daylandingsfullstop", "day landings"],
        "landings_night":       ["flight_nightlandingsfullstop", "night landings"],
        "approaches_count":     ["flight_instrumentapproaches", "approaches"],
        "remarks":              ["flight_remarks", "remarks"],
    ]
}

// MARK: - Template Registry

struct LogbookTemplateRegistry {

    /// Returns the merged alias table for the given import format.
    /// `canonicalColumnAliases` is defined in ImportModels.swift.
    static func aliasesFor(_ format: LogbookImportFormat) -> [String: [String]] {
        switch format {
        case .asa:        return merge(canonicalColumnAliases, ASATemplate.additionalAliases)
        case .foreFlight: return merge(canonicalColumnAliases, ForeFlightTemplate.aliases)
        case .logTenPro:  return merge(canonicalColumnAliases, LogTenProTemplate.aliases)
        default:          return canonicalColumnAliases
        }
    }

    private static func merge(_ a: [String: [String]],
                               _ b: [String: [String]]) -> [String: [String]] {
        var result = a
        for (k, v) in b { result[k] = (result[k] ?? []) + v }
        return result
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
