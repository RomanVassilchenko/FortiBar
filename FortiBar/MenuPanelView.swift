import SwiftUI

/// Content of the popover shown when clicking the menu bar icon.
struct MenuPanelView: View {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var vpn: VPNManager

    /// Rows shown before the server list starts scrolling
    private let maxVisibleServers = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tunnelCards
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if let banner = setupBanner {
                banner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            Divider()

            serverSection
                .padding(.vertical, 8)

            Divider()

            footer
        }
        .frame(width: 320)
    }

    // MARK: - Tunnel cards (one per active tunnel)

    private var tunnelCards: some View {
        VStack(spacing: 8) {
            if vpn.tunnels.isEmpty {
                TunnelCard(tunnel: nil, live: nil, onDisconnect: nil, disconnectShortcut: false)
            }
            ForEach(vpn.tunnels) { tunnel in
                TunnelCard(
                    tunnel: tunnel,
                    live: vpn.live[tunnel.serverID],
                    onDisconnect: { model.disconnect(serverID: tunnel.serverID) },
                    // ⌘D stays unambiguous: only with a single tunnel
                    disconnectShortcut: vpn.tunnels.count == 1
                )
            }
        }
    }

    // MARK: - Setup banner

    private var setupBanner: SetupBanner? {
        func banner(_ title: String, _ detail: String, _ action: String, tab: SettingsTab = .permission) -> SetupBanner {
            SetupBanner(title: title, detail: detail, action: action) { model.openSettings(tab, nil) }
        }

        switch model.sudoersStatus {
        case .missing:
            return banner("Administrator permission not set up", "openfortivpn needs it to start the tunnel.", "Set up")
        case .legacyRule:
            return banner("Update the permission rule", "One-time step: the sudo rule got a new name.", "Update")
        case .routesMissing:
            return banner("Static routes need permission", "Update the rule so routes can be added.", "Update")
        case .forceStopMissing:
            return banner("Update the permission rule", "Needed to stop a tunnel that hangs.", "Update")
        case .outdated:
            return banner("Permission points to another openfortivpn", "Update the rule after moving openfortivpn.", "Update")
        case .binaryNotFound:
            return banner("openfortivpn not found", "Install it with brew install openfortivpn.", "Settings", tab: .general)
        default:
            return nil
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private var serverSection: some View {
        if model.servers.isEmpty {
            VStack(spacing: 6) {
                Text("No Servers")
                    .font(.callout.weight(.semibold))
                Text("Add your FortiGate SSL VPN to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add Server…") { model.openSettings(.servers, .add) }
                    .glassButtonStyle()
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if model.servers.count > maxVisibleServers {
                    ScrollView {
                        serverList
                    }
                    .frame(height: CGFloat(maxVisibleServers) * 44)
                } else {
                    serverList
                }
            }
        }
    }

    private var serverList: some View {
        VStack(spacing: 2) {
            ForEach(model.servers) { server in
                PanelServerRow(
                    server: server,
                    tunnel: vpn.status(for: server.id),
                    live: vpn.live[server.id],
                    hasPassword: !model.serversWithoutPassword.contains(server.id)
                ) {
                    model.toggle(server)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(symbol: "plus", help: "Add server") {
                model.openSettings(.servers, .add)
            }
            FooterButton(symbol: "gearshape", help: "Settings") {
                model.openSettings(nil, nil)
            }
            .keyboardShortcut(",", modifiers: .command)
            FooterButton(symbol: "doc.text", help: "Log") {
                model.openSettings(.log, nil)
            }

            Spacer()

            FooterButton(symbol: "power", help: "Quit FortiBar") {
                model.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - State helpers

extension VPNState {
    /// Status card symbol, the same shields as the menu bar icon.
    var iconSymbol: String {
        switch self {
        case .disconnected: return "shield"
        case .connecting, .disconnecting, .reconnecting: return "shield.lefthalf.filled"
        case .connected: return "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting, .disconnecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        }
    }
}

// MARK: - Tunnel Card

/// One tunnel, or the idle state when `tunnel` is nil. Flat on the popover's own glass:
/// only the status puck and the buttons are glass.
private struct TunnelCard: View {
    let tunnel: TunnelStatus?
    let live: TunnelLive?
    let onDisconnect: (() -> Void)?
    let disconnectShortcut: Bool

    private var state: VPNState { tunnel?.state ?? .disconnected }
    private var busy: Bool { tunnel?.isBusy ?? false }
    /// Connected, but the health check sees no traffic getting through
    private var troubled: Bool { state.isConnected && live?.health.isProblem == true }
    private var tint: Color { troubled ? .orange : state.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statusPuck

                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel?.serverName ?? "Not connected")
                        .font(.headline)
                        .lineLimit(1)
                    TunnelSubtitle(tunnel: tunnel, health: live?.health ?? .unknown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let onDisconnect {
                    if busy {
                        Button("Cancel", action: onDisconnect)
                            .glassButtonStyle()
                    } else {
                        Button("Disconnect", action: onDisconnect)
                            .glassButtonStyle(prominent: true)
                            .tint(.red)
                            .keyboardShortcut(disconnectShortcut ? KeyboardShortcut("d", modifiers: .command) : nil)
                    }
                }
            }

            if let tunnel, tunnel.isConnected {
                details(of: tunnel)
            }
        }
    }

    private var statusPuck: some View {
        ZStack {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: troubled ? "exclamationmark.shield.fill" : state.iconSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 36, height: 36)
        .glassSurface(in: Circle(), tint: tint)
        // Decorative: the name and status line next to it carry the state
        .accessibilityHidden(true)
    }

    /// Short facts side by side, routes (possibly long) on their own line.
    @ViewBuilder
    private func details(of tunnel: TunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if let ip = tunnel.assignedIP {
                    Label(ip, systemImage: "network")
                }
                if let interface = tunnel.interface {
                    Label(interface, systemImage: "cable.connector")
                }
            }
            if !tunnel.routes.isEmpty {
                Label(tunnel.routes.joined(separator: ", "), systemImage: "arrow.triangle.branch")
                    .lineLimit(2)
            }
            if let live {
                trafficLine(live)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.leading, 48)
    }
}

/// Traffic through the tunnel since it came up, with the current speed while data is moving.
extension TunnelCard {
    @ViewBuilder
    fileprivate func trafficLine(_ live: TunnelLive) -> some View {
        let traffic = live.traffic
        HStack(spacing: 12) {
            Label(ByteFormat.size(traffic.rxBytes) + rateSuffix(traffic.rxRate), systemImage: "arrow.down")
            Label(ByteFormat.size(traffic.txBytes) + rateSuffix(traffic.txRate), systemImage: "arrow.up")
        }
        .monospacedDigit()
        .help("Received and sent through this tunnel since it connected")
    }

    private func rateSuffix(_ rate: Double) -> String {
        // Under 1 KB/s is idle chatter
        rate >= 1024 ? " · " + ByteFormat.rate(rate) : ""
    }
}

enum ByteFormat {
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        size(UInt64(max(0, bytesPerSecond))) + "/s"
    }
}

/// Status line under the tunnel name; connected and reconnecting tick every second.
private struct TunnelSubtitle: View {
    let tunnel: TunnelStatus?
    let health: TunnelHealth

    var body: some View {
        switch tunnel?.state ?? .disconnected {
        case .disconnected:
            Text("Choose a server to connect")
        case .connecting:
            Text("Connecting…")
        case .disconnecting:
            Text("Disconnecting…")
        case .reconnecting(let date):
            if let date {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text("Reconnecting in \(max(0, Int(date.timeIntervalSince(context.date).rounded(.up))))s…")
                        .monospacedDigit()
                }
            } else {
                Text("Waiting for the network…")
            }
        case .connected:
            if let since = tunnel?.connectedSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    HStack(spacing: 0) {
                        Text("Connected · \(CommandLineTool.duration(context.date.timeIntervalSince(since)))")
                            .monospacedDigit()
                        healthSuffix
                    }
                }
            } else {
                Text("Connected")
            }
        }
    }

    /// Latency while healthy, a warning when probes fail
    @ViewBuilder
    private var healthSuffix: some View {
        switch health {
        case .good(let latency):
            Text(" · \(Int(latency.rounded())) ms").monospacedDigit()
        case .failing:
            Text(" · no reply").foregroundStyle(.orange)
        case .unresponsive:
            Text(" · not responding").foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - Setup Banner

private struct SetupBanner: View {
    let title: String
    let detail: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        // Icon column as wide as the status puck, so the texts line up with the tunnel name
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action, action: onAction)
                    .glassButtonStyle()
                    .controlSize(.small)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Server Row

private struct PanelServerRow: View {
    let server: VPNServer
    let tunnel: TunnelStatus?
    let live: TunnelLive?
    let hasPassword: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    private var stateText: String? {
        switch tunnel?.state {
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected: return "Connected"
        case .disconnected, .none: return nil
        }
    }

    private var tint: Color { tunnel?.state.tint ?? .secondary }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: server.iconName)
                    .frame(width: 20)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                        .lineLimit(1)
                    subtitle
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let tunnel {
                    Circle()
                        .fill(tunnel.isConnected && live?.health.isProblem != true ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                } else if hovering {
                    Text(hasPassword ? "Connect" : "Edit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // The action is only shown on hover: tell VoiceOver what a click does
        .accessibilityHint(actionHint)
    }

    private var actionHint: String {
        switch tunnel?.state {
        case .none: return hasPassword ? "Connects" : "Opens the server editor to add the password"
        case .connecting, .reconnecting: return "Cancels the connection"
        default: return "Disconnects"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let stateText {
            Text("\(server.host) · \(stateText)").foregroundStyle(.orange)
        } else if hasPassword {
            Text(server.host).foregroundStyle(.secondary)
        } else {
            Text("No password").foregroundStyle(.orange)
        }
    }
}

// MARK: - Footer Button

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
