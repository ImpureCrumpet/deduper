import SwiftUI
import SwiftData
import DeduperUI

@main
struct DeduperApp: App {
    private let container: ModelContainer
    @StateObject private var triageBridge = TriageActionBridge()

    init() {
        do {
            container = try UIPersistenceFactory.makeContainer()
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(triageBridge)
        }
        .modelContainer(container)
        .commands { TriageCommands(bridge: triageBridge) }

        Settings {
            SettingsView()
        }
    }
}
