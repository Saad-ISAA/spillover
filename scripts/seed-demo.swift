// Fills a throwaway HOME with sample Switchboard state so every screen can be looked at without
// real accounts: three accounts plus Default, assigned folders, limit readings with a week of
// history, and a month of session-log token counts. All names and numbers are made up.
//
//   swift scripts/seed-demo.swift <demo-home>
//
// Then run the app against it with scripts/demo-screenshot.sh. Nothing outside <demo-home> is
// written.
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: swift scripts/seed-demo.swift <demo-home>")
    exit(64)
}
let home = URL(fileURLWithPath: args[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let cli = root.appendingPathComponent(".build/debug/switchboard").path
let fm = FileManager.default

func mkdir(_ path: String) -> URL {
    let url = home.appendingPathComponent(path, isDirectory: true)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, to url: URL, mode: Int = 0o600) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
    try! fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func run(_ arguments: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    env.removeValue(forKey: "SWITCHBOARD_HOME")
    env["SWITCHBOARD_REAL_CLAUDE"] = home.appendingPathComponent("bin/claude").path
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}

// A stand-in `claude` that answers `auth status` per account.
write(
    """
    #!/bin/sh
    if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
      case "${CLAUDE_CONFIG_DIR:-}" in
        *work*)     echo '{"loggedIn":true,"authMethod":"claude.ai","email":"dev@work.example","orgName":"Northwind Labs","subscriptionType":"max"}' ;;
        *personal*) echo '{"loggedIn":true,"authMethod":"claude.ai","email":"me@personal.example","subscriptionType":"pro"}' ;;
        *client*)   echo '{"loggedIn":true,"authMethod":"claude.ai","email":"contractor@client.example","orgName":"Fabrikam","subscriptionType":"max"}' ;;
        "")         echo '{"loggedIn":true,"authMethod":"claude.ai","email":"main@home.example","subscriptionType":"max"}' ;;
        *)          echo '{"loggedIn":false}' ;;
      esac
      exit 0
    fi
    echo "demo claude"
    """, to: home.appendingPathComponent("bin/claude"), mode: 0o755)

// Accounts and folders.
for name in ["Work", "Personal", "Client"] { run(["profile", "create", name]) }
let folders = ["api-server", "billing-service", "client-portal", "blog", "infra", "notes"]
for f in folders { _ = mkdir("Code/\(f)") }
run(["route", "set", home.appendingPathComponent("Code/api-server").path, "work"])
run(["route", "set", home.appendingPathComponent("Code/billing-service").path, "work"])
run(["route", "set", home.appendingPathComponent("Code/client-portal").path, "client"])
run(["route", "set", home.appendingPathComponent("Code/blog").path, "personal"])
run(["route", "set", home.appendingPathComponent("Code/infra").path, "auto"])

// VS Code: recently opened folders, and connect it so the setup notice is not shown.
let storage = """
    {"backupWorkspaces":{"folders":[\(folders.map { "{\"folderUri\":\"file://\(home.path)/Code/\($0)\"}" }.joined(separator: ","))]}}
    """
write(storage, to: home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json"), mode: 0o644)
write("{}\n", to: home.appendingPathComponent("Library/Application Support/Code/User/settings.json"), mode: 0o644)
run(["install", "--editor"])

// Limits now, and how they moved. Work is busy but on pace; Client runs out before its weekly
// reset; Personal is light; Default is barely used.
let now = Date()
struct Account {
    let id: String
    let five: Double
    let fiveResetsIn: TimeInterval
    let seven: Double
    let sevenResetsIn: TimeInterval
    let dailyTokens: Int
}
let accounts = [
    Account(id: "work", five: 72, fiveResetsIn: 2 * 3600 + 14 * 60, seven: 61, sevenResetsIn: 2 * 86400 + 3 * 3600, dailyTokens: 5_200_000),
    Account(id: "client", five: 34, fiveResetsIn: 3 * 3600 + 40 * 60, seven: 83, sevenResetsIn: 3 * 86400, dailyTokens: 7_900_000),
    Account(id: "personal", five: 12, fiveResetsIn: 4 * 3600 + 2 * 60, seven: 24, sevenResetsIn: 5 * 86400 + 6 * 3600, dailyTokens: 1_400_000),
    Account(id: "default", five: 0, fiveResetsIn: 5 * 3600, seven: 9, sevenResetsIn: 6 * 86400, dailyTokens: 300_000),
]

let iso = ISO8601DateFormatter()
func isActive(_ d: Date) -> Bool {
    let h = Calendar.current.component(.hour, from: d)
    return h >= 9 && h < 20
}

for a in accounts {
    let fiveReset = now.addingTimeInterval(a.fiveResetsIn)
    let sevenReset = now.addingTimeInterval(a.sevenResetsIn)
    let snapshot = """
        {"capturedAt":"\(iso.string(from: now.addingTimeInterval(-180)))","model":"Claude","profileId":"\(a.id)",
         "windows":[{"kind":"five_hour","resetsAt":"\(iso.string(from: fiveReset))","usedPercentage":\(a.five)},
                    {"kind":"seven_day","resetsAt":"\(iso.string(from: sevenReset))","usedPercentage":\(a.seven)}]}
        """
    write(snapshot, to: home.appendingPathComponent(".switchboard/usage/\(a.id).json"))

    // Weekly use grows only in working hours; each 5-hour window ramps from zero.
    let weekStart = sevenReset.addingTimeInterval(-7 * 86400)
    var t = max(weekStart, now.addingTimeInterval(-8 * 86400))
    var activeSteps: [Date] = []
    while t < now {
        if isActive(t) { activeSteps.append(t) }
        t = t.addingTimeInterval(1800)
    }
    var points: [String] = []
    for (i, at) in activeSteps.enumerated() {
        let seven = a.seven * Double(i + 1) / Double(activeSteps.count + 1)
        let k = ceil(fiveReset.timeIntervalSince(at) / (5 * 3600)) - 1
        let windowReset = fiveReset.addingTimeInterval(-k * 5 * 3600)
        let into = 1 - windowReset.timeIntervalSince(at) / (5 * 3600)
        let five = k == 0 ? a.five * into / max(0.01, 1 - a.fiveResetsIn / (5 * 3600)) : min(95, (0.35 + 0.4 * sin(Double(i))) * 100 * into)
        points.append(
            "{\"at\":\(Int(at.timeIntervalSince1970)),\"fiveHour\":\(String(format: "%.1f", max(0, min(five, 100)))),\"fiveHourResetsAt\":\(Int(windowReset.timeIntervalSince1970)),\"sevenDay\":\(String(format: "%.1f", seven)),\"sevenDayResetsAt\":\(Int(sevenReset.timeIntervalSince1970))}"
        )
    }
    write("[" + points.joined(separator: ",") + "]", to: home.appendingPathComponent(".switchboard/usage/\(a.id).history.json"))

    // Session logs: token counts only, spread over the last 30 days.
    let configDir = a.id == "default" ? home.appendingPathComponent(".claude") : home.appendingPathComponent(".switchboard/profiles/\(a.id)")
    let mine: [String]
    switch a.id {
    case "work": mine = ["api-server", "billing-service"]
    case "client": mine = ["client-portal"]
    case "personal": mine = ["blog", "notes"]
    default: mine = ["infra"]
    }
    let models = ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
    var lines: [String] = []
    var n = 0
    for day in 0..<30 {
        let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
        let weekday = Calendar.current.component(.weekday, from: date)
        if weekday == 1 || weekday == 7, a.id != "personal" { continue }
        let wave = 0.55 + 0.45 * abs(sin(Double(day) * 1.7 + Double(a.id.count)))
        let total = Double(a.dailyTokens) * wave * (day == 0 ? 0.6 : 1)
        for m in 0..<12 {
            n += 1
            let folder = mine[m % mine.count]
            let model = models[(m + day) % (a.id == "personal" ? 1 : models.count)]
            let share = Int(total / 12)
            let stamp = iso.string(from: Calendar.current.date(bySettingHour: 9 + m % 10, minute: (m * 7) % 60, second: 0, of: date)!)
            lines.append(
                "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"cwd\":\"\(home.path)/Code/\(folder)\",\"message\":{\"id\":\"msg_\(a.id)_\(n)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(share / 20),\"output_tokens\":\(share / 12),\"cache_creation_input_tokens\":\(share / 8),\"cache_read_input_tokens\":\(share - share / 20 - share / 12 - share / 8)}}}"
            )
        }
    }
    write(lines.joined(separator: "\n") + "\n", to: configDir.appendingPathComponent("projects/demo/session.jsonl"))
}

print("Seeded \(home.path)")
print("Run the app against it: SWITCHBOARD_REAL_CLAUDE=\(home.path)/bin/claude scripts/demo-screenshot.sh \(home.path) popover out.png")
