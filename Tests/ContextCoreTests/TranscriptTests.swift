import CodexAdapter
import AppKit
import Testing
import SwiftUI
import ContextCore
@testable import ContextTranscript
@testable import ContextDesk

@Test @MainActor func chatControlsDoNotPushTextOutsideNarrowDetail() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = DeskModel(store: AppStore(file: folder.appendingPathComponent("state.sqlite")))
    model.authenticated = true
    model.models = [CodexModel(id: "gpt-5.4", displayName: "GPT-5.4")]
    model.state.model = "gpt-5.4"
    model.draft = String(repeating: "Текст сообщения ", count: 100)
    model.items = [TranscriptItem(id: "u", kind: "user", text: model.draft)]
    let host = NSHostingView(rootView: ChatView(model: model))
    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    for width: CGFloat in [840, 560, 680] {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        host.layoutSubtreeIfNeeded()
        let scrolls = scrollViews(in: host)
        #expect(scrolls.count == 2)
        for scroll in scrolls {
            let rect = scroll.convert(scroll.bounds, to: host)
            #expect(rect.minX >= 0)
            #expect(rect.maxX <= width)
        }
    }
}

@Test @MainActor func hostedChatTextWrapsInsideViewportAfterResize() throws {
    let longText = String(repeating: "Длинное сообщение без обрезания справа. ", count: 40)
        + String(repeating: "x", count: 2_000)
    let host = NSHostingView(rootView: VStack(spacing: 0) {
        NativeTranscript(items: [TranscriptItem(id: "u", kind: "user", text: longText),
                                 TranscriptItem(id: "a", kind: "assistant", text: longText)],
                         conversationID: "width", followOutput: false, isWorking: true)
        MessageComposer(text: .constant(longText), focused: .constant(false), onSubmit: {})
            .frame(height: 84).padding(16)
    })
    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    for width: CGFloat in [760, 360, 920, 440] {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 550)
        host.layoutSubtreeIfNeeded()
        let scrolls = scrollViews(in: host)
        #expect(scrolls.count == 2)
        for scroll in scrolls {
            let editor = try #require(scroll.documentView as? NSTextView)
            let container = try #require(editor.textContainer)
            let manager = try #require(editor.layoutManager)
            manager.ensureLayout(for: container)
            #expect(scroll.frame.width <= width)
            #expect(abs(editor.frame.width - scroll.contentSize.width) < 1)
            #expect(container.containerSize.width <= scroll.contentSize.width)
            #expect(manager.usedRect(for: container).maxX + editor.textContainerOrigin.x <= scroll.contentSize.width)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            #expect(abs(scroll.contentView.bounds.origin.x) < 1)
        }
    }
}

@Test @MainActor func messageBubblesAlignByAuthorAndResize() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 550)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Сделай чат понятным, как в мессенджере."),
                 TranscriptItem(id: "a", kind: "assistant", text: "Твои сообщения будут справа, мои — слева.\nМожно выделить текст и скопировать его."),
                 TranscriptItem(id: "tool", kind: "activity", text: "Проверяю вёрстку\nЗапускаю тесты")]
    view.update(items: items, conversationID: "bubbles", followOutput: false, isWorking: true)
    view.layoutSubtreeIfNeeded()
    let storage = try #require(view.transcript.textStorage)
    let user = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    let assistantIndex = (storage.string as NSString).range(of: "Codex\n").location
    let assistant = try #require(storage.attribute(.paragraphStyle, at: assistantIndex, effectiveRange: nil) as? NSParagraphStyle)
    #expect(user.headIndent > assistant.headIndent)
    #expect(assistant.tailIndent == -4)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:tool", at: 0)
    let actionIndex = (storage.string as NSString).range(of: "1. Проверяю").location
    #expect(storage.attribute(.foregroundColor, at: actionIndex, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    let action = try #require(storage.attribute(.paragraphStyle, at: actionIndex, effectiveRange: nil) as? NSParagraphStyle)
    #expect(action.lineSpacing < assistant.lineSpacing)
    if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
        view.drawsBackground = true
        view.backgroundColor = .windowBackgroundColor
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    view.frame.size.width = 460
    view.layoutSubtreeIfNeeded()
    let resized = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(resized.headIndent < user.headIndent)
    #expect(view.transcript.frame.width <= 460)
}

