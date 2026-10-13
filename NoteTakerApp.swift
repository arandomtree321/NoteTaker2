import SwiftUI

@main
struct NoteTakerApp: App {
    @StateObject private var store = NotebookStore()
    @StateObject private var settings = ToolSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, phase in
                    // Make sure nothing is lost when the app is closed or switched away from.
                    if phase != .active { store.flush() }
                }
        }
    }
}
