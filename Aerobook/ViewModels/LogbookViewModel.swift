import Foundation
import SwiftUI
import Combine

final class LogbookViewModel: ObservableObject {
    @Published var flights: [[String: Any]] = []
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .logbookDataDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fetchFlights()
            }
            .store(in: &cancellables)

        // Debounce search to avoid hammering DB on fast typing
        $searchText
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Filtered + Sorted

    var filteredFlights: [[String: Any]] {
        guard !searchText.isEmpty else { return flights }
        let q = searchText.lowercased()
        return flights.filter { flight in
            let ident   = (flight["aircraft_ident"]  as? String ?? "").lowercased()
            let type    = (flight["aircraft_type"]   as? String ?? "").lowercased()
            let route   = (flight["route"]           as? String ?? "").lowercased()
            let remarks = (flight["remarks"]         as? String ?? "").lowercased()
            let date    = (flight["date"]            as? String ?? "").lowercased()
            return ident.contains(q) || type.contains(q) ||
                   route.contains(q) || remarks.contains(q) || date.contains(q)
        }
    }

    // MARK: - Fetch

    func fetchFlights() {
        let start = Calendar.current.date(byAdding: .year, value: -50, to: Date()) ?? Date()
        let end = Date()
        let result = DatabaseManager.shared.fetchFlightsByDateRange(start: start, end: end)
        print("🛫 fetchFlights returned \(result.count) rows | start=\(start) end=\(end)")
        flights = result
    }
    
    // MARK: - Lock / Verify

    /// Lock (verify) a single flight — irreversible from the UI once confirmed
    func lockFlight(id: Int64, completion: @escaping (Bool) -> Void) {
        DatabaseManager.shared.markFlightVerified(id: id) { success in
            if success { self.fetchFlights() }
            completion(success)
        }
    }

    /// Lock all currently unverified flights
    func lockAllFlights(completion: @escaping (Int) -> Void) {
        DatabaseManager.shared.markAllFlightsVerified { count in
            self.fetchFlights()
            completion(count)
        }
    }

    // MARK: - Delete

    func deleteFlight(id: Int64, completion: @escaping (Bool) -> Void) {
        DatabaseManager.shared.deleteFlight(id: id) { success in
            if success { self.fetchFlights() }
            completion(success)
        }
    }

    // MARK: - Convenience

    var unverifiedCount: Int {
        flights.filter { !($0["is_verified"] as? Bool ?? false) }.count
    }

    var totalHours: Double {
        flights.reduce(0) { $0 + ($1["total_time"] as? Double ?? 0) }
    }
}