@Test @MainActor func workingIndicatorStaysInTranscriptUntilTurnEnds() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let items = [TranscriptItem(id: "local-user:1", kind: "user", text: "Проверь", phase: "Отправляется…"),
                 TranscriptItem(id: "action", kind: "activity", text: "Проверка файлов")]
    view.update(items: items, conversationID: "t", followOutput: true, isWorking: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.transcript.string.contains("Отправляется…"))
    #expect(!view.workingIndicator.isHidden)
    #expect(view.workingIndicator.superview === view.transcript)
    let edits = view.editCount
    view.update(items: items, conversationID: "t", followOutput: true, isWorking: true)
    #expect(view.editCount == edits)
    view.update(items: items, conversationID: "t", followOutput: true, isWorking: false)
    #expect(view.workingIndicator.isHidden)
}

@Test @MainActor func workingRowShowsStatusAndElapsedTurnTime() {
    let start = Date(timeIntervalSince1970: 1_000)
    let row = TranscriptScrollView.workingRow(status: "Inspecting pipeline lock", since: start, now: start.addingTimeInterval(41.7))
    #expect(row.text == "Inspecting pipeline lock")
    #expect(row.phase == ResponseTiming.duration(41))
    #expect(ResponseTiming.duration(41, language: .english) == "41s")
    #expect(ResponseTiming.duration(125, language: .russian) == "2 мин 5 с")
    #expect(TranscriptScrollView.workingRow(status: nil, since: nil).phase == nil)
    #expect(TranscriptScrollView.workingRow(status: nil, since: start.addingTimeInterval(5), now: start).phase == ResponseTiming.duration(0))
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    view.update(items: [TranscriptItem(id: "u", kind: "user", text: "Go")], conversationID: "t", followOutput: true,
                isWorking: true, workingStatus: "Inspecting pipeline lock", workingSince: Date().addingTimeInterval(-3))
    #expect(view.transcript.string.contains("Inspecting pipeline lock  " + ResponseTiming.duration(3)))
}

@Test @MainActor func longTranscriptHasBoundedWidthAndUnchangedUpdatesDoNoWork() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    var items = (0..<30).map { TranscriptItem(id: "\($0)", kind: "assistant", text: String(repeating: "Строка текста и `код`.\n", count: 100)) }
    items.append(TranscriptItem(id: "code", kind: "assistant", text: "```swift\n" + String(repeating: "x", count: 40_000) + "\n```"))
    view.update(items: items, conversationID: "first", followOutput: true)
    // AppKit applies the document width during layout, not synchronously in update.
    view.layoutSubtreeIfNeeded()
    let edits = view.editCount
    for _ in 0..<100 { view.update(items: items, conversationID: "first", followOutput: true) }
    #expect(view.editCount == edits)
    #expect(view.transcript.frame.width <= view.frame.width)
    #expect(view.transcript.frame.height.isFinite)
    for _ in 0..<50 {
        items[items.count - 1].text += " продолжение"
        view.update(items: items, conversationID: "first", followOutput: false)
    }
    #expect(view.transcript.string.contains(String(repeating: "x", count: 40_000)))
    view.update(items: [TranscriptItem(id: "new", kind: "user", text: "Другой чат")], conversationID: "second", followOutput: true)
    #expect(view.transcript.string == "Другой чат\n\u{FFFC}\n\n")
}

