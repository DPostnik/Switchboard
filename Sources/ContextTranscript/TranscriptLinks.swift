import AppKit
import ContextCore
import Foundation
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Rounded background behind inline code and link chips; value is `TranscriptLinks.Chip`.
    static let inlineChip = NSAttributedString.Key("ContextDeskInlineChip")
    /// Line number of a file reference such as `View.swift:42`.
    static let fileLine = NSAttributedString.Key("ContextDeskFileLine")
}

/// Link parsing produces data only; opening is handled exclusively by a user click.
@MainActor public enum TranscriptLinks {
    enum Chip: Int { case code, file, web }

    /// `switchboard-chat:<chat id>` links, written by the chat-search agent, open that chat in the app.
    public static let chatScheme = "switchboard-chat"
    /// Set by the app; without it chat links stay plain text.
    public static var openChat: ((String) -> Void)?

    /// How agent text is decorated in the transcript. Defaults keep the literal text.
    public struct Options {
        /// File links get an icon and a compact name; long bare URLs are shortened to their host.
        public var chips = false
        /// Relative paths in prose and inline code resolve against this directory.
        public var baseDirectory: URL?
        public var fileExists: @MainActor (String) -> Bool = { TranscriptLinks.cachedFileExists($0) }
        /// The document being shown, if any: `[[wiki links]]` resolve from it.
        public var source: URL?
        /// Bare URLs longer than this show as host and first path segments.
        public var urlDisplayLimit = 48
        public init(chips: Bool = false, baseDirectory: URL? = nil, source: URL? = nil) {
            self.chips = chips; self.baseDirectory = baseDirectory; self.source = source
        }

        /// Vault lookup for `[[page]]`; the index is built only when a wiki link appears.
        func resolveWiki(_ target: String) -> URL? {
            guard let anchor = source ?? baseDirectory.map({ $0.appendingPathComponent(".", isDirectory: true) }) else { return nil }
            return WikiIndex.shared(for: anchor)?.resolve(target, from: source)
        }
    }

    public static func destination(_ value: String) -> URL? {
        if value.hasPrefix("/") {
            // Source references may include a line and optional column suffix.
            let path = value.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
            return URL(fileURLWithPath: path)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        case chatScheme: return openChat != nil && !(url.absoluteString.dropFirst(chatScheme.count + 1)).isEmpty ? url : nil
        case "file": return url.host == nil || url.host == "" || url.host == "localhost" ? url : nil
        default: return nil
        }
    }

