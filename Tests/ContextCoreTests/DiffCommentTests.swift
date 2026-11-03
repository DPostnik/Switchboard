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

private let twoHunks = """
diff --git a/a.swift b/a.swift
old mode 100644
new mode 100755
--- a/a.swift
+++ b/a.swift
@@ -1,2 +1,2 @@
-let a = 1
+let a = 2
 let b = 2
@@ -20,2 +20,1 @@ func f() {
 let y = 0
-let z = 1
\\ No newline at end of file
"""

@Test func diffHunkSpansItsHeaderToTheNextOne() throws {
    let lines = DiffLine.parse(twoHunks)
    #expect(lines.map(\.kind) == [.note, .note, .hunk, .removed, .added, .context, .hunk, .context, .removed, .note])
    // File start: the first hunk, from any of its lines, the header included.
    for index in 2...5 { #expect(DiffLine.hunk(containing: index, in: lines)?.indices == 2..<6) }
    // File end: the last hunk runs to the last line, the "no newline" note included.
    let last = try #require(DiffLine.hunk(containing: 8, in: lines))
    #expect(last.indices == 6..<10)
    #expect(DiffComment.copyText(last) == "@@ -20,2 +20,1 @@ func f() {\n let y = 0\n-let z = 1\n\\ No newline at end of file")
    // Mode notes before the first header belong to no hunk; out of range is nil.
    #expect(DiffLine.hunk(containing: 0, in: lines) == nil)
    #expect(DiffLine.hunk(containing: 10, in: lines) == nil)
    #expect(DiffLine.hunk(containing: -1, in: lines) == nil)
}

@Test func diffCopyTextDropsTheSignOfALineAndKeepsItInAHunk() throws {
    let deleted = DiffLine.parse("@@ -1,2 +0,0 @@\n-gone\n-also gone\n")
    let hunk = try #require(DiffLine.hunk(containing: 2, in: deleted))
    #expect(DiffComment.copyText(hunk) == "@@ -1,2 +0,0 @@\n-gone\n-also gone")
    #expect(DiffComment.copyText(deleted[1]) == "gone")
    let lines = DiffLine.parse(patch)
    #expect(DiffComment.copyText(lines[1]) == "let a = 1") // context
    #expect(DiffComment.copyText(lines[3]) == "let b = 3") // added
    #expect(DiffComment.copyText(try #require(DiffLine.hunk(containing: 4, in: lines)))
            == "@@ -10,4 +10,4 @@ struct A {\n let a = 1\n-let b = 2\n+let b = 3\n+let c = 4\n let d = 5")
}