@Test @MainActor func expandingActionsDoesNotLoseFollowingMessages() {
    let view = TranscriptScrollView()
    let command = String(repeating: "длинная команда ", count: 3_000)
    var items = [TranscriptItem(id: "tool-1", kind: "activity", text: command), TranscriptItem(id: "answer", kind: "assistant", text: "Ответ после команды")]
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(view.transcript.string.count < 300)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:tool-1", at: 0)
    #expect(view.transcript.string.contains(command))
    items[1].text += " и продолжение"
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(view.transcript.string.contains(command))
    #expect(view.transcript.string.contains("Ответ после команды и продолжение"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:tool-1", at: 0)
    #expect(!view.transcript.string.contains(command))
    #expect(view.transcript.string.contains("Ответ после команды и продолжение"))
}

@Test @MainActor func activitiesGroupAcrossCommentaryAndCollapseAfterCompletion() {
    let view = TranscriptScrollView()
    let items = [
        TranscriptItem(id: "user", kind: "user", text: "Проверь проект"),
        TranscriptItem(id: "a", kind: "activity", text: "Первая команда"),
        TranscriptItem(id: "comment", kind: "assistant", text: "Проверяю файлы"),
        TranscriptItem(id: "b", kind: "activity", text: "Вторая команда")
    ]
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: true)
    // One status line: the running tool call with the turn timer; the group shows the count.
    #expect(view.transcript.string.contains("Действия Codex · 2"))
    #expect(view.transcript.string.contains("Вторая команда"))
    #expect(!view.transcript.string.contains("Первая команда"))
    #expect(view.transcript.string.contains("Проверяю файлы"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:a", at: 0)
    #expect(view.transcript.string.contains("1. Первая команда"))
    #expect(view.transcript.string.contains("2. Вторая команда"))
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: false)
    #expect(view.transcript.string.contains("Действия Codex · 2"))
    #expect(!view.transcript.string.contains("Первая команда"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:a", at: 0)
    #expect(view.transcript.string.contains("Первая команда"))
    let next = items + [TranscriptItem(id: "user2", kind: "user", text: "Ещё запрос"), TranscriptItem(id: "c", kind: "activity", text: "Третья команда")]
    view.update(items: next, conversationID: "t", followOutput: false, isWorking: true)
    #expect(view.transcript.string.contains("Действия Codex · 2"))
    #expect(view.transcript.string.contains("Действия Codex · 1"))
    #expect(view.transcript.string.contains("Третья команда"))
    view.update(items: items, conversationID: "other", followOutput: false)
    #expect(!view.transcript.string.contains("Первая команда"))
}

@Test @MainActor func finishedTurnRerendersOnlyClosingRowsAndTheChangedTail() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let items = [
        TranscriptItem(id: "user", kind: "user", text: "Проверь проект"),
        TranscriptItem(id: "a", kind: "activity", text: "Первая команда"),
        TranscriptItem(id: "comment", kind: "assistant", text: "Проверяю файлы", phase: "commentary"),
        TranscriptItem(id: "b", kind: "activity", text: "Вторая команда"),
        TranscriptItem(id: "final", kind: "assistant", text: "Готово", phase: "final_answer")
    ]
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: true)
    view.layoutSubtreeIfNeeded()
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:a", at: 0)
    #expect(view.transcript.string.contains("1. Первая команда"))
    let renders = view.renderCount
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: false)
    // The open row closes and the final answer gains its copy control; the user message and the commentary keep their rendering.
    #expect(view.renderCount - renders == 2)
    #expect(!view.transcript.string.contains("Первая команда"))
    #expect(view.transcript.string.contains("Действия Codex · 2"))
    #expect(view.transcript.string.contains("Проверяю файлы"))
    #expect(view.transcript.string.contains("Готово"))
    let next = items + [TranscriptItem(id: "user2", kind: "user", text: "Ещё"),
                        TranscriptItem(id: "final2", kind: "assistant", text: "Второй итог", phase: "final_answer")]
    view.update(items: next, conversationID: "t", followOutput: false, isWorking: true)
    let before = view.renderCount
    view.update(items: next, conversationID: "t", followOutput: false, isWorking: false)
    // Nothing was open: only the final answer, whose copy control appears, is rendered again.
    #expect(view.renderCount - before == 1)
    #expect(view.transcript.string.contains("Второй итог"))
}

