# Live Wallpaper

A small macOS app that plays your own videos as a looping desktop wallpaper, can rotate through several of them on a timer, and sets a still frame of the current video as the lock screen wallpaper.

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
- Apply to chooses whether the video plays on the Desktop, sets the Lock Screen still, or both.
- Start Wallpaper (⌘↩) begins playback, Stop Wallpaper ends it and restores your original wallpaper.
- The menu bar icon offers Show Window, Start/Stop, Pause/Resume, Next Video and Quit. Closing the window does not quit the app.

## Lock screen limitation

The lock screen shows a still frame of the current video, not motion. macOS has no public API for animated lock-screen wallpaper. It may apply only to the active Space on some macOS versions. The FileVault pre-boot login screen is unaffected. While running, your system wallpaper is replaced by the still. It is restored on Stop or Quit.

## Permissions and Gatekeeper

The app is signed ad hoc, not notarized. If macOS refuses to open a downloaded build, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine build/LiveWallpaper.app
```

Because the signature is ad hoc, macOS may ask again for access to folders such as Desktop, Documents, Downloads or removable volumes after each rebuild.

## Performance

Prefer H.264 or HEVC videos at or near your screen resolution. Higher resolutions and exotic codecs use more CPU and battery. Playback pauses automatically when the desktop is fully covered and while the display sleeps.

## Possible future extras

- Launch at login
- Shuffle order
- Different videos per screen
- App Sandbox support (needs security-scoped bookmarks for the chosen videos)
