import Foundation
import CommonCrypto
import CryptoKit
import Security
import CSQLite

public enum ChromeCookieError: Error, LocalizedError, Sendable {
    case sourceRunning, unavailable, invalidProfile, unsupportedSchema, keychain, sourceChanged, tooLarge
    case browserBusy, destinationRunning, uncertain, connection, missingEnvironment, empty, browserLimit
    /// A consent file without a valid app signature (written outside the app, copied or edited).
    case unsignedPolicy
    /// This site was imported into this chat browser within the last hour, or too many sites were.
    case recentlyImported, importLimit
    /// IndexedDB transfer was requested for a site the user has not granted it for, or the origin has no store.
    case indexedDBDisabled, indexedDBMissing

    public var errorDescription: String? { message(language: L10n.language) }
    public func message(language: AppLanguage) -> String {
        switch self {
        case .sourceRunning: return L10n.text("Chrome не дал прочитать файл cookies. Заверши обычный Google Chrome через Cmd+Q и повтори импорт.", "Chrome did not allow reading its cookie file. Quit regular Google Chrome with Cmd+Q, then import again.", language: language)
        case .unavailable: return L10n.text("Не удалось прочитать cookies выбранного профиля Chrome.", "Could not read cookies from the selected Chrome profile.", language: language)
        case .recentlyImported: return L10n.text("Сессию этого сайта уже импортировали в браузер чата за последний час. Повторного импорта не будет: проверь вход на странице.", "This site's session was already imported into the chat browser within the last hour. It will not be imported again: check sign-in on the page.", language: language)
        case .importLimit: return L10n.text("За последний час в браузер чата импортировали сессии слишком многих сайтов. Новый импорт будет доступен позже.", "Too many sites were imported into the chat browser within the last hour. A new import will be available later.", language: language)
        case .unsignedPolicy: return L10n.text("Разрешение на импорт не подтверждено приложением. Включи его заново в Браузер → Импортировать только cookies.", "The import permission was not confirmed by the app. Enable it again in Browser → Import cookies only.", language: language)
        case .invalidProfile: return L10n.text("Профиль Chrome недоступен или его путь изменился. Обнови список профилей.", "The Chrome profile is unavailable or its path changed. Refresh the profile list.", language: language)
        case .unsupportedSchema: return L10n.text("Этот формат cookies Chrome пока не поддерживается. Импорт не выполнен.", "This Chrome cookie format is not supported yet. Nothing was imported.", language: language)
        case .keychain: return L10n.text("Не получен доступ к Chrome Safe Storage в Связке ключей. Разреши доступ при следующем явном импорте.", "Access to Chrome Safe Storage in Keychain was not granted. Allow access during your next explicit import.", language: language)
        case .sourceChanged: return L10n.text("Профиль Chrome менялся во время чтения. Заверши обычный Google Chrome через Cmd+Q и повтори импорт.", "The Chrome profile kept changing during reading. Quit regular Google Chrome with Cmd+Q, then import again.", language: language)
        case .tooLarge: return L10n.text("Профиль cookies превышает поддерживаемый размер. Импорт не выполнен.", "The cookie profile exceeds the supported size. Nothing was imported.", language: language)
        case .browserBusy: return L10n.text("Браузер чата занят. Дождись завершения текущей операции.", "This chat's browser is busy. Wait for its current operation to finish.", language: language)
        case .destinationRunning: return L10n.text("Перед импортом закрой Chrome for Testing этого чата через меню «Браузер». Импорт откроет его снова.", "Before importing, close this chat's Chrome for Testing from the Browser menu. Import will reopen it.", language: language)
        case .uncertain: return L10n.text("Результат импорта не подтверждён. Повтора не было. Проверь браузер и заверши его через Cmd+Q перед новым импортом.", "The import outcome is unconfirmed. Nothing was retried. Check the browser and quit it with Cmd+Q before a new import.", language: language)
        case .connection: return L10n.text("Не удалось подготовить проверенное подключение к браузеру чата. Cookies не отправлены.", "Could not prepare a verified connection to this chat's browser. Cookies were not sent.", language: language)
        case .missingEnvironment: return L10n.text("У чата ещё нет среды браузера. Примени настройку браузера и открой чат снова.", "This chat has no browser environment yet. Apply the browser setting and reopen the chat.", language: language)
        case .browserLimit: return L10n.text("Достигнут лимит одновременно открытых браузеров Switchboard. Cookies не отправлены; заверши неиспользуемый браузер чата или увеличь лимит в настройках.", "The Switchboard limit of simultaneously open browsers is reached. Cookies were not sent; quit an unused chat browser or increase the limit in settings.", language: language)
        case .empty: return L10n.text("В профиле нет поддерживаемых действующих cookies для импорта.", "The profile has no supported, unexpired cookies to import.", language: language)
        case .indexedDBDisabled: return L10n.text("Перенос IndexedDB не разрешён для этого сайта. Включи его в Браузер → Импорт сессии для конкретного сайта.", "IndexedDB transfer is not enabled for this site. Enable it in Browser → Import session for a specific site.", language: language)
        case .indexedDBMissing: return L10n.text("В выбранном профиле Chrome нет базы IndexedDB для этого сайта. Перенос не выполнен.", "The selected Chrome profile has no IndexedDB store for this site. Nothing was transferred.", language: language)
        }
    }
}

