// RowLineDetector.swift
// AeroBook — Scanner group
//
// Build Order Item #7 — Row Line Detector.
//
// ─────────────────────────────────────────────────────────────────────────────
// PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
// Takes the full-resolution UIImage that was cropped from the camera ROI and
// returns an ordered array of UIImage slices — one per data row — ready to be
// passed one-by-one to the OCR engine (Build Order Item #8).
//
// The detector does NOT perform OCR. It only answers one question:
//   "Where are the horizontal ruled lines in this strip, and what is the
//    pixel boundary of each data cell?"
//
// ─────────────────────────────────────────────────────────────────────────────
// ALGORITHM (three passes, all in greyscale pixel space)
// ─────────────────────────────────────────────────────────────────────────────
//
// Pass 1 — Edge mark
//   For every scanline y, compute the maximum absolute difference between
//   adjacent horizontal pixels. If this max-diff ≥ edgeThreshold AND the
//   run of edge pixels spans ≥ minWidthFraction of the strip width, mark y
//   as a candidate line scanline. This is identical to the quality gate's
//   detection logic (Section 10) so the two are always consistent.
//
// Pass 2 — Line merge & Y-centre extraction
//   Merge adjacent candidate scanlines within a suppressionBand-pixel window
//   into single ruled lines. Record the y-centre of each merged group as
//   the definitive line position in pixel coordinates.
//
// Pass 3 — Row boundary resolution + data zone trimming
//   Given the detected line positions:
//   a. Identify the header zone (lines above the first data row). The number
//      of header lines is profile.headerLevels. Lines are counted from the
//      top; lines[headerLevels] is the top boundary of data row 0.
//   b. The bottom of the last data row is detected from the image height,
//      confirmed against totalsRowCount rows that are structurally excluded.
//   c. Each data cell rect is: y = lines[headerLevels + i], height = lines[i+1] - y.
//      The last row uses imageHeight - totalsZonePixels as its bottom bound.
//
// Fallback — uniform subdivision
//   If Pass 2 yields fewer lines than expected (bleed, tight crop, etc.), the
//   detector falls back to uniform row height subdivision using the confirmed
//   activeRowCount. This guarantees the OCR engine always receives exactly
//   activeRowCount slices even on difficult images. The fallback is flagged
//   in DetectionResult.usedFallback so the review UI can surface a soft warning.
//
// ─────────────────────────────────────────────────────────────────────────────
// LOCKED DECISIONS (Section 12 of Strategy Doc)
// ─────────────────────────────────────────────────────────────────────────────
//   • activeRowCount is a caller-supplied integer — NEVER auto-detected.
//   • Totals rows are excluded structurally — they are never sliced or OCR'd.
//   • No per-row ink detection — blank rows are detected by the cross-check
//     engine (blank_row_detection rule on totalTime), not here.
//   • All processing runs on a background DispatchQueue (userInitiated QoS).
//     The completion callback is always delivered on the main thread.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEPENDENCIES
// ─────────────────────────────────────────────────────────────────────────────
//   • ColumnStrip, OCRCellResult    (ColumnStrip.swift)
//   • ScanPage.didCompleteOCR       (ScanPage.swift) — caller passes results in
//   • Accelerate (vDSP)             — greyscale buffer ops
//   • No UIKit beyond UIImage crop  — pure image processing
//   • No Vision framework           — Vision is OCR engine territory (Item #8)
//   • No SwiftUI                    — this is a pure service type

import Foundation
import UIKit
import Accelerate
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowLineDetector Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// All tunable parameters for the row-line detector, with defaults calibrated
/// for Jeppesen logbook strips photographed via the portrait ROI camera.
///
/// The same constants are used by ImageQualityGate for consistency; changing
/// a threshold in one place should be reflected in the other. They are kept
/// separate so each component can be calibrated independently without coupling.
public struct RowDetectorConfig {

    // MARK: Analysis Resolution

    /// Width of the internal greyscale working buffer in pixels.
    /// The source image is downsampled to this width before processing.
    /// Larger = more accurate line positions but slower. 256 is sufficient
    /// for ruled-line detection; the slicing step uses the original full-res image.
    public var analysisWidth: Int = 256

