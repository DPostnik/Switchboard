import AppKit
import ContextCore

/// Detailed activity (AUD-007, 2026-11-01). Thinking appears as a collapsed row inside the turn ("Thinking · 12s") that
/// opens to its text; consecutive thinking items share one row. In an open activity card a shell command and its
/// result share one row: the command on one line, an exit badge once it finished, and its output behind a disclosure.
/// Rows carry only ids and sizes (`activityKey`, `thinkingRow`); bodies are read from `actionGroups` when rendered, so
/// a streamed update re-renders only the row it changes.
extension TranscriptScrollView {
    static let detailLinkPrefix = "contextdesk-detail:"
    private static let separator = "\u{1F}"

    enum ActivityStep {
        case tool(TranscriptItem)
        case command(call: TranscriptItem, result: TranscriptItem?)
        /// A call with its structured form (`AgentToolCall`, stage C) and its result.
        case call(TranscriptItem, AgentToolCall, result: TranscriptItem?)
    }

    /// The rows of an activity card: a shell command takes its result into its own row, and so does a structured
    /// call; other calls and results (items stored before the structured model) keep a row each. Uses only id and
    /// prefix checks, so the grouping pass can count rows on every update.
    static func activitySteps(_ actions: [TranscriptItem]) -> [ActivityStep] {
        let commands = Set(actions.lazy.filter(ActivityDetail.isShellCall).map(\.id))
        let structured = Set(actions.lazy.filter { $0.toolCall != nil && !commands.contains($0.id) }.map(\.id))
        guard !commands.isEmpty || !structured.isEmpty else { return actions.map { .tool($0) } }
        let folded = Set(commands.union(structured).map(ActivityDetail.resultID(of:)))
        var results: [String: TranscriptItem] = [:]
        for item in actions where folded.contains(item.id) { results[item.id] = item }
        return actions.compactMap { item in
            if commands.contains(item.id) { return .command(call: item, result: results[ActivityDetail.resultID(of: item.id)]) }
            if structured.contains(item.id), let call = item.toolCall { return .call(item, call, result: results[ActivityDetail.resultID(of: item.id)]) }
            return folded.contains(item.id) ? nil : .tool(item)
        }
    }

    /// One line of a summary row's text: what decides whether the open card must be drawn again.
    static func activityKey(_ item: TranscriptItem) -> String {
        "\(item.id) \(item.text.utf8.count)" + (item.exitCode.map { " \($0)" } ?? "") + (item.failed == true ? " !" : "")
            + (item.toolCall.map { " " + $0.status.rawValue } ?? "")
    }

    /// Adds a thinking item to the grouped rows: it joins the thinking row right before it, otherwise starts one.
    /// Items without text (redacted thinking) add nothing.
    static func appendThinking(_ item: TranscriptItem, to result: inout [TranscriptItem], groups: inout [String: [TranscriptItem]]) {
        guard !ActivityDetail.thinkingText(item).allSatisfy(\.isWhitespace) else { return }
        if let last = result.last, last.kind == ActivityDetail.thinkingKind, let members = groups[last.id] {
            groups[last.id] = members + [item]
            result[result.count - 1] = thinkingRow(id: last.id, members + [item])
        } else {
            groups[item.id] = [item]
            result.append(thinkingRow(id: item.id, [item]))
        }
    }

    static func thinkingRow(id: String, _ members: [TranscriptItem]) -> TranscriptItem {
        var row = TranscriptItem(id: id, kind: ActivityDetail.thinkingKind,
                                 text: members.map { "\($0.id) \($0.text.utf8.count)" }.joined(separator: "\n"))
        let durations = members.compactMap(\.seconds)
        row.seconds = durations.isEmpty ? nil : durations.reduce(0, +)
        row.showsCopyControl = false; row.turnID = members.first?.turnID; row.agentName = members.first?.agentName
        return row
    }

    static func detailLink(_ action: String, row: String, target: String? = nil) -> String {
        detailLinkPrefix + ([action, row] + (target.map { [$0] } ?? [])).joined(separator: separator)
    }

    static func detailKey(_ action: String, _ target: String) -> String { action + separator + target }

    // MARK: Thinking row

