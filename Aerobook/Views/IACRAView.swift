import SwiftUI
import Combine
// MARK: - ViewModel

final class IACRAViewModel: ObservableObject {
    @Published var rows: [DatabaseManager.IACRACategoryRow] = []
    @Published var isLoading = true

    // Categories that have class breakdowns
    let classesByCategory: [String: [String]] = [
        "Airplane":         ["SEL", "MEL", "SES", "MES"],
        "Rotorcraft":       ["Helicopter", "Gyroplane"],
        "Lighter-than-air": ["Balloon", "Airship"],
        "FFS":              ["SE", "ME", "Helicopter"]
    ]

    func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let data = DatabaseManager.shared.fetchIACRAByCategory()
            DispatchQueue.main.async {
                self.rows = data
                self.isLoading = false
            }
        }
    }
}

// MARK: - Main View

struct IACRAView: View {
    @StateObject private var vm = IACRAViewModel()
    @State private var selectedCategory: String? = nil   // for drill-down highlight
    @State private var showInfo = true

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
                            HStack {
                                AeroPageHeader(
                                    title: "IACRA Totals",
                                    subtitle: "Record of Pilot Time · Section III"
                                )
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)

                            // Info banner
                            if showInfo { infoBanner }

                            // Main table
                            mainTable

                            // Class breakdowns
                            classBreakdownSection

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
            Text("Calculating from logbook…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AeroTheme.textSecondary)
        }
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.statusAmber)

            Text("Totals are calculated from your logbook entries. Ensure aircraft category (Airplane, Rotorcraft, etc.) and class (SEL, MEL, etc.) are correctly set on each flight.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 120/255, green: 80/255, blue: 10/255))
                .lineSpacing(4)

            Spacer()

            Button(action: { withAnimation { showInfo = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(16)
        .background(Color(red: 255/255, green: 251/255, blue: 235/255))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusAmber.opacity(0.25), lineWidth: 1))
        .padding(.horizontal)
        .transition(.opacity)
    }

    // MARK: - Main Table (horizontal scroll)

    private var mainTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells.fill")
                    .font(.system(size: 10))
                Text("Section III — Flight Time by Category")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header row
                    tableHeaderRow

                    // Data rows
                    ForEach(Array(vm.rows.enumerated()), id: \.element.category) { idx, row in
                        tableDataRow(row: row, isEven: idx % 2 == 0)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3)) {
                                    selectedCategory = selectedCategory == row.category
                                        ? nil : row.category
                                }
                            }
                    }
                }
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusLg)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
                .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
                .padding(.horizontal)
            }
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 0) {
            tableHeader("Category",    width: 130, leading: true)
            tableHeader("Total",       width: 72)
            tableHeader("Inst Recv",   width: 72)
            tableHeader("Solo",        width: 72)
            tableHeader("PIC",         width: 72)
            tableHeader("SIC",         width: 60)
            tableHeader("XC Total",    width: 72)
            tableHeader("XC Inst",     width: 72)
            tableHeader("XC Solo",     width: 72)
            tableHeader("XC PIC/SIC",  width: 80)
            tableHeader("Instrument",  width: 80)
            tableHeader("Night",       width: 72)
            tableHeader("Night Inst",  width: 80)
            tableHeader("Night Ldgs",  width: 80)
        }
        .background(AeroTheme.brandPrimary.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AeroTheme.cardStroke).frame(height: 1)
        }
    }

    private func tableHeader(_ text: String, width: CGFloat, leading: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)
            .multilineTextAlignment(leading ? .leading : .center)
            // FIX: use same frame sizing as dataCell — no extra horizontal padding
            // that was shifting headers out of alignment with data rows.
            .frame(width: width, alignment: leading ? .leading : .center)
            .padding(.leading, leading ? 16 : 0)
            .padding(.vertical, 12)
    }

    private func tableDataRow(row: DatabaseManager.IACRACategoryRow, isEven: Bool) -> some View {
        let isSelected = selectedCategory == row.category
        return HStack(spacing: 0) {
            // Category name — same frame+padding as tableHeader leading cell
            HStack(spacing: 6) {
                if isSelected {
                    Circle()
                        .fill(AeroTheme.brandPrimary)
                        .frame(width: 5, height: 5)
                }
                Text(row.category)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? AeroTheme.brandPrimary : AeroTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 130, alignment: .leading)
            .padding(.leading, 16)
            .padding(.vertical, 14)

            // Column widths must exactly match tableHeaderRow widths above
            dataCell(row.total,               width: 72)
            dataCell(row.instructionReceived,  width: 72)
            dataCell(row.solo,                 width: 72)
            dataCell(row.pic,                  width: 72)
            dataCell(row.sic,                  width: 60)
            dataCell(row.xcTotal,              width: 72)   // NEW: XC Total hours
            dataCell(row.xcInstruction,        width: 72)
            dataCell(row.xcSolo,               width: 72)
            dataCell(row.xcPicSic,             width: 80)
            dataCell(row.instrument,           width: 80)
            dataCell(row.nightTotal,           width: 72)   // NEW: Night total hours
            dataCell(row.nightInstruction,     width: 80)
            // Night landings is Int — same frame width as header
            Text(row.nightLdgs > 0 ? "\(row.nightLdgs)" : "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.nightLdgs > 0 ? AeroTheme.textPrimary : AeroTheme.textTertiary)
                .frame(width: 80, height: 48, alignment: .center)
        }
        .background(isSelected
            ? AeroTheme.brandPrimary.opacity(0.05)
            : (isEven ? AeroTheme.cardBg : AeroTheme.pageBg))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AeroTheme.cardStroke.opacity(0.5)).frame(height: 0.5)
        }
    }

    private func dataCell(_ value: Double, width: CGFloat) -> some View {
        // FIX: use .frame(width:, height:) with fixed height so every cell in a row
        // is exactly the same height — prevents row height fighting between cells.
        Text(value > 0 ? String(format: "%.1f", value) : "—")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(value > 0 ? AeroTheme.textPrimary : AeroTheme.textTertiary)
            .frame(width: width, height: 48, alignment: .center)
    }

    // MARK: - Class Breakdown Section

    private var classBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 10))
                Text("Class Totals")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)
            .padding(.horizontal)

            // Show only categories that have class breakdowns
            let breakdownCategories = ["Airplane", "Rotorcraft", "Lighter-than-air", "FFS"]
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 14
            ) {
                ForEach(breakdownCategories, id: \.self) { cat in
                    if let row = vm.rows.first(where: { $0.category == cat }),
                       let classes = vm.classesByCategory[cat] {
                        classBreakdownCard(category: cat, row: row, classes: classes)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func classBreakdownCard(
        category: String,
        row: DatabaseManager.IACRACategoryRow,
        classes: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: categoryIcon(category))
                    .font(.system(size: 12))
                    .foregroundStyle(AeroTheme.brandPrimary)
                Text(category)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
            }

            VStack(spacing: 8) {
                ForEach(classes, id: \.self) { cls in
                    let breakdown = row.classes[cls] ?? DatabaseManager.ClassBreakdown()
                    classRow(cls: cls, breakdown: breakdown)
                }
            }
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private func classRow(cls: String, breakdown: DatabaseManager.ClassBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cls)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(AeroTheme.brandPrimary)
                .textCase(.uppercase)

            // FIX: added Total column — was missing from ClassBreakdown entirely
            HStack(spacing: 0) {
                classStatCell(label: "Total",    value: breakdown.total)
                Rectangle().fill(AeroTheme.cardStroke).frame(width: 1, height: 28)
                classStatCell(label: "PIC",      value: breakdown.pic)
                Rectangle().fill(AeroTheme.cardStroke).frame(width: 1, height: 28)
                classStatCell(label: "SIC",      value: breakdown.sic)
                Rectangle().fill(AeroTheme.cardStroke).frame(width: 1, height: 28)
                classStatCell(label: "Inst Recv",value: breakdown.instructionReceived)
            }
            .background(AeroTheme.pageBg)
            .cornerRadius(AeroTheme.radiusSm)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
        }
    }

    private func classStatCell(label: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(value > 0 ? AeroTheme.textPrimary : AeroTheme.textTertiary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func categoryIcon(_ cat: String) -> String {
        switch cat {
        case "Airplane":          return "airplane"
        case "Rotorcraft":        return "tornado"
        case "Lighter-than-air":  return "cloud.fill"
        case "FFS":               return "desktopcomputer"
        default:                  return "airplane"
        }
    }
}

#Preview {
    IACRAView()
}
