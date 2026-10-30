import QuartzCore
import SwiftUI
import ContextCore

/// The black island drawn over the notch: a status strip at rest, the chats and settings when open.
struct NotchIslandView: View {
    @ObservedObject var state: NotchIslandState
    let onHeight: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(width: NotchIslandController.panelSize.width, height: NotchIslandController.panelSize.height, alignment: .top)
    }

    private var island: some View {
        let expanded = state.mode == .expanded
        return VStack(spacing: 0) {
            header
            if state.mode == .peek, let peek = state.peek {
                NotchPeekLine(chat: peek.chat, waiting: peek.waiting)
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if expanded {
                NotchExpandedContent(state: state)
                    .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(width: width)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { onHeight(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in onHeight(height) }
        })
        .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
        .opacity(state.mode == .hidden ? 0 : 1)
        // Same curve as the controller's mode change; it also carries the peek and settings
        // updates the controller makes just before, outside its own animation.
        .animation(NotchIslandController.animation(reduceMotion: reduceMotion), value: state.mode)
    }

    private var width: CGFloat {
        let notch = state.notch.width, wing = NotchIslandController.wing
        return switch state.mode {
        case .hidden: notch
        case .compact: notch + wing * 2
        case .peek: notch + wing * 2 + 80
        case .expanded: NotchIslandController.expandedWidth
        }
    }
    private var radius: CGFloat { state.mode == .expanded ? 22 : state.mode == .peek ? 16 : 10 }

    /// The band beside the cut-out; nothing is drawn under the notch itself.
    private var header: some View {
        HStack(spacing: 0) {
            HStack {
                DeskBuddy(summary: state.summary, size: state.mode == .expanded ? 20 : 17, celebratedAt: state.celebratedAt,
                          look: state.look, paused: state.mode == .hidden)
            }
                .frame(maxWidth: .infinity, alignment: state.mode == .expanded ? .leading : .center)
            Color.clear.frame(width: state.notch.width)
            HStack {
                if state.mode == .expanded {
                    Button { withAnimation(NotchIslandController.animation(reduceMotion: reduceMotion)) { state.showingSettings.toggle() } } label: {
                        Image(systemName: state.showingSettings ? "xmark" : "gearshape.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L10n.text("Настройки острова", "Island settings"))
                } else {
                    NotchCountLabel(summary: state.summary)
                }
            }.frame(maxWidth: .infinity, alignment: state.mode == .expanded ? .trailing : .center)
        }
        .padding(.horizontal, state.mode == .expanded ? 18 : 6)
        .frame(height: state.notch.height)
    }
}

/// A chat row's status mark: a spinner while it works, a pulsing dot while it waits, a check when done.
private struct NotchStatusIndicator: View {
    let summary: NotchSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch summary {
            case .working: NotchLoopMark(kind: .spinner)
            // Reduce Motion keeps the orange dot and drops its expanding halo.
            case .waiting: NotchLoopMark(kind: reduceMotion ? .dot : .pulse).id(reduceMotion)
            case .finished:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
            case .idle:
                Circle().fill(.white.opacity(0.35)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Looping row marks on Core Animation, so they stay smooth while the main thread is busy.
private struct NotchLoopMark: NSViewRepresentable {
    enum Kind { case spinner, pulse, dot }
    let kind: Kind

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let root = CALayer()
        view.layer = root
        view.wantsLayer = true
        let box = CGRect(x: 0, y: 0, width: 14, height: 14)
        switch kind {
        case .spinner:
            let ring = CAShapeLayer()
            ring.frame = box
            ring.path = CGPath(ellipseIn: box.insetBy(dx: 1.6, dy: 1.6), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor.systemCyan.cgColor
            ring.lineWidth = 2.2
            ring.lineCap = .round
            ring.strokeEnd = 0.72
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2 * Double.pi
            spin.duration = 0.9; spin.repeatCount = .infinity; spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: "spin")
            root.addSublayer(ring)
        case .pulse, .dot:
            let dotBox = box.insetBy(dx: 3, dy: 3)
            let halo = CAShapeLayer()
            halo.frame = box
            halo.path = CGPath(ellipseIn: dotBox, transform: nil)
            halo.fillColor = NSColor.systemOrange.withAlphaComponent(0.45).cgColor
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1; grow.toValue = 2.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]; group.duration = 1.1; group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut); group.isRemovedOnCompletion = false
            let dot = CAShapeLayer()
            dot.frame = box
            dot.path = CGPath(ellipseIn: dotBox, transform: nil)
            dot.fillColor = NSColor.systemOrange.cgColor
            if kind == .pulse {
                halo.add(group, forKey: "pulse")
                root.addSublayer(halo)
            }
            root.addSublayer(dot)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: 14, height: 14) }
}

private struct NotchCountLabel: View {
    let summary: NotchSummary
    var body: some View {
        switch summary {
        case .working(let count), .waiting(let count), .finished(let count):
            Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).contentTransition(.numericText())
        case .idle: EmptyView()
        }
    }
    private var color: Color {
        switch summary {
        case .waiting: .orange
        case .finished: .green
        default: .white.opacity(0.85)
        }
    }
}

private struct NotchPeekLine: View {
    let chat: NotchChat
    let waiting: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(waiting ? L10n.text("Ждёт тебя", "Needs you") : L10n.text("Готово", "Done"))
                .foregroundStyle(waiting ? .orange : .green).fontWeight(.semibold)
            Text(chat.title).foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).frame(height: 30)
    }
}

