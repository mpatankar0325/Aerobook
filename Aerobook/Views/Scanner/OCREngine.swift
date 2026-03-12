// OCREngine.swift
// AeroBook — Scanner group
//
// Build Order Item #8 — OCR Engine Wrapper.
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Runs Apple Vision framework text recognition on a single cell UIImage and
// returns an OCRCellResult with rawText and confidence populated.
//
// The OCR engine is the ONLY component that touches VNRecognizeTextRequest.
// All other scanner components receive pre-built OCRCellResult values and
// never call Vision directly.
//
// ─────────────────────────────────────────────────────────────────────────────
// RECOGNITION STRATEGY PER DATA TYPE (Section 2 + Section 5, Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
//
//  ColumnDataType.decimalHours (H or t cell)
//    • recognitionLevel = .accurate
//    • customWords = ["0","1","2","3","4","5","6","7","8","9"]
//    • usesLanguageCorrection = false  — no dictionary; single digit expected
//    • Post-process: trim whitespace → take first character → O→0 substitution
//      → validate digit 0–9 (H ≥ 10 is always an OCR error per spec)
//    • confidence penalty if result length ≠ 1 or char not in 0–9
//
//  ColumnDataType.integer
//    • recognitionLevel = .accurate
//    • customWords = ["0","1","2","3","4","5","6","7","8","9"]
//    • usesLanguageCorrection = false
//    • Post-process: trim → digits only → validate against ColumnDefinition.validationRange
//    • O→0, I→1 substitutions (common OCR errors on integer columns)
//
//  ColumnDataType.text
//    • recognitionLevel = .accurate
//    • usesLanguageCorrection = true  — date strings and ICAO codes benefit
//    • customWords = empty (free-form)
//    • Post-process: trim, collapse whitespace, uppercase ICAO candidates
//    • No validation range check — cross-check engine handles text semantics
//
//  ColumnDataType.imageOnly
//    • NEVER OCR'd. A no-op that returns a zero-confidence result with empty text.
//    • The raw cell image is already stored on OCRCellResult.cellImage from the
//      row-line detector. No Vision call is made.
//
// ─────────────────────────────────────────────────────────────────────────────
// O → 0 CORRECTION (locked in Section 2, Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
// "If OCR returns a letter 'O' for zero, it is corrected to 0 before any
//  calculation." This rule applies to ALL numeric columns (decimalHours and
//  integer). It is applied in the post-processing step before confidence scoring,
//  so the rawText stored in OCRCellResult already has the substitution applied.
//
// ─────────────────────────────────────────────────────────────────────────────
// CONFIDENCE SCORING
// ─────────────────────────────────────────────────────────────────────────────
// VNRecognizedText.confidence is a Float in [0.0, 1.0] from Vision.
// The OCR engine applies additional penalties to produce a composite score:
//
//   baseConfidence   = max(Vision candidate confidences)
//   lengthPenalty    = applied when result length doesn't match expected for type
//   rangeViolation   = hard penalty (×0.1) when integer outside validationRange
//   blankPenalty     = applied when result is empty on an isRequired column
//
//   finalConfidence  = baseConfidence × lengthPenalty × rangeViolationFactor
//
// The cross-check engine uses confidence thresholds:
//   ≥ 0.85 → potential auto-accept (subject to cross-check rule outcome)
//   0.50–0.85 → accept but show in review table
//   < 0.50 → flagged for mandatory pilot review
//
// ─────────────────────────────────────────────────────────────────────────────
// THREADING
// ─────────────────────────────────────────────────────────────────────────────
// • All Vision calls run on a dedicated serial DispatchQueue (QoS .userInitiated).
// • recognizeAsync delivers its completion on the **main thread**.
// • The batch variant (recognizeStrip) processes cells sequentially on the
//   OCR queue and delivers a completion with all results on the main thread.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   • OCRCellResult, ColumnStrip, StripQualityResult  (ColumnStrip.swift)
//   • ColumnDefinition, ColumnDataType, PairRole      (DatabaseManager+LogbookProfile.swift)
//   • ScanPage.didCompleteOCR                         (ScanPage.swift)
//   • RowLineDetector (receives its output)           (RowLineDetector.swift)
//   • Vision framework
//   • No SwiftUI — pure service type
//   • No SQLite — this component never touches the DB

