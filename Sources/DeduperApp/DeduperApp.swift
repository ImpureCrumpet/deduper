import SwiftUI
import DeduperKit

@main
struct DeduperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Deduper")
            .frame(width: 400, height: 300)
    }
}
