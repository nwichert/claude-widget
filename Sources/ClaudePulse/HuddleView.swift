import AppKit
import Combine
import SwiftUI

/// The huddle's own accent: a lime for progress and for the agent that needs you.
enum HuddlePalette {
    static let lime = Color(red: 0.831, green: 0.973, blue: 0.290)        // #D4F84A
    static let card = Color(red: 0.200, green: 0.200, blue: 0.192)
    static let inset = Color(red: 0.122, green: 0.122, blue: 0.118)
    static let robots: [Color] = [
        Color(red: 0.231, green: 0.494, blue: 0.965),   // blue
        Color(red: 0.957, green: 0.400, blue: 0.635),   // pink
        Color(red: 0.976, green: 0.596, blue: 0.231),   // orange
        Color(red: 0.612, green: 0.459, blue: 0.937),   // violet
        Color(red: 0.235, green: 0.773, blue: 0.659),   // teal
        Color(red: 0.937, green: 0.800, blue: 0.231),   // yellow
    ]
}

/// A small pixel robot: square head, two eyes, a mouth, two legs, and a shadow.
struct PixelRobot: View {
    var color: Color
    var size: CGFloat = 40
    var blink = false

    var body: some View {
        let u = size / 10
        ZStack(alignment: .topLeading) {
            Ellipse().fill(Color.black.opacity(0.45))
                .frame(width: u * 6, height: u * 1.1)
                .offset(x: u * 2, y: u * 9)
            // legs
            Rectangle().fill(color.opacity(0.85)).frame(width: u, height: u * 1.6).offset(x: u * 3, y: u * 7.2)
            Rectangle().fill(color.opacity(0.85)).frame(width: u, height: u * 1.6).offset(x: u * 6, y: u * 7.2)
            // head
            RoundedRectangle(cornerRadius: u * 1.1, style: .continuous).fill(color)
                .frame(width: u * 8, height: u * 7)
                .offset(x: u, y: u * 0.5)
            RoundedRectangle(cornerRadius: u * 1.1, style: .continuous).fill(Color.black.opacity(0.16))
                .frame(width: u * 8, height: u * 1.2)
                .offset(x: u, y: u * 6.3)
            // eyes
            Rectangle().fill(Color.black.opacity(0.82)).frame(width: u * 1.2, height: blink ? u * 0.3 : u * 1.6)
                .offset(x: u * 3, y: u * (blink ? 3.3 : 2.6))
            Rectangle().fill(Color.black.opacity(0.82)).frame(width: u * 1.2, height: blink ? u * 0.3 : u * 1.6)
                .offset(x: u * 5.8, y: u * (blink ? 3.3 : 2.6))
            // mouth
            Rectangle().fill(Color.black.opacity(0.82)).frame(width: u * 2.4, height: u * 0.6)
                .offset(x: u * 2.4, y: u * 5)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

final class HuddleLayout: ObservableObject {
    /// One state for the window and the docked copy, so folding or opening a card carries over.
    static let shared = HuddleLayout()
    @Published var collapsed = UserDefaults.standard.bool(forKey: "huddleCollapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "huddleCollapsed") }
    }
    /// Cards showing their checklist and terminal, by agent id.
    @Published var expanded: Set<String> = []
}

/// Where the huddle lives: floating in its own window, or docked in Pulse's panel between two
/// sections. Dragging the huddle's header moves it; letting go over the panel docks it where the
/// clay line shows, and letting go anywhere else floats it there.
final class HuddleDock: ObservableObject {
    static let shared = HuddleDock()

    /// The panel section the docked huddle follows ("top" for above them all); nil while floating.
    @Published var anchor: String? = UserDefaults.standard.string(forKey: "huddleDockAnchor") {
        didSet { UserDefaults.standard.set(anchor, forKey: "huddleDockAnchor") }
    }
    /// Hidden with its close button or the menu. Docked or floating, it comes back where it was.
    @Published var hidden = UserDefaults.standard.bool(forKey: "huddleHidden") {
        didSet { UserDefaults.standard.set(hidden, forKey: "huddleHidden") }
    }
    @Published private(set) var dragging = false
    /// Where it would dock if let go now.
    @Published private(set) var dropAnchor: String?

    /// The panel's visible sections, top to bottom, in the panel's own view coordinates
    /// (origin top-left). Reported by the panel as it lays out.
    var slots: [(id: String, frame: CGRect)] = []
    /// Converts a point in screen coordinates to the panel's view coordinates; nil when the
    /// panel is hidden, minimized, or showing settings.
    var panelPoint: ((NSPoint) -> CGPoint?)?
    /// The floating window's frame and a way to move it, from its controller.
    var floatingFrame: (() -> NSRect)?
    var moveFloating: ((NSPoint) -> Void)?

    private var grab = NSPoint.zero

    /// The docked huddle's header, in the panel's view coordinates: the handle for dragging it out.
    var dockedHeader: CGRect? {
        guard anchor != nil, let f = slots.first(where: { $0.id == "huddle" })?.frame, f.height > 1 else { return nil }
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: 40)
    }

    /// The section a drop at this screen point would follow, or nil if it is not over the panel.
    func anchor(at screen: NSPoint) -> String? {
        guard let p = panelPoint?(screen) else { return nil }
        let visible = slots.filter { $0.frame.height > 1 && $0.id != "huddle" }
        guard !visible.isEmpty else { return "top" }
        var previous = "top"
        for slot in visible {
            if p.y < slot.frame.midY { return previous }
            previous = slot.id
        }
        return previous
    }

    func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if !dragging {
            dragging = true
            if anchor == nil, let f = floatingFrame?() {
                grab = NSPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
            } else {
                grab = NSPoint(x: 60, y: 16)  // pick the docked huddle up by its header
            }
        }
        moveFloating?(NSPoint(x: mouse.x - grab.x, y: mouse.y + grab.y))
        let target = anchor(at: mouse)
        if dropAnchor != target { dropAnchor = target }
    }

    func dragEnded() {
        guard dragging else { return }
        anchor = anchor(at: NSEvent.mouseLocation)
        dropAnchor = nil
        dragging = false
    }
}

/// The handle behind the huddle's header. A native view, so a press on it never moves the
/// window it sits in (Pulse's panel moves when dragged by its background), and it runs the drag
/// that carries the huddle in and out of the panel.
private struct HuddleDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        private var start: NSPoint?
        private var moving = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            moving = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            if !moving, hypot(now.x - start.x, now.y - start.y) < 3 { return }
            moving = true
            HuddleDock.shared.dragMoved()
        }
        override func mouseUp(with event: NSEvent) {
            if moving { HuddleDock.shared.dragEnded() }
            start = nil
            moving = false
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {}
}

