// End-to-end test of the app's protocol core against DevTools/mock_pikvm.py.
// Builds on Linux with the files in KVMRemote.swiftpm/Core; see DevTools/run_core_test.sh.
import Foundation

final class Recorder: RFBClientDelegate, RFBFramebufferSink {
    var connected = false
    var disconnected = false
    var disconnectError: Error?
    var name = ""
    var sizes: [String] = []
    var jpegLengths: [Int] = []
    var updates = 0

    func rfbClientDidConnect(_ client: RFBClient, name: String, width: Int, height: Int) {
        connected = true
        self.name = name
    }
    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?) {
        disconnected = true
        disconnectError = error
    }
    func rfbClient(_ client: RFBClient, didReceiveClipboard text: String) {}
    func rfbClient(_ client: RFBClient, didRename name: String) {}
    func rfbClient(_ client: RFBClient, didTrustCertificate sha256: String) {}

    func rfbResize(width: Int, height: Int) { sizes.append("\(width)x\(height)") }
    func rfbJPEG(_ data: Data, x: Int, y: Int, width: Int, height: Int) { jpegLengths.append(data.count) }
    func rfbFill(x: Int, y: Int, width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) {}
    func rfbRaw(_ pixels: Data, x: Int, y: Int, width: Int, height: Int) {}
    func rfbCopy(srcX: Int, srcY: Int, x: Int, y: Int, width: Int, height: Int) {}
    func rfbUpdateComplete() { updates += 1 }
}

func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return condition()
}

func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { exit(1) }
}

let port = Int(CommandLine.arguments.dropFirst().first ?? "5901")!
let password = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "admin"

let config = RFBConfig(host: "127.0.0.1", port: port, username: "admin", password: password,
                       serverKind: .pikvm, security: .none, jpegQuality: 8, pinnedCertificateSHA256: nil)
let recorder = Recorder()
let client = RFBClient(config: config)
client.delegate = recorder
client.sink = recorder
client.start()

if password != "admin" {
    check(spin { recorder.disconnected }, "disconnects on bad password")
    let message = recorder.disconnectError?.localizedDescription ?? ""
    check(message.contains("Invalid username or password"), "shows server's reason: \(message)")
    exit(0)
}

check(spin { recorder.connected }, "connects and authenticates")
check(recorder.name == "PiKVM", "reads desktop name")
check(spin { recorder.jpegLengths.count >= 3 }, "receives Tight JPEG frames")
check(recorder.jpegLengths.allSatisfy { $0 == 2 + 256 * 40 + 2 }, "JPEG lengths decoded correctly (\(recorder.jpegLengths))")
check(recorder.sizes == ["1920x1080", "1280x720"], "handles DesktopSize (\(recorder.sizes))")
check(spin { client.isUsingExtendedKeys }, "switches to QEMU extended key events")

let router = KeyInputRouter { usage, down in client.sendKey(usage: usage, down: down) }
var localActions: [KeyInputRouter.LocalAction] = []
router.onLocalAction = { localActions.append($0) }

// ⌘C as delivered by iPadOS, but with the C key-up missing (it can get swallowed while ⌘ is held).
router.hardwareKeyDown(HIDUsage.leftGUI)
router.hardwareKeyDown(HIDUsage.c)
router.hardwareKeyUp(HIDUsage.leftGUI)

// ⌘Space via the key-command path.
router.hardwareKeyDown(HIDUsage.leftGUI)
router.tapFromIPad(HIDUsage.space, modifiers: [HIDUsage.leftGUI])
router.hardwareKeyUp(HIDUsage.leftGUI)

// ⌃⌘V triggers the local "type iPad clipboard" action instead of going to the Mac.
router.hardwareKeyDown(HIDUsage.leftControl)
router.hardwareKeyDown(HIDUsage.leftGUI)
router.hardwareKeyDown(HIDUsage.v)
router.hardwareKeyUp(HIDUsage.v)
router.hardwareKeyUp(HIDUsage.leftGUI)
router.hardwareKeyUp(HIDUsage.leftControl)
check(localActions.count == 1, "⌃⌘V is intercepted locally")

// ⌥Tab, Tab, then let go of ⌥: the Mac sees ⌘ held through both Tabs.
router.hardwareKeyDown(HIDUsage.leftAlt)
router.hardwareKeyDown(HIDUsage.tab)
router.hardwareKeyUp(HIDUsage.tab)
router.hardwareKeyDown(HIDUsage.tab)
router.hardwareKeyUp(HIDUsage.tab)
router.hardwareKeyUp(HIDUsage.leftAlt)

// ⌥Space → ⌘Space.
router.hardwareKeyDown(HIDUsage.leftAlt)
router.hardwareKeyDown(HIDUsage.space)
router.hardwareKeyUp(HIDUsage.space)
router.hardwareKeyUp(HIDUsage.leftAlt)
check(router.down.isEmpty, "no keys left down on the remote")

client.typeViaPiKVM("héllo ✓")
router.type("Hi!")
client.sendPointer(x: 5000, y: 10, buttons: .left)
client.sendScroll(.wheelDown, held: [])

Thread.sleep(forTimeInterval: 0.5)
client.stop()
check(spin { recorder.disconnected }, "disconnects cleanly")
check(recorder.disconnectError == nil, "no error on user-initiated stop")
print("CLIENT DONE")
