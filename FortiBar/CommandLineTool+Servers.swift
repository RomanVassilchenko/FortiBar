import Foundation

/// Server management and settings for the `fortibar` CLI: add, edit, remove, show,
/// settings, permission. Writes config.json and the Keychain directly (same signed
/// executable as the app), then asks a running app to reload.
extension CommandLineTool {

    // MARK: - Option parsing

    struct Options {
        var positional: [String] = []
        var values: [String: [String]] = [:]
        var flags: Set<String> = []

        func value(_ name: String) -> String? { values[name]?.last }
        func all(_ name: String) -> [String] { values[name] ?? [] }
        func has(_ name: String) -> Bool { flags.contains(name) }
    }

    /// Options taking a value; everything else starting with "--" is a flag.
    static let valueOptions: Set<String> = [
        "--name", "--host", "--port", "--user", "--username", "--cert", "--icon",
        "--route", "--add-route", "--remove-route",
        "--allow-multiple", "--openfortivpn-path"
    ]

    /// Options without a value. Anything else starting with "--" is rejected, so a typo
    /// like --auto-conect fails instead of being ignored.
    static let flagOptions: Set<String> = [
        "--password", "--password-stdin", "--no-routes-dns", "--routes-dns",
        "--clear-routes", "--auto-connect", "--no-auto-connect",
        "--auto-reconnect", "--no-auto-reconnect", "--no-cert", "--yes", "-y"
    ]

