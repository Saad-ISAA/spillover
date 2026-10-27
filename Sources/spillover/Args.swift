import Foundation

/// Tiny argument reader: positionals, `--flag`, and `--option value`.
struct Args {
    private(set) var positionals: [String] = []
    private var flags: Set<String> = []
    private var options: [String: String] = [:]

    /// Options that take a value; everything else starting with `--` is a boolean flag.
    static let valued: Set<String> = ["editor", "from", "days", "file"]

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a == "--" {
                positionals += raw[(i + 1)...]
                break
            }
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if Self.valued.contains(name), i + 1 < raw.count {
                    options[name] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }
    func positional(_ index: Int) -> String? { index < positionals.count ? positionals[index] : nil }
}

enum CLIError: Error, LocalizedError {
    case usage(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let s): return s
        case .failed(let s): return s
        }
    }
}

enum Out {
    static func line(_ s: String = "") { print(s) }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func table(_ rows: [[String]]) {
        guard let width = rows.map(\.count).max(), width > 0 else { return }
        var widths = [Int](repeating: 0, count: width)
        for row in rows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        for row in rows {
            let cells = row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }
            print(cells.joined(separator: "  "))
        }
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        let future = s >= 0
        let a = abs(s)
        let text: String
        if a < 60 {
            text = "\(a)s"
        } else if a < 3600 {
            text = "\(a / 60)m"
        } else if a < 86400 {
            text = "\(a / 3600)h \((a % 3600) / 60)m"
        } else {
            text = "\(a / 86400)d \((a % 86400) / 3600)h"
        }
        return future ? "in \(text)" : "\(text) ago"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}
