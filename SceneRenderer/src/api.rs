//! The Swift-facing `Renderer`. All Metal work happens on one render thread that owns the
//! `Engine`; the methods below only send it messages, so they never block the main thread
//! (except `render_frame`, which waits for its pixels).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CGSize;
use objc2_metal::*;
use objc2_quartz_core::{CAMetalDrawable, CAMetalLayer};
use serde_json::Value;

use crate::engine::{Engine, FitMode, FrameInput};
use crate::gpu::TARGET_FORMAT;
use crate::scene::project_properties;
use crate::vfs::Vfs;
use crate::Error;

#[derive(Debug, Clone, uniffi::Record)]
pub struct SceneProperty {
    pub name: String,
    /// `bool`, `slider`, `color`, `combo`, `textinput`, ... as in project.json.
    pub kind: String,
    pub label: String,
    /// Current value as JSON.
    pub value_json: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RenderStats {
    pub frames: u64,
    /// Average GPU time per frame in milliseconds: the main heat driver.
    pub gpu_ms_per_frame: f64,
}

#[derive(Debug, Default)]
struct Counters {
    frames: AtomicU64,
    gpu_ns: AtomicU64,
    /// Frames committed but not yet on screen.
    waiting: AtomicU64,
}

enum Command {
    Play,
    Pause,
    Stop,
    Property(String, Value),
    Antialiasing(u32),
    FpsCap(f32),
    HideScriptedText(bool),
    Resize(u32, u32),
    Visible(bool),
    Attach(String, usize, u32, u32),
    Detach(String),
    Fit(FitMode),
    PanZoom(f32, f32, f32),
    RenderScale(f32),
    AudioResponse(bool),
    Sound(bool, f32),
    Spectrum(Vec<f32>, Vec<f32>),
    RenderFrame(f64, Sender<Result<Vec<u8>, Error>>),
    /// Something in the shared state changed; draw a frame.
    Wake,
}

#[derive(Debug, uniffi::Object)]
pub struct Renderer {
    tx: Mutex<Sender<Command>>,
    properties: Mutex<Vec<SceneProperty>>,
    errors: Vec<String>,
    audio: Mutex<(bool, f32)>,
    counters: Arc<Counters>,
    /// Latest pointer, read by the render thread each frame. Shared state rather than a command, so
    /// a mouse move never waits for the render thread's queue.
    pointer: Arc<Mutex<Pointer>>,
}

/// Pointer in 0...1 screen coordinates (origin top-left) and the left button.
#[derive(Debug, Clone, Copy)]
struct Pointer {
    pos: [f32; 2],
    down: bool,
}

impl Default for Pointer {
    fn default() -> Self {
        Self {
            pos: [0.5, 0.5],
            down: false,
        }
    }
}

impl std::fmt::Debug for Command {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Command")
    }
}

