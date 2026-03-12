import SwiftUI
import Combine
// MARK: - Models

struct CertificateRequirement: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let checks: [RequirementCheck]

    var completedCount: Int { checks.filter(\.isMet).count }
    var progressPercent: Double { Double(completedCount) / Double(checks.count) }
    var isComplete: Bool { completedCount == checks.count }
}

struct RequirementCheck: Identifiable {
    let id = UUID()
    let label: String
    let required: Double
    let actual: Double
    let unit: String
    var isMet: Bool { actual >= required }
    var progress: Double { min(1.0, actual / required) }
}

// MARK: - ViewModel

final class IACRAAssistantViewModel: ObservableObject {
    @Published var requirements: [CertificateRequirement] = []
    @Published var isLoading = true

    func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let t = DatabaseManager.shared.fetchIACRATotals()
            let reqs = Self.buildRequirements(from: t)
            DispatchQueue.main.async {
                self.requirements = reqs
                self.isLoading = false
            }
        }
    }

    /// Mirrors IACRAAssistant.tsx requirements array exactly.
    /// Sources: FAA 14 CFR Part 61 §61.109, §61.65, §61.129
    private static func buildRequirements(
        from t: DatabaseManager.IACRATotals
    ) -> [CertificateRequirement] {
        [
            CertificateRequirement(
                name: "Private Pilot (Airplane SEL)",
                icon: "trophy.fill",
                checks: [
                    RequirementCheck(label: "Total Flight Time",   required: 40,  actual: t.total,        unit: "hrs"),
                    RequirementCheck(label: "Instruction Received",required: 20,  actual: t.dualReceived, unit: "hrs"),
                    RequirementCheck(label: "Solo Flight Time",    required: 10,  actual: t.solo,         unit: "hrs"),
                    RequirementCheck(label: "Solo Cross Country",  required: 5,   actual: t.xcSolo,       unit: "hrs"),
                    RequirementCheck(label: "Night Training",      required: 3,   actual: t.nightInst,    unit: "hrs"),
                    RequirementCheck(label: "Instrument Training", required: 3,   actual: t.instrumentInst, unit: "hrs"),
                ]
            ),
            CertificateRequirement(
                name: "Instrument Rating",
                icon: "target",
                checks: [
                    RequirementCheck(label: "Cross Country PIC",  required: 50,  actual: t.xcPic,        unit: "hrs"),
                    RequirementCheck(label: "Instrument Time",    required: 40,  actual: t.instrument,   unit: "hrs"),
                    RequirementCheck(label: "Instruction Received",required: 15, actual: t.dualReceived, unit: "hrs"),
                ]
            ),
            CertificateRequirement(
                name: "Commercial Pilot (Airplane SEL)",
                icon: "award.fill",
                checks: [
                    RequirementCheck(label: "Total Flight Time",  required: 250, actual: t.total,        unit: "hrs"),
                    RequirementCheck(label: "PIC Time",           required: 100, actual: t.pic,          unit: "hrs"),
                    RequirementCheck(label: "Cross Country PIC",  required: 50,  actual: t.xcPic,        unit: "hrs"),
                    RequirementCheck(label: "Night PIC / Solo",   required: 10,  actual: t.night,        unit: "hrs"),
                ]
            )
        ]
    }
}

// MARK: - Main View

