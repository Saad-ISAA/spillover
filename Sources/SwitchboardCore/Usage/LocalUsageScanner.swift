import Foundation

public struct TokenTotals: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheCreation = 0
    public var cacheRead = 0
    public var messages = 0

    public init() {}

    public var total: Int { input + output + cacheCreation + cacheRead }

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
        messages += other.messages
    }
}

public struct UsageReport: Equatable, Sendable {
    public var total = TokenTotals()
    /// "yyyy-MM-dd" (UTC) -> totals
    public var byDay: [String: TokenTotals] = [:]
    public var byModel: [String: TokenTotals] = [:]
    /// Working directory recorded by Claude Code -> totals
    public var byProject: [String: TokenTotals] = [:]
    /// Estimated cost for priced models only (lower bound when `unpricedModels` is non-empty).
    public var pricedCostUSD: Double = 0
    public var unpricedModels: Set<String> = []

    public init() {}
}

/// Optional per-model prices (USD per million tokens), supplied by the user in
/// `<root>/prices.json`. Switchboard ships no prices of its own: an unknown price is reported as
/// "unpriced", never as zero.
public struct PriceTable: Codable, Equatable, Sendable {
    public struct Price: Codable, Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheWrite: Double?
        public var cacheRead: Double?
    }

    /// Model id or id prefix -> price. Longest matching prefix wins.
    public var models: [String: Price] = [:]

    public init(models: [String: Price] = [:]) {
        self.models = models
    }

    public static func load(env: SBEnvironment) -> PriceTable {
        let url = env.paths.root.appendingPathComponent("prices.json")
        guard let data = try? Data(contentsOf: url),
            let table = try? JSONDecoder().decode(PriceTable.self, from: data)
        else { return PriceTable() }
        return table
    }

    public func price(for model: String) -> Price? {
        models.filter { model.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    public func cost(_ t: TokenTotals, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        let m = 1_000_000.0
        return Double(t.input) * p.input / m + Double(t.output) * p.output / m
            + Double(t.cacheCreation) * (p.cacheWrite ?? p.input) / m
            + Double(t.cacheRead) * (p.cacheRead ?? p.input) / m
    }
}

/// Token totals from a profile's local Claude Code session logs (`<config>/projects/**/*.jsonl`).
/// Reads only the usage counters, model, timestamp and working directory of each assistant
/// message; message content is never stored or returned.
public struct LocalUsageScanner {
    private let env: SBEnvironment

    public init(env: SBEnvironment) {
        self.env = env
    }

    public func scan(profile: Profile, since: Date, prices: PriceTable? = nil) -> UsageReport {
        let dir = URL(fileURLWithPath: profile.configDir ?? env.paths.defaultClaudeDir.path)
            .appendingPathComponent("projects", isDirectory: true)
        var report = UsageReport()
        var seen = Set<String>()
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return report }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < since { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            Self.accumulate(data: data, since: since, seen: &seen, into: &report)
        }
        if let prices {
            report.pricedCostUSD = 0
            for (model, totals) in report.byModel {
                if let c = prices.cost(totals, model: model) {
                    report.pricedCostUSD += c
                } else {
                    report.unpricedModels.insert(model)
                }
            }
        }
        return report
    }

    static let usageMarker = Data("\"usage\"".utf8)

    /// Parse one JSONL file's bytes. Duplicate message ids (streamed partials) are counted once.
    static func accumulate(data: Data, since: Date, seen: inout Set<String>, into report: inout UsageReport) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard line.range(of: usageMarker) != nil,
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }

            let stamp = obj["timestamp"] as? String
            let date = stamp.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            if let date, date < since { continue }
            if let id = message["id"] as? String {
                guard seen.insert(id).inserted else { continue }
            }

            var t = TokenTotals()
            t.input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            t.output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            t.cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            t.cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            t.messages = 1
            if t.total == 0 { continue }

            let model = (message["model"] as? String) ?? "unknown"
            let project = (obj["cwd"] as? String) ?? "unknown"
            let day = date.map { dayFormatter.string(from: $0) } ?? "unknown"
            report.total.add(t)
            report.byModel[model, default: TokenTotals()].add(t)
            report.byProject[project, default: TokenTotals()].add(t)
            report.byDay[day, default: TokenTotals()].add(t)
        }
    }
}
