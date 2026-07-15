# AGENTS.md

## Project overview

The **main** project is a native SwiftUI menu bar **macOS app** (`TunnelProxy`, at the
repo root) that runs an SSH SOCKS5 → HTTP (bundled Privoxy) tunnel and toggles the macOS
system proxy. The tunnel logic is native Swift and Privoxy is bundled in the `.app`, so
it needs no external scripts at runtime.

An older, standalone **bash CLI** lives in [cli/](cli/). The app and the CLI do not share
configuration.

See [CLAUDE.md](CLAUDE.md) for the full architecture; [README.md](README.md) for build/
release; [cli/README.md](cli/README.md) for the CLI.

## Key locations

- `TunnelProxy.xcodeproj`, `TunnelProxy/` — the macOS app (open the project from the root)
- `release.sh`, `ExportOptions.plist` — build + sign a distributable DMG
- `plan/` — design docs + mockups
- `cli/` — bash CLI:
  - `cli/proxy` — entry point (`proxy start|stop|status|socks-on|socks-off|log`)
  - `cli/start.sh` — SSH tunnel + Privoxy + optional watchdog
  - `cli/stop.sh` — kills tunnel + Privoxy + watchdog
  - `cli/.env` — configuration (gitignored)
  - `cli/install.sh` / `cli/Makefile` — `make install` symlinks `proxy` to `/usr/local/bin`

## Build & run

```bash
# macOS app
xcodebuild -project TunnelProxy.xcodeproj -scheme TunnelProxy -configuration Debug build
./release.sh                          # signed DMG (see README.md for notarization)

# CLI (from cli/)
cd cli && make install                # symlink proxy to /usr/local/bin
proxy start        # start tunnel + privoxy
proxy start -a     # + background watchdog (reconnects every 30s), alias for --always
proxy stop         # stop everything
proxy status       # check if running (curls through proxy)
proxy socks-on     # enable macOS SOCKS proxy + git proxy (alias: proxy so)
proxy socks-off    # disable macOS SOCKS proxy + git proxy (alias: proxy sf)
proxy log          # tail the log file
```

The app has no test/lint steps beyond `xcodebuild build`. The CLI has none.

## CLI gotchas

- `proxy start` **overwrites** `/opt/homebrew/etc/privoxy/config` on every run. Don't put custom Privoxy config there.
- `socks-on`/`socks-off` use `sudo networksetup` — requires macOS admin password.
- Scripts use `pkill -f "ssh.*-D ..."` to kill tunnels — this pattern matches the host string, so keep `SSH_HOST` unique.
- Watchdog PID stored at `/tmp/ssh-tunnel-watchdog.pid`. Stale PID file means zombie watchdog.
- Health check uses `api.anthropic.com` (expects auth error) and `api.ipify.org` (expects IP) — both must be reachable.

## Dependencies

- macOS app: Xcode 15+, macOS 14+ (Privoxy bundled; `ssh`/`curl` built in)
- CLI: `ssh` (built-in), `privoxy` via Homebrew, `curl`