private struct NotchExpandedContent: View {
    @ObservedObject var state: NotchIslandState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.showingSettings {
                NotchSettings(state: state)
            } else if state.chats.isEmpty {
                Text(L10n.text("Сейчас агенты не работают", "No agents are working right now"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.chats) { chat in
                            NotchChatRow(chat: chat, actions: state.actions.filter { $0.threadID == chat.id }, state: state)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: NotchIslandController.panelSize.height - 80)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14)
    }
}

private struct NotchSettings: View {
    @ObservedObject var state: NotchIslandState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("Прятать, когда агенты не работают", "Hide when no agent is working"), isOn: binding(\.autoHide))
            Toggle(L10n.text("Звук, когда агент закончил или ждёт ответа", "Sound when an agent finishes or needs you"), isOn: binding(\.sound))
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Включить снова: Настройки → Основные", "Turn back on in Settings → General"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 8)
                Button(L10n.text("Выключить остров", "Turn off island")) { state.onDisable() }
                    .buttonStyle(NotchButtonStyle(prominent: false))
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func binding(_ key: WritableKeyPath<NotchPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { state.preferences[keyPath: key] }, set: { state.preferences[keyPath: key] = $0; state.onPreferencesChanged() })
    }
}

private struct NotchChatRow: View {
    let chat: NotchChat
    let actions: [PendingAction]
    @ObservedObject var state: NotchIslandState
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { state.onOpenChat(chat.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    NotchStatusIndicator(summary: rowSummary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        subtitle
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(hovered ? 0.7 : 0)).padding(.top, 3)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Открыть чат", "Open chat"))
            ForEach(actions) { action in NotchActionCard(action: action, state: state) }
        }
        .padding(10)
        .background(.white.opacity(hovered ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovered = $0 }
    }

    private var rowSummary: NotchSummary {
        switch chat.phase {
        case .waiting: .waiting(1)
        case .working: .working(1)
        case .finished: .finished(1)
        }
    }

    @ViewBuilder private var subtitle: some View {
        // Only a working row with a start time shows a duration; the others need no clock.
        if chat.phase == .working, chat.since != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in subtitleLine(now: context.date) }
        } else {
            subtitleLine(now: .now)
        }
    }

    private func subtitleLine(now: Date) -> some View {
        Text(subtitleText(now: now)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
    }

    private func subtitleText(now: Date) -> String {
        var parts = [chat.project].filter { !$0.isEmpty }
        switch chat.phase {
        case .waiting: parts.append(L10n.text("ждёт ответа", "waiting for you"))
        case .finished: parts.append(L10n.text("готово", "done"))
        case .working:
            parts.append(chat.activity ?? L10n.text("работает", "working"))
            if let since = chat.since { parts.append(NotchPolicy.duration(since: since, now: now)) }
        }
        return parts.joined(separator: " · ")
    }
}

