import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case russian = "ru"
    case english = "en"

    public static let preferenceKey = "interfaceLanguage"
    public var nativeName: String { self == .russian ? "Русский" : "English" }
    public var locale: Locale { Locale(identifier: self == .russian ? "ru_RU" : "en_US") }

    /// Preserve the original Russian UI for existing installations and invalid preferences.
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .russian
    }

    /// AppleLanguages is app-scoped. Never write global macOS or Codex preferences.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

/// The Mac keeps one language for the process lifetime, including background errors and
/// notifications: changing its preference takes effect after a user-initiated restart.
/// The iPhone app switches live through `use(_:)` and re-renders its views.
public enum L10n {
    private static let current = LanguageBox(AppLanguage.load())
    public static var language: AppLanguage { current.value }
    public static var locale: Locale { language.locale }

    /// Switches the language of later `text` calls in this process. Persisting the preference is the caller's job.
    public static func use(_ language: AppLanguage) { current.value = language }

    /// Both translations are required at the call site; interpolations remain type checked.
    public static func text(_ russian: String, _ english: String, language: AppLanguage = L10n.language) -> String {
        language == .russian ? russian : english
    }

    public static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

private final class LanguageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppLanguage
    init(_ value: AppLanguage) { stored = value }
    var value: AppLanguage {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