    /// `:line` or `:line:column` of a source reference, if present.
    static func lineSuffix(_ value: String) -> String? {
        value.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression).map { String(value[$0]) }
    }

    /// An existing file named by an absolute or project-relative path, with an optional `:line` suffix.
    /// `explicit` marks a Markdown link target, where a bare file name is clearly meant as a path.
    static func fileReference(_ text: String, options: Options, explicit: Bool = false) -> (url: URL, line: String?)? {
        var path = text.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains(" ") || path.hasPrefix("/"), !path.contains("://") else { return nil }
        var anchor: String?
        if let hash = path.firstIndex(of: "#"), hash != path.startIndex {
            anchor = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }
        let line = lineSuffix(path)
        if let line { path.removeLast(line.count) }
        if path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1) }
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let base = options.baseDirectory, path.contains("/") || line != nil || explicit {
            url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        } else { return nil }
        guard url.path.count > 1, options.fileExists(url.path) else { return nil }
        return (withAnchor(url, anchor), line)
    }

    /// A file URL carrying a heading anchor as its fragment.
    static func withAnchor(_ url: URL, _ anchor: String?) -> URL {
        guard let anchor, !anchor.isEmpty,
              let encoded = (anchor.removingPercentEncoding ?? anchor).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
              let anchored = URL(string: url.absoluteString + "#" + encoded) else { return url }
        return anchored
    }

    /// GitHub-style heading slug, used to match `#anchor` links in either spelling.
    public static func slug(_ text: String) -> String {
        let decoded = (text.removingPercentEncoding ?? text).lowercased()
        var result = ""
        for character in decoded {
            if character.isLetter || character.isNumber || character == "_" || character == "-" { result.append(character) }
            else if character == " " { result.append("-") }
        }
        return result
    }

    private static let inlineHTML: [(NSRegularExpression?, String)] = [
        (try? NSRegularExpression(pattern: #"<!--.*?-->"#, options: [.dotMatchesLineSeparators]), ""),
        (try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]), "\n"),
        (try? NSRegularExpression(pattern: #"<(b|strong)>(.+?)</\1>"#, options: [.caseInsensitive]), "**$2**"),
        (try? NSRegularExpression(pattern: #"<(i|em)>(.+?)</\1>"#, options: [.caseInsensitive]), "*$2*"),
        (try? NSRegularExpression(pattern: #"<code>(.+?)</code>"#, options: [.caseInsensitive]), "`$1`"),
    ]
    private static let wikiLink = try? NSRegularExpression(pattern: #"!?\[\[([^\[\]\n]+?)\]\]"#)

    /// Simple inline HTML and `[[wiki links]]` become Markdown before parsing; other HTML stays literal text.
    static func prepare(_ text: String) -> String {
        var text = text
        if text.contains("<") {
            for (expression, template) in inlineHTML {
                guard let expression else { continue }
                text = expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
            }
        }
        guard text.contains("[["), let wikiLink else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in wikiLink.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            // Leave links inside inline code literal.
            let before = source.substring(to: match.range.location)
            if before.filter({ $0 == "`" }).count % 2 == 1 { continue }
            let inner = source.substring(with: match.range(at: 1)).replacingOccurrences(of: "\\|", with: "|")
            let parts = WikiIndex.parse(inner)
            var title = parts.alias ?? (parts.target.isEmpty ? (parts.anchor ?? inner) : parts.target)
            if parts.alias == nil, let anchor = parts.anchor, !parts.target.isEmpty { title += " › " + anchor }
            title = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            guard let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
            result.replaceCharacters(in: match.range, with: "[\(title)](contextdesk-wiki:\(encoded))")
        }
        return result as String
    }

    public static func render(_ text: String, attributes: [NSAttributedString.Key: Any], options: Options = Options()) -> NSAttributedString {
        let text = prepare(text)
        // Plain prose needs no Markdown parser; it is the bulk of long documents.
        if !text.contains(where: { "*_`[]<>~\\!&=".contains($0) }), !text.contains("://"), !text.contains("www."), !text.contains("@") {
            let chunk = NSMutableAttributedString(string: text, attributes: attributes)
            if options.chips, text.contains("/"), text.contains(".") { linkPlainPaths(in: chunk, options: options) }
            return chunk
        }
        guard let markdown = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )) else { return NSAttributedString(string: text, attributes: attributes) }
        let result = NSMutableAttributedString()
        let baseFont = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        for run in markdown.runs {
            let content = String(markdown[run.range].characters)
            var style = attributes
            let intent = run.inlinePresentationIntent ?? []
            let isCode = intent.contains(.code)
            var font = baseFont
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            style[.font] = font
            if intent.contains(.strikethrough) { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if isCode {
                style[.font] = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1.5), weight: .regular)
                if options.chips { style[.inlineChip] = Chip.code.rawValue }
            }
            if !isCode, let target = run.link, target.scheme == "contextdesk-wiki" {
                let inner = String(target.absoluteString.dropFirst("contextdesk-wiki:".count)).removingPercentEncoding ?? ""
                let parts = WikiIndex.parse(inner)
                if let url = parts.target.isEmpty ? options.source : options.resolveWiki(parts.target) {
                    result.append(link(content, url: withAnchor(url, parts.anchor), line: nil, style: style, options: options, keepText: true))
                } else {
                    // A page that does not exist (yet) stays readable but quiet.
                    style[.foregroundColor] = NSColor.secondaryLabelColor
                    style[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    style[.toolTip] = L10n.text("Страница не найдена: \(parts.target)", "Page not found: \(parts.target)")
                    result.append(NSAttributedString(string: content, attributes: style))
                }
                continue
            }
            if !isCode, let target = run.link, target.scheme == nil, target.relativeString.hasPrefix("#") {
                style[.link] = "contextdesk-anchor:" + slug(String(target.relativeString.dropFirst()))
                style[.foregroundColor] = NSColor.linkColor
                style[.toolTip] = L10n.text("Перейти к разделу", "Go to section")
                result.append(NSAttributedString(string: content, attributes: style))
                continue
            }
            if !isCode, let target = run.link {
                let raw = target.scheme == nil ? (target.relativeString.removingPercentEncoding ?? target.relativeString) : target.absoluteString
                let file = options.chips && target.scheme == nil ? fileReference(raw, options: options, explicit: true) : nil
                if let url = file?.url ?? destination(raw) {
                    result.append(link(content, url: url, line: file?.line ?? lineSuffix(raw), style: style, options: options))
                    continue
                }
            }
            if isCode, options.chips, let file = fileReference(content, options: options) {
                // Paths in inline code are the most common way agents cite files.
                result.append(link(content, url: file.url, line: file.line, style: style, options: options, keepText: true))
                continue
            }
            let chunk = NSMutableAttributedString(string: content, attributes: style)
            // Cheap checks first: most runs hold no URL, path, highlight or footnote.
            if !isCode, let detector = Self.detector,
               content.contains("://") || content.contains("www.") || content.contains("@") {
                let range = NSRange(location: 0, length: chunk.length)
                for match in detector.matches(in: content, range: range).reversed() {
                    guard let target = match.url, let url = destination(target.absoluteString) else { continue }
                    let shown = (content as NSString).substring(with: match.range)
                    chunk.replaceCharacters(in: match.range, with: link(shown, url: url, line: nil, style: style, options: options))
                }
            }
            if !isCode {
                if options.chips, content.contains("/"), content.contains(".") { linkPlainPaths(in: chunk, options: options) }
                if content.contains("==") || content.contains("[^") { decorate(chunk) }
            }
            result.append(chunk)
        }
        return result
    }

    private static func link(_ text: String, url: URL, line: String?, style: [NSAttributedString.Key: Any],
                             options: Options, keepText: Bool = false) -> NSAttributedString {
        var style = style
        style[.link] = url
        style[.toolTip] = url.isFileURL ? url.path + (line ?? "") : url.scheme == chatScheme ? L10n.text("Открыть чат", "Open the chat") : url.absoluteString
        style[.foregroundColor] = NSColor.linkColor
        guard options.chips else {
            style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: style)
        }
        let result = NSMutableAttributedString()
        if url.isFileURL {
            style[.inlineChip] = Chip.file.rawValue
            if let line, let number = Int(line.dropFirst().split(separator: ":").first ?? "") { style[.fileLine] = number }
            let attachment = NSTextAttachment()
            attachment.image = fileIcon(url)
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14)
            result.append(NSAttributedString(attachment: attachment))
            // A full path as the visible text is shortened to the file name; written titles stay.
            var title = text
            if !keepText, text.hasPrefix("/") || text == url.path || text.hasSuffix(url.lastPathComponent + (line ?? "")) && text.contains("/") {
                title = url.lastPathComponent
            }
            if let line, !title.hasSuffix(line) { title += line }
            result.append(NSAttributedString(string: "\u{2009}" + title, attributes: style))
            result.addAttributes(style, range: NSRange(location: 0, length: 1))
        } else {
            style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            style[.underlineColor] = NSColor.linkColor.withAlphaComponent(0.35)
            var title = text
            if text == url.absoluteString, text.count > options.urlDisplayLimit, let host = url.host {
                let path = url.path.split(separator: "/").prefix(2).joined(separator: "/")
                title = host.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
                    + (path.isEmpty ? "" : "/" + path) + "/…"
            }
            result.append(NSAttributedString(string: title, attributes: style))
        }
        return result
    }

    /// Plain-text paths such as `Sources/App/View.swift:42` become file links when the file exists.
    private static func linkPlainPaths(in chunk: NSMutableAttributedString, options: Options) {
        let pattern = #"(?<![\w/.@:-])(?:~?/)?(?:[\w.@-]+/)+[\w@-][\w.@-]*\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?)?"#
        guard let expression = Self.plainPath(pattern) else { return }
        let string = chunk.string
        for match in expression.matches(in: string, range: NSRange(location: 0, length: chunk.length)).reversed() {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let text = (string as NSString).substring(with: match.range)
            guard let file = fileReference(text, options: options) else { continue }
            let style = chunk.attributes(at: match.range.location, effectiveRange: nil)
            chunk.replaceCharacters(in: match.range, with: link(text, url: file.url, line: file.line, style: style, options: options, keepText: true))
        }
    }

    /// Icons by file type, cached: per-file icon lookups cost ~20 ms each and dominated long documents.
    private static var icons: [String: NSImage] = [:]
    static func fileIcon(_ url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if let icon = icons[ext] { return icon }
        let icon = (UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data))
            .copy() as! NSImage
        icon.size = NSSize(width: 14, height: 14)
        icons[ext] = icon
        return icon
    }

    /// Long documents cite the same files many times; existence is cached for a few seconds.
    private static var existence: [String: (Bool, Date)] = [:]
    static func cachedFileExists(_ path: String) -> Bool {
        let now = Date()
        if let (exists, checked) = existence[path], now.timeIntervalSince(checked) < 5 { return exists }
        let exists = FileManager.default.fileExists(atPath: path)
        if existence.count > 4096 { existence.removeAll() }
        existence[path] = (exists, now)
        return exists
    }

    // Built once: creating detectors per text run dominated rendering of long documents.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let highlightExpression = try? NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
    private static let footnoteExpression = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
    private static var plainPathExpression: NSRegularExpression?
    private static func plainPath(_ pattern: String) -> NSRegularExpression? {
        if plainPathExpression == nil { plainPathExpression = try? NSRegularExpression(pattern: pattern) }
        return plainPathExpression
    }

    /// `==highlight==` and footnote references `[^1]`, outside code and links.
    private static func decorate(_ chunk: NSMutableAttributedString) {
        let highlight = Self.highlightExpression
        for match in highlight?.matches(in: chunk.string, range: NSRange(location: 0, length: chunk.length)).reversed() ?? [] {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let inner = chunk.attributedSubstring(from: match.range(at: 1)).mutableCopy() as! NSMutableAttributedString
            inner.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), range: NSRange(location: 0, length: inner.length))
            chunk.replaceCharacters(in: match.range, with: inner)
        }
        let footnote = Self.footnoteExpression
        for match in footnote?.matches(in: chunk.string, range: NSRange(location: 0, length: chunk.length)).reversed() ?? [] {
            guard chunk.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            var style = chunk.attributes(at: match.range.location, effectiveRange: nil)
            style[.font] = NSFont.systemFont(ofSize: 10, weight: .semibold)
            style[.baselineOffset] = 5
            style[.foregroundColor] = NSColor.controlAccentColor
            chunk.replaceCharacters(in: match.range, with: NSAttributedString(string: (chunk.string as NSString).substring(with: match.range(at: 1)), attributes: style))
        }
    }
}
