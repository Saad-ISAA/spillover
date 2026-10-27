import CryptoKit
import Foundation

public struct InstallRecord: Codable, Equatable, Sendable {
    public var editor: Editor
    public var settingsPath: String
    /// Copy of the settings file taken before the edit (nil when the file did not exist).
    public var backupPath: String?
    /// Raw JSON of the previous `claudeProcessWrapper` value, nil when the key was absent.
    public var previousValueJSON: String?
    /// SHA-256 of the file right after our edit; equal later means nothing else changed it.
    public var installedSHA256: String
    public var installedAt: Date
}

public enum InstallStatus: Equatable, Sendable {
    case editorNotFound
    case notInstalled
    case installed
    /// Some other wrapper is configured; we never overwrite it unless forced.
    case otherWrapper(String)
}

public enum UninstallOutcome: Equatable, Sendable {
    case restoredExactly
    case restoredValue
    case removedKey
    case nothingToDo
    /// The setting no longer points at our launcher (the user changed it): left untouched.
    case leftAlone(String)
}

public enum InstallError: Error, LocalizedError, Equatable {
    case editorNotFound(String)
    case launcherMissing
    case existingWrapper(String)
    case settingsUnreadable(String)
    case verificationFailed
    case manifestUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .editorNotFound(let name): return "\(name) has no user settings folder (has it been run?)."
        case .launcherMissing: return "The launcher is not installed yet (run `spillover install`)."
        case .existingWrapper(let v):
            return "claudeCode.claudeProcessWrapper is already set to \(v). Re-run with --force to replace it (it will be restored on uninstall)."
        case .settingsUnreadable(let why): return "Cannot edit settings: \(why)"
        case .verificationFailed: return "The edited settings did not verify; nothing was changed."
        case .manifestUnreadable(let why):
            return "~/.spillover/install-manifest.json is unreadable (\(why)). Fix or remove it; backups are in ~/.spillover/backups."
        }
    }
}

/// Points the Claude Code extension's `claudeCode.claudeProcessWrapper` at the Spillover
/// launcher, by editing exactly one key of the editor's user settings. Always backs up first,
/// verifies the result, and records enough to undo it exactly.
///
/// The key is machine-scoped in the extension, so it only takes effect in USER settings.
public struct VSCodeInstaller {
    public static let wrapperKey = "claudeCode.claudeProcessWrapper"

    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    private var launcherPath: String { env.paths.launcher.path }

    // MARK: Status

    public func status(of editor: Editor) -> InstallStatus {
        let url = editor.settingsFile(env: env)
        guard FileManager.default.fileExists(atPath: editor.userDirectory(env: env).path) else {
            return .editorNotFound
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let doc = try? JSONCDocument(text)
        else { return .notInstalled }
        guard let raw = doc.rawValue(forKey: Self.wrapperKey) else { return .notInstalled }
        if doc.stringValue(forKey: Self.wrapperKey) == launcherPath { return .installed }
        return .otherWrapper(raw)
    }

    // MARK: Install

    @discardableResult
    public func install(editor: Editor, force: Bool = false) throws -> InstallRecord {
        guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
            throw InstallError.launcherMissing
        }
        let userDir = editor.userDirectory(env: env)
        guard FileManager.default.fileExists(atPath: userDir.path) else {
            throw InstallError.editorNotFound(editor.displayName)
        }
        let url = editor.settingsFile(env: env)
        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        let original = fileExisted ? try readText(url) : "{}\n"
        let doc: JSONCDocument
        do { doc = try JSONCDocument(original) } catch {
            throw InstallError.settingsUnreadable(error.localizedDescription)
        }

        let previousRaw = doc.rawValue(forKey: Self.wrapperKey)
        if doc.stringValue(forKey: Self.wrapperKey) == launcherPath {
            // Already pointing at us. Never record our own launcher as the "previous" value:
            // uninstall would then "restore" it.
            var m = try manifest()
            if let existing = m.records.first(where: { $0.editor == editor }) { return existing }
            let record = InstallRecord(
                editor: editor, settingsPath: url.path, backupPath: nil, previousValueJSON: nil,
                installedSHA256: Self.sha256(original), installedAt: Date())
            m.records.append(record)
            try saveManifest(m)
            return record
        } else if previousRaw != nil && !force {
            throw InstallError.existingWrapper(previousRaw ?? "")
        }

        var backupPath: String?
        if fileExisted {
            backupPath = try writeBackup(original, editor: editor)
        }

        let updated = doc.settingString(launcherPath, forKey: Self.wrapperKey)
        guard let check = try? JSONCDocument(updated),
            check.stringValue(forKey: Self.wrapperKey) == launcherPath
        else { throw InstallError.verificationFailed }

        try SafeFS.writeAtomic(Data(updated.utf8), to: url, mode: fileExisted ? nil : 0o644)

        let record = InstallRecord(
            editor: editor, settingsPath: url.path, backupPath: backupPath,
            previousValueJSON: previousRaw, installedSHA256: Self.sha256(updated),
            installedAt: Date())
        var m = try manifest()
        m.records.removeAll { $0.editor == editor }
        m.records.append(record)
        try saveManifest(m)
        return record
    }