    static let thinkingIcon = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [DeskPalette.ns.muted])))

    func renderThinking(_ item: TranscriptItem, into result: NSMutableAttributedString) {
        let open = expandedDetails.contains(Self.detailKey("thinking", item.id))
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let header = NSMutableAttributedString(attachment: { let icon = NSTextAttachment(); icon.image = Self.thinkingIcon
            icon.bounds = NSRect(x: 0, y: -2, width: 14, height: 13); return icon }())
        header.append(NSAttributedString(string: "  " + ActivityDetail.thinkingLabel(seconds: item.seconds) + "  " + (open ? "▾" : "▸")))
        header.addAttributes([.font: font, .foregroundColor: DeskPalette.ns.muted, .link: Self.detailLink("thinking", row: item.id),
                              .toolTip: open ? L10n.text("Свернуть размышления", "Collapse thinking") : L10n.text("Показать размышления", "Show thinking")],
                             range: NSRange(location: 0, length: header.length))
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.firstLineHeadIndent = 12; headerStyle.headIndent = 12; headerStyle.tailIndent = -16
        headerStyle.paragraphSpacingBefore = 2; headerStyle.paragraphSpacing = open ? 6 : 0
        header.addAttribute(.paragraphStyle, value: headerStyle, range: NSRange(location: 0, length: header.length))
        result.append(header)
        guard open else { return }
        let members = actionGroups[item.id] ?? [item]
        let text = members.map(ActivityDetail.thinkingText).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let body = NSMutableParagraphStyle()
        body.firstLineHeadIndent = 32; body.headIndent = 32; body.tailIndent = -16
        body.lineSpacing = 2; body.paragraphSpacing = 4; body.lineBreakMode = .byWordWrapping
        let regular = NSFont.systemFont(ofSize: 12.5), bold = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        for line in text.components(separatedBy: "\n") {
            // Codex summaries title their parts as "**Title**"; the title is shown in bold without the markers.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let title = trimmed.count > 4 && trimmed.hasPrefix("**") && trimmed.hasSuffix("**")
            result.append(NSAttributedString(string: "\n" + (title ? String(trimmed.dropFirst(2).dropLast(2)) : line), attributes: [
                .font: title ? bold : regular, .foregroundColor: DeskPalette.ns.muted, .paragraphStyle: body
            ]))
        }
    }

    // MARK: Activity card rows

    /// The rows of an open activity card. A document's own activity item (no group) keeps its text.
    func appendActivitySteps(of item: TranscriptItem, into result: NSMutableAttributedString, row: NSParagraphStyle, first: NSParagraphStyle) {
        let steps = actionGroups[item.id].map(Self.activitySteps) ?? [.tool(item)]
        let numbered = actionGroups[item.id] != nil
        for (index, step) in steps.enumerated() {
            let number = numbered ? "\(index + 1). " : ""
            let part: NSMutableAttributedString
            switch step {
            case .tool(let action): part = toolStep(number: number, text: action.text, row: row, first: first)
            case .command(let call, let outcome): part = commandStep(number: number, call: call, result: outcome, rowID: item.id, index: index, row: row, first: first)
            case .call(let action, let call, let outcome):
                part = callStep(number: number, item: action, call: call, result: outcome, rowID: item.id, row: row, first: first)
            }
            guard part.length > 0 else { continue }
            if index < steps.count - 1 {
                let style = part.attribute(.paragraphStyle, at: part.length - 1, effectiveRange: nil) ?? row
                part.append(NSAttributedString(string: "\n", attributes: [.font: Self.stepFont, .paragraphStyle: style]))
            }
            part.addAttribute(.activityStep, value: index, range: NSRange(location: 0, length: 1))
            result.append(part)
        }
    }

    static let stepFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let outputFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    /// A call or result as before: its number and its whole text. Tool output stays literal, including link-like text.
    private func toolStep(number: String, text: String, row: NSParagraphStyle, first: NSParagraphStyle) -> NSMutableAttributedString {
        let step = NSMutableAttributedString(string: number, attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.accent])
        step.append(NSAttributedString(string: text.replacingOccurrences(of: "```", with: ""),
                                       attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.inkSoft]))
        guard step.length > 0 else { return step }
        step.addAttribute(.paragraphStyle, value: row, range: NSRange(location: 0, length: step.length))
        step.addAttribute(.paragraphStyle, value: first, range: (step.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
        return step
    }

    /// "N. $ command  [badge] · 3s  ▸": one line; once finished the line opens the output below it.
    private func commandStep(number: String, call: TranscriptItem, result: TranscriptItem?, rowID: String, index: Int,
                             row: NSParagraphStyle, first: NSParagraphStyle) -> NSMutableAttributedString {
        let open = result != nil && expandedDetails.contains(Self.detailKey("output", call.id))
        let line = NSMutableAttributedString(string: number, attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.accent])
        line.append(NSAttributedString(string: "$ ", attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.muted]))
        line.append(NSAttributedString(string: ActivityDetail.oneLine(ActivityDetail.command(call), limit: 140),
                                       attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.inkSoft]))
        if let outcome = ActivityDetail.outcome(result) {
            line.append(NSAttributedString(string: "  ", attributes: [.font: Self.stepFont]))
            line.append(Self.badge(outcome))
        } else if result == nil, let status = call.toolCall?.status, status != .inProgress, status != .completed {
            // Waiting for approval, denied or stopped before it ran.
            line.append(NSAttributedString(string: "  ", attributes: [.font: Self.stepFont]))
            line.append(Self.statusBadge(status))
        }
        if let seconds = result?.seconds, seconds >= 1, seconds.isFinite, seconds < 1e7 {
            line.append(NSAttributedString(string: " · " + ResponseTiming.duration(Int(seconds.rounded())), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: DeskPalette.ns.muted
            ]))
        }
        if result != nil {
            line.append(NSAttributedString(string: "  " + (open ? "▾" : "▸"), attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.muted]))
            line.addAttributes([.link: Self.detailLink("output", row: rowID, target: call.id),
                                .toolTip: open ? L10n.text("Скрыть вывод", "Hide output") : L10n.text("Показать вывод", "Show output")],
                               range: NSRange(location: 0, length: line.length))
        }
        // A command Codex parsed as reading or searching names its files; they open like file links.
        if let call = call.toolCall, call.kind != .execute { appendLocations(call.locations, to: line) }
        line.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: line.length))
        guard open, let result else { return line }
        let output = ActivityDetail.output(result)
        let style = (row.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 32; style.headIndent = 32; style.paragraphSpacingBefore = 0; style.paragraphSpacing = 0
        let noteStyle = (style.mutableCopy() as? NSMutableParagraphStyle) ?? style
        noteStyle.paragraphSpacingBefore = 4; noteStyle.paragraphSpacing = 2
        func note(_ text: String) {
            line.append(NSAttributedString(string: "\n" + text, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: DeskPalette.ns.muted, .paragraphStyle: noteStyle
            ]))
        }
        if output.archived {
            note(L10n.text("В архиве хранится только первая строка вывода.", "Archived chats keep only the first line of the output."))
        } else if output.omittedLines > 0 {
            note(L10n.text("Показаны последние строки; ещё \(output.omittedLines) выше скрыто.",
                           "Showing the last lines; \(output.omittedLines) earlier lines are hidden."))
        }
        if output.text.isEmpty {
            note(L10n.text("Нет вывода", "No output"))
        } else {
            line.append(NSAttributedString(string: "\n" + output.text, attributes: [
                .font: Self.outputFont, .foregroundColor: DeskPalette.ns.inkSoft, .paragraphStyle: style
            ]))
        }
        if !output.archived, !output.text.isEmpty {
            let feedback = copyFeedback.flatMap { $0.id == rowID && $0.block == index ? $0.succeeded : nil }
            let copy = NSMutableAttributedString(string: "\n", attributes: [.font: Self.outputFont, .paragraphStyle: noteStyle])
            copy.append(copyControl(feedback: feedback, description: L10n.text("Скопировать вывод команды", "Copy the command output"),
                                    label: L10n.text("Скопировать", "Copy"),
                                    attributes: [.link: Self.detailLink("copy", row: rowID, target: call.id), .paragraphStyle: noteStyle]))
            line.append(copy)
        }
        return line
    }

    /// Success is a quiet moss check; a non-zero exit or a failure is a clay label.
    static func badge(_ outcome: ActivityDetail.Outcome) -> NSAttributedString {
        let description = ActivityDetail.label(outcome)
        guard outcome != .succeeded else {
            let icon = NSTextAttachment()
            icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [DeskPalette.ns.accent])))
            icon.bounds = NSRect(x: 0, y: -1, width: 11, height: 11)
            let check = NSMutableAttributedString(attachment: icon)
            check.addAttribute(.toolTip, value: description, range: NSRange(location: 0, length: check.length))
            return check
        }
        return NSAttributedString(string: description, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: DeskPalette.ns.problem, .toolTip: description
        ])
    }

    // MARK: Links

    /// Opens or closes a thinking row or a command's output, or copies a command's output.
    func handleDetailLink(_ value: String) {
        let parts = value.dropFirst(Self.detailLinkPrefix.count).components(separatedBy: Self.separator)
        guard parts.count >= 2, previous.contains(where: { $0.id == parts[1] }) else { return }
        let action = parts[0], rowID = parts[1], target = parts.count > 2 ? parts[2] : rowID
        switch action {
        case "thinking", "output", "call":
            let key = Self.detailKey(action, target)
            if expandedDetails.contains(key) { expandedDetails.remove(key) } else { expandedDetails.insert(key) }
            rerenderItem(id: rowID)
        case "copy":
            guard let actions = actionGroups[rowID],
                  let result = actions.first(where: { $0.id == ActivityDetail.resultID(of: target) }) else { return }
            let index = Self.activitySteps(actions).firstIndex { step in
                if case .command(let call, _) = step { return call.id == target }; return false
            } ?? 0
            pasteboard.clearContents()
            let text = ActivityDetail.output(result, lineLimit: .max, byteLimit: .max).text
            showCopyFeedback(id: rowID, succeeded: pasteboard.setString(text, forType: .string), block: index)
        default: break
        }
    }
}
