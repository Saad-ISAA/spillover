import SwiftUI
import SpilloverCore

/// Overview: whether resuming is working, and every chat stopped by a limit with when it resumes
/// (or what happened to it).
struct ResumePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel {
            SectionHeader(title: "Auto resume", font: TypeScale.section) {
                HStack(spacing: 10) {
                    status
                    Button("Sessions") { model.selectedSection = .sessions }.buttonStyle(LinkButtonStyle())
                }
            }
            let current = model.stoppedChats.filter { !LimitResumeLog.isMissed($0.entry, now: model.now) && !isOld($0) }
            let leftAlone = model.stoppedChats.count - current.count
            if current.isEmpty {
                Text("No chat is waiting on a usage limit. When one stops, it shows here with when it will resume.")
                    .font(TypeScale.body).foregroundStyle(Ink.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(current.sorted(by: order)) { chat in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chat.stop.title ?? "Untitled chat").font(TypeScale.body).foregroundStyle(Ink.text).lineLimit(1)
                                Text("\(Fmt.folderName(chat.stop.cwd)) · stopped \(Fmt.moment(chat.stop.stoppedAt, now: model.now))")
                                    .font(TypeScale.meta).foregroundStyle(Ink.faint).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let p = chat.targetProfileId.flatMap(model.profile(id:)) {
                                HStack(spacing: 6) {
                                    Monogram(profile: p, size: 16)
                                    Text(p.displayName).font(TypeScale.meta).foregroundStyle(Ink.muted).lineLimit(1)
                                }
                                .frame(width: 140, alignment: .leading)
                            }
                            ResumeStatePill(chat: chat).frame(width: 150, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        if chat.id != current.sorted(by: order).last?.id { Rule() }
                    }
                }
            }
            Text(footnote(leftAlone: leftAlone))
                .font(TypeScale.meta).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var status: some View {
        if !model.autoPolicy.resumeChats {
            Pill(text: "Off")
        } else if !ChatSender.isAllowed {
            Pill(text: "Needs permission", tone: .warning)
        } else {
            Pill(text: "On", tone: .positive)
        }
    }

    private func footnote(leftAlone: Int) -> String {
        var parts: [String] = []
        if !model.autoPolicy.resumeChats {
            parts.append("Turn on Resume chats automatically under Setup to continue chats stopped by a limit when their account has room.")
        } else if !ChatSender.isAllowed {
            parts.append("Allow Spillover under System Settings → Privacy & Security → Accessibility.")
        } else if let checked = model.lastStoppedCheck {
            parts.append("Checked \(Fmt.relative(checked, now: model.now)); checks every minute.")
        }
        if leftAlone > 0 {
            parts.append("\(Fmt.plural(leftAlone, "older stopped chat")) left as \(leftAlone == 1 ? "it is" : "they are").")
        }
        return parts.joined(separator: " ")
    }

    /// Done more than a day ago: no longer news.
    private func isOld(_ chat: StoppedChat) -> Bool {
        guard let at = chat.entry.attemptedAt else { return false }
        return model.now.timeIntervalSince(at) > 86400
    }

    /// Waiting chats first, soonest first; then what already happened, newest first.
    private func order(_ a: StoppedChat, _ b: StoppedChat) -> Bool {
        switch (a.entry.attemptedAt, b.entry.attemptedAt) {
        case (nil, nil): return (a.expected ?? .distantFuture) < (b.expected ?? .distantFuture)
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?): return x > y
        }
    }
}

/// What Spillover will do, or did, about one stopped chat.
struct ResumeStatePill: View {
    @EnvironmentObject var model: AppModel
    let chat: StoppedChat

    var body: some View {
        if let outcome = chat.entry.outcome {
            let when = chat.entry.attemptedAt.map { " \(Fmt.moment($0, now: model.now))" } ?? ""
            if outcome == "resumed" {
                Pill(text: "Resumed\(when)", tone: .positive)
            } else {
                Pill(text: "Not resumed", tone: .negative).help(outcome)
            }
        } else if chat.targetProfileId == nil {
            Pill(text: "Folder refused", tone: .negative)
        } else if LimitResumeLog.isMissed(chat.entry, now: model.now) {
            Pill(text: "Left as it is")
                .help("Its account has had room for more than \(Int(LimitStops.resumeWindow / 3600)) hours, so it was not resumed. Send it a message to continue.")
        } else if !model.autoPolicy.resumeChats {
            Pill(text: chat.expected.map { $0 <= model.now ? "Can continue" : "Room \(Fmt.moment($0, now: model.now))" } ?? "Waiting for room")
                .help("Resuming chats is off: send it a message to continue.")
        } else if let at = chat.expected {
            Pill(text: at <= model.now ? "Resuming…" : "Resumes \(Fmt.moment(at, now: model.now))", tone: .data)
                .help("A minute after its account has room again.")
        } else {
            Pill(text: "Waiting for room")
                .help("Resumes a minute after its account has room again.")
        }
    }
}
