import SwiftUI

/// Everything pinned under a chat's transcript, top to bottom: this chat's delivery notice,
/// the agent's current activity, the request waiting for an answer, then the composer.
/// A card for answering an agent's structured question belongs next to `MobileApprovalCard`.
struct MobileChatDock: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let project: RemoteProject?
    var writing: FocusState<Bool>.Binding
    let openSettings: () -> Void
    let sent: () -> Void
    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        VStack(spacing: 10) {
            MobileDeliveryNotice(model: model, key: key, receipt: model.receipt(key))
            if let approval = nextApproval {
                MobileApprovalCard(model: model, device: device, chat: chat, approval: approval,
                                   position: (chat.approvals.firstIndex { $0.id == approval.id } ?? 0) + 1, total: chat.approvals.count)
            } else if chat.running {
                MobileActivityLine(chat: chat)
            }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 8) { buttons }
            }
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
        } label: { Text(L10n.text("Отклонить", "Decline")).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).accessibilityIdentifier("deny-approval")
        if approval.canAllow {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { _ = await model.send(device: device, chat: chat, kind: "allow", approval: approval.id) }
            } label: { Text(L10n.text("Разрешить один раз", "Allow once")).lineLimit(1).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.orange).accessibilityIdentifier("allow-approval")
        }
    }
}
