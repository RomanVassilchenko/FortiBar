import Foundation
import AppKit
import UserNotifications
import Combine
import Network

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(serverName: String)
    case disconnecting
    /// Auto-reconnect: next attempt at the given time, or nil while waiting for the network
    case reconnecting(at: Date?)
}

extension VPNState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Live state of one tunnel, published to the UI.
struct TunnelStatus: Identifiable, Equatable {
    let serverID: String
    /// Identifies the current connection attempt, so a cancelled one that is still
    /// starting up cannot take over a newer one
    var attempt = UUID()
    /// Consecutive auto-reconnect attempts, 0 outside a reconnect cycle
    var reconnectAttempt = 0
    var state: VPNState = .disconnected
    var serverName: String = ""
    var assignedIP: String?
    /// ppp interface picked by pppd ("ppp0", "ppp1", …): numbering is dynamic,
    /// so it is read from the output once the tunnel is up.
    var interface: String?
    var connectedSince: Date?
    /// Static routes currently installed through this tunnel
    var routes: [String] = []

    var id: String { serverID }

    var isConnected: Bool { state.isConnected }

    var isBusy: Bool {
        switch state {
        case .connecting, .disconnecting, .reconnecting: return true
        case .connected, .disconnected: return false
        }
    }
}

/// Everything owned by one running openfortivpn process.
private final class TunnelConnection {
    let server: VPNServer
    let process: Process
    let pipe: Pipe
    let configPath: String
    var routesAdded: [(cidr: String, interface: String)] = []
    var finished = false
    /// A failure was already reported, so termination stays quiet
    var failed = false
    /// Retrying cannot help (wrong credentials or certificate): no auto-reconnect
    var fatal = false
    /// openfortivpn rejected an unpinned gateway certificate: its digest is on the next line
    var awaitingCertificateDigest = false
    /// The profile with the certificate pinned: the attempt is repeated with it once the process is gone
    var retryServer: VPNServer?
    /// Bytes after the last newline: pipe reads do not end on line (or UTF-8) boundaries
    var outputBuffer = Data()
    /// The pipe reached EOF: all output has been handled
    var outputClosed = false
    /// Set when the process exited; termination is handled once the output is drained
    var exitCode: Int32?
    /// A stop was requested: the SIGTERM grace period (and any force stop) runs once
    var stopRequested = false

    // Monitoring (see "Monitoring" in VPNManager)
    /// When the tunnel came up; nil until then and after the session was recorded
    var sessionStart: Date?
    var traffic = TrafficAccumulator()
    var health: TunnelHealth = .unknown
    var tracker = HealthTracker()
    /// Address the health check pings, resolved with the first probe
    var probeTarget: String?
    /// DNS servers the gateway handed out: probe candidates when the far end of the link is silent
    var nameservers: [String] = []
    var probing = false
    var nextProbeAt = Date.distantFuture
    /// Probe more often until then (after wake-up or a network change)
    var burstUntil = Date.distantPast
    /// The health check stopped this tunnel because it stopped passing traffic
    var restartedForHealth = false
    var notifiedUnresponsive = false

    init(server: VPNServer, process: Process, pipe: Pipe, configPath: String) {
        self.server = server
        self.process = process
        self.pipe = pipe
        self.configPath = configPath
    }
}

/// Manages openfortivpn tunnels: one at a time by default, or several side by side
/// when "Allow multiple connections" is on. Each tunnel has its own root process,
/// status, log lines and optional static routes through its ppp interface.
///
/// All state lives on the main thread; background work hops back with `onMain`.
class VPNManager: ObservableObject {
    static let shared = VPNManager()

    /// One entry per active/connecting tunnel, in connection order.
    @Published private(set) var tunnels: [TunnelStatus] = []
    @Published private(set) var connectionLogs: [String] = []
    /// Last failure per server id (shown by the CLI); cleared on the next connect
    @Published private(set) var lastErrors: [String: TunnelError] = [:]
    /// Traffic and health of connected tunnels, by server id. Separate from `tunnels`
    /// because it changes every couple of seconds and must not rewrite state.json.
    @Published private(set) var live: [String: TunnelLive] = [:]

    struct TunnelError: Equatable {
        let message: String
        let date: Date
    }

    private var connections: [String: TunnelConnection] = [:]
    /// Single-connection mode: the connect waiting for the previous tunnel to go down
    private var pendingSwitch: AnyCancellable?

    /// Auto-reconnect waits for the network instead of failing attempts while offline
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    /// Interfaces and gateways of the last network path: a change means a new network
    private var networkSignature: [String]?
    private var monitorTimer: Timer?

