# Live Wallpaper

A small macOS app that plays your own videos as a looping desktop wallpaper, can rotate through several of them on a timer, and plays the current video on the lock screen too (macOS 26 or later).

## Requirements

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later

## Build and run

```sh
./build.sh
open build/LiveWallpaper.app
```

Run the app through the `.app` bundle. `swift run` does not work, because the app needs its `Info.plist`.

`./build.sh` builds a release binary, wraps it in `build/LiveWallpaper.app` and signs it ad hoc. Use `CONFIG=debug ./build.sh` for a debug build and `UNIVERSAL=1 ./build.sh` for an arm64 + x86_64 binary.

## Usage

- Add videos by dropping them on the window or with Add Videos (⌘O). The first video is selected automatically.
- The preview shows the selected video, muted and looping.
- Rotate wallpaper cycles through your videos in list order. Set how often it switches (minimum 5 seconds). Rotation needs at least two videos.
- Apply to chooses whether the video plays on the Desktop, the Lock Screen, or both. The Lock Screen needs a one-time setup, see below.
- Start Wallpaper (⌘↩) begins playback, Stop Wallpaper ends it and restores your original wallpapers.
- The menu bar icon offers Show Window, Start/Stop, Pause/Resume, Next Video and Quit. Closing the window does not quit the app.

## Lock screen

On macOS 26 (Tahoe) and later the lock screen plays your video. macOS has no public API for that, so the app borrows the slot of an Apple Aerial wallpaper: Apple stores downloaded Aerial videos as `.mov` files in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`, and the app swaps your video into all of them. The system then plays it on the lock screen as if it were the Aerial. No admin rights or SIP changes are needed, and everything stays inside your user folder.

One-time setup: open System Settings > Wallpaper, pick any Apple Aerial, wait for it to download and leave it selected. Without a downloaded Aerial the app reports an error instead of applying the lock screen.

The app can't tell which downloaded Aerial the lock screen plays, and each display or Space can use a different one, so it replaces every downloaded Aerial with your video. The extra copies are hard links, so they normally take no additional disk space. Apple's Aerial screen saver shows your video too while the app runs.

- Apple's original files are moved to `~/Library/Application Support/LiveWallpaper/Backups/` before the first swap. Stop and Quit move them back. After a crash they are moved back the next time the app launches without resuming playback, or on Stop.
- Your video is converted without audio and repeated end to end until it lasts about 3 minutes, because the renderer misbehaves when a video ends. The converted file normally keeps the source encoding and can be large, since the repeats add up.
- Rotation updates the lock screen at most every 30 seconds, always ending on the latest video. The desktop switches at your chosen interval.
- The app restarts the wallpaper renderer each time you unlock the screen, which keeps later lock screens from going black. It never does this while the screen is locked.
- The first lock after switching videos may briefly show the previous frame.
- The FileVault login screen shown after a cold boot stays static, because it appears before your session exists.
- A macOS update may put Apple's own Aerial back. Stop and start the wallpaper to install your video again.
- On macOS 13 to 15 the lock screen gets a still frame of the current video as the system wallpaper instead, which replaces your wallpaper while the app runs and is restored on Stop or Quit.

## Permissions and Gatekeeper

The app is signed ad hoc, not notarized. If macOS refuses to open a downloaded build, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine build/LiveWallpaper.app
```

Because the signature is ad hoc, macOS may ask again for access to folders such as Desktop, Documents, Downloads or removable volumes after each rebuild.

## Performance

Prefer H.264 or HEVC videos at or near your screen resolution. Higher resolutions and exotic codecs use more CPU and battery. Playback pauses automatically when the desktop is fully covered and while the display sleeps.

## Credits

The lock screen technique is prior art from [vlzuiev/animated](https://github.com/vlzuiev/animated) (MIT). This app is an independent implementation and is not affiliated with it or with Apple.

## Possible future extras

- Launch at login
- Shuffle order
- Different videos per screen
- App Sandbox support (needs security-scoped bookmarks for the chosen videos)