#[uniffi::export]
impl Renderer {
    /// Opens `scene.pkg` (or an unpacked scene folder). Shared assets are looked up in the
    /// library's sibling `WallpaperEngineAssets` folder. Fails if the scene cannot be drawn at all;
    /// partial support is reported by `load_errors`.
    #[uniffi::constructor]
    pub fn new(pkg_path: String) -> Result<Arc<Self>, Error> {
        let path = PathBuf::from(&pkg_path);
        let folder = if path.is_dir() {
            path.clone()
        } else {
            path.parent().map(Path::to_path_buf).unwrap_or_default()
        };
        // Library/<id>/scene.pkg -> ../../WallpaperEngineAssets
        let assets = folder
            .parent()
            .and_then(Path::parent)
            .map(|p| p.join("WallpaperEngineAssets"))
            .filter(|p| p.is_dir());
        let project: Value = std::fs::read_to_string(folder.join("project.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        let props = project_properties(&project);
        let values: HashMap<String, Value> = props
            .iter()
            .map(|p| (p.name.clone(), p.value.clone()))
            .collect();
        let properties = props
            .into_iter()
            .map(|p| SceneProperty {
                name: p.name,
                kind: p.kind,
                label: p.label,
                value_json: p.value.to_string(),
            })
            .collect();

        let (tx, rx) = channel();
        let (ready_tx, ready_rx) = channel();
        let counters = Arc::new(Counters::default());
        let thread_counters = counters.clone();
        let pointer = Arc::new(Mutex::new(Pointer::default()));
        let thread_pointer = pointer.clone();
        let _ = std::thread::Builder::new()
            .name("scene-renderer".into())
            .spawn(move || {
                let engine =
                    Vfs::open(&path, assets.as_deref()).and_then(|vfs| Engine::load(vfs, values));
                match engine {
                    Ok(engine) => {
                        let _ = ready_tx.send(Ok(engine.warnings.clone()));
                        run(engine, rx, thread_counters, thread_pointer);
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                    }
                }
            })
            .map_err(|e| Error::Io(format!("render thread: {e}")))?;
        let errors = ready_rx
            .recv()
            .map_err(|_| Error::Metal("render thread exited".into()))??;
        Ok(Arc::new(Self {
            tx: Mutex::new(tx),
            properties: Mutex::new(properties),
            errors,
            audio: Mutex::new((false, 1.0)),
            counters,
            pointer,
        }))
    }

    /// Hands over the `CAMetalLayer` to draw into (pointer from `Unmanaged.passUnretained(layer).toOpaque()`).
    /// The renderer retains it. One layer per display; the scene is shared between them.
    pub fn attach_layer(&self, display_id: String, layer_ptr: u64, width: u32, height: u32) {
        self.send(Command::Attach(
            display_id,
            layer_ptr as usize,
            width.max(1),
            height.max(1),
        ));
    }

    /// Gives up a display's layer; its textures are freed with it.
    pub fn detach_layer(&self, display_id: String) {
        self.send(Command::Detach(display_id));
    }

    /// How the scene is mapped onto the target: fill, fit, stretch, unscaled or blurred fit.
    pub fn set_fit_mode(&self, mode: FitMode) {
        self.send(Command::Fit(mode));
    }

    /// Hides text layers that scripts compute (clocks and the like). The lock screen loop uses
    /// this: a frame recorded once cannot follow the time.
    pub fn set_hide_scripted_text(&self, hide: bool) {
        self.send(Command::HideScriptedText(hide));
    }

    /// Moves the picture on screen (in screen widths and heights) and magnifies it.
    pub fn set_pan_zoom(&self, pan_x: f32, pan_y: f32, zoom: f32) {
        self.send(Command::PanZoom(pan_x, pan_y, zoom));
    }

    /// Fraction of the target's pixels the scene is drawn in; the layer scales it up.
    pub fn set_render_scale(&self, scale: f32) {
        self.send(Command::RenderScale(scale));
    }

    /// Whether shaders that read an audio spectrum may do so. No audio yet, so the spectrum
    /// stays silent either way; the flag is remembered for when it is.
    pub fn set_audio_response(&self, enabled: bool) {
        self.send(Command::AudioResponse(enabled));
    }

    pub fn play(&self) {
        self.send(Command::Play);
    }

    pub fn pause(&self) {
        self.send(Command::Pause);
    }

    /// Stops drawing and frees GPU memory; `play` resumes from the start.
    pub fn stop(&self) {
        self.send(Command::Stop);
    }

    /// `value_json` is JSON (`true`, `0.5`, `"1 0 0"`); anything else is taken as a string.
    pub fn apply_property(&self, name: String, value_json: String) {
        let value = serde_json::from_str(&value_json).unwrap_or(Value::String(value_json));
        if let Ok(mut props) = self.properties.lock() {
            if let Some(p) = props.iter_mut().find(|p| p.name == name) {
                p.value_json = value.to_string();
            }
        }
        self.send(Command::Property(name, value));
    }

    /// MSAA sample count: 0/1 off, 2, 4.
    pub fn apply_antialiasing(&self, samples: u32) {
        self.send(Command::Antialiasing(samples));
    }

    pub fn load_errors(&self) -> Vec<String> {
        self.errors.clone()
    }

    pub fn properties(&self) -> Vec<SceneProperty> {
        self.properties
            .lock()
            .map(|p| p.clone())
            .unwrap_or_default()
    }

    pub fn set_muted(&self, muted: bool) {
        if let Ok(mut a) = self.audio.lock() {
            a.0 = muted;
            self.send(Command::Sound(a.0, a.1));
        }
    }

    pub fn set_volume(&self, volume: f32) {
        if let Ok(mut a) = self.audio.lock() {
            a.1 = volume.clamp(0.0, 1.0);
            self.send(Command::Sound(a.0, a.1));
        }
    }

    /// Latest system audio spectrum, 0...1 per band, low to high, for each channel. Shaders and
    /// scripts that respond to audio read it; it is ignored while audio response is off.
    pub fn set_audio_spectrum(&self, left: Vec<f32>, right: Vec<f32>) {
        self.send(Command::Spectrum(left, right));
    }

    /// Frames per second; 0 means the display's rate.
    pub fn set_fps_cap(&self, fps: f32) {
        self.send(Command::FpsCap(fps));
    }

    /// Drawable size in pixels.
    pub fn resize(&self, width: u32, height: u32) {
        self.send(Command::Resize(width, height));
    }

    /// Hidden (covered, screen off, other space): no frames, intermediate buffers released.
    pub fn set_visible(&self, visible: bool) {
        self.send(Command::Visible(visible));
    }

    /// Pointer in 0...1 screen coordinates (origin top-left), for parallax and cursor effects.
    pub fn set_pointer(&self, x: f32, y: f32) {
        if let Ok(mut pointer) = self.pointer.lock() {
            pointer.pos = [x, y];
        }
    }

    /// Left button pressed on the desktop, for scripts that react to clicks and drags.
    pub fn set_pointer_down(&self, down: bool) {
        if let Ok(mut pointer) = self.pointer.lock() {
            pointer.down = down;
        }
        self.send(Command::Wake);
    }

    /// Frames drawn to the screen so far and their average GPU cost.
    pub fn stats(&self) -> RenderStats {
        let frames = self.counters.frames.load(Ordering::Relaxed);
        let ns = self.counters.gpu_ns.load(Ordering::Relaxed);
        RenderStats {
            frames,
            gpu_ms_per_frame: if frames == 0 {
                0.0
            } else {
                ns as f64 / frames as f64 / 1e6
            },
        }
    }

    /// Renders the scene at `time` seconds into BGRA8 pixels at the last `resize` size (or the
    /// scene's design size), for the lock-screen video. Independent of play/pause.
    pub fn render_frame(&self, time: f64) -> Result<Vec<u8>, Error> {
        let (tx, rx) = channel();
        self.send(Command::RenderFrame(time, tx));
        rx.recv()
            .map_err(|_| Error::Metal("render thread exited".into()))?
    }
}

impl Renderer {
    fn send(&self, c: Command) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(c);
        }
    }
}

