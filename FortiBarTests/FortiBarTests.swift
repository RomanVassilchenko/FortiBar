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
        #expect(plain == [
            "me ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn",
            "me ALL = (root) NOPASSWD: /bin/kill -KILL [1-9][0-9], /bin/kill -KILL [1-9][0-9][0-9], "
                + "/bin/kill -KILL [1-9][0-9][0-9][0-9], /bin/kill -KILL [1-9][0-9][0-9][0-9][0-9]",
        ])
        let withRoutes = SudoersManager.ruleContent(user: "me", binaryPath: "/opt/homebrew/bin/openfortivpn", includeRoutes: true)
        #expect(withRoutes.count == 3 && withRoutes[2].contains("/sbin/route -n add -net * -interface ppp*"))
    }

    @Test func forceStopRuleHasNoSpaceCrossingWildcard() {
        // A sudoers "*" also matches spaces: "kill -KILL 1 -1" would kill every process
        for command in SudoersManager.forceStopCommands {
            #expect(command.hasPrefix("/bin/kill -KILL [1-9]"))
            #expect(!command.contains("*") && !command.contains("?"))
        }
        // The probe pid matches the longest pattern
        #expect(String(SudoersManager.forceStopProbePID).count == SudoersManager.forceStopCommands.count + 1)
    }

    @Test func forceStopProbeClassification() {
        #expect(SudoersManager.forceStopProbeSucceeded(status: 1, output: "kill: 99999: No such process\n"))
        #expect(SudoersManager.forceStopProbeSucceeded(status: 0, output: ""))
        #expect(!SudoersManager.forceStopProbeSucceeded(status: 1, output: "sudo: a password is required\n"))
        #expect(!SudoersManager.forceStopProbeSucceeded(status: 1, output: "Sorry, user me is not allowed to execute '/bin/kill -KILL 99999' as root on mac.\n"))
        #expect(!SudoersManager.forceStopProbeSucceeded(status: 1, output: "sudo: me may not run sudo on mac\n"))
        // Unknown failures (e.g. sudo missing) are not evidence that the rule works
        #expect(!SudoersManager.forceStopProbeSucceeded(status: -1, output: "The file doesn't exist."))
    }

    @Test func forceStopArgumentsOnlyForAllowedPIDs() {
        #expect(SudoersManager.forceStopArguments(pid: 4242) == ["-n", "/bin/kill", "-KILL", "4242"])
        #expect(SudoersManager.forceStopArguments(pid: 10) != nil)
        #expect(SudoersManager.forceStopArguments(pid: 99_998) != nil)
        for pid: Int32 in [-1, 0, 1, 9, 99_999, 100_000, .max] {
            #expect(SudoersManager.forceStopArguments(pid: pid) == nil)
        }
    }

    @Test func parsesPgrepOutput() {
        #expect(VPNManager.parsePIDs("123\n456\n") == [123, 456])
        #expect(VPNManager.parsePIDs("") == [])
        #expect(VPNManager.parsePIDs(" 77 \n-1\n0\nabc\n12 34\n٣\n99999999999\n") == [77])
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
        #expect(VPNServer.isValidCIDR("0.0.0.0/0"))
    }

    @Test func cidrRejectsOctalLookingAndNonASCIIDigits() {
        // inet_aton would read 010 as 8
        #expect(!VPNServer.isValidCIDR("010.0.0.0/8"))
        #expect(!VPNServer.isValidCIDR("10.0.0.0/08"))
        #expect(!VPNServer.isValidCIDR("\u{0661}0.0.0.0/8"))
    }
}

