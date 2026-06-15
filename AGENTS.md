# AGENTS.md

## Project overview

Bash scripts that set up an SSH SOCKS5 tunnel, convert it to HTTP via Privoxy, and manage macOS system proxy settings. Not a traditional code project — no build, test, or lint steps.

## Key files

- `proxy` — CLI entry point (`proxy start|stop|status|socks-on|socks-off|log`)
- `start.sh` — creates SSH tunnel + restarts Privoxy + optional watchdog
- `stop.sh` — kills tunnel + stops Privoxy + kills watchdog
- `.env` — configuration (SSH host, ports, Privoxy config path). Gitignored.
- `install.sh` — symlinks `proxy` to `/usr/local/bin`

## Gotchas

- `proxy start` **overwrites** `/opt/homebrew/etc/privoxy/config` on every run. Don't put custom Privoxy config there.
- `socks-on`/`socks-off` use `sudo networksetup` — requires macOS admin password.
- Scripts use `pkill -f "ssh.*-D ..."` to kill tunnels — this pattern matches the host string, so keep `SSH_HOST` unique.
- Watchdog PID stored at `/tmp/ssh-tunnel-watchdog.pid`. Stale PID file means zombie watchdog.
- Health check uses `api.anthropic.com` (expects auth error) and `api.ipify.org` (expects IP) — both must be reachable.

## Commands

```bash
make install    # symlink proxy to /usr/local/bin
proxy start     # start tunnel + privoxy
proxy start -a  # same + background watchdog (reconnects every 30s), alias for --always
proxy stop      # stop everything
proxy status    # check if running (curls through proxy)
proxy socks-on  # enable macOS SOCKS proxy + git proxy (alias: proxy so)
proxy socks-off # disable macOS SOCKS proxy + git proxy (alias: proxy sf)
proxy log       # tail /tmp/ssh-tunnel.log
```

## Dependencies

- `ssh` (macOS built-in)
- `privoxy` via Homebrew
- `curl`
