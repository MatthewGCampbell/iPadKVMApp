import Foundation

/// A VNC (RFB 3.8) client tuned for PiKVM's kvmd-vnc, but usable with other servers.
///
/// The protocol runs on its own thread with blocking reads. Input methods
/// (`sendKey`, `sendPointer`, …) are safe to call from any thread.
final class RFBClient {
    weak var delegate: RFBClientDelegate?
    weak var sink: RFBFramebufferSink?

    let config: RFBConfig

    private var transport: RFBTransport?
    private let lock = NSLock()
    private var stopped = false
    private var connected = false
    private var extendedKeysSupported = false
    private var shiftDown = false
    private var lastPointer: (x: Int, y: Int) = (0, 0)
    private(set) var width = 0
    private(set) var height = 0
    private(set) var name = ""

    init(config: RFBConfig) {
        self.config = config
    }

    var isUsingExtendedKeys: Bool {
        lock.lock(); defer { lock.unlock() }
        return extendedKeysSupported
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "VNC protocol"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = transport
        lock.unlock()
        t?.close()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: - Protocol thread

    private func run() {
        do {
            let t = try makeTransport()
            lock.lock()
            transport = t
            let alreadyStopped = stopped
            lock.unlock()
            if alreadyStopped { throw RFBError.connectionClosed }

            try t.connect(host: config.host, port: config.port, timeout: 10)
            t.setReadTimeout(15)
            try handshake(t)
            t.setReadTimeout(nil)

            lock.lock()
            connected = true
            lock.unlock()

            sendInitialMessages()
            let (n, w, h) = (name, width, height)
            DispatchQueue.main.async { self.delegate?.rfbClientDidConnect(self, name: n, width: w, height: h) }

            try messageLoop(t)
        } catch {
            finish(isStopped ? nil : error)
            return
        }
        finish(nil)
    }

    private func makeTransport() throws -> RFBTransport {
        switch config.security {
        case .none:
            return SocketTransport()
        case .tls:
            #if canImport(Darwin)
            return StreamTransport()
            #else
            return SocketTransport()
            #endif
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        connected = false
        let t = transport
        transport = nil
        lock.unlock()
        t?.close()
        DispatchQueue.main.async { self.delegate?.rfbClient(self, didDisconnectWith: error) }
    }

    // MARK: Reading helpers

    private func read(_ t: RFBTransport, _ count: Int) throws -> Data { try t.read(exactly: count) }

    private func readU8(_ t: RFBTransport) throws -> UInt8 { try t.read(exactly: 1)[0] }

    private func readU16(_ t: RFBTransport) throws -> UInt16 {
        let d = try t.read(exactly: 2)
        return UInt16(d[0]) << 8 | UInt16(d[1])
    }

    private func readU32(_ t: RFBTransport) throws -> UInt32 {
        let d = try t.read(exactly: 4)
        return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
    }

    private func readS32(_ t: RFBTransport) throws -> Int32 { Int32(bitPattern: try readU32(t)) }

    private func readString(_ t: RFBTransport, maxLength: Int = 1 << 20) throws -> String {
        let length = Int(try readU32(t))
        guard length <= maxLength else { throw RFBError.protocolError("String too long (\(length) bytes)") }
        let data = try read(t, length)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Handshake

    private func handshake(_ t: RFBTransport) throws {
        let version = try read(t, 12)
        guard let versionString = String(data: version, encoding: .ascii), versionString.hasPrefix("RFB ") else {
            throw RFBError.protocolError("This doesn't look like a VNC server.")
        }
        let minor = Int(versionString.dropFirst(8).prefix(3)) ?? 0
        guard minor >= 7 else {
            throw RFBError.unsupported("This VNC server only speaks the old RFB 3.\(minor) protocol.")
        }
        t.send(Data("RFB 003.008\n".utf8))

        let typeCount = Int(try readU8(t))
        if typeCount == 0 {
            throw RFBError.connectionFailed(try readString(t))
        }
        let types = Set(try read(t, typeCount))

        let haveUser = !config.username.isEmpty
        if types.contains(19) && (haveUser || config.security == .tls) {
            t.send(Data([19]))
            try authenticateVeNCrypt(t)
        } else if types.contains(2) && !config.password.isEmpty {
            t.send(Data([2]))
            try authenticateVNC(t)
            try readSecurityResult(t)
        } else if types.contains(1) {
            t.send(Data([1]))
            try readSecurityResult(t)
        } else if types.contains(19) {
            t.send(Data([19]))
            try authenticateVeNCrypt(t)
        } else {
            throw RFBError.unsupported("The server requires an authentication method this app doesn't support (types: \(types.sorted())).")
        }

        // ClientInit: ask to share the desktop with other viewers.
        t.send(Data([1]))

        // ServerInit
        width = Int(try readU16(t))
        height = Int(try readU16(t))
        _ = try read(t, 16)  // Server pixel format; we override it below.
        name = try readString(t)
        sink?.rfbResize(width: width, height: height)
    }

    private func authenticateVeNCrypt(_ t: RFBTransport) throws {
        let major = try readU8(t)
        let minor = try readU8(t)
        guard major == 0 && minor >= 2 else {
            throw RFBError.unsupported("Unsupported VeNCrypt version \(major).\(minor).")
        }
        t.send(Data([0, 2]))
        guard try readU8(t) == 0 else { throw RFBError.protocolError("The server rejected VeNCrypt 0.2.") }

        let count = Int(try readU8(t))
        var subtypes: [UInt32] = []
        for _ in 0..<count { subtypes.append(try readU32(t)) }

        // 262 X509Plain, 261 X509VNC, 260 X509None, 256 Plain, 2 VNC, 1 None.
        // (Anonymous-TLS variants 257-259 need ciphers iOS doesn't offer.)
        let preference: [UInt32]
        switch config.security {
        case .tls: preference = [262, 261, 260]
        case .none: preference = config.username.isEmpty ? [2, 256, 1] : [256, 2, 1]
        }
        guard let chosen = preference.first(where: subtypes.contains) else {
            if config.security == .tls {
                throw RFBError.unsupported("The server doesn't offer certificate-based TLS. Set Encryption to “None” for this host, or configure an X.509 certificate for VNC on the server.")
            }
            throw RFBError.unsupported("The server requires TLS. Set Encryption to “TLS” for this host.")
        }
        var choice = Data()
        choice.appendU32(chosen)
        t.send(choice)

        if chosen >= 260 {
            guard try readU8(t) == 1 else { throw RFBError.protocolError("The server refused to start TLS.") }
            try t.startTLS()
            // Verify the certificate before sending the password if the handshake is already done.
            if let fingerprint = t.peerCertificateSHA256(waitingUpTo: 2) {
                try verifyCertificate(fingerprint)
            }
        }

        switch chosen {
        case 262, 256:
            let user = Data(config.username.utf8)
            let pass = Data(config.password.utf8)
            var msg = Data()
            msg.appendU32(UInt32(user.count))
            msg.appendU32(UInt32(pass.count))
            msg.append(user)
            msg.append(pass)
            t.send(msg)
        case 261, 2:
            try authenticateVNC(t)
        default:
            break
        }
        try readSecurityResult(t)

        if chosen >= 260, let fingerprint = t.peerCertificateSHA256(waitingUpTo: 5) {
            try verifyCertificate(fingerprint)
            DispatchQueue.main.async { self.delegate?.rfbClient(self, didTrustCertificate: fingerprint) }
        }
    }

    private func verifyCertificate(_ fingerprint: String) throws {
        if let pinned = config.pinnedCertificateSHA256, !pinned.isEmpty, pinned != fingerprint {
            throw RFBError.certificateChanged(expected: pinned, actual: fingerprint)
        }
    }

    private func authenticateVNC(_ t: RFBTransport) throws {
        let challenge = try read(t, 16)
        guard let response = VNCAuth.response(challenge: challenge, password: config.password) else {
            throw RFBError.unsupported("VNC password authentication isn't available on this platform.")
        }
        t.send(response)
    }

    private func readSecurityResult(_ t: RFBTransport) throws {
        let result = try readU32(t)
        guard result == 0 else {
            let reason = (try? readString(t)) ?? ""
            throw RFBError.authenticationFailed(reason.isEmpty ? "Wrong username or password." : reason)
        }
    }

    // MARK: Main loop

    private func sendInitialMessages() {
        // 32bpp little-endian true colour, R<<16 G<<8 B: matches a BGRA CGBitmapContext.
        var pf = Data([0, 0, 0, 0])
        pf.append(contentsOf: [32, 24, 0, 1])
        pf.appendU16(255); pf.appendU16(255); pf.appendU16(255)
        pf.append(contentsOf: [16, 8, 0])
        pf.appendPadding(3)
        send(pf)

        var encodings: [Int32]
        switch config.serverKind {
        case .pikvm:
            encodings = [RFBEncoding.tight, RFBEncoding.jpegQuality(config.jpegQuality),
                         RFBEncoding.copyRect, RFBEncoding.raw]
        case .generic:
            encodings = [RFBEncoding.copyRect, RFBEncoding.raw]
        }
        encodings += [RFBEncoding.desktopSize, RFBEncoding.desktopName, RFBEncoding.qemuExtendedKeys]

        var msg = Data([2, 0])
        msg.appendU16(UInt16(encodings.count))
        for e in encodings { msg.appendS32(e) }
        send(msg)

        requestUpdate(incremental: false)
    }

    private func messageLoop(_ t: RFBTransport) throws {
        while !isStopped {
            let type = try readU8(t)
            switch type {
            case 0:
                try readFramebufferUpdate(t)
            case 1:  // SetColourMapEntries (not used with true colour, but skip safely)
                _ = try read(t, 3)
                let count = Int(try readU16(t))
                _ = try read(t, count * 6)
            case 2:  // Bell
                break
            case 3:  // ServerCutText
                _ = try read(t, 3)
                let text = try readString(t, maxLength: 8 << 20)
                DispatchQueue.main.async { self.delegate?.rfbClient(self, didReceiveClipboard: text) }
            case 150:  // EndOfContinuousUpdates
                break
            default:
                throw RFBError.protocolError("Unknown server message \(type).")
            }
        }
    }

    private func readFramebufferUpdate(_ t: RFBTransport) throws {
        _ = try read(t, 1)
        let rects = Int(try readU16(t))
        for _ in 0..<rects {
            let x = Int(try readU16(t))
            let y = Int(try readU16(t))
            let w = Int(try readU16(t))
            let h = Int(try readU16(t))
            let encoding = try readS32(t)

            switch encoding {
            case RFBEncoding.raw:
                let pixels = try read(t, w * h * 4)
                sink?.rfbRaw(pixels, x: x, y: y, width: w, height: h)
            case RFBEncoding.copyRect:
                let sx = Int(try readU16(t))
                let sy = Int(try readU16(t))
                sink?.rfbCopy(srcX: sx, srcY: sy, x: x, y: y, width: w, height: h)
            case RFBEncoding.tight:
                try readTight(t, x: x, y: y, width: w, height: h)
            case RFBEncoding.desktopSize:
                resize(width: w, height: h)
            case RFBEncoding.extendedDesktopSize:
                let screens = Int(try readU8(t))
                _ = try read(t, 3 + screens * 16)
                resize(width: w, height: h)
            case RFBEncoding.desktopName:
                let newName = try readString(t)
                name = newName
                DispatchQueue.main.async { self.delegate?.rfbClient(self, didRename: newName) }
            case RFBEncoding.qemuExtendedKeys:
                lock.lock()
                extendedKeysSupported = true
                lock.unlock()
            case RFBEncoding.qemuLEDState:
                _ = try read(t, 1)
            default:
                throw RFBError.protocolError("Unsupported encoding \(encoding).")
            }
        }
        sink?.rfbUpdateComplete()
        requestUpdate(incremental: true)
    }

    private func resize(width w: Int, height h: Int) {
        width = w
        height = h
        sink?.rfbResize(width: w, height: h)
    }

    private func readTight(_ t: RFBTransport, x: Int, y: Int, width w: Int, height h: Int) throws {
        let control = try readU8(t)
        switch control >> 4 {
        case 0x08:  // Fill: one TPIXEL (R, G, B for our 32/24 pixel format)
            let p = try read(t, 3)
            sink?.rfbFill(x: x, y: y, width: w, height: h, red: p[0], green: p[1], blue: p[2])
        case 0x09:  // JPEG
            let length = try readCompactLength(t)
            let jpeg = try read(t, length)
            sink?.rfbJPEG(jpeg, x: x, y: y, width: w, height: h)
        default:
            throw RFBError.unsupported("The server sent zlib-compressed Tight data. Set Server Type to “Other VNC server” for this host.")
        }
    }

    private func readCompactLength(_ t: RFBTransport) throws -> Int {
        var b = Int(try readU8(t))
        var length = b & 0x7F
        if b & 0x80 != 0 {
            b = Int(try readU8(t))
            length |= (b & 0x7F) << 7
            if b & 0x80 != 0 {
                b = Int(try readU8(t))
                length |= b << 14
            }
        }
        return length
    }

    // MARK: - Sending (any thread)

    private func send(_ data: Data) {
        lock.lock()
        let t = connected ? transport : nil
        lock.unlock()
        t?.send(data)
    }

    func requestUpdate(incremental: Bool) {
        var msg = Data([3, incremental ? 1 : 0])
        msg.appendU16(0); msg.appendU16(0)
        msg.appendU16(UInt16(clamping: width)); msg.appendU16(UInt16(clamping: height))
        send(msg)
    }

    /// Press or release a key identified by its USB HID usage (what iPadOS reports).
    func sendKey(usage: UInt16, down: Bool) {
        guard let info = KeyMap.info(for: usage) else { return }
        lock.lock()
        if usage == HIDUsage.leftShift || usage == HIDUsage.rightShift { shiftDown = down }
        let ext = extendedKeysSupported
        let shifted = shiftDown
        lock.unlock()

        if ext {
            // QEMU extended key event: the raw scancode, so the remote sees the exact
            // physical key (⌘C stays ⌘C regardless of keyboard layout).
            var msg = Data([255, 0])
            msg.appendU16(down ? 1 : 0)
            msg.appendU32(info.keysym)
            msg.appendU32(UInt32(info.scancode))
            send(msg)
        } else {
            sendKeysym(shifted ? (info.shiftedKeysym ?? info.keysym) : info.keysym, down: down)
        }
    }

    func sendKeysym(_ keysym: UInt32, down: Bool) {
        var msg = Data([4, down ? 1 : 0, 0, 0])
        msg.appendU32(keysym)
        send(msg)
    }

    /// Absolute pointer position in framebuffer pixels plus the full button state.
    func sendPointer(x: Int, y: Int, buttons: PointerButtons) {
        let cx = max(0, min(width - 1, x))
        let cy = max(0, min(height - 1, y))
        lock.lock()
        lastPointer = (cx, cy)
        lock.unlock()
        var msg = Data([5, buttons.rawValue])
        msg.appendU16(UInt16(clamping: cx))
        msg.appendU16(UInt16(clamping: cy))
        send(msg)
    }

    /// One wheel "click" at the last pointer position.
    func sendScroll(_ direction: PointerButtons, held: PointerButtons) {
        lock.lock()
        let (x, y) = lastPointer
        lock.unlock()
        sendPointer(x: x, y: y, buttons: held.union(direction))
        sendPointer(x: x, y: y, buttons: held)
    }

    /// ClientCutText. PiKVM decodes it as UTF-8; the RFB spec says Latin-1.
    func sendClipboard(_ text: String) {
        let data: Data
        switch config.serverKind {
        case .pikvm: data = Data(text.utf8)
        case .generic: data = text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
        }
        var msg = Data([6, 0, 0, 0])
        msg.appendU32(UInt32(data.count))
        msg.append(data)
        send(msg)
    }

    /// Makes PiKVM type `text` on the remote computer.
    ///
    /// kvmd-vnc stores the last ClientCutText and types it out when it sees its
    /// "magic" sequence: Left Alt tapped twice, then P. The P is swallowed by
    /// PiKVM; the Mac only sees two harmless Option taps.
    func typeViaPiKVM(_ text: String) {
        sendClipboard(text)
        for _ in 0..<2 {
            sendKey(usage: HIDUsage.leftAlt, down: true)
            sendKey(usage: HIDUsage.leftAlt, down: false)
        }
        sendKey(usage: HIDUsage.p, down: true)
        sendKey(usage: HIDUsage.p, down: false)
    }
}
