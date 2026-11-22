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
