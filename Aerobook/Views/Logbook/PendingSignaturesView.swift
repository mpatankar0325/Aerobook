import SwiftUI
import MessageUI

// MARK: - Pending Signatures View
//
// Shown in the Logbook tab so students can:
//   • See all pending / signed / expired requests
//   • Resend a request via email or iMessage
//   • Cancel a pending request
//   • Fetch / apply a returned signature link

struct PendingSignaturesView: View {

    @StateObject private var service   = RemoteSignatureService.shared
    @State private var showSendSheet   = false
    @State private var selectedToken: SignatureToken?
    @State private var sendChannel: SendChannel = .email

    // Mail / Message sheet state
    @State private var mailVC:    MFMailComposeViewController?
    @State private var messageVC: MFMessageComposeViewController?
    @State private var showMail    = false
    @State private var showMessage = false

    // Apply-return-link sheet
    @State private var showPasteSheet  = false
    @State private var pastedReturnURL = ""
    @State private var applyResult: String?
    @State private var showApplyAlert  = false

    enum SendChannel { case email, message }

    private var pending: [SignatureToken] {
        service.pendingTokens.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt }
    }
    private var signed: [SignatureToken] {
        service.pendingTokens.filter { $0.status == .signed }.sorted { $0.createdAt > $1.createdAt }
    }
    private var expired: [SignatureToken] {
        service.pendingTokens.filter { $0.status == .expired || $0.status == .cancelled }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        AeroPageHeader(
                            title: "Signatures",
                            subtitle: "Remote instructor signature requests"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // Apply return link button
                        applyReturnLinkCard
                            .padding(.horizontal)

                        // Apply result banner
                        if let result = applyResult {
                            resultBanner(result)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Pending section
                        if !pending.isEmpty {
                            tokenSection(title: "Awaiting Signature",
                                         icon: "clock.fill",
                                         color: Color.statusAmber,
                                         tokens: pending)
                        }

                        // Signed section
                        if !signed.isEmpty {
                            tokenSection(title: "Signed & Complete",
                                         icon: "checkmark.shield.fill",
                                         color: Color.statusGreen,
                                         tokens: signed)
                        }

                        // Expired / cancelled
                        if !expired.isEmpty {
                            tokenSection(title: "Expired / Cancelled",
                                         icon: "clock.badge.xmark.fill",
                                         color: AeroTheme.textTertiary,
                                         tokens: expired)
                        }

                        if service.pendingTokens.isEmpty {
                            emptyState
                        }

                        Color.clear.frame(height: 20)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            // Mail sheet
            .sheet(isPresented: $showMail) {
                if let vc = mailVC {
                    MailComposerSheet(viewController: vc)
                }
            }
            // Message sheet
            .sheet(isPresented: $showMessage) {
                if let vc = messageVC {
                    MessageComposerSheet(viewController: vc)
                }
            }
            // Paste return URL sheet
            .sheet(isPresented: $showPasteSheet) {
                pasteReturnURLSheet
            }
            .alert("Signature Applied", isPresented: $showApplyAlert) {
                Button("OK") { withAnimation { applyResult = nil } }
            } message: {
                Text(applyResult ?? "")
            }
        }
    }

    // MARK: - Apply Return Link Card

    private var applyReturnLinkCard: some View {
        Button(action: { showPasteSheet = true }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.statusGreen.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.statusGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply Returned Signature")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text("Got a return link from your instructor? Tap to apply it.")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(16)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(Color.statusGreen.opacity(0.25), lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Token Sections

    private func tokenSection(title: String, icon: String, color: Color,
                               tokens: [SignatureToken]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(color)
                Spacer()
                Text("\(tokens.count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .foregroundStyle(color)
                    .cornerRadius(20)
            }
            .padding(.horizontal)

            VStack(spacing: 10) {
                ForEach(tokens) { token in
                    TokenCard(token: token,
                              onResend: { resendToken(token) },
                              onCancel: { service.cancelToken(token) })
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "signature")
                .font(.system(size: 48))
                .foregroundStyle(AeroTheme.textTertiary.opacity(0.4))
            Text("No Signature Requests")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AeroTheme.textPrimary)
            Text("When you log dual instruction or endorsements, you can request your instructor's digital signature here.")
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Result Banner

    private func resultBanner(_ message: String) -> some View {
        let success = message.lowercased().contains("signed")
        return HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(success ? Color.statusGreen : Color.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(14)
        .background(success ? Color.statusGreenBg : Color.red.opacity(0.06))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke((success ? Color.statusGreen : Color.red).opacity(0.2), lineWidth: 1))
    }

    // MARK: - Paste Return URL Sheet

    private var pasteReturnURLSheet: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste Return Link")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("Your instructor should have shared an aerobook://sigreturn?... link after signing.")
                            .font(.system(size: 13))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Paste from clipboard button
                    if let clipboard = UIPasteboard.general.string,
                       clipboard.hasPrefix("aerobook://sigreturn") {
                        Button(action: { pastedReturnURL = clipboard }) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard.fill")
                                    .foregroundStyle(Color.statusGreen)
                                Text("Use Clipboard Link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AeroTheme.textPrimary)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.statusGreen)
                            }
                            .padding(14)
                            .background(Color.statusGreen.opacity(0.07))
                            .cornerRadius(AeroTheme.radiusMd)
                            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                .stroke(Color.statusGreen.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    ZStack(alignment: .topLeading) {
                        if pastedReturnURL.isEmpty {
                            Text("aerobook://sigreturn?...")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(AeroTheme.textTertiary)
                                .padding(.horizontal, 14).padding(.vertical, 14)
                        }
                        TextEditor(text: $pastedReturnURL)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 100)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                    }
                    .background(AeroTheme.fieldBg)
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))

                    Button(action: applyPastedURL) {
                        Text("Apply Signature")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(pastedReturnURL.hasPrefix("aerobook://sigreturn")
                                ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                            .foregroundStyle(.white)
                            .cornerRadius(AeroTheme.radiusMd)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!pastedReturnURL.hasPrefix("aerobook://sigreturn"))

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Apply Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPasteSheet = false }
                }
            }
        }
    }

    // MARK: - Logic

    private func resendToken(_ token: SignatureToken) {
        selectedToken = token
        if MFMailComposeViewController.canSendMail() {
            mailVC    = RemoteSignatureService.shared.emailViewController(for: token)
            showMail  = true
        } else if MFMessageComposeViewController.canSendText() {
            messageVC   = RemoteSignatureService.shared.messageViewController(for: token)
            showMessage = true
        }
    }

    private func applyPastedURL() {
        guard let url = URL(string: pastedReturnURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "aerobook" else { return }

        showPasteSheet = false
        RemoteSignatureService.shared.applyReturnedSignature(url) { success, message in
            withAnimation {
                applyResult = message
            }
            showApplyAlert = true
        }
    }
}

