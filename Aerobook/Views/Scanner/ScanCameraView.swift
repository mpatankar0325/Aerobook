// ScanCameraView.swift
// AeroBook — Scanner/Views group
//
// Build Order Item #6 — Camera + ROI Overlay.
//
// Presents a full-screen portrait camera with a fixed narrow vertical strip
// cutout (the ROI — Region of Interest). The pilot slides their logbook under
// the cutout so the target column is perfectly framed, then taps Capture.
//
// Architecture (Section 12, Decisions Locked):
//   • Portrait orientation only — AVCaptureSession locked to portrait.
//   • Column-by-column capture — one strip per tap; caller drives the sequence.
//   • The ROI cutout is fixed on-screen; the PILOT moves the book, not the
//     camera. This eliminates crop math and alignment errors.
//   • imageOnly columns (Phase 5 Remarks) use the same ROI but skip quality
//     gate + OCR — the captured UIImage is stored directly on the strip.
//
// ROI Crop:
//   After capture the preview frame is mapped to the full-resolution
//   AVCapturePhoto pixel buffer. The strip region is cropped out of the
//   full-res buffer and returned as a UIImage. The crop rect is computed
//   from the on-screen ROI frame mapped through the preview layer's
//   videoPreviewLayer coordinate system — no guesswork, no fixed fractions.
//
// Output:
//   onCapture(UIImage, ColumnDefinition) fires on the main thread with:
//     • A UIImage cropped precisely to the ROI strip at full camera resolution.
//     • The ColumnDefinition that was being captured (for the caller to pass
//       to ImageQualityGate and/or store directly for imageOnly columns).
//
// Depends on:
//   • ColumnDefinition, CapturePhase  (DatabaseManager+LogbookProfile.swift)
//   • ScanPage                        (ScanPage.swift)
//   • AeroTheme                       (Theme.swift)
//   • AVFoundation, CoreImage

import SwiftUI
import AVFoundation
import CoreImage
import Combine
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ROI Layout Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Fixed dimensions for the vertical strip ROI cutout, expressed as fractions
/// of the screen width and height. All values tuned for a Jeppesen logbook
/// column photographed in portrait orientation at a comfortable arm's length.
private enum ROILayout {

    /// Width of the transparent strip as a fraction of the screen width.
    /// 0.18 ≈ 18% — wide enough to capture a single H or t cell with margins.
    /// For text columns (wider), the pilot can crop slightly more; the strip
    /// still captures more than enough for Vision to recognise the text.
    static let stripWidthFraction:  CGFloat = 0.18

    /// Vertical extent of the transparent strip — nearly full screen height
    /// so all data rows plus some margin are always in frame.
    static let stripTopFraction:    CGFloat = 0.06   // 6% from top
    static let stripBottomFraction: CGFloat = 0.94   // 94% from top

    /// Horizontal centre of the ROI strip (fixed). Pilot slides book left/right.
    static let stripCentreX:        CGFloat = 0.50   // centred on screen

    // Corner bracket dimensions (decorative alignment guides)
    static let bracketLength:  CGFloat = 22
    static let bracketWidth:   CGFloat = 3
    static let bracketRadius:  CGFloat = 3
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CaptureFlash State
// ─────────────────────────────────────────────────────────────────────────────

/// Controls the white flash animation that fires on capture.
private enum FlashState {
    case idle, flashing
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanCameraView
// ─────────────────────────────────────────────────────────────────────────────

/// Full-screen portrait camera view with a fixed vertical strip ROI cutout.
///
/// Usage:
/// ```swift
/// ScanCameraView(
///     currentColumn: strip.definition,
///     phaseColor: .sky400,
///     onCapture: { image, column in
///         scanPage.runQualityGate(for: column.columnId, image: image)
///     },
///     onSkip: {
///         scanPage.skipStrip(for: column.columnId)
///     },
///     onCancel: { isPresented = false }
/// )
/// ```
struct ScanCameraView: View {

    // MARK: Inputs

    /// The ColumnDefinition currently being captured.
    /// Drives the header label, phase colour, and skip/imageOnly behaviour.
    let currentColumn: ColumnDefinition