    /// Height of the internal greyscale working buffer.
    /// 1024 gives ~1px accuracy on a 13-row strip (≈78px per row at analysis res).
    public var analysisHeight: Int = 1024

    // MARK: Edge Detection (Pass 1)

    /// Minimum absolute pixel difference to count as an edge pixel (0–255).
    /// Jeppesen ruled lines are printed in blue/grey ink — they register as
    /// a contrast change of ≥ 20 grey levels against cream paper.
    public var edgeThreshold: UInt8 = 20

    /// A scanline is only a ruled-line candidate if the horizontal span of
    /// edge pixels is at least this fraction of the strip width.
    /// 0.55 = 55% — wide enough to ignore short ink marks and pen strokes.
    public var minWidthFraction: Double = 0.55

    // MARK: Line Merge (Pass 2)

    /// After a candidate line is counted, suppress the next N scanlines to
    /// avoid counting a thick printed rule as multiple lines.
    /// 5 pixels at analysisHeight=1024 corresponds to ≈2px per 400dpi line.
    public var suppressionBand: Int = 5

    // MARK: Fallback

    /// If the number of detected lines is fewer than
    /// (expectedDataLines - fallbackTolerance), trigger uniform subdivision.
    /// Default 2: tolerate missing one ruled line before falling back.
    public var fallbackTolerance: Int = 2

    // MARK: Cell Padding

    /// Vertical padding in pixels (original image coordinate space) added to
    /// the top and bottom of each cell crop. This gives the OCR engine a few
    /// extra pixels of context around handwritten characters.
    /// Applied as a fraction of the computed row height (0.05 = 5%).
    public var cellPaddingFraction: Double = 0.05

    /// Minimum absolute vertical padding in original-image pixels.
    /// Prevents padding from collapsing to zero on very short crops.
    public var minCellPaddingPx: Int = 6

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DetectionResult
// ─────────────────────────────────────────────────────────────────────────────

/// The full output of one RowLineDetector run.
/// The caller (ScanPage coordinator) consumes this and constructs OCRCellResult
/// skeletons (with cellImage populated, rawText/confidence to be filled by OCR).
public struct DetectionResult {

    // MARK: Per-row slices

    /// Ordered cell images, index 0 = topmost data row.
    /// Count is guaranteed to equal `activeRowCount` — the caller's confirmed value.
    /// Each image is a UIImage at the original camera resolution, cropped to the
    /// cell's pixel rect with `cellPaddingFraction` padding applied.
    public let cellImages: [UIImage]

    // MARK: Geometry

    /// The pixel y-coordinates of each detected ruled line in the full-resolution
    /// image coordinate space (origin top-left, y increases downward).
    /// Includes header lines. Count = detectedLineCount.
    /// Useful for debug overlay visualisation.
    public let detectedLineYPositions: [CGFloat]

    /// Pixel rects of every data cell in the original image coordinate space,
    /// before padding is applied. Parallel to `cellImages`.
    public let cellRectsOriginal: [CGRect]

    // MARK: Diagnostics

    /// Number of horizontal ruled lines found by the detector (Pass 2 output).
    public let detectedLineCount: Int

    /// Number of lines the detector expected given the profile geometry.
    /// = profile.headerLevels + activeRowCount + profile.totalsRowCount
    public let expectedLineCount: Int

    /// true when the detector fell back to uniform row subdivision because
    /// too few lines were detected. The review UI surfaces a soft warning.
    public let usedFallback: Bool

    /// Processing time in milliseconds (wall clock).
    public let processingTimeMs: Double
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DetectionError
// ─────────────────────────────────────────────────────────────────────────────

/// Errors that can prevent the detector from producing any output.
/// These are distinct from soft-fallback conditions (usedFallback = true).
public enum DetectionError: LocalizedError {

    /// The UIImage has no CGImage backing (e.g. CIImage-backed image not yet rendered).
    case imageNotRenderable

    /// The pixel buffer could not be allocated (memory pressure).
    case bufferAllocationFailed

    /// The image is too small to contain any data rows (< 32px height).
    case imageTooSmall

