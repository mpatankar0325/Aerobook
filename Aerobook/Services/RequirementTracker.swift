import Foundation
import SwiftUI
import Combine

final class RequirementTracker: ObservableObject {
    static let shared = RequirementTracker()
    
    struct RatingProgress: Identifiable {
        let id = UUID()
        let name: String
        let current: Double
        let required: Double
        var percentage: Double {
            min(1.0, current / required)
        }
    }
    
    @Published var commercialProgress: [RatingProgress] = []
    @Published var privateProgress: [RatingProgress] = []
    
    func refreshStats() {
        let totals = DatabaseManager.shared.fetchIACRATotals()
        
        // FAA 14 CFR 61.129 - Commercial Pilot (Airplane Single Engine)
        commercialProgress = [
            RatingProgress(name: "Total Time", current: totals.total, required: 250.0),
            RatingProgress(name: "PIC Time", current: totals.pic, required: 100.0),
            RatingProgress(name: "XC Time", current: totals.crossCountry, required: 50.0),
            RatingProgress(name: "Night Time", current: totals.night, required: 10.0),
            RatingProgress(name: "Instrument", current: totals.instrument, required: 10.0)
        ]
        
        // FAA 14 CFR 61.109 - Private Pilot
        privateProgress = [
            RatingProgress(name: "Total Time", current: totals.total, required: 40.0),
            RatingProgress(name: "Solo Time", current: totals.solo, required: 10.0),
            RatingProgress(name: "XC Time", current: totals.crossCountry, required: 5.0),
            RatingProgress(name: "Night Time", current: totals.night, required: 3.0),
            RatingProgress(name: "Instruction", current: totals.dualReceived, required: 20.0)
        ]
    }
}