/// An agent request answered in place through the same path as the chat's own card.
private struct NotchActionCard: View {
    let action: PendingAction
    @ObservedObject var state: NotchIslandState
    @State private var submitting = false
    @State private var failure: String?
    @State private var showingDetails = false
    @State private var detailsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let collapsedDetailsHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch action.interaction.kind {
            case .approval(let canAllow):
                if let reason = action.interaction.reason, !reason.isEmpty {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(4)
                }
                if !action.interaction.details.isEmpty {
                    ScrollView {
                        Text(action.interaction.details).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { proxy in
                                Color.clear.onAppear { detailsHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, height in detailsHeight = height }
                            })
                    }
                    .frame(maxHeight: showingDetails ? 160 : Self.collapsedDetailsHeight)
                    .padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    // An explicit control, so selecting the text never resizes the box.
                    if detailsHeight > Self.collapsedDetailsHeight {
                        Button {
                            withAnimation(NotchIslandController.animation(reduceMotion: reduceMotion)) { showingDetails.toggle() }
                        } label: {
                            Label(showingDetails ? L10n.text("Свернуть", "Show less") : L10n.text("Показать всё", "Show all"),
                                  systemImage: showingDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !canAllow {
                    Text(L10n.text("Этот запрос нельзя подтвердить в приложении.", "This request cannot be approved in the app."))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L10n.text("Отклонить", "Decline")) { submit(.deny) }
                        .buttonStyle(NotchButtonStyle(prominent: false))
                    if canAllow {
                        Button(L10n.text("Разрешить один раз", "Allow once")) { submit(.allowOnce) }
                            .buttonStyle(NotchButtonStyle(prominent: true))
                    }
                }
            default:
                HStack {
                    Text(action.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Button(L10n.text("Ответить в чате", "Answer in chat")) { state.onOpenChat(action.threadID) }
                        .buttonStyle(NotchButtonStyle(prominent: true))
                }
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .disabled(submitting)
    }

    private func submit(_ response: AgentInteractionResponse) {
        guard !submitting else { return }
        submitting = true; failure = nil
        Task {
            // Never retried: a failure stays on the card, like in the chat.
            failure = await state.onAnswer(action, response)
            submitting = false
        }
    }
}

private struct NotchButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(prominent ? Color.white : Color.white.opacity(0.14), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
    }
}

/// Settings → General: the island can be switched off entirely.
struct NotchIslandSettings: View {
    @State private var enabled = NotchPreferences.load().enabled
    var body: some View {
        Section(L10n.text("Остров в нотче", "Notch island")) {
            Toggle(L10n.text("Показывать остров над нотчем", "Show the island over the notch"), isOn: $enabled)
                .onChange(of: enabled) { _, value in NotchIslandController.setEnabled(value) }
            Text(L10n.text("Только на встроенном экране MacBook. Выключенный остров не тратит память и процессор. Пока запущено приложение Fringe, нотч показывает оно, а остров скрыт.",
                           "Built-in MacBook display only. When off, the island uses no memory or CPU. While the Fringe app runs, it owns the notch and the island stays hidden."))
                .font(.caption).foregroundStyle(.secondary)
        }
        // The island's own button may have turned it off while Settings was open in the background.
        .onAppear { enabled = NotchPreferences.load().enabled }
    }
}
