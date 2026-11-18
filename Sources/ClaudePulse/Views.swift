import AppKit
import SwiftUI

/// Anthropic's dark theme: warm charcoal surfaces, ivory text, clay as the single accent.
enum Palette {
    static let background = Color(red: 0.149, green: 0.149, blue: 0.141)   // #262624
    static let raised = Color(red: 0.188, green: 0.188, blue: 0.180)       // #30302E
    static let border = Color(red: 0.871, green: 0.863, blue: 0.820).opacity(0.14)
    static let text = Color(red: 0.980, green: 0.976, blue: 0.961)         // #FAF9F5
    static let text2 = Color(red: 0.761, green: 0.753, blue: 0.714)        // #C2C0B6
    static let text3 = Color(red: 0.612, green: 0.604, blue: 0.573)        // #9C9A92
    static let track = Color(red: 0.980, green: 0.976, blue: 0.961).opacity(0.10)
    /// Clay: reserved for "this one is waiting on you" and for anything close to a limit.
    static let attention = Color(red: 0.851, green: 0.467, blue: 0.341)    // #D97757
    /// Green means one thing: Claude finished and the next move is yours.
    static let done = Color(red: 0.478, green: 0.725, blue: 0.541)
    /// Muted blue for "still going, nothing for you to do".
    static let working = Color(red: 0.416, green: 0.608, blue: 0.800)      // #6A9BCC
    static let idle = Color(red: 0.612, green: 0.604, blue: 0.573).opacity(0.7)
}

/// Size state shared between the window and the view. The panel hugs its rows until you
/// drag it to a height of your own; from then on the list scrolls inside the size you chose.
final class PanelLayout: ObservableObject {
    static let defaultWidth: CGFloat = 340
    @Published var width: CGFloat = PanelLayout.defaultWidth
    @Published var manualHeight = false
    @Published var showSettings = false

    /// How many chats are listed: starts at one page, grows a page per "Load more", capped.
    static let chatPage = 5
    static let chatMax = 15
    @Published var chatLimit = PanelLayout.chatPage

    /// Collapsed to a one-line ticker. The full size is kept and comes back on expand.
    static let compactSize = CGSize(width: 340, height: 38)
    @Published var minimized = UserDefaults.standard.bool(forKey: "panelMinimized") {
        didSet { UserDefaults.standard.set(minimized, forKey: "panelMinimized") }
    }
}

