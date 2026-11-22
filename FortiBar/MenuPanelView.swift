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
                .padding(12)

            if let banner = setupBanner {
                banner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
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
                TunnelCard(tunnel: nil, iconStyle: model.iconStyle, onDisconnect: nil, disconnectShortcut: false)
            }
            ForEach(vpn.tunnels) { tunnel in
                TunnelCard(
                    tunnel: tunnel,
                    iconStyle: model.iconStyle,
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
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Add your first server")
                    .font(.callout)
                Button("Add server") { model.openSettings(.servers, .add) }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servers")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        GlassGroup(spacing: 8) {
            HStack(spacing: 6) {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - State helpers

extension VPNState {
    /// Status card symbol, matching the menu bar icon style.
    func iconSymbol(style: MenuBarIconStyle) -> String {
        switch (self, style) {
        case (.disconnected, .classic): return "lock.open"
        case (.connecting, .classic), (.disconnecting, .classic), (.reconnecting, .classic): return "arrow.triangle.2.circlepath"
        case (.connected, .classic): return "lock.fill"
        case (.disconnected, .monochrome): return "shield"
        case (.connecting, .monochrome), (.disconnecting, .monochrome), (.reconnecting, .monochrome): return "shield.lefthalf.filled"
        case (.connected, .monochrome): return "checkmark.shield.fill"
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

/// One tunnel, or the idle state when `tunnel` is nil. A content surface: the glass is the
/// status puck and the buttons, so nothing is stacked on glass.
private struct TunnelCard: View {
    let tunnel: TunnelStatus?
    let iconStyle: MenuBarIconStyle
    let onDisconnect: (() -> Void)?
    let disconnectShortcut: Bool

    private var state: VPNState { tunnel?.state ?? .disconnected }
    private var busy: Bool { tunnel?.isBusy ?? false }
    private var tint: Color { state.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statusPuck

                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel?.serverName ?? "Not connected")
                        .font(.headline)
                        .lineLimit(1)
                    TunnelSubtitle(tunnel: tunnel)
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
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusPuck: some View {
        ZStack {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.iconSymbol(style: iconStyle))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 40, height: 40)
        .glassSurface(in: Circle(), tint: tint)
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

/// Status line under the tunnel name; connected and reconnecting tick every second.
private struct TunnelSubtitle: View {
    let tunnel: TunnelStatus?

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
                    Text("Connected · \(Self.format(context.date.timeIntervalSince(since)))")
                        .monospacedDigit()
                }
            } else {
                Text("Connected")
            }
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Setup Banner

private struct SetupBanner: View {
    let title: String
    let detail: String
    let action: String
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action, action: onAction)
                .glassButtonStyle()
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Server Row

private struct PanelServerRow: View {
    let server: VPNServer
    let tunnel: TunnelStatus?
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
                        .fill(tunnel.isConnected ? Color.green : Color.orange)
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
    }

    @ViewBuilder
    private var subtitle: some View {
        if let stateText {
            Text("\(server.host) · \(stateText)").foregroundStyle(.orange)
        } else if hasPassword {
            Text(server.host).foregroundStyle(.secondary)
        } else {
            Text("No password · click to edit").foregroundStyle(.orange)
        }
    }
}

// MARK: - Footer Button

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glassSurface(in: Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }
}
