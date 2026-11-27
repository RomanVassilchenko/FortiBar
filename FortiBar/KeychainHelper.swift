import Foundation
import Security
import os

private let log = Logger(subsystem: "com.romanvassilchenko.FortiBar", category: "keychain")

/// Server passwords in the login Keychain.
///
/// All passwords live in ONE item (a JSON object `{serverID: password}`). Keychain grants access
/// per item, and for an app without a Team ID per build: with an item per server, every update
/// asked once for each server. One item means one question.
struct KeychainStore {
    let service: String
    let account: String
    /// Move the older one-item-per-server layout into the single item on first use
    let migratesPerServerItems: Bool

    private let lock = KeychainLock()

    init(service: String, account: String = "all-passwords", migratesPerServerItems: Bool = false) {
        self.service = service
        self.account = account
        self.migratesPerServerItems = migratesPerServerItems
    }

    private enum Loaded {
        case found([String: String])
        case missing
        case failed(OSStatus)
    }

    // MARK: - Public

    func read(for serverID: String) -> String? {
        lock.withLock {
            migrateIfNeeded()
            if case .found(let all) = load() { return all[serverID] }
            return nil
        }
    }

    /// Server ids that have a non-empty password, with a single Keychain read.
    func serverIDsWithPassword() -> Set<String> {
        lock.withLock {
            migrateIfNeeded()
            if case .found(let all) = load() {
                return Set(all.filter { !$0.value.isEmpty }.keys)
            }
            return []
        }
    }

    func save(password: String, for serverID: String) -> Bool {
        lock.withLock {
            migrateIfNeeded()
            switch load() {
            case .found(var all):
                all[serverID] = password
                return write(all, exists: true)
            case .missing:
                return write([serverID: password], exists: false)
            case .failed:
                // Never overwrite what could not be read (access denied, Keychain locked)
                return false
            }
        }
    }

    func delete(for serverID: String) {
        lock.withLock {
            migrateIfNeeded()
            if case .found(var all) = load(), all.removeValue(forKey: serverID) != nil {
                _ = write(all, exists: true)
            }
            // A per-server item the migration could not move (access denied) goes too
            SecItemDelete(perServerQuery(serverID) as CFDictionary)
        }
    }

    // MARK: - Single item

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func load() -> Loaded {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let all = try? JSONDecoder().decode([String: String].self, from: data) else {
                log.error("The password item is not readable as JSON")
                return .failed(errSecDecode)
            }
            return .found(all)
        case errSecItemNotFound:
            return .missing
        default:
            log.error("Could not read the password item: \(status)")
            return .failed(status)
        }
    }

    private func write(_ all: [String: String], exists: Bool) -> Bool {
        guard let data = try? JSONEncoder().encode(all) else { return false }
        let status: OSStatus
        if exists {
            status = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = itemQuery
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("Could not write the password item: \(status)")
        }
        return status == errSecSuccess
    }

    // MARK: - Migration from one item per server

    private func perServerQuery(_ serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID
        ]
    }

    /// Per-server items still in the Keychain. Listing attributes needs no access to the secrets.
    private func perServerAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != account }
    }

    /// Moves each per-server item into the single item, deleting it only after the single item
    /// holds it. Items that cannot be read (access denied) stay and are tried again next launch.
    private func migrateIfNeeded() {
        guard migratesPerServerItems, !migrationChecked.value else { return }
        let accounts = perServerAccounts()
        guard !accounts.isEmpty else {
            migrationChecked.value = true
            return
        }

        var all: [String: String] = [:]
        var exists = false
        switch load() {
        case .found(let current): all = current; exists = true
        case .missing: break
        case .failed: return  // try again later; never replace an item that could not be read
        }

        var moved: [String] = []
        for serverID in accounts {
            var query = perServerQuery(serverID)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                log.error("Could not read a password item for migration: \(status)")
                continue
            }
            // A password already saved in the single item wins
            if all[serverID] == nil { all[serverID] = password }
            moved.append(serverID)
        }

        guard !moved.isEmpty else { return }
        guard write(all, exists: exists) else { return }
        for serverID in moved {
            let status = SecItemDelete(perServerQuery(serverID) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log.error("Could not delete a migrated password item: \(status)")
            }
        }
        // Complete only when nothing was left behind
        migrationChecked.value = moved.count == accounts.count
    }

    private let migrationChecked = Flag()
}

/// Reference-typed so a `let` store can remember things.
private final class Flag: @unchecked Sendable {
    var value = false
}

private final class KeychainLock: @unchecked Sendable {
    private let lock = NSLock()
    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The app's passwords: unit tests get a store of their own, never the real one.
struct KeychainHelper {
    static let service = "com.romanvassilchenko.FortiBar.vpn"

    private static let store = KeychainStore(
        service: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? service + ".tests" : service,
        migratesPerServerItems: true
    )

    static func save(password: String, for serverID: String) -> Bool {
        store.save(password: password, for: serverID)
    }

    static func read(for serverID: String) -> String? {
        store.read(for: serverID)
    }

    static func serverIDsWithPassword() -> Set<String> {
        store.serverIDsWithPassword()
    }

    static func delete(for serverID: String) {
        store.delete(for: serverID)
    }
}