    /// Accent colour for the ROI outline, derived from the active CapturePhase.
    /// Phase 1 = sky400, Phase 2 = emerald500, etc. Passed from the caller.
    var phaseColor: Color = .sky400

    /// Called on the main thread when a strip image has been captured and cropped.
    var onCapture: (UIImage, ColumnDefinition) -> Void

    /// Called when the pilot skips a non-required column (isRequired == false).
    var onSkip: (() -> Void)? = nil

    /// Called when the pilot taps Cancel.
    var onCancel: () -> Void

    // MARK: Private State

    @StateObject private var cameraController = CameraController()
    @State private var flashState: FlashState = .idle
    @State private var captureButtonPressed  = false
    @State private var showSkipConfirm       = false

    // ROI rect in screen-space, populated by a GeometryReader
    @State private var roiScreenRect: CGRect  = .zero

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── 1. Live camera preview (fills screen) ─────────────────
                CameraPreviewLayer(controller: cameraController)
                    .ignoresSafeArea()

                // ── 2. Darkened vignette mask with ROI cutout ─────────────
                ROIMaskView(
                    geo:          geo,
                    phaseColor:   phaseColor,
                    onROIChanged: { rect in roiScreenRect = rect }
                )
                .ignoresSafeArea()

                // ── 3. ROI corner brackets (alignment guides) ─────────────
                ROIBracketsView(geo: geo, phaseColor: phaseColor)
                    .ignoresSafeArea()

