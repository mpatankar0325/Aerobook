// SettingsView.swift — AeroBook
//
// App behaviour only: notifications, display preferences, data management.
// Pilot Profile has moved to its own top-level destination in MoreView.

import SwiftUI

struct SettingsView: View {
    // Notification prefs
    @AppStorage("notificationsEnabled")   private var notificationsEnabled = true
    @AppStorage("currencyAlertDays")      private var currencyAlertDays: Double = 30
    // Display prefs
    @AppStorage("hoursFormat")            private var hoursFormat = "Decimal"
    @AppStorage("dateFormat")             private var dateFormat  = "MM/dd/yyyy"
    // State
    @State private var showResetConfirm   = false
    @State private var showResetSuccess   = false
    @State private var isResetting        = false
    @State private var dbSizeText         = "Calculating…"

    let hoursFormats = ["Decimal", "HH:MM"]
    let dateFormats  = ["MM/dd/yyyy", "dd/MM/yyyy", "yyyy-MM-dd"]

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        AeroPageHeader(
                            title: "Settings",
                            subtitle: "App preferences & data management"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // ── Notifications ──────────────────────────────────
                        settingsSection(title: "Notifications") {
                            HStack(spacing: 14) {
                                iconBadge("bell.fill", color: .statusAmber)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Currency Alerts")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AeroTheme.textPrimary)
                                    Text("Notify before certificates expire")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AeroTheme.textSecondary)
                                }
                                Spacer()
                                Toggle("", isOn: $notificationsEnabled)
                                    .tint(AeroTheme.brandPrimary)
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)

                            if notificationsEnabled {
                                Divider().padding(.leading, 60)

                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        iconBadge("clock.badge.exclamationmark.fill",
                                                  color: AeroTheme.brandPrimary)
                                        Text("Alert")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AeroTheme.textPrimary)
                                        Spacer()
                                        Text("\(Int(currencyAlertDays)) days before")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(AeroTheme.brandPrimary)
                                    }
                                    .padding(.horizontal, 16)

                                    Slider(value: $currencyAlertDays, in: 7...90, step: 1)
                                        .tint(AeroTheme.brandPrimary)
                                        .padding(.horizontal, 16)

                                    HStack {
                                        Text("7 days")
                                        Spacer()
                                        Text("90 days")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundStyle(AeroTheme.textTertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 4)
                                }
                                .padding(.top, 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .animation(.spring(response: 0.3), value: notificationsEnabled)
                            }
                        }

                        // ── Display Preferences ────────────────────────────
                        settingsSection(title: "Display Preferences") {
                            VStack(spacing: 0) {
                                HStack(spacing: 14) {
                                    iconBadge("timer", color: .sky500)
                                    Text("Hours Format")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AeroTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)

                                HStack(spacing: 8) {
                                    ForEach(hoursFormats, id: \.self) { fmt in
                                        Button(action: { hoursFormat = fmt }) {
                                            Text(fmt)
                                                .font(.system(size: 12, weight: .semibold))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(hoursFormat == fmt
                                                    ? AeroTheme.brandPrimary : AeroTheme.pageBg)
                                                .foregroundStyle(hoursFormat == fmt
                                                    ? .white : AeroTheme.textSecondary)
                                                .cornerRadius(8)
                                                .overlay(RoundedRectangle(cornerRadius: 8)
                                                    .stroke(hoursFormat == fmt
                                                        ? AeroTheme.brandPrimary
                                                        : AeroTheme.cardStroke, lineWidth: 1))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .animation(.spring(response: 0.25), value: hoursFormat)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.bottom, 14)
                            }

                            Divider().padding(.leading, 60)

                            VStack(spacing: 0) {
                                HStack(spacing: 14) {
                                    iconBadge("calendar", color: AeroTheme.brandPrimary)
                                    Text("Date Format")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AeroTheme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)

                                VStack(spacing: 6) {
                                    ForEach(dateFormats, id: \.self) { fmt in
                                        Button(action: { dateFormat = fmt }) {
                                            HStack {
                                                Text(fmt)
                                                    .font(.system(size: 13, weight: .medium,
                                                                  design: .monospaced))
                                                    .foregroundStyle(dateFormat == fmt
                                                        ? AeroTheme.brandPrimary
                                                        : AeroTheme.textPrimary)
                                                Spacer()
                                                if dateFormat == fmt {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(AeroTheme.brandPrimary)
                                                }
                                            }
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .background(dateFormat == fmt
                                                ? AeroTheme.brandPrimary.opacity(0.06)
                                                : Color.clear)
                                            .cornerRadius(8)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.horizontal, 8).padding(.bottom, 10)
                            }
                        }

                        // ── Data Management ────────────────────────────────
                        settingsSection(title: "Data Management") {
                            // DB size
                            HStack(spacing: 14) {
                                iconBadge("internaldrive.fill", color: AeroTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Database Size")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AeroTheme.textPrimary)
                                    Text("Local SQLite — no cloud sync")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AeroTheme.textSecondary)
                                }
                                Spacer()
                                Text(dbSizeText)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AeroTheme.brandPrimary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)

                            Divider().padding(.leading, 60)

                            // Reset button
                            Button(action: { showResetConfirm = true }) {
                                HStack(spacing: 14) {
                                    iconBadge("trash.fill", color: .statusRed)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Reset All Data")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.statusRed)
                                        Text("Permanently deletes all flights and profile data")
                                            .font(.system(size: 11))
                                            .foregroundStyle(AeroTheme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AeroTheme.textTertiary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        // ── About ──────────────────────────────────────────
                        settingsSection(title: "About") {
                            settingsInfoRow(icon: "info.circle.fill",    color: AeroTheme.brandPrimary, title: "Version",    value: "1.0.0")
                            Divider().padding(.leading, 60)
                            settingsInfoRow(icon: "hammer.fill",         color: .sky500,                title: "Build",      value: "2026.1")
                            Divider().padding(.leading, 60)
                            settingsInfoRow(icon: "airplane.circle.fill",color: AeroTheme.brandPrimary, title: "Made for",   value: "Pilots by Pilots")
                        }

                        Color.clear.frame(height: 20)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("").navigationBarHidden(true)
            .onAppear { calculateDBSize() }
            .confirmationDialog("Reset All Data?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    isResetting = true
                    DatabaseManager.shared.resetAllData { success in
                        isResetting = false
                        showResetSuccess = success
                        calculateDBSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all flights, endorsements, aircraft, and profile data. This cannot be undone.")
            }
            .alert("Data Cleared", isPresented: $showResetSuccess) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("All data has been permanently deleted.")
            }
            .overlay {
                if isResetting {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.4).tint(.white)
                            Text("Deleting all data…")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func settingsInfoRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, color: color)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(AeroTheme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func iconBadge(_ icon: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12)).frame(width: 36, height: 36)
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
        }
    }

    private func calculateDBSize() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dbURL = appSupport.appendingPathComponent("aerobook.sqlite")
            let size  = (try? fm.attributesOfItem(atPath: dbURL.path))?[.size] as? Int64 ?? 0
            let formatted: String
            if size < 1024            { formatted = "\(size) B" }
            else if size < 1_048_576  { formatted = String(format: "%.1f KB", Double(size) / 1024) }
            else                      { formatted = String(format: "%.2f MB", Double(size) / 1_048_576) }
            DispatchQueue.main.async { dbSizeText = formatted }
        }
    }
}

#Preview { SettingsView() }
