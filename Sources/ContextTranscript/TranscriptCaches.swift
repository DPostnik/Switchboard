import Foundation

/// Process-wide caches of the transcript renderer that can be rebuilt on demand.
@MainActor public enum TranscriptCaches {
    /// Drops them under memory pressure; images shown again are re-read from their files.
    public static func release() { TranscriptMarkdown.releaseImages() }
}
