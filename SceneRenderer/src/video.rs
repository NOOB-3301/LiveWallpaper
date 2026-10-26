//! Video textures: a movie embedded in a `.tex`, decoded by AVFoundation. A worker thread owns
//! an `AVAssetReader` per decode run and pushes BGRA pixel buffers to the render thread, which
//! uploads the frame at the current playhead into the layer's Metal texture. Audio tracks are
//! not decoded: scenes play their music through sound objects.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2::{msg_send, Encode, Encoding};
use objc2_foundation::{NSNumber, NSString};

use crate::Error;

/// `kCVPixelFormatType_32BGRA`, what `MTLPixelFormat::BGRA8Unorm` reads.
const BGRA: i32 = 0x4247_5241;
/// Frames buffered per video. A 4K frame is ~33 MB, so this bounds decoder memory.
const QUEUE_CAP: usize = 4;
/// The value of `AVMediaTypeVideo` (an NSString constant).
const MEDIA_VIDEO: &str = "vide";

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTimeRange {
    start: CMTime,
    duration: CMTime,
}

// SAFETY: the layouts are the C ones from CoreMedia; the encodings only describe the fields.
unsafe impl Encode for CMTime {
    const ENCODING: Encoding = Encoding::Struct(
        "{CMTime=qiIq}",
        &[i64::ENCODING, i32::ENCODING, u32::ENCODING, i64::ENCODING],
    );
}

// SAFETY: as above.
unsafe impl Encode for CMTimeRange {
    const ENCODING: Encoding = Encoding::Struct(
        "{CMTimeRange={CMTime}{CMTime}}",
        &[CMTime::ENCODING, CMTime::ENCODING],
    );
}

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMTimeGetSeconds(t: CMTime) -> f64;
    fn CMTimeMakeWithSeconds(seconds: f64, preferredTimescale: i32) -> CMTime;
    fn CMTimeRangeMake(start: CMTime, duration: CMTime) -> CMTimeRange;
    fn CMSampleBufferGetImageBuffer(s: *const c_void) -> *mut c_void;
    fn CMSampleBufferGetPresentationTimeStamp(s: *const c_void) -> CMTime;
    fn CFRelease(cf: *const c_void);
}

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    fn CVPixelBufferRetain(buffer: *mut c_void) -> *mut c_void;
    fn CVPixelBufferRelease(buffer: *mut c_void);
    fn CVPixelBufferLockBaseAddress(buffer: *mut c_void, lockFlags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(buffer: *mut c_void, unlockFlags: u64) -> i32;
    fn CVPixelBufferGetBaseAddress(buffer: *mut c_void) -> *mut c_void;
    fn CVPixelBufferGetBytesPerRow(buffer: *const c_void) -> usize;
}

/// A decoded frame. The buffer was retained on the worker thread and is only read (base address
/// locked) on the render thread, so the raw pointer is safe to hand over exactly once.
pub struct Frame {
    pub pts: f64,
    buffer: *mut c_void,
}

// SAFETY: the pointer is a retained CVPixelBuffer, whose refcount is atomic; each frame is
// handed to exactly one reader.
unsafe impl Send for Frame {}

impl Frame {
    /// The frame's pixels as BGRA rows, through (pointer, bytes per row). The base address stays
    /// locked for the call.
    ///
    /// # Safety
    ///
    /// The pointer is only valid inside the closure.
    pub unsafe fn with_pixels<T>(&self, f: impl FnOnce(*const c_void, usize) -> T) -> Option<T> {
        if self.buffer.is_null() {
            return None;
        }
        // SAFETY: a read-only lock of a live pixel buffer, released when the guard drops.
        unsafe {
            let _unlock = Locked::new(self.buffer);
            let base = CVPixelBufferGetBaseAddress(self.buffer);
            if base.is_null() {
                return None;
            }
            Some(f(base, CVPixelBufferGetBytesPerRow(self.buffer)))
        }
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        if !self.buffer.is_null() {
            // SAFETY: paired with the retain that created the frame.
            unsafe { CVPixelBufferRelease(self.buffer) };
        }
    }
}

/// Locks a pixel buffer's base address until dropped.
struct Locked(*mut c_void);

impl Locked {
    fn new(buffer: *mut c_void) -> Self {
        // SAFETY: read-only lock of a live pixel buffer.
        unsafe { CVPixelBufferLockBaseAddress(buffer, 0) };
        Self(buffer)
    }
}

