# App Routing — fix for DNS poisoning / IP-only flows

Status: plan (2026-11-19). Not implemented.

## Problem

With Per-App Routing on, most connections from routed apps are shown as **Blocked**.
ChatGPT fails completely. Claude mostly works.

### Root cause (verified)

1. **Local DNS is poisoned.** The resolver (`192.168.1.1`) returns GFW fake answers:

   | name | local A | local AAAA |
   |---|---|---|
   | chatgpt.com | 104.244.43.52 (Twitter range) | 2a03:2880:…:face:b00c:0:25de (Facebook) |
   | api.openai.com | 66.220.146.94 (Facebook range) | 2a03:2880:…:face:b00c:0:25de |
   | claude.ai / api.anthropic.com | 160.79.104.10 (real) | 2607:6bc0::10 (real) |

   Every address in the screenshots (`104.244.46.17`, `128.242.240.x`, `31.13.84.2`,
   `185.45.5.35`, `2a03:2880:f12c:83:face:b00c:0:25de`, …) is a typical poisoned answer.
   Claude works because its domains are not poisoned.

2. **The extension only sees an IP.** Chromium and Electron apps (and others) resolve
   the name themselves and then `connect()` to an IP. So `flow.remoteHostname` is nil,
   and `RoutingDestination.socksCommand` sends an ATYP 1/4 (IP) SOCKS request. The
   SSH server then tries to connect to the fake IP.
   - `curl --socks5-hostname 127.0.0.1:1080 https://chatgpt.com/` returns **200**
     (the server resolves the name, so the tunnel works).
   - `curl --socks5 … --resolve chatgpt.com:443:104.244.43.52` fails with exit 35.

3. **The SSH server has no IPv6 egress.** Any IPv6 literal target fails
   (`curl --socks5 … https://[2607:6bc0::10]/` gives exit 97). `tunnel.log` shows
   `channel N: open failed: connect failed: open failed`.

4. **The app's own DNS is blocked and falls back to poisoned DNS.** UDP flows from
   routed apps (e.g. Chrome's built-in resolver to `8.8.8.8` /
   `2001:4860:4860::8888`) are blocked ("UDP cannot use the SSH tunnel"). The app
   then falls back to the system resolver, which `mDNSResponder` performs. That is
   not a routed process, so the extension cannot intercept it.

### How the UI reasons map to these causes

| UI reason | Real meaning |
|---|---|
| SSH connection timed out | The server is still trying to reach a fake IP; the 12 s relay timer fired. |
| SSH rejected SOCKS negotiation | OpenSSH buffers its SOCKS success reply until the server's channel opens. If the remote connect fails, ssh closes the socket and sends no reply, so `receive(4)` fails. It does **not** mean negotiation was rejected. |
| Could not open the application connection | SOCKS succeeded too late; the app had already given up on the flow. |
| UDP cannot use the SSH tunnel | The app's own DNS/QUIC was blocked (intended, but it causes cause 4). |

Domain policies (`proxyListed`) also return `.blocked` ("Hostname unavailable")
whenever the hostname is nil, so they fail for the same reason.

## Fix

### Phase 1 — sniff the hostname from the first client bytes (main fix)

When `flow.remoteHostname` is nil, accept the flow and read the client's first
bytes before connecting upstream. Get the real name from:

- the **TLS ClientHello SNI** (`server_name` extension), or
- the **HTTP/1.x `Host:` header** (plain HTTP, port 80 and others).

Then send a domain-name SOCKS request (ATYP 3), so the SSH server resolves the
name. This fixes both the poisoned IPv4 answers and the unreachable IPv6 answers.
It needs no DNS changes and covers almost all app traffic, which is HTTPS.

#### New file: `TunnelProxyRoutingExtension/RoutingSniffer.swift`

Pure functions with no NetworkExtension dependency, so the harness can test them:

```swift
enum RoutingSniffer {
    enum Result { case hostname(String), notApplicable, needMoreData }
    static func sniff(_ prefix: Data) -> Result
}
```

- **TLS:** record type `0x16`, handshake type `0x01`. Walk session id, cipher
  suites, compression and extensions to extension `0x0000`, host_name (type 0).
  Bounds-check every length. Accept a ClientHello split across several records up
  to a 16 KB cap (post-quantum key shares make ClientHellos larger than one
  segment).
- **HTTP:** first line matches `METHOD SP target SP HTTP/1.x`. Find `Host:`
  (case-insensitive) before `\r\n\r\n`, and strip the port.
- Pass the result through `RoutingDomain.normalize`. Reject IP literals, so a
  `Host: 1.2.3.4` keeps the IP path.
- Return `.needMoreData` until the cap is reached; after that, `.notApplicable`.

#### `RoutingTCPRelay` changes

Reorder the relay when sniffing is needed:

1. `flow.open(...)` first. This is needed to read the client's data, and it also
   removes the "Could not open the application connection" race.
2. Read client data into a prefix buffer until `sniff` returns `.hostname` or
   `.notApplicable`, or a **sniff timeout** (≈300 ms) passes. Server-speaks-first
   protocols (SMTP, SSH, FTP) send nothing first, so they hit the timeout.
3. Build the SOCKS command: the sniffed name and original port, otherwise the
   original IP target.
4. Connect, verify the peer and negotiate as today. Then **write the buffered
   prefix upstream** before starting `readClient()` / `readSSH()`.

When `remoteHostname` is already known, keep today's flow unchanged.

The relay takes a `destination` (or a closure that builds the command from the
sniffed name) instead of a ready-made `command`.

