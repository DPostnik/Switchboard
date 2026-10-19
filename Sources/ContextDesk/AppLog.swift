import os

/// Unified-log categories for background work that never surfaces errors in the UI.
/// Read with `log stream --predicate 'subsystem == "local.daniil.switchboard"' --level info`.
/// Prompts and generated text are never logged: only IDs, states, timings and adapter diagnostics.
enum AppLog {
    static let subsystem = "local.daniil.switchboard"
    static let chatTitle = Logger(subsystem: subsystem, category: "chat-title")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let delivery = Logger(subsystem: subsystem, category: "delivery")
    static let remote = Logger(subsystem: subsystem, category: "remote")
    static let browser = Logger(subsystem: subsystem, category: "browser")
}
