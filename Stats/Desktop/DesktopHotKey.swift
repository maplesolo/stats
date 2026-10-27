import AppKit
import Carbon

struct DesktopShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += Self.keyLabel(keyCode)
        return text
    }

    private static func keyLabel(_ keyCode: UInt16) -> String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[keyCode] { return name }
        let ansi: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
        ]
        return ansi[keyCode] ?? "键\(keyCode)"
    }
}

enum HotKeyCenter {
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var handlerInstalled = false

    /// Returns an error message when the system rejects the shortcut.
    static func update(_ shortcut: DesktopShortcut?) -> String? {
        installHandlerIfNeeded()
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let shortcut, shortcut.carbonModifiers != 0 else { return nil }
        var ref: EventHotKeyRef?
        let identity = EventHotKeyID(signature: fourChar("STDK"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identity,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return "这个快捷键已被占用"
        }
        hotKey = ref
        return nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyPressed,
            1,
            &spec,
            nil,
            &handler
        )
        handlerInstalled = status == noErr
    }
}

final class ShortcutCaptureButton: NSButton {
    var onCapture: ((DesktopShortcut) -> Void)?
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleCapture)
        title = "点击设置"
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(_ shortcut: DesktopShortcut?) {
        guard monitor == nil else { return }
        title = shortcut?.display ?? "点击设置"
    }

    @objc private func toggleCapture() {
        if monitor != nil {
            endCapture(restoreHotKey: true)
            return
        }
        DesktopWallpaper.shared.suspendHotKey()
        title = "请按键"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            endCapture(restoreHotKey: true)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }
        let shortcut = DesktopShortcut(keyCode: event.keyCode, modifiers: flags.rawValue)
        endCapture(restoreHotKey: false)
        onCapture?(shortcut)
    }

    private func endCapture(restoreHotKey: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if restoreHotKey {
            DesktopWallpaper.shared.restoreHotKey()
        }
    }
}

private func hotKeyPressed(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            DesktopWallpaper.shared.toggleFromHotKey()
        }
    }
    return noErr
}

private func fourChar(_ string: String) -> OSType {
    string.utf8.prefix(4).reduce(OSType(0)) { ($0 << 8) + OSType($1) }
}
