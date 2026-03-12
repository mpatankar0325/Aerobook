// ImportModels.swift
// AeroBook
//
// ── SINGLE SOURCE OF TRUTH ─────────────────────────────────────────────────
// All import-pipeline shared types live here ONLY.
//
// DO NOT re-declare LogbookImportFormat, ParsedFlightRecord, or
// LogbookImportResult in any other file — doing so causes the
// "ambiguous for type lookup" and "ambiguous use of init" compiler errors
// you saw in ExcelImporter.swift, JeppesenASATemplates.swift, and
// LogbookImportService.swift.
//
// Files that reference these types:
//   • ExcelImporter.swift           (uses ParsedFlightRecord, LogbookImportResult)
//   • LogbookImportService.swift    (uses all three)
//   • JeppesenASATemplates.swift    (uses LogbookImportFormat, ParsedFlightRecord)
//   • ImportReviewView.swift        (uses all three)
//   • LogbookImporter.swift         ← DELETE THIS FILE — it is a duplicate of
//                                     ImportReviewView.swift with the same types.
// ───────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Logbook Import Format

enum LogbookImportFormat: String, CaseIterable, Identifiable {
    case autoDetect = "Auto-Detect"
    case foreFlight = "ForeFlight"
    case logTenPro  = "LogTen Pro"
    case jeppesen   = "Jeppesen"
    case asa        = "ASA"
    case garmin     = "Garmin Pilot"
    case genericCSV = "Generic CSV"
    case excel      = "Excel / XLSX"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .autoDetect: return "wand.and.stars"
        case .foreFlight: return "airplane"
        case .logTenPro:  return "book.closed.fill"
        case .jeppesen:   return "book.fill"
        case .asa:        return "graduationcap.fill"
        case .garmin:     return "antenna.radiowaves.left.and.right"
        case .genericCSV: return "tablecells.fill"
        case .excel:      return "tablecells.badge.ellipsis"
        }
    }

    var description: String {
        switch self {
        case .autoDetect: return "Detects format automatically"
        case .foreFlight: return "ForeFlight CSV backup export"
        case .logTenPro:  return "LogTen Pro standard CSV export"
        case .jeppesen:   return "Jeppesen Professional Pilot Logbook"
        case .asa:        return "ASA standard logbook"
        case .garmin:     return "Garmin Pilot flight log CSV"
        case .genericCSV: return "Any CSV with recognisable headers"
        case .excel:      return "Excel / XLSX with double-row headers"
        }
    }

    var supportsDoubleRowHeader: Bool {
        switch self {
        case .jeppesen, .asa, .excel, .autoDetect: return true
        default: return false
        }
    }
}

// MARK: - Parsed Flight Record
//
// Uses stored-property defaults (Swift 5.9+) so callers can do either:
//   var r = ParsedFlightRecord()           — zero-value record
//   var r = ParsedFlightRecord(date: "…")  — memberwise init
//
// The canonical init is the synthesised memberwise one.
// If you need `init(id:isSelected:)` anywhere, define it as an extension
// in the file that needs it — do NOT add a custom init here, as mixing
// memberwise + custom init on a struct breaks call sites in other files.

struct ParsedFlightRecord: Identifiable {
    let id: UUID           = UUID()
    var isSelected: Bool   = true

    // Identity
    var date:             String = ""
    var aircraftIdent:    String = ""
    var aircraftType:     String = ""
    var aircraftCategory: String = "Airplane"
    var aircraftClass:    String = "SEL"

    // Route — kept as one combined string for the DB.
    // `routeFrom` and `routeTo` are intermediate fields used during parsing only.
    var route:     String = ""
    var routeFrom: String = ""   // intermediate — not persisted directly
    var routeTo:   String = ""   // intermediate — not persisted directly

    // Hours
    var totalTime:            Double = 0
    var pic:                  Double = 0
    var sic:                  Double = 0
    var solo:                 Double = 0
    var dualReceived:         Double = 0
    var dualGiven:            Double = 0
    var crossCountry:         Double = 0
    var night:                Double = 0
    var instrumentActual:     Double = 0
    var instrumentSimulated:  Double = 0
    var flightSim:            Double = 0

