import Foundation

/// What a `fortibar` entry in a bin directory is.
enum CLILinkState: Equatable {
    /// No `fortibar` in any candidate directory
    case notInstalled
    /// A symlink to this app's executable
    case installed
    /// A symlink to the executable of another FortiBar.app (e.g. Homebrew's Caskroom copy)
    case otherCopy(target: String)
    /// A symlink whose target does not exist
    case dangling(target: String)
    /// A symlink to something that is not a FortiBar executable
    case foreignLink(target: String)
    /// A regular file or directory: never replaced or removed
    case notALink
    /// None of the candidate directories exists
    case noDirectory
}

struct CLILinkStatus: Equatable {
    /// `<dir>/fortibar`: the entry found, or where Install would create it (nil with `.noDirectory`)
    let linkPath: String?
    let state: CLILinkState
    /// The entry is a symlink into an app executable named FortiBar: Remove may delete it
    let removable: Bool
    /// Install would (re)create the link here without an administrator password
    let writable: Bool
}

/// Where the running app is, as far as linking it matters.
enum CLIAppLocation: Equatable {
    /// In /Applications or ~/Applications
    case applications
    /// Somewhere else (Downloads, DerivedData, a mounted DMG): the link follows that location
    case unusual
    /// Gatekeeper runs the app from a random read-only copy: a link would break on the next launch
    case translocated
}

enum CLIInstallerError: LocalizedError, Equatable {
    case translocated
    case notALink(String)
    case noDirectory
    case invalidPath(String)
    case notRemovable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .translocated:
            return "macOS runs FortiBar from a temporary copy. Move FortiBar to Applications, open it again, then install."
        case .notALink(let path):
            return "\(path) is not a symbolic link: remove it yourself if it is not needed"
        case .noDirectory:
            return "Neither /opt/homebrew/bin nor /usr/local/bin exists"
        case .invalidPath(let path):
            return "Unsupported characters in \"\(path)\""
        case .notRemovable(let path):
            return "\(path) is not a link to FortiBar"
        case .failed(let message):
            return message
        }
    }
}

/// Links the app executable as `fortibar` into a bin directory on the PATH.
/// Directories and the executable are parameters so the logic runs against temp folders in tests.
struct CLIInstaller {
    struct Candidate: Equatable {
        let directory: String
        /// When the directory is not writable, may the administrator dialog be used for it
        let allowsAdministrator: Bool
    }

    static let linkName = "fortibar"

    /// Homebrew's bin on Apple Silicon (user-writable), then the Intel / system-wide one.
    /// Directories are never created.
    static let defaultCandidates = [
        Candidate(directory: "/opt/homebrew/bin", allowsAdministrator: false),
        Candidate(directory: "/usr/local/bin", allowsAdministrator: true),
    ]

    /// What happened, for the status line.
    struct Result: Equatable {
        let linkPath: String
        /// Target of the symlink that was replaced, if any
        let replacedTarget: String?
    }

    typealias AdministratorRunner = (_ script: String, _ prompt: String) throws -> Void

    let candidates: [Candidate]
    /// The executable the link points at (Bundle.main.executableURL in the app)
    let executablePath: String
    let homeDirectory: String
    let runAsAdministrator: AdministratorRunner

    private var fileManager: FileManager { .default }

    init(
        candidates: [Candidate] = CLIInstaller.defaultCandidates,
        executablePath: String,
        homeDirectory: String = NSHomeDirectory(),
        runAsAdministrator: @escaping AdministratorRunner = { script, prompt in
            try SudoersManager.runAsAdministrator(script, prompt: prompt, fallbackError: "Could not change the fortibar link")
        }
    ) {
        self.candidates = candidates
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
        self.runAsAdministrator = runAsAdministrator
    }

    // MARK: - Pure logic

