import AppKit
import Testing
import ContextCore
@testable import ContextTranscript

@MainActor private func readingItems() -> [TranscriptItem] {
    (0..<20).map { TranscriptItem(id: "message-\($0)", kind: "assistant",
        text: String(repeating: "Reading line / Строка чтения\n", count: 12)) }
}

@MainActor private func readingView(_ positions: TranscriptReadingPositions) -> TranscriptScrollView {
    let view = TranscriptScrollView(positions: positions)
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    return view
}

@Test @MainActor func readingPositionSurvivesSwitchAndViewRecreation() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    let y = view.contentView.bounds.origin.y
    #expect(y > 0)
    #expect(!view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "b", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    #expect(abs(view.contentView.bounds.origin.y - y) < 2)

    let recreated = readingView(positions)
    recreated.update(items: items, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    recreated.layoutSubtreeIfNeeded()
    #expect(abs(recreated.contentView.bounds.origin.y - y) < 2)
}

@Test @MainActor func readingAnchorSurvivesPrependedHistoryAndNewAnswers() throws {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    view.contentView.scroll(to: NSPoint(x: 0, y: 1800))
    view.reflectScrolledClipView(view.contentView)
    guard case let .anchor(id, character, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected a reading anchor"); return
    }
    let expanded = [TranscriptItem(id: "older", kind: "user", text: String(repeating: "Older history\n", count: 30))]
        + items + [TranscriptItem(id: "new", kind: "assistant", text: "New answer")]
    view.update(items: expanded, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    guard case let .anchor(restoredID, restoredCharacter, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected the restored reading anchor"); return
    }
    #expect(restoredID == id)
    #expect(restoredCharacter == character)
    #expect(!view.isAtTranscriptEnd)
}

@Test @MainActor func returningFromEndFollowsNewContentWithFollowingDisabled() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: false)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "b", followOutput: false)
    view.layoutSubtreeIfNeeded()
    view.update(items: items + [TranscriptItem(id: "new", kind: "assistant", text: String(repeating: "New\n", count: 50))],
                conversationID: "a", followOutput: false, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
}

@Test @MainActor func sentMessageScrollsIntoViewAfterReadingUp() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    #expect(!view.isAtTranscriptEnd)
    view.update(items: items + [TranscriptItem(id: "sent", kind: "user", text: "A new question")], conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
}

/// The chat always passes follow = true: scrolling up stops following, returning to the end or the jump button resumes it.
@Test @MainActor func scrollingUpStopsFollowingAndReturningToTheEndResumes() {
    let positions = TranscriptReadingPositions()
    var items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    func stream(_ id: String) {
        items.append(TranscriptItem(id: id, kind: "assistant", text: String(repeating: "Streamed / Поток\n", count: 20)))
        view.update(items: items, conversationID: "a", followOutput: true, isWorking: true)
        view.layoutSubtreeIfNeeded()
    }
    stream("first")
    #expect(view.isAtTranscriptEnd)
    // Scrolled up: new output arrives below, the reader keeps their place.
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    stream("second")
    #expect(!view.isAtTranscriptEnd)
    #expect(abs(view.contentView.bounds.origin.y - 900) < 2)
    // Back at the end by scrolling: following resumes.
    if let container = view.transcript.textContainer { view.transcript.layoutManager?.ensureLayout(for: container) }
    view.transcript.scrollRangeToVisible(NSRange(location: view.transcript.textStorage?.length ?? 0, length: 0))
    view.reflectScrolledClipView(view.contentView)
    #expect(view.isAtTranscriptEnd)
    stream("third")
    #expect(view.isAtTranscriptEnd)
    // Scrolled up again, then the jump-to-latest button: following resumes too.
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    stream("fourth")
    #expect(!view.isAtTranscriptEnd)
    view.jumpToEnd()
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    stream("fifth")
    #expect(view.isAtTranscriptEnd)
}

