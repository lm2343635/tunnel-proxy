# Plan: Handle "port already in use" with a force-kill prompt

## Problem

When the tunnel starts, two local ports must be free:

- **SOCKS port** (`config.socksPort`, default **1080**) — bound by `ssh -D`.
- **HTTP proxy port** (`config.httpProxyPort`, default **8118**) — bound by the bundled Privoxy.

If another process already holds one of these ports, the child fails to bind. Today
those failures only appear in the log file and the UI just says *"Tunnel failed to
start"* — the user is never told **why**, and the watchdog keeps relaunching `ssh`
on the same interval, so the log fills with the same errors forever (the screenshot):

```
bind [127.0.0.1]:1080: Address already in use
channel_setup_fwd_listener_tcpip: cannot listen to port: 1080
Could not request local forwarding.
...
Fatal error: can't bind to 127.0.0.1:8118: There may be another Privoxy or
some other proxy running on port 8118
```

A very common cause is a **stale Privoxy / ssh from a previous run** (or a crashed
app) still holding the port. Another app can hold it too.

### Why the log spins forever (the actual screenshot bug)

The endless loop is not only a missing preflight — it's that the watchdog is armed
**even when the initial connect never succeeded**. `TunnelEngine.connect()` calls
`startWatchdog()` unconditionally after the health check, so a connect that returned
`.down` (both ports failed to bind) still starts a 30s watchdog that relaunches `ssh`
into the same occupied port forever. That is exactly the
`Tunnel failed to start → Watchdog started → bind … Address already in use` cadence in
the screenshot. Fixing the prompt without fixing this leaves the spin in place, so the
watchdog-arming guard (Step 5) is part of the core fix, not a nice-to-have.

## Decision (shipped): silent reclaim, no prompt

The design below describes a confirmation prompt. In implementation we chose the
**simpler** behavior: on Connect, silently force-quit whatever holds the SOCKS / HTTP
ports (SIGTERM → SIGKILL grace), then connect. No dialog. Rationale: the ports are
app-owned by convention, the overwhelmingly common holder is a stale ssh/privoxy from a
previous run, and a menu-bar Connect click is already an explicit "make it work" intent.
A root-owned holder we can't kill simply falls through to the normal "failed to start"
error. The watchdog-arming guard (don't arm on `.down`, don't relaunch into a
foreign-held port) still applies and is the core fix for the screenshot spin. The
prompt/`PortConflict`/alert sections below are retained as the considered alternative.

## Goal

Before (or when) a bind fails, detect the port conflict, tell the user which process
is holding the port, and **ask whether to force-quit that process**:

- **Force Quit & Connect** → kill the occupying process, then proceed.
- **Cancel** → stop, leave a clear error state (no watchdog spin).

This matches the request: *"8118 port is used by other application… ask user to
force kill the application using this port or not."*

## Where the code lives (grounding)

| Concern | File |
|---------|------|
| Spawns `ssh -D` (SOCKS) and Privoxy (HTTP), owns the processes | `TunnelProxy/Controllers/TunnelEngine.swift` (`startSSH`, `startPrivoxy`) |
| Drives connect flow, owns published UI state, runs `Task.detached` shell calls | `TunnelProxy/Controllers/TunnelController.swift` (`connect()`) |
| Synchronous `Process` wrapper (used for `lsof` / `kill`) | `TunnelProxy/Controllers/ProcessRunner.swift` |
| Menu bar popover / where a confirmation surfaces | `TunnelProxy/Views/MenuBarView.swift` |
| Port values | `TunnelProxy/Controllers/TunnelConfig.swift` (`socksPort`, `httpProxyPort`) |

## Approach

**Preflight check before spawning** (recommended over parsing Privoxy stderr after
the fact — we can prompt *before* launching any child, and the same code covers both
ports).

### 1. Detect who holds a port — `PortInspector`

New helper (e.g. `TunnelProxy/Controllers/PortInspector.swift`) using the existing
`ProcessRunner`:

```
lsof -nP -Fcpn -iTCP:<port> -sTCP:LISTEN
```

`-F` field output is stable to parse (one field per line, prefixed by a type char):
`p<pid>`, `c<command>`, `n<name>`. Request `n` so we get the **full executable path**,
not just the short command name — `isOurs` compares that path, which is more reliable
than matching `"privoxy"`/`"ssh"` by name (a foreign privoxy would match by name too).

Parse into a small struct per listener:

```swift
struct PortHolder {
    let port: Int
    let pid: Int32
    let command: String    // short name for display, e.g. "privoxy", "ssh"
    let path: String       // full executable path, used for isOurs
    let isOurs: Bool        // path is our bundled privoxy or /usr/bin/ssh
}
```

`isOurs` is true when `path` equals `AppPaths.bundledPrivoxy?.path` or `/usr/bin/ssh`.
Note this is a heuristic: it means "the kind of process we spawn," used only to soften
the prompt copy ("a leftover TunnelProxy process") and to let the watchdog reclaim its
own leftovers. It does **not** prove the process is *our* current live child — never use
`isOurs` alone to auto-kill without the reconnect-race guard below.

`lsof` is present on every macOS install; if it's somehow missing (or returns nothing
parseable), treat the port as "unknown" and fall back to today's behavior (attempt +
log) rather than blocking the connect.

### 2. Preflight in `TunnelController.connect()`

Before `engine.connect(...)`:

1. Check `socksPort` and `httpProxyPort` for holders.
2. If none → connect as today.
3. If a holder exists → set a `@Published var portConflict: PortConflict?` describing
   the port(s), process name(s), and PID(s). The view presents a confirmation.
4. On **Force Quit & Connect** → call `PortInspector.kill(holders)` then continue the
   connect. On **Cancel** → `state = .error("Port 8118 in use by <name>")` and stop.

