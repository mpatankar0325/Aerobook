// ImportReviewView.swift
// AeroBook
//
// ── TYPE DECLARATIONS ──────────────────────────────────────────────────────
// LogbookImportFormat, ParsedFlightRecord, LogbookImportResult are declared
// ONLY in ImportModels.swift.  They have been removed from this file to
// eliminate the "ambiguous for type lookup" compiler errors.
// ───────────────────────────────────────────────────────────────────────────

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Main Import View

struct ImportView: View {

    @State private var selectedFormat: LogbookImportFormat = .jeppesen
    @State private var showFilePicker   = false
    @State private var isProcessing     = false
    @State private var importResult: LogbookImportResult?
    @State private var showReviewSheet  = false
    @State private var errorMessage: String?
    @State private var commitDone: (inserted: Int, failed: Int)?

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        AeroPageHeader(
                            title: "Importer",
                            subtitle: "Jeppesen · ASA · ForeFlight · LogTen · CSV / Excel"
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)

                        dropZone.padding(.horizontal)

                        if let done = commitDone {
                            commitBanner(inserted: done.inserted, failed: done.failed)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let err = errorMessage {
                            errorBanner(err)
                                .padding(.horizontal)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        formatPicker.padding(.horizontal)
                        templateInfoCard.padding(.horizontal)
                        supportedSourcesGrid.padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .sheet(isPresented: $showFilePicker) {
                MultiFormatDocumentPicker(format: selectedFormat) { url in
                    handleFilePicked(url: url)
                }
            }
            .sheet(isPresented: $showReviewSheet, onDismiss: { importResult = nil }) {
                if let result = importResult {
                    ImportReviewView(result: result) { approved in
                        commitRecords(approved)
                    }
                }
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        Button(action: { showFilePicker = true }) {
            VStack(spacing: 24) {
                if isProcessing {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.4).tint(AeroTheme.brandPrimary)
                        Text("Parsing logbook…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                    .frame(height: 120)
                } else {
                    ZStack {
                        Circle().fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 88, height: 88)
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 30)).foregroundStyle(AeroTheme.brandPrimary)
                    }
                    VStack(spacing: 6) {
                        Text("Select Your Logbook File")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("CSV · XLSX · Excel — all logbook formats supported")
                            .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(["CSV", "XLSX", "Jeppesen", "ASA", "ForeFlight"], id: \.self) { fmt in
                            Text(fmt)
                                .font(.system(size: 10, weight: .bold)).tracking(0.5)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(AeroTheme.brandPrimary.opacity(0.08))
                                .foregroundStyle(AeroTheme.brandPrimary)
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusXl)
            .overlay(
                RoundedRectangle(cornerRadius: AeroTheme.radiusXl)
                    .strokeBorder(
                        AeroTheme.brandPrimary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isProcessing)
    }

    // MARK: - Format Picker

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Select Import Format", icon: "square.grid.2x2.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogbookImportFormat.allCases) { fmt in
                        Button(action: { selectedFormat = fmt }) {
                            HStack(spacing: 6) {
                                Image(systemName: fmt.icon).font(.system(size: 11))
                                Text(fmt.rawValue).font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(selectedFormat == fmt ? AeroTheme.brandPrimary : AeroTheme.cardBg)
                            .foregroundStyle(selectedFormat == fmt ? .white : AeroTheme.textSecondary)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedFormat == fmt ? AeroTheme.brandPrimary : AeroTheme.cardStroke,
                                        lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .animation(.spring(response: 0.25), value: selectedFormat)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Template Info Card

    private var templateInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 36, height: 36)
                    Image(systemName: selectedFormat.icon)
                        .font(.system(size: 15)).foregroundStyle(AeroTheme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedFormat.rawValue)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                    Text(selectedFormat.description)
                        .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 16) {
                capability(icon: "checkmark.circle.fill", color: .statusGreen, text: "Auto-detect headers")
                capability(
                    icon: selectedFormat.supportsDoubleRowHeader ? "checkmark.circle.fill" : "minus.circle.fill",
                    color: selectedFormat.supportsDoubleRowHeader ? .statusGreen : AeroTheme.textTertiary,
                    text: "Double-row headers"
                )
                capability(icon: "checkmark.circle.fill", color: .statusGreen, text: "Review before import")
            }
        }
        .padding(20)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
    }

    // MARK: - Supported Sources Grid

    private var supportedSourcesGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Supported Formats", icon: "doc.fill")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                sourceCard(icon: "book.fill",     name: "Jeppesen",    detail: "FAA paper logbook",   color: .sky500)
                sourceCard(icon: "graduationcap.fill", name: "ASA",    detail: "Standard logbook",    color: AeroTheme.brandPrimary)
                sourceCard(icon: "airplane",      name: "ForeFlight",  detail: "CSV backup export",   color: .statusGreen)
                sourceCard(icon: "book.closed.fill", name: "LogTen Pro", detail: "Standard CSV export", color: .statusAmber)
                sourceCard(icon: "antenna.radiowaves.left.and.right", name: "Garmin Pilot",
                           detail: "Flight log CSV", color: .sky500)
                sourceCard(icon: "tablecells.badge.ellipsis", name: "Excel / XLSX",
                           detail: "Double-row Jeppesen format", color: AeroTheme.brandPrimary)
            }
        }
    }

    // MARK: - Banners

    private func commitBanner(inserted: Int, failed: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.statusGreen.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Color.statusGreen)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Complete").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.statusGreen)
                Text("\(inserted) flights added\(failed > 0 ? ", \(failed) failed" : "")")
                    .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
            Button(action: { withAnimation { commitDone = nil } }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(16)
        .background(Color.statusGreenBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(Color.statusGreen.opacity(0.2), lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.red.opacity(0.12)).frame(width: 44, height: 44)
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(Color.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Error").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.red)
                Text(message).font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary).lineLimit(2)
            }
            Spacer()
            Button(action: { withAnimation { errorMessage = nil } }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.06))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(Color.red.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Logic

    private func handleFilePicked(url: URL) {
        isProcessing = true
        errorMessage = nil
        commitDone   = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: LogbookImportResult
                let ext = url.pathExtension.lowercased()
                if ext == "xlsx" || ext == "xls" || selectedFormat == .excel {
                    result = try ExcelImporter.parse(url: url)
                } else {
                    result = try LogbookImportService.shared.parseFile(
                        at: url,
                        format: selectedFormat == .autoDetect ? detectFormat(url: url) : selectedFormat
                    )
                }
                DispatchQueue.main.async {
                    isProcessing    = false
                    importResult    = result
                    showReviewSheet = true
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func detectFormat(url: URL) -> LogbookImportFormat {
        let name = url.lastPathComponent.lowercased()
        if name.contains("foreflight") { return .foreFlight }
        if name.contains("logten")     { return .logTenPro  }
        if name.contains("garmin")     { return .garmin     }
        if name.contains("jeppesen")   { return .jeppesen   }
        return .genericCSV
    }

    private func commitRecords(_ records: [ParsedFlightRecord]) {
        let flightDicts: [[String: Any]] = records
            .filter { $0.isSelected }
            .map { r in
                [
                    "date":                  r.date,
                    "aircraft_type":         r.aircraftType,
                    "aircraft_ident":        r.aircraftIdent,
                    "aircraft_category":     r.aircraftCategory,
                    "aircraft_class":        r.aircraftClass,
                    "route":                 r.route,
                    "total_time":            r.totalTime,
                    "pic":                   r.pic,
                    "sic":                   r.sic,
                    "solo":                  r.solo,
                    "dual_received":         r.dualReceived,
                    "dual_given":            r.dualGiven,
                    "cross_country":         r.crossCountry,
                    "night":                 r.night,
                    "instrument_actual":     r.instrumentActual,
                    "instrument_simulated":  r.instrumentSimulated,
                    "flight_sim":            r.flightSim,
                    "takeoffs":              r.takeoffs,
                    "landings_day":          r.landingsDay,
                    "landings_night":        r.landingsNight,
                    "approaches_count":      r.approachesCount,
                    "holds_count":           r.holdsCount,
                    "nav_tracking":          false,
                    "remarks":               r.remarks,
                    "is_legacy_import":      true,
                    "legacy_signature_path": ""
                ] as [String: Any]
            }

        DatabaseManager.shared.addFlightsBatch(flightDicts) { inserted, failed in
            withAnimation { commitDone = (inserted, failed) }
            NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
        }
    }

    // MARK: - Reusable Sub-views

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .bold)).tracking(1.2)
        }
        .foregroundStyle(AeroTheme.brandPrimary).textCase(.uppercase)
    }

    private func capability(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(AeroTheme.textSecondary)
        }
    }

    private func sourceCard(icon: String, name: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                Text(detail).font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
            }
            Spacer()
        }
        .padding(12)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.cardStroke, lineWidth: 1))
    }
}

