import AppKit
import Carbon.HIToolbox
import Foundation

/// A user-recorded global keyboard shortcut: a virtual key code plus its
/// Cocoa modifier flags. Persisted to `UserDefaults` and converted to the
/// Carbon modifier mask on demand for `RegisterEventHotKey`.
struct KeyboardShortcut: Equatable {
    let keyCode: UInt16
    /// Stored as the device-independent subset of `NSEvent.ModifierFlags`.
    let modifierFlags: NSEvent.ModifierFlags

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    static func == (lhs: KeyboardShortcut, rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifierFlags == rhs.modifierFlags
    }

    /// At least one of command/option/control must be present for a usable
    /// global hotkey (shift alone is too easy to trigger by accident).
    var hasRequiredModifier: Bool {
        !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifierFlags.contains(.command) { mask |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { mask |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { mask |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Human-readable form, e.g. `⌃⌥N`.
    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    // MARK: - Persistence

    private static let keyCodeKey = "hotkey.keyCode"
    private static let modifiersKey = "hotkey.modifiers"

    /// The currently-saved shortcut, or `nil` if the user has none / cleared it.
    static func load(from defaults: UserDefaults = .standard) -> KeyboardShortcut? {
        guard defaults.object(forKey: keyCodeKey) != nil else { return nil }
        let code = UInt16(truncatingIfNeeded: defaults.integer(forKey: keyCodeKey))
        let mods = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: defaults.integer(forKey: modifiersKey)))
        return KeyboardShortcut(keyCode: code, modifierFlags: mods)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(bitPattern: modifierFlags.rawValue), forKey: Self.modifiersKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyCodeKey)
        defaults.removeObject(forKey: modifiersKey)
    }

    // MARK: - Key naming

    /// Readable label for a virtual key code. Covers letters, digits, and the
    /// common special keys; unknown codes fall back to `Key NN`.
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let char = ansiKeyNames[Int(keyCode)] { return char }
        return "Key \(keyCode)"
    }

    private static let ansiKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Help: "?⃝", kVK_Home: "↖",
        kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Wraps a single global hotkey via Carbon's `RegisterEventHotKey`, which
/// fires app-wide without requiring Accessibility permissions.
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerInstalled = false
    private let signature: OSType = 0x4E474B4D // 'NGKM'
    private let hotKeyID: UInt32 = 1

    private init() {}

    /// Apply the saved shortcut (or clear the hotkey if there is none).
    func apply(_ shortcut: KeyboardShortcut?, handler: @escaping () -> Void) {
        unregister()
        guard let shortcut = shortcut, shortcut.hasRequiredModifier else { return }
        self.handler = handler
        installEventHandlerIfNeeded()

        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        handler = nil
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if hkID.signature == manager.signature && hkID.id == manager.hotKeyID {
                    DispatchQueue.main.async { manager.handler?() }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )
    }
}
