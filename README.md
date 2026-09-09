<p align="center">
  <img src="assets/icon.svg" alt="VPN NetGuard icon" width="140">
</p>

<h1 align="center">VPN NetGuard</h1>

<p align="center">
  Kill switch, automatic reconnection, and network privacy for your VPN on Linux.<br>
  One single script: graphical panel, terminal menu, or headless systemd service — your choice.
</p>

<p align="center">
  <img alt="Bash 4+" src="https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Linux Mint 22.3 Cinnamon" src="https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white">
  <img alt="Debian/Ubuntu Server headless" src="https://img.shields.io/badge/Debian%2FUbuntu-Server%20headless-A81D33?logo=debian&logoColor=white">
  <a href="LICENSE"><img alt="GPLv3 License" src="https://img.shields.io/badge/license-GPLv3-blue"></a>
  <img alt="Version 1.0.0" src="https://img.shields.io/badge/version-1.0.0-informational">
</p>

<p align="center">
  <a href="README.es.md">Español</a> · <b>English</b>
</p>

---

## Table of Contents

- [What is VPN NetGuard?](#what-is-vpn-netguard)
- [Getting started](#getting-started)
- [The problem it solves](#the-problem-it-solves)
- [What it actually does](#what-it-actually-does)
- [Installation](#installation)
- [Commands](#commands)
- [Daily use](#daily-use)
- [Configuration](#configuration)
- [Compatibility](#compatibility)
- [Scriptya](#scriptya)
- [About the language](#about-the-language)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## What is VPN NetGuard?

VPN NetGuard is a **privacy tool** for Linux. If you use a VPN so your Internet provider, the Wi-Fi network you're on, or the sites you visit can't see what you're doing or your real location, VPN NetGuard makes sure that protection doesn't quietly fail on you.

Specifically, it protects you from two things:

- **Your VPN failing silently.** If the connection drops, the computer reboots, or the tunnel stops working without warning, your "real" (unprotected) traffic normally starts going out to the Internet without you noticing, exposing your IP and your activity. VPN NetGuard blocks all traffic the moment it detects the VPN isn't working, and won't let anything through again until it's back up — even during the computer's own boot process.
- **Being identified even while the VPN is working fine.** Beyond your traffic, your computer introduces itself to any Wi-Fi network (the one at the bar, the airport, or the office) using things like its MAC address or hostname. That lets networks recognize you and track you from one place to another, even with the VPN active. VPN NetGuard can hide and change that information automatically.

And this doesn't depend on the VPN itself being the problem: if it's your Internet connection that's unstable — flaky Wi-Fi, a router that hiccups — VPN NetGuard handles it just as well. As soon as there's a signal again, it reconnects the VPN right away on its own, so you're protected and back online as fast as possible, with nothing for you to do.

In short: if your VPN is the lock, VPN NetGuard is what keeps checking that the door is actually shut — and it also helps you avoid leaving footprints along the way.

And it doesn't have to be your desktop computer: it works just the same on a headless server you only reach over SSH — a VPS, a NAS, a headless Raspberry Pi... It's the same script either way: it detects on its own where it's running and adapts, without you having to specify anything.

## Getting started

If you just want to try it out, this is all you need:

1. **Download the script:**

   ```bash
   git clone https://github.com/filonux/VPN-NetGuard.git
   cd VPN-NetGuard/script
   ```

2. **Install it.** On a desktop (Linux Mint, for example):

   ```bash
   pkexec bash vpn-netguard.sh install
   ```

   On a headless server, over SSH:

   ```bash
   sudo bash vpn-netguard.sh install
   ```

   A wizard (graphical or text-based, depending on the case) asks you a couple of simple yes/no questions, and that's it — it's installed.

3. **Use it day to day** without ever touching the terminal again: look for "VPN NetGuard" in the Applications menu (or double-click the Desktop icon, if you chose that option during install). A window opens with a list of actions grouped by category; the ones you'll use almost every time are right at the top — "View current status", "Enable VPN protection", and "Disable VPN protection" — and if it's your first time, "1-click set & forget" gets everything configured and connected in a single step. Double-click the option you want, and as soon as it finishes, the same window comes back for the next one, with nothing to memorize.

   If you'd rather manage it from a terminal (over SSH on a headless server, for example), there's the same kind of menu in text mode: just run `vpn-netguard.sh` on its own and pick each option with the keyboard — no commands to remember there either.

Need more detail — unattended install flags, how to uninstall, the full list of commands...? Keep reading: the sections below cover everything else, starting with the reasoning behind each design decision.

## The problem it solves

Most "VPN kill switches" floating around forums are two or three `iptables` rules applied by hand, once. They work as long as nothing changes — but if the VPN drops in the middle of the night, your laptop reboots, or the tunnel goes "zombie" (the interface stays up but the remote server no longer responds), those rules never notice, and your real traffic goes out to the Internet unprotected, without you ever knowing.

VPN NetGuard is a daemon that continuously watches the connection, not a loose rule. The difference shows up exactly where a homemade kill switch fails: the system's own boot process (even before the network exists), a zombie tunnel a simple ping wouldn't catch, or the moments when nobody's watching. Separately, it adds a network privacy module so that, even when the VPN is working perfectly, the router at the bar, the airport, or the office can't recognize you by your MAC address, your IPv6, or your hostname — something no kill switch alone covers. How it pulls each of these off is in the next section.

## What it actually does

VPN NetGuard brings together in a single file what used to be seven (the watcher, the panel, the installer, the configuration, two systemd units, and the desktop launcher). Here's what it does:

### A real kill switch (fail-closed)

- Blocks all outbound traffic that doesn't go through the VPN tunnel, using `iptables` and `ip6tables` rules applied atomically: there's never a moment where the chain is left half-built or empty.
- A second systemd service, independent of the main one, shuts down traffic *before* the network is even configured at boot — the leak window almost no other script covers.
- Explicitly allows only the bare minimum needed to work: DNS (only to the servers you define, not to just anyone), the traffic needed to establish the tunnel itself, your LAN traffic if you enable it, and ping to whatever targets you use to check for real Internet access.
- Three modes, depending on what you need: `auto` (blocking only kicks in when you activate the VPN), `true` (permanent blocking while the service runs), or `false` (just watches and reconnects, without blocking anything).

### Monitoring and automatic reconnection

- Reacts instantly to NetworkManager events (`nmcli monitor`), and also runs a backup check every few seconds in case anything slips through.
- Retries the VPN connection with progressive backoff, so it doesn't hammer a server that's been down for a while.
- With WireGuard, it doesn't just trust that the interface stays "up": it measures the age of the last handshake to catch a zombie tunnel that a simple ping wouldn't reveal.
- Relies on systemd's watchdog: if something hangs (an `nmcli` or `iptables` call that never returns), systemd restarts the service on its own, with no need for you to step in.

### Network privacy (independent of the VPN)

- Randomized MAC per network: the same MAC every time you return to a known network, or a different one on every connection, your choice — with the option to make the reported vendor look real instead of "obviously random."
- Also randomizes the MAC used when scanning for Wi-Fi networks, even before you connect to any of them.
- Hides your hostname from the router's DHCP and fixes a little-known leak (the DHCP client identifier, the DUID, and the IAID) that can still give you away even after the MAC changes.
- Private, temporary IPv6 addresses, or the option to disable IPv6 entirely if you'd rather minimize your footprint as much as possible.
- Can silence your hostname broadcast over mDNS/Avahi and NetBIOS, and force Firefox, Chrome, and Chromium to stop resolving DNS on their own (DNS-over-HTTPS), so they respect your DNS settings and the kill switch itself.

### Alerts, history, and monitoring

- Desktop notifications when the state actually changes, not on every periodic check.
- An alert "hook" (`ALERT_HOOK`) for headless servers: plug in a webhook, an email, or whatever you need there.
- Event history in CSV, meant to be imported into a spreadsheet or used to chart uptime over time.
- Metrics for Prometheus (node_exporter's textfile collector format) and a `check` subcommand with an exit code, ready for cron, Nagios, or Zabbix.

### Three ways to manage it

- Graphical panel (zenity) for everyday desktop use.
- Interactive terminal menu, which needs neither zenity nor the program already installed — designed for use over SSH.
- Direct subcommands for automation, debugging, or integration into your own scripts.

## Installation

The installer only detects whether you have a graphical session and picks the right wizard — nothing to specify. It uses the same commands from [Getting started](#getting-started) (`pkexec bash vpn-netguard.sh install` on desktop, `sudo bash vpn-netguard.sh install` over SSH); here's what each wizard asks:

- **With a graphical session (zenity):** autostart at boot, starting the service right away, an entry in the Applications menu — and, if so, a Desktop icon too — and whether to apply network privacy now.
- **Over SSH, text mode:** the same questions except the Desktop icon one, which doesn't apply without a graphical session.

The network privacy question always comes up; if the installer detects you're connected over SSH, it shows a stronger warning first, since changing your MAC could cut your own connection if your provider filters by it.

**Unattended install (Ansible, cloud-init, Dockerfile...):** `install` also accepts flags — or the `VPN_NETGUARD_INSTALL_*` environment variables — that skip the interactive yes/no questions:

```bash
sudo bash vpn-netguard.sh install --yes
sudo bash vpn-netguard.sh install --autostart --start-now --no-privacy
```

`--yes`/`-y` sets autostart, immediate start, and the Applications menu entry to "yes" and network privacy to "no" (unless a specific flag says otherwise) — the same privacy caution described above for remote servers. Individual flags: `--[no-]autostart`, `--[no-]start-now`, `--[no-]privacy`, `--[no-]menu-entry`. With none of these, install stays interactive as always, and it has no effect on the graphical (zenity) installer.

VPN NetGuard needs NetworkManager (`nmcli`) in either case. If your server uses netplan with the plain `networkd` renderer, install it first:

```bash
sudo apt install network-manager
sudo systemctl enable --now NetworkManager
```

If any other dependency is missing (`iptables`, `ping`...), the script itself tells you exactly what's missing and which `apt` package installs it — no guessing required.

Once installed, forget about `pkexec`/`sudo` for everyday use: look for "VPN NetGuard" in the Applications menu, or just run `vpn-netguard.sh` with no arguments for the terminal menu. Every action that needs privileges asks for them separately, so you never need to deliberately open a terminal as root.

**Uninstalling:**

```bash
sudo bash vpn-netguard.sh uninstall
```

or option 19 in the interactive menu. `/etc/vpn-netguard/vpn-netguard.conf` is kept in case you reinstall later; remove it by hand (`sudo rm -rf /etc/vpn-netguard /var/lib/vpn-netguard`) if you no longer need it.

**Optional alternative way to launch it:** if you organize your scripts with [Scriptya](#scriptya), by the same author, you can add `vpn-netguard.sh` to its menu and stop worrying about remembering the path either — explained further down.

## Commands

| Command | What it does |
|---|---|
| *(no arguments)* / `menu` | Opens the interactive terminal menu |
| `install` | Installs VPN NetGuard on the system |
| `uninstall` | Uninstalls VPN NetGuard from the system |
| `panel` | Opens the graphical control panel (zenity) |
| `status` | Shows the current status: interfaces, VPN, kill switch, DNS, privacy... |
| `check` | Health check with an exit code, designed for cron/Nagios/Zabbix |
| `doctor` | Combined diagnostics: dependencies, network, firewall, and kill switch |
| `activate` | Marks that you want the VPN active, connects, and enables protection |
| `deactivate` | Marks that you don't want it active and removes the block |
| `enable-killswitch` | Forces the block right now |
| `disable-killswitch` | Removes the block without changing whether you want the VPN active |
| `apply-privacy` | (Re)applies the network privacy module (MAC, IPv6, hostname...) |
| `privacy-status` | Shows the current status of network privacy |
| `export-config` | Exports `vpn-netguard.conf` for backup |
| `import-config` | Imports a previously exported `vpn-netguard.conf` |
| `sync-localized` | Rewrites the already-installed systemd units/`.desktop` launcher in the current language |
| `rotate-mac` | Immediately regenerates the "stable" MAC (used by the optional timer) |
| `start` | Starts the watcher in the foreground (used by systemd, no need to run by hand) |
| `boot-killswitch` | Early blocking before the network exists (used by systemd) |
| `version` / `--version` / `-v` | Shows the installed version |
| `-h` / `--help` | Shows this same help text |

Almost all of them require root privileges: use `sudo`, `pkexec`, or leave it to the systemd service, which already invokes itself correctly. The exceptions are the interactive menu and the graphical panel, which ask for privileges action by action as you need them; `version`, which doesn't need them at all; and `export-config`, which only reads the config file.

## Daily use

Everyday use doesn't need a terminal, but if you do use one:

```bash
vpn-netguard.sh status      # what's connected, whether the kill switch is active, real DNS...
vpn-netguard.sh activate    # connects the VPN and enables protection
vpn-netguard.sh deactivate  # disconnects and removes the block
vpn-netguard.sh panel       # the same graphical panel, without hunting for it in the Applications menu
```

The difference between `activate`/`deactivate` and `enable-killswitch`/`disable-killswitch` is the first thing almost everyone asks:

| Action | What it changes | When to use it |
|---|---|---|
| `activate` / `deactivate` | Marks whether you **want** the VPN active or not, and adjusts the connection and the block accordingly | Normal, everyday use |
| `enable-killswitch` / `disable-killswitch` | Forces or removes the block **without** changing whether you want the VPN active | One-off debugging, or testing the block without disconnecting anything |

For unattended monitoring, for example on a server:

```bash
vpn-netguard.sh check
```

Returns a one-line summary and an exit code (`0` = OK, `1` = warning, `2` = critical); if you set `PROMETHEUS_TEXTFILE_DIR`, it also drops metrics ready for node_exporter in that same call.

And to see what the service is doing in real time:

```bash
journalctl -u vpn-netguard.service -f
```

## Configuration

All the configuration lives in a single file, commented line by line:

```
/etc/vpn-netguard/vpn-netguard.conf
```

It's generated with sensible defaults on install, and isn't overwritten on later installs. Some of the most relevant keys:

```bash
LANGUAGE="es"                    # es | en — language for menus, panel, and messages
KILLSWITCH_MODE="auto"          # auto | true | false
DNS_SERVERS="1.1.1.1 9.9.9.9"   # which DNS servers are allowed out while the kill switch is blocking
MAC_MODE="stable"                # stable | random | off
IPV6_PRIVACY="true"
PROMETHEUS_TEXTFILE_DIR=""       # empty = disabled
ALERT_HOOK=""                    # your script or webhook, for headless servers
```

You can edit it by hand, from the interactive menu (options 8, 9, and 12), or the graphical panel ("Configuration", "Network privacy", and "Monitoring"). After changing it, restart the service to apply it:

```bash
sudo systemctl restart vpn-netguard.service
```

## Compatibility

- **Primary target:** Linux Mint 22.3 (Cinnamon), with a graphical panel and a shortcut in the Applications menu.
- **Also as a headless service:** any Debian/Ubuntu server with NetworkManager, no graphical environment or zenity needed — installs and works the same way over SSH, swapping `pkexec` for `sudo`.
- **Requirements:** Bash 4+, NetworkManager (`nmcli`), `iptables`, `systemd`. Everything else (coreutils, `ping`, `flock`...) is usually already part of the base system.

Optional — none of this is required, but it improves the experience:

| Package | What for |
|---|---|
| `ip6tables` | Kill switch on IPv6 too (highly recommended) |
| `zenity` | Graphical panel and installer with windows |
| `wireguard-tools` (`wg`) | Zombie tunnel detection on WireGuard connections |
| `libnotify-bin` (`notify-send`) | Desktop notifications |
| `policykit-1` (`pkexec`) | Elevating privileges without a terminal, from the panel/menu |

Should work unmodified on any Ubuntu/Debian derivative with NetworkManager, though for now it's only been verified on Linux Mint 22.3 Cinnamon and on a headless Ubuntu/Debian server. Plays nicely with `ufw` (it uses its own, independent `iptables` chain).

## Scriptya

VPN NetGuard doesn't need anything else to work. If you keep several of your own scripts around, [Scriptya](https://github.com/filonux/Scriptya) — by the same author — is a menu that organizes them and can turn any of them into a standalone app with its own icon.

Dropping `vpn-netguard.sh` into your Scriptya scripts folder gets you a shortcut to launch it without having to remember the path. Keep in mind, though: Scriptya's "install" only creates that shortcut. Actually installing VPN NetGuard — the systemd services, the kill switch, the privacy module — is still done once with `vpn-netguard.sh install`, as described above.

## About the language

The interface is bilingual: the interactive menu, the graphical panel, the installation wizard, and the status messages are all available in Spanish and English. Spanish is the default (`LANGUAGE="es"`); to switch to English, edit `LANGUAGE="en"` in `/etc/vpn-netguard/vpn-netguard.conf` (or do it from the interface itself: option 7 in the menu, "Interface language" in the panel) and restart the service as in [Configuration](#configuration).

You can also force it for a single run, without touching the configuration, with the `VPN_NETGUARD_LANGUAGE` environment variable:

```bash
VPN_NETGUARD_LANGUAGE=en vpn-netguard.sh status
```

This README is also available in both languages — the link is right at the top, just below the badges.

**Mini roadmap**, depending on real interest:

- [x] Bilingual interface (Spanish/English): menu, panel, and installation wizard
- [x] Bilingual README (Spanish/English)
- [ ] A `.deb` package or dedicated `apt` repository, to install with `apt install` instead of cloning the repo

If you'd be interested, open an issue — that's the signal I need to prioritize it.

## Contributing

Issues and pull requests are welcome. Ready-made templates are available in `.github/` for reporting a bug or proposing an improvement, along with a full guide in [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Security

VPN NetGuard runs as root and modifies firewall rules. If you find a security issue, please report it following the process in [SECURITY.md](.github/SECURITY.md) instead of opening a public issue.

## License

Free software under the GNU General Public License version 3 (GPLv3). See the [LICENSE](LICENSE) file for the full text.

---

<p align="center">Made by <strong><a href="https://github.com/filonux">Filonux</a></strong>.</p>
