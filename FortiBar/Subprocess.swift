import Foundation

/// Runs short helper tools (sudo, osascript, ifconfig, pgrep) and collects their output.
nonisolated enum Subprocess {
    /// Blocking: waits for the process to exit. stdout and stderr are combined.
    /// With `timeout` a process still running after that many seconds is terminated
    /// (status -2), so a hung helper cannot block its queue forever.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) -> (status: Int32, output: String) {
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

        var timedOut = false
        let timeoutLock = NSLock()
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                timeoutLock.lock()
                defer { timeoutLock.unlock() }
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        }

        // Read before waiting so a full pipe cannot block the child
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()

        timeoutLock.lock()
        defer { timeoutLock.unlock() }
        return (timedOut ? -2 : process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