@Test @MainActor func streamedTextWaitsForTheScrollGestureToEnd() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    let origin = view.contentView.bounds.origin.y
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
    let streamed = items + [TranscriptItem(id: "reply", kind: "assistant", text: String(repeating: "Streamed\n", count: 40))]
    view.update(items: streamed, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(abs(view.contentView.bounds.origin.y - origin) < 1)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)

    // A reader who scrolls up during the gesture keeps their place.
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
    view.update(items: streamed + [TranscriptItem(id: "more", kind: "assistant", text: "More\n")], conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    view.layoutSubtreeIfNeeded()
    #expect(!view.isAtTranscriptEnd)
    #expect(abs(view.contentView.bounds.origin.y - 900) < 2)
}

/// Takes any origin, as AppKit's rubber band does past the end.
private final class StretchableClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}

@Test @MainActor func layoutLeavesTheRubberBandStretchedPastTheEnd() {
    let view = readingView(TranscriptReadingPositions())
    view.update(items: readingItems(), conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    let clip = StretchableClipView()
    clip.drawsBackground = false
    view.contentView = clip
    view.documentView = view.transcript
    view.layoutSubtreeIfNeeded()
    let maxY = view.transcript.frame.height - view.contentView.bounds.height
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
    // Mid-bounce: the viewport is past the end and a layout pass comes from outside.
    view.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxY + 60))
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    #expect(abs(view.contentView.bounds.origin.y - (maxY + 60)) < 1)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    view.layoutSubtreeIfNeeded()
    #expect(view.contentView.bounds.origin.y <= maxY + 1)
}

@Test @MainActor func endStaysInViewWhenTheViewportShrinks() {
    let positions = TranscriptReadingPositions()
    let view = readingView(positions)
    view.update(items: readingItems(), conversationID: "a", followOutput: false)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    // The composer grows: the transcript loses height at the bottom.
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 260)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
}

@Test @MainActor func longChatOpensInPartsAndKeepsTheReadingPlace() throws {
    let positions = TranscriptReadingPositions()
    let items = (0..<200).map { TranscriptItem(id: "long-\($0)", kind: "assistant",
        text: "Message \($0)\n" + String(repeating: "Reading line / Строка чтения\n", count: 12)) }
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.renderHistory()
    view.layoutSubtreeIfNeeded()
    if let container = view.transcript.textContainer { view.transcript.layoutManager?.ensureLayout(for: container) }
    view.layoutSubtreeIfNeeded()
    // A place well above the first screen of the end (about message 150).
    view.contentView.scroll(to: NSPoint(x: 0, y: (view.transcript.frame.height * 0.75).rounded()))
    view.reflectScrolledClipView(view.contentView)
    guard case let .anchor(id, character, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected a reading anchor"); return
    }

    // Reopened on a new view: the anchor's row is rendered at once, the rest of the history follows in parts.
    let reopened = readingView(positions)
    reopened.update(items: items, conversationID: "a", followOutput: true)
    reopened.layoutSubtreeIfNeeded()
    #expect(!reopened.historyBacklog.isEmpty)
    #expect(reopened.previous.contains { $0.id == id })
    func place() -> String {
        guard case let .anchor(id, character, _, _)? = positions.values["a"] else { return "none" }
        return "\(id)@\(character)"
    }
    #expect(place() == "\(id)@\(character)")
    let top = reopened.contentView.bounds.origin.y
    var parts = 0
    while !reopened.historyBacklog.isEmpty, parts < 1_000 {
        reopened.renderHistoryChunk(); reopened.layoutSubtreeIfNeeded(); parts += 1
        #expect(place() == "\(id)@\(character)")
    }
    #expect(reopened.previous.count == 200)
    #expect(reopened.contentView.bounds.origin.y > top)
    #expect(!reopened.isAtTranscriptEnd)
}