struct Loop {
    engine: Engine,
    /// One target per display; the scene's textures are shared between them.
    targets: Vec<(String, Target)>,
    size: Option<(u32, u32)>,
    playing: bool,
    visible: bool,
    fps: f32,
    pointer: Arc<Mutex<Pointer>>,
    /// The pointer eased toward its latest position, for parallax.
    parallax: [f32; 2],
    /// Scene clock while playing.
    time: f32,
    last: Instant,
    /// A static scene only draws when something changed.
    dirty: bool,
    animated: bool,
    /// Fraction of the target's pixels the scene is drawn in.
    render_scale: f32,
    /// Whether the scene may read an audio spectrum.
    audio_response: bool,
    muted: bool,
    volume: f32,
    counters: Arc<Counters>,
}

/// A display the scene is drawn on.
struct Target {
    layer: Retained<CAMetalLayer>,
    size: (u32, u32),
}

fn run(
    engine: Engine,
    rx: Receiver<Command>,
    counters: Arc<Counters>,
    pointer: Arc<Mutex<Pointer>>,
) {
    let animated = engine.is_animated();
    let mut s = Loop {
        engine,
        targets: Vec::new(),
        size: None,
        playing: false,
        visible: true,
        fps: 30.0,
        pointer,
        parallax: [0.5, 0.5],
        time: 0.0,
        last: Instant::now(),
        dirty: true,
        animated,
        render_scale: 1.0,
        audio_response: false,
        muted: false,
        volume: 1.0,
        counters,
    };
    let mut next = Instant::now();
    loop {
        // While the button is held, scripts may be dragging something: keep drawing.
        let held = s.pointer.lock().is_ok_and(|p| p.down);
        let drawing =
            s.playing && s.visible && !s.targets.is_empty() && (s.animated || s.dirty || held);
        let cmd = if drawing {
            rx.recv_timeout(next.saturating_duration_since(Instant::now()))
        } else {
            rx.recv().map_err(|_| RecvTimeoutError::Disconnected)
        };
        match cmd {
            Ok(c) => s.handle(c),
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                let period = if s.fps > 0.0 {
                    Duration::from_secs_f32(1.0 / s.fps)
                } else {
                    Duration::from_millis(16)
                };
                // Fixed cadence; after a stall, restart from now instead of bursting.
                next += period;
                if next < Instant::now() {
                    next = Instant::now() + period;
                }
                s.frame();
            }
        }
    }
}