Run the `lsof`/`kill` calls off the MainActor. The existing `Task.detached` +
`ProcessRunner.run` pattern in `TunnelController.syncSystemSocksState()` is the model to
mirror.

Killing our own user's process needs **no sudo** (`kill(pid, SIGTERM)`, escalate to
`SIGKILL` after a short grace period — mirror the existing `terminate(_:name:)` grace
loop in `TunnelEngine`). If the holder is root-owned, `kill` returns `EPERM`; surface
"couldn't quit <name> (needs admin) — free port <n> manually" rather than failing
silently.

### 3. Stop the watchdog from spinning on a conflict

Two separate fixes — the first is the real screenshot bug:

**3a. Don't arm the watchdog on a failed connect.** In `TunnelEngine.connect()`, only
call `startWatchdog()` when the health check is `.proxyOK` (or at least not `.down`). A
connect that never came up must not leave a background task relaunching `ssh` forever.
This alone stops the log spin in the screenshot.

**3b. Don't relaunch into a foreign-held port on reconnect.** `watchdogTick()` currently
relaunches `ssh` whenever the `curl --socks5` probe fails. But that probe can't tell
"tunnel down" from "a foreign process is squatting on :1080" — both fail identically. So
`watchdogTick()` must consult `PortInspector` before relaunching: if the SOCKS port is
held by a process that isn't ours (or isn't a live child of ours), log once and stop
relaunching instead of spinning.

This means **`PortInspector` must be reachable from inside the `TunnelEngine` actor**,
not just from `TunnelController` — it's a plain `enum`/`static`-method helper on
`ProcessRunner`, so both call sites can use it directly.

### 3c. Preflight also guards reconnect, not just first connect

`startSSH()` is called both from `connect()` (first connect) and from `watchdogTick()`
(reconnect), the latter entirely inside the actor without touching the controller's
`connect()`. A preflight that lives only in the controller protects the first connect
but not reconnects — 3b covers the reconnect path so the guard isn't bypassed. Keep the
user-facing *prompt* in the controller (needs UI); the *silent guard* lives in the
engine.

### 3d. Reconnect-race guard on `isOurs`

During a watchdog reconnect there's a window where our own just-killed ssh is being torn
down while a new one starts. Don't let the engine flag its own live/expected child as
"foreign" and refuse to reconnect. `watchdogTick()` should only refuse when the holder
is present *and* not ours *and* not the pid of a child we currently own — otherwise fall
through to the normal relaunch.

## UI

A confirmation dialog when a conflict is detected. Because the app is a menu-bar agent
(`LSUIElement`), call `NSApp.activate(ignoringOtherApps:)` first (same pattern as
`MenuBarView.activateApp()`) so the alert comes to the front.

```
┌───────────────────────────────────────────────┐
│  Port 8118 is already in use                    │
│                                                 │
│  “privoxy” (PID 4821) is listening on port      │
│  8118. TunnelProxy needs this port for the      │
│  HTTP proxy.                                     │
│                                                 │
│  Force-quit that process and connect?           │
│                                                 │
│     [ Cancel ]        [ Force Quit & Connect ]  │
└───────────────────────────────────────────────┘
```

- If the holder **is ours** (a stale bundled privoxy / our ssh), the copy can say
  *"a leftover TunnelProxy process"* and this is the safe, expected case.
- If **both** ports are held, list both in one dialog.

Implementation: SwiftUI `.alert` bound to `controller.portConflict`, or an `NSAlert`
from the controller. Alert-based keeps it in the existing SwiftUI flow.

## Recommended defaults (call out for review)

- **Scope:** cover **both** 1080 and 8118 — the screenshot shows both conflicting and
  the root cause (stale children) is identical. The prompt still leads with the port
  the user hit.
- **Auto-kill our own stale process:** *Recommended off for v1* — always ask, even for
  our own leftover, so nothing is killed without a click. (Easy toggle later:
  "silently reclaim leftover TunnelProxy processes.")
- **Offer "use a different port" instead of killing:** out of scope for v1; the request
  is specifically about force-killing. Note as a future alternative.

## Steps

1. Add `PortInspector` (`lsof -Fcpn` parse incl. full path + `isOurs`; `kill` with
   SIGTERM→SIGKILL grace). Reachable from both the controller and the engine actor.
2. Add `PortConflict` model + `@Published var portConflict` on `TunnelController`.
3. Preflight both ports in `connect()`; wire confirm/cancel to kill-then-connect / error.
4. **Watchdog-arming guard**: in `TunnelEngine.connect()`, don't `startWatchdog()` on a
   `.down` health result (the core screenshot fix).
5. **Watchdog-relaunch guard**: `watchdogTick()` consults `PortInspector` and refuses to
   relaunch into a foreign-held SOCKS port (with the reconnect-race guard, 3d).
6. Add the confirmation `.alert` in `MenuBarView` (activate app first).
7. Localize new strings (`en` + `zh-Hans`, matching existing `Localizable.strings`).
8. Manual test: occupy 8118 (`privoxy` or `nc -l 8118`), Connect → prompt →
   Force Quit → connects; Cancel → clean error, **no watchdog spin**. Repeat for 1080.
   Also verify a `.down` connect with no occupant leaves no spinning watchdog.

## Risks / open questions

- **Killing the wrong thing:** always show name + PID; never kill without confirmation
  (see auto-kill default above).
- **Root-owned holder:** `kill` fails with `EPERM` — report clearly, don't loop.
- **Menu-bar agent modality:** must `NSApp.activate` before the alert or it can appear
  behind other windows.
- **Race:** the port could be re-taken between the check and the spawn; if the bind
  still fails after a kill, fall back to the error state with the logged reason.
