# Handoff: Tunnel Proxy — Unified Window Redesign (Sidebar + Tiles)

## Overview
Redesign of the Tunnel Proxy macOS menu bar app (SwiftUI, macOS 14+). The chosen direction ("2a") replaces the top icon-tab strip with a **left sidebar** (Mail/System Settings style) and restyles all content as **Control-Center-like white tiles on a light-gray canvas**. It also adds four new UI capabilities: live throughput sparkline, latency indicator, in-place server quick-switch, and a compact always-on-top mini window. Settings apply **in real time — there is no Save button**.

## About the Design Files
The bundled files are **design references created in HTML** — prototypes showing intended look and behavior, not production code. The task is to **recreate these designs in the existing SwiftUI codebase** (`tunnel-proxy/TunnelProxy/`), reusing its established patterns (`TunnelController` observable state, `SectionCard`-style composition, SF Symbols). Do not port HTML/CSS directly.

Open `Tunnel Proxy Redesign.dc.html` in a browser — it contains the final design ("2a"): Connection light/dark, Servers, Logs, Statistics, Settings, Tools, menu-bar popover, and mini window.

## Fidelity
**High-fidelity.** Colors, spacing, type sizes, and copy are final. Recreate pixel-perfectly with native SwiftUI equivalents; where macOS system colors exist (e.g. `.green`, `Color(nsColor: .windowBackgroundColor)`), prefer them over hardcoded hex so dark mode adapts automatically. The dark-mode frame shows the expected adaptation.

## Target codebase map
| Design surface | Existing file to modify |
|---|---|
| Window shell + sidebar | `Views/UnifiedWindowView.swift` (replace `TabToolbar` with sidebar; `WindowTab` enum unchanged: connection, servers, logs, stats, settings, tools) |
| Connection tab | `Views/ConnectionTab.swift` |
| Servers tab | `Views/ServersView.swift` |
| Logs tab | `Views/LogsView.swift` |
| Statistics tab | `Views/StatisticsView.swift` |
| Settings tab (merged) | `Views/SettingsView.swift` → `SettingsTab` |
| Tools tab | `Views/SettingsView.swift` → `ToolsTab` |
| Popover | `Views/MenuBarView.swift` + `Views/TunnelControlsView.swift` |
| Mini window (new) | new `Views/MiniWindowView.swift` + new `Window` scene in `TunnelProxyApp.swift` |
| Latency probe (new) | extend `Controllers/TunnelEngine.swift` / `TunnelController.swift` |
| Sparkline data | existing `Controllers/SpeedMonitor.swift` (add a ring buffer of recent samples) |

## Screens / Views

