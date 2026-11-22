import Foundation
import Testing
@testable import FortiBar

struct CertificateTests {
    private let digest = "2d5a1b9e0f3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6"

    @Test func extractsDigestFromOpenfortivpnHint() {
        #expect(VPNManager.certificateDigest(in: "ERROR:      --trusted-cert \(digest)") == digest)
    }

    @Test func lowercasesDigest() {
        #expect(VPNManager.certificateDigest(in: "--trusted-cert \(digest.uppercased())") == digest)
    }

    @Test func ignoresLinesWithoutDigest() {
        #expect(VPNManager.certificateDigest(in: "ERROR:  Gateway certificate validation failed, rerun with:") == nil)
        #expect(VPNManager.certificateDigest(in: "--trusted-cert abc123") == nil)
    }

    @Test func pinningKeepsTheRestOfTheProfile() {
        let server = VPNServer(name: "Office", host: "vpn.example.com", port: 10443, username: "me",
                               password: nil, trustedCert: nil, id: "id-1", noRoutesDNS: true,
                               staticRoutes: ["10.0.0.0/8"], autoConnect: true, autoReconnect: true)
        let pinned = server.pinning(certificate: digest)
        #expect(pinned.trustedCert == digest)
        #expect(pinned.id == "id-1" && pinned.port == 10443 && pinned.noRoutesDNS)
        #expect(pinned.staticRoutes == ["10.0.0.0/8"] && pinned.autoConnect && pinned.autoReconnect)
    }
}

struct FailureParsingTests {
    private let server = VPNServer(name: "Office", host: "vpn.example.com", port: 443, username: "me",
                                   password: nil, trustedCert: nil)

    @Test func certificateErrorDependsOnPinning() {
        let line = "ERROR: certificate error"
        #expect(VPNManager.failureReason(in: line, server: server)?.contains("could not be verified") == true)
        let pinned = server.pinning(certificate: String(repeating: "a", count: 64))
        #expect(VPNManager.failureReason(in: line, server: pinned)?.contains("no longer matches") == true)
    }

    @Test func authenticationFailureIsFatal() {
        let reason = VPNManager.failureReason(in: "ERROR: Authentication failed", server: server)
        #expect(reason != nil && VPNManager.isFatal(reason!))
    }

    @Test func authenticationHintMentioningCertificatesIsNotACertificateError() {
        // openfortivpn's own wording: "... check the password, client certificate, etc."
        let line = "ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc."
        #expect(VPNManager.failureReason(in: line, server: server)?.hasPrefix("Authentication failed") == true)
    }

    @Test func parsesTunnelAddressAndInterface() {
        #expect(VPNManager.assignedAddress(in: "INFO: Got addresses: [10.0.0.5], ns [1.1.1.1]") == "10.0.0.5")
        #expect(VPNManager.interfaceName(in: "Using interface ppp3") == "ppp3")
    }
}

struct SudoersAndRoutesTests {
    @Test func ruleAllowsOnlyTheBinaryUnlessRoutesAreNeeded() {
        let plain = SudoersManager.ruleContent(user: "me", binaryPath: "/opt/homebrew/bin/openfortivpn", includeRoutes: false)
        #expect(plain == ["me ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn"])
        let withRoutes = SudoersManager.ruleContent(user: "me", binaryPath: "/opt/homebrew/bin/openfortivpn", includeRoutes: true)
        #expect(withRoutes.count == 2 && withRoutes[1].contains("/sbin/route -n add -net * -interface ppp*"))
    }

    @Test func rulePathUsesTheNewName() {
        #expect(SudoersManager.rulePath == "/etc/sudoers.d/fortibar")
        #expect(LegacyMigration.legacySudoersRulePath != SudoersManager.rulePath)
    }

    @Test func cidrValidation() {
        #expect(VPNServer.isValidCIDR("10.20.30.0/24"))
        #expect(!VPNServer.isValidCIDR("10.20.30.0/33"))
        #expect(!VPNServer.isValidCIDR("300.1.1.1/8"))
        #expect(!VPNServer.isValidCIDR("10.0.0.0/8; rm -rf /"))
    }
}

struct MigrationTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fortibar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func configFolderMovesAndOldOneIsRemoved() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("OldApp"), new = root.appendingPathComponent("NewApp")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{\"servers\":[]}".utf8).write(to: old.appendingPathComponent("config.json"))
        try Data("runtime".utf8).write(to: old.appendingPathComponent("state.json"))
        try Data("backup".utf8).write(to: old.appendingPathComponent("config.json.bak"))

        LegacyMigration.migrateConfigFolder(from: old, to: new)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: new.appendingPathComponent("config.json").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("config.json.bak").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("state.json").path))
        #expect(!fm.fileExists(atPath: old.path))
    }

    @Test func existingNewConfigIsNeverOverwritten() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("OldApp"), new = root.appendingPathComponent("NewApp")
        for folder in [old, new] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: old.appendingPathComponent("config.json"))
        try Data("new".utf8).write(to: new.appendingPathComponent("config.json"))

        LegacyMigration.migrateConfigFolder(from: old, to: new)

        #expect(try String(contentsOf: new.appendingPathComponent("config.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path))
    }

    @Test func logsMoveToTheNewName() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("OldLogs")
        let newLog = root.appendingPathComponent("NewLogs/new.log")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("line".utf8).write(to: old.appendingPathComponent("openfortimac.log"))

        LegacyMigration.migrateLogs(from: old, to: newLog)

        #expect(try String(contentsOf: newLog, encoding: .utf8) == "line")
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}

import Security

struct KeychainMigrationTests {
    /// Uses a throw-away account name in the real Keychain; the real saved passwords are not touched.
    @Test func passwordMovesToTheNewService() throws {
        let account = "fortibar-test-\(UUID().uuidString)"
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.openfortimac.vpn",
            kSecAttrAccount as String: account
        ]
        var add = legacy
        add[kSecValueData as String] = Data("secret".utf8)
        defer {
            SecItemDelete(legacy as CFDictionary)
            KeychainHelper.delete(for: account)
        }
        // No usable Keychain (e.g. a locked CI session): nothing to test
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return }

        #expect(LegacyMigration.migratePassword(account: account))

        #expect(KeychainHelper.read(for: account) == "secret")
        #expect(SecItemCopyMatching(legacy as CFDictionary, nil) == errSecItemNotFound)
    }
}
