# App Routing Lab

This standalone Xcode project starts Phase 1 of the [app routing plan](../../plan/app-routing-implementation.md). It contains a macOS 14+ SwiftUI host, a bundled transparent proxy system extension, and a desktop TCP/UDP test client.

The lab observes outbound flows to one synthetic IPv4 endpoint, by default `198.18.0.10:28443`. In observation mode, the provider returns every flow to the system. Its in-memory counters distinguish TCP and UDP, the probe's exact source signing identifier, and audit token presence on matching flows. The host checks the active session ID and rule version in each response. The provider stores counts only. The probe displays a random marker and whether the controlled server echoed it. Build 0.1/4 also provides a separate, explicitly selected Claude CONNECT relay experiment.

## Build and inspect locally

From this directory, with Xcode installed:

```sh
derived="$(mktemp -d /tmp/tunnelproxy-lab.XXXXXX)"
xcodebuild -project AppRoutingLab.xcodeproj -scheme AppRoutingLab \
  -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build

app="$derived/Build/Products/Debug/AppRoutingLab.app"
provider="$app/Contents/Library/SystemExtensions/com.xwkj.tunnelproxy.lab.proxy.systemextension"
plutil -extract NSSystemExtensionUsageDescription raw "$app/Contents/Info.plist"
plutil -extract NetworkExtension xml1 -o - "$provider/Contents/Info.plist"
```

The host and the embedded extension should each contain `NSSystemExtensionUsageDescription`. The provider plist should map `com.apple.networkextension.app-proxy` to `TransparentProxy.ProxyProvider`. The unsigned build leaves the Mach service name without a team prefix and serves as a compile and packaging check. The checked-in project builds directly in Xcode. If changing target declarations, edit `project.yml` and regenerate with XcodeGen.

## Signed isolated test setup

Use a disposable or approved test Mac and a separate controlled TCP/UDP echo service at `198.18.0.10:28443`. Give the test server an independently reachable lab-network address. Configure and verify the route on the isolated network before testing. Reserve the fixed IP and port exclusively for these tests.

