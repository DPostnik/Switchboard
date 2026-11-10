import AppKit
import os
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
    /// The next chat is loading: the view keeps what it shows (covered by the loading state) and its kept chats, and
    /// takes the chat once its items arrive, so a recent chat comes back without rendering. Empty items are covered too.
    let isLoading: Bool
    /// Read while the parent renders, so a zoom change updates the view.
    let zoom = InterfaceZoom.shared.scale
    public init(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, projectPath: String? = nil,
                isLoading: Bool = false, onOpenFile: ((URL, Int?) -> Void)? = nil, onReadToEnd: ((String, String) -> Void)? = nil) {
        self.isLoading = isLoading
        self.unreadCompletionID = unreadCompletionID; self.onReadToEnd = onReadToEnd; self.projectPath = projectPath
        self.onOpenFile = onOpenFile
        self.unreadResponseItemID = unreadResponseItemID
        self.isWorking = isWorking; self.workingStatus = workingStatus; self.workingSince = workingSince
        self.items = items; self.conversationID = conversationID; self.followOutput = followOutput
    }
    public func makeNSView(context: Context) -> TranscriptScrollView {
        let view = TranscriptScrollView(positions: .session)
        // Cmd+F opens the native find bar above the conversation (`showFind`).
        view.transcript.usesFindBar = true
        view.transcript.isIncrementalSearchingEnabled = true
        TranscriptScrollView.chatTranscript = view
        return view
    }
    public static func dismantleNSView(_ view: TranscriptScrollView, coordinator: ()) {
        view.tearDown()
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    public func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.onReadToEnd = onReadToEnd
        view.onOpenFile = onOpenFile
        view.zoom = zoom
        // Covered (loading, or an empty chat): the view keeps what it shows. Taking the empty items would make the chat's
        // first items an ordinary update, rendered all at once instead of from the end.
        view.isCovered = isLoading || items.isEmpty
        guard !view.isCovered else { return }
        view.update(items: items, conversationID: conversationID, followOutput: followOutput,
                    isWorking: isWorking, workingStatus: workingStatus, workingSince: workingSince, unreadCompletionID: unreadCompletionID,
                    unreadResponseItemID: unreadResponseItemID, projectPath: projectPath)
    }
}

