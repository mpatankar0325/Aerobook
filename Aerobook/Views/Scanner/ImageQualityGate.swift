// ImageQualityGate.swift
// AeroBook — Scanner group
//
// Build Order Item #4 — Image Quality Gate.
//
// Runs four ordered checks on a captured UIImage strip before OCR is attempted.
// A bad image sent to OCR produces garbage results that cost the pilot correction
// time. It is always better to reject and retake than to accept a bad strip.
//
// Checks run in order (Section 10 of Strategy Doc):
//   1. Blur detection     — Laplacian variance below threshold → retake
//   2. Contrast check     — mean pixel intensity too high or too low → retake
//   3. Row-line detection — expected ruled lines not found → retake
//   4. Row count sanity   — detected rows differ from profile dataRowCount by > 1 → warn
//
// What is NOT checked (Section 10, locked decisions):
//   • Per-row ink presence — blank rows are detected by Total Duration = 0, not ink
//   • Handwriting style or slant — the OCR engine handles this
//
// Threading:
//   • `ImageQualityGate.check(...)` is a blocking call intended to run on a
//     background DispatchQueue (userInitiated QoS). Never call from the main thread.
//   • The async variant `ImageQualityGate.checkAsync(...)` dispatches internally
//     and delivers the result on the main thread via a completion handler.
//
// Depends on: ScanPage model (StripQualityResult, ColumnStrip) from Build Item #3.

import UIKit
import Accelerate
import Vision

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quality Gate Thresholds
// ─────────────────────────────────────────────────────────────────────────────

/// Tunable thresholds for the image quality gate.
/// All values are empirically calibrated for iPhone cameras shooting a
/// Jeppesen logbook page under typical indoor lighting conditions.
/// Changing these values does not require a code change — pass a custom
/// `ImageQualityGate.Thresholds` to `check(image:profile:thresholds:)`.
public struct QualityGateThresholds {

    // MARK: Blur (Laplacian variance)

    /// Normalised Laplacian variance below which the strip is considered too blurry.
    /// Range [0, 1]. Empirically: < 0.15 = blurry, > 0.35 = sharp.
    /// Default: 0.20 — slightly lenient to account for narrow strips.
    public var blurMinScore: Float = 0.20

    // MARK: Contrast (mean pixel intensity)

    /// Mean greyscale intensity below which the image is considered underexposed.
    /// Range [0, 255]. Below 30 the ink lines are invisible to OCR.
    public var contrastMinIntensity: Float = 30.0

    /// Mean greyscale intensity above which the image is considered washed out.
    /// Range [0, 255]. Above 230 the ruled lines wash out in the white paper.
    public var contrastMaxIntensity: Float = 230.0

    // MARK: Row-line detection (Hough horizontal lines)

    /// Fraction of image width a horizontal edge segment must span to be counted
    /// as a ruled line. Filters out short ink marks and partial lines.
    /// Range [0, 1]. Default: 0.60 — must span at least 60% of strip width.
    public var rowLineMinWidthFraction: Double = 0.60

    /// Minimum pixel contrast (0–255) for a horizontal scan to register a line edge.
    /// Lower values catch faint ruled lines; higher values reduce false positives.
    public var rowLineEdgeThreshold: UInt8 = 18

    // MARK: Row count sanity

    /// Maximum allowed difference between detected row count and profile.dataRowCount
    /// before the gate issues a soft warning (not a hard failure).
    /// The pilot can override and proceed; the gate does not block on count mismatch.
    public var rowCountToleranceDelta: Int = 1

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quality Gate Failure
// ─────────────────────────────────────────────────────────────────────────────

/// Describes one specific quality gate failure.
/// Multiple failures can occur on a single strip — all are collected and shown
/// to the pilot in the retake prompt so they can correct the right thing.
public struct QualityGateFailure: Equatable {

    /// Machine-readable failure category.
    public enum Category: String, Equatable {
        case tooBlurry
        case underexposed
        case washout
        case rowLinesNotFound
        case rowCountMismatch    // Soft warning — does not block, just advises.
    }

    public let category: Category

    /// Pilot-facing message shown in the retake banner.
    public let pilotMessage: String

    /// Suggested corrective action shown as a subtitle.
    public let suggestion: String