@Test @MainActor func activitySummaryRowKeepsToolBodiesOutOfTheTextUntilOpened() throws {
    let body = String(repeating: "{\"output\": \"очень длинный вывод инструмента\"}\n", count: 2_000)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Запусти"),
                 TranscriptItem(id: "t1", kind: "activity", text: "Bash\n" + body),
                 TranscriptItem(id: "t2", kind: "activity", text: "Read\n" + body),
                 TranscriptItem(id: "a", kind: "assistant", text: "Готово")]
    let grouped = TranscriptScrollView.groupActivities(items, isWorking: false)
    let summary = try #require(grouped.items.first { $0.kind == "activity" })
    #expect(summary.phase == "Действия Codex · 2")
    #expect(!summary.text.contains("длинный вывод"))
    #expect(summary.text.utf8.count < 100)
    #expect(grouped.groups["t1"]?.map(\.id) == ["t1", "t2"])
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(view.transcript.string.contains("Действия Codex · 2"))
    #expect(!view.transcript.string.contains("длинный вывод"))
    #expect(view.transcript.string.utf8.count < 200)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:t1", at: 0)
    #expect(view.transcript.string.contains("1. Bash\n" + body))
    #expect(view.transcript.string.contains("2. Read\n" + body))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-action:t1", at: 0)
    #expect(!view.transcript.string.contains("длинный вывод"))
}

@Test @MainActor func composerReturnSubmitsAndShiftReturnInsertsNewline() throws {
    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    editor.isRichText = false
    editor.string = "Уточнение"
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    var submissions = 0
    editor.onSubmit = { submissions += 1 }
    func enter(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeated, keyCode: 36))
    }
    editor.keyDown(with: try enter())
    #expect(submissions == 1)
    #expect(editor.string == "Уточнение")
    editor.keyDown(with: try enter(.shift))
    #expect(submissions == 1)
    #expect(editor.string == "Уточнение\n")
    editor.keyDown(with: try enter(repeated: true))
    #expect(submissions == 1)
    editor.keyDown(with: try enter(.command))
    #expect(submissions == 2)
}

@Test func responseTimingPersistsAndLocalizes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let timing = ResponseTiming(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 167))
    #expect(timing.label(language: .english) == "Worked for 1m 7s")
    #expect(timing.label(language: .russian) == "Время работы: 1 мин 7 с")
    #expect(ResponseTiming(startedAt: nil, completedAt: Date()).label(language: .english) == "Work finished")
    try await store.saveTiming(threadID: "t", turnID: "one", timing: timing)
    try await store.saveTiming(threadID: "t", turnID: "two", timing: timing)
    let restored = try await AppStore(file: folder.appendingPathComponent("state.sqlite")).loadTimings(threadID: "t")
    #expect(restored.count == 2)
    #expect(restored["one"] == timing)
    #expect(try await store.loadTimings(threadID: "other").isEmpty)
    var entries = [TranscriptItem(id: "c", kind: "assistant", text: "Commentary"), TranscriptItem(id: "a", kind: "assistant", text: "Answer")]
    ResponseTiming.apply(restored["one"], to: &entries)
    #expect(entries[0].timing == nil)
    #expect(entries[1].timing == timing)
    TranscriptItem.merge(TranscriptItem(id: "a", kind: "assistant", text: "Updated answer"), into: &entries)
    #expect(entries[1].timing == timing)
    try await store.saveDeletingChat(SavedState(), threadID: "t")
    #expect(try await store.loadTimings(threadID: "t").isEmpty)
}

@Test @MainActor func timedAnswerRendersWithSeparatorAndFullWidth() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
    let timing = ResponseTiming(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 167))
    view.update(items: [TranscriptItem(id: "a", kind: "assistant", text: "Готово. Ответ отделён от действий тонкой границей.\n\nDone. The answer has a clear header.", timing: timing)], conversationID: "t", followOutput: false)
    view.layoutSubtreeIfNeeded()
    #expect(view.transcript.string.contains(timing.label()))
    #expect(view.transcript.string.contains(L10n.date(timing.completedAt)))
    let storage = try #require(view.transcript.textStorage)
    let timingIndex = (storage.string as NSString).range(of: timing.label()).location
    #expect(storage.attribute(NSAttributedString.Key("ContextDeskResponseSeparator"), at: timingIndex, effectiveRange: nil) as? Bool == true)
    if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
        view.drawsBackground = true
        view.backgroundColor = .windowBackgroundColor
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".timing.png"))
    }
}