/// Text not laid out yet has an estimated height. A reader who comes near the end fast (a flick, a scroller drag) gets the
/// rest of the text laid out before reaching it, so the end does not move under them when the last part is shown.
@Test @MainActor func endIsExactBeforeAFastScrollReachesIt() throws {
    let items = (0..<300).map { TranscriptItem(id: "fast-\($0)", kind: "assistant",
        text: "Message \($0)\n" + String(repeating: "Reading line / Строка чтения\n", count: 40)) }
    let view = readingView(TranscriptReadingPositions())
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    // At the top the whole history goes in; inserting it drops the layout of the end.
    view.contentView.scroll(to: .zero)
    view.reflectScrolledClipView(view.contentView)
    view.renderHistory()
    view.layoutSubtreeIfNeeded()
    #expect(view.historyBacklog.isEmpty)
    let manager = try #require(view.transcript.layoutManager), container = try #require(view.transcript.textContainer)
    let storage = try #require(view.transcript.textStorage)
    // One long step to two viewports above the (estimated) end.
    let viewport = view.contentView.bounds.height
    view.contentView.scroll(to: NSPoint(x: 0, y: view.transcript.frame.height - 3 * viewport))
    view.reflectScrolledClipView(view.contentView)
    let below = view.transcript.frame.maxY - view.contentView.bounds.maxY
    // Showing the rest on the way down lays it out; the end stays where it was.
    let point = NSPoint(x: 0, y: view.contentView.bounds.minY - view.transcript.textContainerOrigin.y)
    let start = manager.characterIndexForGlyph(at: manager.glyphIndex(for: point, in: container))
    manager.ensureLayout(forCharacterRange: NSRange(location: start, length: storage.length - start))
    #expect(abs(view.transcript.frame.maxY - view.contentView.bounds.maxY - below) < 2)
    #expect(below > viewport)
}

/// Text put above the reader makes TextKit lay out everything from the top to their place again, so a reader far below
/// a long history gets it only near the top, in slices; a selection moves with its text.
@Test @MainActor func renderedHistoryWaitsAboveADistantReaderAndGoesInNearTheTop() async throws {
    let positions = TranscriptReadingPositions()
    let items = (0..<300).map { TranscriptItem(id: "far-\($0)", kind: "assistant",
        text: "Message \($0)\n" + String(repeating: "Reading line / Строка чтения\n", count: 40)) }
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    let waiting = view.historyBacklog.count
    #expect(waiting > 0)
    // Read up from the end a little: well above the end, far below the top of a long history.
    let storage = try #require(view.transcript.textStorage)
    let top = view.contentView.bounds.minY
    view.contentView.scroll(to: NSPoint(x: 0, y: top - 300))
    view.reflectScrolledClipView(view.contentView)
    // Parts wait while the reader scrolls far from the top; this one has stopped.
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(350))
    guard case let .anchor(id, _, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected a reading anchor"); return
    }
    // The whole backlog renders, and waits: the text above the reader is far longer than a cheap layout.
    var parts = 0
    while view.historyPendingStart > 0, parts < 1_000 { view.renderHistoryChunk(); view.layoutSubtreeIfNeeded(); parts += 1 }
    view.renderHistoryChunk(); view.layoutSubtreeIfNeeded()
    #expect(view.historyPendingStart == 0)
    #expect(view.historyBacklog.count == waiting)
    // The reader stays in the same message (TextKit may still settle the viewport by a line under load).
    guard case let .anchor(sameID, _, _, _)? = positions.values["a"] else { Issue.record("Lost the anchor"); return }
    #expect(sameID == id)
    // Near the top the rows just above go in, a slice at a time, until the history is complete.
    let marked = (storage.string as NSString).range(of: "Message 299")
    view.transcript.setSelectedRange(marked)
    view.contentView.scroll(to: .zero)
    view.reflectScrolledClipView(view.contentView)
    view.renderHistoryChunk(); view.layoutSubtreeIfNeeded()
    #expect(view.historyBacklog.count < waiting)
    #expect(!view.historyBacklog.isEmpty)
    parts = 0
    while !view.historyBacklog.isEmpty, parts < 1_000 {
        view.contentView.scroll(to: .zero); view.reflectScrolledClipView(view.contentView)
        view.renderHistoryChunk(); view.layoutSubtreeIfNeeded(); parts += 1
    }
    #expect(view.previous.map(\.id) == items.map(\.id))
    #expect((storage.string as NSString).substring(with: view.transcript.selectedRange()) == "Message 299")
    let once = readingView(TranscriptReadingPositions())
    once.update(items: items, conversationID: "a", followOutput: true)
    once.renderHistory()
    #expect(once.transcript.string == view.transcript.string)
}
