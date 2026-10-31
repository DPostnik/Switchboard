import AppKit
import SwiftUI
import ContextCore

/// A bounded AppKit viewport owns text layout. No SwiftUI lazy-stack sizing or
/// scrollTo transaction participates in streaming updates.
public struct NativeTranscript: NSViewRepresentable {
    let items: [TranscriptItem]
    let conversationID: String?
    let followOutput: Bool
    let isWorking: Bool
    let workingStatus: String?
    let workingSince: Date?
    let unreadCompletionID: String?
    let unreadResponseItemID: String?
    let onReadToEnd: ((String, String) -> Void)?
    let projectPath: String?
    let onOpenFile: ((URL, Int?) -> Void)?
    /// Read while the parent renders, so a zoom change updates the view.
    let zoom = InterfaceZoom.shared.scale
    public init(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, projectPath: String? = nil,
                onOpenFile: ((URL, Int?) -> Void)? = nil, onReadToEnd: ((String, String) -> Void)? = nil) {
        self.unreadCompletionID = unreadCompletionID; self.onReadToEnd = onReadToEnd; self.projectPath = projectPath
        self.onOpenFile = onOpenFile
        self.unreadResponseItemID = unreadResponseItemID
        self.isWorking = isWorking; self.workingStatus = workingStatus; self.workingSince = workingSince
        self.items = items; self.conversationID = conversationID; self.followOutput = followOutput
    }
    public func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView(positions: .session) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    public func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.onReadToEnd = onReadToEnd
        view.onOpenFile = onOpenFile
        view.zoom = zoom
        view.update(items: items, conversationID: conversationID, followOutput: followOutput,
                    isWorking: isWorking, workingStatus: workingStatus, workingSince: workingSince, unreadCompletionID: unreadCompletionID,
                    unreadResponseItemID: unreadResponseItemID, projectPath: projectPath)
    }
}

@MainActor public final class TranscriptScrollView: WidthBoundTextScrollView, NSTextViewDelegate {
    public let transcript: NSTextView
    private let pasteboard: NSPasteboard
    private var previous: [TranscriptItem] = []
    private var ranges: [NSRange] = []
    private var conversationID: String?
    private var followed = false
    private var wasWorking = false
    private var expandedActions: Set<String> = []
    private var expandedMetrics: Set<String> = []
    /// The tool calls behind each activity summary row, keyed by the row's id; their bodies are rendered only when the row is open.
    private var actionGroups: [String: [TranscriptItem]] = [:]
    /// The last grouping and the cheap key it was computed for; a streaming update mostly changes only the last item.
    private var groupingMemo: (key: GroupingKey, items: [TranscriptItem], groups: [String: [TranscriptItem]])?
    /// The headline of the running tool call, keyed by item id and text length; parsing its JSON input is not free.
    private var headlineMemo: (id: String, length: Int, headline: String)?
    /// Number of `render` calls so far; tests check that unchanged messages are not rendered again.
    public private(set) var renderCount = 0
    private struct GroupingKey: Equatable {
        var conversationID: String?
        var count: Int
        var lastID: String?
        var lastLength: Int
        var totalLength: Int
        var isWorking: Bool
    }
    private(set) var copyFeedback: (id: String, succeeded: Bool, block: Int?)?
    /// Collapsible code, `<details>` and source lists the user opened, keyed by item and block.
    private(set) var expandedBlocks: Set<String> = []
    /// Answer section under the pointer; its heading shows a copy control.
    private(set) var hoveredSection: String?
    private var projectPath: String?
    /// Previews a file the user clicked in an answer (URL and optional line); without it files open externally.
    public var onOpenFile: ((URL, Int?) -> Void)?
    /// Quotes the selected text into the chat with its numbered code lines, if any; nil hides the menu item.
    public var onQuoteSelection: ((String, ClosedRange<Int>?) -> Void)?
    /// A document shown in the preview pane: no grouping, author headers or copy-all control, code never collapses.
    public var isDocument = false
    /// The file shown in document mode; wiki links and relative paths resolve from it.
    public var documentURL: URL?
    private var copyFeedbackTask: Task<Void, Never>?
    private var needsEndScroll = false
    /// The reader was at the end at the last user scroll; a viewport height change then keeps the end in view.
    private var pinnedToEnd = false
    private var lastViewportHeight: CGFloat = 0
    private let positions: TranscriptReadingPositions
    private var pendingPosition: TranscriptReadingPositions.Position?
    private var changingLayout = false
    private var unreadCompletionID: String?
    private var unreadResponseItemID: String?
    private var readCheckScheduled = false
    public var onReadToEnd: ((String, String) -> Void)?
    private var styledWidth: CGFloat = 0
    /// True from a trackpad gesture's start through its momentum. Moving the clip view meanwhile fought the
    /// rubber band at the end, so streamed text waits; `deferredEndScroll` is the end the reader was at.
    private var liveScrolling = false
    private var deferredEndScroll: CGFloat?
    public private(set) var editCount = 0
    public let workingIndicator = WorkingIndicatorView()
    private var workingStatus: String?
    private var workingSince: Date?
    private var workingTimer: Timer?
    /// Storage edits that arrived while AppKit tracked a click, keyed so the latest of each kind wins.
    private var afterClick: [(key: String, work: () -> Void)] = []
    private var clickDepth = 0
    /// Message whose copy control is shown; controls of other messages stay hidden until hovered.
    public private(set) var hoveredItemID: String?
    /// Transcript text keeps a readable column; wider windows add margins instead of longer lines.
    public static let readableWidth: CGFloat = 760
    /// Interface zoom. Magnification keeps every font, inset and table width in proportion;
    /// TextKit lays out in unscaled document points, so the readable column scales too.
    public var zoom: CGFloat = 1 {
        didSet {
            guard abs(zoom - oldValue) > 0.001 else { return }
            magnification = zoom
            needsLayout = true
        }
    }