struct ConfigCodingTests {
    @Test func oldMenuBarIconSettingIsIgnoredAndNotWrittenBack() throws {
        let json = """
        {"servers":[{"name":"Office","host":"vpn.example.com","username":"me"}],
         "openfortivpn_path":"/usr/local/bin/openfortivpn",
         "allow_multiple_connections":true,
         "menu_bar_icon":"classic"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.servers.map(\.name) == ["Office"])
        #expect(config.openfortivpnPath == "/usr/local/bin/openfortivpn")
        #expect(config.allowMultipleConnections)

        let encoded = try #require(String(data: JSONEncoder().encode(config), encoding: .utf8))
        #expect(!encoded.contains("menu_bar_icon"))
    }

    @Test func serverWithoutIDGetsTheSameIDOnEveryLoad() throws {
        let json = Data(#"{"servers":[{"name":"Office","host":"vpn.example.com","username":"me"}]}"#.utf8)
        let first = try JSONDecoder().decode(AppConfig.self, from: json)
        let second = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(first.servers[0].id == second.servers[0].id)
        #expect(UUID(uuidString: first.servers[0].id) != nil)
    }

    @Test func duplicateIDsAreMadeUnique() throws {
        let json = Data("""
        {"servers":[{"id":"a","name":"One","host":"h1","username":"u"},
                    {"id":"a","name":"Two","host":"h2","username":"u"},
                    {"name":"Same","host":"h","username":"u"},
                    {"name":"Same","host":"h","username":"u"}]}
        """.utf8)
        let ids = try JSONDecoder().decode(AppConfig.self, from: json).servers.map(\.id)
        #expect(ids[0] == "a" && ids[1] == "a-2")
        #expect(Set(ids).count == 4)
    }
}

struct CLIParsingTests {
    @Test func parsesValuesFlagsAndPositionals() throws {
        let options = try #require(CommandLineTool.parseOptions(
            ["Office", "--host=vpn.example.com", "--username", "me", "--route", "10.0.0.0/8", "--route", "10.1.0.0/16", "-y"]))
        #expect(options.positional == ["Office"])
        #expect(options.value("--host") == "vpn.example.com" && options.value("--user") == "me")
        #expect(options.all("--route") == ["10.0.0.0/8", "10.1.0.0/16"])
        #expect(options.has("-y"))
    }

    @Test func rejectsUnknownFlagsAndMissingValues() {
        #expect(CommandLineTool.parseOptions(["x", "--auto-conect"]) == nil)
        #expect(CommandLineTool.parseOptions(["x", "--host"]) == nil)
        #expect(CommandLineTool.parseOptions(["x", "--host", "--user", "me"]) == nil)
        #expect(CommandLineTool.parseOptions(["x", "--auto-connect=yes"]) == nil)
    }

    @Test func validationRejectsLineBreaksThatWouldInjectOpenfortivpnOptions() {
        func server(host: String = "vpn.example.com", user: String = "me", cert: String? = nil) -> VPNServer {
            VPNServer(name: "Office", host: host, port: 443, username: user, password: nil, trustedCert: cert)
        }
        #expect(CommandLineTool.validate(server()) == nil)
        #expect(CommandLineTool.validate(server(user: "me\npppd-plugin = /tmp/x.so")) != nil)
        #expect(CommandLineTool.validate(server(host: "vpn\rexample")) != nil)
        #expect(CommandLineTool.validate(server(cert: "abc\nset-dns = 0")) != nil)
    }

    @Test func editKeepsAnIconThatIsNoLongerOffered() {
        let old = VPNServer(name: "Office", host: "h", port: 443, username: "u", password: nil,
                            trustedCert: nil, icon: "globe", id: "id-1")
        #expect(CommandLineTool.validate(old, previous: old) == nil)
        #expect(CommandLineTool.validate(old) != nil)
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

    @Test func oldLogIsKeptWhenANewOneAlreadyExists() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("OldLogs")
        let newLog = root.appendingPathComponent("NewLogs/new.log")
        for folder in [old, newLog.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: old.appendingPathComponent("openfortimac.log"))
        try Data("old rotated".utf8).write(to: old.appendingPathComponent("openfortimac.log.1"))
        try Data("new".utf8).write(to: newLog)

        LegacyMigration.migrateLogs(from: old, to: newLog)

        #expect(try String(contentsOf: newLog, encoding: .utf8) == "new")
        #expect(try String(contentsOf: URL(fileURLWithPath: newLog.path + ".1"), encoding: .utf8) == "old rotated")
        #expect(try String(contentsOf: old.appendingPathComponent("openfortimac.log"), encoding: .utf8) == "old")
    }
}

struct ServerEqualityTests {
    @Test func editedProfileIsNotEqualButHashesLikeTheOriginal() {
        let server = VPNServer(name: "Office", host: "vpn.example.com", port: 443, username: "me",
                               password: nil, trustedCert: nil, id: "id-1")
        let pinned = server.pinning(certificate: String(repeating: "a", count: 64))
        #expect(server == server)
        #expect(pinned != server)
        #expect(pinned.hashValue == server.hashValue)
        #expect(Set([server, pinned]).count == 2)

        let other = VPNServer(name: "Office", host: "vpn.example.com", port: 443, username: "me",
                              password: nil, trustedCert: nil, id: "id-2")
        #expect(other != server)
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