// MARK: - Import Review Sheet

struct ImportReviewView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var records: [ParsedFlightRecord]
    let onCommit: ([ParsedFlightRecord]) -> Void
    private let result: LogbookImportResult

    init(result: LogbookImportResult, onCommit: @escaping ([ParsedFlightRecord]) -> Void) {
        self.result   = result
        self._records = State(initialValue: result.records)
        self.onCommit = onCommit
    }

    private var selectedCount: Int { records.filter { $0.isSelected }.count }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    statsBar
                    if !result.warnings.isEmpty { warningsBanner }
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach($records) { $record in
                                ImportRecordCard(record: $record)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 12)
                    }
                    commitBar
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select All")   { setAll(true)  }
                        Button("Deselect All") { setAll(false) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    // MARK: Stats Bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            statPill(value: "\(result.records.count)", label: "Parsed",   color: AeroTheme.brandPrimary)
            Divider().frame(height: 30)
            statPill(value: "\(result.skippedCount)",  label: "Skipped",  color: .statusAmber)
            Divider().frame(height: 30)
            statPill(value: "\(selectedCount)",        label: "Selected", color: .statusGreen)
            Divider().frame(height: 30)
            statPill(value: result.detectedFormat.rawValue, label: "Format", color: AeroTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(AeroTheme.cardBg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(AeroTheme.cardStroke), alignment: .bottom)
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Warnings Banner

    private var warningsBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.statusAmber)
                Text("\(result.warnings.count) Import Warning\(result.warnings.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.statusAmber)
            }
            ForEach(result.warnings.prefix(3), id: \.self) { w in
                Text("• \(w)").font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.statusAmberBg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.statusAmber.opacity(0.2)), alignment: .bottom)
    }

    // MARK: Commit Bar

    private var commitBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(AeroTheme.cardBg).foregroundStyle(AeroTheme.textSecondary)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AeroTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: commitAndDismiss) {
                    Label("Import \(selectedCount) Flights", systemImage: "arrow.down.doc.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(selectedCount > 0 ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                        .foregroundStyle(.white).cornerRadius(12)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
        }
        .background(AeroTheme.pageBg)
    }

    private func commitAndDismiss() { onCommit(records); dismiss() }
    private func setAll(_ s: Bool) { for i in records.indices { records[i].isSelected = s } }
}