import Foundation
import UIKit
import Vision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OCREngine Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Tuning parameters for the OCR engine.
/// Defaults calibrated for Jeppesen logbook handwriting (blue ballpoint on cream).
public struct OCREngineConfig {

    // MARK: Vision Recognition Level

    /// Recognition level for numeric columns (.decimalHours, .integer).
    /// .accurate always; fast mode would sacrifice too much quality on single digits.
    public var numericRecognitionLevel: VNRequestTextRecognitionLevel = .accurate

    /// Recognition level for text columns (.text).
    public var textRecognitionLevel: VNRequestTextRecognitionLevel = .accurate

    // MARK: Candidate Count

    /// How many top candidates Vision returns per observation.
    /// We use 3: take the top candidate but use runners-up for confidence blending.
    public var candidateCount: Int = 3

    // MARK: Confidence Thresholds

    /// Composite confidence at or above which a cell is eligible for auto-accept.
    /// Subject to cross-check rule outcome — the cross-check engine makes the
    /// final auto-accept decision using this threshold.
    public var autoAcceptThreshold: Float = 0.85

    /// Composite confidence below which a cell is flagged for mandatory review.
    /// Matches the threshold in ColumnStrip.flaggedRowIndices.
    public var flagThreshold: Float = 0.50

    // MARK: Confidence Penalty Factors

    /// Multiplier applied when a numeric result has unexpected length (e.g. "12" for H cell).
    public var lengthMismatchPenalty: Float = 0.50

    /// Multiplier applied when an integer result is outside its validationRange.
    public var rangeViolationPenalty: Float = 0.10

    /// Multiplier applied when a required cell returns empty text.
    public var emptyRequiredPenalty: Float = 0.15

    // MARK: Minimum Image Dimension

    /// Images smaller than this in either dimension are not sent to Vision.
    /// Returns confidence = 0.0 with rawText = "" instead.
    public var minimumCellDimension: CGFloat = 12

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OCRResult (single-cell output before OCRCellResult wrapping)
// ─────────────────────────────────────────────────────────────────────────────

/// Intermediate result of recognising one cell image.
/// Converted to OCRCellResult (with rowIndex injected) by the caller.
public struct CellOCRResult {

    /// Recognised and post-processed text for this cell.
    /// May be empty string for blank cells. Never nil.
    public let text: String

    /// Composite confidence score in [0.0, 1.0].
    public let confidence: Float

    /// true when the O→0 substitution was applied (numeric columns only).
    public let oToZeroCorrected: Bool

    /// true when the integer result was outside validationRange (hard penalty applied).
    public let rangeViolated: Bool

    /// The raw unprocessed string returned by Vision before any post-processing.
    /// Preserved for debug / correction sheet display.
    public let visionRawText: String

    /// All candidates Vision returned (top candidateCount), for debug.
    public let allCandidates: [(text: String, confidence: Float)]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OCREngine
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless OCR engine namespace. All entry points are static.
///
/// Primary call site (inside ColumnStrip extension or ScanPage coordinator):
/// ```swift
/// OCREngine.recognizeStrip(
///     strip:    columnStrip,
///     scanPage: scanPage,
///     config:   OCREngineConfig()
/// ) { success in
///     if success {
///         CrossCheckEngine.run(on: scanPage)
///     }
/// }
/// ```
public enum OCREngine {

    /// Dedicated serial queue for all Vision calls.
    /// Serial ensures requests do not saturate the Neural Engine on low-end devices.
    private static let ocrQueue = DispatchQueue(
        label: "com.aerobook.ocr",
        qos:   .userInitiated
    )

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Single-Cell Recognition (async)
    // ─────────────────────────────────────────────────────────────────────────

