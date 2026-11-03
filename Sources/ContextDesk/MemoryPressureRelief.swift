import Foundation
import Darwin
import ContextCore
import ContextTranscript

/// On a system memory-pressure warning drops what is rebuilt on demand: the store's cached transcripts other than the
/// open chat's (pending items stay until written) and the transcript image cache, then asks malloc to return free
/// pages. Nothing visible changes; the next read of a dropped transcript decodes it from the file again.
@MainActor final class MemoryPressureRelief {
    private static var current: MemoryPressureRelief?
    private let source: DispatchSourceMemoryPressure

    /// Replaces the previous handler (the main window's task runs again after the window is reopened).
    static func install(_ model: DeskModel) {
        current?.source.cancel()
        current = MemoryPressureRelief(model: model)
    }

    private init(model: DeskModel) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak model, source] in
            let level = source.data.contains(.critical) ? "critical" : "warning"
            MainActor.assumeIsolated {
                guard let model else { return }
                AppLog.lifecycle.notice("Memory pressure (\(level, privacy: .public)): releasing caches")
                TranscriptCaches.release()
                let store = model.store, kept = model.chatID
                Task.detached(priority: .utility) {
                    await store.releaseCachedTranscripts(keeping: kept)
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
        source.activate()
    }
}