impl Drop for Locked {
    fn drop(&mut self) {
        // SAFETY: paired with the lock in `new`.
        unsafe { CVPixelBufferUnlockBaseAddress(self.0, 0) };
    }
}

/// One decode run: a reader over the movie from a start time to its end.
struct Reader {
    /// Retained so the reader and its asset outlive `output`.
    _asset: Retained<AnyObject>,
    _reader: Retained<AnyObject>,
    output: Retained<AnyObject>,
}

impl Reader {
    /// `from` is clamped to the movie; reading starts at the key frame at or before it.
    /// AVFoundation raises ObjC exceptions for bad arguments, so the whole construction runs
    /// inside `exception::catch`; a raise becomes `None` and the video shows nothing.
    fn new(path: &std::path::Path, from: f64, duration: f64) -> Option<Self> {
        let from = from.max(0.0);
        let path = path.to_str()?.to_string();
        let built = objc2::exception::catch(AssertUnwindSafe(|| {
            let asset = open_asset(std::path::Path::new(&path))?;
            let track = video_track(&asset)?;
            let reader_class = AnyClass::get(c"AVAssetReader")?;
            // SAFETY: AVAssetReader's documented constructor; a null error pointer is allowed.
            let reader: Option<Retained<AnyObject>> = unsafe {
                msg_send![reader_class, assetReaderWithAsset: &*asset, error: std::ptr::null_mut::<*mut AnyObject>()]
            };
            let reader = reader?;
            let start = unsafe { CMTimeMakeWithSeconds(from, 600) };
            let length = unsafe { CMTimeMakeWithSeconds((duration - from).max(0.1), 600) };
            let range = unsafe { CMTimeRangeMake(start, length) };
            // SAFETY: plain setter on a live reader.
            unsafe {
                let _: () = msg_send![&*reader, setTimeRange: range];
            }
            // Output settings: BGRA pixels, by the literal value of `kCVPixelBufferPixelFormatTypeKey`.
            let dict_class = AnyClass::get(c"NSMutableDictionary")?;
            let settings: Option<Retained<AnyObject>> = unsafe { msg_send![dict_class, dictionary] };
            let settings = settings?;
            unsafe {
                let _: () = msg_send![
                    &*settings,
                    setObject: &*NSNumber::new_i32(BGRA),
                    forKey: &*NSString::from_str("PixelFormatType")
                ];
            }
            let output_class = AnyClass::get(c"AVAssetReaderTrackOutput")?;
            // SAFETY: the documented initialiser, `alloc` + `initWithTrack:outputSettings:`.
            let output: Option<Retained<AnyObject>> = unsafe {
                let alloc: objc2::rc::Allocated<AnyObject> = msg_send![output_class, alloc];
                msg_send![alloc, initWithTrack: &*track, outputSettings: &*settings]
            };
            let output = output?;
            // SAFETY: plain calls on live objects.
            unsafe {
                let _: Bool = msg_send![&*reader, addOutput: &*output];
                let started: Bool = msg_send![&*reader, startReading];
                if !started.as_bool() {
                    return None;
                }
            }
            Some(Self {
                _asset: asset,
                _reader: reader,
                output,
            })
        }))
        .unwrap_or_else(|e| {
            log_exception("video reader", e.as_deref());
            None
        });
        built
    }

    fn next(&mut self) -> Option<Frame> {
        let output = self.output.clone();
        objc2::exception::catch(AssertUnwindSafe(move || {
            // SAFETY: copyNextSampleBuffer returns a CMSampleBuffer we own, or null at the end.
            let sample: *mut c_void = unsafe { msg_send![&*output, copyNextSampleBuffer] };
            if sample.is_null() {
                return None;
            }
            // SAFETY: the sample buffer is released after we retained its image buffer.
            unsafe {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample);
                let image = CMSampleBufferGetImageBuffer(sample);
                let buffer = if image.is_null() {
                    None
                } else {
                    Some(CVPixelBufferRetain(image))
                };
                CFRelease(sample);
                buffer.map(|buffer| Frame {
                    pts: CMTimeGetSeconds(pts),
                    buffer,
                })
            }
        }))
        .unwrap_or_else(|e| {
            log_exception("video decode", e.as_deref());
            None
        })
    }
}

