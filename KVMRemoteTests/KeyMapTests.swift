import XCTest
@testable import KVMRemote

final class KeyMapTests: XCTestCase {
    func testScancodesMatchPiKVMsTable() {
        // Values PiKVM's kvmd maps back to keys (AT set 1, E0-prefixed keys with the high bit set).
        XCTAssertEqual(KeyMap.info(for: HIDUsage.a)?.scancode, 0x1E)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.c)?.scancode, 0x2E)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.v)?.scancode, 0x2F)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.space)?.scancode, 0x39)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.leftGUI)?.scancode, 0xDB)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.rightGUI)?.scancode, 0xDC)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.leftAlt)?.scancode, 0x38)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.upArrow)?.scancode, 0xC8)
        XCTAssertEqual(KeyMap.info(for: HIDUsage.deleteForward)?.scancode, 0xD3)
    }

    func testEveryModifierIsMapped() {
        for usage in UInt16(0xE0)...0xE7 {
            XCTAssertNotNil(KeyMap.info(for: usage), "modifier \(usage) missing")
        }
    }

    func testCharacterLookup() {
        XCTAssertEqual(KeyMap.usage(for: "a")?.usage, HIDUsage.a)
        XCTAssertEqual(KeyMap.usage(for: "a")?.shift, false)
        XCTAssertEqual(KeyMap.usage(for: "A")?.shift, true)
        XCTAssertEqual(KeyMap.usage(for: "?")?.usage, 0x38)
        XCTAssertEqual(KeyMap.usage(for: "?")?.shift, true)
        XCTAssertEqual(KeyMap.usage(for: "\n")?.usage, HIDUsage.returnKey)
        XCTAssertNil(KeyMap.usage(for: "é"))
    }

    func testJPEGQualityEncodings() {
        XCTAssertEqual(RFBEncoding.jpegQuality(1), -32)
        XCTAssertEqual(RFBEncoding.jpegQuality(10), -23)
        XCTAssertEqual(RFBEncoding.jpegQuality(99), -23)
    }
}