    public init(pasteboard: NSPasteboard = .general, positions: TranscriptReadingPositions = TranscriptReadingPositions()) {
        self.positions = positions
        self.pasteboard = pasteboard
        // TextKit 1's non-contiguous layout avoids laying out an entire long
        // transcript to display a small viewport.
        let storage = NSTextStorage(), manager = BubbleLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        manager.allowsNonContiguousLayout = true
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        transcript = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), textContainer: container)
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isRichText = true; transcript.importsGraphics = false
        transcript.isAutomaticLinkDetectionEnabled = false
        // Keep our link styling, but explicitly retain the hand cursor for links
        // and linked attachments such as the message-copy icon.
        transcript.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        // Width is set only by `WidthBoundTextScrollView.layout()` in document points. Autoresizing
        // would apply the unmagnified clip width, so under zoom the two would keep resetting each other.
        transcript.autoresizingMask = []
        transcript.textContainerInset = NSSize(width: 24, height: 24)
        container.widthTracksTextView = true; container.heightTracksTextView = false
        transcript.delegate = self
        transcript.setAccessibilityLabel(L10n.text("История разговора", "Conversation history"))
        documentView = transcript
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted),
                                               name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
                                               name: NSScrollView.didEndLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReadCheck),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        workingIndicator.isHidden = true
        workingIndicator.setAccessibilityLabel(L10n.text("Агент работает", "Agent is working"))
        transcript.addSubview(workingIndicator)
        (transcript as? TranscriptTextView)?.didDrawText = { [weak self] in self?.positionWorkingIndicator() }
        (transcript as? TranscriptTextView)?.hoverChanged = { [weak self] point in self?.updateHover(at: point) }
        (transcript as? TranscriptTextView)?.trackClick = { [weak self] click in
            if let self { self.holdingEdits(during: click) } else { click() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                       workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, projectPath: String? = nil) {
        if deferWhileClicking("update", { [weak self] in
            self?.update(items: items, conversationID: conversationID, followOutput: followOutput, isWorking: isWorking, workingStatus: workingStatus,
                         workingSince: workingSince, unreadCompletionID: unreadCompletionID, unreadResponseItemID: unreadResponseItemID,
                         projectPath: projectPath)
        }) { return }
        // Relative file links resolve against the project; a different project re-renders everything.
        let projectChanged = self.projectPath != projectPath
        self.projectPath = projectPath
        self.unreadResponseItemID = unreadResponseItemID
        self.unreadCompletionID = unreadCompletionID
        let workingStatus = isWorking ? Self.currentActivity(items).map { headline(of: $0) } ?? workingStatus : workingStatus
        var items = isDocument ? items : groupedItems(items, conversationID: conversationID, isWorking: isWorking)
        if isWorking {
            items.append(Self.workingRow(status: workingStatus, since: workingSince))
        }
        self.workingStatus = workingStatus; self.workingSince = isWorking ? workingSince : nil
        updateWorkingTimer()
        if workingIndicator.isHidden == isWorking { workingIndicator.isHidden = !isWorking }
        workingIndicator.isWorking = isWorking
        let finished = wasWorking && !isWorking
        wasWorking = isWorking
        let switched = self.conversationID != conversationID
        // Rows opened during the turn close when it finishes; they are re-rendered in place below.
        let closing = finished && !switched ? expandedActions : []
        if switched || finished { expandedActions.removeAll() }
        if switched { expandedMetrics.removeAll(); expandedBlocks.removeAll() }
        if let feedback = copyFeedback,
           switched || previous.first(where: { $0.id == feedback.id })?.text != items.first(where: { $0.id == feedback.id })?.text {
            copyFeedbackTask?.cancel()
            copyFeedback = nil
        }
        let resumeFollowing = followOutput && !followed
        followed = followOutput
        guard switched || finished || projectChanged || items != previous else {
            if resumeFollowing { scrollToEnd() }
            scheduleReadCheck()
            return
        }
        let savedPosition = pendingPosition ?? capturePosition()
        if let id = self.conversationID, let savedPosition { positions.values[id] = savedPosition }
        changingLayout = true
        defer { changingLayout = false; scheduleReadCheck() }
        let wasAtEnd = followOutput && !switched && isAtTranscriptEnd
        guard let storage = transcript.textStorage else { return }
        let oldOrigin = contentView.bounds.origin
        // Clamped: past the end the rubber band stretches the viewport beyond the document.
        let oldBottom = min(contentView.bounds.maxY, transcript.frame.maxY)
        let stretched = liveScrolling && contentView.bounds.maxY > oldBottom + 0.5
        // A finished turn changes the items it affects (copy control, compaction state, the working row), so the
        // prefix is computed as usual; only the rows that were open and now close are re-rendered above it.
        var common = 0
        if !switched && !projectChanged {
            while common < min(previous.count, items.count), previous[common] == items[common] { common += 1 }
        }
        let closingRows = closing.isEmpty ? [] : (0..<common).filter { closing.contains(previous[$0].id) }
        // A message the user just sent is brought into view even if they had scrolled up to re-read.
        let knownIDs = Set(previous.map(\.id))
        let sentMessage = followOutput && !switched && items.dropFirst(common).contains { $0.kind == "user" && !knownIDs.contains($0.id) }
        // Streaming rewrites only the last message or appends; text above the viewport keeps its place.
        let tailOnly = !switched && !projectChanged && closingRows.isEmpty && common + 1 >= previous.count
        // Re-rendering the last message briefly shortens the document and clamps the viewport; an anchor survives that.
        let gestureAnchor = liveScrolling && tailOnly && wasAtEnd && !stretched ? capturePosition(anchorAtEnd: true) : nil
        storage.beginEditing()
        for index in closingRows {
            let rendered = render(previous[index], expanded: false)
            let delta = rendered.length - ranges[index].length
            storage.replaceCharacters(in: ranges[index], with: rendered)
            ranges[index].length = rendered.length
            for next in (index + 1)..<ranges.count { ranges[next].location += delta }
        }
        let start = common < ranges.count ? ranges[common].location : storage.length
        storage.deleteCharacters(in: NSRange(location: start, length: storage.length - start))
        ranges = Array(ranges.prefix(common))
        for item in items.dropFirst(common) {
            let rendered = render(item, expanded: expandedActions.contains(item.id))
            ranges.append(NSRange(location: storage.length, length: rendered.length))
            storage.append(rendered)
        }
        storage.endEditing()
        previous = items; self.conversationID = conversationID; editCount += 1
        needsLayout = true
        if switched {
            needsEndScroll = false
            pendingPosition = conversationID.flatMap { positions.values[$0] }
            if pendingPosition == nil { scrollToEnd() }
        } else if followOutput && (resumeFollowing || sentMessage) { scrollToEnd() }
        else if wasAtEnd && !(liveScrolling && tailOnly) { scrollToEnd() }
        else {
            if wasAtEnd { deferredEndScroll = deferredEndScroll ?? oldBottom }
            if case .anchor = savedPosition { pendingPosition = savedPosition }
            if let gestureAnchor { pendingPosition = gestureAnchor }
            // Past the end the rubber band owns the origin; clamping it here would snap the stretch back.
            if !stretched {
                contentView.scroll(to: oldOrigin); reflectScrolledClipView(contentView)
            }
        }
    }

    /// NSTextView keeps the clicked link unretained between mouse-down and its delegate call, while its tracking loop
    /// still runs timers and main-queue work. Replacing that text meanwhile (a streaming update) frees the link and
    /// crashes the click, so transcript updates wait until `click` returns; the click's own edits apply at once.
    public func holdingEdits(during click: () -> Void) {
        clickDepth += 1
        click()
        clickDepth -= 1
        guard clickDepth == 0 else { return }
        let pending = afterClick
        afterClick = []
        for entry in pending { entry.work() }
    }

    private var isTrackingClick: Bool { clickDepth > 0 }

    private func deferWhileClicking(_ key: String, _ work: @escaping () -> Void) -> Bool {
        guard isTrackingClick else { return false }
        afterClick.removeAll { $0.key == key }
        afterClick.append((key, work))
        return true
    }

    private func scrollToEnd() {
        pendingPosition = nil
        needsEndScroll = true
        pinnedToEnd = true
        needsLayout = true
    }

    /// A reader at the end stays there when only the viewport's height changes (the composer grows, the window resizes).
    /// Uses the flag cached at the last scroll; checking the end here would lay out the whole transcript every frame.
    private func keepEndPinned() {
        let height = contentView.bounds.height
        defer { lastViewportHeight = height }
        guard pinnedToEnd, !liveScrolling, lastViewportHeight > 0, abs(height - lastViewportHeight) > 0.5, pendingPosition == nil else { return }
        needsEndScroll = true
        needsLayout = true
    }

    public override func layout() {
        changingLayout = true
        defer { changingLayout = false; rememberPosition() }
        let margin = max(24, ((contentView.bounds.width - Self.readableWidth) / 2).rounded(.down))
        if abs(transcript.textContainerInset.width - margin) > 0.5 {
            transcript.textContainerInset = NSSize(width: margin, height: 24)
        }
        super.layout()
        let width = transcript.textContainer?.containerSize.width ?? 0
        if width > 0, abs(width - styledWidth) > 0.5 {
            styledWidth = width
            if let storage = transcript.textStorage {
                storage.beginEditing()
                for (item, range) in zip(previous, ranges) {
                    applyMessageStyle(item, to: storage, range: range)
                }
                storage.endEditing()
            }
        }
        positionWorkingIndicator()
        defer { scheduleReadCheck() }
        guard contentSize.width > 0, contentSize.height > 0, !previous.isEmpty else { return }
        keepEndPinned()
        if let position = pendingPosition {
            pendingPosition = nil
            restorePosition(position)
        } else if needsEndScroll {
            needsEndScroll = false
            if let container = transcript.textContainer { transcript.layoutManager?.ensureLayout(for: container) }
            transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
        }
    }

    @objc private func liveScrollStarted() { liveScrolling = true }

    /// A reader who stayed at the end through the gesture follows the text that arrived meanwhile.
    @objc private func liveScrollEnded() {
        liveScrolling = false
        guard let end = deferredEndScroll else { return }
        deferredEndScroll = nil
        if contentView.bounds.maxY >= end - 2 { scrollToEnd() }
    }

    @objc private func viewportChanged() {
        workingIndicator.refreshAnimation()
        keepEndPinned()
        rememberPosition()
        scheduleReadCheck()
    }

    private func rememberPosition() {
        guard !changingLayout, pendingPosition == nil, !needsEndScroll,
              let id = conversationID, let position = capturePosition() else { return }
        positions.values[id] = position
        if case .end = position { pinnedToEnd = true } else { pinnedToEnd = false }
    }

    private func capturePosition(anchorAtEnd: Bool = false) -> TranscriptReadingPositions.Position? {
        guard !previous.isEmpty, contentSize.width > 0, contentSize.height > 0,
              let manager = transcript.layoutManager, let container = transcript.textContainer,
              let storage = transcript.textStorage, storage.length > 0 else { return nil }
        // Documents keep their place by anchor; checking the end lays out the whole text, which is costly for long files.
        if !anchorAtEnd, needsEndScroll || (!isDocument && isAtTranscriptEnd) { return .end }
        let origin = contentView.bounds.origin
        let point = NSPoint(x: container.lineFragmentPadding,
                            y: max(0, origin.y - transcript.textContainerOrigin.y))
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        guard let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) }) else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return .anchor(itemID: previous[index].id, character: character - ranges[index].location,
                       offset: origin.y - (line.minY + transcript.textContainerOrigin.y), fallbackY: origin.y)
    }

    private func restorePosition(_ position: TranscriptReadingPositions.Position) {
        guard let manager = transcript.layoutManager, let container = transcript.textContainer else { return }
        // A document growing part by part only needs layout up to the reading position, not to its end.
        if isDocument, case let .anchor(itemID, character, _, _) = position, let storage = transcript.textStorage,
           let index = previous.firstIndex(where: { $0.id == itemID }), ranges.indices.contains(index) {
            manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, ranges[index].location + character + 1)))
        } else {
            manager.ensureLayout(for: container)
        }
        switch position {
        case .end:
            transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
        case let .anchor(itemID, character, offset, fallbackY):
            var y = fallbackY
            if let index = previous.firstIndex(where: { $0.id == itemID }), ranges[index].length > 0 {
                let location = ranges[index].location + min(character, ranges[index].length - 1)
                let glyph = manager.glyphIndexForCharacter(at: location)
                y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + transcript.textContainerOrigin.y + offset
            }
            contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            reflectScrolledClipView(contentView)
        }
    }

    /// Non-contiguous TextKit layout can place the final glyph at an estimated position. Lay out the container
    /// before deciding that the end is visible, but only when the viewport is within one viewport height of the
    /// document's end: farther up, the frame alone shows that the end is out of view, and no layout is forced.
    public var isAtTranscriptEnd: Bool {
        guard contentSize.width > 0, contentSize.height > 0,
              let storage = transcript.textStorage, storage.length > 0,
              let manager = transcript.layoutManager, let container = transcript.textContainer else { return false }
        let viewport = contentView.bounds
        guard viewport.height > 0, viewport.maxY >= transcript.frame.maxY - viewport.height else { return false }
        let lastCharacter = NSRange(location: storage.length - 1, length: 1)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
        let end = manager.boundingRect(forGlyphRange: glyphs, in: container).maxY + transcript.textContainerOrigin.y
        let visible = transcript.visibleRect
        return visible.height > 0 && visible.maxY >= end - 2
    }

    /// A later running turn must not prevent acknowledgement of a completed answer.
    public var isUnreadResponseVisible: Bool {
        guard let itemID = unreadResponseItemID else { return !wasWorking && isAtTranscriptEnd }
        guard let index = previous.firstIndex(where: { $0.id == itemID }), ranges.indices.contains(index),
              let storage = transcript.textStorage, let manager = transcript.layoutManager,
              let container = transcript.textContainer, contentSize.height > 0 else { return false }
        let range = ranges[index]
        let text = storage.string as NSString
        // Copy controls and trailing blank paragraphs are not part of the answer to read.
        var bodyRange = range
        storage.enumerateAttribute(.messageCopy, in: range) { value, copyRange, _ in
            if value != nil { bodyRange.length = min(bodyRange.length, copyRange.location - range.location) }
        }
        let lastContent = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted,
                                               options: .backwards, range: bodyRange)
        guard lastContent.location != NSNotFound else { return false }
        let end = NSMaxRange(lastContent)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: end - 1, length: 1), actualCharacterRange: nil)
        let bottom = manager.boundingRect(forGlyphRange: glyphs, in: container).maxY + transcript.textContainerOrigin.y
        let visible = transcript.visibleRect
        return visible.height > 0 && visible.maxY >= bottom - 2
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReadCheck()
    }

    @objc private func scheduleReadCheck() {
        guard unreadCompletionID != nil, !readCheckScheduled else { return }
        readCheckScheduled = true
        // Never publish SwiftUI state from updateNSView or AppKit layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readCheckScheduled = false
            guard let completionID = self.unreadCompletionID, let threadID = self.conversationID,
                  let window = self.window, window.isKeyWindow, window.isVisible, !window.isMiniaturized,
                  NSApplication.shared.isActive, !self.isHiddenOrHasHiddenAncestor,
                  !self.needsEndScroll, self.pendingPosition == nil, self.isUnreadResponseVisible else { return }
            self.onReadToEnd?(threadID, completionID)
        }
    }

    /// The live row: the agent's latest status plus elapsed turn time (kept in `phase`).
    public static func workingRow(status: String?, since: Date?, now: Date = Date()) -> TranscriptItem {
        let elapsed = since.map { max(0, now.timeIntervalSince($0)) }.flatMap { $0.isFinite && $0 < 1e9 ? Int($0) : nil }
        return TranscriptItem(id: "local-working", kind: "loading", text: status ?? "",
                              phase: elapsed.map { ResponseTiming.duration($0) })
    }

    private func updateWorkingTimer() {
        guard wasWorking, workingSince != nil else { workingTimer?.invalidate(); workingTimer = nil; return }
        guard workingTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.refreshWorkingRow() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        workingTimer = timer
    }

    /// Replaces only the trailing working row, so ticking never re-renders the transcript.
    private func refreshWorkingRow() {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              let last = previous.last, last.kind == "loading", let range = ranges.last, let storage = transcript.textStorage,
              NSMaxRange(range) == storage.length, !isTrackingClick else { return }
        let row = Self.workingRow(status: workingStatus, since: workingSince)
        guard row != last else { return }
        let wasAtEnd = followed && isAtTranscriptEnd
        let rendered = render(row, expanded: false)
        changingLayout = true
        defer { changingLayout = false }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: rendered)
        storage.endEditing()
        previous[previous.count - 1] = row
        ranges[ranges.count - 1] = NSRange(location: range.location, length: rendered.length)
        if wasAtEnd && liveScrolling {
            deferredEndScroll = deferredEndScroll ?? min(contentView.bounds.maxY, transcript.frame.maxY)
        } else if wasAtEnd { scrollToEnd() }
    }

    private func positionWorkingIndicator() {
        if wasWorking, let range = ranges.last, let manager = transcript.layoutManager, let container = transcript.textContainer {
            manager.ensureLayout(forCharacterRange: range)
            let glyph = manager.glyphIndexForCharacter(at: range.location + 6)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let frame = NSRect(x: transcript.textContainerOrigin.x + container.lineFragmentPadding,
                               y: transcript.textContainerOrigin.y + rect.midY - 10, width: 20, height: 20)
            if workingIndicator.frame != frame { workingIndicator.frame = frame }
            workingIndicator.refreshAnimation()
        }
    }

    /// The tool call the agent is running now: the latest activity of the current request,
    /// unless the agent has already moved on to writing text.
    static func currentActivity(_ items: [TranscriptItem]) -> TranscriptItem? {
        guard let last = items.last(where: { $0.kind != "loading" }), last.kind == "activity" else { return nil }
        return last
    }

    private func updateHover(at point: NSPoint?) {
        var id: String?
        var section: String?
        if let point, let manager = transcript.layoutManager, let container = transcript.textContainer,
           let storage = transcript.textStorage, storage.length > 0 {
            let local = NSPoint(x: point.x - transcript.textContainerOrigin.x, y: point.y - transcript.textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if line.minY - 8 <= local.y, local.y <= line.maxY + 8 {
                let character = manager.characterIndexForGlyph(at: glyph)
                if character < storage.length { section = storage.attribute(.sectionKey, at: character, effectiveRange: nil) as? String }
                if let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) }), previous[index].showsCopyControl {
                    id = previous[index].id
                }
            }
        }
        guard id != hoveredItemID || section != hoveredSection else { return }
        hoveredItemID = id; hoveredSection = section
        transcript.setNeedsDisplay(transcript.visibleRect)
    }

    // Each user message starts a new activity group. Assistant commentary stays
    // visible; all tool entries for that request share one disclosure row.
    /// One readable line for the running action. A Claude tool call arrives as its name
    /// and JSON input; show the name and its most telling field instead of raw JSON.
    nonisolated public static func activityHeadline(_ text: String, limit: Int = 120) -> String {
        var line = text
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].contains(" "),
           let data = parts[1].data(using: .utf8),
           let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !input.isEmpty {
            let keys = ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "expression"]
            let value = keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
            line = value.map { parts[0] + " · " + $0 } ?? parts[0]
        }
        line = line.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private func headline(of activity: TranscriptItem) -> String {
        let length = activity.text.utf8.count
        if let memo = headlineMemo, memo.id == activity.id, memo.length == length { return memo.headline }
        let line = Self.activityHeadline(activity.text)
        headlineMemo = (activity.id, length, line)
        return line
    }

    /// Groups once per (conversation, item count, last item id and length, total text length, working) key: a
    /// streaming delta changes the last item's length, an appended item the count, a finished turn the flag. A
    /// middle item that changes without changing the total length keeps the previous grouping until the next change.
    private func groupedItems(_ items: [TranscriptItem], conversationID: String?, isWorking: Bool) -> [TranscriptItem] {
        let key = GroupingKey(conversationID: conversationID, count: items.count, lastID: items.last?.id,
                              lastLength: items.last?.text.utf8.count ?? 0,
                              totalLength: items.reduce(0) { $0 + $1.text.utf8.count }, isWorking: isWorking)
        if let memo = groupingMemo, memo.key == key {
            actionGroups = memo.groups
            return memo.items
        }
        let grouped = Self.groupActivities(items, isWorking: isWorking)
        groupingMemo = (key, grouped.items, grouped.groups)
        actionGroups = grouped.groups
        return grouped.items
    }

    /// Groups each request's tool calls behind one summary row. The row's text names the calls by id and text
    /// length only, so building and comparing it stays cheap on every update; their bodies come from `groups`
    /// (keyed by the row's id) through `actionDetails` when the row is open.
    static func groupActivities(_ items: [TranscriptItem], isWorking: Bool) -> (items: [TranscriptItem], groups: [String: [TranscriptItem]]) {
        var result: [TranscriptItem] = []
        var groups: [String: [TranscriptItem]] = [:]
        var segment: [TranscriptItem] = []
        func appendSegment(active: Bool) {
            let actions = segment.filter { $0.kind == "activity" }
            // Show one copy control only after the response finishes. Older history
            // may omit phase, so fall back to its last non-commentary assistant item.
            let finalAnswer = active ? nil : (segment.last { $0.kind == "assistant" && $0.phase == "final_answer" && !$0.text.isEmpty }
                ?? segment.last { $0.kind == "assistant" && $0.phase != "commentary" && !$0.text.isEmpty })
            let responseTiming = segment.last(where: { $0.kind == "assistant" && $0.timing != nil })?.timing
            var inserted = false
            var showedAuthor = false
            for var item in segment {
                if item.kind == "compaction", item.phase == "inProgress", !active {
                    item.phase = "unconfirmed"
                    item.text = L10n.text("Сжатие контекста: завершение не подтверждено", "Context compaction: completion unconfirmed")
                }
                if item.kind == "assistant" {
                    item.timing = showedAuthor ? nil : responseTiming
                    item.showsAuthor = !showedAuthor
                    item.showsCopyControl = item.id == finalAnswer?.id
                    showedAuthor = true
                }
                guard item.kind == "activity" else { result.append(item); continue }
                guard !inserted, let first = actions.first else { continue }
                inserted = true
                let summary = L10n.text("Действия \(first.agentName ?? "Codex") · \(actions.count)", "\(first.agentName ?? "Codex") actions · \(actions.count)")
                groups[first.id] = actions
                result.append(TranscriptItem(id: first.id, kind: "activity",
                                             text: actions.map { "\($0.id) \($0.text.utf8.count)" }.joined(separator: "\n"), phase: summary))
            }
            segment.removeAll()
        }
        for item in items {
            if item.kind == "user" { appendSegment(active: false) }
            segment.append(item)
        }
        appendSegment(active: isWorking)
        return (result, groups)
    }

    /// The numbered tool calls shown by an open summary row.
    static func actionDetails(_ actions: [TranscriptItem]) -> String {
        actions.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
    }

    private func render(_ item: TranscriptItem, expanded: Bool) -> NSAttributedString {
        renderCount += 1
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = item.kind == "activity" ? 1 : 4; paragraph.paragraphSpacing = item.kind == "activity" ? 2 : 0
        paragraph.lineBreakMode = .byWordWrapping
        if item.kind == "compaction" || item.kind == "refusal" {
            // A refusal is a stop notice from the safety classifier; a compaction tracks its own progress.
            let refusal = item.kind == "refusal"
            let active = !refusal && item.phase == "inProgress"
            let tint: NSColor? = refusal ? .systemOrange : active ? .controlAccentColor : nil
            let color = tint ?? NSColor.secondaryLabelColor
            let symbol = refusal ? "exclamationmark.shield" : active ? "arrow.triangle.2.circlepath"
                : item.phase == "completed" ? "checkmark.circle" : "minus.circle"
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
                    .applying(.init(paletteColors: [color])))
            attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            let spacer = NSMutableParagraphStyle()
            spacer.maximumLineHeight = 8
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 6), .paragraphStyle: spacer
            ]))
            let badgeStart = result.length
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  " + item.text))
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
            paragraph.tailIndent = -12
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 12
            paragraph.lineSpacing = 2
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color, .paragraphStyle: paragraph,
                .compactionBadge: item.id
            ], range: NSRange(location: badgeStart, length: result.length - badgeStart))
            if let tint { result.addAttribute(.badgeTint, value: tint, range: NSRange(location: badgeStart, length: result.length - badgeStart)) }
            // Keep paragraph terminators outside the badge so it hugs its content.
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph,
                .font: NSFont.systemFont(ofSize: 12)]))
            return result
        }
        if item.kind == "loading" {
            let font = NSFont.systemFont(ofSize: 12)
            result.append(NSAttributedString(string: "      " + item.text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            if let elapsed = item.phase {
                result.append(NSAttributedString(string: (item.text.isEmpty ? "" : "  ") + elapsed, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
                ]))
            }
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            return result
        }
        if item.kind == "activity" {
            let title = item.phase ?? L10n.text("Действия \(item.agentName ?? "Codex")", "\(item.agentName ?? "Codex") actions")
            result.append(NSAttributedString(string: (expanded ? "▾ " : "▸ ") + title + (expanded ? "\n" : "\n\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .link: "contextdesk-action:" + item.id,
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ]))
            if !expanded { return result }
        } else {
            if (item.kind == "user" && item.phase != nil) || (item.kind != "user" && item.showsAuthor) {
                let title = item.kind == "user" ? item.phase ?? "" : (item.agentName ?? "Codex")
                result.append(NSAttributedString(string: title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                    .responseHeader: true
                ]))
            }
            if let timing = item.timing {
                let open = expandedMetrics.contains(item.id)
                result.append(NSAttributedString(string: (open ? "▾ " : "▸ ") + timing.label() + " · " + L10n.date(timing.completedAt) + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                    .link: "contextdesk-metrics:" + item.id, .responseHeader: true, .responseSeparator: true
                ]))
                if open {
                    let detail = timing.tokens?.detail() ?? L10n.text("Данные о токенах для этого запроса недоступны.", "Token data is unavailable for this request.")
                    result.append(NSAttributedString(string: detail + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        }
        if item.kind == "assistant" {
            var markdown = TranscriptMarkdown(view: self, item: item, options: linkOptions,
                                              width: transcript.textContainer?.containerSize.width ?? 600)
            markdown.render(into: result)
        } else {
            // An open summary row shows its tool calls; a document's own activity item keeps its text.
            let body = item.kind == "activity" ? actionGroups[item.id].map(Self.actionDetails) ?? item.text : item.text
            for (index, block) in body.components(separatedBy: "```").enumerated() {
                let isCode = index % 2 == 1 || item.kind == "activity"
                let font = isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: item.kind == "activity" ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
                // Code and tool output stay literal, including link-like text.
                result.append(isCode ? NSAttributedString(string: block, attributes: attributes)
                              : TranscriptLinks.render(block, attributes: attributes))
            }
        }
        if (item.kind == "user" || item.kind == "assistant"), item.showsCopyControl, !item.text.isEmpty {
            if !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
            let feedback = copyFeedback.flatMap { $0.id == item.id && $0.block == nil ? $0.succeeded : nil }
            result.append(copyControl(feedback: feedback,
                                      description: L10n.text("Скопировать полный текст сообщения", "Copy the full message text"),
                                      hoverItemID: item.id,
                                      attributes: [.link: "contextdesk-copy:" + item.id, .messageCopy: true]))
        }
        // Exactly one blank line between messages: rendered Markdown already ends its last paragraph.
        while result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        // Document parts continue on the next line; messages are separated by a gap.
        result.append(NSAttributedString(string: isDocument ? "\n" : "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        applyMessageStyle(item, to: result, range: NSRange(location: 0, length: result.length))
        return result
    }

    var linkOptions: TranscriptLinks.Options {
        TranscriptLinks.Options(chips: true, baseDirectory: projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }, source: documentURL)
    }

    func copyControl(feedback: Bool?, description: String, hoverItemID: String? = nil, label: String? = nil,
                     visible: (@MainActor @Sendable () -> Bool)? = nil, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let feedbackText = feedback.map { $0 ? L10n.text("Скопировано", "Copied") : L10n.text("Не удалось скопировать", "Could not copy") }
        let description = feedbackText ?? description
        let color: NSColor = feedback.map { $0 ? .systemGreen : .systemRed } ?? .secondaryLabelColor
        let symbol = feedback.map { $0 ? "checkmark" : "exclamationmark.circle" } ?? "doc.on.doc"
        let attachment = NSTextAttachment()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: label == nil ? 13 : 11, weight: .regular)
                .applying(.init(paletteColors: [color])))
        if visible != nil || hoverItemID != nil, feedback == nil {
            // Message and section copy controls appear while the pointer is over their content.
            let cell = HoverAttachmentCell(imageCell: image ?? NSImage())
            if let visible { cell.isVisible = { MainActor.assumeIsolated { visible() } } }
            else if let itemID = hoverItemID { cell.isVisible = { [weak self] in self?.hoveredItemID == itemID } }
            attachment.attachmentCell = cell
        } else {
            attachment.image = image
            attachment.bounds = label == nil ? NSRect(x: 0, y: -3, width: 18, height: 18) : NSRect(x: 0, y: -2, width: 14, height: 14)
        }
        let result = NSMutableAttributedString(attachment: attachment)
        if let text = feedbackText ?? label {
            result.append(NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: label == nil ? .regular : .medium), .foregroundColor: color
            ]))
        }
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        result.addAttribute(.toolTip, value: description, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func applyMessageStyle(_ item: TranscriptItem, to text: NSMutableAttributedString, range: NSRange) {
        guard item.kind == "user" || item.kind == "assistant", range.length > 2 else { return }
        let width = max(1, transcript.textContainer?.containerSize.width ?? 600)
        let outgoing = item.kind == "user"
        let inset = outgoing ? Self.outgoingInset(item, width: width) : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = outgoing ? inset + 16 : 0
        paragraph.headIndent = paragraph.firstLineHeadIndent
        paragraph.tailIndent = outgoing ? -16 : -4
        paragraph.lineSpacing = 4
        // Markdown already carries blank lines; do not add spacing to every newline.
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        text.enumerateAttribute(.responseHeader, in: range) { value, headerRange, _ in
            guard value != nil else { return }
            let header = paragraph.mutableCopy() as! NSMutableParagraphStyle
            header.paragraphSpacingBefore = 8
            header.minimumLineHeight = 24
            header.paragraphSpacing = outgoing ? 6 : 16
            text.addAttribute(.paragraphStyle, value: header, range: headerRange)
        }
        text.enumerateAttribute(.messageCopy, in: range) { value, copyRange, _ in
            guard value != nil else { return }
            let footer = paragraph.mutableCopy() as! NSMutableParagraphStyle
            footer.lineSpacing = 0
            footer.paragraphSpacingBefore = outgoing ? 12 : 4
            // A user's copy control sits under the bubble's trailing edge.
            if outgoing { footer.alignment = .right; footer.tailIndent = -6 }
            text.addAttribute(.paragraphStyle, value: footer, range: copyRange)
        }
        // Blocks of an answer (headings, lists, cards) keep the styles they chose; header
        // controls get a right tab stop at the trailing edge of the current width.
        text.enumerateAttribute(.blockParagraphStyle, in: range) { value, blockRange, _ in
            guard let style = value as? NSParagraphStyle else { return }
            if let inset = text.attribute(.rightTabInset, at: blockRange.location, effectiveRange: nil) as? CGFloat,
               let tabbed = style.mutableCopy() as? NSMutableParagraphStyle {
                // Tab locations are measured inside the line fragment padding on both sides.
                let padding = transcript.textContainer?.lineFragmentPadding ?? 5
                tabbed.tabStops = [NSTextTab(textAlignment: .right, location: max(tabbed.headIndent + 40, width - 2 * padding - inset - 1))]
                text.addAttribute(.paragraphStyle, value: tabbed, range: blockRange)
            } else {
                text.addAttribute(.paragraphStyle, value: style, range: blockRange)
            }
        }
        TranscriptTables.restoreStyles(in: text, range: range)
        // Leave the final empty paragraph, and a user's copy control, outside the bubble.
        var bubble = NSRange(location: range.location, length: range.length - 1)
        if outgoing {
            text.enumerateAttribute(.messageCopy, in: range) { value, copyRange, stop in
                guard value != nil else { return }
                bubble.length = max(0, copyRange.location - 1 - range.location); stop.pointee = true
            }
        }
        text.addAttribute(.messageBubble, value: item.id, range: bubble)
        if outgoing { text.addAttribute(.outgoingBubble, value: inset, range: bubble) }
    }

    /// Left edge of a user bubble that hugs its text, up to 78% of the column.
    static func outgoingInset(_ item: TranscriptItem, width: CGFloat) -> CGFloat {
        let maxText = max(80, width * 0.78 - 32)
        let body = NSAttributedString(string: item.text.isEmpty ? " " : item.text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        var textWidth = body.boundingRect(with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        if let phase = item.phase {
            let header = NSAttributedString(string: phase, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            textWidth = max(textWidth, header.size().width)
        }
        // Line fragment padding and rounding must not wrap the last word of a hugging bubble.
        textWidth = min(maxText, max(40, textWidth.rounded(.up) + 12))
        return max(0, width - textWidth - 32)
    }

    private func rerenderItem(id: String) {
        guard let index = previous.firstIndex(where: { $0.id == id }), ranges.indices.contains(index),
              let storage = transcript.textStorage else { return }
        let origin = contentView.bounds.origin
        let rendered = render(previous[index], expanded: expandedActions.contains(id))
        let oldRange = ranges[index], delta = rendered.length - oldRange.length
        storage.replaceCharacters(in: oldRange, with: rendered)
        ranges[index].length = rendered.length
        for next in (index + 1)..<ranges.count { ranges[next].location += delta }
        editCount += 1
        needsLayout = true
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func showCopyFeedback(id: String, succeeded: Bool, block: Int?) {
        let previousID = copyFeedback?.id
        copyFeedbackTask?.cancel()
        copyFeedback = (id, succeeded, block)
        if let previousID, previousID != id { rerenderItem(id: previousID) }
        rerenderItem(id: id)
        copyFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            if self.deferWhileClicking("copy-feedback:\(id)", { [weak self] in self?.endCopyFeedback(id: id) }) { return }
            self.endCopyFeedback(id: id)
        }
    }

    private func endCopyFeedback(id: String) {
        copyFeedback = nil
        rerenderItem(id: id)
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let value = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if value == "contextdesk-block-copy" || value.hasPrefix("contextdesk-table:") {
            guard let storage = transcript.textStorage, charIndex >= 0, charIndex < storage.length,
                  let block = storage.attribute(.quoteIndex, at: charIndex, effectiveRange: nil) as? Int,
                  let index = ranges.firstIndex(where: { NSLocationInRange(charIndex, $0) }) else { return true }
            let body: String
            if value == "contextdesk-block-copy" {
                guard let text = storage.attribute(.blockCopy, at: charIndex, effectiveRange: nil) as? String else { return true }
                body = text
            } else {
                guard let table = (storage.attribute(.tableData, at: charIndex, effectiveRange: nil) as? TableBox)?.table else { return true }
                switch value {
                case "contextdesk-table:md": body = table.markdown
                case "contextdesk-table:tsv": body = table.tabSeparated
                default:
                    TranscriptTableWindow.show(table, relativeTo: window)
                    return true
                }
            }
            pasteboard.clearContents()
            showCopyFeedback(id: previous[index].id, succeeded: pasteboard.setString(body, forType: .string), block: block)
            return true
        }
        if value.hasPrefix("contextdesk-anchor:") {
            scroll(toAnchor: String(value.dropFirst("contextdesk-anchor:".count)))
            return true
        }
        if value.hasPrefix("contextdesk-toggle:") {
            let key = String(value.dropFirst("contextdesk-toggle:".count))
            guard let index = ranges.firstIndex(where: { NSLocationInRange(charIndex, $0) }) else { return true }
            if expandedBlocks.contains(key) { expandedBlocks.remove(key) } else { expandedBlocks.insert(key) }
            rerenderItem(id: previous[index].id)
            return true
        }
        if value == "contextdesk-quote-copy" {
            guard let storage = transcript.textStorage, charIndex >= 0, charIndex < storage.length,
                  let body = storage.attribute(.quoteCopy, at: charIndex, effectiveRange: nil) as? String,
                  let block = storage.attribute(.quoteIndex, at: charIndex, effectiveRange: nil) as? Int,
                  let index = ranges.firstIndex(where: { NSLocationInRange(charIndex, $0) }) else { return true }
            let id = previous[index].id
            pasteboard.clearContents()
            showCopyFeedback(id: id, succeeded: pasteboard.setString(body, forType: .string), block: block)
            return true
        }
        if value.hasPrefix("contextdesk-copy:") {
            let id = String(value.dropFirst("contextdesk-copy:".count))
            guard let item = previous.first(where: { $0.id == id && ($0.kind == "user" || $0.kind == "assistant") }),
                  item.showsCopyControl, !item.text.isEmpty else { return true }
            // Copy the source body only, never rendered headers, disclosures or adjacent messages.
            pasteboard.clearContents()
            let succeeded = pasteboard.setString(item.text, forType: .string)
            showCopyFeedback(id: id, succeeded: succeeded, block: nil)
            return true
        }
        if value.hasPrefix("contextdesk-metrics:") {
            let id = String(value.dropFirst("contextdesk-metrics:".count))
            guard let index = previous.firstIndex(where: { $0.id == id && $0.timing != nil }),
                  ranges.indices.contains(index), let storage = transcript.textStorage else { return true }
            if expandedMetrics.contains(id) { expandedMetrics.remove(id) } else { expandedMetrics.insert(id) }
            let rendered = render(previous[index], expanded: expandedActions.contains(id))
            let oldRange = ranges[index], delta = rendered.length - oldRange.length
            storage.replaceCharacters(in: oldRange, with: rendered)
            ranges[index].length = rendered.length
            for next in (index + 1)..<ranges.count { ranges[next].location += delta }
            editCount += 1
            needsLayout = true
            return true
        }
        if value.hasPrefix("contextdesk-action:") {
            let id = String(value.dropFirst("contextdesk-action:".count))
            guard let index = previous.firstIndex(where: { $0.id == id && $0.kind == "activity" }),
                  ranges.indices.contains(index), let storage = transcript.textStorage else { return true }
            if expandedActions.contains(id) { expandedActions.remove(id) } else { expandedActions.insert(id) }
            let rendered = render(previous[index], expanded: expandedActions.contains(id))
            let oldRange = ranges[index], delta = rendered.length - oldRange.length
            storage.replaceCharacters(in: oldRange, with: rendered)
            ranges[index].length = rendered.length
            for next in (index + 1)..<ranges.count { ranges[next].location += delta }
            editCount += 1
            needsLayout = true
            return true
        }
        if value.hasPrefix(TranscriptLinks.chatScheme + ":") {
            TranscriptLinks.openChat?(String(value.dropFirst(TranscriptLinks.chatScheme.count + 1)))
            return true
        }
        guard let url = TranscriptLinks.destination(value) else { return true }
        if url.isFileURL {
            let line = transcript.textStorage.flatMap { storage in
                charIndex >= 0 && charIndex < storage.length ? storage.attribute(.fileLine, at: charIndex, effectiveRange: nil) as? Int : nil
            }
            // Links to a heading of the document already shown just scroll.
            if isDocument, let fragment = url.fragment, url.path == documentURL?.path {
                scroll(toAnchor: TranscriptLinks.slug(fragment)); return true
            }
            switch Self.fileClickAction(NSApp.currentEvent?.modifierFlags ?? [], url: url, canPreview: onOpenFile != nil) {
            case .preview: onOpenFile?(url, line)
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: url.path)])
            case .open: NSWorkspace.shared.open(URL(fileURLWithPath: url.path))
            }
            return true
        }
        NSWorkspace.shared.open(url); return true
    }

    public enum FileClickAction: Equatable { case preview, reveal, open }

    /// Click previews a file in the app, Option-click reveals it in Finder, Command-click opens it externally.
    /// Folders and missing files are never previewed.
    public static func fileClickAction(_ flags: NSEvent.ModifierFlags, url: URL, canPreview: Bool) -> FileClickAction {
        if flags.contains(.option) { return .reveal }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        if flags.contains(.command) || !canPreview || !exists || directory.boolValue { return .open }
        return .preview
    }

    /// The path relative to the chat's project, or nil when the file lies outside it.
    public static func relativePath(_ path: String, project: String?) -> String? {
        guard let project else { return nil }
        let base = URL(fileURLWithPath: project).standardizedFileURL.pathComponents
        let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    /// Links get their own actions above the standard text menu.
    public func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: @escaping () -> Void) {
            items.append(LinkMenuItem(title: title, perform: action))
        }
        if let onQuoteSelection, let quote = selectedQuote(view) {
            add(L10n.text("Попросить агента изменить", "Ask Agent to Edit")) { onQuoteSelection(quote.text, quote.lines) }
        }
        guard let storage = transcript.textStorage, charIndex >= 0, charIndex < storage.length,
              let url = storage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL,
              TranscriptLinks.destination(url.absoluteString) != nil else {
            if !items.isEmpty {
                items.append(.separator())
                for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
            }
            return menu
        }
        let pasteboard = self.pasteboard
        if url.isFileURL {
            if let onOpenFile, Self.fileClickAction([], url: url, canPreview: true) == .preview {
                let line = storage.attribute(.fileLine, at: charIndex, effectiveRange: nil) as? Int
                add(L10n.text("Предпросмотр", "Preview")) { onOpenFile(url, line) }
            }
            let file = URL(fileURLWithPath: url.path)
            add(L10n.text("Открыть в программе по умолчанию", "Open in Default App")) { NSWorkspace.shared.open(file) }
            add(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            if let relative = Self.relativePath(url.path, project: projectPath) {
                add(L10n.text("Скопировать относительный путь", "Copy Relative Path")) {
                    pasteboard.clearContents(); pasteboard.setString(relative, forType: .string)
                }
            }
            add(L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")) {
                pasteboard.clearContents(); pasteboard.setString(url.path, forType: .string)
            }
        } else {
            add(L10n.text("Открыть ссылку", "Open Link")) { NSWorkspace.shared.open(url) }
            add(L10n.text("Скопировать ссылку", "Copy Link")) {
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString.hasPrefix("mailto:") ? String(url.absoluteString.dropFirst(7)) : url.absoluteString, forType: .string)
            }
        }
        // Replace AppKit's own link items; keep selection items such as Copy.
        let linkActions: Set<String> = ["openLink:", "copyLink:", "_openLinkFromMenu:", "_copyLinkFromMenu:"]
        for item in menu.items.reversed() where item.action.map({ linkActions.contains(NSStringFromSelector($0)) }) == true {
            menu.removeItem(item)
        }
        items.append(.separator())
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    /// The selected text and, in numbered code, its first and last line (the number sits on each line's first character).
    private func selectedQuote(_ view: NSTextView) -> (text: String, lines: ClosedRange<Int>?)? {
        let range = view.selectedRange()
        guard range.length > 0, let storage = view.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let text = storage.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        func line(at index: Int) -> Int? {
            var found: Int?
            storage.enumerateAttribute(.codeLineNumber, in: NSRange(location: 0, length: index + 1), options: .reverse) { value, _, stop in
                if let number = value as? Int { found = number; stop.pointee = true }
            }
            return found
        }
        guard let first = line(at: range.location), let last = line(at: NSMaxRange(range) - 1) else { return (text, nil) }
        return (text, min(first, last)...max(first, last))
    }
}

