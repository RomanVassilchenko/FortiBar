import Foundation
import Testing
@testable import FortiBar

/// Temp folder with two fake bin dirs and two fake FortiBar.app copies.
private final class Sandbox {
    let root: URL
    let homebrewBin: URL
    let localBin: URL
    let executable: URL
    let otherExecutable: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("fortibar-cli-\(UUID().uuidString)")
        homebrewBin = root.appendingPathComponent("opt/homebrew/bin")
        localBin = root.appendingPathComponent("usr/local/bin")
        executable = root.appendingPathComponent("Applications/FortiBar.app/Contents/MacOS/FortiBar")
        otherExecutable = root.appendingPathComponent("Caskroom/fortibar/1.5.0/FortiBar.app/Contents/MacOS/FortiBar")
        for url in [homebrewBin, localBin, executable.deletingLastPathComponent(), otherExecutable.deletingLastPathComponent()] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [executable, otherExecutable] {
            try Data("#!/bin/sh\n".utf8).write(to: url)
        }
    }

    deinit {
        // Restore permissions changed by a test so the folder can be deleted
        for url in [homebrewBin, localBin] {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? fm.removeItem(at: root)
    }

    func installer(
        includeHomebrew: Bool = true,
        runAsAdministrator: @escaping CLIInstaller.AdministratorRunner = { _, _ in Issue.record("unexpected admin dialog") }
    ) -> CLIInstaller {
        var candidates = [CLIInstaller.Candidate(directory: localBin.path, allowsAdministrator: true)]
        if includeHomebrew {
            candidates.insert(CLIInstaller.Candidate(directory: homebrewBin.path, allowsAdministrator: false), at: 0)
        }
        return CLIInstaller(
            candidates: candidates,
            executablePath: executable.path,
            homeDirectory: root.appendingPathComponent("home").path,
            runAsAdministrator: runAsAdministrator
        )
    }

    func link(in dir: URL) -> String { dir.appendingPathComponent("fortibar").path }

    func makeLink(in dir: URL, to target: String) throws {
        try fm.createSymbolicLink(atPath: link(in: dir), withDestinationPath: target)
    }

    func destination(in dir: URL) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: link(in: dir))
    }
}

struct CLIInstallerTests {
    @Test func prefersWritableHomebrewBin() throws {
        let box = try Sandbox()
        let installer = box.installer()
        let choice = try #require(installer.installCandidate())
        #expect(choice.candidate.directory == box.homebrewBin.path)
        #expect(!choice.needsAdministrator)

        let status = installer.status()
        #expect(status.state == .notInstalled)
        #expect(status.linkPath == box.link(in: box.homebrewBin))
        #expect(status.writable)
    }

