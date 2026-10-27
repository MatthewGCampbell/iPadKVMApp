import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: HostProfile
    @State private var password: String
    private let isNew: Bool

    init(profile: HostProfile) {
        _profile = State(initialValue: profile)
        _password = State(initialValue: Keychain.password(for: profile.id))
        isNew = profile.host.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $profile.name)
                    TextField("Address, e.g. pikvm.local or 192.168.1.50", text: $profile.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Port") {
                        TextField("5900", value: $profile.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Server Type", selection: $profile.serverKind) {
                        ForEach(ServerKind.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Computer")
                }

                Section {
                    TextField("Username", text: $profile.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Login")
                } footer: {
                    if profile.serverKind == .pikvm {
                        Text("Use your PiKVM web login (the default is admin / admin). If you turned on two-factor authentication, type your password followed immediately by the current 6-digit code.")
                    } else {
                        Text("Leave the username empty for servers that only use a VNC password.")
                    }
                }

                Section {
                    Picker("Encryption", selection: $profile.security) {
                        ForEach(TransportSecurity.allCases) { Text($0.title).tag($0) }
                    }
                    if let pin = profile.pinnedCertificateSHA256 {
                        LabeledContent("Trusted Certificate") {
                            Text(pin.prefix(16) + "…").font(.caption.monospaced())
                        }
                        Button("Forget Trusted Certificate", role: .destructive) {
                            profile.pinnedCertificateSHA256 = nil
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("The first time you connect with TLS, the app remembers the server's certificate and warns you if it ever changes.")
                }

                if profile.serverKind == .pikvm {
                    Section("Video") {
                        LabeledContent("JPEG Quality") {
                            Stepper("\(profile.jpegQuality * 10)%", value: $profile.jpegQuality, in: 1...10)
                        }
                    }
                }

                Section {
                    Toggle("Send ⌘ Shortcuts as Quick Taps", isOn: $profile.commandShortcutsAsTaps)
                    Toggle("Swap ⌘ Command and ⌥ Option", isOn: $profile.swapCommandAndOption)
                    Toggle("⌃⌘V Pastes iPad Clipboard", isOn: $profile.clipboardShortcut)
                    Toggle("⌥Tab and ⌥Space Act as ⌘Tab and ⌘Space", isOn: $profile.optionStandsInForCommand)
                    Toggle("Invert Scroll Direction", isOn: $profile.invertScroll)
                } header: {
                    Text("Keyboard & Mouse")
                } footer: {
                    Text("Quick taps stop keys getting stuck if iPadOS drops a key-up while ⌘ is held. Turn it off if you need held keys to auto-repeat with ⌘ down. iPadOS keeps ⌘Tab (and sometimes ⌘Space) for itself, so ⌥Tab opens the Mac's app switcher and ⌥Space opens Spotlight. Swap ⌘/⌥ when controlling a Windows or Linux PC.")
                }

                if profile.serverKind == .generic {
                    Section("Clipboard") {
                        Toggle("Copy Remote Clipboard to iPad", isOn: $profile.copyRemoteClipboard)
                    }
                }
            }
            .navigationTitle(isNew ? "Add Computer" : "Edit Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.save(profile, password: password)
                        dismiss()
                    }
                    .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty
                              || !(1...65535).contains(profile.port))
                }
            }
        }
    }
}