impl Loop {
    fn handle(&mut self, c: Command) {
        let was_dirty = self.dirty;
        self.dirty = true;
        match c {
            Command::Play => {
                self.playing = true;
                self.last = Instant::now();
            }
            Command::Pause => self.playing = false,
            Command::Stop => {
                self.playing = false;
                self.time = 0.0;
                self.engine.reset_videos();
                self.engine.trim();
            }
            Command::Property(name, value) => {
                let _ = self.engine.props.insert(name, value);
                self.engine.rebuild();
                self.engine.sync_script_layers();
                self.animated = self.engine.is_animated();
            }
            Command::Antialiasing(n) => self.engine.set_samples(n as usize),
            Command::FpsCap(f) => self.fps = f.max(0.0),
            Command::Resize(w, h) => {
                self.size = Some((w.max(1), h.max(1)));
                for target in self.targets.iter_mut() {
                    target.1.size = (w.max(1), h.max(1));
                    target.1.layer.setDrawableSize(CGSize::new(
                        w.max(1) as f64 * self.render_scale as f64,
                        h.max(1) as f64 * self.render_scale as f64,
                    ));
                }
            }
            Command::Visible(v) => {
                self.visible = v;
                self.last = Instant::now();
                if !v {
                    self.engine.trim();
                }
            }
            Command::Attach(id, ptr, w, h) => {
                // SAFETY: the caller passes a live CAMetalLayer; retaining keeps it alive here.
                let layer = unsafe { Retained::retain(ptr as *mut CAMetalLayer) };
                let Some(layer) = layer else {
                    return;
                };
                layer.setDevice(Some(&self.engine.gpu.device));
                layer.setPixelFormat(TARGET_FORMAT);
                layer.setFramebufferOnly(!self.engine.reads_framebuffer());
                // Two drawables: less memory, and a wallpaper does not need deep pipelining.
                layer.setMaximumDrawableCount(2);
                layer.setDrawableSize(CGSize::new(
                    w as f64 * self.render_scale as f64,
                    h as f64 * self.render_scale as f64,
                ));
                match self.targets.iter_mut().find(|(name, _)| name == &id) {
                    Some(target) => {
                        target.1 = Target {
                            layer,
                            size: (w, h),
                        }
                    }
                    None => self.targets.push((
                        id,
                        Target {
                            layer,
                            size: (w, h),
                        },
                    )),
                }
            }
            Command::Detach(id) => {
                self.targets.retain(|(name, _)| name != &id);
            }
            Command::Fit(mode) => {
                self.engine.fit = mode;
            }
            Command::HideScriptedText(hide) => {
                self.engine.hide_scripted_text = hide;
                self.engine.rebuild();
            }
            Command::PanZoom(x, y, zoom) => {
                self.engine.pan = [x, y];
                self.engine.zoom = zoom.max(0.05);
            }
            Command::AudioResponse(enabled) => {
                self.audio_response = enabled;
                if !enabled {
                    self.engine.audio = [vec![0.0; 64], vec![0.0; 64]];
                }
            }
            Command::Sound(muted, volume) => {
                self.muted = muted;
                self.volume = volume;
            }
            Command::Spectrum(left, right) => {
                // A new spectrum alone does not make a still scene redraw.
                self.dirty = was_dirty;
                if self.audio_response {
                    self.engine.audio = [left, right];
                }
                return;
            }
            Command::RenderScale(scale) => {
                self.render_scale = scale.clamp(0.1, 1.0);
                for target in self.targets.iter_mut() {
                    target.1.layer.setDrawableSize(CGSize::new(
                        target.1.size.0 as f64 * self.render_scale as f64,
                        target.1.size.1 as f64 * self.render_scale as f64,
                    ));
                }
            }
            Command::Wake => {}
            Command::RenderFrame(time, reply) => {
                let _ = reply.send(self.offscreen(time as f32));
            }
        }
        let audible = self.playing && self.visible && !self.muted;
        self.engine.sounds.set(audible, self.volume);
    }

