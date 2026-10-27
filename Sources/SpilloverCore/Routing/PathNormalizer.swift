import Foundation

public struct NormalizedPath: Equatable, Hashable, Sendable {
    /// Canonical absolute path (symlinks resolved, NFC, no trailing slash).
    public let display: String
    /// What comparisons use: `display`, lowercased on case-insensitive volumes.
    public let key: String
}

/// Canonical form for every path that is compared or stored by Spillover. There is exactly one
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

        // Components without empty and "." parts. ".." is kept here: it must be applied AFTER
        // symlinks are resolved (physically, like the kernel), not lexically.
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }

        // Resolve the longest prefix that exists. realpath applies "..", symlinks and case
        // physically for that prefix.
        var resolved: [String] = []
        var restStart = 0
        var k = comps.count
        while k >= 0 {
            let candidate = "/" + comps[0..<k].joined(separator: "/")
            if let real = realpathString(candidate) {
                resolved = real.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                restStart = k
                break
            }
            k -= 1
        }

        // The tail does not exist, so there are no symlinks left in it: apply it lexically.
        for part in comps[restStart...] {
            if part == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
            } else {
                resolved.append(part)
            }
        }

        let combined = "/" + resolved.joined(separator: "/")
        // Unicode normalisation (macOS can hand back decomposed names).
        let display = combined.precomposedStringWithCanonicalMapping
        return NormalizedPath(display: display, key: caseInsensitive ? display.lowercased() : display)
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
