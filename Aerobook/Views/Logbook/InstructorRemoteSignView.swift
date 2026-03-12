import SwiftUI
import PencilKit
import CryptoKit
import MessageUI

// MARK: - Instructor Remote Sign View
//
// Shown on the instructor's device when they open:
//   aerobook://remotesign?token=...
//
// Flow:
//   1. Display flight/endorsement details for review
//   2. Instructor enters their name + certificate number
//   3. Draw signature with PencilKit
//   4. Tap "Sign & Return" → generates aerobook://sigreturn?... link
//   5. Share that return link back to the student via share sheet

struct InstructorRemoteSignView: View {

    let token: SignatureToken
    @Environment(\.dismiss) private var dismiss

    @State private var cfiName        = ""
    @State private var cfiCert        = ""
    @State private var cfiExpiry      = ""
    @State private var canvasView     = PKCanvasView()
    @State private var hasSignature   = false
    @State private var isSigning      = false
    @State private var signedReturnURL: String?
    @State private var showShareSheet  = false
    @State private var showAlert       = false
    @State private var alertMessage    = ""

    private var canSign: Bool {
        !cfiName.isEmpty && !cfiCert.isEmpty && hasSignature && !token.isExpired
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        headerBanner
                        entryDetailsCard
                        if token.isExpired {
                            expiredBanner
                        } else {
                            instructorInfoCard
                            signatureCard
                            if canSign { signButton }
                            legalFooter
                        }
                        Color.clear.frame(height: 30)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Sign Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = signedReturnURL {
                    ReturnSignatureShareSheet(returnURL: url, token: token) {
                        dismiss()
                    }
                }
            }
            .alert("Signature", isPresented: $showAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: - Header Banner

    private var headerBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AeroTheme.brandPrimary.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: "signature")
                    .font(.system(size: 22))
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Signature Requested")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("\(token.pilotName) · \(token.entryType == .endorsement ? "Endorsement" : "Dual Flight")")
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    // MARK: - Entry Details

    private var entryDetailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("Entry Details", icon: "doc.text.fill")

            VStack(spacing: 0) {
                detailRow("Pilot",        value: token.pilotName,     icon: "person.fill")
                Divider().padding(.leading, 42)
                detailRow("Date",         value: token.flightDate,    icon: "calendar")
                Divider().padding(.leading, 42)
                detailRow("Aircraft",     value: token.aircraftIdent, icon: "airplane")
                Divider().padding(.leading, 42)
                detailRow("Total Time",
                          value: String(format: "%.1f hrs", token.totalTime),
                          icon: "clock.fill")
                if token.dualReceived > 0 {
                    Divider().padding(.leading, 42)
                    detailRow("Dual Received",
                              value: String(format: "%.1f hrs", token.dualReceived),
                              icon: "person.2.fill",
                              valueColor: AeroTheme.brandPrimary)
                }
                if !token.remarks.isEmpty {
                    Divider().padding(.leading, 42)
                    detailRow("Remarks", value: token.remarks, icon: "text.bubble.fill")
                }
                detailRow("Entry Type",
                          value: token.entryType == .endorsement ? "Endorsement" : "Dual Flight",
                          icon: "checkmark.seal.fill",
                          valueColor: token.entryType == .endorsement ? Color.statusAmber : AeroTheme.brandPrimary)
            }
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    // MARK: - Instructor Info

    private var instructorInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("Your Information", icon: "person.badge.key.fill")

            AeroField(label: "Your Full Name",
                      text: $cfiName,
                      placeholder: "John Smith",
                      icon: "person.fill")

            HStack(spacing: 12) {
                AeroField(label: "CFI Certificate #",
                          text: $cfiCert,
                          placeholder: "1234567",
                          icon: "creditcard.fill")
                AeroField(label: "Cert Expiry",
                          text: $cfiExpiry,
                          placeholder: "MM/YYYY",
                          icon: "calendar.badge.clock")
            }