    /// true for hard failures that block OCR from running.
    /// false for soft warnings (rowCountMismatch) that the pilot can override.
    public var isHardFailure: Bool {
        category != .rowCountMismatch
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quality Gate Result
// ─────────────────────────────────────────────────────────────────────────────

/// The complete result of running the image quality gate on one strip.
/// Written to `ColumnStrip.qualityResult` by the scanner pipeline.
public struct QualityGateResult {

    // MARK: Raw Metrics (always populated regardless of pass/fail)

    /// Normalised Laplacian variance in [0, 1]. Higher = sharper.
    public let blurScore: Float

    /// Mean greyscale pixel intensity in [0, 255].
    public let meanIntensity: Float

    /// Number of candidate horizontal ruled lines detected in the strip.
    public let detectedRowLineCount: Int

    /// The profile's expected data row count used for sanity comparison.
    public let expectedRowCount: Int

    // MARK: Gate Decision

    /// All failures detected. Empty array = gate passed completely.
    public let failures: [QualityGateFailure]

    /// true when there are no hard failures — OCR may proceed.
    /// A result with only soft warnings (rowCountMismatch) is still acceptable.
    public var isAcceptable: Bool {
        !failures.contains { $0.isHardFailure }
    }

    /// true when isAcceptable AND there are no warnings of any kind.
    public var isClean: Bool {
        failures.isEmpty
    }

    /// The single most important failure to surface in the UI (first hard failure,
    /// or first warning if no hard failures).
    public var primaryFailure: QualityGateFailure? {
        failures.first { $0.isHardFailure } ?? failures.first
    }

    /// All pilot-facing messages, formatted as a single string for logging.
    public var failureSummary: String {
        failures.isEmpty
            ? "Pass"
            : failures.map { $0.pilotMessage }.joined(separator: "; ")
    }

    // MARK: Convenience label for UI

    /// Human-readable sharpness label matching the existing SpreadScannerView style.
    public var sharpnessLabel: String {
        switch blurScore {
        case 0.70...:        return "Excellent"
        case 0.50..<0.70:   return "Good"
        case 0.20..<0.50:   return "Acceptable"
        default:             return "Too Blurry"
        }
    }

    /// Human-readable exposure label.
    public var exposureLabel: String {
        if meanIntensity < 30  { return "Underexposed" }
        if meanIntensity > 230 { return "Overexposed"  }
        if meanIntensity < 80  { return "Dark"         }
        if meanIntensity > 200 { return "Bright"       }
        return "Good"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ImageQualityGate
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless service that runs all four quality checks on a captured strip image.
///
/// Usage — synchronous (must run on a background thread):
/// ```swift
/// let result = ImageQualityGate.check(image: capturedImage,
///                                     expectedRowCount: profile.dataRowCount)
/// if result.isAcceptable {
///     // proceed to OCR
/// } else {
///     // surface result.primaryFailure to the pilot
/// }
/// ```
///
/// Usage — async (can call from any thread, delivers on main):
/// ```swift
/// ImageQualityGate.checkAsync(image: capturedImage,
///                             expectedRowCount: profile.dataRowCount) { result in
///     // runs on main thread
///     scanPage.didCompleteQualityGate(result: result, for: columnId)
/// }
/// ```
public enum ImageQualityGate {

    // MARK: - Entry Points

    /// Synchronous check. Blocks the calling thread. Run on a background queue.
    ///
    /// - Parameters:
    ///   - image: The captured strip UIImage from the ROI camera overlay.
    ///   - expectedRowCount: `profile.dataRowCount` — the pilot-confirmed row count.
    ///   - thresholds: Tunable thresholds. Pass default for standard operation.
    /// - Returns: A fully populated `QualityGateResult`.
    public static func check(
        image: UIImage,
        expectedRowCount: Int,
        thresholds: QualityGateThresholds = QualityGateThresholds()
    ) -> QualityGateResult {

        // ── 1. Render a normalised greyscale pixel buffer for all checks ───
        let bufferSize = CGSize(width: 512, height: 1024) // Tall aspect — strips are narrow and tall
        guard let (pixels, width, height) = greyscalePixelBuffer(from: image, size: bufferSize) else {
            // If we can't decode the image at all, treat as hard failure.
            return QualityGateResult(
                blurScore:            0,
                meanIntensity:        0,
                detectedRowLineCount: 0,
                expectedRowCount:     expectedRowCount,
                failures: [
                    QualityGateFailure(
                        category:     .tooBlurry,
                        pilotMessage: "Could not decode image",
                        suggestion:   "Try capturing the strip again"
                    )
                ]
            )
        }

        // ── 2. Run all metrics in one pass over the pixel buffer ──────────
        let blurScore      = computeBlurScore(pixels: pixels, width: width, height: height)
        let meanIntensity  = computeMeanIntensity(pixels: pixels)
        let detectedLines  = detectHorizontalRowLines(
            pixels:           pixels,
            width:            width,
            height:           height,
            minWidthFraction: thresholds.rowLineMinWidthFraction,
            edgeThreshold:    thresholds.rowLineEdgeThreshold
        )

        // ── 3. Evaluate each check in spec order, collect failures ────────
        var failures: [QualityGateFailure] = []

        // Check 1 — Blur
        if blurScore < thresholds.blurMinScore {
            failures.append(QualityGateFailure(
                category:     .tooBlurry,
                pilotMessage: "Image too blurry",
                suggestion:   "Hold your phone steady and retake"
            ))
        }

        // Check 2a — Underexposed
        if meanIntensity < thresholds.contrastMinIntensity {
            failures.append(QualityGateFailure(
                category:     .underexposed,
                pilotMessage: "Image too dark",
                suggestion:   "Move to better lighting or turn on torch and retake"
            ))
        }

        // Check 2b — Washed out
        if meanIntensity > thresholds.contrastMaxIntensity {
            failures.append(QualityGateFailure(
                category:     .washout,
                pilotMessage: "Image washed out",
                suggestion:   "Reduce direct light on the page and retake"
            ))
        }

        // Check 3 — Row-line detection
        // Expected: dataRowCount + totalsRowCount + 1 header separator.
        // We check for at least (dataRowCount - 1) lines — one or two faint lines
        // at top/bottom may not be detected; we are lenient here to avoid
        // frustrating retakes on slightly angled shots.
        let minimumExpectedLines = max(expectedRowCount - 1, 1)
        if detectedLines < minimumExpectedLines {
            failures.append(QualityGateFailure(
                category:     .rowLinesNotFound,
                pilotMessage: "Can't detect rows",
                suggestion:   "Align the column within the guide and retake"
            ))
        }

        // Check 4 — Row count sanity (soft warning — never blocks)
        let countDelta = abs(detectedLines - expectedRowCount)
        if countDelta > thresholds.rowCountToleranceDelta && detectedLines >= minimumExpectedLines {
            failures.append(QualityGateFailure(
                category:     .rowCountMismatch,
                pilotMessage: "Found \(detectedLines) rows, expected \(expectedRowCount)",
                suggestion:   "Confirm row count before proceeding"
            ))
        }

        return QualityGateResult(
            blurScore:            blurScore,
            meanIntensity:        meanIntensity,
            detectedRowLineCount: detectedLines,
            expectedRowCount:     expectedRowCount,
            failures:             failures
        )
    }

    /// Async wrapper. Dispatches the check to a `.userInitiated` background queue,
    /// then delivers the result on the main thread. Safe to call from any thread.
    ///
    /// - Parameters:
    ///   - image: The captured strip UIImage.
    ///   - expectedRowCount: `profile.dataRowCount`.
    ///   - thresholds: Tunable thresholds. Pass default for standard operation.
    ///   - completion: Called on the **main thread** with the gate result.
    public static func checkAsync(
        image: UIImage,
        expectedRowCount: Int,
        thresholds: QualityGateThresholds = QualityGateThresholds(),
        completion: @escaping (QualityGateResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = check(
                image:            image,
                expectedRowCount: expectedRowCount,
                thresholds:       thresholds
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Check 1: Blur Detection (Laplacian Variance)
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes a normalised sharpness score using Laplacian variance.
    ///
    /// Algorithm:
    ///   1. Apply the discrete 5-point Laplacian kernel to every interior pixel.
    ///      Kernel: [0, 1, 0 / 1, -4, 1 / 0, 1, 0]
    ///   2. Compute the variance of the Laplacian response values.
    ///   3. Normalise: variance / 400.0, clamped to [0, 1].
    ///
    /// A sharp image has high-contrast edges → high Laplacian response → high variance.
    /// A blurry image has smooth gradients → low Laplacian response → low variance.
    ///
    /// Empirical calibration on Jeppesen logbook photos:
    ///   • > 0.50 → Excellent (sharp ink lines, clean ruled lines)
    ///   • 0.20–0.50 → Acceptable (mild hand-shake or slight defocus)
    ///   • < 0.20 → Too blurry (OCR error rate unacceptably high)
    ///
    /// Uses vDSP (Accelerate framework) for the mean/variance computation,
    /// matching the existing implementation in SpreadScannerView.swift.
    private static func computeBlurScore(pixels: [UInt8], width: Int, height: Int) -> Float {
        var laplacian = [Float](repeating: 0, count: width * height)

        // Apply 5-point Laplacian: top + bottom + left + right - 4*center
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Float(pixels[y * width + x])
                let top    = Float(pixels[(y - 1) * width + x])
                let bottom = Float(pixels[(y + 1) * width + x])
                let left   = Float(pixels[y * width + (x - 1)])
                let right  = Float(pixels[y * width + (x + 1)])
                laplacian[y * width + x] = abs(top + bottom + left + right - 4.0 * center)
            }
        }

        // Variance via vDSP: var = mean((x - mean(x))^2)
        var mean: Float = 0
        var variance: Float = 0
        let n = vDSP_Length(laplacian.count)

        vDSP_meanv(laplacian, 1, &mean, n)

        // Subtract mean from every element
        var negMean = -mean
        var demeaned = [Float](repeating: 0, count: laplacian.count)
        vDSP_vsadd(laplacian, 1, &negMean, &demeaned, 1, n)

        // Square each element
        var squared = [Float](repeating: 0, count: laplacian.count)
        vDSP_vsq(demeaned, 1, &squared, 1, n)

        // Mean of squared values = variance
        vDSP_meanv(squared, 1, &variance, n)

        // Normalise: empirically, variance ~400 = very sharp, ~30 = blurry.
        return min(variance / 400.0, 1.0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Check 2: Contrast (Mean Pixel Intensity)
    // ─────────────────────────────────────────────────────────────────────────

    /// Computes the mean greyscale pixel intensity over the entire pixel buffer.
    ///
    /// Returns a value in [0, 255].
    ///   • Very low (< 30): the strip is nearly black — underexposed or in shadow.
    ///     OCR cannot distinguish ink from background.
    ///   • Very high (> 230): the strip is nearly white — washed out by direct light.
    ///     Ruled lines and ink both disappear; OCR reads blank.
    ///   • Normal range is approximately 100–190 for a logbook page in typical
    ///     indoor office or kitchen lighting.
    private static func computeMeanIntensity(pixels: [UInt8]) -> Float {
        // Convert to Float for vDSP, then compute mean.
        var floatPixels = [Float](repeating: 0, count: pixels.count)
        vDSP_vfltu8(pixels, 1, &floatPixels, 1, vDSP_Length(pixels.count))

        var mean: Float = 0
        vDSP_meanv(floatPixels, 1, &mean, vDSP_Length(floatPixels.count))
        return mean
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Check 3+4: Row-Line Detection
    // ─────────────────────────────────────────────────────────────────────────

    /// Detects horizontal ruled lines in the strip image using a horizontal
    /// edge-scan approach.
    ///
    /// Algorithm:
    ///   1. For each row of pixels (y scanline), compute the maximum absolute
    ///      difference between adjacent pixels across the row.
    ///   2. If the maximum difference exceeds `edgeThreshold`, mark the scanline
    ///      as containing a candidate horizontal edge.
    ///   3. Merge adjacent candidate scanlines within a 3-pixel vertical band
    ///      into a single detected line (avoids counting one thick ruled line twice).
    ///   4. Filter: only count candidate lines that span at least `minWidthFraction`
    ///      of the strip width (short ink marks and partial lines are excluded).
    ///
    /// This approach is chosen over a full Hough transform because:
    ///   • Jeppesen ruled lines are always strictly horizontal (portrait capture).
    ///   • Row-level scanning is O(width × height) — fast enough for 512×1024 on device.
    ///   • No dependency on OpenCV or additional frameworks.
    ///
    /// - Returns: Count of detected horizontal ruled lines.
    private static func detectHorizontalRowLines(
        pixels: [UInt8],
        width: Int,
        height: Int,
        minWidthFraction: Double,
        edgeThreshold: UInt8
    ) -> Int {

        let minSpanPixels = Int(Double(width) * minWidthFraction)
        var candidateRows = [Bool](repeating: false, count: height)

        // Pass 1: mark each scanline that contains a strong horizontal edge
        // spanning at least minSpanPixels consecutive edge pixels.
        for y in 0..<height {
            let rowStart = y * width
            var spanCount = 0
            var maxSpan   = 0

            for x in 1..<width {
                let diff = absDiff(pixels[rowStart + x], pixels[rowStart + x - 1])
                if diff >= edgeThreshold {
                    spanCount += 1
                    maxSpan = max(maxSpan, spanCount)
                } else {
                    spanCount = 0
                }
            }

            candidateRows[y] = (maxSpan >= minSpanPixels)
        }

        // Pass 2: merge adjacent candidate scanlines into single ruled lines.
        // A ruled line printed at 600 dpi on an iPhone image is typically 2–4px tall.
        var lineCount      = 0
        var inLine         = false
        var suppressBand   = 0      // pixels to suppress after a line is counted

        for y in 0..<height {
            if suppressBand > 0 {
                suppressBand -= 1
                inLine = candidateRows[y] // stay in line if edge continues
                continue
            }

            if candidateRows[y] {
                if !inLine {
                    lineCount += 1
                    inLine      = true
                    suppressBand = 3  // suppress next 3 rows to avoid double-counting
                }
            } else {
                inLine = false
            }
        }

        return lineCount
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Pixel Buffer Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Renders a UIImage to a greyscale UInt8 pixel buffer at the given size.
    ///
    /// Downsampling to a fixed size before analysis keeps all checks O(constant)
    /// regardless of the source resolution — a 48MP camera and a 12MP camera
    /// both produce the same 512×1024 buffer for analysis.
    ///
    /// Returns (pixels, width, height) or nil if the image cannot be decoded.
    private static func greyscalePixelBuffer(
        from image: UIImage,
        size: CGSize
    ) -> ([UInt8], Int, Int)? {

        let w = Int(size.width)
        let h = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: w * h)

        guard let ctx = CGContext(
            data:             &pixels,
            width:            w,
            height:           h,
            bitsPerComponent: 8,
            bytesPerRow:      w,
            space:            CGColorSpaceCreateDeviceGray(),
            bitmapInfo:       CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Draw the image into the greyscale context (automatic colour conversion).
        guard let cgImage = image.cgImage else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return (pixels, w, h)
    }

    /// Absolute difference between two UInt8 values without wrapping.
    @inline(__always)
    private static func absDiff(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a > b ? a - b : b - a
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanPage Integration
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience extension on ScanPage that runs the quality gate for a captured
/// strip and updates the strip's state and the page's scanState accordingly.
///
/// This is the canonical call site used by the camera layer (Build Item #6)
/// after a strip image is captured:
///
/// ```swift
/// scanPage.runQualityGate(for: strip.definition.columnId, image: capturedImage)
/// ```
extension ScanPage {

    /// Runs the quality gate asynchronously for the given column strip.
    ///
    /// On gate pass  → transitions the strip to `.processing` and leaves the
    ///                 page scanState at `.processing(columnId:)` for OCR to begin.
    /// On gate fail  → calls `didFailProcessing(reasons:for:)` to put the strip
    ///                 and page into `.error` state so the pilot can retake.
    ///
    /// - Parameters:
    ///   - columnId: The `ColumnDefinition.columnId` of the captured strip.
    ///   - image:    The raw UIImage from the ROI camera overlay.
    ///   - thresholds: Optional custom thresholds. Defaults to standard values.
    @MainActor
    public func runQualityGate(
        for columnId: String,
        image: UIImage,
        thresholds: QualityGateThresholds = QualityGateThresholds()
    ) {
        // Store the image on the strip immediately so the review UI can show it.
        didCapture(image: image, for: columnId)

        ImageQualityGate.checkAsync(
            image:            image,
            expectedRowCount: activeRowCount,
            thresholds:       thresholds
        ) { [weak self] result in
            guard let self = self else { return }

            // Map QualityGateResult → StripQualityResult (the type ScanPage owns).
            let stripResult = StripQualityResult(
                isAcceptable:         result.isAcceptable,
                blurScore:            result.blurScore,
                contrastScore:        result.meanIntensity / 255.0,
                detectedRowLineCount: result.detectedRowLineCount,
                failureReasons:       result.failures.map { $0.pilotMessage }
            )

            if result.isAcceptable {
                // Gate passed — write quality result to strip, leave in .processing
                // state for the OCR engine (Build Item #8) to pick up.
                self.strip(for: columnId)?.qualityResult = stripResult
                // scanState stays .processing(columnId:) — OCR continues.
            } else {
                // Gate failed — surface hard failure reasons to the pilot.
                let hardReasons = result.failures
                    .filter { $0.isHardFailure }
                    .map { "\($0.pilotMessage). \($0.suggestion)." }
                self.didFailProcessing(reasons: hardReasons, for: columnId)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - QualityGateResult → StripQualityResult bridge
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience initialiser so the scanner pipeline can convert between the
/// gate's rich result type and the leaner StripQualityResult stored on ColumnStrip.
extension StripQualityResult {
    init(from gateResult: QualityGateResult) {
        self.init(
            isAcceptable:         gateResult.isAcceptable,
            blurScore:            gateResult.blurScore,
            contrastScore:        gateResult.meanIntensity / 255.0,
            detectedRowLineCount: gateResult.detectedRowLineCount,
            failureReasons:       gateResult.failures.map { $0.pilotMessage }
        )
    }
}
