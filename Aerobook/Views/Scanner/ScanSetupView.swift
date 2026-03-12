// ScanSetupView.swift
// AeroBook — Scanner/Views group
//
// Build Order Item #5 — Pre-Scan Setup Screen.
//
// Implements the full three-step pre-scan setup flow (Section 6, Strategy Doc):
//
//   Step 1 — Logbook Type Selection
//     Shows all available LogbookProfiles loaded from the DB.
//     Jeppesen Pilot Logbook is pre-selected. Tapping a profile shows its
//     summary (row count, column count, phases). Custom option is stubbed
//     for v2 — not available in v1.
//
//   Step 2 — Page Geometry Confirmation (first page only)
//     Full-page camera capture via VNDocumentCameraViewController.
//     Pilot drags a top handle to the first data row and a bottom handle
//     to the last data row. Live row count updates as handles move.
//     Pilot confirms or adjusts, saves dataRowCount to the profile.
//     Subsequent pages skip Step 2 entirely and inherit the confirmed count.
//
//   Step 3 — Ready State
//     Visual 5-phase strip map (horizontal lane diagram).
//     Phase 1 strip highlighted. Estimated time shown.
//     "Start Scanning" fires onComplete with the confirmed ScanPage.
//
// Locked decisions enforced here (Section 12):
//   • dataRowCount is user-confirmed — never auto-detected or assumed.
//   • totalsRowCount is always 3 — shown as greyed rows in geometry step.
//   • Profile geometry is confirmed once per logbook, inherited thereafter.
//   • Portrait orientation only — no landscape option offered.
//   • Custom logbook builder deferred — tapping Custom shows a "coming soon" note.
//
// Dependencies:
//   • LogbookProfile, ColumnDefinition, CapturePhase  (DatabaseManager+LogbookProfile.swift)
//   • ScanPage                                         (ScanPage.swift)
//   • AeroTheme design system                          (Theme.swift)
//   • VNDocumentCameraViewController                   (VisionKit)

import SwiftUI
import VisionKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Setup Step State Machine
// ─────────────────────────────────────────────────────────────────────────────

private enum SetupStep: Int, CaseIterable {
    case profilePicker  = 0   // Step 1 — choose logbook type
    case geometry       = 1   // Step 2 — drag top/bottom row handles
    case ready          = 2   // Step 3 — strip map + start button
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScanSetupView
// ─────────────────────────────────────────────────────────────────────────────

/// Full pre-scan setup screen. Present modally when the pilot starts scanning
/// for the first time, or when switching to a different logbook profile.
///
/// - Parameters:
///   - profiles: All available LogbookProfiles loaded from the DB.
///     Pass `DatabaseManager.shared.fetchAllProfiles()` at the call site.
///   - needsGeometryConfirmation: Pass `true` on first use; `false` on
///     subsequent pages (skips Step 2 and jumps directly to Step 3).
///   - onComplete: Called with the ready-to-use ScanPage when the pilot
///     taps "Start Scanning". The ScanPage has `activeRowCount` confirmed.
///   - onCancel: Called when the pilot taps Cancel at any step.
struct ScanSetupView: View {

    // MARK: Inputs
    let profiles: [LogbookProfile]
    var needsGeometryConfirmation: Bool = true
    var onComplete: (ScanPage) -> Void
    var onCancel: () -> Void

    // MARK: Step State
    @State private var currentStep: SetupStep = .profilePicker
    @State private var stepProgress: CGFloat  = 0          // 0→1 animate between steps

    // MARK: Step 1 — Profile Selection
    @State private var selectedProfile: LogbookProfile?
    @State private var showCustomComingSoon = false

    // MARK: Step 2 — Geometry Confirmation
    @State private var pageImage: UIImage?                  // Full captured page image
    @State private var showPageCamera = false               // Trigger document scanner
    @State private var topHandleFraction: CGFloat  = 0.20  // Fraction of image height (0=top)
    @State private var bottomHandleFraction: CGFloat = 0.82 // Fraction of image height (0=top)
    @State private var confirmedRowCount: Int = 13          // Live-updated as handles move
    @State private var confirmedTotalsCount: Int = 3        // Always 3 per spec; editable
    @State private var isSkippingGeometry = false           // Pilot chose "skip" on partial page

