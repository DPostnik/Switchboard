// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ContextDesk", targets: ["ContextDesk"]),
        .executable(name: "context-probe", targets: ["ContextProbe"])
    ],
    dependencies: [.package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5")],
    targets: [
        .target(name: "AgentContract"),
        // Vendored from github.com/DPostnik/fringe Packages/FringeProtocol; protocol version pinned by FringeProtocol.version.
        .target(name: "FringeProtocol"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "ContextCore", dependencies: ["AgentContract", "CSQLite", "TOMLDecoder"]),
        .target(name: "ClaudeAdapter", dependencies: ["AgentContract", "ContextCore"]),
        .target(name: "CodexAdapter", dependencies: ["AgentContract", "ContextCore"]),
        // Generic Agent Client Protocol v1 client (Gemini CLI first); wired into the app by AgentIntegrationFactory only.
        .target(name: "ACPAdapter", dependencies: ["AgentContract", "ContextCore"]),
        .target(name: "ContextTranscript", dependencies: ["ContextCore"]),
        .executableTarget(name: "ContextDesk", dependencies: ["ContextCore", "ContextTranscript", "CodexAdapter", "ClaudeAdapter", "FringeProtocol"]),
        .executableTarget(name: "ContextProbe", dependencies: ["ContextCore", "CodexAdapter"]),
        .testTarget(name: "ContextCoreTests", dependencies: ["AgentContract", "ContextCore", "CodexAdapter", "ClaudeAdapter", "ACPAdapter", "ContextTranscript", "ContextDesk", "FringeProtocol"])
    ]
)
