import AppKit
import ContextCore
import ContextTranscript
import SwiftUI

/// The composer's `/` skill list (2026-11-04): the skills of the chat's engine matching the typed `/token`.
/// The editor reports its text and caret here; only `SkillSuggestionMenu` observes the list, so a keystroke renders
/// nothing else. Skill folders are scanned off the main thread on first use and kept for `cacheLifetime`.
@MainActor final class SkillSuggestionController: ObservableObject, ComposerCompletion {
    @Published private(set) var items: [SkillInfo] = []
    @Published private(set) var selection = 0
    /// The chat engine's syntax; nil for an engine without skills, which never opens the list.
    private(set) var syntax: SkillMentionSyntax?
    private weak var editor: NSTextView?
    private var token: SkillSuggestions.Token?
    /// The token Esc closed the list on; it stays closed until the typed token differs.
    private var dismissed: SkillSuggestions.Token?
    private var cache: [SkillMentionSyntax: (skills: [SkillInfo], scanned: Date)] = [:]
    private var scanning: Set<SkillMentionSyntax> = []
    static let cacheLifetime: TimeInterval = 30

    var isActive: Bool { !items.isEmpty }

    func setEngine(_ syntax: SkillMentionSyntax?) {
        guard syntax != self.syntax else { return }
        self.syntax = syntax
        refresh()
    }

    /// Another chat: skills installed meanwhile show up, and an earlier Esc no longer applies.
    func reset() {
        cache.removeAll(); dismissed = nil; token = nil
        close()
    }

    func editorChanged(_ editor: NSTextView) {
        self.editor = editor
        refresh()
    }

    func handle(_ key: ComposerCompletionKey, in editor: NSTextView) -> Bool {
        guard !items.isEmpty else { return false }
        self.editor = editor
        switch key {
        case .up: selection = (selection - 1 + items.count) % items.count
        case .down: selection = (selection + 1) % items.count
        case .accept: accept(items[min(selection, items.count - 1)])
        case .dismiss: dismissed = token; close()
        }
        return true
    }

    /// Replaces the typed `/token` with the engine's invocation, through the text system so it can be undone.
    func accept(_ skill: SkillInfo) {
        guard let editor, let syntax, let token else { return close() }
        close()
        let string = editor.string as NSString
        guard NSMaxRange(token.range) <= string.length, string.substring(with: token.range) == "/" + token.query else { return }
        editor.window?.makeFirstResponder(editor)
        // The editor's change report then finds no token after the inserted space and keeps the list closed.
        editor.insertText(syntax.invocation(skill.name), replacementRange: token.range)
    }

    private func refresh() {
        guard let editor, let syntax, !editor.hasMarkedText(), editor.selectedRange().length == 0,
              let token = SkillSuggestions.token(in: editor.string, caret: editor.selectedRange().location) else {
            self.token = nil; dismissed = nil
            return close()
        }
        self.token = token
        if dismissed == token { return close() }
        dismissed = nil
        guard let skills = skills(for: syntax) else { return close() }
        let found = SkillSuggestions.matches(skills, query: token.query)
        if found != items { items = found; if selection != 0 { selection = 0 } }
    }

    private func close() {
        if !items.isEmpty { items = [] }
        if selection != 0 { selection = 0 }
    }

    /// Cached skills, possibly stale while a rescan runs; nil until the first scan for the engine finishes, which then
    /// refreshes the list for whatever is typed by then.
    private func skills(for syntax: SkillMentionSyntax) -> [SkillInfo]? {
        let cached = cache[syntax]
        let fresh = cached.map { Date().timeIntervalSince($0.scanned) < Self.cacheLifetime } ?? false
        if !fresh, scanning.insert(syntax).inserted {
            let roots = SkillSuggestions.roots(syntax)
            Task { [weak self] in
                let skills = await Task.detached(priority: .userInitiated) { SkillCatalog.scan(roots) }.value
                guard let self else { return }
                self.scanning.remove(syntax)
                self.cache[syntax] = (skills, Date())
                self.refresh()
            }
        }
        return cached?.skills
    }
}

/// The list above the composer: up to eight rows, then it scrolls; the selected row follows the arrow keys.
struct SkillSuggestionMenu: View {
    @ObservedObject var controller: SkillSuggestionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let visibleRows = 8

    var body: some View {
        ZStack {
            if !controller.items.isEmpty {
                list.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.items.isEmpty)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, skill in
                        row(skill, selected: index == controller.selection).id(skill.id)
                    }
                }.padding(.ui(4))
            }
            .frame(height: CGFloat(min(controller.items.count, Self.visibleRows)) * Self.rowHeight + .ui(8))
            .onChange(of: controller.selection) { _, selection in
                guard controller.items.indices.contains(selection) else { return }
                proxy.scrollTo(controller.items[selection].id)
            }
        }
        .frame(maxWidth: .ui(460), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DeskPalette.canvas).shadow(color: DeskPalette.shadow, radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeskPalette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Скиллы", "Skills"))
    }

    private static var rowHeight: CGFloat { .ui(40) }

    private func row(_ skill: SkillInfo, selected: Bool) -> some View {
        Button { controller.accept(skill) } label: {
            VStack(alignment: .leading, spacing: .ui(1)) {
                Text(skill.name).font(.ui(.callout).weight(.semibold)).foregroundStyle(DeskPalette.ink).lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description).font(.ui(.caption)).foregroundStyle(DeskPalette.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, .ui(10))
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .background(selected ? DeskPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(skill.description)
        .accessibilityLabel(skill.description.isEmpty ? skill.name : skill.name + ", " + skill.description)
        .accessibilityHint(L10n.text("Вставить скилл в сообщение", "Insert the skill into the message"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