Use the same development team for all three targets. The host (`com.xwkj.tunnelproxy.lab`) and provider (`com.xwkj.tunnelproxy.lab.proxy`) each need a provisioning profile with Network Extensions enabled. Enable the System Extension capability on the host so its profile allows `com.apple.developer.system-extension.install`. The provider's built `NEMachServiceName` should be `<TeamID>.com.xwkj.tunnelproxy.lab.proxy`, within the shared macOS app group `<TeamID>.com.xwkj.tunnelproxy.lab`. This macOS app group uses a team ID prefix and requires no portal registration. Sign RoutingProbe with the same team to give it a known source signing identifier. [Apple's deployment note](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) · [Apple DTS on the Mach service name](https://developer.apple.com/forums/thread/776759) · [Apple's app group guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)

**Debug with Apple Development.** Both entitlements use `app-proxy-provider`. After the team has authorized automatic provisioning, run the following from this directory with the team's account configured in Xcode. It can create or update the lab's app IDs and profiles and may manage development certificates. It assumes the test Mac is already registered for development. [Apple DTS on development and Developer ID signing](https://developer.apple.com/forums/thread/125508)

```sh
derived="$(mktemp -d /tmp/tunnelproxy-lab-development.XXXXXX)"
xcodebuild -project AppRoutingLab.xcodeproj -scheme AppRoutingLab \
  -configuration Debug -derivedDataPath "$derived" \
  DEVELOPMENT_TEAM=X92HAV9XYP CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

**Release with Developer ID Application.** Both entitlements use `app-proxy-provider-systemextension`. Create Developer ID provisioning profiles for the lab host and provider, import both into Xcode, and select each profile for its own Release target using manual signing. Keep the probe profile-free. Archive the lab, export it for Developer ID distribution with secure timestamps, and notarize the host and embedded extension before testing installation with normal macOS validation. Take the separately signed probe from the build products. [Apple's Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension) · [Apple's system extension requirements](https://developer.apple.com/documentation/systemextensions) · [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

For either signed configuration, set `app`, `provider` and `probe` to the signed bundle paths before verifying signatures and effective entitlements.

```sh
codesign --verify --deep --strict "$app"
codesign --verify --strict "$probe"
codesign -d --entitlements - --xml "$app"
codesign -d --entitlements - --xml "$provider"
codesign -dv --verbose=4 "$provider"
plutil -extract NetworkExtension xml1 -o - "$provider/Contents/Info.plist"
```

Inspect both embedded profiles in Xcode or decode their `Contents/embedded.provisionprofile` with `security cms -D -i`. Confirm the team, signing certificate, App ID, expiry and allowed entitlements match each bundle. Keep profiles out of the repository. [Apple's provisioning profile reference](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

On 2026-11-19, Developer ID signing reported both Developer ID profiles missing. Apple Development automatic provisioning initially returned `PLA Update available` for both targets. After the Account Holder accepted the updated agreement, rerunning the Debug build with `-allowProvisioningDeviceRegistration` registered the approved test Mac and provisioned both laboratory targets. Use the device-registration flag only when authorized to register the destination on the team. The finished Debug build passed signature and embedded-profile checks for both targets. [Apple's account access guidance](https://developer.apple.com/help/account/access/resolving-access-issues/)

## Check installation and synthetic flow attribution

1. From the approved test environment, launch RoutingProbe. With lab observation off, send one TCP and one UDP probe. Record the markers and successful echoes, and verify that the server saw the same markers and the expected source IP.
2. Place the signed AppRoutingLab in `/Applications` on the test Mac. Launch it and choose **Request extension approval**. Complete the approval in System Settings. The lab does not start observation upon approval. Choose **Start observation** explicitly, accept the macOS network configuration prompt if shown, then choose **Read provider** after the connection reports connected. Record the confirmed rule version and starting counters.
3. Send TCP and UDP probes one at a time. After each echo, choose **Read provider**. Compare the TCP/UDP deltas, probe signing-ID match and audit-token presence to the server's corresponding marker and source IP. For a contrast, send a synthetic request to the same endpoint from a second source and check the other-source counter. An echo proves reachability. Counter deltas show flow delivery to the provider. Audit token presence is metadata evidence and does not establish code identity validation or Helper ownership.
4. Choose **Stop and remove lab configuration**, then **Deactivate extension**. Verify the profile and extension state in System Settings and `systemextensionsctl list`. Repeat the probe baseline and confirm the independent network path still works. If a request reports that completion requires a reboot, record the observed state again after the reboot.

Keep the OS build, CPU architecture, host/provider signing IDs, rule version, timestamps, protocol, counter deltas and synthetic server observations with the result. On macOS 27.0.1 (26A434), unsigned Debug built on arm64 and unsigned Release archived with an arm64/x86_64 host and embedded provider. The standalone RoutingProbe passed strict signature verification under team `X92HAV9XYP` with both Apple Development and Developer ID Application.

The signed Apple Development build opened from `/Applications`. Its first activation exposed the missing usage description on the provider bundle. After adding it, the macOS system extension service reported `activated waiting for user`. After the user allowed the lab network extension, `systemextensionsctl list` reported `activated enabled` for provider `com.xwkj.tunnelproxy.lab.proxy` version `0.1/1`. On starting observation, `nesessionmanager` recorded the provider process start and a connected lab session. The host's **Read provider** action confirmed rule version 1 and returned a zero baseline for TCP, UDP, matching signing identifier, audit token and other-source counters.

These are first-install and provider-handshake results on the current Mac. The wider V1 matrix and V2 real-app attribution and egress still require validation.

## Check a local-only echo service

If an independently reachable test host is unavailable, a disposable echo service bound to a high loopback port can verify the probe's echo handling. The lab and probe both accept `--loopback-port=<port>` for ports 49152–65535. Launch both while they are closed so that each receives the same argument.

```sh
open /Applications/AppRoutingLab.app --args --loopback-port=54843
open "$probe" --args --loopback-port=54843
```

For each TCP and UDP request, match the probe marker to the server log. When observation is on, separately check the provider's counter deltas. A loopback connection can succeed even if macOS does not deliver the flow to the provider. Docker Desktop's loopback port publication forwards the connection into its Linux VM. The container logs the forwarding peer and does not establish a separate host route or external egress. [Docker Desktop networking](https://docs.docker.com/desktop/features/networking/)

On 2026-11-19, the signed 0.1/2 build replaced 0.1/1 on the same Mac. Before the upgrade, the active version 1 rule covered only `198.18.0.10:28443`. The signed probe sent one TCP and one UDP marker to the loopback endpoint outside that rule. Both echoes matched the Docker log. After the upgrade, the system reported 0.1/2 enabled and left the prior build terminated pending removal on a future reboot. The host started a new observation session for `127.0.0.1:54843`, confirmed rule version 2, and read a zero baseline.

| Active observation | Matching echo marker | Cumulative TCP / UDP | Probe signing ID / audit token | Other source |
| --- | --- | --- | --- | --- |
| RoutingProbe TCP | `FEA4F8B0-D4F9-496F-B766-C8122F2A6688` | 1 / 0 | 1 / 1 | 0 |
| RoutingProbe UDP | `E8976C6D-3EDA-4908-B6A0-798190302F1C` | 1 / 1 | 2 / 2 | 0 |
| Separate Python TCP and UDP | `c8539874-f725-48ad-95ea-d56ef4a2e145`, `d202ffb1-8be4-40c6-aa02-8bdb3a2f85a4` | 2 / 2 | 2 / 2 | 2 |

The container recorded every marker from its Docker forwarding peer. The provider counted both observed protocols, distinguished the signed probe from the Python process, and returned all flows to macOS. The signing-ID match and audit-token presence are metadata observations. V2 still requires attribution for real applications and independent egress evidence.

After stopping and removing the lab configuration, both protocols still echoed and the server recorded the new markers. The temporary container and network were removed. The approved lab extension remains installed and idle.

## Installed Claude path check

On 2026-11-19, the installed Claude desktop app reported version and build `6.6395.1` and passed a strict signature check. The main executable used signing identifier `com.anthropic.claudefordesktop`. Its Chromium Helper bundles shared `com.anthropic.claudefordesktop.helper` under team `Q6L2SF6YDW`. Chromium's NetworkService, Renderer, GPU, Node, Audio and VideoCapture roles therefore require process or executable evidence in addition to their signing identifier. The embedded disclaimer and crash reporter use separate signing identifiers under the same team.

During a user-confirmed open-existing-conversation window, the Chromium `network.mojom.NetworkService` Helper had byte activity on existing TCP sockets and another TCP socket appeared. The observed endpoints were on `lo0` with peer `127.0.0.1:7890`. The observation followed socket metadata only and establishes timing correlation. No matching socket to TunnelProxy's Privoxy port 8118 or SSH SOCKS port 1080 was observed for the monitored process IDs. Other Claude components showed no socket activity in this check. Claude started under a different process ID at 12:47:56 JST, before the isolated test runs. The original short monitor did not follow that process change.

Independent synthetic requests to two public IP-check endpoints succeeded via both the current HTTP proxy on 7890 and the verified SSH SOCKS listener on 1080. The two paths reported different public egress addresses. These were diagnostic requests from a separate process.

The empty-profile Claude runs under an outer sandbox stopped when Chromium child processes failed to initialize their own sandboxes. A subsequent run kept Chromium's normal sandbox and used a temporary home, user-data directory, and a process-only `--proxy-server=socks5://127.0.0.1:1080`. The new process opened files in its own profile and no open handles under the regular home were observed. In the startup window, 16 NetworkService TCP sockets paired with sockets owned by the SSH listener and carried bytes in both directions. The temporary Claude main process independently used port 7890 on one TCP connection. The user's running Claude session and system settings were left alone.

The signed 0.1/3 lab build checks Claude claims against the flow's audit token and a code-signing requirement for the corresponding main or Helper identity. The installed binaries matched their respective requirements in a static check. Swapping the requirements and testing the separately signed RoutingProbe produced rejections. [Apple's flow audit token API](https://developer.apple.com/documentation/networkextension/neflowmetadata/sourceappaudittoken) · [Apple's dynamic code validation API](https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:))

The upgrade to 0.1/3 reached `activated enabled`. After macOS saved the approved proxy configuration, the host confirmed rule version 3 and read all zero counters for `127.0.0.1:54843`. Two empty-profile Claude instances were then run in sequence with an explicit, process-only SOCKS setting pointing at a disposable loopback bridge. The bridge forwarded SOCKS to the verified SSH listener on 1080. It counted negotiation outcomes and bytes and recorded local socket ports for pairing.

| Startup run | Provider TCP flows with verified Claude Helper identity | Bridge SOCKS CONNECT successes with bidirectional bytes | Complete Claude → bridge → SSH socket joins |
| --- | --- | --- | --- |
| First | 16 | 15 | Partial process-side sampling |
| Repeat | 19 | 18 | 15 |

Across the two runs, the provider reported 35 verified Helper flows and zero UDP, main, unverified and other-source flows. Process-role metadata identified the sampled client sockets as Chromium's NetworkService. The provider reports an aggregate for the shared Helper signing identifier. Its count exceeded the bridge's successful CONNECT count by one in each run. The first run also ended early when its socket reporter encountered an empty counter field. The repeat used socket pairing and the bridge's separate counts.

The negative control sent one `curl` request through the same bridge. The bridge recorded one successful CONNECT and bidirectional transfer. The provider counters rose to TCP 36 and other source 1. Verified Helper stayed at 35 and all remaining counters stayed at zero.

The experiment proves dynamic Claude Helper identity verification on this Mac and a matched SSH path for the explicitly configured test connections. The provider returned every flow to macOS. Product-level transparent SSH forwarding and logged-in Claude coverage remain untested.

The lab network configuration was removed after the test, and macOS reported the session disconnected. The approved 0.1/3 extension remains installed and idle. The bridge and temporary Claude processes stopped, and their profiles were removed. The system proxy snapshot, VPN route interface and production Privoxy/SSH listeners matched the pre-test checks.

## Scoped Claude transparent CONNECT relay

Build 0.1/4 uses a separate TCP-only mode for `127.0.0.1:7890`, the existing HTTP(S) proxy port on the approved test Mac. The lab host arguments `--relay-claude-pid=<pid>` and `--relay-ssh-pid=<pid>` pin both processes by PID and kernel process start time. The provider checks Claude's audit-token-backed signature and its ancestry under the pinned root before accepting a flow. Other flows return to macOS without recording their destinations or reading their data. Ordinary loopback policy is outside this experiment. [Apple's transparent proxy behavior](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider)

The relay accepts HTTP/1.0 and HTTP/1.1 CONNECT to `claude.ai`, `claude.com`, `anthropic.com` or their subdomains on port 443. It extracts only CONNECT request-line metadata and discards the remaining proxy headers. Before sending the CONNECT authority as a SOCKS5 request, it checks the accepted reverse socket tuple in the pinned SSH process. The relay sends HTTP 200 only after SSH SOCKS reports success. It copies subsequent bytes unchanged with bounded buffers and timeouts. Unsupported traffic and relay failures close within the selected tree. Ordinary HTTP forwarding, literal IP destinations, and other domain names or ports are outside this experiment.

The isolated Claude root was spawned suspended, pinned to the rule and resumed after the zero baseline. It had a separate empty profile and kept its normal Chromium sandbox. Claude used the existing system proxy settings without a process-specific proxy argument, environment variable or PAC. The provider admitted 1 verified main-process TCP flow and 18 verified Helper TCP flows. SSH SOCKS succeeded for 1 main flow and 10 Helper flows. Both directions transferred data for 1 main flow and 9 Helper flows. The provider reported 8 unsupported flows and 2 failures. A separate same-port `curl` sent through the original HTTP proxy succeeded. Its interval overlaps the completion of previously admitted Claude flows, so the run does not provide an isolated no-increment comparison. The temporary profile was confirmed by open-file metadata. Independent socket sampling outside the provider did not obtain additional provider-to-SSH tuples.

For the logged-in test, the user kept the existing Claude process and used a new conversation. After the rule version 4 zero baseline, a `curl` request through the same `7890` port succeeded with all provider counters still at zero. The user then sent the agreed test prompt and confirmed receiving a reply. The provider recorded 5 new verified Helper TCP flows, including 2 with successful SSH SOCKS CONNECT and bidirectional data, and 3 unsupported flows. It recorded zero new main-process flows and zero relay failures in this window.

Before enabling the rule, the logged-in NetworkService already had 3 established TCP connections to `7890`. All 3 remained active and carried more bytes during the two-minute sample from 16:57:39 to 16:59:38 JST. Two newly observed socket entries lacked byte values. The existing TCP connections were outside the new-flow relay. The reply and metadata share the test window, so this evidence cannot identify the route of the individual prompt or reply. The main process had a verified relay in the isolated startup run, with no corresponding new main flow in the logged-in run.

The lab network configuration was removed after each run. The 0.1/4 extension remains approved and idle. The temporary Claude process and profile were removed, and the logged-in process stayed running. System proxy settings, the VPN route interface, and the official Privoxy and SSH listener processes matched the pre-test checks.

### Logged-in cold-start reply diagnostic

Build 0.1/5 retains the same relay scope and adds fixed diagnostic categories. The provider counts open SSH relays and post-CONNECT bytes successfully copied in each direction for the desktop main and Helper identities. It reports unsupported protocol, method, CONNECT version or authority, port, domain scope and header size, as well as failure stage. It neither saves nor reports domains, request URIs, proxy headers, or payloads. Diagnostic categories in build 5 cannot recover the reasons for build 4's three earlier rejected flows.

The user quit the logged-in app through its normal UI. The previous process tree and its three old proxy sockets were gone. For both subsequent starts, Claude's signed executable was suspended with the existing login profile, with no proxy arguments or overrides. Each new process had no sockets while suspended. The host confirmed rule version 5 and an all-zero provider baseline before that process resumed.

The first fresh root disappeared about 24 seconds after resume. It had no matching crash report, replacement process, app version change, or explicit exit signal in the inspected system records. The launcher had already exited and had not isolated Claude's process group. The retry used a separate process group and held the launcher through the action window. The second root remained running after the launcher's release. The user later confirmed both test replies. The first window recorded only 35 additional bytes toward SSH and zero additional bytes from SSH after the message checkpoint. Its early process exit prevents attributing the first reply to the pinned relay.

The second test's message-window readings were:

| Scope | Before | After | Change |
| --- | ---: | ---: | ---: |
| Helper flows admitted | 29 | 40 | 11 |
| Helper SOCKS CONNECT successes | 10 | 12 | 2 |
| Helper flows carrying bytes both ways | 10 | 12 | 2 |
| Helper relay bytes sent | 794,073 | 1,099,648 | 305,575 |
| Helper relay bytes received | 434,389 | 1,522,220 | 1,087,831 |
| Main relay bytes sent / received | 1,977 / 5,201 | 2,001 / 5,201 | 24 / 0 |
| Rejected outside domain scope | 15 | 24 | 9 |
| Rejected ordinary HTTP methods | 3 | 3 | 0 |

One main flow had already connected and transferred both ways before the message checkpoint. Main/Helper open relays changed from 1/7 to 0/5, so new CONNECT totals alone do not describe all traffic in the window. The final failure counters were one opening the client flow and six reading client payload, including three client-read failures added during the action window. The first, aborted startup had seven domain-scope rejections before its message checkpoint.

The whole-tree observer refreshed the descendant list on each TCP/UDP metadata sample. In the second action window, two selected-tree TCP connections owned by processes outside the app bundle had exact accepted reverse socket tuples on the original system HTTP proxy at `7890`. Separate byte-counter samples showed activity for this class. A post-action check paired two still-active sockets and verified the binaries' signing requirement as `com.anthropic.claude-code` under Team `Q6L2SF6YDW`. That signing identifier is outside build 5's relay selection. The sample also saw an unconnected Helper UDP socket and no non-loopback first hop. Sampling does not cover every short-lived socket, datagram, or system service acting on the app's behalf.

The second window therefore proves both transparent SSH relay activity and actual original-proxy traffic from the selected tree. The encrypted byte counts and reply confirmation cannot identify which path carried an individual message or reply. Both experimental configurations were removed. The second logged-in Claude process stayed running, the observers stopped, and build 5 remains approved and idle. The system proxy snapshot, existing VPN route interface, and official Privoxy and SSH listener process IDs matched the pre-test values.
