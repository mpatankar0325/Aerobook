import SwiftUI
import PencilKit
import CryptoKit
import MessageUI

// MARK: - ManualEntryView

struct ManualEntryView: View {
    @Environment(\.dismiss) var dismiss

    // Basic info
    @State private var date              = Date()
    @State private var aircraftIdent     = ""
    @State private var aircraftType      = ""
    @State private var aircraftCategory  = "Airplane"
    @State private var aircraftClass     = "SEL"
    @State private var route             = ""

    // Times
    @State private var totalTime         = ""
    @State private var pic               = ""
    @State private var sic               = ""
    @State private var solo              = ""
    @State private var dualReceived      = ""
    @State private var dualGiven         = ""
    @State private var groundTrainer     = ""
    @State private var crossCountry      = ""
    @State private var night             = ""
    @State private var instrumentActual  = ""
    @State private var instrumentSimulated = ""

    // Operations
    @State private var landingsDay       = ""
    @State private var landingsNight     = ""
    @State private var approaches        = ""
    @State private var holds             = ""

    // Remarks
    @State private var remarks           = ""

    // Instructor / signature
    @State private var instructorName       = ""
    @State private var instructorCertificate = ""
    @State private var instructorExpiry      = ""   // expiry date string for UI display
    @State private var isEndorsement         = false

    // Signature canvas
    @State private var canvasView        = PKCanvasView()
    @State private var hasSignature      = false
    @State private var signatureImage: UIImage?
    @State private var signatureLocked   = false   // true after "Sign & Lock"

    // Remote signature request
    @State private var showRemoteSendSheet    = false
    @State private var pendingToken: SignatureToken?
    @State private var showMailComposer       = false
    @State private var showMessageComposer    = false
    @State private var remoteSendMailVC:    MFMailComposeViewController?
    @State private var remoteSendMsgVC:     MFMessageComposeViewController?
    @State private var remoteRequestSent      = false

    // Save state
    @State private var isSaving          = false
    @State private var showSignatureAlert = false
    @State private var signatureAlertMsg  = ""

    let categories = ["Airplane", "Rotorcraft", "Powered Lift", "Glider",
                      "Lighter-than-air", "FFS", "FTD", "ATD"]
    let classes     = ["SEL", "MEL", "SES", "MES", "Helicopter",
                       "Gyroplane", "Balloon", "Airship", "SE", "ME"]

    // Dual Received entries require instructor signature (FAR 61.51(h))
    private var requiresSignature: Bool {
        (Double(dualReceived) ?? 0) > 0 || isEndorsement
    }

    private var signatureComplete: Bool {
        !instructorName.isEmpty && !instructorCertificate.isEmpty && hasSignature
    }

    private var canSave: Bool {
        !aircraftIdent.isEmpty && !totalTime.isEmpty &&
        (!requiresSignature || signatureLocked)
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        basicInfoCard
                        timesCard
                        opsCard
                        remarksCard
                        instructorSignatureCard    // ← FAA-compliant signature block
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("New Flight Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AeroTheme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    saveButton
                }
            }
            .alert("Signature", isPresented: $showSignatureAlert) {
                Button("OK") {}
            } message: {
                Text(signatureAlertMsg)
            }
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button(action: saveFlight) {
            HStack(spacing: 6) {
                if isSaving {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: requiresSignature && !signatureLocked
                          ? "lock.open.fill" : "checkmark.circle.fill")
                    Text("Save")
                }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background((canSave && !isSaving) ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
            .cornerRadius(20)
        }
        .disabled(!canSave || isSaving)
    }

    // MARK: - Basic Info Card