@MainActor public final class TranscriptScrollView: WidthBoundTextScrollView, NSTextViewDelegate {
    public let transcript: NSTextView
    let pasteboard: NSPasteboard
    private(set) var previous: [TranscriptItem] = []
    private var ranges: [NSRange] = []
    private(set) var conversationID: String?
    private var followed = false
    private var wasWorking = false
    private var expandedActions: Set<String> = []
    private var expandedMetrics: Set<String> = []
    /// The tool calls behind each activity summary row and the thinking items behind each thinking row, keyed by the
    /// row's id; their bodies are rendered only when the row is open.
    var actionGroups: [String: [TranscriptItem]] = [:]
    /// Open thinking rows and command outputs (`TranscriptActivityDetail`).
    var expandedDetails: Set<String> = []
    /// The last grouping; a streaming update changes only the last request, so the rows before it are kept.
    private var groupingMemo: GroupingMemo?
    /// The headline of the running tool call, keyed by item id and text length; parsing its JSON input is not free.
    private var headlineMemo: (id: String, length: Int, headline: String)?
    /// Number of `render` calls so far; tests check that unchanged messages are not rendered again.
    public private(set) var renderCount = 0
    /// `renderCount` and the time at the last chat switch, and whether its text was kept: the `chat.open` signpost
    /// reports how many rows an open rendered.
    private var openRenders = 0
    private var openedAt: TimeInterval = 0
    private var openReused = false
    /// Rendered answer blocks reused across the re-renders of a streamed message.
    let renderCache = TranscriptRenderCache()
    fileprivate struct GroupingMemo {
        var conversationID: String?
        var isWorking: Bool
        /// The items grouped, and the index of their last user message, where the last request starts.
        var raw: [TranscriptItem]
        var split: Int
        /// Rows and groups of the requests before `split`; they do not depend on anything after it.
        var head: [TranscriptItem]
        var headGroups: [String: [TranscriptItem]]
        var items: [TranscriptItem]
        var groups: [String: [TranscriptItem]]
    }
    private(set) var copyFeedback: (id: String, succeeded: Bool, block: Int?)?
    /// Collapsible code, `<details>` and source lists the user opened, keyed by item and block.
    private(set) var expandedBlocks: Set<String> = []
    /// Answer section under the pointer; its heading shows a copy control.
    private(set) var hoveredSection: String?
    private(set) var projectPath: String?
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
    /// Message styles depend on the column width; during a live window resize they are applied once, at its end.
    private var restyleAfterLiveResize = false
    /// Shown while newer text lies below the viewport; one click returns to the end.
    private let jumpToLatest = JumpToLatestButton()
    private var jumpToLatestShown = false
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
            renderCache.invalidateStyles()
            releaseRenderedChats()
            needsLayout = true
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Diff line colors are blended at render time, so cached blocks and kept chats belong to the old appearance.
        renderCache.invalidateStyles()
        releaseRenderedChats()
    }

    public init(pasteboard: NSPasteboard = .general, positions: TranscriptReadingPositions = TranscriptReadingPositions()) {
        self.positions = positions
        self.pasteboard = pasteboard
        // TextKit 1's non-contiguous layout avoids laying out an entire long
        // transcript to display a small viewport.
        let storage = NSTextStorage(), manager = BubbleLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        manager.allowsNonContiguousLayout = true
        // AppKit's shared typesetter keeps the last text it laid out; a closed chat's whole text stack stayed alive
        // through it until some other text was laid out. An own typesetter goes away with the view.
        manager.typesetter = NSATSTypesetter()
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        transcript = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), textContainer: container)
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isRichText = true; transcript.importsGraphics = false
        transcript.isAutomaticLinkDetectionEnabled = false
        Self.disableTextChecking(transcript)
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
        jumpToLatest.target = self; jumpToLatest.action = #selector(jumpToEnd)
        jumpToLatest.alphaValue = 0
        addSubview(jumpToLatest, positioned: .above, relativeTo: nil)
        (transcript as? TranscriptTextView)?.didDrawText = { [weak self] in self?.positionWorkingIndicator() }
        (transcript as? TranscriptTextView)?.hoverChanged = { [weak self] point in self?.updateHover(at: point) }
        (transcript as? TranscriptTextView)?.beforeSelectAll = { [weak self] in self?.renderHistory() }
        (transcript as? TranscriptTextView)?.trackClick = { [weak self] click in
            if let self { self.holdingEdits(during: click) } else { click() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text is read-only, but NSTextView inherits the global spelling, grammar and substitution defaults and
    /// checks every paragraph scrolled into view on a background queue: one pass through a long chat kept a core
    /// busy for minutes. The composer keeps its own settings.
    static func disableTextChecking(_ view: NSTextView) {
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.enabledTextCheckingTypes = 0
    }

    /// Called when SwiftUI removes the view (the chat area closes). Its text stack can outlive it, for a while in an
    /// autorelease pool or the shared typesetter, so the text is emptied, also that of the chats kept for switching back:
    /// whatever still holds a storage holds no chat. Reading positions were saved while scrolling and are not touched.
    public func tearDown() {
        changingLayout = true
        copyFeedbackTask?.cancel(); copyFeedbackTask = nil
        workingTimer?.invalidate(); workingTimer = nil
        afterClick.removeAll()
        clearHistoryBacklog(); previous = []; ranges = []
        groupingMemo = nil; actionGroups = [:]; renderCache.removeAll()
        releaseRenderedChats()
        transcript.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: Recent chats

    /// A chat switched away from, with its rendered text and the state that describes it, for switching back without
    /// rendering again. Its storage is detached from the layout manager; it gets layout again when it is shown.
    struct RenderedChat {
        let storage: NSTextStorage
        var previous: [TranscriptItem]
        var ranges: [NSRange]
        var historyBacklog: [TranscriptItem]
        var historyPending: [NSAttributedString]
        var historyPendingLength: Int
        fileprivate var groupingMemo: GroupingMemo?
        var actionGroups: [String: [TranscriptItem]]
        var expandedActions: Set<String>
        var expandedMetrics: Set<String>
        var expandedBlocks: Set<String>
        var expandedDetails: Set<String>
        var sourcesDeferred: Set<String>
        var styledWidth: CGFloat
        var projectPath: String?
        var wasWorking: Bool
        var characters: Int { storage.length + historyPendingLength }
        /// Emptied, not only dropped: an autorelease pool or the typesetter may still hold the storage for a while.
        func release() {
            storage.setAttributedString(NSAttributedString())
            for part in historyPending { (part as? NSMutableAttributedString)?.setAttributedString(NSAttributedString()) }
        }
    }

    /// Recently shown chats, least recent first. Their characters and the shown chat's together stay within
    /// `renderedCharacterLimit`; a chat longer than that alone is not kept. Document previews keep none.
    private(set) var renderedChats: [(id: String, chat: RenderedChat)] = []
    /// About 2 M characters: a 1000-message chat renders to 1.6 M, about 55-110 bytes in memory per character.
    static let renderedCharactersDefault = 2_000_000
    var renderedCharacterLimit = TranscriptScrollView.renderedCharactersDefault

    private func releaseRenderedChats() {
        for entry in renderedChats { entry.chat.release() }
        renderedChats.removeAll()
    }

    /// Evicts the least recently shown chats until the kept and the shown text fit the limit.
    private func trimRenderedChats() {
        var total = (transcript.textStorage?.length ?? 0) + historyPendingLength + renderedChats.reduce(0) { $0 + $1.chat.characters }
        while total > renderedCharacterLimit, !renderedChats.isEmpty {
            let evicted = renderedChats.removeFirst()
            total -= evicted.chat.characters
            evicted.chat.release()
        }
    }

    /// On a chat switch: saves the reading place, keeps the shown chat's rendered text and state, and puts the next
    /// chat's kept text in place. True when the next chat's text was kept and can be reused (it is compared with the
    /// items as usual, so only rows that changed meanwhile are rendered); a chat whose turn finished meanwhile renders
    /// again, as a finished turn does (file chips and images may exist by now).
    private func switchRenderedChat(to next: String?, isWorking: Bool) -> Bool {
        if let id = conversationID, let position = pendingPosition ?? capturePosition() { positions.values[id] = position }
        pendingPosition = nil; needsEndScroll = false; deferredEndScroll = nil
        hoveredItemID = nil; hoveredSection = nil
        // Swapping the text resizes the text view and moves the viewport while `previous` and `ranges` still describe the
        // chat being left: saved as its reading place, that move reopened it near the top.
        let wasChanging = changingLayout
        changingLayout = true
        defer { changingLayout = wasChanging }
        guard !isDocument, let manager = transcript.layoutManager, let storage = transcript.textStorage else { return false }
        // A search belongs to the chat it ran in (the view used to be rebuilt on every switch).
        if isFindBarVisible { isFindBarVisible = false }
        if let feedback = copyFeedback {
            // The kept text shows no "Copied" mark that nothing would clear.
            copyFeedbackTask?.cancel(); copyFeedback = nil
            rerenderItem(id: feedback.id)
        }
        var kept: RenderedChat?
        if let index = renderedChats.firstIndex(where: { $0.id == next }) { kept = renderedChats.remove(at: index).chat }
        if let chat = kept, chat.wasWorking && !isWorking { chat.release(); kept = nil }
        let shown = storage.length + historyPendingLength
        if let id = conversationID, !previous.isEmpty, shown > 0, shown <= renderedCharacterLimit {
            renderedChats.append((id, RenderedChat(
                storage: storage, previous: previous, ranges: ranges, historyBacklog: historyBacklog, historyPending: historyPending,
                historyPendingLength: historyPendingLength, groupingMemo: groupingMemo, actionGroups: actionGroups,
                expandedActions: expandedActions, expandedMetrics: expandedMetrics, expandedBlocks: expandedBlocks,
                expandedDetails: expandedDetails, sourcesDeferred: sourcesDeferred, styledWidth: styledWidth,
                projectPath: projectPath, wasWorking: wasWorking)))
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
            manager.replaceTextStorage(kept?.storage ?? NSTextStorage())
        } else if let chat = kept {
            storage.setAttributedString(NSAttributedString())
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
            manager.replaceTextStorage(chat.storage)
        }
        guard let chat = kept else {
            // Rendered anew: `update` starts from an empty text.
            if let current = transcript.textStorage, current.length > 0 { current.deleteCharacters(in: NSRange(location: 0, length: current.length)) }
            previous = []; ranges = []; clearHistoryBacklog(); groupingMemo = nil; actionGroups = [:]
            return false
        }
        previous = chat.previous; ranges = chat.ranges
        historyBacklog = chat.historyBacklog; historyPending = chat.historyPending; historyPendingLength = chat.historyPendingLength
        groupingMemo = chat.groupingMemo; actionGroups = chat.actionGroups
        expandedActions = chat.expandedActions; expandedMetrics = chat.expandedMetrics
        expandedBlocks = chat.expandedBlocks; expandedDetails = chat.expandedDetails; sourcesDeferred = chat.sourcesDeferred
        styledWidth = chat.styledWidth; projectPath = chat.projectPath; wasWorking = chat.wasWorking
        return true
    }

    /// The open chat's conversation; one main window shows at most one. Document previews are not registered.
    public fileprivate(set) static weak var chatTranscript: TranscriptScrollView?

    /// The chat area shows a loading or empty state over the view (which stays to keep recent chats): it takes no
    /// keyboard focus, find or read acknowledgement meanwhile.
    public var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            if isCovered, let window, window.firstResponder === transcript { window.makeFirstResponder(nil) }
            if !isCovered { scheduleReadCheck() }
        }
    }

    /// Shows the native find bar above the text and moves focus into it; matches are highlighted as you type.
    public func showFind() {
        guard transcript.usesFindBar else { return }
        // Find searches the whole chat, also the older part still waiting to be rendered.
        renderHistory()
        window?.makeFirstResponder(transcript)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        transcript.performTextFinderAction(item)
    }

    /// The transcript that should answer Cmd+F: the document or chat holding keyboard focus (its text or its find bar),
    /// otherwise the open chat's conversation.
    public static func findTarget(in window: NSWindow?) -> TranscriptScrollView? {
        var view = window?.firstResponder as? NSView
        // A focused text field edits through the window's field editor, which is not inside the field.
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { view = field }
        while let current = view {
            if let scroll = current as? TranscriptScrollView, scroll.transcript.usesFindBar { return scroll }
            view = current.superview
        }
        guard let chat = chatTranscript, chat.window != nil, !chat.isCovered else { return nil }
        return chat
    }

    public func update(items: [TranscriptItem], conversationID: String?, followOutput: Bool, isWorking: Bool = false, workingStatus: String? = nil,
                       workingSince: Date? = nil, unreadCompletionID: String? = nil, unreadResponseItemID: String? = nil, projectPath: String? = nil) {
        if deferWhileClicking("update", { [weak self] in
            self?.update(items: items, conversationID: conversationID, followOutput: followOutput, isWorking: isWorking, workingStatus: workingStatus,
                         workingSince: workingSince, unreadCompletionID: unreadCompletionID, unreadResponseItemID: unreadResponseItemID,
                         projectPath: projectPath)
        }) { return }
        let perfSpan = Perf.span("transcript.update", id: "\(items.count) items"); defer { perfSpan.end() }
        let switched = self.conversationID != conversationID
        // A chat shown recently comes back with its rendered text and state.
        let reused = switched && switchRenderedChat(to: conversationID, isWorking: isWorking)
        let rendersBefore = renderCount
        if switched { openRenders = renderCount; openedAt = ProcessInfo.processInfo.systemUptime; openReused = reused }
        // Relative file links resolve against the project; a different project re-renders everything.
        let projectChanged = self.projectPath != projectPath
        self.projectPath = projectPath
        self.unreadResponseItemID = unreadResponseItemID
        self.unreadCompletionID = unreadCompletionID
        let workingStatus = isWorking ? Self.currentActivity(items).map { headline(of: $0) } ?? workingStatus : workingStatus
        var items = isDocument ? items : groupedItems(items, conversationID: conversationID, isWorking: isWorking)
        streamingItemID = isWorking && !isDocument ? items.last?.id : nil
        if isWorking {
            items.append(Self.workingRow(status: workingStatus, since: workingSince))
        }
        self.workingStatus = workingStatus; self.workingSince = isWorking ? workingSince : nil
        updateWorkingTimer()
        if workingIndicator.isHidden == isWorking { workingIndicator.isHidden = !isWorking }
        workingIndicator.isWorking = isWorking
        let finished = wasWorking && !isWorking
        wasWorking = isWorking
        // Rows opened during the turn close when it finishes; they are re-rendered in place below.
        let closing = finished && !switched ? expandedActions : []
        if (switched && !reused) || finished { expandedActions.removeAll() }
        if switched && !reused { expandedMetrics.removeAll(); expandedBlocks.removeAll(); expandedDetails.removeAll(); sourcesDeferred.removeAll() }
        // A finished answer is rendered once more from scratch: file chips and images it mentioned may exist by now.
        if switched || finished || projectChanged { renderCache.removeAll() }
        if let feedback = copyFeedback,
           switched || previous.first(where: { $0.id == feedback.id })?.text != items.first(where: { $0.id == feedback.id })?.text {
            copyFeedbackTask?.cancel()
            copyFeedback = nil
        }
        let resumeFollowing = followOutput && !followed
        followed = followOutput
        // Older rows of a chat opened in parts wait in `historyBacklog`: they are compared, not rendered, and any change
        // among them renders the chat again.
        var restart = (switched && !reused) || projectChanged
        if !historyBacklog.isEmpty, !restart {
            if items.count >= historyBacklog.count, items.prefix(historyBacklog.count).elementsEqual(historyBacklog) {
                items = Array(items[historyBacklog.count...])
            } else { restart = true }
        }
        if restart { clearHistoryBacklog() }
        // From the end first: a streaming delta changes the last rows.
        let changed = restart || items.count != previous.count || items.last != previous.last || items != previous
        guard switched || finished || projectChanged || changed else {
            if resumeFollowing { scrollToEnd() }
            scheduleReadCheck()
            return
        }
        // A switch saved the previous chat's place before its text went away (`switchRenderedChat`).
        let savedPosition = switched ? nil : pendingPosition ?? capturePosition()
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
        if !restart {
            while common < min(previous.count, items.count), previous[common] == items[common] { common += 1 }
        }
        let closingRows = closing.isEmpty ? [] : (0..<common).filter { closing.contains(previous[$0].id) }
        // Rows equal at the end keep their rendering too: the engine's history that replaces the stored transcript
        // after an open usually differs in a few rows (a decoration, a late changes card), not in everything after them.
        // Not while an answer streams or a turn ends, when the last rows change or render once more anyway.
        var suffix = 0
        if !restart, !isWorking, !finished {
            let limit = min(previous.count, items.count) - common
            while suffix < limit, previous[previous.count - 1 - suffix] == items[items.count - 1 - suffix] { suffix += 1 }
        }
        // A message the user just sent is brought into view even if they had scrolled up to re-read.
        // Only items after the last known one count: prepended older history also contains user messages.
        // While an answer streams the last row stays the same one: no set of every row's id per tick.
        let lastKnown: Int?
        if let last = items.last?.id, last == previous.last?.id { lastKnown = items.count - 1 } else {
            let knownIDs = Set(previous.map(\.id))
            lastKnown = items.lastIndex { knownIDs.contains($0.id) }
        }
        let sentMessage = followOutput && !switched && lastKnown != nil
            && items[(lastKnown! + 1)...].contains { $0.kind == "user" }
        // Streaming rewrites only the last message or appends; text above the viewport keeps its place.
        let tailOnly = !restart && closingRows.isEmpty && common + 1 >= previous.count
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
        let keptStart = suffix > 0 ? ranges[ranges.count - suffix].location : storage.length
        let keptRanges = ranges.suffix(suffix)
        storage.deleteCharacters(in: NSRange(location: start, length: keptStart - start))
        ranges = Array(ranges.prefix(common))
        // A chat rendered anew shows its end first; the rows above it follow in parts (`renderHistoryChunk`).
        var first = common
        if restart, !isDocument {
            // The source length stands in for the rendered one; rows render oldest first, as the block cache expects.
            first = items.count
            var length = 0
            while first > 0, length < Self.firstScreenCharacters { first -= 1; length += items[first].text.utf16.count }
        }
        if suffix == 0 {
            for item in items.dropFirst(first) {
                let rendered = render(item, expanded: expandedActions.contains(item.id))
                ranges.append(NSRange(location: storage.length, length: rendered.length))
                storage.append(rendered)
            }
        } else {
            let middle = NSMutableAttributedString()
            for item in items[first..<(items.count - suffix)] {
                let rendered = render(item, expanded: expandedActions.contains(item.id))
                ranges.append(NSRange(location: start + middle.length, length: rendered.length))
                middle.append(rendered)
            }
            storage.insert(middle, at: start)
            let delta = start + middle.length - keptStart
            ranges += keptRanges.map { NSRange(location: $0.location + delta, length: $0.length) }
        }
        storage.endEditing()
        if Perf.enabled, !switched, renderCount > rendersBefore, ProcessInfo.processInfo.systemUptime - openedAt < 30, !isWorking {
            // Rows rendered again soon after an open: the engine's history replacing the stored transcript (fix I).
            Perf.event("chat.rerender", "\(conversationID ?? "") \(renderCount - rendersBefore) of \(items.count) rows, from row \(common), kept \(suffix) at the end")
        }
        if restart, !isDocument {
            historyBacklog = Array(items[..<first])
            previous = Array(items[first...])
        } else { previous = items }
        self.conversationID = conversationID; editCount += 1
        needsLayout = true
        if switched {
            needsEndScroll = false
            pendingPosition = conversationID.flatMap { positions.values[$0] }
            openRestorePending = pendingPosition != nil
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
        // An answer that stopped streaming before the turn finished (more tool calls followed) gets its sources now.
        for id in sourcesDeferred where id != streamingItemID { sourcesDeferred.remove(id); rerenderItem(id: id) }
        // A reading position inside the older history needs its row now.
        if case let .anchor(itemID, _, _, _)? = pendingPosition, let index = historyBacklog.firstIndex(where: { $0.id == itemID }) {
            renderHistory(from: index)
        }
        if !renderedChats.isEmpty { trimRenderedChats() }
        scheduleHistoryChunk()
    }

    /// The row being written while the agent works; its web sources wait until it stops growing.
    private(set) var streamingItemID: String?
    /// Answers rendered while streaming whose text may hold a sources list.
    var sourcesDeferred: Set<String> = []

    /// Older rows of the open chat not in the text yet, oldest first; `previous` holds the rows after them.
    private(set) var historyBacklog: [TranscriptItem] = []
    /// The newest rows of the backlog, already rendered but not inserted (`historyBacklog[historyPendingStart...]`).
    /// TextKit 1 keeps absolute line positions, so text inserted above the reader makes it lay out everything from the
    /// top to the reading place again: inserting every part at once cost 100-660 ms per part in a 1000-message chat.
    /// Parts therefore wait here until the reader nears the top of the text (then a small slice goes in), or until
    /// inserting them is cheap (the reader is at the end, or little text lies above the reading place).
    private var historyPending: [NSAttributedString] = []
    private var historyPendingLength = 0
    var historyPendingStart: Int { historyBacklog.count - historyPending.count }
    private var historyChunkScheduled = false
    /// Rendered synchronously when a chat opens: about two tall viewports from its end.
    static let firstScreenCharacters = 12_000
    /// Main-thread time rendering one part of the older history may take; the run loop handles input between parts.
    static let historyChunkSeconds = 0.02
    /// The same while the reader scrolls near the top, where a turn renders or inserts, not both: each fits in a frame or two.
    static let scrollingChunkSeconds = 0.006
    /// Most text one insertion puts above a reader near the top (it is laid out at once): idle, and while scrolling.
    static let historySliceCharacters = 24_000
    static let scrollingSliceCharacters = 6_000
    /// A reader at the end gets the rest in one insertion once it is all rendered (each insertion copies the text);
    /// a reader further up too, if laying out the text above their place stays this short.
    static let historyRelayoutCharacters = 120_000
    /// Up to this size an insertion at the start costs less than copying the text (`prepend`).
    static let directInsertCharacters = 4_000
    /// When the viewport last moved other than by the transcript itself: parts wait while the reader scrolls.
    private var lastScrolled: TimeInterval = 0

    private func scheduleHistoryChunk(after delay: Double = 0.005) {
        guard !historyBacklog.isEmpty, !historyChunkScheduled else { return }
        historyChunkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.historyChunkScheduled = false
            self.renderHistoryChunk()
        }
    }

    private func clearHistoryBacklog() {
        historyBacklog.removeAll(); historyPending.removeAll(); historyPendingLength = 0
    }

    /// Renders the next part of the older history and puts rendered parts above the text when that is needed or cheap,
    /// keeping the reader's place (or the end).
    func renderHistoryChunk() {
        guard !historyBacklog.isEmpty else { return }
        // A click, or scrolling anywhere but near the top of what is rendered, owns the main thread; the history waits.
        let scrolling = liveScrolling || ProcessInfo.processInfo.systemUptime - lastScrolled < 0.3
        let nearTop = contentView.bounds.minY < 2 * max(contentView.bounds.height, 1)
        if isTrackingClick || (scrolling && !nearTop) { scheduleHistoryChunk(after: 0.1); return }
        let started = ProcessInfo.processInfo.systemUptime
        // While the reader scrolls near the top, a turn either renders or inserts, so neither adds to the other's frame;
        // rows already rendered go in first.
        let insertOnly = scrolling && nearTop && !historyPending.isEmpty
        var didRender = false
        if historyPendingStart > 0, !insertOnly {
            didRender = true
            let budget = scrolling ? Self.scrollingChunkSeconds : Self.historyChunkSeconds
            var index = historyPendingStart
            var parts: [NSAttributedString] = []
            renderingHistory {
                repeat {
                    index -= 1
                    parts.append(render(historyBacklog[index], expanded: expandedActions.contains(historyBacklog[index].id)))
                } while index > 0 && ProcessInfo.processInfo.systemUptime - started < budget
            }
            historyPending.insert(contentsOf: parts.reversed(), at: 0)
            historyPendingLength += parts.reduce(0) { $0 + $1.length }
        }
        if nearTop, !(scrolling && didRender) {
            // Only the rows just above the text: the reader scrolls into them, and less text means less layout.
            let limit = scrolling ? Self.scrollingSliceCharacters : Self.historySliceCharacters
            var count = 0, length = 0
            for part in historyPending.reversed() {
                if count > 0, length + part.length > limit { break }
                count += 1; length += part.length
            }
            insertPending(count)
        } else if historyPendingStart == 0 {
            var cheap = true
            if case let .anchor(itemID, character, _, _)? = pendingPosition ?? capturePosition() {
                let above = previous.firstIndex { $0.id == itemID }.map { ranges[$0].location + character } ?? Int.max
                cheap = above <= Self.historyRelayoutCharacters - historyPendingLength
            }
            if cheap { insertPending(historyPending.count) }
        }
        // All rendered, waiting for the reader to come near the top: only the viewport needs checking now and then.
        scheduleHistoryChunk(after: historyPendingStart == 0 && !historyPending.isEmpty ? 0.25 : 0.005)
    }

    /// Moves the newest `count` rendered parts into the text.
    private func insertPending(_ count: Int) {
        guard count > 0 else { return }
        let parts = Array(historyPending.suffix(count))
        historyPending.removeLast(count)
        historyPendingLength -= parts.reduce(0) { $0 + $1.length }
        prepend(parts, from: historyBacklog.count - count)
    }

    /// Puts the older history from row `index` on into the text at once (find, select all, a reveal or a reading
    /// position needs it); rows rendered earlier are reused.
    func renderHistory(from index: Int = 0) {
        guard index < historyBacklog.count else { return }
        let start = historyPendingStart
        var parts: [NSAttributedString] = []
        if index < start {
            renderingHistory { parts = historyBacklog[index..<start].map { render($0, expanded: expandedActions.contains($0.id)) } }
        }
        let reused = max(0, index - start)
        let kept = historyPending[reused...]
        historyPendingLength -= kept.reduce(0) { $0 + $1.length }
        parts += kept
        historyPending.removeSubrange(reused...)
        prepend(parts, from: index)
    }

    /// Older rows rarely render again; caching them would evict the blocks of the newest messages.
    private func renderingHistory(_ work: () -> Void) {
        let enabled = renderCache.isEnabled
        renderCache.isEnabled = false
        work()
        renderCache.isEnabled = enabled
    }

    /// Inserts rendered rows of the backlog from `index` on above the text; the reader stays where they were.
    private func prepend(_ parts: [NSAttributedString], from index: Int) {
        guard let storage = transcript.textStorage, !parts.isEmpty else { return }
        let position = pendingPosition ?? capturePosition()
        let wasChanging = changingLayout
        changingLayout = true
        defer {
            changingLayout = wasChanging
            switch position {
            case .end?: scrollToEnd()
            case .anchor?: pendingPosition = position
            case nil: break
            }
        }
        let text = NSMutableAttributedString()
        var added: [NSRange] = []
        for part in parts {
            added.append(NSRange(location: text.length, length: part.length))
            text.append(part)
        }
        for row in ranges.indices { ranges[row].location += text.length }
        // Inserting at the start shifts the storage's whole attribute-run array once per inserted run (a memmove each):
        // 0.1-0.6 s per 200 k characters in a long chat; replacing the whole text does the same. Beyond a few thousand
        // characters the old text is appended behind the new one instead, and the emptied storage takes the result by
        // appending, so runs are only ever added at the end (one copy, about 50 ms per million characters).
        // The selection moves with the text it covered.
        if text.length <= Self.directInsertCharacters {
            storage.beginEditing()
            storage.insert(text, at: 0)
            storage.endEditing()
        } else {
            let selection = transcript.selectedRanges.map { NSValue(range: NSRange(location: $0.rangeValue.location + text.length,
                                                                                    length: $0.rangeValue.length)) }
            text.append(storage)
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
            storage.append(text)
            storage.endEditing()
            transcript.selectedRanges = selection
        }
        ranges = added + ranges
        previous = Array(historyBacklog[index...]) + previous
        historyBacklog.removeSubrange(index...)
        editCount += 1
        needsLayout = true
        if !renderedChats.isEmpty { trimRenderedChats() }
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
        if width > 0, abs(width - styledWidth) > 0.5, inLiveResize {
            // Text still rewraps every frame; restyling every message every frame made window resizing stutter.
            restyleAfterLiveResize = true
        } else if width > 0, abs(width - styledWidth) > 0.5 {
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
        let jumpSize = (30 * zoom).rounded()
        jumpToLatest.frame = NSRect(x: ((bounds.width - jumpSize) / 2).rounded(), y: isFlipped ? bounds.height - jumpSize - 16 : 16,
                                    width: jumpSize, height: jumpSize)
        defer { scheduleReadCheck(); updateJumpToLatest() }
        guard contentSize.width > 0, contentSize.height > 0, !previous.isEmpty else { return }
        keepEndPinned()
        if let position = pendingPosition {
            pendingPosition = nil
            restorePosition(position)
        } else if needsEndScroll {
            needsEndScroll = false
            layoutTail()
            transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage?.length ?? 0, length: 0))
        }
        if Perf.end("chat.open", id: conversationID, "\(previous.count) rows, \(renderCount - openRenders) rendered, \(openReused ? "kept text" : "new text")") {
            Perf.watchHitches(in: self, for: 2)
        }
    }

    /// Lays out the last rows, at least `tailCharacters` of them, so the end can be placed and shown; non-contiguous
    /// layout fills in the history above only when it scrolls into view. Laying out the whole container here took
    /// 1.3-1.7 s of a 1000-message chat's open.
    private func layoutTail() {
        guard let manager = transcript.layoutManager, let storage = transcript.textStorage, storage.length > 0 else { return }
        var start = storage.length
        for range in ranges.reversed() {
            start = min(start, range.location)
            if storage.length - start >= Self.tailCharacters { break }
        }
        if ranges.isEmpty { start = max(0, storage.length - Self.tailCharacters) }
        manager.ensureLayout(forCharacterRange: NSRange(location: start, length: storage.length - start))
    }

    /// About two tall viewports of prose.
    static let tailCharacters = 8_000

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard restyleAfterLiveResize else { return }
        restyleAfterLiveResize = false
        needsLayout = true
    }

    /// Geometry only (document height against the viewport), so it is cheap enough for every scroll and update.
    private func updateJumpToLatest() {
        let below = transcript.frame.maxY - contentView.bounds.maxY
        let show = !isDocument && !previous.isEmpty && !needsEndScroll && pendingPosition == nil && below > 120
        guard show != jumpToLatestShown else { return }
        jumpToLatestShown = show
        jumpToLatest.setAccessibilityElement(show)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            jumpToLatest.animator().alphaValue = show ? 1 : 0
        }
    }

    @objc func jumpToEnd() {
        scrollToEnd()
        updateJumpToLatest()
    }

    /// Scrolls to the message holding `itemID` (a tool call inside a collapsed action row brings up that row) and
    /// briefly highlights the link to `file` in it, or the message's first line. False when the item is not shown.
    @discardableResult public func reveal(itemID: String, file: String? = nil) -> Bool {
        if let index = historyBacklog.firstIndex(where: { $0.id == itemID || actionGroups[$0.id]?.contains { $0.id == itemID } == true }) {
            renderHistory(from: index)
        }
        let rowID = previous.contains(where: { $0.id == itemID }) ? itemID
            : actionGroups.first(where: { $0.value.contains { $0.id == itemID } })?.key
        guard let rowID, let index = previous.firstIndex(where: { $0.id == rowID }), ranges.indices.contains(index),
              ranges[index].length > 0, let storage = transcript.textStorage, let manager = transcript.layoutManager,
              let container = transcript.textContainer, NSMaxRange(ranges[index]) <= storage.length else { return false }
        let row = ranges[index]
        var target: NSRange?
        if let file {
            storage.enumerateAttribute(.link, in: row) { value, range, stop in
                guard let url = value as? URL, url.isFileURL, url.standardizedFileURL.path == file else { return }
                target = range; stop.pointee = true
            }
        }
        if target == nil {
            // The first visible line of the message; rows start with spacing newlines.
            let text = storage.string as NSString
            var start = row.location
            while start < NSMaxRange(row), CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: start)) ?? " ") { start += 1 }
            let line = text.lineRange(for: NSRange(location: min(start, NSMaxRange(row) - 1), length: 0))
            target = NSIntersectionRange(NSRange(location: start, length: max(0, NSMaxRange(line) - start)), row)
            if target?.length ?? 0 > 1, text.character(at: NSMaxRange(target!) - 1) == 10 { target!.length -= 1 }
        }
        guard let target, target.length > 0 else { return false }
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, NSMaxRange(target) + 1)))
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: container)
        // A third of the way down: the text before the mention stays readable.
        let maxY = max(0, transcript.frame.height - contentView.bounds.height)
        let y = min(maxY, max(0, rect.minY + transcript.textContainerOrigin.y - contentView.bounds.height / 3))
        pendingPosition = nil; needsEndScroll = false; pinnedToEnd = false; deferredEndScroll = nil
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        updateJumpToLatest()
        transcript.showFindIndicator(for: target)
        return true
    }

    @objc private func liveScrollStarted() { liveScrolling = true }

    /// A reader who stayed at the end through the gesture follows the text that arrived meanwhile.
    @objc private func liveScrollEnded() {
        liveScrolling = false
        guard let end = deferredEndScroll else { return }
        deferredEndScroll = nil
        if contentView.bounds.maxY >= end - 2 { scrollToEnd() }
    }

    /// Text not laid out yet has an estimated height, TextKit's guess from its length (about half the real height of a
    /// chat with code, more than the real one for long prose). A fast scroll or a scroller drag skips parts of the text,
    /// which stay estimated, so reaching the end laid them out and moved the end by hundreds of points under the reader:
    /// the scroll overshot into blank space, then snapped. Once the viewport comes within a few heights of the end,
    /// everything from it to the end is laid out, so the end is exact before the reader gets there. Text below the
    /// reader moves nothing in view; when it is all laid out already this costs next to nothing.
    private func layoutTowardEnd() {
        guard !changingLayout, !layingOutTowardEnd, let manager = transcript.layoutManager, let container = transcript.textContainer,
              let storage = transcript.textStorage, storage.length > 0 else { return }
        let viewport = contentView.bounds
        guard viewport.height > 0, viewport.maxY >= transcript.frame.maxY - Self.endLayoutViewports * viewport.height else { return }
        layingOutTowardEnd = true
        changingLayout = true
        defer { changingLayout = false; layingOutTowardEnd = false }
        let point = NSPoint(x: container.lineFragmentPadding, y: max(0, viewport.minY - transcript.textContainerOrigin.y))
        let glyph = manager.glyphIndex(for: point, in: container)
        let start = glyph < manager.numberOfGlyphs ? manager.characterIndexForGlyph(at: glyph) : storage.length
        guard start < storage.length else { return }
        manager.ensureLayout(forCharacterRange: NSRange(location: start, length: storage.length - start))
    }

    /// How close to the end (in viewport heights below the viewport) the rest of the text is laid out: a flick or a
    /// drag on a busy main thread moves one to two viewports per frame.
    static let endLayoutViewports: CGFloat = 3
    private var layingOutTowardEnd = false

    @objc private func viewportChanged() {
        // An edit resizes the text view from `endEditing`, before `previous` matches the new `ranges`; the hover lookup
        // then indexed past the end of `previous` and crashed. The next scroll or mouse move finds the hover again.
        if !changingLayout {
            lastScrolled = ProcessInfo.processInfo.systemUptime
            refreshHover()
        }
        workingIndicator.refreshAnimation()
        logJumpAfterRestore()
        // Past an edge the rubber band owns the origin. Layout here (the end check lays out the last rows) could resize
        // the text view, and the clip view then clamped the origin back to the edge for one frame mid-bounce.
        let viewport = contentView.bounds
        guard viewport.minY >= -0.5, viewport.maxY <= transcript.frame.maxY + 0.5 else { return }
        layoutTowardEnd()
        keepEndPinned()
        updateJumpToLatest()
        rememberPosition()
        scheduleReadCheck()
    }

    private func rememberPosition() {
        guard !changingLayout, pendingPosition == nil, !needsEndScroll, let id = conversationID else { return }
        // Checking the end lays out the last rows, and TextKit's resize of the text view may move the viewport: that
        // is layout, not the reader scrolling (which pauses the older history).
        changingLayout = true
        let captured = capturePosition()
        changingLayout = false
        guard let position = captured else { return }
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
        // Only the text up to the reading position needs layout (the end: only the last rows), not the whole chat.
        if case let .anchor(itemID, character, _, _) = position, let storage = transcript.textStorage,
           let index = previous.firstIndex(where: { $0.id == itemID }), ranges.indices.contains(index) {
            manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, ranges[index].location + character + 1)))
        } else if case .end = position {
            layoutTail()
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
        guard !isDocument, openRestorePending else { return }
        openRestorePending = false
        // A chat sometimes reopened at its top (2026-11-04, not reproduced): the restore and any jump after it are logged.
        let found: String
        if case let .anchor(itemID, _, _, _) = position {
            found = previous.contains { $0.id == itemID } ? "found" : historyBacklog.contains { $0.id == itemID } ? "in backlog" : "missing"
        } else { found = "end" }
        restoredAt = ProcessInfo.processInfo.systemUptime
        Self.placeLog.notice("""
            restore \(self.conversationID ?? "", privacy: .public) \(found, privacy: .public): y \(Int(self.contentView.bounds.minY)) \
            of \(Int(self.transcript.frame.height)), \(self.previous.count) rows, backlog \(self.historyBacklog.count)
            """)
    }

    /// Reading-place diagnostics: identifiers and coordinates only, never message text.
    private static let placeLog = Logger(subsystem: "local.daniil.switchboard", category: "transcript")
    private var restoredAt: TimeInterval = 0
    private var openRestorePending = false
    private var lastViewportY: CGFloat = 0

    /// Logs a viewport that moves up by more than two heights at once without a gesture soon after a restore.
    private func logJumpAfterRestore() {
        let y = contentView.bounds.minY
        defer { lastViewportY = y }
        guard !isDocument, !liveScrolling, ProcessInfo.processInfo.systemUptime - restoredAt < 5,
              lastViewportY - y > 2 * max(contentView.bounds.height, 1) else { return }
        Self.placeLog.notice("""
            jump \(self.conversationID ?? "", privacy: .public): y \(Int(self.lastViewportY)) -> \(Int(y)) of \
            \(Int(self.transcript.frame.height)), layout \(self.changingLayout), pending \(self.pendingPosition != nil), \
            backlog \(self.historyBacklog.count)
            """)
    }

    /// Non-contiguous TextKit layout can place the final glyph at an estimated position. Lay out the last rows
    /// before deciding that the end is visible, but only when the viewport is within one viewport height of the
    /// document's end: farther up, the frame alone shows that the end is out of view, and no layout is forced.
    public var isAtTranscriptEnd: Bool {
        guard contentSize.width > 0, contentSize.height > 0,
              let storage = transcript.textStorage, storage.length > 0,
              let manager = transcript.layoutManager, let container = transcript.textContainer else { return false }
        let viewport = contentView.bounds
        guard viewport.height > 0, viewport.maxY >= transcript.frame.maxY - viewport.height else { return false }
        let lastCharacter = NSRange(location: storage.length - 1, length: 1)
        layoutTail()
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
        manager.ensureLayout(forCharacterRange: NSRange(location: range.location, length: end - range.location))
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
            guard let completionID = self.unreadCompletionID, let threadID = self.conversationID, !self.isCovered,
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

    /// The working row's line for the tool call the agent is running now; nil when it runs none.
    public static func currentActivityLine(_ items: [TranscriptItem]) -> String? {
        guard let activity = currentActivity(items) else { return nil }
        if let title = activity.toolCall?.title, !title.isEmpty { return ActivityDetail.oneLine(title, limit: 120) }
        return activityHeadline(activity.text)
    }

    /// Text moves under a still pointer while scrolling, and AppKit rebuilds the tracking area with an exit event, so the
    /// copy control of the message under the pointer went out mid-scroll and stayed out until the mouse moved.
    private func refreshHover() {
        guard let window = transcript.window, window.isKeyWindow else { return }
        let point = transcript.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: transcript.visibleRect.contains(point) ? point : nil)
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
                if let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) }), index < previous.count,
                   previous[index].showsCopyControl {
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
    /// The rule lives in `ActivityRetention`, next to the cap and the archive reduction it must keep working on.
    nonisolated public static func activityHeadline(_ text: String, limit: Int = 120) -> String {
        ActivityRetention.headline(text, limit: limit)
    }

    private func headline(of activity: TranscriptItem) -> String {
        if let title = activity.toolCall?.title, !title.isEmpty { return ActivityDetail.oneLine(title, limit: 120) }
        let length = activity.text.utf8.count
        if let memo = headlineMemo, memo.id == activity.id, memo.length == length { return memo.headline }
        let line = Self.activityHeadline(activity.text)
        headlineMemo = (activity.id, length, line)
        return line
    }

    /// Requests group independently (`groupActivities` closes a segment at each user message), so the rows before the
    /// last user message are reused while they are unchanged and only the last request is regrouped: a streaming delta,
    /// a new tool call or a status flip in the running turn costs as much as that turn, not the whole chat. Any change
    /// before it (a late changes card on an earlier answer, an older call's status) regroups everything.
    private func groupedItems(_ items: [TranscriptItem], conversationID: String?, isWorking: Bool) -> [TranscriptItem] {
        let split = items.lastIndex { $0.kind == "user" } ?? 0
        if let memo = groupingMemo, memo.conversationID == conversationID {
            // Compared from the end first: a streaming delta differs in the last item.
            if memo.isWorking == isWorking, memo.raw.count == items.count, memo.raw.last == items.last, memo.raw == items {
                actionGroups = memo.groups
                return memo.items
            }
            if memo.split == split, memo.raw.count >= split, memo.raw[..<split] == items[..<split] {
                let tail = Self.groupActivities(Array(items[split...]), isWorking: isWorking)
                var groups = memo.headGroups
                for (id, members) in tail.groups { groups[id] = members }
                let grouped = memo.head + tail.items
                groupingMemo = GroupingMemo(conversationID: conversationID, isWorking: isWorking, raw: items, split: split,
                                            head: memo.head, headGroups: memo.headGroups, items: grouped, groups: groups)
                actionGroups = groups
                return grouped
            }
        }
        let head = Self.groupActivities(Array(items[..<split]), isWorking: false)
        let tail = Self.groupActivities(Array(items[split...]), isWorking: isWorking)
        var groups = head.groups
        for (id, members) in tail.groups { groups[id] = members }
        let grouped = head.items + tail.items
        groupingMemo = GroupingMemo(conversationID: conversationID, isWorking: isWorking, raw: items, split: split,
                                    head: head.items, headGroups: head.groups, items: grouped, groups: groups)
        actionGroups = groups
        return grouped
    }

    /// Groups each request's tool calls behind one summary row. The row's text names the calls by id and text
    /// length only, so building and comparing it stays cheap on every update; their bodies come from `groups`
    /// (keyed by the row's id) through `renderActivity` when the row is open.
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
            // A finished turn's changed files go under its answer, or under the turn when it ended without one.
            let timingSource = segment.last(where: { $0.kind == "assistant" && $0.timing != nil })
            let card = active ? nil : responseTiming.flatMap { timing in timingSource.flatMap { TranscriptChangesCard.item(for: timing, sourceID: $0.id) } }
            var cardPlaced = card == nil
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
                if item.kind == ActivityDetail.thinkingKind { appendThinking(item, to: &result, groups: &groups); continue }
                guard item.kind == "activity" else {
                    result.append(item)
                    if !cardPlaced, item.id == finalAnswer?.id, let card { result.append(card); cardPlaced = true }
                    continue
                }
                guard !inserted, let first = actions.first else { continue }
                inserted = true
                // A command and its result share one row.
                let count = activitySteps(actions).count
                let summary = L10n.text("Действия \(first.speakerName) · \(count)", "\(first.speakerName) actions · \(count)")
                groups[first.id] = actions
                result.append(TranscriptItem(id: first.id, kind: "activity",
                                             text: actions.map(activityKey).joined(separator: "\n"), phase: summary))
            }
            if !cardPlaced, let card { result.append(card) }
            segment.removeAll()
        }
        for item in items {
            if item.kind == "user" { appendSegment(active: false) }
            segment.append(item)
        }
        appendSegment(active: isWorking)
        return (result, groups)
    }

    private func render(_ item: TranscriptItem, expanded: Bool) -> NSAttributedString {
        renderCount += 1
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        if item.kind == "compaction" { return TranscriptCompactionDivider.render(item) }
        if item.kind == TranscriptChangesCard.itemKind {
            guard TranscriptLinks.openTurnChanges != nil, let container = transcript.textContainer else { return result }
            return TranscriptChangesCard.render(item, width: container.containerSize.width, padding: container.lineFragmentPadding)
        }
        if item.kind == "refusal" {
            // A stop notice from the safety classifier.
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
                    .applying(.init(paletteColors: [DeskPalette.ns.attention])))
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
                .foregroundColor: DeskPalette.ns.attentionInk, .paragraphStyle: paragraph,
                .noticeBadge: item.id, .badgeTint: DeskPalette.ns.attentionWash
            ], range: NSRange(location: badgeStart, length: result.length - badgeStart))
            // Keep paragraph terminators outside the badge so it hugs its content.
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph,
                .font: NSFont.systemFont(ofSize: 12)]))
            return result
        }
        if item.kind == "loading" {
            let font = NSFont.systemFont(ofSize: 12)
            result.append(NSAttributedString(string: "      " + item.text, attributes: [.font: font, .foregroundColor: DeskPalette.ns.muted]))
            if let elapsed = item.phase {
                result.append(NSAttributedString(string: (item.text.isEmpty ? "" : "  ") + elapsed, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: DeskPalette.ns.muted.withAlphaComponent(0.75)
                ]))
            }
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            return result
        }
        if item.kind == "activity" {
            renderActivity(item, expanded: expanded, into: result)
        } else if item.kind == ActivityDetail.thinkingKind {
            renderThinking(item, into: result)
        } else if item.kind == AgentPlan.itemKind, let plan = item.plan {
            renderPlan(plan, id: item.id, into: result)
        } else {
            if (item.kind == "user" && item.phase != nil) || (item.kind != "user" && item.showsAuthor) {
                let user = item.kind == "user"
                let header = NSMutableAttributedString()
                if !user {
                    let avatar = NSTextAttachment()
                    avatar.image = Self.assistantAvatar
                    avatar.bounds = NSRect(x: 0, y: -5.5, width: 20, height: 20)
                    header.append(NSAttributedString(attachment: avatar))
                    header.append(NSAttributedString(string: "  "))
                }
                header.append(NSAttributedString(string: (user ? item.phase ?? "" : (item.speakerName)) + "\n"))
                header.addAttributes([
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: user ? DeskPalette.ns.muted : DeskPalette.ns.ink,
                    .responseHeader: true
                ], range: NSRange(location: 0, length: header.length))
                result.append(header)
            }
            if let timing = item.timing {
                let open = expandedMetrics.contains(item.id)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: DeskPalette.ns.muted,
                    .link: "contextdesk-metrics:" + item.id, .responseHeader: true
                ]
                var pill = attributes; pill[.metricsPill] = true
                result.append(NSAttributedString(string: (open ? "▾ " : "▸ ") + timing.label() + " · " + L10n.date(timing.completedAt), attributes: pill))
                result.append(NSAttributedString(string: "\n", attributes: attributes))
                if open {
                    let detail = timing.tokens?.detail() ?? L10n.text("Данные о токенах для этого запроса недоступны.", "Token data is unavailable for this request.")
                    result.append(NSAttributedString(string: detail + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DeskPalette.ns.muted
                    ]))
                }
            }
        }
        if item.kind == "assistant" {
            var markdown = TranscriptMarkdown(view: self, item: item, options: linkOptions,
                                              width: transcript.textContainer?.containerSize.width ?? 600)
            markdown.render(into: result)
        } else if item.kind != "activity" && item.kind != ActivityDetail.thinkingKind && !(item.kind == AgentPlan.itemKind && item.plan != nil) {
            for (index, block) in item.text.components(separatedBy: "```").enumerated() {
                let isCode = index % 2 == 1
                let font = isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 14)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ]
                // Code and tool output stay literal, including link-like text; image paths a user pasted show as chips.
                result.append(isCode ? NSAttributedString(string: block, attributes: attributes)
                              : item.kind == "user" ? TranscriptImagePaths.render(block, attributes: attributes)
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
        // Before the first layout the column width is unknown and `layout()` styles every message once it is;
        // styling here as well did that work twice for every message of a newly opened chat.
        if styledWidth > 0 { applyMessageStyle(item, to: result, range: NSRange(location: 0, length: result.length)) }
        return result
    }

    /// A tool-call group as a soft card: the header toggles it; an open group lists one numbered row per call.
    /// The card padding lies in the first and last paragraphs' spacing, inside their own line fragments.
    private func renderActivity(_ item: TranscriptItem, expanded: Bool, into result: NSMutableAttributedString) {
        let start = result.length
        func style(before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 12; style.headIndent = 12; style.tailIndent = -16
            style.lineSpacing = 1; style.lineBreakMode = .byWordWrapping
            style.paragraphSpacingBefore = before; style.paragraphSpacing = after
            return style
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = item.phase ?? L10n.text("Действия \(item.speakerName)", "\(item.speakerName) actions")
        let header = NSMutableAttributedString(attachment: { let icon = NSTextAttachment(); icon.image = Self.activityIcon
            icon.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14); return icon }())
        header.append(NSAttributedString(string: "  " + title, attributes: [.foregroundColor: DeskPalette.ns.ink]))
        header.append(NSAttributedString(string: "  " + (expanded ? "▾" : "▸"), attributes: [.foregroundColor: DeskPalette.ns.muted]))
        header.addAttributes([.font: font, .link: "contextdesk-action:" + item.id], range: NSRange(location: 0, length: header.length))
        header.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        header.addAttribute(.paragraphStyle, value: style(before: 9, after: expanded ? 2 : 9), range: NSRange(location: 0, length: header.length))
        result.append(header)
        if expanded {
            // An open summary row shows its tool calls (`TranscriptActivityDetail`); a document's own activity item keeps its text.
            appendActivitySteps(of: item, into: result, row: style(before: 0, after: 2), first: style(before: 7, after: 2))
            let last = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
            if last.location > start, let style = (result.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacing = 9
                result.addAttribute(.paragraphStyle, value: style, range: last)
            }
        }
        result.addAttribute(.activityCard, value: item.id, range: NSRange(location: start, length: result.length - start))
    }

    /// Drawn once: a moss sparkle on a moss-wash circle before the assistant's name.
    static let assistantAvatar: NSImage = {
        let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [DeskPalette.ns.accent])))
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            DeskPalette.ns.accentWash.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }()

    static let activityIcon = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [DeskPalette.ns.accent])))

    var linkOptions: TranscriptLinks.Options {
        TranscriptLinks.Options(chips: true, baseDirectory: projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }, source: documentURL)
    }

    /// Configured control symbols, shared by every message: looking one up and configuring it per message was a
    /// visible part of opening a chat. The colour is kept with its image, so the key's identity stays its own.
    private struct ControlKey: Hashable { var symbol: String; var size: CGFloat; var description: String; var color: ObjectIdentifier }
    private static var controlImages: [ControlKey: (color: NSColor, image: NSImage?)] = [:]
    static func controlImage(_ symbol: String, size: CGFloat, color: NSColor, description: String) -> NSImage? {
        let key = ControlKey(symbol: symbol, size: size, description: description, color: ObjectIdentifier(color))
        if let known = controlImages[key], known.color === color { return known.image }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: [color])))
        if controlImages.count >= 256 { controlImages.removeAll() }
        controlImages[key] = (color, image)
        return image
    }

    func copyControl(feedback: Bool?, description: String, hoverItemID: String? = nil, label: String? = nil, tint: NSColor? = nil,
                     visible: (@MainActor @Sendable () -> Bool)? = nil, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let feedbackText = feedback.map { $0 ? L10n.text("Скопировано", "Copied") : L10n.text("Не удалось скопировать", "Could not copy") }
        let description = feedbackText ?? description
        let color: NSColor = feedback.map { $0 ? DeskPalette.ns.accent : DeskPalette.ns.problem } ?? tint ?? DeskPalette.ns.muted
        let symbol = feedback.map { $0 ? "checkmark" : "exclamationmark.circle" } ?? "doc.on.doc"
        let attachment = NSTextAttachment()
        let image = Self.controlImage(symbol, size: label == nil ? 13 : 11, color: color, description: description)
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
        if item.kind == TranscriptChangesCard.itemKind, let container = transcript.textContainer {
            TranscriptChangesCard.restyle(text, range: range, width: container.containerSize.width, padding: container.lineFragmentPadding)
            return
        }
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
        // The metrics pill's fill reaches 8 pt past its text; the indent keeps it on the column's edge.
        text.enumerateAttribute(.metricsPill, in: range) { value, pillRange, _ in
            guard value != nil, let pill = (text.attribute(.paragraphStyle, at: pillRange.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle else { return }
            pill.firstLineHeadIndent += 8; pill.headIndent += 8; pill.paragraphSpacingBefore = 2; pill.lineSpacing = 0; pill.minimumLineHeight = 20
            let string = text.string as NSString
            let line = string.paragraphRange(for: pillRange)
            text.addAttribute(.paragraphStyle, value: pill, range: line)
            // The pill sits right under the author line.
            guard line.location > range.location else { return }
            let author = string.paragraphRange(for: NSRange(location: line.location - 1, length: 0))
            guard text.attribute(.responseHeader, at: author.location, effectiveRange: nil) != nil,
                  let style = (text.attribute(.paragraphStyle, at: author.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle else { return }
            style.paragraphSpacing = 2; style.lineSpacing = 0
            text.addAttribute(.paragraphStyle, value: style, range: author)
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

    private struct InsetKey: Hashable { var text: String; var phase: String?; var width: CGFloat }
    /// Measured bubble insets: a user message is measured once per column width, not on every restyle and reopen.
    private static var insets: [InsetKey: CGFloat] = [:]

    /// Left edge of a user bubble that hugs its text, up to 78% of the column.
    static func outgoingInset(_ item: TranscriptItem, width: CGFloat) -> CGFloat {
        let key = InsetKey(text: item.text, phase: item.phase, width: width)
        if let known = insets[key] { return known }
        let inset = measureOutgoingInset(item, width: width)
        if insets.count >= 4_096 { insets.removeAll() }
        insets[key] = inset
        return inset
    }

    private static func measureOutgoingInset(_ item: TranscriptItem, width: CGFloat) -> CGFloat {
        let maxText = max(80, width * 0.78 - 32)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        // Image paths show as chips: the bubble fits the chips, not the long paths.
        let body = TranscriptImagePaths.measuringText(item.text, attributes: font)
            ?? NSAttributedString(string: item.text.isEmpty ? " " : item.text, attributes: font)
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

    func rerenderItem(id: String) {
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

    func showCopyFeedback(id: String, succeeded: Bool, block: Int?) {
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
        if value == "contextdesk-code-open" {
            if let storage = transcript.textStorage, charIndex >= 0, charIndex < storage.length,
               let text = storage.attribute(.blockCopy, at: charIndex, effectiveRange: nil) as? String {
                TranscriptTextWindow.show(text, relativeTo: window)
            }
            return true
        }
        if value.hasPrefix(Self.detailLinkPrefix) { handleDetailLink(value); return true }
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
        if let link = TranscriptChangesCard.parse(value) {
            if let changes = previous.first(where: { $0.id == link.itemID })?.timing?.changes {
                if let onOpenFile, let url = TranscriptChangesCard.previewURL(changes, file: link.file) { onOpenFile(url, nil) }
                else { TranscriptLinks.openTurnChanges?(conversationID, changes, link.file) }
            }
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
            case .open:
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                    EditorLauncher.open(url.path, line: line)
                } else { NSWorkspace.shared.open(URL(fileURLWithPath: url.path)) }
            }
            return true
        }
        NSWorkspace.shared.open(url); return true
    }

    public enum FileClickAction: Equatable { case preview, reveal, open }

    /// Click previews a file in the app, Option-click reveals it in Finder, Command-click opens it in the code editor
    /// (folders in Finder).
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
        let isImagePreview = storage.attribute(.imagePreview, at: charIndex, effectiveRange: nil) != nil
        if isImagePreview {
            // A pasted screenshot: its path is what the user most often needs again.
            add(L10n.text("Скопировать путь", "Copy Path")) {
                pasteboard.clearContents(); pasteboard.setString(url.path, forType: .string)
            }
            add(L10n.text("Скопировать изображение", "Copy Image")) { _ = TranscriptImagePaths.copyImage(url, to: pasteboard) }
            items.append(.separator())
        }
        if url.isFileURL {
            if let onOpenFile, Self.fileClickAction([], url: url, canPreview: true) == .preview {
                let line = storage.attribute(.fileLine, at: charIndex, effectiveRange: nil) as? Int
                add(L10n.text("Предпросмотр", "Preview")) { onOpenFile(url, line) }
            }
            let file = URL(fileURLWithPath: url.path)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue {
                let line = storage.attribute(.fileLine, at: charIndex, effectiveRange: nil) as? Int
                add(EditorLauncher.openTitle) { EditorLauncher.open(file.path, line: line) }
                items.append(contentsOf: EditorLauncher.browserItems(file.path))
                items.append(EditorLauncher.submenu(file.path, line: line))
            } else {
                add(L10n.text("Открыть в программе по умолчанию", "Open in Default App")) { NSWorkspace.shared.open(file) }
            }
            add(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            if let relative = Self.relativePath(url.path, project: projectPath) {
                add(L10n.text("Скопировать относительный путь", "Copy Relative Path")) {
                    pasteboard.clearContents(); pasteboard.setString(relative, forType: .string)
                }
            }
            if !isImagePreview {
                add(L10n.text("Скопировать абсолютный путь", "Copy Absolute Path")) {
                    pasteboard.clearContents(); pasteboard.setString(url.path, forType: .string)
                }
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
        // A changes-card row is one target across its whole width and height, not only over its text.
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let hit = changesLink(at: convert(event.locationInWindow, from: nil)) {
            _ = delegate?.textView?(self, clickedOnLink: hit.link, at: hit.index)
            return
        }
        // A pasted image's thumbnail opens like its file link; AppKit tracks a click on an attachment as a cell click.
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let hit = imagePreview(at: convert(event.locationInWindow, from: nil)) {
            _ = delegate?.textView?(self, clickedOnLink: hit.url, at: hit.index)
            return
        }
        guard let trackClick else { return super.mouseDown(with: event) }
        trackClick { super.mouseDown(with: event) }
    }
    /// The link of the changes-card row under `point`, anywhere in the row's line.
    func changesLink(at point: NSPoint) -> (link: String, index: Int)? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= line.minY, local.y < line.maxY else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, storage.attribute(.changesCard, at: index, effectiveRange: nil) != nil,
              let link = storage.attribute(.link, at: index, effectiveRange: nil) as? String else { return nil }
        return (link, index)
    }
    /// The file of the image thumbnail under `point`.
    func imagePreview(at point: NSPoint) -> (url: URL, index: Int)? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let url = storage.attribute(.imagePreview, at: index, effectiveRange: nil) as? URL,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return (url, index)
    }
    /// Select All (and the copy after it) covers the whole chat, also the older part still waiting to be rendered.
    var beforeSelectAll: (() -> Void)?
    override func selectAll(_ sender: Any?) {
        beforeSelectAll?()
        super.selectAll(sender)
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
        let point = convert(event.locationInWindow, from: nil)
        if changesLink(at: point) != nil || imagePreview(at: point) != nil { NSCursor.pointingHand.set() }
        hoverChanged?(point)
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
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
    /// A notice drawn as a rounded badge (a refusal).
    static let noticeBadge = NSAttributedString.Key("ContextDeskNoticeBadge")
    /// The wash a badge is filled with; badges without it are neutral.
    static let badgeTint = NSAttributedString.Key("ContextDeskBadgeTint")
    /// The "worked for" line of an answer, drawn as a capsule.
    static let metricsPill = NSAttributedString.Key("ContextDeskMetricsPill")
    /// The turn's changed-files row next to the metrics pill; opens the diff viewer.
    /// A tool-call group drawn as a card; `activityStep` marks the first character of each listed call.
    static let activityCard = NSAttributedString.Key("ContextDeskActivityCard")
    static let activityStep = NSAttributedString.Key("ContextDeskActivityStep")
    static let quoteCard = NSAttributedString.Key("ContextDeskQuoteCard")
    static let quoteCopy = NSAttributedString.Key("ContextDeskQuoteCopy")
    static let quoteIndex = NSAttributedString.Key("ContextDeskQuoteIndex")
    static let messageCopy = NSAttributedString.Key("ContextDeskMessageCopy")
    static let responseHeader = NSAttributedString.Key("ContextDeskResponseHeader")
    static let messageBubble = NSAttributedString.Key("ContextDeskMessageBubble")
    static let outgoingBubble = NSAttributedString.Key("ContextDeskOutgoingBubble")
}

/// Paint only visible message fragments; keep native selection and TextKit's bounded layout.
final class BubbleLayoutManager: NSLayoutManager {
    /// A user bubble reaches this far above and below its text, outside the text's line fragments.
    static let bubbleOverhang: CGFloat = 10
    /// Hairline between tool calls in an open card, a step darker than its `subtle` fill.
    static let stepRule = DeskPalette.ns.rgb(0xDDE1D6)
    static let diffAdded = DeskPalette.ns.accent.withAlphaComponent(0.13)
    static let diffRemoved = DeskPalette.ns.problem.withAlphaComponent(0.11)
    static let lineNumberColor = DeskPalette.ns.muted.withAlphaComponent(0.75)
    nonisolated(unsafe) static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Full runs of the card attributes found while drawing; a long card's run is merged from many attribute runs
    /// (syntax colours), so finding it again on every scroll frame cost as much as the card is long.
    private var cardRanges: [NSAttributedString.Key: [NSRange]] = [:]

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        cardRanges.removeAll()
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    /// The whole run of `key` around `location`.
    func cardRange(_ key: NSAttributedString.Key, at location: Int, in storage: NSTextStorage) -> NSRange {
        if let known = cardRanges[key]?.first(where: { NSLocationInRange(location, $0) }) { return known }
        var full = NSRange()
        _ = storage.attribute(key, at: location, longestEffectiveRange: &full, in: NSRange(location: 0, length: storage.length))
        cardRanges[key, default: []].append(full)
        return full
    }
    static func calloutWash(_ kind: String) -> NSColor {
        switch kind {
        case "warning": DeskPalette.ns.attentionWash
        case "caution": DeskPalette.ns.problemWash
        case "important": TranscriptMarkdown.Syntax.keyword.withAlphaComponent(0.09)
        default: DeskPalette.ns.accentWash
        }
    }
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
            Self.bubblePath(rect, radius: 20, tail: 6).fill()
        }
    }
    /// A rounded rect in flipped coordinates whose bottom-trailing corner, the bubble's tail, is tighter.
    static func bubblePath(_ rect: NSRect, radius: CGFloat, tail: CGFloat) -> NSBezierPath {
        let r = min(radius, rect.height / 2, rect.width / 2), t = min(tail, r)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + r, y: rect.minY))
        path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY), radius: t)
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.minY), radius: r)
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.close()
        return path
    }
    /// Top of the first and bottom of the last line fragment holding `glyphs`, as `boundingRect` reports them, from two
    /// lookups instead of a walk over every line in between.
    func lineExtent(forGlyphRange glyphs: NSRange) -> (top: CGFloat, bottom: CGFloat) {
        guard glyphs.length > 0, glyphs.location < numberOfGlyphs else { return (0, 0) }
        let first = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lineFragmentUsedRect(forGlyphAt: min(numberOfGlyphs, NSMaxRange(glyphs)) - 1, effectiveRange: nil)
        return (first.minY, last.maxY)
    }
    /// Top and bottom of the text between two characters: the first line's ascender to the last line's descender.
    private func textExtent(from first: Int, to last: Int, in storage: NSTextStorage) -> (top: CGFloat, bottom: CGFloat) {
        func edges(_ character: Int) -> (CGFloat, CGFloat) {
            let glyph = glyphIndexForCharacter(at: character)
            guard glyph < numberOfGlyphs else { return (0, 0) }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y
            let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
            return (baseline - font.ascender, baseline - font.descender)
        }
        return (edges(first).0, edges(last).1)
    }
    /// Last character of `range` that is not a line break.
    private func lastVisible(in range: NSRange, of storage: NSTextStorage) -> Int {
        let string = storage.string as NSString
        var index = NSMaxRange(range) - 1
        while index > range.location, string.character(at: index) == 10 { index -= 1 }
        return index
    }
    /// Capsules behind each line's part of `range`, sized from the font: `pad` wide beyond the text, `rise` above and below it.
    private func fillRuns(_ range: NSRange, in storage: NSTextStorage, container: NSTextContainer, origin: NSPoint,
                          pad: CGFloat, rise: CGFloat, radius: CGFloat?) {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, glyphs)
            guard part.length > 0 else { return }
            let rect = self.boundingRect(forGlyphRange: part, in: container)
            let baseline = self.location(forGlyphAt: part.location).y
            let line = self.lineFragmentRect(forGlyphAt: part.location, effectiveRange: nil)
            let height = font.ascender - font.descender + 2 * rise
            let box = NSRect(x: origin.x + rect.minX - pad, y: origin.y + line.minY + baseline - font.ascender - rise,
                             width: rect.width + 2 * pad, height: height)
            let corner = radius ?? height / 2
            NSBezierPath(roundedRect: box, xRadius: corner, yRadius: corner).fill()
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
        TranscriptCompactionDivider.drawRules(self, storage: storage, characters: characters, container: container, origin: origin)
        storage.enumerateAttribute(.noticeBadge, in: characters) { value, range, _ in
            guard value != nil else { return }
            var fullRange = NSRange()
            _ = storage.attribute(.noticeBadge, at: range.location, longestEffectiveRange: &fullRange,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -10, dy: -6)
            let wash = storage.attribute(.badgeTint, at: range.location, effectiveRange: nil) as? NSColor
            (wash ?? DeskPalette.ns.subtle).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        storage.enumerateAttribute(.metricsPill, in: characters) { value, range, _ in
            guard value != nil else { return }
            DeskPalette.ns.subtle.setFill()
            fillRuns(range, in: storage, container: container, origin: origin, pad: 8, rise: 3, radius: nil)
        }
        let whole = NSRange(location: 0, length: storage.length)
        let padding = container.lineFragmentPadding
        // Only the part of a long card near the drawn area is filled; its rounded ends lie beyond the clip.
        let clip = NSGraphicsContext.current.map { $0.cgContext.boundingBoxOfClipPath.insetBy(dx: 0, dy: -24) }
        /// A card spans its whole attribute run; its sides follow the first paragraph's indents. Its top and bottom
        /// come from its first and last line, so a long code block or previewed file costs the same as a short one.
        func card(_ key: NSAttributedString.Key, at location: Int, inset: CGFloat) -> (NSRect, NSRange) {
            let full = cardRange(key, at: location, in: storage)
            let extent = lineExtent(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil))
            let style = storage.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle
            let left = padding + (style?.firstLineHeadIndent ?? inset) - inset
            let right = container.containerSize.width - padding + (style?.tailIndent ?? 0) + inset + 4
            // The last paragraph's spacing is not part of its line fragment; pad the card below.
            var rect = NSRect(x: origin.x + left, y: origin.y + extent.top - 2, width: max(1, right - left), height: extent.bottom - extent.top + 12)
            if let clip, !clip.isNull, !clip.isInfinite {
                let top = max(rect.minY, clip.minY), bottom = min(rect.maxY, clip.maxY)
                if bottom > top { rect = NSRect(x: rect.minX, y: top, width: rect.width, height: bottom - top) }
            }
            return (rect, full)
        }
        var drawn = Set<String>()
        storage.enumerateAttribute(.changesCard, in: characters) { value, range, _ in
            guard let id = value as? String, drawn.insert("c" + id).inserted else { return }
            var full = NSRange()
            _ = storage.attribute(.changesCard, at: range.location, longestEffectiveRange: &full, in: whole)
            let lines = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            let first = lineFragmentRect(forGlyphAt: lines.location, effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: max(lines.location, NSMaxRange(lines) - 1), effectiveRange: nil)
            let left = origin.x + padding, width = max(1, container.containerSize.width - 2 * padding - 4)
            let rect = NSRect(x: left, y: origin.y + first.minY, width: width, height: last.maxY - first.minY).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            DeskPalette.ns.canvas.setFill(); shape.fill()
            DeskPalette.ns.border.setStroke(); shape.lineWidth = 1; shape.stroke()
            storage.enumerateAttribute(.changesRow, in: NSIntersectionRange(full, characters)) { row, rowRange, _ in
                guard row != nil, rowRange.location > full.location else { return }
                let top = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: rowRange.location), effectiveRange: nil).minY
                DeskPalette.ns.border.setFill()
                NSRect(x: left + 12, y: origin.y + top, width: width - 24, height: 1).fill()
            }
        }
        storage.enumerateAttribute(.activityCard, in: characters) { value, range, _ in
            guard let id = value as? String, drawn.insert("a" + id).inserted else { return }
            var full = NSRange()
            _ = storage.attribute(.activityCard, at: range.location, longestEffectiveRange: &full, in: whole)
            let extent = textExtent(from: full.location, to: lastVisible(in: full, of: storage), in: storage)
            let left = origin.x + padding, width = max(1, container.containerSize.width - 2 * padding)
            let rect = NSRect(x: left, y: origin.y + extent.top - 7, width: width, height: extent.bottom - extent.top + 14)
            DeskPalette.ns.subtle.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            Self.stepRule.setFill()
            storage.enumerateAttribute(.activityStep, in: NSIntersectionRange(full, characters)) { step, stepRange, _ in
                guard step != nil else { return }
                let top = textExtent(from: stepRange.location, to: stepRange.location, in: storage).top
                NSRect(x: left, y: origin.y + top - 5, width: width, height: 1).fill()
            }
        }
        storage.enumerateAttribute(.quoteCard, in: characters) { value, range, _ in
            guard let index = value as? Int, drawn.insert("q\(index)@\(range.location)").inserted else { return }
            var full = NSRange()
            _ = storage.attribute(.quoteCard, at: range.location, longestEffectiveRange: &full, in: whole)
            // A bar along the quoted text only, not the spacer and copy rows above it.
            var text = full.location
            let string = storage.string as NSString
            while text < NSMaxRange(full) - 1, storage.attribute(.quoteCopy, at: text, effectiveRange: nil) != nil
                    || string.character(at: text) == 10 { text += 1 }
            let extent = textExtent(from: text, to: lastVisible(in: full, of: storage), in: storage)
            let style = storage.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle
            DeskPalette.ns.quoteBar.setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x + padding + (style?.firstLineHeadIndent ?? 16) - 16, y: origin.y + extent.top - 2,
                                             width: 3, height: extent.bottom - extent.top + 4), xRadius: 1.5, yRadius: 1.5).fill()
        }
        storage.enumerateAttribute(.calloutCard, in: characters) { value, range, _ in
            guard let value = value as? String else { return }
            let (rect, _) = card(.calloutCard, at: range.location, inset: 16)
            let kind = value.split(separator: "|").first.map(String.init) ?? ""
            Self.calloutWash(kind).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        storage.enumerateAttribute(.codeCard, in: characters) { value, range, _ in
            guard value != nil else { return }
            let (rect, full) = card(.codeCard, at: range.location, inset: 14)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            DeskPalette.ns.code.setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            storage.enumerateAttribute(.diffLine, in: NSIntersectionRange(full, characters)) { value, lineRange, _ in
                guard let sign = value as? String else { return }
                (sign == "+" ? Self.diffAdded : Self.diffRemoved).setFill()
                let glyphs = glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                    NSRect(x: rect.minX, y: origin.y + lineRect.minY, width: rect.width, height: lineRect.height).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let numberFont = Self.numberFont
        storage.enumerateAttribute(.codeLineNumber, in: characters) { value, range, _ in
            guard let number = value as? Int else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph).y
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let label = NSAttributedString(string: "\(number)", attributes: [.font: numberFont, .foregroundColor: Self.lineNumberColor])
            let right = origin.x + padding + (style?.headIndent ?? 0) - 10
            label.draw(at: NSPoint(x: right - label.size().width, y: origin.y + line.minY + baseline - numberFont.ascender))
        }
        storage.enumerateAttribute(.horizontalRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let left = padding + (style?.headIndent ?? 0)
            DeskPalette.ns.border.setFill()
            NSRect(x: origin.x + left, y: origin.y + bounds.midY.rounded() - 0.5,
                   width: max(1, container.containerSize.width - padding - left), height: 1).fill()
        }
        storage.enumerateAttribute(.inlineChip, in: characters) { value, range, _ in
            guard let raw = value as? Int, let chip = TranscriptLinks.Chip(rawValue: raw), chip != .web else { return }
            (chip == .code ? DeskPalette.ns.code : DeskPalette.ns.accentWash).setFill()
            fillRuns(range, in: storage, container: container, origin: origin, pad: 3, rise: 1.5, radius: 5)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Round "jump to latest" control over the transcript's bottom edge.
@MainActor final class JumpToLatestButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false; title = ""; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = DeskPalette.ns.ink
        wantsLayer = true
        layer?.backgroundColor = DeskPalette.ns.canvas.cgColor
        // The token carries the shadow's alpha; a slightly firmer one keeps the small control visible on the canvas.
        layer?.shadowColor = DeskPalette.ns.shadow.withAlphaComponent(1).cgColor
        layer?.shadowOpacity = Float(DeskPalette.ns.shadow.alphaComponent * 1.6)
        layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -3)
        toolTip = L10n.text("К последнему сообщению", "Jump to latest")
        setAccessibilityLabel(L10n.text("К последнему сообщению", "Jump to latest"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    /// Faded out, it must not catch clicks meant for the text beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue > 0.01 ? super.hitTest(point) : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
