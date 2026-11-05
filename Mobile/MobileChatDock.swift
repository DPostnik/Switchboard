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
                Task { _ = await model.send(device: device, chat: chat, kind: "allow", approval: approval.id) }
            } label: { Text(L10n.text("Разрешить один раз", "Allow once")).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
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
