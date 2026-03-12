import SwiftUI
import Combine

// MARK: - LogbookListView

struct LogbookListView: View {
    @StateObject private var viewModel     = LogbookViewModel()
    @State private var showingManualEntry  = false
    @State private var selectedFilter: FlightFilter = .all
    @State private var sortOrder: SortOrder = .dateDesc
    @State private var lastSavedAt: Date?  = nil
    @State private var showEndorsements    = false

    // Edit / delete / lock state
    @State private var flightToEdit:   [String: Any]? = nil
    @State private var flightToDelete: [String: Any]? = nil
    @State private var flightToLock:   [String: Any]? = nil
    @State private var showDeleteAlert      = false
    @State private var showLockAlert        = false
    @State private var showBulkLockAlert    = false
    @State private var bulkLockResult: Int? = nil

    // MARK: - Enums

    enum SortOrder: String, CaseIterable {
        case dateDesc  = "Newest First"
        case dateAsc   = "Oldest First"
        case timeDesc  = "Longest Flight"
        case timeAsc   = "Shortest Flight"
    }

    enum FlightFilter: String, CaseIterable {
        case all        = "All"
        case unverified = "Unverified"
        case locked     = "Locked"
        case xc         = "XC"
        case night      = "Night"
        case ifr        = "IFR"
        case signed     = "Signed"
    }

    // MARK: - Computed

    var displayedFlights: [[String: Any]] {
        let base = viewModel.filteredFlights
        var result: [[String: Any]]
        switch selectedFilter {
        case .all:        result = base
        case .unverified: result = base.filter { !isLocked($0) }
        case .locked:     result = base.filter {  isLocked($0) }
        case .xc:         result = base.filter { ($0["cross_country"]  as? Double ?? 0) > 0 }
        case .night:      result = base.filter { ($0["night"]          as? Double ?? 0) > 0 }
        case .ifr:        result = base.filter {
            ($0["instrument_actual"]    as? Double ?? 0) +
            ($0["instrument_simulated"] as? Double ?? 0) > 0
        }
        case .signed:     result = base.filter { $0["is_signed"] as? Bool ?? false }
        }
        return sorted(result)
    }

    private func isLocked(_ f: [String: Any]) -> Bool {
        f["is_verified"] as? Bool ?? false
    }

    private func sorted(_ f: [[String: Any]]) -> [[String: Any]] {
        switch sortOrder {
        case .dateDesc: return f.sorted { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }
        case .dateAsc:  return f.sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        case .timeDesc: return f.sorted { ($0["total_time"] as? Double ?? 0) > ($1["total_time"] as? Double ?? 0) }
        case .timeAsc:  return f.sorted { ($0["total_time"] as? Double ?? 0) < ($1["total_time"] as? Double ?? 0) }
        }
    }

    // MARK: - Body

    var body: some View {
        navigationContent
            .onAppear {
                viewModel.fetchFlights()
                lastSavedAt = DatabaseManager.shared.fetchLastFlightSavedAt()
            }
    }

