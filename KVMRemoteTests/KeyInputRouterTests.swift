import XCTest
@testable import KVMRemote

final class KeyInputRouterTests: XCTestCase {
    private struct Key: Equatable, CustomStringConvertible {
        let usage: UInt16
        let down: Bool
        var description: String { String(format: "%02X%@", usage, down ? "↓" : "↑") }
    }

    private var sent: [Key] = []
    private var router: KeyInputRouter!

    override func setUp() {
        super.setUp()
        sent = []
        router = KeyInputRouter { [unowned self] usage, down in sent.append(Key(usage: usage, down: down)) }
    }

    private func down(_ u: UInt16) -> Key { Key(usage: u, down: true) }
    private func up(_ u: UInt16) -> Key { Key(usage: u, down: false) }

    func testCommandShortcutIsSentAsTapEvenIfKeyUpIsLost() {
        router.hardwareKeyDown(HIDUsage.leftGUI)
        router.hardwareKeyDown(HIDUsage.c)
        router.hardwareKeyUp(HIDUsage.leftGUI)   // iPadOS dropped the C key-up
        router.hardwareKeyUp(HIDUsage.c)         // ...or delivers it late

        XCTAssertEqual(sent, [down(HIDUsage.leftGUI), down(HIDUsage.c), up(HIDUsage.c), up(HIDUsage.leftGUI)])
        XCTAssertTrue(router.down.isEmpty)
    }

    func testPlainKeysAreHeldUntilReleased() {
        router.hardwareKeyDown(HIDUsage.a)
        XCTAssertEqual(sent, [down(HIDUsage.a)])
        router.hardwareKeyUp(HIDUsage.a)
        XCTAssertEqual(sent, [down(HIDUsage.a), up(HIDUsage.a)])
    }

    func testOptionTabHoldsCommandForTheAppSwitcher() {
        router.hardwareKeyDown(HIDUsage.leftAlt)
        router.hardwareKeyDown(HIDUsage.tab)
        router.hardwareKeyUp(HIDUsage.tab)
        router.hardwareKeyDown(HIDUsage.tab)
        router.hardwareKeyUp(HIDUsage.tab)
        router.hardwareKeyUp(HIDUsage.leftAlt)

        XCTAssertEqual(sent, [
            down(HIDUsage.leftAlt), up(HIDUsage.leftAlt), down(HIDUsage.leftGUI),
            down(HIDUsage.tab), up(HIDUsage.tab), down(HIDUsage.tab), up(HIDUsage.tab),
            up(HIDUsage.leftGUI),
        ])
    }

    func testOptionSpaceOpensSpotlight() {
        router.hardwareKeyDown(HIDUsage.leftAlt)
        router.hardwareKeyDown(HIDUsage.space)
        router.hardwareKeyUp(HIDUsage.space)
        router.hardwareKeyUp(HIDUsage.leftAlt)

        XCTAssertEqual(sent, [
            down(HIDUsage.leftAlt), up(HIDUsage.leftAlt),
            down(HIDUsage.leftGUI), down(HIDUsage.space), up(HIDUsage.space), up(HIDUsage.leftGUI),
        ])
    }

    func testControlCommandVTypesIPadClipboardWithoutReachingTheRemote() {
        var actions = 0
        router.onLocalAction = { _ in actions += 1 }
        router.hardwareKeyDown(HIDUsage.leftControl)
        router.hardwareKeyDown(HIDUsage.leftGUI)
        router.hardwareKeyDown(HIDUsage.v)
        router.hardwareKeyUp(HIDUsage.v)
        router.hardwareKeyUp(HIDUsage.leftGUI)
        router.hardwareKeyUp(HIDUsage.leftControl)

        XCTAssertEqual(actions, 1)
        XCTAssertFalse(sent.contains(down(HIDUsage.v)))
        XCTAssertTrue(router.down.isEmpty)
    }

    func testSwapCommandAndOption() {
        router.options.swapCommandAndOption = true
        router.hardwareKeyDown(HIDUsage.leftGUI)
        router.hardwareKeyUp(HIDUsage.leftGUI)
        XCTAssertEqual(sent, [down(HIDUsage.leftAlt), up(HIDUsage.leftAlt)])
    }

    func testTypingUsesShiftForCapitalsAndSymbols() {
        router.type("A!")
        XCTAssertEqual(sent, [
            down(HIDUsage.leftShift), down(HIDUsage.a), up(HIDUsage.a), up(HIDUsage.leftShift),
            down(HIDUsage.leftShift), down(0x1E), up(0x1E), up(HIDUsage.leftShift),
        ])
    }

    func testCharactersOutsideTheKeyMapAreHandedOff() {
        var unmapped: [String] = []
        router.onUnmappedText = { unmapped.append($0) }
        router.type("hé!")
        XCTAssertEqual(unmapped, ["é"])
    }

    func testLatchedCommandSurvivesHardwareReleaseAndReleaseAllClearsIt() {
        router.toggleLatch(HIDUsage.leftGUI)
        router.hardwareKeyDown(HIDUsage.leftGUI)
        router.hardwareKeyUp(HIDUsage.leftGUI)
        XCTAssertTrue(router.isCommandDown)

        router.releaseAll()
        XCTAssertFalse(router.isCommandDown)
        XCTAssertTrue(router.latched.isEmpty)
    }

    func testOneShotModifierAppliesToNextKeyOnly() {
        router.toggleOneShot(HIDUsage.leftGUI)
        router.tap(HIDUsage.c)
        router.tap(HIDUsage.v)
        XCTAssertEqual(sent, [
            down(HIDUsage.leftGUI), down(HIDUsage.c), up(HIDUsage.c), up(HIDUsage.leftGUI),
            down(HIDUsage.v), up(HIDUsage.v),
        ])
    }
}
