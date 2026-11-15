import AppKit
import Foundation
import Testing
import ContextCore
@testable import ContextTranscript

/// Runs the generated launcher with a real zsh and a fake home: the user's startup files load,
/// the command waits in the line editor's buffer, `ZDOTDIR` is restored and the temporary folder is gone.
@Test func terminalPrefillLeavesTheCommandAtThePromptAndCleansUp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prefill-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), folder = root.appendingPathComponent("it's a folder")
    let directory = root.appendingPathComponent(TerminalPrefill.folderPrefix + "test")
    for url in [home, folder, directory.appendingPathComponent("zdot")] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try "export PREFILL_ENV=env\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
    try "PREFILL_RC=rc\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    try "PREFILL_LOGIN=login\n".write(to: home.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)

    let command = "echo 'it''s' \"$HOME\" && \\\n  ls -la"
    for file in TerminalPrefill.files(command: command, folder: folder.path, shell: "/bin/zsh", directory: directory.path) {
        try file.contents.write(toFile: file.path, atomically: true, encoding: .utf8)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", directory.appendingPathComponent(TerminalPrefill.launcherName).path]
    // Terminal's own startup script (/etc/zshrc_Apple_Terminal) runs as in a real Terminal window.
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb",
                           "TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "prefill-test"]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data("""
    read -rz line; print -r -- "CMD<$line>"
    print -r -- "STATE<${ZDOTDIR-unset}|$PREFILL_ENV|$PREFILL_RC|$PREFILL_LOGIN|$PWD|${SWITCHBOARD_PREFILL_DIR-gone}|${SHELL_SESSION_DID_INIT-unset}|$HISTFILE>"
    exit

    """.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let problems = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(text.contains("CMD<\(command)>"))
    #expect(text.contains("STATE<unset|env|rc|login|\(folder.path)|gone|unset|"))
    #expect(!problems.contains("No such file"), "\(problems)")
    // The window's first shell owns Terminal's session files; the prefilled shell creates none.
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zsh_sessions").path))
    #expect(text.hasPrefix("\u{1B}[H\u{1B}[2J\u{1B}[3J"))
    #expect(!text.contains("zdot/.zsh_history"))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func terminalPrefillQuotesAndShellSupport() {
    #expect(TerminalPrefill.quote("a'b") == "'a'\\''b'")
    #expect(TerminalPrefill.supports(shell: "/bin/zsh"))
    #expect(TerminalPrefill.supports(shell: "/opt/homebrew/bin/zsh"))
    #expect(!TerminalPrefill.supports(shell: "/bin/bash"))
}

/// Shell blocks offer "Open in Terminal" with the commands only; other code does not.
@MainActor @Test func shellBlocksOfferTerminalControl() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
    view.update(items: [TranscriptItem(id: "answer", kind: "assistant",
                                       text: "```bash\n$ swift build\nok\n```\n\n```swift\nlet x = 1\n```")],
                conversationID: "terminal", followOutput: false)
    view.layoutSubtreeIfNeeded()
    let storage = view.transcript.textStorage!
    var found: [String] = []
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if value as? String == "contextdesk-code-terminal",
           let text = storage.attribute(.blockCopy, at: range.location, effectiveRange: nil) as? String { found.append(text) }
    }
    #expect(Set(found) == ["swift build"])
}
