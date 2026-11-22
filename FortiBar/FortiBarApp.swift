import SwiftUI

/// Entry point: `fortibar <command>` runs the command line tool,
/// anything else starts the menu bar app.
@main
enum Main {
    static func main() {
        if CommandLineTool.handles(CommandLine.arguments) {
            exit(CommandLineTool.run(CommandLine.arguments))
        }
        FortiBarApp.main()
    }
}

struct FortiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // The settings window is managed by AppDelegate. This scene only exists because an App needs one,
        // so ⌘, is routed to the real window instead of opening this empty one.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
