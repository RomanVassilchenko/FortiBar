# Changelog

## v1.8.1

### Changed
- All server passwords are kept in **one** Keychain item instead of one per server. macOS grants Keychain access per item and, for an app without an Apple Team ID, per build, so every update asked once for each server; now it asks once. Existing passwords are moved on the first launch (macOS may ask one last time) and the old items are deleted
- The Keychain is read off the main thread, so a pending access prompt no longer freezes the app at launch

### Fixed
- The health check pings the DNS servers of the tunnel when the far end of the link does not answer ping (many gateways, including FortiGate, ignore it), so it works without setting a health check host

## v1.8.0

### Added
- **Tunnel health check**: connected tunnels are pinged through their own interface every 20 seconds. The panel shows the latency, and a tunnel that stops answering is restarted when automatic reconnect is on (otherwise you get a notification). A host that never answers switches the check off for that connection instead of restarting a good tunnel. Optional **Health check host** per server, **Settings → General → Check tunnel health** to turn it off, `fortibar edit --health-host` and `fortibar settings --health-check`
- **Sleep and network changes**: on wake-up and when the network changes, tunnels are checked within seconds and a dead one is replaced without waiting for openfortivpn to notice; a tunnel waiting out a long reconnect delay retries right away on wake-up
- **Statistics**: the panel shows traffic and its current speed per tunnel; the new **Settings → Statistics** tab shows seven days of connected time, interruptions and traffic per server, kept in `stats.json` for 90 days

## v1.7.0

### Added
- **Settings → General → Command Line Tool**: install or remove the `fortibar` command from the UI, no terminal needed (links into `/opt/homebrew/bin` or `/usr/local/bin`; Homebrew installs already have it)
- `fortibar permission status` is listed in the help

### Changed
- New app icon and menu bar icon: a white **F** with a green "connected" dot. The menu bar icon shows the state with its dot: an empty ring when disconnected, half-filled while connecting, filled for one tunnel and a count badge for several
- New social preview card and README header; the website uses the new icon

### Fixed
- The upgrade notes no longer claim that the original OpenFortiMac had a command line tool or log files, and the 1.4.0 notes no longer say the CLI was renamed

### Internal
- Removed the log file migration (OpenFortiMac never wrote log files), unused code and duplicated helpers; Dependabot keeps the pinned GitHub Actions up to date

## v1.6.0

### Security
- Line breaks and control characters in a server's host, user, password or certificate are rejected (app, settings editor and CLI): they could add options to the config that openfortivpn reads as root
- The CLI talks to the app over a private Unix socket (owner-only, peer uid checked) instead of distributed notifications, which any process in the login session could post
- The temporary config with the password is created with owner-only permissions or the connection fails; the server editor no longer loads the saved password into its field

### Added
- A tunnel that ignores SIGTERM is now force-stopped (SIGKILL of openfortivpn and pppd) through a narrow sudoers rule. Existing installs show **Update…** in Settings → Permission (or run `fortibar permission update`)

### Fixed
- Lost trust-on-first-use certificate digests and failure messages when openfortivpn's output arrived in pieces or the process exited quickly
- Disconnect no longer triggers a reconnect; a memory leak per connection is gone
- Auto-connect skips servers without a saved password and takes the next one in single-connection mode
- Config: atomic writes, an unreadable file is kept as `config.json.invalid` instead of being replaced, no races between app and CLI; servers without an `id` keep a stable one
- A certificate pinned while the server editor is open survives saving it; a legacy plaintext password moves to the Keychain
- Settings no longer rewrite the config or re-register launch at login on open; the log Clear button stays cleared
- CLI: unknown flags, bad `--timeout` / `-n` values and extra arguments are errors; saves are verified; `remove` no longer loses the Keychain password when saving fails
- A second app instance waits for the first (for example during a Homebrew upgrade) instead of fighting over tunnels

### Changed
- `fortibar status --json` exits 3 when the app is not running, like `status`

## v1.5.1

### Added
- Homebrew install: `brew trust romanvassilchenko/tap && brew install --cask romanvassilchenko/tap/fortibar`. The cask installs openfortivpn, links the `fortibar` command, and is updated automatically with every release. `brew uninstall --zap` also removes the sudo rule, settings and logs; upgrades keep them

## v1.5.0

### Changed
- The menu bar icon is always the template shield that follows the menu bar appearance and shows the number of connected tunnels. The Classic lock style, its setting and `fortibar settings --menu-bar-icon` are gone (an old `menu_bar_icon` key in config.json is ignored)
- Cleaner interface: consistent spacing, plain list rows in Settings, native sheet buttons, clearer empty states, shorter labels; the config path is shown with `~`
- Redrawn app icon, new website and a shorter README

