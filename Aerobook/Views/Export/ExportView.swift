import SwiftUI
import PDFKit

struct ExportView: View {
    @State private var startDate = Calendar.current.date(
        byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var isGenerating = false
    @State private var pdfURL: URL?
    @State private var selectedFormat: ExportFormat = .pdf

    enum ExportFormat: String, CaseIterable {
        case pdf  = "PDF Report"
        case csv  = "CSV"
    }

    // Computed flight count for selected range
    @State private var flightCount: Int = 0

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        // Header
                        AeroPageHeader(
                            title: "Export",
                            subtitle: "Generate a professional logbook report"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)

                        // Format selector
                        formatSelector
                            .padding(.horizontal)

                        // Date range card
                        dateRangeCard
                            .padding(.horizontal)

                        // Preview summary card
                        previewCard
                            .padding(.horizontal)

                        // Export options
                        exportOptions
                            .padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .onChange(of: startDate) { updateCount() }
            .onChange(of: endDate)   { updateCount() }
            .onAppear { updateCount() }
        }
    }

    // MARK: - Format Selector

    private var formatSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 10))
                Text("Export Format")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)

            HStack(spacing: 10) {
                ForEach(ExportFormat.allCases, id: \.self) { fmt in
                    Button(action: { selectedFormat = fmt }) {
                        HStack(spacing: 8) {
                            Image(systemName: fmt == .pdf ? "doc.richtext.fill" : "tablecells.fill")
                                .font(.system(size: 14))
                            Text(fmt.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(selectedFormat == fmt
                            ? AeroTheme.brandPrimary
                            : AeroTheme.cardBg)
                        .foregroundStyle(selectedFormat == fmt
                            ? .white
                            : AeroTheme.textSecondary)
                        .cornerRadius(AeroTheme.radiusMd)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(selectedFormat == fmt
                                ? AeroTheme.brandPrimary
                                : AeroTheme.cardStroke, lineWidth: 1))
                        .shadow(color: selectedFormat == fmt
                            ? AeroTheme.brandPrimary.opacity(0.25) : .clear,
                            radius: 6, y: 3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .animation(.spring(response: 0.25), value: selectedFormat)
                }
            }
        }
    }

    // MARK: - Date Range Card

    private var dateRangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10))
                Text("Date Range")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)

            VStack(spacing: 0) {
                dateRow(label: "From", icon: "calendar", date: $startDate)
                Divider().padding(.horizontal, 16)
                dateRow(label: "To", icon: "calendar.badge.checkmark", date: $endDate)
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)

            // Quick range buttons
            HStack(spacing: 8) {
                ForEach(["30d", "90d", "6m", "1y", "All"], id: \.self) { range in
                    Button(action: { applyRange(range) }) {
                        Text(range)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AeroTheme.cardBg)
                            .foregroundStyle(AeroTheme.brandPrimary)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(AeroTheme.brandPrimary.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private func dateRow(label: String, icon: String, date: Binding<Date>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AeroTheme.brandPrimary.opacity(0.1))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AeroTheme.textSecondary)
                .frame(width: 36, alignment: .leading)
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .tint(AeroTheme.brandPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Preview Card

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
                Text("Export Preview")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)

            HStack(spacing: 0) {
                previewStat(value: "\(flightCount)", label: "Flights")
                previewDivider
                previewStat(value: selectedFormat == .pdf ? "A4" : "UTF-8", label: "Format")
                previewDivider
                previewStat(
                    value: flightCount > 0 ? "\(Int(ceil(Double(flightCount) / 15.0)))" : "0",
                    label: selectedFormat == .pdf ? "Pages" : "Rows"
                )
            }
            .padding(.vertical, 16)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)

            // PDF preview chip
            if selectedFormat == .pdf {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AeroTheme.brandPrimary)
                    Text("FAA-compliant layout · Landscape A4 · 15 entries per page · Signature line")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
                .padding(12)
                .background(AeroTheme.brandPrimary.opacity(0.06))
                .cornerRadius(AeroTheme.radiusSm)
            }
        }
    }

    private func previewStat(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .light, design: .rounded))
                .foregroundStyle(AeroTheme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var previewDivider: some View {
        Rectangle()
            .fill(AeroTheme.cardStroke)
            .frame(width: 1, height: 32)
    }

    // MARK: - Export Options

    private var exportOptions: some View {
        VStack(spacing: 12) {
            // Generate button
            if isGenerating {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(AeroTheme.brandPrimary)
                        .scaleEffect(1.2)
                    Text("Rendering report pages…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusLg)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
            } else {
                Button(action: generateReport) {
                    HStack(spacing: 10) {
                        Image(systemName: "printer.fill")
                        Text("Generate \(selectedFormat.rawValue)")
                    }
                    .aeroPrimaryButton()
                }
                .disabled(flightCount == 0)
                .opacity(flightCount == 0 ? 0.5 : 1)
            }

            // Share button — appears after generation
            if let url = pdfURL {
                ShareLink(item: url) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share Logbook \(selectedFormat.rawValue)")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AeroTheme.brandPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AeroTheme.brandPrimary.opacity(0.08))
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.brandPrimary.opacity(0.25), lineWidth: 1))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Helpers

    private func updateCount() {
        let flights = DatabaseManager.shared.fetchFlightsByDateRange(
            start: startDate, end: endDate)
        flightCount = flights.count
    }

    private func applyRange(_ range: String) {
        let cal = Calendar.current
        endDate = Date()
        switch range {
        case "30d": startDate = cal.date(byAdding: .day,   value: -30,  to: endDate) ?? endDate
        case "90d": startDate = cal.date(byAdding: .day,   value: -90,  to: endDate) ?? endDate
        case "6m":  startDate = cal.date(byAdding: .month, value: -6,   to: endDate) ?? endDate
        case "1y":  startDate = cal.date(byAdding: .year,  value: -1,   to: endDate) ?? endDate
        case "All": startDate = cal.date(byAdding: .year,  value: -20,  to: endDate) ?? endDate
        default: break
        }
    }

    private func generateReport() {
        isGenerating = true
        pdfURL = nil
        // Fetch on background, then hand off to async PDF generator on main actor.
        // Use Task.detached so the DB fetch doesn't block the main thread.
        Task.detached(priority: .userInitiated) {
            let flights = await DatabaseManager.shared.fetchFlightsByDateRange(
                start: startDate, end: endDate)
            let url = await ExportService.shared.generatePDF(flights: flights)
            await MainActor.run {
                withAnimation(.spring()) {
                    self.pdfURL = url
                    self.isGenerating = false
                }
            }
        }
    }
}

#Preview {
    ExportView()
}