    fn frame(&mut self) {
        // After a stall (a Space switch, a busy window server) frames back up behind the
        // minimum-duration presents and stay queued, so the picture lags the pointer for good.
        // Skipping a tick lets the queue drain; the clock catches up on the next frame.
        let now = Instant::now();
        if self.counters.waiting.load(Ordering::Relaxed) >= 2 {
            // A frame that is never shown must not stop drawing for good.
            if now - self.last < Duration::from_millis(250) {
                return;
            }
            self.counters.waiting.store(0, Ordering::Relaxed);
        }
        let period = if self.fps > 0.0 { 1.0 / self.fps } else { 0.0 };
        let mut dt = (now - self.last).as_secs_f32().min(0.25);
        // Frames are shown on a steady cadence (see the present below), so on-time frames advance
        // the clock by exactly one period; wake-up jitter would otherwise show as uneven motion.
        if (0.5 * period..1.5 * period).contains(&dt) {
            dt = period;
        }
        self.last = now;
        self.time += dt;
        if self.targets.is_empty() {
            return;
        }
        let pointer = self.pointer.lock().map(|p| *p).unwrap_or_default();
        // Parallax follows the pointer with the scene's delay instead of jumping with it.
        let delay = self.engine.parallax_now().map_or(0.1, |p| p.delay);
        let ease = if delay > 0.0 {
            (dt / delay).min(1.0)
        } else {
            1.0
        };
        for i in 0..2 {
            self.parallax[i] += (pointer.pos[i] - self.parallax[i]) * ease;
        }
        let input = FrameInput {
            time: self.time,
            frame_time: dt,
            pointer: pointer.pos,
            pointer_down: pointer.down,
            parallax: self.parallax,
        };
        objc2::rc::autoreleasepool(|_| {
            // All displays share one command buffer per frame. Transient targets come from a
            // pool whose memory is reused within a frame; two buffers in flight at once would
            // let the second one write memory the first is still reading.
            let Some(cb) = self.engine.gpu.queue.commandBuffer() else {
                return;
            };
            let mut drawables = Vec::new();
            for (_, target) in self.targets.iter() {
                let Some(drawable) = target.layer.nextDrawable() else {
                    continue;
                };
                if let Err(e) = self.engine.encode(&cb, &drawable.texture(), input) {
                    self.engine.warnings.push(e.to_string());
                    self.playing = false;
                    return;
                }
                drawables.push(drawable);
            }
            if drawables.is_empty() {
                return;
            }
            let counters = self.counters.clone();
            let done = block2::RcBlock::new(
                move |cb: std::ptr::NonNull<ProtocolObject<dyn MTLCommandBuffer>>| {
                    // SAFETY: Metal passes the completed command buffer, valid for this call.
                    let cb = unsafe { cb.as_ref() };
                    let ns = ((cb.GPUEndTime() - cb.GPUStartTime()).max(0.0) * 1e9) as u64;
                    let _ = counters.gpu_ns.fetch_add(ns, Ordering::Relaxed);
                    let _ = counters.frames.fetch_add(1, Ordering::Relaxed);
                },
            );
            // SAFETY: the block is retained by the command buffer until it runs.
            unsafe { cb.addCompletedHandler(block2::RcBlock::as_ptr(&done)) };
            let _ = self.counters.waiting.fetch_add(1, Ordering::Relaxed);
            let counters = self.counters.clone();
            let shown = block2::RcBlock::new(
                move |_: std::ptr::NonNull<ProtocolObject<dyn MTLDrawable>>| {
                    let _ = counters.waiting.fetch_sub(1, Ordering::Relaxed);
                },
            );
            // SAFETY: the block is retained by the drawable until it runs; it runs once, also
            // when the drawable is dropped without being shown.
            unsafe { drawables[0].addPresentedHandler(block2::RcBlock::as_ptr(&shown)) };
            for drawable in &drawables {
                if period > 0.0 {
                    // The window server keeps each frame up for at least this long, which gives
                    // an even frame rate below the display's; the margin keeps it from slipping a
                    // whole refresh when a frame is a little early.
                    cb.presentDrawable_afterMinimumDuration(drawable.as_ref(), period as f64 * 0.9);
                } else {
                    cb.presentDrawable(drawable.as_ref());
                }
            }
            cb.commit();
            self.dirty = false;
            // Videos start and stop with their scripts, so the idle check follows them.
            self.animated = self.engine.is_animated();
        });
    }

