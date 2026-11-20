# App Routing — recover hostnames for IP-only proxied flows

Status: implemented in the working tree (2026-11-20). The local relay fixture
exercises the production parser and relay. Signed-extension acceptance on the
affected network and the ChatGPT desktop reproduction are still pending.

> **Revision (2026-11-20, later):** the v1 rule "any `0xfe0d` extension means
> `ECH or GREASE`, use the IP path" was dropped after real traffic hit it. On the
> affected network every routed flow reported `ECH/GREASE` and none reached the
> IP path successfully (`TLS names 0 · ECH/GREASE 7` in Recent Connections), so
> discarding the visible name threw away the only usable hostname. The parser now
> records the extension and keeps walking the extension list; the visible SNI
> wins when it is present, and `echOrGrease` is reported only when a complete
> ClientHello carries no SNI. Per RFC 9849 the outer `public_name` of a real ECH
> hello identifies the client-facing server, so dialling it is correct (and still
> better than a poisoned IP); GREASE keeps the real hostname next to the
> extension. This does not change any direct-vs-proxy decision. Tests cover both
> shapes: ECH + SNI → `.hostname`, ECH without SNI → `.echOrGrease`.
>
> Two relay defects surfaced in the same session and are fixed with it:
> `start()` now opens the application flow **before** dialling (a flow opened only
> after the SOCKS handshake was often abandoned by busy clients, reported as
> `Could not open the application connection`), and a single client read larger
> than 64 KiB is forwarded instead of aborting the flow (`Application data
> exceeded the relay buffer` used to kill in-flight HTTP/2 connections).
> Measured after the change: `TLS names 44 · ECH/GREASE 0`, with `chatgpt.com`
> flows reaching the tunnel; only SNI-less IP flows (poisoned A/AAAA, IPv6 DNS)
> still fail.

## Problem

With Per-App Routing on, most connections from routed apps show **Blocked**.
ChatGPT (desktop) fails completely; Claude mostly works.

### Observed facts

1. **Local DNS returns known poisoned answers** (resolver `192.168.1.1`):

   | name | local A | local AAAA |
   |---|---|---|
   | chatgpt.com | 104.244.43.52 (Twitter range) | 2a03:2880:…:face:b00c:0:25de (Facebook range) |
   | api.openai.com | 66.220.146.94 (Facebook range) | 2a03:2880:…:face:b00c:0:25de |
   | claude.ai / api.anthropic.com | 160.79.104.10 | 2607:6bc0::10 |

   The destinations in the screenshots (`104.244.46.17`, `128.242.240.x`, `31.13.84.2`,
   `185.45.5.35`, `2a03:2880:f12c:83:face:b00c:0:25de`, …) are in the same poisoned
   ranges, and they are shown as bare IPs (no hostname).
2. **Remote resolution works, the poisoned IP does not** (SOCKS port 1080):
   - `curl --socks5-hostname … https://chatgpt.com/` → 200.
   - `curl --socks5 … --resolve chatgpt.com:443:104.244.43.52` → exit 35.
   - `curl --socks5 … https://[2607:6bc0::10]/` → exit 97 (one IPv6 target).
3. `tunnel.log` has many `channel N: open failed: connect failed: open failed` and
   `… Connection timed out` lines at the times of the failures.
4. **Code path:** `RoutingDestination` takes `flow.remoteHostname`, then a name
   carried by the endpoint. When both are absent, `socksCommand` sends an IPv4/IPv6
   address (ATYP 1/4), so the SSH server only sees the IP the app resolved.

### Working hypothesis (to verify, see Instrumentation)

The routed apps resolve names locally, get poisoned IPs, and connect by IP. The
extension forwards that IP and the SSH server cannot reach it. Not yet proven:

- that the ChatGPT desktop failures are exactly this path (which process/helper,
  which original target, whether a hostname was ever available);
- that Chrome's own DNS is blocked and it falls back to the system resolver;
- whether the SSH server has IPv6 egress at all (one failed target is not proof).

## Scope of the first version

Sniff a hostname **only** when all of these hold:

- the app's policy is **Proxy All**;
- the flow is **TCP** to an external destination (`isLocal == false`);
- `destination.name == nil` (no `remoteHostname`, no name in the endpoint).

Everything else is unchanged. In particular the product decision table in
`app-routing-implementation.md` §2.2 stays as is:

- `proxyListed` + unknown name → **blocked**;
- `directListed` + unknown name → **proxy by IP**;
- no relay that connects directly from the extension.

A sniff miss (ECH/GREASE, no SNI, timeout, parse window exceeded) never goes direct. It falls
back to today's behavior: SOCKS to the original IP.