    private var navigationContent: some View {
        NavigationView {
            mainContent
                .navigationTitle("")
                .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualEntryView().onDisappear { viewModel.fetchFlights() }
        }
        .sheet(item: editBinding) { item in
            FlightEditView(originalFlight: item.dict) {
                viewModel.fetchFlights()
                flightToEdit = nil
            }
        }
        // Delete confirmation
        .alert("Delete Flight?", isPresented: $showDeleteAlert, presenting: flightToDelete,
               actions: { flight in
                   Button("Delete", role: .destructive) { confirmDelete(flight) }
                   Button("Cancel", role: .cancel) { flightToDelete = nil }
               }, message: deleteMessage)
        // Single lock confirmation
        .alert("Lock Entry?", isPresented: $showLockAlert, presenting: flightToLock,
               actions: { flight in
                   Button("Lock Entry", role: .destructive) {
                       guard let id = flight["id"] as? Int64 else { return }
                       viewModel.lockFlight(id: id) { _ in flightToLock = nil }
                   }
                   Button("Cancel", role: .cancel) { flightToLock = nil }
               }, message: lockMessage)
        // Bulk lock confirmation
        .alert("Lock All Unverified?", isPresented: $showBulkLockAlert) {
            Button("Lock \(viewModel.unverifiedCount) Entries", role: .destructive) { bulkLock() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently lock \(viewModel.unverifiedCount) entries. Locked entries can no longer be deleted or edited without CFI override.")
        }
        // Bulk lock result
        .alert("Entries Locked", isPresented: bulkLockResultBinding) {
            Button("OK", role: .cancel) { bulkLockResult = nil }
        } message: {
            if let n = bulkLockResult {
                Text("\(n) flight\(n == 1 ? "" : "s") locked successfully.")
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack(alignment: .bottomTrailing) {
            AeroTheme.pageBg.ignoresSafeArea()

            if viewModel.isLoading && viewModel.flights.isEmpty {
                loadingState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerSection
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        if viewModel.unverifiedCount > 0 {
                            unverifiedBanner
                                .padding(.horizontal)
                                .padding(.bottom, 16)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        searchBar
                            .padding(.horizontal)
                            .padding(.bottom, 12)

                        filterRow
                            .padding(.bottom, 8)

                        summaryStrip
                            .padding(.horizontal)
                            .padding(.bottom, 16)

                        if displayedFlights.isEmpty {
                            emptyState
                        } else {
                            flightList
                        }

                        Color.clear.frame(height: 100)
                    }
                }
            }

            fabButton
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AEROBOOK")
                    .font(.system(size: 10, weight: .black))
                    .tracking(2.5)
                    .foregroundStyle(AeroTheme.brandPrimary)
                Text("Logbook")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(viewModel.flights.count)")
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text("entries")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                if let ts = lastSavedAt {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.statusGreen)
                            .frame(width: 6, height: 6)
                        Text("Saved \(ts, style: .relative) ago")
                            .font(.system(size: 10))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .logbookDataDidChange)) { _ in
            lastSavedAt = DatabaseManager.shared.fetchLastFlightSavedAt()
        }
    }

    // MARK: - Unverified Banner

    private var unverifiedBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.statusAmber.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.statusAmber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.unverifiedCount) entries pending review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("Review, edit, then lock to commit to logbook")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
            }

            Spacer()

            Button(action: { showBulkLockAlert = true }) {
                Label("Lock All", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.statusAmber)
                    .cornerRadius(20)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(Color(red: 1.0, green: 0.984, blue: 0.922))
        .cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(Color.statusAmber.opacity(0.35), lineWidth: 1))
        .animation(.spring(response: 0.3), value: viewModel.unverifiedCount)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(AeroTheme.textTertiary)
            TextField("Tail #, route, aircraft type, remarks…", text: $viewModel.searchText)
                .font(.system(size: 14))
                .foregroundStyle(AeroTheme.textPrimary)
            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
    }

    // MARK: - Filter + Sort Row

    private var filterRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FlightFilter.allCases, id: \.self) { filter in
                        filterChip(filter)
                    }
                }
                .padding(.horizontal)
            }

            // Sort menu
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button(action: { withAnimation { sortOrder = order } }) {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(sortOrder.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(AeroTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AeroTheme.cardBg)
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
            }
            .padding(.trailing, 14)
        }
    }

    private func filterChip(_ filter: FlightFilter) -> some View {
        let isActive = selectedFilter == filter
        return Button(action: {
            withAnimation(.spring(response: 0.25)) {
                selectedFilter = (selectedFilter == filter) ? .all : filter
            }
        }) {
            HStack(spacing: 5) {
                if filter == .unverified && viewModel.unverifiedCount > 0 {
                    Text("\(viewModel.unverifiedCount)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(isActive ? .white : Color.statusAmber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isActive ? Color.white.opacity(0.3) : Color.statusAmber.opacity(0.15))
                        .cornerRadius(8)
                }
                Text(filter.rawValue)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isActive ? .white : AeroTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? AeroTheme.brandPrimary : AeroTheme.cardBg)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(isActive ? AeroTheme.brandPrimary : AeroTheme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        let shown = displayedFlights
        let hours = shown.reduce(0.0) { $0 + ($1["total_time"] as? Double ?? 0) }
        let pics  = shown.reduce(0.0) { $0 + ($1["pic"]         as? Double ?? 0) }
        let xc    = shown.reduce(0.0) { $0 + ($1["cross_country"] as? Double ?? 0) }
        let night = shown.reduce(0.0) { $0 + ($1["night"]        as? Double ?? 0) }

        return HStack(spacing: 0) {
            summaryCell(label: "Total", value: hours, unit: "h")
            summaryDivider
            summaryCell(label: "PIC", value: pics, unit: "h")
            summaryDivider
            summaryCell(label: "XC", value: xc, unit: "h")
            summaryDivider
            summaryCell(label: "Night", value: night, unit: "h")
            summaryDivider
            summaryCountCell(label: "Flights", count: shown.count)
        }
        .padding(.vertical, 12)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 4, x: 0, y: 2)
    }

    private func summaryCell(label: String, value: Double, unit: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AeroTheme.textTertiary)
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryCountCell(label: String, count: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AeroTheme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AeroTheme.textTertiary)
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(AeroTheme.cardStroke)
            .frame(width: 1, height: 28)
    }

    // MARK: - Flight List

    private var flightList: some View {
        LazyVStack(spacing: 10) {
            ForEach(displayedFlights) { flight in
                FlightRow(
                    flight:   flight,
                    onEdit:   { if !isLocked(flight) { flightToEdit = flight } },
                    onDelete: { if !isLocked(flight) { flightToDelete = flight; showDeleteAlert = true } },
                    onLock:   {
                        if !isLocked(flight) {
                            flightToLock = flight
                            showLockAlert = true
                        }
                    }
                )
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AeroTheme.brandPrimary.opacity(0.07))
                    .frame(width: 80, height: 80)
                Image(systemName: selectedFilter == .locked ? "lock.fill" :
                                  selectedFilter == .unverified ? "checkmark.seal.fill" : "airplane")
                    .font(.system(size: 30))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(0.4))
            }
            Text(emptyStateTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AeroTheme.textPrimary)
            Text(emptyStateSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal)
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .unverified: return "All entries locked"
        case .locked:     return "No locked entries"
        default:          return viewModel.searchText.isEmpty ? "No flights logged" : "No results"
        }
    }

    private var emptyStateSubtitle: String {
        switch selectedFilter {
        case .unverified: return "Every flight has been reviewed and locked."
        case .locked:     return "Lock entries after verifying them to commit to logbook."
        default:          return viewModel.searchText.isEmpty
            ? "Tap Log Flight to add your first entry"
            : "Try adjusting your search or filter"
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(AeroTheme.brandPrimary)
            Text("Loading logbook…")
                .font(.system(size: 13))
                .foregroundStyle(AeroTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button(action: { showingManualEntry = true }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("Log Flight")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .background(AeroTheme.brandPrimary)
            .cornerRadius(30)
            .shadow(color: AeroTheme.brandPrimary.opacity(0.45), radius: 14, x: 0, y: 6)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Bindings + Alerts

    private var editBinding: Binding<IdentifiableFlightDict?> {
        Binding(
            get: { flightToEdit.map { IdentifiableFlightDict(dict: $0) } },
            set: { flightToEdit = $0?.dict }
        )
    }

    private var bulkLockResultBinding: Binding<Bool> {
        Binding(
            get: { bulkLockResult != nil },
            set: { if !$0 { bulkLockResult = nil } }
        )
    }

    @ViewBuilder
    private func deleteMessage(_ flight: [String: Any]) -> some View {
        let ident  = flight["aircraft_ident"] as? String ?? "this entry"
        let date   = flight["date"]           as? String ?? ""
        let signed = flight["is_signed"]      as? Bool   ?? false
        if signed {
            Text("Delete \(ident) on \(date)?\n\n⚠️ This flight carries a CFI signature. Deletion is permanent.")
        } else {
            Text("Delete \(ident) on \(date)? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func lockMessage(_ flight: [String: Any]) -> some View {
        let ident = flight["aircraft_ident"] as? String ?? "this entry"
        let date  = flight["date"]           as? String ?? ""
        Text("Lock \(ident) on \(date)?\n\nLocked entries are committed to your official logbook record and can no longer be deleted.")
    }

    // MARK: - Actions

    private func confirmDelete(_ flight: [String: Any]) {
        guard let id = flight["id"] as? Int64 else { return }
        viewModel.deleteFlight(id: id) { _ in flightToDelete = nil }
    }

    private func bulkLock() {
        viewModel.lockAllFlights { count in
            bulkLockResult = count
        }
    }
}

// MARK: - Identifiable wrapper

struct IdentifiableFlightDict: Identifiable {
    let id   = UUID()
    let dict: [String: Any]
}

// MARK: - FlightRow

struct FlightRow: View {
    let flight:   [String: Any]
    var onEdit:   () -> Void = {}
    var onDelete: () -> Void = {}
    var onLock:   () -> Void = {}

    // MARK: Derived

    private var isLocked:   Bool   { flight["is_verified"] as? Bool   ?? false }
    private var isSigned:   Bool   { flight["is_signed"]   as? Bool   ?? false }
    private var totalTime:  Double { flight["total_time"]  as? Double ?? 0 }
    private var picTime:    Double { flight["pic"]          as? Double ?? 0 }
    private var sicTime:    Double { flight["sic"]          as? Double ?? 0 }
    private var nightTime:  Double { flight["night"]        as? Double ?? 0 }
    private var xcTime:     Double { flight["cross_country"] as? Double ?? 0 }
    private var dualRcv:    Double { flight["dual_received"] as? Double ?? 0 }
    private var soloTime:   Double { flight["solo"]          as? Double ?? 0 }
    private var instTime:   Double {
        (flight["instrument_actual"]    as? Double ?? 0) +
        (flight["instrument_simulated"] as? Double ?? 0)
    }
    private var dayLdgs:   Int { flight["landings_day"]   as? Int ?? 0 }
    private var nightLdgs: Int { flight["landings_night"] as? Int ?? 0 }
    private var dateStr:   String { flight["date"]           as? String ?? "" }
    private var ident:     String { flight["aircraft_ident"] as? String ?? "—" }
    private var acType:    String { flight["aircraft_type"]  as? String ?? "" }
    private var route:     String { flight["route"]          as? String ?? "" }
    private var remarks:   String { flight["remarks"]        as? String ?? "" }

    // MARK: Body

    var body: some View {
        Button(action: { if !isLocked { onEdit() } }) {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                mainRow
                infoStrip
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(
                RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(
                        isLocked
                            ? (isSigned ? Color.statusGreen.opacity(0.4) : AeroTheme.cardStroke)
                            : Color.statusAmber.opacity(0.55),
                        lineWidth: isLocked ? 1 : 1.5
                    )
            )
            .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
            .opacity(isLocked ? 0.92 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        // Trailing swipe: Edit + Delete (only when unlocked), or nothing when locked
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isLocked {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(AeroTheme.brandPrimary)
            }
        }
        // Leading swipe: Lock (only when unlocked)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isLocked {
                Button(action: onLock) {
                    Label("Lock", systemImage: "lock.fill")
                }
                .tint(Color.statusGreen)
            }
        }
        .contextMenu {
            if !isLocked {
                Button(action: onEdit) {
                    Label("Edit Flight", systemImage: "pencil")
                }
                Button(action: onLock) {
                    Label("Lock Entry", systemImage: "lock.fill")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Label("Entry Locked", systemImage: "lock.fill")
            }
        }
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // Date
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                Text(formattedDate)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(AeroTheme.textSecondary)

            if !acType.isEmpty {
                separatorDot
                HStack(spacing: 4) {
                    Image(systemName: categoryIcon)
                        .font(.system(size: 10))
                    Text(acType)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(AeroTheme.brandPrimary)
            }

            separatorDot
            dayNightBadge

            Spacer()

            // Status badge (right-aligned)
            if isLocked {
                HStack(spacing: 3) {
                    Image(systemName: isSigned ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: 9))
                    Text(isSigned ? "SIGNED" : "LOCKED")
                        .font(.system(size: 8, weight: .black))
                        .tracking(0.5)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isSigned ? Color.statusGreenBg : AeroTheme.brandPrimary.opacity(0.1))
                .foregroundStyle(isSigned ? Color.statusGreen : AeroTheme.brandPrimary)
                .cornerRadius(6)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 9))
                    Text("REVIEW")
                        .font(.system(size: 8, weight: .black))
                        .tracking(0.5)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.statusAmber.opacity(0.15))
                .foregroundStyle(Color.statusAmber)
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            isLocked
                ? AeroTheme.brandPrimary.opacity(0.025)
                : Color.statusAmber.opacity(0.05)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(AeroTheme.cardStroke.opacity(0.5)).frame(height: 0.5)
        }
    }

    private var separatorDot: some View {
        Text("·")
            .font(.system(size: 14, weight: .light))
            .foregroundStyle(AeroTheme.textTertiary)
            .padding(.horizontal, 6)
    }

    private var formattedDate: String {
        guard dateStr.count >= 10 else { return dateStr }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: String(dateStr.prefix(10))) {
            df.dateFormat = "MMM d, yyyy"
            return df.string(from: d)
        }
        return dateStr
    }

    @ViewBuilder
    private var dayNightBadge: some View {
        let dayHrs  = totalTime - nightTime
        let isDay   = dayHrs   > 0.05
        let isNight = nightTime > 0
        HStack(spacing: 5) {
            if isDay {
                HStack(spacing: 3) {
                    Image(systemName: "sun.max.fill").font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.1))
                    Text(String(format: "%.1f", dayHrs))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }
            if isDay && isNight {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 8)).foregroundStyle(AeroTheme.textTertiary)
            }
            if isNight {
                HStack(spacing: 3) {
                    Image(systemName: "moon.stars.fill").font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.45, green: 0.55, blue: 0.95))
                    Text(String(format: "%.1f", nightTime))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Main Row

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 14) {
            // Category icon badge
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AeroTheme.brandPrimary.opacity(isLocked ? 0.1 : 0.06))
                    .frame(width: 44, height: 44)
                Image(systemName: categoryIcon)
                    .font(.system(size: 17))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(isLocked ? 1 : 0.5))
                if !isLocked {
                    Circle()
                        .fill(Color.statusAmber)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(AeroTheme.cardBg, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ident)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                if !route.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 10))
                            .foregroundStyle(AeroTheme.textTertiary)
                        Text(route)
                            .font(.system(size: 12))
                            .foregroundStyle(AeroTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 11, design: .serif))
                        .italic()
                        .foregroundStyle(AeroTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", totalTime))
                        .font(.system(size: 24, weight: .light, design: .rounded))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text("h")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                let ldgs = dayLdgs + nightLdgs
                if ldgs > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 9))
                        Text("\(ldgs) ldg").font(.system(size: 10))
                    }
                    .foregroundStyle(AeroTheme.textTertiary)
                }
                if isLocked {
                    // No chevron for locked entries (not tappable)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.textTertiary.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Info Strip

    private var infoStrip: some View {
        HStack(spacing: 6) {
            if dualRcv  > 0 { statPill(icon: "person.2.fill", label: "Dual",  value: dualRcv) }
            if soloTime > 0 { statPill(icon: "person.fill",   label: "Solo",  value: soloTime) }
            if picTime  > 0 { statPill(icon: "person.fill",   label: "PIC",   value: picTime) }
            if sicTime  > 0 { statPill(icon: "person.2.fill", label: "SIC",   value: sicTime) }
            if xcTime   > 0 { statPill(icon: "map.fill",      label: "XC",    value: xcTime) }
            if instTime > 0 { statPill(icon: "cloud.fill",    label: "IFR",   value: instTime) }
            if dualRcv == 0 && soloTime == 0 && picTime == 0 && sicTime == 0 && xcTime == 0 && instTime == 0 {
                statPill(icon: "clock", label: "Total", value: totalTime)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(AeroTheme.pageBg.opacity(0.4))
        .overlay(alignment: .top) {
            Rectangle().fill(AeroTheme.cardStroke.opacity(0.5)).frame(height: 0.5)
        }
    }

    private func statPill(icon: String, label: String, value: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(AeroTheme.textTertiary)
            Text(label).foregroundStyle(AeroTheme.textTertiary)
            Text(String(format: "%.1f", value)).foregroundStyle(AeroTheme.textSecondary)
        }
        .font(.system(size: 10, weight: .semibold))
    }

    private var categoryIcon: String {
        switch flight["aircraft_category"] as? String ?? "" {
        case "Rotorcraft":        return "tornado"
        case "Glider":            return "wind"
        case "Lighter-than-air":  return "cloud.fill"
        case "FFS", "FTD", "ATD": return "desktopcomputer"
        default:                  return "airplane"
        }
    }
}

// MARK: - FlightEditView

struct FlightEditView: View {
    @Environment(\.dismiss) private var dismiss

    let originalFlight: [String: Any]
    let onSaved: () -> Void

    @State private var date                = Date()
    @State private var aircraftIdent       = ""
    @State private var aircraftType        = ""
    @State private var aircraftCategory    = "Airplane"
    @State private var aircraftClass       = "SEL"
    @State private var route               = ""
    @State private var totalTime           = ""
    @State private var pic                 = ""
    @State private var sic                 = ""
    @State private var solo                = ""
    @State private var dualReceived        = ""
    @State private var dualGiven           = ""
    @State private var crossCountry        = ""
    @State private var night               = ""
    @State private var instrumentActual    = ""
    @State private var instrumentSimulated = ""
    @State private var landingsDay         = ""
    @State private var landingsNight       = ""
    @State private var approaches          = ""
    @State private var holds               = ""
    @State private var remarks             = ""

    // Lock-on-save (not retroactive verify)
    @State private var lockOnSave          = false

    @State private var isSaving            = false
    @State private var showDiscardAlert    = false
    @State private var showLockConfirm     = false
    @State private var isDirty             = false

    private var isSigned:   Bool { originalFlight["is_signed"]   as? Bool ?? false }
    private var isVerified: Bool { originalFlight["is_verified"] as? Bool ?? false }
    private var canSave: Bool    { !aircraftIdent.isEmpty && !totalTime.isEmpty }

    let categories = ["Airplane","Rotorcraft","Powered Lift","Glider",
                      "Lighter-than-air","FFS","FTD","ATD"]
    let classes    = ["SEL","MEL","SES","MES","Helicopter",
                      "Gyroplane","Balloon","Airship","SE","ME"]

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        statusCard
                        if isSigned { signedWarning }
                        basicInfoCard
                        timesCard
                        opsCard
                        remarksCard
                        lockCard
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(isVerified ? "Locked Entry" : "Edit Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        if isDirty { showDiscardAlert = true } else { dismiss() }
                    }
                    .foregroundStyle(AeroTheme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isVerified {
                        Button(action: {
                            if lockOnSave { showLockConfirm = true } else { saveChanges() }
                        }) {
                            HStack(spacing: 6) {
                                if isSaving {
                                    ProgressView().tint(.white).scaleEffect(0.8)
                                } else {
                                    Image(systemName: lockOnSave ? "lock.fill" : "checkmark.circle.fill")
                                    Text(lockOnSave ? "Save & Lock" : "Save")
                                }
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background((canSave && !isSaving)
                                ? (lockOnSave ? Color.statusGreen : AeroTheme.brandPrimary)
                                : AeroTheme.textTertiary)
                            .cornerRadius(20)
                        }
                        .disabled(!canSave || isSaving)
                    }
                }
            }
            .alert("Discard Changes?", isPresented: $showDiscardAlert) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("You have unsaved edits. Discard them?")
            }
            // Final lock confirmation from save button
            .alert("Lock This Entry?", isPresented: $showLockConfirm) {
                Button("Save & Lock", role: .destructive) { saveChanges() }
                Button("Save Without Locking") { lockOnSave = false; saveChanges() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Locking commits this entry to your official logbook. It cannot be edited or deleted without a CFI override.")
            }
        }
        .onAppear { loadFields() }
    }

    // MARK: Sub-views

    /// Top status bar — shows locked / unlocked state clearly
    private var statusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isVerified
                          ? (isSigned ? Color.statusGreen.opacity(0.15) : AeroTheme.brandPrimary.opacity(0.1))
                          : Color.statusAmber.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: isVerified
                      ? (isSigned ? "checkmark.seal.fill" : "lock.fill")
                      : "lock.open.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isVerified
                                     ? (isSigned ? Color.statusGreen : AeroTheme.brandPrimary)
                                     : Color.statusAmber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isVerified
                     ? (isSigned ? "Signed & Locked" : "Locked Entry")
                     : "Pending Review")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(isVerified
                     ? "This entry is committed to your logbook record"
                     : "Edit details, then lock to commit to your logbook")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .padding(14)
        .background(isVerified
                    ? AeroTheme.brandPrimary.opacity(0.05)
                    : Color.statusAmber.opacity(0.06))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(isVerified
                    ? AeroTheme.brandPrimary.opacity(0.2)
                    : Color.statusAmber.opacity(0.3), lineWidth: 1))
    }

    private var signedWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.statusAmber)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text("CFI Signed Entry")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("This flight carries a CFI signature. Editing may invalidate its integrity hash.")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .background(Color(red: 1.0, green: 0.984, blue: 0.922))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusAmber.opacity(0.35), lineWidth: 1))
    }

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
                            .onChange(of: date) { isDirty = true }
                            .disabled(isVerified)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(isVerified ? AeroTheme.pageBg : AeroTheme.fieldBg)
                    .cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                }
                HStack(spacing: 12) {
                    dirtyField(label: "Tail Number",   binding: $aircraftIdent, placeholder: "N12345", icon: "number")
                    dirtyField(label: "Aircraft Type", binding: $aircraftType,  placeholder: "C172",   icon: "airplane")
                }
                HStack(spacing: 12) {
                    EntryPickerField(label: "Category", selection: $aircraftCategory, options: categories)
                    EntryPickerField(label: "Class",    selection: $aircraftClass,    options: classes)
                }
                dirtyField(label: "Route", binding: $route,
                           placeholder: "KSQL – KHAF – KSQL",
                           icon: "arrow.triangle.swap")
            }
        }
        .disabled(isVerified)
        .opacity(isVerified ? 0.7 : 1)
    }

    private var timesCard: some View {
        EntryCard(title: "Flight Times", icon: "clock.fill", accent: .sky500) {
            VStack(spacing: 0) {
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
                            .onChange(of: totalTime) { isDirty = true }
                            .disabled(isVerified)
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
                    timeField("PIC",           $pic)
                    timeField("SIC",           $sic)
                    timeField("Solo",          $solo)
                    timeField("Dual Received", $dualReceived)
                    timeField("Dual Given",    $dualGiven)
                    timeField("Night",         $night)
                    timeField("Cross Country", $crossCountry)
                    timeField("Actual IMC",    $instrumentActual)
                    timeField("Simulated IMC", $instrumentSimulated)
                }
            }
        }
        .disabled(isVerified)
        .opacity(isVerified ? 0.7 : 1)
    }

    private var opsCard: some View {
        EntryCard(title: "Operations", icon: "location.fill", accent: .purple) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                intField("Day Landings",   $landingsDay)
                intField("Night Landings", $landingsNight)
                intField("Approaches",     $approaches)
                intField("Holds",          $holds)
            }
        }
        .disabled(isVerified)
        .opacity(isVerified ? 0.7 : 1)
    }

    private var remarksCard: some View {
        EntryCard(title: "Remarks", icon: "text.alignleft") {
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
                    .onChange(of: remarks) { isDirty = true }
                    .disabled(isVerified)
            }
            .background(AeroTheme.fieldBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
        .opacity(isVerified ? 0.7 : 1)
    }

    /// Lock card — only shown when entry is not yet locked
    @ViewBuilder
    private var lockCard: some View {
        if !isVerified {
            EntryCard(title: "Commit to Logbook", icon: "lock.fill", accent: Color.statusGreen) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("When you're satisfied this entry is accurate, lock it to commit it to your official logbook record.")
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .lineSpacing(3)

                    Toggle(isOn: $lockOnSave) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lock on Save")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AeroTheme.textPrimary)
                            Text("Entry will be locked permanently when you tap Save & Lock")
                                .font(.system(size: 11))
                                .foregroundStyle(AeroTheme.textTertiary)
                        }
                    }
                    .tint(Color.statusGreen)

                    if lockOnSave {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.statusAmber)
                                .font(.system(size: 13))
                            Text("Once locked, this entry cannot be edited or deleted.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.statusAmber)
                        }
                        .padding(12)
                        .background(Color.statusAmber.opacity(0.1))
                        .cornerRadius(AeroTheme.radiusSm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.spring(response: 0.25), value: lockOnSave)
                    }
                }
            }
        }
    }

    // MARK: Field helpers

    private func dirtyField(label: String, binding: Binding<String>,
                            placeholder: String, icon: String) -> some View {
        AeroField(label: label, text: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; isDirty = true }
        ), placeholder: placeholder, icon: icon)
    }

    private func timeField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
            TextField("0.0", text: Binding(
                get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0; isDirty = true }
            ))
            .keyboardType(.decimalPad)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(AeroTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AeroTheme.fieldBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }

    private func intField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
            TextField("0", text: Binding(
                get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0; isDirty = true }
            ))
            .keyboardType(.numberPad)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(AeroTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AeroTheme.fieldBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }

    // MARK: Load + Save

    private func loadFields() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        if let s = originalFlight["date"] as? String, let d = df.date(from: s) { date = d }

        aircraftIdent       = originalFlight["aircraft_ident"]    as? String ?? ""
        aircraftType        = originalFlight["aircraft_type"]     as? String ?? ""
        aircraftCategory    = originalFlight["aircraft_category"] as? String ?? "Airplane"
        aircraftClass       = originalFlight["aircraft_class"]    as? String ?? "SEL"
        route               = originalFlight["route"]             as? String ?? ""
        remarks             = originalFlight["remarks"]           as? String ?? ""

        func d(_ k: String) -> String {
            guard let v = originalFlight[k] as? Double, v > 0 else { return "" }
            return String(format: "%.1f", v)
        }
        func i(_ k: String) -> String {
            guard let v = originalFlight[k] as? Int, v > 0 else { return "" }
            return "\(v)"
        }
        totalTime           = d("total_time")
        pic                 = d("pic")
        sic                 = d("sic")
        solo                = d("solo")
        dualReceived        = d("dual_received")
        dualGiven           = d("dual_given")
        crossCountry        = d("cross_country")
        night               = d("night")
        instrumentActual    = d("instrument_actual")
        instrumentSimulated = d("instrument_simulated")
        landingsDay         = i("landings_day")
        landingsNight       = i("landings_night")
        approaches          = i("approaches_count")
        holds               = i("holds_count")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isDirty = false }
    }

    private func saveChanges() {
        let df  = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let now = ISO8601DateFormatter().string(from: Date())

        let flightData: [String: Any] = [
            "id":                   originalFlight["id"]           as? Int64  ?? 0,
            "date":                 df.string(from: date),
            "aircraft_ident":       aircraftIdent,
            "aircraft_type":        aircraftType,
            "aircraft_category":    aircraftCategory,
            "aircraft_class":       aircraftClass,
            "route":                route,
            "total_time":           Double(totalTime)              ?? 0.0,
            "pic":                  Double(pic)                    ?? 0.0,
            "sic":                  Double(sic)                    ?? 0.0,
            "solo":                 Double(solo)                   ?? 0.0,
            "dual_received":        Double(dualReceived)           ?? 0.0,
            "dual_given":           Double(dualGiven)              ?? 0.0,
            "cross_country":        Double(crossCountry)           ?? 0.0,
            "night":                Double(night)                  ?? 0.0,
            "instrument_actual":    Double(instrumentActual)       ?? 0.0,
            "instrument_simulated": Double(instrumentSimulated)    ?? 0.0,
            "flight_sim":           originalFlight["flight_sim"]   as? Double ?? 0.0,
            "takeoffs":             originalFlight["takeoffs"]     as? Int    ?? 0,
            "landings_day":         Int(landingsDay)               ?? 0,
            "landings_night":       Int(landingsNight)             ?? 0,
            "approaches_count":     Int(approaches)                ?? 0,
            "holds_count":          Int(holds)                     ?? 0,
            "nav_tracking":         originalFlight["nav_tracking"] as? Bool   ?? false,
            "remarks":              remarks,
            "is_verified":          lockOnSave,
            "verified_at":          lockOnSave ? now : (originalFlight["verified_at"] as? String ?? "")
        ]

        isSaving = true
        DatabaseManager.shared.updateFlight(flightData) { success in
            isSaving = false
            if success {
                onSaved()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { dismiss() }
            }
        }
    }
}

// MARK: - Extensions

struct DetailPill: View {
    let label: String
    let value: Double
    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundStyle(AeroTheme.textTertiary)
            Text(String(format: "%.1f", value)).foregroundStyle(AeroTheme.textSecondary)
        }
        .font(.system(size: 10, weight: .bold))
    }
}

extension Dictionary: @retroactive Identifiable where Key == String {
    public var id: String {
        if let flightId = self["id"] as? Int64 { return String(flightId) }
        return UUID().uuidString
    }
}

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(EdgeBorder(width: width, edges: edges).foregroundColor(color))
    }
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat { switch edge { case .top, .bottom, .leading: return rect.minX; case .trailing: return rect.maxX - width } }
            var y: CGFloat { switch edge { case .top, .leading, .trailing: return rect.minY; case .bottom: return rect.maxY - width } }
            var w: CGFloat { switch edge { case .top, .bottom: return rect.width; case .leading, .trailing: return width } }
            var h: CGFloat { switch edge { case .top, .bottom: return width; case .leading, .trailing: return rect.height } }
            path.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return path
    }
}

#Preview {
    LogbookListView()
}
