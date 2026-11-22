import Foundation
import Security
import os

private let log = Logger(subsystem: "com.romanvassilchenko.FortiBar", category: "migration")

/// One-time migration of data written under the app's former name (OpenFortiMac).
///
/// This is the only place that still mentions the old name: the identifiers below
/// are what earlier versions stored on disk, in the Keychain and in sudoers.d.
/// Nothing is deleted before its replacement has been written.
enum LegacyMigration {
    private static let legacyAppFolder = "OpenFortiMac"
    private static let legacyLogFolder = "OpenFortiMac"
    private static let legacyLogName = "openfortimac.log"
    private static let legacyKeychainService = "com.openfortimac.vpn"

    /// Sudoers rule of earlier versions. SudoersManager replaces it with its own rule.
    static let legacySudoersRulePath = "/etc/sudoers.d/openfortimac"

    /// Unit tests are hosted in the app and must never touch the real home folder or Keychain.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // MARK: - Files

    /// Moves ~/Library/Application Support/OpenFortiMac (config.json) and the log files
    /// to their FortiBar locations. No Keychain access, so the CLI can run it too.
    static func migrateFiles() {
        guard !isRunningTests else { return }
        migrateConfigFolder()
        migrateLogs()
    }

    private static func migrateConfigFolder() {
        let fm = FileManager.default
        let oldFolder = ConfigManager.configPath.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(legacyAppFolder)
        let newFolder = ConfigManager.configPath.deletingLastPathComponent()

        guard fm.fileExists(atPath: oldFolder.appendingPathComponent("config.json").path) else { return }

        // The new app already has its own settings (fresh start): leave the old ones alone
        guard !fm.fileExists(atPath: ConfigManager.configPath.path) else { return }

        do {
            try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: oldFolder.path) where name != "state.json" {
                let destination = newFolder.appendingPathComponent(name)
                if !fm.fileExists(atPath: destination.path) {
                    try fm.copyItem(at: oldFolder.appendingPathComponent(name), to: destination)
                }
            }
            try fm.removeItem(at: oldFolder)
            log.info("Migrated settings from the previous app folder")
        } catch {
            // The copy is partial at worst and the old folder is still there: it is retried next launch
            log.error("Settings migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func migrateLogs() {
        let fm = FileManager.default
        let oldFolder = CLIProtocol.logURL.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(legacyLogFolder)
        guard fm.fileExists(atPath: oldFolder.path) else { return }

        let newLog = CLIProtocol.logURL
        do {
            try fm.createDirectory(at: newLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            for suffix in ["", ".1"] {
                let old = oldFolder.appendingPathComponent(legacyLogName + suffix)
                let new = URL(fileURLWithPath: newLog.path + suffix)
                if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                    try fm.moveItem(at: old, to: new)
                }
            }
            try fm.removeItem(at: oldFolder)
        } catch {
            log.error("Log migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Keychain

    private static var keychainMarker: URL {
        ConfigManager.configPath.deletingLastPathComponent().appendingPathComponent(".keychain-migrated")
    }

    /// Copies every password stored under the old Keychain service to the new one, then
    /// deletes the old item. macOS may ask once whether FortiBar can use the old items.
    /// Blocking: call it from the app only, never from the CLI.
    static func migrateKeychain() {
        let fm = FileManager.default
        guard !isRunningTests, !fm.fileExists(atPath: keychainMarker.path) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            markKeychainDone()
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            log.error("Could not list old Keychain items: \(status)")
            return
        }

        var complete = true
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            complete = migratePassword(account: account) && complete
        }
        // Not marked on failure (for example the user denied access): retried on the next launch
        if complete { markKeychainDone() }
    }

    private static func migratePassword(account: String) -> Bool {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: account
        ]

        var readQuery = itemQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)

        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            log.error("Could not read an old Keychain item: \(status)")
            return false
        }

        // A password already saved under the new name wins
        if KeychainHelper.read(for: account) == nil {
            guard KeychainHelper.save(password: password, for: account) else {
                log.error("Could not write a password to the new Keychain service")
                return false
            }
        }

        let deleteStatus = SecItemDelete(itemQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            log.error("Could not delete an old Keychain item: \(deleteStatus)")
            return false
        }
        return true
    }

    private static func markKeychainDone() {
        try? FileManager.default.createDirectory(
            at: keychainMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keychainMarker.path, contents: nil)
    }
}