    public var errorDescription: String? {
        switch self {
        case .imageNotRenderable:   return "Strip image could not be decoded for line detection."
        case .bufferAllocationFailed: return "Insufficient memory for row-line detection buffer."
        case .imageTooSmall:        return "Captured strip is too small for row detection (< 32px)."
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowLineDetector
// ─────────────────────────────────────────────────────────────────────────────

/// Stateless namespace. All entry points are static.
///
/// Typical call site (inside ScanPage or a coordinator):
/// ```swift
/// RowLineDetector.detectAsync(
///     in: capturedStripImage,
///     activeRowCount: scanPage.activeRowCount,
///     profile: scanPage.profile
/// ) { result in
///     // result is on the main thread
///     switch result {
///     case .success(let detection):
///         for (index, cellImage) in detection.cellImages.enumerated() {
///             let skeleton = OCRCellResult(rowIndex: index,
///                                         rawText: "",
///                                         confidence: 0,
///                                         cellImage: cellImage)
///             scanPage.didCompleteOCR(results: [skeleton], for: column.columnId)
///         }
///     case .failure(let error):
///         scanPage.didFailProcessing(for: column.columnId, reasons: [error.localizedDescription])
///     }
/// }
/// ```
public enum RowLineDetector {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Public API — Async Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// Detects row lines and slices the strip asynchronously.
    ///
    /// - Parameters:
    ///   - image:          The full-resolution strip UIImage (output of ScanCameraView's cropToROI).
    ///   - activeRowCount: Pilot-confirmed number of data rows on this page (from ScanPage).
    ///   - headerLevels:   Header rows above the first data row (from LogbookProfile). Default 3.
    ///   - totalsRowCount: Bottom rows to structurally exclude (from LogbookProfile). Default 3.
    ///   - config:         Tuning parameters. Default values are calibrated for Jeppesen logbooks.
    ///   - completion:     Called on the **main thread** with the result.
    public static func detectAsync(
        in image: UIImage,
        activeRowCount: Int,
        headerLevels: Int = 3,
        totalsRowCount: Int = 3,
        config: RowDetectorConfig = RowDetectorConfig(),
        completion: @escaping (Result<DetectionResult, DetectionError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = detect(
                in: image,
                activeRowCount: activeRowCount,
                headerLevels: headerLevels,
                totalsRowCount: totalsRowCount,
                config: config
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous variant. Must be called on a background thread.
    /// Prefer `detectAsync` at all call sites; this is exposed for unit tests.
    public static func detect(
        in image: UIImage,
        activeRowCount: Int,
        headerLevels: Int = 3,
        totalsRowCount: Int = 3,
        config: RowDetectorConfig = RowDetectorConfig()
    ) -> Result<DetectionResult, DetectionError> {

        let wallStart = Date()

        // ── Validate inputs ───────────────────────────────────────────────
        guard let cgSource = image.cgImage else {
            return .failure(.imageNotRenderable)
        }
        let srcW = CGFloat(cgSource.width)
        let srcH = CGFloat(cgSource.height)
        guard srcH >= 32 else { return .failure(.imageTooSmall) }

        // ── Build greyscale analysis buffer ───────────────────────────────
        guard let (pixels, anaW, anaH) = greyscaleBuffer(
            from: image,
            width:  config.analysisWidth,
            height: config.analysisHeight
        ) else {
            return .failure(.bufferAllocationFailed)
        }

        // ── Pass 1: Mark candidate scanlines ──────────────────────────────
        let candidateRows = markCandidateScanlines(
            pixels:           pixels,
            width:            anaW,
            height:           anaH,
            edgeThreshold:    config.edgeThreshold,
            minWidthFraction: config.minWidthFraction
        )

        // ── Pass 2: Merge into line y-centres (analysis coord space) ──────
        let analysisCentres = mergeToLineCentres(
            candidates:     candidateRows,
            height:         anaH,
            suppressBand:   config.suppressionBand
        )

        // ── Map analysis coords → full-resolution pixel coords ────────────
        let scaleY    = srcH / CGFloat(anaH)
        let fullResCentres = analysisCentres.map { CGFloat($0) * scaleY }

        // ── Pass 3: Resolve data cell rects ───────────────────────────────
        let expectedLines = headerLevels + activeRowCount + totalsRowCount

        let (cellRects, usedFallback) = resolveDataCellRects(
            detectedCentres: fullResCentres,
            imageWidth:      srcW,
            imageHeight:     srcH,
            activeRowCount:  activeRowCount,
            headerLevels:    headerLevels,
            totalsRowCount:  totalsRowCount,
            expectedLines:   expectedLines,
            fallbackTolerance: config.fallbackTolerance,
            config:          config
        )

        // ── Slice full-resolution cell images ─────────────────────────────
        let cellImages = sliceCellImages(
            source:     cgSource,
            rects:      cellRects,
            imageWidth: srcW,
            imageHeight: srcH,
            config:     config,
            orientation: image.imageOrientation,
            scale:       image.scale
        )

        let elapsed = Date().timeIntervalSince(wallStart) * 1000

        let result = DetectionResult(
            cellImages:            cellImages,
            detectedLineYPositions: fullResCentres,
            cellRectsOriginal:     cellRects,
            detectedLineCount:     fullResCentres.count,
            expectedLineCount:     expectedLines,
            usedFallback:          usedFallback,
            processingTimeMs:      elapsed
        )

        return .success(result)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pass 1 — Candidate Scanline Marking
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns a Bool array of length `height`; true = this scanline has a
    /// strong horizontal edge spanning ≥ minWidthFraction of the strip width.
    ///
    /// Algorithm:
    ///   For each row y, walk pixels left-to-right counting consecutive pixels
    ///   whose absolute grey difference from their neighbour ≥ edgeThreshold.
    ///   Track the longest such run. If it reaches minSpanPixels, mark the row.
    ///
    /// This intentionally matches the algorithm in ImageQualityGate.detectHorizontalRowLines
    /// so quality-gate pass/fail and slice positions are computed on the same basis.
    private static func markCandidateScanlines(
        pixels:           [UInt8],
        width:            Int,
        height:           Int,
        edgeThreshold:    UInt8,
        minWidthFraction: Double
    ) -> [Bool] {

        let minSpan = Int(Double(width) * minWidthFraction)
        var candidates = [Bool](repeating: false, count: height)

        for y in 0..<height {
            let base = y * width
            var run    = 0
            var maxRun = 0

            for x in 1..<width {
                let diff = absDiff(pixels[base + x], pixels[base + x - 1])
                if diff >= edgeThreshold {
                    run   += 1
                    maxRun = max(maxRun, run)
                } else {
                    run = 0
                }
            }
            candidates[y] = (maxRun >= minSpan)
        }

        return candidates
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pass 2 — Merge Candidates into Line Y-Centres
    // ─────────────────────────────────────────────────────────────────────────

    /// Merges adjacent candidate scanlines into ruled lines and returns the
    /// y-coordinate of each line's centre in the analysis buffer's coordinate
    /// space (origin top-left, integer pixel units).
    ///
    /// A printed Jeppesen ruled line is typically 2–4px tall at analysis
    /// resolution; suppressionBand prevents it counting as multiple lines.
    private static func mergeToLineCentres(
        candidates:   [Bool],
        height:       Int,
        suppressBand: Int
    ) -> [Int] {

        var centres    = [Int]()
        var inLine     = false
        var lineStart  = 0
        var suppress   = 0

        for y in 0..<height {
            if suppress > 0 {
                suppress -= 1
                continue
            }

            if candidates[y] {
                if !inLine {
                    lineStart = y
                    inLine    = true
                }
                // Extend current line span; centre will be computed on exit
            } else {
                if inLine {
                    // Line just ended — record its centre
                    let centre = (lineStart + y - 1) / 2
                    centres.append(centre)
                    inLine   = false
                    suppress = suppressBand
                }
            }
        }

        // Handle line that runs to the very bottom edge
        if inLine {
            let centre = (lineStart + height - 1) / 2
            centres.append(centre)
        }

        return centres
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pass 3 — Data Cell Rect Resolution
    // ─────────────────────────────────────────────────────────────────────────

    /// Given detected line positions in full-resolution pixel coordinates,
    /// produces exactly `activeRowCount` CGRects covering the data cells only
    /// (header and totals zones excluded).
    ///
    /// Strategy:
    ///   A. If enough lines are detected (≥ expectedLines - fallbackTolerance):
    ///      Use the lines directly. Lines [0 ..< headerLevels] are the header zone.
    ///      Lines [headerLevels ..< headerLevels+activeRowCount] bound the data rows.
    ///      The bottom of the last data row uses either the next line (first totals
    ///      line) or falls back to imageHeight if totals lines are not visible.
    ///
    ///   B. If too few lines detected (usedFallback = true):
    ///      Estimate the header zone as the top fraction of the image, then
    ///      subdivide the remaining data zone uniformly into activeRowCount rows.
    ///
    /// Returns (rects, usedFallback).
    private static func resolveDataCellRects(
        detectedCentres:  [CGFloat],
        imageWidth:       CGFloat,
        imageHeight:      CGFloat,
        activeRowCount:   Int,
        headerLevels:     Int,
        totalsRowCount:   Int,
        expectedLines:    Int,
        fallbackTolerance: Int,
        config:           RowDetectorConfig
    ) -> ([CGRect], Bool) {

        let sufficientLines = detectedCentres.count >= (expectedLines - fallbackTolerance)

        if sufficientLines && detectedCentres.count > headerLevels {
            return (
                directCellRects(
                    centres:       detectedCentres,
                    imageWidth:    imageWidth,
                    imageHeight:   imageHeight,
                    activeRowCount: activeRowCount,
                    headerLevels:  headerLevels,
                    totalsRowCount: totalsRowCount
                ),
                false
            )
        } else {
            return (
                fallbackCellRects(
                    imageWidth:    imageWidth,
                    imageHeight:   imageHeight,
                    activeRowCount: activeRowCount,
                    headerLevels:  headerLevels,
                    totalsRowCount: totalsRowCount
                ),
                true
            )
        }
    }

    /// Produces cell rects directly from detected line positions.
    private static func directCellRects(
        centres:        [CGFloat],
        imageWidth:     CGFloat,
        imageHeight:    CGFloat,
        activeRowCount: Int,
        headerLevels:   Int,
        totalsRowCount: Int
    ) -> [CGRect] {

        var rects = [CGRect]()

        // Lines at indices 0..<headerLevels are the column-header bands.
        // The first data row starts at the line at index `headerLevels`.
        let dataLineStart = headerLevels
        let dataLineEnd   = min(dataLineStart + activeRowCount, centres.count)

        for i in dataLineStart..<dataLineEnd {
            let topY: CGFloat    = centres[i]
            let bottomY: CGFloat

            if i + 1 < centres.count {
                bottomY = centres[i + 1]
            } else {
                // Last row — use image bottom minus an estimated totals zone.
                // The totals zone height is estimated as one average row height.
                let avgRowH = (topY > 0 && i > dataLineStart)
                    ? (topY - centres[i - 1])
                    : (imageHeight - topY) / CGFloat(max(1, activeRowCount - (i - dataLineStart)))
                let totalsZoneH = avgRowH * CGFloat(totalsRowCount)
                bottomY = max(topY + 1, imageHeight - totalsZoneH)
            }

            let rect = CGRect(
                x:      0,
                y:      topY,
                width:  imageWidth,
                height: max(1, bottomY - topY)
            )
            rects.append(rect)
        }

        // Pad to exactly activeRowCount if some rows are past the last detected line
        while rects.count < activeRowCount {
            let lastRect = rects.last ?? CGRect(x: 0, y: 0, width: imageWidth, height: 1)
            let extraY = lastRect.maxY
            let extraH = max(1, (imageHeight - extraY) / CGFloat(max(1, activeRowCount - rects.count)))
            rects.append(CGRect(x: 0, y: extraY, width: imageWidth, height: extraH))
        }

        return Array(rects.prefix(activeRowCount))
    }

    /// Uniform-subdivision fallback for images where line detection is unreliable.
    private static func fallbackCellRects(
        imageWidth:     CGFloat,
        imageHeight:    CGFloat,
        activeRowCount: Int,
        headerLevels:   Int,
        totalsRowCount: Int
    ) -> [CGRect] {

        // Heuristic header height: 12% of image height per header level,
        // capped at 35% total to avoid consuming too much of short strips.
        let headerFraction: CGFloat = min(0.35, CGFloat(headerLevels) * 0.10)
        let headerH = imageHeight * headerFraction

        // Heuristic totals height: same fraction per totals row, capped at 20%.
        let totalsFraction: CGFloat = min(0.20, CGFloat(totalsRowCount) * 0.05)
        let totalsH = imageHeight * totalsFraction

        let dataZoneTop = headerH
        let dataZoneH   = max(1, imageHeight - headerH - totalsH)
        let rowH        = dataZoneH / CGFloat(max(1, activeRowCount))

        return (0..<activeRowCount).map { i in
            CGRect(
                x:      0,
                y:      dataZoneTop + CGFloat(i) * rowH,
                width:  imageWidth,
                height: rowH
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Cell Image Slicing
    // ─────────────────────────────────────────────────────────────────────────

    /// Crops the source CGImage to each cell rect, applying vertical padding.
    ///
    /// Padding rules:
    ///   • pad = max(minCellPaddingPx, rect.height × cellPaddingFraction)
    ///   • topY    = clamp(rect.minY − pad, 0, imageHeight)
    ///   • bottomY = clamp(rect.maxY + pad, 0, imageHeight)
    ///   • Padding deliberately bleeds across ruled lines — this gives Vision
    ///     context pixels that help it orient character baselines correctly.
    ///
    /// If CGImage.cropping fails for any rect (degenerate geometry), the
    /// entire source image is used as the fallback so the array length is
    /// always exactly activeRowCount.
    private static func sliceCellImages(
        source:      CGImage,
        rects:       [CGRect],
        imageWidth:  CGFloat,
        imageHeight: CGFloat,
        config:      RowDetectorConfig,
        orientation: UIImage.Orientation,
        scale:       CGFloat
    ) -> [UIImage] {

        rects.map { rect in
            let padPx  = max(
                CGFloat(config.minCellPaddingPx),
                rect.height * CGFloat(config.cellPaddingFraction)
            )
            let paddedRect = CGRect(
                x:      0,                                                   // full strip width
                y:      max(0,           rect.minY - padPx),
                width:  imageWidth,
                height: min(imageHeight, rect.maxY + padPx) - max(0, rect.minY - padPx)
            )

            // Convert to integer pixel rect for CGImage.cropping
            let pixelRect = CGRect(
                x:      paddedRect.origin.x.rounded(.down),
                y:      paddedRect.origin.y.rounded(.down),
                width:  paddedRect.size.width.rounded(.up),
                height: paddedRect.size.height.rounded(.up)
            )

            if let cropped = source.cropping(to: pixelRect) {
                return UIImage(cgImage: cropped, scale: scale, orientation: orientation)
            }
            // Fallback: return full-strip image (OCR will still run; confidence will be lower)
            return UIImage(cgImage: source, scale: scale, orientation: orientation)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Greyscale Buffer
    // ─────────────────────────────────────────────────────────────────────────

    /// Renders the UIImage into a greyscale UInt8 pixel buffer at the analysis
    /// resolution. Downsampling keeps processing O(constant) regardless of the
    /// source camera resolution (12MP or 48MP produce identical buffers).
    ///
    /// Returns (pixels, width, height) or nil on allocation failure.
    private static func greyscaleBuffer(
        from image: UIImage,
        width:  Int,
        height: Int
    ) -> ([UInt8], Int, Int)? {

        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let ctx = CGContext(
            data:             &pixels,
            width:            width,
            height:           height,
            bitsPerComponent: 8,
            bytesPerRow:      width,
            space:            CGColorSpaceCreateDeviceGray(),
            bitmapInfo:       CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (pixels, width, height)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Utilities
    // ─────────────────────────────────────────────────────────────────────────

    /// Absolute difference of two UInt8 values, no overflow.
    @inline(__always)
    private static func absDiff(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a > b ? a - b : b - a
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ColumnStrip Integration Extension
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience extension on ColumnStrip that runs the row-line detector
/// and populates the strip's cellResults with image-only OCRCellResult
/// skeletons ready for the OCR engine (Build Item #8).
///
/// Call site in the ScanPage coordinator / camera controller:
/// ```swift
/// strip.runRowDetector(on: capturedImage, scanPage: scanPage) { success in
///     if success {
///         OCREngine.run(on: strip, for: scanPage)
///     }
/// }
/// ```
public extension ColumnStrip {

    /// Runs RowLineDetector on `image`, populates `cellResults` with image
    /// skeletons (rawText = "", confidence = 0, cellImage = sliced UIImage),
    /// then calls `completion(true)` on the main thread.
    ///
    /// On failure, calls `completion(false)` and does NOT modify cellResults.
    ///
    /// - Parameters:
    ///   - image:     Full-resolution strip image from the ROI camera.
    ///   - scanPage:  Live ScanPage — used to read activeRowCount and profile geometry.
    ///   - config:    Detector config (defaults calibrated for Jeppesen).
    ///   - completion: Called on main thread with success/failure flag.
    func runRowDetector(
        on image: UIImage,
        scanPage: ScanPage,
        config: RowDetectorConfig = RowDetectorConfig(),
        completion: @escaping (Bool) -> Void
    ) {
        let columnId    = definition.columnId
        let rowCount    = scanPage.activeRowCount
        let headerLevels = scanPage.profile.headerLevels
        let totalsCount  = scanPage.profile.totalsRowCount

        RowLineDetector.detectAsync(
            in:             image,
            activeRowCount: rowCount,
            headerLevels:   headerLevels,
            totalsRowCount: totalsCount,
            config:         config
        ) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let detection):
                // Build OCRCellResult skeletons — rawText and confidence will be
                // filled in by the OCR engine (Build Item #8).
                let skeletons: [OCRCellResult] = detection.cellImages
                    .enumerated()
                    .map { index, cellImage in
                        OCRCellResult(
                            rowIndex:   index,
                            rawText:    "",       // OCR engine fills this
                            confidence: 0,        // OCR engine fills this
                            cellImage:  cellImage
                        )
                    }

                // Soft-warn if fallback was used (surfaces in review UI)
                if detection.usedFallback {
                    print("[AeroBook] RowLineDetector: fallback subdivision used for \(columnId) " +
                          "(detected \(detection.detectedLineCount) lines, " +
                          "expected \(detection.expectedLineCount))")
                }

                // Update ScanPage via its public OCR-completion method.
                // StripQualityResult is built from the detection outcome:
                // isAcceptable = true (we reached this point past the quality gate),
                // detectedRowLineCount from the detector, neutral blur/contrast scores
                // (ImageQualityGate already validated those before this runs).
                let qualityResult = StripQualityResult(
                    isAcceptable:         true,
                    blurScore:            1.0,
                    contrastScore:        1.0,
                    detectedRowLineCount: detection.detectedLineCount,
                    failureReasons:       detection.usedFallback
                        ? ["Row line detection used fallback subdivision — verify row alignment."]
                        : []
                )
                scanPage.didCompleteOCR(results: skeletons, qualityResult: qualityResult, for: columnId)
                completion(true)

            case .failure(let error):
                print("[AeroBook] RowLineDetector: detection failed for \(columnId): \(error.localizedDescription)")
                scanPage.didFailProcessing(
                    reasons: [error.localizedDescription], for:     columnId
                )
                completion(false)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DetectionResult Diagnostics
// ─────────────────────────────────────────────────────────────────────────────

public extension DetectionResult {

    /// Human-readable summary for debug logs.
    var debugDescription: String {
        let mode = usedFallback ? "FALLBACK uniform" : "line-guided"
        return "[RowLineDetector] \(mode) " +
               "detected=\(detectedLineCount)/\(expectedLineCount) lines | " +
               "\(cellImages.count) cells | " +
               String(format: "%.1f ms", processingTimeMs)
    }

    /// true when the detected line count is within tolerance of the expected count.
    var lineCountIsNominal: Bool {
        abs(detectedLineCount - expectedLineCount) <= 2
    }

    /// Pilot-facing message when fallback is active (surfaced in review UI).
    var fallbackWarningMessage: String? {
        guard usedFallback else { return nil }
        return "Row lines could not be detected clearly. " +
               "Cells were divided uniformly — check for any misaligned rows in the review table."
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RowDetectionDebugView (SwiftUI diagnostic overlay)
// ─────────────────────────────────────────────────────────────────────────────
//
// Optional debug overlay shown during development / TestFlight. Renders the
// detected line positions as coloured horizontal lines over the strip image.
// Excluded from production builds via DEBUG conditional.
//
// Usage (development only):
//   RowDetectionDebugView(image: stripImage, result: detectionResult)

#if DEBUG
import SwiftUI

/// Renders a strip image with detected row lines overlaid as coloured
/// horizontal rules. Green = header lines, blue = data row lines,
/// amber = totals zone boundary.
///
/// For development and TestFlight diagnostic sessions only.
public struct RowDetectionDebugView: View {

    public let image:  UIImage
    public let result: DetectionResult

    /// How many of the detected lines belong to the column header.
    public var headerLevels: Int = 3

    /// How many totals rows are excluded at the bottom.
    public var totalsRowCount: Int = 3

    public init(image: UIImage, result: DetectionResult,
                headerLevels: Int = 3, totalsRowCount: Int = 3) {
        self.image         = image
        self.result        = result
        self.headerLevels  = headerLevels
        self.totalsRowCount = totalsRowCount
    }

    public var body: some View {
        GeometryReader { geo in
            let srcH   = CGFloat(image.cgImage?.height ?? 1)
            let scaleY = geo.size.height / srcH

            ZStack(alignment: .topLeading) {
                // Strip image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // Detected line overlays
                ForEach(Array(result.detectedLineYPositions.enumerated()), id: \.offset) { idx, yPx in
                    let screenY = yPx * scaleY
                    let lineColor: Color = lineColour(for: idx)

                    Rectangle()
                        .fill(lineColor.opacity(0.85))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .offset(y: screenY)
                        .overlay(alignment: .leading) {
                            Text(lineLabel(for: idx))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(lineColor)
                                .padding(.leading, 4)
                                .offset(y: screenY - 10)
                        }
                }

                // Cell rect outlines
                ForEach(Array(result.cellRectsOriginal.enumerated()), id: \.offset) { idx, rect in
                    let screenRect = CGRect(
                        x:      rect.minX,
                        y:      rect.minY   * scaleY,
                        width:  geo.size.width,
                        height: rect.height * scaleY
                    )
                    Rectangle()
                        .stroke(Color.sky400.opacity(0.5), lineWidth: 1)
                        .frame(width: screenRect.width, height: max(1, screenRect.height))
                        .offset(y: screenRect.minY)
                }

                // Diagnostics badge
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.usedFallback ? "⚠ FALLBACK" : "✓ LINE-GUIDED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(result.usedFallback ? Color.statusAmber : Color.statusGreen)
                    Text("\(result.detectedLineCount)/\(result.expectedLineCount) lines")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(String(format: "%.1f ms", result.processingTimeMs))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(6)
                .background(Color.black.opacity(0.65))
                .cornerRadius(6)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    // MARK: Helpers

    private func lineColour(for idx: Int) -> Color {
        if idx < headerLevels { return .gold400 }
        let dataEnd = headerLevels + (result.cellImages.count)
        if idx >= dataEnd { return .statusAmber }
        return .statusGreen
    }

    private func lineLabel(for idx: Int) -> String {
        if idx < headerLevels { return "H\(idx + 1)" }
        let dataEnd = headerLevels + result.cellImages.count
        if idx >= dataEnd { return "T\(idx - dataEnd + 1)" }
        return "R\(idx - headerLevels + 1)"
    }
}

#Preview("Row Detection Debug") {
    ZStack {
        Color.neutral900.ignoresSafeArea()
        RowDetectionDebugView(
            image:  UIImage(systemName: "doc.text.fill")!,
            result: DetectionResult(
                cellImages:             [],
                detectedLineYPositions: [50, 120, 190, 260, 330, 400, 470,
                                         540, 610, 680, 750, 820, 890, 960,
                                         1030, 1100, 1170, 1240, 1310],
                cellRectsOriginal:      [],
                detectedLineCount:      19,
                expectedLineCount:      19,
                usedFallback:           false,
                processingTimeMs:       4.2
            )
        )
        .frame(width: 120, height: 480)
    }
}
#endif
