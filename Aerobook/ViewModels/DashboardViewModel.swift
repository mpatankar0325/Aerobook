import Foundation
import Combine

enum CurrencyCategory: String, CaseIterable {
    case part61 = "61"
    case part135 = "135"
    case part121 = "121"
}

struct CurrencyStatus {
    let label: String
    let status: StatusType
    let details: String
    
    enum StatusType {
        case current, warning, expired
    }
}

final class DashboardViewModel: ObservableObject {
    @Published var totalHours: Double = 0.0
    @Published var picHours: Double = 0.0
    @Published var xcHours: Double = 0.0
    @Published var soloHours: Double = 0.0
    @Published var instrumentTotalHours: Double = 0.0
    @Published var last30DaysHours: Double = 0.0
    @Published var lastFlightDate: String = "No flights logged"
    @Published var recentFlightsCount: Int = 0
    @Published var userRole: String = "Commercial Pilot"
    
    @Published var selectedCategory: CurrencyCategory = .part61
    @Published var currencyStatuses: [CurrencyStatus] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        refresh()
        setupObservers()
    }
    
    private func setupObservers() {
        NotificationCenter.default.publisher(for: .logbookDataDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }
    
    func refresh() {
        // Use fetchFlightTotals() — correct per-column SUM with COALESCE(value, 0)
        // This prevents NULL propagation that caused wrong totals when some rows
        // had no value in a column (SQLite SUM returns NULL if all values are NULL).
        let totals = DatabaseManager.shared.fetchFlightTotals()
        self.totalHours           = totals.totalTime
        self.picHours             = totals.pic
        self.xcHours              = totals.crossCountry
        self.soloHours            = totals.solo
        self.instrumentTotalHours = totals.instrumentActual + totals.instrumentSimulated
        
        let now = Date()
        let calendar = Calendar.current
        
        // Fetch Profile
        let profile = DatabaseManager.shared.fetchUserProfile()
        self.userRole = profile["pilot_certificate"] as? String ?? "Pilot"
        
        // Calculate Currency based on selected category
        updateCurrencyStatuses(profile: profile, now: now, calendar: calendar)
        
        // Fetch most recent flight
        let allFlights = DatabaseManager.shared.fetchFlightsByDateRange(
            start: calendar.date(byAdding: .year, value: -10, to: now) ?? now,
            end: now
        )
        
        if let last = allFlights.first {
            self.lastFlightDate = last["date"] as? String ?? "Unknown"
        }
        
        self.recentFlightsCount = allFlights.count
        
        // Last 30 Days
        if let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) {
            let recentFlights = DatabaseManager.shared.fetchFlightsByDateRange(start: thirtyDaysAgo, end: now)
            self.last30DaysHours = recentFlights.reduce(0.0) { $0 + ($1["total_time"] as? Double ?? 0.0) }
        }
    }
    
    private func updateCurrencyStatuses(profile: [String: Any], now: Date, calendar: Calendar) {
        var statuses: [CurrencyStatus] = []
        
        // Medical Status (Common)
        let medicalType = profile["medical_type"] as? String ?? "None"
        let medicalDateStr = profile["medical_date"] as? String ?? ""
        
        var medicalStatus: CurrencyStatus
        if medicalType == "None" || medicalDateStr.isEmpty {
            medicalStatus = CurrencyStatus(label: "Medical", status: .expired, details: "No medical on file")
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let medicalDate = df.date(from: medicalDateStr) {
                let medicalClass = profile["medical_class"] as? Int ?? 3
                var months = 24
                if medicalClass == 1 || medicalClass == 2 { months = 12 }
                
                if let expiry = calendar.date(byAdding: .month, value: months, to: medicalDate) {
                    let diff = calendar.dateComponents([.day], from: now, to: expiry).day ?? 0
                    df.dateStyle = .short
                    if diff < 0 {
                        medicalStatus = CurrencyStatus(label: "Medical (\(medicalType))", status: .expired, details: "Expired on \(df.string(from: expiry))")
                    } else if diff < 30 {
                        medicalStatus = CurrencyStatus(label: "Medical (\(medicalType))", status: .warning, details: "Expires in \(diff) days")
                    } else {
                        medicalStatus = CurrencyStatus(label: "Medical (\(medicalType))", status: .current, details: "Valid until \(df.string(from: expiry))")
                    }
                } else {
                    medicalStatus = CurrencyStatus(label: "Medical", status: .expired, details: "Invalid date")
                }
            } else {
                medicalStatus = CurrencyStatus(label: "Medical", status: .expired, details: "Invalid date")
            }
        }
        
        // Fetch recent flights for other currency checks
        let ninetyDaysAgo = calendar.date(byAdding: .day, value: -90, to: now)!
        let ninetyDayFlights = DatabaseManager.shared.fetchFlightsByDateRange(start: ninetyDaysAgo, end: now)
        let dayLandings = ninetyDayFlights.reduce(0) { $0 + ($1["landings_day"] as? Int ?? 0) }
        let nightLandings = ninetyDayFlights.reduce(0) { $0 + ($1["landings_night"] as? Int ?? 0) }
        
        let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now)!
        let sixMonthFlights = DatabaseManager.shared.fetchFlightsByDateRange(start: sixMonthsAgo, end: now)
        let approaches = sixMonthFlights.reduce(0) { $0 + ($1["approaches_count"] as? Int ?? 0) }
        let holds = sixMonthFlights.reduce(0) { $0 + ($1["holds_count"] as? Int ?? 0) }
        
        switch selectedCategory {
        case .part61:
            statuses.append(medicalStatus)
            statuses.append(CurrencyStatus(
                label: "Passenger (Day)",
                status: dayLandings >= 3 ? .current : (dayLandings > 0 ? .warning : .expired),
                details: "\(dayLandings)/3 landings in 90 days"
            ))
            statuses.append(CurrencyStatus(
                label: "Passenger (Night)",
                status: nightLandings >= 3 ? .current : (nightLandings > 0 ? .warning : .expired),
                details: "\(nightLandings)/3 full-stop landings in 90 days"
            ))
            statuses.append(CurrencyStatus(
                label: "Instrument (6-H-I-T)",
                status: (approaches >= 6 && holds >= 1) ? .current : ((approaches > 0 || holds > 0) ? .warning : .expired),
                details: "\(approaches)/6 approaches, \(holds)/1 hold in 6 months"
            ))
            
        case .part135:
            statuses.append(CurrencyStatus(
                label: "Recent Experience",
                status: (dayLandings + nightLandings) >= 3 ? .current : .expired,
                details: "\(dayLandings + nightLandings)/3 takeoffs & landings in 90 days"
            ))
            statuses.append(CurrencyStatus(
                label: "PIC Proficiency",
                status: .warning,
                details: "Checkride due in 45 days (Manual entry required)"
            ))
            
        case .part121:
            statuses.append(CurrencyStatus(
                label: "Line Currency",
                status: (dayLandings + nightLandings) >= 3 ? .current : .expired,
                details: "\(dayLandings + nightLandings)/3 cycles in 90 days"
            ))
            statuses.append(CurrencyStatus(
                label: "CAT II/III",
                status: approaches >= 3 ? .current : .expired,
                details: "\(approaches)/3 autoland events in 6 months"
            ))
        }
        
        self.currencyStatuses = statuses
    }
}
