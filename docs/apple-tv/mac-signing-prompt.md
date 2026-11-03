You are helping me set up automatic re-signing of a sideloaded tvOS app from my MacBook. Work in small steps, run commands yourself, and stop to ask me only when a step needs my hands (Apple ID sign-in, 2FA, the Apple TV remote, sudo). Reply concisely.

## Context

- Repo: https://github.com/VaibhavTUD/stremio (my fork of VortX, a native tvOS Stremio client). Read `docs/apple-tv/setup-log.md` there first for full background.
- The repo's CI publishes an unsigned tvOS IPA with my bundle ID every day:
  - IPA: https://github.com/VaibhavTUD/stremio/releases/latest/download/StremioTV.ipa
  - Checksum: https://github.com/VaibhavTUD/stremio/releases/latest/download/SHA256SUMS.txt
  - App: `Payload/VortXTV.app`, bundle ID `com.vaibhavtud.stremiotv`, minimum tvOS 18.0. It contains `PlugIns/VortXTopShelf.appex` (`com.vaibhavtud.stremiotv.topshelf`) and many frameworks under `Frameworks/`.
- I use a free Apple ID (personal team), so the provisioning profile lasts 7 days. Signing from my Linux server failed because Apple rejects the emulated sign-in, so signing must now happen on this Mac with Xcode's native sign-in.
- The Apple TV and the Mac are on the same home Wi-Fi.

## Goal

A launchd job on this Mac that runs daily and, with no manual steps:
1. downloads the latest IPA and verifies its SHA-256,
2. renews the free provisioning profile for `com.vaibhavtud.stremiotv`,
3. re-signs the app (and every framework inside it) with my Apple Development certificate and that profile,
4. installs it on the Apple TV over the network,
5. logs to `~/Library/Logs/stremiotv-resign.log` and exits non-zero on failure.

## Steps

1. Check prerequisites: macOS version, Xcode installed (if not, tell me to install it from the App Store), tvOS platform support (Xcode > Settings > Components), `xcode-select -p`, Homebrew. Install `xcodegen` with Homebrew if needed.
2. Ask me to sign in to my Apple ID in Xcode > Settings > Accounts. If Apple shows an error, stop and tell me; do NOT retry sign-ins repeatedly (the account was rate-limited recently).
3. Pair the Apple TV: tell me to open Settings > Remotes and Devices > Remote App and Devices on the TV, then pair it in Xcode > Window > Devices and Simulators and enter the PIN. Confirm with `xcrun devicectl list devices` and record the TV's identifier.
4. Create a placeholder tvOS app project in `~/stremio-tv-signer/placeholder` (xcodegen is fine) with bundle ID `com.vaibhavtud.stremiotv`, my personal team, automatic signing, deployment target tvOS 18.0. Build it once for the Apple TV with `xcodebuild ... -allowProvisioningUpdates -allowProvisioningDeviceRegistration` so Xcode registers the TV and creates the profile. Find the profile (`~/Library/Developer/Xcode/UserData/Provisioning Profiles` or `~/Library/MobileDevice/Provisioning Profiles`) and check it with `security cms -D -i`.
5. Write `~/stremio-tv-signer/resign-and-install.sh` that does the Goal steps:
   - Rebuild the placeholder with `-allowProvisioningUpdates` to renew the profile, then pick the newest valid profile whose application identifier ends in `com.vaibhavtud.stremiotv` and whose platform is tvOS.
   - Unzip the IPA to a temp dir. Remove `PlugIns/` (the Top Shelf extension is cosmetic and would need a second profile; keep it simple), every `_CodeSignature`, and any old `embedded.mobileprovision`.
   - Copy the profile in as `embedded.mobileprovision`. Build the entitlements from the profile's `Entitlements` dictionary (drop anything the profile does not grant, such as app groups or the increased-memory-limit entitlement).
   - `codesign --force --sign <Apple Development identity>` every framework/dylib first, then the app with `--entitlements`. Verify with `codesign --verify --deep --strict`.
   - Install with `xcrun devicectl device install app --device <TV id> <path to VortXTV.app>`.
   - Use `set -euo pipefail`, temp dirs cleaned with a trap, and clear log lines.
6. Run the script once by hand. Ask me to confirm the app opens on the TV, that I can log in to Stremio, and that a stream plays.
7. Install a LaunchAgent `~/Library/LaunchAgents/com.vaibhavtud.stremiotv.resign.plist` that runs the script daily at 10:00 and at login (RunAtLoad), with stdout/stderr to the log file. Load it with `launchctl bootstrap gui/$(id -u) ...` and trigger it once with `launchctl kickstart` to prove it works.
8. Tell me what keeps it reliable: the Mac must be awake and on the same Wi-Fi at least once every 6 days; optionally suggest a `pmset` wake schedule (ask before using sudo).
9. Copy the script, the LaunchAgent plist and the placeholder's xcodegen spec into the repo under `mac/` (no secrets, no team ID hard-coded: read it from the profile), commit on a branch named `feat/mac-resign`, push, and tell me.

## Rules

- Never store or print my Apple ID password. Never commit certificates, profiles or team IDs.
- Do not change the bundle ID.
- If something fails twice the same way, stop and explain the error instead of trying variations.