// MARK: - Import Record Card

struct ImportRecordCard: View {

    @Binding var record: ParsedFlightRecord
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: { record.isSelected.toggle() }) {
                    Image(systemName: record.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(record.isSelected ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(record.date.isEmpty ? "No Date" : record.date)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(record.date.isEmpty ? Color.red : AeroTheme.textPrimary)

                        if !record.aircraftType.isEmpty {
                            Text(record.aircraftType)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(AeroTheme.brandPrimary.opacity(0.1))
                                .foregroundStyle(AeroTheme.brandPrimary).cornerRadius(5)
                        }

                        if !record.aircraftIdent.isEmpty {
                            Text(record.aircraftIdent)
                                .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                        }

                        Spacer()

                        Text(String(format: "%.1fh", record.totalTime))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(record.totalTime > 0 ? AeroTheme.textPrimary : .statusAmber)
                    }

                    HStack(spacing: 4) {
                        if !record.route.isEmpty {
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(AeroTheme.textTertiary)
                            Text(record.route).font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if !record.importWarnings.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(Color.statusAmber)
                        }
                    }
                }

                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(AeroTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(16)

            if expanded {
                Divider().padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    timePill("PIC",   record.pic)
                    timePill("SIC",   record.sic)
                    timePill("Dual",  record.dualReceived)
                    timePill("CFI",   record.dualGiven)
                    timePill("Solo",  record.solo)
                    timePill("XC",    record.crossCountry)
                    timePill("Night", record.night)
                    timePill("Inst.", record.instrumentActual)
                    timePill("Hood",  record.instrumentSimulated)
                }
                .padding(.horizontal, 16).padding(.top, 12)

                if record.landingsDay > 0 || record.landingsNight > 0 {
                    HStack(spacing: 20) {
                        if record.landingsDay > 0 {
                            Label("\(record.landingsDay) Day Ldg", systemImage: "arrow.down.to.line")
                                .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                        }
                        if record.landingsNight > 0 {
                            Label("\(record.landingsNight) Night Ldg", systemImage: "moon.stars.fill")
                                .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }

                if !record.remarks.isEmpty {
                    Text(record.remarks)
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 8).lineLimit(2)
                }

                if !record.importWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.importWarnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(Color.statusAmber)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }

                Color.clear.frame(height: 12)
            }
        }
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(record.isSelected ? AeroTheme.brandPrimary.opacity(0.4) : AeroTheme.cardStroke, lineWidth: 1))
        .opacity(record.isSelected ? 1.0 : 0.55)
        .animation(.spring(response: 0.25), value: record.isSelected)
    }

    private func timePill(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(value > 0 ? String(format: "%.1f", value) : "—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(value > 0 ? AeroTheme.textPrimary : AeroTheme.textTertiary)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(AeroTheme.brandPrimary.opacity(0.04)).cornerRadius(8)
    }
}

// MARK: - Multi-Format Document Picker

struct MultiFormatDocumentPicker: UIViewControllerRepresentable {
    let format: LogbookImportFormat
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.commaSeparatedText, .spreadsheet, .data, .plainText]
        if let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") { types.append(xlsx) }
        if let xls  = UTType("com.microsoft.excel.xls")                { types.append(xls) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: MultiFormatDocumentPicker
        init(_ p: MultiFormatDocumentPicker) { parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
    }
}

#Preview {
    ImportView()
}