struct PanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var layout: PanelLayout
    @ObservedObject var chats: ChatReader
    @ObservedObject var artifacts: ArtifactStore
    @ObservedObject var github: GitHubReader
    @ObservedObject var insights: InsightsStore
    @ObservedObject private var settings = Settings.shared
    var open: (SessionRow) -> Void

    /// Cap while the panel sizes itself, so a busy day cannot run it off the screen.
    private let autoMaxRows = 12

    /// Shown when the widget would notify you but macOS will not let it.
    @ViewBuilder private var notificationWarning: some View {
        let access = settings.notificationAccess
        if settings.notifyOnFinish, ["denied", "notDetermined", "bannersOff"].contains(access) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "bell.slash.fill").font(.system(size: 10.5)).padding(.top, 2)
                Text(access == "bannersOff"
                     ? "macOS has banners turned off for Claude Pulse, so nothing will pop up. Click to open Notification settings."
                     : "macOS is not allowing Claude Pulse notifications, so you will not be alerted. Click to open Notification settings.")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.background)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.attention))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                Self.openLink("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            }
        }
    }

    @ViewBuilder private var expanded: some View {
        let manual = layout.manualHeight
        VStack(alignment: .leading, spacing: 0) {
            header
            notificationWarning
            if layout.showSettings {
                if manual {
                    // A long hidden-chats list must stay reachable at whatever height you chose.
                    ScrollView(.vertical) { SettingsView(settings: settings, github: github, connections: connections) }
                        .scrollIndicators(.never)
                        .frame(maxHeight: .infinity)
                } else {
                    SettingsView(settings: settings, github: github, connections: connections)
                }
            } else if manual {
                ScrollView(.vertical) { list(limit: nil) }
                    .scrollIndicators(.never)
                    .frame(maxHeight: .infinity)
            } else {
                list(limit: autoMaxRows)
            }
            footer
        }
        .frame(minWidth: manual ? 0 : layout.width,
               idealWidth: layout.width,
               maxWidth: manual ? .infinity : layout.width,
               maxHeight: manual ? .infinity : nil,
               alignment: .top)
    }

    var body: some View {
        Group {
            if layout.minimized {
                TickerView(headlines: headlines) { layout.minimized = false }
                    .frame(width: PanelLayout.compactSize.width, height: PanelLayout.compactSize.height)
            } else {
                expanded
            }
        }
        .background(Palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }

    /// One line per data source that is switched on: is it working, and how fresh is it?
    private var connections: [ConnectionLine] {
        var lines: [ConnectionLine] = []
        let stale: (Date?, TimeInterval) -> Bool = { date, limit in
            date.map { Date().timeIntervalSince($0) > limit } ?? true
        }
        func age(_ date: Date?) -> String { date.map { "last read \(Format.ago($0)) ago" } ?? "never read" }

        if !store.claudeRunning {
            lines.append(ConnectionLine(name: "Claude Desktop", state: .down, detail: "not running"))
        } else if settings.showCode {
            lines.append(ConnectionLine(name: "Code sessions", state: .ok, detail: "live, read every 2 seconds"))
        }
        if settings.showGitHub {
            switch github.connection {
            case .connected(let accounts):
                lines.append(ConnectionLine(name: "GitHub", state: .ok, detail: "connected as \(accounts.joined(separator: ", "))"))
            case .checking:
                lines.append(ConnectionLine(name: "GitHub", state: .ok, detail: "checking"))
            case .noCLI:
                lines.append(ConnectionLine(name: "GitHub", state: .problem, detail: "the gh CLI is not installed"))
            case .notLoggedIn:
                lines.append(ConnectionLine(name: "GitHub", state: .problem, detail: "not logged in; run gh auth login"))
            }
        }
        if settings.showChats || settings.showDuet {
            if !chats.trusted {
                lines.append(ConnectionLine(name: "Chats and Duet", state: .problem, detail: "Accessibility access is off"))
            } else {
                // Readable only while on screen, so an old reading is normal here, not a fault.
                if settings.showDuet {
                    lines.append(ConnectionLine(name: "Duet", state: .ok, detail: "connected; \(age(chats.duetSeenAt))"))
                }
                if settings.showChats {
                    lines.append(ConnectionLine(name: "Chats", state: .ok, detail: "connected; \(age(chats.seenAt))"))
                }
            }
        }
        if settings.showArtifacts {
            let old = stale(artifacts.updatedAt, 3 * 86_400)
            lines.append(ConnectionLine(name: "Artifacts", state: old ? .problem : .ok,
                                        detail: artifacts.updatedAt == nil ? "no snapshot yet" : "snapshot \(Format.ago(artifacts.updatedAt!)) old"))
        }
        if settings.showUsage || settings.showSkillIdeas {
            let at = insights.insights?.updatedAt
            lines.append(ConnectionLine(name: "Usage and skill ideas", state: stale(at, 4 * 86_400) ? .problem : .ok,
                                        detail: at == nil ? "no snapshot yet" : "snapshot \(Format.ago(at!)) old"))
        }
        if settings.notifyOnFinish {
            let blocked = ["denied", "notDetermined", "bannersOff"].contains(settings.notificationAccess)
            lines.append(ConnectionLine(name: "Notifications", state: blocked ? .problem : .ok,
                                        detail: blocked ? "blocked by macOS" : "allowed"))
        }
        return lines
    }

    /// What the ticker cycles through: sessions and PRs waiting on you, what is still running, then usage.
    /// Artifact tags stay in the full panel only.
    private var headlines: [Headline] {
        var out: [Headline] = []
        for row in store.rows where row.state == .needsInput {
            out.append(Headline(id: "ask-" + row.id, icon: "questionmark.bubble.fill", color: Palette.attention,
                                label: "Answer", text: row.title,
                                action: { open(row) }))
        }
        if settings.showDuet {
            for task in chats.duetTasks where task.needsInput {
                out.append(Headline(id: "duet-" + task.id, icon: "questionmark.bubble.fill", color: Palette.attention,
                                    label: "Duet", text: task.title,
                                    action: { chats.openDuet(task) }))
            }
        }
        for row in store.rows where row.state == .needsYou {
            out.append(Headline(id: "done-" + row.id, icon: "checkmark.circle.fill", color: Palette.done,
                                label: "Done", text: row.title,
                                action: { open(row) }))
        }
        if settings.showGitHub {
            for pr in github.pullRequests where pr.status.needsYou {
                out.append(Headline(id: "pr-" + pr.url, icon: "arrow.triangle.pull", color: Palette.attention,
                                    label: "PR \(pr.status.label)", text: pr.title,
                                    action: { Self.openLink(pr.url) }))
            }
        }
        for row in store.rows where row.state == .working {
            out.append(Headline(id: "work-" + row.id, icon: "circle.fill", color: Palette.working,
                                label: "Working", text: row.title,
                                action: { open(row) }))
        }
        // Usage closes every rotation, so the ticker always has something to show.
        if let plan = store.plan {
            let high = max(plan.fiveHour, plan.sevenDay) >= 80
            let age = Date().timeIntervalSince(plan.sampledAt) < 60 ? "just now" : "\(Format.ago(plan.sampledAt)) ago"
            out.append(Headline(id: "usage-plan", icon: "gauge.medium",
                                color: high ? Palette.attention : Palette.text2,
                                label: "Usage",
                                text: "5h \(plan.fiveHour)% · 7d \(plan.sevenDay)% · as of \(age)",
                                action: { layout.minimized = false }))
        }
        let counted = store.rows.filter { $0.tokens.context > 0 }
        if !counted.isEmpty {
            let output = counted.reduce(0) { $0 + $1.tokens.output }
            let fullest = counted.map(\.contextFraction).max() ?? 0
            out.append(Headline(id: "usage-tokens", icon: "number",
                                color: fullest >= 0.8 ? Palette.attention : Palette.text2,
                                label: "Tokens",
                                text: "\(Format.tokens(output)) out over \(counted.count) session\(counted.count == 1 ? "" : "s") · fullest context \(Int((fullest * 100).rounded()))%",
                                action: { layout.minimized = false }))
        }
        return out
    }

    @ViewBuilder private func list(limit: Int?) -> some View {
        if settings.showCode { sessionList(limit: limit) }
        if settings.showGitHub, !github.pullRequests.isEmpty { pullRequestSection }
        if settings.showDuet, chats.trusted, chats.duetSeenAt != nil { duetSection }
        if settings.showArtifacts, !artifacts.items.isEmpty { artifactSection }
        if settings.showChats { chatSection }
        if settings.showSkillIdeas || settings.showUsage, let data = insights.insights { insightsSection(data) }
    }

    @ViewBuilder private func insightsSection(_ data: Insights) -> some View {
        let total = max(1, data.projects.reduce(0) { $0 + $1.outputTokens })
        let top = Array(data.projects.prefix(5))
        let ideas = (data.skillIdeas ?? []).filter { !settings.dismissedIdeas.contains($0.name) }
        VStack(alignment: .leading, spacing: 1) {
            if settings.showSkillIdeas, !ideas.isEmpty {
                sectionHeader("SKILLS WORTH CREATING") { Spacer() }
                ForEach(ideas) { idea in
                    SkillIdeaRowView(idea: idea) { settings.dismissedIdeas.append(idea.name) }
                }
            }
            if settings.showUsage {
            sectionHeader("YOUR USAGE · LAST \(data.windowDays) DAYS") {
                Spacer()
                if let at = data.updatedAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(context.date.timeIntervalSince(at) < 60 ? "just updated" : "as of \(Format.ago(at, now: context.date)) ago")
                            .font(.system(size: 10))
                    }
                    .help("Counts are exact, read from your local transcripts. What the work was for, and the skill ideas, are a Claude session's reading of your prompts.")
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("\(data.totals.sessions) sessions · \(data.totals.prompts) prompts · \(Format.tokens(data.totals.outputTokens)) tokens written")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .monospacedDigit()

                // Share of Claude's output by project, biggest first; lighter means smaller.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(data.projects.enumerated()), id: \.element.id) { index, project in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Self.color(for: project.name))
                                .frame(width: max(2, (geo.size.width - CGFloat(data.projects.count - 1) * 2)
                                                  * CGFloat(project.outputTokens) / CGFloat(total)))
                                .help("\(project.name): \(Int((Double(project.outputTokens) / Double(total) * 100).rounded()))% · \(Format.tokens(project.outputTokens)) tokens · \(project.sessions) sessions · \(project.prompts) prompts")
                        }
                    }
                }
                .frame(height: 8)

                HStack(spacing: 10) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, project in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Self.color(for: project.name))
                                .frame(width: 7, height: 7)
                            Text("\(project.name) \(Int((Double(project.outputTokens) / Double(total) * 100).rounded()))%")
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.text2)
                .monospacedDigit()

                if let activities = data.activities, !activities.isEmpty {
                    Text("Mostly: " + activities.prefix(3).map { "\($0.label.lowercased()) ~\($0.share)%" }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(activities.map { "\($0.label): about \($0.share)%" }.joined(separator: "\n") + "\n\nEstimated from your prompts.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Six project colours, checked for colour-blind separation and contrast on this background.
    /// Orange and red are left out on purpose: clay already means "needs you" everywhere else.
    private static let series: [Color] = [
        Color(red: 0.224, green: 0.529, blue: 0.898),  // blue    #3987E5
        Color(red: 0.098, green: 0.620, blue: 0.439),  // aqua    #199E70
        Color(red: 0.788, green: 0.522, blue: 0.000),  // yellow  #C98500
        Color(red: 0.835, green: 0.318, blue: 0.506),  // magenta #D55181
        Color(red: 0.047, green: 0.639, blue: 0.047),  // green   #0CA30C
        Color(red: 0.565, green: 0.522, blue: 0.914),  // violet  #9085E9
    ]

    /// A project keeps its colour for good: slots are handed out in the order projects are first
    /// seen and remembered, so a project does not change colour when its rank changes. Projects
    /// past the sixth share a neutral grey rather than a made-up seventh hue.
    private static func color(for project: String) -> Color {
        let key = "projectColorSlots"
        var slots = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        if let slot = slots[project] { return slot < series.count ? series[slot] : Palette.text3 }
        let slot = slots.count
        slots[project] = slot
        UserDefaults.standard.set(slots, forKey: key)
        return slot < series.count ? series[slot] : Palette.text3
    }

    private func pullRequests(for row: SessionRow) -> [PullRequest] {
        guard let repo = row.git?.repo?.lowercased() else { return [] }
        return github.pullRequests.filter { $0.repo.lowercased() == repo }
    }

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.8)
            trailing()
        }
        .foregroundStyle(Palette.text3)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var pullRequestSection: some View {
        let needs = github.pullRequests.filter { $0.status.needsYou }.count
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("PULL REQUESTS") {
                Spacer()
                if needs > 0 {
                    Text(needs == 1 ? "1 needs you" : "\(needs) need you")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.attention)
                }
            }
            ForEach(github.pullRequests.prefix(8)) { pr in
                PullRequestRowView(pr: pr)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var duetSection: some View {
        let needs = chats.duetTasks.filter { $0.needsInput }.count
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("DUET TASKS") {
                // The header is a way into Duet whether or not there are tasks.
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 14, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { chats.openDuet(nil) }
                    .help("Open Claude Duet")
                if needs > 0 {
                    Text(needs == 1 ? "· 1 needs input" : "· \(needs) need input")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.attention)
                }
                Spacer()
                if let seen = chats.duetSeenAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(context.date.timeIntervalSince(seen) < 60 ? "live" : "as of \(Format.ago(seen, now: context.date)) ago")
                            .font(.system(size: 10))
                    }
                    .help("Duet's tasks can only be read while Duet is open in the Claude app. Otherwise this is the last list seen.")
                }
            }
            if chats.duetTasks.isEmpty {
                DuetEmptyRowView { chats.openDuet(nil) }
            } else {
                ForEach(chats.duetTasks.prefix(8)) { task in
                    DuetTaskRowView(task: task,
                                    open: { chats.openDuet(task) },
                                    complete: { chats.completeDuet(task) })
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var artifactSection: some View {
        // Already ordered by the store: tags for you, new shares, your recent work, then comment activity.
        // Your own recent work is capped at four so it cannot crowd out what other people are doing.
        let urgent = artifacts.items.filter { ($0.mentions ?? 0) > 0 || $0.newShareAt != nil }
        let rest = artifacts.items.filter { ($0.mentions ?? 0) == 0 && $0.newShareAt == nil }
        let active = Array(rest.filter { $0.isActive }.prefix(4))
        let others = rest.filter { !$0.isActive && $0.isCollaboration }
        let shown = Array((urgent + active + others).prefix(max(8, urgent.count)))
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("ARTIFACTS") {
                Spacer()
                if let at = artifacts.updatedAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(context.date.timeIntervalSince(at) < 60 ? "just updated" : "as of \(Format.ago(at, now: context.date)) ago").font(.system(size: 10))
                    }
                    .help("Artifacts and comments come from a snapshot a Claude session writes. They are not live.")
                }
            }
            ForEach(shown) { item in
                ArtifactRowView(item: item)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var chatSection: some View {
        let hidden = Set(settings.hiddenChats)
        // Hidden chats are dropped before the limit is applied, so hiding one pulls the next one up.
        let available = chats.chats.filter { !hidden.contains($0.title) }
        let visible = Array(available.prefix(layout.chatLimit))
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("CHATS") {
                if !hidden.isEmpty {
                    Text("· \(hidden.count) hidden")
                        .font(.system(size: 10))
                        .underline()
                        .contentShape(Rectangle())
                        .onTapGesture { layout.showSettings = true }
                        .help("Show the hidden chats list")
                }
                Spacer()
                if let seen = chats.seenAt, chats.trusted {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        // Under a minute old means the Claude tab is open and the list is live.
                        Text(context.date.timeIntervalSince(seen) < 60 ? "live" : "as of \(Format.ago(seen, now: context.date)) ago")
                            .font(.system(size: 10))
                    }
                    .help("Claude only lists chats while its Claude tab is open. On the Code tab this is the last list seen.")
                }
            }

            if !chats.trusted {
                hint("Allow Accessibility access to list chats", action: chats.requestAccess)
            } else if chats.chats.isEmpty {
                hint("Open the Claude tab once to load your chats", action: nil)
            } else if visible.isEmpty {
                hint("All recent chats are hidden", action: nil)
            } else {
                ForEach(visible) { chat in
                    ChatRowView(chat: chat,
                                open: { chats.open(chat) },
                                hide: { settings.hideChat(chat.title) })
                }
                HStack(spacing: 14) {
                    if available.count > visible.count, layout.chatLimit < PanelLayout.chatMax {
                        let next = min(PanelLayout.chatPage,
                                       PanelLayout.chatMax - layout.chatLimit,
                                       available.count - visible.count)
                        pager("Load \(next) more") {
                            layout.chatLimit = min(PanelLayout.chatMax, layout.chatLimit + PanelLayout.chatPage)
                        }
                    }
                    if layout.chatLimit > PanelLayout.chatPage {
                        pager("Show fewer") { layout.chatLimit = PanelLayout.chatPage }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 6)
    }

    private func pager(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.text2)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func hint(_ text: String, action: (() -> Void)?) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(action == nil ? Palette.text3 : Palette.attention)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { action?() }
    }

    @ViewBuilder private func sessionList(limit: Int?) -> some View {
        if store.rows.isEmpty {
            Text("No sessions active in the last \(Format.span(hours: settings.recentHours))")
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 22)
        } else {
            let shown = limit.map { Array(store.rows.prefix($0)) } ?? store.rows
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader("CODE") { Spacer() }
                    .padding(.top, -8)
                ForEach(shown) { row in
                    SessionRowView(row: row,
                                   pullRequests: settings.showGitHub ? pullRequests(for: row) : [],
                                   showGit: settings.showGit,
                                   showContext: settings.showContext,
                                   action: { open(row) },
                                   dismiss: { store.markSeen(row) })
                }
                if store.rows.count > shown.count {
                    Text("+\(store.rows.count - shown.count) more · drag the panel taller to see them")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var header: some View {
        let waiting = store.rows.filter { $0.state == .needsYou }.count
        let asking = store.rows.filter { $0.state == .needsInput }.count
        let working = store.rows.filter { $0.state == .working }.count
        return HStack(spacing: 10) {
            LogoMark()
                .frame(width: 15, height: 15)
                .padding(.trailing, -3)
            Text("CLAUDE PULSE")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.2)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.text2)
            // Counts with their words where there is room, bare counts where there is not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    if asking > 0 { Tally(count: asking, label: asking == 1 ? "needs answer" : "need answers", color: Palette.attention) }
                    if waiting > 0 { Tally(count: waiting, label: "done", color: Palette.done) }
                    if working > 0 { Tally(count: working, label: "working", color: Palette.working) }
                }
                HStack(spacing: 8) {
                    if asking > 0 { Tally(count: asking, label: "", color: Palette.attention) }
                    if waiting > 0 { Tally(count: waiting, label: "", color: Palette.done) }
                    if working > 0 { Tally(count: working, label: "", color: Palette.working) }
                }
            }
            .help("\(asking) waiting on your answer · \(waiting) done · \(working) working")
            Spacer(minLength: 4)
            LiveBadge(store: store, connections: connections) { layout.showSettings = true }
            Menu {
                Button("New Code session") { Self.openLink("claude://code/new") }
                Button("New chat") { Self.openLink("claude://claude.ai/new?surface=chat") }
                Divider()
                Button("Sessions waiting for you") { Self.openLink("claude://code/needs-input") }
                Button("Search sessions") { Self.openLink("claude://code/search") }
            } label: {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Palette.text2)
            .help("Quick actions")

            Image(systemName: "minus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.text2)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { layout.minimized = true }
                .help("Minimize to a ticker")

            Button {
                layout.showSettings.toggle()
            } label: {
                Image(systemName: layout.showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(layout.showSettings ? Palette.text : Palette.text2)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(layout.showSettings ? "Close settings" : "Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private static func openLink(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    @ViewBuilder private var footer: some View {
        if settings.showUsage, !layout.showSettings, let plan = store.plan {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 12) {
                    Meter(label: "5h", percent: plan.fiveHour)
                    Meter(label: "7d", percent: plan.sevenDay)
                    Spacer()
                    Text(context.date.timeIntervalSince(plan.sampledAt) < 60 ? "plan · just now" : "plan · \(Format.ago(plan.sampledAt, now: context.date)) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.text3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .help("Plan usage as last sampled by Claude Desktop. It is not live.")
        } else {
            Color.clear.frame(height: 8)
        }
    }
}

/// The Claude Pulse mark: a six-ray burst with a pulse line where the horizontal rays would be.
/// Same geometry as assets/logo.svg, drawn on a 512 grid.
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 360   // the mark spans about 360 of the 512 grid
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: size.width / 2 + (x - 256) * scale, y: size.height / 2 + (y - 256) * scale)
            }
            var rays = Path()
            for degrees in [45.0, 90, 135, 225, 270, 315] {
                let a = degrees * .pi / 180
                rays.move(to: point(256 + 84 * cos(a), 256 - 84 * sin(a)))
                rays.addLine(to: point(256 + 158 * cos(a), 256 - 158 * sin(a)))
            }
            context.stroke(rays, with: .color(Palette.attention),
                           style: StrokeStyle(lineWidth: 40 * scale, lineCap: .round))

            var pulse = Path()
            let points: [(CGFloat, CGFloat)] = [(86, 256), (218, 256), (236, 212), (262, 302), (282, 232), (294, 256), (426, 256)]
            pulse.move(to: point(points[0].0, points[0].1))
            for p in points.dropFirst() { pulse.addLine(to: point(p.0, p.1)) }
            context.stroke(pulse, with: .color(Palette.text),
                           style: StrokeStyle(lineWidth: 30 * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Claude Pulse")
    }
}

struct ConnectionLine: Identifiable {
    enum State { case ok, problem, down }
    let name: String
    let state: State
    let detail: String
    var id: String { name }
}

/// The header's status light. "Live" means Claude Desktop is running, the session reader is
/// keeping up, and every data source you have switched on is working.
private struct LiveBadge: View {
    let store: SessionStore
    let connections: [ConnectionLine]
    let openSettings: () -> Void

    static let warning = Color(red: 0.788, green: 0.522, blue: 0.000)  // #C98500

    var body: some View {
        // The reader's heartbeat is polled here, so a stalled reader shows up within seconds.
        TimelineView(.periodic(from: .now, by: 3)) { context in
            let stalled = context.date.timeIntervalSince(store.lastReadAt) > 12
            let down = connections.contains { $0.state == .down }
            let problems = connections.filter { $0.state == .problem }
            let (label, color): (String, Color) =
                down ? ("Offline", Palette.text3)
                : stalled ? ("Paused", Palette.text3)
                : !problems.isEmpty ? ("Limited", Self.warning)
                : ("Live", Palette.done)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.text2)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openSettings)
            .help((stalled && !down ? ["The session reader has stopped updating."] : [])
                  .appending(contentsOf: connections.map { "\($0.state == .ok ? "✓" : "!") \($0.name): \($0.detail)" })
                  .joined(separator: "\n"))
        }
    }
}

private extension Array {
    func appending(contentsOf other: [Element]) -> [Element] { self + other }
}

struct Headline: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let label: String
    let text: String
    let action: () -> Void
}

