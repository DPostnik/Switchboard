import AppKit
import ContextCore

/// Structured tool calls and plans in the transcript (ACP-shaped model, stage C, 2026-11-02). A call row inside an
/// activity card shows the call's kind icon, title, status badge and file locations (links that open like other file
/// links: preview, Option to reveal, Command to open in the editor); it opens to the input summary, the inline diff of
/// an edit, the call's text and its result. Shell commands keep their own row (`commandStep`). A turn's plan is a
/// compact checklist. Items stored before the structured model have no `toolCall`/`plan` and keep their old rows.
extension TranscriptScrollView {
    /// Diff lines shown per call; the rest is summarized in a note.
    static let diffLineLimit = 400

    static func kindSymbol(_ kind: AgentToolCall.Kind) -> String {
        switch kind {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "lightbulb"
        case .fetch: "globe"
        case .switchMode: "arrow.triangle.swap"
        case .other: "wrench.and.screwdriver"
        }
    }

    private static func symbol(_ name: String, color: NSColor, description: String? = nil, size: CGFloat = 10.5) -> NSMutableAttributedString {
        let icon = NSTextAttachment()
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium).applying(.init(paletteColors: [color])))
        icon.bounds = NSRect(x: 0, y: -1.5, width: size + 2, height: size + 1)
        return NSMutableAttributedString(attachment: icon)
    }

    /// Done is a quiet moss check like a clean exit; waiting is amber, failed and denied are clay, the rest muted.
    static func statusBadge(_ status: AgentToolCall.Status) -> NSAttributedString {
        let description = ToolCallText.status(status)
        if status == .completed {
            let check = symbol("checkmark", color: DeskPalette.ns.accent, description: description, size: 10)
            check.addAttribute(.toolTip, value: description, range: NSRange(location: 0, length: check.length))
            return check
        }
        let color: NSColor = switch status {
        case .awaitingApproval: DeskPalette.ns.attention
        case .failed, .rejected: DeskPalette.ns.problem
        default: DeskPalette.ns.muted
        }
        return NSAttributedString(string: description, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color, .toolTip: description
        ])
    }

    /// An absolute path for a location: relative ones resolve against the chat's project; nil when that is unknown.
    func absolutePath(_ path: String) -> String? {
        if path.hasPrefix("/") { return path }
        guard let projectPath, !path.isEmpty else { return nil }
        return (projectPath as NSString).appendingPathComponent(path)
    }

    /// "  a.swift:40  Sources/" after a call's title, at most three; each a file link with its line.
    func appendLocations(_ locations: [AgentToolCall.Location], to line: NSMutableAttributedString) {
        for location in locations.prefix(3) {
            let absolute = absolutePath(location.path)
            let shown = absolute.flatMap { Self.relativePath($0, project: projectPath) } ?? ToolCallText.name(location.path)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: DeskPalette.ns.accentDeep
            ]
            if let absolute {
                attributes[.link] = absolute
                attributes[.toolTip] = absolute
                if let number = location.line { attributes[.fileLine] = number }
            }
            line.append(NSAttributedString(string: "  ", attributes: [.font: Self.stepFont]))
            line.append(NSAttributedString(string: shown + (location.line.map { ":\($0)" } ?? ""), attributes: attributes))
        }
        if locations.count > 3 {
            line.append(NSAttributedString(string: "  +\(locations.count - 3)", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: DeskPalette.ns.muted
            ]))
        }
    }

    /// The chip beside a call's title (a sub-agent's type or model), one line and short; nil when absent.
    static func badgeText(_ call: AgentToolCall) -> String? {
        guard let badge = call.badge.map({ ActivityDetail.oneLine($0, limit: 40) }), !badge.isEmpty else { return nil }
        return badge
    }

    /// Whether a call row has anything to open.
    static func hasBody(_ call: AgentToolCall, item: TranscriptItem, result: TranscriptItem?) -> Bool {
        if call.inputSummary?.isEmpty == false || !call.content.isEmpty || item.reduced == true { return true }
        guard let result else { return false }
        return !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "N. [icon] title  [status]  a.swift:12  ▸"; open, the call's details below it.
    func callStep(number: String, item: TranscriptItem, call: AgentToolCall, result: TranscriptItem?, rowID: String,
                  row: NSParagraphStyle, first: NSParagraphStyle) -> NSMutableAttributedString {
        let expandable = Self.hasBody(call, item: item, result: result)
        let open = expandable && expandedDetails.contains(Self.detailKey("call", item.id))
        let line = NSMutableAttributedString(string: number, attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.accent])
        line.append(Self.symbol(Self.kindSymbol(call.kind), color: DeskPalette.ns.muted))
        let title = call.title.isEmpty ? Self.activityHeadline(item.text) : call.title
        line.append(NSAttributedString(string: " " + ActivityDetail.oneLine(title, limit: 140),
                                       attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.inkSoft]))
        if let badge = Self.badgeText(call) {
            line.append(NSAttributedString(string: "  ", attributes: [.font: Self.stepFont]))
            line.append(NSAttributedString(string: "\u{2009}" + badge + "\u{2009}", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: DeskPalette.ns.muted,
                .backgroundColor: DeskPalette.ns.subtle, .toolTip: badge
            ]))
        }
        line.append(NSAttributedString(string: "  ", attributes: [.font: Self.stepFont]))
        // A call that failed by its result shows the failure even when the engine reported no status change.
        let status = result?.failed == true && !call.status.isFinal ? .failed : call.status
        line.append(Self.statusBadge(status))
        if expandable {
            line.append(NSAttributedString(string: "  " + (open ? "▾" : "▸"), attributes: [.font: Self.stepFont, .foregroundColor: DeskPalette.ns.muted]))
            line.addAttributes([.link: Self.detailLink("call", row: rowID, target: item.id),
                                .toolTip: open ? L10n.text("Скрыть подробности", "Hide details") : L10n.text("Показать подробности", "Show details")],
                               range: NSRange(location: 0, length: line.length))
        }
        appendLocations(call.locations, to: line)
        line.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: line.length))
        guard open else { return line }
        appendCallBody(call, item: item, result: result, into: line, row: row)
        return line
    }

    private func appendCallBody(_ call: AgentToolCall, item: TranscriptItem, result: TranscriptItem?, into line: NSMutableAttributedString,
                                row: NSParagraphStyle) {
        let style = (row.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 32; style.headIndent = 32; style.paragraphSpacingBefore = 0; style.paragraphSpacing = 0
        let noteStyle = (style.mutableCopy() as? NSMutableParagraphStyle) ?? style
        noteStyle.paragraphSpacingBefore = 4; noteStyle.paragraphSpacing = 2
        func note(_ text: String) {
            line.append(NSAttributedString(string: "\n" + text, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: DeskPalette.ns.muted, .paragraphStyle: noteStyle
            ]))
        }
        func output(_ text: String, color: NSColor = DeskPalette.ns.inkSoft) {
            let shown = ActivityDetail.output(TranscriptItem(id: "", kind: "activity", text: text))
            if shown.omittedLines > 0 {
                note(L10n.text("Показаны последние строки; ещё \(shown.omittedLines) выше скрыто.",
                               "Showing the last lines; \(shown.omittedLines) earlier lines are hidden."))
            }
            guard !shown.text.isEmpty else { return }
            line.append(NSAttributedString(string: "\n" + shown.text, attributes: [.font: Self.outputFont, .foregroundColor: color, .paragraphStyle: style]))
        }
        // The note repeats nothing the chip already shows (a Claude sub-agent's type).
        if let summary = call.inputSummary, !summary.isEmpty, summary != call.badge { note(summary) }
        if item.reduced == true, call.content.isEmpty {
            note(L10n.text("В архиве подробности вызова не хранятся.", "Archived chats do not keep call details."))
        }
        var budget = Self.diffLineLimit, hidden = 0
        let paths = Set(call.diffs.map(\.path))
        for (index, diff) in call.diffs.enumerated() {
            let lines = ToolCallDiffLines.lines(old: diff.oldText, new: diff.newText)
            if paths.count > 1 || diff.line != nil {
                let name = Self.relativePath(absolutePath(diff.path) ?? diff.path, project: projectPath) ?? ToolCallText.name(diff.path)
                note(name + (diff.line.map { ":\($0)" } ?? ""))
            }
            guard budget > 0 else { hidden += lines.count; continue }
            let shown = lines.prefix(budget)
            hidden += lines.count - shown.count; budget -= shown.count
            if shown.isEmpty { continue }
            let diffStyle = (style.mutableCopy() as? NSMutableParagraphStyle) ?? style
            diffStyle.firstLineHeadIndent = 40; diffStyle.headIndent = 40
            let start = line.length
            for (offset, entry) in shown.enumerated() {
                let first = offset == 0, last = offset == shown.count - 1
                let paragraph: NSParagraphStyle
                if first || last, let edge = diffStyle.mutableCopy() as? NSMutableParagraphStyle {
                    if first { edge.paragraphSpacingBefore = 8 }
                    if last { edge.paragraphSpacing = 8 }
                    paragraph = edge
                } else { paragraph = diffStyle }
                let sign: String?, mark: String, color: NSColor
                switch entry.sign {
                case .added: sign = "+"; mark = "+ "; color = DeskPalette.ns.accentDeep
                case .removed: sign = "-"; mark = "- "; color = DeskPalette.ns.problemInk
                case .context: sign = nil; mark = "  "; color = DeskPalette.ns.inkSoft
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: Self.outputFont, .foregroundColor: color, .paragraphStyle: paragraph]
                if let sign { attributes[.diffLine] = sign }
                line.append(NSAttributedString(string: "\n", attributes: [.font: Self.outputFont, .paragraphStyle: paragraph]))
                line.append(NSAttributedString(string: mark + entry.text, attributes: attributes))
            }
            line.addAttribute(.codeCard, value: "call:\(item.id):\(index)", range: NSRange(location: start + 1, length: line.length - start - 1))
        }
        if hidden > 0 {
            note(L10n.text("Ещё \(hidden) строк изменений скрыто.", "\(hidden) more diff lines are hidden."))
        }
        for content in call.content {
            if case .text(let text) = content { output(text) }
        }
        if let terminal = call.terminal, !terminal.output.isEmpty { output(terminal.output) }
        // The result of an edit repeats the diff ("The file has been updated"); it is shown only when the call failed.
        if let result, call.diffs.isEmpty || result.failed == true || call.status == .failed {
            let shown = ActivityDetail.output(result)
            if shown.archived {
                note(L10n.text("В архиве хранится только первая строка результата.", "Archived chats keep only the first line of the result."))
            }
            if shown.omittedLines > 0 {
                note(L10n.text("Показаны последние строки; ещё \(shown.omittedLines) выше скрыто.",
                               "Showing the last lines; \(shown.omittedLines) earlier lines are hidden."))
            }
            if !shown.text.isEmpty {
                line.append(NSAttributedString(string: "\n" + shown.text, attributes: [
                    .font: Self.outputFont, .foregroundColor: result.failed == true ? DeskPalette.ns.problemInk : DeskPalette.ns.inkSoft, .paragraphStyle: style
                ]))
            }
        }
    }

    // MARK: Plan

    /// The turn's plan as a compact checklist: a header with its progress, then one line per entry.
    func renderPlan(_ plan: AgentPlan, id: String, into result: NSMutableAttributedString) {
        let start = result.length
        let progress = plan.progress
        let header = Self.symbol("checklist", color: DeskPalette.ns.accent, size: 11)
        header.append(NSAttributedString(string: "  " + ToolCallText.planHeader(done: progress.done, total: progress.total),
                                         attributes: [.foregroundColor: DeskPalette.ns.ink]))
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.firstLineHeadIndent = 12; headerStyle.headIndent = 12; headerStyle.tailIndent = -16
        headerStyle.paragraphSpacingBefore = 9; headerStyle.paragraphSpacing = 4
        header.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .medium), .paragraphStyle: headerStyle],
                             range: NSRange(location: 0, length: header.length))
        result.append(header)
        let body = NSMutableParagraphStyle()
        body.firstLineHeadIndent = 14; body.headIndent = 34; body.tailIndent = -16
        body.lineSpacing = 1; body.paragraphSpacing = 3; body.lineBreakMode = .byWordWrapping
        if let explanation = plan.explanation, !explanation.isEmpty {
            result.append(NSAttributedString(string: "\n" + explanation, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DeskPalette.ns.muted, .paragraphStyle: body
            ]))
        }
        for entry in plan.entries {
            let (name, color, label): (String, NSColor, String) = switch entry.status {
            case .completed: ("checkmark.circle.fill", DeskPalette.ns.accent, L10n.text("выполнено", "done"))
            case .inProgress: ("circle.lefthalf.filled", DeskPalette.ns.attention, L10n.text("в работе", "in progress"))
            case .pending: ("circle", DeskPalette.ns.muted, L10n.text("впереди", "to do"))
            }
            let line = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5)])
            line.append(Self.symbol(name, color: color, description: label, size: 11))
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: entry.status == .inProgress ? .medium : .regular),
                .foregroundColor: entry.status == .completed ? DeskPalette.ns.muted : DeskPalette.ns.inkSoft
            ]
            if entry.status == .completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            line.append(NSAttributedString(string: "  " + entry.content, attributes: attributes))
            line.addAttribute(.paragraphStyle, value: body, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        let last = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
        if let style = (result.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 9
            result.addAttribute(.paragraphStyle, value: style, range: last)
        }
        // Drawn as a soft card like an activity group.
        result.addAttribute(.activityCard, value: id, range: NSRange(location: start, length: result.length - start))
    }
}