struct HuddleView: View {
    @ObservedObject var store: HuddleStore
    @ObservedObject var layout: HuddleLayout
    /// Shown inside Pulse's panel rather than in its own window.
    var docked = false
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !layout.collapsed {
                if store.agents.isEmpty {
                    Text("No agents running. Sessions show up here while Claude is working on them.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text3)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.agents.prefix(8)) { agent in
                        HuddleCard(agent: agent, store: store,
                                   expanded: layout.expanded.contains(agent.id)) {
                            if layout.expanded.contains(agent.id) { layout.expanded.remove(agent.id) }
                            else { layout.expanded.insert(agent.id) }
                        }
                    }
                }
                if !store.hookInstalled && store.agents.contains(where: { $0.waitsWithoutHook }) {
                    Text("To Allow, Deny or answer from here, turn on \"Answer from the huddle\" in Pulse settings.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.text3)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(docked ? 8 : 10)
        .frame(width: docked ? nil : 380, alignment: .leading)
        .frame(maxWidth: docked ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: docked ? 12 : 16, style: .continuous)
                .fill(docked ? Palette.raised.opacity(0.55) : Palette.background)
                .overlay(RoundedRectangle(cornerRadius: docked ? 12 : 16, style: .continuous).strokeBorder(Palette.border))
        )
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The title is the grip: the handle lies over it, as text would otherwise take the press.
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.text3)
                Circle().fill(store.agents.contains { $0.state == .working } ? HuddlePalette.lime : Palette.text3)
                    .frame(width: 8, height: 8)
                Text("Agent Huddle").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.text)
                Text("\(store.agents.count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text3)
            }
            .overlay(HuddleDragHandle())
            .help(docked ? "Drag out of the panel to float the huddle" : "Drag into the Pulse panel to dock it between sections")
            Spacer(minLength: 6)
            iconButton(store.muted ? "speaker.slash" : "speaker.wave.2",
                       help: store.muted ? "Turn the chime back on" : "Mute the chime") { store.muted.toggle() }
            iconButton(layout.collapsed ? "chevron.down" : "chevron.up",
                       help: layout.collapsed ? "Show the agents" : "Fold to the header") { layout.collapsed.toggle() }
            iconButton("xmark", help: "Hide the huddle") { close() }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .background(HuddleDragHandle())
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.text2)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The huddle as a section of Pulse's panel. While it is being dragged out it stays in place,
/// faded, so the drag is not cut short.
struct DockedHuddle: View {
    @ObservedObject var store: HuddleStore
    @ObservedObject var dock = HuddleDock.shared
    @ObservedObject var layout = HuddleLayout.shared

