import Foundation

public struct NormalizedPath: Equatable, Hashable, Sendable {
    /// Canonical absolute path (symlinks resolved, NFC, no trailing slash).
    public let display: String
    /// What comparisons use: `display`, lowercased on case-insensitive volumes.
    public let key: String
}

/// Canonical form for every path that is compared or stored by Switchboard. There is exactly one
/// implementation; route matching, profile directory checks and the UI all go through it.
public enum PathNormalizer {
    /// - Returns: nil when `raw` is empty, contains NUL, or is not absolute (after `~` expansion).
    public static func normalize(
        _ raw: String, caseInsensitive: Bool, home: String? = nil
    ) -> NormalizedPath? {
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        var path = raw
        if path == "~" || path.hasPrefix("~/") {
            guard let home else { return nil }
            path = home + path.dropFirst(1)
        }
        guard path.hasPrefix("/") else { return nil }

        // 1. Lexical clean-up: drop empty and "." components, apply "..".
        var comps: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !comps.isEmpty { comps.removeLast() }
                continue
            }
            comps.append(String(part))
        }

        // 2. Resolve symlinks on the longest prefix that exists; keep the rest verbatim.
        var resolvedPrefix = ""
        var restStart = 0
        var k = comps.count
        while k >= 0 {
            let candidate = "/" + comps[0..<k].joined(separator: "/")
            if let real = realpathString(candidate) {
                resolvedPrefix = real == "/" ? "" : real
                restStart = k
                break
            }
            k -= 1
        }
        let rest = comps[restStart...].joined(separator: "/")
        var combined = resolvedPrefix
        if !rest.isEmpty { combined += "/" + rest }
        if combined.isEmpty { combined = "/" }

        // 3. Unicode normalisation (macOS can hand back decomposed names).
        let display = combined.precomposedStringWithCanonicalMapping
        return NormalizedPath(display: display, key: caseInsensitive ? display.lowercased() : display)
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
