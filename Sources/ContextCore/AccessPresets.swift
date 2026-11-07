import Foundation
import AgentContract

/// A shared bundle of toolchain paths and trusted commands that a project ticks instead of copying folders by hand.
/// Paths may start with `~/`; they open only inside the command sandbox (`AgentPermissionProfile.CommandSandbox`),
/// not for the file tools.
public struct AccessPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var titleRU: String
    public var titleEN: String
    public var summaryRU: String
    public var summaryEN: String
    /// Readable paths.
    public var read: [String]
    /// Readable and writable paths.
    public var write: [String]
    /// Command prefixes that run outside the sandbox without a prompt (`gh`, `swift build`).
    public var unsandboxed: [String]
    /// Project entries that suggest the preset: a file name, a `*.ext` glob over the top level, or `file:text`
    /// for a file that contains the text. Empty: never suggested, the user ticks it on purpose.
    public var markers: [String]

    public init(id: String, titleRU: String, titleEN: String, summaryRU: String, summaryEN: String,
                read: [String] = [], write: [String] = [], unsandboxed: [String] = [], markers: [String] = []) {
        self.id = id; self.titleRU = titleRU; self.titleEN = titleEN; self.summaryRU = summaryRU; self.summaryEN = summaryEN
        self.read = read; self.write = write; self.unsandboxed = unsandboxed; self.markers = markers
    }
    public func title(language: AppLanguage = L10n.language) -> String { L10n.text(titleRU, titleEN, language: language) }
    public var title: String { title() }
    public func summary(language: AppLanguage = L10n.language) -> String { L10n.text(summaryRU, summaryEN, language: language) }
    public var summary: String { summary() }

    /// Whether the project folder has one of the preset's markers.
    public func matches(projectPath: String, manager: FileManager = .default) -> Bool {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
        return markers.contains { marker in
            if let colon = marker.firstIndex(of: ":") {
                let file = root.appendingPathComponent(String(marker[..<colon]))
                guard let data = try? Data(contentsOf: file), data.count <= 1 << 20 else { return false }
                return String(decoding: data, as: UTF8.self).contains(String(marker[marker.index(after: colon)...]))
            }
            if marker.hasPrefix("*.") {
                let suffix = String(marker.dropFirst())
                return ((try? manager.contentsOfDirectory(atPath: projectPath)) ?? []).contains { $0.hasSuffix(suffix) }
            }
            return manager.fileExists(atPath: root.appendingPathComponent(marker).path)
        }
    }
}