### Window shell (all tabs)
- Window: `.hiddenTitleBar`, default 840×580 (Settings ideal 640 tall), min 780×560. Content = HStack: sidebar 188 pt fixed + content pane.
- **Sidebar**: background = system sidebar material (design shows `#E9E9EB`), 1 px trailing separator `#D9D9DC`. Padding 12/10. Traffic lights occupy top ~36 pt.
  - App row: app icon 22 pt (rounded 5) + "Tunnel Proxy" 13 pt semibold.
  - Nav list (16 pt below, 2 pt row gap). Row: HStack(gap 8), padding 5×8, radius 6; SF Symbol 15 pt + label 13 pt. Symbols: `bolt.horizontal.circle`, `server.rack`, `doc.plaintext`, `chart.bar`, `gearshape`, `wrench.and.screwdriver`.
  - Selected row: fill `Color.accentColor` (#0A7CFF light / #0A84FF dark), white text, weight 500. Unselected: primary label, secondary icon.
  - Bottom status card (pinned with Spacer): white 65% fill (dark: white 6%), 1 px border, radius 8, padding 8×10. Row 1: 8 pt green dot + "Connected" 12 pt semibold + right-aligned latency "42 ms" 10 pt semibold green. Row 2: exit IP 11 pt monospaced secondary.
- **Content pane**: background `#F2F2F5` (dark `#151517`), padding 16.
- **Tile** (reused everywhere): white fill (dark `#232327` + 1 px border white 6%), radius 16, shadow `0 1 3 rgba(0,0,0,.06)`, padding ~13×16. Tile caption: 10.5 pt bold, +0.6 tracking, uppercase, secondary (`#85858B` / `#9A9AA2`).

### Connection
Grid: hero tile spanning 2 columns, then 2×2 tiles (Throughput, Latency, Server, Options). Gap 13.
- **Hero tile**: gradient `linear(120°, #E4F8E9 → #FFF 55%)` (dark: `rgba(50,215,75,.14) → #232327 60%`). HStack gap 20:
  - Power button 84 pt: circle, 8 pt ring `#28CD41` (dark `#32D74B`), white face (dark `#2A2A2E`), SF `power` glyph 25 pt in ring color, radial glow behind (green 28% → transparent, ~12 pt beyond). Tap = toggleConnection.
  - Status column: "Connected" 20 pt heavy; subtitle 12.5 pt secondary "Tunnel + HTTP proxy active · since 12:37"; chip row (gap 8, no wrap): chips = white fill, 1 px `#E4E4E7` border, radius 6, padding 4×9 → IP (11.5 pt semibold monospaced), "● 42 ms" (11.5 pt semibold, green `#1F9E38`), "Watchdog on" (secondary).
  - Right column (trailing): **Disconnect** button — red-tint style: fill `rgba(255,59,48,.10)` (dark `.16`), text `#E5372B` (dark `#FF6B60`) 13 pt semibold, radius 8, padding 7×22. Caption below "via fczm.site" 11 pt secondary.
  - Other states: **disconnected** (see dedicated frame) → neutral hero gradient `linear(120°, #F1F1F4 → #FFF 55%)`, gray ring `#D2D2D7` with secondary power glyph, no glow, title "Disconnected", subtitle "Traffic goes out directly", chips reduce to "Watchdog on", **Connect** = blue-tint button (`rgba(10,124,255,.12)` fill, `#0A7CFF` text); throughput shows "↓ 0 KB/s / ↑ 0 KB/s" with flat gray lines; latency shows "—" with all-gray bars + "not connected" footer; server latencies "—"; sidebar status card: gray dot, "Disconnected", "—". Connecting → sweeping arc (existing PowerToggle animation logic carries over).
- **Throughput tile**: caption THROUGHPUT; values row "↓ 1.2 MB/s" 15 pt bold `#0F7BF5`, "↑ 340 KB/s" `#28BD4B`; **mirrored bar chart** (iStat-style, bottom-anchored): dotted zero baseline through the middle (`#C9C9CE`, dark `#55555C`), thin bars ~2 pt wide with ~2 pt gap, 50–60 samples from SpeedMonitor — **up = green bars above the line** (`#28BD4B`, dark `#32D74B`), **down = blue bars below** (`#0F7BF5`, dark `#409CFF`). Swift Charts: two `BarMark` series, down values negated, `chartYScale` symmetric, baseline via dashed `RuleMark(y: 0)`. Disconnected: dotted baseline only, `#D2D2D7`.
- **Latency tile**: caption LATENCY; "42 ms" — number 24 pt heavy green, unit 13 pt secondary; below, a **history bar chart** in the same style as throughput (bottom-anchored): thin green bars ~2 pt wide (`#28BD4B`, dark `#32D74B`) rising from a dotted baseline at the bottom (`#C9C9CE`, dark `#55555C`), one bar per probe (~50 samples, occasional taller spikes); Swift Charts `BarMark` + dashed `RuleMark(y: 0)`. Footer "fczm.site · avg over 60 s" 11 pt secondary. Disconnected: "—" number, dotted baseline only (`#D2D2D7`), footer "not connected".
- **Server tile** (quick-switch): caption SERVER; one row per profile: radio (15 pt, accent when selected) + name 12.5 pt (semibold when selected) + trailing latency 10.5 pt (green for active); "+ Add server" 12 pt accent at bottom. Row tap = `controller.selectServer(id)`; disabled while connected/busy (match existing picker rule).
- **Options tile**: caption OPTIONS; below it 3 **button-cards** stacked with 7 pt gap, equal heights, radius 10, horizontal padding 12 — same style as the popover toggle cards: the whole card is the toggle, no switch control. ON: accent gradient fill `linear(180°, #4E96F7 → #3873F1)` (dark: `#0A84FF`), title 12 pt semibold white + state caption 9.5 pt white 85%. OFF: inset fill `#F5F5F7` (dark: white 5%), primary title + secondary caption. Cards: "Route Mac traffic" (On/Off; systemSocksOn intent binding), "Auto-reconnect" (caption "Watchdog · On/Off"), "Launch at login" (On/Off).

### Servers
- Header row: "Servers" 16 pt bold + trailing accent-filled button "＋ Add Server" (white text 12.5 pt semibold, radius 8, padding 6×14) → opens existing `ServerEditor` sheet.
- One tile per profile (full width, padding 14×16): radio 16 pt + name 13.5 pt semibold + caption 11 pt secondary "root@fczm.site:22 · Default keys / agent"; trailing: "● active · 42 ms" 10.5 pt green (active only, else latency gray), pencil + trash icon buttons 15 pt secondary. Active tile: 1.5 pt accent border.
- Dashed "add" tile: 1.5 pt dashed `#C9C9CE`, radius 16, centered "＋ Add an SSH server to connect through" 12.5 pt secondary. Footer hint 11 pt secondary: "Secrets are stored in the macOS Keychain — never in config.json…".

### Logs
- Header row: "Logs" 16 pt bold; trailing controls: filter field (white tile-style, radius 8, 220 pt, placeholder "Filter…"), "Auto-scroll" checkbox, "Clear" button (white tile-style with trash icon).
- Log tile fills remaining height: monospaced 11.5 pt, line-height 1.8, colors: info=primary, success=`#1F9E38`, warn=`#C77800`, error=red. (Existing `LogTailer` + severity mapping unchanged.)
- Status row below tile: green dot + "Streaming · N lines" 11 pt secondary; trailing log path 11 pt tertiary.

### Statistics
- Header row: "Statistics" 16 pt bold; trailing: segmented Today/Week/Month/All (native segmented picker) + "All servers" popup.
- 3 stat tiles (equal widths): captions DOWNLOADED / UPLOADED / TOTAL; values 21 pt heavy — blue `#0F7BF5`, green `#28BD4B`, primary.
- Chart tile: caption USAGE OVER TIME + trailing legend (Down blue / Up green, 7 pt square swatches, 11 pt). Plot ~110 pt: existing Swift Charts BarMarks, bar radius 4, dashed gridlines `#ECECEF`, solid baseline `#E4E4E7`; x labels 00–12, 10.5 pt tertiary.
- Sessions tile: header row caption SESSIONS + trailing "Export CSV" accent link with share icon (keeps `exportCSV()`); rows: green dot 8 + time 12 pt monospaced in HH:MM:SS, e.g. "12:50:00–…" (width ~126) + server 12 pt secondary + trailing "↓ x" blue / "↑ y" green 12 pt; hairline separators `#F2F2F4`; footer pinned: green dot + "Recording since Jul 15, 2026" 11 pt secondary.

### Settings (merged Tunnel + Advanced) — REAL-TIME, NO SAVE BUTTON
- Header row: "Settings" 16 pt bold + trailing caption "Changes apply immediately" 11 pt secondary.
- 2-column grid of tiles (gap 11), last tile spans both columns:
  - **PORTS**: rows "SOCKS Port" / "HTTP Proxy Port" with right-aligned bordered fields (monospaced 12 pt, min-width 48, radius 6, fill `#F5F5F7`, border `#E4E4E7`). Values 1080 / 8118.
  - **STARTUP**: "Launch at login" (on), "Auto-connect on launch" (off).
  - **MACOS**: "Network Service" popup (Wi-Fi), "Auto-reconnect (watchdog)" toggle, "Watchdog Interval (s)" field (15).
  - **MENU BAR**: "Show menu bar icon", "Show network speed".
  - **RUNTIME**: 3 dependency rows: green check disc 15 pt + name 12.5 pt + trailing detail 10.5 pt secondary/monospaced (privoxy (bundled)/included, ssh//usr/bin/ssh, curl//usr/bin/curl). Failure state: red x disc.
  - **STATISTICS**: "Record traffic statistics" toggle; caption 10.5 pt secondary ("Records byte volume over time — not the sites you visit. Stored locally only."); "Clear statistics…" 12 pt `#E5372B` (keeps confirmation dialog).
  - **FILES** (span 2): Config / Logs rows with monospaced 10.5 pt secondary paths + "Reveal in Finder" 12 pt accent.
- **Behavioral change**: delete the Save section and `saveMessage`. Persist on every change: toggles/pickers call `controller.saveConfig()` in their bindings' set (or a single `.onChange(of: controller.config) { controller.saveConfig() }`); numeric fields commit on `.onSubmit`/focus-loss with validation via existing `config.connectError` — surface the error as an inline orange caption under the offending tile. Keep `refreshStatus()` after network-service/port changes.

### Tools
- Header "Tools" 16 pt bold.
- **Claude Code tile**: title-toggle row "Route Claude Code through this proxy" 13.5 pt semibold + switch; caption 11 pt secondary (existing copy with `http://127.0.0.1:8118`); status line 11 pt green "Claude Code will use this proxy."; hairline; "Settings file" row with monospaced path + "Reveal" accent link.
- **System Proxies tile**: "Remove All Proxies" 13.5 pt semibold `#E5372B` + caption; trailing red-tint button "Remove…" (existing confirmation alert flow).
- Footer hint: "Requires admin rights — macOS prompts when toggling system proxies."

### Menu bar popover (310 pt wide, padding 12, bg `#F2F2F5`)
- Hero mini-tile (green gradient): power ring 46 pt (5 pt ring) + "Connected" 14 pt heavy + IP 11 pt monospaced secondary + trailing "● 42 ms" green. Tap ring = toggle.
- Two half-width tiles: SPEED (↓/↑ 12 pt bold blue/green) and SERVER (name 12 pt semibold + "Switch ▾" accent 10.5 pt → menu of profiles via `selectServer`).
- Toggle cards: **two half-width button-cards side by side** (equal widths, 8 pt gap, radius 12, padding 10×12). The whole card is the toggle — no switch control. ON: accent gradient fill `linear(180°, #4E96F7 → #3873F1)`, title 11.5 pt semibold white, state caption 10 pt white 85%. OFF: white card, primary title, secondary caption. Cards: "Route Mac traffic" (On/Off) and "Auto-reconnect" (caption "Watchdog · On/Off"). (Show network speed / Launch at login live in Settings only.)
- Disconnect: full-width red-tint pill (radius 10, 13 pt bold). Disconnected variant (see frame): gray hero (ring `#D2D2D7`, subtitle "Traffic goes out directly", no latency badge), SPEED zeros, "Route Mac traffic" card Off (white), **Connect** = full-width blue-tint pill (`rgba(10,124,255,.12)` / `#0A7CFF`).
- Footer: two rectangular buttons side by side (equal widths, radius 8, white card fill, padding 8 vertical, 12.5 pt semibold): **Open App** (accent text; opens the main window via `openWindow`) and **Quit** (secondary text; `NSApp.terminate`). No other footer links.

### Mini window (new, 300×~120)
- Always-on-top floating panel (`Window` scene, `.windowLevel(.floating)`, hidden titlebar, non-resizable), opened by ⌥-click on the menu bar icon (or a popover button).
- Hero-tile look: green gradient, radius 16; power ring 52 pt + "Connected" 14 pt heavy + IP monospaced + "42 ms" green; bottom row: two white-75% pills "↓ 1.2 MB/s" / "↑ 340 KB/s" + red-tint "Stop" pill.

## Interactions & Behavior
- Connect/disconnect: existing `controller.toggleConnection()`; connecting state reuses the sweep/breathing animation from `ConnectionTab.PowerToggle` (respect Reduce Motion).
- Sidebar selection = `WindowTab` SceneStorage (unchanged); popover/menu deep-links via `controller.requestedTab`.
- Server quick-switch disabled while `isBusy || isConnected` (matches current picker).
- Sparkline: 1 Hz samples, last 60; animate with `.animation(.linear(duration: 1))` on data change.
- Latency: ping active server every 10 s while connected (TCP connect time or `ssh -O check` RTT); color: green < 80 ms, orange < 200, red above; "—" when disconnected.
- Warning states (no servers / config error / privoxy missing): amber banner above the hero tile, copy unchanged from current app.
- Settings: real-time persistence as specified above; no Save anywhere.

## State Management
- Reuse `TunnelController` published state (`state`, `exitIP`, `watchdogEnabled`, `systemSocksOn`, `launchAtLogin`, `recordStats`, `config`, …).
- Add: `@Published var latencyMS: Int?`, `@Published var speedHistory: [SpeedSample]` (SpeedMonitor), mini-window scene id `"mini"`.
- No new persistence beyond existing `config.json` — real-time saves go through `saveConfig()`.

## Design Tokens
- Canvas: light `#F2F2F5` / dark `#151517`. Sidebar: `#E9E9EB` / `#232327` (or native sidebar material). Tile: `#FFFFFF` / `#232327` + border white 6%.
- Accent blue: `#0A7CFF` / `#0A84FF`. Data blue: `#0F7BF5` / `#409CFF`. Green (status/ring): `#28CD41` / `#32D74B`; data green `#28BD4B`; text green `#1F9E38`. Red: text `#E5372B` / `#FF6B60`; tint fill `rgba(255,59,48,.10/.16)`. Warning orange: `#C77800`.
- Text: primary `#1D1D1F` / `#F2F2F4`; secondary `#85858B` / `#9A9AA2`; tertiary `#B0B0B5`.
- Type scale (SF Pro): page title 16/700; hero status 20/800; stat value 21–24/800; body 13; row label 12.5; caption 11; tile caption 10.5/700 uppercase +0.6 tracking; data/mono = SF Mono 10.5–15.
- Radii: tile 16, chip/field 6–8, button pill 8–10, sidebar row 6. Tile shadow `0 1 3 rgba(0,0,0,.06)`.
- Spacing: content padding 16, grid gap 11–13, tile padding 13×16.
- Hero gradient: `linear-gradient(120°, #E4F8E9, #FFF 55%)`; dark `rgba(50,215,75,.14) → #232327 60%`.

## Assets
- `assets/app-icon.svg` — the app's real icon (copied from `tunnel-proxy/icon/icon.svg`); used in the sidebar header at 22 pt.
- All glyphs are SF Symbols in the app: `power`, `bolt.horizontal.circle`, `server.rack`, `doc.plaintext`, `chart.bar`, `gearshape`, `wrench.and.screwdriver`, `checkmark.circle.fill`, `xmark.circle.fill`, `square.and.arrow.up`, `pencil`, `trash`, `plus`, `chevron.up.chevron.down`.

## Files
- `Tunnel Proxy Redesign.dc.html` — open in a browser; implement the **2a** frames.
- `support.js` — runtime required by the HTML file (keep next to it).
- `assets/app-icon.svg` — app icon.
