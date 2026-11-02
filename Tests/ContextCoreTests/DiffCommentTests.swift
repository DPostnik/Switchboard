import Foundation
import Testing
import ContextCore

private let patch = """
diff --git a/a.swift b/a.swift
index 1..2 100644
--- a/a.swift
+++ b/a.swift
@@ -10,4 +10,4 @@ struct A {
 let a = 1
-let b = 2
+let b = 3
+let c = 4
 let d = 5
"""

@Test func diffCommentQuotesTheLinesAndNamesTheirNewLocation() {
    let lines = DiffLine.parse(patch)
    let picked = DiffComment.codeLines(lines[0...3]) // the hunk header is not code
    #expect(picked.map(\.kind) == [.context, .removed, .added])
    #expect(DiffComment.location(path: "Sources/a.swift", lines: picked) == "Sources/a.swift:10-11")
    #expect(DiffComment.location(path: "a.swift", lines: [lines[3]]) == "a.swift:11")
    // Removed lines alone are named by their old lines.
    #expect(DiffComment.location(path: "a.swift", lines: [lines[2]]).hasPrefix("a.swift:11 ("))

    let draft = DiffComment.draft(path: "Sources/a.swift", lines: picked, comment: "  Why 3?  ", appendingTo: "Earlier text\n")
    #expect(draft == "Earlier text\n\n`Sources/a.swift:10-11`\n```diff\n let a = 1\n-let b = 2\n+let b = 3\n```\nWhy 3?\n\n")
    // A second comment goes after the first.
    let second = DiffComment.draft(path: "a.swift", lines: [lines[4]], comment: "ok", appendingTo: draft)
    #expect(second.hasPrefix(draft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n`a.swift:12`\n"))
}

@Test func diffCommentFenceOutgrowsBackticksInTheCodeAndCapsTheQuote() {
    let lines = [DiffLine(id: 0, kind: .added, text: "let s = \"```\"", old: nil, new: 1)]
    #expect(DiffComment.draft(path: "a", lines: lines, comment: "c", appendingTo: "").contains("````diff\n+let s = \"```\"\n````\n"))

    let many = (0..<50).map { DiffLine(id: $0, kind: .added, text: "x\($0)", old: nil, new: $0 + 1) }
    let draft = DiffComment.draft(path: "a", lines: many, comment: "c", appendingTo: "")
    #expect(draft.hasPrefix("`a:1-50`"))
    #expect(draft.contains("+x39\n…\n```"))
    #expect(!draft.contains("x40"))
}

@Test func diffEditorLineFallsForwardFromARemovedLine() {
    let lines = DiffLine.parse(patch)
    #expect(DiffComment.editorLine(1, in: lines) == 10)
    #expect(DiffComment.editorLine(2, in: lines) == 11) // removed: the next surviving line
    #expect(DiffComment.editorLine(0, in: lines) == 10) // the hunk header: its first line
    #expect(DiffComment.editorLine(99, in: lines) == nil)
}