    @Test func fallsBackToLocalBinWhenHomebrewIsMissing() throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.homebrewBin)
        let choice = try #require(box.installer().installCandidate())
        #expect(choice.candidate.directory == box.localBin.path)
        #expect(!choice.needsAdministrator)
    }

    @Test func unwritableLocalBinNeedsAdministrator() throws {
        let box = try Sandbox()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.homebrewBin.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.localBin.path)
        let choice = try #require(box.installer().installCandidate())
        // Homebrew's bin does not allow the dialog: the system-wide one is used
        #expect(choice.candidate.directory == box.localBin.path)
        #expect(choice.needsAdministrator)
    }

    @Test func noDirectoryIsReported() throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.homebrewBin)
        try FileManager.default.removeItem(at: box.localBin)
        let installer = box.installer()
        #expect(installer.installCandidate() == nil)
        #expect(installer.status().state == .noDirectory)
        #expect(throws: CLIInstallerError.noDirectory) { try installer.install() }
        // Directories are never created
        #expect(!FileManager.default.fileExists(atPath: box.localBin.path))
    }

    @Test func installsAndRemovesLink() throws {
        let box = try Sandbox()
        let installer = box.installer()
        let result = try installer.install()
        #expect(result == CLIInstaller.Result(linkPath: box.link(in: box.homebrewBin), replacedTarget: nil))
        #expect(box.destination(in: box.homebrewBin) == box.executable.path)

        let status = installer.status()
        #expect(status.state == .installed)
        #expect(status.removable)

        // Installing again is a no-op
        #expect(try installer.install().replacedTarget == nil)

        try installer.remove()
        #expect(box.destination(in: box.homebrewBin) == nil)
        #expect(installer.status().state == .notInstalled)
        // The app executable is untouched
        #expect(FileManager.default.fileExists(atPath: box.executable.path))
    }

    @Test func classifiesOtherCopyAndReplacesIt() throws {
        let box = try Sandbox()
        try box.makeLink(in: box.homebrewBin, to: box.otherExecutable.path)
        let installer = box.installer()

        let status = installer.status()
        #expect(status.state == .otherCopy(target: box.otherExecutable.path))
        #expect(status.removable)

        let result = try installer.install()
        #expect(result.replacedTarget == box.otherExecutable.path)
        #expect(box.destination(in: box.homebrewBin) == box.executable.path)
        #expect(FileManager.default.fileExists(atPath: box.otherExecutable.path))
    }

    @Test func relativeLinkToThisAppIsInstalled() throws {
        let box = try Sandbox()
        try box.makeLink(in: box.homebrewBin, to: "../../../Applications/FortiBar.app/Contents/MacOS/FortiBar")
        #expect(box.installer().status().state == .installed)
    }

    @Test func danglingFortiBarLinkIsRemovableAndReplaced() throws {
        let box = try Sandbox()
        try box.makeLink(in: box.homebrewBin, to: "/nonexistent/Old FortiBar.app/Contents/MacOS/FortiBar")
        let installer = box.installer()
        let status = installer.status()
        #expect(status.state == .dangling(target: "/nonexistent/Old FortiBar.app/Contents/MacOS/FortiBar"))
        #expect(status.removable)

        let result = try installer.install()
        #expect(result.replacedTarget == "/nonexistent/Old FortiBar.app/Contents/MacOS/FortiBar")
        #expect(box.destination(in: box.homebrewBin) == box.executable.path)
    }

    @Test func foreignLinkIsReplacedButNeverRemoved() throws {
        let box = try Sandbox()
        let foreign = box.root.appendingPathComponent("other-tool")
        try Data().write(to: foreign)
        try box.makeLink(in: box.homebrewBin, to: foreign.path)
        let installer = box.installer()

        let status = installer.status()
        #expect(status.state == .foreignLink(target: foreign.path))
        #expect(!status.removable)
        #expect(throws: CLIInstallerError.notRemovable(box.link(in: box.homebrewBin))) { try installer.remove() }
        #expect(box.destination(in: box.homebrewBin) == foreign.path)

        #expect(try installer.install().replacedTarget == foreign.path)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func regularFileIsNeverTouched() throws {
        let box = try Sandbox()
        let file = box.link(in: box.homebrewBin)
        try Data("real binary".utf8).write(to: URL(fileURLWithPath: file))
        let installer = box.installer()

        let status = installer.status()
        #expect(status.state == .notALink)
        #expect(!status.removable)
        #expect(throws: CLIInstallerError.notALink(file)) { try installer.install() }
        #expect(throws: CLIInstallerError.notRemovable(file)) { try installer.remove() }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "real binary")
        // Nothing was linked anywhere else either
        #expect(box.destination(in: box.localBin) == nil)
    }

    @Test func existingLinkInLaterDirectoryIsReplacedInPlace() throws {
        let box = try Sandbox()
        try box.makeLink(in: box.localBin, to: box.otherExecutable.path)
        let installer = box.installer()
        #expect(installer.status().linkPath == box.link(in: box.localBin))

        try installer.install()
        #expect(box.destination(in: box.localBin) == box.executable.path)
        #expect(box.destination(in: box.homebrewBin) == nil)
    }

    @Test func unwritableDirectoryGoesThroughAdministratorScript() throws {
        let box = try Sandbox()
        try FileManager.default.removeItem(at: box.homebrewBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.localBin.path)
        var scripts: [String] = []
        let installer = box.installer(includeHomebrew: false) { script, _ in scripts.append(script) }

        try installer.install()
        #expect(scripts == [try CLIInstaller.installScript(link: box.link(in: box.localBin), target: box.executable.path)])
    }

    @Test func cancelledAdministratorDialogPropagates() throws {
        let box = try Sandbox()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.localBin.path)
        let installer = box.installer(includeHomebrew: false) { _, _ in throw SudoersError.cancelled }
        #expect(throws: SudoersError.self) { try installer.install() }
    }

    @Test func refusesTranslocatedApp() throws {
        let installer = CLIInstaller(
            candidates: [],
            executablePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/FortiBar.app/Contents/MacOS/FortiBar",
            runAsAdministrator: { _, _ in Issue.record("unexpected admin dialog") }
        )
        #expect(installer.location == .translocated)
        #expect(throws: CLIInstallerError.translocated) { try installer.install() }
    }

    @Test func appLocations() {
        let home = "/Users/me"
        #expect(CLIInstaller.location(ofExecutable: "/Applications/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .applications)
        #expect(CLIInstaller.location(ofExecutable: "/Applications/Utilities/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .applications)
        #expect(CLIInstaller.location(ofExecutable: "/Users/me/Applications/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .applications)
        #expect(CLIInstaller.location(ofExecutable: "/Users/me/Downloads/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .unusual)
        #expect(CLIInstaller.location(ofExecutable: "/Volumes/FortiBar/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .unusual)
        #expect(CLIInstaller.location(ofExecutable: "/ApplicationsX/FortiBar.app/Contents/MacOS/FortiBar", homeDirectory: home) == .unusual)
    }

    @Test func fortiBarExecutablePaths() {
        #expect(CLIInstaller.isFortiBarExecutable("/Applications/FortiBar.app/Contents/MacOS/FortiBar"))
        #expect(CLIInstaller.isFortiBarExecutable("/opt/homebrew/Caskroom/fortibar/1.6.0/FortiBar 2.app/Contents/MacOS/FortiBar"))
        #expect(!CLIInstaller.isFortiBarExecutable("/Applications/FortiBar.app/Contents/MacOS/Other"))
        #expect(!CLIInstaller.isFortiBarExecutable("/usr/local/bin/FortiBar"))
        #expect(!CLIInstaller.isFortiBarExecutable("/Applications/FortiBar/Contents/MacOS/FortiBar"))
        #expect(!CLIInstaller.isFortiBarExecutable("/.app/Contents/MacOS/FortiBar"))
    }

    @Test func shellPathWhitelist() throws {
        #expect(CLIInstaller.isSafeShellPath("/usr/local/bin/fortibar"))
        #expect(CLIInstaller.isSafeShellPath("/Applications/FortiBar 2.app/Contents/MacOS/FortiBar"))
        for bad in ["relative/path", "/tmp/it's", "/tmp/$(id)", "/tmp/a`b`", "/tmp/a\\b", "/tmp/a\nb", "/tmp/a\"b", "/usr/local/bin/../../etc/x", "/tmp/;rm"] {
            #expect(!CLIInstaller.isSafeShellPath(bad), "\(bad)")
        }
        #expect(throws: CLIInstallerError.invalidPath("/tmp/it's")) {
            try CLIInstaller.installScript(link: "/usr/local/bin/fortibar", target: "/tmp/it's")
        }
        #expect(throws: CLIInstallerError.invalidPath("/tmp/$x/fortibar")) {
            try CLIInstaller.removeScript(link: "/tmp/$x/fortibar")
        }
    }

    @Test func installScriptOnlyReplacesSymlinks() throws {
        let script = try CLIInstaller.installScript(link: "/usr/local/bin/fortibar", target: "/Applications/FortiBar.app/Contents/MacOS/FortiBar")
        #expect(script.hasPrefix("l='/usr/local/bin/fortibar'; t='/Applications/FortiBar.app/Contents/MacOS/FortiBar';"))
        #expect(script.contains("if [ -L \"$l\" ]; then /bin/rm -f \"$l\""))
        #expect(script.contains("elif [ -e \"$l\" ]"))
        #expect(!script.contains("ln -sf"))
    }

    /// Runs the generated script with sh against temp files (no root needed in a writable dir).
    @Test func scriptsBehaveInAShell() throws {
        let box = try Sandbox()
        let link = box.link(in: box.localBin)

        func sh(_ script: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        try box.makeLink(in: box.localBin, to: box.otherExecutable.path)
        #expect(try sh(CLIInstaller.installScript(link: link, target: box.executable.path)) == 0)
        #expect(box.destination(in: box.localBin) == box.executable.path)

        #expect(try sh(CLIInstaller.removeScript(link: link)) == 0)
        #expect(box.destination(in: box.localBin) == nil)

        try Data("keep".utf8).write(to: URL(fileURLWithPath: link))
        #expect(try sh(CLIInstaller.installScript(link: link, target: box.executable.path)) != 0)
        #expect(try sh(CLIInstaller.removeScript(link: link)) == 0)
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "keep")
    }
}
