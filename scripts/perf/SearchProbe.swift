// Search performance probe: calls the real ContextCore search code (ChatSearchIndex, PaletteSearch, sidebar filters,
// ProjectFiles.search) against a synthetic corpus and, when SEARCH_PROBE_REAL_DIR is set, against a COPY of the app's
// chat-index.sqlite and metadata.sqlite. Built and run by scripts/perf/search-bench.py inside a throwaway copy of the
// package; never point it at the live files. The report holds timings and counts only, never message text or titles.
import AgentContract
import CSQLite
import Darwin
import Foundation
@testable import ContextCore

// MARK: Measurement helpers

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ start: UInt64, _ end: UInt64 = now()) -> Double { Double(end - start) / 1_000_000 }

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

struct Stats: Encodable {
    var n: Int, p50: Double, p95: Double, max: Double, mean: Double
    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        n = sorted.count
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        p50 = pct(0.5); p95 = pct(0.95); max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }
}

final class Report: @unchecked Sendable {
    var sections: [String: Any] = [:]
    func put(_ key: String, _ value: Any) { sections[key] = value; log("  \(key): \(Self.short(value))") }
    static func short(_ value: Any) -> String {
        if let stats = value as? Stats { return String(format: "p50 %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)", stats.p50, stats.p95, stats.max, stats.n) }
        if let double = value as? Double { return String(format: "%.2f", double) }
        return "\(value)"
    }
    func json() throws -> Data {
        func convert(_ value: Any) -> Any {
            switch value {
            case let stats as Stats: return ["n": stats.n, "p50_ms": stats.p50, "p95_ms": stats.p95, "max_ms": stats.max, "mean_ms": stats.mean]
            case let dict as [String: Any]: return dict.mapValues(convert)
            case let array as [Any]: return array.map(convert)
            default: return value
            }
        }
        return try JSONSerialization.data(withJSONObject: convert(sections), options: [.prettyPrinted, .sortedKeys])
    }
}

func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

/// Deterministic generator, so every run sees the same corpus.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: Synthetic corpus

/// Zipf-like vocabulary: common words first, so short prefixes match most rows as in real chats.
enum Vocabulary {
    static let common = ["the", "a", "to", "and", "is", "in", "it", "of", "that", "for", "this", "file", "run", "test", "build",
                         "и", "в", "не", "что", "на", "это", "файл", "как", "сделай", "проверь", "так", "все", "по", "тест", "сборка"]
    static let topical = ["background", "transcript", "performance", "index", "search", "sidebar", "palette", "archive", "commit",
                          "streaming", "sqlite", "render", "layout", "markdown", "session", "project", "window", "browser", "agent",
                          "приложение", "синхронизация", "транскрипт", "индекс", "поиск", "архив", "проект", "окно", "агент", "задача",
                          "производительность", "настройки", "сообщение", "чат", "ошибка", "результат", "запуск", "сервер", "модель"]
    static let syllablesLatin = ["ka", "lo", "mer", "tin", "ra", "vex", "dor", "pli", "sun", "gra", "ent", "ux", "bel", "cor", "tra"]
    static let syllablesCyr = ["ка", "ло", "мер", "тин", "ра", "вес", "дор", "пли", "сун", "гра", "ент", "бел", "кор", "тра", "ни"]

    static func rareWord(_ rng: inout SplitMix) -> String {
        let cyr = Bool.random(using: &rng)
        let syllables = cyr ? syllablesCyr : syllablesLatin
        return (0..<Int.random(in: 2...4, using: &rng)).map { _ in syllables.randomElement(using: &rng)! }.joined()
    }

    static func sentence(_ rng: inout SplitMix, words: Int) -> String {
        (0..<words).map { _ in
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < 0.55 { return common.randomElement(using: &rng)! }
            if roll < 0.80 { return topical.randomElement(using: &rng)! }
            return rareWord(&rng)
        }.joined(separator: " ")
    }
}

