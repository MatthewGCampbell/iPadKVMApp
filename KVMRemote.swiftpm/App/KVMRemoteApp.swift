import SwiftUI

@main
struct KVMRemoteApp: App {
    @StateObject private var store = HostStore()

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