    var body: some View {
        HuddleView(store: store, layout: layout, docked: true) { dock.hidden = true }
            .opacity(dock.dragging ? 0.35 : 1)
    }
}

/// The clay line that shows where the huddle will land.
struct HuddleDropLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(Palette.attention).frame(height: 3)
            Text("Agent Huddle")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Palette.attention)
                .fixedSize()
            Capsule().fill(Palette.attention).frame(height: 3)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
    }
}

private struct HuddleCard: View {
    let agent: HuddleAgent
    @ObservedObject var store: HuddleStore
    let expanded: Bool
    let toggle: () -> Void

    private var color: Color { HuddlePalette.robots[agent.colorIndex % HuddlePalette.robots.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                PixelRobot(color: color, size: 42)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.title)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(agent.activity)
                        .font(.system(size: 11.5, weight: agent.needsYou ? .semibold : .regular))
                        .foregroundStyle(agent.needsYou ? HuddlePalette.lime : Palette.text2)
                        .lineLimit(1)
                    counter
                    if !agent.steps.isEmpty || agent.state == .needsYou {
                        ProgressTrack(value: agent.progress, working: agent.state == .working)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if agent.openURL != nil {
                        cardButton("arrow.up.right.square", help: "Open this session in Claude") { store.open(agent) }
                    }
                    cardButton("xmark", help: "Dismiss until it does something new") { store.dismiss(agent) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            switch agent.need {
            case .permission(let summary, let detail, let request):
                PermissionBox(summary: summary, detail: detail, request: request, agent: agent, store: store)
            case .question(let questions, let request):
                QuestionBox(questions: questions, request: request, agent: agent, store: store)
            case .closingQuestion(let text):
                ClosingQuestionBox(text: text, agent: agent, store: store)
            case .none:
                EmptyView()
            }

            if expanded {
                Divider().overlay(Palette.border)
                if agent.steps.isEmpty {
                    Text("No checklist yet. Claude writes one for longer tasks.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text3)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(agent.steps.prefix(12)) { step in StepRow(step: step) }
                        if agent.steps.count > 12 {
                            Text("and \(agent.steps.count - 12) more").font(.system(size: 10.5)).foregroundStyle(Palette.text3)
                        }
                    }
                }
                if let command = agent.command { TerminalBox(command: command) }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HuddlePalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(agent.needsYou ? HuddlePalette.lime : Color.clear, lineWidth: 2)
                )
        )
    }

    @ViewBuilder private var counter: some View {
        if !agent.steps.isEmpty {
            HStack(spacing: 5) {
                Text("\(agent.doneSteps)/\(agent.steps.count)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(HuddlePalette.lime)
                    .monospacedDigit()
                Text(agent.currentStep?.text ?? (agent.doneSteps == agent.steps.count ? "All steps done" : "Steps"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
            }
        } else {
            Text(agent.project)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
        }
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text2)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ProgressTrack: View {
    let value: Double
    let working: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(HuddlePalette.lime.opacity(working || value > 0 ? 1 : 0.4))
                    .frame(width: max(working ? 6 : 0, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

private struct StepRow: View {
    let step: HuddleStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                switch step.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.text3)
                case .inProgress:
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(Palette.text3.opacity(0.7))
                }
            }
            .font(.system(size: 13))
            .frame(width: 16, height: 14)
            Image(systemName: Self.icon(for: step.text))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.text3)
                .frame(width: 14)
            Text(step.text)
                .font(.system(size: 12, weight: step.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(step.status == .completed ? Palette.text3 : Palette.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A rough guess at the kind of work a step is, for its icon.
    static func icon(for text: String) -> String {
        let t = text.lowercased()
        if ["write", "edit", "add ", "fix", "update", "build ", "design", "draft", "rename", "refactor"].contains(where: t.contains) {
            return "pencil"
        }
        if ["run", "test", "render", "install", "deploy", "commit", "push", "build"].contains(where: t.contains) {
            return "terminal"
        }
        if ["read", "find", "look", "check", "review", "learn", "search"].contains(where: t.contains) {
            return "doc.text.magnifyingglass"
        }
        return "circle.dashed"
    }
}

private struct TerminalBox: View {
    let command: HuddleCommand

    private var tail: String {
        guard let output = command.output else { return "" }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
        return lines.map { String($0.prefix(120)) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "terminal").font(.system(size: 10))
                Text("Terminal").font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.raised))
            Text("$ " + command.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(HuddlePalette.lime)
                .lineLimit(3)
                .textSelection(.enabled)
            if command.output == nil {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("running for \(max(0, Int(ctx.date.timeIntervalSince(command.startedAt))))s…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.text2)
                }
            } else if !tail.isEmpty {
                Text(tail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(command.failed ? Palette.attention : Palette.text2)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text("finished with no output").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HuddlePalette.inset))
    }
}

/// A filled lime button for the main action, grey pills for the rest.
private struct Pill: View {
    let title: String
    var primary = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(primary ? Color.black : Palette.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(primary ? HuddlePalette.lime : Palette.raised.opacity(1.6)))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Palette.border))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct PermissionBox: View {
    let summary: String
    let detail: String?
    let request: HuddleRequest?
    let agent: HuddleAgent
    @ObservedObject var store: HuddleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(summary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.text)
                .lineLimit(4)
                .textSelection(.enabled)
            if let detail, !detail.isEmpty, !summary.contains(detail) {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.text3).lineLimit(2)
            }
            HStack(spacing: 7) {
                if let request {
                    Pill(title: "Allow", primary: true) { store.allow(request) }
                    Pill(title: "Deny") { store.deny(request) }
                }
                if agent.openURL != nil {
                    Pill(title: "In Claude", primary: request == nil) { store.open(agent) }
                }
            }
            if request == nil {
                Text(agent.openURL == nil
                     ? "Answer it where the session is running."
                     : "This prompt started before the huddle could take it. Answer it in Claude.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.text3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HuddlePalette.inset))
    }
}

private struct QuestionBox: View {
    let questions: [HuddleQuestion]
    let request: HuddleRequest?
    let agent: HuddleAgent
    @ObservedObject var store: HuddleStore
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var complete: Bool {
        questions.allSatisfy { q in
            !(picks[q.question] ?? []).isEmpty || !(other[q.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = q.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(HuddlePalette.lime))
                    }
                    Text(q.question)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options) { option in optionRow(q, option) }
                    if request != nil {
                        TextField("Something else…", text: Binding(
                            get: { other[q.question] ?? "" },
                            set: { other[q.question] = $0; if !$0.isEmpty, !q.multiSelect { picks[q.question] = [] } }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.raised))
                    }
                }
            }
            HStack(spacing: 7) {
                if let request {
                    Pill(title: "Send", primary: true, enabled: complete) { send(request) }
                }
                if agent.openURL != nil {
                    Pill(title: "Answer in Claude", primary: request == nil) { store.open(agent) }
                }
            }
            if request == nil {
                Text("This question started before the huddle could take it. Answer it in Claude.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.text3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HuddlePalette.inset))
    }

    private func optionRow(_ q: HuddleQuestion, _ option: HuddleQuestion.Option) -> some View {
        let chosen = picks[q.question]?.contains(option.label) == true
        return Button {
            var set = picks[q.question] ?? []
            if q.multiSelect {
                if chosen { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
                other[q.question] = ""
            }
            picks[q.question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: q.multiSelect ? (chosen ? "checkmark.square.fill" : "square")
                                                : (chosen ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(chosen ? HuddlePalette.lime : Palette.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                    if let d = option.detail, !d.isEmpty {
                        Text(d).font(.system(size: 10.5)).foregroundStyle(Palette.text3).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? HuddlePalette.lime : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(request == nil)
    }

    private func send(_ request: HuddleRequest) {
        var answers: [String: String] = [:]
        for q in questions {
            var chosen = q.options.map(\.label).filter { picks[q.question]?.contains($0) == true }
            let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { chosen.append(typed) }
            answers[q.question] = chosen.joined(separator: ", ")
        }
        store.answer(request, answers)
    }
}

private struct ClosingQuestionBox: View {
    let text: String
    let agent: HuddleAgent
    @ObservedObject var store: HuddleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                if agent.openURL != nil {
                    Pill(title: "Answer in Claude", primary: true) { store.open(agent) }
                }
            }
            Text("Claude asked this as its turn ended. The reply goes in as your next message, so it's typed in Claude.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HuddlePalette.inset))
    }
}

// MARK: - Window

private final class HuddleWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HuddleHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The huddle's own floating window, kept apart from the main panel so it can sit wherever you
/// work. It hugs its cards, with the top edge pinned.
final class HuddlePanelController: NSObject, NSWindowDelegate {
    private let panel: HuddleWindow
    private let hosting: NSView
    private let layout = HuddleLayout.shared
    private let dock = HuddleDock.shared
    private var cancellables = Set<AnyCancellable>()
    private let originKey = "huddleTopLeft"

    /// Shown, docked or floating: what the menu's Show / Hide goes by.
    var isVisible: Bool { Settings.shared.showHuddle && !dock.hidden }

    init(store: HuddleStore) {
        panel = HuddleWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let host = HuddleHostingView(rootView: HuddleView(store: store, layout: HuddleLayout.shared,
                                                         close: { HuddleDock.shared.hidden = true }))
        host.sizingOptions = [.intrinsicContentSize]
        hosting = host
        super.init()

        // One step above Pulse's panel, so it stays in view while dragged over it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Moved by its header only, so a drag can be followed into the panel.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        panel.delegate = self
        fit()
        restorePosition()

        dock.floatingFrame = { [weak self] in self?.panel.frame ?? .zero }
        dock.moveFloating = { [weak self] topLeft in
            guard let self else { return }
            self.panel.setFrameTopLeftPoint(topLeft)
            if !self.panel.isVisible { self.panel.orderFrontRegardless() }
        }

        store.objectWillChange.map { _ in () }
            .merge(with: layout.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.fit() } }
            .store(in: &cancellables)
        dock.objectWillChange.map { _ in () }
            .merge(with: Settings.shared.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    /// Floats only while on, not hidden, and not docked (or on its way out of the dock).
    func refresh() {
        let float = Settings.shared.showHuddle && !dock.hidden && (dock.anchor == nil || dock.dragging)
        if float && !panel.isVisible { fit(); panel.orderFrontRegardless() }
        if !float && panel.isVisible { panel.orderOut(nil) }
    }

    func show() { dock.hidden = false; refresh() }
    func hide() { dock.hidden = true; refresh() }
    func toggle() { isVisible ? hide() : show() }

    /// Unfolds the huddle if it was folded to its header, so a new request is in view.
    func reveal() {
        layout.collapsed = false
        show()
    }

    func snapshot(to path: String, expandAll: Bool = false, agents: [String] = []) {
        if expandAll { layout.expanded = Set(agents) }
        hosting.layoutSubtreeIfNeeded()
        fit()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private func fit() {
        let size = hosting.fittingSize
        guard size.height > 0 else { return }
        let maxHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(size.height, maxHeight - 20)
        let frame = panel.frame
        guard abs(frame.height - height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: size.width, height: height), display: true)
        panel.invalidateShadow()
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: p.x + 20, y: p.y - 20)) }) {
                panel.setFrameTopLeftPoint(p)
                return
            }
        }
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 24, y: visible.maxY - 24))
        }
    }

    func windowDidMove(_ notification: Notification) {
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: originKey)
    }
}

// MARK: - Settings

/// The huddle's switches, shown in Pulse's settings.
struct HuddleSettings: View {
    @Environment(\.uiScale) private var scale
    @ObservedObject var store: HuddleStore
    @ObservedObject private var settings = Settings.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Agent Huddle", $settings.showHuddle)
            note("A floating window with a card for each Claude Code agent: what it's doing, its checklist, its last command, and any permission or question it's waiting on.")
            if settings.showHuddle {
                VStack(alignment: .leading, spacing: 7) {
                    row("Answer from the huddle", Binding(
                        get: { store.hookInstalled },
                        set: { on in
                            error = HuddleHookInstaller.install(on)
                            store.refreshHookState()
                        }))
                    note(store.hookInstalled
                         ? "Pulse's hook is in ~/.claude/settings.json. Claude still shows its own prompt too, and whichever you answer first wins. Sessions started before you turned this on keep asking in Claude only."
                         : "Adds a small hook to ~/.claude/settings.json so Allow, Deny and question answers in the huddle reach the agent. Without it, you answer in Claude.")
                    if let error { note(error).foregroundStyle(Palette.attention) }
                    row("Chime when an agent needs you", Binding(get: { !store.muted }, set: { store.muted = !$0 }))
                    row("Bring the huddle up when an agent needs you", $store.openOnNeed)
                }
                .padding(.leading, 12)
            } else if store.hookInstalled {
                note("The answer hook is still in ~/.claude/settings.json but steps aside while the huddle is off.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5 * scale))
            .foregroundStyle(Palette.text3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 12 * scale)).foregroundStyle(Palette.text)
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Palette.attention)
        }
    }
}