public struct ChromeCookieProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

/// Secret values stay in memory and travel only to the app-owned Chrome endpoint.
public struct ImportedChromeCookie: Sendable, Equatable {
    public let host: String
    public let name: String
    public let value: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let sameSite: String?
    public let expires: Double?

    public var parameters: JSONValue {
        var fields: [String: JSONValue] = ["url": .string((secure ? "https://" : "http://") + host.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "/"),
            "name": .string(name), "value": .string(value), "path": .string(path), "secure": .bool(secure), "httpOnly": .bool(httpOnly)]
        if host.hasPrefix(".") { fields["domain"] = .string(host) }
        if let sameSite { fields["sameSite"] = .string(sameSite) }
        if let expires { fields["expires"] = .number(expires) }
        return .object(fields)
    }
    public func matches(_ stored: JSONValue, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard stored["domain"].string == host, stored["name"].string == name,
              stored["value"].string == value, stored["path"].string == path,
              stored["secure"].bool == secure, stored["httpOnly"].bool == httpOnly else { return false }
        if let sameSite, stored["sameSite"].string != sameSite { return false }
        if let expires {
            guard case .number(let actual) = stored["expires"], actual.isFinite, actual > now, actual <= expires + 1,
                  stored["session"].bool == false else { return false }
        } else if stored["session"].bool != true { return false }
        return true
    }
}

public struct ChromeCookieRead: Sendable {
    public var cookies: [ImportedChromeCookie] = []
    public var expired = 0
    public var partitioned = 0
    public var unsupported = 0
    public var skipped: Int { expired + partitioned + unsupported }
}