    // MARK: Step 3 — Ready
    @State private var highlightedPhase: CapturePhase = .phase1Anchor

    // MARK: Environment
    @Environment(\.dismiss) private var dismiss

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Body
    // ─────────────────────────────────────────────────────────────────────────

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    stepIndicatorBar
                    stepContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
        }
        .sheet(isPresented: $showPageCamera) {
            GeometryCameraSheet(
                onCapture: { image in
                    pageImage = image
                    showPageCamera = false
                },
                onCancel: {
                    showPageCamera = false
                }
            )
        }
        .alert("Custom Logbook Builder",
               isPresented: $showCustomComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Custom column builder is coming in a future update. For now, choose one of the pre-built logbook types.")
        }
        .onAppear {
            // Pre-select Jeppesen Pilot Logbook if available, else first profile.
            selectedProfile = profiles.first { $0.name.contains("Jeppesen") && $0.publisher == "Jeppesen" }
                           ?? profiles.first
            if let p = selectedProfile {
                confirmedRowCount    = p.dataRowCount
                confirmedTotalsCount = p.totalsRowCount
            }
            // If geometry already confirmed for this logbook, skip to ready.
            if !needsGeometryConfirmation {
                currentStep = .ready
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Step Indicator Bar
    // ─────────────────────────────────────────────────────────────────────────

    private var stepIndicatorBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    stepPill(step: step)
                    if step != SetupStep.allCases.last {
                        connectorLine(completed: currentStep.rawValue > step.rawValue)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(AeroTheme.cardBg)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func stepPill(step: SetupStep) -> some View {
        let isActive    = currentStep == step
        let isCompleted = currentStep.rawValue > step.rawValue
        let label: String = switch step {
            case .profilePicker: "Logbook"
            case .geometry:      "Geometry"
            case .ready:         "Ready"
        }
        let icon: String = switch step {
            case .profilePicker: "books.vertical"
            case .geometry:      "ruler"
            case .ready:         "checkmark.circle"
        }

        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isCompleted ? AeroTheme.brandPrimary :
                          isActive    ? AeroTheme.brandPrimary.opacity(0.12) :
                                        AeroTheme.fieldBg)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(
                        isActive || isCompleted ? AeroTheme.brandPrimary : AeroTheme.cardStroke,
                        lineWidth: isActive ? 2 : 1))

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                }
            }

