# Live Wallpaper phase 3 — SPEC3 (schema v2, scene host, scene engine M0, Steam wizard, releases)

Authoritative for phase 3 together with `docs/PLAN-scene-renderer.md` (the agreed plan) and `SPEC2.md` (phase-2 architecture, IPC and compile traps, still valid except where this file says otherwise). **Base: branch `feat-pkg-renderer`, scaffold commit given in the final report.** The scaffold files in `Sources/` are the contract: every signature in section 3 exists there, compiles (CI decides), and is what the five workers code against. If a contract must change, stop and tell the orchestrator.

Nobody has a Mac here. The only real compiler is GitHub Actions (`build.yml`: macos-14 with Xcode 15.4 and macos-latest). A Linux harness (section 9.3) typechecks and runs the Foundation-only parts with Swift 5.10.1 and 6.0.3. Nothing in this document has been run against a real Wallpaper Engine scene or a real Steam account: items marked **UNVERIFIED** need the real-Mac test listed in section 9.2.

Workers: **AGENT, SETTINGS, STEAM, SCENEPARSE, SCENERENDER**. Each edits ONLY the files it owns (section 2). `Core`, `Package.swift`, `build.sh`, `scripts/`, the plists, the workflows, `README.md`, `Tests/CoreTests` and `LoopPlan.swift` are scaffold-owned and frozen.

---

## 0. Decisions and deviations (with reasons)

Accepted as given in the brief / plan: scenes play live on the desktop in a separate helper process; the lock screen plays an offline-rendered looping video installed through the existing Aerial-swap path; own MIT scene engine (no code from GPL projects); SteamCMD downloaded by the app, never bundled; password through a pty only; public repo, MIT, no Apple Developer account, ad-hoc signed DMGs; name stays "LiveWallpaper"; no model names anywhere.

| # | Decision / deviation | Why |
|---|---|---|
| D1 | **Deployment target is macOS 14 for every target** (raised from 13, as this row always allowed). | The UI now uses 14-only scroll and inspector APIs, so the pre-14 fallbacks were deleted instead of maintained. `swift-tools-version 5.9` has no `.macOS(.v15)`; the plists advertise the renderer's higher 15.0 install floor. |
| D2 | **Two library targets, not one**: `SceneFormat` (Foundation only, no dependencies; PKG, TEX, scene.json, analysis, `LoopPlan`) and `SceneEngine` (Metal, CoreGraphics, ImageIO, AVFoundation; depends on Core and SceneFormat). | The brief wants the parsing part Linux-testable and Foundation-only. A separate target enforces it at compile time and lets the Settings app run the analyzer at import time (support badge) WITHOUT linking Metal or the renderer. Settings -> `Core, SceneFormat`; host -> `Core, SceneFormat, SceneEngine`; agent -> `Core` only. |
| D3 | **`muted` lives in state.json but has its own writer API**: `StateStore.setMuted(_:)` (read, change, write, revision + 1), callable from Settings AND the agent's menu. `StateStore.commit` never changes `muted` (the value on disk wins). | The agent menu must toggle mute and the agent is not allowed to rewrite the whole library file. This keeps "only Settings writes the library" true for everything except one boolean and removes the stale-snapshot race (a Settings snapshot can never undo the menu's toggle). Settings adopts the new value when a status shows `stateRevision > written.revision`. |
| D4 | **IPC notification names stay `.v1`; payload version `IPC.version` becomes 2.** All additions are optional keys (commands: `target`; status: `lockID`, `muted`, `sceneHostRunning`, `lockRender`). | Same bundle, additive change: an old agent ignores `target` (acts on both targets) and an old Settings ignores the new status keys. A new name would make a surviving old agent look "unresponsive" instead of "outdated" (the existing outdated banner compares versions). Bundle versions go to 3.0 so the banner fires. |
| D5 | **The scene host gets its own IPC pair** (`HostCommand`/`HostStatus`, names `com.noob3301.LiveWallpaper.host.command.v1` / `.status.v1`, Core/HostIPC.swift) between agent and host. Settings does not talk to the host; the agent relays lock render progress in `AgentStatus.lockRender`. | Same style as phase 2 (property-list payload, selector observers, `.deliverImmediately`, ids + retransmit + dedupe). Relaying keeps one status stream for the UI. |
| D6 | **Host = a third nested helper app** `Contents/Library/LoginItems/LiveWallpaperSceneHost.app` (`LSUIElement`, id `com.noob3301.LiveWallpaper.scenehost`, `LWRole = scenehost`), launched by the AGENT (not by Settings) with `NSWorkspace.openApplication`. | Matches the brief. The agent already owns playback state, rotation and the lock screen; only it knows when a scene becomes the desktop/lock item. |
| D7 | **Metal shaders are Swift string literals compiled at runtime** (`makeLibrary(source:)`), no `.metal` files. | `swift build` on the command line then needs no Metal build rules, no resource bundle and no metallib lookup; `build.sh` stays a plain copy of three executables. Cost: ~tens of ms at first use. |
| D8 | **`TargetConfig.playlist` exists in the schema (nil = whole library) but M0 UI does not edit it.** | The brief says "own wallpaper/playlist". The data model supports per-target playlists so the format never needs another migration; the UI for choosing members is a follow-up. |
| D9 | **Scenes are library items, not a new list**: `VideoItem` gains `scene: SceneInfo?` (`kind` is derived: `.scene` when non-nil). `VideoItem.path` of a scene is `Library/<id>/scene.pkg`. The type keeps the name `VideoItem`. | Zero churn in phase-2 call sites; `Library/<id>/` already means "the only files the app may delete", so the lock cache inside it is covered. |
| D10 | **Lock render sizes**: one video for the LARGEST screen's pixel size (what the phase-2 still/video path already uses), file `lock-<W>x<H>.mov` + `lock-<W>x<H>.json` metadata (`LockRenderCache.Meta`) in the item's folder; stale = other size, other `LockRenderCache.engineRevision`, or other `sourceStamp`. | Plan says `lock-<WxH>.mov`; the sidecar makes invalidation cheap and testable without the engine. |
| D11 | **Universal binary for releases** (`UNIVERSAL=1` on macos-14, dry-run input to switch to arm64 only). | Intel Macs still exist on macOS 13-15; the workflow dry run proves the universal build before the first tag. |
| D12 | **Phase-2 files are edited minimally by the scaffold** (listed in 2.3): `Model.swift` and `IPC.swift` (Core, extended), `SettingsModel.swift` (snapshot built from the last written state, `muted`, `sameForBoth`, `lockConfig`, `assign`, status accessors), `Workshop.swift` (`WorkshopItem.isImportable`). The Orchestrator and WallpaperWindows compile unchanged through phase-2 accessors on `LibraryState` (they behave as before for videos: desktop-driven). | Five workers fork from this commit; the scaffold must compile and keep phase-2 behaviour. |
| D13 | **Shared Wallpaper Engine assets are optional and fetched lazily** (STEAM, section 4.8). M0 renders image layers from the scene's own `.pkg`; assets matter from M1 (shaders, effects, particles). | Avoids a multi-GB download for the common image-only scene; the depot id is UNVERIFIED so the feature degrades to "unavailable" instead of blocking Steam setup. |
| D14 | **The host has a `--probe <scene.pkg>` command line mode** (prints the analysis as JSON). | The only way for the user to test the parser/analyzer on real scenes without UI, and to report bugs with data. |

---

## 1. Architecture and process lifecycle

### 1.1 Processes

```
LiveWallpaper.app                       Settings (SwiftUI). Only writer of state.json (plus StateStore.setMuted).
  Contents/MacOS/LiveWallpaper          Links Core + SceneFormat (analysis at import). Downloads, Steam wizard, UI.
  Contents/Library/LoginItems/
    LiveWallpaperAgent.app              Headless AppKit player + status item. Links Core ONLY (~16 MB). Never networks.
    LiveWallpaperSceneHost.app          Metal scene player + offline lock renderer. Links Core + SceneFormat + SceneEngine.
```
Launch rules: the user starts Settings; Settings starts the agent (phase 2). **The agent starts the host**, only when a scene is the current item of an enabled target (desktop) or needs a lock video that is not cached, and quits it (`HostCommand.quit`) 10 s after neither is true. The host also quits on its own when (a) the agent process is gone (checked every 2 s with `kill(pid, 0)`, pid from `HostCommand.agentPID`), (b) it has been idle 15 s, (c) SIGTERM/SIGINT. Settings never launches or talks to the host.

### 1.2 The agent has two channels

`Orchestrator` keeps one **channel** per `WallpaperTarget` (`desktop`, `lock`), each with: its `TargetConfig` (from `state.config(for:)`), `currentID`, a rotation timer (`interval(for:)`, `rotates(_:)`), and its own apply path:

| Item kind | Desktop channel | Lock channel |
|---|---|---|
| video | `WallpaperWindowManager.show(url:)` (phase 2) | `LockScreenWallpaper.apply(from: url)` (phase 2: tile ~3 min, Aerial swap; macOS 13-15 still) |
| scene | `SceneHostClient.send(.showScene)`; agent windows are hidden once the host reports `.playing`/`.fallbackStill` | cached `lock-<W>x<H>.mov` if `LockRenderCache.isValid`, else `SceneHostClient.send(.renderLock)`; when the render finishes, `LockScreenWallpaper.apply(from: cached .mov)` |

Rules:
- `start(at:)` starts every enabled target with at least one item; `at` (phase-2 `videoID`) selects that item on both channels, nil uses each target's `selectedID`, else the first playable item of its list.
- `AgentCommand.target` (nil = both) scopes `play` and `next`. `pause`/`resume`/`stop`/`start` are global. `reload` re-reads state.json and applies the DIFF per channel: changed `selectedID` of a target switches that channel to it; `enabled` false restores that target (desktop: hide windows; lock: `lock.restore()`); interval/rotate changes re-arm only that channel's timer; `muted` changes are applied to the player and the host; a removed current item moves that channel on. A channel never restarts its current item when only the other channel's config changed.
- `failedIDs` stays one set (a file that cannot be played on one channel will not play on the other). A scene that fails on the desktop host (`sceneState == .failed`) or whose lock render fails is added to `failedIDs` with a message and the channel moves on; a `.fallbackStill` scene is NOT a failure (it shows its preview).
- Desktop and lock may show the same item or different ones; the lock install path still coalesces overlapping applies (phase 2) and keeps its 30 s minimum between installs.
- `AgentStatus.currentID` = desktop item, `lockID` = lock item, `lockBusy` = a lock video is being converted/installed OR rendered, `lockRender` = the render job (queued/rendering/finished/failed with progress), `sceneHostRunning`, `muted` (state.json value).

### 1.3 Host IPC (Core/HostIPC.swift)

Agent -> host: `HostCommand` on `HostIPC.commandName`; host -> agent: `HostStatus` on `HostIPC.statusName`. Payloads are property lists of scalars (UUIDs as strings, paths as strings). Handlers run on the main actor; observers are selector-based with `.deliverImmediately`.

Handshake: the agent launches the host (`SceneHostClient.start()`), then sends `.ping` every 1 s until the first `HostStatus` arrives (the host posts a hello status as soon as it listens; commands sent before are lost, which is why the agent re-pings). Hello timeout 10 s -> `onTerminated(true)`. Commands queued by the agent before the hello are flushed on it.

Reliability: every command has an `id`; the host de-duplicates the last 32 ids and answers every command, executed or not, with a status whose `reply` is the id. The agent retransmits an unanswered command after 1.5 s and 3 s; no answer after 4.5 s -> the host is unresponsive: `NSRunningApplication.terminate()` it, report `onTerminated(true)`. Statuses carry `seq` (per host pid); the agent ignores older ones.

Commands:

| Kind | Fields used | Host behaviour |
|---|---|---|
| `ping` | | answer |
| `showScene` | `itemID`, `scenePath`, `previewPath`, `assetsPath`, `muted`, `fpsCap` | load, open windows (section 1.4); replaces a running scene (the old one is released AFTER the new one presented its first frame) |
| `hideScene` | | close windows, release GPU resources (`SceneRenderer.releaseGPUResources`), `sceneState = .none` |
| `setPaused` | `paused` | stop/start the frame pump (windows stay) |
| `setMuted` | `muted` | stored; no audio in M0 |
| `renderLock` | `jobID`, `itemID`, `scenePath`, `previewPath`, `assetsPath`, `width`, `height`, `fps`, `loopSeconds`, `outputPath` | one job at a time; a new `renderLock` while one runs cancels the old job first |
| `cancelRender` | `jobID` | abort, delete the partial file, `jobState = .cancelled` |
| `quit` | | answer, close windows, exit |

Status: `sceneState` (`none, loading, playing, paused, fallbackStill, failed`), `sceneItemID`, `sceneMessage`; `jobID`, `jobState` (`idle, rendering, finished, failed, cancelled`), `jobProgress`, `jobMessage`; `residentMB` (physical footprint); `quitting`. The host posts a status on every state change and at least every 0.5 s while a job renders (progress), plus the reply to each command.

### 1.4 Desktop scene handover, crash, covered desktop

Sequence for "desktop item becomes a scene":
1. Agent keeps its video windows as they are (they show the previous item) and sends `showScene` (launching the host first if needed).
2. Host posts `sceneState = .loading`; it loads and prepares the renderer, opens one borderless window per screen at the SAME level as the agent's (`desktopWindow + 1`), `canJoinAllSpaces/stationary/ignoresCycle/fullScreenAuxiliary`, ignores mouse events; draws the first frame; posts `.playing` (or `.fallbackStill` when the analysis says `previewOnly` or a load/shader/texture error occurred and the preview image is shown instead).
3. On `.playing`/`.fallbackStill` the agent calls `windows.hide()` (closes its windows and releases its player) and sets `statusMessage` nil. Until then there is no black flash: the previous wallpaper stays up. A `.failed` status makes the agent mark the item failed and move on (`windows` untouched).

