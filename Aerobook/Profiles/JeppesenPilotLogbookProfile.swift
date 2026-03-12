// JeppesenPilotLogbookProfile.swift
// AeroBook — Profiles group
//
// Pure Swift model data. Zero database imports.
// Contains the pre-built LogbookProfile for the Jeppesen Pilot Logbook
// (part number JS506161, landscape spread format, 13 data rows per page).
//
// This file is the canonical source for:
//   • All 22 logical columns (30 ColumnDefinitions — 14 H+t pairs × 2 + 8 singles + 1 image)
//   • captureOrder assignments for all 5 scanner phases
//   • pairId / pairRole links for every H+t pair
//   • flightField strings matching the Flight DB schema (verified against ManualEntryView.swift)
//   • validationRange for every numeric cell
//   • 8 CrossCheckRules from the AeroBook Scanner Architecture document Section 4
//
// ─────────────────────────────────────────────────────────────────────────────
// Column Map Summary (Section 2 of Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
//
// Phase 1 — Anchor (captureOrder 1–3)
//   total_duration_hours (H)      captureOrder 1
//   total_duration_tenths (t)     captureOrder 2
//   date                          captureOrder 3
//
// Phase 2 — Cross-check (captureOrder 4–9)
//   dual_received_hours (H)       captureOrder 4
//   dual_received_tenths (t)      captureOrder 5
//   pic_hours (H)                 captureOrder 6
//   pic_tenths (t)                captureOrder 7
//   category_se_hours (H)         captureOrder 8
//   category_se_tenths (t)        captureOrder 9
//
// Phase 3 — Remaining time columns (captureOrder 10–27)
//   cross_country_hours           10
//   cross_country_tenths          11
//   night_hours                   12
//   night_tenths                  13
//   instrument_actual_hours       14
//   instrument_actual_tenths      15
//   instrument_sim_hours          16
//   instrument_sim_tenths         17
//   flight_sim_hours              18
//   flight_sim_tenths             19
//   dual_given_hours              20
//   dual_given_tenths             21
//   category_me_hours             22
//   category_me_tenths            23
//   class_se_hours                24
//   class_se_tenths               25
//   class_me_hours                26
//   class_me_tenths               27
//
// Phase 4 — Text & counts (captureOrder 28–34)
//   aircraft_type                 28
//   aircraft_ident                29
//   route_from                    30
//   route_to                      31
//   approaches_count              32
//   takeoffs_count                33
//   landings_day_count            34
//
// Phase 5 — Image only (captureOrder 35)
//   remarks_image                 35
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

public extension LogbookProfile {