/// The minimized panel: one line that rotates through what needs you, like a news ticker.
private struct TickerView: View {
    let headlines: [Headline]
    let expand: () -> Void
    @State private var hovering = false

    private let interval: TimeInterval = 4

    var body: some View {
        HStack(spacing: 10) {
            if headlines.isEmpty {
                Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(Palette.text3)
                Text("All quiet").font(.system(size: 12)).foregroundStyle(Palette.text3)
                Spacer(minLength: 0)
            } else {
                TimelineView(.periodic(from: .now, by: interval)) { context in
                    let index = Int(context.date.timeIntervalSinceReferenceDate / interval) % headlines.count
                    let item = headlines[index]
                    HStack(spacing: 7) {
                        Image(systemName: item.icon)
                            .font(.system(size: item.icon == "circle.fill" ? 7 : 10.5, weight: .semibold))
                            .foregroundStyle(item.color)
                            .frame(width: 13)
                        Text(item.label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(item.color)
                            .fixedSize()
                        Text(item.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: item.action)
                    .id(item.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
                    .animation(.easeInOut(duration: 0.35), value: item.id)
                }
                .clipped()
                if headlines.count > 1 {
                    Text("\(headlines.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.track))
                        .help("\(headlines.count) items in rotation")
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Palette.text : Palette.text2)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onTapGesture(perform: expand)
                .help("Expand the panel")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .onHover { hovering = $0 }
    }
}

private struct Tally: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label.isEmpty ? "\(count)" : "\(count) \(label)")
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
        }
    }
}

private struct Meter: View {
    let label: String
    let percent: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.text3)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(percent >= 80 ? Palette.attention : Palette.text2)
                    .frame(width: max(2, 44 * CGFloat(min(percent, 100)) / 100))
            }
            .frame(width: 44, height: 3)
            Text("\(percent)%")
                .font(.system(size: 10))
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// How full the session's context window is. Turns clay at 80%, when compaction is getting close.
private struct ContextBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.track)
            Capsule()
                .fill(fraction >= 0.8 ? Palette.attention : Palette.text2)
                .frame(width: max(2, 26 * fraction))
        }
        .frame(width: 26, height: 3)
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    var pullRequests: [PullRequest] = []
    var showGit = true
    var showContext = true
    let action: () -> Void
    var dismiss: () -> Void = {}
    @State private var hovering = false

    /// Orange when Claude is waiting on an answer from you, green when it simply finished.
    private var accent: Color { row.state == .needsInput ? Palette.attention : Palette.done }

    /// The loud part: a solid bar on any session whose next move is yours.
    private var doneBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: row.state == .needsInput ? "questionmark.bubble.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(row.state == .needsInput
                 ? (row.prompt.map { "Answer me: \($0)" } ?? "Waiting on your answer")
                 : "Done. Get back to me")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Format.ago(row.lastActivity, now: context.date) == "now"
                     ? "just now"
                     : "\(Format.ago(row.lastActivity, now: context.date)) ago")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
            }
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .help("Mark as seen without opening")
        }
        .foregroundStyle(Palette.background)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent))
        .padding(.top, 4)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(state: row.state)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 12.5, weight: row.wantsYou ? .semibold : .medium))
                        .foregroundStyle(row.state == .idle ? Palette.text2 : Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(trailing(now: context.date))
                            .font(.system(size: 10.5, weight: row.state == .idle ? .regular : .medium))
                            .foregroundStyle(trailingColor)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 9.5))
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if showContext, row.tokens.context > 0 {
                        HStack(spacing: 5) {
                            ContextBar(fraction: row.contextFraction)
                            Text("\(Int((row.contextFraction * 100).rounded()))% · \(Format.tokens(row.tokens.context)) ctx")
                                .foregroundStyle(row.contextFraction >= 0.8 ? Palette.attention : Palette.text3)
                        }
                        .monospacedDigit()
                        .fixedSize()
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.text3)
                if showGit, row.git != nil || row.pr != nil || !pullRequests.isEmpty {
                    gitLine
                }
                if row.wantsYou {
                    doneBanner
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.wantsYou
                      ? accent.opacity(hovering ? 0.16 : 0.09)
                      : (hovering ? Palette.raised : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(row.wantsYou ? accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(tooltip)
        .contextMenu {
            if row.desktopId != nil { Button("Open in Claude", action: action) }
            if row.wantsYou { Button("Mark as seen", action: dismiss) }
            Button("Show project in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.cwd)
            }
            if let id = row.cliSessionId {
                Button("Copy session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
        }
    }

    private var gitLine: some View {
        HStack(spacing: 4) {
            if let git = row.git {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(gitSummary(git)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !pullRequests.isEmpty {
                // Live GitHub state for this project's repository.
                let needs = pullRequests.filter { $0.status.needsYou }.count
                Text(pullRequests.count == 1
                     ? "PR #\(pullRequests[0].number) \(pullRequests[0].status.label)"
                     : "\(pullRequests.count) PRs" + (needs > 0 ? " · \(needs) need you" : ""))
                    .foregroundStyle(needs > 0 ? Palette.attention : Palette.text2)
                    .underline(hovering)
                    .fixedSize()
                    .onTapGesture {
                        let link = pullRequests.count == 1
                            ? pullRequests[0].url
                            : "https://github.com/\(pullRequests[0].repo)/pulls"
                        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                    }
                    .help(pullRequests.map { "#\($0.number) \($0.title): \($0.status.label)" }.joined(separator: "\n"))
            } else if let pr = row.pr {
                Text("PR #\(pr.number) \(pr.state.lowercased())")
                    .foregroundStyle(pr.state == "OPEN" ? Palette.text2 : Palette.text3)
                    .underline(hovering)
                    .fixedSize()
                    .onTapGesture {
                        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                    }
                    .help("Open the pull request. State is as Claude Desktop last recorded it.")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Palette.text3)
        .monospacedDigit()
    }

    private func gitSummary(_ git: GitInfo) -> String {
        var parts = [git.branch]
        if git.changed > 0 { parts.append("\(git.changed) changed") }
        if git.ahead > 0 { parts.append("\(git.ahead) to push") }
        if git.behind > 0 { parts.append("\(git.behind) behind") }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        [row.project, row.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func trailing(now: Date) -> String {
        switch row.state {
        case .needsYou, .needsInput: return ""
        case .working: return "working"
        case .idle: return Format.ago(row.lastActivity, now: now)
        }
    }

    private var trailingColor: Color {
        switch row.state {
        case .needsInput: return Palette.attention
        case .needsYou: return Palette.done
        case .working: return Palette.working
        case .idle: return Palette.text3
        }
    }

    private var tooltip: String {
        var lines = [row.title, row.cwd]
        if let w = row.waitingFor { lines.append("Waiting for: \(w)") }
        let t = row.tokens
        if t.context > 0 {
            lines.append("Context: \(t.context.formatted()) of about \(Format.tokens(row.contextWindow)) tokens (\(Int((row.contextFraction * 100).rounded()))% full; window size is inferred)")
            lines.append("Session total: \(t.input.formatted()) new input · \(t.cacheRead.formatted()) cached input · \(t.output.formatted()) output")
        }
        if row.desktopId == nil { lines.append("Running outside Claude Desktop") }
        return lines.joined(separator: "\n")
    }
}

private struct StatusDot: View {
    let state: SessionState

    var body: some View {
        ZStack {
            switch state {
            case .working:
                PulseHalo().frame(width: 8, height: 8)
                Circle().fill(Palette.working).frame(width: 8, height: 8)
            case .needsInput:
                Circle().fill(Palette.attention).frame(width: 8, height: 8)
            case .needsYou:
                Circle().fill(Palette.done).frame(width: 8, height: 8)
            case .idle:
                Circle().strokeBorder(Palette.idle, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Expanding ring behind a working dot. Drawn with Core Animation so the loop runs in the
/// window server; a SwiftUI `repeatForever` here cost a few percent CPU all day.
private struct PulseHalo: NSViewRepresentable {
    final class HaloView: NSView {
        private let ring = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            ring.backgroundColor = NSColor(Palette.working).withAlphaComponent(0.4).cgColor
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            ring.frame = bounds
            ring.cornerRadius = bounds.width / 2
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ring.removeAllAnimations()
            guard window != nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.5
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "pulse")
        }
    }

    func makeNSView(context: Context) -> HaloView { HaloView() }
    func updateNSView(_ nsView: HaloView, context: Context) {}
}

/// Shown when Duet has nothing active; still a way into Duet.
private struct DuetEmptyRowView: View {
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("No active Duet tasks")
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Palette.text2 : Palette.text3)
            Spacer(minLength: 4)
            Text("Open Duet")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovering ? Palette.text : Palette.text2)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Palette.text2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Open Claude Duet in the Claude app")
    }
}

struct DuetTaskRowView: View {
    let task: DuetTask
    let open: () -> Void
    let complete: () -> Void
    @State private var hovering = false
    @State private var completing = false

    private var color: Color {
        task.needsInput ? Palette.attention : task.readyForReview ? Palette.done : Palette.text3
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.needsInput ? "questionmark.bubble.fill" : task.readyForReview ? "checkmark.circle" : "circle.dotted")
                .font(.system(size: 9.5))
                .foregroundStyle(color)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.title)
                        .font(.system(size: 12, weight: task.needsInput ? .semibold : .regular))
                        .foregroundStyle(task.needsInput ? Palette.text : Palette.text2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if completing {
                        Text("completing…")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.text3)
                            .fixedSize()
                    } else if hovering {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .medium))
                            Text("Mark complete").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Palette.text)
                        .fixedSize()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            completing = true
                            complete()
                            // If the tick does not land, the row comes back to normal.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { completing = false }
                        }
                        .help("Mark this task complete in Duet. Claude's window visits Duet briefly to do it.")
                    } else {
                        Text(task.status.lowercased())
                            .font(.system(size: 10, weight: task.needsInput ? .medium : .regular))
                            .foregroundStyle(color)
                            .fixedSize()
                    }
                }
                if let summary = task.summary {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(task.needsInput
                      ? Palette.attention.opacity(hovering ? 0.16 : 0.09)
                      : (hovering ? Palette.raised : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help([task.title, task.status, task.summary ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

private struct SkillIdeaRowView: View {
    let idea: Insights.SkillIdea
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var started = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: started ? "checkmark" : "lightbulb")
                .font(.system(size: 9.5))
                .foregroundStyle(started ? Palette.done : Palette.attention)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(idea.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Palette.text2)
                            .frame(width: 16, height: 14)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismiss)
                            .help("Not interested")
                    } else if let seen = idea.seen {
                        Text("asked ~\(seen)×")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.text3)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                Text(started ? "Prompt copied. Paste it into the new session if it is not already there." : idea.why)
                    .font(.system(size: 10.5))
                    .foregroundStyle(started ? Palette.done : Palette.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: start)
        .help("Start a new Code session that builds this skill. The request is also copied to the clipboard.\n\n" + idea.prompt)
    }

    /// Copies the request, then opens a new Code session with it filled in where Claude allows.
    private func start() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(idea.prompt, forType: .string)
        var link = URLComponents(string: "claude://code/new")
        link?.queryItems = [URLQueryItem(name: "q", value: idea.prompt)]
        if let url = link?.url { NSWorkspace.shared.open(url) }
        started = true
    }
}

private struct PullRequestRowView: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pr.kind == .reviewRequested ? "eye" : "arrow.triangle.pull")
                .font(.system(size: 9.5))
                .foregroundStyle(pr.status.needsYou ? Palette.attention : Palette.text3)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pr.title)
                        .font(.system(size: 12, weight: pr.status.needsYou ? .semibold : .regular))
                        .foregroundStyle(pr.status.needsYou ? Palette.text : Palette.text2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(pr.status.label)
                        .font(.system(size: 10, weight: pr.status.needsYou ? .medium : .regular))
                        .foregroundStyle(statusColor)
                        .fixedSize()
                }
                Text("\(pr.repo) #\(pr.number)" + (pr.kind == .reviewRequested && !pr.author.isEmpty ? " · by \(pr.author)" : ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        }
        .help("Open the pull request on GitHub")
    }

    private var statusColor: Color {
        switch pr.status {
        case .readyToMerge: return Palette.done
        case .reviewRequested, .checksFailing, .changesRequested: return Palette.attention
        case .checksRunning, .awaitingReview, .draft: return Palette.text3
        }
    }
}

