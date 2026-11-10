import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// Keys and text sent to the front app.  Like scrolling, this needs the Accessibility
/// permission.
public enum KeySender {
    public static let left: CGKeyCode = 123, right: CGKeyCode = 124, enter: CGKeyCode = 36

    /// IOKit's NX_KEYTYPE_* values.
    public enum Media: Int32 {
        case brightnessUp = 2, brightnessDown = 3, next = 17, previous = 18
    }

    public static var trusted: Bool { AXIsProcessTrusted() }
    @MainActor public static func requestTrust() { PageScroller.requestTrust() }

    // as the keyboard itself would
    private static let source = CGEventSource(stateID: .hidSystemState)

    public static func press(_ code: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    public static func press(_ key: Media) {
        for down in [true, false] {
            let data = Int(key.rawValue) << 16 | (down ? 0xA : 0xB) << 8
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: data, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Wake the display as a key press would, then type at a typist's pace (the lock screen
    /// drops characters sent all at once), optionally with Return.  Off the main thread.
    /// Stops the moment `allowed` turns false: the screen can unlock while this waits or types,
    /// and what remains would land in the focused window.
    public static func typeAwake(_ text: String, enter submit: Bool, while allowed: @escaping @Sendable () -> Bool = { true }) {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Touch SD" as CFString, kIOPMUserActiveLocal, &id)
        Thread.detachNewThread {
            usleep(600_000)
            for c in text.unicodeScalars {
                guard allowed() else { return }
                send(c)
                usleep(25_000)
            }
            if submit {
                usleep(60_000)
                if allowed() { press(enter) }
            }
        }
    }

    /// One character, whole: a pair of UTF-16 units must go in one event.
    private static func send(_ c: Unicode.Scalar) {
        if c == "\n" || c == "\r" {
            press(enter)
            return
        }
        var units = Array(String(c).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Type text into whatever has the keyboard focus.
    public static func type(_ text: String) {
        for c in text.unicodeScalars { send(c) }
    }
}
