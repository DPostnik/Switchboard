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
    /// Whether a command outside the sandbox runs without a prompt: every segment, as written, is a trusted command,
    /// a `cd`, an `echo`, an `exit` with a status, or a filter that reads only its input (`| tail -5`, `| grep -E 'x'`)
    /// or `tail`/`head` of a temporary file the same command overwrote before. Allowed redirections: descriptor copies (`2>&1`), `/dev/null`
    /// and files in temporary folders, also as `$TMPDIR/…` when the command never sets `TMPDIR`. Environment prefixes
    /// and wrappers (`GIT_SSH_COMMAND=…`, `env`, `nohup`), reading redirections and any other target could run or
    /// reach anything outside the sandbox, so they are asked.
    public func trusts(_ command: String) -> Bool {
        guard sandbox != nil else { return false }
        // The segment scanner is used for deny/ask inspection, not as a complete shell grammar. Never derive an
        // allow decision from recursive executable substitutions (including the scanner's depth limit).
        guard !command.contains("$("), !command.contains("`"), !command.contains("\\\n") else { return false }
        // The segment parser splits at `&`: descriptor copies (`2>&1`) only route output and are dropped first, and
        // `&>` writes like `>`. Both only remove characters, so quoted text cannot gain a command this way.
        let normalized = command.replacingOccurrences(of: #"(^|\s)\d*>&\d+(?=\s|[;|&)]|$)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&>", with: ">")
        let temporaryVariable = Self.onlyExpandsTemporaryVariable(command)
        let segments = ShellSegments.commands(normalized + " ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let changesDirectory = segments.contains { Self.words($0)?.first?.text == "cd" }
        // Temporary files an earlier segment overwrote with `>`: `tail`/`head` may read their output back.
        // Only in a sequential command: in a pipeline or
        // with `&` the reader could run before the file is overwritten.
        var written = Set<String>()
        var matchedGrant = false
        let sequential = normalized.range(of: #"(^|[^|])\|([^|]|$)|(^|[^&])&([^&]|$)"#, options: .regularExpression) == nil
        for segment in segments {
            guard let raw = Self.words(segment), var words = Self.withoutSafeRedirections(raw, temporaryVariable: temporaryVariable) else { return false }
            while let first = words.first, ["{", "(", "!"].contains(first.text) { words.removeFirst() }
            while let last = words.last, ["}", ")"].contains(last.text) { words.removeLast() }
            defer { if sequential { written.formUnion(Self.overwrittenFiles(raw)) } }
            guard let head = words.first?.text else { continue }
            // Only assignments (`status=$?`) set a variable; before a command they would change what it runs.
            if words.count == 1, !words[0].quoted,
               words[0].text.range(of: #"^(code|exit_code|status)=\$\?$"#, options: .regularExpression) != nil { continue }
            if ["cd", "echo", "true"].contains(head) { continue }
            let texts = words.map(\.text)
            // `exit $code` after `code=$?` returns the trusted command's status.
            if head == "exit", texts.count <= 2,
               texts.dropFirst().allSatisfy({ $0.range(of: #"^(\d+|\$[A-Za-z_?][A-Za-z0-9_]*)$"#, options: .regularExpression) != nil }) { continue }
            if let prefix = trustedPrefixes.first(where: { $0.matches(texts) }) {
                // A relative script prefix belongs to the supplied working directory. A directory switch could run
                // another project's same-named script; leave such compound commands for an explicit approval.
                if changesDirectory, prefix.requiresWorkingDirectory { return false }
                matchedGrant = true
                continue
            }
            guard Self.readsOnlyInput(texts, written: written) else { return false }
        }
        return !segments.isEmpty && matchedGrant
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
    /// A filter after a pipe that reads only its input: no file operands. `tail` and `head` may also read a temporary
    /// file an earlier segment of the same command overwrote (`written`), such as a trusted command's log.
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
        case "wc": return arguments.allSatisfy { flags($0, allowed: "clmwL") }
        case "sort": return arguments.allSatisfy { flags($0, allowed: "bdfghinrRuVz") }
        case "uniq": return arguments.allSatisfy { flags($0, allowed: "cduiz") }
        case "sleep": return arguments.allSatisfy(number)
        case "grep", "egrep":
            // Options, then at most one pattern; `-e` takes the next word as a pattern.
            var patterns = 0, index = 0
            while index < arguments.count {
                let word = arguments[index]
                if word == "-e" {
                    index += 1
                    guard index < arguments.count else { return false }
                    patterns += 1
                }
                else if word.hasPrefix("-") && word != "-", !flags(word, allowed: "EFGivwxclnoqshHbz") { return false }
                else if !word.hasPrefix("-") || word == "-" { patterns += 1 }
                index += 1
            }
            return patterns <= 1
        default: return false
        }
    }
    struct Word: Equatable {
        var text: String
        var quoted: Bool
        var unquotedRedirection: Bool = false
    }
    /// Shell words with quotes removed; nil for an unfinished quote.
    static func words(_ segment: String) -> [Word]? {
        var result: [Word] = [], current = "", quoted = false, inWord = false, unquotedRedirection = false
        var quote: Character?
        for char in segment {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
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