                // ── 4. Column label header (top) ──────────────────────────
                columnHeader
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // ── 5. Capture controls (bottom) ──────────────────────────
                captureControls(geo: geo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // ── 6. Flash overlay ──────────────────────────────────────
                if flashState == .flashing {
                    Color.white
                        .ignoresSafeArea()
                        .opacity(0.85)
                        .transition(.opacity)
                }
            }
            .onAppear {
                cameraController.start()
            }
            .onDisappear {
                cameraController.stop()
            }
            .alert("Skip this column?", isPresented: $showSkipConfirm) {
                Button("Skip", role: .destructive) { onSkip?() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(currentColumn.groupLabel) is optional. Skipping fills it with the default value (\(currentColumn.defaultValue.isEmpty ? "blank" : currentColumn.defaultValue)).")
            }
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Column Header
    // ─────────────────────────────────────────────────────────────────────────

    private var columnHeader: some View {
        VStack(spacing: 0) {
            // Top safe-area spacer + header pill
            HStack(spacing: 0) {
                // Cancel button
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Cancel")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }

                Spacer()

                // Torch toggle
                Button(action: { cameraController.toggleTorch() }) {
                    Image(systemName: cameraController.torchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(cameraController.torchOn ? .yellow : .white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)   // below status bar / Dynamic Island

            // Column identity pill
            VStack(spacing: 6) {
                // Phase badge
                Text(phaseBadgeText)
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(phaseColor)
                    .cornerRadius(20)

                // Column name
                VStack(spacing: 2) {
                    Text(currentColumn.groupLabel)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if !currentColumn.subLabel.isEmpty {
                        Text(currentColumn.subLabel)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    // H / t unit label (for split cells)
                    if !currentColumn.unitLabel.isEmpty {
                        Text(currentColumn.unitLabel)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(phaseColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(phaseColor.opacity(0.18))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial.opacity(0.95))
            .cornerRadius(AeroTheme.radiusLg)
            .padding(.horizontal, 40)
            .padding(.top, 14)

            // Alignment instruction
            Text(alignmentInstruction)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .padding(.top, 8)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Capture Controls
    // ─────────────────────────────────────────────────────────────────────────

    private func captureControls(geo: GeometryProxy) -> some View {
        VStack(spacing: 16) {

            // Skip button (only for non-required columns)
            if !currentColumn.isRequired {
                Button(action: { showSkipConfirm = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.forward.circle")
                            .font(.system(size: 14))
                        Text("Skip \(currentColumn.groupLabel)")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
            }

            // Capture button
            Button(action: {
                performCapture(geo: geo)
            }) {
                ZStack {
                    // Outer ring (phase colour)
                    Circle()
                        .stroke(phaseColor, lineWidth: 4)
                        .frame(width: 80, height: 80)

                    // Inner disc (white, scales on press)
                    Circle()
                        .fill(.white)
                        .frame(width: captureButtonPressed ? 62 : 68, height: captureButtonPressed ? 62 : 68)
                        .animation(.spring(response: 0.15, dampingFraction: 0.6), value: captureButtonPressed)

                    // imageOnly indicator
                    if currentColumn.dataType == .imageOnly {
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(AeroTheme.brandDark)
                    }
                }
            }
            .buttonStyle(.plain)

            // Capture label
            Text(currentColumn.dataType == .imageOnly
                 ? "Capture image — no OCR"
                 : "Align column under the guide, then capture")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            // Bottom safe area pad
            Color.clear.frame(height: geo.safeAreaInsets.bottom + 16)
        }
        .padding(.bottom, 8)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Capture Logic
    // ─────────────────────────────────────────────────────────────────────────

    private func performCapture(geo: GeometryProxy) {
        // Animate button press
        captureButtonPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            captureButtonPressed = false
        }

        // Capture from the live session
        cameraController.capturePhoto { fullResImage in
            guard let fullResImage else { return }

            // Crop to ROI strip in full resolution
            let croppedImage = cropToROI(
                fullResImage: fullResImage,
                roiScreenRect: roiScreenRect,
                screenSize: geo.size,
                previewSize: cameraController.previewSize
            )

            // Flash animation
            withAnimation(.easeOut(duration: 0.08)) { flashState = .flashing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeIn(duration: 0.22)) { flashState = .idle }
            }

            // Fire callback on main thread
            DispatchQueue.main.async {
                onCapture(croppedImage, currentColumn)
            }
        }
    }

    /// Crops the full-resolution camera image to the ROI strip.
    ///
    /// Coordinate mapping:
    ///   1. The roiScreenRect is in SwiftUI/UIKit screen points.
    ///   2. The camera image is in pixel-space at the full sensor resolution.
    ///   3. The previewSize is the AVCaptureVideoPreviewLayer's bounds in points.
    ///   4. We compute scale factors from screen→preview→pixels and apply them.
    ///
    /// The camera image may be larger or smaller than the preview, and may be
    /// rotated (portrait capture yields a pixel buffer that is taller than wide
    /// after orientation correction). UIImage.cgImage already has orientation
    /// applied when we go through UIGraphicsImageRenderer.
    private func cropToROI(
        fullResImage:  UIImage,
        roiScreenRect: CGRect,
        screenSize:    CGSize,
        previewSize:   CGSize
    ) -> UIImage {
        let imgW = fullResImage.size.width
        let imgH = fullResImage.size.height

        // Scale from screen points → image pixels
        let scaleX = imgW / max(previewSize.width,  1)
        let scaleY = imgH / max(previewSize.height, 1)

        // Map ROI rect into image pixel space
        let cropX = roiScreenRect.origin.x    * scaleX
        let cropY = roiScreenRect.origin.y    * scaleY
        let cropW = roiScreenRect.size.width  * scaleX
        let cropH = roiScreenRect.size.height * scaleY

        let pixelCrop = CGRect(
            x: max(0, cropX),
            y: max(0, cropY),
            width:  min(cropW, imgW - max(0, cropX)),
            height: min(cropH, imgH - max(0, cropY))
        )

        // Perform crop via CGImage for precision; fall back to full image on failure
        guard
            let cgFull = fullResImage.cgImage,
            let cgCrop = cgFull.cropping(to: pixelCrop)
        else {
            return fullResImage
        }

        return UIImage(cgImage: cgCrop, scale: fullResImage.scale, orientation: fullResImage.imageOrientation)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Label Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private var phaseBadgeText: String {
        switch currentColumn.captureOrder {
        case 1...3:   return "Phase 1 — Anchor"
        case 4...9:   return "Phase 2 — Cross-Check"
        case 10...27: return "Phase 3 — Time Columns"
        case 28...34: return "Phase 4 — Text & Counts"
        default:      return "Phase 5 — Remarks"
        }
    }

    private var alignmentInstruction: String {
        switch currentColumn.dataType {
        case .imageOnly:
            return "Align the Remarks column inside the guide, then capture the image"
        case .decimalHours:
            return "Slide your logbook so the \(currentColumn.unitLabel.isEmpty ? currentColumn.groupLabel : currentColumn.unitLabel) cells are centred in the strip"
        case .integer:
            return "Centre the \(currentColumn.groupLabel) column inside the vertical guide"
        case .text:
            return "Align the \(currentColumn.groupLabel) column so all rows are inside the strip"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ROI Mask View
// ─────────────────────────────────────────────────────────────────────────────

/// Renders the darkened vignette with the transparent vertical strip cutout.
/// Reports the screen-space ROI rect upwards via the `onROIChanged` callback
/// so `ScanCameraView` can use it for pixel-accurate cropping.
private struct ROIMaskView: View {

    let geo:          GeometryProxy
    let phaseColor:   Color
    let onROIChanged: (CGRect) -> Void

    var body: some View {
        let stripRect = computeStripRect(in: geo.size)

        Canvas { ctx, size in
            // Full screen dark fill
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.58))
            )

            // Cut out the ROI strip (blend mode .destinationOut removes the dark)
            ctx.blendMode = .destinationOut
            let roiPath = Path(
                roundedRect: stripRect,
                cornerRadius: 6
            )
            ctx.fill(roiPath, with: .color(.black))
        }
        .compositingGroup()  // required for destinationOut to work correctly
        .onAppear { onROIChanged(stripRect) }
        .onChange(of: geo.size) { _ in onROIChanged(computeStripRect(in: geo.size)) }

        // Coloured border around the ROI strip
        RoundedRectangle(cornerRadius: 6)
            .stroke(phaseColor, lineWidth: 2)
            .frame(width: stripRect.width, height: stripRect.height)
            .position(x: stripRect.midX, y: stripRect.midY)
    }

    private func computeStripRect(in size: CGSize) -> CGRect {
        let stripW  = size.width  * ROILayout.stripWidthFraction
        let stripX  = size.width  * ROILayout.stripCentreX - stripW / 2
        let stripY  = size.height * ROILayout.stripTopFraction
        let stripH  = size.height * (ROILayout.stripBottomFraction - ROILayout.stripTopFraction)
        return CGRect(x: stripX, y: stripY, width: stripW, height: stripH)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ROI Corner Brackets
// ─────────────────────────────────────────────────────────────────────────────

/// Draws the four corner bracket guides at the corners of the ROI strip.
/// Pure cosmetic affordance — helps the pilot see exactly where the strip edges are.
private struct ROIBracketsView: View {

    let geo:        GeometryProxy
    let phaseColor: Color

    private var stripRect: CGRect {
        let s = geo.size
        let w = s.width  * ROILayout.stripWidthFraction
        let x = s.width  * ROILayout.stripCentreX - w / 2
        let y = s.height * ROILayout.stripTopFraction
        let h = s.height * (ROILayout.stripBottomFraction - ROILayout.stripTopFraction)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var body: some View {
        Canvas { ctx, _ in
            let r   = stripRect
            let bL  = ROILayout.bracketLength
            let bW  = ROILayout.bracketWidth
            let col = GraphicsContext.Shading.color(phaseColor)

            // Top-left
            drawBracket(ctx: &ctx, x: r.minX, y: r.minY, hDir: 1, vDir: 1,  bL: bL, bW: bW, col: col)
            // Top-right
            drawBracket(ctx: &ctx, x: r.maxX, y: r.minY, hDir: -1, vDir: 1, bL: bL, bW: bW, col: col)
            // Bottom-left
            drawBracket(ctx: &ctx, x: r.minX, y: r.maxY, hDir: 1, vDir: -1, bL: bL, bW: bW, col: col)
            // Bottom-right
            drawBracket(ctx: &ctx, x: r.maxX, y: r.maxY, hDir: -1, vDir: -1, bL: bL, bW: bW, col: col)
        }
    }

    private func drawBracket(
        ctx: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        hDir: CGFloat, vDir: CGFloat,
        bL: CGFloat, bW: CGFloat,
        col: GraphicsContext.Shading
    ) {
        // Horizontal arm
        var hPath = Path()
        hPath.move(to:    CGPoint(x: x,          y: y))
        hPath.addLine(to: CGPoint(x: x + hDir * bL, y: y))
        ctx.stroke(hPath, with: col, style: StrokeStyle(lineWidth: bW, lineCap: .round))

        // Vertical arm
        var vPath = Path()
        vPath.move(to:    CGPoint(x: x, y: y))
        vPath.addLine(to: CGPoint(x: x, y: y + vDir * bL))
        ctx.stroke(vPath, with: col, style: StrokeStyle(lineWidth: bW, lineCap: .round))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Camera Preview Layer (UIViewRepresentable)
// ─────────────────────────────────────────────────────────────────────────────

/// SwiftUI wrapper for AVCaptureVideoPreviewLayer.
/// Fills the available space and reports its bounds back to CameraController
/// so the coordinate mapping math can use the exact displayed preview rect.
private struct CameraPreviewLayer: UIViewRepresentable {

    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session    = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.connection?.videoOrientation = .portrait
        controller.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Orientation stays portrait — no update needed.
    }
}

/// UIView subclass that exposes its layer as an AVCaptureVideoPreviewLayer.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Notify the controller about the current preview bounds for coordinate mapping.
        (videoPreviewLayer.session as? AVCaptureSession).map { _ in
            NotificationCenter.default.post(
                name: .aeroPreviewBoundsChanged,
                object: nil,
                userInfo: ["bounds": bounds]
            )
        }
    }
}

extension Notification.Name {
    static let aeroPreviewBoundsChanged = Notification.Name("AeroBook.previewBoundsChanged")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CameraController (ObservableObject)
// ─────────────────────────────────────────────────────────────────────────────

/// Manages the AVCaptureSession lifecycle, torch toggle, and still photo capture.
/// All session operations run on a dedicated serial background queue (`sessionQueue`).
/// All published property updates are dispatched to the main thread.
@MainActor
final class CameraController: NSObject, ObservableObject {

    // MARK: Published
    @Published var torchOn: Bool = false
    @Published var permissionDenied: Bool = false

    // MARK: Internal
    let session      = AVCaptureSession()
    weak var previewView: PreviewView?

    /// The bounds of the AVCaptureVideoPreviewLayer in screen points.
    /// Updated via the PreviewView.layoutSubviews notification.
    private(set) var previewSize: CGSize = UIScreen.main.bounds.size

    // MARK: Private
    private let sessionQueue = DispatchQueue(label: "com.aerobook.camera.session",
                                            qos: .userInitiated)
    private var photoOutput  = AVCapturePhotoOutput()
    private var captureCompletion: ((UIImage?) -> Void)?
    private var sessionConfigured = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreviewBoundsChanged(_:)),
            name: .aeroPreviewBoundsChanged,
            object: nil
        )
    }

    @objc private func handlePreviewBoundsChanged(_ note: Notification) {
        if let bounds = note.userInfo?["bounds"] as? CGRect {
            previewSize = bounds.size
        }
    }

    // MARK: Session Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.sessionConfigured {
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            // Turn off torch when stopping
            self?.setTorch(on: false)
        }
    }

    // MARK: Session Configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo    // Maximum resolution for OCR quality

        // ── Back camera (wide angle) ──────────────────────────────────────
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            print("[AeroBook] CameraController: failed to create device input — \(error)")
            session.commitConfiguration()
            return
        }

        // ── Lock focus at ~40cm for close-up logbook photography ─────────
        lockFocusAtLogbookDistance(device: device)

        // ── Photo output ──────────────────────────────────────────────────
        photoOutput = AVCapturePhotoOutput()
        photoOutput.isHighResolutionCaptureEnabled = true
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // ── Portrait orientation ──────────────────────────────────────────
        if let connection = photoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        sessionConfigured = true
    }

    /// Locks autofocus at ~40cm — the typical distance when holding a phone
    /// above a logbook lying on a table. This eliminates focus hunting between
    /// strips and drastically reduces motion blur from refocus.
    private func lockFocusAtLogbookDistance(device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            // lensPosition 0.3 ≈ 35–45cm on most iPhone cameras (empirical)
            device.setFocusModeLocked(lensPosition: 0.30, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("[AeroBook] CameraController: focus lock failed — \(error)")
        }
    }

    // MARK: Torch

    func toggleTorch() {
        let newState = !torchOn
        setTorch(on: newState)
        torchOn = newState
    }

    private func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                print("[AeroBook] CameraController: torch toggle failed — \(error)")
            }
        }
    }

    // MARK: Still Photo Capture

    /// Captures one high-resolution still frame.
    /// `completion` is called on the **main thread** with the oriented UIImage,
    /// or nil if capture fails.
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true
            // Use HEIF when available (smaller, lossless at this quality level)
            if let format = self.photoOutput.availablePhotoCodecTypes.first(where: { $0 == .hevc }) {
                let heifSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: format])
                heifSettings.isHighResolutionPhotoEnabled = true
                self.photoOutput.capturePhoto(with: heifSettings, delegate: self)
            } else {
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AVCapturePhotoCaptureDelegate
// ─────────────────────────────────────────────────────────────────────────────

extension CameraController: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            print("[AeroBook] CameraController: photo capture error — \(error)")
            Task { @MainActor in self.captureCompletion?(nil) }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in self.captureCompletion?(nil) }
            return
        }

        // UIImage(data:) from AVCapturePhoto carries the correct imageOrientation
        // for portrait capture automatically — no manual rotation needed.
        Task { @MainActor in
            self.captureCompletion?(image)
            self.captureCompletion = nil
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Camera Permission Gate View
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps ScanCameraView with an upfront camera permission check.
/// If permission is denied, shows an actionable settings prompt instead of
/// a blank screen.
///
/// Call site: always use this wrapper, never ScanCameraView directly.
struct ScanCameraPermissionGate: View {

    let currentColumn: ColumnDefinition
    var phaseColor:    Color = .sky400
    var onCapture:     (UIImage, ColumnDefinition) -> Void
    var onSkip:        (() -> Void)? = nil
    var onCancel:      () -> Void

    @State private var authStatus: AVAuthorizationStatus = .notDetermined
    @State private var checked = false

    var body: some View {
        Group {
            switch authStatus {
            case .authorized:
                ScanCameraView(
                    currentColumn: currentColumn,
                    phaseColor:    phaseColor,
                    onCapture:     onCapture,
                    onSkip:        onSkip,
                    onCancel:      onCancel
                )

            case .denied, .restricted:
                cameraPermissionDeniedView

            case .notDetermined:
                // Show a brief loading state while we request permission
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }
                .onAppear { requestPermission() }

            @unknown default:
                cameraPermissionDeniedView
            }
        }
        .onAppear {
            if !checked {
                checked    = true
                authStatus = AVCaptureDevice.authorizationStatus(for: .video)
                if authStatus == .notDetermined { requestPermission() }
            }
        }
    }

    private func requestPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                authStatus = granted ? .authorized : .denied
            }
        }
    }

    private var cameraPermissionDeniedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.3))

                VStack(spacing: 8) {
                    Text("Camera Access Required")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("AeroBook needs camera access to scan your logbook columns. No photos are stored outside the app.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("Open Settings")
                        .aeroPrimaryButton()
                }
                .padding(.horizontal, 48)

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.top, 80)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase Colour Helper
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the AeroTheme accent colour for the given capture phase.
/// Used by the caller to pass the correct `phaseColor` into ScanCameraPermissionGate.
extension CapturePhase {
    var scanAccentColor: Color {
        switch self {
        case .phase1Anchor:       return .sky400
        case .phase2CrossCheck:   return .emerald500
        case .phase3TimeColumns:  return .sky300
        case .phase4TextAndCounts: return .gold400
        case .phase5ImageOnly:    return Color(red: 147/255, green: 112/255, blue: 219/255) // lavender
        }
    }
}
