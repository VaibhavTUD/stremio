#!/usr/bin/env bash
# Download the latest StremioTV IPA, renew the free 7-day profile, re-sign and install on the Apple TV.
#
# Required env (set in the LaunchAgent or exported before running):
#   STREMIOTV_DEVICE   devicectl identifier of the Apple TV
# Optional:
#   STREMIOTV_BUNDLE_ID (default com.vaibhavtud.stremiotv)
#   STREMIOTV_PLACEHOLDER (default ~/stremio-tv-signer/placeholder)
#   STREMIOTV_RELEASE_BASE (default https://github.com/VaibhavTUD/stremio/releases/latest/download)
set -Eeuo pipefail

BUNDLE_ID="${STREMIOTV_BUNDLE_ID:-com.vaibhavtud.stremiotv}"
PLACEHOLDER="${STREMIOTV_PLACEHOLDER:-$HOME/stremio-tv-signer/placeholder}"
RELEASE_BASE="${STREMIOTV_RELEASE_BASE:-https://github.com/VaibhavTUD/stremio/releases/latest/download}"
DEVICE="${STREMIOTV_DEVICE:?set STREMIOTV_DEVICE to the Apple TV identifier from: xcrun devicectl list devices}"
ASSET="StremioTV.ipa"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: command failed at line $LINENO"' ERR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stremiotv.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
log "work dir $WORK"

# 1. Download and verify the IPA.
curl -fsSL --retry 3 -o "$WORK/$ASSET" "$RELEASE_BASE/$ASSET"
curl -fsSL --retry 3 -o "$WORK/SHA256SUMS.txt" "$RELEASE_BASE/SHA256SUMS.txt"
(cd "$WORK" && shasum -a 256 --check --status SHA256SUMS.txt) || die "SHA-256 mismatch for $ASSET"
log "downloaded and verified $ASSET"

# 2. Renew the provisioning profile by building the placeholder for the TV.
[ -d "$PLACEHOLDER/Placeholder.xcodeproj" ] || die "placeholder project missing at $PLACEHOLDER"
log "renewing provisioning profile"
xcodebuild -project "$PLACEHOLDER/Placeholder.xcodeproj" -scheme Placeholder \
  -destination "generic/platform=tvOS" -derivedDataPath "$WORK/dd" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet \
  > "$WORK/xcodebuild.log" 2>&1 || { tail -30 "$WORK/xcodebuild.log"; die "placeholder build failed"; }

# 3. Pick the newest valid tvOS profile for the bundle ID.
profile=""; newest=0
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.mobileprovision; do
    [ -f "$f" ] || continue
    security cms -D -i "$f" > "$WORK/p.plist" 2>/dev/null || continue
    appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/p.plist" 2>/dev/null || true)"
    [[ "$appid" == *".$BUNDLE_ID" ]] || continue
    /usr/libexec/PlistBuddy -c 'Print :Platform' "$WORK/p.plist" 2>/dev/null | grep -q tvOS || continue
    exp="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$WORK/p.plist")"
    exp_s="$(date -j -f '%a %b %d %H:%M:%S %Z %Y' "$exp" '+%s')"
    [ "$exp_s" -gt "$(date '+%s')" ] || continue
    if [ "$exp_s" -gt "$newest" ]; then newest="$exp_s"; profile="$f"; fi
  done
done
[ -n "$profile" ] || die "no valid tvOS profile for $BUNDLE_ID"
security cms -D -i "$profile" > "$WORK/profile.plist"
team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
log "profile $(basename "$profile") team $team expires $(date -r "$newest" '+%Y-%m-%d')"

identity=""
while read -r hash name; do
  subject="$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
  if [[ "$subject" == *"OU=$team"* ]] || [[ "$subject" == *"OU = $team"* ]]; then identity="$hash"; identity_name="$name"; break; fi
done < <(security find-identity -v -p codesigning | grep -F 'Apple Development' | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) "([^"]+)".*/\1 \2/')
[ -n "$identity" ] || die "no Apple Development identity for team $team"
log "identity $identity_name"

# 4. Unpack, strip, re-sign.
unzip -q "$WORK/$ASSET" -d "$WORK/ipa"
app="$(find "$WORK/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || die "no .app in IPA"
rm -rf "$app/PlugIns"
find "$app" -name _CodeSignature -type d -prune -exec rm -rf {} +
find "$app" -name embedded.mobileprovision -delete
cp "$profile" "$app/embedded.mobileprovision"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$app/Info.plist"

# Entitlements come from the profile only, so nothing the free profile does not grant survives.
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"
for key in com.apple.developer.kernel.increased-memory-limit com.apple.security.application-groups; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$WORK/entitlements.plist" 2>/dev/null || true
done

while IFS= read -r -d '' item; do
  codesign --force --sign "$identity" --timestamp=none "$item" > /dev/null 2>&1 || die "codesign failed for $item"
done < <(find "$app/Frameworks" \( -name '*.framework' -o -name '*.dylib' \) -prune -print0 2>/dev/null)
codesign --force --sign "$identity" --timestamp=none --entitlements "$WORK/entitlements.plist" "$app" \
  || die "codesign failed for app"
codesign --verify --deep --strict "$app" || die "signature verification failed"
log "re-signed $(basename "$app")"

# 5. Install.
xcrun devicectl device install app --device "$DEVICE" "$app" > "$WORK/install.log" 2>&1 \
  || { cat "$WORK/install.log"; die "install failed"; }
log "installed $BUNDLE_ID on $DEVICE"