@Test @MainActor func firstUserBubbleTopIsDrawnInABandAboveItsText() throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
    view.update(items: [TranscriptItem(id: "u", kind: "user", text: "посмотри сегодняшний поиск работы - утренний прогон\nтам было delivery unconfirmed")],
                conversationID: "t", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let text = view.transcript, origin = text.textContainerOrigin
    let width = try #require(text.textContainer).containerSize.width
    // Only the bubble's overhang above the first line: no glyphs lie inside this rect.
    let band = NSRect(x: origin.x + width - 120, y: origin.y - 8, width: 80, height: 6)
    let bitmap = try #require(text.bitmapImageRepForCachingDisplay(in: band))
    text.cacheDisplay(in: band, to: bitmap)
    let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    #expect(color.alphaComponent > 0.9)
    #expect(abs(color.redComponent - 0.95) < 0.03)
}

@Test @MainActor func copyMessageWritesOnlyItsFullSourceTextAndTracksUpdates() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = TranscriptScrollView(pasteboard: pasteboard)
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    let body = "  Полный ответ 👋\n\n**Текст** и [ссылка](https://example.com)\n```swift\nlet n = 1\n```\n"
    var items = [TranscriptItem(id: "u", kind: "user", text: "Мой вопрос"),
                 TranscriptItem(id: "comment", kind: "assistant", text: "Проверяю"),
                 TranscriptItem(id: "tool", kind: "activity", text: "Служебный вывод"),
                 TranscriptItem(id: "answer", kind: "assistant", text: body,
                    timing: ResponseTiming(startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 167)))]
    view.update(items: items, conversationID: "copy", followOutput: false)
    let storage = try #require(view.transcript.textStorage)
    var copyLinks: [String] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if let value = value as? String, value.hasPrefix("contextdesk-copy:") { copyLinks.append(value) }
    }
    #expect(copyLinks == ["contextdesk-copy:u", "contextdesk-copy:answer"])
    var icons = 0
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        // Code blocks carry their own copy control; count message controls only.
        guard let attachment = value as? NSTextAttachment,
              storage.attribute(NSAttributedString.Key("ContextDeskMessageCopy"), at: range.location, effectiveRange: nil) != nil else { return }
        // Message copy icons are drawn by a hover cell; they stay in place and clickable.
        #expect(attachment.image != nil || (attachment.attachmentCell as? NSCell)?.image != nil)
        #expect(storage.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String ==
            L10n.text("Скопировать полный текст сообщения", "Copy the full message text"))
        icons += 1
    }
    #expect(icons == 2)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-metrics:comment", at: 0)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:answer", at: 0)
    #expect(pasteboard.string(forType: .string) == body)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:u", at: 0)
    #expect(pasteboard.string(forType: .string) == "Мой вопрос")
    items[3].text += "Продолжение"
    view.update(items: items, conversationID: "copy", followOutput: false)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:answer", at: 0)
    #expect(pasteboard.string(forType: .string) == body + "Продолжение")
    let changes = pasteboard.changeCount
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:comment", at: 0)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:tool", at: 0)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:unknown", at: 0)
    #expect(pasteboard.changeCount == changes)
    if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
        view.drawsBackground = true; view.backgroundColor = .windowBackgroundColor
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".copy.png"))
    }
    view.update(items: [], conversationID: "other", followOutput: false)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:answer", at: 0)
    #expect(pasteboard.changeCount == changes)
}

