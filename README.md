# Timely

Screen time tracking across Android, Linux and Windows, with one shared dashboard.

I wanted to see how much time I actually spend on screens, all of them, not just on my phone. Digital Wellbeing only knows about the phone, and the desktop trackers I tried either cost money, sent my data somewhere I didn't control, or didn't work on Wayland. Timely runs a small collector on every device, syncs to a backend you host yourself on Cloudflare's free tier, and shows everything in a single dashboard on every device.

## Features

- **Focused-app screen time.** Only the app you actually have in front of you counts.
- **Listening time.** Music or a podcast playing in the background (Spotify with the screen off, a video in another window) is tracked separately, so it doesn't inflate screen time.
- **Any number of devices.** Add one by scanning a QR code or opening a one-time link from a device that is already set up.
- **Dashboard on every device.** Filter by device and category. It has stacked daily, hourly and weekly charts, a weekday × hour heatmap, and an app list where every app expands into a per-device breakdown.
- **Works offline.** Devices keep recording without a connection and upload the backlog when they're back online.
- **Synced settings.** Theme colours, category colours and app categories change on every device at once.
- **Long history, small footprint.** A typical day is 1–3 KB per device. Days older than 90 days are compacted into hourly totals and kept forever.
- **Private by default.** Window titles and URLs are never collected, only which app was in front and for how long.

## How it works

```
android ─┐
linux   ─┼── every 15 min: one gzip'd chunk per device per day ──▶ Cloudflare Worker + D1
windows ─┘                                                              ▲
                                  dashboard (on every device) ──────────┘
```

| Platform | How screen time is collected |
|---|---|
| Android | `UsageStatsManager` event log (needs *Usage access*). Background audio comes from media sessions (needs *Notification access*; notifications themselves are never read). |
| Linux (GNOME, Wayland) | A tiny GNOME Shell extension reports the focused app over D-Bus, because Wayland doesn't let regular apps see it. Audio playback comes from MPRIS. |
| Windows | Foreground window → process, idle time from `GetLastInputInfo`, audio from Core Audio sessions. |

On desktop the collector is a separate headless binary (`timely-agent`) started by systemd on Linux and at login on Windows. The Timely app itself is only the dashboard.

### Repository layout

| Path | |
|---|---|
| `backend/` | Cloudflare Worker: auth, device pairing, chunk storage, settings sync, nightly rollup |
| `packages/timely_core/` | Shared Dart code: chunk format, recorder, API client, aggregation |
| `app/` | Flutter app (Android, Linux, Windows). The Android collector is Kotlin in `app/android/app/src/main/kotlin` |
| `agent/` | Desktop collector for Linux and Windows |
| `linux/gnome-extension/` | The focus-reporting GNOME Shell extension |
| `packaging/` | `.deb` build script, systemd user unit, Inno Setup script |

## Installing

Grab the latest packages from [Releases](../../releases).

**Android:** install `timely-*-arm64.apk` (any phone from the last several years). Then grant:

- **Usage access** (required)
- **Notification access** (for listening time)
- **Battery: unrestricted** (Samsung and some other vendors kill background work otherwise)

The app shows a checklist under *devices*.

If Android says *App not installed* when updating, the installed copy was signed with a different key (builds from before the first release were). Uninstall it once and install again. If you sign back in with the same account, your history is still there.

**Ubuntu / GNOME:**

```sh
sudo apt install ./timely_*_amd64.deb
```

Log out and back in once so GNOME loads the focus extension, then open Timely and sign in. The agent starts automatically.

**Windows 11:** run `timely-setup-*.exe`. It installs per-user without admin rights, and the agent runs in the background from login.

### Adding a device

On a device that's already signed in, open **devices → + add device**. On the new device, choose **add this device** and either scan the QR code or type the code. Codes are valid for 10 minutes and work once.

## Hosting the backend