    // MARK: Uninstall

    @discardableResult
    public func uninstall(editor: Editor) throws -> UninstallOutcome {
        var m = try manifest()
        let record = m.records.first { $0.editor == editor }
        // Any thrown error keeps the record, so a later retry can still restore the previous value.
        let outcome = try restore(editor: editor, record: record)
        if record != nil {
            m.records.removeAll { $0.editor == editor }
            try saveManifest(m)
        }
        return outcome
    }

    private func restore(editor: Editor, record: InstallRecord?) throws -> UninstallOutcome {
        let url = editor.settingsFile(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return .nothingToDo }
        let current = try readText(url)
        let doc: JSONCDocument
        do { doc = try JSONCDocument(current) } catch {
            throw InstallError.settingsUnreadable(error.localizedDescription)
        }
        guard let value = doc.stringValue(forKey: Self.wrapperKey) else { return .nothingToDo }
        guard value == launcherPath else { return .leftAlone(value) }

        if let record, record.installedSHA256 == Self.sha256(current), let backup = record.backupPath,
            let original = try? String(contentsOfFile: backup, encoding: .utf8)
        {
            try SafeFS.writeAtomic(Data(original.utf8), to: url, mode: nil)
            return .restoredExactly
        }
        if let previous = record?.previousValueJSON {
            try SafeFS.writeAtomic(Data(doc.settingRaw(previous, forKey: Self.wrapperKey).utf8), to: url, mode: nil)
            return .restoredValue
        }
        try SafeFS.writeAtomic(Data(doc.removing(key: Self.wrapperKey).utf8), to: url, mode: nil)
        return .removedKey
    }

    // MARK: Internals

    private func readText(_ url: URL) throws -> String {
        do { return try String(contentsOf: url, encoding: .utf8) } catch {
            throw InstallError.settingsUnreadable(error.localizedDescription)
        }
    }

    private func writeBackup(_ text: String, editor: Editor) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.ensureDir(env.paths.backupsDir)
        let url = env.paths.backupsDir.appendingPathComponent("settings-\(editor.rawValue)-\(stamp).json")
        try SafeFS.writeAtomic(Data(text.utf8), to: url)
        return url.path
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Codable {
        var version = 1
        var records: [InstallRecord] = []
    }

    /// A missing manifest is empty; an unreadable one is an error (treating it as empty would
    /// overwrite other editors' records and lose their previous values).
    private func manifest() throws -> Manifest {
        let url = env.paths.installManifest
        guard FileManager.default.fileExists(atPath: url.path) else { return Manifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw InstallError.manifestUnreadable(error.localizedDescription)
        }
    }

    private func saveManifest(_ m: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SafeFS.ensureDir(env.paths.root)
        try SafeFS.writeAtomic(try encoder.encode(m), to: env.paths.installManifest)
    }
}
