import SwiftUI

struct SessionView: View {
    @StateObject private var session: SessionController
    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var toolbarExpanded = true

    init(profile: HostProfile) {
        _session = StateObject(wrappedValue: SessionController(profile: profile,
                                                               password: Keychain.password(for: profile.id)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            RemoteScreen(session: session)
                .ignoresSafeArea()

            if session.isSelectingText {
                TextSelectionOverlay(session: session)
                    .ignoresSafeArea()
            }

            toolbar
                .padding(.top, 6)

            statusOverlay

            if let toast = session.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 30)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(item: $session.recognizedText) { item in
            RecognizedTextSheet(text: item.text)
        }
        .onAppear {
            let store = store
            let id = session.profile.id
            session.onCertificateTrusted = { sha in store.pinCertificate(sha, for: id) }
            session.connect()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            session.disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.appWillResignActive() }
        }
    }

    // MARK: Toolbar

    @ViewBuilder private var toolbar: some View {
        if toolbarExpanded {
            HStack(spacing: 4) {
                toolbarButton("xmark", "Disconnect") { dismiss() }
                Divider().frame(height: 22)

                toolbarButton("magnifyingglass", "Spotlight (⌘Space)") { session.send(.spotlight) }

                Menu {
                    ForEach(RemoteShortcut.macGroups, id: \.self) { group in
                        Section {
                            ForEach(group) { shortcut in
                                Button { session.send(shortcut); refocus() } label: {
                                    Label("\(shortcut.title)   \(shortcut.keys)", systemImage: shortcut.systemImage)
                                }
                            }
                        }
                    }
                } label: {
                    toolbarIcon("command", "Shortcuts")
                }

                latchButton("⌘", HIDUsage.leftGUI, help: "Hold ⌘ down (e.g. keep the app switcher open while pressing Tab)")
                latchButton("⌥", HIDUsage.leftAlt, help: "Hold ⌥ down")
                latchButton("⌃", HIDUsage.leftControl, help: "Hold ⌃ down")

                Divider().frame(height: 22)

                Menu {
                    Button { session.typeIPadClipboard(); refocus() } label: {
                        Label(session.profile.serverKind == .pikvm
                              ? "Type iPad Clipboard on Remote   ⌃⌘V"
                              : "Send iPad Clipboard to Remote   ⌃⌘V",
                              systemImage: "arrow.up.doc.on.clipboard")
                    }
                    Button { session.isSelectingText = true } label: {
                        Label("Copy Text from Screen Area…", systemImage: "text.viewfinder")
                    }
                    Button { session.copyText(in: nil) } label: {
                        Label("Copy All Text on Screen", systemImage: "doc.text.viewfinder")
                    }
                } label: {
                    toolbarIcon(session.isRecognizingText ? "hourglass" : "doc.on.clipboard", "Clipboard")
                }

                toolbarButton(session.softKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                              "On-screen keyboard") {
                    session.softKeyboardVisible.toggle()
                }

                Divider().frame(height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(session.desktopName).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(session.phase == .connected ? "\(session.framesPerSecond) fps" : "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 140, alignment: .leading)
                .padding(.horizontal, 4)

                toolbarButton("chevron.up", "Hide toolbar") { toolbarExpanded = false }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button { withAnimation { toolbarExpanded = true } } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 18)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .environment(\.colorScheme, .dark)
            .accessibilityLabel("Show toolbar")
        }
    }

    private func toolbarIcon(_ systemImage: String, _ label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 36, height: 32)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    private func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            refocus()
        } label: {
            toolbarIcon(systemImage, label)
        }
        .help(label)
    }

    private func latchButton(_ symbol: String, _ usage: UInt16, help: String) -> some View {
        let on = session.heldModifiers.contains(usage)
        return Button {
            session.keys.toggleLatch(usage)
            refocus()
        } label: {
            Text(symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 28)
                .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func refocus() {
        session.screenView?.focusKeyboard()
    }

    // MARK: Status

    @ViewBuilder private var statusOverlay: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Connecting to \(session.profile.displayName)…")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
            .frame(maxHeight: .infinity)
        case .disconnected(let message):
            VStack(spacing: 14) {
                Image(systemName: message == nil ? "display" : "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(message == nil ? "Disconnected" : "Connection Lost").font(.headline)
                if let message {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                HStack {
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                    if session.needsLocalNetworkPermission,
                       let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { UIApplication.shared.open(settings) }
                            .buttonStyle(.bordered)
                    }
                    Button("Reconnect") { session.connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
            .frame(maxHeight: .infinity)
        case .connected:
            EmptyView()
        }
    }
}

/// Hosts the UIKit view that renders the remote screen and captures input.
private struct RemoteScreen: UIViewRepresentable {
    let session: SessionController

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(frame: .zero)
        view.session = session
        session.screenView = view
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {}
}

/// Drag a rectangle over the remote screen to OCR the text inside it.
private struct TextSelectionOverlay: View {
    @ObservedObject var session: SessionController
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let screen = RemoteScreenView.aspectFit(session.framebufferSize == .zero ? geo.size : session.framebufferSize,
                                                    in: CGRect(origin: .zero, size: geo.size))
            ZStack {
                Color.black.opacity(0.35)
                if let rect = selection {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                VStack(spacing: 10) {
                    Text("Drag over the text you want to copy")
                        .font(.headline)
                    Button("Cancel") { session.isSelectingText = false }
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .environment(\.colorScheme, .dark)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { _ in
                        defer { start = nil; current = nil }
                        guard let rect = selection, screen.width > 0, screen.height > 0 else { return }
                        let fb = session.framebufferSize
                        let clipped = rect.intersection(screen)
                        guard !clipped.isNull else { return }
                        let sx = fb.width / screen.width, sy = fb.height / screen.height
                        session.copyText(in: CGRect(x: (clipped.minX - screen.minX) * sx,
                                                    y: (clipped.minY - screen.minY) * sy,
                                                    width: clipped.width * sx,
                                                    height: clipped.height * sy))
                    }
            )
        }
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }
}

private struct RecognizedTextSheet: View {
    @State var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(.horizontal)
                .navigationTitle("Copied from Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = text
                            dismiss()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
                .safeAreaInset(edge: .top) {
                    Text("This text is already on the iPad clipboard. Fix any recognition mistakes here, then tap Copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
    }
}
