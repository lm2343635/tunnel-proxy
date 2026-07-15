# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The **main** project is a native SwiftUI **menu bar** macOS app (`TunnelProxy`) that
sets up an SSH SOCKS5 tunnel, converts it to an HTTP proxy via a **bundled** Privoxy,
and toggles the macOS system proxy. It is fully self-contained — the tunnel logic is
native Swift and Privoxy ships inside the `.app`, so it needs no external scripts or
Homebrew at runtime.

An older, standalone **bash CLI** lives in [cli/](cli/) (`proxy start|stop|…`). The
two do not share configuration.

Pipeline: **`ssh -N -D` (SOCKS5 on :1080)** → **Privoxy (HTTP on :8118)** → app env / system proxy.

## Layout

- `TunnelProxy.xcodeproj` — Xcode project (open from the repo root)
- `TunnelProxy/` — Swift sources
  - `Controllers/` — `TunnelEngine` (native ssh -D + bundled privoxy + watchdog + askpass),
    `TunnelController` (observable state, server CRUD, status polling), `AppPaths`,
    `ServerProfile`, `TunnelConfig`, `KeychainStore`, `NetworkServices`, `SpeedMonitor`,
    `MenuBarRenderer`, `ProcessRunner`, `LogTailer`
  - `Views/` — `MenuBarView`, `SettingsView`, `ServersView`, `LogsView`, `ManualView`
  - `Resources/` — bundled `privoxy/` (binary + relocated dylibs), `helpers/askpass.sh`,
    `manual/` (bundled user-guide HTML)
- `release.sh` — archive → export Developer ID app → build + sign a distributable DMG
- `ExportOptions.plist` — `xcodebuild -exportArchive` options
- `icon/` — app icon master + generator
- `plan/` — design docs + mockups
- `cli/` — standalone bash CLI (see below)

## App architecture

- **Not sandboxed** (`TunnelProxy.entitlements`): the app spawns `ssh`, the bundled
  `privoxy`, and `networksetup`. The macOS SOCKS proxy toggle needs admin rights, so
  the app prompts via `osascript`.
- **Self-contained runtime**: `ssh` and `curl` ship with macOS; Privoxy is bundled at
  `TunnelProxy.app/Contents/Resources/privoxy/` with its `libpcre2-*` dylibs relocated
  to `@loader_path`. A build phase ("Sign bundled privoxy") re-signs the binary + dylibs
  with the app's identity for the hardened runtime.
- **Secrets** (SSH passwords / key passphrases) live in the **macOS Keychain** (service
  `com.monstarlab.tunnelproxy`, keyed by profile UUID) — never in `config.json`. For
  password/passphrase auth, ssh's secret is passed via `SSH_ASKPASS` (`askpass.sh`)
  through the `TP_ASKPASS_SECRET` env var, never on argv.
- **App data** lives in `~/Library/Application Support/TunnelProxy/`: `config.json`,
  `tunnel.log`, and a freshly-generated `privoxy.conf` on each connect.

### Build & run

```bash
xcodebuild -project TunnelProxy.xcodeproj -scheme TunnelProxy -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TunnelProxy-*/Build/Products/Debug/TunnelProxy.app
```

Or open `TunnelProxy.xcodeproj` in Xcode and press ⌘R (Xcode 15+, macOS 14+).

### Release

`./release.sh` produces a signed `build/TunnelProxy-<version>.dmg` (Developer ID, team
`X92HAV9XYP`). Notarization is opt-in via `NOTARY_PROFILE` (or `NOTARY_APPLE_ID` /
`NOTARY_TEAM_ID` / `NOTARY_PASSWORD`). See [README.md](README.md) for details.

## CLI (`cli/`)

Bash scripts — no build, test, or lint steps. See [cli/README.md](cli/README.md).

- `cli/proxy` — CLI entry point (`proxy start|stop|status|socks-on|socks-off|log`)
- `cli/start.sh` — creates SSH tunnel + restarts Privoxy + optional watchdog
- `cli/stop.sh` — kills tunnel + stops Privoxy + kills watchdog
- `cli/.env` — configuration (SSH host, ports, Privoxy config path). Gitignored.
- `cli/install.sh` / `cli/Makefile` — `make install` symlinks `proxy` to `/usr/local/bin`

### CLI gotchas

- `proxy start` **overwrites** `/opt/homebrew/etc/privoxy/config` on every run.
- `socks-on`/`socks-off` use `sudo networksetup` — requires the macOS admin password.
- Tunnels are killed via `pkill -f "ssh.*-D ..."`, which matches the host string — keep
  `SSH_HOST` unique.
- Watchdog PID is stored at `/tmp/ssh-tunnel-watchdog.pid`; a stale file means a zombie
  watchdog.
- Health checks use `api.ipify.org` (expects an IP) and `api.anthropic.com` (expects an
  auth error) — both must be reachable.

## Dependencies

- macOS app: Xcode 15+, macOS 14+ (Privoxy bundled; `ssh`/`curl` built in)
- CLI: `ssh` (built-in), `privoxy` (`brew install privoxy`), `curl`
