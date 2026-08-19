# MZ/MV APK Builder

Turn an **RPG Maker MZ or MV web export** into a signed, installable **Android APK** —
no Android Studio, no Cordova setup, no code. Pick your game folder, an icon and
some colors in a small Windows app, press **BUILD APK**, upload the result to
itch.io (or install it straight on a phone).

Made by [Doma](https://linktr.ee/aak581).

## What the built APKs include

- Fullscreen, landscape-locked, screen stays awake, back button opens the game menu
- On-screen touch controls: d-pad, Z / X / SHIFT, plus an optional extra key button
  - Controls start hidden behind a small round **+** button (Maldives-style);
    the player's choice is remembered
- Fixes for the classic RPG Maker on Android rendering bugs (tile seams,
  garbled fine patterns) via a shader-precision patch
- Your own background art behind the game, an optional itch-style frame with
  configurable color/opacity/margins, and a configurable game-window height
  (0 vertical margin = game fills the full screen height)
- Live phone-mockup preview in the app while you pick colors and images

## Requirements

- Windows 10/11
- [Node.js](https://nodejs.org/en/download) — the app checks at startup and
  points you to the download if it's missing

Everything else (Java JDK, Android SDK, Gradle) is downloaded automatically on
the first build (~900 MB, one time). After that, each game builds in a minute
or two.

## Quick start

1. Download this repo (Code → Download ZIP) and extract it anywhere
2. Double-click **`Launch RMMZ APK Builder.bat`**
   - If Windows warns about a downloaded script: right-click the .bat →
     Properties → Unblock, or choose "More info → Run anyway"
3. Pick your game's web export folder (MV exports with the game inside a
   `www` folder are detected automatically), an icon (square, 512×512+), and
   optionally a background image (2400×1080 recommended)
4. **BUILD APK** — the finished file lands in the `output` folder as
   `<Game Title> v<Version>.apk`

Settings and version numbering are remembered per game: rebuilding after a
game update automatically increments the internal version so players can
install the new APK over the old one without losing saves.

## Signing (read this once)

Android refuses unsigned apps, so a private signing key is created
automatically in your `Documents\android-keys` folder and reused for all your
games. **Back that folder up** — updates must be signed with the same key.
No Google account is involved.

These APKs are for itch.io and sideloading. Publishing on Google Play is a
different pipeline (AAB bundle, store listing, content rating, etc.) that this
tool intentionally does not do.

## Command line

Everything the GUI does is scriptable:

```powershell
powershell -ExecutionPolicy Bypass -File RMMZ-APK-Builder.ps1 -NoGui `
  -GameDir "C:\path\to\your\game" `
  -DevName "yourname" -VersionName "1.0" `
  -IconPath "C:\path\to\icon.png" -BackgroundImage "C:\path\to\bg.png" `
  -FrameColor "#bababa" -FrameOpacity 50 -FrameMargin 4 -VMargin 5 `
  -ButtonColor "#14507e" -ControlsOpacity 55 -ControlsSize 100 `
  -ExtraButton -ExtraKey "C" -OutputDir "C:\path\to\output"
```

All parameters are optional except `-GameDir` (and an icon, which defaults to
the export's own `icon/icon.png`). Use `-NoFrame` to disable the frame.

## Repository layout

| Path | What it is |
|---|---|
| `RMMZ-APK-Builder.ps1` | the whole tool: build pipeline + GUI + CLI |
| `Launch RMMZ APK Builder.bat` | double-click launcher |
| `templates/` | the files generated into every game (controls JS, MainActivity) |
| `README.txt` | plain-text instructions shipped alongside the tool |
| `projects/`, `output/` | created at runtime; per-game workspaces and built APKs (git-ignored) |

## Credits

Made by [Doma](https://linktr.ee/aak581).

Special thanks to [AbraGeroni](https://linktr.ee/AbraGeroni) for testing the
builder and finding the bugs that made it work on machines other than mine.