public enum ChromeCookieSource {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true) }
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumCookies = 20_000

    private static func profileID(_ value: String) -> Bool {
        value == "Default" || (value.hasPrefix("Profile ") && !value.dropFirst(8).isEmpty && value.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber })
    }
    private static func checked(_ relative: String, root: URL) throws -> URL {
        let source = root.appendingPathComponent(relative).standardizedFileURL
        guard source.resolvingSymlinksInPath().path == source.path,
              source.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ChromeCookieError.invalidProfile }
        return source
    }
    public static func profiles(root: URL = directory) throws -> [ChromeCookieProfile] {
        let file = try checked("Local State", root: root)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ChromeCookieError.unavailable }
        return try json["profile"]["info_cache"].object.keys.filter(profileID).sorted().compactMap { id in
            let folder = try checked(id, root: root)
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return ChromeCookieProfile(id: id, name: json["profile"]["info_cache"][id]["name"].string ?? id)
        }
    }

    /// Reads an encrypted database snapshot; never opens the user's database with SQLite.
    /// While Chrome runs, the main file and its WAL are copied together and SQLite replays the WAL on the copy only.
    public static func read(profile: String, root: URL = directory, now: Double = Date().timeIntervalSince1970,
                            site: String? = nil, pageHost: String? = nil, sourceIsRunning: () -> Bool,
                            key: () throws -> Data = keychainKey) throws -> ChromeCookieRead {
        try read(profile: profile, root: root, now: now, site: site, pageHost: pageHost, sourceIsRunning: sourceIsRunning, key: key,
                 temporaryRoot: FileManager.default.temporaryDirectory, afterCopy: { _ in })
    }

    static let snapshotAttempts = 3
    static let snapshotRetryDelay: TimeInterval = 0.2

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date?
    }
    private static func stamp(_ file: URL) throws -> FileStamp? {
        // URL resource values are cached per URL instance, so fresh attributes are read for every comparison.
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
              values[.type] as? FileAttributeType == .typeRegular, let size = (values[.size] as? NSNumber)?.intValue else { throw ChromeCookieError.unavailable }
        guard size <= maximumBytes else { throw ChromeCookieError.tooLarge }
        return FileStamp(size: size, modified: values[.modificationDate] as? Date)
    }

    static func read(profile: String, root: URL, now: Double, site: String?, pageHost: String? = nil, sourceIsRunning: () -> Bool, key: () throws -> Data,
                     temporaryRoot: URL, afterCopy: (Int) throws -> Void) throws -> ChromeCookieRead {
        guard profileID(profile), try profiles(root: root).contains(where: { $0.id == profile }) else { throw ChromeCookieError.invalidProfile }
        let choices = try ["\(profile)/Network/Cookies", "\(profile)/Cookies"].map { (try checked($0, root: root), try checked($0 + "-wal", root: root)) }
        guard let (source, wal) = choices.first(where: { FileManager.default.fileExists(atPath: $0.0.path) }) else { throw ChromeCookieError.unavailable }
        let running = sourceIsRunning()
        // A locked or unreadable file is reported as "running" only when Chrome is open; otherwise it is a plain read failure.
        let blocked = running ? ChromeCookieError.sourceRunning : .unavailable
        var files: [(name: String, bytes: Data)] = []
        var stable = false
        for attempt in 1...snapshotAttempts {
            if attempt > 1 { Thread.sleep(forTimeInterval: snapshotRetryDelay) }
            let before = (try stamp(source), try stamp(wal))
            guard before.0 != nil else { throw ChromeCookieError.unavailable }
            // The WAL may hold committed rows that are not checkpointed yet; copy it whenever Chrome may be writing.
            let includeWAL = before.1 != nil && (running || before.1!.size > 0)
            do {
                files = [(source.lastPathComponent, try Data(contentsOf: source))]
                if includeWAL { files.append((wal.lastPathComponent, try Data(contentsOf: wal))) }
            } catch { throw blocked }
            guard files.allSatisfy({ $0.bytes.count <= maximumBytes }) else { throw ChromeCookieError.tooLarge }
            try afterCopy(attempt)
            let after = (try stamp(source), try stamp(wal))
            if before == after, files[0].bytes.count == before.0?.size, !includeWAL || files[1].bytes.count == before.1?.size {
                stable = true; break
            }
        }
        guard stable else { throw ChromeCookieError.sourceChanged }
        let temporary = temporaryRoot.appendingPathComponent("contextdesk-cookie-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        for file in files {
            // Cookies-shm is never copied; SQLite rebuilds it next to the snapshot.
            guard FileManager.default.createFile(atPath: temporary.appendingPathComponent(file.name).path, contents: file.bytes,
                                                 attributes: [.posixPermissions: 0o600]) else { throw ChromeCookieError.unavailable }
        }
        return try decode(snapshot: temporary.appendingPathComponent(source.lastPathComponent), now: now, site: site, pageHost: pageHost, key: key)
    }

    static func decode(snapshot: URL, now: Double, site: String? = nil, pageHost: String? = nil, key: () throws -> Data) throws -> ChromeCookieRead {
        var database: OpaquePointer?
        // A normal (not immutable) open lets SQLite replay a copied WAL into this private snapshot.
        guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = database else {
            if let database { sqlite3_close(database) }; throw ChromeCookieError.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        // A torn copy must fail loudly instead of yielding a silently partial cookie list.
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement); throw ChromeCookieError.sourceChanged
        }
        let healthy = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_text(statement, 0).map { String(cString: $0) } == "ok"
        sqlite3_finalize(statement); statement = nil
        guard healthy else { throw ChromeCookieError.sourceChanged }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &statement, nil) == SQLITE_OK else { throw ChromeCookieError.unsupportedSchema }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement); statement = nil
        // Chromium's v24 adds the domain hash; future schemas require review.
        guard version == 23 || version == 24 else { throw ChromeCookieError.unsupportedSchema }
        let sql = "SELECT host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite,top_frame_site_key,has_expires FROM cookies LIMIT 20001"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let row = statement else { throw ChromeCookieError.unsupportedSchema }
        defer { sqlite3_finalize(row) }
        func text(_ column: Int32) -> String? {
            let length = Int(sqlite3_column_bytes(row, column))
            guard length <= 1024 * 1024 else { return nil }
            guard let bytes = sqlite3_column_text(row, column) else { return "" }
            let data = Data(bytes: bytes, count: length)
            guard !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        var result = ChromeCookieRead(), material: Data?, count = 0, outputBytes = 0
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            count += 1
            guard count <= maximumCookies else { throw ChromeCookieError.tooLarge }
            defer { step = sqlite3_step(row) }
            guard let host = text(0), let name = text(1), let path = text(4), let partition = text(9) else {
                result.unsupported += 1; continue
            }
            if let site, !ChromeSessionImportPolicy.includes(host: host, site: site) { continue }
            if let pageHost, !ChromeSessionImportPolicy.sent(cookieHost: host, toPageHost: pageHost) { continue }
            if !partition.isEmpty { result.partitioned += 1; continue }
            let expiry = sqlite3_column_int(row, 10) == 0 ? nil : Optional(Double(sqlite3_column_int64(row, 5)) / 1_000_000 - 11_644_473_600)
            if let expiry, expiry <= now { result.expired += 1; continue }
            let sameSite = sqlite3_column_int(row, 8)
            guard [-1, 0, 1, 2].contains(sameSite), !host.isEmpty, host.utf8.count <= 255,
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                  !host.hasSuffix("."), !host.contains(".."), !name.isEmpty, name.utf8.count <= 4096,
                  !name.contains(where: { $0.asciiValue.map { $0 <= 32 || $0 >= 127 } ?? true }),
                  !name.contains(where: { "()<>@,;:\\\"/[]?={}".contains($0) }), path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { result.unsupported += 1; continue }
            let length = Int(sqlite3_column_bytes(row, 3))
            guard length <= 1024 * 1024 else { throw ChromeCookieError.tooLarge }
            let encrypted = sqlite3_column_blob(row, 3).map { Data(bytes: $0, count: length) } ?? Data()
            let value: String
            if encrypted.isEmpty {
                guard let plain = text(2) else { result.unsupported += 1; continue }
                value = plain
            }
            else {
                guard encrypted.starts(with: Data("v10".utf8)) else { result.unsupported += 1; continue }
                if material == nil { material = try key() }
                guard let decoded = decrypt(encrypted, key: material!, host: host, schema: Int(version)) else { result.unsupported += 1; continue }
                value = decoded
            }
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { result.unsupported += 1; continue }
            outputBytes += value.utf8.count + name.utf8.count + host.utf8.count + path.utf8.count
            guard outputBytes <= 16 * 1024 * 1024 else { throw ChromeCookieError.tooLarge }
            result.cookies.append(.init(host: host, name: name, value: value, path: path, secure: sqlite3_column_int(row, 6) != 0,
                                        httpOnly: sqlite3_column_int(row, 7) != 0, sameSite: [0: "None", 1: "Lax", 2: "Strict"][sameSite], expires: expiry))
        }
        guard step == SQLITE_DONE else { throw ChromeCookieError.unavailable }
        return result
    }

    public static func keychainKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let secret = found as? Data, !secret.isEmpty else { throw ChromeCookieError.keychain }
        return try deriveKey(secret)
    }
    static func deriveKey(_ secret: Data) throws -> Data {
        let salt = Data("saltysalt".utf8); var result = Data(count: 16)
        let status = result.withUnsafeMutableBytes { output in secret.withUnsafeBytes { password in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: Int8.self).baseAddress, secret.count,
                                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, output.bindMemory(to: UInt8.self).baseAddress, 16)
        } } }
        guard status == kCCSuccess else { throw ChromeCookieError.keychain }; return result
    }
    static func decrypt(_ encrypted: Data, key: Data, host: String, schema: Int) -> String? {
        guard key.count == 16, encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { return nil }
        let payload = Data(encrypted.dropFirst(3)), iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: payload.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { destination in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in payload.withUnsafeBytes { source in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, payload.count,
                    destination.baseAddress, capacity, &written)
        } } } }
        guard status == kCCSuccess else { return nil }
        output.count = written
        if schema >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard output.starts(with: digest) else { return nil }
            output.removeFirst(32)
        }
        return String(data: output, encoding: .utf8)
    }
}
