import Foundation
import AgentContract

/// Named Keychain items a project grants to its agents (user decision 2026-11-12). Under the external boundary the mediated
/// `security` command gets one exact argument list per item (`argumentForms`); every other form is refused by nono. The
/// whole Keychain is never granted, and a few items are never granted at all (`reserved`). A granted item's secret becomes
/// readable by the project's agents: a deliberate per-item exception to "the session has no Keychain" (PERMISSIONS.md).
public enum KeychainItemRule {
    public typealias Item = AgentPermissionProfile.KeychainItem
    public static let maximumPerProject = 16
    public static let maximumPerChange = 8
    public static let maximumLength = 128
    /// Services (case-insensitive prefixes) that are never granted: provider sign-ins, browser cookie keys and the APNs signing key.
    public static let reserved = ["Claude Code-credentials", "Chrome Safe Storage", "Chromium Safe Storage", "Claude Safe Storage", "Switchboard.APNs"]

    public enum Rejection: Error, Equatable, Sendable {
        case empty, tooLong, characters, reserved
        /// Why `item` was not taken, RU/EN; the item is shown as data, cut and on one line.
        public func message(_ item: Item, language: AppLanguage = L10n.language) -> String {
            switch self {
            case .reserved:
                let service = String(item.service.trimmingCharacters(in: .whitespaces).prefix(60))
                return L10n.text("Эта запись Связки ключей не выдаётся проектам: \(service)", "This Keychain item is never granted to projects: \(service)", language: language)
            case .empty, .tooLong, .characters:
                let label = String(KeychainItemRule.label(item).filter { !$0.isNewline }.prefix(80))
                return L10n.text("Запись Связки ключей не принята (пустое, длинное имя или недопустимые символы): \(label)",
                                 "Keychain item refused (empty, too long or unsupported characters): \(label)", language: language)
            }
        }
    }
    public static func limitMessage(language: AppLanguage = L10n.language) -> String {
        L10n.text("В проекте уже \(maximumPerProject) записей Связки ключей", "The project already has \(maximumPerProject) Keychain items", language: language)
    }

    /// The stored form of an item (trimmed; an empty account means none), or why it cannot be granted.
    public static func checked(_ item: Item) -> Result<Item, Rejection> {
        let service = item.service.trimmingCharacters(in: .whitespaces)
        let account = item.account?.trimmingCharacters(in: .whitespaces)
        for value in [service] + [account].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if value.isEmpty { return .failure(.empty) }
            if value.count > maximumLength { return .failure(.tooLong) }
            if value.hasPrefix("-") || !value.allSatisfy(allowed) { return .failure(.characters) }
        }
        if reserved.contains(where: { service.lowercased().hasPrefix($0.lowercased()) }) { return .failure(.reserved) }
        return .success(Item(service: service, account: account.flatMap { $0.isEmpty ? nil : $0 }))
    }
    /// Letters, digits, an inner space and `. _ - @ : / + =`. No wildcard, quote, backslash, tab, newline or control character.
    static func allowed(_ character: Character) -> Bool {
        if character == " " { return true }
        if ".-_@:/+=".contains(character) { return true }
        return (character.isLetter || character.isNumber) && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The items that may be applied: valid ones only, one entry per service and account, at most `maximumPerProject`.
    public static func usable(_ items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            guard case .success(let value) = checked(item), !result.contains(value) else { continue }
            result.append(value)
            if result.count == maximumPerProject { break }
        }
        return result
    }

    /// The exact `security` arguments that read one item's secret. Without an account: `find-generic-password -s S -w` in
    /// both orders; with one: every order of the groups `-a A`, `-s S`, `-w`. Nothing else.
    public static func argumentForms(_ item: Item) -> [[String]] {
        let command = "find-generic-password"
        var groups: [[String]] = [["-s", item.service], ["-w"]]
        if let account = item.account { groups.insert(["-a", account], at: 0) }
        return permutations(groups).map { [command] + $0.flatMap { $0 } }
    }
    static func permutations(_ groups: [[String]]) -> [[[String]]] {
        guard groups.count > 1 else { return [groups] }
        return groups.indices.flatMap { index -> [[[String]]] in
            var rest = groups; let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    /// The item as the user sees it: `service` or `service (account)`.
    public static func label(_ item: Item) -> String { item.account.map { "\(item.service) (\($0))" } ?? item.service }

    /// The request card line for an added item (shown with warning weight): the exact service and account are data.
    public static func addLine(_ item: Item, language: AppLanguage = L10n.language) -> String {
        let account = item.account.map { L10n.text(", учётная запись «\($0)»", ", account \"\($0)\"", language: language) }
            ?? L10n.text(" (любая учётная запись этого сервиса)", " (any account of this service)", language: language)
        return L10n.text("Связка ключей: агенты проекта смогут прочитать секрет записи «\(item.service)»",
                         "Keychain: this project's agents will be able to read the secret of the item \"\(item.service)\"", language: language) + account
    }
    public static func removeLine(_ item: Item, language: AppLanguage = L10n.language) -> String {
        L10n.text("Убрать запись Связки ключей (доступ сужается): ", "Remove Keychain item (access gets narrower): ", language: language) + label(item)
    }
}
