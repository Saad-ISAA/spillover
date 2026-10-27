import AppKit
import SpilloverCore
import SwiftUI

/// Icons of the real apps a chat runs in, taken from the installed applications (never redrawn).
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func bundleID(for editor: Editor) -> String {
        switch editor {
        case .code: return "com.microsoft.VSCode"
        case .insiders: return "com.microsoft.VSCodeInsiders"
        case .vscodium: return "com.vscodium"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .windsurf: return "com.exafunction.windsurf"
        }
    }

    static func icon(for editor: Editor?) -> NSImage? {
        icon(bundleID: editor.map(bundleID(for:)) ?? "com.apple.Terminal")
    }

    static func icon(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

/// The app a chat runs in, as its real icon (an SF Symbol when the app is not installed).
struct AppIconView: View {
    let editor: Editor?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = AppIcons.icon(for: editor) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: editor == nil ? "terminal" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundStyle(Ink.muted)
            }
        }
        .frame(width: size, height: size)
        .help(editor?.displayName ?? "Terminal")
        .accessibilityLabel(editor?.displayName ?? "Terminal")
    }
}