struct IACRAAssistantView: View {
    @StateObject private var vm = IACRAAssistantViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                if vm.isLoading {
                    loadingState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {

                            // Header
                            AeroPageHeader(
                                title: "IACRA Assistant",
                                subtitle: "Track your FAA certificate progress"
                            )
                            .padding(.horizontal)
                            .padding(.top, 8)

                            // Overall summary strip
                            overallSummary

                            // Certificate cards
                            ForEach(vm.requirements) { req in
                                CertificateCard(requirement: req)
                                    .padding(.horizontal)
                            }

                            // Disclaimer
                            disclaimerBanner

                            Color.clear.frame(height: 20)
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onAppear { vm.load() }
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(AeroTheme.brandPrimary)
                .scaleEffect(1.3)
            Text("Calculating requirements from logbook…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AeroTheme.textSecondary)
        }
    }

    // MARK: - Overall Summary

    private var overallSummary: some View {
        HStack(spacing: 0) {
            ForEach(Array(vm.requirements.enumerated()), id: \.element.id) { idx, req in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(AeroTheme.cardStroke, lineWidth: 3)
                            .frame(width: 44, height: 44)
                        Circle()
                            .trim(from: 0, to: req.progressPercent)
                            .stroke(req.isComplete ? Color.statusGreen : AeroTheme.brandPrimary,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 44, height: 44)
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.6), value: req.progressPercent)

                        Text("\(req.completedCount)/\(req.checks.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(req.isComplete ? Color.statusGreen : AeroTheme.brandPrimary)
                    }

                    Text(req.name.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? req.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: 80)
                }
                .frame(maxWidth: .infinity)

                if idx < vm.requirements.count - 1 {
                    Rectangle().fill(AeroTheme.cardStroke).frame(width: 1, height: 44)
                }
            }
        }
        .padding(.vertical, 20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
        .padding(.horizontal)
    }

    // MARK: - Disclaimer

    private var disclaimerBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(AeroTheme.textTertiary)

            Text("Requirements are based on 14 CFR Part 61. This assistant provides a general overview — always consult your CFI and the FAR/AIM for official certification requirements.")
                .font(.system(size: 12))
                .foregroundStyle(AeroTheme.textSecondary)
                .lineSpacing(4)
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .padding(.horizontal)
    }
}

// MARK: - CertificateCard

struct CertificateCard: View {
    let requirement: CertificateRequirement
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Card header
            Button(action: { withAnimation(.spring(response: 0.35)) { isExpanded.toggle() } }) {
                HStack(spacing: 14) {
                    // Icon badge
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(requirement.isComplete
                                ? Color.statusGreen.opacity(0.12)
                                : AeroTheme.brandPrimary.opacity(0.1))
                            .frame(width: 44, height: 44)
                        Image(systemName: requirement.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(requirement.isComplete
                                ? Color.statusGreen
                                : AeroTheme.brandPrimary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(requirement.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)

                        // Progress bar
                        HStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(AeroTheme.neutral200)
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(requirement.isComplete
                                            ? Color.statusGreen
                                            : AeroTheme.brandPrimary)
                                        .frame(width: geo.size.width * requirement.progressPercent,
                                               height: 4)
                                        .animation(.spring(response: 0.6), value: requirement.progressPercent)
                                }
                            }
                            .frame(height: 4)

                            Text("\(requirement.completedCount)/\(requirement.checks.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(requirement.isComplete
                                    ? Color.statusGreen
                                    : AeroTheme.brandPrimary)
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                .padding(20)
            }
            .buttonStyle(PlainButtonStyle())

            // Checks grid
            if isExpanded {
                Divider().padding(.horizontal, 20)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(requirement.checks) { check in
                        RequirementCheckCell(check: check)
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(requirement.isComplete
                    ? Color.statusGreen.opacity(0.3)
                    : AeroTheme.cardStroke, lineWidth: 1)
        )
        .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
    }
}

// MARK: - RequirementCheckCell

struct RequirementCheckCell: View {
    let check: RequirementCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(check.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: check.isMet ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(check.isMet ? Color.statusGreen : AeroTheme.neutral300)
            }

            // Actual / Required
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", check.actual))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(check.isMet ? Color.statusGreen : AeroTheme.textPrimary)
                Text("/ \(Int(check.required)) \(check.unit)")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textTertiary)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AeroTheme.neutral200)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(check.isMet ? Color.statusGreen : AeroTheme.brandPrimary)
                        .frame(width: geo.size.width * check.progress, height: 4)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8),
                                   value: check.progress)
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(check.isMet ? Color.statusGreenBg : AeroTheme.pageBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(
            RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(check.isMet
                    ? Color.statusGreen.opacity(0.2)
                    : AeroTheme.cardStroke, lineWidth: 1)
        )
    }
}

#Preview {
    IACRAAssistantView()
}
