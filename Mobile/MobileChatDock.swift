import SwiftUI

/// Everything pinned under a chat's transcript, top to bottom: this chat's delivery notice,
/// the request waiting for an answer (approval, then question or form) or the agent's current activity,
/// the chat's desktop queue, then the composer.
struct MobileChatDock: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let project: RemoteProject?
    var writing: FocusState<Bool>.Binding
    /// Most height a pinned card may take, so the composer always stays on screen.
    var cardLimit: CGFloat = 260
    let openSettings: () -> Void
    let sent: () -> Void
    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        VStack(spacing: 10) {
            MobileDeliveryNotice(model: model, key: key, receipt: model.receipt(key))
            if let approval = nextApproval {
                MobileApprovalCard(model: model, device: device, chat: chat, approval: approval,
                                   position: (chat.approvals.firstIndex { $0.id == approval.id } ?? 0) + 1, total: chat.approvals.count)
            } else if let interaction = nextInteraction {
                let interactions = chat.interactions ?? []
                MobileQuestionCard(model: model, device: device, chat: chat, interaction: interaction,
                                   position: (interactions.firstIndex { $0.id == interaction.id } ?? 0) + 1, total: interactions.count,
                                   limit: cardLimit)
                    .id(interaction.id)
            } else if chat.running {
                MobileActivityLine(chat: chat)
            }
            MobileQueueList(model: model, device: device, chat: chat)
            MobileComposer(model: model, device: device, chat: chat, project: project, writing: writing, openSettings: openSettings, sent: sent)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
    /// The first request without an accepted reply; once all have one, the first, so its status stays visible.
    private var nextApproval: RemoteApproval? {
        chat.approvals.first { approval in
            model.approvalCommand(device: device.id, chat: chat.id, approval: approval.id).map { $0.status == "rejected" } ?? true
        } ?? chat.approvals.first
    }
    /// The same rule for questions and forms; their answer and decline carry the request handle too.
    private var nextInteraction: RemoteInteraction? {
        let interactions = chat.interactions ?? []
        return interactions.first { interaction in
            model.approvalCommand(device: device.id, chat: chat.id, approval: interaction.id).map { $0.status == "rejected" } ?? true
        } ?? interactions.first
    }
}

/// One line about what the agent is doing, with the turn's elapsed time.
struct MobileActivityLine: View {
    let chat: RemoteChat
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(chat.activity ?? L10n.text("Агент работает…", "Agent is working…"))
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let start = chat.runningStart {
                Text(start, style: .timer).monospacedDigit().foregroundStyle(.tertiary).layoutPriority(1)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("running-activity")
    }
}

/// A pending approval, pinned above the composer so it never scrolls away.
struct MobileApprovalCard: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let approval: RemoteApproval
    let position: Int
    let total: Int
    @State private var detailsHeight: CGFloat = 0
    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        let response = model.approvalCommand(device: device.id, chat: chat.id, approval: approval.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("Требуется подтверждение", "Approval required"), systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if total > 1 {
                    Text(L10n.text("\(position) из \(total)", "\(position) of \(total)")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // Short requests take their own height; long ones scroll inside a bounded box.
            ScrollView {
                details.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { detailsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(detailsHeight, 18), 120))
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Side by side while both labels fit on one line, otherwise stacked (large text sizes).
            // A custom layout: `ViewThatFits` with fixed-size labels here left the chat screen blank in the simulator.
            MobileApprovalButtonsLayout { buttons }
            .controlSize(.large)
            .disabled(model.isBlocked(key) || response.map { $0.status != "rejected" } == true)
            if let response {
                Text(MobileText.command(response.status)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("approval-status")
            }
            if !approval.canAllow {
                Text(L10n.text("Подтвердить этот запрос с телефона нельзя. Проверь полные детали на Mac или отклони запрос.", "This request cannot be approved on your phone. Review the full details on your Mac or decline it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-card")
    }
    private var details: some View {
        SelectableText(text: MarkdownInline.uiKit(plain: approval.details, style: .footnote, monospaced: true))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var buttons: some View {
        Button(role: .destructive) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { _ = await model.send(device: device, chat: chat, kind: "deny", approval: approval.id) }
        } label: { Text(L10n.text("Отклонить", "Decline")).padding(.horizontal, 6).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).accessibilityIdentifier("deny-approval")
        if approval.canAllow {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { _ = await model.send(device: device, chat: chat, kind: "allow", text: approval.projectSettings == true ? RemoteCommand.projectSettingsDecision : "", approval: approval.id) }
            } label: { Text(approval.projectSettings == true ? L10n.text("Применить настройки", "Apply settings") : L10n.text("Разрешить один раз", "Allow once")).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.orange).accessibilityIdentifier("allow-approval")
        }
    }
}

/// Decline and Allow in one row when their one-line widths fit: Decline at its own width, Allow
/// filling the rest. Otherwise each takes the full width, one under the other.
struct MobileApprovalButtonsLayout: Layout {
    var spacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? ideals.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideals.count - 1))
        if fitsRow(ideals, width) { return CGSize(width: width, height: ideals.map(\.height).max() ?? 0) }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        if fitsRow(ideals, bounds.width) {
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let last = index == subviews.count - 1
                let width = last ? bounds.maxX - x : ideals[index].width
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: width, height: ideals[index].height))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
                y += size.height + spacing
            }
        }
    }
    private func fitsRow(_ ideals: [CGSize], _ width: CGFloat) -> Bool {
        ideals.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideals.count - 1)) <= width
    }
}

