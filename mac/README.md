# Mac re-signing for the Apple TV

Daily launchd job on a Mac that downloads the newest `StremioTV.ipa` from this fork's releases,
renews the free 7-day provisioning profile, re-signs the app and installs it on the Apple TV over
Wi-Fi. Background and the Linux attempts that led here: `docs/apple-tv/setup-log.md`.

## One-time setup

1. Xcode with tvOS platform support (`xcodebuild -downloadPlatform tvOS`), signed in to the
   Apple ID under Xcode > Settings > Accounts, and `brew install xcodegen`.
2. Pair the Apple TV in Xcode > Window > Devices and Simulators. Note its identifier from
   `xcrun devicectl list devices`.
3. Create the placeholder project that owns the profile:

   ```sh
   mkdir -p ~/stremio-tv-signer && cp -R mac/placeholder ~/stremio-tv-signer/
   cp mac/resign-and-install.sh ~/stremio-tv-signer/
   cd ~/stremio-tv-signer/placeholder
   STREMIOTV_TEAM_ID=<your team id> xcodegen generate
   xcodebuild -scheme Placeholder -destination generic/platform=tvOS \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

   The team ID is shown in Xcode after choosing your Personal Team under Signing & Capabilities,
   or in the generated `project.pbxproj` as `DEVELOPMENT_TEAM`.
4. Run it once by hand and check the app opens on the TV:

   ```sh
   STREMIOTV_DEVICE=<identifier> ~/stremio-tv-signer/resign-and-install.sh
   ```

5. Install the LaunchAgent (daily at 10:00 and at login):

   ```sh
   sed -e "s#/Users/USERNAME#$HOME#g" -e "s/APPLE-TV-IDENTIFIER/<identifier>/" \
     mac/com.vaibhavtud.stremiotv.resign.plist > ~/Library/LaunchAgents/com.vaibhavtud.stremiotv.resign.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vaibhavtud.stremiotv.resign.plist
   launchctl kickstart -k gui/$(id -u)/com.vaibhavtud.stremiotv.resign
   tail -f ~/Library/Logs/stremiotv-resign.log
   ```

## What the script does

Verifies the IPA against `SHA256SUMS.txt`, rebuilds the placeholder so Xcode renews the profile,
picks the newest valid tvOS profile for `com.vaibhavtud.stremiotv`, strips `PlugIns/` (the Top
Shelf extension would need its own profile) and all old signatures, signs every framework then the
app with the entitlements the profile actually grants, verifies, and installs with `devicectl`.

## Keeping it working

- The Mac must be awake, logged in and on the same Wi-Fi as the Apple TV at least once every
  6 days. `sudo pmset repeat wakeorpoweron MTWRFSU 09:55:00` schedules a daily wake.
- Turn off automatic tvOS updates on the Apple TV; an update can break pairing.
- Nothing here contains a team ID, certificate, profile or password. Keep it that way.