func syntheticInfo(_ index: Int, project: Int) -> ChatSearchIndex.ChatInfo {
    let id = "chat-\(index)"
    var rng = SplitMix(state: UInt64(index) &* 7919)
    return .init(id: id, projectID: "P\(project)", project: "project-\(project)", projectPath: "/tmp/project-\(project)",
                 title: Vocabulary.sentence(&rng, words: 4), agent: "Claude", archived: index % 3 != 0,
                 updated: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 37.123456789),
                 session: AgentSessionReference(connection: .appClaude, nativeID: "native-\(id)"))
}

/// A saved transcript blob as `AppStore` keeps it: dialogue plus capped tool output that the index skips.
func syntheticBlob(_ info: ChatSearchIndex.ChatInfo, messages: Int, rng: inout SplitMix) throws -> Data {
    var items: [TranscriptItem] = []
    for position in 0..<messages {
        let user = position % 2 == 0
        let text = Vocabulary.sentence(&rng, words: user ? Int.random(in: 6...40, using: &rng) : Int.random(in: 30...120, using: &rng))
        items.append(TranscriptItem(id: "item-\(position)", kind: user ? "user" : "assistant", text: text))
        if position % 4 == 1 {
            items.append(TranscriptItem(id: "tool-\(position)", kind: "tool", text: String(repeating: "tool output line\n", count: 120)))
        }
    }
    let snapshot = try LocalHistory.snapshot(conversation: ConversationID(info.id), source: info.session!, items: items)
    return try JSONEncoder().encode(snapshot)
}

// MARK: Raw SQLite for query variants (separate read-only connection to the bench copy)

final class RawDB {
    let db: OpaquePointer
    init(_ path: String, readOnly: Bool = true) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else { throw NSError(domain: "sqlite", code: 1) }
        db = handle
    }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"; sqlite3_free(error)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    /// Steps every row and returns the column values as strings (only counts and ids leave the probe).
    @discardableResult func rows(_ sql: String, _ binds: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "sqlite", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in binds.enumerated() { _ = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) } }
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return out
    }
    func scalar(_ sql: String, _ binds: [String] = []) throws -> Int { Int(try rows(sql, binds).first?.first ?? "0") ?? 0 }
}

// MARK: Query sets

let queries: [String: [String]] = [
    "1-char": ["a", "s", "t", "п", "к"],
    "3-char": ["arc", "bui", "ind", "про", "фай"],
    "10-char": ["background", "transcript", "performanc", "синхрониза", "приложение"],
    "2-words": ["background index", "поиск архив"],
]
let typed = "background index"
func keystrokePrefixes(_ text: String) -> [String] {
    var seen = Set<String>()
    return (1...text.count).map { String(text.prefix($0)) }.filter { seen.insert($0.trimmingCharacters(in: .whitespaces)).inserted }
}