public enum AccessPresetCatalog {
    public static let all: [AccessPreset] = [
        AccessPreset(id: "github", titleRU: "GitHub (git и gh)", titleEN: "GitHub (git and gh)",
                     summaryRU: "Настройки git и gh. gh и сетевые команды git (push, pull, fetch, clone) идут вне песочницы, чтобы брать токен из Связки ключей.",
                     summaryEN: "git and gh settings. gh and git network commands (push, pull, fetch, clone) run outside the sandbox to use the Keychain token.",
                     read: ["~/.gitconfig", "~/.config/git", "~/.config/gh"],
                     unsandboxed: ["gh", "git push", "git pull", "git fetch", "git clone", "git ls-remote"],
                     markers: [".git"]),
        AccessPreset(id: "node", titleRU: "Node.js (npm, yarn, pnpm, bun)", titleEN: "Node.js (npm, yarn, pnpm, bun)",
                     summaryRU: "nvm и кэши пакетов. ~/.npmrc только для чтения: в нём может быть токен публикации.",
                     summaryEN: "nvm and package caches. ~/.npmrc is read-only: it may hold a publish token.",
                     read: ["~/.nvm", "~/.volta", "~/.npmrc", "~/.yarnrc", "~/.yarnrc.yml"],
                     write: ["~/.npm", "~/.bun", "~/.yarn", "~/Library/Caches/Yarn", "~/Library/pnpm", "~/Library/Caches/pnpm",
                             "~/.cache/node", "~/Library/Caches/node-gyp", "~/Library/Caches/typescript", "~/.config/configstore",
                             "~/Library/Preferences/nextjs-nodejs"],
                     markers: ["package.json", ".nvmrc", ".node-version"]),
        AccessPreset(id: "browsers", titleRU: "Браузерные движки (Playwright, Puppeteer, Electron)", titleEN: "Browser engines (Playwright, Puppeteer, Electron)",
                     summaryRU: "Скачанные браузеры и Electron.", summaryEN: "Downloaded browsers and Electron.",
                     write: ["~/Library/Caches/ms-playwright", "~/Library/Caches/electron", "~/.cache/puppeteer"],
                     markers: ["package.json:playwright", "package.json:puppeteer", "package.json:electron"]),
        AccessPreset(id: "vercel", titleRU: "Vercel", titleEN: "Vercel",
                     summaryRU: "Настройки и вход Vercel CLI.", summaryEN: "Vercel CLI settings and sign-in.",
                     write: ["~/Library/Application Support/com.vercel.cli"],
                     markers: ["vercel.json", ".vercel"]),
        AccessPreset(id: "swift", titleRU: "Swift и Xcode", titleEN: "Swift and Xcode",
                     summaryRU: "Кэши SwiftPM и DerivedData. swift build/test/run и xcodebuild идут вне песочницы: внутри неё SwiftPM не запускает свою.",
                     summaryEN: "SwiftPM caches and DerivedData. swift build/test/run and xcodebuild run outside the sandbox: SwiftPM cannot start its own inside it.",
                     write: ["~/Library/Developer", "~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm", "~/.swiftpm"],
                     unsandboxed: ["swift build", "swift test", "swift run", "swift package", "xcodebuild"],
                     markers: ["Package.swift", "*.xcodeproj", "*.xcworkspace"]),
        AccessPreset(id: "python", titleRU: "Python (pip, uv)", titleEN: "Python (pip, uv)",
                     summaryRU: "Кэши pip и uv, модели Hugging Face.", summaryEN: "pip and uv caches, Hugging Face models.",
                     read: ["~/.config/uv", "~/.pyenv"],
                     write: ["~/Library/Caches/pip", "~/.cache/pip", "~/.cache/uv", "~/.local/share/uv", "~/.cache/huggingface"],
                     markers: ["pyproject.toml", "requirements.txt", "uv.lock", "setup.py", ".venv"]),
        AccessPreset(id: "homebrew", titleRU: "Установка через Homebrew", titleEN: "Homebrew installs",
                     summaryRU: "brew install и brew upgrade меняют программы всего Mac.", summaryEN: "brew install and brew upgrade change software for the whole Mac.",
                     write: ["/opt/homebrew", "~/Library/Caches/Homebrew", "~/Library/Logs/Homebrew"]),
        AccessPreset(id: "agent-clis", titleRU: "CLI агентов и навыки", titleEN: "Agent CLIs and skills",
                     summaryRU: "Чтение ~/.local/bin, навыков и общих правил Claude и Codex. Переписки агентов не входят.",
                     summaryEN: "Read ~/.local/bin, Claude and Codex skills and shared rules. Agent transcripts are not included.",
                     read: ["~/.local/bin", "~/.local/share/claude", "~/.claude/skills", "~/.claude/guidelines", "~/.claude/CLAUDE.md",
                            "~/.codex/skills", "~/.codex/AGENTS.md", "~/.agents/skills"]),
        AccessPreset(id: "downloads", titleRU: "Загрузки (чтение)", titleEN: "Downloads (read)",
                     summaryRU: "Чтение папки «Загрузки».", summaryEN: "Read the Downloads folder.",
                     read: ["~/Downloads"]),
        AccessPreset(id: "apple-signing", titleRU: "Подпись приложений Apple", titleEN: "Apple code signing",
                     summaryRU: "codesign идёт вне песочницы и использует сертификаты из Связки ключей.",
                     summaryEN: "codesign runs outside the sandbox and uses certificates from the Keychain.",
                     write: ["~/Library/Developer/Xcode/UserData/Provisioning Profiles"],
                     unsandboxed: ["codesign"])
    ]
    /// Read-only system queries every sandboxed project keeps: the sandbox denies process and kernel information, and
    /// agents check the Mac's load and running jobs with these before heavy work. `pgrep` and `lsof` are not here: the
    /// CLI treats them as read-only and always runs them inside the sandbox, where they see no processes.
    public static let baseUnsandboxed = ["ps", "sysctl -n"]
    public static func preset(_ id: String) -> AccessPreset? { all.first { $0.id == id } }
    /// Presets a project folder suggests; presets without markers are never suggested.
    public static func detect(projectPath: String, manager: FileManager = .default) -> [String] {
        all.filter { $0.matches(projectPath: projectPath, manager: manager) }.map(\.id)
    }
}

extension Project {
    /// Whether shell commands of roles with a shell run in the command sandbox; absent means on.
    public var usesCommandSandbox: Bool { commandSandbox != false }
    /// The ticked presets; unknown ids are skipped.
    public var resolvedAccessPresets: [AccessPreset] { (accessPresets ?? []).compactMap(AccessPresetCatalog.preset) }

    /// The command sandbox for a role on this project, built from the project, its extra roots, its presets and
    /// its own trusted commands. Nil when the project turned the sandbox off.
    public func commandSandbox(extraRoots roots: [AgentPermissionProfile.Root]) -> AgentPermissionProfile.CommandSandbox? {
        guard usesCommandSandbox else { return nil }
        let presets = resolvedAccessPresets
        func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }
        let write = unique([path] + roots.filter(\.writable).map(\.path) + presets.flatMap(\.write))
        let read = unique(write + roots.map(\.path) + presets.flatMap(\.read))
        let commands = (sandboxCommands ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return .init(read: read, write: write, readOnly: roots.filter { !$0.writable }.map(\.path),
                     unsandboxed: unique(AccessPresetCatalog.baseUnsandboxed + presets.flatMap(\.unsandboxed) + commands))
    }
}

extension SavedState {
    /// Ticks the suggested presets once for projects that never had any; returns whether anything changed.
    public mutating func migrateAccessPresets(manager: FileManager = .default) -> Bool {
        var changed = false
        for index in projects.indices where projects[index].accessPresets == nil {
            projects[index].accessPresets = AccessPresetCatalog.detect(projectPath: projects[index].path, manager: manager)
            changed = true
        }
        return changed
    }
}
