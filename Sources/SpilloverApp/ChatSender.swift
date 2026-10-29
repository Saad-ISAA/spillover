import AppKit
import ApplicationServices
import SpilloverCore

/// Sends a message to one Claude chat inside a VS Code window, the way a person would: the chat's
/// panel is found by its title, checked to be idle with an empty input, its message box is focused,
/// and the message is typed and sent with Return. Claude's extension takes no message from other
/// apps and ignores text placed into its input from outside, so key presses are the only way in.
/// They are posted to VS Code's own process, which needs no window in front: VS Code stays where
/// it is, whatever app is in front keeps the screen, and no key can land anywhere else (a
/// background app cannot bring another one to the front anyway). Needs the Accessibility
/// permission. Everything is checked before a key is sent; any doubt refuses.
@MainActor
enum ChatSender {
    enum Failure: Error, LocalizedError, Equatable {
        case notAllowed
        case editorNotRunning
        case windowNotFound
        case chatNotFound
        case chatBusy
        case draftInInput
        case couldNotFocus
        case notSent

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Spillover is not allowed to control VS Code (System Settings → Privacy & Security → Accessibility)."
            case .editorNotRunning: return "VS Code is not running."
            case .windowNotFound: return "its VS Code window is not open."
            case .chatNotFound: return "its chat is not open in that window."
            case .chatBusy: return "the chat is busy."
            case .draftInInput: return "the chat's message box has text you typed; it was left alone."
            case .couldNotFocus: return "its message box could not be focused."
            case .notSent: return "the message did not go out."
            }
        }
    }

    static let bundleID = "com.microsoft.VSCode"

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that takes the user to the Accessibility settings.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Seconds since the user last touched the keyboard or mouse.
    static var secondsSinceUserInput: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Types `text` into the chat titled `title` in the VS Code window for `folder`. When the chat is
    /// not open in that window it is opened there by its id first (which brings VS Code forward).
    static func send(_ text: String, toChat title: String, conversationId: String, folder: String) throws {
        guard isAllowed else { throw Failure.notAllowed }
        guard let code = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw Failure.editorNotRunning
        }
        let app = AXUIElementCreateApplication(code.processIdentifier)
        // Electron apps expose their page contents to accessibility only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = window(in: app, folder: folder) else { throw Failure.windowNotFound }

        var chat = panels(in: window).filter { $0.title == title }
        if chat.isEmpty, let url = URL(string: "vscode://anthropic.claude-code/open?session=\(conversationId)") {
            // The link opens the chat in the window in front, so that window goes first.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            NSWorkspace.shared.open(url)
            Thread.sleep(forTimeInterval: 2.5)
            chat = panels(in: window).filter { $0.title == title }
        }
        guard chat.count == 1, let panel = chat.first else { throw Failure.chatNotFound }
        guard !panel.busy else { throw Failure.chatBusy }
        guard isEmptyInput(value(panel.input)) else { throw Failure.draftInInput }

        let pid = code.processIdentifier
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(panel.input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.4)
        guard isFocused(panel.input) else { throw Failure.couldNotFocus }
        press(0, flags: .maskCommand, to: pid)  // ⌘A, so whatever the box shows is replaced
        type(text, to: pid)
        Thread.sleep(forTimeInterval: 0.3)
        guard value(panel.input) == text, isFocused(panel.input) else { throw Failure.notSent }
        press(36, to: pid)  // Return
        Thread.sleep(forTimeInterval: 1.0)
        guard isEmptyInput(value(panel.input)) else { throw Failure.notSent }
    }

    // MARK: Finding the chat

    struct Panel {
        let title: String
        let input: AXUIElement
        let busy: Bool
    }

    /// The window whose title ends with the name of `folder` or of the nearest folder above it
    /// ("<editor> — <folder name>").
    private static func window(in app: AXUIElement, folder: String) -> AXUIElement? {
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var path = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
        while path.path != "/" {
            let name = path.lastPathComponent
            let hits = windows.filter { string($0, kAXTitleAttribute).hasSuffix("— " + name) || string($0, kAXTitleAttribute) == name }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }
            path.deleteLastPathComponent()
        }
        return nil
    }

    /// Each Claude chat in the window: the area holding exactly one message input. VS Code nests
    /// web areas, so the innermost copy is kept.
    static func panels(in window: AXUIElement) -> [Panel] {
        let areas = all(window) { e in
            string(e, kAXRoleAttribute) == "AXWebArea"
                && !all(e) { string($0, kAXDescriptionAttribute) == "Claude Code conversation" }.isEmpty
        }
        var seen: [AXUIElement] = []
        return areas.reversed().compactMap { area in
            let inputs = all(area) { string($0, kAXRoleAttribute) == "AXTextArea" && string($0, kAXDescriptionAttribute) == "Message input" }
            guard inputs.count == 1, !seen.contains(where: { CFEqual($0, inputs[0]) }) else { return nil }
            seen.append(inputs[0])
            let buttons = all(area) { string($0, kAXRoleAttribute) == "AXButton" }
            return Panel(
                title: buttons.first.map { string($0, kAXTitleAttribute) } ?? "",
                input: inputs[0],
                busy: buttons.contains { string($0, kAXDescriptionAttribute) == "Stop" })
        }
    }

    /// An empty message box reports its placeholder as its value.
    static func isEmptyInput(_ value: String) -> Bool {
        value.isEmpty || value.hasSuffix("to focus or unfocus Claude") || value == "Queue another message…"
    }

    // MARK: Accessibility and keys

    /// Keys go to VS Code's process only, never to the app in front.
    private static func press(_ key: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for unit in text.utf16 {
            var c = unit
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                event.postToPid(pid)
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String { (attribute(e, name) as? String) ?? "" }
    private static func value(_ e: AXUIElement) -> String { string(e, kAXValueAttribute) }
    private static func isFocused(_ e: AXUIElement) -> Bool { (attribute(e, kAXFocusedAttribute) as? Bool) == true }

    private static func all(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
        if depth > 45 { return [] }
        var found = match(e) ? [e] : []
        // Message bodies hold nothing needed here and are most of the tree.
        if string(e, kAXSubroleAttribute) == "AXDocumentArticle" { return found }
        for child in (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            found += all(child, depth: depth + 1, match)
        }
        return found
    }
}
