import CoreGraphics
import Testing
@testable import ThunderLink

struct KeyboardCaptureTests {
    @Test func installedTapMustReceiveBothKeyTransitionsAndModifierChanges() {
        // The first two values were reported for the primary HID tap before and
        // after keyDown and keyUp were removed by macOS.
        #expect(InputController.capturesKeyboard(0x0e401cfe))
        #expect(!InputController.capturesKeyboard(0x0e4010fe))
        #expect(!InputController.capturesKeyboard(0x0e4014fe))
        #expect(!InputController.capturesKeyboard(0x0e4018fe))
        #expect(!InputController.capturesKeyboard(0x1000))
    }
}