    fn offscreen(&mut self, time: f32) -> Result<Vec<u8>, Error> {
        let (w, h) = self.size.unwrap_or((
            self.engine.scene.width as u32,
            self.engine.scene.height as u32,
        ));
        let (w, h) = (w.max(1) as usize, h.max(1) as usize);
        objc2::rc::autoreleasepool(|_| {
            // Videos follow the recorder's clock, which jumps between calls.
            self.engine.offscreen_videos(time);
            let gpu = &self.engine.gpu;
            // SAFETY: plain descriptor construction.
            let desc = unsafe {
                MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                    TARGET_FORMAT,
                    w,
                    h,
                    false,
                )
            };
            desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
            desc.setStorageMode(MTLStorageMode::Shared);
            let target = gpu
                .device
                .newTextureWithDescriptor(&desc)
                .ok_or_else(|| Error::Metal("offscreen target".into()))?;
            let cb = gpu
                .queue
                .commandBuffer()
                .ok_or_else(|| Error::Metal("command buffer".into()))?;
            let pointer = self.pointer.lock().map(|p| p.pos).unwrap_or([0.5, 0.5]);
            let input = FrameInput {
                time,
                frame_time: 1.0 / 30.0,
                // Centred unless someone set a pointer.
                pointer,
                pointer_down: false,
                parallax: pointer,
            };
            self.engine.encode(&cb, &target, input)?;
            cb.commit();
            cb.waitUntilCompleted();
            let mut out = vec![0u8; w * h * 4];
            let region = MTLRegion {
                origin: MTLOrigin { x: 0, y: 0, z: 0 },
                size: MTLSize {
                    width: w,
                    height: h,
                    depth: 1,
                },
            };
            let ptr = std::ptr::NonNull::new(out.as_mut_ptr().cast())
                .ok_or_else(|| Error::Metal("buffer".into()))?;
            // SAFETY: `out` holds exactly w * h * 4 bytes, the size of the region.
            unsafe { target.getBytes_bytesPerRow_fromRegion_mipmapLevel(ptr, w * 4, region, 0) };
            Ok(out)
        })
    }
}