Known limit: `proxyListed` / `directListed` apps keep failing on poisoned domains.
A later safe step for `directListed`: sniff, and if the name is **not** listed,
proxy by name; if it is listed or unknown, keep proxying by IP. That never sends
traffic direct. Not in v1.

## Design

### Hostname source: readable TLS SNI only

New file `TunnelProxyRoutingExtension/RoutingSniffer.swift`, with pure functions
and no NetworkExtension dependency:

```swift
enum RoutingSniffer {
    enum Result { case hostname(String), echOrGrease, notApplicable, needMoreData }
    static func sniffTLS(_ prefix: Data) -> Result
}
```

- Record type `0x16`, handshake `0x01`. Walk session id, cipher suites,
  compression and extensions to `server_name` (type `0x0000`, host_name 0).
  Bounds-check every length. Allow a ClientHello split across records or reads.
- Parse window: 16 KB. Past it → `.notApplicable`.
- Pass the result through `RoutingDomain.normalize`. IP literals are rejected,
  which keeps the IP path.
- The sniffed SNI is only a **hint for the proxied target**. Keep the original
  port. It never affects a direct-vs-proxy decision, and `isLocal` stays based on
  the original IP.
- **ECH:** with ECH the readable SNI is the outer `public_name`, which identifies
  the client-facing server (RFC 9849). GREASE can use the same extension while
  the real hostname remains visible. A passive relay cannot use the presence of
  0xfe0d alone to distinguish the two, and it cannot tell "no SNI because ECH"
  apart from "no SNI for another reason" — so the extension is only recorded, not
  acted on. The plaintext SNI, when the hello has one, is still the best target
  available: it is a name for the right server, which beats the IP the app
  resolved. Only a complete hello with 0xfe0d and no SNI is reported as
  `ECH or GREASE` and left on the IP path.
- **Plain HTTP `Host`** is left out of v1. A `Host` or `CONNECT` target can name
  something behind an explicit proxy, so rewriting by it is unsafe without more
  rules. Revisit later, and only for plain origin requests.

### Relay changes (`RoutingTCPRelay`)

For sniffing flows only:

1. `flow.open(...)` first. Reading the hello needs an open flow.
2. **One outstanding client read at a time** — a rule for the relay's whole life,
   not only during sniffing:
   - append each read's bytes to a pending buffer, in order;
   - while sniffing and still under the window, issue the next read only after
     the previous callback returns.
3. Sniffing ends with the first of these: a hostname, ECH/GREASE, `.notApplicable`, or the
   **sniff timeout (300 ms)**. The timeout only ends the *decision*:
   - Any read still in flight keeps running. Its data is appended to the pending
     buffer, and that same callback chain continues into normal forwarding. No
     second `readData` is ever started.
   - After the timeout, the upstream may connect and receive server-first bytes
     (SMTP/SSH greetings) while the client read is still pending.
4. Build the SOCKS command: the sniffed name with the original port, otherwise the
   original IP. Connect, verify the peer and negotiate exactly as today.
5. Once SOCKS succeeds, write the whole pending buffer upstream **once, in
   order**. This includes bytes past the 16 KB window and any bytes after the
   ClientHello in the same callback. Start upstream reads immediately on CONNECT
   success, independently of client reads or pending writes.
6. Half-close and tunnel loss follow today's rules:
   - client EOF before SOCKS completes → remember it and send FIN after the
     buffer is flushed;
   - tunnel loss → `finish` with a reason.

Non-sniffing flows keep today's order (SOCKS first, then `flow.open`). The
64 KiB chunk guard applies to each read. Once the routing decision is made, pause
new client reads until CONNECT succeeds and pending bytes have been sent. At
most one partial parse window plus one callback (under 80 KiB) awaits forwarding.
Opening the app flow does not mark the tunnel ready or disarm the 12-second
setup deadline. Only completed SOCKS setup plus an open app flow does that.

### Accurate failure reasons (`RoutingTCPRelay`)

Replace the shared "SSH rejected SOCKS negotiation" message with one reason per
stage:

| Stage | Reason |
|---|---|
| loopback connect / `.waiting` / `.failed` | SSH SOCKS listener unavailable |
| peer verification | Tunnel identity not verified (unchanged) |
| method reply short or EOF | Connection closed during SOCKS greeting |
| method reply not `05 00` | SSH rejected SOCKS method |
| CONNECT reply short or EOF | Connection closed while waiting for CONNECT reply |
| valid CONNECT reply with REP ≠ 0 | Destination failure with the numeric SOCKS REP code in the event |
| unknown ATYP in reply | Malformed SOCKS reply |
| `flow.open` error | Could not open the application connection (unchanged) |
| 12 s timer | Connection setup timed out; the event shows the current stage |