## v1.4.0

### Added
- The gateway certificate is trusted on the first connection: when it cannot be verified, its digest is pinned in the server profile and the connection retried. A pinned certificate that changes is a certificate error. (Before, the `--trusted-cert=any` fallback made such servers fail until the digest was pasted by hand)
- Multiple simultaneous connections (Settings → General, off by default): one openfortivpn process, status card, log and Disconnect per server
- Per-server options: "Don't change routes or DNS" (`--no-routes --no-dns`), static routes through the tunnel's ppp interface, connect at launch
- Per-server auto-reconnect: retries with backoff when a tunnel drops, waits for the network while offline, stops on authentication or certificate errors
- Sudo rule can also allow `/sbin/route` for ppp interfaces, only when a server uses static routes
- `fortibar` command line tool (the app executable): list, status, connect, disconnect, logs, add, edit, remove, show, settings, permission
- Log file at `~/Library/Logs/FortiBar/fortibar.log`
- Right-click menu: connect any idle server
- Optional monochrome menu bar icon (Settings → General → Menu bar icon): a template shield that shows the number of connected tunnels; the classic lock stays the default

### Changed
- Minimal macOS-style interface: a flat menu bar panel on the system's Liquid Glass popover (glass status puck and buttons on macOS 26, a material before), toolbar-style tabs in Settings, a new app icon
- The project is now **FortiBar**, a fork of OpenFortiMac by rempairamore (GPL-3.0). New bundle identifier `com.romanvassilchenko.FortiBar`, new sudo rule `/etc/sudoers.d/fortibar`, new Keychain service, config in `~/Library/Application Support/FortiBar`
- First launch migrates data from OpenFortiMac: servers and settings, and Keychain passwords (copied, then deleted from the old service; macOS may ask for access once: choose **Always Allow**). **Settings → Permission → Update…** replaces the old sudo rule with the new one. Launch at login must be turned on again in FortiBar
- Releases are signed with FortiBar's own self-signed certificate ("FortiBar Self-Signed"); the Homebrew tap of the original project does not apply to FortiBar
- Quitting disconnects all tunnels first, whatever the way of quitting (menu, `brew uninstall`, logout, SIGTERM)
- The temporary openfortivpn config (with the password) is deleted as soon as the tunnel is up

### Fixed
- ⌘, opened an empty settings window
- Permission check: `sudo -l` also lists commands that still need a password for administrators; the check now runs `openfortivpn --version` through `sudo -n`

## v1.3.2

### Changed
- Releases are signed with a stable self-signed certificate ("OpenFortiMac Self-Signed"), so macOS keeps the app's Keychain access across updates instead of asking again after each one. Updating to 1.3.2 asks one last time: choose **Always Allow**.

## v1.3.1

### Added
- Releases are built by GitHub Actions with signed build provenance (`gh attestation verify`) and a VirusTotal report

### Fixed
- Universal binary: the app now runs on Intel Macs too (1.3.0 was Apple Silicon only)

## v1.3.0

### Added
- New menu bar panel: status card with connection time, tunnel IP and Disconnect, server list with Connect on hover, quick actions footer
- Right-click on the menu bar icon opens a quick menu (Disconnect, Settings, Quit)
- Server icons, chosen in the server editor
- Homebrew install: `brew install --cask rempairamore/tap/openfortimac`
- Settings → Permission: set up, update or remove the openfortivpn sudo rule with one password prompt
- Panel banner when the sudo rule or openfortivpn is missing
- First launch opens the permission setup when needed

### Changed
- Servers in Settings are shown as cards with icon, address and a missing-password badge
- A server without a saved password opens its editor instead of an alert
- `build_dmg.sh` names the DMG after the version and prints the values for the Homebrew cask
- Connecting without a sudo rule now fails immediately with a clear message

### Fixed
- Disconnect no longer runs `sudo kill` / `sudo pkill`, which the sudo rule never allowed; openfortivpn is stopped through its sudo parent

## v1.2.0

### Added
- Colored status dot in the menu bar (green when connected, orange when connecting)
- Server names are greyed out in the menu bar while connected
- Double-click a server profile to edit it
- Trash icon on each server row with delete confirmation dialog

### Fixed
- Server list now refreshes immediately after editing or adding a profile

## v1.1.0

- Initial release
- Native macOS menu bar app for OpenFortiVPN
- Multiple VPN server profiles with Keychain password storage
- JSON configuration with GUI editor
- Connection log viewer
- Native macOS notifications
- Launch at Login support
- App icon