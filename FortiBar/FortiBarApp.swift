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
        Settings {
            EmptyView()
        }
    }
}