private struct ArtifactRowView: View {
    let item: ArtifactItem
    @State private var hovering = false

    private var waiting: Int { item.mentions ?? 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.newShareAt != nil ? "person.badge.plus" : item.owner == "shared" ? "person.2" : "doc.richtext")
                .font(.system(size: 9.5))
                .foregroundStyle(waiting > 0 || item.newShareAt != nil ? Palette.attention : Palette.text3)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 12, weight: waiting > 0 || item.newShareAt != nil ? .semibold : .regular))
                        .foregroundStyle(waiting > 0 || item.newShareAt != nil || item.isActive ? Palette.text : Palette.text2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(trailing)
                        .font(.system(size: 10, weight: waiting > 0 || item.newShareAt != nil ? .medium : .regular))
                        .foregroundStyle(waiting > 0 || item.newShareAt != nil ? Palette.attention : Palette.text3)
                        .monospacedDigit()
                        .fixedSize()
                }
                if waiting > 0, let preview = item.mentionPreview {
                    Text("\(item.lastCommentBy.map { $0 + ": " } ?? "")\(preview)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        }
        .help(tooltip)
    }

    private var trailing: String {
        if waiting > 0 { return waiting == 1 ? "1 tag for you" : "\(waiting) tags for you" }
        if item.newShareAt != nil { return "newly shared with you" }
        if item.isActive, let days = item.daysSinceUpdate() {
            return days <= 0 ? "you edited today" : days == 1 ? "you edited yesterday" : "you edited \(days)d ago"
        }
        if let threads = item.threads, threads > 0 { return threads == 1 ? "1 comment thread" : "\(threads) comment threads" }
        return item.owner == "shared" ? "shared with you" : ""
    }

    private var tooltip: String {
        var lines = [item.title, item.owner == "shared" ? "Shared with you" : "Yours"]
        if let open = item.openThreads, let all = item.threads { lines.append("\(open) of \(all) comment threads open") }
        if let by = item.lastCommentBy, let at = item.lastCommentAt {
            lines.append("Last comment: \(by), \(Format.ago(at)) ago")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ChatRowView: View {
    let chat: ChatItem
    let open: () -> Void
    let hide: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.text3)
                .frame(width: 12)
            Text(chat.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.text2)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: hide)
                    .help("Hide this chat from the panel")
            } else if let badge = chat.badge {
                Text(badge.replacingOccurrences(of: "Includes an artifact", with: "artifact"))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Palette.raised : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open in Claude", action: open)
            Button("Hide from panel", action: hide)
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var github: GitHubReader
    var connections: [ConnectionLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Connections") {
                ForEach(connections) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(line.state == .ok ? Palette.done : line.state == .down ? Palette.text3 : LiveBadge.warning)
                            .frame(width: 6, height: 6)
                        Text(line.name).font(.system(size: 12)).foregroundStyle(Palette.text)
                        Spacer(minLength: 8)
                        Text(line.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(line.state == .ok ? Palette.text3 : Palette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            section("Sections") {
                toggle("Code", $settings.showCode)
                toggle("Pull requests", $settings.showGitHub)
                toggle("Duet tasks", $settings.showDuet)
                toggle("Artifacts", $settings.showArtifacts)
                toggle("Chats", $settings.showChats)
                toggle("Skills worth creating", $settings.showSkillIdeas)
                toggle("Your usage and limits", $settings.showUsage)
            }
            section("On each Code row") {
                toggle("Git branch and changes", $settings.showGit)
                toggle("Context meter", $settings.showContext)
                choice("Keep idle sessions for", $settings.recentHours,
                       [(6, "6h"), (24, "1d"), (72, "3d"), (168, "7d")])
            }
            section("Notifications") {
                toggle("Notifications", $settings.notifyOnFinish)
                if settings.notifyOnFinish {
                    // What to be told about. These sit under the master switch above.
                    Group {
                        toggle("Sessions done or waiting on you", $settings.notifySessions)
                        if settings.notifySessions {
                            choice("Remind if still waiting", $settings.remindMinutes,
                                   [(0, "Off"), (5, "5m"), (15, "15m"), (30, "30m")])
                        }
                        toggle("Artifact tags and new shares", $settings.notifyArtifacts)
                        toggle("Duet tasks needing input", $settings.notifyDuet)
                    }
                    .padding(.leading, 12)
                } else {
                    Text("Claude Pulse will not send any notifications. The panel still shows everything.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !settings.hiddenChats.isEmpty {
                section("Hidden chats") {
                    ForEach(settings.hiddenChats, id: \.self) { title in
                        HStack {
                            Text(title)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.text2)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            link("Show") { settings.unhideChat(title) }
                        }
                    }
                    if settings.hiddenChats.count > 1 {
                        link("Show all") { settings.hiddenChats = [] }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func link(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.attention)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Palette.text3)
            content()
        }
    }

    private func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.text)
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Palette.attention)
        }
    }

    private func choice(_ label: String, _ value: Binding<Int>, _ options: [(Int, String)]) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { option in
                    let selected = value.wrappedValue == option.0
                    Text(option.1)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.text : Palette.text3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Palette.raised : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { value.wrappedValue = option.0 }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.track))
        }
    }
}