/// Prints an ObjC exception once; a video that raises keeps rendering nothing instead of taking
/// the process down.
fn log_exception(where_: &str, e: Option<&objc2::exception::Exception>) {
    use std::sync::atomic::{AtomicBool, Ordering};
    static SAID: AtomicBool = AtomicBool::new(false);
    if SAID.swap(true, Ordering::Relaxed) {
        return;
    }
    let reason = e.and_then(|x| {
        // SAFETY: NSException's `reason`, which AVFoundation raises.
        let reason: Option<Retained<NSString>> = unsafe { msg_send![x, reason] };
        reason.map(|s| s.to_string())
    });
    eprintln!(
        "lw video: {where_}: ObjC exception: {}",
        reason.unwrap_or_default()
    );
}

fn open_asset(path: &std::path::Path) -> Option<Retained<AnyObject>> {
    let url = objc2_foundation::NSURL::fileURLWithPath(&NSString::from_str(path.to_str()?));
    let class = AnyClass::get(c"AVURLAsset")?;
    // SAFETY: AVURLAsset's documented constructor; no options.
    unsafe {
        let asset: Option<Retained<AnyObject>> =
            msg_send![class, URLAssetWithURL: &*url, options: std::ptr::null::<*mut AnyObject>()];
        asset
    }
}

/// The asset's first video track.
fn video_track(asset: &AnyObject) -> Option<Retained<AnyObject>> {
    let video = NSString::from_str(MEDIA_VIDEO);
    // SAFETY: synchronous track listing on the calling thread.
    let tracks: Option<Retained<AnyObject>> =
        unsafe { msg_send![asset, tracksWithMediaType: &*video] };
    let tracks = tracks?;
    let count: usize = unsafe { msg_send![&*tracks, count] };
    if count == 0 {
        return None;
    }
    // SAFETY: plain indexed access on a live array.
    unsafe { Some(msg_send![&*tracks, objectAtIndex: 0usize]) }
}

/// Reads the movie's duration and pixel size on the calling thread.
fn probe(path: &std::path::Path) -> Option<(f64, (u32, u32))> {
    let asset = open_asset(path)?;
    let track = video_track(&asset)?;
    // SAFETY: plain property reads on live objects.
    let (duration, size): (CMTime, objc2_core_foundation::CGSize) = unsafe {
        (
            msg_send![&*asset, duration],
            msg_send![&*track, naturalSize],
        )
    };
    let seconds = unsafe { CMTimeGetSeconds(duration) };
    if !seconds.is_finite() || seconds <= 0.0 || size.width < 1.0 || size.height < 1.0 {
        return None;
    }
    Some((seconds, (size.width as u32, size.height as u32)))
}

/// What the renderer wants the worker to decode.
#[derive(Debug, Clone, Copy)]
enum Want {
    /// Decode from a time, continuously.
    Run(f64),
    /// Decode one frame at a time, for a preview while paused.
    Still(f64),
}

impl Want {
    fn from(self) -> f64 {
        match self {
            Self::Run(t) | Self::Still(t) => t,
        }
    }

    fn runs(self) -> bool {
        matches!(self, Self::Run(_))
    }
}

struct Inner {
    shutdown: bool,
    duration: f64,
    /// Bumped on every new `want`; the worker restarts its reader when it changes.
    gen: u64,
    want: Want,
    /// Frames delivered for the current `gen`; a still decode stops after one.
    served: usize,
    /// The worker reached the end of the movie (or could not start) for this `gen`.
    done: bool,
    queue: VecDeque<Frame>,
}

struct Shared {
    inner: Mutex<Inner>,
    signal: Condvar,
}

struct View {
    playing: bool,
    time: f64,
    rate: f32,
    looping: bool,
    current: Option<Frame>,
    /// `gen` of the last want we sent, so repeated commands do not restart the decoder.
    sent: u64,
    /// Increments each time a new frame becomes the shown one; `uploaded` mirrors it for the
    /// caller's upload bookkeeping.
    shown: u64,
    uploaded: u64,
}

/// A video texture. Commands come from scripts and the render loop; the playhead only moves
/// while the renderer draws, so a paused wallpaper never decodes ahead.
pub struct Player {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
    file: PathBuf,
    pub duration: f64,
    /// Pixel dimensions of the video track.
    pub size: (u32, u32),
    view: Mutex<View>,
}

static VIDEO_SEQ: AtomicU64 = AtomicU64::new(0);

