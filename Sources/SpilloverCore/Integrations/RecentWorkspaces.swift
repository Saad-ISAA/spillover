import Foundation
import SQLite3

/// Folders recently opened in VS Code family editors, used to suggest what to assign.
/// Read-only: opens the editor's state database with SQLITE_OPEN_READONLY and never writes.
public struct RecentWorkspaces {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public struct Entry: Equatable, Hashable, Sendable {
        public let path: String
        public let editor: Editor
    }

    /// Local folders only (remote/SSH/container URIs are skipped), most recent first, de-duplicated.
    public func folders(limit: Int = 50) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for editor in Editor.installed(env: env) {
            let globalStorage = editor.userDirectory(env: env).appendingPathComponent("globalStorage")
            var uris = recentFromStateDB(globalStorage.appendingPathComponent("state.vscdb"))
            uris += recentFromStorageJSON(globalStorage.appendingPathComponent("storage.json"))
            for uri in uris {
                guard let path = Self.localPath(fromFileURI: uri) else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                if seen.insert(path).inserted { out.append(Entry(path: path, editor: editor)) }
                if out.count >= limit { return out }
            }
        }
        return out
    }

    static func localPath(fromFileURI uri: String) -> String? {
        guard uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// `history.recentlyOpenedPathsList` -> entries[].folderUri
    static func parseRecentList(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["entries"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["folderUri"] as? String }
    }

    /// Older layouts: storage.json `backupWorkspaces.folders[].folderUri` and
    /// `profileAssociations.workspaces` keys.
    static func parseStorageJSON(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var uris: [String] = []
        if let backups = root["backupWorkspaces"] as? [String: Any],
            let folders = backups["folders"] as? [[String: Any]]
        {
            uris += folders.compactMap { $0["folderUri"] as? String }
        }
        if let assoc = root["profileAssociations"] as? [String: Any],
            let workspaces = assoc["workspaces"] as? [String: Any]
        {
            uris += workspaces.keys.sorted()
        }
        return uris
    }

    private func recentFromStorageJSON(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.parseStorageJSON(data)
    }

    private func recentFromStateDB(_ url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        if let text = sqlite3_column_text(stmt, 0) {
            return Self.parseRecentList(String(cString: text))
        }
        if let blob = sqlite3_column_blob(stmt, 0) {
            let count = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: count)
            return Self.parseRecentList(String(decoding: data, as: UTF8.self))
        }
        return []
    }
}