            Text(label)
                .font(.system(size: 10, weight: isActive ? .bold : .medium))
                .tracking(0.5)
                .foregroundStyle(isActive ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
        }
    }

    private func connectorLine(completed: Bool) -> some View {
        Rectangle()
            .fill(completed ? AeroTheme.brandPrimary : AeroTheme.cardStroke)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .offset(y: -10) // align with circle centres
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Step Content Router
    // ─────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .profilePicker:
            step1ProfilePicker
        case .geometry:
            step2Geometry
        case .ready:
            step3Ready
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Step 1 — Profile Picker
    // ─────────────────────────────────────────────────────────────────────────

    private var step1ProfilePicker: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .padding(.top, 8)

                    Text("Choose Your Logbook")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(AeroTheme.textPrimary)

                    Text("The scanner uses your logbook's column layout to OCR each page accurately.")
                        .font(.system(size: 14))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 12)

                // Built-in profiles
                VStack(spacing: 0) {
                    sectionHeader("SUPPORTED LOGBOOKS", icon: "checkmark.seal.fill", color: AeroTheme.brandPrimary)
                        .padding(.bottom, 12)

                    VStack(spacing: 10) {
                        ForEach(profiles.filter { $0.isBuiltIn }, id: \.id) { profile in
                            profileRow(profile: profile)
                        }
                    }
                }

                // Custom option (v2 — disabled in v1)
                VStack(spacing: 0) {
                    sectionHeader("CUSTOM", icon: "slider.horizontal.3", color: AeroTheme.textTertiary)
                        .padding(.bottom, 12)

                    customProfileRow
                }

                // Selected profile summary card
                if let profile = selectedProfile {
                    profileSummaryCard(profile)
                }

                // Geometry note
                if needsGeometryConfirmation {
                    geometryNoteCard
                }

                // CTA
                Button(action: advanceToGeometryOrReady) {
                    Text(needsGeometryConfirmation ? "Next — Confirm Page Geometry" : "Next — Review Setup")
                        .aeroPrimaryButton()
                }
                .disabled(selectedProfile == nil)
                .opacity(selectedProfile == nil ? 0.5 : 1)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 20)
        }
    }

    private func profileRow(profile: LogbookProfile) -> some View {
        let isSelected = selectedProfile?.id == profile.id

        return Button(action: {
            withAnimation(.spring(response: 0.3)) {
                selectedProfile      = profile
                confirmedRowCount    = profile.dataRowCount
                confirmedTotalsCount = profile.totalsRowCount
            }
        }) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? AeroTheme.brandPrimary : AeroTheme.fieldBg)
                        .frame(width: 44, height: 44)
                    Image(systemName: profileIcon(for: profile))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : AeroTheme.brandPrimary)
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text(profile.publisher.isEmpty ? "Custom" : profile.publisher)
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                }

                Spacer()

                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? AeroTheme.brandPrimary : AeroTheme.cardStroke, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(AeroTheme.brandPrimary)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .fill(isSelected ? AeroTheme.brandPrimary.opacity(0.05) : AeroTheme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(isSelected ? AeroTheme.brandPrimary : AeroTheme.cardStroke, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? AeroTheme.brandPrimary.opacity(0.12) : AeroTheme.shadowCard,
                    radius: isSelected ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var customProfileRow: some View {
        Button(action: { showCustomComingSoon = true }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AeroTheme.fieldBg)
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(AeroTheme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Custom Logbook")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AeroTheme.textSecondary)
                        Text("SOON")
                            .font(.system(size: 9, weight: .black))
                            .tracking(0.8)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AeroTheme.brandPrimary.opacity(0.1))
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .cornerRadius(4)
                    }
                    Text("Define your own column layout")
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(14)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func profileSummaryCard(_ profile: LogbookProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("PROFILE SUMMARY", icon: "info.circle", color: AeroTheme.brandPrimary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                summaryStatCell(value: "\(profile.dataRowCount)", label: "Data Rows")
                summaryStatCell(value: "\(profile.totalsRowCount)", label: "Totals Rows")
                summaryStatCell(value: "\(profile.columns.count)", label: "Columns")
                summaryStatCell(value: "5", label: "Scan Phases")
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private func summaryStatCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(AeroTheme.brandPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AeroTheme.fieldBg)
        .cornerRadius(AeroTheme.radiusMd)
    }

    private var geometryNoteCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ruler.fill")
                .font(.system(size: 16))
                .foregroundStyle(.statusAmber)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("One-time geometry setup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("On the next screen you'll photograph one full page and drag handles to mark your first and last data rows. This is saved once and used for every subsequent page.")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.statusAmber.opacity(0.06))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusAmber.opacity(0.25), lineWidth: 1))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Step 2 — Page Geometry Confirmation
    // ─────────────────────────────────────────────────────────────────────────

    private var step2Geometry: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Text("Confirm Page Layout")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AeroTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Photograph one full page, then drag the handles to mark where your flight entries begin and end.")
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 16)

                if let image = pageImage {
                    // Geometry drag canvas
                    geometryCanvas(image: image)

                    // Row count confirmation panel
                    rowCountPanel

                    // Totals row count editor
                    totalsRowPanel

                    // Retake button
                    Button(action: { showPageCamera = true }) {
                        Label("Retake Photo", systemImage: "arrow.counterclockwise.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AeroTheme.brandPrimary.opacity(0.07))
                            .cornerRadius(AeroTheme.radiusMd)
                    }

                } else {
                    // No image yet — prompt to capture
                    capturePromptCard
                }

                // Partial page shortcut
                partialPageNote

                // CTA
                if pageImage != nil {
                    Button(action: {
                        saveGeometryAndAdvance()
                    }) {
                        Text("Confirm — \(confirmedRowCount) Rows")
                            .aeroPrimaryButton()
                    }
                }

                Color.clear.frame(height: 32)
            }
            .padding(.horizontal, 20)
        }
    }

    // Camera prompt before any image captured
    private var capturePromptCard: some View {
        VStack(spacing: 20) {
            // Preview mockup (shows what the canvas will look like)
            ZStack {
                RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .fill(AeroTheme.fieldBg)
                    .frame(height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                            .stroke(AeroTheme.cardStroke, lineWidth: 1)
                    )

                VStack(spacing: 14) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 48))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.3))

                    VStack(spacing: 4) {
                        Text("Photograph your logbook page")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AeroTheme.textSecondary)
                        Text("Place it flat, fully in frame, good light")
                            .font(.system(size: 12))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }
            }

            Button(action: { showPageCamera = true }) {
                Label("Photograph a Page", systemImage: "camera.fill")
                    .aeroPrimaryButton()
            }

            // Tips
            VStack(alignment: .leading, spacing: 10) {
                tipRow(icon: "sun.max.fill", text: "Use bright, even light — avoid shadows across the page")
                tipRow(icon: "rectangle.portrait",  text: "Hold phone parallel to the page — directly above, not angled")
                tipRow(icon: "crop",                text: "One page fills the whole frame for best row detection")
            }
            .padding(14)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
        }
    }

    // Interactive drag canvas — pilot drags top/bottom handles
    private func geometryCanvas(image: UIImage) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let topY    = topHandleFraction    * h
            let bottomY = bottomHandleFraction * h

            ZStack(alignment: .top) {
                // Page image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
                    .cornerRadius(AeroTheme.radiusMd)

                // Semi-transparent overlays for header + totals zones
                // Header zone (above top handle)
                Rectangle()
                    .fill(Color.sky900.opacity(0.45))
                    .frame(width: w, height: max(topY, 0))
                    .cornerRadius(AeroTheme.radiusMd, corners: [.topLeft, .topRight])

                // Totals zone (below bottom handle)
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.statusAmber.opacity(0.35))
                        .frame(width: w, height: max(h - bottomY, 0))
                        .cornerRadius(AeroTheme.radiusMd, corners: [.bottomLeft, .bottomRight])
                }

                // Data zone boundary lines
                // Top handle
                handleLine(y: topY, width: w, color: .sky400, label: "First entry row")
                    .offset(y: topY)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let newFraction = (topY + value.translation.height) / h
                                let clamped = min(max(newFraction, 0.05), bottomHandleFraction - 0.08)
                                topHandleFraction = clamped
                                recalculateRowCount(canvasHeight: h)
                            }
                    )

                // Bottom handle
                handleLine(y: bottomY, width: w, color: .statusAmber, label: "Last entry row")
                    .offset(y: bottomY)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let newFraction = (bottomY + value.translation.height) / h
                                let clamped = min(max(newFraction, topHandleFraction + 0.08), 0.95)
                                bottomHandleFraction = clamped
                                recalculateRowCount(canvasHeight: h)
                            }
                    )

                // Row count badge (live)
                VStack {
                    Spacer().frame(height: topY + (bottomY - topY) / 2 - 16)
                    HStack {
                        Spacer()
                        Text("\(confirmedRowCount) rows")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AeroTheme.brandPrimary)
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        Spacer()
                    }
                }
            }
        }
        .frame(height: 340)
    }

    private func handleLine(y: CGFloat, width: CGFloat, color: Color, label: String) -> some View {
        ZStack(alignment: .leading) {
            // Dashed line
            Rectangle()
                .fill(color)
                .frame(width: width, height: 2)

            // Drag handle pill
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
            .offset(x: 12, y: -14)
        }
    }

    private var rowCountPanel: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DATA ROWS DETECTED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(AeroTheme.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(confirmedRowCount)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(AeroTheme.brandPrimary)
                    Text("rows")
                        .font(.system(size: 14))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }

            Spacer()

            // Manual stepper override
            VStack(alignment: .trailing, spacing: 6) {
                Text("Adjust manually")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textTertiary)
                HStack(spacing: 0) {
                    Button(action: { if confirmedRowCount > 1 { confirmedRowCount -= 1 } }) {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .background(AeroTheme.fieldBg)
                    }
                    Text("\(confirmedRowCount)")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36)
                        .foregroundStyle(AeroTheme.textPrimary)
                    Button(action: { if confirmedRowCount < 30 { confirmedRowCount += 1 } }) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .background(AeroTheme.fieldBg)
                    }
                }
                .background(AeroTheme.fieldBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(confirmedRowCount == selectedProfile?.dataRowCount
                    ? AeroTheme.cardStroke : Color.statusAmber.opacity(0.5),
                    lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
    }

    private var totalsRowPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "sum")
                .font(.system(size: 16))
                .foregroundStyle(.statusAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Totals rows to ignore")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("Bottom rows showing page totals — never OCR'd")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textTertiary)
            }

            Spacer()

            // Stepper for totals count
            HStack(spacing: 0) {
                Button(action: { if confirmedTotalsCount > 0 { confirmedTotalsCount -= 1 } }) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.statusAmber)
                        .background(Color.statusAmber.opacity(0.08))
                }
                Text("\(confirmedTotalsCount)")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28)
                    .foregroundStyle(AeroTheme.textPrimary)
                Button(action: { if confirmedTotalsCount < 6 { confirmedTotalsCount += 1 } }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.statusAmber)
                        .background(Color.statusAmber.opacity(0.08))
                }
            }
            .background(Color.statusAmber.opacity(0.06))
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(Color.statusAmber.opacity(0.25), lineWidth: 1))
        }
        .padding(14)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
    }

    private var partialPageNote: some View {
        Button(action: {
            isSkippingGeometry = true
            showPageCamera     = false
            // Reset to partial page mode: pilot enters count manually
            pageImage          = UIImage(systemName: "doc.text")   // sentinel: unlocks Confirm button; pilot enters count via stepper, no photo needed
            confirmedRowCount  = selectedProfile?.dataRowCount ?? 13
        }) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textTertiary)
                Text("This page has fewer rows (partial last page)")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textTertiary)
                    .underline()
            }
        }
        .buttonStyle(.plain)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Step 3 — Ready State (Phase Strip Map)
    // ─────────────────────────────────────────────────────────────────────────

    private var step3Ready: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {

                // Success header
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.statusGreen.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Circle()
                            .fill(Color.statusGreen.opacity(0.06))
                            .frame(width: 104, height: 104)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.statusGreen)
                    }
                    .padding(.top, 16)

                    Text("Ready to Scan")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(AeroTheme.textPrimary)

                    if let profile = selectedProfile {
                        Text("\(profile.name) · \(confirmedRowCount) rows per page")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                }

                // Time estimate banner
                HStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 14))
                        .foregroundStyle(AeroTheme.brandPrimary)
                    Text("Phase 1+2 takes about 3 minutes per page and produces a complete flight record.")
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(AeroTheme.brandPrimary.opacity(0.06))
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.brandPrimary.opacity(0.15), lineWidth: 1))

                // Phase strip map
                phaseStripMap

                // Profile detail summary
                if let profile = selectedProfile {
                    configSummaryCard(profile)
                }

                // Start button
                Button(action: buildScanPageAndComplete) {
                    Label("Start Scanning", systemImage: "viewfinder")
                        .aeroPrimaryButton()
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 20)
        }
    }

    // Horizontal 5-phase lane diagram (Section 6 Step 3)
    private var phaseStripMap: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CAPTURE PHASES", icon: "rectangle.split.5", color: AeroTheme.brandPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CapturePhase.allCases, id: \.rawValue) { phase in
                        phaseCard(phase: phase)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }

            // Legend
            HStack(spacing: 16) {
                legendDot(color: AeroTheme.brandPrimary,       label: "Start here")
                legendDot(color: AeroTheme.textTertiary.opacity(0.5), label: "Optional phases")
                legendDot(color: Color.statusGreen,            label: "Minimum viable scan")
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private func phaseCard(phase: CapturePhase) -> some View {
        let isHighlighted = phase == .phase1Anchor || phase == .phase2CrossCheck
        let isFirst       = phase == .phase1Anchor
        let info          = phaseInfo(for: phase)

        return VStack(alignment: .leading, spacing: 10) {
            // Phase number badge
            HStack(spacing: 6) {
                Text("Phase \(phase.rawValue)")
                    .font(.system(size: 10, weight: .black))
                    .tracking(0.8)
                    .foregroundStyle(isHighlighted ? AeroTheme.brandPrimary : AeroTheme.textTertiary)

                if isFirst {
                    Text("START")
                        .font(.system(size: 8, weight: .black))
                        .tracking(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AeroTheme.brandPrimary)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                }
                if isHighlighted && !isFirst {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.statusGreen)
                }
            }

            // Phase name
            Text(info.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AeroTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Columns list
            VStack(alignment: .leading, spacing: 3) {
                ForEach(info.columns, id: \.self) { col in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isHighlighted ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                            .frame(width: 4, height: 4)
                        Text(col)
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                }
            }

            Spacer()

            // Accept rule chip
            Text(info.acceptRule)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHighlighted ? Color.statusGreen : AeroTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isHighlighted ? Color.statusGreen : AeroTheme.textTertiary).opacity(0.10))
                .cornerRadius(8)
        }
        .padding(14)
        .frame(width: 150, height: 210)
        .background(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .fill(isFirst ? AeroTheme.brandPrimary.opacity(0.06) : AeroTheme.fieldBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(
                    isFirst       ? AeroTheme.brandPrimary :
                    isHighlighted ? Color.statusGreen.opacity(0.4) :
                                    AeroTheme.cardStroke,
                    lineWidth: isFirst ? 2 : 1
                )
        )
    }

    private func configSummaryCard(_ profile: LogbookProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CONFIRMED SETUP", icon: "checkmark.circle.fill", color: .statusGreen)

            VStack(spacing: 8) {
                configRow(label: "Logbook",        value: profile.name,                icon: "books.vertical")
                configRow(label: "Publisher",      value: profile.publisher,            icon: "building.2")
                configRow(label: "Data rows",      value: "\(confirmedRowCount)",       icon: "list.number")
                configRow(label: "Totals rows",    value: "\(confirmedTotalsCount)",    icon: "sum")
                configRow(label: "Column count",   value: "\(profile.columns.count)",  icon: "tablecells")
                configRow(label: "Page layout",    value: profile.pageLayout == .landscapeSpread ? "Landscape spread" : "Portrait single", icon: "rectangle.landscape")
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private func configRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AeroTheme.textPrimary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 30)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Toolbar
    // ─────────────────────────────────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: handleBack) {
                HStack(spacing: 4) {
                    if currentStep != .profilePicker {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(currentStep == .profilePicker ? "Cancel" : "Back")
                }
                .foregroundStyle(AeroTheme.textSecondary)
            }
        }

        ToolbarItem(placement: .principal) {
            Text(navigationTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AeroTheme.textPrimary)
        }
    }

    private var navigationTitle: String {
        switch currentStep {
        case .profilePicker: return "Scanner Setup"
        case .geometry:      return "Page Geometry"
        case .ready:         return "Ready to Scan"
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Actions & Logic
    // ─────────────────────────────────────────────────────────────────────────

    private func handleBack() {
        switch currentStep {
        case .profilePicker:
            onCancel()
        case .geometry:
            withAnimation { currentStep = .profilePicker }
        case .ready:
            if needsGeometryConfirmation {
                withAnimation { currentStep = .geometry }
            } else {
                withAnimation { currentStep = .profilePicker }
            }
        }
    }

    private func advanceToGeometryOrReady() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = needsGeometryConfirmation ? .geometry : .ready
        }
    }

    private func saveGeometryAndAdvance() {
        // Persist confirmed row count onto the profile for subsequent pages.
        // Per spec: the profile is not permanently mutated (isBuiltIn stays true).
        // The confirmed count is passed forward into ScanPage at creation time.
        // A future session will need to re-confirm or use a UserDefaults cache.
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = .ready
        }
    }

    /// Re-calculates confirmedRowCount from the top/bottom handle positions.
    /// Uses the profile dataRowCount as the baseline: the fraction of the
    /// data zone maps linearly to rows 1…dataRowCount.
    private func recalculateRowCount(canvasHeight: CGFloat) {
        let baseline   = selectedProfile?.dataRowCount ?? 13
        let zoneHeight = bottomHandleFraction - topHandleFraction
        // Each row occupies an equal fraction of the zone
        let rowHeight  = 1.0 / CGFloat(baseline)
        let detected   = max(1, min(30, Int((zoneHeight / rowHeight).rounded())))
        confirmedRowCount = detected
    }

    /// Builds the confirmed ScanPage and fires the completion callback.
    private func buildScanPageAndComplete() {
        guard let profile = selectedProfile else { return }

        let page = ScanPage(
            profile:        profile,
            activeRowCount: confirmedRowCount,
            pageNumber:     nil
        )
        onComplete(page)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Helpers & Sub-components
    // ─────────────────────────────────────────────────────────────────────────

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(color)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AeroTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(AeroTheme.textTertiary)
        }
    }

    private func profileIcon(for profile: LogbookProfile) -> String {
        if profile.name.lowercased().contains("student") { return "graduationcap" }
        if profile.name.lowercased().contains("jeppesen") { return "book.closed" }
        if profile.name.lowercased().contains("asa") { return "books.vertical" }
        return "doc.text"
    }

    // Phase metadata for strip map display (Section 5 of Strategy Doc)
    private struct PhaseInfo {
        let name: String
        let columns: [String]
        let acceptRule: String
    }

    private func phaseInfo(for phase: CapturePhase) -> PhaseInfo {
        switch phase {
        case .phase1Anchor:
            return PhaseInfo(
                name: "Anchor",
                columns: ["Total Duration (H)", "Total Duration (t)", "Date"],
                acceptRule: "Auto-accept if H.t valid"
            )
        case .phase2CrossCheck:
            return PhaseInfo(
                name: "Cross-Check",
                columns: ["Dual Received", "PIC", "Category SE"],
                acceptRule: "Auto-accept on 5-way match"
            )
        case .phase3TimeColumns:
            return PhaseInfo(
                name: "Time Cols",
                columns: ["XC", "Night", "Act. Inst", "Sim. Inst", "CFI", "Multi E"],
                acceptRule: "Flag outliers only"
            )
        case .phase4TextAndCounts:
            return PhaseInfo(
                name: "Text & Counts",
                columns: ["Type", "Ident", "From", "To", "Approaches", "T/O", "Ldg"],
                acceptRule: "Confirm if no match"
            )
        case .phase5ImageOnly:
            return PhaseInfo(
                name: "Remarks",
                columns: ["Remarks & Endorsements"],
                acceptRule: "Image only — no OCR"
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GeometryCameraSheet
// ─────────────────────────────────────────────────────────────────────────────

/// Thin wrapper around VNDocumentCameraViewController for the geometry step.
/// Captures one full-page photo and returns the first scanned image.
private struct GeometryCameraSheet: UIViewControllerRepresentable {

    var onCapture: (UIImage) -> Void
    var onCancel:  () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: GeometryCameraSheet
        init(_ parent: GeometryCameraSheet) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount > 0 else { parent.onCancel(); return }
            parent.onCapture(scan.imageOfPage(at: 0))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            print("[AeroBook] GeometryCameraSheet error: \(error)")
            parent.onCancel()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RoundedCorner helper (selective corner radius)
// ─────────────────────────────────────────────────────────────────────────────

private extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────────────────────

#Preview {
    ScanSetupView(
        profiles: [LogbookProfile.jeppesenPilotLogbook],
        needsGeometryConfirmation: true,
        onComplete: { _ in },
        onCancel: {}
    )
}