    /// The directory a new link goes to: the first existing writable candidate, else the first
    /// existing one that allows the administrator dialog.
    func installCandidate() -> (candidate: Candidate, needsAdministrator: Bool)? {
        let existing = candidates.filter { isDirectory($0.directory) }
        if let writable = existing.first(where: { fileManager.isWritableFile(atPath: $0.directory) }) {
            return (writable, false)
        }
        if let admin = existing.first(where: { $0.allowsAdministrator }) {
            return (admin, true)
        }
        return nil
    }

    /// The first `fortibar` entry in the candidate directories (in order), else where Install would put it.
    func status() -> CLILinkStatus {
        for candidate in candidates {
            let path = linkPath(in: candidate.directory)
            guard entryExists(path) else { continue }
            let state = classify(path)
            return CLILinkStatus(
                linkPath: path,
                state: state,
                removable: isRemovable(path),
                writable: fileManager.isWritableFile(atPath: candidate.directory)
            )
        }
        guard let target = installCandidate() else {
            return CLILinkStatus(linkPath: nil, state: .noDirectory, removable: false, writable: false)
        }
        return CLILinkStatus(
            linkPath: linkPath(in: target.candidate.directory),
            state: .notInstalled,
            removable: false,
            writable: !target.needsAdministrator
        )
    }

    /// What the entry at `path` is. `.notInstalled` when nothing is there.
    func classify(_ path: String) -> CLILinkState {
        guard entryExists(path) else { return .notInstalled }
        guard let target = symlinkTarget(path) else { return .notALink }
        // fileExists follows the link
        guard fileManager.fileExists(atPath: path) else { return .dangling(target: target) }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let this = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        if resolved == this { return .installed }
        if Self.isFortiBarExecutable(resolved) || Self.isFortiBarExecutable(target) {
            return .otherCopy(target: target)
        }
        return .foreignLink(target: target)
    }

