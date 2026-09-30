# Live Wallpaper

A small macOS app that plays your own videos as a looping desktop wallpaper, can rotate through several of them on a timer, and plays the current video on the lock screen too (macOS 26 or later). Videos can come from your Mac or from the Steam Workshop for Wallpaper Engine.

It is two apps in one bundle:

- **Live Wallpaper** (Settings): the window where you manage your library, rotation and Steam downloads. Open and close it whenever you like.
- **Live Wallpaper Agent**: a tiny background app with a menu bar icon that actually plays the wallpaper. It keeps running when the Settings window is closed.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later

## Build and run

```sh
./build.sh
open build/LiveWallpaper.app
```

Run the app through the `.app` bundle. `swift run` does not work, because both apps need their `Info.plist`.

`./build.sh` builds a release binary of each app, assembles `build/LiveWallpaper.app` with the agent nested inside at `Contents/Library/LoginItems/LiveWallpaperAgent.app`, and signs the agent first and then the outer app, ad hoc. Use `CONFIG=debug ./build.sh` for a debug build and `UNIVERSAL=1 ./build.sh` for an arm64 + x86_64 binary.

## Usage

- Add videos by dropping them on the window or with Add Videos (⌘O). The first video is selected automatically.
- The preview shows the selected video, muted and looping.
- Rotate wallpaper cycles through your videos in list order. Set how often it switches (minimum 5 seconds). Rotation needs at least two videos.
- Apply to chooses whether the video plays on the Desktop, the Lock Screen, or both. The Lock Screen needs a one-time setup, see below.
- Start Wallpaper (⌘↩) starts the agent if needed and begins playback. Stop Wallpaper ends it and restores your original wallpapers.
- The agent's menu bar icon offers Open Settings, Start/Stop, Pause/Resume, Next Video and Quit Wallpaper. Quitting the agent restores your original wallpapers and ends the background app. Closing the Settings window does not stop anything.

## Steam Workshop (Wallpaper Engine)

The Workshop tab downloads video wallpapers from the Steam Workshop into your library. It uses Valve's official SteamCMD with your own Steam account, which must own Wallpaper Engine. The app never sees your Steam password or Steam Guard code: you sign in once in Terminal and SteamCMD remembers the session.

1. Install SteamCMD: `brew install --cask steamcmd`. On Apple silicon it needs Rosetta: `softwareupdate --install-rosetta --agree-to-license`.
2. Open the Steam Setup tab, enter your Steam username, and follow the one-time sign-in instructions (`steamcmd +login <username>` in Terminal).
3. In the Workshop tab, paste a Workshop link or item number and press Download. With a free Steam Web API key (optional, added in Steam Setup) you can also browse and search.

Only video wallpapers (MP4, MOV, M4V) can play. Scene, web and application wallpapers, and video formats macOS cannot decode, are shown as unsupported and are never converted. Workshop items belong to their creators: they are downloaded for your personal use on this Mac, through your own account. Do not redistribute them. This app is not affiliated with Valve or Wallpaper Engine.

## Lock screen

On macOS 26 (Tahoe) and later the lock screen plays your video. macOS has no public API for that, so the agent borrows the slot of an Apple Aerial wallpaper: Apple stores downloaded Aerial videos as `.mov` files in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`, and the agent swaps your video into all of them. The system then plays it on the lock screen as if it were the Aerial. No admin rights or SIP changes are needed, and everything stays inside your user folder.

One-time setup: open System Settings > Wallpaper, pick any Apple Aerial, wait for it to download and leave it selected. Without a downloaded Aerial the agent reports an error instead of applying the lock screen.

The agent can't tell which downloaded Aerial the lock screen plays, and each display or Space can use a different one, so it replaces every downloaded Aerial with your video. The extra copies are hard links, so they normally take no additional disk space. Apple's Aerial screen saver shows your video too while the agent runs.

- Apple's original files are moved to `~/Library/Application Support/LiveWallpaper/Backups/` before the first swap. Stop and Quit Wallpaper move them back. After a crash they are moved back the next time the agent launches without resuming playback, or on Stop.
- Your video is converted without audio and repeated end to end until it lasts about 3 minutes, because the renderer misbehaves when a video ends. The converted file normally keeps the source encoding and can be large, since the repeats add up.
- Rotation updates the lock screen at most every 30 seconds, always ending on the latest video. The desktop switches at your chosen interval.
- The agent restarts the wallpaper renderer each time you unlock the screen, which keeps later lock screens from going black. It never does this while the screen is locked.
- The first lock after switching videos may briefly show the previous frame.
- The FileVault login screen shown after a cold boot stays static, because it appears before your session exists.
- A macOS update may put Apple's own Aerial back. Stop and start the wallpaper to install your video again.
- On macOS 13 to 15 the lock screen gets a still frame of the current video as the system wallpaper instead, which replaces your wallpaper while the agent runs and is restored on Stop or Quit.

## Upgrading from the single-app version

Quit the old Live Wallpaper app first (its Quit restores your Aerials), then replace it with this build. The first launch of the new Settings app imports your old library once. Do not run the old and new versions together: the new agent refuses to start while an old copy is running.

## Files

Everything lives in `~/Library/Application Support/LiveWallpaper/`: `state.json` (library and settings, written by Settings), `agent.json` (what the agent needs to restore your wallpapers), `Library/` (downloaded Workshop videos), `Backups/` and `Stills/` (lock screen). Steam downloads are staged in `~/Library/Caches/LiveWallpaperSteam/`.

## Permissions and Gatekeeper

The apps are signed ad hoc, not notarized. If macOS refuses to open a downloaded build, clear the quarantine flag on the whole bundle (this includes the nested agent):

```sh
xattr -dr com.apple.quarantine build/LiveWallpaper.app
```

Because the signature is ad hoc, macOS may ask again for access to folders such as Desktop, Documents, Downloads or removable volumes after each rebuild, once for the Settings app and once for the agent (the agent is what plays your videos).

## Performance

Prefer H.264 or HEVC videos at or near your screen resolution. Higher resolutions and exotic codecs use more CPU and battery. The agent is AppKit only and keeps its memory low; playback pauses automatically when the desktop is fully covered and while the display sleeps.

## Credits

The lock screen technique is prior art from [vlzuiev/animated](https://github.com/vlzuiev/animated) (MIT). This app is an independent implementation and is not affiliated with it, with Apple, Valve or Wallpaper Engine.

## Possible future extras

- Launch at login (the agent already sits where `SMAppService.loginItem` expects it)
- Shuffle order
- Different videos per screen
- App Sandbox support (needs security-scoped bookmarks for the chosen videos)