The backend fits comfortably in Cloudflare's free plan, with no credit card and no trial period. A device makes roughly 100 requests a day (the limit is 100k) and stores about 1 MB a year (the limit is 5 GB).

```sh
cd backend
npm install
npx wrangler login
npx wrangler d1 create timely        # put the printed database_id into wrangler.toml
npm run db:init
npx wrangler deploy
```

Then point the app at your worker URL on the login screen, or bake it in at build time with `--dart-define=TIMELY_SERVER=https://...`.

## Building from source

You need Flutter (stable), the Android SDK for the APK, and `clang cmake ninja-build libgtk-3-dev` for the Linux build.

```sh
# Linux
cd app && flutter build linux --release
cd ../agent && dart pub get && dart compile exe bin/timely_agent.dart -o build/timely-agent
cd .. && packaging/linux/build-deb.sh 1.0.0

# Android
cd app && flutter build apk --release --split-per-abi
```

Windows builds have to run on Windows, so the GitHub Actions workflow in `.github/workflows/release.yml` handles them. Pushing a `v*` tag builds all three platforms and attaches the packages to a release.

### Android signing

Android only installs an update if it's signed with the same key as the installed app, so release APKs must always be signed with the same release key. Create it once:

```sh
keytool -genkeypair -keystore timely-release.jks -storetype PKCS12 -alias timely \
  -keyalg RSA -keysize 4096 -validity 10000
```

Keep the `.jks` file and its password somewhere safe and outside the repo. If you lose them, existing installs can't be updated anymore and have to be uninstalled first.

**Local builds:** create `app/android/key.properties` (it's git-ignored):

```
storeFile=/absolute/path/to/timely-release.jks
storePassword=...
keyAlias=timely
keyPassword=...
```

**GitHub Actions:** add these repository secrets:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_B64` | Output of `base64 -w0 timely-release.jks` |
| `ANDROID_KEYSTORE_PASS` | The keystore password |
| `ANDROID_KEY_ALIAS` | `timely` |

Without the secrets the workflow still builds the APKs but doesn't publish them, because a debug-signed APK can't be installed over a release.

### Tests

```sh
cd packages/timely_core && dart test

# end-to-end UI tests against a running backend
cd app && flutter test integration_test/e2e_test.dart -d linux \
  --dart-define=PAIR_CODE=XXXX-XXXX --dart-define=SHOT_DIR=/tmp/shots
```

For local development, run the backend with `npx wrangler dev` and on Android use `adb reverse tcp:8787 tcp:8787`. Plain HTTP is only accepted for `localhost`.

## Data format

Each device uploads one chunk per local day:

```json
{"v":1, "d":"2026-11-09", "z":60,
 "a":[["com.spotify.music","Spotify"], ...],
 "f":[app, startDelta, duration, ...],
 "m":[app, startDelta, duration, ...],
 "u":42}
```

| Key | Contents |
|---|---|
| `a` | App dictionary for the day |
| `f` | Focused sessions |
| `m` | Media playback sessions |
| `u` | Unlocks |
| `z` | UTC offset in minutes |

Sessions refer to apps by index into `a`, and start times are stored as the difference from the previous session. The numbers stay small, so the JSON gzips very well. Rolled-up days use `hf` / `hm` (`[app, hour, seconds, ...]`) instead.

## Security

- **Transport:** HTTPS only, with HSTS.
- **Passwords:** PBKDF2-SHA256 with 100k iterations and a per-user salt, compared in constant time. Login and registration are rate limited per IP and per account.
- **Device tokens:** every device has its own random 256-bit token, and the server stores only its SHA-256 hash. Removing a device revokes its token immediately.
- **Pairing codes:** single use, valid 10 minutes, and rate limited.
- **Desktop credentials:** stored with `0600` permissions.

## License

MIT, see [LICENSE](LICENSE).

---

*Disclaimer: this app was co-developed with the help of AI tools. It has been tested on Android and Ubuntu (GNOME, Wayland). Windows support is newer and less tested. Use it at your own risk.*
