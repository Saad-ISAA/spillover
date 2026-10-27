import AppKit
import SpilloverCore
import SwiftUI

/// Documentation only: `SPILLOVER_DEMO_RENDER=<folder>` renders the popover (light and dark) and
/// the menu bar glyph states to PNG files without showing a window, then quits. Lets screenshots
/// be made where window capture is unavailable. AppKit-backed controls (menus, pickers) render as
/// placeholders in this mode.
@MainActor
enum DemoRender {
    static func runIfRequested(model: AppModel) {
        guard let folder = model.env.processEnv["SPILLOVER_DEMO_RENDER"] else { return }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Give background refreshes (logins, sessions, logs) a moment to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let view = MenuPopover(rendersStatically: true).environmentObject(model).environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.09) : Color.white)
                write(view, to: out.appendingPathComponent("popover-\(name).png"), appearance: scheme == .dark ? .darkAqua : .aqua)
            }
            for (name, alert) in [("calm", false), ("alert", true)] {
                let glyph = Image(nsImage: MenuBarGlyph.image(alert: alert))
                    .renderingMode(.template).foregroundStyle(.black).frame(width: 18, height: 18)
                    .padding(4).background(Color.white)
                write(glyph, to: out.appendingPathComponent("glyph-\(name).png"), appearance: .aqua, scale: 6)
            }
            write(BrandMark(size: 64).padding(8).background(Color.white), to: out.appendingPathComponent("brand-light.png"), appearance: .aqua)
            write(BrandMark(size: 64).padding(8).background(Color(white: 0.09)), to: out.appendingPathComponent("brand-dark.png"), appearance: .darkAqua)
            NSApp.terminate(nil)
        }
    }

    private static func write<V: View>(_ view: V, to url: URL, appearance: NSAppearance.Name, scale: CGFloat = 2) {
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }
}

/// Documentation only: `SPILLOVER_DEMO_SESSIONS=<file>` lists made-up chats instead of the real
/// process table, so screenshots never show the machine's own folders. Moves are off in this mode.
enum DemoSessions {
    private struct Entry: Decodable {
        let pid: Int32
        /// Relative to the demo home.
        let folder: String
        let account: String
        let editor: Bool
        let minutesAgo: Double
        let conversation: String?
    }

    static func isActive(_ env: SBEnvironment) -> Bool { env.processEnv["SPILLOVER_DEMO_SESSIONS"] != nil }

    static func load(_ env: SBEnvironment) -> [RunningSession]? {
        guard let path = env.processEnv["SPILLOVER_DEMO_SESSIONS"] else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        let profiles = (try? ProfileStore(env: env).all()) ?? []
        let editorBinary = env.home.appendingPathComponent(
            ".vscode/extensions/anthropic.claude-code-2.1.0-darwin-arm64/resources/native-binary/claude").path
        let terminalBinary = env.home.appendingPathComponent(".local/share/claude/versions/2.1.0").path
        return entries.map { e in
            RunningSession(
                pid: e.pid, executable: e.editor ? editorBinary : terminalBinary,
                cwd: env.home.appendingPathComponent(e.folder).path,
                configDir: profiles.first { $0.id == e.account }?.configDir, spilloverProfile: nil,
                startedAt: Date().addingTimeInterval(-e.minutesAgo * 60), conversationId: e.conversation)
        }
    }
}
