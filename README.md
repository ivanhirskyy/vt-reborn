# vt-reborn

Native macOS app for VisualTime — a fast, usable replacement for the web portal.

## Why
The official VisualTime portal is slow, clunky, and web-based. This app gives you a native macOS interface with:

- **Week view** — punch in/out, backfill missing punches, see status at a glance
- **Smart backfill** — conflict-aware: only submits entrance + exit when due; shows preview with conflicts; never submits future times
- **Vacation calendar** — monthly grid: vacations (green), bank holidays (grey), today (blue), absences (orange)
- **Scheduler** — automatic punches with configurable jitter
- **Keychain credentials** — secure storage, auto-login on launch
- **Native SwiftUI** — no Electron, no webview, ~2 MB binary

## Install

### Homebrew (recommended)
```bash
brew tap ivanhirskyy/vt-puncher
brew install vt-reborn
```

### Manual
Download `vt-reborn.zip` from [Releases](https://github.com/ivanhirskyy/vt-reborn/releases), unzip, and run.

### From source (install to /Applications)
```bash
git clone https://github.com/ivanhirskyy/vt-reborn.git
cd vt-reborn
./scripts/install-app.sh
```
This builds the app, installs it to `~/Applications/vt-reborn.app`, pins it to the
Dock, and launches it. Re-run the same command any time to update to the latest
source — it replaces the installed copy and restarts the app.

## Build from source
```bash
git clone https://github.com/ivanhirskyy/vt-reborn.git
cd vt-reborn
./scripts/build-app.sh
open dist/vt-reborn.app
```
(Use this if you just want a local build without installing/pinning it.)

## Configuration
1. Open the app → Settings tab
2. Enter your VisualTime credentials (User, Password, Company ID)
3. Set punch times (default: 07:00 in, 12:00 out, 13:00 in, 16:00 out)
4. Enable "Launch at login" if desired

## Usage
- **Week tab**: see this week's punches, click "Backfill" to submit missing entrance/exit
- **Vacation tab**: monthly calendar with your booked vacations and bank holidays
- **Alerts tab**: incomplete-punch notifications (auto-dismissed after backfill)
- **Scheduler**: start automatic punches from the Week tab

## Requirements
- macOS 13+
- VisualTime portal access

## License
MIT