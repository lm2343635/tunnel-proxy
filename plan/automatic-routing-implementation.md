# Automatic SSH routing — scheme A

Implemented on 2026-11-19. Design: `mockups/ssh-route-auto/A-light-touch.svg`.

## Behavior

- Existing and new profiles default to automatic routing. HTTP CONNECT and SOCKS5
  endpoints are discovered from system settings and conventional loopback ports.
- Validate the target with a no-credentials SSH key exchange; then authenticate the
  real SSH process. Failed proxy paths fall back to a physical-interface-bound
  transport. Never mistake the app's own proxy listeners for an upstream proxy.
- Every automatic reconnect discovers routes again. Healthy connections stay on
  their selected route. Explicit disconnect cancels pending startup and recovery.
- Authentication and host-verification failures halt fallback/retry. Startup waits
  for the owned SOCKS listener instead of using a fixed 3.5-second deadline.
- Scheme A adds the compact connection-path row and opens the existing per-server
  editor with Automatic / Direct / Via proxy controls and proxy autodetection.
- Automatic mode includes recovery; the legacy watchdog control displays that it
  is managed. In fixed proxy mode, no direct fallback occurs.

## Validation

- Debug macOS xcodebuild succeeded (ad-hoc deliverable; no release/notarization).
- Production-model/planner checks cover legacy decoding, proxy ordering/dedup,
  self-loop exclusion, fixed modes and unsafe host rejection.
- Isolated live engine checks used ephemeral ports and temporary app data, with
  the existing SSH server and key: explicit VPN proxy and physical-direct key
  exchange, authenticated SSH + bundled Privoxy, dead-proxy direct fallback,
  stopping child processes/recovery, auth failure stopping retries, and stop
  during discovery. A disposable local HTTP CONNECT relay simulated proxy loss
  and the watchdog successfully recovered over physical direct networking.
- GUI checked in a separate preview bundle ID with a temporary home directory:
  connection-path row, three modes, proxy autodetection and manual fields.
- No installed app replacement or user VPN/network configuration change.

## Limits

Proxy authentication and PAC evaluation are not implemented. Automatic mode tests
availability rather than comparing route speeds. Recovery follows the configured
watchdog interval and backoff; transport liveness still uses SSH keepalives.
The proxy latency tile reports SSH-handshake time; direct mode reports TCP time.
Manual settings apply on the next connection. See README for reproducible checks.