@MainActor private final class LinkMenuItem: NSMenuItem {
    private var perform: (() -> Void)?
    convenience init(title: String, perform: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.perform = perform
        target = self
    }
    @objc private func run() { perform?() }
}

private final class TranscriptTextView: NSTextView {
    var didDrawText: (() -> Void)?
    var hoverChanged: ((NSPoint?) -> Void)?
    var trackClick: ((() -> Void) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func mouseDown(with event: NSEvent) {
        guard let trackClick else { return super.mouseDown(with: event) }
        trackClick { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Bubbles go under the selection and the text; the view itself draws no background.
        (layoutManager as? BubbleLayoutManager)?.drawBubbles(in: dirtyRect, origin: textContainerOrigin)
        super.draw(dirtyRect)
        didDrawText?()
    }
    /// TextKit invalidates only the changed lines; a user bubble also covers its overhang beyond them.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.isEmpty ? rect : rect.insetBy(dx: 0, dy: -BubbleLayoutManager.bubbleOverhang), avoidAdditionalLayout: flag)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverChanged?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverChanged?(nil)
    }
}

/// Keeps its place in the layout and stays clickable, but draws only while `isVisible`.
private final class HoverAttachmentCell: NSTextAttachmentCell {
    var isVisible: () -> Bool = { true }
    override func cellSize() -> NSSize { NSSize(width: 18, height: 18) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard isVisible(), let image else { return }
        let size = image.size
        let rect = NSRect(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

extension NSAttributedString.Key {
    static let compactionBadge = NSAttributedString.Key("ContextDeskCompactionBadge")
    /// The colour of a badge's fill and outline; badges without it are neutral.
    static let badgeTint = NSAttributedString.Key("ContextDeskBadgeTint")
    static let quoteCard = NSAttributedString.Key("ContextDeskQuoteCard")
    static let quoteCopy = NSAttributedString.Key("ContextDeskQuoteCopy")
    static let quoteIndex = NSAttributedString.Key("ContextDeskQuoteIndex")
    static let messageCopy = NSAttributedString.Key("ContextDeskMessageCopy")
    static let responseHeader = NSAttributedString.Key("ContextDeskResponseHeader")
    static let responseSeparator = NSAttributedString.Key("ContextDeskResponseSeparator")
    static let messageBubble = NSAttributedString.Key("ContextDeskMessageBubble")
    static let outgoingBubble = NSAttributedString.Key("ContextDeskOutgoingBubble")
}

/// Paint only visible message fragments; keep native selection and TextKit's bounded layout.
private final class BubbleLayoutManager: NSLayoutManager {
    /// A user bubble reaches this far above and below its text, outside the text's line fragments.
    static let bubbleOverhang: CGFloat = 10
    /// Paints user bubbles that reach into `dirtyRect`. Each bubble is drawn whole, so a rect that holds only
    /// its overhang (above the first message) or a part of it still shows the right shape.
    func drawBubbles(in dirtyRect: NSRect, origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let local = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -Self.bubbleOverhang)
        let glyphs = glyphRange(forBoundingRect: local, in: container)
        guard glyphs.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.messageBubble, in: characters) { value, range, _ in
            guard value != nil,
                  let inset = storage.attribute(.outgoingBubble, at: range.location, effectiveRange: nil) as? CGFloat else { return }
            var full = NSRange()
            _ = storage.attribute(.messageBubble, at: range.location, longestEffectiveRange: &full, in: whole)
            let bounds = boundingRect(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil), in: container)
            let width = container.containerSize.width
            let top = bounds.minY - Self.bubbleOverhang
            let rect = NSRect(x: origin.x + inset + 2, y: origin.y + top,
                              width: max(1, width - inset - 4), height: bounds.maxY + Self.bubbleOverhang - top)
            guard rect.intersects(dirtyRect) else { return }
            DeskPalette.outgoingBubble.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        }
    }
    /// Selection follows the text line by line: it skips blank lines and the empty column, and stays inside user bubbles.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // Only the selection is reshaped; table cells and other fills keep their full rectangles.
        let selection = textContainers.first?.textView?.selectedTextAttributes[.backgroundColor] as? NSColor
        guard color == (selection ?? .selectedTextBackgroundColor) || color == .unemphasizedSelectedTextBackgroundColor,
              let storage = textStorage, storage.length > 0, let container = textContainers.first,
              let origin = container.textView?.textContainerOrigin else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // A multi-line selection arrives as one block; split it into lines so bubble lines can be narrowed.
        var rects: [NSRect] = []
        for index in 0..<rectCount {
            let rect = rectArray[index]
            let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = glyphRange(forBoundingRect: local, in: container)
            var pieces: [NSRect] = []
            if glyphs.length > 0 {
                enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, lineGlyphs, _ in
                    // Highlight the line's text, not the empty column beside it; blank lines stay unmarked.
                    guard used.width > 1 else { return }
                    // Lines holding only hidden controls (copy icons) or spacing have nothing to highlight.
                    let characters = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                    let visible = (storage.string as NSString).substring(with: characters)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}")))
                    guard !visible.isEmpty else { return }
                    // Paragraph spacing stays out of the highlight; only the text's own line box is filled.
                    let textLine = NSRect(x: used.minX - 2, y: used.minY, width: used.width + 4, height: used.height)
                    var piece = textLine.offsetBy(dx: origin.x, dy: origin.y).intersection(rect)
                    guard !piece.isEmpty else { return }
                    let character = self.characterIndexForGlyph(at: lineGlyphs.location)
                    if character < storage.length,
                       let inset = storage.attribute(.outgoingBubble, at: character, effectiveRange: nil) as? CGFloat {
                        let left = origin.x + inset + 14, right = origin.x + container.containerSize.width - 14
                        piece = NSRect(x: max(piece.minX, left), y: piece.minY, width: min(piece.maxX, right) - max(piece.minX, left), height: piece.height)
                    }
                    if piece.width > 0 { pieces.append(piece) }
                }
            }
            rects += glyphs.length > 0 ? pieces : [rect]
        }
        guard !rects.isEmpty else { return }
        rects.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: buffer.count, forCharacterRange: charRange, color: color)
        }
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphsToShow.length > 0,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.compactionBadge, in: characters) { value, range, _ in
            guard value != nil else { return }
            var fullRange = NSRange()
            _ = storage.attribute(.compactionBadge, at: range.location, longestEffectiveRange: &fullRange,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -10, dy: -6)
            let tint = storage.attribute(.badgeTint, at: range.location, effectiveRange: nil) as? NSColor
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            (tint?.withAlphaComponent(0.08) ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.07)).setFill()
            path.fill()
            (tint?.withAlphaComponent(0.18) ?? NSColor.separatorColor.withAlphaComponent(0.35)).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        storage.enumerateAttribute(.responseSeparator, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + bounds.maxY + 6,
                   width: max(1, container.containerSize.width - 2 * container.lineFragmentPadding), height: 1).fill()
        }
        let whole = NSRange(location: 0, length: storage.length)
        let padding = container.lineFragmentPadding
        /// A card spans its whole attribute run; its sides follow the first paragraph's indents.
        func card(_ key: NSAttributedString.Key, at location: Int, inset: CGFloat) -> (NSRect, NSRange) {
            var full = NSRange()
            _ = storage.attribute(key, at: location, longestEffectiveRange: &full, in: whole)
            let bounds = boundingRect(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil), in: container)
            let style = storage.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle
            let left = padding + (style?.firstLineHeadIndent ?? inset) - inset
            let right = container.containerSize.width - padding + (style?.tailIndent ?? 0) + inset + 4
            // The last paragraph's spacing is not part of its line fragment; pad the card below.
            return (NSRect(x: origin.x + left, y: origin.y + bounds.minY - 2, width: max(1, right - left), height: bounds.height + 12), full)
        }
        var drawn = Set<String>()
        storage.enumerateAttribute(.quoteCard, in: characters) { value, range, _ in
            guard let index = value as? Int, drawn.insert("q\(index)@\(range.location)").inserted else { return }
            let (rect, _) = card(.quoteCard, at: range.location, inset: 16)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor.controlBackgroundColor.setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        storage.enumerateAttribute(.calloutCard, in: characters) { value, range, _ in
            guard let value = value as? String else { return }
            let (rect, _) = card(.calloutCard, at: range.location, inset: 16)
            let color: NSColor = switch value.split(separator: "|").first.map(String.init) ?? "" {
            case "tip": .systemGreen
            case "important": .systemPurple
            case "warning": .systemOrange
            case "caution": .systemRed
            default: .systemBlue
            }
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            color.withAlphaComponent(0.07).setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.withAlphaComponent(0.85).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        storage.enumerateAttribute(.codeCard, in: characters) { value, range, _ in
            guard value != nil else { return }
            let (rect, full) = card(.codeCard, at: range.location, inset: 14)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor.textColor.withAlphaComponent(0.035).setFill(); path.fill()
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke(); path.lineWidth = 1; path.stroke()
            // Hairline under the header row.
            var header = NSRange()
            if storage.attribute(.rightTabInset, at: full.location, longestEffectiveRange: &header, in: full) != nil {
                let headerRect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: header, actualCharacterRange: nil), in: container)
                NSColor.separatorColor.withAlphaComponent(0.5).setFill()
                NSRect(x: rect.minX + 1, y: origin.y + headerRect.maxY + 3, width: rect.width - 2, height: 0.5).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            storage.enumerateAttribute(.diffLine, in: NSIntersectionRange(full, characters)) { value, lineRange, _ in
                guard let sign = value as? String else { return }
                (sign == "+" ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.11).setFill()
                let glyphs = glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                    NSRect(x: rect.minX, y: origin.y + lineRect.minY, width: rect.width, height: lineRect.height).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        storage.enumerateAttribute(.codeLineNumber, in: characters) { value, range, _ in
            guard let number = value as? Int else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph).y
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let label = NSAttributedString(string: "\(number)", attributes: [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor])
            let right = origin.x + padding + (style?.headIndent ?? 0) - 10
            label.draw(at: NSPoint(x: right - label.size().width, y: origin.y + line.minY + baseline - numberFont.ascender))
        }
        storage.enumerateAttribute(.horizontalRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let left = padding + (style?.headIndent ?? 0)
            NSColor.separatorColor.setFill()
            NSRect(x: origin.x + left, y: origin.y + bounds.midY.rounded() - 0.5,
                   width: max(1, container.containerSize.width - padding - left), height: 1).fill()
        }
        storage.enumerateAttribute(.inlineChip, in: characters) { value, range, _ in
            guard let raw = value as? Int, let chip = TranscriptLinks.Chip(rawValue: raw), chip != .web else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
            (chip == .code ? NSColor.textColor.withAlphaComponent(0.06) : NSColor.controlAccentColor.withAlphaComponent(0.08)).setFill()
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let rect = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = self.location(forGlyphAt: part.location).y
                let line = self.lineFragmentRect(forGlyphAt: part.location, effectiveRange: nil)
                let top = line.minY + baseline - font.ascender - 1.5
                let height = font.ascender - font.descender + 3
                NSBezierPath(roundedRect: NSRect(x: origin.x + rect.minX - 3, y: origin.y + top, width: rect.width + 6, height: height),
                             xRadius: 4, yRadius: 4).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
