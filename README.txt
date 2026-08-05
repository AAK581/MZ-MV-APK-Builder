RMMZ APK Builder
================
Turns an RPG Maker MV or MZ web export into an installable Android APK
(for itch.io / sideloading - not a Play Store pipeline).
Made by Doma - https://linktr.ee/aak581

HOW TO RUN
1. Install Node.js if you don't have it: https://nodejs.org/en/download
   (the app checks and will point you there anyway)
2. Double-click "Launch RMMZ APK Builder.bat"
3. In the app: pick your game's web export folder, an icon, colors -
   the phone preview updates live - then click BUILD APK.
   There is a Help button with the details.

FIRST BUILD
The very first build downloads the Android build tools automatically
(about 900 MB: Java JDK + Android SDK + Gradle). This happens once.
After that, each game builds in a minute or two.

NOTES
- Windows may warn about running a downloaded script; choose
  "More info" -> "Run anyway" (or right-click the .bat ->
  Properties -> Unblock).
- A private signing key is created automatically in your
  Documents\android-keys folder and reused for all your builds.
  Back it up: app updates must be signed with the same key.
- Settings and version numbering are remembered per game
  (in the "projects" folder next to the app).

