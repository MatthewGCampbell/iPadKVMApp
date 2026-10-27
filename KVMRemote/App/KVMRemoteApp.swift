import SwiftUI

@main
struct KVMRemoteApp: App {
    @StateObject private var store = HostStore()

    init() {
        #if DEBUG
        // The iPad's own keyboard views log dozens of harmless "Unable to simultaneously
        // satisfy constraints" warnings (accessoryView/inputView, TUIKeyplane) whenever
        // the on-screen keyboard appears. They come from UIKit, not this app, and bury
        // useful output in the Xcode console.
        UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(store)
        }
        .commands {
            // ⌘N would open a second iPad window instead of reaching the remote.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
