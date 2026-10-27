import Foundation

/// Which kind of VNC server we are talking to. PiKVM's kvmd-vnc only speaks
/// Tight-JPEG video and has a few special features (typing out the clipboard),
/// so we treat it differently from a generic VNC server.
enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case pikvm
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pikvm: return "PiKVM"
        case .generic: return "Other VNC server"
        }
    }
}

enum TransportSecurity: String, Codable, CaseIterable, Identifiable {
    /// VeNCrypt X509 TLS (PiKVM default). Credentials are encrypted.
    case tls
    /// No encryption. Only use on a network you trust.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tls: return "TLS (encrypted)"
        case .none: return "None (trusted LAN only)"
        }
    }
}

struct RFBConfig {
    var host: String
    var port: Int
    var username: String
    var password: String
    var serverKind: ServerKind
    var security: TransportSecurity
    /// 1...10, mapped to the JPEG quality pseudo-encodings.
    var jpegQuality: Int
    /// SHA-256 of the server's TLS certificate from a previous connection (trust on first use).
    var pinnedCertificateSHA256: String?
}

enum RFBError: LocalizedError, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case protocolError(String)
    case authenticationFailed(String)
    case unsupported(String)
    case certificateChanged(expected: String, actual: String)
    /// iPadOS refuses LAN connections until the user allows Local Network access.
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let why): return "Couldn't connect: \(why)"
        case .connectionClosed: return "The connection was closed."
        case .timeout: return "The server stopped responding."
        case .protocolError(let why): return "VNC protocol error: \(why)"
        case .authenticationFailed(let why): return "Login failed: \(why)"
        case .unsupported(let why): return why
        case .certificateChanged:
            return "The server's TLS certificate has changed since you last connected. If you regenerated the PiKVM certificate, reset the saved certificate in this host's settings."
        case .localNetworkDenied:
            return "iPadOS blocked the connection to your local network. If it just asked whether KVM Remote can find devices on your network, tap Allow, then Reconnect. Otherwise turn on Local Network for KVM Remote in Settings › Privacy & Security › Local Network."
        }
    }
}

extension RFBError {
    /// "Network is down" (ENETDOWN, errno 50) is how iPadOS reports a connection
    /// blocked by the Local Network permission.
    static func isNetworkDown(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 50 { return true }
        if ns.domain == "kCFErrorDomainCFNetwork" || ns.domain == "NSStreamSocketSSLErrorDomain",
           (ns.userInfo["_kCFStreamErrorCodeKey"] as? Int) == 50 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isNetworkDown(underlying) }
        return false
    }
}

/// Receives decoded framebuffer updates. Called on the RFB reader thread.
protocol RFBFramebufferSink: AnyObject {
    func rfbResize(width: Int, height: Int)
    func rfbJPEG(_ data: Data, x: Int, y: Int, width: Int, height: Int)
    func rfbFill(x: Int, y: Int, width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8)
    /// Pixels are 32bpp little-endian with R<<16 | G<<8 | B (i.e. bytes B, G, R, X).
    func rfbRaw(_ pixels: Data, x: Int, y: Int, width: Int, height: Int)
    func rfbCopy(srcX: Int, srcY: Int, x: Int, y: Int, width: Int, height: Int)
    func rfbUpdateComplete()
}

/// Connection lifecycle callbacks. Always delivered on the main queue.
protocol RFBClientDelegate: AnyObject {
    func rfbClientDidConnect(_ client: RFBClient, name: String, width: Int, height: Int)
    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?)
    func rfbClient(_ client: RFBClient, didReceiveClipboard text: String)
    func rfbClient(_ client: RFBClient, didRename name: String)
    func rfbClient(_ client: RFBClient, didTrustCertificate sha256: String)
}

enum RFBEncoding {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let tight: Int32 = 7
    static let desktopSize: Int32 = -223
    static let extendedDesktopSize: Int32 = -308
    static let desktopName: Int32 = -307
    static let qemuExtendedKeys: Int32 = -258
    static let qemuLEDState: Int32 = -261
    static let continuousUpdates: Int32 = -313

    /// JPEG quality pseudo-encodings: -32 (lowest) ... -23 (highest).
    static func jpegQuality(_ level: Int) -> Int32 {
        let clamped = max(1, min(10, level))
        return Int32(-32 + (clamped - 1))
    }
}

/// Pointer button bits in an RFB PointerEvent.
struct PointerButtons: OptionSet {
    let rawValue: UInt8
    static let left = PointerButtons(rawValue: 1 << 0)
    static let middle = PointerButtons(rawValue: 1 << 1)
    static let right = PointerButtons(rawValue: 1 << 2)
    static let wheelUp = PointerButtons(rawValue: 1 << 3)
    static let wheelDown = PointerButtons(rawValue: 1 << 4)
    static let wheelLeft = PointerButtons(rawValue: 1 << 5)
    static let wheelRight = PointerButtons(rawValue: 1 << 6)
}
