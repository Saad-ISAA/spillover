import Foundation

/// The one redaction chokepoint. Every string that may reach a log,
/// the UI's "copy diagnostics", or the launch log goes through `Redaction.scrub` first.
public enum Redaction {
    public static let marker = "[redacted]"

    /// `jane.doe@example.com` -> `j***@example.com`
    public static func email(_ value: String) -> String {
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return value }
        let first = value[value.startIndex]
        return "\(first)***\(value[at...])"
    }

    /// Remove credential-shaped substrings: provider key prefixes, JSON token fields,
    /// bearer headers and any long unbroken base64-ish run.
    public static func scrub(_ text: String) -> String {
        var out = text
        for (pattern, template) in patterns {
            out = out.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    private static let patterns: [(String, String)] = [
        ("sk-ant-[A-Za-z0-9_\\-]{8,}", marker),
        ("sk-[A-Za-z0-9_\\-]{20,}", marker),
        ("(?i)bearer\\s+[A-Za-z0-9._\\-]{12,}", "Bearer \(marker)"),
        (
            "(?i)\"(access|refresh|id)?_?token\"\\s*:\\s*\"[^\"]+\"",
            "\"token\": \"\(marker)\""
        ),
        ("(?i)\"(accessToken|refreshToken)\"\\s*:\\s*\"[^\"]+\"", "\"token\": \"\(marker)\""),
        ("eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{5,}", marker),
        // Long unbroken runs. '/' is excluded on purpose so folder paths survive (launch log).
        ("[A-Za-z0-9_\\-]{40,}={0,2}", marker),
    ]
}