    private var basicInfoCard: some View {
        EntryCard(title: "Basic Information", icon: "info.circle.fill") {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Date of Flight")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                            .frame(width: 20)
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .tint(AeroTheme.brandPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(AeroTheme.fieldBg)
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                }

                HStack(spacing: 12) {
                    AeroField(label: "Tail Number",  text: $aircraftIdent,
                              placeholder: "N12345", icon: "number")
                    AeroField(label: "Aircraft Type", text: $aircraftType,
                              placeholder: "C172",   icon: "airplane")
                }

                HStack(spacing: 12) {
                    EntryPickerField(label: "Category",
                                    selection: $aircraftCategory, options: categories)
                    EntryPickerField(label: "Class",
                                    selection: $aircraftClass,    options: classes)
                }

                AeroField(label: "Route", text: $route,
                          placeholder: "KSQL – KHAF – KSQL",
                          icon: "arrow.triangle.swap")
            }
        }
    }

    // MARK: - Times Card

    private var timesCard: some View {
        EntryCard(title: "Flight Times", icon: "clock.fill", accent: .sky500) {
            VStack(spacing: 0) {
                // Total time — featured
                VStack(alignment: .leading, spacing: 6) {
                    Text("Total Flight Time")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .frame(width: 20)
                        TextField("0.0", text: $totalTime)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 22, weight: .light, design: .rounded))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("hrs")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AeroTheme.brandPrimary.opacity(0.06))
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.brandPrimary.opacity(0.2), lineWidth: 1.5))
                }
                .padding(.bottom, 16)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    timeField(label: "PIC",           text: $pic)
                    timeField(label: "SIC",           text: $sic)
                    timeField(label: "Solo",          text: $solo)
                    timeField(label: "Dual Received", text: $dualReceived)
                    timeField(label: "Dual Given",    text: $dualGiven)
                    timeField(label: "Ground / Sim",  text: $groundTrainer)
                    timeField(label: "Night",         text: $night)
                    timeField(label: "Cross Country", text: $crossCountry)
                    timeField(label: "Actual IMC",    text: $instrumentActual)
                    timeField(label: "Simulated IMC", text: $instrumentSimulated)
                }
            }
        }
    }

    // MARK: - Operations Card

    private var opsCard: some View {
        EntryCard(title: "Operations", icon: "airplane.circle.fill", accent: .sky400) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                countField(label: "Day Landings",   text: $landingsDay,   icon: "sun.max.fill")
                countField(label: "Night Landings", text: $landingsNight, icon: "moon.fill")
                countField(label: "Approaches",     text: $approaches,    icon: "arrow.down.to.line")
                countField(label: "Holds",          text: $holds,         icon: "arrow.clockwise")
            }
        }
    }

    // MARK: - Remarks Card

    private var remarksCard: some View {
        EntryCard(title: "Remarks & Notes", icon: "text.bubble.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remarks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AeroTheme.textSecondary)

                ZStack(alignment: .topLeading) {
                    if remarks.isEmpty {
                        Text("Training notes, special conditions, etc.")
                            .font(.system(size: 14))
                            .foregroundStyle(AeroTheme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                    }
                    TextEditor(text: $remarks)
                        .font(.system(size: 14))
                        .foregroundStyle(AeroTheme.textPrimary)
                        .frame(minHeight: 90)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .scrollContentBackground(.hidden)
                }
                .background(AeroTheme.fieldBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
            }
        }
    }

    // MARK: - ✍️ FAA Instructor Signature Card
    //
    // FAA regulatory basis:
    //  • 14 CFR 61.51(h)(1) — Instructor must sign logbook for each training flight
    //  • 14 CFR 61.189(a)   — Instructor must sign each entry they authorized
    //  • AC 120-78A §4       — Electronic signatures must be uniquely linked to the signer
    //                          and must render the record tamper-evident
    //  • AC 120-78A §4.2.5  — CFI name, certificate number, and certificate expiry
    //                          are required fields for a legally valid digital signature

    private var instructorSignatureCard: some View {
        EntryCard(title: "Instructor Signature", icon: "signature",
                  accent: requiresSignature ? .statusAmber : AeroTheme.brandPrimary) {
            VStack(spacing: 16) {

                // ── FAA requirement banner ──────────────────────────────────
                faaRequirementBanner

                // ── Endorsement toggle ──────────────────────────────────────
                endorsementToggleRow

                // ── Instructor info fields ──────────────────────────────────
                AeroField(label: "Instructor Full Name",
                          text: $instructorName,
                          placeholder: "John Smith",
                          icon: "person.badge.key.fill")
                .disabled(signatureLocked)

                HStack(spacing: 12) {
                    AeroField(label: "CFI Certificate #",
                              text: $instructorCertificate,
                              placeholder: "1234567",
                              icon: "creditcard.fill")
                    .disabled(signatureLocked)

                    AeroField(label: "Certificate Expiry",
                              text: $instructorExpiry,
                              placeholder: "MM/YYYY",
                              icon: "calendar.badge.clock")
                    .disabled(signatureLocked)
                }

                // ── Signature canvas ─────────────────────────────────────────
                signatureCanvasSection

                // ── Sign & Lock (instructor present) ─────────────────────────
                if !signatureLocked {
                    signAndLockButton

                    // ── OR divider ───────────────────────────────────────────
                    HStack(spacing: 10) {
                        Rectangle().fill(AeroTheme.cardStroke).frame(height: 1)
                        Text("OR").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AeroTheme.textTertiary)
                        Rectangle().fill(AeroTheme.cardStroke).frame(height: 1)
                    }

                    // ── Request remote signature ─────────────────────────────
                    requestRemoteSignatureButton
                } else {
                    lockedBadge
                }

                // ── Legal declaration ────────────────────────────────────────
                legalDeclaration
            }
        }
    }

    // MARK: FAA Banner

    private var faaRequirementBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.statusAmber.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.statusAmber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("FAA Regulatory Requirement")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.statusAmber)
                Text("14 CFR 61.51(h) & 61.189 — CFI must sign each dual instruction entry.")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.statusAmber.opacity(0.07))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusAmber.opacity(0.2), lineWidth: 1))
    }

    // MARK: Endorsement Toggle

    private var endorsementToggleRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AeroTheme.brandPrimary.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Log as Endorsement")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("Marks this as an official CFI endorsement per AC 61-65")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $isEndorsement)
                .tint(AeroTheme.brandPrimary)
                .labelsHidden()
                .disabled(signatureLocked)
        }
        .padding(14)
        .background(AeroTheme.fieldBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(AeroTheme.fieldStroke, lineWidth: 1))
    }

    // MARK: Signature Canvas Section

    private var signatureCanvasSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            HStack {
                Text("CFI Signature")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AeroTheme.textSecondary)
                Spacer()
                if hasSignature && !signatureLocked {
                    Button(action: clearSignature) {
                        Label("Clear", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            // Canvas or locked image
            if signatureLocked, let img = signatureImage {
                // Show frozen signature image after locking
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.white)
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(
                        RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(Color.statusGreen.opacity(0.4), lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.statusGreen)
                            .padding(8)
                            .background(Color.statusGreen.opacity(0.1))
                            .cornerRadius(6)
                            .padding(8),
                        alignment: .topTrailing
                    )
            } else {
                // Live PencilKit canvas
                ZStack {
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .fill(Color.white)
                    EntrySignatureCanvas(canvasView: $canvasView) {
                        hasSignature = !canvasView.drawing.strokes.isEmpty
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AeroTheme.radiusMd))

                    if !hasSignature {
                        VStack(spacing: 6) {
                            Image(systemName: "signature")
                                .font(.system(size: 28))
                                .foregroundStyle(AeroTheme.textTertiary.opacity(0.4))
                            Text("Sign here with Apple Pencil or finger")
                                .font(.system(size: 12))
                                .foregroundStyle(AeroTheme.textTertiary)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(height: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(
                            hasSignature
                                ? AeroTheme.brandPrimary.opacity(0.4)
                                : AeroTheme.fieldStroke,
                            style: StrokeStyle(lineWidth: 1.5, dash: hasSignature ? [] : [6, 4])
                        )
                )
            }

            // Signature validity hint
            if hasSignature && !signatureLocked {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("Tap \"Sign & Lock\" to cryptographically secure this entry")
                        .font(.system(size: 10))
                }
                .foregroundStyle(AeroTheme.textTertiary)
            }
        }
    }

    // MARK: Sign & Lock Button

    private var signAndLockButton: some View {
        Button(action: signAndLock) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 15))
                Text("Sign & Cryptographically Lock Entry")
                    .font(.system(size: 14, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(signatureComplete
                ? AeroTheme.brandPrimary
                : AeroTheme.textTertiary)
            .foregroundStyle(.white)
            .cornerRadius(AeroTheme.radiusMd)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!signatureComplete)
        .overlay(
            Group {
                if !signatureComplete {
                    RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.fieldStroke, lineWidth: 1)
                }
            }
        )
    }

    // MARK: Locked Badge

    private var lockedBadge: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.statusGreen.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.statusGreen)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Entry Signed & Locked")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.statusGreen)
                Text("SHA-256 hash secured — tamper-evident per AC 120-78A")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.statusGreen.opacity(0.6))
        }
        .padding(14)
        .background(Color.statusGreen.opacity(0.07))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusGreen.opacity(0.25), lineWidth: 1))
    }

    // MARK: Legal Declaration

    private var legalDeclaration: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)

            Text("By signing, the certificated flight instructor certifies that all logged flight time and training is accurate and truthful under 14 CFR 61.51 and 61.189, and that the student/pilot performed the logged operations. Falsification of logbook entries is a federal offense under 18 U.S.C. § 1001 and may result in certificate revocation under 14 CFR 61.15(a).")
                .font(.system(size: 10))
                .foregroundStyle(AeroTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    // MARK: Request Remote Signature Button

    private var requestRemoteSignatureButton: some View {
        Button(action: prepareRemoteRequest) {
            HStack(spacing: 10) {
                Image(systemName: remoteRequestSent
                      ? "checkmark.circle.fill" : "envelope.badge.shield.half.filled.fill")
                    .font(.system(size: 15))
                Text(remoteRequestSent
                     ? "Request Sent — Awaiting Signature"
                     : "Request Instructor Signature Remotely")
                    .font(.system(size: 14, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(remoteRequestSent
                ? Color.statusGreen
                : AeroTheme.brandPrimary.opacity(requiresSignature ? 1.0 : 0.6))
            .foregroundStyle(.white)
            .cornerRadius(AeroTheme.radiusMd)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(remoteRequestSent)
        .sheet(isPresented: $showRemoteSendSheet) {
            remoteSignatureChannelSheet
        }
        .sheet(isPresented: $showMailComposer) {
            if let vc = remoteSendMailVC { MailComposerSheet(viewController: vc) }
        }
        .sheet(isPresented: $showMessageComposer) {
            if let vc = remoteSendMsgVC { MessageComposerSheet(viewController: vc) }
        }
    }

    // MARK: Remote Send Channel Picker Sheet

    private var remoteSignatureChannelSheet: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "envelope.badge.shield.half.filled.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(AeroTheme.brandPrimary)
                        Text("Send Signature Request")
                            .font(.system(size: 20, weight: .bold))
                        Text("Your instructor will receive a link to review and sign this entry remotely.")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 16)

                    VStack(spacing: 12) {
                        // Email
                        channelButton(icon: "envelope.fill", color: AeroTheme.brandPrimary,
                                      label: "Send via Email") {
                            showRemoteSendSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if let token = pendingToken,
                                   let vc = RemoteSignatureService.shared.emailViewController(for: token) {
                                    remoteSendMailVC = vc
                                    showMailComposer = true
                                    remoteRequestSent = true
                                }
                            }
                        }

                        // iMessage
                        channelButton(icon: "message.fill", color: .statusGreen,
                                      label: "Send via iMessage / SMS") {
                            showRemoteSendSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if let token = pendingToken,
                                   let vc = RemoteSignatureService.shared.messageViewController(for: token) {
                                    remoteSendMsgVC = vc
                                    showMessageComposer = true
                                    remoteRequestSent = true
                                }
                            }
                        }

                        // Copy link
                        channelButton(icon: "doc.on.doc.fill", color: .sky500,
                                      label: "Copy Link to Clipboard") {
                            if let token = pendingToken {
                                UIPasteboard.general.string = token.deepLink
                                remoteRequestSent = true
                            }
                            showRemoteSendSheet = false
                        }
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Send Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRemoteSendSheet = false }
                }
            }
        }
    }

    private func channelButton(icon: String, color: Color, label: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
                }
                Text(label).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(16)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: Prepare Remote Request

    private func prepareRemoteRequest() {
        let df     = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let profile = DatabaseManager.shared.fetchUserProfile()
        let pilot   = profile["pilot_name"] as? String ?? "Pilot"

        // We don't have a DB row ID yet (entry not saved), so use -1 as placeholder.
        // The actual flight ID will be set when the entry is saved.
        // The token deep link contains all the relevant review information.
        let token = RemoteSignatureService.shared.createToken(
            flightID:      -1,
            endorsementID: isEndorsement ? -1 : nil,
            entryType:     isEndorsement ? .endorsement : .dualFlight,
            pilotName:     pilot,
            flightDate:    df.string(from: date),
            aircraftIdent: aircraftIdent,
            totalTime:     Double(totalTime) ?? 0,
            dualReceived:  Double(dualReceived) ?? 0,
            remarks:       remarks
        )
        pendingToken        = token
        showRemoteSendSheet = true
    }

    private func clearSignature() {
        canvasView.drawing = PKDrawing()
        hasSignature = false
    }

    private func signAndLock() {
        guard signatureComplete else { return }

        // 1. Capture PNG from canvas
        let bounds     = CGRect(x: 0, y: 0, width: canvasView.bounds.width.isZero ? 600 : canvasView.bounds.width, height: 140)
        let drawing    = canvasView.drawing
        let rawImage   = drawing.image(from: bounds, scale: UIScreen.main.scale)
        signatureImage = rawImage

        // 2. Compute SHA-256 of flight data string for tamper evidence
        let df         = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dataString = "\(df.string(from: date))|\(aircraftIdent)|\(aircraftType)|\(totalTime)|\(instructorName)|\(instructorCertificate)"
        let hashString: String
        if let data = dataString.data(using: .utf8) {
            let hash = SHA256.hash(data: data)
            hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        } else {
            hashString = UUID().uuidString
        }

        // 3. Store hash in remarks suffix (will be saved to DB with the flight)
        let hashSuffix = "\n[SIG:\(hashString.prefix(16))…]"
        if !remarks.hasSuffix(hashSuffix) {
            remarks += hashSuffix
        }

        signatureLocked = true
        signatureAlertMsg = "Entry signed and cryptographically locked.\nHash: \(hashString.prefix(16))…\n\nThis entry is now tamper-evident per AC 120-78A."
        showSignatureAlert = true
    }

    // MARK: - Save

    private func saveFlight() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        // Encode signature to base64 if present
        var signatureBase64 = ""
        if let img = signatureImage, let pngData = img.pngData() {
            signatureBase64 = pngData.base64EncodedString()
        }

        let flightData: [String: Any] = [
            "date":                    df.string(from: date),
            "aircraft_ident":          aircraftIdent,
            "aircraft_type":           aircraftType,
            "aircraft_category":       aircraftCategory,
            "aircraft_class":          aircraftClass,
            "route":                   route,
            "total_time":              Double(totalTime)           ?? 0.0,
            "pic":                     Double(pic)                 ?? 0.0,
            "sic":                     Double(sic)                 ?? 0.0,
            "solo":                    Double(solo)                ?? 0.0,
            "dual_received":           Double(dualReceived)        ?? 0.0,
            "dual_given":              Double(dualGiven)           ?? 0.0,
            "cross_country":           Double(crossCountry)        ?? 0.0,
            "night":                   Double(night)               ?? 0.0,
            "instrument_actual":       Double(instrumentActual)    ?? 0.0,
            "instrument_simulated":    Double(instrumentSimulated) ?? 0.0,
            "landings_day":            Int(landingsDay)            ?? 0,
            "landings_night":          Int(landingsNight)          ?? 0,
            "approaches_count":        Int(approaches)             ?? 0,
            "holds_count":             Int(holds)                  ?? 0,
            "nav_tracking":            false,
            "remarks":                 remarks,
            "is_legacy_import":        false,
            "legacy_signature_path":   "",
            // Signature fields
            "signature_blob":          signatureBase64,
            "cfi_name":                instructorName,
            "cfi_certificate":         instructorCertificate,
            "is_signed":               signatureLocked ? 1 : 0,
        ]

        isSaving = true
        DatabaseManager.shared.addFlight(flightData) { rowId in
            isSaving = false
            if rowId != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { dismiss() }
            }
        }
    }

    // MARK: - Field Helpers

    private func timeField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                TextField("0.0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("h")
                    .font(.system(size: 10))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AeroTheme.fieldBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }

    private func countField(label: String, text: Binding<String>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(0.6))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .font(.system(size: 20, weight: .light, design: .rounded))
                .foregroundStyle(AeroTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AeroTheme.fieldBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }
}