    static func parseOptions(_ args: [String]) -> Options? {
        var options = Options()
        var index = 0
        while index < args.count {
            var arg = args[index]
            var inlineValue: String?
            // --host=example.com
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inlineValue = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            if valueOptions.contains(arg) {
                let key = arg == "--username" ? "--user" : arg
                if let value = inlineValue {
                    options.values[key, default: []].append(value)
                } else if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    options.values[key, default: []].append(args[index + 1])
                    index += 1
                } else {
                    printError("\(arg) needs a value")
                    return nil
                }
            } else if flagOptions.contains(arg) {
                guard inlineValue == nil else {
                    printError("\(arg) does not take a value")
                    return nil
                }
                options.flags.insert(arg)
            } else if arg.hasPrefix("--") {
                printError("unknown option \(arg)")
                return nil
            } else {
                options.positional.append(arg)
            }
            index += 1
        }
        return options
    }

    // MARK: - add

    static func add(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        // `add My Server …` without quotes would silently drop "Server"
        guard options.positional.count <= (options.value("--name") == nil ? 1 : 0) else {
            return usage("unexpected argument \"\(options.positional.last!)\" (quote names with spaces)")
        }
        guard let name = (options.value("--name") ?? options.positional.first)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return usage("add needs a name: fortibar add <name> --host <host> --user <user>")
        }
        guard let host = options.value("--host"), let user = options.value("--user") else {
            return usage("add needs --host and --user")
        }

        var servers = ConfigManager.shared.config.servers
        if servers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            printError("a server named \"\(name)\" already exists (use edit)")
            return 2
        }

        let routes = options.all("--route") + options.all("--add-route")
        let server = VPNServer(
            name: name,
            host: host,
            port: Int(options.value("--port") ?? "443") ?? -1,
            username: user,
            password: nil,
            trustedCert: nonEmpty(options.value("--cert")),
            icon: options.value("--icon") ?? VPNServer.defaultIcon,
            noRoutesDNS: options.has("--no-routes-dns"),
            staticRoutes: routes,
            autoConnect: options.has("--auto-connect"),
            autoReconnect: options.has("--auto-reconnect")
        )
        if let problem = validate(server) {
            printError(problem)
            return 2
        }

        if let code = storePassword(options, serverID: server.id) {
            return code
        }

        servers.append(server)
        ConfigManager.shared.saveServers(servers)
        guard isSaved(server) else {
            KeychainHelper.delete(for: server.id)
            printError("could not save \(ConfigManager.configPath.path)")
            return 1
        }
        configChanged()
        print("Added \(server.name)" + (KeychainHelper.read(for: server.id) == nil ? " (no password yet: fortibar edit \"\(server.name)\" --password)" : ""))
        warnIfRoutesNeedPermission(server)
        return 0
    }

    // MARK: - edit

    static func edit(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        guard let query = options.positional.first else {
            return usage("edit needs a server: fortibar edit <server> [options]")
        }
        guard options.positional.count == 1 else {
            return usage("unexpected argument \"\(options.positional[1])\" (quote names with spaces)")
        }
        guard let old = resolve(query) else { return 2 }

        var routes = old.staticRoutes
        if !options.all("--route").isEmpty { routes = options.all("--route") }
        if options.has("--clear-routes") { routes = [] }
        routes += options.all("--add-route").filter { !routes.contains($0) }
        routes.removeAll { options.all("--remove-route").contains($0) }

        var noRoutesDNS = old.noRoutesDNS
        if options.has("--no-routes-dns") { noRoutesDNS = true }
        if options.has("--routes-dns") { noRoutesDNS = false }

        var autoConnect = old.autoConnect
        if options.has("--auto-connect") { autoConnect = true }
        if options.has("--no-auto-connect") { autoConnect = false }

        var autoReconnect = old.autoReconnect
        if options.has("--auto-reconnect") { autoReconnect = true }
        if options.has("--no-auto-reconnect") { autoReconnect = false }

        var cert = old.trustedCert
        if let value = options.value("--cert") { cert = nonEmpty(value) }
        if options.has("--no-cert") { cert = nil }

        // A plaintext password from an old config file is never written back: it moves to the
        // Keychain (unless one is saved there or given now) and is dropped from config.json
        let settingPassword = options.has("--password") || options.has("--password-stdin")
        var plaintextPassword = old.password.flatMap { $0.isEmpty ? nil : $0 }
        if let plain = plaintextPassword,
           settingPassword || KeychainHelper.read(for: old.id) != nil || KeychainHelper.save(password: plain, for: old.id) {
            plaintextPassword = nil
        }

        let name = options.value("--name")?.trimmingCharacters(in: .whitespaces) ?? old.name
        let server = VPNServer(
            name: name,
            host: options.value("--host") ?? old.host,
            port: options.value("--port").map { Int($0) ?? -1 } ?? old.port,
            username: options.value("--user") ?? old.username,
            password: plaintextPassword,
            trustedCert: cert,
            icon: options.value("--icon") ?? old.icon,
            id: old.id,
            noRoutesDNS: noRoutesDNS,
            staticRoutes: routes,
            autoConnect: autoConnect,
            autoReconnect: autoReconnect
        )
        if let problem = validate(server, previous: old) {
            printError(problem)
            return 2
        }

        var servers = ConfigManager.shared.config.servers
        if name != old.name, servers.contains(where: { $0.id != old.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            printError("a server named \"\(name)\" already exists")
            return 2
        }

        if let code = storePassword(options, serverID: server.id) {
            return code
        }

        guard let index = servers.firstIndex(where: { $0.id == old.id }) else { return 1 }
        servers[index] = server
        ConfigManager.shared.saveServers(servers)
        guard isSaved(server) else {
            printError("could not save \(ConfigManager.configPath.path)")
            return 1
        }
        configChanged()
        print("Updated \(server.name)")

        // Auto-connect, auto-reconnect, name and icon apply right away; the rest is openfortivpn input
        let connectionChanged = server.host != old.host || server.port != old.port
            || server.username != old.username || server.trustedCert != old.trustedCert
            || server.noRoutesDNS != old.noRoutesDNS || server.staticRoutes != old.staticRoutes
            || options.has("--password") || options.has("--password-stdin")
        if connectionChanged, runningState()?.tunnels.contains(where: { $0.id == server.id }) == true {
            print("Note: \(server.name) is connected; connection changes apply on the next connect")
        }
        warnIfRoutesNeedPermission(server)
        return 0
    }

    // MARK: - remove

    static func remove(_ args: [String]) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        guard let query = options.positional.first else {
            return usage("remove needs a server: fortibar remove <server> [--yes]")
        }
        guard options.positional.count == 1 else {
            return usage("unexpected argument \"\(options.positional[1])\" (quote names with spaces)")
        }
        guard let server = resolve(query) else { return 2 }

        if !(options.has("--yes") || options.has("-y")) {
            guard isatty(STDIN_FILENO) != 0 else {
                printError("pass --yes to remove \"\(server.name)\" non-interactively")
                return 2
            }
            print("Remove \"\(server.name)\" and its saved password? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Cancelled")
                return 1
            }
        }

        if runningState()?.tunnels.contains(where: { $0.id == server.id }) == true {
            _ = disconnect(server.id, wait: true)
        }

        let servers = ConfigManager.shared.config.servers.filter { $0.id != server.id }
        ConfigManager.shared.saveServers(servers)
        // saveServers does not report failures: only drop the password once the server is really gone
        guard !ConfigManager.shared.config.servers.contains(where: { $0.id == server.id }) else {
            printError("could not save \(ConfigManager.configPath.path)")
            return 1
        }
        KeychainHelper.delete(for: server.id)
        configChanged()
        print("Removed \(server.name)")
        return 0
    }

    // MARK: - show

    static func show(_ args: [String], json: Bool) -> Int32 {
        guard let query = args.first else { return usage("show needs a server") }
        guard let server = resolve(query) else { return 2 }
        let tunnel = runningState()?.tunnels.first { $0.id == server.id }
        let hasPassword = !(KeychainHelper.read(for: server.id)?.isEmpty ?? true)

        if json {
            var item: [String: Any] = [
                "id": server.id, "name": server.name, "host": server.host, "port": server.port,
                "username": server.username, "icon": server.iconName,
                "no_routes_dns": server.noRoutesDNS, "static_routes": server.staticRoutes,
                "auto_connect": server.autoConnect, "auto_reconnect": server.autoReconnect,
                "has_password": hasPassword,
                "state": tunnel?.state ?? "disconnected"
            ]
            item["trusted_cert"] = server.trustedCert
            item["interface"] = tunnel?.interface
            item["ip"] = tunnel?.ip
            return printJSON(item)
        }

        let rows: [(String, String)] = [
            ("Name", server.name),
            ("ID", server.id),
            ("Gateway", "\(server.host):\(server.port)"),
            ("User", server.username),
            ("Password", hasPassword ? "saved in Keychain" : "not set"),
            ("Certificate", server.trustedCert ?? "not pinned yet (trusted on first connect)"),
            ("Routes/DNS", server.noRoutesDNS ? "left untouched (--no-routes --no-dns)" : "managed by openfortivpn"),
            ("Static routes", server.staticRoutes.isEmpty ? "-" : server.staticRoutes.joined(separator: ", ")),
            ("Auto-connect", server.autoConnect ? "yes" : "no"),
            ("Reconnect", server.autoReconnect ? "automatically" : "no"),
            ("State", tunnel.map { [$0.state, $0.ip, $0.interface].compactMap { $0 }.joined(separator: ", ") } ?? "disconnected")
        ]
        for (label, value) in rows {
            print(pad(label + ":", 15) + value)
        }
        return 0
    }

    // MARK: - settings

    static func settings(_ args: [String], json: Bool) -> Int32 {
        guard let options = parseOptions(args) else { return 2 }
        if let extra = options.positional.first ?? options.flags.first {
            return usage("unexpected argument \"\(extra)\"")
        }

        // Validate everything before saving anything, so a bad value leaves the config untouched
        let enabled = options.value("--allow-multiple").map(parseBool)
        if case .some(.none) = enabled { return usage("--allow-multiple takes on or off") }
        let path = options.value("--openfortivpn-path")
        if let path = path {
            // Relative paths would be resolved against the app's working directory, not this one
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                printError("not an executable (absolute path needed): \(path)")
                return 2
            }
        }

        if let enabled = enabled ?? nil {
            ConfigManager.shared.saveAllowMultipleConnections(enabled)
        }
        if let path = path {
            ConfigManager.shared.saveOpenfortivpnPath(path)
        }
        if enabled != nil || path != nil { configChanged() }

        let config = ConfigManager.shared.config
        if json {
            return printJSON([
                "allow_multiple_connections": config.allowMultipleConnections,
                "openfortivpn_path": config.openfortivpnPath,
                "config_file": ConfigManager.configPath.path
            ] as [String: Any])
        }
        print(pad("Allow multiple connections:", 29) + (config.allowMultipleConnections ? "on" : "off"))
        print(pad("openfortivpn:", 29) + config.openfortivpnPath)
        print(pad("Config file:", 29) + ConfigManager.configPath.path)
        return 0
    }

    // MARK: - permission

    static func permission(_ args: [String]) -> Int32 {
        // A typo (`permission instal`) must not look like a successful status check
        if let sub = args.first, !["install", "update", "status"].contains(sub) || args.count > 1 {
            return usage("permission takes status, install, update or nothing")
        }
        let path = VPNManager.locateOpenfortivpn()
        if args.first == "install" || args.first == "update" {
            guard let path = path else {
                printError("openfortivpn not found")
                return 1
            }
            do {
                // Shows the macOS administrator password dialog
                try SudoersManager.shared.install(binaryPath: path)
            } catch {
                printError(error.localizedDescription)
                return 1
            }
        }

        let status = SudoersManager.shared.status(for: path)
        let text: String
        switch status {
        case .managed: text = "ok (\(SudoersManager.rulePath))"
        case .external: text = "ok (a rule not managed by FortiBar)"
        case .legacyRule: text = "ok, but under the old OpenFortiMac rule name: run fortibar permission update"
        case .routesMissing: text = "static routes not allowed: run fortibar permission update"
        case .forceStopMissing: text = "force stop of a hung tunnel not allowed: run fortibar permission update"
        case .outdated: text = "rule points to another openfortivpn: run fortibar permission update"
        case .missing: text = "not set up: run fortibar permission install"
        case .binaryNotFound: text = "openfortivpn not found"
        }
        print("Permission: \(text)")
        return [.managed, .external, .legacyRule].contains(status) ? 0 : 1
    }

    // MARK: - Helpers

    /// `previous`: the profile being edited; its icon is accepted as is even if no longer offered.
    static func validate(_ server: VPNServer, previous: VPNServer? = nil) -> String? {
        // These values end up as `key = value` lines in openfortivpn's config file:
        // a line break would add options of its own (openfortivpn runs as root)
        let hasControl: (String) -> Bool = { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        if server.name.isEmpty { return "name cannot be empty" }
        if hasControl(server.name) { return "name cannot contain control characters" }
        if server.host.isEmpty || server.host.contains(where: \.isWhitespace) || hasControl(server.host) {
            return "host cannot be empty or contain spaces"
        }
        if !(1...65535).contains(server.port) { return "port must be a number between 1 and 65535" }
        if server.username.trimmingCharacters(in: .whitespaces).isEmpty { return "user cannot be empty" }
        if hasControl(server.username) { return "user cannot contain control characters" }
        if let cert = server.trustedCert, cert.contains(where: \.isWhitespace) || hasControl(cert) {
            return "certificate digest cannot contain spaces"
        }
        if let bad = server.staticRoutes.first(where: { !VPNServer.isValidCIDR($0) }) {
            return "invalid route \"\(bad)\": use CIDR notation like 10.20.30.0/24"
        }
        if let icon = server.icon, icon != previous?.icon, !VPNServer.iconChoices.contains(icon) {
            return "unknown icon \"\(icon)\": choose one of " + VPNServer.iconChoices.joined(separator: ", ")
        }
        return nil
    }

    /// `--password` prompts without echo, `--password-stdin` reads one line from stdin.
    /// Returns an exit code on failure, nil when done or not requested.
    static func storePassword(_ options: Options, serverID: String) -> Int32? {
        var password: String?
        if options.has("--password-stdin") {
            password = readLine(strippingNewline: true)
        } else if options.has("--password") {
            var buffer = [CChar](repeating: 0, count: 1024)
            // Do not leave the clear text in the process memory longer than needed
            defer { _ = memset_s(&buffer, buffer.count, 0, buffer.count) }
            guard let raw = readpassphrase("Password: ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
                printError("could not read the password (no terminal? use --password-stdin)")
                return 1
            }
            password = String(cString: raw)
        } else {
            return nil
        }

        guard let value = password, !value.isEmpty else {
            printError("empty password")
            return 2
        }
        guard KeychainHelper.save(password: value, for: serverID) else {
            printError("could not save the password to the Keychain")
            return 1
        }
        return nil
    }

    static func warnIfRoutesNeedPermission(_ server: VPNServer) {
        guard !server.validatedStaticRoutes.isEmpty, !SudoersManager.shared.routesAllowed() else { return }
        print("Note: static routes need an updated sudo rule: fortibar permission update")
    }

    /// Tells a running app to re-read config.json, so it does not overwrite these changes.
    static func configChanged() {
        guard runningState() != nil else { return }
        // The change is saved either way; send() has printed why the app did not pick it up
        _ = send(.reloadConfig, server: nil)
    }

    /// True when config.json now holds exactly this profile (ConfigManager does not report write errors).
    static func isSaved(_ server: VPNServer) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let saved = ConfigManager.shared.config.servers.first(where: { $0.id == server.id }) else { return false }
        return (try? encoder.encode(saved)) == (try? encoder.encode(server))
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }
}