            // FAA regulatory reminder
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.statusAmber)
                Text("14 CFR 61.189 — You must be current and qualified to provide this instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.statusAmber.opacity(0.07))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.statusAmber.opacity(0.2), lineWidth: 1))
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    // MARK: - Signature Canvas

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                cardHeader("Your Signature", icon: "signature")
                Spacer()
                if hasSignature {
                    Button(action: clearCanvas) {
                        Label("Clear", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: AeroTheme.radiusMd).fill(Color.white)

                EntrySignatureCanvas(canvasView: $canvasView) {
                    hasSignature = !canvasView.drawing.strokes.isEmpty
                }
                .clipShape(RoundedRectangle(cornerRadius: AeroTheme.radiusMd))

                if !hasSignature {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.draw.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(AeroTheme.textTertiary.opacity(0.35))
                        Text("Sign with Apple Pencil or finger")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(
                        hasSignature ? AeroTheme.brandPrimary.opacity(0.5) : AeroTheme.fieldStroke,
                        style: StrokeStyle(lineWidth: 1.5, dash: hasSignature ? [] : [6, 4])
                    )
            )

            if hasSignature {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.statusGreen)
                    Text("Signature captured — tap Sign & Return to complete")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
            }
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    // MARK: - Sign Button

    private var signButton: some View {
        Button(action: performSign) {
            HStack(spacing: 10) {
                if isSigning {
                    ProgressView().tint(.white).scaleEffect(0.9)
                } else {
                    Image(systemName: "lock.shield.fill").font(.system(size: 15))
                }
                Text(isSigning ? "Signing…" : "Sign & Return to Student")
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(canSign ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
            .foregroundStyle(.white)
            .cornerRadius(AeroTheme.radiusMd)
            .shadow(color: canSign ? AeroTheme.brandPrimary.opacity(0.3) : .clear,
                    radius: 8, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canSign || isSigning)
    }

    // MARK: - Expired Banner

    private var expiredBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge.xmark.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.statusRed)
            VStack(alignment: .leading, spacing: 3) {
                Text("Request Expired")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.statusRed)
                Text("This signature request has expired. Please ask \(token.pilotName) to send a new request.")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color.statusRedBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusRed.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Legal Footer

    private var legalFooter: some View {
        Text("By signing, you certify that all logged instruction time is accurate and that the pilot performed the described operations. You confirm you hold a current and valid flight instructor certificate for the operations listed. Falsification of FAA records is a federal offense under 18 U.S.C. § 1001 and 14 CFR 61.15.")
            .font(.system(size: 10))
            .foregroundStyle(AeroTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(3)
            .padding(.horizontal, 4)
    }

    // MARK: - Logic

    private func clearCanvas() {
        canvasView.drawing = PKDrawing()
        hasSignature = false
    }

    private func performSign() {
        guard canSign else { return }
        isSigning = true

        // Capture signature PNG
        let bounds  = CGRect(x: 0, y: 0,
                             width: canvasView.bounds.width.isZero ? 600 : canvasView.bounds.width,
                             height: 160)
        let img     = canvasView.drawing.image(from: bounds, scale: UIScreen.main.scale)
        guard let pngData = img.pngData() else {
            isSigning = false; return
        }
        let sigB64  = pngData.base64EncodedString()

        // Generate return URL
        let returnURL = RemoteSignatureService.shared.completeSignature(
            token:           token,
            instructorName:  cfiName,
            instructorCert:  cfiCert,
            signatureBase64: sigB64
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isSigning        = false
            signedReturnURL  = returnURL
            showShareSheet   = true
        }
    }

    // MARK: - Helpers

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1.2)
        }
        .foregroundStyle(AeroTheme.brandPrimary)
    }

    private func detailRow(_ label: String, value: String, icon: String,
                            valueColor: Color = AeroTheme.textPrimary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(AeroTheme.brandPrimary.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Return Signature Share Sheet
//
// After instructor signs, they share the aerobook://sigreturn?... URL
// back to the student via AirDrop, iMessage, email, or copy-paste.

struct ReturnSignatureShareSheet: View {

    let returnURL: String
    let token: SignatureToken
    let onDone: () -> Void

    @State private var showSystemShare = false
    @State private var showCopied      = false

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // Success header
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.statusGreen.opacity(0.12))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(Color.statusGreen)
                            }
                            Text("Signed!")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(AeroTheme.textPrimary)
                            Text("Now send the signed entry back to \(token.pilotName)")
                                .font(.system(size: 14))
                                .foregroundStyle(AeroTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)

                        // Share options
                        VStack(spacing: 12) {
                            shareOptionButton(
                                icon: "square.and.arrow.up.fill",
                                label: "Share via AirDrop / iMessage / Email",
                                color: AeroTheme.brandPrimary
                            ) { showSystemShare = true }

                            shareOptionButton(
                                icon: "doc.on.doc.fill",
                                label: showCopied ? "Copied!" : "Copy Return Link",
                                color: showCopied ? Color.statusGreen : .sky500
                            ) {
                                UIPasteboard.general.string = returnURL
                                withAnimation { showCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { showCopied = false }
                                }
                            }
                        }
                        .padding(.horizontal)

                        // Link preview
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RETURN LINK")
                                .font(.system(size: 10, weight: .bold)).tracking(1.2)
                                .foregroundStyle(AeroTheme.brandPrimary)
                            Text(returnURL)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AeroTheme.textTertiary)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(AeroTheme.fieldBg)
                        .cornerRadius(AeroTheme.radiusMd)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                        .padding(.horizontal)

                        Text("When \(token.pilotName) opens this link in AeroBook, their logbook entry will be automatically signed and cryptographically locked.")
                            .font(.system(size: 12))
                            .foregroundStyle(AeroTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                }
            }
            .navigationTitle("Send Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onDone)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .sheet(isPresented: $showSystemShare) {
                SystemShareSheet(items: [returnURL])
            }
        }
    }

    private func shareOptionButton(icon: String, label: String, color: Color,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
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
}

// MARK: - System Share Sheet wrapper

struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