#### `AppRoutingProvider` changes — decisions that depend on the hostname

`proxyAll` needs no decision before sniffing. Domain policies do, because a
direct verdict currently returns `false` (hand back to the system). A flow that
was already accepted for sniffing cannot be handed back. Plan:

- `remoteHostname` known → keep the current behavior (decide immediately; direct
  returns `false`).
- `remoteHostname` nil and policy is `proxyAll` → sniff, then proxy.
- `remoteHostname` nil and policy is `proxyListed` / `directListed` → accept,
  sniff, then decide with the sniffed name:
  - proxy → SOCKS as above.
  - direct → a **direct relay** from the extension: an `NWConnection` to the
    original IP:port, with the same buffered-prefix write. The extension's own
    sockets are not intercepted. The app's own (local) DNS answer is right for
    direct traffic by definition.
  - no name found → the existing fallback (`proxyListed` → direct relay;
    `directListed` → proxy by IP). Remove the hard "Hostname unavailable"
    block.
- Factor the byte pump (`readClient` / `readSSH` / half-close) so the SOCKS relay
  and the direct relay share it. Only the upstream setup differs.

Record the event with the sniffed hostname as `destination` (keeping the IP in
the reason, or as a secondary field), so the Recent Connections list shows
`chatgpt.com` instead of a fake IP.

### Phase 2 — fail fast and give accurate reasons

- Change the "SSH rejected SOCKS negotiation" text for the post-command
  `receive(4)` failure to **"Server could not reach destination"**. Keep the
  current text only for a bad `[5, 0]` method reply. Add the new string to both
  `AppRouting.strings` files (en / zh-Hans).
- IPv6 literal target with no sniffed name: send it anyway, but shorten the
  timeout. Optionally add a profile setting "Server has IPv6" (default off). When
  it is off, close IPv6-only flows at once with "Server has no IPv6", so Happy
  Eyeballs falls back to IPv4 immediately instead of waiting.
- Lower the 12 s connect timer for IP-only targets (e.g. 6 s). Keep 12 s for
  name targets, which include remote DNS time.

### Phase 3 (optional) — proxy app-originated DNS

For routed apps, intercept UDP flows to port 53 instead of blocking them. Forward
each query as **DNS-over-TCP** through SOCKS to a fixed resolver (`1.1.1.1:53` or
`8.8.8.8:53`, configurable), and write the answer back to the UDP flow. This gives
Chrome's built-in resolver clean A/AAAA and HTTPS records. It does not help
`getaddrinfo` (that goes through `mDNSResponder`), so it complements Phase 1 and
does not replace it. Keep other UDP (QUIC on 443) blocked; browsers fall back to
TCP.

## Risks / notes

- **ECH:** Chrome may send an outer SNI (`public_name`, e.g. `cloudflare-ech.com`)
  that differs from the real host. Connecting to the outer name still reaches the
  same CDN edge, which decrypts the inner hello, so proxying still works.
  Domain-list policies may match the cover name instead; document this limit.
- **Latency:** sniffing costs nothing for client-speaks-first protocols. The data
  is already there when the flow opens. Only server-speaks-first protocols pay the
  ≈300 ms timeout.
- **Memory:** the prefix buffer is capped at 16 KB per flow, under the existing
  256-relay limit.
- **Hostname trust:** sniffed names come from the app itself, so they are as
  trustworthy as `remoteHostname`. Normalize them all the same, and never use them
  to bypass `isLocal` (that check stays on the original IP).

## Files

- `TunnelProxyRoutingExtension/RoutingSniffer.swift` — new; add it to the
  extension target in `project.pbxproj`.
- `TunnelProxyRoutingExtension/RoutingTCPRelay.swift` — open-first and sniff
  path, prefix replay, shared pump, direct-upstream variant.
- `TunnelProxyRoutingExtension/AppRoutingProvider.swift` — deferred decisions
  for IP-only flows, event destination from the sniffed name, (Phase 3) UDP 53.
- `TunnelProxyRoutingExtension/RoutingDestination.swift` — build a command from
  an override name; IPv6 helper.
- `TunnelProxy/AppRouting/RoutingRules.swift` — `decision(hostname:)` callers
  stop treating nil as final for flows that are still sniffing.
- `TunnelProxy/*.lproj/AppRouting.strings` — new reason strings.
- `tests/run-routing-checks.sh`, `tests/RoutingHarness.swift` — compile
  `RoutingSniffer.swift` and `RoutingDomain` and add parser checks.

## Validation

1. **Parser unit checks (harness):** real ClientHellos (curl, Chrome, with a PQ key
   share split across two records), truncated or malformed records, missing SNI,
   HTTP `Host` with port, IP-literal Host, non-TLS/non-HTTP bytes, and the size
   cap.
2. **Tunnel checks:** against the live SOCKS port, confirm that ATYP 3
   `chatgpt.com:443` succeeds where the poisoned IP fails. This is the same
   comparison as in the investigation, written as a script.
3. **End-to-end:** a Debug build with Per-App Routing:
   - ChatGPT and Google Chrome on **Proxy All** load chatgpt.com.
   - Recent Connections shows hostnames and **Proxy**.
   - `tunnel.log` has no `open failed` for those hosts.
   - Claude still works.
   - A `proxyListed` app with `chatgpt.com` proxies that host and sends others
     direct.
4. **Regression:** local-network destinations stay direct; a server-speaks-first
   connection (e.g. `ssh` to an external host from a routed terminal) still
   connects after the sniff timeout.
