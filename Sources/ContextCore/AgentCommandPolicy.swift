import Foundation
import CryptoKit
import AgentContract

/// A compiled view of the project's existing command grants. This is not an approval responder: a provider's
/// mandatory approval remains mandatory even when an observation matches a project grant.
public struct AgentCommandPolicy: Sendable {
    public struct Prefix: Equatable, Sendable {
        public let ruleID: String
        public let tokens: [String]
        public var command: String { tokens.joined(separator: " ") }
        private static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "python", "python3", "node", "nodejs", "perl", "ruby", "osascript"]
        public var requiresWorkingDirectory: Bool {
            if tokens.contains(where: { $0.contains("/") && !$0.hasPrefix("/") }) { return true }
            return Self.interpreters.contains((tokens[0] as NSString).lastPathComponent) && tokens.count > 1 && !tokens[1].hasPrefix("/")
        }

        /// Persisted settings are literal argv prefixes, never shell programs, expansions, globs or assignments.
        public init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ").map(String.init)
            let forbidden = CharacterSet(charactersIn: "\n\r\t\0'\"`$;|&<>(){}[]*?!\\=~")
            guard !tokens.isEmpty, trimmed.rangeOfCharacter(from: forbidden) == nil else { return nil }
            let executable = (tokens[0] as NSString).lastPathComponent
            if Self.interpreters.contains(executable) {
                guard tokens.count > 1, tokens[1] != "-", !tokens[1].hasPrefix("-") else { return nil }
            }
            self.tokens = tokens
            ruleID = "project.command." + SHA256.hash(data: Data(tokens.joined(separator: "\0").utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        public func matches(_ arguments: [String]) -> Bool {
            arguments.count >= tokens.count && Array(arguments.prefix(tokens.count)) == tokens
        }
    }
    public enum Decision: String, Sendable { case notGranted, granted, unsupportedGrant, providerApprovalRequired }
    public enum Reason: String, Sendable { case noMatchingGrant, projectCommand, nativeRulesUnavailable, mandatoryProviderApproval }
    public struct Assessment: Equatable, Sendable {
        public let decision: Decision
        public let ruleIDs: [String]
        public let reason: Reason
    }
    public let trustedPrefixes: [Prefix]
    public let rejectedPrefixes: [String]
    private let sandbox: AgentPermissionProfile.CommandSandbox?

    public init(_ profile: AgentPermissionProfile) {
        let effective = profile.effective
        sandbox = effective.filesystem != .unrestricted && effective.shell == .on ? effective.commandSandbox : nil
        var prefixes: [Prefix] = [], rejected: [String] = []
        for command in sandbox?.unsandboxed ?? [] {
            guard let prefix = Prefix(command) else { rejected.append(command); continue }
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        trustedPrefixes = prefixes; rejectedPrefixes = rejected
    }
    /// Observation only. Never use a matching grant to answer a provider's mandatory approval callback.
    public func assess(command: String, support: AgentPermissionSupport, providerRequiresApproval: Bool = false) -> Assessment {
        let commands = Self.heads(command + " ")
        let rules = trustedPrefixes.filter { prefix in
            commands.contains { head in Self.words(head).map { prefix.matches($0.map(\.text)) } == true }
        }.map(\.ruleID)
        guard trusts(command), !rules.isEmpty else {
            return .init(decision: providerRequiresApproval ? .providerApprovalRequired : .notGranted, ruleIDs: [],
                         reason: providerRequiresApproval ? .mandatoryProviderApproval : .noMatchingGrant)
        }
        if providerRequiresApproval {
            return .init(decision: .providerApprovalRequired, ruleIDs: rules, reason: .mandatoryProviderApproval)
        }
        guard support.enforced.contains(.trustedCommands) else {
            return .init(decision: .unsupportedGrant, ruleIDs: rules, reason: .nativeRulesUnavailable)
        }
        return .init(decision: .granted, ruleIDs: rules, reason: .projectCommand)
    }
    /// Diagnostic matching for a provider's displayed invocation, never for enforcement. Native Codex approval
    /// commands may wrap the actual command in one shell invocation. Recognize only an exact, literal quoted payload;
    /// do not interpret expansions, quote concatenation, nested wrappers or arguments after the payload.
    public func assessInvocation(command: String, support: AgentPermissionSupport) -> Assessment? {
        func observed(_ command: String) -> Assessment? {
            let assessment = assess(command: command, support: support)
            guard !assessment.ruleIDs.isEmpty else { return nil }
            if assessment.decision == .unsupportedGrant { return assessment }
            return .init(decision: .providerApprovalRequired, ruleIDs: assessment.ruleIDs, reason: .mandatoryProviderApproval)
        }
        let text = command.trimmingCharacters(in: .whitespaces)
        let shells = ["/bin/zsh", "/bin/bash"]
        let executable = text.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard executable.map(shells.contains) == true else { return observed(command) }
        for shell in shells {
            for option in ["-c", "-lc"] {
                let opening = shell + " " + option + " '"
                guard text.hasPrefix(opening), text.hasSuffix("'"), text.count > opening.count else { continue }
                let payload = String(text.dropFirst(opening.count).dropLast())
                let forbidden = CharacterSet(charactersIn: "'\\$`\n\r\0")
                guard !payload.isEmpty, payload.rangeOfCharacter(from: forbidden) == nil else { return nil }
                // Keep the native-support gap visible. Even when the inner command is supported, the wrapper itself
                // remains outside the trust matcher and still requires the provider's explicit approval.
                return observed(payload)
            }
        }
        return nil
    }
    /// Conservative sandbox routing hint, never an approval decision. Shell quoting must not hide a native exclusion.
    public func containsTrustedCommand(_ command: String) -> Bool {
        Self.heads(command + " ").contains { head in
            guard let words = Self.words(head) else { return false }
            return trustedPrefixes.contains { $0.matches(words.map(\.text)) }
        }
    }
    /// Why `trusts` refuses a command. Stable identifiers: the capability ledger records them as reasons.
    public enum TrustRejection: String, Sendable, CaseIterable {
        /// A command substitution or backtick other than `$(pwd)` / `$(git rev-parse --show-toplevel)`.
        case substitution
        /// A `cd` to anything but the session working directory before a script given by a relative path.
        case cdBeforeScript
        /// A segment that is neither a trusted command, a no-file command nor an accepted reader or filter.
        case unknownFilter
        /// A redirection that reads a file or writes outside temporary folders.
        case redirection
        /// No trusted command in the line, or no command sandbox (and so no grants) for this profile.
        case noGrant
        /// A backslash-newline line continuation.
        case lineContinuation
    }
    /// Whether a command outside the sandbox runs without a prompt: every segment, as written, is a trusted command,
    /// a no-file command (`cd`, `echo`, `true`, `pwd`, `date`, `printf`, `exit` with a status), a filter that reads
    /// only its input (`| tail -5`, `| grep -E 'x'`), or a reader (`cat`, `grep`, `sed -n 1,20p`, `wc -l`, `tail`,
    /// `head`) of a temporary file the same sequential command overwrote before. Allowed redirections: descriptor
    /// copies (`2>&1`), `/dev/null` and files in temporary folders, also as `$TMPDIR/…` when the command never sets
    /// `TMPDIR`. Environment prefixes and wrappers (`GIT_SSH_COMMAND=…`, `env`, `nohup`), reading redirections and any
    /// other target could run or reach anything outside the sandbox, so they are asked.
    public func trusts(_ command: String) -> Bool { trusts(command, cwd: nil) }
    /// `cwd` is the session's working directory, the project that owns the trusted commands: a `cd` to it (also as
    /// `"$(pwd)"` or `"$(git rev-parse --show-toplevel)"`) may precede a trusted script given by a relative path.
    public func trusts(_ command: String, cwd: String?) -> Bool { rejection(command, cwd: cwd) == nil }
    /// Nil when `trusts(command, cwd:)` holds, otherwise a `TrustRejection` identifier.
    public func trustRejection(_ command: String, cwd: String?) -> String? { rejection(command, cwd: cwd)?.rawValue }

    func rejection(_ original: String, cwd: String?) -> TrustRejection? {
        guard sandbox != nil else { return .noGrant }
        guard !original.contains("\\\n") else { return .lineContinuation }
        guard !original.contains("\u{E000}") else { return .unknownFilter }
        // The two directory queries are read-only and stand for the working directory; they are replaced by one
        // token before parsing. The segment scanner is used for deny/ask inspection, not as a complete shell grammar:
        // never derive an allow decision from any other executable substitution (including the scanner's depth limit).
        let command = Self.withoutDirectorySubstitutions(original)
        guard !command.contains("$("), !command.contains("`") else { return .substitution }
        // Comments and ANSI-C quoting (`$'\''`) would end or open quotes where the word parser does not see them.
        guard !Self.hasComment(command), !command.contains("$'") else { return .unknownFilter }
        // The segment parser splits at `&`: descriptor copies (`2>&1`) only route output and are dropped first, and
        // `&>` writes like `>`. Both only remove characters, so quoted text cannot gain a command this way.
        let normalized = command.replacingOccurrences(of: #"(^|\s)\d*>&\d+(?=\s|[;|&)]|$)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&>", with: ">")
        let temporaryVariable = Self.onlyExpandsTemporaryVariable(command)
        let segments = ShellSegments.commands(normalized + " ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A relative script prefix belongs to the session's working directory. Any `cd` elsewhere (another project, a
        // writable root, `cd` alone, `cd -`) could run another project's same-named script, in whatever order or
        // branch (`||`) it appears; leave such compound commands for an explicit approval.
        let session = cwd.flatMap(Self.canonicalDirectory)
        let leavesSession = segments.contains { segment in
            guard let raw = Self.words(segment), let words = Self.withoutSafeRedirections(raw, temporaryVariable: temporaryVariable)
            else { return false }
            let command = Self.withoutGrouping(words)
            guard command.first?.text == "cd", command.first?.quoted == false else { return false }
            return !Self.entersSession(Array(command.dropFirst()), session: session)
        }
        // Temporary files an earlier segment overwrote with `>`: readers may read their output back. Only in a
        // sequential command: in a pipeline or with `&` the reader could run before the file is overwritten.
        var written = Set<String>()
        var matchedGrant = false
        let sequential = Self.isSequential(normalized)
        for segment in segments {
            guard let raw = Self.words(segment) else { return .unknownFilter }
            guard let unredirected = Self.withoutSafeRedirections(raw, temporaryVariable: temporaryVariable) else { return .redirection }
            let words = Self.withoutGrouping(unredirected)
            defer { if sequential { written.formUnion(Self.overwrittenFiles(raw)) } }
            guard let head = words.first?.text else { continue }
            // Only assignments (`status=$?`) set a variable; before a command they would change what it runs.
            if words.count == 1, !words[0].quoted,
               words[0].text.range(of: #"^(code|exit_code|status)=\$\?$"#, options: .regularExpression) != nil { continue }
            let texts = words.map(\.text)
            if head == "cd" || Self.usesNoFiles(texts) { continue }
            if let prefix = trustedPrefixes.first(where: { $0.matches(texts) }) {
                if leavesSession, prefix.requiresWorkingDirectory { return .cdBeforeScript }
                matchedGrant = true
                continue
            }
            guard Self.readsOnlyInput(texts, written: written) else { return .unknownFilter }
        }
        return !segments.isEmpty && matchedGrant ? nil : .noGrant
    }
    /// Stands for `$(pwd)` and `$(git rev-parse --show-toplevel)`; a private-use character no accepted command contains.
    static let directoryToken = "\u{E000}session-directory\u{E000}"
    static func withoutDirectorySubstitutions(_ command: String) -> String {
        command.replacingOccurrences(of: #"\$\((pwd|git rev-parse --show-toplevel)\)"#, with: directoryToken, options: .regularExpression)
    }
    /// Words without grouping (`{`, `(`, `!` before and `}`, `)` after the command).
    static func withoutGrouping(_ words: [Word]) -> [Word] {
        var words = words
        while let first = words.first, !first.quoted, ["{", "(", "!"].contains(first.text) { words.removeFirst() }
        while let last = words.last, !last.quoted, ["}", ")"].contains(last.text) { words.removeLast() }
        return words
    }
    /// Commands that open no file and run nothing (`cd` is checked separately; `printf -v` would set a variable,
    /// `date` with an operand would set the clock).
    static func usesNoFiles(_ words: [String]) -> Bool {
        guard let head = words.first else { return false }
        let arguments = words.dropFirst()
        switch head {
        case "echo", "true": return true
        case "pwd": return arguments.allSatisfy { ["-L", "-P"].contains($0) }
        case "date": return arguments.allSatisfy { $0 == "-u" || $0.hasPrefix("+") }
        case "printf": return !arguments.isEmpty && !arguments.contains { $0.hasPrefix("-v") }
        case "exit":
            // `exit $code` after `code=$?` returns the trusted command's status.
            return arguments.count <= 1
                && arguments.allSatisfy { $0.range(of: #"^(\d+|\$[A-Za-z_?][A-Za-z0-9_]*)$"#, options: .regularExpression) != nil }
        default: return false
        }
    }
    /// Whether the operands of a `cd` name the session directory: exactly one absolute path (or `~/…`, or the
    /// directory token) that canonicalizes to it. Expansions, globs and `..` never match.
    static func entersSession(_ operands: [Word], session: String?) -> Bool {
        guard let session, operands.count == 1 else { return false }
        let operand = operands[0]
        // Unquoted, the shell splits the substituted path at spaces, and `cd a b` in zsh changes to another directory.
        if operand.text == directoryToken { return operand.quoted || session.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }
        guard !(operand.quoted && operand.text.hasPrefix("~")),
              operand.text.rangeOfCharacter(from: CharacterSet(charactersIn: "$*?[]{}`\u{E000}")) == nil,
              !operand.text.split(separator: "/").contains("..") else { return false }
        return canonicalDirectory(operand.text) == session
    }
    /// An absolute directory path with `~` expanded, symbolic links resolved and no trailing slash.
    static func canonicalDirectory(_ path: String) -> String? {
        var path = path.trimmingCharacters(in: .whitespaces)
        if path == "~" || path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Whether the command has a shell comment: an unquoted, unescaped `#` at the start of a word (line start, after
    /// whitespace or after `;`, `|`, `&`, `(`, `)`, `{`, `}`). A `#` inside quotes or within a word is data.
    static func hasComment(_ command: String) -> Bool {
        let chars = Array(command)
        var index = 0, wordStart = true
        var quote: Character?
        while index < chars.count {
            let char = chars[index]
            if quote == "'" {
                if char == "'" { quote = nil }
                wordStart = false
            } else if quote == "\"" {
                if char == "\\" { index += 1 } else if char == "\"" { quote = nil }
                wordStart = false
            } else if char == "\\" {
                index += 1; wordStart = false
            } else if char == "'" || char == "\"" {
                quote = char; wordStart = false
            } else if char == "#" {
                if wordStart { return true }
            } else {
                wordStart = char.isWhitespace || ";|&(){}".contains(char)
            }
            index += 1
        }
        return false
    }
    /// No pipe (`|`, `|&`) or background `&` outside quotes; `||`, `&&`, `;` and newlines keep segments in order.
    static func isSequential(_ command: String) -> Bool {
        let chars = Array(command)
        var index = 0
        var quote: Character?
        while index < chars.count {
            let char = chars[index]
            if quote == "'" {
                if char == "'" { quote = nil }
            } else if char == "\\" {
                index += 1
            } else if quote == "\"" {
                if char == "\"" { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "|" || char == "&" {
                if index + 1 < chars.count, chars[index + 1] == char { index += 2; continue }
                return false
            }
            index += 1
        }
        return true
    }
    /// Whether every mention of `TMPDIR` reads it (`$TMPDIR`, `${TMPDIR}`), so the command cannot point it elsewhere.
    static func onlyExpandsTemporaryVariable(_ command: String) -> Bool {
        func count(_ text: String) -> Int { command.components(separatedBy: text).count - 1 }
        return count("TMPDIR") == count("$TMPDIR") + count("${TMPDIR}")
    }
    /// Targets of truncating output redirections (`>`, `2>`; not `>>` or descriptor copies).
    static func overwrittenFiles(_ words: [Word]) -> [String] {
        var result: [String] = []
        for (index, word) in words.enumerated() where !word.quoted || word.unquotedRedirection {
            guard let range = word.text.range(of: #"^\d*>(?![>&])"#, options: .regularExpression) else { continue }
            let target = String(word.text[range.upperBound...])
            if !target.isEmpty { result.append(target) } else if index + 1 < words.count { result.append(words[index + 1].text) }
        }
        return result
    }
    /// A filter after a pipe that reads only its input: no file operands. Readers may also read a temporary file an
    /// earlier segment of the same sequential command overwrote (`written`), such as a trusted command's log:
    /// `tail`, `head`, `cat`, `wc`, `grep` (a path-like pattern is refused) and `sed -n <address>p` (no other script).
    static func readsOnlyInput(_ words: [String], written: Set<String> = []) -> Bool {
        guard let head = words.first else { return false }
        let arguments = Array(words.dropFirst())
        func number(_ word: String) -> Bool { !word.isEmpty && word.allSatisfy(\.isNumber) }
        func flags(_ word: String, allowed: String) -> Bool {
            word.hasPrefix("-") && !word.hasPrefix("--") && word.count > 1 && word.dropFirst().allSatisfy { allowed.contains($0) }
        }
        switch head {
        case "tail", "head":
            var index = 0
            while index < arguments.count {
                let word = arguments[index]
                if word == "-n" || word == "-c" {
                    index += 1
                    guard index < arguments.count, number(arguments[index]) else { return false }
                } else if ["-q", "-v"].contains(word) || (word.hasPrefix("-") && number(String(word.dropFirst()))) {
                    // Count shorthand (`-15`) and output formatting flags have no file operands.
                } else if written.contains(word) {
                    // Only a file overwritten earlier in this same sequential command may be read back.
                } else { return false }
                index += 1
            }
            return true
        case "cat": return arguments.allSatisfy(written.contains)
        case "wc": return arguments.allSatisfy { flags($0, allowed: "clmwL") || written.contains($0) }
        case "sed":
            // Print a line range only (`sed -n 1,20p`, `sed -n '$p'`): any other script could write (`w`), read (`r`)
            // or run (`e`) files, and `-i` edits in place.
            guard arguments.count >= 2, arguments[0] == "-n",
                  arguments[1].range(of: #"^(\d+|\$)(,(\d+|\$))?p$"#, options: .regularExpression) != nil else { return false }
            return arguments.dropFirst(2).allSatisfy(written.contains)
        case "sort": return arguments.allSatisfy { flags($0, allowed: "bdfghinrRuVz") }
        case "uniq": return arguments.allSatisfy { flags($0, allowed: "cduiz") }
        case "sleep": return arguments.allSatisfy(number)
        case "grep", "egrep":
            // Options without file arguments, one pattern (`-e` takes the next word as the pattern), then only files
            // from `written`.
            var pattern: String?, files: [String] = [], index = 0
            while index < arguments.count {
                let word = arguments[index]
                if word == "-e" {
                    index += 1
                    guard index < arguments.count, pattern == nil else { return false }
                    pattern = arguments[index]
                } else if word.hasPrefix("-") && word != "-" {
                    guard flags(word, allowed: "EFGivwxclnoqshHbz") else { return false }
                } else if pattern == nil {
                    pattern = word
                } else {
                    files.append(word)
                }
                index += 1
            }
            guard files.allSatisfy(written.contains) else { return false }
            // With file operands, a path-like pattern is refused rather than guessed at.
            if !files.isEmpty, let pattern, pattern.hasPrefix("/") || pattern.hasPrefix("~") { return false }
            return true
        default: return false
        }
    }
    struct Word: Equatable {
        var text: String
        var quoted: Bool
        var unquotedRedirection: Bool = false
    }
    /// Shell words with quotes and backslash escapes removed; nil for an unfinished quote or a trailing backslash.
    /// An escaped character counts as quoted: it is never a redirection, a `~` or grouping.
    static func words(_ segment: String) -> [Word]? {
        var result: [Word] = [], current = "", quoted = false, inWord = false, unquotedRedirection = false
        var quote: Character?
        let chars = Array(segment)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            index += 1
            if quote == "'" {
                if char == "'" { quote = nil } else { current.append(char) }
            } else if quote == "\"" {
                if char == "\"" { quote = nil }
                else if char == "\\", index < chars.count, "$`\"\\\n".contains(chars[index]) { current.append(chars[index]); index += 1 }
                else { current.append(char) }
            } else if char == "\\" {
                guard index < chars.count else { return nil }
                current.append(chars[index]); index += 1; quoted = true; inWord = true
            } else if char == "'" || char == "\"" {
                quote = char; quoted = true; inWord = true
            } else if char == " " || char == "\t" {
                if inWord {
                    result.append(.init(text: current, quoted: quoted, unquotedRedirection: unquotedRedirection))
                    current = ""; quoted = false; inWord = false; unquotedRedirection = false
                }
            } else {
                if char == ">" || char == "<" { unquotedRedirection = true }
                current.append(char); inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { result.append(.init(text: current, quoted: quoted, unquotedRedirection: unquotedRedirection)) }
        return result
    }
    /// Words without harmless redirections; nil when a redirection reads a file or writes outside temporary folders.
    static func withoutSafeRedirections(_ words: [Word], temporaryVariable: Bool = false) -> [Word]? {
        var result: [Word] = [], index = 0
        while index < words.count {
            let word = words[index]
            guard !word.quoted || word.unquotedRedirection, let range = word.text.range(of: #"^(\d*|&)(>>?|<)(&\d+)?"#, options: .regularExpression) else {
                if (!word.quoted || word.unquotedRedirection), word.text.contains(where: { $0 == ">" || $0 == "<" }) { return nil }
                result.append(word); index += 1; continue
            }
            let operatorText = String(word.text[range])
            if operatorText.contains("<") { return nil }
            if operatorText.contains(">&") { index += 1; continue }
            var target = String(word.text[range.upperBound...])
            if target.isEmpty {
                guard index + 1 < words.count else { return nil }
                target = words[index + 1].text; index += 1
            }
            guard target == "/dev/null" || isTemporary(target, temporaryVariable: temporaryVariable) else { return nil }
            index += 1
        }
        return result
    }
    /// A plain absolute path inside a temporary folder (no `..`, `~` or variables other than a leading `$TMPDIR/`
    /// when `temporaryVariable` says the command never sets it).
    static func isTemporary(_ path: String, temporaryVariable: Bool = false) -> Bool {
        if temporaryVariable, let rest = ["$TMPDIR/", "${TMPDIR}/"].first(where: path.hasPrefix).map({ String(path.dropFirst($0.count)) }) {
            guard !rest.isEmpty, !rest.contains("$"), !rest.contains("`"), !rest.split(separator: "/").contains(".."),
                  let root = ProcessInfo.processInfo.environment["TMPDIR"], root.hasPrefix("/") else { return false }
            return isTemporary((root as NSString).appendingPathComponent(rest))
        }
        guard path.hasPrefix("/"), !path.contains("$"), !path.utf8.contains(0), !path.split(separator: "/").contains("..") else { return false }
        let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        // Existing output symlinks and symlinked parents may point outside temporary storage. Do not grant those
        // redirects on lexical spelling alone. This check observes the current filesystem, not a future race.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return roots.contains { resolved.hasPrefix($0 + "/") }
    }

    /// The commands a shell line runs (see `ShellSegments`), with leading environment assignments and
    /// command wrappers (`nohup`, `env`, `exec`…) removed so the real command is what gets matched.
    public static func heads(_ text: String) -> [String] {
        ShellSegments.commands(text).map { segment in
            var head = segment.trimmingCharacters(in: .whitespaces)
            var changed = true
            while changed {
                changed = false
                if let space = head.firstIndex(of: " "), head[..<space].contains("="), !head[..<space].contains("/") {
                    head = String(head[head.index(after: space)...]).trimmingCharacters(in: .whitespaces); changed = true
                }
                for wrapper in ShellSegments.wrappers where head.hasPrefix(wrapper + " ") {
                    head = String(head.dropFirst(wrapper.count + 1)).trimmingCharacters(in: .whitespaces); changed = true
                }
            }
            return head
        }
    }
    /// A pattern matches the head of a command segment (after `|`, `;`, `&&`, `(`, backticks, `$(` or a newline),
    /// so `sudo ` is found in `cd x && sudo rm` but not inside `pseudo ` or as an argument such as `echo curl`.
    public static func matches(_ text: String, _ pattern: String) -> Bool {
        heads(text).contains { ($0 + " ").hasPrefix(pattern) }
    }

}
