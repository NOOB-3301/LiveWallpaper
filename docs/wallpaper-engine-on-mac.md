# Wallpaper Engine on Mac

Wallpaper Engine is a Windows application. There is no official macOS version, so Steam's "Wallpaper Engine" does not install or run on a Mac. PaperFlow is a free, open-source Mac app that plays the same Steam Workshop wallpapers natively.

## What works

| Wallpaper type | Supported | Notes |
|---|---|---|
| Video (MP4, MOV, M4V) | Yes | Played with Apple's `AVPlayer`. |
| Scene (`.pkg`) | Yes, on the desktop | Drawn by PaperFlow's own Rust + Metal renderer: layers, effects, bloom, particles, puppet animation, text, parallax, SceneScript and audio-reactive properties. Compatibility varies by wallpaper. |
| Web | No | Shown as unsupported instead of failing after download. |
| Application | No | |

On the lock screen, a video plays live on macOS 26 or later. A scene is first recorded as a short looping video. On macOS 15 the lock screen gets a still frame.

## How to get Workshop wallpapers on your Mac

1. Download PaperFlow from the [Releases](../../../releases) page and open it (the app is not notarized, so see [Install](../README.md#install) for the one-time Open Anyway step).
2. Open the **Steam Setup** tab. It walks you through installing Valve's SteamCMD (about 3 MB) and signing in with your own Steam account. The account must own Wallpaper Engine. PaperFlow never sees your password.
3. Open the **Workshop** tab, browse Trending or search, or paste a Workshop link or item number, then press Download.
4. Pick the wallpaper in your library and choose **Set as Desktop**, **Set as Lock Screen** or **Set as Both**.

## Battery and heat

Scenes only render while something changes. You can cap the frame rate, lower the render scale, or pause on battery. Rendering stops while the screen is locked or the desktop is covered.

## Requirements

macOS 15 or later on Apple silicon. Live lock-screen video needs macOS 26 or later.

## Not affiliated

PaperFlow is independent and is not affiliated with Valve or Wallpaper Engine. Workshop items belong to their creators and are for personal use on your Mac.