/// A pending question or tool form, pinned above the composer: options as rows, free text where the agent accepts it,
/// Send once the answers pass `RemoteInteraction.validate(answers:)`. A request the phone cannot show faithfully
/// (secret, link, too large) says "answer on the Mac" and offers only Decline where the desktop has it.
struct MobileQuestionCard: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let interaction: RemoteInteraction
    let position: Int
    let total: Int
    let limit: CGFloat
    /// Chosen option label per question.
    @State private var chosen: [String: String] = [:]
    /// Free text per question; it is the answer while `typing` holds the question.
    @State private var other: [String: String] = [:]
    @State private var typing: Set<String> = []
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focused: String?

    private var answers: [String: String] {
        var result: [String: String] = [:]
        for question in interaction.questions {
            let value = typing.contains(question.id) || question.options.isEmpty ? other[question.id] ?? "" : chosen[question.id] ?? ""
            // Questions need every key; a form leaves out what the user did not fill in.
            if interaction.kindValue == .questions || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[question.id] = value }
        }
        return result
    }
    private var valid: Bool { (try? interaction.validate(answers: answers)) != nil }

    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        let response = model.approvalCommand(device: device.id, chat: chat.id, approval: interaction.id)
        let locked = model.isBlocked(key) || response.map { $0.status != "rejected" } == true
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(interaction.kindValue == .questions ? L10n.text("Вопрос агента", "Question from the agent") : L10n.text("Запрос инструмента", "Tool request"),
                      systemImage: interaction.kindValue == .questions ? "questionmark.bubble.fill" : "list.bullet.rectangle.portrait.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.indigo)
                Spacer()
                if total > 1 {
                    Text(L10n.text("\(position) из \(total)", "\(position) of \(total)")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The questions scroll inside a bounded box; the buttons and the composer stay visible.
            ScrollView {
                content.disabled(locked).onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .frame(height: min(max(contentHeight, 24), limit))
            if let message = interaction.macOnlyMessage {
                Label(message, systemImage: "desktopcomputer")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("question-mac-only")
            }
            if interaction.canAnswer || interaction.canDecline {
                MobileApprovalButtonsLayout { buttons }
                    .controlSize(.large)
                    .disabled(locked)
            }
            if let response {
                Text(MobileText.command(response.status, kind: response.kind)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("question-status")
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("question-card")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = interaction.message, !message.isEmpty {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(interaction.questions) { question in questionView(question) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func questionView(_ question: RemoteQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(question.text).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !question.required && interaction.canAnswer {
                    Text(L10n.text("необязательно", "optional")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if interaction.canAnswer {
                VStack(spacing: 0) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { Divider().padding(.leading, 40) }
                        optionRow(question, option, index: index)
                    }
                    if question.allowsOther {
                        if !question.options.isEmpty { Divider().padding(.leading, 40) }
                        otherRow(question)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let preview = selectedOption(question)?.preview, !preview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(preview).font(.caption.monospaced()).fixedSize().padding(10).textSelection(.enabled)
                    }
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("question-preview")
                }
            } else if !question.options.isEmpty {
                // Read-only: what the agent asks, so the user knows what waits on the Mac.
                Text(question.options.map(\.label).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func selectedOption(_ question: RemoteQuestion) -> RemoteQuestionOption? {
        guard !typing.contains(question.id), let label = chosen[question.id] else { return nil }
        return question.options.first { $0.label == label }
    }

    private func optionRow(_ question: RemoteQuestion, _ option: RemoteQuestionOption, index: Int) -> some View {
        let selected = selectedOption(question)?.label == option.label
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            chosen[question.id] = option.label; typing.remove(question.id); focused = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.indigo : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body).foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("question-option-\(question.id)-\(index)")
    }

    private func otherRow(_ question: RemoteQuestion) -> some View {
        let active = typing.contains(question.id) || question.options.isEmpty
        let field = Binding(get: { other[question.id] ?? "" }, set: { value in
            other[question.id] = value
            if !question.options.isEmpty { typing.insert(question.id) }
        })
        return HStack(alignment: .center, spacing: 12) {
            if !question.options.isEmpty {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(active ? Color.indigo : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            TextField(question.options.isEmpty ? L10n.text("Ответ", "Answer") : L10n.text("Свой ответ", "Other answer"), text: field, axis: .vertical)
                .lineLimit(1...4).focused($focused, equals: question.id)
                .accessibilityIdentifier("question-other-" + question.id)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if !question.options.isEmpty { typing.insert(question.id) }; focused = question.id }
    }

    @ViewBuilder private var buttons: some View {
        if interaction.canDecline {
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                focused = nil
                Task { _ = await model.decline(device: device, chat: chat, interaction: interaction) }
            } label: { Text(L10n.text("Отклонить", "Decline")).padding(.horizontal, 6).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).accessibilityIdentifier("decline-question")
        }
        if interaction.canAnswer {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                focused = nil
                let answers = answers
                Task { _ = await model.answer(device: device, chat: chat, interaction: interaction, answers: answers) }
            } label: { Text(L10n.text("Ответить", "Send answer")).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.indigo)
                .disabled(!valid)
                .accessibilityIdentifier("send-answer")
        }
    }
}

/// The chat's desktop queue: messages that run after the current turn, the phone's own still on their way to the Mac,
/// and whether the queue waits on the Mac.
struct MobileQueueList: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    private let shown = 3
    var body: some View {
        let queued = chat.queue ?? []
        let sending = model.unlistedQueueCommands(device: device.id, chat: chat)
        let total = max(chat.queueCount ?? 0, queued.count) + sending.count
        if total > 0 {
            // The phone's own messages on their way stay visible; the desktop queue fills the remaining rows in order.
            let rows: [(id: String, text: String, note: String?, phone: Bool)] =
                queued.prefix(max(1, shown - sending.count)).map { ($0.id, $0.text, $0.claimed == true ? L10n.text("отправляется", "sending") : nil, $0.command != nil) }
                + sending.map { ("command:" + $0.id, $0.text, MobileText.command($0.status), true) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward").accessibilityHidden(true)
                    Text(L10n.text("В очереди: \(total)", "Queued: \(total)")).monospacedDigit()
                    Spacer(minLength: 4)
                    if chat.queuePaused == true {
                        Label(L10n.text("Очередь на паузе на Mac", "Queue paused on the Mac"), systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange).accessibilityIdentifier("queue-paused")
                    }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.phone ? "iphone" : "desktopcomputer").imageScale(.small).foregroundStyle(.tertiary)
                            .accessibilityLabel(row.phone ? L10n.text("С телефона", "From the phone") : L10n.text("С Mac", "From the Mac"))
                        Text(row.text).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let note = row.note { Text(note).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1) }
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("queued-" + row.id)
                }
                if total > rows.count {
                    Text(L10n.text("Ещё \(total - rows.count)", "+\(total - rows.count) more")).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("queue-more")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue-list")
        }
    }
}