@Test @MainActor func assistantCopyAppearsOnlyOnceAfterFinalResponse() throws {
    let view = TranscriptScrollView()
    var items = [TranscriptItem(id: "c1", kind: "assistant", text: "Начинаю", phase: "commentary"),
                 TranscriptItem(id: "tool", kind: "activity", text: "Проверка"),
                 TranscriptItem(id: "c2", kind: "assistant", text: "Проверяю", phase: "commentary")]
    func copyLinks() throws -> [String] {
        let storage = try #require(view.transcript.textStorage)
        var links: [String] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let value = value as? String, value.hasPrefix("contextdesk-copy:") { links.append(value) }
        }
        return links
    }
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: true)
    #expect(try copyLinks().isEmpty)
    items.append(TranscriptItem(id: "final", kind: "assistant", text: "Итог", phase: "final_answer"))
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: true)
    #expect(try copyLinks().isEmpty)
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(try copyLinks() == ["contextdesk-copy:final"])
    items += [TranscriptItem(id: "u", kind: "user", text: "Дальше"),
              TranscriptItem(id: "next", kind: "assistant", text: "Работаю", phase: "commentary")]
    view.update(items: items, conversationID: "t", followOutput: false, isWorking: true)
    #expect(try copyLinks() == ["contextdesk-copy:final", "contextdesk-copy:u"])
    view.update(items: items, conversationID: "t", followOutput: false)
    #expect(try copyLinks() == ["contextdesk-copy:final", "contextdesk-copy:u"])
    view.update(items: [TranscriptItem(id: "old1", kind: "assistant", text: "Старый прогресс"),
                       TranscriptItem(id: "old2", kind: "assistant", text: "Старый итог")], conversationID: "history", followOutput: false)
    #expect(try copyLinks() == ["contextdesk-copy:old2"])
}

@Test @MainActor func copyFeedbackConfirmsSuccessThenResetsWithoutChangingClipboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = TranscriptScrollView(pasteboard: pasteboard)
    view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
    let items = [TranscriptItem(id: "u", kind: "user", text: "Вопрос"),
                 TranscriptItem(id: "a", kind: "assistant", text: "Ответ")]
    view.update(items: items, conversationID: "t", followOutput: false)
    let copied = L10n.text("Скопировано", "Copied")
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:a", at: 0)
    #expect(view.transcript.string.contains(copied))
    #expect(pasteboard.string(forType: .string) == "Ответ")
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:u", at: 0)
    #expect(view.transcript.string.components(separatedBy: copied).count - 1 == 1)
    #expect(pasteboard.string(forType: .string) == "Вопрос")
    for _ in 0..<60 {
        if !view.transcript.string.contains(copied) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!view.transcript.string.contains(copied))
    #expect(pasteboard.string(forType: .string) == "Вопрос")
    #expect(view.transcript.string.contains("Ответ"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-copy:a", at: 0)
    view.update(items: items, conversationID: "other", followOutput: false)
    #expect(!view.transcript.string.contains(copied))
    #expect(pasteboard.string(forType: .string) == "Ответ")
}

