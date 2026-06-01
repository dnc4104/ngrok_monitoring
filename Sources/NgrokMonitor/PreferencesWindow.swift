import AppKit
import Carbon.HIToolbox

/// A button that records a keyboard shortcut: click to begin, then press the
/// desired key combination. Escape cancels, Delete/Backspace clears.
final class ShortcutRecorderView: NSButton {
    /// Called whenever the shortcut changes (capture or clear). `nil` means cleared.
    var onChange: ((KeyboardShortcut?) -> Void)?

    private(set) var shortcut: KeyboardShortcut?
    private var recording = false {
        didSet { updateAppearance() }
    }

    init(shortcut: KeyboardShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .roundRect
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .none
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { recording }

    @objc private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    private func updateAppearance() {
        if recording {
            title = "Type shortcut… (⎋ to cancel)"
        } else if let shortcut = shortcut {
            title = shortcut.displayString
        } else {
            title = "Click to record"
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            endRecording()
            return
        case kVK_Delete, kVK_ForwardDelete:
            shortcut = nil
            endRecording()
            onChange?(nil)
            return
        default:
            break
        }

        let candidate = KeyboardShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        guard candidate.hasRequiredModifier else {
            NSSound.beep() // needs ⌘/⌥/⌃ — keep recording
            return
        }
        shortcut = candidate
        endRecording()
        onChange?(candidate)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    /// Clear the recorded shortcut and notify via `onChange`.
    func clear() {
        recording = false
        shortcut = nil
        updateAppearance()
        onChange?(nil)
    }
}

/// Small Preferences window hosting the shortcut recorder.
final class PreferencesWindowController: NSWindowController {
    /// Fired when the user changes the shortcut so the app can re-register it.
    var onShortcutChange: ((KeyboardShortcut?) -> Void)?

    private var recorder: ShortcutRecorderView!

    convenience init(shortcut: KeyboardShortcut?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent(in: window, shortcut: shortcut)
    }

    private func buildContent(in window: NSWindow, shortcut: KeyboardShortcut?) {
        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let heading = makeLabel("Start / Stop ngrok shortcut", bold: true, size: 13)
        let hint = makeLabel(
            "A global shortcut that toggles ngrok from anywhere.\nClick the field and press a combination including ⌘, ⌥, or ⌃.",
            bold: false,
            size: 11
        )
        hint.textColor = .secondaryLabelColor

        recorder = ShortcutRecorderView(shortcut: shortcut)
        recorder.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearShortcut))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, hint, recorder, clearButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            recorder.heightAnchor.constraint(equalToConstant: 28),
            recorder.widthAnchor.constraint(equalToConstant: 240),
        ])

        recorder.onChange = { [weak self] shortcut in
            self?.onShortcutChange?(shortcut)
        }

        window.contentView = content
    }

    @objc private func clearShortcut() {
        recorder.clear()
    }

    private func makeLabel(_ text: String, bold: Bool, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
