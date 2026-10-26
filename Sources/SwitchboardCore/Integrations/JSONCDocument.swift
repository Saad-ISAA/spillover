import Foundation

public enum JSONCError: Error, Equatable, LocalizedError {
    case notAnObject
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notAnObject: return "settings file is not a JSON object"
        case .malformed(let why): return "settings file could not be parsed: \(why)"
        }
    }
}

/// A minimal, byte-preserving editor for a top-level JSON object that may contain comments and
/// trailing commas (VS Code `settings.json`). It can read, set or remove ONE top-level key and
/// leaves every other byte exactly as it was (comments, ordering, indentation, nested keys that
/// happen to share the name).
public struct JSONCDocument {
    private struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
        let commaAfter: Int?
    }

    private let bytes: [UInt8]
    private let openBrace: Int
    private let closeBrace: Int
    private let members: [Member]

    public init(_ text: String) throws {
        let b = Array(text.utf8)
        var scanner = Scanner(bytes: b)
        try scanner.skipTrivia()
        guard scanner.peek == UInt8(ascii: "{") else { throw JSONCError.notAnObject }
        let open = scanner.index
        scanner.index += 1

        var found: [Member] = []
        var close: Int?
        while scanner.index < b.count {
            try scanner.skipTrivia()
            guard let c = scanner.peek else { break }
            if c == UInt8(ascii: "}") {
                close = scanner.index
                break
            }
            if c == UInt8(ascii: ",") {
                scanner.index += 1
                continue
            }
            guard c == UInt8(ascii: "\"") else {
                throw JSONCError.malformed("expected a key at offset \(scanner.index)")
            }
            let keyStart = scanner.index
            try scanner.skipString()
            let rawKey = Array(b[(keyStart + 1)..<(scanner.index - 1)])
            try scanner.skipTrivia()
            guard scanner.peek == UInt8(ascii: ":") else {
                throw JSONCError.malformed("expected ':' at offset \(scanner.index)")
            }
            scanner.index += 1
            try scanner.skipTrivia()
            let valueStart = scanner.index
            try scanner.skipValue()
            let valueEnd = scanner.index
            try scanner.skipTrivia()
            var comma: Int?
            if scanner.peek == UInt8(ascii: ",") {
                comma = scanner.index
                scanner.index += 1
            }
            found.append(
                Member(
                    key: JSONCDocument.decodeKey(rawKey), keyStart: keyStart, valueStart: valueStart,
                    valueEnd: valueEnd, commaAfter: comma))
        }
        guard let closeIndex = close else { throw JSONCError.malformed("missing closing brace") }
        self.bytes = b
        self.openBrace = open
        self.closeBrace = closeIndex
        self.members = found
    }

    // MARK: Read

    public func hasKey(_ key: String) -> Bool { member(key) != nil }

    public func rawValue(forKey key: String) -> String? {
        guard let m = member(key) else { return nil }
        return String(decoding: bytes[m.valueStart..<m.valueEnd], as: UTF8.self)
    }

    /// The decoded value when it is a JSON string, else nil.
    public func stringValue(forKey key: String) -> String? {
        guard let raw = rawValue(forKey: key), raw.hasPrefix("\"") else { return nil }
        guard let data = "[\(raw)]".data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [String],
            let first = array.first
        else { return nil }
        return first
    }

    // MARK: Edit (each returns the new document text)

    public func settingString(_ value: String, forKey key: String) -> String {
        settingRaw(JSONCDocument.quote(value), forKey: key)
    }

    public func settingRaw(_ raw: String, forKey key: String) -> String {
        if let m = member(key) {
            return replacing(m.valueStart..<m.valueEnd, with: raw)
        }
        let quotedKey = JSONCDocument.quote(key)
        if let last = members.last {
            let indent = indentation()
            let insertion = ",\n\(indent)\(quotedKey): \(raw)"
            return replacing(last.valueEnd..<last.valueEnd, with: insertion)
        }
        let between = bytes[(openBrace + 1)..<closeBrace]
        let needsClosingNewline = !between.contains(UInt8(ascii: "\n"))
        let insertion = "\n  \(quotedKey): \(raw)" + (needsClosingNewline ? "\n" : "")
        return replacing((openBrace + 1)..<(openBrace + 1), with: insertion)
    }

    public func removing(key: String) -> String {
        guard let index = members.firstIndex(where: { $0.key == key }) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let m = members[index]
        var deletions: [Range<Int>] = []

        // Start at the line start when the key is the first thing on its line.
        var start = m.keyStart
        var onOwnLine = false
        var probe = m.keyStart
        while probe > 0, bytes[probe - 1] == UInt8(ascii: " ") || bytes[probe - 1] == UInt8(ascii: "\t") {
            probe -= 1
        }
        if probe == 0 || bytes[probe - 1] == UInt8(ascii: "\n") {
            start = probe
            onOwnLine = true
        }

        var end = m.commaAfter.map { $0 + 1 } ?? m.valueEnd
        if onOwnLine {
            var e = end
            while e < bytes.count, bytes[e] == UInt8(ascii: " ") || bytes[e] == UInt8(ascii: "\t") { e += 1 }
            if e < bytes.count, bytes[e] == UInt8(ascii: "\r") { e += 1 }
            if e < bytes.count, bytes[e] == UInt8(ascii: "\n") { e += 1; end = e }
        }
        deletions.append(start..<end)

        // A last member without its own comma leaves the previous member's comma dangling.
        if m.commaAfter == nil, index > 0, let prevComma = members[index - 1].commaAfter {
            deletions.append(prevComma..<(prevComma + 1))
        }

        var out = bytes
        for r in deletions.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            out.removeSubrange(r)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Helpers

    private func member(_ key: String) -> Member? { members.first { $0.key == key } }

    private func replacing(_ range: Range<Int>, with text: String) -> String {
        var out = bytes
        out.replaceSubrange(range, with: Array(text.utf8))
        return String(decoding: out, as: UTF8.self)
    }

    /// Whitespace in front of the first member's key (its line), or two spaces.
    private func indentation() -> String {
        guard let first = members.first else { return "  " }
        var probe = first.keyStart
        while probe > 0, bytes[probe - 1] == UInt8(ascii: " ") || bytes[probe - 1] == UInt8(ascii: "\t") {
            probe -= 1
        }
        guard probe == 0 || bytes[probe - 1] == UInt8(ascii: "\n") else { return "  " }
        return String(decoding: bytes[probe..<first.keyStart], as: UTF8.self)
    }

    /// JSON string literal for `value`.
    public static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func decodeKey(_ raw: [UInt8]) -> String {
        let text = String(decoding: raw, as: UTF8.self)
        guard text.contains("\\") else { return text }
        guard let data = "[\"\(text)\"]".data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [String],
            let first = array.first
        else { return text }
        return first
    }

    // MARK: Scanner

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipTrivia() throws {
            while index < bytes.count {
                let c = bytes[index]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    index += 1
                } else if c == UInt8(ascii: "/"), index + 1 < bytes.count {
                    if bytes[index + 1] == UInt8(ascii: "/") {
                        index += 2
                        while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                    } else if bytes[index + 1] == UInt8(ascii: "*") {
                        index += 2
                        var closed = false
                        while index + 1 < bytes.count {
                            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") {
                                index += 2
                                closed = true
                                break
                            }
                            index += 1
                        }
                        if !closed { throw JSONCError.malformed("unterminated comment") }
                    } else {
                        return
                    }
                } else {
                    return
                }
            }
        }

        /// At an opening quote; leaves `index` just past the closing quote.
        mutating func skipString() throws {
            index += 1
            while index < bytes.count {
                let c = bytes[index]
                if c == UInt8(ascii: "\\") {
                    index += 2
                } else if c == UInt8(ascii: "\"") {
                    index += 1
                    return
                } else {
                    index += 1
                }
            }
            throw JSONCError.malformed("unterminated string")
        }

        mutating func skipValue() throws {
            guard let c = peek else { throw JSONCError.malformed("missing value") }
            if c == UInt8(ascii: "\"") {
                try skipString()
            } else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                var depth = 0
                while index < bytes.count {
                    let d = bytes[index]
                    if d == UInt8(ascii: "\"") {
                        try skipString()
                        continue
                    }
                    if d == UInt8(ascii: "/"), index + 1 < bytes.count,
                        bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*")
                    {
                        try skipTrivia()
                        continue
                    }
                    if d == UInt8(ascii: "{") || d == UInt8(ascii: "[") { depth += 1 }
                    if d == UInt8(ascii: "}") || d == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return
                        }
                    }
                    index += 1
                }
                throw JSONCError.malformed("unterminated object or array")
            } else {
                while index < bytes.count {
                    let d = bytes[index]
                    if d == 0x20 || d == 0x09 || d == 0x0A || d == 0x0D || d == UInt8(ascii: ",")
                        || d == UInt8(ascii: "}") || d == UInt8(ascii: "]") || d == UInt8(ascii: "/")
                    {
                        break
                    }
                    index += 1
                }
            }
        }
    }
}