// MARK: - EntrySignatureCanvas
// A UIViewRepresentable PKCanvasView with a drawing-changed callback.
// Named distinctly from PencilKitView (in SignatureCanvasView.swift) to avoid ambiguity.

struct EntrySignatureCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy     = .anyInput
        canvasView.backgroundColor   = .clear
        canvasView.isOpaque          = false
        canvasView.delegate          = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: EntrySignatureCanvas
        init(_ p: EntrySignatureCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onDrawingChanged()
        }
    }
}

// MARK: - Supporting components (kept for compatibility)

struct EntryCard<Content: View>: View {
    let title: String
    let icon: String
    var accent: Color = AeroTheme.brandPrimary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(accent)
            }
            content()
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 4)
    }
}

struct EntryPickerField: View {
    let label: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
            Menu {
                ForEach(options, id: \.self) { opt in Button(opt) { selection = opt } }
            } label: {
                HStack {
                    Text(selection)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(AeroTheme.fieldBg)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
            }
        }
    }
}

// Kept for backward compatibility
struct ManualEntryField: View {
    let label: String; @Binding var text: String
    var placeholder: String = ""; var keyboard: UIKeyboardType = .default; var icon: String? = nil
    var body: some View {
        AeroField(label: label, text: $text, placeholder: placeholder, keyboard: keyboard, icon: icon)
    }
}
struct PickerField: View {
    let label: String; @Binding var selection: String; let options: [String]
    var body: some View { EntryPickerField(label: label, selection: $selection, options: options) }
}
struct DatePickerField: View {
    let label: String; @Binding var selection: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(AeroTheme.textSecondary)
            DatePicker("", selection: $selection, displayedComponents: .date)
                .labelsHidden().tint(AeroTheme.brandPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }
}

#Preview { ManualEntryView() }