/// The index's own query plus variants that a fix could use, timed on a separate read-only connection.
func ftsVariants(path: String, report: Report, prefix: String, repeats: Int) throws {
    let raw = try RawDB(path)
    var counts: [String: Int] = [:]
    var byVariant: [String: [String: Stats]] = [:]
    for (bucket, words) in queries.sorted(by: { $0.key < $1.key }) {
        var current: [Double] = [], noSnippet: [Double] = [], twoPhase: [Double] = [], countOnly: [Double] = []
        var extra: [String: [Double]] = [:]
        for word in words {
            guard let match = ChatSearchIndex.matchQuery(word) else { continue }
            counts[word] = try raw.scalar("SELECT count(*) FROM messages WHERE messages MATCH ?", [match])
            for _ in 0..<repeats {
                var t = now()
                try raw.rows("SELECT chat_id, snippet(messages, 4, '', '', '…', 12) FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000", [match])
                current.append(ms(t))
                t = now()
                let ids = try raw.rows("SELECT rowid, chat_id FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000", [match])
                noSnippet.append(ms(t))
                // Fix candidate: rank without snippets, keep the best row per chat, then snippet only those rows.
                t = now()
                var seen = Set<String>(), best: [String] = []
                for row in try raw.rows("SELECT rowid, chat_id FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000", [match])
                    where best.count < 40 && seen.insert(row[1]).inserted { best.append(row[0]) }
                if !best.isEmpty {
                    try raw.rows("SELECT chat_id, snippet(messages, 4, '', '', '…', 12) FROM messages WHERE messages MATCH ? AND rowid IN (\(best.joined(separator: ",")))", [match])
                }
                twoPhase.append(ms(t))
                // Fix candidate: rank without snippets, keep the best row per chat, fetch only their text by rowid
                // (no MATCH) and cut the snippet in Swift around the first query word.
                for (limit, bucketName) in [(40, "rank_then_text_40"), (300, "rank_then_text_300")] {
                    t = now()
                    var seenChats = Set<String>(), rowids: [String] = []
                    for row in try raw.rows("SELECT rowid, chat_id FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000", [match])
                        where rowids.count < limit && seenChats.insert(row[1]).inserted { rowids.append(row[0]) }
                    if !rowids.isEmpty {
                        let needle = word.split(separator: " ").first.map(String.init) ?? word
                        for row in try raw.rows("SELECT text FROM messages WHERE rowid IN (\(rowids.joined(separator: ",")))") {
                            let text = row[0]
                            let hit = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound ?? text.startIndex
                            let from = text.index(hit, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                            let to = text.index(hit, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
                            _ = text[from..<to]
                        }
                    }
                    extra[bucketName, default: []].append(ms(t))
                }
                // Fix candidate for 1-2 letter queries: newest rows first, no bm25 over every match.
                t = now()
                try raw.rows("SELECT rowid, chat_id FROM messages WHERE messages MATCH ? ORDER BY rowid DESC LIMIT 3000", [match])
                extra["recency_no_bm25_no_snippet", default: []].append(ms(t))
                t = now()
                _ = try raw.scalar("SELECT count(*) FROM messages WHERE messages MATCH ?", [match])
                countOnly.append(ms(t))
                _ = ids
            }
        }
        byVariant[bucket] = ["current_sql": Stats(current), "no_snippet": Stats(noSnippet), "two_phase_40": Stats(twoPhase),
                             "match_count_only": Stats(countOnly)].merging(extra.mapValues(Stats.init)) { first, _ in first }
    }
    report.put(prefix + ".fts_variants", byVariant)
    report.put(prefix + ".match_rows_per_query", counts)
}

/// Rebuilds the FTS table with a prefix index into a scratch copy and times the same short queries there.
func prefixIndexVariant(source: String, scratch: URL, report: Report, prefix: String, repeats: Int) throws {
    try? FileManager.default.removeItem(at: scratch)
    let raw = try RawDB(scratch.path, readOnly: false)
    try raw.exec("PRAGMA journal_mode=WAL")
    try raw.exec("ATTACH DATABASE 'file:\(source)?mode=ro' AS src")
    var t = now()
    try raw.exec("""
        CREATE VIRTUAL TABLE messages USING fts5(chat_id UNINDEXED, position UNINDEXED, role UNINDEXED, date UNINDEXED, text,
            tokenize='unicode61 remove_diacritics 2', prefix='1 2 3');
        INSERT INTO messages (rowid, chat_id, position, role, date, text) SELECT rowid, chat_id, position, role, date, text FROM src.messages;
        """)
    let build = ms(t)
    try raw.exec("DETACH DATABASE src")
    try raw.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    let size = (try? FileManager.default.attributesOfItem(atPath: scratch.path)[.size] as? Int) ?? 0
    var results: [String: Stats] = [:]
    for (bucket, words) in queries.sorted(by: { $0.key < $1.key }) {
        var samples: [Double] = []
        for word in words {
            guard let match = ChatSearchIndex.matchQuery(word) else { continue }
            for _ in 0..<repeats {
                t = now()
                try raw.rows("SELECT chat_id, snippet(messages, 4, '', '', '…', 12) FROM messages WHERE messages MATCH ? ORDER BY bm25(messages) LIMIT 3000", [match])
                samples.append(ms(t))
            }
        }
        results[bucket] = Stats(samples)
    }
    report.put(prefix + ".prefix_index_variant", ["rebuild_fts_only_ms": build, "file_mb": Double(size) / 1_048_576, "current_sql": results])
    try? FileManager.default.removeItem(at: scratch)
}

/// The real actor API, as the archive (limit 300) and the palette (limit 40) call it.
func actorQueries(_ index: ChatSearchIndex, report: Report, prefix: String, repeats: Int) async throws {
    _ = try await index.search("warmup")
    var buckets: [String: [String: Stats]] = [:]
    for (bucket, words) in queries.sorted(by: { $0.key < $1.key }) {
        var archive: [Double] = [], palette: [Double] = [], hits: [Int] = []
        for word in words {
            var cold = true
            for _ in 0..<repeats {
                var t = now()
                let result = try await index.search(word)
                archive.append(ms(t))
                if cold { hits.append(result.count); cold = false }
                t = now(); _ = try await index.search(word, limit: 40); palette.append(ms(t))
            }
        }
        buckets[bucket] = ["archive_limit300": Stats(archive), "palette_limit40": Stats(palette)]
        report.put(prefix + ".hits_" + bucket, hits)
    }
    report.put(prefix + ".search", buckets)
    // Typing "background index" without pauses: one archive search per keystroke (what a 250 ms debounce avoids).
    var sequence: [[String: Any]] = []
    var total = 0.0
    for text in keystrokePrefixes(typed) {
        var samples: [Double] = []
        for _ in 0..<max(3, repeats / 4) { let t = now(); _ = try await index.search(text); samples.append(ms(t)) }
        let stats = Stats(samples); total += stats.p50
        sequence.append(["query_len": text.count, "p50_ms": stats.p50, "p95_ms": stats.p95])
    }
    report.put(prefix + ".keystrokes_archive", ["per_prefix": sequence, "sum_p50_ms": total])
}

/// Archive and palette searches issued while the index is busy re-indexing one large chat: they wait on the actor.
func searchDuringReindex(_ index: ChatSearchIndex, chat: (ChatSearchIndex.ChatInfo, Data), report: Report, prefix: String) async throws {
    let started = now()
    let writer = Task { try await index.index([(info: chat.0, transcript: chat.1)]) }
    try await Task.sleep(for: .milliseconds(5))
    let t = now()
    _ = try await index.search("background")
    let waited = ms(t)
    try await writer.value
    report.put(prefix + ".search_while_reindexing", ["reindex_ms": ms(started), "search_latency_ms": waited])
}

// MARK: In-memory filters (run on the main actor in the app)

func sidebarBody(_ state: SavedState, search: String) -> Int {
    // DeskView.sidebar and projectEntries: favorites filter, project filter, then per shown project its ordered
    // chats filtered, plus the per-project badge scans at DeskView.swift:372 and :423.
    var rows = state.visiblePinnedChats.filter { state.sidebarShowsFavorite($0, search: search) }.count
    for project in state.visibleProjects.filter({ state.sidebarShowsProject($0, search: search) }) {
        rows += state.orderedChats(projectID: project.id, archived: false).filter { state.sidebarShowsChat($0, in: project, search: search) }.count
        _ = state.chats.filter { $0.projectID == project.id && !$0.isArchived }.contains(where: \.hasUnreadResponse)
        _ = state.chats.allSatisfy { $0.projectID != project.id || $0.isArchived }
    }
    return rows
}

func paletteSections(_ state: SavedState, query: String) -> Int {
    // CommandPalette.sections without the actions list (CommandPaletteView.swift:172-219).
    let hidden = Set(state.projects.filter(\.isHidden).map(\.id))
    let projects = Dictionary(state.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let active = state.chats.filter { !$0.isArchived && !hidden.contains($0.projectID) }
    _ = Dictionary(state.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let chats = PaletteSearch.rank(active.map { PaletteSearch.Candidate(id: $0.id, title: $0.title, detail: projects[$0.projectID]?.name ?? "", recency: $0.updated) },
                                   query: query, limit: 8)
    let lastActivity = Dictionary(active.map { ($0.projectID, $0.updated) }, uniquingKeysWith: { max($0, $1) })
    let found = PaletteSearch.rank(state.visibleProjects.map { PaletteSearch.Candidate(id: $0.id, title: $0.name, detail: $0.path, recency: lastActivity[$0.id]) },
                                   query: query, limit: 6)
    return chats.count + found.count
}

func archiveListing(_ state: SavedState, search: String) -> Int {
    // ArchiveView.listing (ArchiveView.swift:32-54), copied because ContextDesk is an executable module.
    var total = 0
    for project in state.projects {
        let archived = state.orderedChats(projectID: project.id, archived: true)
        let projectMatches = search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search)
        func matches(_ chat: Chat) -> Bool { projectMatches || chat.title.localizedCaseInsensitiveContains(search) }
        total += archived.filter(matches).count
        if !search.isEmpty {
            total += state.orderedChats(projectID: project.id, archived: false).filter { !$0.isScheduledRecord && $0.chatSearch != true && matches($0) }.count
        }
    }
    return total
}

func timeFilters(_ state: SavedState, report: Report, prefix: String, repeats: Int) {
    var result: [String: Any] = ["chats": state.chats.count, "projects": state.projects.count,
                                 "active_chats": state.chats.count(where: { !$0.isArchived })]
    for (name, body) in [("sidebar_body", sidebarBody), ("palette_sections", paletteSections), ("archive_listing", archiveListing)] as [(String, (SavedState, String) -> Int)] {
        var perPrefix: [[String: Any]] = []
        var all: [Double] = []
        for text in [""] + keystrokePrefixes(typed) {
            var samples: [Double] = []
            for _ in 0..<repeats { let t = now(); _ = body(state, text); samples.append(ms(t)) }
            let stats = Stats(samples); all += samples
            perPrefix.append(["query_len": text.count, "p50_ms": stats.p50, "p95_ms": stats.p95])
        }
        result[name] = ["all_keystrokes": Stats(all), "per_prefix": perPrefix]
    }
    var sequence: [Double] = []
    for _ in 0..<repeats {
        var listing = SidebarListing()
        let t = now()
        for text in keystrokePrefixes(typed) { listing.search = text; _ = state.sidebarChatRows(listing) }
        sequence.append(ms(t) / Double(keystrokePrefixes(typed).count))
    }
    result["sidebarChatRows_per_keystroke"] = Stats(sequence)
    report.put(prefix + ".filters", result)
}

func syntheticState(projects: Int, chats: Int, rng: inout SplitMix) -> SavedState {
    var state = SavedState()
    state.projects = (0..<projects).map { Project(path: "/tmp/synthetic/project-\($0)-" + Vocabulary.rareWord(&rng)) }
    state.chats = (0..<chats).map { index in
        var chat = Chat(id: "chat-\(index)", projectID: state.projects[index % projects].id,
                        title: Vocabulary.sentence(&rng, words: Int.random(in: 3...8, using: &rng)), model: "m")
        chat.archived = index % 4 != 0 ? true : nil
        chat.pinned = index % 50 == 0 ? true : nil
        chat.updated = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        return chat
    }
    return state
}

func projectFileSearch(report: Report, repeats: Int, repoPaths: [String]) {
    var rng = SplitMix(state: 7)
    let synthetic = (0..<ProjectFiles.limit).map { index in
        (0..<Int.random(in: 1...6, using: &rng)).map { _ in Vocabulary.rareWord(&rng) }.joined(separator: "/") + "/file\(index).swift"
    }
    var result: [String: Any] = [:]
    for (name, paths) in [("synthetic_50k", synthetic), ("this_repo", repoPaths)] {
        var perPrefix: [[String: Any]] = []
        var all: [Double] = []
        for text in keystrokePrefixes("chatsearchindex") {
            var samples: [Double] = []
            for _ in 0..<repeats { let t = now(); _ = ProjectFiles.search(text, in: paths); samples.append(ms(t)) }
            all += samples
            let stats = Stats(samples)
            perPrefix.append(["query_len": text.count, "p50_ms": stats.p50, "p95_ms": stats.p95])
        }
        result[name] = ["paths": paths.count, "all_keystrokes": Stats(all), "per_prefix": perPrefix]
    }
    var treeSamples: [Double] = []
    for _ in 0..<3 { let t = now(); _ = ProjectFiles.tree(synthetic); treeSamples.append(ms(t)) }
    result["tree_build_50k"] = Stats(treeSamples)
    report.put("project_files", result)
}

/// Find-in-chat proxy: NSTextFinder's incremental search scans the transcript's full string per keystroke.
func findInTranscriptProxy(texts: [String], report: Report, repeats: Int) {
    let joined = texts.joined(separator: "\n\n") as NSString
    var result: [String: Any] = ["chars": joined.length]
    for word in ["a", "ind", "background"] {
        var samples: [Double] = []
        var count = 0
        for _ in 0..<repeats {
            let t = now()
            count = 0
            var range = NSRange(location: 0, length: joined.length)
            while true {
                let found = joined.range(of: word, options: [.caseInsensitive], range: range)
                if found.location == NSNotFound { break }
                count += 1
                range = NSRange(location: found.upperBound, length: joined.length - found.upperBound)
            }
            samples.append(ms(t))
        }
        result[word] = ["matches": count, "scan": Stats(samples)]
    }
    report.put("find_in_transcript_proxy", result)
}

// MARK: Runs

func synthetic(report: Report, root: URL, chats: Int, messages: Int, repeats: Int) async throws -> [String] {
    log("Synthetic corpus: \(chats) chats x \(messages) messages")
    var rng = SplitMix(state: 42)
    let infos = (0..<chats).map { syntheticInfo($0, project: $0 % 25) }
    var t = now()
    var blobs: [String: Data] = [:]
    for info in infos { blobs[info.id] = try syntheticBlob(info, messages: messages, rng: &rng) }
    let blobBytes = blobs.values.reduce(0) { $0 + $1.count }
    report.put("synthetic.corpus", ["chats": chats, "messages_per_chat": messages, "blob_mb": Double(blobBytes) / 1_048_576, "generate_ms": ms(t)])

    let file = root.appendingPathComponent("synthetic-" + ChatSearchIndex.fileName)
    let index = ChatSearchIndex(file: file)
    let before = footprintMB()
    var batches: [Double] = []
    t = now()
    let plan = try await index.plan(infos)
    let planMs = ms(t)
    for start in stride(from: 0, to: plan.content.count, by: 8) {
        let batch = Array(plan.content[start..<min(start + 8, plan.content.count)])
        let b = now()
        try await index.index(batch.map { id in (info: infos.first { $0.id == id }!, transcript: blobs[id]) })
        batches.append(ms(b))
    }
    let build = ms(t)
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    let wal = (try? FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? Int) ?? 0
    report.put("synthetic.build", ["plan_empty_index_ms": planMs, "total_ms": build, "batch_of_8": Stats(batches),
                                   "file_plus_wal_mb": Double(size + wal) / 1_048_576,
                                   "footprint_before_mb": before, "footprint_after_mb": footprintMB()])

    var planSamples: [Double] = []
    for _ in 0..<10 { let p = now(); _ = try await index.plan(infos); planSamples.append(ms(p)) }
    report.put("synthetic.plan_unchanged", Stats(planSamples))
    var one = infos[0]; one.updated = one.updated.addingTimeInterval(1)
    t = now(); try await index.index([(info: one, transcript: blobs[one.id])])
    report.put("synthetic.reindex_one_chat_ms", ms(t))
    var renamed = infos[1]; renamed.title += " renamed"
    t = now(); try await index.updateMetadata([renamed])
    report.put("synthetic.update_metadata_one_ms", ms(t))
    // A long active chat (2000 messages), re-read in full after every turn because `updated` changed.
    var big = syntheticInfo(chats + 1, project: 0); big.archived = false
    let bigBlob = try syntheticBlob(big, messages: 2000, rng: &rng)
    t = now(); try await index.index([(info: big, transcript: bigBlob)])
    report.put("synthetic.reindex_2000_message_chat", ["blob_mb": Double(bigBlob.count) / 1_048_576, "ms": ms(t)])

    try await actorQueries(index, report: report, prefix: "synthetic", repeats: repeats)
    try await searchDuringReindex(index, chat: (big, bigBlob), report: report, prefix: "synthetic")
    try ftsVariants(path: file.path, report: report, prefix: "synthetic", repeats: max(3, repeats / 2))
    try prefixIndexVariant(source: file.path, scratch: root.appendingPathComponent("prefix-variant.sqlite"), report: report,
                           prefix: "synthetic", repeats: max(3, repeats / 2))

    let snapshotTexts = try JSONDecoder().decode(AgentTranscriptSnapshot.self, from: bigBlob).items.map(\.text)
    findInTranscriptProxy(texts: snapshotTexts, report: report, repeats: repeats)

    var stateRng = SplitMix(state: 9)
    timeFilters(syntheticState(projects: 25, chats: 800, rng: &stateRng), report: report, prefix: "synthetic_state_800", repeats: repeats)
    timeFilters(syntheticState(projects: 60, chats: 3000, rng: &stateRng), report: report, prefix: "synthetic_state_3000", repeats: max(3, repeats / 2))
    return []
}

/// Same steps against copies of the user's databases; only counts and timings are recorded.
func real(report: Report, directory: URL, root: URL, repeats: Int) async throws {
    let indexCopy = directory.appendingPathComponent(ChatSearchIndex.fileName)
    let storeCopy = directory.appendingPathComponent("metadata.sqlite")
    log("Real copy: \(directory.path)")
    if FileManager.default.fileExists(atPath: indexCopy.path) {
        let raw = try RawDB(indexCopy.path)
        let stats: [String: Any] = [
            "chats": try raw.scalar("SELECT count(*) FROM chats"),
            "fts_rows": try raw.scalar("SELECT count(*) FROM messages"),
            "message_rows": try raw.scalar("SELECT count(*) FROM message_rows"),
            "text_mb": Double(try raw.scalar("SELECT sum(length(text)) FROM messages")) / 1_048_576,
            "schema": try raw.rows("SELECT value FROM meta WHERE key='schema'").first?.first ?? "?",
            "file_mb": Double((try FileManager.default.attributesOfItem(atPath: indexCopy.path)[.size] as? Int) ?? 0) / 1_048_576,
            "freelist_pages": try raw.scalar("PRAGMA freelist_count"),
            "page_count": try raw.scalar("PRAGMA page_count"),
        ]
        report.put("real_index.stats", stats)
        let index = ChatSearchIndex(file: indexCopy)
        try await actorQueries(index, report: report, prefix: "real_index", repeats: repeats)
        try ftsVariants(path: indexCopy.path, report: report, prefix: "real_index", repeats: max(3, repeats / 2))
        try prefixIndexVariant(source: indexCopy.path, scratch: root.appendingPathComponent("real-prefix-variant.sqlite"), report: report,
                               prefix: "real_index", repeats: max(3, repeats / 2))
    }
    guard FileManager.default.fileExists(atPath: storeCopy.path) else { return }
    let store = AppStore(file: storeCopy)
    var t = now()
    let state = try await store.load()
    let summaries = (try? await store.loadArchiveSummaries()) ?? [:]
    report.put("real_store.load", ["state_load_ms": ms(t), "chats": state.chats.count, "projects": state.projects.count, "summaries": summaries.count])

    // DeskModel.chatSearchInfos (ChatSearch.swift:13-24) runs on the main actor every 15 s, then compares with the memo.
    func infos() -> [ChatSearchIndex.ChatInfo] {
        let projects = Dictionary(state.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return state.chats.compactMap { chat in
            guard !chat.isScheduledRecord, chat.chatSearch != true, let project = projects[chat.projectID] else { return nil }
            let summary = summaries[chat.id].flatMap { record in
                record.status == .ready ? record.parts.flatMap { [$0.content.overview] + $0.content.activities.map(\.goal) }.joined(separator: "\n") : nil
            } ?? ""
            return .init(id: chat.id, projectID: project.id.uuidString, project: project.name, projectPath: project.path, title: chat.title,
                         agent: chat.nativeSession?.connection.agent.rawValue ?? "", archived: chat.isArchived,
                         updated: chat.updated, summary: summary, session: chat.nativeSession)
        }
    }
    var tick: [Double] = []
    var memo = infos()
    for _ in 0..<repeats { let s = now(); let fresh = infos(); _ = fresh != memo; memo = fresh; tick.append(ms(s)) }
    report.put("real_store.chatSearchInfos_and_compare_main_actor", Stats(tick))
    timeFilters(state, report: report, prefix: "real_state", repeats: repeats)

    // Full rebuild into a fresh index, as after a schema bump or a deleted index file.
    let rebuilt = ChatSearchIndex(file: root.appendingPathComponent("real-rebuild-" + ChatSearchIndex.fileName))
    let list = infos()
    let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let before = footprintMB()
    var peak = before
    t = now()
    let plan = try await rebuilt.plan(list)
    var fetch: [Double] = [], insert: [Double] = [], largest: (bytes: Int, ms: Double) = (0, 0)
    var blobBytes = 0
    for start in stride(from: 0, to: plan.content.count, by: 8) {
        let batch = Array(plan.content[start..<min(start + 8, plan.content.count)])
        var b = now()
        let blobs = try await store.transcriptBlobs(conversationIDs: batch)
        fetch.append(ms(b))
        let bytes = blobs.values.reduce(0) { $0 + $1.count }; blobBytes += bytes
        b = now()
        try await rebuilt.index(batch.compactMap { id in byID[id].map { ($0, blobs[id]) } })
        let took = ms(b); insert.append(took)
        if bytes > largest.bytes { largest = (bytes, took) }
        peak = max(peak, footprintMB())
    }
    let total = ms(t)
    let size = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("real-rebuild-" + ChatSearchIndex.fileName).path)[.size] as? Int) ?? 0
    report.put("real_store.full_rebuild", ["chats": plan.content.count, "total_ms": total, "blob_mb_read": Double(blobBytes) / 1_048_576,
                                          "fetch_batch_of_8": Stats(fetch), "index_batch_of_8": Stats(insert),
                                          "largest_batch_mb": Double(largest.bytes) / 1_048_576, "largest_batch_index_ms": largest.ms,
                                          "footprint_before_mb": before, "footprint_peak_mb": peak, "index_file_mb": Double(size) / 1_048_576])

    // Per-turn upkeep: re-reading the largest non-archived chat in full (what happens after each finished turn).
    let activeIDs = list.filter { !$0.archived }.map(\.id)
    var sizes: [(String, Int)] = []
    for start in stride(from: 0, to: activeIDs.count, by: 16) {
        let batch = Array(activeIDs[start..<min(start + 16, activeIDs.count)])
        for (id, data) in try await store.transcriptBlobs(conversationIDs: batch) { sizes.append((id, data.count)) }
    }
    sizes.sort { $0.1 > $1.1 }
    var upkeep: [[String: Any]] = []
    for (id, bytes) in sizes.prefix(3) {
        guard var info = byID[id] else { continue }
        info.updated = info.updated.addingTimeInterval(1)
        let blob = try await store.transcriptBlobs(conversationIDs: [id])
        let s = now(); try await rebuilt.index([(info: info, transcript: blob[id])]); let took = ms(s)
        let decoded = ChatSearchIndex.messages(blob[id], info: info, decoder: JSONDecoder()).count
        upkeep.append(["blob_mb": Double(bytes) / 1_048_576, "dialogue_messages": decoded, "reindex_ms": took])
    }
    report.put("real_store.reindex_largest_active_chats", upkeep)
}

@main struct SearchProbe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["SEARCH_PROBE_REPORT"] else { log("SEARCH_PROBE_REPORT is not set"); exit(2) }
        let chats = Int(env["SEARCH_PROBE_CHATS"] ?? "") ?? 500
        let messages = Int(env["SEARCH_PROBE_MESSAGES"] ?? "") ?? 200
        let repeats = Int(env["SEARCH_PROBE_REPEATS"] ?? "") ?? 20
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-probe-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = Report()
        report.put("environment", ["chats": chats, "messages": messages, "repeats": repeats, "sqlite": String(cString: sqlite3_libversion())])
        do {
            if env["SEARCH_PROBE_SKIP_SYNTHETIC"] == nil {
                _ = try await synthetic(report: report, root: root, chats: chats, messages: messages, repeats: repeats)
                let repoPaths = (env["SEARCH_PROBE_REPO_PATHS"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
                    .split(separator: "\n").map(String.init)
                projectFileSearch(report: report, repeats: repeats, repoPaths: repoPaths)
            }
            if let directory = env["SEARCH_PROBE_REAL_DIR"] {
                try await real(report: report, directory: URL(fileURLWithPath: directory), root: root, repeats: repeats)
            }
            try report.json().write(to: URL(fileURLWithPath: output))
            log("Report: \(output)")
        } catch {
            log("Search probe failed: \(error)")
            try? report.json().write(to: URL(fileURLWithPath: output))
            exit(1)
        }
    }
}