impl std::fmt::Debug for Player {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Player")
            .field("duration", &self.duration)
            .field("size", &self.size)
            .finish()
    }
}

impl Player {
    /// `data` is the movie file as stored in the `.tex`. Like Wallpaper Engine, the video
    /// plays from load; a scene drives it with a script whose `init` calls `stop()` first.
    pub fn new(data: &[u8]) -> Result<Self, Error> {
        let file = std::env::temp_dir().join(format!(
            "lw-video-{}-{:x}.mp4",
            std::process::id(),
            VIDEO_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&file, data).map_err(|e| Error::Io(format!("video temp file: {e}")))?;
        let Some((duration, size)) = probe(&file) else {
            let _ = std::fs::remove_file(&file);
            return Err(Error::Unsupported("video track cannot be decoded".into()));
        };
        let shared = Arc::new(Shared {
            inner: Mutex::new(Inner {
                shutdown: false,
                duration,
                gen: 1,
                want: Want::Run(0.0),
                served: 0,
                done: false,
                queue: VecDeque::new(),
            }),
            signal: Condvar::new(),
        });
        let thread_shared = shared.clone();
        let thread_file = file.clone();
        let worker = std::thread::Builder::new()
            .name("lw-video".into())
            .spawn(move || decode_loop(thread_file, thread_shared))
            .map_err(|e| Error::Io(format!("video thread: {e}")))?;
        Ok(Self {
            shared,
            worker: Some(worker),
            file,
            duration,
            size,
            view: Mutex::new(View {
                playing: true,
                time: 0.0,
                rate: 1.0,
                looping: true,
                current: None,
                sent: 1,
                shown: 0,
                uploaded: 0,
            }),
        })
    }

    /// Playing, and where the playhead is.
    pub fn state(&self) -> (bool, f64) {
        let v = self.view.lock().unwrap();
        (v.playing, v.time)
    }

    pub fn play(&self) {
        let mut v = self.view.lock().unwrap();
        v.playing = true;
        let t = v.time;
        self.want(&mut v, Want::Run(t));
    }

    pub fn pause(&self) {
        let mut v = self.view.lock().unwrap();
        v.playing = false;
        let t = v.time;
        self.want(&mut v, Want::Still(t));
    }

    /// Back to the start, showing nothing.
    pub fn stop(&self) {
        let mut v = self.view.lock().unwrap();
        v.playing = false;
        v.time = 0.0;
        v.current = None;
        self.want(&mut v, Want::Still(0.0));
    }

    pub fn seek(&self, time: f64) {
        let mut v = self.view.lock().unwrap();
        v.time = time.clamp(0.0, self.duration);
        let (t, playing) = (v.time, v.playing);
        self.want(
            &mut v,
            if playing {
                Want::Run(t)
            } else {
                Want::Still(t)
            },
        );
    }

    pub fn set_rate(&self, rate: f32) {
        self.view.lock().unwrap().rate = rate.clamp(0.0, 8.0);
    }

    pub fn set_looping(&self, looping: bool) {
        self.view.lock().unwrap().looping = looping;
    }

    /// Moves the playhead by one frame interval. True when a new frame is ready to upload.
    pub fn advance(&self, dt: f32) -> bool {
        let mut v = self.view.lock().unwrap();
        if v.playing {
            v.time += dt as f64 * v.rate as f64;
            if v.time >= self.duration {
                if v.looping {
                    v.time %= self.duration;
                    self.want(&mut v, Want::Run(0.0));
                } else {
                    v.time = self.duration;
                    v.playing = false;
                }
            }
        }
        self.poll(&mut v)
    }

    /// Shows the frame at an absolute scene time, waiting up to `wait_ms` for the decoder (the
    /// offscreen recorder jumps between calls and needs the frame now). True when a new frame is
    /// ready to upload.
    pub fn show_at(&self, time: f64, wait_ms: u64) -> bool {
        let mut v = self.view.lock().unwrap();
        if !v.playing {
            return false;
        }
        let t = if v.looping && self.duration > 0.0 {
            time.rem_euclid(self.duration)
        } else {
            time.clamp(0.0, self.duration)
        };
        v.time = t;
        v.current = None;
        let at = t;
        self.want(&mut v, Want::Run(at));
        let deadline = Instant::now() + Duration::from_millis(wait_ms);
        loop {
            if self.poll(&mut v) {
                return true;
            }
            let ready = v.current.as_ref().is_some_and(|f| f.pts >= t - 1.0 / 240.0);
            if ready || Instant::now() >= deadline {
                return false;
            }
            let inner = self.shared.inner.lock().unwrap();
            if inner.queue.is_empty() && !inner.done {
                let (guard, _) = self
                    .shared
                    .signal
                    .wait_timeout(inner, Duration::from_millis(4))
                    .unwrap();
                drop(guard);
            }
        }
    }

    /// The shown frame's pixels as BGRA rows, through (pointer, bytes per row). The base address
    /// stays locked for the call.
    pub fn with_pixels<T>(&self, f: impl FnOnce(*const c_void, usize) -> T) -> Option<T> {
        let v = self.view.lock().unwrap();
        // SAFETY: the frame's base address is locked for the closure.
        v.current
            .as_ref()
            .and_then(|frame| unsafe { frame.with_pixels(f) })
    }

    fn want(&self, v: &mut View, want: Want) {
        // A command equivalent to the current one (scripts call play/pause every frame) must not
        // restart the decoder; one whose run already reached the movie's end stays put too.
        {
            let inner = self.shared.inner.lock().unwrap();
            let same = match (inner.want, want) {
                (Want::Run(a), Want::Run(b)) | (Want::Still(a), Want::Still(b)) => {
                    (a - b).abs() < 0.05
                }
                _ => false,
            };
            let at_end = inner.done
                && matches!((inner.want, want), (Want::Run(_), Want::Run(b)) if b >= self.duration - 0.1);
            if (same && inner.gen == v.sent) || at_end {
                return;
            }
        }
        v.sent = self.force_want(want);
    }

    fn force_want(&self, want: Want) -> u64 {
        let gen = {
            let mut inner = self.shared.inner.lock().unwrap();
            inner.gen += 1;
            inner.want = want;
            inner.served = 0;
            inner.done = false;
            inner.queue.clear();
            inner.gen
        };
        self.shared.signal.notify_all();
        gen
    }

    /// Takes queued frames up to the playhead; the newest becomes the shown frame. True when the
    /// shown frame is new since the caller last saw one.
    fn poll(&self, v: &mut View) -> bool {
        let mut inner = self.shared.inner.lock().unwrap();
        while let Some(front) = inner.queue.front() {
            if front.pts <= v.time + 1.0 / 240.0 {
                v.current = inner.queue.pop_front();
                v.shown += 1;
            } else {
                break;
            }
        }
        self.shared.signal.notify_all();
        if v.shown != v.uploaded {
            v.uploaded = v.shown;
            true
        } else {
            false
        }
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        {
            let mut inner = self.shared.inner.lock().unwrap();
            inner.shutdown = true;
        }
        self.shared.signal.notify_all();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let _ = std::fs::remove_file(&self.file);
    }
}

fn decode_loop(file: PathBuf, shared: Arc<Shared>) {
    let mut reader: Option<Reader> = None;
    let mut reader_gen: u64 = 0;
    loop {
        enum Step {
            Open(f64, f64),
            Read,
        }
        // Decide under the lock, decode outside it.
        let step = {
            let mut inner = shared.inner.lock().unwrap();
            loop {
                if inner.shutdown {
                    return;
                }
                if inner.gen != reader_gen {
                    let from = inner.want.from();
                    break Step::Open(from, inner.duration);
                }
                if !inner.done
                    && inner.queue.len() < QUEUE_CAP
                    && (inner.want.runs() || inner.served == 0)
                {
                    break Step::Read;
                }
                // Nothing to do: wait until the renderer pops frames or changes the want.
                inner = shared.signal.wait(inner).unwrap();
            }
        };
        match step {
            Step::Open(from, duration) => {
                let gen = shared.inner.lock().unwrap().gen;
                reader = Reader::new(&file, from, duration);
                reader_gen = gen;
                if reader.is_none() {
                    shared.inner.lock().unwrap().done = true;
                }
            }
            Step::Read => {
                let frame = reader.as_mut().and_then(|r| r.next());
                let mut inner = shared.inner.lock().unwrap();
                match frame {
                    Some(frame) => {
                        inner.served += 1;
                        inner.queue.push_back(frame);
                    }
                    None => inner.done = true,
                }
                shared.signal.notify_all();
            }
        }
    }
}
