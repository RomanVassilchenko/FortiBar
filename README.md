# FortiBar
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License: GPL v3](https://img.shields.io/badge/license-GPLv3-green)

> **FortiBar** is a macOS menu bar FortiVPN client for several simultaneous tunnels (via [openfortivpn](https://github.com/adrienverge/openfortivpn)), with auto-reconnect and a CLI.
>
> It is inspired by and forked from [OpenFortiMac](https://github.com/rempairamore/OpenFortiMac) by [@rempairamore](https://github.com/rempairamore), and is released under the same GPL-3.0 license. Many thanks to the original author. This project is not affiliated with Fortinet.
>
> See [Attribution](#attribution) and [Upgrading from OpenFortiMac](#upgrading-from-openfortimac).


---

A native macOS menu bar app for managing [openfortivpn](https://github.com/adrienverge/openfortivpn) connections. Built with Swift and SwiftUI, it sits in your menu bar and lets you connect/disconnect with a single click, with several simultaneous tunnels, auto-reconnect and a command line tool.

Passwords are stored in the macOS Keychain.

<img src="docs/assets/fortibar-panel-demo.gif" width="356" alt="Click the FortiBar menu bar icon, then Connect on a server: the panel shows Connecting and then Connected with the tunnel IP">


## Installation

### Build yourself

FortiBar has no prebuilt releases yet. To build from source (Xcode 26 or later required):

```bash
brew install openfortivpn
git clone https://github.com/RomanVassilchenko/FortiBar.git
cd FortiBar
chmod +x build_dmg.sh
./build_dmg.sh
```

This produces `FortiBar_vX.Y.Z.dmg`: open it and drag **FortiBar** to your Applications folder.

Without the `FortiBar Self-Signed` certificate in your keychain the app is signed ad hoc, and macOS asks for Keychain access again after every rebuild. Create a self-signed code signing certificate with that name (Keychain Access → Certificate Assistant) to keep the app's identity stable across updates.

### First launch

FortiBar is not notarized by Apple, so macOS blocks it the first time. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the FortiBar message. This is needed only once.

### Allow openfortivpn to run as root

openfortivpn needs root privileges to create the VPN tunnel. On first launch FortiBar opens **Settings → Permission**: click **Set Up…** and enter your administrator password once.

The app installs this rule in `/etc/sudoers.d/fortibar` (validated with `visudo`, owned by root, read-only):

```
YOUR_USERNAME ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

Click **Remove** in the same place to delete it.

> **Security note:** with this rule any process running as your user can start openfortivpn as root without a password, and `/opt/homebrew` is writable by your user. This is the usual trade-off for openfortivpn GUIs; remove the rule if you stop using the app.

<details>
<summary>Manual setup</summary>

```bash
sudo visudo -f /etc/sudoers.d/fortibar
```

Add this line (replace `YOUR_USERNAME` with your macOS username):

```
YOUR_USERNAME ALL = (root) NOPASSWD: /opt/homebrew/bin/openfortivpn
```

The path is `/opt/homebrew/bin/openfortivpn` on Apple Silicon and `/usr/local/bin/openfortivpn` on Intel Macs. Run `which openfortivpn` to check.
</details>

### Configure

A lock icon appears in the menu bar. Click it → **Settings** → **Servers** tab → add your VPN servers.

## Usage

Click the menu bar icon to open the panel:

- **Status card** — the current server, connection time and tunnel IP, with **Disconnect** (⌘D)
- **Servers** — hover a server and click **Connect**; a server without a saved password opens its editor
- **Footer** — add a server, Settings (⌘,), Log, Quit (⌘Q)

If the administrator permission is missing, a banner in the panel links to **Settings → Permission**. Right-click the menu bar icon for a quick menu with Disconnect, Settings and Quit.

Each server can have its own icon, chosen in the server editor.

| Icon | Status |
|------|--------|
| 🔓 | Disconnected |
| 🔄 | Connecting / Disconnecting |
| 🔒 (green) | Connected |

**Settings → General → Menu bar icon → Monochrome** switches to a template shield that follows the menu bar appearance and shows how many tunnels are up:

| Icon | Status |
|------|--------|
| Outlined shield | Disconnected |
| Half-filled shield | Connecting |
| Shield with checkmark | One tunnel connected |
| Filled shield with a number | That many tunnels connected |
| Small dot next to it | Another tunnel is connecting |

### Multiple connections

Turn on **Settings → General → Allow multiple connections at once** to run several tunnels side by side, each with its own status card, log lines and Disconnect button. When it is off (the default), connecting to a server drops the current one.

Only one tunnel should own the default routes and DNS. For the others, open the server editor → **Advanced**:

- **Don't change routes or DNS** — runs openfortivpn with `--no-routes --no-dns`
- **Static routes** — CIDRs (one per line) routed through this tunnel's own ppp interface while it is up; the interface is detected after connecting, since ppp numbering is dynamic. Needs the sudo rule to allow `/sbin/route` for ppp interfaces: the panel shows an **Update** banner when it is missing.
- **Connect at launch** — connect automatically when FortiBar starts
- **Reconnect automatically** — when the tunnel drops (network change, sleep, gateway timeout), reconnect after 2, 5, 10, 20, 30, then every 60 seconds until you disconnect. While offline it waits for the network and retries as soon as it is back. Wrong credentials or certificate stop the retries.

Quitting FortiBar (menu, ⌘Q, `brew uninstall`, logout or `SIGTERM`) disconnects every tunnel first, so openfortivpn restores routes and DNS.

### Command line

The app executable doubles as a command line tool. Link it into your `PATH`:

```bash
ln -s /Applications/FortiBar.app/Contents/MacOS/FortiBar /opt/homebrew/bin/fortibar
```

```bash
fortibar list                     # servers and their state
fortibar status [--json]          # active tunnels: time, IP, ppp interface, routes
fortibar connect office           # name, unique prefix or id; waits until up
fortibar disconnect office        # or: disconnect --all
fortibar logs -f                  # openfortivpn output (~/Library/Logs/FortiBar)

fortibar add "Branch" --host vpn.example.com --port 10443 --user me --password \
    --no-routes-dns --route 10.20.30.0/24
fortibar edit branch --add-route 10.40.0.0/16 --auto-connect --auto-reconnect
fortibar show branch
fortibar remove branch --yes      # also deletes the saved password
fortibar settings --allow-multiple on --menu-bar-icon monochrome
fortibar permission update        # sudo rule incl. static routes (admin dialog)
```

Connect and disconnect run through the app (started in the background if needed), which owns the tunnels, the Keychain and the sudo rule. Passwords are read with `--password` (prompt) or `--password-stdin`, never from arguments.

The app sends native macOS notifications on connect, disconnect, and errors.

## Configuration

Server profiles are stored at `~/Library/Application Support/FortiBar/config.json`. You can edit them through the Settings GUI or manually:

```json
{
    "servers": [
        {
            "id": "office-1",
            "name": "Office VPN",
            "host": "vpn.company.com",
            "port": 443,
            "username": "john.doe"
        }
    ],
    "openfortivpn_path": "/opt/homebrew/bin/openfortivpn"
}
```

Optional fields, written only when used:

| Field | Where | Meaning |
|-------|-------|---------|
| `allow_multiple_connections` | top level | Run several tunnels at once (default `false`) |
| `menu_bar_icon` | top level | `classic` (default) or `monochrome` |
| `no_routes_dns` | server | Pass `--no-routes --no-dns` (default `false`) |
| `static_routes` | server | CIDRs routed through the tunnel's ppp interface, e.g. `["10.20.30.0/24"]` |
| `auto_connect` | server | Connect when FortiBar starts (default `false`) |
| `auto_reconnect` | server | Reconnect when the tunnel drops (default `false`) |

Passwords are **not** stored in this file — they live in the macOS Keychain.

The `trusted_cert` field is optional. If omitted, the app uses `--trusted-cert=any`.

## Troubleshooting

**"openfortivpn not found"** — Check the binary path in Settings → General. Run `which openfortivpn` to find yours.

**"Administrator permission not set up"** — The sudo rule is missing or points to another openfortivpn path. Open Settings → Permission and click **Set Up…** (or **Update…**).

**"FortiBar is damaged" / "cannot be opened"** — See [First launch](#first-launch).

**Connection fails** — Open Settings → Log tab for details. 

## Uninstall

1. Settings → Permission → **Remove**
2. Quit FortiBar
3. Delete from Applications: `rm -rf /Applications/FortiBar.app`
4. Remove config: `rm -rf ~/Library/Application\ Support/FortiBar ~/Library/Logs/FortiBar`
5. Remove the saved passwords (Keychain Access, service `com.romanvassilchenko.FortiBar.vpn`)

If you followed the manual setup of older versions, also run `sudo rm /etc/sudoers.d/openfortivpn`.

## Upgrading from FortiBar

FortiBar is the new name of FortiBar with a new bundle identifier, so it is a separate app. Quit FortiBar, then start FortiBar once and it migrates your data automatically:

- **Servers and settings** move from `~/Library/Application Support/FortiBar` to `~/Library/Application Support/FortiBar`, and the log to `~/Library/Logs/FortiBar`.
- **Passwords** are copied from the old Keychain service into the new one and then deleted from the old one. macOS may ask whether FortiBar can use the old items: choose **Always Allow**. If you decline, the migration is retried on the next launch.
- **The sudo rule** `/etc/sudoers.d/fortibar` keeps working until you open **Settings → Permission** and click **Update…**: one administrator prompt installs `/etc/sudoers.d/fortibar` and removes the old rule.
- **Launch at login** is tied to the app identity: remove FortiBar from System Settings → General → Login Items and turn it on again in FortiBar's Settings.
- The CLI is now `fortibar` (it was `fortibar`): update symlinks and scripts.

Then delete `/Applications/FortiBar.app`.

## Releasing

Releases are currently built by hand with `./build_dmg.sh`. The GitHub Actions release workflow is kept disabled as [`.github/workflows/release.yml.disabled`](.github/workflows/release.yml.disabled): it needs signing secrets and a Homebrew tap that do not exist yet (see the comments at the top of the file). To enable it, set those up and rename the file to `release.yml`.

Version bumps go in `MARKETING_VERSION` in Xcode plus a `## vX.Y.Z` section in `CHANGELOG.md`.

The demo GIF at the top of this README is generated with `python3 scripts/make_panel_demo.py` (macOS and ffmpeg required) from example data.

## Attribution

FortiBar is a fork of [OpenFortiMac](https://github.com/rempairamore/OpenFortiMac) by [@rempairamore](https://github.com/rempairamore), forked from the project at the commit "Start FortiBar: standalone project forked from OpenFortiMac". The original work is copyright its author and licensed under the GNU General Public License v3.0; this project is distributed under the same license (see [LICENSE](LICENSE)), and all original copyright and license notices are retained. FortiBar wraps [openfortivpn](https://github.com/adrienverge/openfortivpn) by Adrien Vergé. FortiBar is not affiliated with Fortinet.

