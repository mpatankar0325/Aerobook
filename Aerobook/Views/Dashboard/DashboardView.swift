import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        topBar
                        heroCard
                        categoryPicker
                        currencySection
                        iacraSection
                        activitySection
                        Color.clear.frame(height: 8)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onAppear { viewModel.refresh() }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AeroBook")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(AeroTheme.brandPrimary)
                    .textCase(.uppercase)

                Text("Dashboard")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
            }

            Spacer()

            // Role badge
            Text(viewModel.userRole)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AeroTheme.brandPrimary.opacity(0.1))
                .foregroundStyle(AeroTheme.brandPrimary)
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(AeroTheme.brandPrimary.opacity(0.2), lineWidth: 1))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Hero Card (total hours + quick stats)

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            // Background gradient
            LinearGradient(
                colors: [AeroTheme.brandDark, AeroTheme.brandPrimary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .cornerRadius(AeroTheme.radiusXl)

            // Decorative circle
            Circle()
                .fill(.white.opacity(0.05))
                .frame(width: 200, height: 200)
                .offset(x: 60, y: -60)

            Circle()
                .fill(.white.opacity(0.04))
                .frame(width: 120, height: 120)
                .offset(x: 30, y: 60)

            VStack(alignment: .leading, spacing: 20) {
                // Hours
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOTAL FLIGHT TIME")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.6))

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", viewModel.totalHours))
                            .font(.system(size: 52, weight: .light, design: .rounded))
                            .foregroundStyle(.white)
                            .tracking(-1)
                        Text("hrs")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 6)
                    }
                }

                // Quick stats row
                HStack(spacing: 0) {
                    heroStat(label: "30 Days", value: String(format: "%.1f", viewModel.last30DaysHours))
                    heroDivider
                    heroStat(label: "Last Flight", value: viewModel.lastFlightDate)
                    heroDivider
                    heroStat(label: "Flights", value: "\(viewModel.recentFlightsCount)")
                }
                .padding(16)
                .background(.white.opacity(0.08))
                .cornerRadius(16)
            }
            .padding(28)
        }
        .padding(.horizontal)
        .shadow(color: AeroTheme.brandPrimary.opacity(0.35), radius: 20, x: 0, y: 8)
    }

    private func heroStat(label: String, value: String) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private var heroDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 32)
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Currency Regulation")
                .aeroSectionHeader()
                .padding(.horizontal)

            HStack(spacing: 8) {
                ForEach(CurrencyCategory.allCases, id: \.self) { cat in
                    Button(action: {
                        viewModel.selectedCategory = cat
                        viewModel.refresh()
                    }) {
                        VStack(spacing: 2) {
                            Text("Part")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.5)
                            Text(cat.rawValue)
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(viewModel.selectedCategory == cat
                            ? AeroTheme.brandPrimary
                            : AeroTheme.cardBg)
                        .foregroundStyle(viewModel.selectedCategory == cat
                            ? .white
                            : AeroTheme.textSecondary)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(viewModel.selectedCategory == cat
                                    ? AeroTheme.brandPrimary
                                    : AeroTheme.cardStroke, lineWidth: 1)
                        )
                        .shadow(color: viewModel.selectedCategory == cat
                            ? AeroTheme.brandPrimary.opacity(0.25) : .clear,
                            radius: 6, y: 3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .animation(.spring(response: 0.3), value: viewModel.selectedCategory)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Currency Cards

    private var currencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Currency Status")
                .aeroSectionHeader()
                .padding(.horizontal)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(viewModel.currencyStatuses, id: \.label) { status in
                    CurrencyCard(status: status)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - IACRA Section

    private var iacraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("")
                .aeroSectionHeader()
                .padding(.horizontal)

            VStack(spacing: 0) {
                // Header strip
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AeroTheme.brandPrimary)
                        Text("Flight Summary")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)
                    }
                    Spacer()
                    Text("FAA 14 CFR")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AeroTheme.brandPrimary.opacity(0.1))
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .cornerRadius(6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 20)

                // Stats grid
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 0
                ) {
                    IACRAStatCell(
                        icon: "figure.seated.seatbelt",
                        label: "PIC Time",
                        value: viewModel.picHours,
                        isLast: false, isRight: false
                    )
                    IACRAStatCell(
                        icon: "map.fill",
                        label: "Cross Country",
                        value: viewModel.xcHours,
                        isLast: false, isRight: true
                    )
                    IACRAStatCell(
                        icon: "person.fill",
                        label: "Solo",
                        value: viewModel.soloHours,
                        isLast: true, isRight: false
                    )
                    IACRAStatCell(
                        icon: "cloud.fill",
                        label: "Instrument",
                        value: viewModel.instrumentTotalHours,
                        isLast: true, isRight: true
                    )
                }
                .padding(.vertical, 4)
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
            .padding(.horizontal)
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Activity")
                .aeroSectionHeader()
                .padding(.horizontal)

            VStack(spacing: 0) {
                activityRow(
                    icon: "airplane.departure",
                    iconColor: AeroTheme.brandPrimary,
                    label: "Last Flight",
                    value: viewModel.lastFlightDate
                )

                Divider().padding(.leading, 56)

                activityRow(
                    icon: "calendar",
                    iconColor: .sky500,
                    label: "30-Day Hours",
                    value: String(format: "%.1f hrs", viewModel.last30DaysHours)
                )

                Divider().padding(.leading, 56)

                activityRow(
                    icon: "tray.full.fill",
                    iconColor: .statusGreen,
                    label: "Total Flights Logged",
                    value: "\(viewModel.recentFlightsCount)"
                )
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
            .padding(.horizontal)
        }
    }

    private func activityRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
            }
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AeroTheme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AeroTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - CurrencyCard

