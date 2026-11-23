import Foundation

/// Runs short helper tools (sudo, osascript, ifconfig, pgrep) and collects their output.
nonisolated enum Subprocess {
    /// Blocking: waits for the process to exit. stdout and stderr are combined.
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        // Read before waiting so a full pipe cannot block the child
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
