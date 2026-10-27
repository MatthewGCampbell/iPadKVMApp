import UIKit

/// Shows the remote screen and turns iPad keyboard, trackpad, mouse and touch input
/// into VNC events.
///
/// Keyboard: while this view is first responder it receives every hardware key as
/// a `UIPress` with its USB HID usage, including ⌘, ⌥, ⌃ and ⇧ on their own, so
/// ⌘C, ⌘V, ⌘Z… reach the remote exactly as typed. Shortcuts iPadOS reserves for
/// itself (⌘Space, ⌘H, ⇧⌘4…) are claimed with priority key commands.
final class RemoteScreenView: UIView, UIPointerInteractionDelegate {
    weak var session: SessionController?

    var framebufferSize: CGSize = .zero {
        didSet { if framebufferSize != oldValue { setNeedsLayout() } }
    }

    private let screenLayer = CALayer()
    private let softKeyboard = SoftKeyboardField()
    private var dragStart: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        screenLayer.contentsGravity = .resize
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        screenLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(screenLayer)

        softKeyboard.screen = self
        addSubview(softKeyboard)

        setUpGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Display

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = image
        CATransaction.commit()
    }

    /// Where the remote screen is drawn: aspect-fit, centred.
    var screenRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return bounds }
        return Self.aspectFit(framebufferSize, in: bounds)
    }

    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.frame = screenRect
        CATransaction.commit()
        softKeyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// View point → remote pixel.
    private func remotePoint(_ point: CGPoint) -> CGPoint {
        let rect = screenRect
        guard rect.width > 0, rect.height > 0, framebufferSize.width > 0 else { return .zero }
        let x = (point.x - rect.minX) / rect.width * framebufferSize.width
        let y = (point.y - rect.minY) / rect.height * framebufferSize.height
        return CGPoint(x: min(max(0, x), framebufferSize.width - 1),
                       y: min(max(0, y), framebufferSize.height - 1))
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { true }
    override var canBecomeFocused: Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { focusKeyboard() }
    }

    func focusKeyboard() {
        if session?.softKeyboardVisible == true {
            softKeyboard.becomeFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    func setSoftKeyboardVisible(_ visible: Bool) {
        if visible {
            softKeyboard.becomeFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    func modifierStateChanged() {
        softKeyboard.refreshAccessory(held: session?.heldModifiers ?? [])
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Sends key presses to the remote; returns the presses that weren't keys.
    func handlePresses(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        guard let keys = session?.keys else { return presses }
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.keyCode.rawValue > 0, key.keyCode.rawValue <= 0xFFFF else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt16(key.keyCode.rawValue)
            if down { keys.hardwareKeyDown(usage) } else { keys.hardwareKeyUp(usage) }
        }
        return unhandled
    }

    /// Shortcuts iPadOS would otherwise act on itself. `wantsPriorityOverSystemBehavior`
    /// asks for them first; iPadOS still keeps a few (⌘Tab, Globe shortcuts), which is
    /// why the toolbar offers them too.
    static let systemShortcutOverrides: [UIKeyCommand] = {
        let combos: [(String, UIKeyModifierFlags)] = [
            (" ", .command), (" ", [.command, .alternate]), (" ", [.command, .control]), (" ", .control),
            ("\t", .command), ("\t", [.command, .shift]), ("`", .command),
            ("h", .command), ("h", [.command, .alternate]), ("q", .command), ("w", .command),
            ("n", .command), ("n", [.command, .shift]), ("t", .command), ("m", .command),
            ("d", [.command, .alternate]), ("f", [.command, .control]), ("q", [.command, .control]),
            ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]),
            ("/", .command), (",", .command), (UIKeyCommand.inputEscape, [.command, .alternate]),
        ]
        return combos.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags,
                                       action: #selector(RemoteScreenView.sendSystemShortcut(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }()

    override var keyCommands: [UIKeyCommand]? { Self.systemShortcutOverrides }

    @objc func sendSystemShortcut(_ command: UIKeyCommand) {
        guard let keys = session?.keys, let input = command.input else { return }
        let usage: UInt16
        if input == UIKeyCommand.inputEscape {
            usage = HIDUsage.escape
        } else if let character = input.first, let mapped = KeyMap.usage(for: character) {
            usage = mapped.usage
        } else {
            return
        }
        var modifiers: [UInt16] = []
        if command.modifierFlags.contains(.control) { modifiers.append(HIDUsage.leftControl) }
        if command.modifierFlags.contains(.alternate) { modifiers.append(HIDUsage.leftAlt) }
        if command.modifierFlags.contains(.shift) { modifiers.append(HIDUsage.leftShift) }
        if command.modifierFlags.contains(.command) { modifiers.append(HIDUsage.leftGUI) }
        keys.tapFromIPad(usage, modifiers: modifiers)
    }

    // Keep ⌘C, ⌘V, ⌘Z, ⌘A… away from the iPad's own Edit menu so they reach the remote.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(sendSystemShortcut(_:))
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        action == #selector(sendSystemShortcut(_:)) ? self : nil
    }

    // MARK: Pointer & touch

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The remote computer draws its own cursor into the video.
        .hidden()
    }

    private func setUpGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)

        let click = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(click)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryClick)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerScroll)

        // Trackpad two-finger scrolling and mouse wheels (no touches involved).
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        addGestureRecognizer(wheel)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        session?.pointerMoved(to: remotePoint(g.location(in: self)))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        focusKeyboard()
        session?.click(at: remotePoint(g.location(in: self)), button: .left)
    }

    @objc private func rightClicked(_ g: UITapGestureRecognizer) {
        session?.click(at: remotePoint(g.location(in: self)), button: .right)
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        let location = g.location(in: self)
        switch g.state {
        case .began:
            // The pan only begins after some movement; press where the finger first landed.
            let translation = g.translation(in: self)
            let start = remotePoint(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            session.pointerMoved(to: start)
            session.pointer(at: start, button: .left, down: true)
            session.pointerMoved(to: remotePoint(location))
        case .changed:
            session.pointerMoved(to: remotePoint(location))
        default:
            session.pointer(at: remotePoint(location), button: .left, down: false)
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        switch g.state {
        case .began, .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            if g.numberOfTouches == 0 {
                // Trackpad: keep the remote pointer where the iPad pointer is.
                session.pointerMoved(to: remotePoint(g.location(in: self)))
            }
            session.scroll(by: t)
        default:
            session.endScroll()
        }
    }
}

/// Invisible text input that brings up the on-screen keyboard, with a bar of
/// keys the iPad keyboard lacks (Esc, ⌘, ⌥, ⌃, arrows).
final class SoftKeyboardField: UIView, UIKeyInput {
    weak var screen: RemoteScreenView?
    private lazy var accessory = makeAccessory()
    private var modifierButtons: [UInt16: UIButton] = [:]

    // UITextInputTraits: send exactly what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        screen?.session?.typeFromSoftKeyboard(text)
    }

    func deleteBackward() {
        screen?.session?.keys.tap(HIDUsage.backspace)
    }

    // A hardware keyboard can still be used while this has focus.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = screen?.handlePresses(presses, down: true) ?? presses
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = screen?.handlePresses(presses, down: false) ?? presses
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = screen?.handlePresses(presses, down: false) ?? presses
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    override var keyCommands: [UIKeyCommand]? { RemoteScreenView.systemShortcutOverrides }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        screen?.target(forAction: action, withSender: sender)
    }

    func refreshAccessory(held: Set<UInt16>) {
        for (usage, button) in modifierButtons {
            var config = button.configuration
            config?.baseBackgroundColor = held.contains(usage) ? .tintColor : .secondarySystemFill
            config?.baseForegroundColor = held.contains(usage) ? .white : .label
            button.configuration = config
        }
    }

    private func makeAccessory() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 100, height: 48), inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
        ])

        func key(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.baseBackgroundColor = .secondarySystemFill
            config.baseForegroundColor = .label
            config.cornerStyle = .medium
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            stack.addArrangedSubview(button)
            return button
        }
        let tap: (UInt16) -> () -> Void = { usage in { [weak self] in self?.screen?.session?.keys.tap(usage) } }

        _ = key("esc", tap(HIDUsage.escape))
        _ = key("tab", tap(HIDUsage.tab))
        for (title, usage) in [("⌘", HIDUsage.leftGUI), ("⌥", HIDUsage.leftAlt),
                               ("⌃", HIDUsage.leftControl), ("⇧", HIDUsage.leftShift)] {
            modifierButtons[usage] = key(title) { [weak self] in self?.screen?.session?.keys.toggleOneShot(usage) }
        }
        _ = key("←", tap(HIDUsage.leftArrow))
        _ = key("↑", tap(HIDUsage.upArrow))
        _ = key("↓", tap(HIDUsage.downArrow))
        _ = key("→", tap(HIDUsage.rightArrow))
        _ = key("⌦", tap(HIDUsage.deleteForward))
        let hide = key("⌨︎↓") { [weak self] in self?.screen?.session?.softKeyboardVisible = false }
        hide.accessibilityLabel = "Hide keyboard"
        return bar
    }
}
