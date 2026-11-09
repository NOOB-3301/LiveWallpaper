//! Renders one frame of a scene to PNG.
//!
//! Usage: render_png <scene.pkg> <out.png> [time] [width height] [fit]
//! `fit` is one of fill, fit, stretch, unscaled, blurred.
//! `LW_AUDIO=0.6` feeds a test spectrum.
//! `LW_PROPS="name=json,name=json"` sets user properties first, e.g. `LW_PROPS=clock=1`.
use scene_renderer::FitMode;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let started = std::time::Instant::now();
    let r = scene_renderer::Renderer::new(a[1].clone()).expect("load");
    println!("loaded in {:?}", started.elapsed());
    for e in r.load_errors() {
        println!("warning: {e}");
    }
    let time: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let w: u32 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(1920);
    let h: u32 = a.get(5).and_then(|s| s.parse().ok()).unwrap_or(1080);
    if let Some(mode) = a.get(6) {
        let mode = match mode.as_str() {
            "fit" => FitMode::Fit,
            "stretch" => FitMode::Stretch,
            "unscaled" => FitMode::Unscaled,
            "blurred" => FitMode::MatchBlurred,
            _ => FitMode::Fill,
        };
        r.set_fit_mode(mode);
    }
    // `LW_HIDE_TEXT=1` hides script-computed text, as the lock screen recording does.
    r.set_hide_scripted_text(std::env::var("LW_HIDE_TEXT").is_ok());
    for pair in std::env::var("LW_PROPS").unwrap_or_default().split(',').filter(|p| !p.is_empty()) {
        if let Some((name, value)) = pair.split_once('=') {
            r.apply_property(name.to_string(), value.to_string());
        }
    }
    // `LW_AUDIO=0.6` feeds a flat spectrum at that level, to see audio-driven layers.
    if let Some(level) = std::env::var("LW_AUDIO").ok().and_then(|v| v.parse::<f32>().ok()) {
        r.set_audio_response(true);
        let bands: Vec<f32> = (0..64).map(|i| level * (1.0 - i as f32 / 128.0)).collect();
        r.set_audio_spectrum(bands.clone(), bands);
    }
    // `LW_POINTER=0.1,0.9` puts the pointer there (0...1, top-left origin).
    if let Some((x, y)) = std::env::var("LW_POINTER").ok().and_then(|v| {
        let (x, y) = v.split_once(',')?;
        Some((x.parse().ok()?, y.parse().ok()?))
    }) {
        r.set_pointer(x, y);
    }
    r.resize(w, h);
    // `LW_FRAMES=n` renders n-1 warm-up frames (1/30 s apart) first, so scripts settle.
    let frames: u32 = std::env::var("LW_FRAMES").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
    for i in 1..frames {
        let _ = r.render_frame(time - f64::from(frames - i) / 30.0);
    }
    let started = std::time::Instant::now();
    let mut px = r.render_frame(time).expect("render");
    println!("frame in {:?}", started.elapsed());
    for e in r.load_errors() {
        println!("after frame: {e}");
    }
    for p in px.chunks_mut(4) {
        p.swap(0, 2);
    }
    image::save_buffer(&a[2], &px, w, h, image::ColorType::Rgba8).expect("save");
}
