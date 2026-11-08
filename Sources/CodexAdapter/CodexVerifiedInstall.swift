import CryptoKit
import Foundation
import ContextCore

/// A nightly pass applies only to the exact native executable selected inside Switchboard's managed install.
enum CodexVerifiedInstall {
    struct Receipt: Decodable { let version: String; let sha256: String }
    static func version(of binary: URL, selected: URL, root: URL = Locations.agentsHome.appendingPathComponent("codex")) -> String? {
        guard selected.standardizedFileURL.path == root.appendingPathComponent("bin/codex").standardizedFileURL.path,
              binary.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), binary.lastPathComponent == "codex",
              let data = try? Data(contentsOf: binary.deletingLastPathComponent().appendingPathComponent("switchboard-compat-v1.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              let contents = try? Data(contentsOf: binary, options: .alwaysMapped),
              SHA256.hash(data: contents).map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else { return nil }
        return receipt.version
    }
}
