# MZ/MV APK Builder

Turn an **RPG Maker MZ or MV web export** into a signed, installable **Android APK** —
no Android Studio, no Cordova setup, no code. Pick your game folder, an icon and
some colors in a small Windows app, press **BUILD APK**, upload the result to
itch.io (or install it straight on a phone).

It can also make a **Google Play** build: an `.aab` with AdMob interstitial
ads, a "Remove Ads" purchase and the EU consent form, ready to upload to Play
Console. That needs some setup in AdMob and Play Console first, so it has its
own step-by-step guide: [Google Play builds](#google-play-builds).

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

If the export was made for a web portal, its ad SDK is removed from the app
automatically (currently Game Monetize). Events that call
`window.sdk.showBanner()` at ad breaks keep working: in a Google Play build
that call shows the native AdMob interstitial, elsewhere it does nothing.

## Signing (read this once)

Android refuses unsigned apps, so a private signing key is created
automatically in your `Documents\android-keys` folder and reused for all your
games. **Back that folder up** — updates must be signed with the same key.
No Google account is involved.

The same key is the **upload key** for Google Play builds. Play re-signs the app
with its own key (Play App Signing), but every update you upload must still be
signed with this one. If you lose it, you have to ask Google for an upload key
reset.

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

## Google Play builds

Tick **Google Play build** in the app and every build makes three files in
`output\<Game Title> v<Version>\`:

| File | What it is for |
|---|---|
| `<Title> v<Version> (Play).aab` | The file you upload to Play Console. Real ads, real purchases. |
| `<Title> v<Version> (Play test ads).apk` | For testing on your own phone. Shows Google's **test** ads (safe to tap) and a green status line at the bottom that says what the ad code is doing. |
| `<Title> v<Version>.apk` | The itch.io / sideload build. No ads, no purchases, no ad permissions. |

There are two kinds of Play build. You pick one per game in the **Play IDs...**
dialog:

- **Ads + remove-ads purchase** (the default): interstitial ads at break points
  you choose, a "Remove Ads" button on the title screen and in the pause menu,
  and Google's consent form for players in Europe.
- **Support button only**: no ads and no AdMob account. Just a "Support the
  dev!" tip button on the title screen and in the pause menu. The tip can be
  bought more than once. If you pick this, skip everything about AdMob below.

### What the ads do in the game

- **No ad when the app starts.** Google's rules forbid it.
- The first ad is loaded when the player reaches the first map, not on the
  title screen, so people who only look at the title screen don't cost you
  ad requests.
- **Ads only show where your events ask for one** (see the next section), plus
  every time the player returns to the title screen (To Title, game over,
  the ending).
- There are at least 3 minutes between event ads unless the event forces one.
- While an ad is on screen the game and its music are paused. When the player
  closes the ad, the event carries on exactly where it stopped.
- A player who bought Remove Ads never loads an ad at all. Ownership is
  checked with Google Play on every launch and whenever the app comes back to
  the front, so refunds bring ads back and offline buyers stay ad-free.
- If no ad is loaded (offline, nothing to show), the break is just skipped.
  The game never waits for an ad.

### Step 1: put ad breaks in your game (RPG Maker editor)

Add a **Script** event command at natural pauses, such as the end of a day,
after a chapter or before a long cutscene:

```js
window.showAdBreak && window.showAdBreak();
```

To show an ad even if the last one was less than 3 minutes ago, use:

```js
window.showAdBreak && window.showAdBreak({ force: true });
```

The `window.showAdBreak &&` part makes the line do nothing in the itch build,
in the browser and in playtests, so you can leave it in every export.

If the export was made for the Game Monetize portal, you don't need to change
anything: its `window.sdk.showBanner()` calls become ad breaks in the Play
build.

**Keep the title screen.** The consent form (step 3) only opens on the title
screen or at launch, never in the middle of play. A game that skips its title
screen never shows the form, so European players would get no ads.

Optional: players on phones often don't know the on-screen buttons. A message
at the very start of the game helps. In the first autorun event, add a
Conditional Branch with the Script condition
`!!document.getElementById('tc-dpad')` (true in the phone app, false in the
browser and desktop). Put the phone text in the "true" branch, for example
"D-pad to move / SHIFT to sprint / Z to interact / X to pause", and the
keyboard text in the "else" branch.

Export the game for **Web browsers/Android** as usual. That export folder is
what you give the builder.

### Step 2: create the app in Play Console

1. Create the app in [Play Console](https://play.google.com/console). The
   package name the builder uses is `com.<developer name>.<game title>`,
   lowercase, with only letters and numbers, for example
   `com.doma581.thereids`. Use the same developer name and game title in the
   builder every time, or you get a different package that Play won't
   accept as an update.
2. Under **Monetize > Products > In-app products**, create a one-time product
   with the ID `remove_ads` (or `support_dev` for the support button). Play
   only lets you create products after you've uploaded a build that contains
   the billing permission. If the page asks for that, upload a first `.aab` to
   **Internal testing** (step 6) and come back.
   - Give it a **purchase option** (for example the ID `buy`, type Buy) and
     keep it backwards compatible. The game buys the product's first offer,
     so the option ID never needs to match anything.
   - Set a price and **activate** the product. Put the same price in the
     builder's price label so the button shows it before Play answers.
3. **App content** (Policy section). Answer these to match the build:
   - **Ads:** yes, the app contains ads.
   - **Advertising ID:** yes, used for "Advertising or marketing". Leave the
     box that turns off release errors **unticked** (that box is for apps
     that don't have the permission).
   - **Data safety:** Device or other IDs > Advertising ID, collected and
     shared, purpose Advertising or marketing.
   - **Privacy policy:** apps with ads need a public privacy policy URL.
     Mention AdMob, the advertising ID and the consent form.
   - **Target audience:** keep it 13 and older while the game shows ads. Ads
     aimed at children fall under Google's Families rules, which these ads
     are not set up for.
   - **Content rating:** answer honestly about violence, language and so on.

New personal developer accounts must run a closed test (at least 12 testers
for 14 days) before Play lets them apply for production. Upload the `.aab` to
**Closed testing** for that.

### Step 3: set up AdMob (skip for the support button)

1. In [AdMob](https://admob.google.com), **Apps > Add app**, Android. Once
   the game is on Play you can link it to the store listing.
2. Copy the **App ID**. It looks like `ca-app-pub-1234567890123456~1234567890`
   (with a `~`).
3. **Ad units > Add ad unit > Interstitial.** Copy its ID. It looks like
   `ca-app-pub-1234567890123456/1234567890` (with a `/`).
4. **Privacy & messaging > European regulations (GDPR) > create a message**,
   then:
   - User choices: **Consent** on, **Manage options** on, **Do not consent**
     on (shown as a button), **Close (do not consent)** off.
   - **Apps:** tick every game that uses this builder.
   - Countries: all the regions it offers. Ad partners: leave the default.
   - Press **Publish** (saving is not enough). The message list must say
     **Published** and list your app.

   Without a published message that lists the app, Google never shows the
   form, European players can't give consent, and you break Google's EU
   consent policy. The game doesn't need a rebuild when you add an app to
   the message later. It picks the message up on the next launch.

New ad units can take a few hours before they show real ads. Each game needs
its own AdMob app and its own ad unit.

### Step 4: build

1. Open the builder, pick the game's export folder, icon and colors as usual.
2. Tick **Google Play build** and click **Play IDs...**.
3. Choose **Ads + remove-ads purchase** (or Support button only), paste the
   App ID and the interstitial ad unit ID, and check the product ID
   (`remove_ads` by default) and the price label.
4. Raise the **version** (1.0, 1.1, 1.2...) for every build you upload. The
   internal version code goes up by itself with every build, and Play refuses
   any version code it has seen before, even from a build you deleted. So a
   rebuild always gets a fresh one.
5. **BUILD APK.** A Play build takes several minutes.

Keep the icon file in a folder you won't clean out. Every build reads it
again, and the build stops with "Icon image not found" if it has moved.

All of this is also on the command line:

```powershell
powershell -ExecutionPolicy Bypass -File RMMZ-APK-Builder.ps1 -NoGui `
  -GameDir "C:\path\to\your\game" -DevName "yourname" -GameTitle "Your Game" `
  -VersionName "1.1" -IconPath "C:\path\to\icon.png" `
  -PlayMode -PlayVariant ads `
  -AdMobAppId "ca-app-pub-1234567890123456~1234567890" `
  -AdUnitId "ca-app-pub-1234567890123456/1234567890" `
  -ProductId remove_ads
```

Leave `-PriceLabel` out to get `$0.99`. If you do pass it, use single quotes
(`-PriceLabel '$1.99'`), because PowerShell treats `$` inside double quotes
as a variable.

### Step 5: test on your phone before uploading

**Never tap real ads on your own phone.** AdMob bans accounts for it. Test
only with the `(Play test ads).apk`.

1. Copy the test-ads APK to the phone and install it. If the same game is
   installed from Play, uninstall it first: the two are signed with different
   keys, so one can't install over the other. Uninstalling deletes that
   game's saves on the phone.
   - Xiaomi phones block installs over USB (`adb install`). Copy the APK to
     the Download folder and install it from the Files app instead.
2. Turn off any ad blocker for the test, including **Private DNS** set to an
   ad-blocking server (AdGuard and similar), under Settings > Connections or
   Network. Otherwise every ad fails to load. Turn it back on afterwards.
3. Start a new game. The green line at the bottom should say the interstitial
   loaded. Trigger one of your ad breaks, close the test ad and check that the
   game carries on.
4. Return to the title screen. An ad should show.
5. Tap **Remove Ads**. Play's purchase sheet should open with your price. To
   test buying without paying, add your Google account under Play Console >
   Settings > **License testing** (you then get a test card). Once you own
   it, ads stop on that account. To see ads again, refund the order in Play
   Console's **Order management** and tick removing the entitlement.

The test-ads build also has debug commands. Connect the phone with USB
debugging on, open `chrome://inspect` in Chrome on the PC, and click
**inspect** under the game's WebView. Then type these in the Console:

| Command | What it does |
|---|---|
| `__adsDebug.break()` | Ad break right now |
| `__adsDebug.reset()` | Forget Remove Ads for this session so ads show again |
| `__adsDebug.consentTest("HASH")` | Make this phone act like it's in the EU and forget its consent answer. Restart the app afterwards to get the form. |
| `__adsDebug.consentOff()` | Back to the phone's real location |

**Testing the EU consent form:**

1. Get the phone's test ID (the "hash"). With the phone on USB, run
   `adb logcat | findstr UserMessagingPlatform` on the PC and start the game.
   Look for a line like
   `addTestDeviceHashedId("0123456789ABCDEF0123456789ABCDEF")`. The text in
   quotes is the hash.
2. Run `__adsDebug.consentTest("<that hash>")` in the console and restart the
   game. The consent form should appear over the title screen.
3. Try **Do not consent**, **Consent** and **Manage options**. After any of
   them the game should continue and ads should still load. "Do not consent"
   still allows limited, non-personalized ads.
4. A **Privacy Options** button should now be under Remove Ads on the title
   screen, and a "Privacy Options" line in the pause menu. Both reopen the
   form.
5. The phone remembers the answer between launches. Run `consentTest` again
   before each fresh test, and `consentOff()` when you're done.

If the form never appears and the log says
`"status":"NOT_REQUIRED","isConsentFormAvailable":false`, the AdMob message
isn't published or doesn't list this app (step 3).

A player who owns Remove Ads is never asked for consent, because they never
see ads. Test with an account that doesn't own it.

### Step 6: upload

1. Play Console > the track (Internal testing, Closed testing or
   **Production**) > **Create new release**.
2. Upload the `(Play).aab`. On the very first upload Play turns on Play App
   Signing. Accept it.
3. Write the release notes and send it for review.
4. If Play warns that a build "doesn't include the AD_ID permission", an older
   build without ads (for example a support-button build) is still active in
   one of your tracks. Replace or remove it there. Don't change the
   Advertising ID answer to "no".

### When something goes wrong

| Problem | Likely cause |
|---|---|
| No ads at all | Ad blocker or Private DNS on; your account owns Remove Ads; new ad unit not serving yet (wait a few hours); an ad break within 3 minutes of the last ad without `force` |
| First ad break right after loading a save shows nothing | The first ad is only requested on the first map and takes a few seconds to load |
| No consent form for EU players | AdMob message not published, or this app isn't ticked in it |
| Purchase sheet doesn't open | Product not active, or the account isn't a license tester and the app isn't published yet |
| Can't install the test APK | The Play version is installed (different signature). Uninstall it first |
| "Icon image not found" | The icon file moved since the last build |
| Play says the version code is already used | Rebuild. Every build gets a new version code |
| Play says the package name is wrong | Developer name or game title changed in the builder |

## Repository layout

| Path | What it is |
|---|---|
| `RMMZ-APK-Builder.ps1` | the whole tool: build pipeline + GUI + CLI |
| `Launch RMMZ APK Builder.bat` | double-click launcher |
| `templates/` | the files generated into every game (controls JS, MainActivity, the Play ads/purchase/consent script, the support-button script) |
| `README.txt` | plain-text instructions shipped alongside the tool |
| `projects/`, `output/` | created at runtime; per-game workspaces and built APKs (git-ignored) |

## Credits

Made by [Doma](https://linktr.ee/aak581).

Special thanks to [AbraGeroni](https://linktr.ee/AbraGeroni) for testing the
builder and finding the bugs that made it work on machines other than mine.