    /// Seconds before each reconnect attempt; the last value repeats
    static let reconnectDelays: [TimeInterval] = [2, 5, 10, 20, 30, 60]

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            // Physical interfaces only: the tunnel's own ppp interface comes and goes with us
            let physical: Set<NWInterface.InterfaceType> = [.wifi, .wiredEthernet, .cellular]
            let signature = path.availableInterfaces.filter { physical.contains($0.type) }.map(\.name).sorted()
                + path.gateways.map { "\($0)" }.sorted()
            DispatchQueue.main.async {
                self?.networkChanged(available: available, signature: signature)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "fortibar.network"))

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    // MARK: - Computed state

    var connectedCount: Int { tunnels.filter(\.isConnected).count }

    var busyCount: Int { tunnels.filter(\.isBusy).count }

    var hasTunnels: Bool { !tunnels.isEmpty }

    func status(for serverID: String) -> TunnelStatus? {
        tunnels.first { $0.serverID == serverID }
    }

    // MARK: - Connect

    func connect(to server: VPNServer, password: String) {
        guard status(for: server.id) == nil else { return }

        // Single-connection mode: switch servers by dropping the current tunnel first
        if !ConfigManager.shared.config.allowMultipleConnections, hasTunnels {
            addLog(server.name, "Switching: disconnecting current tunnel first")
            disconnectAll()
            pendingSwitch = $tunnels
                .first(where: \.isEmpty)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.pendingSwitch = nil
                    self?.connect(to: server, password: password)
                }
            return
        }

        lastErrors[server.id] = nil
        tunnels.append(TunnelStatus(serverID: server.id, state: .connecting, serverName: server.name))
        addLog(server.name, "Connecting to \(server.name)...")
        startAttempt(server: server, password: password)
    }

    /// Main thread: starts openfortivpn for a tunnel entry that already exists.
    private func startAttempt(server: VPNServer, password: String) {
        let attempt = UUID()
        updateTunnel(server.id) { status in
            status.state = .connecting
            status.attempt = attempt
        }
        notifyStateChange()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performConnection(server: server, password: password, attempt: attempt)
        }
    }

    /// Connects every server marked "Connect at launch" that has a saved password
    /// (single-connection mode: the first such server).
    func connectAutoStartServers() {
        let servers = ConfigManager.shared.config.servers.filter(\.autoConnect)
        let allowMultiple = ConfigManager.shared.config.allowMultipleConnections
        guard !servers.isEmpty else { return }

        // The Keychain can block (e.g. an access prompt after an update): keep the main thread free
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let passwords = servers.map { ($0, KeychainHelper.read(for: $0.id)) }
            self?.onMain { manager in
                for (server, password) in passwords {
                    guard let password, !password.isEmpty else {
                        manager.addLog(server.name, "Auto-connect skipped: no saved password")
                        continue
                    }
                    manager.connect(to: server, password: password)
                    if !allowMultiple { break }
                }
            }
        }
    }

    /// Runs on a background queue.
    private func performConnection(server: VPNServer, password: String, attempt: UUID) {
        // A line break would end the value and inject further options into a config read by root
        let configValues = [server.host, server.username, password, server.trustedCert ?? ""]
        guard !configValues.contains(where: { $0.contains(where: \.isNewline) }) else {
            onMain { $0.connectionFailed(server: server, reason: "Host, username, password or certificate contains a line break") }
            return
        }

        guard let openfortivpnPath = findOpenfortivpnBinary() else {
            onMain { $0.connectionFailed(server: server, reason: "openfortivpn not found. Install via: brew install openfortivpn") }
            return
        }

        // Fail early with a clear message instead of a bare sudo error
        guard SudoersManager.shared.isAllowed(binaryPath: openfortivpnPath) else {
            onMain { $0.connectionFailed(server: server, reason: "Administrator permission not set up. Open Settings › Permission.") }
            return
        }

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fortivpn_\(UUID().uuidString).conf")

        var configContent = """
        host = \(server.host)
        port = \(server.port)
        username = \(server.username)
        password = \(password)
        """

        if let trustedCert = server.trustedCert, !trustedCert.isEmpty {
            configContent += "\ntrusted-cert = \(trustedCert)"
        }

        do {
            // Created 0600 before the password is written; if that fails, never fall back to a umask-default file
            guard FileManager.default.createFile(atPath: configURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try configContent.write(to: configURL, atomically: false, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: configURL)
            onMain { $0.connectionFailed(server: server, reason: "Failed to create config: \(error.localizedDescription)") }
            return
        }

        var arguments = ["-c", configURL.path]
        if server.noRoutesDNS {
            arguments += ["--no-routes", "--no-dns"]
        }

        onMain { manager in
            // Cancelled while the config was being prepared
            guard let status = manager.status(for: server.id), status.attempt == attempt, status.state == .connecting else {
                try? FileManager.default.removeItem(at: configURL)
                return
            }
            if server.noRoutesDNS {
                manager.addLog(server.name, "Routes and DNS left untouched (--no-routes --no-dns)")
            }
            manager.start(openfortivpnPath: openfortivpnPath, arguments: arguments, server: server, configPath: configURL.path)
        }
    }

    func findOpenfortivpnBinary() -> String? {
        Self.locateOpenfortivpn()
    }

    /// Static so the CLI can use it without creating the manager (and its notification setup).
    static func locateOpenfortivpn() -> String? {
        let configPath = ConfigManager.shared.config.openfortivpnPath
        if FileManager.default.isExecutableFile(atPath: configPath) {
            return configPath
        }

        let commonPaths = [
            "/opt/homebrew/bin/openfortivpn",
            "/usr/local/bin/openfortivpn",
            "/opt/local/bin/openfortivpn"
        ]

        return commonPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Main thread: launches `sudo -n openfortivpn …` for one server.
    private func start(openfortivpnPath: String, arguments: [String], server: VPNServer, configPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never prompt; without a sudoers rule sudo exits instead of waiting for a tty
        process.arguments = ["-n", openfortivpnPath] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let conn = TunnelConnection(server: server, process: process, pipe: pipe, configPath: configPath)
        connections[server.id] = conn

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: without this the handler keeps firing with empty reads
                handle.readabilityHandler = nil
            }
            // Empty data tells the main thread the output is complete
            DispatchQueue.main.async {
                self?.handleOutput(data, conn: conn)
            }
        }

        process.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            DispatchQueue.main.async {
                self?.processExited(conn: conn, exitCode: exitCode)
            }
        }

        // Per-tunnel connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak conn] in
            guard let self = self, let conn = conn, !conn.finished,
                  self.status(for: server.id)?.state == .connecting else { return }
            self.connectionFailed(server: server, reason: "Connection timeout - server not responding")
        }

        do {
            try process.run()
        } catch {
            connectionFailed(server: server, reason: "Failed to start process: \(error.localizedDescription)")
            // No termination callback will come: release the connection (and the config file) now
            finish(conn)
        }
    }

    // MARK: - Output parsing

    /// Main thread: buffers raw pipe data and handles it line by line. Empty data is EOF.
    private func handleOutput(_ data: Data, conn: TunnelConnection) {
        if data.isEmpty {
            conn.outputClosed = true
            if !conn.outputBuffer.isEmpty {
                let rest = conn.outputBuffer
                conn.outputBuffer = Data()
                handleLines(String(decoding: rest, as: UTF8.self), conn: conn)
            }
            if let exitCode = conn.exitCode {
                handleTermination(conn: conn, exitCode: exitCode)
            }
            return
        }

        conn.outputBuffer.append(data)
        guard let newline = conn.outputBuffer.lastIndex(of: UInt8(ascii: "\n")) else {
            // A runaway line without a newline: do not buffer it forever
            if conn.outputBuffer.count > 65_536 {
                let text = String(decoding: conn.outputBuffer, as: UTF8.self)
                conn.outputBuffer = Data()
                handleLines(text, conn: conn)
            }
            return
        }
        let complete = conn.outputBuffer.subdata(in: conn.outputBuffer.startIndex..<newline)
        conn.outputBuffer = conn.outputBuffer.subdata(in: (newline + 1)..<conn.outputBuffer.endIndex)
        handleLines(String(decoding: complete, as: UTF8.self), conn: conn)
    }

    /// Main thread: the process exited. Output still in the pipe (e.g. the certificate
    /// digest printed right before exiting) is handled first, so wait for EOF.
    private func processExited(conn: TunnelConnection, exitCode: Int32) {
        conn.exitCode = exitCode
        if conn.outputClosed {
            handleTermination(conn: conn, exitCode: exitCode)
            return
        }
        // A leftover child may keep the pipe open: do not wait for EOF forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.handleTermination(conn: conn, exitCode: exitCode)
        }
    }

    private func handleLines(_ output: String, conn: TunnelConnection) {
        guard connections[conn.server.id] === conn else { return }
        let server = conn.server

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            addLog(server.name, line)

            // Trust on first use: an unpinned gateway certificate that fails validation is pinned
            // and the attempt repeated. A pinned certificate that stops matching is an error.
            if (server.trustedCert ?? "").isEmpty {
                if line.contains("certificate digest is not in the local whitelist") {
                    conn.awaitingCertificateDigest = true
                    continue
                }
                if conn.awaitingCertificateDigest, let digest = Self.certificateDigest(in: line) {
                    conn.awaitingCertificateDigest = false
                    pinCertificate(digest, conn: conn)
                    continue
                }
            }
            if conn.retryServer != nil { continue }

            if let ip = Self.assignedAddress(in: line) {
                updateTunnel(server.id) { $0.assignedIP = ip }
                conn.nameservers = Self.assignedNameservers(in: line)
            }

            if let iface = Self.interfaceName(in: line) {
                updateTunnel(server.id) { $0.interface = iface }
            }

            if line.contains("Tunnel is up and running") {
                // Not after a disconnect or a failure (timeout) already terminating the process:
                // a .connected state would turn its exit into a "drop" and auto-reconnect
                if status(for: server.id)?.state == .connecting, !conn.failed {
                    markConnected(conn: conn)
                }
                continue
            }

            guard status(for: server.id)?.state == .connecting,
                  let reason = Self.failureReason(in: line, server: server) else { continue }
            connectionFailed(server: server, reason: reason, fatal: Self.isFatal(reason))
        }
    }

    /// Extracts the digest from openfortivpn's "--trusted-cert <sha256>" hint.
    static func certificateDigest(in line: String) -> String? {
        guard let range = line.range(of: #"--trusted-cert\s+[0-9a-fA-F]{64}\b"#, options: .regularExpression) else {
            return nil
        }
        return line[range].split(whereSeparator: \.isWhitespace).last.map { String($0).lowercased() }
    }

    /// Saves the certificate in the profile and repeats the attempt once the failed process is gone.
    private func pinCertificate(_ digest: String, conn: TunnelConnection) {
        let server = conn.server
        let servers = ConfigManager.shared.config.servers
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }

        var updated = servers
        updated[index] = servers[index].pinning(certificate: digest)
        ConfigManager.shared.saveServers(updated)
        NotificationCenter.default.post(name: .configChanged, object: nil)
        // An open Settings window must reload, or its next save would drop the pinned certificate
        NotificationCenter.default.post(name: .configReloaded, object: nil)

        addLog(server.name, "First connection: trusting the gateway certificate (sha256 \(digest)) and retrying")
        conn.retryServer = updated[index]
        conn.failed = true
        terminate(conn: conn)
    }

    static func failureReason(in line: String, server: VPNServer) -> String? {
        let lower = line.lowercased()
        if lower.contains("could not resolve host") || lower.contains("cannot resolve host") {
            return "Cannot resolve host: \(server.host)"
        } else if lower.contains("connection timed out") {
            return "Connection timed out"
        } else if lower.contains("connection refused") {
            return "Connection refused by server"
        } else if lower.contains("authentication failed") || lower.contains("login failed") || lower.contains("could not authenticate") {
            return "Authentication failed - check username/password"
        } else if lower.contains("permission denied") && !lower.contains("sudo") {
            return "Authentication failed - check username/password"
        } else if lower.contains("certificate") && lower.contains("error") {
            return server.trustedCert?.isEmpty == false
                ? "Certificate error - the gateway certificate no longer matches the pinned one. Clear the certificate in the server settings to trust the new one"
                : "Certificate error - the gateway certificate could not be verified"
        } else if lower.contains("gateway") && lower.contains("error") {
            return "Gateway error: \(line)"
        }
        return nil
    }

    /// Failures that a retry cannot fix: auto-reconnect stops instead of locking the account.
    static func isFatal(_ reason: String) -> Bool {
        reason.hasPrefix("Authentication failed") || reason.hasPrefix("Certificate error")
    }

    /// Extracts the tunnel IP from openfortivpn's "Got addresses: [10.0.0.5], ns [...]" line.
    static func assignedAddress(in line: String) -> String? {
        guard let range = line.range(of: #"Got addresses: \[[^\],]+"#, options: .regularExpression) else {
            return nil
        }
        let match = line[range]
        guard let open = match.firstIndex(of: "[") else { return nil }
        let ip = match[match.index(after: open)...].trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : ip
    }

    /// Extracts the DNS servers from "Got addresses: [10.0.0.5], ns [10.10.5.2, 0.0.0.0], ns_suffix [...]".
    /// Unset (0.0.0.0) entries are dropped.
    static func assignedNameservers(in line: String) -> [String] {
        guard let range = line.range(of: #"\bns \[[^\]]*\]"#, options: .regularExpression),
              let open = line[range].firstIndex(of: "["), let close = line[range].lastIndex(of: "]") else { return [] }
        return line[line.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 != "0.0.0.0" && TunnelProbe.isValidHost($0) }
    }

    /// Extracts the ppp interface from pppd's "Using interface ppp0" line.
    static func interfaceName(in line: String) -> String? {
        guard let range = line.range(of: #"Using interface ppp\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range].dropFirst("Using interface ".count))
    }

    private func markConnected(conn: TunnelConnection) {
        let server = conn.server
        let reconnected = (status(for: server.id)?.reconnectAttempt ?? 0) > 0

        // openfortivpn read its config at startup: do not keep the password on disk while connected
        try? FileManager.default.removeItem(atPath: conn.configPath)

        let now = Date()
        updateTunnel(server.id) { status in
            status.state = .connected(serverName: server.name)
            status.connectedSince = now
            status.reconnectAttempt = 0
        }
        conn.sessionStart = now
        // The first probe waits a moment for routes and DNS to settle
        conn.nextProbeAt = now.addingTimeInterval(Self.firstProbeDelay)
        live[server.id] = TunnelLive()
        startMonitor()
        notifyStateChange()
        showNotification(title: reconnected ? "VPN Reconnected" : "VPN Connected", body: server.name)

        let routes = server.validatedStaticRoutes
        guard !routes.isEmpty else { return }

        let knownInterface = status(for: server.id)?.interface
        let tunnelIP = status(for: server.id)?.assignedIP

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fallback when pppd's "Using interface" line was not seen: look the IP up in ifconfig
            guard let iface = knownInterface ?? Self.findInterface(tunnelIP: tunnelIP) else {
                self?.onMain { $0.addLog(server.name, "ERROR: could not determine the ppp interface, static routes not added") }
                return
            }
            self?.addStaticRoutes(routes, interface: iface, conn: conn)
        }
    }

    /// Blocking: finds the ppp interface holding the given local address, e.g. "ppp1".
    static func findInterface(tunnelIP: String?) -> String? {
        guard let tunnelIP = tunnelIP else { return nil }
        let text = Subprocess.run("/sbin/ifconfig", []).output

        // Blocks look like: "ppp1: flags=...\n\tinet 10.0.0.2 --> 169.254.2.1 ..."
        var currentInterface: String?
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), let name = line.split(separator: ":").first, !name.isEmpty {
                currentInterface = String(name)
            } else if let iface = currentInterface, iface.hasPrefix("ppp") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 2, fields[0] == "inet", fields[1] == tunnelIP {
                    return iface
                }
            }
        }
        return nil
    }

    // MARK: - Static routes

    /// Background queue: `sudo -n /sbin/route -n add -net <cidr> -interface <pppN>` per route.
    /// Failures are logged; the tunnel itself stays up.
    private func addStaticRoutes(_ routes: [String], interface: String, conn: TunnelConnection) {
        let server = conn.server
        for cidr in routes {
            var result = Self.runRoute("add", cidr: cidr, interface: interface)
            // A leftover route (e.g. from an earlier session) is re-pointed to this tunnel
            if !result.success && result.output.contains("File exists") {
                result = Self.runRoute("change", cidr: cidr, interface: interface)
            }

            onMain { manager in
                if result.success {
                    // The tunnel may have dropped meanwhile; the kernel removed the route with it
                    guard !conn.finished else { return }
                    conn.routesAdded.append((cidr, interface))
                    manager.updateTunnel(server.id) { $0.routes.append(cidr) }
                    manager.addLog(server.name, "Route added: \(cidr) via \(interface)")
                } else {
                    manager.addLog(server.name, "ERROR: could not add route \(cidr) via \(interface): \(result.output)")
                    if SudoersManager.needsPassword(result.output) {
                        manager.addLog(server.name, "Static routes need permission: open Settings › Permission and click Update")
                        manager.showNotification(title: "Static routes not added", body: "\(server.name): update the permission in Settings")
                    }
                }
            }
        }
    }

    /// Background queue. Interface-bound routes vanish with the ppp interface;
    /// this cleans up whatever outlived it.
    private func removeStaticRoutes(_ routes: [(cidr: String, interface: String)]) {
        guard !routes.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for route in routes {
                _ = Self.runRoute("delete", cidr: route.cidr, interface: route.interface)
            }
        }
    }

    private static func runRoute(_ verb: String, cidr: String, interface: String) -> (success: Bool, output: String) {
        // Matches the sudoers rule: /sbin/route -n <verb> -net * -interface ppp*
        let result = Subprocess.run("/usr/bin/sudo", ["-n", "/sbin/route", "-n", verb, "-net", cidr, "-interface", interface])
        return (result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Disconnect

    func disconnect(serverID: String) {
        guard let conn = connections[serverID], !conn.finished else {
            // Preparing the config or waiting to reconnect: dropping the entry cancels it
            if let status = status(for: serverID) {
                if case .reconnecting = status.state {
                    addLog(status.serverName, "Auto-reconnect cancelled")
                }
                removeTunnel(serverID)
            }
            return
        }

        updateTunnel(serverID) { $0.state = .disconnecting }
        notifyStateChange()
        addLog(conn.server.name, "Disconnecting...")

        terminate(conn: conn)
    }

    func disconnectAll() {
        tunnels.map(\.serverID).forEach(disconnect(serverID:))
        pendingSwitch = nil
    }

    /// Quit path: SIGTERM to every tunnel and returns the processes to wait for.
    /// While the app waits to terminate, the main queue is not serviced, so the
    /// usual termination callbacks cannot be relied on: clean up synchronously here.
    func stopAllForQuit() -> [Process] {
        pendingSwitch = nil
        let active = connections.values.filter { !$0.finished }
        for conn in active {
            if conn.process.isRunning {
                conn.process.terminate()
            }
            // openfortivpn has read its config by now: do not leave the password on disk
            try? FileManager.default.removeItem(atPath: conn.configPath)
            endSession(conn, reason: .quit)
        }
        return active.map(\.process)
    }

    /// Seconds openfortivpn gets to exit after SIGTERM before it is force-stopped
    static let terminateGracePeriod: TimeInterval = 5
    /// Seconds to wait for the exit callback after SIGKILL before dropping the entry anyway
    static let forceStopGracePeriod: TimeInterval = 3

    /// Sends SIGTERM to the sudo parent, which relays it to openfortivpn so it can restore routes and DNS.
    private func terminate(conn: TunnelConnection) {
        if conn.process.isRunning {
            conn.process.terminate()
        }

        guard !conn.stopRequested else { return }
        conn.stopRequested = true

        // openfortivpn may hang and ignore SIGTERM: escalate if the process does not report back
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminateGracePeriod) { [weak self] in
            guard let self = self, !conn.finished else { return }
            self.forceStop(conn: conn)
        }
    }

    /// Main thread. Last resort: SIGKILL the root processes under the sudo parent (openfortivpn,
    /// its pppd) through the narrow `/bin/kill -KILL <pid>` sudo rule. The usual exit callback
    /// then cleans up; if it still does not come, the entry is dropped.
    private func forceStop(conn: TunnelConnection) {
        let name = conn.server.name
        // The sudo parent exited and its callback is pending (e.g. waiting for pipe EOF)
        guard conn.process.isRunning else {
            dropForcedStop(conn: conn)
            return
        }

        let sudoPID = conn.process.processIdentifier
        addLog(name, "openfortivpn did not stop within \(Int(Self.terminateGracePeriod))s: force-stopping it")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pids = Self.descendantPIDs(of: sudoPID)
            var killed: [Int32] = []
            var failures: [String] = []
            var notAllowed = false
            for pid in pids {
                guard let arguments = SudoersManager.forceStopArguments(pid: pid) else {
                    failures.append("\(pid): pid outside the allowed range")
                    continue
                }
                let result = Subprocess.run("/usr/bin/sudo", arguments)
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 0 {
                    killed.append(pid)
                } else if SudoersManager.needsPassword(output) {
                    notAllowed = true
                    break
                } else if !output.contains("No such process") {
                    // "No such process": it exited meanwhile, which is what we wanted
                    failures.append("\(pid): \(output)")
                }
            }

            self?.onMain { manager in
                if pids.isEmpty {
                    manager.addLog(name, "Force stop: no processes found under sudo (pid \(sudoPID))")
                } else if notAllowed {
                    manager.addLog(name, "ERROR: could not force-stop openfortivpn: the permission rule does not allow it. Open Settings › Permission and click Update; until then the process may keep running as root")
                    manager.showNotification(title: "VPN not stopped", body: "\(name): update the permission in Settings")
                } else {
                    if !killed.isEmpty {
                        manager.addLog(name, "Force stop: sent SIGKILL to pid \(killed.map(String.init).joined(separator: ", ")). Routes and DNS set by openfortivpn may not have been restored")
                    }
                    for failure in failures {
                        manager.addLog(name, "ERROR: force stop failed for pid \(failure)")
                    }
                }

                // The exit callback normally arrives now; drop the entry if it does not
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.forceStopGracePeriod) { [weak manager] in
                    guard let manager = manager, !conn.finished else { return }
                    manager.dropForcedStop(conn: conn)
                }
            }
        }
    }

    private func dropForcedStop(conn: TunnelConnection) {
        guard !conn.finished else { return }
        addLog(conn.server.name, "Disconnected (forced)")
        finish(conn)
    }

    /// Background queue: every process below `pid` (sudo's own monitor, openfortivpn, pppd),
    /// deepest first so children go before the parents that would otherwise reap them.
    private static func descendantPIDs(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        var seen: Set<Int32> = [pid]
        while !queue.isEmpty, result.count < 64 {
            let parent = queue.removeFirst()
            let output = Subprocess.run("/usr/bin/pgrep", ["-P", String(parent)]).output
            for child in parsePIDs(output) where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result.reversed()
    }

    /// One pid per line, as printed by pgrep; anything that is not a positive integer is ignored.
    static func parsePIDs(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
                  let pid = Int32(text), pid > 0 else { return nil }
            return pid
        }
    }

    // MARK: - Termination handling

    private func handleTermination(conn: TunnelConnection, exitCode: Int32) {
        guard !conn.finished else { return }
        let server = conn.server
        let status = status(for: server.id)
        let previousState = status?.state ?? .disconnected
        let inReconnectCycle = (status?.reconnectAttempt ?? 0) > 0

        // Reconnect a tunnel that dropped, and keep retrying while a reconnect fails,
        // unless the user disconnected or retrying cannot help
        let dropped = previousState.isConnected || (previousState == .connecting && inReconnectCycle)
        let reconnect = dropped && !conn.fatal && autoReconnectEnabled(for: server.id)

        // Not if the user disconnected while the pinned retry was pending
        if let pinned = conn.retryServer, previousState == .connecting {
            finish(conn, keepStatus: true)
            let attempt = status?.attempt
            // The Keychain can block (e.g. an access prompt): read it off the main thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let password = KeychainHelper.read(for: pinned.id)
                self?.onMain { manager in
                    // Not if the user disconnected (or reconnected) while the password was read
                    guard let current = manager.status(for: pinned.id), current.attempt == attempt,
                          current.state == .connecting, manager.connections[pinned.id] == nil else { return }
                    if let password = password, !password.isEmpty {
                        manager.startAttempt(server: pinned, password: password)
                    } else {
                        manager.reportError(server: pinned, reason: "No saved password")
                        manager.removeTunnel(pinned.id)
                    }
                }
            }
            return
        }

        finish(conn, keepStatus: reconnect)

        switch previousState {
        case .connecting where !conn.failed:
            lastErrors[server.id] = TunnelError(message: "openfortivpn exited with code \(exitCode)", date: Date())
            addLog(server.name, "ERROR: Connection failed (exit code: \(exitCode))")
            if !inReconnectCycle {
                showNotification(title: "Connection Failed", body: "\(server.name): openfortivpn exited with code \(exitCode)")
            }
        case .connected:
            addLog(server.name, "Disconnected (exit code: \(exitCode))")
            showNotification(title: "VPN Disconnected", body: reconnect ? "\(server.name): reconnecting…" : server.name)
        case .disconnecting:
            addLog(server.name, "Disconnected")
        default:
            break
        }

        if reconnect {
            scheduleReconnect(server: server, attempt: (status?.reconnectAttempt ?? 0) + 1)
        }
    }

    // MARK: - Auto-reconnect

    private func autoReconnectEnabled(for serverID: String) -> Bool {
        // Read the saved profile: the option may have changed while connected
        ConfigManager.shared.config.servers.first { $0.id == serverID }?.autoReconnect ?? false
    }

    /// Main thread: keeps the tunnel entry and retries after a growing delay.
    private func scheduleReconnect(server: VPNServer, attempt: Int) {
        let delay = Self.reconnectDelays[min(attempt, Self.reconnectDelays.count) - 1]
        let date = networkAvailable ? Date().addingTimeInterval(delay) : nil

        updateTunnel(server.id) { status in
            status.state = .reconnecting(at: date)
            status.reconnectAttempt = attempt
            status.assignedIP = nil
            status.interface = nil
            status.connectedSince = nil
            status.routes = []
        }
        notifyStateChange()

        guard let date = date else {
            addLog(server.name, "Waiting for the network to reconnect")
            return
        }
        addLog(server.name, "Reconnecting in \(Int(delay))s (attempt \(attempt))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip if cancelled, or already retried because the network came back
            guard let self = self, self.status(for: server.id)?.state == .reconnecting(at: date) else { return }
            self.reconnect(serverID: server.id)
        }
    }

    private func reconnect(serverID: String) {
        guard let status = status(for: serverID) else { return }

        // The Keychain can block (e.g. an access prompt): read it off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let password = KeychainHelper.read(for: serverID)
            self?.onMain { manager in
                // Skip if the user disconnected, or another trigger (timer, network back) already
                // retried while the password was read
                guard let current = manager.status(for: serverID), current.state == status.state,
                      current.attempt == status.attempt, manager.connections[serverID] == nil else { return }
                manager.reconnect(serverID: serverID, status: current, password: password)
            }
        }
    }

    /// Main thread, with the password already read from the Keychain.
    private func reconnect(serverID: String, status: TunnelStatus, password: String?) {
        // The profile may have been edited or deleted in the meantime
        guard let server = ConfigManager.shared.config.servers.first(where: { $0.id == serverID }),
              server.autoReconnect else {
            addLog(status.serverName, "Auto-reconnect stopped")
            removeTunnel(serverID)
            return
        }
        guard let password = password, !password.isEmpty else {
            reportError(server: server, reason: "Auto-reconnect stopped: no saved password")
            removeTunnel(serverID)
            return
        }
        guard networkAvailable else {
            updateTunnel(serverID) { $0.state = .reconnecting(at: nil) }
            notifyStateChange()
            addLog(server.name, "Waiting for the network to reconnect")
            return
        }

        addLog(server.name, "Reconnecting (attempt \(status.reconnectAttempt))...")
        startAttempt(server: server, password: password)
    }

    private func networkChanged(available: Bool, signature: [String]) {
        let restored = available && !networkAvailable
        // The first callback only records where we are
        let changed = networkSignature != nil && networkSignature != signature
        networkAvailable = available
        networkSignature = signature

        // A tunnel often stays "up" over a dead path (Wi-Fi switched, cable pulled): look at it now
        if available, changed || restored {
            expediteHealthChecks(reason: "Network changed")
        }
        guard restored else { return }

        // Retry right away instead of waiting for the backoff to expire
        for status in tunnels {
            if case .reconnecting = status.state {
                addLog(status.serverName, "Network is back")
                reconnect(serverID: status.serverID)
            }
        }
    }

    /// Records a failure that happened before a tunnel was started (e.g. no saved password).
    func reportError(server: VPNServer, reason: String) {
        lastErrors[server.id] = TunnelError(message: reason, date: Date())
        addLog(server.name, "ERROR: \(reason)")
    }

    private func connectionFailed(server: VPNServer, reason: String, fatal: Bool = false) {
        lastErrors[server.id] = TunnelError(message: reason, date: Date())
        addLog(server.name, "ERROR: \(reason)")

        // While reconnecting, every failed attempt would notify: the log is enough
        let reconnecting = (status(for: server.id)?.reconnectAttempt ?? 0) > 0
        if !reconnecting || fatal {
            showNotification(title: "Connection Failed", body: "\(server.name): \(String(reason.prefix(100)))")
        }

        if let conn = connections[server.id], !conn.finished {
            conn.failed = true
            conn.fatal = fatal
            terminate(conn: conn)
        } else {
            removeTunnel(server.id)
        }
    }

    /// Main thread: releases everything the connection owned.
    /// `keepStatus`: the tunnel entry stays for an auto-reconnect.
    private func finish(_ conn: TunnelConnection, keepStatus: Bool = false) {
        let endState = status(for: conn.server.id)?.state
        endSession(conn, reason: conn.restartedForHealth ? .unresponsive : (endState?.isConnected == true ? .dropped : .user))
        conn.finished = true
        conn.pipe.fileHandleForReading.readabilityHandler = nil
        // The handler captures the connection, which owns the process: break the cycle
        conn.process.terminationHandler = nil
        try? FileManager.default.removeItem(atPath: conn.configPath)
        removeStaticRoutes(conn.routesAdded)

        if connections[conn.server.id] === conn {
            connections.removeValue(forKey: conn.server.id)
            live.removeValue(forKey: conn.server.id)
            if !keepStatus {
                removeTunnel(conn.server.id)
            }
        }
    }

    // MARK: - Monitoring (traffic, health check, wake-up)

    /// Seconds between traffic samples
    private static let monitorInterval: TimeInterval = 2
    /// Seconds before the first probe of a new connection
    private static let firstProbeDelay: TimeInterval = 5
    /// Seconds between probes of a healthy tunnel
    private static let probeInterval: TimeInterval = 20
    /// Seconds between probes while one failed (and while still looking for a first answer)
    private static let failingProbeInterval: TimeInterval = 5
    /// Seconds between probes right after wake-up or a network change
    private static let burstProbeInterval: TimeInterval = 3
    private static let burstDuration: TimeInterval = 30
    /// Wi-Fi and DNS need a moment after wake-up before a probe means anything
    private static let wakeSettleDelay: TimeInterval = 3

    private func startMonitor() {
        guard monitorTimer == nil else { return }
        let timer = Timer(timeInterval: Self.monitorInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitorTick() }
        }
        // Common modes: keeps ticking while the menu bar menu or a window is tracking events
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func stopMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    /// Connections that are up right now.
    private var connectedConnections: [TunnelConnection] {
        connections.values.filter { conn in
            !conn.finished && conn.sessionStart != nil && status(for: conn.server.id)?.isConnected == true
        }
    }

    private func monitorTick() {
        let active = connectedConnections
        guard !active.isEmpty else {
            stopMonitor()
            if !live.isEmpty { live = [:] }
            return
        }

        let now = Date()
        let counters = InterfaceCounters.read()
        let healthCheck = ConfigManager.shared.config.healthCheck
        for conn in active {
            if let interface = status(for: conn.server.id)?.interface, let sample = counters[interface] {
                conn.traffic.update(rx: sample.rx, tx: sample.tx, at: now)
            }
            if healthCheck, !conn.probing, now >= conn.nextProbeAt {
                startProbe(conn)
            }
            publishLive(conn)
        }
    }

    private func publishLive(_ conn: TunnelConnection) {
        let value = TunnelLive(traffic: conn.traffic, health: conn.health)
        guard live[conn.server.id] != value else { return }
        live[conn.server.id] = value
    }

    /// Main thread: pings the tunnel off the main thread and hears back in `probeFinished`.
    private func startProbe(_ conn: TunnelConnection) {
        conn.probing = true
        let server = conn.server
        let interface = status(for: server.id)?.interface
        let knownTarget = conn.probeTarget
        let nameservers = conn.nameservers

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Once a target has answered it is the one to watch. Until then: the configured host,
            // else the far end of the point-to-point link (many gateways ignore ping there),
            // then the DNS servers the gateway handed out.
            let candidates: [String]
            if let knownTarget {
                candidates = [knownTarget]
            } else if let host = server.healthCheckHost {
                candidates = [host]
            } else {
                candidates = [interface.flatMap(TunnelProbe.peerAddress(of:))].compactMap { $0 } + nameservers
            }

            var answeredBy: String?
            var latency: Double?
            for candidate in candidates {
                if let milliseconds = TunnelProbe.ping(host: candidate, interface: interface) {
                    answeredBy = candidate
                    latency = milliseconds
                    break
                }
            }
            self?.onMain { $0.probeFinished(conn, answeredBy: answeredBy, tried: candidates, latency: latency) }
        }
    }

    private func probeFinished(_ conn: TunnelConnection, answeredBy: String?, tried: [String], latency: Double?) {
        conn.probing = false
        // The tunnel went away (or was replaced) while the probe was running
        guard !conn.finished, connections[conn.server.id] === conn,
              status(for: conn.server.id)?.isConnected == true else { return }

        let name = conn.server.name
        let now = Date()
        guard !tried.isEmpty else {
            conn.health = .unknown
            conn.nextProbeAt = .distantFuture
            addLog(name, "Health check off: nothing to probe. Set a health check host in the server settings")
            publishLive(conn)
            return
        }
        if let answeredBy { conn.probeTarget = answeredBy }
        let target = conn.probeTarget ?? tried.joined(separator: ", ")

        let wasEstablished = conn.tracker.established
        let hadProblem = conn.health.isProblem
        let inBurst = now < conn.burstUntil

        switch conn.tracker.record(latency: latency) {
        case .good(let milliseconds):
            conn.health = .good(latency: milliseconds)
            conn.notifiedUnresponsive = false
            if !wasEstablished {
                addLog(name, "Health check: \(target) answers (\(Int(milliseconds.rounded())) ms)")
            } else if hadProblem {
                addLog(name, "The tunnel responds again")
            }
            conn.nextProbeAt = now.addingTimeInterval(inBurst ? Self.burstProbeInterval : Self.probeInterval)
        case .waiting:
            conn.nextProbeAt = now.addingTimeInterval(Self.failingProbeInterval)
        case .failing:
            conn.health = .failing
            if !hadProblem {
                addLog(name, "No reply from \(target) through the tunnel")
            }
            conn.nextProbeAt = now.addingTimeInterval(inBurst ? Self.burstProbeInterval : Self.failingProbeInterval)
        case .unresponsive:
            conn.health = .unresponsive
            handleUnresponsive(conn, target: target)
        case .notMeasurable:
            conn.health = .unknown
            conn.nextProbeAt = .distantFuture
            addLog(name, "Health check off: \(target) does not answer ping through this tunnel. Set a health check host in the server settings")
        }
        publishLive(conn)
    }

    /// The tunnel is up but no longer passes traffic: restart it when auto-reconnect is on,
    /// otherwise say so and keep watching.
    private func handleUnresponsive(_ conn: TunnelConnection, target: String) {
        let name = conn.server.name
        if autoReconnectEnabled(for: conn.server.id) {
            addLog(name, "The tunnel stopped responding (no reply from \(target)): restarting it")
            conn.restartedForHealth = true
            conn.nextProbeAt = .distantFuture
            // The state stays "connected", so its exit is treated as a drop and reconnects
            terminate(conn: conn)
            return
        }

        conn.nextProbeAt = Date().addingTimeInterval(Self.failingProbeInterval)
        guard !conn.notifiedUnresponsive else { return }
        conn.notifiedUnresponsive = true
        addLog(name, "The tunnel stopped responding (no reply from \(target)). Reconnect it, or turn on automatic reconnect for this server")
        showNotification(title: "VPN Not Responding", body: "\(name): the tunnel passes no traffic. Reconnect it.")
    }

    /// Checks connected tunnels soon and often for a while, e.g. after wake-up.
    private func expediteHealthChecks(reason: String) {
        guard ConfigManager.shared.config.healthCheck else { return }
        let now = Date()
        for conn in connectedConnections where conn.tracker.established && !conn.restartedForHealth {
            // Failures from before the sleep or the switch say nothing about the new situation
            conn.tracker.resetFailures()
            conn.burstUntil = now.addingTimeInterval(Self.burstDuration)
            conn.nextProbeAt = min(conn.nextProbeAt, now.addingTimeInterval(Self.wakeSettleDelay))
            addLog(conn.server.name, "\(reason): checking the tunnel")
        }
    }

    private func systemDidWake() {
        guard hasTunnels else { return }
        expediteHealthChecks(reason: "Mac woke up")

        // A tunnel waiting out a long backoff retries now instead of up to a minute later
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleDelay) { [weak self] in
            guard let self = self else { return }
            for status in self.tunnels {
                if case .reconnecting(let date) = status.state, date != nil {
                    self.addLog(status.serverName, "Mac woke up: reconnecting now")
                    self.reconnect(serverID: status.serverID)
                }
            }
        }
    }

    // MARK: - Statistics

    /// Records the connection once, with how it ended.
    private func endSession(_ conn: TunnelConnection, reason: SessionRecord.End) {
        guard let start = conn.sessionStart else { return }
        conn.sessionStart = nil
        StatsStore.shared.record(SessionRecord(
            serverID: conn.server.id, serverName: conn.server.name, start: start, end: Date(),
            rxBytes: conn.traffic.rxBytes, txBytes: conn.traffic.txBytes, endedBy: reason
        ))
    }

    /// Connections still running, as sessions that end now, for the Statistics tab.
    func activeSessions(now: Date = Date()) -> [SessionRecord] {
        connectedConnections.compactMap { conn in
            conn.sessionStart.map {
                SessionRecord(serverID: conn.server.id, serverName: conn.server.name, start: $0, end: now,
                              rxBytes: conn.traffic.rxBytes, txBytes: conn.traffic.txBytes, endedBy: .active)
            }
        }
    }

    // MARK: - State helpers (main thread)

    private func updateTunnel(_ serverID: String, _ mutate: (inout TunnelStatus) -> Void) {
        guard let index = tunnels.firstIndex(where: { $0.serverID == serverID }) else { return }
        mutate(&tunnels[index])
    }

    private func removeTunnel(_ serverID: String) {
        tunnels.removeAll { $0.serverID == serverID }
        notifyStateChange()
    }

    private func onMain(_ work: @escaping (VPNManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self = self { work(self) }
        }
    }

    // MARK: - Logs & notifications

    private func addLog(_ serverName: String, _ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionLogs.append("[\(timestamp)] [\(serverName)] \(message)")
        LogFile.shared.append("\(Self.fileTimestamp.string(from: Date())) [\(serverName)] \(message)")

        if connectionLogs.count > 500 {
            connectionLogs.removeFirst(connectionLogs.count - 500)
        }
        NotificationCenter.default.post(name: .vpnLogsChanged, object: nil)
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func notifyStateChange() {
        NotificationCenter.default.post(name: .vpnStateChanged, object: nil)
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
