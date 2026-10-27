import SwiftUI
import UIKit

/// Owns one VNC connection and everything the session UI needs from it.
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case connected
        case disconnected(String?)
    }

    struct RecognizedText: Identifiable {
        let id = UUID()
        var text: String
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var desktopName: String
    @Published private(set) var framebufferSize: CGSize = .zero
    @Published private(set) var framesPerSecond = 0
    /// Modifiers held from the toolbar or the on-screen keyboard bar.
    @Published private(set) var heldModifiers: Set<UInt16> = []
    @Published var toast: String?
    @Published var recognizedText: RecognizedText?
    @Published var isSelectingText = false
    @Published private(set) var isRecognizingText = false
    /// The last disconnect was iPadOS blocking Local Network access.
    @Published private(set) var needsLocalNetworkPermission = false
    @Published var softKeyboardVisible = false {
        didSet { screenView?.setSoftKeyboardVisible(softKeyboardVisible) }
    }

    let profile: HostProfile
    let framebuffer = Framebuffer()
    private(set) var keys: KeyInputRouter!
    weak var screenView: RemoteScreenView?
    var onCertificateTrusted: (String) -> Void = { _ in }

    private let password: String
    private var client: RFBClient?
    private var fpsTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var scrollRemainder = CGPoint.zero
    private var heldButtons: PointerButtons = []

    init(profile: HostProfile, password: String) {
        self.profile = profile
        self.password = password
        self.desktopName = profile.displayName

        keys = KeyInputRouter { [weak self] usage, down in
            self?.client?.sendKey(usage: usage, down: down)
        }
        keys.options = .init(commandShortcutsAsTaps: profile.commandShortcutsAsTaps,
                             swapCommandAndOption: profile.swapCommandAndOption,
                             clipboardShortcut: profile.clipboardShortcut,
                             optionStandsInForCommand: profile.optionStandsInForCommand)
        keys.onLocalAction = { [weak self] action in
            switch action {
            case .typeIPadClipboard: self?.typeIPadClipboard()
            }
        }
        keys.onUnmappedText = { [weak self] text in self?.typeUnmapped(text) }
        keys.onModifierStateChange = { [weak self] in
            guard let self else { return }
            heldModifiers = keys.latched.union(keys.oneShot)
            screenView?.modifierStateChanged()
        }

        framebuffer.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.showLatestFrame() }
            }
        }
        framebuffer.onResize = { [weak self] width, height in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.framebufferSize = CGSize(width: width, height: height)
                    self?.screenView?.framebufferSize = CGSize(width: width, height: height)
                }
            }
        }
    }

    // MARK: Connection

    func connect() {
        client?.stop()
        phase = .connecting
        let config = RFBConfig(host: profile.host.trimmingCharacters(in: .whitespaces),
                               port: profile.port,
                               username: profile.username,
                               password: password,
                               serverKind: profile.serverKind,
                               security: profile.security,
                               jpegQuality: profile.jpegQuality,
                               pinnedCertificateSHA256: profile.pinnedCertificateSHA256)
        let newClient = RFBClient(config: config)
        newClient.delegate = self
        newClient.sink = framebuffer
        client = newClient
        newClient.start()

        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.framesPerSecond = self.framebuffer.takeFrameCount()
            }
        }
    }

    func disconnect() {
        keys.releaseAll()
        fpsTimer?.invalidate()
        fpsTimer = nil
        let c = client
        client = nil
        c?.stop()
    }

    func appWillResignActive() {
        // Anything held when the iPad takes over (⌘Tab, Home) would stay stuck on the remote.
        keys.releaseAll()
        releaseMouseButtons()
    }

    private func showLatestFrame() {
        screenView?.show(framebuffer.imageForDisplay())
    }

    // MARK: Pointer

    func pointerMoved(to point: CGPoint) {
        client?.sendPointer(x: Int(point.x), y: Int(point.y), buttons: heldButtons)
    }

    func pointer(at point: CGPoint, button: PointerButtons, down: Bool) {
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        client?.sendPointer(x: Int(point.x), y: Int(point.y), buttons: heldButtons)
    }

    func click(at point: CGPoint, button: PointerButtons) {
        pointerMoved(to: point)
        pointer(at: point, button: button, down: true)
        pointer(at: point, button: button, down: false)
    }

    func releaseMouseButtons() {
        heldButtons = []
    }

    /// `delta` in screen points, positive = fingers moving right/down.
    func scroll(by delta: CGPoint) {
        let step: CGFloat = 18
        scrollRemainder.x += delta.x
        scrollRemainder.y += delta.y
        let invert = profile.invertScroll
        while abs(scrollRemainder.y) >= step {
            let fingersDown = scrollRemainder.y > 0
            // macOS applies "natural scrolling" to the wheel, so fingers down = wheel down.
            client?.sendScroll(fingersDown != invert ? .wheelDown : .wheelUp, held: heldButtons)
            scrollRemainder.y -= fingersDown ? step : -step
        }
        while abs(scrollRemainder.x) >= step {
            let fingersRight = scrollRemainder.x > 0
            client?.sendScroll(fingersRight != invert ? .wheelRight : .wheelLeft, held: heldButtons)
            scrollRemainder.x -= fingersRight ? step : -step
        }
    }

    func endScroll() { scrollRemainder = .zero }

    // MARK: Keyboard

    func send(_ shortcut: RemoteShortcut) {
        let combo = shortcut.combo
        keys.tap(combo.key, modifiers: combo.modifiers)
    }

    func typeFromSoftKeyboard(_ text: String) {
        keys.type(text)
    }

    private func typeUnmapped(_ text: String) {
        guard let client else { return }
        switch profile.serverKind {
        case .pikvm:
            // PiKVM can only type what its keymap knows; it skips the rest.
            client.typeViaPiKVM(text)
        case .generic:
            for scalar in text.unicodeScalars {
                let keysym = scalar.value < 0x100 ? scalar.value : 0x0100_0000 | scalar.value
                client.sendKeysym(keysym, down: true)
                client.sendKeysym(keysym, down: false)
            }
        }
    }

    // MARK: Clipboard

    /// iPad → remote. PiKVM can't set the Mac's clipboard (it's just a keyboard and
    /// a capture card), so it types the text out instead.
    func typeIPadClipboard() {
        guard let client, phase == .connected else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showToast("The iPad clipboard has no text.")
            return
        }
        keys.releaseAll()
        switch profile.serverKind {
        case .pikvm:
            client.typeViaPiKVM(text)
            showToast("Typing \(text.count) characters on \(desktopName)…")
        case .generic:
            client.sendClipboard(text)
            showToast("Sent to the remote clipboard. Press ⌘V to paste.")
        }
    }

    /// Remote → iPad via OCR. `rect` is in framebuffer pixels; nil means the whole screen.
    func copyText(in rect: CGRect?) {
        isSelectingText = false
        guard let image = framebuffer.snapshot() else { return }
        let fbWidth = max(1, framebuffer.width)
        let scale = CGFloat(image.width) / CGFloat(fbWidth)
        var crop = image
        if let rect {
            let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                   width: rect.width * scale, height: rect.height * scale).integral
            guard pixelRect.width >= 4, pixelRect.height >= 4,
                  let cropped = image.cropping(to: pixelRect) else { return }
            crop = cropped
        }
        isRecognizingText = true
        Task {
            let text = (try? await TextRecognizer.recognizeText(in: crop)) ?? ""
            isRecognizingText = false
            if text.isEmpty {
                showToast("No text found there.")
            } else {
                UIPasteboard.general.string = text
                recognizedText = RecognizedText(text: text)
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }
}