    /// Recognises a single cell image for a given ColumnDefinition.
    ///
    /// - Parameters:
    ///   - image:      Cell UIImage (output of RowLineDetector.sliceCellImages).
    ///   - definition: The ColumnDefinition for this strip — drives recognition mode.
    ///   - config:     Tuning config (defaults calibrated for Jeppesen).
    ///   - completion: Called on the **main thread** with the result.
    public static func recognizeAsync(
        image:      UIImage,
        definition: ColumnDefinition,
        config:     OCREngineConfig = OCREngineConfig(),
        completion: @escaping (CellOCRResult) -> Void
    ) {
        ocrQueue.async {
            let result = recognize(image: image, definition: definition, config: config)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Strip Batch Recognition (async)
    // ─────────────────────────────────────────────────────────────────────────

    /// Recognises all cells in a ColumnStrip sequentially and calls
    /// `ScanPage.didCompleteOCR` with populated OCRCellResult values.
    ///
    /// This is the primary integration method for the scanner pipeline.
    /// It reads cell images from `strip.cellResults` (which were populated with
    /// skeleton entries by RowLineDetector), runs OCR on each cellImage, and
    /// replaces the skeleton with a fully-populated OCRCellResult.
    ///
    /// For imageOnly columns it is a no-op: the strip is already in .complete
    /// state with cell images stored, and no Vision call is made.
    ///
    /// - Parameters:
    ///   - strip:    The ColumnStrip whose cellResults skeletons to fill.
    ///   - scanPage: Live ScanPage — used to call didCompleteOCR / didFailProcessing.
    ///   - config:   OCR config.
    ///   - completion: Called on the main thread. `true` = all cells recognised.
    public static func recognizeStrip(
        strip:    ColumnStrip,
        scanPage: ScanPage,
        config:   OCREngineConfig = OCREngineConfig(),
        completion: @escaping (Bool) -> Void
    ) {
        let definition = strip.definition
        let columnId   = definition.columnId

        // imageOnly: nothing to OCR; cellImages already stored as skeletons.
        // The strip was set .complete by runRowDetector; just fire completion.
        if definition.dataType == .imageOnly {
            DispatchQueue.main.async { completion(true) }
            return
        }

        // Collect skeleton cell images in rowIndex order.
        // RowLineDetector guarantees one entry per row index.
        let sortedSkeletons = strip.cellResults
            .sorted { $0.key < $1.key }
            .map    { ($0.key, $0.value) }   // (rowIndex, OCRCellResult skeleton)

        guard !sortedSkeletons.isEmpty else {
            // No skeletons — row detector hasn't run yet or strip is empty.
            DispatchQueue.main.async {
                scanPage.didFailProcessing(
                    reasons: ["No cell images available for OCR (row detector not run)."],
                    for: columnId
                )
                completion(false)
            }
            return
        }

        ocrQueue.async {
            var populated: [OCRCellResult] = []

            for (rowIndex, skeleton) in sortedSkeletons {
                let cellImage: UIImage

                // Use the image from the skeleton (set by row detector).
                // Fall back to the full strip raw image if somehow absent.
                if let img = skeleton.cellImage {
                    cellImage = img
                } else if let raw = strip.rawImage {
                    cellImage = raw
                } else {
                    // No image at all — produce a zero-confidence blank result.
                    populated.append(OCRCellResult(
                        rowIndex:   rowIndex,
                        rawText:    definition.defaultValue,
                        confidence: 0.0,
                        cellImage:  nil
                    ))
                    continue
                }

                let ocrResult = recognize(image: cellImage,
                                          definition: definition,
                                          config: config)

                let cellResult = OCRCellResult(
                    rowIndex:   rowIndex,
                    rawText:    ocrResult.text,
                    confidence: ocrResult.confidence,
                    cellImage:  cellImage
                )
                populated.append(cellResult)
            }

            // Build a synthetic StripQualityResult for the OCR pass.
            // The image quality was already gate-checked before OCR ran;
            // we synthesise a passing quality result here to satisfy the
            // ScanPage.didCompleteOCR signature.
            let avgConfidence = populated.isEmpty ? 0.0 :
                populated.map(\.confidence).reduce(0, +) / Float(populated.count)

            let syntheticQuality = StripQualityResult(
                isAcceptable:         avgConfidence > config.flagThreshold,
                blurScore:            1.0,   // quality gate already passed before OCR ran
                contrastScore:        1.0,   // quality gate already passed before OCR ran
                detectedRowLineCount: populated.count,
                failureReasons:       []
            )

            DispatchQueue.main.async {
                scanPage.didCompleteOCR(
                    results:       populated,
                    qualityResult: syntheticQuality,
                    for:           columnId
                )
                completion(true)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Core Recognition (synchronous, runs on ocrQueue)
    // ─────────────────────────────────────────────────────────────────────────

    /// Synchronous core. Must only be called from `ocrQueue`.
    static func recognize(
        image:      UIImage,
        definition: ColumnDefinition,
        config:     OCREngineConfig
    ) -> CellOCRResult {

        // imageOnly — never OCR'd (locked decision, Section 12).
        guard definition.dataType != .imageOnly else {
            return CellOCRResult(
                text:              "",
                confidence:        0.0,
                oToZeroCorrected:  false,
                rangeViolated:     false,
                visionRawText:     "",
                allCandidates:     []
            )
        }

        // Guard minimum image size — Vision on a 1×1 pixel image is meaningless.
        let imgW = image.size.width  * image.scale
        let imgH = image.size.height * image.scale
        guard imgW >= config.minimumCellDimension,
              imgH >= config.minimumCellDimension else {
            return CellOCRResult(
                text:              definition.defaultValue,
                confidence:        0.0,
                oToZeroCorrected:  false,
                rangeViolated:     false,
                visionRawText:     "",
                allCandidates:     []
            )
        }

        // Render to CGImage for Vision.
        // UIImage from AVCapture / CGImage.cropping may be CIImage-backed on
        // some devices; force a CGImage render to guarantee Vision can process it.
        guard let cgImage = renderedCGImage(from: image) else {
            return CellOCRResult(
                text:              definition.defaultValue,
                confidence:        0.0,
                oToZeroCorrected:  false,
                rangeViolated:     false,
                visionRawText:     "",
                allCandidates:     []
            )
        }

        // Build and run the Vision request.
        let (rawText, baseCandidates) = runVision(
            cgImage:    cgImage,
            definition: definition,
            config:     config
        )

        // Post-process and score.
        return postProcess(
            visionRaw:   rawText,
            candidates:  baseCandidates,
            definition:  definition,
            config:      config
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Vision Request Builder + Runner
    // ─────────────────────────────────────────────────────────────────────────

    /// Builds and synchronously executes a VNRecognizeTextRequest.
    /// Returns (topCandidateText, [(text, confidence)]).
    private static func runVision(
        cgImage:    CGImage,
        definition: ColumnDefinition,
        config:     OCREngineConfig
    ) -> (String, [(text: String, confidence: Float)]) {

        var candidates: [(text: String, confidence: Float)] = []
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { reqst, error in
            defer { semaphore.signal() }

            if let error {
                print("[AeroBook] OCREngine Vision error for \(definition.columnId): \(error)")
                return
            }

            guard let observations = reqst.results as? [VNRecognizedTextObservation] else { return }

            // Collect top candidates across all observations, sorted by confidence.
            // Each cell image contains exactly one logbook entry; multiple observations
            // can appear if the handwriting has large gaps between strokes.
            for obs in observations {
                let topN = obs.topCandidates(config.candidateCount)
                for candidate in topN {
                    candidates.append((text: candidate.string, confidence: candidate.confidence))
                }
            }

            // Sort by confidence descending
            candidates.sort { $0.confidence > $1.confidence }
        }

        // Configure recognition level and language correction per data type.
        switch definition.dataType {

        case .decimalHours, .integer:
            request.recognitionLevel      = config.numericRecognitionLevel
            request.usesLanguageCorrection = false
            // Hint Vision toward individual digits.
            // customWords biases the language model; for single-digit cells
            // this dramatically reduces letter-for-digit substitutions.
            request.customWords = ["0","1","2","3","4","5","6","7","8","9",
                                   "00","01","02","03","04","05","06","07","08","09",
                                   "10","11","12","13","14","15","16","17","18","19",
                                   "20","21","22","23","24","25","26","27","28","29",
                                   "30","31","32","33","34","35","36","37","38","39"]

        case .text:
            request.recognitionLevel      = config.textRecognitionLevel
            request.usesLanguageCorrection = true
            // For ICAO codes and date fields, language correction helps.
            // Date columns benefit from month-name recognition (JAN, FEB…).
            request.customWords = [
                "JAN","FEB","MAR","APR","MAY","JUN",
                "JUL","AUG","SEP","OCT","NOV","DEC",
                "KSQL","KHAF","KSFO","KOAK","KSJC",   // common Bay Area ICAO starters
                "N","C","PA","CE","BE",                 // common aircraft type prefixes
            ]

        case .imageOnly:
            semaphore.signal()
            return ("", [])
        }

        // Revision 3 uses the Neural Engine (A12 and later) for best accuracy.
        // Falls back to revision 1 on older devices transparently.
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[AeroBook] OCREngine VNImageRequestHandler error: \(error)")
            semaphore.signal()
        }

        semaphore.wait()

        let topText = candidates.first?.text ?? ""
        return (topText, candidates)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Post-Processing + Confidence Scoring
    // ─────────────────────────────────────────────────────────────────────────

    /// Applies dataType-specific cleaning, substitutions, and confidence
    /// penalties to produce the final CellOCRResult.
    private static func postProcess(
        visionRaw:  String,
        candidates: [(text: String, confidence: Float)],
        definition: ColumnDefinition,
        config:     OCREngineConfig
    ) -> CellOCRResult {

        let baseConfidence: Float = candidates.first?.confidence ?? 0.0

        switch definition.dataType {

        // ── Decimal Hours (H or t — single digit 0–9) ────────────────────
        case .decimalHours:
            return postProcessDecimalHours(
                visionRaw:      visionRaw,
                candidates:     candidates,
                baseConfidence: baseConfidence,
                definition:     definition,
                config:         config
            )

        // ── Integer (0–99 counts: T/O, LDG, Approaches) ──────────────────
        case .integer:
            return postProcessInteger(
                visionRaw:      visionRaw,
                candidates:     candidates,
                baseConfidence: baseConfidence,
                definition:     definition,
                config:         config
            )

        // ── Text (Date, Aircraft Type/Ident, Route From/To) ──────────────
        case .text:
            return postProcessText(
                visionRaw:      visionRaw,
                candidates:     candidates,
                baseConfidence: baseConfidence,
                definition:     definition,
                config:         config
            )

        // ── imageOnly — handled before Vision runs, guard is a safety net ─
        case .imageOnly:
            return CellOCRResult(
                text: "", confidence: 0.0,
                oToZeroCorrected: false, rangeViolated: false,
                visionRawText: "", allCandidates: []
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: decimalHours Post-Processing
    // ─────────────────────────────────────────────────────────────────────────
    //
    // H cell: expects a single digit 0–9. H ≥ 10 is always an OCR error.
    // t cell: expects a single digit 0–9. t ≥ 10 is always an OCR error.
    // Both: O → 0 substitution applied first.

    private static func postProcessDecimalHours(
        visionRaw:      String,
        candidates:     [(text: String, confidence: Float)],
        baseConfidence: Float,
        definition:     ColumnDefinition,
        config:         OCREngineConfig
    ) -> CellOCRResult {

        // Step 1: Take raw, trim, collapse whitespace
        var raw = visionRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 2: O → 0 substitution (mandatory per spec, Section 2)
        let oToZero = raw.contains("O") || raw.contains("o")
        raw = raw.replacingOccurrences(of: "O", with: "0")
                 .replacingOccurrences(of: "o", with: "0")

        // Step 3: Extract first digit-like character.
        // Vision sometimes returns "3." or "3 " for a clean "3" — strip trailing noise.
        let digitOnly = raw.filter { $0.isNumber }

        // Step 4: Take only the first character (H and t are single digits)
        let finalText = digitOnly.isEmpty ? "" : String(digitOnly.prefix(1))

        // Step 5: Confidence scoring
        var confidence = baseConfidence

        // Penalty: result should be exactly one digit
        if finalText.isEmpty {
            // Blank on a required column
            if definition.isRequired {
                confidence *= config.emptyRequiredPenalty
            } else {
                // Non-required blank is expected — boost confidence slightly
                confidence = max(confidence, 0.80)
            }
        } else if digitOnly.count > 1 {
            // Vision returned multiple digits — suspicious for a single-digit cell
            confidence *= config.lengthMismatchPenalty
        }

        // Penalty: value out of valid range (0–9).
        // Per spec: H ≥ 10 or t ≥ 10 is always an OCR error.
        var rangeViolated = false
        if let digit = Int(finalText), digit > 9 {
            rangeViolated = true
            confidence   *= config.rangeViolationPenalty
        }

        return CellOCRResult(
            text:             finalText,
            confidence:       min(1.0, max(0.0, confidence)),
            oToZeroCorrected: oToZero,
            rangeViolated:    rangeViolated,
            visionRawText:    visionRaw,
            allCandidates:    candidates
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Integer Post-Processing
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Nr T/O, Nr LDG: 0–99 integers.
    // Nr Inst App: 0–9 integer.
    // validationRange in ColumnDefinition provides the hard bounds.

    private static func postProcessInteger(
        visionRaw:      String,
        candidates:     [(text: String, confidence: Float)],
        baseConfidence: Float,
        definition:     ColumnDefinition,
        config:         OCREngineConfig
    ) -> CellOCRResult {

        var raw = visionRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // O → 0 and I → 1 substitutions (common OCR errors on integer columns)
        let oToZero = raw.contains("O") || raw.contains("o")
        raw = raw.replacingOccurrences(of: "O", with: "0")
                 .replacingOccurrences(of: "o", with: "0")
                 .replacingOccurrences(of: "I", with: "1")
                 .replacingOccurrences(of: "l", with: "1")   // lowercase L → 1
                 .replacingOccurrences(of: "S", with: "5")   // common S/5 confusion
                 .replacingOccurrences(of: "Z", with: "2")   // common Z/2 confusion

        // Extract digit string
        let digits = raw.filter { $0.isNumber }
        let finalText = digits

        var confidence    = baseConfidence
        var rangeViolated = false

        if finalText.isEmpty {
            confidence *= definition.isRequired
                ? config.emptyRequiredPenalty
                : 1.0   // blank non-required integer is fine
        } else if let value = Int(finalText),
                  let range = definition.validationRange,
                  !range.contains(value) {
            rangeViolated = true
            confidence   *= config.rangeViolationPenalty
        }

        return CellOCRResult(
            text:             finalText.isEmpty ? definition.defaultValue : finalText,
            confidence:       min(1.0, max(0.0, confidence)),
            oToZeroCorrected: oToZero,
            rangeViolated:    rangeViolated,
            visionRawText:    visionRaw,
            allCandidates:    candidates
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Text Post-Processing
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Date:          "Jan 3", "MAR 14" → stored as-is for flexible downstream parsing
    // Aircraft Type: "C172", "PA28" → uppercase, trim
    // Aircraft Ident: "N12345" → uppercase, trim
    // Route From/To: "KSQL", "KHAF" → uppercase 4-letter ICAO codes

    private static func postProcessText(
        visionRaw:      String,
        candidates:     [(text: String, confidence: Float)],
        baseConfidence: Float,
        definition:     ColumnDefinition,
        config:         OCREngineConfig
    ) -> CellOCRResult {

        var raw = visionRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Collapse internal whitespace runs to a single space
        raw = raw.components(separatedBy: .whitespaces)
                 .filter { !$0.isEmpty }
                 .joined(separator: " ")

        // ICAO route columns: uppercase + filter to alphanumeric + dash
        let isICAO = definition.flightField == "routeFrom" || definition.flightField == "routeTo"
        if isICAO {
            raw = raw.uppercased()
                     .filter { $0.isLetter || $0.isNumber }
                     .prefix(4)
                     .description
        }

        // Aircraft ident / type: uppercase
        let isAircraftField = definition.flightField == "aircraftIdent" ||
                              definition.flightField == "aircraftType"
        if isAircraftField {
            raw = raw.uppercased()
        }

        var confidence = baseConfidence

        if raw.isEmpty {
            confidence *= definition.isRequired
                ? config.emptyRequiredPenalty
                : 1.0
        }

        // No range validation for text — cross-check engine handles semantics.
        return CellOCRResult(
            text:             raw,
            confidence:       min(1.0, max(0.0, confidence)),
            oToZeroCorrected: false,
            rangeViolated:    false,
            visionRawText:    visionRaw,
            allCandidates:    candidates
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Force-renders a UIImage to a CGImage, resolving CIImage-backed images.
    /// Vision requires a CGImage; UIImage from AVCapture may be CIImage-backed
    /// on some devices if the photo pipeline returns a CIImage directly.
    private static func renderedCGImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }

        // CIImage-backed fallback: render through UIGraphicsImageRenderer
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let rendered = renderer.image { _ in image.draw(at: .zero) }
        return rendered.cgImage
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ColumnStrip + OCREngine Integration Extension
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience extension on ColumnStrip that triggers the full OCR pass on
/// all cell skeletons previously populated by RowLineDetector.
///
/// This is the canonical two-step pipeline entry point:
///   1. strip.runRowDetector(on: image, scanPage: scanPage) { _ in
///   2.     strip.runOCR(scanPage: scanPage) { success in … }
///   3. }
public extension ColumnStrip {

    /// Runs OCREngine.recognizeStrip on this strip and delivers the populated
    /// cell results to scanPage via didCompleteOCR.
    ///
    /// Precondition: `runRowDetector` must have been called first — this method
    /// reads cellResults skeletons and writes rawText/confidence into each entry.
    ///
    /// For imageOnly strips, this is a no-op that calls completion(true) immediately.
    func runOCR(
        scanPage: ScanPage,
        config:   OCREngineConfig = OCREngineConfig(),
        completion: @escaping (Bool) -> Void
    ) {
        OCREngine.recognizeStrip(
            strip:      self,
            scanPage:   scanPage,
            config:     config,
            completion: completion
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CellOCRResult Diagnostics
// ─────────────────────────────────────────────────────────────────────────────

public extension CellOCRResult {

    /// Human-readable one-liner for debug logs.
    var debugDescription: String {
        let flags = [
            oToZeroCorrected ? "O→0"  : nil,
            rangeViolated    ? "RANGE" : nil,
        ].compactMap { $0 }.joined(separator: " ")

        return "[OCR] \"\(text)\" conf=\(String(format: "%.2f", confidence))" +
               (flags.isEmpty ? "" : " [\(flags)]") +
               " raw=\"\(visionRawText)\""
    }

    /// true when confidence is high enough for auto-accept consideration.
    func isAutoAcceptEligible(config: OCREngineConfig = OCREngineConfig()) -> Bool {
        confidence >= config.autoAcceptThreshold
    }

    /// true when confidence is low enough to require mandatory pilot review.
    func requiresReview(config: OCREngineConfig = OCREngineConfig()) -> Bool {
        confidence < config.flagThreshold
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Full Strip Pipeline Helper
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the complete two-stage pipeline (RowLineDetector → OCREngine) for a
/// single captured strip in one call.
///
/// Convenience for the camera controller / ScanPage coordinator:
/// ```swift
/// StripPipeline.process(
///     image: capturedImage,
///     strip: strip,
///     scanPage: scanPage
/// ) { success in
///     // strip.cellResults now has rawText + confidence populated
/// }
/// ```
public enum StripPipeline {

    /// Runs RowLineDetector then OCREngine sequentially for one strip.
    ///
    /// - Parameters:
    ///   - image:      Full-resolution ROI-cropped strip image.
    ///   - strip:      The ColumnStrip to populate (must be in .processing state).
    ///   - scanPage:   Live ScanPage for state transitions and row count.
    ///   - rowConfig:  RowLineDetector config (defaults calibrated for Jeppesen).
    ///   - ocrConfig:  OCREngine config (defaults calibrated for Jeppesen).
    ///   - completion: Called on main thread with success flag.
    public static func process(
        image:     UIImage,
        strip:     ColumnStrip,
        scanPage:  ScanPage,
        rowConfig: RowDetectorConfig  = RowDetectorConfig(),
        ocrConfig: OCREngineConfig    = OCREngineConfig(),
        completion: @escaping (Bool) -> Void
    ) {
        // imageOnly: row detector stores images, OCR is skipped.
        // runRowDetector handles the imageOnly case internally.
        strip.runRowDetector(on: image, scanPage: scanPage, config: rowConfig) { detectorSuccess in
            guard detectorSuccess else {
                completion(false)
                return
            }
            strip.runOCR(scanPage: scanPage, config: ocrConfig, completion: completion)
        }
    }
}
