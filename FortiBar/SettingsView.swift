import SwiftUI
import Combine
import ServiceManagement

enum SettingsTab: CaseIterable {
    case servers, permission, general, log

    var title: String {
        switch self {
        case .servers: return "Servers"
        case .permission: return "Permission"
        case .general: return "General"
        case .log: return "Log"
        }
    }

    var symbol: String {
        switch self {
        case .servers: return "server.rack"
        case .permission: return "lock.shield"
        case .general: return "gearshape"
        case .log: return "doc.text"
        }
    }
}

/// Asks the settings window to open the server editor, e.g. from the menu bar panel.
enum ServerEditorRequest: Equatable {
    case add
    case edit(String)
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    /// The server the editor sheet shows
    @State private var selectedServer: VPNServer?
    /// List highlight, by id: a VPNServer value changes with every edit or reload
    @State private var selectedServerID: String?
    @State private var showingAddServer = false
    @State private var showingEditServer = false
    @State private var selectedTab: SettingsTab
    @State private var pendingEditor: ServerEditorRequest?
    @State private var serverToDelete: VPNServer?
    @State private var showingDeleteConfirm = false
    
    init(initialTab: SettingsTab = .servers, initialEditor: ServerEditorRequest? = nil) {
        _selectedTab = State(initialValue: initialTab)
        _pendingEditor = State(initialValue: initialEditor)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch selectedTab {
                case .servers: serversTab
                case .permission: permissionTab
                case .general: generalTab
                case .log: logTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openServerEditor)) { notification in
            if let request = notification.object as? ServerEditorRequest {
                openEditor(request)
            }
        }
        .onAppear {
            if let request = pendingEditor {
                pendingEditor = nil
                // Wait for the window to be on screen before presenting a sheet
                DispatchQueue.main.async { openEditor(request) }
            }
        }
        .sheet(isPresented: $showingAddServer, onDismiss: { viewModel.loadServers() }) {
            ServerEditView(viewModel: viewModel, server: nil)
        }
        .sheet(isPresented: $showingEditServer, onDismiss: { viewModel.loadServers() }) {
            if let server = selectedServer {
                ServerEditView(viewModel: viewModel, server: server)
                    // A new form per server: opening another server while the sheet is up
                    // must not keep the previous server's fields
                    .id(server.id)
            }
        }
        .alert("Delete Server", isPresented: $showingDeleteConfirm, presenting: serverToDelete) { server in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let index = viewModel.servers.firstIndex(where: { $0.id == server.id }) {
                    viewModel.deleteServers(at: IndexSet(integer: index))
                    selectedServer = nil
                    selectedServerID = nil
                }
            }
        } message: { server in
            Text("Are you sure you want to delete \"\(server.name)\"?")
        }
    }
    
    /// Toolbar-style tabs, like the settings windows of system apps.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(tab.title).font(.caption)
                    }
                    .frame(width: 80, height: 48)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    .background(selectedTab == tab ? Color.primary.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func openEditor(_ request: ServerEditorRequest) {
        selectedTab = .servers
        switch request {
        case .add:
            showingAddServer = true
        case .edit(let id):
            if let server = viewModel.servers.first(where: { $0.id == id }) {
                selectedServer = server
                showingEditServer = true
            }
        }
    }
    
    // MARK: - Servers Tab
    
    private var serversTab: some View {
        VStack(spacing: 0) {
            if viewModel.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text("No Servers")
                        .font(.title3.weight(.semibold))
                    Text("Add the host, port and username of your FortiGate SSL VPN.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Server…") { showingAddServer = true }
                        .glassButtonStyle(prominent: true)
                        .controlSize(.large)
                        .padding(.top, 8)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedServerID) {
                    ForEach(viewModel.servers) { server in
                        ServerRowView(
                            server: server,
                            hasPassword: !viewModel.serversWithoutPassword.contains(server.id),
                            onEdit: {
                                selectedServer = server
                                showingEditServer = true
                            },
                            onDelete: {
                                serverToDelete = server
                                showingDeleteConfirm = true
                            }
                        )
                        .tag(server.id)
                        .onTapGesture(count: 2) {
                            selectedServer = server
                            showingEditServer = true
                        }
                    }
                    .onMove(perform: viewModel.moveServers)
                }
                .listStyle(.inset)
                .id(viewModel.refreshID)

                Divider()

                HStack {
                    Button(action: { showingAddServer = true }) {
                        Label("Add Server…", systemImage: "plus")
                    }

                    Spacer()

                    Text("Double-click to edit, drag to reorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
    
    // MARK: - Permission Tab
    
    private var permissionTab: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: sudoersIcon)
                        .font(.system(size: 28))
                        .foregroundColor(sudoersTint)
                        .frame(width: 36)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sudoersStatusText)
                            .font(.headline)
                        if let detail = sudoersStatusDetail {
                            Text(detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    
                    Spacer()
                    
                    if viewModel.sudoersBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
                
                if let actions = sudoersActions {
                    HStack {
                        Spacer()
                        actions
                    }
                }
                
                if let error = viewModel.sudoersError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            Section("How it works") {
                Text("openfortivpn needs root to create the VPN tunnel. FortiBar adds a sudo rule so it can start without asking for your password every time.")
                    .font(.callout)
                Text("Servers with static routes also need /sbin/route, limited to routes through ppp interfaces.")
                    .font(.callout)
                Text("The rule also allows /bin/kill -KILL, used only to stop an openfortivpn that hangs on disconnect.")
                    .font(.callout)
                Text("Any app running as your user gains the same ability. Remove the rule if you stop using FortiBar.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    private var sudoersActions: AnyView? {
        let busy = viewModel.sudoersBusy
        switch viewModel.sudoersStatus {
        case .routesMissing, .forceStopMissing:
            return AnyView(
                Button("Update…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            )
        case .missing:
            return AnyView(
                Button("Set Up…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            )
        case .legacyRule:
            return AnyView(HStack {
                Button("Remove") { viewModel.removeSudoers() }
                    .disabled(busy)
                Button("Update…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            })
        case .outdated:
            return AnyView(HStack {
                Button("Remove") { viewModel.removeSudoers() }
                    .disabled(busy)
                Button("Update…") { viewModel.setUpSudoers() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            })
        case .managed:
            return AnyView(
                Button("Remove") { viewModel.removeSudoers() }
                    .disabled(busy)
            )
        case .binaryNotFound:
            return AnyView(
                Button("Open General") { selectedTab = .general }
            )
        default:
            return nil
        }
    }
    
    private var sudoersIcon: String {
        switch viewModel.sudoersStatus {
        case .managed, .external: return "checkmark.shield.fill"
        case .legacyRule, .outdated, .missing, .routesMissing, .forceStopMissing: return "exclamationmark.shield.fill"
        case .binaryNotFound: return "xmark.shield.fill"
        case .none: return "shield"
        }
    }
    
    private var sudoersTint: Color {
        switch viewModel.sudoersStatus {
        case .managed, .external: return .green
        case .legacyRule, .outdated, .missing, .routesMissing, .forceStopMissing: return .orange
        case .binaryNotFound: return .red
        case .none: return .secondary
        }
    }
    
    private var sudoersStatusText: String {
        switch viewModel.sudoersStatus {
        case .none: return "Checking…"
        case .managed: return "openfortivpn can start without a password"
        case .external: return "Allowed by a rule you added manually"
        case .legacyRule: return "The rule uses the old OpenFortiMac name"
        case .outdated: return "The rule points to a different openfortivpn"
        case .missing: return "Not set up: connections will fail"
        case .routesMissing: return "Static routes need an updated rule"
        case .forceStopMissing: return "Update the rule to stop hung tunnels"
        case .binaryNotFound: return "openfortivpn not found"
        }
    }
    
    private var sudoersStatusDetail: String? {
        switch viewModel.sudoersStatus {
        case .managed, .outdated:
            return SudoersManager.rulePath
        case .legacyRule:
            return "\(LegacyMigration.legacySudoersRulePath) → \(SudoersManager.rulePath)"
        case .external:
            return "Not managed by FortiBar (e.g. /etc/sudoers.d/openfortivpn)"
        case .routesMissing:
            return "A server adds static routes: allow /sbin/route for ppp interfaces"
        case .forceStopMissing:
            return "Allows /bin/kill -KILL, so an openfortivpn that ignores Disconnect can be stopped"
        case .missing:
            return viewModel.resolvedOpenfortivpnPath
        case .binaryNotFound:
            return "Install it with brew install openfortivpn, or set its path in General."
        case .none:
            return nil
        }
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    LabeledContent("Path") {
                        TextField("", text: $viewModel.openfortivpnPath, prompt: Text(AppConfig.defaultOpenfortivpnPath))
                            .labelsHidden()
                            .font(.system(.callout, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                    
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.openfortivpnPath = url.path
                        }
                    }
                }
                
            } header: {
                Text("openfortivpn")
            } footer: {
                if !viewModel.isOpenfortivpnValid {
                    Label("No executable at this path. Install it with brew install openfortivpn.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            Section {
                Toggle("Allow multiple connections at once", isOn: $viewModel.allowMultipleConnections)
            } header: {
                Text("Connections")
            } footer: {
                Text("Each server runs its own tunnel. Give secondary servers \"Don't change routes or DNS\" so only one tunnel owns the default route and resolver. When off, connecting to a server drops the current one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Startup") {
                Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
            }

            Section {
                commandLineToolRow
            } header: {
                Text("Command Line Tool")
            } footer: {
                if let hint = commandLineToolHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Config File") {
                HStack {
                    Text((ConfigManager.configPath.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    
                    Spacer(minLength: 12)
                    
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            ConfigManager.configPath.path,
                            inFileViewerRootedAtPath: ConfigManager.configPath.deletingLastPathComponent().path
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private var commandLineToolRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cliStatusText)
                    if let detail = cliStatusDetail {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 12)

                if viewModel.cliBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                if viewModel.cliStatus?.removable == true {
                    Button("Remove") { viewModel.removeCLI() }
                        .disabled(viewModel.cliBusy)
                }
                if cliCanInstall {
                    Button("Install…") { viewModel.installCLI() }
                        .disabled(viewModel.cliBusy || viewModel.cliLocation == .translocated)
                }
            }

            if let error = viewModel.cliError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message = viewModel.cliMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cliCanInstall: Bool {
        switch viewModel.cliStatus?.state {
        case .notInstalled, .otherCopy, .dangling, .foreignLink: return true
        case .installed, .notALink, .noDirectory, .none: return false
        }
    }

    private var cliStatusText: String {
        switch viewModel.cliStatus?.state {
        case .none: return "Checking…"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .otherCopy: return "Linked to another copy of FortiBar"
        case .dangling: return "The fortibar link is broken"
        case .foreignLink: return "fortibar links to another program"
        case .notALink: return "A file named fortibar is in the way"
        case .noDirectory: return "No /opt/homebrew/bin or /usr/local/bin"
        }
    }

    private var cliStatusDetail: String? {
        guard let status = viewModel.cliStatus, let link = status.linkPath else { return nil }
        switch status.state {
        case .notInstalled:
            return "fortibar in \((link as NSString).deletingLastPathComponent)"
        case .installed, .notALink:
            return link
        case .otherCopy(let target), .dangling(let target), .foreignLink(let target):
            return "\(link) → \(target)"
        case .noDirectory:
            return nil
        }
    }

    private var commandLineToolHint: String? {
        switch viewModel.cliLocation {
        case .translocated:
            return "macOS runs FortiBar from a temporary copy. Move FortiBar to Applications and open it again to install the command."
        case .unusual:
            return "FortiBar is not in Applications: the link points at its current location and breaks if you move the app."
        case .applications, .none:
            return "Run fortibar help in Terminal for the commands."
        }
    }

    // MARK: - Log Tab
    
    private var logTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .overlay {
                    if viewModel.logs.isEmpty {
                        VStack(spacing: 6) {
                            Text("No Log Yet")
                                .font(.title3.weight(.semibold))
                            Text("openfortivpn output appears here when you connect.")
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.logs.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            Divider()
            
            HStack(spacing: 12) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.logs.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.logs.isEmpty)
                
                Button("Clear") {
                    viewModel.clearLogs()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.logs.isEmpty)
                
                Spacer()
                
                Button("Refresh") {
                    viewModel.loadLogs()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if !viewModel.logs.isEmpty {
            proxy.scrollTo(viewModel.logs.count - 1, anchor: .bottom)
        }
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let server: VPNServer
    /// Cached by the view model: reading the Keychain in `body` would hit it on every redraw
    let hasPassword: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.iconName)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text("\(server.host):\(server.port) · \(server.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !hasPassword {
                Text("No password")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Edit Server")
            .accessibilityLabel("Edit \(server.name)")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete Server")
            .accessibilityLabel("Delete \(server.name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Server Edit

struct ServerEditView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let server: VPNServer?
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "443"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var hasSavedPassword = false
    @State private var trustedCert: String = ""
    @State private var icon: String = VPNServer.defaultIcon
    @State private var noRoutesDNS: Bool = false
    @State private var staticRoutes: String = ""
    @State private var autoConnect: Bool = false
    @State private var autoReconnect: Bool = false
    @State private var validationError: String?
    
    var isEditing: Bool { server != nil }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Server" : "Add Server")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 4)
            
            Form {
                TextField("Name", text: $name, prompt: Text("Office VPN"))
                TextField("Host", text: $host, prompt: Text("vpn.example.com"))
                TextField("Port", text: $port, prompt: Text("443"))
                TextField("Username", text: $username, prompt: Text("Required"))
                // The saved password stays in the Keychain: an empty field keeps it
                SecureField("Password", text: $password, prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Required to connect"))
                LabeledContent("Certificate") {
                    TextField("", text: $trustedCert, prompt: Text("Trusted on first connect"))
                        .labelsHidden()
                        .font(trustedCert.isEmpty ? .body : .system(.caption, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Icon") {
                    HStack(spacing: 2) {
                        ForEach(VPNServer.iconChoices, id: \.self) { choice in
                            Button {
                                icon = choice
                            } label: {
                                Image(systemName: choice)
                                    .frame(width: 28, height: 24)
                                    .foregroundStyle(icon == choice ? Color.accentColor : .secondary)
                                    .background(
                                        icon == choice ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice)
                            .accessibilityAddTraits(icon == choice ? .isSelected : [])
                        }
                    }
                }
                
                Section {
                    Toggle("Connect at launch", isOn: $autoConnect)
                    Toggle("Reconnect automatically", isOn: $autoReconnect)
                        .help("Reconnects when the tunnel drops, e.g. after a network change, until you disconnect")
                    Toggle("Don't change routes or DNS", isOn: $noRoutesDNS)
                        .help("Runs openfortivpn with --no-routes --no-dns")
                    LabeledContent("Static routes") {
                        TextField("", text: $staticRoutes, prompt: Text("10.20.30.0/24"), axis: .vertical)
                            .labelsHidden()
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(2...4)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("One CIDR per line, routed through this tunnel's ppp interface while it is up")
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("For a secondary tunnel next to another one: leave routes and DNS to the main tunnel and list the networks to reach through this one, one CIDR per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            
            Divider()

            HStack(spacing: 12) {
                if let error = validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button(isEditing ? "Save" : "Add") {
                    if validate(), saveServer() {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 660)
        .onAppear {
            if let server = server {
                name = server.name
                host = server.host
                port = String(server.port)
                username = server.username
                // Do not pull the secret into the form: only show whether one is saved
                hasSavedPassword = !viewModel.serversWithoutPassword.contains(server.id)
                trustedCert = server.trustedCert ?? ""
                icon = server.iconName
                noRoutesDNS = server.noRoutesDNS
                staticRoutes = server.staticRoutes.joined(separator: "\n")
                autoConnect = server.autoConnect
                autoReconnect = server.autoReconnect
            }
        }
    }
    
    private func validate() -> Bool {
        validationError = nil
        
        // Host, username, password and certificate become "key = value" lines of the
        // openfortivpn config: a line break would inject further options
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty || trimmedHost.contains(where: { $0.isWhitespace }) || Self.hasControlCharacters(trimmedHost) {
            validationError = "Host cannot be empty or contain spaces"
            return false
        }
        if trimmedHost.hasPrefix("-") {
            validationError = "Host cannot start with \"-\""
            return false
        }

        guard let portInt = Int(port.trimmingCharacters(in: .whitespaces)), portInt >= 1, portInt <= 65535 else {
            validationError = "Port must be a number between 1 and 65535"
            return false
        }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationError = "Name cannot be empty"
            return false
        }

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            validationError = "Username cannot be empty"
            return false
        }
        if Self.hasControlCharacters(trimmedUser) {
            validationError = "Username cannot contain line breaks"
            return false
        }

        if Self.hasControlCharacters(password) {
            validationError = "Password cannot contain line breaks"
            return false
        }

        let cert = trustedCert.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cert.isEmpty, cert.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) == nil {
            validationError = "Certificate must be a SHA-256 digest (64 hex digits), or empty"
            return false
        }

        for cidr in parsedRoutes where !VPNServer.isValidCIDR(cidr) {
            validationError = "Invalid route \"\(cidr)\" — use CIDR notation like 10.20.30.0/24"
            return false
        }

        return true
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
    
    private var parsedRoutes: [String] {
        staticRoutes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    /// Returns false (with `validationError` set) when the password could not be stored.
    private func saveServer() -> Bool {
        let portInt = Int(port.trimmingCharacters(in: .whitespaces)) ?? 443
        // The profile as saved now: it may have changed since the editor opened
        let current = server.flatMap { old in ConfigManager.shared.config.servers.first { $0.id == old.id } }

        // A certificate pinned on first connect while the editor was open is kept, unless
        // the user changed the field
        let formCert = trustedCert.trimmingCharacters(in: .whitespacesAndNewlines)
        let cert: String?
        if let current = current, formCert == (server?.trustedCert ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
            cert = current.trustedCert
        } else {
            cert = formCert.isEmpty ? nil : formCert
        }

        // A plaintext password from an old config file is never written back: it moves to the
        // Keychain (unless one is saved there or given now) and is dropped from config.json
        var plaintextPassword = (current ?? server)?.password.flatMap { $0.isEmpty ? nil : $0 }
        if let plain = plaintextPassword, let id = server?.id,
           !password.isEmpty || KeychainHelper.read(for: id) != nil || KeychainHelper.save(password: plain, for: id) {
            plaintextPassword = nil
        }

        let newServer = VPNServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: plaintextPassword,
            trustedCert: cert,
            icon: icon,
            id: server?.id,
            noRoutesDNS: noRoutesDNS,
            staticRoutes: parsedRoutes,
            autoConnect: autoConnect,
            autoReconnect: autoReconnect
        )
        
        if !password.isEmpty, !KeychainHelper.save(password: password, for: newServer.id) {
            validationError = "Could not save the password in the Keychain"
            return false
        }

        if let existingServer = server {
            viewModel.updateServer(existingServer, with: newServer)
        } else {
            viewModel.addServer(newServer)
        }
        return true
    }
}

// MARK: - ViewModel

class SettingsViewModel: ObservableObject {
    @Published var servers: [VPNServer] = []
    /// Servers without a saved password, cached so rows do not hit the Keychain on every redraw
    @Published private(set) var serversWithoutPassword: Set<String> = []
    @Published var logs: [String] = []
    @Published var refreshID = UUID()
    @Published var openfortivpnPath: String = "" {
        didSet {
            if !isApplyingStoredValues, oldValue != openfortivpnPath {
                ConfigManager.shared.saveOpenfortivpnPath(openfortivpnPath)
            }
        }
    }
    @Published var allowMultipleConnections: Bool = false {
        didSet {
            if !isApplyingStoredValues, oldValue != allowMultipleConnections {
                ConfigManager.shared.saveAllowMultipleConnections(allowMultipleConnections)
            }
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            if !isApplyingStoredValues, oldValue != launchAtLogin {
                updateLaunchAtLogin()
            }
        }
    }

    /// Set while values are loaded from the config or the system, so the didSet handlers
    /// do not write them back (or re-register the login item) as if the user changed them
    private var isApplyingStoredValues = false
    /// Last log line when the user pressed Clear: only newer lines are shown afterwards
    private var clearedThroughLine: String?
    
    @Published private(set) var sudoersStatus: SudoersStatus?
    @Published private(set) var sudoersError: String?
    @Published private(set) var sudoersBusy = false
    @Published private(set) var resolvedOpenfortivpnPath: String?

    @Published private(set) var cliStatus: CLILinkStatus?
    @Published private(set) var cliLocation: CLIAppLocation?
    @Published private(set) var cliBusy = false
    @Published private(set) var cliError: String?
    /// What the last install or remove did, e.g. which link it replaced
    @Published private(set) var cliMessage: String?

    var isOpenfortivpnValid: Bool {
        FileManager.default.isExecutableFile(atPath: openfortivpnPath)
    }

    private var logsObserver: NSObjectProtocol?
    private var reloadObserver: NSObjectProtocol?
    private var pathObserver: AnyCancellable?

    init() {
        loadServers()
        loadLogs()
        applyStoredValues {
            openfortivpnPath = ConfigManager.shared.config.openfortivpnPath
            allowMultipleConnections = ConfigManager.shared.config.allowMultipleConnections
        }
        loadLaunchAtLogin()
        refreshSudoersStatus()
        refreshCLIStatus()

        // The path is saved on every keystroke, so wait for typing to settle before asking sudo
        pathObserver = $openfortivpnPath
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSudoersStatus()
            }

        reloadObserver = NotificationCenter.default.addObserver(
            forName: .configReloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let config = ConfigManager.shared.config
            self.loadServers()
            self.refreshID = UUID()
            self.applyStoredValues {
                self.allowMultipleConnections = config.allowMultipleConnections
                self.openfortivpnPath = config.openfortivpnPath
            }
        }

        logsObserver = NotificationCenter.default.addObserver(
            forName: .vpnLogsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadLogs()
        }
    }
    
    deinit {
        [logsObserver, reloadObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
    }
    
    private func applyStoredValues(_ apply: () -> Void) {
        isApplyingStoredValues = true
        apply()
        isApplyingStoredValues = false
    }

    func loadServers() {
        servers = []
        servers = ConfigManager.shared.config.servers
        refreshPasswordState()
    }

    private func refreshPasswordState() {
        serversWithoutPassword = Set(servers.filter { KeychainHelper.read(for: $0.id)?.isEmpty ?? true }.map(\.id))
    }

    func loadLogs() {
        let all = VPNManager.shared.connectionLogs
        // VPNManager keeps the lines; Clear only hides the ones already shown
        if let marker = clearedThroughLine, let index = all.lastIndex(of: marker) {
            logs = Array(all[(index + 1)...])
        } else {
            logs = all
        }
    }

    func clearLogs() {
        clearedThroughLine = VPNManager.shared.connectionLogs.last
        logs = []
    }
    
    func addServer(_ server: VPNServer) {
        servers.append(server)
        saveConfig()
        refreshID = UUID()
    }
    
    func updateServer(_ oldServer: VPNServer, with newServer: VPNServer) {
        if let index = servers.firstIndex(where: { $0.id == oldServer.id }) {
            servers[index] = newServer
            saveConfig()
            refreshID = UUID()
        }
    }
    
    func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            KeychainHelper.delete(for: servers[index].id)
        }
        servers.remove(atOffsets: offsets)
        saveConfig()
        refreshID = UUID()
    }
    
    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        saveConfig()
    }
    
    private func saveConfig() {
        ConfigManager.shared.saveServers(servers)
        refreshPasswordState()
        NotificationCenter.default.post(name: .configChanged, object: nil)
        // Static routes added or removed change what the sudo rule must allow
        refreshSudoersStatus()
    }
    
    // MARK: - Administrator Permission

    func refreshSudoersStatus() {
        let path = VPNManager.shared.findOpenfortivpnBinary()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoersManager.shared.status(for: path)
            DispatchQueue.main.async {
                self?.resolvedOpenfortivpnPath = path
                self?.sudoersStatus = status
                NotificationCenter.default.post(name: .sudoersChanged, object: status)
            }
        }
    }

    func setUpSudoers() {
        guard let path = VPNManager.shared.findOpenfortivpnBinary() else { return }
        changeSudoers { try SudoersManager.shared.install(binaryPath: path) }
    }

    func removeSudoers() {
        changeSudoers { try SudoersManager.shared.remove() }
    }

    private func changeSudoers(_ change: @escaping () throws -> Void) {
        sudoersBusy = true
        sudoersError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String?
            do {
                try change()
            } catch SudoersError.cancelled {
                // The user closed the password dialog: nothing to report
            } catch {
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                self?.sudoersBusy = false
                self?.sudoersError = message
                self?.refreshSudoersStatus()
            }
        }
    }

    // MARK: - Command Line Tool

    private var cliInstaller: CLIInstaller? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return CLIInstaller(executablePath: executable.path)
    }

    func refreshCLIStatus() {
        guard let installer = cliInstaller else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = installer.status()
            let location = installer.location
            DispatchQueue.main.async {
                self?.cliStatus = status
                self?.cliLocation = location
            }
        }
    }

    func installCLI() {
        changeCLI { installer in
            let result = try installer.install()
            if let replaced = result.replacedTarget {
                return "Replaced the link to \(replaced)"
            }
            return nil
        }
    }

    func removeCLI() {
        changeCLI { installer in
            try installer.remove()
            return nil
        }
    }

    /// `change` returns the message to show under the row.
    private func changeCLI(_ change: @escaping (CLIInstaller) throws -> String?) {
        guard let installer = cliInstaller else { return }
        cliBusy = true
        cliError = nil
        cliMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String?
            var errorMessage: String?
            do {
                message = try change(installer)
            } catch SudoersError.cancelled {
                // The user closed the password dialog: nothing to report
            } catch {
                errorMessage = error.localizedDescription
            }

            DispatchQueue.main.async {
                self?.cliBusy = false
                self?.cliMessage = message
                self?.cliError = errorMessage
                self?.refreshCLIStatus()
            }
        }
    }

    // MARK: - Launch at Login

    private func loadLaunchAtLogin() {
        // Only reflect the current state: registering again on every Settings open is not wanted
        applyStoredValues {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
            // Revert the toggle without calling register/unregister again
            DispatchQueue.main.async { [weak self] in
                self?.loadLaunchAtLogin()
            }
        }
    }
}

#Preview {
    SettingsView()
}
