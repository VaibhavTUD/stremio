# Stremio on Apple TV: setup log

Reference record of what was built, what was tried, and where things stand. Dates are 2026-11-03.

## Goal

Stremio (VortX fork) on the Apple TV, permanently, at zero cost, re-signed automatically before the
7-day free Apple ID limit, with new releases reaching the TV without manual work.

## Phase 1: IPA pipeline (done, working)

The plan said to build the IPA from source in CI. That is not possible: the VortX engine lives in a
private repository (`VortXTV/vortx-core`) that upstream CI fetches with a secret token. A build from
this fork can only link a CI stub engine that does not work at runtime.

Instead, the fork mirrors the official upstream IPA:

| Item | Value |
| --- | --- |
| Workflow | `.github/workflows/mirror-tvos-ipa.yml` |
| Rebundle script | `scripts/rebundle-tvos-ipa.py` |
| Bundle ID (never change) | `com.vaibhavtud.stremiotv` (Top Shelf: `com.vaibhavtud.stremiotv.topshelf`) |
| Release tags | `tv-<upstream tag>`, e.g. `tv-v0.5.6-beta.11` |
| Stable download URL | `https://github.com/VaibhavTUD/stremio/releases/latest/download/StremioTV.ipa` |
| Checksum file | `https://github.com/VaibhavTUD/stremio/releases/latest/download/SHA256SUMS.txt` |
| Triggers | daily at 03:17 UTC, a pushed `tv-v*` tag, or manual run in the Actions tab |
| Betas | only if repo variable `MIRROR_PRERELEASES=true` (upstream currently ships 0.5.6 beta 11 as its normal release) |

First run verified: SHA-256 matched, app ID `com.vaibhavtud.stremiotv`, tvOS, minimum tvOS 18.0.

Limitation: no code changes to the app are possible until we have access to the private engine.

## Phase 2: Linux server (done)

One-command setup, committed as `server/atvloadly-setup.sh`:

```
curl -fsSL https://raw.githubusercontent.com/VaibhavTUD/stremio/main/server/atvloadly-setup.sh | sudo bash
```

It installs Avahi and Docker, runs atvloadly on port 5533 with `--restart=always`, keeps data in
`/srv/atvloadly`, and adds a daily systemd timer (`atvloadly-update.timer`) that recreates the
container only when a newer image exists. Log: `journalctl -u atvloadly-update`.

## Phase 3: pairing and Apple ID sign-in

| Step | Result |
| --- | --- |
| Pairing over Tailscale | Failed: "Pairing port not found". Apple TV pairing uses Bonjour (mDNS), which does not cross Tailscale. |
| Pairing on the local network | Worked after turning off Tailscale on the Apple TV. Check: `avahi-browse -art \| grep -iE "remotepairing\|mobdev"` |
| Sign-in with a phone number | Failed. Use the Apple ID email address. |
| Sign-in with email (atvloadly v0.8.2) | Failed: SRP error -23782 "A Mac with macOS 10.13 or later is required". |
| tvsign (`/opt/tvsign`, port 8765) | Same -23782. Every public anisette server announces Mac OS X 10.12.6, which Apple now rejects. |
| Self-hosted anisette (`dadoum/anisette-v3-server`, port 6969) | Announces macOS 13.1, so -23782 is gone. Apple then answered HTTP 503: the account is temporarily refused after many attempts. |

Conclusion: everything works except Apple accepting a developer sign-in from the Linux server. Other
sideloading tools (AltStore issue #1852) hit the same -23782 regression.

### tvsign settings in use

`/opt/tvsign/docker-compose.override.yml`:

```
services:
  tvsign:
    environment:
      TVSIGN_ANISETTE_URL: http://127.0.0.1:6969
      TVSIGN_ANISETTE_FALLBACK: "off"
```

Self-hosted anisette container:

```
sudo docker run -d --name anisette --restart=always -p 127.0.0.1:6969:6969 \
  -v anisette_v3:/home/Alcoholic/.config/anisette-v3/lib/ dadoum/anisette-v3-server:latest
```

## Decision: sign on the Mac instead

A real Mac signs in to Apple natively, so the Linux sign-in problem does not apply. A daily launchd
job on the MacBook downloads the latest IPA, renews the free 7-day profile, re-signs, and installs on
the Apple TV over Wi-Fi. Prompt for Claude on the Mac: `docs/apple-tv/mac-signing-prompt.md`.

Limits: the MacBook must be awake, on the same Wi-Fi as the Apple TV, and logged in at least once
every 6 days. Do not sign in to the Apple ID for about a day after the HTTP 503 block.

## Server cleanup once the Mac route works (optional)

```
sudo systemctl disable --now atvloadly-update.timer
sudo docker rm -f atvloadly anisette
cd /opt/tvsign && sudo docker compose down
```

## Open items

1. Turn off automatic tvOS updates on the Apple TV (Settings > System > Software Updates); an update can break pairing.
2. Upstream workflows (Engine Leak Guard, Release apps, CodeQL and others) also run in this fork and mostly fail without upstream secrets. Disable them in the Actions tab if the noise bothers you.
3. If Stremio Lite is ever back on the tvOS App Store, that replaces all of this.
4. Paid fallback: an Apple Developer account ($99/year) gives a 1-year certificate that atvloadly or tvsign can import, with no Apple ID sign-in.
