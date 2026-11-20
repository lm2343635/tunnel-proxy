---
name: release
description: Sign, package, and notarize TunnelProxy macOS releases. Use for /release X.Y.Z, $release X.Y.Z, or requests to resume a TunnelProxy release.
---

# Release

- In the TunnelProxy repo, `/release X.Y.Z` or `$release X.Y.Z` is explicit authorization to sign, package, and submit a new build of that version to Apple. Run `./release.sh X.Y.Z` from the repository root. Apply any limits stated in the same request. Discussion, version checks, and script development carry no upload authorization.
- Show the current source commit and working tree status before running. The script uses the current checkout and applies the requested version and a new build number to both Xcode targets. Every new invocation allocates a build number, even for the same version.
- When asked to continue a release, find the intended build in `build/release-runs/*/release.json` and run `./release.sh --resume BUILD`. If several builds match and the intended one is unclear, ask which build. Before a signed DMG exists, resume packages the current checkout under the reserved number. After packaging, it uses the saved DMG and resumes the existing Apple submission. An upload attempt with an unknown result requires checking Apple history before using `--submission-id UUID` or `--retry-submit`. Apple rejection details are retained in `notary-log.json`.
- Use the `TunnelProxyNotary` Keychain profile or a user-supplied `NOTARY_PROFILE`. If initial setup is needed, the user can run `xcrun notarytool store-credentials TunnelProxyNotary --apple-id "<Apple ID>" --team-id X92HAV9XYP` and enter the app-specific password at the secure prompt. Keep secrets out of chat, command arguments, and repository files.
- Report the version, Build, absolute DMG path, Apple submission ID, and verification result. If interrupted, report the saved Build and the stage that needs recovery. Installation and distribution require their own instruction.