// MARK: - Token Card

struct TokenCard: View {

    let token: SignatureToken
    let onResend: () -> Void
    let onCancel: () -> Void

    @State private var expanded = false

    private var statusColor: Color {
        switch token.status {
        case .pending:   return Color.statusAmber
        case .signed:    return Color.statusGreen
        case .expired:   return Color.statusRed
        case .cancelled: return AeroTheme.textTertiary
        }
    }
    private var statusIcon: String {
        switch token.status {
        case .pending:   return "clock.fill"
        case .signed:    return "checkmark.shield.fill"
        case .expired:   return "clock.badge.xmark.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
    private var statusLabel: String {
        switch token.status {
        case .pending:   return "Pending"
        case .signed:    return "Signed"
        case .expired:   return "Expired"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusColor.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: statusIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(token.flightDate)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text(token.aircraftIdent)
                            .font(.system(size: 12))
                            .foregroundStyle(AeroTheme.textSecondary)
                        Spacer()
                        statusPill
                    }
                    HStack(spacing: 6) {
                        Text(String(format: "%.1f hrs", token.totalTime))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AeroTheme.textSecondary)
                        Text("·")
                            .foregroundStyle(AeroTheme.textTertiary)
                        Text(token.entryType == .endorsement ? "Endorsement" : "Dual")
                            .font(.system(size: 12))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }

                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AeroTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(16)

            // Expanded actions
            if expanded {
                Divider().padding(.horizontal, 16)

                VStack(spacing: 10) {
                    // Signed-by info
                    if token.status == .signed {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.statusGreen)
                            Text("Signed by \(token.instructorName) · \(token.instructorCert)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AeroTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // Expiry info
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textTertiary)
                        Text("Sent \(relativeDate(token.createdAt)) · Expires \(relativeDate(token.expiresAt))")
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, token.status == .signed ? 0 : 12)

                    // Action buttons for pending
                    if token.status == .pending {
                        HStack(spacing: 10) {
                            Button(action: onResend) {
                                Label("Resend", systemImage: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(AeroTheme.brandPrimary)
                                    .foregroundStyle(.white)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: onCancel) {
                                Label("Cancel", systemImage: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(AeroTheme.fieldBg)
                                    .foregroundStyle(Color.red.opacity(0.8))
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    } else {
                        Color.clear.frame(height: 14)
                    }
                }
            }
        }
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(token.status == .pending
                    ? statusColor.opacity(0.25) : AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(statusColor.opacity(0.12))
            .foregroundStyle(statusColor)
            .cornerRadius(20)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter        = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Mail / Message UIViewControllerRepresentable wrappers

struct MailComposerSheet: UIViewControllerRepresentable {
    let viewController: MFMailComposeViewController
    func makeUIViewController(context: Context) -> MFMailComposeViewController { viewController }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
}

struct MessageComposerSheet: UIViewControllerRepresentable {
    let viewController: MFMessageComposeViewController
    func makeUIViewController(context: Context) -> MFMessageComposeViewController { viewController }
    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
}

#Preview { PendingSignaturesView() }
