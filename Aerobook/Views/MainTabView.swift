// MainTabView.swift — AeroBook
//
// MoreView restructured:
//   • Pilot Profile — top-level, first item (was buried inside Settings)
//   • IACRA & Certificates
//   • Signatures
//   • Tools (Import + Settings — Settings is now app behaviour only)

import SwiftUI
import Combine

struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var deepLinkManager = DeepLinkManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {

                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "house.fill") }
                    .tag(0)

                LogbookListView()
                    .tabItem { Label("Logbook", systemImage: "book.fill") }
                    .tag(1)

                ScannerView()
                    .tabItem { Label("Scanner", systemImage: "viewfinder.circle.fill") }
                    .tag(2)

                ExportView()
                    .tabItem { Label("Export", systemImage: "square.and.arrow.up.fill") }
                    .tag(3)

                MoreView()
                    .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                    .tag(4)
            }
            .tint(AeroTheme.brandPrimary)

            .fullScreenCover(item: $deepLinkManager.activeSignatureRequest) { request in
                SignatureCanvasView(flightID: request.flightID, pilotName: request.pilotName)
            }
            .fullScreenCover(item: $deepLinkManager.activeRemoteSignToken) { token in
                InstructorRemoteSignView(token: token)
            }
            .fullScreenCover(item: $deepLinkManager.activeEndorsementToken) { token in
                InstructorEndorsementSignView(token: token)
            }

            if let result = deepLinkManager.signatureReturnResult {
                signatureReturnBanner(result)
                    .padding(.horizontal, 16)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                    .animation(.spring(response: 0.4), value: deepLinkManager.signatureReturnResult != nil)
            }
        }
        .animation(.spring(response: 0.4), value: deepLinkManager.signatureReturnResult != nil)
    }

    // MARK: - Signature Return Banner

    private func signatureReturnBanner(_ result: (success: Bool, message: String)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: result.success ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(result.success ? Color.statusGreen : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.success ? "Signature Applied!" : "Signature Error")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(result.success ? Color.statusGreen : Color.red)
                Text(result.message)
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: { deepLinkManager.signatureReturnResult = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(14)
        .background(result.success ? Color.statusGreenBg : Color.red.opacity(0.07))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke((result.success ? Color.statusGreen : Color.red).opacity(0.2), lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
    }
}

// MARK: - SignatureToken / EndorsementToken Conformances

extension SignatureToken: Equatable {
    public static func == (lhs: SignatureToken, rhs: SignatureToken) -> Bool { lhs.id == rhs.id }
}

extension EndorsementToken: Equatable {
    public static func == (lhs: EndorsementToken, rhs: EndorsementToken) -> Bool { lhs.id == rhs.id }
}

// MARK: - More Tab

struct MoreView: View {

    // Live aircraft count for the profile badge
    @State private var aircraftCount: Int = 0

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        AeroPageHeader(title: "More", subtitle: "Profile, tools & settings")
                            .padding(.horizontal).padding(.top, 8)

                        // ── Pilot Profile — top level ──────────────────────
                        moreSection(title: "Pilot Profile") {
                            NavigationLink(destination: ProfileView()) {
                                moreRow(
                                    icon: "person.circle.fill",
                                    color: AeroTheme.brandPrimary,
                                    title: "My Profile",
                                    subtitle: "Identity, aircraft, instructors & home base",
                                    badge: 0
                                )
                            }
                        }

                        // ── IACRA & Certificates ───────────────────────────
                        moreSection(title: "IACRA & Certificates") {
                            NavigationLink(destination: IACRAView()) {
                                moreRow(
                                    icon: "tablecells.fill",
                                    color: AeroTheme.brandPrimary,
                                    title: "IACRA Totals",
                                    subtitle: "Section III flight time by category"
                                )
                            }
                            Divider().padding(.leading, 60)
                            NavigationLink(destination: IACRAAssistantView()) {
                                moreRow(
                                    icon: "trophy.fill",
                                    color: Color(red: 0.85, green: 0.65, blue: 0.10),
                                    title: "Certificate Progress",
                                    subtitle: "FAA 14 CFR Part 61 requirements tracker"
                                )
                            }
                        }

                        // ── Signatures ─────────────────────────────────────
                        moreSection(title: "Signatures") {
                            NavigationLink(destination: PendingSignaturesView()) {
                                moreRow(
                                    icon: "signature",
                                    color: AeroTheme.brandPrimary,
                                    title: "Remote Signatures",
                                    subtitle: "Request & track instructor e-signatures",
                                    badge: RemoteSignatureService.shared.pendingTokens
                                        .filter { $0.status == .pending }.count
                                )
                            }
                            Divider().padding(.leading, 60)
                            NavigationLink(destination: EndorsementsView()) {
                                moreRow(
                                    icon: "checkmark.seal.fill",
                                    color: .sky500,
                                    title: "CFI Endorsements",
                                    subtitle: "AC 61-65 templates & signed history"
                                )
                            }
                        }

                        // ── Tools ──────────────────────────────────────────
                        moreSection(title: "Tools") {
                            NavigationLink(destination: ImportView()) {
                                moreRow(
                                    icon: "arrow.down.doc.fill",
                                    color: .statusGreen,
                                    title: "Import",
                                    subtitle: "ForeFlight, LogTen Pro, CSV"
                                )
                            }
                            Divider().padding(.leading, 60)
                            NavigationLink(destination: SettingsView()) {
                                moreRow(
                                    icon: "gearshape.fill",
                                    color: AeroTheme.textSecondary,
                                    title: "Settings",
                                    subtitle: "Notifications, display & data management"
                                )
                            }
                        }

                        Color.clear.frame(height: 20)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("").navigationBarHidden(true)
            .onAppear {
                aircraftCount = DatabaseManager.shared.fetchAllAircraft().count
            }
        }
    }

    // MARK: - Section Builder

    private func moreSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                .foregroundStyle(AeroTheme.brandPrimary)
                .padding(.horizontal)

            VStack(spacing: 0) { content() }
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusLg)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
                .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
                .padding(.horizontal)
        }
    }

    // MARK: - Row Builder

    private func moreRow(icon: String, color: Color, title: String,
                         subtitle: String, badge: Int = 0) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
            }

            Spacer()

            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.statusAmber.opacity(0.15))
                    .foregroundStyle(Color.statusAmber)
                    .cornerRadius(20)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

// MARK: - Backward compatibility

extension Int64: @retroactive Identifiable {
    public var id: Int64 { self }
}

#Preview { MainTabView() }