    /// Only a symlink into `<something>.app/Contents/MacOS/FortiBar` (existing or not) may be removed.
    func isRemovable(_ path: String) -> Bool {
        guard let target = symlinkTarget(path) else { return false }
        if Self.isFortiBarExecutable(target) { return true }
        // A link to a link (e.g. through a renamed folder) that ends at a FortiBar executable
        return fileManager.fileExists(atPath: path)
            && Self.isFortiBarExecutable(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    static func isFortiBarExecutable(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 4 else { return false }
        let tail = parts.suffix(4)
        let app = tail[tail.startIndex]
        return app.hasSuffix(".app") && app.count > 4
            && Array(tail.dropFirst()) == ["Contents", "MacOS", "FortiBar"]
    }

    /// Where the app bundle of `executablePath` lives.
    static func location(ofExecutable executablePath: String, homeDirectory: String) -> CLIAppLocation {
        if executablePath.contains("/AppTranslocation/") { return .translocated }
        // <bundle>.app/Contents/MacOS/<exe>
        let bundle = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = bundle.deletingLastPathComponent().standardizedFileURL.path
        let roots = ["/Applications", (homeDirectory as NSString).appendingPathComponent("Applications")]
        let inApplications = roots.contains { parent == $0 || parent.hasPrefix($0 + "/") }
        return inApplications ? .applications : .unusual
    }

    var location: CLIAppLocation {
        Self.location(ofExecutable: executablePath, homeDirectory: homeDirectory)
    }

    /// Paths end up inside single quotes in a root shell: no quotes, no `$`, no backslashes,
    /// no control characters. Spaces are fine ("FortiBar 2.app").
    static func isSafeShellPath(_ path: String) -> Bool {
        path.range(of: "^/[A-Za-z0-9 ._/+-]+$", options: .regularExpression) != nil
            && !path.split(separator: "/").contains("..")
    }

    /// Root shell script that replaces a symlink (never anything else) at `link` with one to `target`.
    static func installScript(link: String, target: String) throws -> String {
        guard isSafeShellPath(link) else { throw CLIInstallerError.invalidPath(link) }
        guard isSafeShellPath(target) else { throw CLIInstallerError.invalidPath(target) }
        return """
        l='\(link)'; t='\(target)'; \
        if [ -L "$l" ]; then /bin/rm -f "$l" || exit 1; \
        elif [ -e "$l" ]; then echo "$l is not a symbolic link" >&2; exit 1; fi; \
        /bin/ln -s "$t" "$l"
        """
    }

    /// Root shell script that deletes `link` only if it is a symlink.
    static func removeScript(link: String) throws -> String {
        guard isSafeShellPath(link) else { throw CLIInstallerError.invalidPath(link) }
        return "l='\(link)'; if [ -L \"$l\" ]; then /bin/rm -f \"$l\"; fi"
    }

    // MARK: - Actions (blocking: call off the main thread)

    /// Creates `fortibar` -> executable, replacing a symlink that points elsewhere or nowhere.
    @discardableResult
    func install() throws -> Result {
        if location == .translocated { throw CLIInstallerError.translocated }

        let current = status()
        let link: String
        let needsAdministrator: Bool
        var replaced: String?

        switch current.state {
        case .noDirectory:
            throw CLIInstallerError.noDirectory
        case .notALink:
            throw CLIInstallerError.notALink(current.linkPath ?? Self.linkName)
        case .installed:
            return Result(linkPath: current.linkPath ?? Self.linkName, replacedTarget: nil)
        case .notInstalled:
            guard let target = installCandidate() else { throw CLIInstallerError.noDirectory }
            link = linkPath(in: target.candidate.directory)
            needsAdministrator = target.needsAdministrator
        case .otherCopy(let target), .dangling(let target), .foreignLink(let target):
            // Replace it where it is, so no second fortibar shadows the new one on the PATH
            link = current.linkPath ?? Self.linkName
            needsAdministrator = !current.writable
            replaced = target
        }

        if needsAdministrator {
            let script = try Self.installScript(link: link, target: executablePath)
            try runAsAdministrator(script, "FortiBar wants to install the fortibar command in \((link as NSString).deletingLastPathComponent).")
        } else {
            do {
                // Re-check right before touching anything: only a symlink is ever removed
                if entryExists(link) {
                    guard symlinkTarget(link) != nil else { throw CLIInstallerError.notALink(link) }
                    try fileManager.removeItem(atPath: link)
                }
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: executablePath)
            } catch let error as CLIInstallerError {
                throw error
            } catch {
                throw CLIInstallerError.failed(error.localizedDescription)
            }
        }
        return Result(linkPath: link, replacedTarget: replaced)
    }

    /// Deletes the `fortibar` link if it points into a FortiBar executable; never anything else.
    func remove() throws {
        let current = status()
        guard let link = current.linkPath, current.state != .notInstalled else { return }
        guard current.removable else { throw CLIInstallerError.notRemovable(link) }

        if current.writable {
            do {
                guard isRemovable(link) else { throw CLIInstallerError.notRemovable(link) }
                try fileManager.removeItem(atPath: link)
            } catch let error as CLIInstallerError {
                throw error
            } catch {
                throw CLIInstallerError.failed(error.localizedDescription)
            }
        } else {
            let script = try Self.removeScript(link: link)
            try runAsAdministrator(script, "FortiBar wants to remove the fortibar command from \((link as NSString).deletingLastPathComponent).")
        }
    }

    // MARK: - File system helpers

    private func linkPath(in directory: String) -> String {
        (directory as NSString).appendingPathComponent(Self.linkName)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// lstat: true for dangling symlinks too.
    private func entryExists(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)) != nil
    }

    /// The link's target made absolute, or nil if `path` is not a symlink.
    private func symlinkTarget(_ path: String) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return nil }
        if destination.hasPrefix("/") { return destination }
        let directory = (path as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: directory).appendingPathComponent(destination).standardizedFileURL.path
    }
}