"Desktop item becomes a video while a scene is showing": the agent calls `windows.show(url:)` first (its windows go in front of the host's because they are created later at the same level), then sends `hideScene`. If no scene is needed any more the host exits after 10 s (agent timer).

Screens: the host rebuilds its windows on `NSApplication.didChangeScreenParametersNotification` (same as the agent) and after wake (1 s delay). The agent does not hand over per-screen state: both processes cover all screens.

Covered desktop and sleep: the host observes window occlusion (all windows not `.visible`) -> stops the pump; after 10 s covered it calls `releaseGPUResources()` (textures and pipelines; the parsed document stays) and `prepare()`s again when uncovered. Display sleep/`willSleep` pauses; wake rebuilds windows. Battery: the agent sends `fpsCap` 30 on battery and 60 on power with `showScene`; when the power source changes it repeats `showScene` for the same `itemID` and `scenePath`, which the host treats as "update `fpsCap` and `muted`" without reloading.

**Host crash.** `SceneHostClient` watches `NSWorkspace.didTerminateApplicationNotification` for the host's bundle id. If it ends while the agent still wants it (a scene on the desktop or a render running): restart it, resend `showScene` / `renderLock` (the render with the SAME job id); back-off 1 s, 2 s, 4 s; after 3 unexpected exits within 2 minutes the item that was loading is added to `failedIDs` ("This scene keeps crashing the scene player and was skipped.") and the channel advances. The agent itself is unaffected. Visible wallpaper meanwhile: a crash while `.loading` leaves the previous wallpaper up (the agent hides its windows only after `.playing`). A crash while `.playing` takes the host's windows with it; the agent then re-shows the last VIDEO it displayed (`lastVideoURL`, kept for exactly this) until the restarted host reports `.playing` again, and if there never was one, Apple's own desktop picture is visible for the few seconds of the restart. That gap is a known limitation (section 9.1).

**Quit.** `Orchestrator.shutdown` sends `quit` to the host and force-terminates it after 2 s.

### 1.5 Lock screen render pipeline

Trigger: the lock channel's current item is a scene (any support level; `previewOnly` scenes render a static loop of the preview image) and `state.isEnabled(.lock)`.

1. Size: `LockScreenWallpaper.largestScreenPixelSize()` (make it `static` internal; today it is private) rounded to even integers = `(W, H)`.
2. Cache: `LockRenderCache.isValid(for: item, width: W, height: H)` -> `lock.apply(from: LockRenderCache.videoURL(...))` and done. (The cached file is a plain HEVC `.mov`; the phase-2 path tiles it to ~3 min and swaps it into the Aerial slots, or stills on macOS 13-15 using `VideoStills`.)
3. Otherwise the agent sets `lockRender = LockRenderStatus(itemID, .queued)`, starts the host if needed and sends `renderLock(jobID: UUID().uuidString, width: W, height: H, fps: 30, loopSeconds: scene.loopSeconds (may be nil), outputPath: LockRenderCache.videoURL(...).path)`. The lock channel keeps the PREVIOUS lock wallpaper meanwhile.
4. Host: `LockVideoRenderer.render` (SceneEngine) at `.utility` priority (`Task.detached(priority: .utility)` plus `ProcessInfo.beginActivity(.background)`), progress via status every 0.5 s. Writes `lock-WxH.partial.mov` through `AVAssetWriter` (HEVC, `AVVideoCodecType.hevc`, bitrate ~ 0.07 bits per pixel per frame capped 40 Mbit/s, no audio), then renames to `lock-WxH.mov`, then writes the metadata (`LockRenderCache.writeMeta`) and calls `LockRenderCache.removeStale(keeping W x H)`; posts `jobState = .finished`.
5. Agent on `.finished`: re-checks `isValid` and, if it is still the current lock item, `lock.apply(from:)`; `lockRender = .finished` for 3 s then nil. On `.failed`: `lockRender = .failed(message)`, the item joins `failedIDs`, `statusMessage = "Couldn’t render “<title>” for the lock screen."`, and the channel advances if rotating.
6. **Loop**: `LoopPlan.choose(scenePeriod: scene.loopSeconds, fps:)` — a known period repeats to at least 10 s with no crossfade, otherwise 20 s with a 2 s cross-fade (formula in `LoopPlan.swift`). Frame `i` shows `f(t)` or, in the first `crossfadeFrames`, `(1-a) f(t+T) + a f(t)`; the renderer is asked for times up to `T + crossfade`. M0 scenes are stateless, so one `SceneRenderer` renders both sources (two encodes + one blend per crossfade frame).
7. **Cancellation**: the lock channel moved to another item, the lock target was disabled, the agent quits, or the resolution changed -> `cancelRender(jobID)`; the host stops within one frame, deletes the partial file and posts `.cancelled`. A job still running when the SAME item is re-selected is reused (no second job).
8. **Resolution change** (`didChangeScreenParametersNotification`, debounced 3 s): new `(W, H)`; if the lock item is a scene and the new size has no valid cache -> cancel + re-render; otherwise just re-apply. Old sizes are deleted by `removeStale` after the new file exists.
9. **Invalidation**: size differs; `LockRenderCache.engineRevision` bumped; `sourceStamp` (size + mtime of `scene.pkg`) differs (item re-downloaded); the user removes the item (folder deleted by Settings, phase 2 rule). A missing/empty `.mov` with metadata present is treated as invalid.
10. Disk: one finished video per scene (about `W*H*fps*20*0.07/8` bytes; ~50-90 MB at 2560x1440).

Progress reaches the UI as `AgentStatus.lockRender` (state, 0...1, message) plus `lockBusy = true`.

### 1.6 Mute

`LibraryState.muted` (default true). The video player: `AVQueuePlayer.isMuted = muted`; while muted, audio tracks of the item are disabled once the item is ready (`AVPlayerItemTrack.isEnabled = false`) so the audio decoder idles; toggling re-enables them. Sound plays only while the desktop is visible: the player is already paused when occluded or asleep; additionally the agent mutes/pauses the desktop player while the screen is locked (it already observes `com.apple.screenIsLocked/Unlocked` in LockScreen.swift; expose the callback). The lock screen file never has audio (phase 2 converts without audio; the scene renderer writes none). Scenes: `setMuted` is passed to the host and stored (M3 uses it). Menu bar item "Mute Sound" (checkmark) calls `StateStore.setMuted` and applies it at once; Settings shows the same toggle and picks changes up from the next status.

### 1.7 State flow (unchanged principle)

Settings writes `state.json` (`StateStore.commit`, revision + 1) and sends `.reload(revision)`. The agent re-reads the FILE and applies the diff (`fresh.revision != applied.revision`). Phase-2 files migrate in memory on load (`LibraryState.init(from:)`); `StateStore.loadOrMigrate` (Settings only) rewrites a schema 1 file as schema 2 once and keeps `state.v1-backup.json`. The agent only reads. The single exception is `StateStore.setMuted` (D3).

---

## 2. Targets, files, owners, line budgets

### 2.1 Targets

| Target | Kind | Depends on | Links (must / must not) |
|---|---|---|---|
| `Core` | library | – | Foundation, CoreGraphics, CoreMedia, AVFoundation, UniformTypeIdentifiers; no SwiftUI/AppKit/Combine/Metal |
| `SceneFormat` | library | – | Foundation ONLY (builds on Linux) |
| `SceneEngine` | library | Core, SceneFormat | Foundation, CoreGraphics, ImageIO, Metal, AVFoundation; no AppKit/SwiftUI |
| `LiveWallpaperAgent` | executable | Core | AppKit; must NOT link SwiftUI, Metal, SceneEngine, SceneFormat (build.sh fails) |
| `LiveWallpaperSceneHost` | executable | Core, SceneFormat, SceneEngine | AppKit, Metal; no SwiftUI |
| `LiveWallpaper` | executable | Core, SceneFormat | SwiftUI, AppKit; must NOT contain SceneEngine (build.sh fails) |
| `CoreTests`, `SceneFormatTests` | tests (XCTest, run by `swift test` in both workflows) | Core / SceneFormat | pure checks, never touch `~/Library` |

### 2.2 Files and owners (every file has exactly one owner)

| File | Owner | Budget (lines) | State in scaffold |
|---|---|---|---|
| `Sources/Core/Model.swift`, `IPC.swift`, `HostIPC.swift`, `SceneCache.swift` | scaffold (frozen) | – | complete |
| `Sources/SceneFormat/LoopPlan.swift` | scaffold (frozen) | – | complete |
| `Sources/SceneFormat/Archive.swift` | SCENEPARSE | 220 | stub (PKG, sources) |
| `Sources/SceneFormat/Tex.swift` | SCENEPARSE | 420 | stub (TEX, LZ4) |
| `Sources/SceneFormat/SceneDocument.swift` | SCENEPARSE | 260 | complete model (contract; add members with defaults only) |
| `Sources/SceneFormat/SceneParser.swift` | SCENEPARSE | 650 | stub (loader, analyzer, capabilities) |
| `Tests/SceneFormatTests/*.swift` (new files; `LoopPlanTests.swift` is scaffold) | SCENEPARSE | 500 | – |
| `Sources/SceneEngine/SceneRenderer.swift` | SCENERENDER | 650 | stub (API + options) |
| `Sources/SceneEngine/SceneShaders.swift` | SCENERENDER | 220 | placeholder |
| `Sources/SceneEngine/SceneTextures.swift` | SCENERENDER | 300 | placeholder |
| `Sources/SceneEngine/LockVideoRenderer.swift` | SCENERENDER | 380 | stub |
| `Sources/LiveWallpaperSceneHost/HostMain.swift` | SCENERENDER | 330 | working IPC skeleton, scene/job parts stubbed |
| `Sources/LiveWallpaperSceneHost/ScenePlayer.swift` | SCENERENDER | 380 | stub |
| `Sources/LiveWallpaperAgent/Orchestrator.swift` | AGENT | 520 (now 282) | phase-2 behaviour |
| `Sources/LiveWallpaperAgent/AgentMain.swift` | AGENT | 340 (now 252) | phase-2 |
| `Sources/LiveWallpaperAgent/WallpaperWindows.swift` | AGENT | 300 (now 260) | phase-2 |
| `Sources/LiveWallpaperAgent/LockScreen.swift` | AGENT | touch only to expose `largestScreenPixelSize` and the lock callback | phase-2 |
| `Sources/LiveWallpaperAgent/SceneHostClient.swift` | AGENT | 260 | stub |
| `Sources/LiveWallpaper/SettingsModel.swift` | SETTINGS | 650 (now ~495) | phase-2 + scaffold additions (D12) |
| `Sources/LiveWallpaper/App.swift` | SETTINGS | 260 | phase-2 |
| `Sources/LiveWallpaper/ContentView.swift` (Library) | SETTINGS | 650 (now 423) | phase-2 |
| `Sources/LiveWallpaper/WorkshopViews.swift` | SETTINGS | 800 (now 690) | phase-2 |
| `Sources/LiveWallpaper/WorkshopDetailView.swift` | SETTINGS | 380 | stub |
| `Sources/LiveWallpaper/SteamWizardView.swift` | SETTINGS | 520 | stub |
| `Sources/LiveWallpaper/Workshop.swift` | STEAM | 1800 (now 1497) | phase-2 + `isImportable` |
| `Sources/LiveWallpaper/SteamTools.swift` | STEAM | 850 | stub (all types + signatures final) |
| `Sources/LiveWallpaper/SteamPTY.swift` | STEAM | 260 | stub |
| `Sources/LiveWallpaper/SceneImport.swift` | STEAM | 260 | stub |
| `Package.swift`, `build.sh`, `scripts/*`, `Resources/*.plist`, `.github/workflows/*`, `README.md`, `LICENSE`, `docs/*` | scaffold (frozen) | – | complete |

If a worker needs a new file it asks the orchestrator (the owner list must stay complete). `Tests/CoreTests` is scaffold-owned; new tests go in new files.

### 2.3 Phase-2 files the scaffold edited (minimal, compile-fixing or contract-bearing)

- `Core/Model.swift`: `VideoItem.scene`, `SceneInfo`, `TargetConfig`, `LibraryState` v2 (phase-2 stored properties became computed accessors on `desktop`/`lock`, so `state.selectedID`, `.rotateEnabled`, `.intervalValue`, `.intervalUnit`, `.applyToDesktop`, `.applyToLockScreen`, `.selectedItem`, `.canStart`, `.canRotate`, `.rotationActive`, `.intervalSeconds`, `.intervalIsClamped` still compile and mean "the desktop config; written through to the lock config while `sameForBoth`"), `StateStore` (migration, `setMuted`, `diskSchema`, commit keeps disk `muted`), `AppPaths` (`steamToolsDirectory`, `steamHomeDirectory`, `sharedAssetsDirectory`). The memberwise `LibraryState` init changed shape; the only phase-2 caller (`SettingsModel.snapshot`) was rewritten.
- `Core/IPC.swift`: `version = 2`, `AgentCommand.target`, `AgentStatus.lockID/muted/sceneHostRunning/lockRender`, `LockRenderStatus`.
- `LiveWallpaper/SettingsModel.swift`: `snapshot` starts from `written`; new `sameForBoth`, `lockConfig`, `muted`, `lockID`, `lockRender`, `roles(of:)`, `assign(_:to:)`, `changeMuted`; status adoption of newer revisions.
- `LiveWallpaper/Workshop.swift`: `WorkshopItem.isImportable` only. `download(_:)` still rejects scenes (`item.isVideo`); STEAM switches it to `isImportable` when `SceneImporter` works.
- Plists: versions 3.0 / build 3; new `SceneHost-Info.plist`.


---

## 3. Contracts

The scaffold files are the contract; this section explains what each signature MEANS and who may call what. **Appendix A is a generated digest of every declaration (names, types, labels) in the contract files**; when this text and the files differ, the files win and the orchestrator must be told. Compile-against-stubs rule: every worker's files compile against the scaffold stubs of the other workers' files, so any worker can build and typecheck alone (section 9.3).

### 3.1 Core (frozen; `public`)

`Model.swift`
- `WallpaperTarget { desktop, lock }` (`CaseIterable`, `Identifiable`, `label`), `ItemKind { video, scene }`, `SceneSupport { full, partial, previewOnly }`.
- `SceneInfo` (Codable): `support`, `notes: [String]`, `designWidth/designHeight`, `loopSeconds: Double?`, `needsSharedAssets`, `analysisRevision`. Built by STEAM's importer from `SceneAnalysis` (`SceneSupport(rawValue: analysis.support.rawValue)`).
- `VideoItem`: new `scene: SceneInfo?`, `kind`, `isScene`; `init(... , scene:)` last parameter. For a scene: `path` = `Library/<id>/scene.pkg` (or the folder's `scene.json` when a Workshop scene is not packed), `previewPath` = preview image, `workshopID` set, `title/author/tags` from the Workshop.
- `TargetConfig { enabled, selectedID, playlist: [UUID]?, rotateEnabled, intervalValue, intervalUnit; intervalSeconds, intervalIsClamped }`.
- `LibraryState { schema (=2), revision, videos, muted, sameForBoth, desktop, lock }` with:
  - `config(for:)` effective config (lock mirrors desktop except `enabled` while `sameForBoth`), `items(for:)` (playlist resolved, missing ids dropped), `selectedItem(for:)`, `isEnabled(_:)`, `canPlay(_:)`, `hasMultipleItems(_:)`, `rotates(_:)`, `interval(for:)`, `targets(of:)` (enabled targets whose selection is that id), `canStart`, `usesScenes`.
  - `normalize()` (idempotent), `assign(_ id:, to: Set<WallpaperTarget>)`: one target while `sameForBoth` turns it off and keeps the other target's old config; both leaves it alone; the chosen targets become enabled.
  - phase-2 accessors (desktop config, written through while `sameForBoth`): `selectedID, rotateEnabled, intervalValue, intervalUnit, applyToDesktop, applyToLockScreen, selectedItem, canRotate, rotationActive, intervalSeconds, intervalIsClamped`.
  - Codable: a file without `desktop` and with `schema < 2` is read as v1 and mapped to `sameForBoth = true`, shared selection/rotation/interval, `desktop.enabled = applyToDesktop`, `lock.enabled = applyToLockScreen`, `muted = true`. Encoding writes v2 only. `intervalValue` is clamped to 1...999 on decode.
- `StateStore`: `load()`, `diskSchema()`, `commit(&state)` (Settings only; keeps the on-disk `muted`, bumps revision, normalizes), `setMuted(_:)` (Settings and agent), `loadOrMigrate(defaults:)` (Settings only; rewrites schema 1 once and keeps `state.v1-backup.json`).
- `AppPaths`: + `steamToolsDirectory` (`SteamCMD/`), `steamHomeDirectory` (`SteamHome/`), `sharedAssetsDirectory` (`WallpaperEngineAssets/`).

`IPC.swift`: `IPC.version = 2`; `AgentCommand.target: WallpaperTarget?` (init parameter `target:` sits after `revision:`); `LockRenderStatus { itemID, state (queued, rendering, finished, failed), progress, message }`; `AgentStatus` adds `lockID`, `muted`, `sceneHostRunning`, `lockRender` (appended init parameters, all defaulted). Wire keys: command `target`; status `lockCur`, `muted`, `host`, `lrItem`, `lrState`, `lrProg`, `lrMsg`.

`HostIPC.swift`: `HostIPC { version, bundleID, bundleName, role, commandName, statusName }`, `HostCommand` (+ `Kind`), `HostStatus` (+ `SceneState`, `JobState`), `HostEndpoint` (host side: `onCommand`, `startListening()`, `post(_:)`), `HostClientEndpoint` (agent side: `onStatus`, `startListening()`, `send(_:)`). Same compile rules as `AgentEndpoint` (SPEC2 9.1).

`SceneCache.swift`: `LockRenderCache { engineRevision, Meta, folder(for:), videoURL/partialURL/metaURL(for:width:height:), sourceStamp(for:), readMeta, writeMeta, isValid, removeStale }`.

### 3.2 IPC v2 behaviour additions (AGENT implements, SETTINGS consumes)

- `play`/`next` honour `target`. Status after EVERY handled command as before (the reply carries the result).
- `AgentStatus.currentID` desktop item, `lockID` lock item. SETTINGS must treat nil `lockID` as "nothing on the lock screen" and the phase-2 meaning of `currentID` as "desktop".
- `lockRender`: present while a render is queued/running and for 3 s after it ended (`finished`/`failed`), nil otherwise.
- `message` stays one user-facing line (blocked reasons first, then playback problems, then lock render failures).

### 3.3 SceneFormat public API (SCENEPARSE implements; SCENERENDER, STEAM consume)

Files: `Archive.swift`, `Tex.swift`, `SceneDocument.swift`, `SceneParser.swift`, `LoopPlan.swift` (frozen). All `public`, Foundation only, `Sendable` values.

```swift
public enum SceneFormatError: Error, Equatable, LocalizedError { notImplemented, truncated, badMagic, invalid, missingFile, unsupported }
public protocol SceneFileSource: AnyObject, Sendable { displayName; fileExists(_:); data(at:) throws; allPaths() }
public final class PKGArchive: SceneFileSource      // init(data:displayName:) throws, convenience init(contentsOf:) throws
public final class DirectorySource: SceneFileSource // init(root:)
public final class LayeredSource: SceneFileSource   // init(primary:fallback:)
public enum TexPixelFormat / TexPayload / struct TexFlags / TexMipmap / TexFrame / TexImage
public enum LZ4 { static func decompress(_:decompressedSize:) throws -> Data }
public enum TexDecoder { static func decode(_ data: Data) throws -> TexImage }
public struct Vec2, Vec3; enum BlendMode; SceneCamera; SceneGeneral; EffectInstance; ImageLayer; enum SceneObjectKind; SceneObject; SceneDocument
public struct EngineCapabilities { ...; static let milestone0; static let current }
public enum SceneSupportLevel { full, partial, previewOnly }; enum SceneFeature; struct SceneAnalysis { static let revision; ... }
public struct LoadedScene { files; document; analysis }
public enum SceneLoader { load(packageAt:sharedAssets:capabilities:) throws; load(directory:sharedAssets:capabilities:) throws; parseDocument(sceneJSON:files:) throws }
public enum SceneAnalyzer { static func analyze(document:files:capabilities:) -> SceneAnalysis }
public struct LoopPlan { init(loopSeconds:crossfadeSeconds:fps:); source(forFrame:); static func choose(scenePeriod:fps:) }
```
Path conventions: `SceneFileSource` paths are the paths inside the `.pkg` (`scene.json`, `models/x.json`, `materials/x.json`, `materials/x.tex`, `particles/...`, `effects/...`), lower or mixed case as stored; lookups are case-insensitive. `ImageLayer.texturePath` is always a `.tex` path that exists in the source or nil when it could not be resolved (then the analyzer reports `missingTexture`). `SceneDocument.objects` is in file order = draw order, back to front. Units: scene units with y up, origin of an object = its centre; `SceneGeneral.designWidth/Height` is the orthogonal projection size; the camera centre defaults to `(designWidth/2, designHeight/2)`.

Stability rules: SCENEPARSE may ADD fields to the document types with default values; renaming or removing needs the orchestrator. `SceneAnalysis.revision` is bumped whenever the analyzer's verdict for the same input can change (new rules, or `EngineCapabilities.current` changes); `SceneImporter.reanalyze` uses it.

### 3.4 SceneEngine public API (SCENERENDER implements; the host consumes)

```swift
public struct ParallaxInput { x, y: Float; static let zero }                 // pointer relative to screen centre, -1...1, y up
public struct RenderOptions { pixelWidth, pixelHeight, pixelFormat, textureBudgetBytes, fitMode (.fill/.fit) }
public enum SceneRendererError: Error, LocalizedError { notImplemented, noGPU, textureFailed, shaderFailed, encodeFailed }
public final class SceneRenderer {
    public let options: RenderOptions; public let designSize: CGSize
    public private(set) var supportsRandomAccessTime: Bool; public private(set) var residentTextureBytes: Int
    public static var capabilities: EngineCapabilities { get }
    public init(scene: LoadedScene, device: MTLDevice, options: RenderOptions) throws
    public init(previewImage: CGImage, device: MTLDevice, options: RenderOptions) throws
    public func prepare() throws
    public func encode(at time: Double, parallax: ParallaxInput, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws
    public func releaseGPUResources()
}
public struct LockRenderRequest { scenePath, previewPath, assetsPath, outputURL, pixelWidth, pixelHeight, fps, loopSeconds }
public enum LockRenderError: Error { notImplemented, cancelled, sceneUnreadable, noGPU, writerFailed }
public enum LockVideoRenderer { public static func render(_ request: LockRenderRequest, progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> Double }
```
Semantics:
- **Time-driven.** `encode(at:)` is a pure function of `time` (plus parallax) in M0 (`supportsRandomAccessTime == true`). The live player passes `time = wall clock since the scene started`; the lock renderer passes `LoopPlan.source(forFrame:)` times. Nothing in the renderer reads the clock, the display link or the pointer.
- The caller owns the command buffer: live = `commandBuffer.present(drawable)`; commit; offline = commit + `waitUntilCompleted()` (or completion handler) then copy to the writer's `CVPixelBuffer`.
- The render target has `options.pixelFormat` (default `.bgra8Unorm`) and `.renderTarget` usage; the scene is fitted by `options.fitMode` (`.fill` like `resizeAspectFill`) from `designSize` to the target.
- `init(previewImage:)` exists so previewOnly scenes and failed scenes have a visible result through the same pipeline.
- Memory: textures stay compressed (BC1/2/3 = `.bc1_rgba/.bc2_rgba/.bc3_rgba`), 8-bit formats otherwise, mip chains only when the layer is drawn smaller than its texture; resident textures are capped by `textureBudgetBytes` with least-recently-drawn eviction; `releaseGPUResources()` drops everything but the parsed document. A frame that needs more than the budget draws what fits and the analyzer's note says so.
- Extension points for M1 to M3 without breaking the above: `encode` stays the only draw entry point; effects add passes inside it (ping-pong targets owned by the renderer); particles and scripts make `supportsRandomAccessTime` false (the lock renderer then renders strictly in order and builds a SECOND renderer for the crossfade source); audio is a separate `SceneAudio` object owned by the host, not the renderer; SceneScript (JavaScriptCore) runs on the renderer's queue before encoding; puppets add a skeleton evaluated per `time`. `EngineCapabilities.current` is the only switch the analyzer reads.

### 3.5 Scene host (SCENERENDER) — `HostMain.swift`, `ScenePlayer.swift`

- `@main enum HostEntry { @MainActor static func main() }` (not `main.swift`), `HostDelegate: NSObject, NSApplicationDelegate` with property-default members (no `override init()`), single instance by `LSMultipleInstancesProhibited`.
- `--probe <scene.pkg> [--assets <dir>]` prints `{support, notes, used, unsupported, design, objects, needsSharedAssets}` as JSON and exits 0, or prints `probe failed: ...` to stderr and exits 1. No windows, no IPC.
- `HostDelegate.handle(_ command: HostCommand)`: the switch over `HostCommand.Kind` (all cases). Every command ends with `postStatus(reply: command.id)`.
- `ScenePlayer` (`@MainActor`): `onChange: (HostStatus.SceneState, String?) -> Void`, `state`, `itemID`, `show(itemID:scenePath:previewPath:assetsPath:fpsCap:)`, `hide()`, `setPaused(_:)`, `setMuted(_:)`, `setFPSCap(_:)`. `show` with the same `itemID` and `scenePath` only updates caps/mute.
- Render jobs run in `HostDelegate` (a `Task` stored for cancel); the job fields of `HostStatus` are the only output. One job at a time; the job writes `<outputPath>.partial.mov`, renames it, then writes `LockRenderCache.Meta` (`engineRevision = LockRenderCache.engineRevision`, `sourceStamp = LockRenderCache.sourceStamp(for:)` of a `VideoItem(path: scenePath)` built just for that call) and calls `LockRenderCache.removeStale`.
- Footprint: `HostStatus.residentMB` = `task_info(TASK_VM_INFO).phys_footprint / 1 MB`.

### 3.6 Agent additions (AGENT)

`SceneHostClient` (stub signatures in the file): `onStatus`, `onTerminated(unexpectedly:)`, `isRunning`, `isReady`, `lastStatus`, `static hostAppURL`, `static hostProcessExists()`, `start()`, `send(_:)`, `shutdown()`. It imports only AppKit and Core. Orchestrator changes are specified in 1.2 and 1.5; the observable additions are `currentID(for:)`, `lockRender`, `sceneHostRunning`, `muted` in `status(reply:)`; `AgentMain` adds the status line `Desktop: Playing “X” · Lock Screen: Rendering 42%` (see 6.5), the `Mute Sound` item and per-target Next.

### 3.7 Settings surfaces (SETTINGS consumes STEAM)

`SettingsModel` additions already in the scaffold: `sameForBoth`, `lockConfig`, `muted`, `lockID`, `lockRender`, `roles(of:)`, `assign(_:to:)`. SETTINGS adds the per-target rotation controls on top (bind to `rotateEnabled/intervalValue/intervalUnit` for the desktop and to `lockConfig` for the lock screen while `!sameForBoth`), `play(_:target:)` (sends `AgentCommand(kind: .play, videoID:, target:)`), and the library row state described in 6.2.

`WorkshopDetailView(model:workshop:item:close:openSteamSetup:)`, `AnimatedImageView(image:)`, `WorkshopPreviewLoader.load(_:)`, `SteamWizardView(setup:)` exist as stubs with these exact initializers; SETTINGS fills them and wires `WorkshopView`/`RootView` (replace `SteamSetupView` by the wizard plus an "Advanced" disclosure that keeps the phase-2 API key and manual SteamCMD path fields).

### 3.8 Steam surface (STEAM implements; SETTINGS consumes) — `SteamTools.swift`

All internal to the Settings target. Types: `SteamArch`, `SteamToolsInfo`, `SteamInstallStep`, `SteamToolsState`, `SteamCodeKind`, `SteamSignInStep`, `SteamAccountState`, `SteamOwnershipState`, `SteamAssetsState`, `SteamWizardStep`, `SteamSetupError` (with `title`/`message` copy), `SteamPrompt`, `SteamPromptClassifier.classify(_:)`.

`@MainActor final class SteamSetupModel: ObservableObject` (`static let shared`): published `tools`, `account`, `ownership`, `assets`, `username`, `lastError`; derived `step`, `canDownload`, `steamcmdPath`; methods `refresh()`, `installTools()`, `cancelInstall()`, `signIn(username:password:)`, `submitGuardCode(_:)`, `cancelSignIn()`, `signOut()`, `checkOwnership()`, `prepareSharedAssets()`, `confirmSharedAssets()`, `removeSharedAssets()`.

Integration points STEAM must keep working for the phase-2 views until SETTINGS replaces them: `WorkshopModel.setup` (`SteamSetupStatus`) is computed from `SteamSetupModel.shared` (tools ready -> `steamcmdPath`, Rosetta rule, `login` from `account`); `WorkshopModel.prerequisites()` uses `SteamSetupModel.steamcmdPath` first, then the phase-2 locator; every steamcmd run (download, login, ownership, assets) goes through ONE gate so two runs never overlap (`SteamRunGate`, a private main-actor flag in SteamTools.swift: wizard actions are refused with "A download is running" while `WorkshopModel.hasActiveDownloads`, and downloads wait while a wizard action runs).

Scene import: `SceneImporter.importScene(_ input: SceneImportInput) async throws -> VideoItem`; `reanalyze(_:)`. Called from the import step in `Workshop.swift` when `project.json` says `"type": "scene"` (case-insensitive); the video path is untouched. Errors are `WorkshopError.importFailed(detail)` with the user-facing detail (no stack, no paths).

---

## 4. Steam wizard, SteamCMD installer, pty and assets (owner: STEAM; views: SETTINGS)

### 4.1 Rules (non-negotiable)

1. SteamCMD comes from Valve, downloaded by the app when the user presses **Install Steam tools**. It is never bundled in the app, the DMG or the repo (Valve's SteamCMD license restricts redistribution). Fixed URL, https only: `https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz` (the macOS download listed on Valve's developer wiki "SteamCMD"; fetched successfully during phase 2, file size about 2.5 MB). Valve publishes no checksum, so integrity is TLS only; the app shows the size and does not execute anything before extraction succeeded.
2. Only the user's own Steam account that owns Wallpaper Engine (app 431960). No anonymous login, no shared or borrowed accounts, no third-party downloader sites, no Web scraping. The Web API calls of phase 2 (SPEC2 4.1) are unchanged.
3. The password and Steam Guard code: typed into app fields -> `[UInt8]` -> pty. Never in argv, environment, a file, `UserDefaults`, Keychain, a `@Published` property, a log, an error string or the clipboard. After the write the byte buffer is zeroed and the SwiftUI field is cleared. Captured steamcmd output is scrubbed before anything else sees it (ANSI removed, secret occurrences replaced by `••••`). The username is not secret and is remembered in `UserDefaults`.
4. SteamCMD keeps only its own cached login token on disk; the app has no copy. **Sign out** deletes that token (4.5).
5. No Wallpaper Engine file is ever committed, bundled or redistributed (`.gitignore` already excludes build output; add nothing from the Workshop or assets to the repo, tests build fixtures in memory).

### 4.2 Install Steam tools

Detection order in `SteamSetupModel.refresh()` (no network, no process except `lipo`/`arch`): (1) app-managed `AppPaths.steamToolsDirectory/steamcmd.sh`; (2) the phase-2 locations (`steamcmdPathOverride`, `/opt/homebrew/bin/steamcmd`, `/usr/local/bin/steamcmd`, Caskroom glob, `~/steamcmd/steamcmd.sh`, `~/Steam/steamcmd.sh`) -> `managedByApp = false`. If none: `tools = .missing`.

`installTools()` (all steps report `tools = .installing(step)`):
1. `downloading`: `URLSession` download task to a temp file with progress delegate (`fraction`). Errors -> `SteamSetupError.downloadFailed(localized reason)`.
2. `extracting`: list first (`/usr/bin/tar -tzf`), refuse entries that are absolute or contain `..`, then `/usr/bin/tar -xzf <file> -C AppPaths.steamToolsDirectory`; `chmod 755` on `steamcmd.sh` and `steamcmd`. Errors -> `extractFailed`.
3. `firstRun`: run `steamcmd.sh +quit` with `HOME=AppPaths.steamHomeDirectory`, `TERM=dumb`, stdin `/dev/null`. SteamCMD updates itself on first start (minutes; "Downloading update (x of y KB)" lines drive `note`/progress; idle timeout 120 s, 600 s while updating, hard limit 15 min). It may need two runs (the launcher restarts with exit code 42 internally; the script handles it). Errors -> `firstRunFailed(last useful line)`.
4. `checking`: architecture and Rosetta (4.3). Result -> `.ready(SteamToolsInfo)` or `.rosettaRequired`.
`cancelInstall()` terminates the process and deletes a half-written directory.

### 4.3 Architecture and Rosetta (the only place Rosetta may be mentioned)

- The real binary: the launcher script runs `<dir>/steamcmd`, else `<dir>/Steam.AppBundle/Steam/Contents/MacOS/steamcmd`. Run `/usr/bin/lipo -archs <binary>` (fallback `/usr/bin/file -b`) -> `arm64`, `x86_64`, both (`universal`) or `unknown`. Verified in phase 2: the downloaded tarball's `steamcmd` was x86_64 only (`file`); whether Valve's self-update installs an arm64 build is **UNVERIFIED** (the user reports SteamCMD running on Apple silicon without a Rosetta prompt).
- Apple silicon test: `sysctlbyname("hw.optional.arm64")` == 1 (not `#if arch(arm64)`, the app itself may run translated).
- Rosetta is mentioned ONLY when the Mac is Apple silicon AND the binary has no arm64 slice AND Rosetta is missing. Missing = `/usr/bin/arch -x86_64 /usr/bin/true` exits non-zero (or prints "Bad CPU type"). Then `tools = .rosettaRequired` and the card offers `softwareupdate --install-rosetta --agree-to-license` ([Copy command], [Open Terminal]; the install needs an administrator, so the app does not run it) and "Check again".
- Any later steamcmd output with `Bad CPU type` (the classifier) re-enters `.rosettaRequired`.

### 4.4 Sign-in through a pseudo-terminal

Process: `<steamcmd.sh> +login <username> +quit`, environment `HOME=AppPaths.steamHomeDirectory`, `TERM=dumb`, plus the inherited environment minus anything named like `STEAM_*`/`*PASSWORD*`. The username is validated with the phase-2 rule (`^[A-Za-z0-9_.-]{2,64}$`, no leading `+`/`-`) so it can never become another steamcmd command. No `+@NoPromptForPassword` here (we want the prompt).

`SteamPTYSession` (SteamPTY.swift): `posix_openpt/grantpt/unlockpt/ptsname`, master fd read on a background `DispatchSource`, slave opened three times for `Process.standardInput/Output/Error`; echo off verified with `tcgetattr` on the master before the first secret write; output scrubbed; the session ends when the process exits. Plan B (UNVERIFIED which one works): `/usr/bin/script -q /dev/null <steamcmd.sh> ...` over plain pipes.

Driver (`SteamSetupModel.signIn`): feed the scrubbed output delta since the last action to `SteamPromptClassifier.classify`, act, then reset the delta window:

| Classifier result | Action | `account` |
|---|---|---|
| `.passwordPrompt` (first time) | write the password + `\n`, wipe | `.signingIn(.working("Signing in…"))` |
| `.passwordPrompt` again after a send | wrong password re-prompt: kill | `.signedOut`, error `.badPassword` |
| `.guardCode(kind)` | wait for the user | `.signingIn(.needsCode(kind, previousWasWrong: codesSent > 0))` |
| after `submitGuardCode` | write code + `\n`, wipe | `.working("Checking the code…")` |
| `.mobileApproval` | keep waiting (up to 120 s) | `.signingIn(.needsMobileApproval)` |
| `.badCode` | if fewer than 3 codes sent: back to waiting; else kill | `.needsCode(kind, previousWasWrong: true)` / error `.badCode` |
| `.badPassword` | kill | error `.badPassword` |
| `.rateLimited` | kill | error `.rateLimited` |
| `.rosettaMissing` | kill | `tools = .rosettaRequired` |
| `.failed(line)` | kill | error `.loginFailed(line)` |
| `.signedIn` | remember the username, wait for exit (`+quit`) up to 10 s then terminate | `.signedIn(username:)` |
| nothing recognised, process alive, no new output for 20 s | stop acting | `.signingIn(.unrecognizedPrompt(lastLines:))`; buttons [Copy details] [Cancel] [Sign in with Terminal] |
| no progress for 5 min overall | kill | error `.guardTimedOut` |

`cancelSignIn()` terminates the process (SIGTERM, SIGKILL after 2 s) and wipes any pending secret.

**Classifier (pure, tolerant).** Input: the scrubbed text since the last action. Normalise: remove ANSI (`ESC[...letters`), resolve carriage-return redraws (keep text after the last `\r` of each line), strip trailing spaces, lower-case copy for matching (the original casing is kept for `failed(line)`), look only at the last 2000 characters. First match wins, in this order:

| # | Pattern (lower-cased) | Result |
|---|---|---|
| 1 | `bad cpu type` | `.rosettaMissing` |
| 2 | `rate limit exceeded`, `too many login failures`, `too many retries`, `account logon denied` + `rate` | `.rateLimited` |
| 3 | `invalid password` (also inside `failed (invalid password)` and `login failure: invalid password`) | `.badPassword` |
| 4 | `two-factor code mismatch`, `invalid login auth code`, `incorrect` + `code`, (`code` or `steam guard`) + (`wrong`, `invalid`, `mismatch`, `expired`) | `.badCode` |
| 5 | `logged in ok`, `waiting for user info...ok` | `.signedIn` |
| 6 | `confirm the login in the steam mobile app`, `approve` + (`sign in` or `login` or `log in`) + `app`, `waiting for confirmation`, `check your phone` | `.mobileApproval` |
| 7 | last line contains `steam guard code`, `two-factor code`, `enter the code`, `enter your code` -> kind: tail mentions `email`, `e-mail` or `sent to` -> `.email`; mentions `mobile`, `authenticator`, `two-factor` or `app` -> `.authenticator`; else `.unknown` | `.guardCode(kind)` |
| 8 | last line (trimmed) matches `password\s*:$` | `.passwordPrompt` |
| 9 | a line matching `failed.*\((.+)\)` or `login failure: (.+)` | `.failed(group 1)` |
| 10 | a line starting `error!` | `.failed(rest of line)` |
| – | otherwise | `.none` |

Required unit vectors (STEAM adds them to its harness copy; expected result in brackets): `"Steam>password: "` [`.passwordPrompt`]; `"\u{1B}[0mPassword:\r\nPassword: "` [`.passwordPrompt`]; `"This computer has not been authenticated for your account using Steam Guard.\nPlease check your email for the message from Steam, and enter the Steam Guard\ncode from that message.\nYou can also enter this code at any time using 'set_steam_guard_code'\nat the console.\nSteam Guard code:"` [`.guardCode(.email)`]; `"Two-factor code:"` [`.guardCode(.authenticator)`]; `"Steam Guard code:"` alone [`.guardCode(.unknown)`]; `"Please confirm the login in the Steam Mobile app on your phone."` [`.mobileApproval`]; `"FAILED (Invalid Password)"` [`.badPassword`]; `"Login Failure: Invalid Password"` [`.badPassword`]; `"FAILED (Two-factor code mismatch)"` [`.badCode`]; `"FAILED (Rate Limit Exceeded)"` [`.rateLimited`]; `"Logging in user 'x' to Steam Public...OK\nWaiting for client config...OK\nWaiting for user info...OK"` [`.signedIn`]; `"Logged in OK"` [`.signedIn`]; `"/bin/sh: ... Bad CPU type in executable"` [`.rosettaMissing`]; `"ERROR! Failed to install app"` [`.failed("Failed to install app")`]; `"Loading Steam API...OK"` [`.none`]. The Guard-code sample above is the text commonly reported for SteamCMD; the exact current wording, whether SteamCMD supports mobile approval or QR sign-in, and whether it prompts for the code on the same pty line are **UNVERIFIED** (real-account test T3-T5, section 9.2).

### 4.5 Account state, sign out, ownership

- `refresh()` does NOT log in (frequent logins risk rate limits). It sets `account = .signedIn(username)` when a username was stored AND the token file exists under the app's private HOME (`SteamHome/Library/Application Support/Steam/config/config.vdf` contains the account name; layout **UNVERIFIED**), else `.signedOut`. A visible **Check sign-in** button (and the first download) runs `steamcmd.sh +@NoPromptForPassword 1 +login <user> +quit`: `Logged in OK` -> `.signedIn`, otherwise `.signedOut`.
- Does SteamCMD honour `HOME` on macOS (so the token stays inside `SteamHome`)? **UNVERIFIED**. After the first successful sign-in the model checks that `SteamHome/Library/Application Support/Steam/config/config.vdf` exists; if not it records `tokenLocation = .sharedWithSteamClient` (in `UserDefaults`) and sign out only runs `+logout` and shows: "Steam’s tool keeps its login in Steam’s normal folder. To remove it completely, sign out in the Steam app." The app never edits or deletes files under the user's real `~/Library/Application Support/Steam`.
- `signOut()`: runs `+logout` best effort (5 s), deletes `AppPaths.steamHomeDirectory` (the isolated token and caches), clears the stored username state, `account = .signedOut`, `ownership = .unknown`. Refused while a download runs.
- `checkOwnership()`: `steamcmd.sh +@NoPromptForPassword 1 +login <user> +licenses_print +quit`. Any output line containing `431960` -> `.owned`; output that contains `License packageID` lines but not `431960` -> `.notOwned` (the UI hedges: "…unless the game comes through Steam Family Sharing"); no recognisable licence list -> `.couldNotCheck("Steam didn’t list your games. You can still try a download.")`. Format of `licenses_print` and whether Wallpaper Engine's package lists app 431960: **UNVERIFIED** (test T6). A rejected download with `No subscription` later also sets `.notOwned`.

### 4.6 User-facing copy of the wizard (exact; SETTINGS puts it in views, STEAM in `SteamSetupError`)

| Card / state | Title | Body | Buttons |
|---|---|---|---|
| Install tools, `.missing` | Install Steam’s download tool | Live Wallpaper downloads Steam’s official command-line tool (SteamCMD, about 3 MB) from Valve. It is used only to download wallpapers you ask for, with your own Steam account. | **Install Steam tools** |
| `.installing(.downloading)` | Downloading… | (progress bar, "x of y MB") | Cancel |
| `.installing(.extracting)` | Unpacking… | | |
| `.installing(.firstRun(note))` | Setting up Steam’s tool | Steam’s tool updates itself the first time it runs. This can take a few minutes. `note` | Cancel |
| `.installing(.checking)` | Checking… | | |
| `.rosettaRequired` | Rosetta is needed | Steam’s tool is built for Intel Macs and this Mac needs Rosetta to run it. Install it once, then press Check again. | **Copy command** (`softwareupdate --install-rosetta --agree-to-license`), Open Terminal, Check again |
| Sign in, `.signedOut` | Sign in to Steam | Use the Steam account that owns Wallpaper Engine. Your password goes straight to Valve’s tool. Live Wallpaper never stores it. | Username, Password, **Sign in** |
| `.signingIn(.starting/.working)` | Signing in… | | Cancel |
| `.needsCode(.email, _)` | Steam Guard code | Steam sent a code to your email. Enter it here. | Code field, **Continue**, Cancel |
| `.needsCode(.authenticator, _)` | Steam Guard code | Open the Steam Mobile app and enter the current code. | same |
| `.needsCode(.unknown, _)` | Steam Guard code | Steam wants a Steam Guard code. Enter the newest one you have. | same |
| `.needsCode(_, previousWasWrong: true)` | (same) | That code didn’t work. Enter the newest one. | same |
| `.needsMobileApproval` | Approve on your phone | Open the Steam Mobile app and approve the sign-in. This window continues by itself. | Cancel |
| `.unrecognizedPrompt` | Steam is waiting for something unexpected | Live Wallpaper doesn’t recognise Steam’s last message. You can sign in using Terminal instead. `lastLines` in a monospaced box | **Copy details**, **Copy Terminal command** (`steamcmd +login <username>` with the app’s tool path), Cancel |
| Ownership, `.checking` | Checking Wallpaper Engine… | | |
| `.notOwned` | Wallpaper Engine isn’t on this account | Steam doesn’t show Wallpaper Engine for **name**. Downloads need an account that owns it. | Sign out, Check again |
| `.couldNotCheck(reason)` | Couldn’t confirm Wallpaper Engine | reason | **Continue anyway**, Check again |
| Done, `.owned` | You’re all set | Signed in as **name**. Wallpaper Engine found. | **Sign out**, Check again |
| Errors | `SteamSetupError.title` / `.message` | (strings in SteamTools.swift) | Retry where it makes sense |
| Footer (always) | | Not affiliated with Valve or Wallpaper Engine. Downloads use Valve’s own SteamCMD with your own account, for your personal use on this Mac. Workshop items belong to their creators; don’t redistribute them. | |

### 4.7 Scene import (STEAM, `SceneImporter`)

Called when `project.json` has `"type": "scene"` (any case) after steamcmd succeeded. Content folder contents (UNVERIFIED but expected): `project.json`, `scene.pkg`, `preview.jpg|png|gif`, sometimes loose scene folders instead of a pkg.
1. Choose the scene source: `project.json.file` if it names a `.pkg` that exists, else `scene.pkg`, else the first `*.pkg`, else a folder with `scene.json`. None -> `importFailed("This wallpaper has no scene file.")`.
2. Copy into `Library/<id>.partial/` as `scene.pkg` (a loose scene: the whole folder as `Library/<id>.partial/scene/` and `path` = `.../scene/scene.json`), `project.json`, `preview.<ext>`; then rename to `Library/<id>/` (replacing an older copy, same rule as videos). Size cap 3 GB.
3. Analyse: `SceneLoader.load(packageAt:sharedAssets: AppPaths.sharedAssetsDirectory if it exists)`; on success `SceneInfo(support: SceneSupport(rawValue: analysis.support.rawValue)!, notes: analysis.notes, designWidth/Height, loopSeconds, needsSharedAssets, analysisRevision: SceneAnalysis.revision)`. On a parse error: import anyway as `previewOnly` with note "This scene’s files couldn’t be read, so only its preview is shown." (needs a preview image; without one -> `importFailed`).
4. `VideoItem(path: .../scene.pkg, title: project title ?? Workshop title, author, workshopID: id, previewPath:, tags:, scene: info)`; `onImport` on the main actor; `.done(videoID:)`.
5. `reanalyze(_:)` is used at launch for items whose `analysisRevision` differs from `SceneAnalysis.revision` (Settings replaces the item through `addImported`).

### 4.8 Wallpaper Engine shared assets (optional, UNVERIFIED territory)

Why: M1+ effects, particles and many materials reference files that ship with Wallpaper Engine (`assets/` next to the game), not with the scene. M0 does not need them; the analyzer sets `needsSharedAssets` when a referenced path is missing from the `.pkg` and exists in no layer. Fetch only on request (**Get shared files** in Steam Setup, offered when an imported scene needs them, or in Advanced).

Discovery (`prepareSharedAssets`, `assets = .discovering`): `steamcmd.sh +@NoPromptForPassword 1 +login <user> +app_info_print 431960 +quit`; parse the VDF output: `depots` section; candidates = depots with a `manifests > public` entry, `config > oslist` containing `windows` or absent, no `config > language`, no `dlcappid`; choose the largest by `size` (fallback `download`). Which depot contains `assets/` is **UNVERIFIED** (the main Windows content depot is the best guess; do not hard-code an id). Nothing found or unparsable -> `.unavailable("Live Wallpaper couldn’t find Wallpaper Engine’s shared files on Steam. Scenes that need them will show their preview only.")` and an escape hatch "Choose a folder…" where the user points at an `assets` folder of their own copy (copied to `AppPaths.sharedAssetsDirectory`).

Confirmation: `.needsConfirmation(downloadBytes:depotName:)` -> text "Steam will download about **X GB** of Wallpaper Engine files to your Mac, keep the shared scene files (about Y) and delete the rest. Continue?" Disk check: free space >= 1.2 x size else `.failed(.diskSpace)`.

Fetch (`confirmSharedAssets`, `.fetching`): `steamcmd.sh +@sSteamCmdForcePlatformType windows +force_install_dir <staging>/assets-<n> +login <user> +download_depot 431960 <depot> +quit` (idle timeout 300 s; progress by polling the folder size against `size`). Then move `<...>/steamapps/content/app_431960/depot_<id>/assets` (directory name UNVERIFIED; if absent, the folder containing `shaders/` or `materials/` is used) to `AppPaths.sharedAssetsDirectory`, delete the staging tree, `assets = .ready(folder:)`. `removeSharedAssets()` deletes the folder. These files are the user's own licensed copy, stored in their own Library for their own use; never uploaded, never committed (the test suite and CI never download them).

### 4.9 Errors that must never leak a secret

Every `SteamSetupError` string, log line and `lastLines` goes through `Scrubber.scrub(_:secrets:)` (ANSI strip + secret replacement + redact anything matching `\b[0-9A-Z]{5}\b` right after "code" when a code was sent). Logging uses `NSLog`/`print` only for scrubbed text and only in DEBUG builds. Crash/diagnostic copy ("Copy details") contains the last scrubbed lines and the steamcmd version string, never environment dumps.

---

## 5. Scene format notes (SCENEPARSE; SCENERENDER reads 5.3 to 5.5)

Sources and licensing of the knowledge. **PKG and TEX layouts** were read from the source of RePKG (github.com/notscuffed/repkg, **MIT**; files `PackageReader.cs`, `TexReader.cs`, `TexHeaderReader.cs`, `TexImageContainerReader.cs`, `TexImageReader.cs`, `TexMipmapDecompressor.cs`, `TexFrameInfoContainerReader.cs`, enums `TexFormat`, `TexFlags`, `FreeImageFormat`) on 2026-10-20. Only the byte layout and enum values were taken; no code was copied, the Swift is written from this description. Marked **[V]** below = verified against that source. **`scene.json`, model/material JSON and parallax semantics** are NOT in an MIT source I could read: they come from general knowledge of how these files look and from the public designer documentation (docs.wallpaperengine.io, which documents the editor, not the file format). They are marked **[U]** (UNVERIFIED) and the parser must treat every such key as optional and tolerate other types. The GPL scene renderers named in the README were deliberately not consulted for this section. Nothing here was run against a real file.

### 5.1 `.pkg` container [V]

All integers little-endian `int32`. `string` = `int32 length` + that many bytes (UTF-8).
```
string  magic                     e.g. "PKGV0001" (max 32 bytes)
int32   entryCount
entryCount x { string path (max 255 bytes), int32 offset, int32 length }
(data section starts here)
```
`offset` is relative to the start of the data section (the byte after the last entry); `length` bytes follow. Paths use `/`. Checks (hostile input): `entryCount` <= 100 000, path length <= 255, `0 <= offset`, `length >= 0`, `offset + length` within the file, no overflow in `Int`; duplicate paths: last wins; lookups case-insensitive. Typical entries: `scene.json`, `models/*.json`, `materials/*.json`, `materials/*.tex`, `particles/*.json`, `effects/**`, `shaders/**`, `scripts/**`, `sounds/*.mp3|ogg|wav`.

### 5.2 `.tex` texture [V]

```
cstring magic1  "TEXV0005"        (null terminated, max 16)
cstring magic2  "TEXI0001"
int32 format      0 RGBA8888 | 4 DXT5 | 6 DXT3 | 7 DXT1 | 8 RG88 | 9 R8
int32 flags       bit 1 NoInterpolation | bit 2 ClampUVs | bit 4 IsGif (sprite sheet) | bit 32 IsVideoTexture (others unknown)
int32 textureWidth, textureHeight, imageWidth, imageHeight
uint32 unknown
-- image container --
cstring magic     "TEXB0001" .. "TEXB0004"
int32   imageCount
  TEXB0003:  int32 imageFormat           (FreeImage format id)
  TEXB0004:  int32 imageFormat, int32 isVideoMp4   (imageFormat -1 + isVideoMp4 == 1 means MP4)
  (TEXB0001/2: none)
imageCount x {
  int32 mipmapCount
  mipmapCount x mip   (layout by container version, see below)
}
-- if flags & IsGif: frame table --
cstring magic     "TEXS0001" | "TEXS0002" | "TEXS0003"
int32   frameCount
  TEXS0003: int32 gifWidth, gifHeight
  TEXS0001: frameCount x { int32 imageId, float32 frameTime, int32 x, y, width, widthY, heightX, height }
  TEXS0002/3: frameCount x { int32 imageId, float32 frameTime, float32 x, y, width, widthY, heightX, height }
```
Mip layout: container v1: `int32 width, int32 height, int32 byteCount, bytes`. v2 and v3: `int32 width, height, int32 isLZ4Compressed, int32 decompressedSize, int32 byteCount, bytes`. v4 is treated as v3 unless the image format is MP4 (RePKG downgrades v4 to v3 for non-video); the MP4 variant prefixes each mip with `int32 1 (must be 1), int32 2 (must be 2), cstring conditionJson, int32 1 (must be 1)` and then reads like v3. `isLZ4Compressed == 1` -> bytes are an LZ4 BLOCK (no frame header) that decompresses to `decompressedSize`. `imageFormat` (FreeImage ids): -1 unknown, 0 BMP, 2 JPEG, 13 PNG, 17 TARGA, 18 TIFF, 24 DDS, 25 GIF, 35 MP4 (full table in RePKG). If `imageFormat != -1` the (decompressed) mip bytes are a complete encoded image file of that type and `format` is ignored for decoding; otherwise the bytes are raw pixels in `format`: RGBA8888 = 4 B/px (R,G,B,A), RG88 = 2 B/px, R8 = 1 B/px, DXT1/3/5 = BC1/BC2/BC3 blocks (8/16/16 bytes per 4x4 block). Mip 0 is the largest. Sizes: `textureWidth/Height` are the padded storage size, `imageWidth/Height` the picture inside; the picture occupies the top-left `imageWidth x imageHeight` of the texture (**[U]**: UV scale = image/texture size).

Limits (hostile input): imageCount <= 8 (only the first is exposed), mipmapCount <= 16, width/height <= 16384, byteCount and decompressedSize <= 512 MB and consistent with `width*height*bpp` (compressed formats: block math), total allocation per texture <= 1 GB, every read bounds-checked, LZ4 decoder checks every literal/match length and offset against both buffers.

M0 handling: RGBA8888/RG88/R8/DXT -> `TexImage` with `.pixels`; embedded PNG/JPEG -> `.image(ext)` (SCENERENDER decodes with ImageIO); GIF-flag sprite sheets -> frame 0 only and the analyzer reports `animatedTextures`; MP4 / `IsVideoTexture` -> `.video`, unsupported in M0.

### 5.3 `scene.json` and what it references [U]

Top level (all optional): `"version"`, `"general"`, `"camera"`, `"objects"`.
- `general`: `clearcolor` ("r g b" floats 0...1 as a string), `orthogonalprojection` `{ "width": 1920, "height": 1080 }` (design size; default 1920x1080), `cameraparallax` (bool), `cameraparallaxamount` (default 1), `cameraparallaxdelay` (default 0.1), `cameraparallaxmouseinfluence` (default 1), `bloom` (bool, post effect), `hdr` (bool); also `zoom`, `fov`, `nearz`, `farz`, `ambientcolor`, `skylightcolor`, lighting keys (ignored).
- `camera`: `center`, `eye`, `up`, each "x y z" string.
- `objects[]`: common keys `id` (int), `name`, `origin` ("x y z"), `angles` ("x y z" degrees), `scale` ("x y z"), `size` ("w h"), `visible` (bool), `parent` (object id), `alpha`, `color` ("r g b"), `brightness`, `parallaxDepth` ("x y"), plus ONE kind key:
  - `image`: path of a model json (e.g. `"models/foo.json"`); also `effects: [ { "file": "effects/x/effect.json", "id", "name", "visible", "passes": [...] } ]` (image layers only), `colorBlendMode` (int, Photoshop-like; ignored in M0).
  - `particle`: path of a particle json; `sound`: array of paths + `playbackmode`, `volume`; `text`/`light`/`model` (3D) variants; an object with none of these but `origin` is a group.
- Any scalar may be replaced by an object `{ "value": <v>, "user": "<property>" }` (bound to a user property) or `{ "value": <v>, "script": "<code>" }` (SceneScript) or with `"animation"`; the parser takes `value`, sets `hasUserProperties`/`hasScripts` and carries on. Booleans may arrive as `true`/`false` or 0/1; vectors as strings ("1 2 3"), as arrays, or as a single number meaning all components.
- Model json (`models/foo.json`): `"material"` (path of a material json), `"autosize"` (bool), `"width"`, `"height"`, `"puppet"` (skeletal data path), `"cropoffset"`. Resolution of `sourceSize`: explicit width/height, else the texture's `imageWidth x imageHeight`.
- Material json (`materials/foo.json`): `"passes": [ { "shader": "genericimage2", "blending": "translucent", "cullmode", "depthtest", "depthwrite", "textures": ["foo"], "combos": {...}, "constantshadervalues": {...} } ]`. Texture names map to `materials/<name>.tex`. Pass 0 provides `texturePath` (first texture), `shader`, `blend`.
- `blending` mapping used by the parser: `translucent` -> `.normal`; `normal` -> `.normal`; `additive` -> `.additive`; `opaque` and `disabled` -> `.opaque`; `multiply` -> `.multiply`; `screen` -> `.screen`; anything else -> `.unknown` (drawn as `.normal`, reported). (**[U]** the exact vocabulary; `translucent` and `additive` are the common ones.)

Geometry conventions the renderer assumes (section 9.2 T10; the file-space and camera parts were checked against a real
Workshop scene and are now **verified**, the rest stays **[U]**): orthographic camera, scene units = pixels of the
design size, y up; a layer is a quad of `size` (or the texture's picture size) centred on `origin.xy`, scaled by
`scale.xy` **once**, rotated by `angles.z` degrees about its centre; draw order = `objects` order; `parent` composes
transforms (child origin is in the parent's space); `visible == false`, `alpha == 0` and hidden parents skip the object;
colour = texture * `color` * `brightness`, alpha = texture alpha * `alpha`. Fitting the design size to the screen uses
`resizeAspectFill` semantics.

**Coordinates.** The file's coordinates are y down with the origin at the design's top left. The document model
mirrors every origin (`y' = designHeight - y`) so the world is y up, but the parent chain is composed in the FILE
space and mirrored once at the end (`world = T(0, designHeight) * flipY * fileChain * flipY`). Mirroring every
ancestor's translation instead adds the design height once per level and pushes children off the design; the
content frame is flipped once, which also turns the file's clockwise angle into the world's counter-clockwise one.

**Camera.** `camera.center` is a file value. `[0, 0]` means "no camera offset" and falls back to the design centre;
the check has to happen before the y flip, because `(0, 0)` mirrors to `(0, designHeight)` and would otherwise look
like a real offset and shift the whole scene into one corner.

Parallax (M0, **[U]** magnitudes): enabled when `general.cameraparallax` is true. Smoothed pointer `p` in -1...1 (exponential smoothing with time constant `cameraparallaxdelay` seconds, driven by `time`, so offline renders are deterministic: parallax `.zero`). Per layer offset in scene units: `offset = -p * cameraparallaxamount * cameraparallaxmouseinfluence * parallaxDepth * K` with `K = 0.02 * designWidth` as a tunable constant in one place (`SceneRenderer.parallaxScale`). The offline lock render uses `.zero`. Wrong magnitudes only change how far layers slide; they are a tuning item, not a correctness risk.

### 5.4 What M0 supports and ignores

Supported: image layers with decoded `.tex` (all `TexPixelFormat`s and embedded PNG/JPEG), object transform (origin, angles z, scale, size), parent transforms, visibility, alpha, colour tint and brightness, blend modes normal/opaque/additive/multiply/screen, scene clear colour, camera parallax from the pointer (live) or none (offline), fit/fill to the screen, sprite sheets as frame 0.
Ignored (reported, never fatal): effects (`effects[]`, including `colorBlendMode` and post effects `bloom`/`hdr`), particles, sounds and music, SceneScript and property bindings (the `value` is used), user properties, puppet/skeletal animation, text, lights, 3D models, video textures, additional passes beyond pass 0, masks (extra textures of pass 0), cursor interaction.

### 5.5 Support badge rules (`SceneAnalyzer`) and note wording

Inputs: the document, a header-only decode of every texture of a visible image layer, `EngineCapabilities`. Output `SceneAnalysis.support`:

1. **previewOnly** if any of: `scene.json` missing or unparsable (the loader throws and the importer falls back, 4.7); there is no visible image layer whose texture exists and decodes (`noRenderableLayer`); every renderable layer is an effect carrier only (no texture) — treated as no renderable layer.
2. **partial** if not previewOnly and any of: a visible effect on a visible layer while `capabilities.effects == false`; any particle / sound / script / puppet / text / light / 3D object while the capability is false; any user-property binding while `userProperties == false`; animated or video textures; an unknown blend mode; a visible image layer whose texture is missing or undecodable (`missingTexture` / `undecodableTexture`, with `needsSharedAssets` set when the path is not in the `.pkg` and looks like a shared asset); bloom/hdr post effects.
3. **full** otherwise.
`notes` holds one sentence per distinct reason, in this order, max 5, each at most 80 characters:

| Feature | Note |
|---|---|
| effects | "Effects (water, glow, …) are not supported yet and are skipped." |
| particles | "Particles are not supported yet." |
| sound | "Sound isn’t supported yet." |
| scripts | "Scripted behaviour isn’t supported yet." |
| puppet | "Character animation isn’t supported yet." |
| text, lights, model3D | "Some objects (text, lights, 3D) are skipped." |
| userProperties | "User settings of this wallpaper aren’t supported yet." |
| animatedTextures | "Animated textures show their first frame only." |
| unknownBlendMode | "A blend mode isn’t supported and is drawn as normal." |
| missingTexture / undecodableTexture | "Some images are missing or unreadable." |
| sharedAssetsNeeded | "Needs Wallpaper Engine’s shared files (Steam Setup)." |
| bloom/hdr | "Glow and colour post-processing are skipped." |
| previewOnly | "Only the preview image is shown." |

`loopSeconds`: M0 returns nil (a parallax-only scene is static and has no period). `designWidth/Height` from `general.orthogonalprojection` rounded, default 1920x1080.

---

## 6. UX spec (SETTINGS builds, AGENT does the menu)

Principles: phase-2 look and tone; sentence case; the curly apostrophe (’) in user-facing text; nothing is silent when it fails; no jargon ("scene host" never appears in the UI).

### 6.1 Window

Segmented sections stay `Library | Workshop | Steam Setup`. The agent pill and banners are as in phase 2. New banner (priority after the existing ones): none.

### 6.2 Library

Row (each item): thumbnail, title, subtitle (author · size/resolution as in phase 2), then **badges**:
- Role badges (capsules, accent colour): `Desktop` when `roles(of:)` contains `.desktop`, `Lock Screen` for `.lock`; both -> two capsules. Shown only for enabled targets. While the agent runs, the badge of the CURRENT item of each target uses the filled style, others the outlined style.
- Kind/support badge for scenes: `Scene` (full), `Scene · Partial`, `Scene · Preview only` (secondary colour; help text = the joined `scene.notes`). Videos show no kind badge.
- Lock render state for a scene that is the lock item: subtitle line replaced by `Rendering for lock screen… 42%` with a thin progress bar while `lockRender.state == .rendering` for this item; `Waiting to render for lock screen…` for `.queued`; `Couldn’t render this for the lock screen.` (orange) for `.failed` (help text = `message`); nothing when finished.
- Existing states (playing/paused/unplayable) keep their phase-2 glyphs.

Actions per item (context menu AND a **Set as** menu button on the row and the preview pane): `Set as Desktop`, `Set as Lock Screen`, `Set as Both` (the check mark shows the current role). Each calls `SettingsModel.assign(_:to:)`; if the agent is not running nothing starts, the wallpaper changes when the user presses Start. If the agent is running, the change applies at once (`.reload`). Double-click = `Set as Both` + `play` (phase-2 double-click semantics).

Bottom bar / settings panel (replaces the "Rotate / Apply to" block):
- Toggle **Same wallpaper for desktop and lock screen** (on by default). On: one rotation setting block. Off: two blocks titled **Desktop** and **Lock Screen**, each with: switch `Show on desktop` / `Show on lock screen` (= enabled), `Rotate wallpaper` toggle, `Every [N] [seconds|minutes|hours]` (minimum 5 s message as phase 2), and `Playing now: “title”` (from `currentID` / `lockID`).
- Toggle **Mute sound** (default on). Help: "Videos play silently. The lock screen never has sound."
- Start/Stop, Pause: unchanged.

Empty and error states: unchanged from phase 2, plus the scene-specific notes in the preview pane (below).

Preview pane: video items as before. Scene items show the preview image (animating if GIF), the support badge, the notes as a short bullet list, and if `needsSharedAssets` a link button `Get Wallpaper Engine’s shared files` that opens Steam Setup.

### 6.3 Workshop detail pane

Clicking a result card (not its buttons) opens a detail pane to the right of the grid (min width 320, replaces the grid below 760 pt window width with a back button `‹ Results`). Content, top to bottom:
1. Preview: `AnimatedImageView` filling the width (aspect fit, max height 320, rounded 8), spinner while loading, `photo` placeholder on failure. After the item is in the library the pane switches to the library item's preview (video: the phase-2 muted looping `AVPlayerView`; scene: its preview image + support badge).
2. Title (title2), author (secondary) if known.
3. Chips: kind (`Video`/`Scene`/`Web`/`Application`), resolution tag, rating tag, size (`ByteCountFormatter`, hidden when 0), subscriptions (`12,345 subscribers`) when known.
4. Tags (wrapping chips, tags already shown as chips excluded).
5. Description (callout, selectable, scrolls; "No description." in secondary when empty).
6. Primary button: `Download` (disabled with the phase-2 reason text when setup is incomplete, with `Set up Steam…` as a secondary link); while downloading the phase-2 progress row with Cancel; after: `Set as Desktop`, `Set as Lock Screen`, `Set as Both`, `Show in Library`. Unsupported kinds: the phase-2 explanation text (`Web and application wallpapers can’t be played.`) and no Download.
7. Footer link `Open on Steam` (https://steamcommunity.com/sharedfiles/filedetails/?id=<id>).
Keyboard: Esc closes the pane. VoiceOver: the preview has the title as label.

### 6.4 Steam Setup tab

`SteamWizardView`: a vertical stack of cards (4.6) where only the card for `setup.step` is expanded and earlier completed steps collapse to one line with a green check ("Steam tools installed · arm64", "Signed in as name", "Wallpaper Engine found"). Below: an **Advanced** disclosure containing the phase-2 fields (Steam Web API key for browsing, manual SteamCMD path, `Check sign-in`, `Sign out`, `Shared files` row with Get/Remove). The sign-in form: Username (`TextField`, remembered), Password (`SecureField`, cleared on submit and when the view disappears), `Sign in` default button, disabled until both are non-empty. A second line under the form: "Your password goes straight to Valve’s tool and is never stored."

### 6.5 Agent menu (AppKit, AGENT)

```
Desktop: Playing “Title”                    (disabled; "Desktop: Stopped" / "Desktop: Paused · “Title”" / "Desktop: Off")
Lock Screen: Playing “Title”                (or "Lock Screen: Rendering 42%…", "Lock Screen: Off")
⚠ <message>                                 (hidden when nil, as phase 2)
────────────
Open Settings…                              ⌘,
────────────
Start Wallpaper / Stop Wallpaper
Pause Wallpaper / Resume Wallpaper
Next Desktop Wallpaper                      ⌘→   (disabled unless desktop rotation has more than one item)
Next Lock Screen Wallpaper                       (same rule for the lock channel)
Mute Sound                                  ✓ when muted (toggle; StateStore.setMuted)
────────────
Quit Wallpaper                              ⌘Q
```
When `sameForBoth` is on, a single `Next Wallpaper` replaces the two next items and a single `Playing “Title”` line is shown ("Playing “Title” on desktop and lock screen"). Status item symbol rules as phase 2; while a lock render runs the symbol is unchanged (no animation).

### 6.6 Microcopy list (exact)

Badges: `Desktop`, `Lock Screen`, `Scene`, `Scene · Partial`, `Scene · Preview only`. Menus: `Set as Desktop`, `Set as Lock Screen`, `Set as Both`. Lock render: `Rendering for lock screen… 42%`, `Waiting to render for lock screen…`, `Couldn’t render this for the lock screen.` Agent message on failure: `Couldn’t render “Title” for the lock screen.` Crash loop: `This scene keeps crashing the scene player and was skipped.` Host missing (bundle damaged): `The scene player is missing. Reinstall Live Wallpaper.` Toggle labels: `Same wallpaper for desktop and lock screen`, `Mute sound`. Detail pane: `Download`, `Show in Library`, `No description.`, `Open on Steam`, `‹ Results`.

---

## 7. Release pipeline (scaffold, done; spec for review)

- **Workflow** `.github/workflows/release.yml`: `on: push tags v*` and `workflow_dispatch` (inputs `version` default `0.0.0`, `universal` default true). Job on `macos-14`: resolve version (`v1.2.3` -> `1.2.3`; must match `^[0-9]+(\.[0-9]+){1,3}$` because it becomes `CFBundleShortVersionString`), toolchain print, `swift test`, `VERSION=<v> BUILD_NUMBER=<run number> UNIVERSAL=1 ./build.sh`, `scripts/verify-bundle.sh` (three bundles, ids, equal versions, codesign verify, `lipo`), `scripts/make-dmg.sh` (staging folder with the app via `ditto` + `Applications` symlink, `hdiutil create -format UDZO`, `shasum -a 256`, mounts the DMG and verifies the app inside), upload the DMG and checksum as an artifact (always), and on tags `gh release create vX --title ... --notes-file ... --generate-notes` (or `upload --clobber` if the release exists). `permissions: contents: write`.
- **Version injection**: `build.sh` rewrites `CFBundleShortVersionString` and `CFBundleVersion` in all three Info.plists after copying them (never edits the files in `Resources/`). The agent compares versions to detect a stale process, so all three always match.
- **Signing**: ad hoc, inner first (host, agent, app), no `--deep`. No notarization, no hardened runtime. README documents Open Anyway / `xattr -dr com.apple.quarantine`; the release notes repeat it.
- **Dry run**: Actions > release > Run workflow on `feat-pkg-renderer`; the artifact `LiveWallpaper-<version>-dmg` holds the DMG. Result of the scaffold's own dry run is in the final report.
- Later (not now): a Homebrew tap cask pointing at the release DMG; Sparkle-style updates; notarization if an Apple Developer account appears.

---

## 8. Memory plan and measurement

Budgets (resident/physical footprint, steady state, 1 display 3024x1964 unless noted):

| Process | Idle / video | Scene playing | Lock render |
|---|---|---|---|
| Agent | about 16 MB (measured in phase 2), must stay under 25 MB | same (it only relays) | same |
| Settings | as phase 2 plus ~5 MB (SceneFormat analysis is tiny) | – | – |
| Scene host | not running | target 150-300 MB for a typical image scene; hard budget 400 MB of textures (`RenderOptions.textureBudgetBytes`) plus pipelines; 30 fps cap on battery | one scene's textures + 2 render targets (W x H x 4 x 2) + AVAssetWriter buffers: target below 500 MB at 2560x1440; utility priority |

Rules: BC-compressed textures stay compressed; no mip generation for layers drawn at or below texture size; at most 3 frames in flight (`DispatchSemaphore`); the command queue is created once; after 10 s covered the host calls `releaseGPUResources()`; when the scene is replaced the old renderer is released AFTER the new first frame; after a lock job the offline renderer is released and its textures freed before the next job; the host quits 10 s after the last scene/job. Image decoding via ImageIO uses `kCGImageSourceShouldCache = false` and downsamples with `kCGImageSourceThumbnailMaxPixelSize` when the layer is drawn smaller than the texture.

Measuring on a Mac (the numbers go into the final report of the real-Mac test, section 9.2 T12):
```sh
footprint -p LiveWallpaperAgent        # physical footprint; compare idle / video / with a scene active
footprint -p LiveWallpaperSceneHost
vmmap --summary $(pgrep LiveWallpaperSceneHost) | grep -E "IOSurface|IOAccelerator|Physical footprint"
sudo powermetrics --samplers gpu_power,cpu_power -i 2000 -n 5     # GPU/CPU cost of a playing scene
```
Instruments: Allocations + Metal System Trace on the host while a scene plays and while a lock render runs; Leaks after 10 scene switches (memory must return to within 20 MB of the first scene's steady state). `HostStatus.residentMB` is logged by the agent in DEBUG builds every 5 s while the host runs. Build-time guard (build.sh): agent contains no SwiftUI link, no Metal API use, no SceneEngine/SceneFormat symbols; Settings contains no SceneEngine symbols.

---

## 9. Risks, UNVERIFIED items, real-Mac tests, compile traps, checklists

### 9.1 Risks and known limitations

- **Scene fidelity** will be partial for a long time (effects, particles, scripts come later); the badge and the preview fallback exist so a scene is never a black desktop. M0 may mis-place layers if the geometry assumptions in 5.3 are off (T10).
- **The Aerial swap** used for the lock screen depends on undocumented macOS behaviour (phase 2); macOS updates can break it. The scene lock video rides on it unchanged.
- **Host crash while playing** leaves a gap of a few seconds without a wallpaper of ours (1.4).
- **Third process + GPU/disk load** during lock renders; mitigated by utility priority, one job at a time, cancellation, size-keyed cache, and measurement (section 8).
- **SteamCMD** may change prompts or behaviour (the wizard degrades to the "unrecognised prompt" card with a Terminal fallback). The Intel-only history of the macOS tarball may or may not still hold. Steam can rate-limit logins: the app never logs in on its own except on explicit actions and downloads.
- **HEVC** encoding via `AVAssetWriter` needs a hardware or software encoder; on a Mac without HEVC support the renderer falls back to H.264 (`canApply(outputSettings:)` check) — the lock path accepts both.
- **No notarization**: first launch needs Open Anyway; some users will balk. A Homebrew cask or notarization are the only fixes.
- **Rosetta** availability is time-limited by Apple (a limited version is announced from macOS 28); only relevant if SteamCMD stays Intel-only.
- **Mixed-resolution displays**: the lock video is one size (largest screen); smaller screens scale it (phase-2 behaviour).
- **Legal**: scene files and assets are third-party content; the app handles them only on the user's Mac, from the user's own downloads. See 4.1. Not legal advice.

### 9.2 UNVERIFIED items and the real-Mac tests they need

| ID | UNVERIFIED | Test on a real Mac (with a real account / scenes) |
|---|---|---|
| T1 | Agent launches the host with `NSWorkspace.openApplication(activates=false)`; hello within 2 s; host quits 10 s after the last scene; dies with the agent | `open LiveWallpaper.app`, Start with a scene as desktop item; `pgrep -l LiveWallpaperSceneHost`; Quit Wallpaper; `pgrep` again; `kill -9` the agent and check the host exits within ~4 s |
| T2 | SteamCMD tarball URL still serves; extraction; first-run self-update; `lipo -archs` of the real binary after update; whether Rosetta is needed | Steam Setup > Install on an Apple-silicon Mac without Rosetta and on one with it; record `lipo -archs`, time, and whether macOS shows a Rosetta prompt |
| T3 | The pty approach reaches steamcmd's password prompt (primary) or needs `script` (plan B); echo is off | Sign in with a test account; confirm the password prompt text; check that no password appears in the app's output buffer; `ps aux` during sign-in shows no password |
| T4 | Steam Guard (email) prompt text, accepted input, retries | Account with email Guard: record the exact output; wrong code twice; right code |
| T5 | Mobile-app code prompt vs mobile approval vs QR; text of each | Account with the Steam Mobile authenticator: record outputs; test approval without typing a code |
| T6 | `+licenses_print` format; Wallpaper Engine appears with `431960`; behaviour with a non-owning account | Owning and non-owning accounts; save the (scrubbed) outputs into the report |
| T7 | `HOME` isolation of SteamCMD's token on macOS (`SteamHome/Library/Application Support/Steam/config/config.vdf`) | After sign-in, `find ~/Library/Application\ Support/LiveWallpaper/SteamHome -name config.vdf` and compare with `~/Library/Application Support/Steam`; sign out and check the token is gone |
| T8 | Workshop scene download layout: `project.json type`, `scene.pkg` name, preview file, loose folders | Download 5 different scene items; `ls -R` each content folder; run the importer |
| T9 | PKG/TEX parsing on real files: container/mip versions seen, formats, limits | `LiveWallpaperSceneHost --probe scene.pkg` on 10 scenes; collect the JSON; unit-test fixtures from the observed layouts (bytes built in memory, not copied) |
| T10 | Geometry, draw order, parent transforms, blend modes, parallax scale | File-space composition, the camera default and the scale rule are verified (2026-10-21, Workshop item 3695791724) and covered by `SceneEngineTests`; still to check against a PC render: the exact layer anchor point, the blend vocabulary and the parallax scale |
| T11 | Lock render: HEVC writer on Intel and Apple silicon; the `.mov` plays when installed through the Aerial swap on macOS 26; loop seam invisible | Render a scene lock video; open it in QuickTime with loop; install via the app; lock the screen |
| T12 | Memory/CPU/GPU numbers of section 8 | The commands in section 8 for a video, a scene, a lock render |
| T13 | Shared assets: depots in `app_info_print 431960`, platform override works, `assets` folder name and size | Run Prepare on an owning account; read the confirmation size; fetch; list the result |
| T14 | Release flow: DMG opens, drag install, Open Anyway / `xattr` clear the nested helpers too, helpers launch afterwards | Download the dry-run DMG artifact on a clean user account (macOS 15 and 26), follow the README |
| T15 | Mute: `AVPlayerItemTrack.isEnabled = false` stops the audio decoder; no sound under the lock screen | Play a video with audio unmuted, lock the screen, listen; mute and check CPU |
| T16 | Host crash recovery | `kill -9` the host while a scene plays: agent shows the previous video, restarts the host, scene returns; three kills in 2 minutes skip the item |
| T17 | `CAMetalLayer` windows at desktop level behave like the video windows (Spaces, Mission Control, fullscreen apps, screen sleep) | Walk through the phase-2 window checklist with a scene |

### 9.3 Compile traps (additions to SPEC2 9.1) and the Linux harness

Everything in SPEC2 9.1 still applies. New for phase 3:
- **Targets**: `SceneFormat` must not import Core or any Apple-only framework (Linux). `SceneEngine` must not import AppKit. The agent must not import `SceneFormat`/`SceneEngine`/`Metal`/`SwiftUI` (build.sh fails). Settings may import `SceneFormat` but never `SceneEngine`.
- **Cross-module `public`**: every SceneFormat/SceneEngine/Core declaration used across targets is `public` with a `public init`; default argument expressions must be public-visible (`.current`, `.zero` are). `Sendable` structs holding `Data`/`URL` are fine; classes that are `Sendable` must be `final` with immutable state (`PKGArchive`, `DirectorySource`: the compiler warns about `URL` on Linux; ignore).
- **Property vs method with the same base name** (`LibraryState.canStart` var vs a `canStart(_:)` method) type-checks on Linux but invites ambiguity in comparisons; the scaffold renamed the methods (`canPlay`, `hasMultipleItems`, `rotates`, `interval(for:)`). Keep new APIs distinct from phase-2 property names.
- **Metal**: `MTLDevice`, textures and command buffers are not `Sendable`: keep each renderer on one queue. Shaders are strings compiled with `makeLibrary(source:options:)`; compile errors surface at runtime, so unit-check the source with `xcrun metal` locally when a Mac is available and keep the library creation in a `throws` function that reports `shaderFailed(log)`. Upload buffers use `.storageModeShared`; render targets for offline use `.storageModePrivate` or `.shared` with `getBytes` after `waitUntilCompleted`. `MTLPixelFormat.bc1_rgba/.bc2_rgba/.bc3_rgba` exist on macOS only (fine). `CAMetalLayer.maximumDrawableCount = 2`, `framebufferOnly = true`, `pixelFormat = .bgra8Unorm`. Create `CAMetalLayer` as the view's backing layer (`makeBackingLayer`, as `PlayerView` does for `AVPlayerLayer`), not by assigning `layer` after `wantsLayer`.
- **AVAssetWriter**: `expectsMediaDataInRealTime = false`; append only when `isReadyForMoreMediaData` (wait with `try await Task.sleep` 5 ms, never spin); `await writer.finishWriting()` is available on macOS 12+; use `AVAssetWriterInputPixelBufferAdaptor` with a pixel buffer pool; set `AVVideoColorPropertiesKey` explicitly (BT.709) so the swap path does not change colours; check `status == .failed` and read `writer.error` after every batch.
- **Process and pty** (STEAM): `fork`/`forkpty` are unavailable in Swift; use `posix_openpt/grantpt/unlockpt/ptsname` (stdlib.h) and hand the slave to `Process`. `ioctl` is variadic and unavailable: use `tcgetattr/tcsetattr`. `FileHandle(fileDescriptor:closeOnDealloc:)`. Read the master with a `DispatchSource.makeReadSource` and cancel it on EOF. Zero `[UInt8]` with `withUnsafeMutableBytes { memset_s }` or a loop. `sysctlbyname` needs a sized `UnsafeMutableRawPointer`.
- **Downloads**: `URLSession.download(from:)` async has no progress; use a `URLSessionDownloadDelegate` object (an `NSObject` subclass, `@unchecked Sendable`) and hop to the main actor with `Task { @MainActor [weak self] in }`.
- **SwiftUI ceiling macOS 14** (SPEC2): `scrollTransition`, `scrollPosition`, `defaultScrollAnchor`, `.inspector`, `@Observable`, `ContentUnavailableView` and `#Preview` are all in bounds, so no pre-14 fallbacks. `NSViewRepresentable` for `NSImageView` with `animates = true`.
- **Host entry**: `@main enum HostEntry { @MainActor static func main() }` in `HostMain.swift` (never `main.swift`); the delegate class uses property defaults, never `override init()` with main-actor calls.
- **XCTest** targets use `@testable import`; tests must not touch `~/Library/Application Support` (`AppPaths` are static lets on the real home).

**Linux harness** (scratchpad, not in the repo): `/tmp/claude-0/-home-user-LiveWallpaper/786a77d0-2c1f-5e76-b05e-c0e37879f4e0/scratchpad/linuxcheck3/`
```
cd <your worktree>
S=/tmp/claude-0/-home-user-LiveWallpaper/786a77d0-2c1f-5e76-b05e-c0e37879f4e0/scratchpad
OUT=/tmp/<you>-lw SWIFTC=$S/toolchain/sdk/usr/bin/swiftc  $S/linuxcheck3/run.sh        # Swift 5.10.1 (Xcode 15.4)
OUT=/tmp/<you>-lw6 SWIFTC=$S/toolchain/sdk6/usr/bin/swiftc $S/linuxcheck3/run.sh       # Swift 6.0.3 in -swift-version 5 mode
OUT=/tmp/<you>-lw SWIFTC=$S/toolchain/sdk/usr/bin/swiftc  $S/linuxcheck3/agentcheck.sh # agent files vs AppKitShim (run run.sh first, same OUT)
```
`run.sh` = `prep.py` (copies and strips Core, SceneFormat, the UI-free Settings files `Workshop/SettingsModel/SteamTools/SteamPTY/SceneImport`, the agent files) -> builds Core and SceneFormat as modules -> `scenecheck.swift` (SceneFormat checks: LoopPlan, defaults, stub paths) -> builds the Settings logic files against `SettingsShim.swift`/`CombineShim.swift` -> `main.swift` (about 75 checks: phase-2 behaviour, v1 -> v2 migration on disk, `setMuted`/`commit` interplay, `assign`, IPC v2 and host payload round trips, lock cache validity). Workers copy `scenecheck.swift` / `main.swift` / the shims into a PRIVATE directory and extend them (SCENEPARSE: PKG/TEX/LZ4/scene.json fixtures built in memory; STEAM: classifier vectors of 4.4, scrubber, VDF parsing, arch parsing; AGENT: extend `AppKitShim.swift` for what they add). `agentcheck.sh` also typechecks `SceneHostClient.swift`. Not covered: SceneEngine, the host, all SwiftUI/AppKit views, `WallpaperWindows.swift`, `LockScreen.swift`. `swift test` (XCTest) in CI runs `Tests/CoreTests` and `Tests/SceneFormatTests` on real macOS; those are the only tests that execute against real Foundation on Apple platforms.

### 9.4 Worker checklists and definition of done

All workers: edit only your files (section 2.2); no model names in files/commits; commit trailer exactly `Co-Authored-By: Claude <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01HrtnYnDsaaw2kPbdgkv7mM`; push only your branch; run the harness with BOTH compilers; do not change a contract signature (tell the orchestrator); add tests in new files only.

**AGENT** — implement 1.2 (two channels), 1.3 and 1.4 (`SceneHostClient`: launch, hello/ping, queue, retransmit, crash policy, `lastVideoURL` fallback), 1.5 (lock render trigger/apply/cancel/resolution change/cache check), 1.6 (mute incl. audio tracks and lock-screen suppression), `AgentStatus` fields, the menu of 6.5 (`Mute Sound` through `StateStore.setMuted`), per-target `play`/`next`. Keep the video path and AppKit-only rule; `blockedReason`, `wantsRunning`, single instance, SIGTERM paths unchanged. Done when: the harness (`agentcheck.sh`) passes with an extended shim; `build.sh` guards would pass (no SwiftUI/Metal/Scene* symbols); every command still answers with a status; `shutdown` is idempotent and also quits the host; a changed config of one target never restarts the other; a failed scene is added to `failedIDs` and skipped; a stale `jobID` status is ignored; `lockBusy` is true while a render or conversion runs; `LockRenderCache.isValid` is checked before any render; nothing in the agent reads scene files.

**SETTINGS** — implement 6.1 to 6.4: Library rows (role + scene badges, lock render state), Set-as menus, same-for-both and per-target rotation controls, mute toggle, `play(_:target:)`, Workshop detail pane with animating preview and post-download preview, `SteamWizardView` (all cards of 4.6, wired to `SteamSetupModel`), Advanced disclosure with the phase-2 key/path fields, banners unchanged, `SettingsModel` finishing (`loadOrMigrate` already writes v2; call `StateStore` only through the model; `reanalyze` scenes whose `analysisRevision` is old, using `SceneImporter.reanalyze`). Done when: all persisted changes go through `persist()`/`assign` (commit + `.reload`) except mute (`StateStore.setMuted`); nothing plays in this process; `remove` still deletes only inside `AppPaths.libraryDirectory` (this now includes `lock-*.mov`); the password field is cleared on submit and on disappear and is never passed anywhere except `SteamSetupModel.signIn`; macOS 14 API only; the harness `run.sh` still passes (SettingsModel stays UI-free).

**STEAM** — implement `SteamTools.swift` (installer, arch/Rosetta, sign-in driver, classifier, ownership, sign-out, assets), `SteamPTY.swift`, `SceneImport.swift`, and the `Workshop.swift` changes: prefer the app-managed steamcmd, `HOME` isolation in every run, one run gate, `isImportable` path for scenes calling `SceneImporter`, `WorkshopError`/fixes updated (`needsLogin` -> open Steam Setup instead of copying a Terminal command; keep the old copy-command path only for `.unrecognizedPrompt`). Done when: the classifier passes the vectors of 4.4 in the harness; the scrubber test proves a password and a code never reach output/log/error strings; no code path puts a secret in argv, env, files or published state; the installer refuses archive paths with `..`; cancel/quit terminates steamcmd; the phase-2 download invocation (stdin closed, `+@NoPromptForPassword 1`) is unchanged; `SceneImporter` leaves nothing half-written; harness `run.sh` passes.

**SCENEPARSE** — implement `Archive.swift`, `Tex.swift`, `SceneParser.swift` per section 5 (tolerant JSON via `JSONSerialization`; numbers as Int/Double/String; vectors in the three spellings; bound-value objects; `parent` cycles detected; object count cap 20 000), add `Tests/SceneFormatTests/*` with in-memory PKG/TEX/LZ4/scene.json fixtures (valid and hostile: truncated, bad counts, offset overflow, LZ4 bombs). Done when: every limit in 5.1/5.2 is enforced and tested; no force unwraps or unchecked integer arithmetic on file-derived values; `SceneLoader.load(packageAt:)` returns a `LoadedScene` for a synthetic scene and the analyzer reproduces the table of 5.5 for synthetic cases (full, each partial reason, previewOnly); files compile with both Linux compilers and under `swift test`; no Apple-only imports.

**SCENERENDER** — implement `SceneRenderer`, shaders, texture upload, `LockVideoRenderer`, `ScenePlayer`, host job handling per 1.3 to 1.5 and 3.4/3.5. Done when: `encode(at:)` is deterministic for a given time (no clock reads); textures stay compressed and honour the byte budget with LRU eviction; `releaseGPUResources()` frees everything and `prepare()` restores; the player pauses when covered, releases after 10 s, honours `fpsCap`, rebuilds windows on screen changes, and reports `.playing` only after the first presented frame; the lock renderer follows `LoopPlan` exactly, writes `.partial.mov` then renames, deletes it on cancel/failure, writes `LockRenderCache.Meta`, reports progress at least every 0.5 s and is cancellable within one frame; `--probe` works; the host exits per 1.1; `previewOnly`/failed scenes show the preview through `SceneRenderer(previewImage:)`; no AppKit import in `Sources/SceneEngine`; no `.metal` files.

### 9.5 Integration order and conflict rules

Files have single owners, so merges are conflict-free. Suggested merge order for the orchestrator: SCENEPARSE, STEAM, SCENERENDER, AGENT, SETTINGS (each branch builds on the scaffold; none edits another's files). After each merge push and read CI (`gh api repos/NOOB-3301/LiveWallpaper/actions/runs?branch=...`). CI's `swift test` step runs the XCTest targets; the `Package app bundle` step proves the guards.

---

## Appendix A. Declaration digest (generated from the scaffold; the files win)

Declarations only: bodies, comments, initial values and private members omitted; multi-line signatures are joined. `case` lines are enum cases.

### `Sources/Core/Model.swift`

```swift
public struct VideoItem: Identifiable, Codable, Hashable, Sendable
    public let id: UUID
    public var path: String
    public var title: String?
    public var author: String?
    public var workshopID: String?
    public var previewPath: String?
    public var tags: [String]?
    public var scene: SceneInfo?
    public init(id: UUID = UUID(), path: String, title: String? = nil, author: String? = nil, workshopID: String? = nil, previewPath: String? = nil, tags: [String]? = nil, scene: SceneInfo? = nil)
    public init(url: URL)
    public var url: URL
    public var name: String
    public var isWorkshop: Bool
    public var kind: ItemKind
    public var isScene: Bool
    public static func isVideo(_ url: URL) -> Bool
public enum IntervalUnit: String, CaseIterable, Identifiable, Codable, Sendable
    case seconds, minutes, hours
    public var id: String
    public var label: String
    public var multiplier: TimeInterval
public enum WallpaperTarget: String, Codable, CaseIterable, Identifiable, Sendable
    case desktop, lock
    public var id: String
    public var label: String
public enum ItemKind: String, Codable, Sendable
    case video, scene
public enum SceneSupport: String, Codable, Sendable
    case full
    case partial
    case previewOnly
public struct SceneInfo: Codable, Hashable, Sendable
    public var support: SceneSupport
    public var notes: [String]
    public var designWidth: Int
    public var designHeight: Int
    public var loopSeconds: Double?
    public var needsSharedAssets: Bool
    public var analysisRevision: Int
    public init(support: SceneSupport, notes: [String] = [], designWidth: Int = 1920, designHeight: Int = 1080, loopSeconds: Double? = nil, needsSharedAssets: Bool = false, analysisRevision: Int = 1)
public struct TargetConfig: Codable, Equatable, Sendable
    public var enabled: Bool
    public var selectedID: UUID?
    public var playlist: [UUID]?
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public init(enabled: Bool = true, selectedID: UUID? = nil, playlist: [UUID]? = nil, rotateEnabled: Bool = true, intervalValue: Int = 5, intervalUnit: IntervalUnit = .minutes)
    public var intervalSeconds: TimeInterval
    public var intervalIsClamped: Bool
public struct LibraryState: Codable, Equatable, Sendable
    public static let minimumInterval: TimeInterval 
    public static let currentSchema
    public var schema: Int
    public var revision: Int
    public var videos: [VideoItem]
    public var muted: Bool
    public var sameForBoth: Bool
    public var desktop: TargetConfig
    public var lock: TargetConfig
    public init(schema: Int = LibraryState.currentSchema, revision: Int = 0, videos: [VideoItem] = [], muted: Bool = true, sameForBoth: Bool = true, desktop: TargetConfig = TargetConfig(), lock: TargetConfig = TargetConfig())
    public init(from decoder: Decoder) throws
    public func encode(to encoder: Encoder) throws
    public func config(for target: WallpaperTarget) -> TargetConfig
    public func items(for target: WallpaperTarget) -> [VideoItem]
    public func selectedItem(for target: WallpaperTarget) -> VideoItem?
    public func isEnabled(_ target: WallpaperTarget) -> Bool
    public func canPlay(_ target: WallpaperTarget) -> Bool
    public func hasMultipleItems(_ target: WallpaperTarget) -> Bool
    public func rotates(_ target: WallpaperTarget) -> Bool
    public func interval(for target: WallpaperTarget) -> TimeInterval
    public func targets(of id: UUID) -> Set<WallpaperTarget>
    public var canStart: Bool
    public var usesScenes: Bool
    public mutating func normalize()
    public mutating func assign(_ id: UUID, to targets: Set<WallpaperTarget>)
    public var selectedID: UUID?
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var applyToDesktop: Bool
    public var applyToLockScreen: Bool
    public var selectedItem: VideoItem?
    public var canRotate: Bool
    public var rotationActive: Bool
    public var intervalSeconds: TimeInterval
    public var intervalIsClamped: Bool
    public static func clampedInterval(_ value: Int) -> Int
public enum AppPaths
    public static let supportDirectory
    public static let stateFile
    public static let agentFile
    public static let libraryDirectory
    public static let backupsDirectory
    public static let stillsDirectory
    public static let aerialVideosDirectory
    public static let steamStagingDirectory
    public static let steamToolsDirectory
    public static let steamHomeDirectory
    public static let sharedAssetsDirectory
    public static func ensureDirectory(_ url: URL) throws
    public static func isInsideLibrary(_ url: URL) -> Bool
public enum StateStore
    public static let phase1DefaultsKey
    public static func load() -> LibraryState?
    public static func diskSchema() -> Int?
    public static func commit(_ state: inout LibraryState) -> Bool
    public static func setMuted(_ muted: Bool) -> LibraryState?
    public static func loadOrMigrate(defaults: UserDefaults = .standard) -> (state: LibraryState, importedCount: Int)
public struct OriginalWallpaper: Codable, Equatable, Sendable
    public var url: String
    public var scaling: UInt
    public var allowClipping: Bool
    public init(url: String, scaling: UInt, allowClipping: Bool)
public struct AgentRecord: Codable, Equatable, Sendable
    public var wantsRunning: Bool
    public var aerialSlots: [String]
    public var originals: [String: OriginalWallpaper]
    public var legacyImported: Bool
    public init(wantsRunning: Bool = false, aerialSlots: [String] = [], originals: [String: OriginalWallpaper] = [:], legacyImported: Bool = false)
public enum AgentRecordStore
    public static func load() -> AgentRecord
    public static func save(_ record: AgentRecord)
    public static func update(_ body: (inout AgentRecord) -> Void)
    public static func backupSlotsOnDisk() -> [String]
public enum VideoStills
    public static func cgImage(for url: URL, maxPixelSize: CGSize?) async -> CGImage?
```

### `Sources/Core/IPC.swift`

```swift
public enum IPC
    public static let version
    public static let settingsBundleID
    public static let agentBundleID
    public static let roleKey
    public static let commandName
    public static let statusName
public struct AgentCommand: Equatable, Sendable
    public enum Kind: String, Sendable
        case ping
        case start
        case stop
        case pause
        case resume
        case next
        case play
        case reload
        case quit
    public var id: String
    public var kind: Kind
    public var videoID: UUID?
    public var revision: Int?
    public var target: WallpaperTarget?
    public init(kind: Kind, videoID: UUID? = nil, revision: Int? = nil, target: WallpaperTarget? = nil, id: String = UUID().uuidString)
    public var userInfo: [String: Any]
    public init?(userInfo: [AnyHashable: Any]?)
public struct LockRenderStatus: Equatable, Sendable
    public enum State: String, Sendable
        case queued, rendering, finished, failed
    public var itemID: UUID
    public var state: State
    public var progress: Double
    public var message: String?
    public init(itemID: UUID, state: State, progress: Double = 0, message: String? = nil)
public struct AgentStatus: Equatable, Sendable
    public var seq: Int
    public var reply: String?
    public var pid: Int32
    public var agentVersion: String
    public var isRunning: Bool
    public var isPaused: Bool
    public var currentID: UUID?
    public var failedIDs: [UUID]
    public var message: String?
    public var lockBusy: Bool
    public var stateRevision: Int
    public var quitting: Bool
    public var lockID: UUID?
    public var muted: Bool
    public var sceneHostRunning: Bool
    public var lockRender: LockRenderStatus?
    public init(seq: Int = 0, reply: String? = nil, pid: Int32 = 0, agentVersion: String = "", isRunning: Bool = false, isPaused: Bool = false, currentID: UUID? = nil, failedIDs: [UUID] = [], message: String? = nil, lockBusy: Bool = false, stateRevision: Int = 0, quitting: Bool = false, lockID: UUID? = nil, muted: Bool = true, sceneHostRunning: Bool = false, lockRender: LockRenderStatus? = nil)
    public var userInfo: [String: Any]
    public init?(userInfo: [AnyHashable: Any]?)
public final class AgentEndpoint: NSObject
    public var onCommand: (@MainActor (AgentCommand) -> Void)?
    public override init()
    public func startListening()
    public func post(_ status: AgentStatus)
public final class SettingsEndpoint: NSObject
    public var onStatus: (@MainActor (AgentStatus) -> Void)?
    public override init()
    public func startListening()
    public func send(_ command: AgentCommand)
```

### `Sources/Core/HostIPC.swift`

```swift
public enum HostIPC
    public static let version
    public static let bundleID
    public static let bundleName
    public static let role
    public static let commandName
    public static let statusName
public struct HostCommand: Equatable, Sendable
    public enum Kind: String, Sendable
        case ping
        case showScene
        case hideScene
        case setPaused
        case setMuted
        case renderLock
        case cancelRender
        case quit
    public var id: String
    public var kind: Kind
    public var agentPID: Int32
    public var itemID: UUID?
    public var scenePath: String?
    public var previewPath: String?
    public var assetsPath: String?
    public var muted: Bool?
    public var paused: Bool?
    public var fpsCap: Int?
    public var jobID: String?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var loopSeconds: Double?
    public var outputPath: String?
    public init(kind: Kind, agentPID: Int32 = ProcessInfo.processInfo.processIdentifier, itemID: UUID? = nil, scenePath: String? = nil, previewPath: String? = nil, assetsPath: String? = nil, muted: Bool? = nil, paused: Bool? = nil, fpsCap: Int? = nil, jobID: String? = nil, width: Int? = nil, height: Int? = nil, fps: Int? = nil, loopSeconds: Double? = nil, outputPath: String? = nil, id: String = UUID().uuidString)
    public var userInfo: [String: Any]
    public init?(userInfo: [AnyHashable: Any]?)
public struct HostStatus: Equatable, Sendable
    public enum SceneState: String, Sendable
        case none
        case loading
        case playing
        case paused
        case fallbackStill
        case failed
    public enum JobState: String, Sendable
        case idle
        case rendering
        case finished
        case failed
        case cancelled
    public var seq: Int
    public var reply: String?
    public var pid: Int32
    public var hostVersion: String
    public var sceneItemID: UUID?
    public var sceneState: SceneState
    public var sceneMessage: String?
    public var jobID: String?
    public var jobState: JobState
    public var jobProgress: Double
    public var jobMessage: String?
    public var residentMB: Int
    public var quitting: Bool
    public init(seq: Int = 0, reply: String? = nil, pid: Int32 = 0, hostVersion: String = "", sceneItemID: UUID? = nil, sceneState: SceneState = .none, sceneMessage: String? = nil, jobID: String? = nil, jobState: JobState = .idle, jobProgress: Double = 0, jobMessage: String? = nil, residentMB: Int = 0, quitting: Bool = false)
    public var userInfo: [String: Any]
    public init?(userInfo: [AnyHashable: Any]?)
public final class HostEndpoint: NSObject
    public var onCommand: (@MainActor (HostCommand) -> Void)?
    public override init()
    public func startListening()
    public func post(_ status: HostStatus)
public final class HostClientEndpoint: NSObject
    public var onStatus: (@MainActor (HostStatus) -> Void)?
    public override init()
    public func startListening()
    public func send(_ command: HostCommand)
```

### `Sources/Core/SceneCache.swift`

```swift
public enum LockRenderCache
    public static let engineRevision
    public struct Meta: Codable, Equatable, Sendable
        public var engineRevision: Int
        public var width: Int
        public var height: Int
        public var fps: Int
        public var loopSeconds: Double
        public var sourceStamp: String
        public var createdAt: Double
        public init(engineRevision: Int = LockRenderCache.engineRevision, width: Int, height: Int, fps: Int, loopSeconds: Double, sourceStamp: String, createdAt: Double = Date().timeIntervalSince1970)
    public static func folder(for item: VideoItem) -> URL
    public static func videoURL(for item: VideoItem, width: Int, height: Int) -> URL
    public static func partialURL(for item: VideoItem, width: Int, height: Int) -> URL
    public static func metaURL(for item: VideoItem, width: Int, height: Int) -> URL
    public static func sourceStamp(for item: VideoItem) -> String
    public static func readMeta(for item: VideoItem, width: Int, height: Int) -> Meta?
    public static func writeMeta(_ meta: Meta, for item: VideoItem) throws
    public static func isValid(for item: VideoItem, width: Int, height: Int) -> Bool
    public static func removeStale(for item: VideoItem, keepingWidth width: Int, height: Int)
```

### `Sources/SceneFormat/Archive.swift`

```swift
public enum SceneFormatError: Error, Equatable, LocalizedError
    case notImplemented(String)
    case truncated(String)
    case badMagic(String)
    case invalid(String)
    case missingFile(String)
    case unsupported(String)
    public var errorDescription: String?
public protocol SceneFileSource: AnyObject, Sendable
    var displayName: String
    func fileExists(_ path: String) -> Bool
    func data(at path: String) throws -> Data
    func allPaths() -> [String]
public final class PKGArchive: SceneFileSource
    public struct Entry: Equatable, Sendable
        public let path: String
        public let offset: Int
        public let length: Int
        public init(path: String, offset: Int, length: Int)
    public let magic: String
    public let entries: [Entry]
    public let displayName: String
    public init(data: Data, displayName: String = "pkg") throws
    public convenience init(contentsOf url: URL) throws
    public func fileExists(_ path: String) -> Bool
    public func data(at path: String) throws -> Data
    public func allPaths() -> [String]
public final class DirectorySource: SceneFileSource
    public let root: URL
    public var displayName: String
    public init(root: URL)
    public func fileExists(_ path: String) -> Bool
    public func data(at path: String) throws -> Data
    public func allPaths() -> [String]
public final class LayeredSource: SceneFileSource
    public let primary: SceneFileSource
    public let fallback: SceneFileSource?
    public var displayName: String
    public init(primary: SceneFileSource, fallback: SceneFileSource?)
    public func fileExists(_ path: String) -> Bool
    public func data(at path: String) throws -> Data
    public func allPaths() -> [String]
```

### `Sources/SceneFormat/Tex.swift`

```swift
public enum TexPixelFormat: Equatable, Sendable
    case rgba8888
    case rg88
    case r8
    case dxt1
    case dxt3
    case dxt5
public enum TexPayload: Equatable, Sendable
    case pixels(TexPixelFormat)
    case image(fileExtension: String)
    case video(fileExtension: String)
public struct TexFlags: OptionSet, Equatable, Sendable
    public let rawValue: Int
    public init(rawValue: Int)
    public static let noInterpolation
    public static let clampUVs
    public static let isGif
    public static let isVideoTexture
public struct TexMipmap: Equatable, Sendable
    public var width: Int
    public var height: Int
    public var data: Data
    public init(width: Int, height: Int, data: Data)
public struct TexFrame: Equatable, Sendable
    public var imageIndex: Int
    public var seconds: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(imageIndex: Int, seconds: Double, x: Double, y: Double, width: Double, height: Double)
public struct TexImage: Equatable, Sendable
    public var textureWidth: Int
    public var textureHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var flags: TexFlags
    public var payload: TexPayload
    public var mipmaps: [TexMipmap]
    public var frames: [TexFrame]
    public var containerMagic: String
    public init(textureWidth: Int, textureHeight: Int, imageWidth: Int, imageHeight: Int, flags: TexFlags, payload: TexPayload, mipmaps: [TexMipmap], frames: [TexFrame] = [], containerMagic: String = "")
public enum LZ4
    public static func decompress(_ source: Data, decompressedSize: Int) throws -> Data
public enum TexDecoder
    public static func decode(_ data: Data) throws -> TexImage
```

### `Sources/SceneFormat/SceneDocument.swift`

```swift
public struct Vec2: Equatable, Sendable
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0)
    public static let zero
    public static let one
public struct Vec3: Equatable, Sendable
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0)
    public static let zero
    public static let one
public enum BlendMode: String, Equatable, Sendable
    case normal
    case opaque
    case additive
    case multiply
    case screen
    case unknown
public struct SceneCamera: Equatable, Sendable
    public var center: Vec3
    public var eye: Vec3
    public var up: Vec3
    public init(center: Vec3 = .zero, eye: Vec3 = Vec3(0, 0, 1), up: Vec3 = Vec3(0, 1, 0))
public struct SceneGeneral: Equatable, Sendable
    public var clearColor: Vec3
    public var designWidth: Double
    public var designHeight: Double
    public var cameraParallax: Bool
    public var parallaxAmount: Double
    public var parallaxDelay: Double
    public var parallaxMouseInfluence: Double
    public var hasBloom: Bool
    public var hasHDR: Bool
    public init(clearColor: Vec3 = Vec3(0, 0, 0), designWidth: Double = 1920, designHeight: Double = 1080, cameraParallax: Bool = false, parallaxAmount: Double = 1, parallaxDelay: Double = 0.1, parallaxMouseInfluence: Double = 1, hasBloom: Bool = false, hasHDR: Bool = false)
public struct EffectInstance: Equatable, Sendable
    public var file: String
    public var name: String
    public var visible: Bool
    public init(file: String, name: String = "", visible: Bool = true)
public struct ImageLayer: Equatable, Sendable
    public var modelPath: String?
    public var materialPath: String?
    public var texturePath: String?
    public var extraTexturePaths: [String]
    public var shader: String?
    public var blend: BlendMode
    public var sourceSize: Vec2?
    public var effects: [EffectInstance]
    public var passCount: Int
    public var usesPuppet: Bool
    public init(modelPath: String? = nil, materialPath: String? = nil, texturePath: String? = nil, extraTexturePaths: [String] = [], shader: String? = nil, blend: BlendMode = .normal, sourceSize: Vec2? = nil, effects: [EffectInstance] = [], passCount: Int = 1, usesPuppet: Bool = false)
public enum SceneObjectKind: Equatable, Sendable
    case image(ImageLayer)
    case particle(path: String)
    case sound(paths: [String])
    case text
    case light
    case model3D(path: String)
    case group
    case other(String)
public struct SceneObject: Equatable, Sendable
    public var id: Int
    public var name: String
    public var kind: SceneObjectKind
    public var origin: Vec3
    public var angles: Vec3
    public var scale: Vec3
    public var size: Vec2?
    public var visible: Bool
    public var parentID: Int?
    public var parallaxDepth: Vec2
    public var alpha: Double
    public var color: Vec3
    public var brightness: Double
    public var hasScripts: Bool
    public var hasUserProperties: Bool
    public init(id: Int, name: String = "", kind: SceneObjectKind, origin: Vec3 = .zero, angles: Vec3 = .zero, scale: Vec3 = .one, size: Vec2? = nil, visible: Bool = true, parentID: Int? = nil, parallaxDepth: Vec2 = .zero, alpha: Double = 1, color: Vec3 = .one, brightness: Double = 1, hasScripts: Bool = false, hasUserProperties: Bool = false)
public struct SceneDocument: Equatable, Sendable
    public var version: Int
    public var general: SceneGeneral
    public var camera: SceneCamera
    public var objects: [SceneObject]
    public init(version: Int = 1, general: SceneGeneral = SceneGeneral(), camera: SceneCamera = SceneCamera(), objects: [SceneObject] = [])
```

### `Sources/SceneFormat/SceneParser.swift`

```swift
public struct EngineCapabilities: Equatable, Sendable
    public var blendModes: Set<BlendMode>
    public var cameraParallax: Bool
    public var effects: Bool
    public var particles: Bool
    public var sound: Bool
    public var scripts: Bool
    public var puppet: Bool
    public var animatedTextures: Bool
    public var userProperties: Bool
    public init(blendModes: Set<BlendMode>, cameraParallax: Bool, effects: Bool = false, particles: Bool = false, sound: Bool = false, scripts: Bool = false, puppet: Bool = false, animatedTextures: Bool = false, userProperties: Bool = false)
    public static let milestone0
    public static let current
public enum SceneSupportLevel: String, Equatable, Sendable
    case full, partial, previewOnly
public enum SceneFeature: String, CaseIterable, Equatable, Hashable, Sendable
    case imageLayers, cameraParallax, blendModes
    case effects, particles, sound, scripts, puppet, text, lights, model3D
    case userProperties, animatedTextures, unknownBlendMode, unknownObject
    case missingTexture, undecodableTexture, sharedAssetsNeeded, noRenderableLayer
public struct SceneAnalysis: Equatable, Sendable
    public static let revision
    public var support: SceneSupportLevel
    public var notes: [String]
    public var used: Set<SceneFeature>
    public var unsupported: Set<SceneFeature>
    public var designWidth: Int
    public var designHeight: Int
    public var loopSeconds: Double?
    public var needsSharedAssets: Bool
    public init(support: SceneSupportLevel, notes: [String] = [], used: Set<SceneFeature> = [], unsupported: Set<SceneFeature> = [], designWidth: Int = 1920, designHeight: Int = 1080, loopSeconds: Double? = nil, needsSharedAssets: Bool = false)
public struct LoadedScene: Sendable
    public let files: SceneFileSource
    public let document: SceneDocument
    public let analysis: SceneAnalysis
    public init(files: SceneFileSource, document: SceneDocument, analysis: SceneAnalysis)
public enum SceneLoader
    public static func load(packageAt url: URL, sharedAssets: URL?, capabilities: EngineCapabilities = .current) throws -> LoadedScene
    public static func load(directory url: URL, sharedAssets: URL?, capabilities: EngineCapabilities = .current) throws -> LoadedScene
    public static func parseDocument(sceneJSON: Data, files: SceneFileSource) throws -> SceneDocument
public enum SceneAnalyzer
    public static func analyze(document: SceneDocument, files: SceneFileSource, capabilities: EngineCapabilities = .current) -> SceneAnalysis
```

### `Sources/SceneFormat/LoopPlan.swift`

```swift
public struct LoopPlan: Equatable, Sendable
    public struct Source: Equatable, Sendable
        public var primary: Double
        public var secondary: Double?
        public var mix: Float
        public init(primary: Double, secondary: Double? = nil, mix: Float = 0)
    public let fps: Int
    public let loopFrames: Int
    public let crossfadeFrames: Int
    public var loopSeconds: Double
    public var crossfadeSeconds: Double
    public var renderCalls: Int
    public init(loopSeconds: Double, crossfadeSeconds: Double, fps: Int)
    public func source(forFrame i: Int) -> Source
    public static func choose(scenePeriod: Double?, fps: Int) -> LoopPlan
```

### `Sources/SceneEngine/SceneRenderer.swift`

```swift
public struct ParallaxInput: Equatable, Sendable
    public var x: Float
    public var y: Float
    public init(x: Float = 0, y: Float = 0)
    public static let zero
public struct RenderOptions: Sendable
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pixelFormat: MTLPixelFormat
    public var textureBudgetBytes: Int
    public var fitMode: FitMode
    public enum FitMode: Sendable
        case fill
        case fit
    public init(pixelWidth: Int, pixelHeight: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm, textureBudgetBytes: Int = 400 * 1024 * 1024, fitMode: FitMode = .fill)
public enum SceneRendererError: Error, Equatable, LocalizedError
    case notImplemented(String)
    case noGPU
    case textureFailed(String)
    case shaderFailed(String)
    case encodeFailed(String)
    public var errorDescription: String?
public final class SceneRenderer
    public let options: RenderOptions
    public let designSize: CGSize
    public private(set) var supportsRandomAccessTime: Bool 
    public private(set) var residentTextureBytes: Int 
    public static var capabilities: EngineCapabilities
    public init(scene: LoadedScene, device: MTLDevice, options: RenderOptions) throws
    public init(previewImage: CGImage, device: MTLDevice, options: RenderOptions) throws
    public func prepare() throws
    public func encode(at time: Double, parallax: ParallaxInput, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws
    public func releaseGPUResources()
```

### `Sources/SceneEngine/LockVideoRenderer.swift`

```swift
public struct LockRenderRequest: Sendable
    public var scenePath: URL
    public var previewPath: URL?
    public var assetsPath: URL?
    public var outputURL: URL
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var loopSeconds: Double?
    public init(scenePath: URL, previewPath: URL? = nil, assetsPath: URL? = nil, outputURL: URL, pixelWidth: Int, pixelHeight: Int, fps: Int = 30, loopSeconds: Double? = nil)
public enum LockRenderError: Error, Equatable, LocalizedError
    case notImplemented
    case cancelled
    case sceneUnreadable(String)
    case noGPU
    case writerFailed(String)
    public var errorDescription: String?
public enum LockVideoRenderer
    public static func render(_ request: LockRenderRequest, progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) async throws -> Double
```

### `Sources/LiveWallpaperSceneHost/ScenePlayer.swift`

```swift
@MainActor final class ScenePlayer
    var onChange: (@MainActor (HostStatus.SceneState, String?) -> Void)?
    private(set) var state: HostStatus.SceneState 
    private(set) var itemID: UUID?
    init()
    func show(itemID: UUID, scenePath: URL, previewPath: URL?, assetsPath: URL?, fpsCap: Int)
    func hide()
    func setPaused(_ paused: Bool)
    func setMuted(_ muted: Bool)
    func setFPSCap(_ fps: Int)
```

### `Sources/LiveWallpaperAgent/SceneHostClient.swift`

```swift
@MainActor final class SceneHostClient
    var onStatus: (@MainActor (HostStatus) -> Void)?
    var onTerminated: (@MainActor (_ unexpectedly: Bool) -> Void)?
    private(set) var isRunning
    private(set) var isReady
    private(set) var lastStatus: HostStatus?
    init()
    static var hostAppURL: URL
    static func hostProcessExists() -> Bool
    func start()
    func send(_ command: HostCommand)
    func shutdown()
```

### `Sources/LiveWallpaper/SteamTools.swift`

```swift
enum SteamArch: String, Equatable
    case arm64, x86_64, universal, unknown
struct SteamToolsInfo: Equatable
    var path: String
    var arch: SteamArch
    var managedByApp: Bool
enum SteamInstallStep: Equatable
    case downloading(fraction: Double?)
    case extracting
    case firstRun(note: String)
    case checking
enum SteamToolsState: Equatable
    case unknown
    case missing
    case installing(SteamInstallStep)
    case rosettaRequired
    case ready(SteamToolsInfo)
    case failed(SteamSetupError)
enum SteamCodeKind: Equatable
    case email
    case authenticator
    case unknown
enum SteamSignInStep: Equatable
    case starting
    case working(String)
    case needsCode(SteamCodeKind, previousWasWrong: Bool)
    case needsMobileApproval
    case unrecognizedPrompt(lastLines: String)
enum SteamAccountState: Equatable
    case unknown
    case checking
    case signedOut
    case signingIn(SteamSignInStep)
    case signedIn(username: String)
enum SteamOwnershipState: Equatable
    case unknown
    case checking
    case owned
    case notOwned
    case couldNotCheck(String)
enum SteamAssetsState: Equatable
    case unknown
    case notFetched
    case discovering
    case needsConfirmation(downloadBytes: Int64, depotName: String)
    case fetching(fraction: Double?)
    case ready(folder: String)
    case unavailable(String)
    case failed(SteamSetupError)
enum SteamWizardStep: Equatable
    case installTools, fixRosetta, signIn, checkOwnership, done
enum SteamSetupError: Error, Equatable
    case downloadFailed(String)
    case extractFailed(String)
    case toolsBroken(String)
    case rosettaMissing
    case firstRunFailed(String)
    case badPassword
    case badCode
    case rateLimited
    case guardTimedOut
    case unrecognizedPrompt(String)
    case loginFailed(String)
    case processFailed(String)
    case timedOut
    case cancelled
    case diskSpace(neededBytes: Int64)
    case assetsFailed(String)
    var title: String
    var message: String
enum SteamPrompt: Equatable
    case none
    case passwordPrompt
    case guardCode(SteamCodeKind)
    case mobileApproval
    case badPassword
    case badCode
    case rateLimited
    case signedIn
    case failed(String)
    case rosettaMissing
enum SteamPromptClassifier
    static func classify(_ tail: String) -> SteamPrompt
@MainActor final class SteamSetupModel: ObservableObject
    static let shared
    var step: SteamWizardStep
    var canDownload: Bool
    var steamcmdPath: String?
    init()
    func refresh()
    func installTools()
    func cancelInstall()
    func signIn(username: String, password: String)
    func submitGuardCode(_ code: String)
    func cancelSignIn()
    func signOut()
    func checkOwnership()
    func prepareSharedAssets()
    func confirmSharedAssets()
    func removeSharedAssets()
```

### `Sources/LiveWallpaper/SteamPTY.swift`

```swift
struct SteamCommandLine
    var executable: String
    var arguments: [String]
    var environment: [String: String]
final class SteamPTYSession: @unchecked Sendable
    var onOutput: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    init(command: SteamCommandLine)
    func start() throws
    func sendLine(_ text: inout [UInt8], secret: Bool)
    func terminate()
```

### `Sources/LiveWallpaper/SceneImport.swift`

```swift
struct SceneImportInput
    var workshopID: String
    var title: String
    var author: String?
    var tags: [String]
    var contentFolder: URL
    var previewSource: URL?
enum SceneImporter
    static func importScene(_ input: SceneImportInput) async throws -> VideoItem
    static func reanalyze(_ item: VideoItem) -> VideoItem
```

### `Sources/LiveWallpaper/WorkshopDetailView.swift`

```swift
struct AnimatedImageView: NSViewRepresentable
    let image: NSImage?
    func makeNSView(context: Context) -> NSImageView
    func updateNSView(_ view: NSImageView, context: Context)
@MainActor final class WorkshopPreviewLoader: ObservableObject
    func load(_ url: URL?) async
struct WorkshopDetailView: View
    let item: WorkshopItem
    let close: () -> Void
    let openSteamSetup: () -> Void
    var body: some View
```

### `Sources/LiveWallpaper/SteamWizardView.swift`

```swift
struct SteamWizardView: View
    var body: some View
```

