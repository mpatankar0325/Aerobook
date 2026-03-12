import SwiftUI
import Combine

@main
struct AeroBookApp: App {
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    
    init() {
        // Initialize database on startup
        _ = DatabaseManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onOpenURL { url in
                    deepLinkManager.handleURL(url)
                }
        }
    }
}
