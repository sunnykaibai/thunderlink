import AppKit
import ApplicationServices

enum SystemPermissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var inputMonitoringGranted: Bool {
        if #available(macOS 10.15, *) { return CGPreflightListenEventAccess() }
        return true
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) { return CGRequestListenEventAccess() }
        return true
    }

    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
