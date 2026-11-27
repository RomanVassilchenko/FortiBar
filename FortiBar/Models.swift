import Foundation
import CryptoKit

struct AppConfig: Codable {
    var servers: [VPNServer]
    var openfortivpnPath: String
    /// Off by default: connecting to a server first drops the current tunnel,
    /// as in earlier versions. On: every server runs its own tunnel side by side.
    var allowMultipleConnections: Bool
    /// On by default: probe connected tunnels and restart one that stopped passing traffic,
    /// e.g. after the Mac woke from sleep.
    var healthCheck: Bool

    static let defaultOpenfortivpnPath = "/opt/homebrew/bin/openfortivpn"

    static let `default` = AppConfig(
        servers: [],
        openfortivpnPath: defaultOpenfortivpnPath
    )

    enum CodingKeys: String, CodingKey {
        case servers
        case openfortivpnPath = "openfortivpn_path"
        case allowMultipleConnections = "allow_multiple_connections"
        case healthCheck = "health_check"
        // "menu_bar_icon" (classic/monochrome) from 1.4 is no longer a setting:
        // it is not listed here, so old files still decode and the key is dropped on save
    }

    init(
        servers: [VPNServer],
        openfortivpnPath: String,
        allowMultipleConnections: Bool = false,
        healthCheck: Bool = true
    ) {
        self.servers = servers
        self.openfortivpnPath = openfortivpnPath
        self.allowMultipleConnections = allowMultipleConnections
        self.healthCheck = healthCheck
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = Self.uniquingIDs(try container.decodeIfPresent([VPNServer].self, forKey: .servers) ?? [])
        openfortivpnPath = try container.decodeIfPresent(String.self, forKey: .openfortivpnPath) ?? Self.defaultOpenfortivpnPath
        allowMultipleConnections = try container.decodeIfPresent(Bool.self, forKey: .allowMultipleConnections) ?? false
        healthCheck = try container.decodeIfPresent(Bool.self, forKey: .healthCheck) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(openfortivpnPath, forKey: .openfortivpnPath)
        // Written only when enabled, so existing config files stay unchanged
        if allowMultipleConnections {
            try container.encode(true, forKey: .allowMultipleConnections)
        }
        if !healthCheck {
            try container.encode(false, forKey: .healthCheck)
        }
    }

    /// Two hand-written profiles without an id (or with the same one) would share Keychain
    /// items and tunnel state: later duplicates get a deterministic "-2", "-3"… suffix.
    static func uniquingIDs(_ servers: [VPNServer]) -> [VPNServer] {
        var seen: Set<String> = []
        return servers.map { server in
            guard seen.contains(server.id) else {
                seen.insert(server.id)
                return server
            }
            var counter = 2
            while seen.contains("\(server.id)-\(counter)") { counter += 1 }
            let id = "\(server.id)-\(counter)"
            seen.insert(id)
            return VPNServer(
                name: server.name, host: server.host, port: server.port, username: server.username,
                password: server.password, trustedCert: server.trustedCert, icon: server.icon, id: id,
                noRoutesDNS: server.noRoutesDNS, staticRoutes: server.staticRoutes,
                autoConnect: server.autoConnect, autoReconnect: server.autoReconnect,
                healthCheckHost: server.healthCheckHost
            )
        }
    }

    /// True when at least one server installs static routes (needs the extra sudo rule).
    var needsRoutePermission: Bool {
        servers.contains { !$0.validatedStaticRoutes.isEmpty }
    }
}

