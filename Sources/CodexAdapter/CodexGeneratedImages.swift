import Foundation
import AgentContract
import ContextCore

/// Code-mode image generation saves originals in the dedicated Codex home's session directory. These files are
/// user-facing output even when the engine's tool item omits its image content. Never scan project files or images
/// merely opened with view_image: those may be private inputs, not generated output.
extension CodexClient {
    func generatedImages(_ session: AgentSessionReference) -> [(url: URL, modified: Date)] {
        guard session.connection == .originalCodex, UUID(uuidString: session.nativeID) != nil,
              let root = generatedImagesHome else { return [] }
        let folder = root.appendingPathComponent(session.nativeID, isDirectory: true).standardizedFileURL
        guard folder.resolvingSymlinksInPath() == folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        return files.compactMap { url -> (url: URL, modified: Date)? in
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { return nil }
            return (url: url, modified: modified)
        }.sorted { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified }
    }

    func generatedImageItem(_ url: URL, turn: String?) -> TranscriptItem {
        // URL encoding keeps spaces, parentheses and other Markdown punctuation in a file name unambiguous.
        let label = L10n.text("Созданное изображение", "Generated image")
        var item = TranscriptItem(id: "generated-image:" + url.lastPathComponent, kind: "assistant",
                                  text: "![\(label)](<\(url.absoluteString)>)", phase: "commentary")
        item.turnID = turn
        item.showsAuthor = false
        item.showsCopyControl = false
        return item
    }

    func publishGeneratedImages(method: String, params: JSONValue) {
        guard ["turn/started", "turn/completed"].contains(method),
              let native = params["threadId"].string,
              let turn = params["turn"]["id"].string else { return }
        let session = AgentSessionReference(connection: .originalCodex, nativeID: native)
        guard knownSessions.contains(session) else { return }
        let images = generatedImages(session)
        if method == "turn/started" {
            generatedImageBaselines[session] = Set(images.map { $0.url.lastPathComponent })
        } else {
            // Without a start baseline, history reconciliation supplies the images with their original turn.
            guard let baseline = generatedImageBaselines.removeValue(forKey: session) else { return }
            for image in images where !baseline.contains(image.url.lastPathComponent) {
                eventSink.yield(.init(session: session, payload: .item(generatedImageItem(image.url, turn: turn))))
            }
        }
    }
}