@Test @MainActor func quotedReplyCardsCopyOnlyTheirVisibleText() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = TranscriptScrollView(pasteboard: pasteboard)
    view.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
    let source = "Можно ответить так:\n\n> Hi Elina,\n>\n> Спасибо за разговор 👋.\n> Could you please confirm the details before we proceed with the submission?\n>\n> Best regards,\n> Daniil\n\nВторой вариант:\n\n> Короткий ответ.\n\n```text\n> literal code\n```"
    var items = [TranscriptItem(id: "reply", kind: "assistant", text: source)]
    view.update(items: items, conversationID: "quotes", followOutput: false)
    let storage = try #require(view.transcript.textStorage)
    func controls() -> [(Int, String)] {
        var result: [(Int, String)] = []
        storage.enumerateAttribute(NSAttributedString.Key("ContextDeskQuoteCopy"), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let body = value as? String { result.append((range.location, body)) }
        }
        return result
    }
    #expect(controls().count == 2)
    #expect(storage.string.contains("> literal code"))
    #expect(!storage.string.contains("> Hi Elina"))
    #expect(!view.transcript.isEditable && view.transcript.isSelectable)
    let first = try #require(controls().first)
    let icon = try #require(storage.attribute(.attachment, at: first.0, effectiveRange: nil) as? NSTextAttachment)
    #expect(icon.image != nil)
    #expect(icon.bounds.size == NSSize(width: 14, height: 14))
    #expect(storage.attributedSubstring(from: NSRange(location: first.0, length: 12)).string.contains(L10n.text("Копировать", "Copy")))
    #expect(storage.attribute(.toolTip, at: first.0, effectiveRange: nil) as? String ==
            L10n.text("Скопировать текст блока", "Copy the block text"))
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-quote-copy", at: first.0)
    #expect(pasteboard.string(forType: .string) == "Hi Elina,\n\nСпасибо за разговор 👋.\nCould you please confirm the details before we proceed with the submission?\n\nBest regards,\nDaniil")
    #expect(storage.string.contains(L10n.text("Скопировано", "Copied")))
    let second = try #require(controls().last)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-quote-copy", at: second.0)
    #expect(pasteboard.string(forType: .string) == "Короткий ответ.")
    let changeCount = pasteboard.changeCount
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-quote-copy", at: 0)
    #expect(pasteboard.changeCount == changeCount)
    for width in [620.0, 340.0] {
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.transcript.layoutManager)
        let container = try #require(view.transcript.textContainer)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).maxX <= container.containerSize.width + 1)
        if let path = ProcessInfo.processInfo.environment["SWITCHBOARD_RENDER_PATH"] {
            view.drawsBackground = true; view.backgroundColor = .windowBackgroundColor
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".quote-\(Int(width)).png"))
        }
    }
    items[0].text = "> Updated reply"
    view.update(items: items, conversationID: "quotes", followOutput: false)
    #expect(controls().count == 1)
    _ = view.textView(view.transcript, clickedOnLink: "contextdesk-quote-copy", at: try #require(controls().first).0)
    #expect(pasteboard.string(forType: .string) == "Updated reply")
    view.update(items: [TranscriptItem(id: "u", kind: "user", text: "> user content")], conversationID: "other", followOutput: false)
    #expect(controls().isEmpty)
}

@Test @MainActor func claudeTranscriptPreservesAgentInLiveAndPortableHistory() {
    let source = AgentSessionReference(connection: .appClaude, nativeID: "fixture")
    let snapshot = AgentTranscriptSnapshot(conversation: ConversationID("claude"), source: source,
        revision: "r1", capturedAt: Date(), completeness: .partial,
        items: [.init(id: "assistant", kind: .assistant, text: "Claude answer"), .init(id: "tool", kind: .activity, text: "Read file")])
    let items = LocalHistory.items(snapshot)
    #expect(items.allSatisfy { $0.agentName == "Claude" })
    let view = TranscriptScrollView()
    view.update(items: items, conversationID: "claude", followOutput: false)
    #expect(view.transcript.string.contains("Claude"))
    #expect(!view.transcript.string.contains("Codex"))
}

@Test func runningActivityShowsToolCallsAsReadableLines() {
    #expect(TranscriptScrollView.activityHeadline("Bash\n{\n  \"command\" : \"cd \\/tmp && ls\",\n  \"timeout\" : 5\n}") == "Bash · cd /tmp && ls")
    #expect(TranscriptScrollView.activityHeadline("Read\n{\"file_path\": \"/a/b.swift\"}") == "Read · /a/b.swift")
    #expect(TranscriptScrollView.activityHeadline("TodoWrite\n{\"todos\": []}") == "TodoWrite")
    #expect(TranscriptScrollView.activityHeadline("Вторая команда\nвывод") == "Вторая команда вывод")
    #expect(TranscriptScrollView.activityHeadline(String(repeating: "x", count: 200)).count == 120)
}