    // Operations
    var takeoffsDay:      Int = 0   // day takeoffs (Jeppesen col 7)
    var takeoffsNight:    Int = 0   // night takeoffs (Jeppesen col 9)
    var takeoffs:         Int = 0   // generic (non-Jeppesen) total takeoffs
    var landingsDay:      Int = 0
    var landingsNight:    Int = 0
    var approachesCount:  Int = 0
    var holdsCount:       Int = 0

    // Metadata
    var remarks:        String   = ""
    var importWarnings: [String] = []
    var sourceFormat:   String   = ""
}

// MARK: - Logbook Import Result

struct LogbookImportResult {
    var records:        [ParsedFlightRecord]
    var warnings:       [String]
    var skippedCount:   Int
    var detectedFormat: LogbookImportFormat
}

// MARK: - Canonical Column Aliases
//
// Used by LogbookTemplateRegistry.aliasesFor(_:) in JeppesenASATemplates.swift.
// Each key is a DB column name; each value is the list of header strings that
// map to it (lowercased, after collapsing whitespace).

let canonicalColumnAliases: [String: [String]] = [
    "date":                 ["date", "flight date", "date of flight"],
    "aircraft_type":        ["aircraft type", "type", "make and model", "make/model",
                             "type of aircraft", "aircraft make & model"],
    "aircraft_ident":       ["aircraft ident", "ident", "tail number", "tail no",
                             "registration", "n-number", "n number", "aircraft id"],
    "route":                ["route", "route of flight", "airports"],
    "route_from":           ["from", "departure", "origin", "dept airport",
                             "from airport", "dep airport", "dep"],
    "route_to":             ["to", "destination", "dest airport", "to airport",
                             "arrival", "arr airport"],
    "total_time":           ["total time", "total", "total flight time",
                             "total duration", "total flight duration",
                             "total time of flight", "flight time", "duration",
                             "block time", "hours"],
    "pic":                  ["pic", "p.i.c", "p.i.c.", "pilot in command",
                             "pilot-in-command"],
    "sic":                  ["sic", "s.i.c", "second in command",
                             "second-in-command", "co-pilot", "copilot"],
    "solo":                 ["solo", "solo time", "solo flight", "student solo"],
    "dual_received":        ["dual received", "dual recv", "dual rec'd",
                             "dual rcv", "student", "dual"],
    "dual_given":           ["dual given", "as flight instructor", "as instructor",
                             "cfi time", "flight instructor", "instructor"],
    "cross_country":        ["cross country", "cross-country", "xc", "x/c", "cc",
                             "x-country"],
    "night":                ["night", "night time", "night flying",
                             "conditions of flight night", "night conditions"],
    "instrument_actual":    ["actual instrument", "actual inst", "imc",
                             "instrument actual", "conditions actual", "actual",
                             "ifr conditions", "act inst"],
    "instrument_simulated": ["simulated instrument", "simulated inst", "hood",
                             "sim inst", "instrument sim", "foggles", "sim imc",
                             "conditions sim", "simulated"],
    "flight_sim":           ["flight sim", "flight simulator", "simulator",
                             "ftd", "pcatd", "atd", "ffs", "sim",
                             "ground trainer", "ground training", "sim time"],
    "landings_day":         ["landings day", "day landings", "ldg", "ldgs",
                             "landings", "nr ldg", "# ldg day", "ldg day"],
    "landings_night":       ["landings night", "night landings", "night ldg",
                             "# ldg night", "ldg night"],
    "takeoffs":             ["takeoffs", "take-offs", "take offs", "t/o",
                             "nr t/o", "nr to"],
    "approaches_count":     ["approaches", "approach", "inst app", "iap",
                             "nr inst app", "app", "apps",
                             "# inst appr", "no of inst appr", "no. of inst. appr",
                             "inst approaches"],
    "holds_count":          ["holds", "hold"],
    "remarks":              ["remarks", "remarks and endorsements",
                             "remarks & endorsements", "comments", "lesson",
                             "notes", "endorsement"],
    "instructor_name":      ["instructor name", "cfi name"],
]
