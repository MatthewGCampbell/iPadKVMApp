import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("1. Turn on VNC on the PiKVM") {
                    Text("PiKVM ships with its VNC server switched off. Open the PiKVM web UI, go to Terminal (or SSH in as root) and run:")
                    Text("su -\nrw\nsystemctl enable --now kvmd-vnc\nro")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Text("It listens on port 5900 and uses your normal PiKVM web login.")
                }

                Section("2. Add it here") {
                    Text("Tap + and enter the PiKVM's address (for example pikvm.local or its IP), port 5900, Server Type “PiKVM”, and your PiKVM username and password. Keep Encryption on TLS.")
                }

                Section("Keyboard shortcuts") {
                    Text("With a hardware keyboard, ⌘C, ⌘V, ⌘Z, ⌘A and most other shortcuts go straight to the remote Mac — they copy and paste using the Mac's own clipboard.")
                    Text("iPadOS keeps ⌘Tab, Globe-key shortcuts and sometimes ⌘Space for itself. Instead press ⌥Tab — hold ⌥ and keep tapping Tab to move through the Mac's app switcher — and ⌥Space for the Mac's Spotlight. The toolbar's ⌘ menu has these too.")
                    Text("No Esc key on your iPad keyboard? Use the toolbar's ⌘ menu, or remap Caps Lock to Escape in iPad Settings › General › Keyboard › Hardware Keyboard › Modifier Keys.")
                }

                Section("Clipboard between iPad and Mac") {
                    Label("iPad → Mac: press ⌃⌘V (or use the clipboard button). PiKVM types the iPad's clipboard text into the Mac wherever the cursor is.", systemImage: "arrow.up.doc.on.clipboard")
                    Label("Mac → iPad: use “Copy Text from Screen Area” in the clipboard menu. The app reads the text off the screen and puts it on the iPad clipboard.", systemImage: "text.viewfinder")
                    Label("Best of both: if the iPad and Mac mini are signed in to the same Apple Account with Handoff on, Universal Clipboard syncs copy and paste in both directions automatically — including images. Copy on the Mac with ⌘C, then paste on the iPad.", systemImage: "icloud")
                    Text("Why not a normal shared clipboard? PiKVM is a hardware KVM: it only sees the video output and acts as a USB keyboard and mouse, so it can't read the Mac's clipboard.")
                        .foregroundStyle(.secondary)
                }

                Section("Mouse & touch") {
                    Text("Trackpad or mouse: move, click, right-click and two-finger scroll work as usual.")
                    Text("Touch: tap to click, two-finger tap to right-click, drag with one finger to click-and-drag, two fingers to scroll.")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