@Test @MainActor func agentMessagesInOneTurnAreSeparatedByOneBlankLine() {
    let view = TranscriptScrollView()
    view.update(items: [
        TranscriptItem(id: "u", kind: "user", text: "Сделай"),
        TranscriptItem(id: "c1", kind: "assistant", text: "Первая заметка.", phase: "commentary"),
        TranscriptItem(id: "c2", kind: "assistant", text: "Вторая заметка.\n", phase: "commentary"),
        TranscriptItem(id: "f", kind: "assistant", text: "Итог.", phase: "final_answer")
    ], conversationID: "gap", followOutput: false)
    #expect(view.transcript.string.contains("Первая заметка.\n\nВторая заметка.\n\nИтог."))
}

@Test @MainActor func composerHeightFollowsTextAndShrinksWhenCleared() async throws {
    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    editor.isRichText = false; editor.font = .systemFont(ofSize: 14)
    editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
    var heights: [CGFloat] = []
    editor.onContentHeight = { heights.append($0) }
    // Reports are delivered on the main queue, after AppKit layout.
    func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }
    editor.string = Array(repeating: "Строка", count: 6).joined(separator: "\n"); editor.reportContentHeight(); try await settle()
    let tall = heights.last ?? 0
    // The frame of a scrolled editor keeps its viewport height; the report must not.
    editor.setFrameSize(NSSize(width: 300, height: 200))
    editor.string = ""; editor.reportContentHeight(); try await settle()
    #expect(tall > 80)
    #expect((heights.last ?? .infinity) < 30)
}

@Test @MainActor func composerReportsHeightSynchronouslyAfterInsertedText() throws {
    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    editor.isRichText = false; editor.font = .systemFont(ofSize: 14)
    editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
    var heights: [CGFloat] = []
    editor.onContentHeight = { heights.append($0) }
    // Dictation and paste insert text; the viewport must be able to grow before the next frame.
    editor.insertText(Array(repeating: "Длинная продиктованная строка", count: 8).joined(separator: " "),
                      replacementRange: NSRange(location: 0, length: 0))
    #expect((heights.last ?? 0) > 60)
}

@Test @MainActor func zoomedTranscriptWidthDoesNotOscillateWhileStreaming() throws {
    // Under magnification the autoresizing width (unmagnified clip width) and the
    // document-point width used to reset each other on every pass, an endless layout loop.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = DeskModel(store: AppStore(file: folder.appendingPathComponent("state.sqlite")))
    model.authenticated = true
    model.models = [CodexModel(id: "gpt-5.4", displayName: "GPT-5.4")]
    model.state.model = "gpt-5.4"
    model.items = (0..<10).flatMap { index in
        [TranscriptItem(id: "u\(index)", kind: "user", text: "Вопрос \(index)"),
         TranscriptItem(id: "a\(index)", kind: "assistant", text: String(repeating: "Ответ с `кодом`. ", count: 60))]
    }
    let host = NSHostingView(rootView: ChatView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    func settle() { for _ in 0..<3 { window.layoutIfNeeded(); window.displayIfNeeded() } }
    settle()
    func find(_ view: NSView) -> TranscriptScrollView? { (view as? TranscriptScrollView) ?? view.subviews.lazy.compactMap(find).first }
    let scroll = try #require(find(host))
    let editor = try #require(scroll.documentView)
    InterfaceZoom.shared.set(1.1)
    defer { InterfaceZoom.shared.set(1); UserDefaults.standard.removeObject(forKey: InterfaceZoom.preferenceKey) }
    settle()
    var widths: [CGFloat] = []
    editor.postsFrameChangedNotifications = true
    let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: editor, queue: nil) { _ in
        MainActor.assumeIsolated { widths.append(editor.frame.width) }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    for step in 0..<5 {
        model.items.append(TranscriptItem(id: "s\(step)", kind: "assistant", text: String(repeating: "Поток ", count: 30)))
        settle()
    }
    #expect(scroll.magnification == 1.1)
    #expect(abs(editor.frame.width - scroll.contentView.bounds.width) < 0.5)
    #expect(widths.allSatisfy { abs($0 - scroll.contentView.bounds.width) < 0.5 })
}