struct CurrencyCard: View {
    let status: CurrencyStatus

    private var statusColor: Color {
        switch status.status {
        case .current: return .statusGreen
        case .warning: return .statusAmber
        case .expired: return .statusRed
        }
    }
    private var statusBg: Color {
        switch status.status {
        case .current: return .statusGreenBg
        case .warning: return .statusAmberBg
        case .expired: return .statusRedBg
        }
    }
    private var statusIcon: String {
        switch status.status {
        case .current: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }
    private var statusLabel: String {
        switch status.status {
        case .current: return "CURRENT"
        case .warning: return "WARNING"
        case .expired: return "EXPIRED"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(status.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: statusIcon)
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                Text(statusLabel)
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12))
                    .foregroundStyle(statusColor)
                    .cornerRadius(5)

                Text(status.details)
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(statusColor.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }
}

// MARK: - IACRA Stat Cell

struct IACRAStatCell: View {
    let icon: String
    let label: String
    let value: Double
    let isLast: Bool
    let isRight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(AeroTheme.textTertiary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 28, weight: .light, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("hrs")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AeroTheme.textTertiary)
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .overlay(alignment: .trailing) {
            if !isRight {
                Rectangle()
                    .fill(AeroTheme.cardStroke)
                    .frame(width: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(AeroTheme.cardStroke)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - StatusType RawRepresentable (kept for compatibility)

extension CurrencyStatus.StatusType: RawRepresentable {
    typealias RawValue = String
    init?(rawValue: String) {
        switch rawValue {
        case "current": self = .current
        case "warning": self = .warning
        case "expired": self = .expired
        default: return nil
        }
    }
    var rawValue: String {
        switch self {
        case .current: return "current"
        case .warning: return "warning"
        case .expired: return "expired"
        }
    }
}

// Keeping for any remaining references in codebase
struct StatItem: View {
    let icon: String
    let label: String
    let value: Double
    var body: some View {
        IACRAStatCell(icon: icon, label: label, value: value, isLast: true, isRight: true)
    }
}

struct DashboardRow: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = AeroTheme.brandPrimary
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 32)
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.bold()).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
    }
}

#Preview {
    DashboardView()
}