    /// The Jeppesen Pilot Logbook pre-built profile.
    /// This value is seeded into the DB on first launch by
    /// `DatabaseManager.seedBuiltInProfilesIfNeeded()`.
    static var jeppesenPilotLogbook: LogbookProfile {
        LogbookProfile(
            id:             UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            name:           "Jeppesen Pilot Logbook",
            publisher:      "Jeppesen",
            dataRowCount:   13,
            totalsRowCount: 3,
            headerLevels:   3,
            pageLayout:     .landscapeSpread,
            columns:        jeppesenColumns,
            crossCheckRules: jeppesenCrossCheckRules,
            createdAt:      Date(timeIntervalSince1970: 0), // epoch — stable seed date
            isBuiltIn:      true
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Columns
    // ─────────────────────────────────────────────────────────────────────────

    private static var jeppesenColumns: [ColumnDefinition] {
        [
            // ═══════════════════════════════════════════════════════════════
            // PHASE 1 — ANCHOR
            // Total Duration is captured first: it establishes row count and
            // provides the primary value all Phase 2 columns cross-check against.
            // Date is captured immediately after to tag the row identity.
            // ═══════════════════════════════════════════════════════════════

            // Total Duration — H cell
            // Captures the integer hours portion of total flight time for the entry.
            // pairId "total_duration" links this to its tenths partner below.
            ColumnDefinition(
                columnId:       "total_duration_hours",
                groupLabel:     "Total Duration",
                subLabel:       "of Flight",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "total_duration",
                pairRole:       .hours,
                flightField:    "total_time",
                captureOrder:   1,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Total Duration — t cell
            // Captures the tenths-of-hour portion. Combined with H cell: value = H.t hours.
            // An OCR result outside 0–9 on either half flags the whole pair immediately.
            ColumnDefinition(
                columnId:       "total_duration_tenths",
                groupLabel:     "Total Duration",
                subLabel:       "of Flight",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "total_duration",
                pairRole:       .tenths,
                flightField:    "total_time",
                captureOrder:   2,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Date
            // Free-form text column — accepts "MMM D" format (e.g. "JAN 5").
            // Date carry-forward: if this cell is blank, it inherits the date from
            // the last non-blank Date cell above it in the same page scan.
            ColumnDefinition(
                columnId:       "date",
                groupLabel:     "Date",
                subLabel:       "",
                unitLabel:      "",
                dataType:       .text,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "date",
                captureOrder:   3,
                isRequired:     true,
                validationRange: nil,
                defaultValue:   ""
            ),

            // ═══════════════════════════════════════════════════════════════
            // PHASE 2 — CROSS-CHECK
            // Dual Received, PIC, and Category SE are captured next so the
            // 5-way cross-check (student_5way_match rule) can run immediately.
            // If all five match, the entire row is auto-accepted without the
            // pilot needing to review individual cells.
            // ═══════════════════════════════════════════════════════════════

            // Dual Received — H cell
            // Hours of dual instruction received during the flight.
            // The most common non-zero piloting time for student pilots.
            ColumnDefinition(
                columnId:       "dual_received_hours",
                groupLabel:     "Piloting Time",
                subLabel:       "Dual Received",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "dual_received",
                pairRole:       .hours,
                flightField:    "dual_received",
                captureOrder:   4,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Dual Received — t cell
            // Tenths portion of dual instruction time received.
            ColumnDefinition(
                columnId:       "dual_received_tenths",
                groupLabel:     "Piloting Time",
                subLabel:       "Dual Received",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "dual_received",
                pairRole:       .tenths,
                flightField:    "dual_received",
                captureOrder:   5,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // PIC — H cell
            // Hours logged as Pilot in Command (includes solo for student pilots).
            // Cross-checked against Total Duration in the 5-way match rule.
            ColumnDefinition(
                columnId:       "pic_hours",
                groupLabel:     "Piloting Time",
                subLabel:       "PIC (incl. Solo)",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "pic",
                pairRole:       .hours,
                flightField:    "pic",
                captureOrder:   6,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // PIC — t cell
            // Tenths portion of PIC time.
            ColumnDefinition(
                columnId:       "pic_tenths",
                groupLabel:     "Piloting Time",
                subLabel:       "PIC (incl. Solo)",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "pic",
                pairRole:       .tenths,
                flightField:    "pic",
                captureOrder:   7,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Category — Single Engine Land — H cell
            // Hours in single-engine land aircraft. Cross-checked against Total,
            // Dual, and PIC in the 5-way match (student_5way_match rule).
            ColumnDefinition(
                columnId:       "category_se_hours",
                groupLabel:     "Aircraft Category",
                subLabel:       "Single Engine",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "category_se",
                pairRole:       .hours,
                flightField:    "single_engine_land",
                captureOrder:   8,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Category — Single Engine Land — t cell
            // Tenths portion of single-engine category time.
            ColumnDefinition(
                columnId:       "category_se_tenths",
                groupLabel:     "Aircraft Category",
                subLabel:       "Single Engine",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "category_se",
                pairRole:       .tenths,
                flightField:    "single_engine_land",
                captureOrder:   9,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // ═══════════════════════════════════════════════════════════════
            // PHASE 3 — REMAINING TIME COLUMNS
            // Lower-frequency columns that enrich the record. Cross-checks on
            // these columns use medium or low confidence — they flag outliers
            // but do not block commit.
            // ═══════════════════════════════════════════════════════════════

            // Cross Country — H cell
            // Hours flown to or from a point more than 50 nm from departure.
            // Must be ≤ Total Duration (xc_lte_total rule).
            ColumnDefinition(
                columnId:       "cross_country_hours",
                groupLabel:     "Piloting Time",
                subLabel:       "Cross Country",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "cross_country",
                pairRole:       .hours,
                flightField:    "cross_country",
                captureOrder:   10,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Cross Country — t cell
            ColumnDefinition(
                columnId:       "cross_country_tenths",
                groupLabel:     "Piloting Time",
                subLabel:       "Cross Country",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "cross_country",
                pairRole:       .tenths,
                flightField:    "cross_country",
                captureOrder:   11,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Night — H cell
            // Hours logged after end of evening civil twilight. Must be ≤ Total
            // (total_gte_components rule).
            ColumnDefinition(
                columnId:       "night_hours",
                groupLabel:     "Condition",
                subLabel:       "Night",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "night",
                pairRole:       .hours,
                flightField:    "night",
                captureOrder:   12,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Night — t cell
            ColumnDefinition(
                columnId:       "night_tenths",
                groupLabel:     "Condition",
                subLabel:       "Night",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "night",
                pairRole:       .tenths,
                flightField:    "night",
                captureOrder:   13,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Actual Instrument — H cell
            // Hours in actual IMC conditions. Must be ≤ Total. If Nr Inst App > 0
            // then at least one of Actual Inst or Sim Inst must be > 0
            // (approach_requires_instrument rule).
            ColumnDefinition(
                columnId:       "instrument_actual_hours",
                groupLabel:     "Condition",
                subLabel:       "Actual Instrument",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "instrument_actual",
                pairRole:       .hours,
                flightField:    "instrument_actual",
                captureOrder:   14,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Actual Instrument — t cell
            ColumnDefinition(
                columnId:       "instrument_actual_tenths",
                groupLabel:     "Condition",
                subLabel:       "Actual Instrument",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "instrument_actual",
                pairRole:       .tenths,
                flightField:    "instrument_actual",
                captureOrder:   15,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Simulated Instrument — H cell
            // Hours under the hood or in a BATD/AATD. Must be ≤ Total.
            // Used in both total_gte_components and approach_requires_instrument rules.
            ColumnDefinition(
                columnId:       "instrument_sim_hours",
                groupLabel:     "Condition",
                subLabel:       "Simulated Instrument",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "instrument_sim",
                pairRole:       .hours,
                flightField:    "instrument_simulated",
                captureOrder:   16,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Simulated Instrument — t cell
            ColumnDefinition(
                columnId:       "instrument_sim_tenths",
                groupLabel:     "Condition",
                subLabel:       "Simulated Instrument",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "instrument_sim",
                pairRole:       .tenths,
                flightField:    "instrument_simulated",
                captureOrder:   17,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Flight Simulator — H cell
            // Hours in a certified FFS, FTD, or ATD. Not required — most student
            // and general aviation entries leave this blank.
            // sim_exclusive rule: if > 0, all aircraft category columns must be 0.
            ColumnDefinition(
                columnId:       "flight_sim_hours",
                groupLabel:     "Flight Simulator",
                subLabel:       "",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "flight_sim",
                pairRole:       .hours,
                flightField:    "flight_sim",
                captureOrder:   18,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Flight Simulator — t cell
            ColumnDefinition(
                columnId:       "flight_sim_tenths",
                groupLabel:     "Flight Simulator",
                subLabel:       "",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "flight_sim",
                pairRole:       .tenths,
                flightField:    "flight_sim",
                captureOrder:   19,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // As Flight Instructor (CFI / Dual Given) — H cell
            // Hours logged as a certificated flight instructor giving dual instruction.
            // cfi_requires_aircraft rule: if > 0 then Category SE or ME must also be > 0.
            ColumnDefinition(
                columnId:       "dual_given_hours",
                groupLabel:     "Piloting Time",
                subLabel:       "As Flight Instructor",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "dual_given",
                pairRole:       .hours,
                flightField:    "dual_given",
                captureOrder:   20,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // As Flight Instructor — t cell
            ColumnDefinition(
                columnId:       "dual_given_tenths",
                groupLabel:     "Piloting Time",
                subLabel:       "As Flight Instructor",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "dual_given",
                pairRole:       .tenths,
                flightField:    "dual_given",
                captureOrder:   21,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Category — Multi Engine Land — H cell
            // Not required: most student pilots fly single-engine only; this column
            // is left blank for the vast majority of entries.
            // sim_exclusive rule: if Flight Sim > 0, this must be 0.
            ColumnDefinition(
                columnId:       "category_me_hours",
                groupLabel:     "Aircraft Category",
                subLabel:       "Multi Engine",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "category_me",
                pairRole:       .hours,
                flightField:    "multi_engine_land",
                captureOrder:   22,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Category — Multi Engine Land — t cell
            ColumnDefinition(
                columnId:       "category_me_tenths",
                groupLabel:     "Aircraft Category",
                subLabel:       "Multi Engine",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "category_me",
                pairRole:       .tenths,
                flightField:    "multi_engine_land",
                captureOrder:   23,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Class — Single Engine Land — H cell
            // Must equal Category Single Engine (single_engine_class_match rule).
            // Treated as a cross-check column — data written to a separate field for
            // audit purposes but typically mirrors category_se exactly.
            ColumnDefinition(
                columnId:       "class_se_hours",
                groupLabel:     "Class",
                subLabel:       "Single Engine",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "class_se",
                pairRole:       .hours,
                flightField:    "class_single_engine",
                captureOrder:   24,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Class — Single Engine Land — t cell
            ColumnDefinition(
                columnId:       "class_se_tenths",
                groupLabel:     "Class",
                subLabel:       "Single Engine",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "class_se",
                pairRole:       .tenths,
                flightField:    "class_single_engine",
                captureOrder:   25,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Class — Multi Engine Land — H cell
            // Not required: mirrors multi-engine category; most students leave blank.
            ColumnDefinition(
                columnId:       "class_me_hours",
                groupLabel:     "Class",
                subLabel:       "Multi Engine",
                unitLabel:      "H",
                dataType:       .decimalHours,
                pairId:         "class_me",
                pairRole:       .hours,
                flightField:    "class_multi_engine",
                captureOrder:   26,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Aircraft Class — Multi Engine Land — t cell
            ColumnDefinition(
                columnId:       "class_me_tenths",
                groupLabel:     "Class",
                subLabel:       "Multi Engine",
                unitLabel:      "t",
                dataType:       .decimalHours,
                pairId:         "class_me",
                pairRole:       .tenths,
                flightField:    "class_multi_engine",
                captureOrder:   27,
                isRequired:     false,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // ═══════════════════════════════════════════════════════════════
            // PHASE 4 — TEXT & COUNT COLUMNS
            // Text OCR is the least reliable; these are captured last so that
            // time-column cross-checks have already established row alignment.
            // Aircraft registry lookup provides a secondary confidence check.
            // ═══════════════════════════════════════════════════════════════

            // Aircraft Type (Make / Model)
            // Free-form text: typically a short ICAO type code (e.g. "C172", "PA28").
            // Matched against an optional pilot aircraft registry for higher confidence.
            ColumnDefinition(
                columnId:       "aircraft_type",
                groupLabel:     "Aircraft",
                subLabel:       "Type",
                unitLabel:      "",
                dataType:       .text,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "aircraft_type",
                captureOrder:   28,
                isRequired:     true,
                validationRange: nil,
                defaultValue:   ""
            ),

            // Aircraft Identification (Tail Number)
            // Registration mark written in the logbook (e.g. "N12345").
            // Used as one of three fields in duplicate detection at commit time.
            ColumnDefinition(
                columnId:       "aircraft_ident",
                groupLabel:     "Aircraft",
                subLabel:       "Ident",
                unitLabel:      "",
                dataType:       .text,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "aircraft_ident",
                captureOrder:   29,
                isRequired:     true,
                validationRange: nil,
                defaultValue:   ""
            ),

            // Route of Flight — From (departure ICAO or common name)
            // Combined with routeTo into a "route" display string in the DB.
            // Text OCR — confirmed by pilot if no registry match.
            ColumnDefinition(
                columnId:       "route_from",
                groupLabel:     "Route of Flight",
                subLabel:       "From",
                unitLabel:      "",
                dataType:       .text,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "route_from",
                captureOrder:   30,
                isRequired:     true,
                validationRange: nil,
                defaultValue:   ""
            ),

            // Route of Flight — To (destination ICAO or common name)
            ColumnDefinition(
                columnId:       "route_to",
                groupLabel:     "Route of Flight",
                subLabel:       "To",
                unitLabel:      "",
                dataType:       .text,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "route_to",
                captureOrder:   31,
                isRequired:     true,
                validationRange: nil,
                defaultValue:   ""
            ),

            // Nr Instrument Approaches
            // Integer 0–9. If > 0, at least one of Actual or Sim Instrument must
            // also be > 0 (approach_requires_instrument rule — low confidence flag).
            ColumnDefinition(
                columnId:       "approaches_count",
                groupLabel:     "Nr Inst App",
                subLabel:       "",
                unitLabel:      "",
                dataType:       .integer,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "approaches_count",
                captureOrder:   32,
                isRequired:     true,
                validationRange: 0...9,
                defaultValue:   "0"
            ),

            // Nr Takeoffs
            // Integer 0–99. Typically 1 per flight; ferry or pattern work may be higher.
            ColumnDefinition(
                columnId:       "takeoffs_count",
                groupLabel:     "Nr T/O",
                subLabel:       "",
                unitLabel:      "",
                dataType:       .integer,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "takeoffs",
                captureOrder:   33,
                isRequired:     true,
                validationRange: 0...99,
                defaultValue:   "0"
            ),

            // Nr Day Landings
            // Integer 0–99. Combines with night landings for currency calculations.
            ColumnDefinition(
                columnId:       "landings_day_count",
                groupLabel:     "Nr LDG",
                subLabel:       "Day",
                unitLabel:      "",
                dataType:       .integer,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "landings_day",
                captureOrder:   34,
                isRequired:     true,
                validationRange: 0...99,
                defaultValue:   "0"
            ),

            // ═══════════════════════════════════════════════════════════════
            // PHASE 5 — IMAGE ONLY
            // Remarks & Endorsements is never passed to OCR. The full-column
            // image is stored at the path in remarksImagePath. The pilot can
            // type a summary manually in the review screen if desired.
            // ═══════════════════════════════════════════════════════════════

            // Remarks & Endorsements — image capture only
            // Stores the raw image of the remarks cell for each row so endorsements
            // are preserved exactly as handwritten. No OCR ever runs on this column.
            ColumnDefinition(
                columnId:       "remarks_image",
                groupLabel:     "Remarks & Endors.",
                subLabel:       "",
                unitLabel:      "",
                dataType:       .imageOnly,
                pairId:         nil,
                pairRole:       .none,
                flightField:    "remarks_image_path",
                captureOrder:   35,
                isRequired:     false,
                validationRange: nil,
                defaultValue:   ""
            ),
        ]
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Cross-Check Rules
    // ─────────────────────────────────────────────────────────────────────────
    //
    // All 8 rules from Section 4 of AeroBook Scanner Architecture document.
    // Rules are evaluated by the generic cross-check engine in captureOrder
    // after the pilot completes their chosen phases. High-confidence passes
    // auto-accept participating fields. Only failures surface in the review table.
    //
    // Field arrays reference columnId strings — not flightField strings.
    // ─────────────────────────────────────────────────────────────────────────

    private static var jeppesenCrossCheckRules: [CrossCheckRule] {
        [
            // ── Rule 1: Student 5-Way Match ───────────────────────────────
            // The dominant pattern for student pilots: Category SE = Dual Received
            // = PIC = Total Duration (and Date must be present).
            // When all four time values match, the entire row auto-accepts.
            // Represents ~99% of typical student logbook entries.
            CrossCheckRule(
                ruleId:         "student_5way_match",
                description:    "Date present; Category SE = Dual Received = PIC = Total Duration",
                fields:         [
                    "date",
                    "category_se_hours",   "category_se_tenths",
                    "dual_received_hours", "dual_received_tenths",
                    "pic_hours",           "pic_tenths",
                    "total_duration_hours","total_duration_tenths"
                ],
                operator:       .allEqual,
                confidence:     .high,
                onFail:         .flagFields,
                applicability:  .always
            ),

            // ── Rule 2: Single Engine Category = Single Engine Class ───────
            // The Jeppesen Pilot Logbook has separate Category and Class columns.
            // For single-engine land operations these must always be equal.
            // A mismatch is almost always an OCR error on one column.
            CrossCheckRule(
                ruleId:         "single_engine_class_match",
                description:    "Category Single Engine must equal Class Single Engine",
                fields:         [
                    "category_se_hours", "category_se_tenths",
                    "class_se_hours",    "class_se_tenths"
                ],
                operator:       .allEqual,
                confidence:     .high,
                onFail:         .flagFields,
                applicability:  .always
            ),

            // ── Rule 3: Total ≥ Component Times ───────────────────────────
            // Night, Actual Instrument, and Simulated Instrument are all subsets
            // of total flight time. Any component exceeding Total is an OCR error.
            // Three separate field-pair checks encoded as one rule; the engine
            // evaluates each adjacent pair with .lte semantics.
            CrossCheckRule(
                ruleId:         "total_gte_components",
                description:    "Total ≥ Night; Total ≥ Actual Instrument; Total ≥ Sim Instrument",
                fields:         [
                    "night_hours",            "night_tenths",
                    "instrument_actual_hours","instrument_actual_tenths",
                    "instrument_sim_hours",   "instrument_sim_tenths",
                    "total_duration_hours",   "total_duration_tenths"
                ],
                operator:       .lte,
                confidence:     .medium,
                onFail:         .flagFields,
                applicability:  .always
            ),

            // ── Rule 4: Cross Country ≤ Total ─────────────────────────────
            // Cross-country time cannot exceed total flight duration.
            // Flagged at medium confidence — a violation is very likely an OCR
            // error, not genuine pilot data.
            CrossCheckRule(
                ruleId:         "xc_lte_total",
                description:    "Cross Country must be ≤ Total Duration",
                fields:         [
                    "cross_country_hours",  "cross_country_tenths",
                    "total_duration_hours", "total_duration_tenths"
                ],
                operator:       .lte,
                confidence:     .medium,
                onFail:         .flagFields,
                applicability:  .always
            ),

            // ── Rule 5: CFI Time Requires an Aircraft Category ─────────────
            // An instructor cannot give dual in mid-air — if Dual Given > 0, the
            // flight must have been in an aircraft (Category SE or ME > 0).
            // Flight Sim time with instructor is handled by the sim_exclusive rule.
            CrossCheckRule(
                ruleId:         "cfi_requires_aircraft",
                description:    "If Dual Given > 0 then Category SE or Category ME must be > 0",
                fields:         [
                    "dual_given_hours",   "dual_given_tenths",
                    "category_se_hours",  "category_se_tenths",
                    "category_me_hours",  "category_me_tenths"
                ],
                operator:       .gtZeroRequires,
                confidence:     .medium,
                onFail:         .flagFields,
                applicability:  .always
            ),

            // ── Rule 6: Flight Simulator Exclusive ────────────────────────
            // A flight simulator session is not an aircraft flight. If Flight Sim > 0
            // then all aircraft category columns must be 0.
            // High confidence: a violation is impossible by definition.
            CrossCheckRule(
                ruleId:         "sim_exclusive",
                description:    "If Flight Simulator > 0 then all aircraft category columns must be 0",
                fields:         [
                    "flight_sim_hours",  "flight_sim_tenths",
                    "category_se_hours", "category_se_tenths",
                    "category_me_hours", "category_me_tenths"
                ],
                operator:       .gtZeroRequires,
                confidence:     .high,
                onFail:         .flagFields,
                applicability:  .ifBlank("flight_sim_hours")
            ),

            // ── Rule 7: Approaches Require Instrument Time ────────────────
            // If instrument approaches were flown, the pilot must have logged
            // either Actual Instrument or Simulated Instrument time.
            // Low confidence: edge cases exist (VFR practice approaches),
            // so the rule flags for review but never blocks commit.
            CrossCheckRule(
                ruleId:         "approach_requires_instrument",
                description:    "If Nr Inst App > 0 then Actual Instrument or Simulated Instrument must be > 0",
                fields:         [
                    "approaches_count",
                    "instrument_actual_hours", "instrument_actual_tenths",
                    "instrument_sim_hours",    "instrument_sim_tenths"
                ],
                operator:       .gtZeroRequires,
                confidence:     .low,
                onFail:         .flagRow,
                applicability:  .ifBlank("approaches_count")
            ),

            // ── Rule 8: Blank Row Detection ───────────────────────────────
            // If Total Duration is blank or zero the row is empty (a ruled line
            // with no entry). Skip it — do not include it in the review table
            // and do not commit it to the flights database.
            // This handles partial pages and unused rows near the end of a logbook.
            CrossCheckRule(
                ruleId:         "blank_row_detection",
                description:    "Total Duration blank or 0 → treat row as empty and skip",
                fields:         [
                    "total_duration_hours",
                    "total_duration_tenths"
                ],
                operator:       .allEqual,
                confidence:     .high,
                onFail:         .skipRow,
                applicability:  .always
            ),
        ]
    }
}
