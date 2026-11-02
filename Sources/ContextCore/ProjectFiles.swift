import Foundation

/// A project's files for the file tree: git's view (tracked and untracked, without ignored files) inside a
/// repository, otherwise a bounded walk that skips hidden and build folders. Read-only; nothing is written.
public enum ProjectFiles {
    public struct Listing: Equatable, Sendable {
        /// Paths relative to the root, `/`-separated.
        public var paths: [String]
        /// More files exist than `limit`; the rest are not listed.
        public var truncated: Bool
        public init(paths: [String], truncated: Bool) { self.paths = paths; self.truncated = truncated }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The home folder or `/`: too large to list, and not a project.
        case tooBroad
        case unreadable(String)
    }

    public static let limit = 50_000
    /// Skipped by the walk outside git; inside a repository `.gitignore` decides.
    public static let skippedFolders: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "dist",
                                                     "target", "venv", ".venv", "__pycache__", ".git"]

    public static func list(root: String, git: GitRunner = GitRunner(timeout: 15), limit: Int = limit) async throws(Failure) -> Listing {
        let url = URL(fileURLWithPath: root).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.path != "/", url.path != home.path else { throw .tooBroad }
        if let listed = try? await git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: url.path),
           listed.succeeded {
            let deleted = (try? await git.run(["ls-files", "-z", "--deleted"], in: url.path)).flatMap { $0.succeeded ? $0.output : nil }
            let gone = Set(split(deleted ?? Data()))
            // Unmerged files appear once per stage.
            var seen = Set<String>()
            let paths = split(listed.output).filter { !gone.contains($0) && seen.insert($0).inserted }
            return Listing(paths: Array(paths.prefix(limit)), truncated: paths.count > limit)
        }
        return try walk(url, limit: limit)
    }

    static func split(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }

    static func walk(_ root: URL, limit: Int) throws(Failure) -> Listing {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw .unreadable(root.path)
        }
        let base = root.pathComponents.count
        var paths: [String] = []
        while let item = walker.nextObject() as? URL {
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if directory {
                if skippedFolders.contains(item.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if paths.count == limit { return Listing(paths: paths, truncated: true) }
            paths.append(item.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/"))
        }
        return Listing(paths: paths, truncated: false)
    }

    /// One row of the tree.
    public struct Node: Identifiable, Hashable, Sendable {
        public let path: String
        public let name: String
        /// Nil for a file.
        public var children: [Node]?
        public var id: String { path }
        public var isFolder: Bool { children != nil }
    }

    /// Folders first, then files, each in Finder order.
    public static func tree(_ paths: [String]) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [String] = []
        }
        let root = Folder()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard let file = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() {
                if let next = folder.folders[part] { folder = next } else {
                    let next = Folder(); folder.folders[part] = next; folder = next
                }
            }
            folder.files.append(file)
        }
        func ordered(_ names: some Sequence<String>) -> [String] {
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        func nodes(_ folder: Folder, prefix: String) -> [Node] {
            ordered(folder.folders.keys).map { name in
                Node(path: prefix + name, name: name, children: nodes(folder.folders[name]!, prefix: prefix + name + "/"))
            } + ordered(folder.files).map { Node(path: prefix + $0, name: $0, children: nil) }
        }
        return nodes(root, prefix: "")
    }

    /// A visible row: the node and its depth, for a flat list that keeps expansion in the caller's hands.
    public struct Row: Identifiable, Hashable, Sendable {
        public let node: Node
        public let depth: Int
        public var id: String { node.path }
    }

    public static func rows(_ nodes: [Node], expanded: Set<String>, depth: Int = 0) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let row = Row(node: node, depth: depth)
            guard let children = node.children, expanded.contains(node.path) else { return [row] }
            return [row] + rows(children, expanded: expanded, depth: depth + 1)
        }
    }

    /// Paths matching every word of `query` (case-insensitive), best first: the whole file name without its
    /// extension, a file-name prefix, anywhere in the file name, then the folder part; shorter paths win ties.
    public static func search(_ query: String, in paths: [String], limit: Int = 200) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, path: String)] = []
        for path in paths {
            let lower = path.lowercased()
            guard words.allSatisfy({ lower.contains($0) }) else { continue }
            let name = lower.split(separator: "/").last.map(String.init) ?? lower
            let stem = (name as NSString).deletingPathExtension
            let score = words.reduce(0) { total, word in
                total + (stem == word ? 0 : name.hasPrefix(word) ? 1 : name.contains(word) ? 2 : 3)
            }
            scored.append((score, path))
        }
        return scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.path.count != $1.path.count ? $0.path.count < $1.path.count : $0.path < $1.path }
            .prefix(limit).map(\.path)
    }

    /// The folders that hold `path`, for revealing a file in the tree.
    public static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }
}