struct VPNServer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String?
    let trustedCert: String?
    /// SF Symbol shown next to the server name
    let icon: String?
    /// Pass --no-routes --no-dns: the tunnel leaves the routing table and the resolver alone,
    /// e.g. a secondary tunnel next to a primary one that owns the default routes.
    let noRoutesDNS: Bool
    /// Static routes (CIDR) installed through this tunnel's ppp interface
    /// when it comes up, and removed when it goes down.
    let staticRoutes: [String]
    /// Connect automatically when FortiBar starts.
    let autoConnect: Bool
    /// Reconnect when the tunnel drops (network change, gateway timeout, sleep)
    /// until the user disconnects.
    let autoReconnect: Bool
    /// Host inside the tunnel that the health check pings; nil: the tunnel's far end
    let healthCheckHost: String?

    static let defaultIcon = "server.rack"
    static let iconChoices = ["server.rack", "building.2", "briefcase", "house", "cloud", "lock.shield", "network", "desktopcomputer"]

    var iconName: String { icon ?? Self.defaultIcon }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, icon
        case trustedCert = "trusted_cert"
        case noRoutesDNS = "no_routes_dns"
        case staticRoutes = "static_routes"
        case autoConnect = "auto_connect"
        case autoReconnect = "auto_reconnect"
        case healthCheckHost = "health_check_host"
    }

    init(
        name: String,
        host: String,
        port: Int,
        username: String,
        password: String?,
        trustedCert: String?,
        icon: String? = nil,
        id: String? = nil,
        noRoutesDNS: Bool = false,
        staticRoutes: [String] = [],
        autoConnect: Bool = false,
        autoReconnect: Bool = false,
        healthCheckHost: String? = nil
    ) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.trustedCert = trustedCert
        self.icon = icon
        self.noRoutesDNS = noRoutesDNS
        self.staticRoutes = staticRoutes
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.healthCheckHost = healthCheckHost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 443
        username = try container.decode(String.self, forKey: .username)
        // A hand-written profile without an id: a random one would change on every load, so the
        // app and the CLI would disagree and the saved password would be lost after a restart
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Self.derivedID(name: name, host: host, port: port, username: username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        trustedCert = try container.decodeIfPresent(String.self, forKey: .trustedCert)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        noRoutesDNS = try container.decodeIfPresent(Bool.self, forKey: .noRoutesDNS) ?? false
        staticRoutes = try container.decodeIfPresent([String].self, forKey: .staticRoutes) ?? []
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        let host = try container.decodeIfPresent(String.self, forKey: .healthCheckHost)
        healthCheckHost = host?.isEmpty == false ? host : nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(trustedCert, forKey: .trustedCert)
        try container.encodeIfPresent(icon, forKey: .icon)
        // Optional features are written only when used, so plain profiles look as before
        if noRoutesDNS {
            try container.encode(true, forKey: .noRoutesDNS)
        }
        if !staticRoutes.isEmpty {
            try container.encode(staticRoutes, forKey: .staticRoutes)
        }
        if autoConnect {
            try container.encode(true, forKey: .autoConnect)
        }
        if autoReconnect {
            try container.encode(true, forKey: .autoReconnect)
        }
        try container.encodeIfPresent(healthCheckHost, forKey: .healthCheckHost)
    }

    /// Stable UUID-formatted id computed from the profile, for configs written without ids.
    static func derivedID(name: String, host: String, port: Int, username: String) -> String {
        let digest = SHA256.hash(data: Data("\(name)\u{0}\(host)\u{0}\(port)\u{0}\(username)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.joined(separator: "-")
    }

    /// The same profile with the gateway certificate pinned (SHA-256 digest as openfortivpn prints it).
    func pinning(certificate digest: String) -> VPNServer {
        VPNServer(
            name: name, host: host, port: port, username: username, password: password,
            trustedCert: digest, icon: icon, id: id, noRoutesDNS: noRoutesDNS,
            staticRoutes: staticRoutes, autoConnect: autoConnect, autoReconnect: autoReconnect,
            healthCheckHost: healthCheckHost
        )
    }

    /// Routes that passed the CIDR check: only these are ever handed to /sbin/route.
    var validatedStaticRoutes: [String] {
        staticRoutes.filter { Self.isValidCIDR($0) }
    }

    /// Strict IPv4 CIDR check: a.b.c.d/n with plain decimal parts. ASCII digits only, and no
    /// leading zeros: inet_aton (used by /sbin/route) reads "010" as octal 8.
    static func isValidCIDR(_ value: String) -> Bool {
        let octet = "(0|[1-9][0-9]{0,2})"
        guard value.range(of: "^\(octet)(\\.\(octet)){3}/(0|[1-9][0-9]?)$", options: .regularExpression) != nil else {
            return false
        }
        let parts = value.split(separator: "/")
        guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        return parts[0].split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    // == is synthesized over every field, so an edited profile is a different value and
    // SwiftUI redraws it. Hashing the id alone stays consistent (equal values share the id).
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