extension SessionController: RFBClientDelegate {
    nonisolated func rfbClientDidConnect(_ client: RFBClient, name: String, width: Int, height: Int) {
        MainActor.assumeIsolated {
            guard client === self.client else { return }
            phase = .connected
            if !name.isEmpty { desktopName = name }
            screenView?.focusKeyboard()
        }
    }

    nonisolated func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?) {
        MainActor.assumeIsolated {
            guard client === self.client else { return }
            self.client = nil
            fpsTimer?.invalidate()
            keys.releaseAll()
            needsLocalNetworkPermission = (error as? RFBError) == .localNetworkDenied
            phase = .disconnected(error?.localizedDescription)
        }
    }

    nonisolated func rfbClient(_ client: RFBClient, didReceiveClipboard text: String) {
        MainActor.assumeIsolated {
            guard client === self.client, profile.copyRemoteClipboard, !text.isEmpty else { return }
            UIPasteboard.general.string = text
            showToast("Copied the remote clipboard to the iPad.")
        }
    }

    nonisolated func rfbClient(_ client: RFBClient, didRename name: String) {
        MainActor.assumeIsolated {
            guard client === self.client, !name.isEmpty else { return }
            desktopName = name
        }
    }

    nonisolated func rfbClient(_ client: RFBClient, didTrustCertificate sha256: String) {
        MainActor.assumeIsolated {
            onCertificateTrusted(sha256)
        }
    }
}