Track the current stage in a field so the 12 s timer can name it. OpenSSH usually
closes the socket instead of sending a failure reply when the remote open fails,
so "closed while waiting for CONNECT reply" is the common case. The text does not
claim the destination was unreachable, because SSH dying looks the same.

Leave the IPv6 behavior and the 12 s timeout unchanged until the instrumentation
has data. Add the new strings to `AppRouting.strings` (en / zh-Hans).

### Instrumentation

Keep original endpoint, actual process signing identifier, hostname source, SOCKS
address type, stage and reply code in the existing per-app 50-event memory
buffer. Recent Connections displays these details and counts unique flows in
the visible sample with recovered SNI, ECH/GREASE, and other sniff misses.
No per-flow logging is needed. Do not pass destination values to unified logs.

On the affected network, reproduce the failing desktop action and check the
responsible helper and sample counts. If required flows consistently skip SNI
because of ECH/GREASE, the feature leaves those targets on the IP path. Record
that limitation before attributing any improvement to hostname recovery.

## Out of scope (separate plans)

- **Forwarding app DNS through the tunnel.** It changes the existing DNS rules
  (`app-routing-implementation.md` DNS table: UDP/53 is blocked under Proxy All)
  and LAN/VPN/split-DNS behavior. The SDK also forbids port-53 address rules
  ("Destination Domain-based rules must be used to match DNS traffic",
  `NETransparentProxyNetworkSettings.h`). First measure on the target macOS which
  UDP/53 flows actually reach the provider and whether they can be attributed to
  the app. The current fix does not depend on it.
- IPv6 fast-fail and timeout tuning: wait for instrumentation data.
- Hostname recovery for domain-list policies (see Scope).
- Plain HTTP `Host` sniffing.

## Files

- `TunnelProxyRoutingExtension/RoutingSniffer.swift` — new; add it to the
  extension target in `project.pbxproj`.
- `TunnelProxyRoutingExtension/RoutingTCPRelay.swift` — open-first sniff path,
  single-read invariant, pending-buffer replay, per-stage reasons.
- `TunnelProxyRoutingExtension/AppRoutingProvider.swift` — eligibility check
  (Proxy All + TCP + external + no name), instrumentation, event destination.
- `TunnelProxyRoutingExtension/RoutingDestination.swift` — build the command with
  an override name and the original port.
- `TunnelProxy/*.lproj/AppRouting.strings` — new reasons.
- `tests/run-routing-checks.sh`, `tests/RoutingHarness.swift` — compile the sniffer
  and add the checks below.

## Validation

Run `bash tests/run-routing-checks.sh --relay` for parser checks and a loopback
SOCKS fixture with a synthetic app flow. The fixture checks wire bytes and EOF,
server-first traffic, ECH/GREASE, known hostnames, cancellation, and a listener
that never replies to CONNECT. It uses its own peer check. The installed
extension still requires the SSH socket ownership and heartbeat checks.

Local verification (2026-11-20): the unsigned Debug app and extension built.
All seven loopback scenarios and the routing harness passed. A separate offline
check recovered the expected SNI from a 1,523-byte TLS-library ClientHello.
The controlled SSH egress comparison and signed desktop cases below remain open.

1. **Sniffer unit checks:**
   - captured ClientHellos (curl, Chrome with a post-quantum key share split
     across two records or reads);
   - SNI absent, ECH present, truncated or malformed lengths, IP-literal SNI;
   - a hello followed by application bytes in the same buffer;
   - more than 16 KB before a decision.
2. **Relay ordering checks** (harness, fake flow plus a local SOCKS fixture):
   - the sniff timeout fires while a read is in flight → late bytes are
     forwarded once, in order, and no second read is started;
   - a first callback larger than 16 KB is forwarded intact;
   - client EOF before SOCKS completes → FIN after the flush;
   - the tunnel drops during sniffing and during the flush;
   - a server-first protocol connects after the timeout.
3. **Controlled poisoned-IP comparison** (same test path, old vs. new build):
   - a test hostname resolves locally to a wrong IP;
   - the old build sends ATYP 1 with the wrong IP and fails;
   - the new build sends ATYP 3 with the name;
   - the test site logs the SSH egress address as the client;
   - the client completes TLS and an application request.
4. **Real apps:**
   - in ChatGPT desktop, repeat the failing action (start a chat, receive a
     streamed reply);
   - Google Chrome (Proxy All) loads chatgpt.com;
   - regression: Claude desktop plus Claude Code;
   - regression: `proxyListed` / `directListed` behave exactly as in §2.2;
   - local destinations stay direct.

   Recent Connections showing **Proxy** helps locate problems, but it is not
   acceptance proof; the actions above are.
