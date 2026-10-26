//! Scene state on the GPU and the per-frame draw.
//!
//! Everything that only changes with user properties (textures, programs, pipelines, uniform
//! defaults and constants) is resolved once into `DrawItem`s; a frame only patches the few
//! engine-driven uniforms (matrices, time) and issues draws.

use std::collections::{BTreeMap, HashMap};
use std::ffi::c_void;
use std::ptr::NonNull;
use std::rc::Rc;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::*;
use serde_json::Value;

use crate::gpu::{self, Gpu, Pool, Texture, TARGET_FORMAT};
use crate::mat;
use crate::particles;
use crate::puppet;
use crate::scene::{self, floats, Blend, Layer, Material, ParticleLayer, PuppetLayer, Scene};
use crate::shader::{self, Program, Uniform};
use crate::tex::Frame;
use crate::text::{self, TextRenderer, TextSpec};
use crate::vfs::Vfs;
use crate::Error;

#[path = "engine_scripts.rs"]
mod scripts;

type Mat4 = [f32; 16];

const IDENTITY: Mat4 = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

/// Maps the unit model quad onto a whole render target (y down, like the texture).
const FBO_MVP: Mat4 = [
    2., 0., 0., 0., 0., -2., 0., 0., 0., 0., 0., 0., 0., 0., 0.5, 1.,
];

fn mul(a: &Mat4, b: &Mat4) -> Mat4 {
    let mut out = [0.0; 16];
    for c in 0..4 {
        for r in 0..4 {
            out[c * 4 + r] = (0..4).map(|k| a[k * 4 + r] * b[c * 4 + k]).sum();
        }
    }
    out
}

fn translate(x: f32, y: f32, z: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[12] = x;
    m[13] = y;
    m[14] = z;
    m
}

fn scale(x: f32, y: f32, z: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[0] = x;
    m[5] = y;
    m[10] = z;
    m
}

fn rotate_z(a: f32) -> Mat4 {
    let (s, c) = a.sin_cos();
    let mut m = IDENTITY;
    m[0] = c;
    m[1] = s;
    m[4] = -s;
    m[5] = c;
    m
}

/// Orthographic projection to Metal clip space with z pinned to the middle of the depth range.
fn ortho(l: f32, r: f32, b: f32, t: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[0] = 2.0 / (r - l);
    m[5] = 2.0 / (t - b);
    m[10] = 0.0;
    m[12] = -(r + l) / (r - l);
    m[13] = -(t + b) / (t - b);
    m[14] = 0.5;
    m
}

fn invert_affine_2d(m: &Mat4) -> Mat4 {
    let (a, b, c, d) = (m[0], m[1], m[4], m[5]);
    let det = a * d - b * c;
    if det.abs() < 1e-12 {
        return IDENTITY;
    }
    let (ia, ib, ic, id) = (d / det, -b / det, -c / det, a / det);
    let (tx, ty) = (m[12], m[13]);
    let mut out = IDENTITY;
    out[0] = ia;
    out[1] = ib;
    out[4] = ic;
    out[5] = id;
    out[12] = -(ia * tx + ic * ty);
    out[13] = -(ib * tx + id * ty);
    out
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Dyn {
    Mvp,
    Model,
    ModelInverse,
    ViewProjection,
    MvpInverse,
    TexProjectionInverse,
    Identity,
    Time,
    FrameTime,
    DayTime,
    Screen,
    Pointer,
    Parallax,
    TexResolution(usize),
    TexTexel(usize),
    TexelSize,
    TexelSizeHalf,
    Color4,
    Color3,
    Alpha,
    SpriteRotation,
    SpriteTranslation,
    /// Audio spectrum: right channel?, band count.
    Audio(bool, usize),
}

impl Dyn {
    /// Changes between frames without any property change.
    fn moves(self) -> bool {
        matches!(
            self,
            Self::Time
                | Self::FrameTime
                | Self::DayTime
                | Self::Pointer
                | Self::Parallax
                | Self::SpriteRotation
                | Self::SpriteTranslation
                | Self::Audio(..)
        )
    }
}

fn engine_uniform(name: &str) -> Option<Dyn> {
    Some(match name {
        "g_ModelViewProjectionMatrix" | "g_EffectModelViewProjectionMatrix" => Dyn::Mvp,
        "g_ModelMatrix" | "g_EffectModelMatrix" | "g_AltModelMatrix" => Dyn::Model,
        "g_ModelMatrixInverse" => Dyn::ModelInverse,
        "g_ViewProjectionMatrix" | "g_AltViewProjectionMatrix" => Dyn::ViewProjection,
        "g_ModelViewProjectionMatrixInverse" | "g_EffectModelViewProjectionMatrixInverse" => {
            Dyn::MvpInverse
        }
        "g_EffectTextureProjectionMatrixInverse" => Dyn::TexProjectionInverse,
        "g_EffectTextureProjectionMatrix" | "g_NormalModelMatrix" => Dyn::Identity,
        "g_Time" => Dyn::Time,
        "g_Frametime" => Dyn::FrameTime,
        "g_Daytime" | "g_DayTime" => Dyn::DayTime,
        "g_Screen" => Dyn::Screen,
        "g_PointerPosition" | "g_PointerPositionLast" => Dyn::Pointer,
        "g_ParallaxPosition" => Dyn::Parallax,
        "g_TexelSize" => Dyn::TexelSize,
        "g_TexelSizeHalf" => Dyn::TexelSizeHalf,
        "g_Color4" => Dyn::Color4,
        "g_Color" => Dyn::Color3,
        "g_Alpha" | "g_UserAlpha" => Dyn::Alpha,
        "g_Texture0Rotation" => Dyn::SpriteRotation,
        "g_Texture0Translation" => Dyn::SpriteTranslation,
        _ if name.starts_with("g_AudioSpectrum") => {
            let rest = name.strip_prefix("g_AudioSpectrum")?.strip_suffix("_v")?;
            let digits = rest.find(|c: char| !c.is_ascii_digit())?;
            Dyn::Audio(&rest[digits..] == "Right", rest[..digits].parse().ok()?)
        }
        _ => {
            let rest = name.strip_prefix("g_Texture")?;
            let digits = rest.find(|c: char| !c.is_ascii_digit())?;
            let index = rest[..digits].parse().ok()?;
            match &rest[digits..] {
                "Resolution" => Dyn::TexResolution(index),
                "Texel" => Dyn::TexTexel(index),
                _ => return None,
            }
        }
    })
}

/// A loaded image: one GPU texture per sprite-sheet image.
#[derive(Debug)]
struct TexEntry {
    images: Vec<Retained<Texture>>,
    /// (texture w, texture h, image w, image h)
    res: [f32; 4],
    frames: Vec<Frame>,
    sampler: usize,
    /// Set for a video texture: `images[0]` is the texture its frames are uploaded into.
    video: Option<crate::video::Player>,
}

impl TexEntry {
    fn frame(&self, time: f32) -> Option<&Frame> {
        let total: f32 = self.frames.iter().map(|f| f.seconds).sum();
        if total <= 0.0 {
            return self.frames.first();
        }
        let mut t = time.rem_euclid(total);
        self.frames.iter().find(|f| {
            t -= f.seconds;
            t < 0.0
        })
    }
}

#[derive(Debug, Clone)]
enum TexSource {
    Image(Rc<TexEntry>),
    /// `previous` or an effect FBO name, resolved at draw time.
    Target(String),
}

#[derive(Debug)]
struct DrawItem {
    pipeline: Retained<gpu::Pipeline>,
    /// (Metal slot, g_TextureN index, source)
    textures: Vec<(u8, usize, TexSource)>,
    vs: Vec<u8>,
    fs: Vec<u8>,
    dynamic: Vec<(bool, Uniform, Dyn)>,
    /// Samples `_rt_FullFrameBuffer`.
    reads_frame: bool,
}

#[derive(Debug)]
struct EffectPassGpu {
    item: DrawItem,
    target: Option<String>,
}

#[derive(Debug)]
struct EffectGpu {
    passes: Vec<EffectPassGpu>,
    fbos: Vec<(String, f32)>,
}

#[derive(Debug)]
struct LayerGpu {
    /// The material draw; `None` for groups.
    base: Option<DrawItem>,
    /// The same material drawn unblended into the first effect buffer.
    base_fx: Option<DrawItem>,
    /// Texture 0 of the base material, used for sizing and the fallback.
    image: Option<Rc<TexEntry>>,
    /// Visible effects only.
    effects: Vec<EffectGpu>,
    blend: Blend,
    /// Placement resolved from the current properties; `None` when hidden or sizeless.
    placed: Option<Placed>,
    /// For a text layer: its bitmap quad inside the layer box (`x, y, w, h`, y down).
    text_rect: Option<[f32; 4]>,
    /// The layer draws a skinned mesh instead of a quad.
    puppet: bool,
    /// The effect chain's output never changes (no time, pointer or sprite input), so it is
    /// rendered once and kept.
    still: bool,
    cached: Option<Retained<Texture>>,
    /// Drawn to the screen; a hidden layer is still built when another layer samples its output.
    shown: bool,
}

#[derive(Debug, Clone, Copy)]
struct Placed {
    world: Mat4,
    size: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    compose: bool,
}

/// A particle system bound to its scene layer.
struct ParticleGpu {
    /// Scene layer index, so particles draw in the same order as the other objects.
    layer: usize,
    sim: particles::Simulation,
    texture: Option<Rc<TexEntry>>,
    blend: Blend,
    /// The layer's transform, in design units.
    world: Mat4,
    color: [f32; 3],
    alpha: f32,
}

/// A puppet drawn as a skinned mesh.
struct PuppetGpu {
    /// Scene layer index.
    layer: usize,
    model: Rc<puppet::Puppet>,
    /// Bind-pose local transform decomposed to translation, Euler rotation and scale.
    bind: Vec<([f32; 3], [f32; 3], [f32; 3])>,
    /// Inverse of each bone's bind-pose world matrix.
    bind_inverse: Vec<mat::M4>,
    /// Enabled animation layers: animation index, rate, blend weight, additive.
    animations: Vec<(usize, f32, f32, bool)>,
    /// The mesh's index buffer, built once.
    indices: Retained<ProtocolObject<dyn MTLBuffer>>,
    texture: Option<Rc<TexEntry>>,
    blend: Blend,
}

/// Values a frame needs.
#[derive(Debug, Clone, Copy)]
pub struct FrameInput {
    pub time: f32,
    pub frame_time: f32,
    pub pointer: [f32; 2],
    pub pointer_down: bool,
    /// The pointer eased over time (0...1, centre 0.5): `g_ParallaxPosition`.
    pub parallax: [f32; 2],
}

#[derive(Debug, Clone, Copy)]
struct DrawCtx {
    mvp: Mat4,
    model: Mat4,
    view_projection: Mat4,
    target: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    /// Intermediate buffers are rendered at this fraction of the layer's native size;
    /// resolution uniforms still report native sizes, so texel-based kernels keep their look.
    buffer_scale: [f32; 2],
    /// The layer's own unit quad (y down) to the screen, and its size in design units. Effect
    /// passes draw a buffer-filling quad, but pointer effects unproject the cursor through these.
    screen_mvp: Mat4,
    size: [f32; 2],
}

/// How the scene is mapped onto the target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FitMode {
    /// Cover the target; the overflow is cropped.
    Fill,
    /// Show the whole scene; the rest stays empty.
    Fit,
    /// Stretch the scene onto the target, ignoring the aspect ratio.
    Stretch,
    /// One scene pixel per target pixel.
    Unscaled,
    /// Show the whole scene; a blurred copy of it fills the rest.
    MatchBlurred,
}

pub struct Engine {
    pub gpu: Gpu,
    vfs: Vfs,
    pub scene: Scene,
    pub props: HashMap<String, Value>,
    textures: HashMap<String, Rc<TexEntry>>,
    sources: HashMap<String, Rc<shader::Source>>,
    programs: HashMap<(String, BTreeMap<String, i64>), Rc<Program>>,
    pipelines: HashMap<(usize, Blend, usize), Retained<gpu::Pipeline>>,
    layers: Vec<LayerGpu>,
    /// Layers whose effect output another layer samples as `_rt_imageLayerComposite_<id>_a`,
    /// with that name. X-ray scenes hide the revealed picture and sample it this way.
    composite_refs: Vec<(usize, String)>,
    pool: Pool,
    pub warnings: Vec<String>,
    samples: usize,
    msaa: Option<Retained<Texture>>,
    white: Rc<TexEntry>,
    black: Rc<TexEntry>,
    /// How the scene is mapped onto the target.
    pub fit: FitMode,
    /// Horizontal and vertical offset, in screen widths and heights.
    pub pan: [f32; 2],
    /// Magnification; 1 shows the scene at its fitted size.
    pub zoom: f32,
    /// Text bitmaps, keyed by font, size and string.
    text: TextRenderer,
    /// Fonts by (name, point size).
    fonts: HashMap<(String, u32), Rc<text::Font>>,
    /// On-screen pixels per design pixel the text bitmaps were rasterised for.
    text_scale: f32,
    /// A text bitmap is too small or too sharp for the current zoom; rebuild after this frame.
    text_dirty: bool,
    /// Hides text layers whose string a script computes, e.g. clocks, when a frame is recorded
    /// for a place that cannot update (the lock screen plays a fixed loop).
    pub hide_scripted_text: bool,
    /// Particle systems, one per visible particle layer.
    particles: Vec<ParticleGpu>,
    /// Skinned meshes, one per visible puppet layer.
    puppets: Vec<PuppetGpu>,
    /// Time the puppet poses are sampled at; attached layers read it through `world`.
    pose_time: f32,
    /// Camera parallax this frame: how far a layer of depth 1 moves, in design units.
    parallax_shift: [f32; 2],
    /// Camera shake this frame: the view's offset, in design units.
    shake_offset: [f32; 2],
    /// The scene's SceneScript runtime; `None` when the scene has no scripts.
    script_host: Option<crate::script::Host>,
    /// Latest audio spectrum, left and right, 0..1 per band.
    pub audio: [Vec<f32>; 2],
    pub sounds: crate::sound::Sounds,
    /// Video textures by cache key; weak, so they are dropped with their `TexEntry`.
    videos: Vec<(String, std::rc::Weak<TexEntry>)>,
    /// Scene time of the previous frame, to tell stepping from seeking.
    last_input_time: Option<f32>,
}

impl Engine {
    pub fn load(vfs: Vfs, props: HashMap<String, Value>) -> Result<Self, Error> {
        let gpu = Gpu::new()?;
        let mut warnings = Vec::new();
        let scene = Scene::load(&vfs, &mut warnings)?;
        for (kind, n) in &scene.skipped {
            warnings.push(format!("{n} {kind} object(s) not drawn yet"));
        }
        let solid = |rgba| -> Result<Rc<TexEntry>, Error> {
            Ok(Rc::new(TexEntry {
                images: vec![gpu.solid(rgba)?],
                res: [1.0; 4],
                frames: Vec::new(),
                video: None,
                sampler: 1,
            }))
        };
        let (white, black) = (solid([255; 4])?, solid([0, 0, 0, 255])?);
        let sounds = crate::sound::Sounds::load(&vfs, &scene.sounds, &mut warnings);
        let mut engine = Self {
            gpu,
            vfs,
            scene,
            props,
            textures: HashMap::new(),
            sources: HashMap::new(),
            programs: HashMap::new(),
            pipelines: HashMap::new(),
            layers: Vec::new(),
            composite_refs: Vec::new(),
            pool: Pool::default(),
            warnings,
            samples: 1,
            msaa: None,
            white,
            black,
            // Shows the whole scene; callers that never set a fit mode (the lock screen recorder) get this.
            fit: FitMode::MatchBlurred,
            pan: [0.0, 0.0],
            zoom: 1.0,
            text: TextRenderer::new(),
            fonts: HashMap::new(),
            text_scale: 0.0,
            text_dirty: false,
            hide_scripted_text: false,
            particles: Vec::new(),
            puppets: Vec::new(),
            pose_time: 0.0,
            parallax_shift: [0.0; 2],
            shake_offset: [0.0; 2],
            script_host: None,
            audio: [vec![0.0; 64], vec![0.0; 64]],
            sounds,
            videos: Vec::new(),
            last_input_time: None,
        };
        engine.rebuild();
        engine.start_scripts();
        Ok(engine)
    }

    /// Re-resolves materials after a property or antialiasing change. Textures, shader sources,
    /// programs and pipelines are cached, so only changed combos compile anything.
    pub fn rebuild(&mut self) {
        self.composite_refs = self.find_composite_refs();
        let layers = (0..self.scene.layers.len())
            .map(|i| self.build_layer(i))
            .collect();
        self.layers = layers;
        // Running simulations and loaded meshes survive a rebuild; only new layers load.
        let mut old_systems = std::mem::take(&mut self.particles);
        let mut old_puppets = std::mem::take(&mut self.puppets);
        let mut systems = Vec::new();
        for index in 0..self.scene.layers.len() {
            let Some(layer) = self.scene.layers[index].particles.clone() else {
                continue;
            };
            if !self.visible(index) {
                continue;
            }
            if let Some(i) = old_systems.iter().position(|p| p.layer == index) {
                systems.push(old_systems.swap_remove(i));
                continue;
            }
            match self.particle_system(index, &layer) {
                Ok(system) => systems.push(system),
                Err(e) => self.warnings.push(format!(
                    "layer {}: {e}; particles skipped",
                    self.scene.layers[index].name
                )),
            }
        }
        self.particles = systems;
        let mut puppets = Vec::new();
        for index in 0..self.scene.layers.len() {
            let Some(layer) = self.scene.layers[index].puppet.clone() else {
                continue;
            };
            if !self.visible(index) {
                continue;
            }
            if let Some(i) = old_puppets.iter().position(|p| p.layer == index) {
                let mut kept = old_puppets.swap_remove(i);
                // A property may have toggled one of its animation layers.
                kept.animations = self.puppet_animations(&kept.model, &layer);
                puppets.push(kept);
                continue;
            }
            match self.puppet_mesh(index, &layer) {
                Ok(mesh) => puppets.push(mesh),
                Err(e) => {
                    // A model we cannot read still has its picture: draw that, unwarped, rather
                    // than leaving a hole in the scene.
                    self.layers[index].puppet = false;
                    self.warnings.push(format!(
                        "layer {}: {e}; drawn as a plain image",
                        self.scene.layers[index].name
                    ));
                }
            }
        }
        self.puppets = puppets;
        // Drop textures nothing draws any more (hidden by a property change).
        self.textures.retain(|_, t| Rc::strong_count(t) > 1);
        self.videos = self
            .textures
            .iter()
            .filter(|(_, t)| t.video.is_some())
            .map(|(k, t)| (k.clone(), Rc::downgrade(t)))
            .collect();
        let mut seen = std::collections::HashSet::new();
        self.warnings.retain(|w| seen.insert(w.clone()));
    }

    /// Redraws the bitmaps of text layers (new string or new zoom) without touching the rest.
    pub fn refresh_texts(&mut self) {
        for i in 0..self.scene.layers.len().min(self.layers.len()) {
            if self.scene.layers[i].text.is_some() {
                self.layers[i] = self.build_layer(i);
            }
        }
    }

    /// Layers that visible layers' materials or effects sample as `_rt_imageLayerComposite_<id>_a`,
    /// directly or through another sampled layer, ordered so each comes before its readers. A
    /// layer in a cycle samples nothing prepared this frame.
    fn find_composite_refs(&self) -> Vec<(usize, String)> {
        // (layer index, buffer name) for every composite a layer samples.
        let sources = |i: usize| -> Vec<(usize, String)> {
            let layer = &self.scene.layers[i];
            let passes = layer
                .effects
                .iter()
                .flat_map(|e| e.passes.iter().map(|p| &p.material));
            layer
                .material
                .iter()
                .chain(passes)
                .flat_map(|m| m.textures.iter().flatten())
                .filter_map(|name| {
                    let (id, _) = name
                        .strip_prefix("_rt_imageLayerComposite_")?
                        .rsplit_once('_')?;
                    let id = id.parse::<i64>().ok()?;
                    let target = self.scene.layers.iter().position(|l| l.id == id)?;
                    (target != i).then(|| (target, name.clone()))
                })
                .collect()
        };
        fn visit(
            node: (usize, String),
            sources: &dyn Fn(usize) -> Vec<(usize, String)>,
            visiting: &mut Vec<usize>,
            out: &mut Vec<(usize, String)>,
        ) {
            if visiting.contains(&node.0) || out.iter().any(|(_, n)| *n == node.1) {
                return;
            }
            visiting.push(node.0);
            for s in sources(node.0) {
                visit(s, sources, visiting, out);
            }
            let _ = visiting.pop();
            out.push(node);
        }
        let mut out = Vec::new();
        for i in (0..self.scene.layers.len()).filter(|&i| self.visible(i)) {
            for s in sources(i) {
                visit(s, &sources, &mut vec![i], &mut out);
            }
        }
        out
    }

    /// GPU state of one layer: its draw items, effect chain and placement.
    fn build_layer(&mut self, index: usize) -> LayerGpu {
        let layer = self.scene.layers[index].clone();
        let shown = self.visible(index);
        // Hidden layers load nothing unless another layer samples them; a property change that
        // shows them rebuilds.
        let visible = shown || self.composite_refs.iter().any(|(i, _)| *i == index);
        let text = if visible && layer.text.is_some() {
            self.text_material(&layer)
        } else {
            None
        };
        let material = match (layer.material.as_ref().filter(|_| visible), text) {
            (Some(m), _) => Some((m.clone(), None)),
            (None, Some((m, rect))) => Some((m, Some(rect))),
            (None, None) => None,
        };
        let Some((material, text_rect)) = material else {
            return LayerGpu {
                base: None,
                base_fx: None,
                image: None,
                effects: Vec::new(),
                blend: Blend::Translucent,
                placed: None,
                text_rect: None,
                puppet: false,
                still: false,
                cached: None,
                shown,
            };
        };
        let material = &material;
        let has_effects = !layer.effects.is_empty();
        let image = material
            .textures
            .first()
            .and_then(|t| t.as_deref())
            .filter(|t| !t.starts_with("_rt_"))
            .and_then(|t| self.texture(t));
        let base = match self.draw_item(
            material,
            material.blend,
            TARGET_FORMAT,
            self.samples,
            &[],
            false,
        ) {
            Ok(item) => Some(item),
            Err(e) => {
                self.warnings.push(format!(
                    "layer {}: {e}; drawing its texture directly",
                    layer.name
                ));
                None
            }
        };
        // With effects the base pass renders into an intermediate buffer, replacing it whole.
        let base_fx = if has_effects && base.is_some() {
            // The colour blend mode applies when the finished layer meets the screen.
            let mut plain = material.clone();
            let _ = plain.combos.remove("BLENDMODE");
            self.draw_item(&plain, Blend::Disabled, gpu::FBO_FORMAT, 1, &[], false)
                .ok()
        } else {
            None
        };
        // A colour blend mode on a layer whose own shader cannot blend (a solid layer's `flat`)
        // still applies: the finished effect result meets the screen through the stock image
        // shader, which does. Without this the blend is dropped and a black effect result shows.
        let base = if base_fx.is_some()
            && material.combos.get("BLENDMODE").is_some_and(|&m| m != 0)
            && base.as_ref().is_some_and(|b| !b.reads_frame)
        {
            let wrap = Material {
                shader: "genericimage2".into(),
                blend: material.blend,
                textures: vec![None],
                combos: material.combos.clone(),
                constants: HashMap::new(),
            };
            self.draw_item(&wrap, wrap.blend, TARGET_FORMAT, self.samples, &[], false)
                .ok()
                .or(base)
        } else {
            base
        };
        let mut effects = Vec::new();
        for effect in &layer.effects {
            if !effect.visible.truthy(&self.props) {
                continue;
            }
            let mut passes = Vec::new();
            let mut failed = None;
            for pass in &effect.passes {
                match self.draw_item(
                    &pass.material,
                    pass.material.blend,
                    gpu::FBO_FORMAT,
                    1,
                    &pass.binds,
                    true,
                ) {
                    Ok(item) => passes.push(EffectPassGpu {
                        item,
                        target: pass.target.clone(),
                    }),
                    Err(e) => {
                        failed = Some(e);
                        break;
                    }
                }
            }
            match failed {
                Some(e) => self.warnings.push(format!(
                    "layer {}: effect {} skipped: {e}",
                    layer.name, effect.name
                )),
                None => effects.push(EffectGpu {
                    passes,
                    fbos: effect
                        .fbos
                        .iter()
                        .map(|f| (f.name.clone(), f.scale.max(1.0)))
                        .collect(),
                }),
            }
        }
        let placed = self.place(index, &layer, image.as_deref());
        let items = base_fx.iter().chain(
            effects
                .iter()
                .flat_map(|e| e.passes.iter().map(|p| &p.item)),
        );
        let still = !effects.is_empty()
            && !base.as_ref().is_some_and(|b| b.reads_frame)
            && image
                .as_ref()
                .is_none_or(|t| t.frames.len() <= 1 && t.video.is_none())
            && !placed.is_some_and(|p| p.compose)
            && items
                .into_iter()
                .all(|i| !i.reads_frame && !i.dynamic.iter().any(|(_, _, d)| d.moves()));
        LayerGpu {
            base,
            base_fx,
            image,
            effects,
            blend: material.blend,
            placed,
            text_rect,
            puppet: layer.puppet.is_some(),
            still,
            cached: None,
            shown,
        }
    }

    pub fn set_samples(&mut self, samples: usize) {
        let samples = match samples {
            0 | 1 => 1,
            2 | 3 => 2,
            _ => 4,
        };
        if samples != self.samples {
            self.samples = samples;
            self.msaa = None;
            self.rebuild();
        }
    }

    /// Frees intermediate buffers; they are recreated on the next frame.
    pub fn trim(&mut self) {
        self.pool.clear();
        for l in &mut self.layers {
            l.cached = None;
        }
        self.msaa = None;
    }

    /// Rasterises a text layer at the last known zoom and registers the bitmap as a texture.
    /// The returned material draws it like an image layer, so effects, colour and alpha work
    /// the same way they do for images.
    fn text_material(&mut self, layer: &Layer) -> Option<(Material, [f32; 4])> {
        let t = layer.text.as_ref()?;
        let scale = if self.text_scale > 0.0 {
            self.text_scale
        } else {
            2.0
        };
        // The editor sizes a text box to fit its text, so the box height against the font's
        // line height at the stored point size gives the point-to-design-unit factor.
        let font = self.font(&t.font, t.point_size).and_then(|base| {
            let (a, d, l) = base.metrics();
            let inner = layer.size[1] - 2.0 * t.padding;
            let k = if a + d + l > 0.0 && inner > 0.0 {
                (inner / (a + d + l)).clamp(1.0, 8.0)
            } else {
                4.0
            };
            self.font(&t.font, t.point_size * k)
        });
        let font = match font {
            Ok(f) => f,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        let spec = TextSpec {
            text: t.value.clone(),
            // The layer's colour and alpha uniforms tint the bitmap, as for image layers.
            color: [1.0; 4],
            opacity: 1.0,
            h_align: text::HAlign::from_scene(Some(&t.horizontal_align)),
            v_align: text::VAlign::from_scene(Some(&t.vertical_align)),
            line_spacing: 1.0,
            padding: t.padding,
            pixels_per_point: scale,
            box_size: Some(layer.size),
        };
        let bitmap = match self.text.render(&font, &spec) {
            Ok(b) => b,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        if bitmap.is_empty() {
            return None;
        }
        let texture = match self.upload_bitmap(&bitmap) {
            Ok(t) => t,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        let key = format!("@text/{}", layer.id);
        let (w, h) = (bitmap.width as f32, bitmap.height as f32);
        let entry = Rc::new(TexEntry {
            images: vec![texture],
            res: [w, h, w, h],
            frames: Vec::new(),
            video: None,
            sampler: 0,
        });
        let _ = self.textures.insert(key.clone(), entry);
        let material = Material {
            shader: "genericimage2".into(),
            blend: Blend::Translucent,
            textures: vec![Some(key)],
            combos: BTreeMap::new(),
            constants: HashMap::new(),
        };
        Some((material, bitmap.rect))
    }

    /// A font from the package or the system, cached per name and point size.
    fn font(&mut self, name: &str, point_size: f32) -> Result<Rc<text::Font>, Error> {
        let key = (name.to_string(), point_size.to_bits());
        if let Some(font) = self.fonts.get(&key) {
            return Ok(font.clone());
        }
        let source = text::FontSource::from_scene(&self.vfs, name);
        let font = Rc::new(text::Font::load(&source, point_size)?);
        let _ = self.fonts.insert(key, font.clone());
        Ok(font)
    }

    /// Loads a puppet model, its index buffer and the bind-pose data skinning needs.
    /// The puppet's enabled animation layers with the user's property values applied.
    fn puppet_animations(
        &self,
        model: &puppet::Puppet,
        layer: &PuppetLayer,
    ) -> Vec<(usize, f32, f32, bool)> {
        let num =
            |b: &scene::Bound, d: f32| floats(&b.get(&self.props)).first().copied().unwrap_or(d);
        layer
            .animations
            .iter()
            .filter(|a| a.visible.truthy(&self.props))
            .filter_map(|a| {
                let found = model
                    .animations
                    .iter()
                    .position(|anim| anim.id as i64 == a.id)?;
                Some((
                    found,
                    num(&a.rate, 1.0),
                    num(&a.blend, 1.0).clamp(0.0, 1.0),
                    a.additive,
                ))
            })
            .collect()
    }

    fn puppet_mesh(&mut self, index: usize, layer: &PuppetLayer) -> Result<PuppetGpu, Error> {
        let data = self
            .vfs
            .read(&layer.model)
            .ok_or_else(|| Error::Missing(layer.model.clone()))?;
        let model = Rc::new(puppet::Puppet::parse(&data)?);
        let bind: Vec<_> = model
            .bones
            .iter()
            .map(|b| mat::decompose(&b.local))
            .collect();
        // Bind-pose world matrices, then their inverses for the skinning transform.
        let mut world = vec![mat::IDENTITY; model.bones.len()];
        for (i, bone) in model.bones.iter().enumerate() {
            world[i] = match bone.parent {
                Some(p) if p < i => mat::mul(&bone.local, &world[p]),
                _ => bone.local,
            };
        }
        let bind_inverse = world.iter().map(mat::invert).collect();
        let animations = self.puppet_animations(&model, layer);
        let (texture_name, blend) = self
            .scene
            .layers
            .get(index)
            .and_then(|l| l.material.as_ref())
            .map(|m| (m.textures.first().cloned().flatten(), m.blend))
            .unwrap_or((None, Blend::Translucent));
        let texture = texture_name.and_then(|name| self.texture(&name));
        let indices_ptr = NonNull::new(model.indices.as_ptr() as *mut c_void)
            .ok_or_else(|| Error::Format("puppet has no indices".into()))?;
        // SAFETY: the buffer copies `indices.len()` u16 values immediately.
        let indices = unsafe {
            self.gpu
                .device
                .newBufferWithBytes_length_options(
                    indices_ptr,
                    model.indices.len() * 2,
                    MTLResourceOptions::StorageModeShared,
                )
                .ok_or_else(|| Error::Metal("puppet index buffer".into()))?
        };
        Ok(PuppetGpu {
            layer: index,
            model,
            bind,
            bind_inverse,
            animations,
            indices,
            texture,
            blend,
        })
    }

    /// Draws one puppet: sample its animation layers, walk the skeleton and skin on the CPU.
    fn draw_puppet(
        &mut self,
        enc: &gpu::Encoder,
        index: usize,
        ctx: &DrawCtx,
        input: FrameInput,
        samples: usize,
    ) -> Result<(), Error> {
        let Some(pi) = self.puppets.iter().position(|p| p.layer == index) else {
            return Ok(());
        };
        let (model, texture, blend, indices) = {
            let p = &self.puppets[pi];
            (
                p.model.clone(),
                p.texture.clone(),
                p.blend,
                p.indices.clone(),
            )
        };
        let bones = self.puppets[pi].bones_at(input.time);
        let mut verts = Vec::with_capacity(model.vertices.len() * 8);
        for v in &model.vertices {
            let mut pos = [0.0f32; 3];
            for k in 0..4 {
                let w = v.bone_weights[k];
                if w <= 0.0 {
                    continue;
                }
                let skin = bones
                    .get(v.bone_indices[k] as usize)
                    .copied()
                    .unwrap_or(mat::IDENTITY);
                let q = mat::point(&skin, v.position);
                pos[0] += q[0] * w;
                pos[1] += q[1] * w;
                pos[2] += q[2] * w;
            }
            // Model-space position; `ctx.mvp` carries the layer transform.
            for f in [
                pos[0],
                pos[1],
                v.uv[0],
                v.uv[1],
                ctx.color[0],
                ctx.color[1],
                ctx.color[2],
                ctx.alpha,
            ] {
                verts.extend_from_slice(&f.to_le_bytes());
            }
        }
        if verts.is_empty() || model.indices.is_empty() {
            return Ok(());
        }
        let pipeline = self.gpu.particle_pipeline(blend, TARGET_FORMAT, samples)?;
        enc.setRenderPipelineState(&pipeline);
        let uniform: Vec<u8> = ctx.mvp.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &uniform, 0);
        let ptr = NonNull::new(verts.as_ptr() as *mut c_void)
            .ok_or_else(|| Error::Format("puppet vertex buffer".into()))?;
        // SAFETY: the buffer copies `verts` immediately and outlives the draw.
        let vb = unsafe {
            self.gpu.device.newBufferWithBytes_length_options(
                ptr,
                verts.len(),
                MTLResourceOptions::StorageModeShared,
            )
        }
        .ok_or_else(|| Error::Metal("puppet vertex buffer".into()))?;
        // SAFETY: the vertex buffer holds 32-byte vertices and lives past the draw.
        unsafe {
            enc.setVertexBuffer_offset_atIndex(Some(&vb), 0, shader::VERTEX_BUFFER_SLOT as usize)
        };
        let (tex, sampler) = match &texture {
            Some(t) => (&t.images[0], t.sampler),
            None => (&self.white.images[0], 0),
        };
        // SAFETY: slot 0 exists in the particle shader; the index buffer and texture outlive the
        // draw.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(tex), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
            enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                MTLPrimitiveType::Triangle,
                model.indices.len(),
                MTLIndexType::UInt16,
                &indices,
                0,
            );
        }
        Ok(())
    }

    /// Loads a particle layer's system, its instance overrides and the texture it draws with.
    fn particle_system(
        &mut self,
        index: usize,
        layer: &ParticleLayer,
    ) -> Result<ParticleGpu, Error> {
        let json = self.vfs.json(&layer.system)?;
        let system = particles::ParticleSystem::from_json(&json)?;
        // A fixed seed per layer keeps a frozen frame, and the golden harness, reproducible.
        let seed = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(index as u64 + 1);
        let mut sim = particles::Simulation::new(&system, seed);
        if let Some(overrides) = &layer.instance_override {
            let overrides = scene::resolve_user_values(overrides, &self.props);
            if let Some(o) = particles::InstanceOverride::from_json(&overrides) {
                sim.apply_override(&o);
            }
        }
        let material = Material::load(&self.vfs, &system.material)?;
        let texture = material
            .textures
            .first()
            .and_then(|t| t.as_deref())
            .and_then(|t| self.texture(t));
        let scene_layer = &self.scene.layers[index];
        let mut color = [1.0f32; 3];
        for (o, v) in color
            .iter_mut()
            .zip(floats(&scene_layer.color.get(&self.props)))
        {
            *o = v * scene_layer.brightness;
        }
        Ok(ParticleGpu {
            layer: index,
            sim,
            texture,
            blend: material.blend,
            world: self.world(index, 0),
            color,
            alpha: floats(&scene_layer.alpha.get(&self.props))
                .first()
                .copied()
                .unwrap_or(1.0),
        })
    }

    /// Draws one particle layer: simulate to `input.time`, build six vertices per particle and
    /// issue a single triangle list draw.
    fn draw_particles(
        &mut self,
        enc: &gpu::Encoder,
        index: usize,
        view_projection: &Mat4,
        input: FrameInput,
        pointer: [f32; 2],
    ) -> Result<(), Error> {
        let (blend, texture, verts) = {
            let Some(p) = self.particles.get_mut(index) else {
                return Ok(());
            };
            // `pointer` is in design units (y down); control points live in the system's own
            // space (y up), which `world` maps to design units with the y flip.
            let inv = invert_affine_2d(&p.world);
            let lx = inv[0] * pointer[0] + inv[4] * pointer[1] + inv[12];
            let ly = inv[1] * pointer[0] + inv[5] * pointer[1] + inv[13];
            p.sim.set_pointer(lx, -ly);
            p.sim.seek_to(input.time);
            let world = p.world;
            let (cr, cg, cb) = (p.color[0], p.color[1], p.color[2]);
            let ca = p.alpha;
            // A sprite sheet's frames: each particle shows one, picked by the animation mode.
            let sheet = p.texture.as_ref().filter(|t| !t.frames.is_empty());
            let system = p.sim.system();
            let mode = system.animation_mode.as_deref().unwrap_or("");
            let speed = system.sequence_multiplier;
            let mut verts = Vec::with_capacity(p.sim.alive_count() * 6 * 8);
            for q in p.sim.alive_particles() {
                let half = (q.size * 0.5).max(0.0);
                let alpha = q.alpha * ca;
                if half <= 0.0 || alpha <= 0.0 {
                    continue;
                }
                // Simulation space is y up; the render space is y down, so the centre and the
                // rotation are mirrored while the sprite itself stays upright.
                let (s, c) = (-q.rotation.z).sin_cos();
                let (x, y) = (q.position.x, -q.position.y);
                let corners = [
                    (-half, -half, 0.0f32, 0.0f32),
                    (half, -half, 1.0, 0.0),
                    (-half, half, 0.0, 1.0),
                    (half, -half, 1.0, 0.0),
                    (half, half, 1.0, 1.0),
                    (-half, half, 0.0, 1.0),
                ];
                let frame = sheet.map(|t| {
                    let n = t.frames.len();
                    let i = match mode {
                        "randomframe" => (q.seed % n as u64) as usize,
                        // shortcut: plays the sheet once per lifetime times the multiplier; check
                        // against a scene that uses "sequence" when one turns up.
                        "sequence" => {
                            let life = (q.age / q.lifetime.max(1e-3)) * speed.max(0.0);
                            ((life * n as f32) as usize) % n
                        }
                        _ => 0,
                    };
                    (t.frames[i], t.res)
                });
                for (dx, dy, u, v) in corners {
                    let (u, v) = match frame {
                        Some((f, res)) => (
                            (f.x + u * f.width_x + v * f.height_x) / res[0].max(1.0),
                            (f.y + u * f.width_y + v * f.height_y) / res[1].max(1.0),
                        ),
                        None => (u, v),
                    };
                    let lx = x + dx * c - dy * s;
                    let ly = y + dx * s + dy * c;
                    let wx = world[0] * lx + world[4] * ly + world[12];
                    let wy = world[1] * lx + world[5] * ly + world[13];
                    for f in [
                        wx,
                        wy,
                        u,
                        v,
                        q.color.x * cr,
                        q.color.y * cg,
                        q.color.z * cb,
                        alpha,
                    ] {
                        verts.extend_from_slice(&f.to_le_bytes());
                    }
                }
            }
            (p.blend, p.texture.clone(), verts)
        };
        if verts.is_empty() {
            return Ok(());
        }
        let pipeline = self
            .gpu
            .particle_pipeline(blend, TARGET_FORMAT, self.samples)?;
        enc.setRenderPipelineState(&pipeline);
        let uniform: Vec<u8> = view_projection
            .iter()
            .flat_map(|f| f.to_le_bytes())
            .collect();
        gpu::set_bytes(enc, true, &uniform, 0);
        gpu::set_buffer_or_bytes(
            &self.gpu,
            enc,
            true,
            &verts,
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        let (tex, sampler) = match &texture {
            Some(t) => (&t.images[0], t.sampler),
            None => (&self.white.images[0], 0),
        };
        // SAFETY: slot 0 exists in the particle shader; resources outlive the frame.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(tex), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(
                MTLPrimitiveType::Triangle,
                0,
                verts.len() / 32,
            );
        }
        Ok(())
    }

    /// Text bitmaps arrive premultiplied; the blend state multiplies by alpha, so divide it out.
    fn upload_bitmap(&self, bitmap: &text::TextBitmap) -> Result<Retained<Texture>, Error> {
        let (w, h) = (bitmap.width as usize, bitmap.height as usize);
        let mut data = bitmap.pixels.clone();
        for p in data.as_chunks_mut::<4>().0 {
            let a = p[3] as u32;
            if a > 0 && a < 255 {
                for c in &mut p[..3] {
                    *c = (((*c as u32) * 255 + a / 2) / a).min(255) as u8;
                }
            }
        }
        let tex = crate::tex::Tex {
            texture_width: w,
            texture_height: h,
            image_width: w,
            image_height: h,
            format: crate::tex::Format::Rgba8,
            clamp: true,
            nearest: false,
            images: vec![vec![crate::tex::Mip {
                width: w,
                height: h,
                data,
            }]],
            frames: Vec::new(),
            video: None,
        };
        self.gpu.upload(&tex, 0, false)
    }

    /// A texture drawn as a picture: layer images, sprites, slot 0 of a material.
    fn texture(&mut self, name: &str) -> Option<Rc<TexEntry>> {
        self.texture_as(name, true)
    }

    /// `color` decides how one- and two-channel files read; see `Gpu::upload`.
    fn texture_as(&mut self, name: &str, color: bool) -> Option<Rc<TexEntry>> {
        let key = if color {
            name.to_string()
        } else {
            format!("{name}#raw")
        };
        if let Some(t) = self.textures.get(&key) {
            return Some(t.clone());
        }
        let loaded = (|| -> Result<TexEntry, Error> {
            let path = format!("materials/{name}.tex");
            let data = self.vfs.read(&path).ok_or(Error::Missing(path))?;
            let tex = crate::tex::decode(&data)?;
            if let Some(movie) = &tex.video {
                let player = crate::video::Player::new(movie)?;
                let texture = self.gpu.video_texture(player.size.0, player.size.1)?;
                self.gpu.clear_texture(&texture);
                return Ok(TexEntry {
                    images: vec![texture],
                    res: [
                        player.size.0 as f32,
                        player.size.1 as f32,
                        player.size.0 as f32,
                        player.size.1 as f32,
                    ],
                    frames: Vec::new(),
                    sampler: usize::from(!tex.clamp) + 2 * usize::from(tex.nearest),
                    video: Some(player),
                });
            }
            let images = (0..tex.images.len())
                .map(|i| self.gpu.upload(&tex, i, color))
                .collect::<Result<Vec<_>, _>>()?;
            let sampler = usize::from(!tex.clamp) + 2 * usize::from(tex.nearest);
            Ok(TexEntry {
                images,
                res: [
                    tex.texture_width as f32,
                    tex.texture_height as f32,
                    tex.image_width as f32,
                    tex.image_height as f32,
                ],
                frames: tex.frames,
                sampler,
                video: None,
            })
        })();
        match loaded {
            Ok(entry) => {
                let entry = Rc::new(entry);
                let _ = self.textures.insert(key, entry.clone());
                Some(entry)
            }
            Err(e) => {
                self.warnings.push(format!("texture {name}: {e}"));
                None
            }
        }
    }

    fn program(
        &mut self,
        shader_name: &str,
        combos: &BTreeMap<String, i64>,
    ) -> Result<(Rc<Program>, Rc<shader::Source>), Error> {
        let source = match self.sources.get(shader_name) {
            Some(s) => s.clone(),
            None => {
                let s = Rc::new(shader::Source::load(&self.vfs, shader_name)?);
                let _ = self.sources.insert(shader_name.to_string(), s.clone());
                s
            }
        };
        let key = (shader_name.to_string(), combos.clone());
        if let Some(p) = self.programs.get(&key) {
            return Ok((p.clone(), source));
        }
        let program = Rc::new(source.compile(combos)?);
        let _ = self.programs.insert(key, program.clone());
        Ok((program, source))
    }

    fn draw_item(
        &mut self,
        material: &Material,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        binds: &[(String, usize)],
        effect: bool,
    ) -> Result<DrawItem, Error> {
        // Texture sources per g_TextureN index.
        let mut sources: BTreeMap<usize, TexSource> = BTreeMap::new();
        if effect {
            let _ = sources.insert(0, TexSource::Target("previous".into()));
        }
        for (i, name) in material.textures.iter().enumerate() {
            if let Some(name) = name {
                if name.starts_with("_rt_") {
                    let _ = sources.insert(i, TexSource::Target(name.clone()));
                } else if let Some(t) = self.texture_as(name, i == 0) {
                    let _ = sources.insert(i, TexSource::Image(t));
                }
            }
        }
        for (name, slot) in binds {
            let _ = sources.insert(*slot, TexSource::Target(name.clone()));
        }

        let shader_name = material.shader.clone();
        let source = match self.sources.get(&shader_name) {
            Some(s) => s.clone(),
            None => {
                let s = Rc::new(shader::Source::load(&self.vfs, &shader_name)?);
                let _ = self.sources.insert(shader_name.clone(), s.clone());
                s
            }
        };
        let mut combos = material.combos.clone();
        for (index, meta) in &source.texture_meta {
            if let Some(combo) = meta["combo"].as_str() {
                if sources.contains_key(index) {
                    let _ = combos.insert(combo.to_string(), 1);
                }
            }
        }
        if let Some(TexSource::Image(t)) = sources.get(&0) {
            if !t.frames.is_empty() {
                let _ = combos.insert("SPRITESHEET".into(), 1);
            }
        }
        let (program, _) = self.program(&shader_name, &combos)?;

        // Shader-declared textures with nothing bound get their annotated default.
        let mut textures = Vec::new();
        for &(index, slot) in program
            .vertex
            .textures
            .iter()
            .chain(&program.fragment.textures)
        {
            let src = match sources.get(&index) {
                Some(s) => s.clone(),
                None => {
                    let default = source
                        .texture_meta
                        .get(&index)
                        .and_then(|m| m["default"].as_str())
                        .unwrap_or("");
                    if default.starts_with("_rt_") {
                        TexSource::Target(default.to_string())
                    } else if default.is_empty() {
                        TexSource::Image(self.white.clone())
                    } else {
                        TexSource::Image(
                            self.texture_as(default, index == 0)
                                .unwrap_or_else(|| self.black.clone()),
                        )
                    }
                }
            };
            textures.push((slot, index, src));
        }

        let pkey = (
            Rc::as_ptr(&program) as usize,
            blend,
            samples * 1000 + format.0,
        );
        let pipeline = match self.pipelines.get(&pkey) {
            Some(p) => p.clone(),
            None => {
                let p = self.gpu.pipeline(&program, blend, format, samples)?;
                let _ = self.pipelines.insert(pkey, p.clone());
                p
            }
        };

        let mut dynamic = Vec::new();
        let mut stage_bytes = |code: &shader::StageCode, vertex: bool| -> Vec<u8> {
            let mut bytes = vec![0u8; code.ubo_size as usize];
            for u in &code.uniforms {
                if let Some(d) = engine_uniform(&u.name) {
                    dynamic.push((vertex, u.clone(), d));
                    continue;
                }
                let meta = program.uniform_meta.get(&u.name);
                let key = meta.and_then(|m| m["material"].as_str());
                let constant = key.and_then(|k| {
                    material
                        .constants
                        .iter()
                        .find(|(c, _)| c.eq_ignore_ascii_case(k))
                        .map(|(_, v)| v.get(&self.props))
                });
                let value = constant
                    .or_else(|| meta.map(|m| m["default"].clone()))
                    .unwrap_or(Value::Null);
                let mut f = floats(&value);
                // Angles in the editor are degrees for `direction` sliders only when flagged; the
                // files already store radians, so values pass through unchanged.
                if f.is_empty() && u.name == "g_Brightness" {
                    f = vec![1.0];
                }
                write_uniform(&mut bytes, u, &f);
            }
            bytes
        };
        let vs = stage_bytes(&program.vertex, true);
        let fs = stage_bytes(&program.fragment, false);
        let reads_frame = textures
            .iter()
            .any(|(_, _, s)| matches!(s, TexSource::Target(n) if n == "_rt_FullFrameBuffer"));
        Ok(DrawItem {
            pipeline,
            textures,
            vs,
            fs,
            dynamic,
            reads_frame,
        })
    }

    /// Everything about a layer's placement that only properties can change, computed once per
    /// rebuild instead of re-parsing the scene values every frame.
    fn place(&self, index: usize, layer: &Layer, image: Option<&TexEntry>) -> Option<Placed> {
        let size = match (layer.size, image) {
            ([w, h], _) if w > 0.0 && h > 0.0 => [w, h],
            (_, Some(t)) => [t.res[2], t.res[3]],
            _ => return None,
        };
        let mut color = [1.0f32; 3];
        for (o, v) in color.iter_mut().zip(floats(&layer.color.get(&self.props))) {
            *o = v * layer.brightness;
        }
        Some(Placed {
            world: self.world(index, 0),
            size,
            color,
            alpha: floats(&layer.alpha.get(&self.props))
                .first()
                .copied()
                .unwrap_or(1.0),
            compose: layer
                .material
                .as_ref()
                .is_some_and(|m| m.shader == "composelayer"),
        })
    }

    /// Re-places layers that move every frame: those hanging off a puppet attachment (the bones
    /// move) and, with camera parallax, all of them (the pointer moves).
    fn follow_motion(&mut self, input: FrameInput) {
        self.pose_time = input.time;
        let now = self.parallax_now();
        self.parallax_shift = match now {
            Some(p) => camera_shift(&p, input.parallax, self.scene.width),
            None => [0.0; 2],
        };
        let all = now.is_some();
        self.shake_offset = match self.scene.shake.now(&self.props) {
            Some(shake) => camera_shake(shake, input.time, [self.scene.width, self.scene.height]),
            None => [0.0; 2],
        };
        for i in 0..self.layers.len().min(self.scene.layers.len()) {
            if self.layers[i].placed.is_none() || !(all || self.attached(i)) {
                continue;
            }
            let world = self.world(i, 0);
            if let Some(p) = &mut self.layers[i].placed {
                p.world = world;
            }
        }
        for i in 0..self.particles.len() {
            let layer = self.particles[i].layer;
            if all || self.attached(layer) {
                self.particles[i].world = self.world(layer, 0);
            }
        }
    }

    /// Camera parallax with the user's properties applied; `None` while it is off.
    pub fn parallax_now(&self) -> Option<scene::ParallaxNow> {
        self.scene.parallax.now(&self.props)
    }

    /// How far, in design units, a layer may move with the pointer: the band the parallax zoom
    /// hides at each edge. Fill zooms in to hide it; the modes that show the whole scene do not
    /// (a zoom would cut it), so a layer moved that far can show the clear colour at an edge.
    fn parallax_margin(&self) -> [f32; 2] {
        let hidden = (1.0 - 1.0 / PARALLAX_ZOOM) / 2.0;
        [self.scene.width * hidden, self.scene.height * hidden]
    }

    fn parallax_zoom(&self) -> f32 {
        if self.parallax_now().is_some() && self.fit == FitMode::Fill {
            PARALLAX_ZOOM
        } else {
            1.0
        }
    }

    /// The layer or one of its parents follows a puppet attachment.
    fn attached(&self, index: usize) -> bool {
        let mut layer = self.scene.layers.get(index);
        for _ in 0..32 {
            let Some(l) = layer else { return false };
            if l.attachment.is_some() {
                return true;
            }
            layer = l
                .parent
                .and_then(|p| self.scene.layers.iter().find(|x| x.id == p));
        }
        false
    }

    /// Layer world matrix including parents and camera parallax, in design pixels (y down).
    fn world(&self, index: usize, depth: u32) -> Mat4 {
        let layer = &self.scene.layers[index];
        let o = floats(&layer.origin.get(&self.props));
        let s = floats(&layer.scale.get(&self.props));
        let a = floats(&layer.angles.get(&self.props));
        let get = |v: &[f32], i: usize, d: f32| v.get(i).copied().unwrap_or(d);
        let parent = layer
            .parent
            .and_then(|p| self.scene.layers.iter().position(|l| l.id == p));
        // The file is y up from the design's bottom-left (a child's origin is an offset from its
        // parent, also y up); the renderer works y down from the top-left, like Metal textures.
        let y = get(&o, 1, 0.0);
        let y = if parent.is_some() {
            -y
        } else {
            self.scene.height - y
        };
        let local = mul(
            &mul(
                &translate(get(&o, 0, 0.0), y, 0.0),
                &rotate_z(-get(&a, 2, 0.0)),
            ),
            &scale(get(&s, 0, 1.0), get(&s, 1, 1.0), 1.0),
        );
        // A layer attached to a puppet follows the attachment point as the bones move.
        let attached = parent
            .zip(layer.attachment.as_deref())
            .and_then(|(p, name)| {
                let puppet = self.puppets.iter().find(|g| g.layer == p)?;
                puppet.attachment_at(name, self.pose_time)
            });
        let local = match attached {
            Some(a) => mul(&a, &local),
            None => local,
        };
        let world = match parent {
            Some(p) if depth < 32 => mul(&self.world(p, depth + 1), &local),
            _ => local,
        };
        // Applied after the parent, in design units: a child moves with its parent's shift plus
        // its own, and a parent's scale does not stretch it.
        let depth = floats(&layer.parallax_depth.get(&self.props));
        let depth = [
            depth.first().copied().unwrap_or(0.0),
            depth.get(1).copied().unwrap_or(0.0),
        ];
        let [dx, dy] = parallax_offset(depth, self.parallax_shift, self.parallax_margin());
        if dx == 0.0 && dy == 0.0 {
            return world;
        }
        mul(&translate(dx, dy, 0.0), &world)
    }

    /// Whether the layer is text whose string a script sets, so it changes between frames.
    fn has_scripted_text(&self, index: usize) -> bool {
        let Some(layer) = self.scene.layers.get(index) else {
            return false;
        };
        layer.text.is_some()
            && self
                .scene
                .scripts
                .iter()
                .any(|s| s.layer_id == layer.id && s.field.starts_with("text"))
    }

    fn visible(&self, index: usize) -> bool {
        if self.hide_scripted_text && self.has_scripted_text(index) {
            return false;
        }
        let mut layer: Option<&Layer> = self.scene.layers.get(index);
        let mut depth = 0;
        while let Some(l) = layer {
            if !l.visible.truthy(&self.props) || depth > 32 {
                return false;
            }
            layer = l
                .parent
                .and_then(|p| self.scene.layers.iter().find(|x| x.id == p));
            depth += 1;
        }
        true
    }

    /// The part of the design that is on screen, in design units: left, right, top, bottom.
    /// The fit mode decides how much of the design is visible, zoom narrows it further and pan
    /// moves it.
    fn view_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        let (w, h) = (self.scene.width, self.scene.height);
        let (vw, vh) = match self.fit {
            // Cover the target: the smaller axis of the design fits exactly.
            FitMode::Fill => {
                let s = (tw / w).max(th / h);
                (tw / s, th / s)
            }
            // Show all of it: the larger axis of the design fits exactly.
            FitMode::Fit | FitMode::MatchBlurred => {
                let s = (tw / w).min(th / h);
                (tw / s, th / s)
            }
            // The design is mapped onto the target as it is.
            FitMode::Stretch => (w, h),
            // One design pixel per target pixel.
            FitMode::Unscaled => (tw, th),
        };
        let z = self.zoom.max(0.05) * self.parallax_zoom();
        let (vw, vh) = (vw / z, vh / z);
        let cx = w / 2.0 - self.pan[0] * vw + self.shake_offset[0];
        let cy = h / 2.0 - self.pan[1] * vh + self.shake_offset[1];
        (cx - vw / 2.0, cx + vw / 2.0, cy - vh / 2.0, cy + vh / 2.0)
    }

    /// The rectangle the design itself covers on the target, in target pixels: x, y, width,
    /// height. Used by the blurred-fit mode, where the rest of the target is filled with a
    /// blurred copy of the same picture.
    fn content_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        let (w, h) = (self.scene.width, self.scene.height);
        let s = (tw / w).min(th / h) * self.zoom.max(0.05) * self.parallax_zoom();
        let (cw, ch) = (w * s, h * s);
        let x = tw / 2.0 + self.pan[0] * tw - cw / 2.0;
        let y = th / 2.0 + self.pan[1] * th - ch / 2.0;
        (x, y, cw, ch)
    }

    /// Renders one frame into `target` (a drawable or offscreen texture) on `cb`.
    pub fn encode(
        &mut self,
        cb: &gpu::CommandBuffer,
        target: &Texture,
        input: FrameInput,
    ) -> Result<(), Error> {
        let (tw, th) = (target.width() as f32, target.height() as f32);
        self.run_scripts(input, [tw, th]);
        self.follow_motion(input);
        self.step_videos(input.time, false);
        if self.samples > 1
            && self
                .msaa
                .as_ref()
                .is_none_or(|m| m.width() != target.width() || m.height() != target.height())
        {
            self.msaa = Some(self.gpu.render_target(
                target.width(),
                target.height(),
                TARGET_FORMAT,
                self.samples,
            )?);
        }
        let msaa = self.msaa.clone();

        // The visible part of the design, in design units. Files are y-down from the design's
        // top-left, which is also Metal's texture orientation.
        let (l, r, t, b) = self.view_rect(tw, th);
        let view_projection = ortho(l, r, b, t);
        // Screen pixels per design pixel.
        let fit = tw / (r - l).max(0.001);

        let mut c = [0.0f32; 3];
        for (o, v) in c
            .iter_mut()
            .zip(floats(&self.scene.clear_color.get(&self.props)))
        {
            *o = v;
        }
        // The blurred-fit mode draws the scene into a texture first: the empty part of the
        // target is then filled with a blurred copy of the same picture.
        let blurred =
            self.fit == FitMode::MatchBlurred && leaves_gaps(self.content_rect(tw, th), tw, th);
        let bloom = self.scene.bloom.enabled.truthy(&self.props);
        let scene_tex = if blurred || bloom {
            Some(self.pool.take(&self.gpu, target.width(), target.height())?)
        } else {
            None
        };
        let scene_target: &Texture = scene_tex.as_ref().map_or(target, |t| &**t);
        let mut main = Some(gpu::begin(
            cb,
            scene_target,
            msaa.as_deref(),
            Some([c[0] as f64, c[1] as f64, c[2] as f64, 1.0]),
        )?);
        let screen = [tw, th];
        // Screen copy for `_rt_FullFrameBuffer` readers, refreshed before each such draw.
        let mut frame_copy: HashMap<String, Retained<Texture>> = HashMap::new();
        // Effect outputs other layers sample, by `_rt_imageLayerComposite_<id>_a` name. Those
        // layers run their chain first, off screen; hidden ones never reach the screen.
        let mut composites: HashMap<String, Retained<Texture>> = HashMap::new();
        let order: Vec<(usize, Option<String>)> = self
            .composite_refs
            .iter()
            .map(|(i, name)| (*i, Some(name.clone())))
            .chain((0..self.layers.len()).map(|i| (i, None)))
            .collect();

        for (li, composite) in order {
            if composite.is_none() && !self.layers[li].shown {
                continue;
            }
            // Particle layers have no image draw of their own; draw their systems in layer order.
            for pi in 0..self.particles.len() {
                if composite.is_some() {
                    break;
                }
                if self.particles[pi].layer != li {
                    continue;
                }
                let enc = main
                    .as_ref()
                    .ok_or_else(|| Error::Metal("main pass".into()))?;
                let vp = view_projection;
                let pointer = [
                    l + input.pointer[0] * (r - l),
                    t + input.pointer[1] * (b - t),
                ];
                self.draw_particles(enc, pi, &vp, input, pointer)?;
            }
            let Some(Placed {
                world,
                size,
                color,
                alpha,
                compose,
            }) = self.layers[li].placed
            else {
                continue;
            };
            if self.layers[li].base.is_none() && self.layers[li].image.is_none() {
                continue;
            }
            let image = self.layers[li].image.clone();
            let is_puppet = self.layers[li].puppet;
            let model = match self.layers[li].text_rect {
                Some([x, y, w, h]) => {
                    // The quad is centred on the model origin, and the layer box is centred on
                    // the layer origin; `rect` is measured from the box's top-left corner.
                    let ox = x - size[0] / 2.0 + w / 2.0;
                    let oy = y - size[1] / 2.0 + h / 2.0;
                    mul(
                        &mul(&world, &translate(ox, oy, 0.0)),
                        &scale(w.max(0.001), h.max(0.001), 1.0),
                    )
                }
                None => mul(&world, &scale(size[0], size[1], 1.0)),
            };
            // Screen pixels per layer pixel. Effects never need more detail than the screen shows.
            let on_screen = fit * world_scale(&world);
            if self.layers[li].text_rect.is_some()
                && self.text_scale > 0.0
                && !(0.75..=1.34).contains(&(on_screen / self.text_scale))
            {
                self.text_dirty = true;
            }
            let ctx = DrawCtx {
                mvp: mul(&view_projection, &model),
                model,
                view_projection,
                target: screen,
                color,
                alpha,
                buffer_scale: [1.0, 1.0],
                screen_mvp: mul(&view_projection, &model),
                size,
            };
            // Nothing of the layer reaches the target: its effects and draw would be wasted.
            if !is_puppet && off_target(&ctx.mvp) {
                continue;
            }
            let uv = image.as_ref().map_or([1.0, 1.0], |t| {
                [t.res[2] / t.res[0].max(1.0), t.res[3] / t.res[1].max(1.0)]
            });
            let visible_effects: Vec<usize> = (0..self.layers[li].effects.len()).collect();

            if visible_effects.is_empty() || self.layers[li].base_fx.is_none() {
                // A sampled layer without effects offers its plain image.
                if let (Some(name), Some(t)) = (composite.as_ref(), image.as_ref()) {
                    let k = axis_scale(&world).map(|s| (fit * s).clamp(0.05, 1.0));
                    let (fw, fh) = (
                        (size[0] * k[0]).round().max(1.0) as usize,
                        (size[1] * k[1]).round().max(1.0) as usize,
                    );
                    if let Some(enc) = main.take() {
                        enc.endEncoding();
                    }
                    let out = self.pool.take(&self.gpu, fw, fh)?;
                    let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
                    let rect = [0.0, 0.0, uv[0], uv[1]];
                    self.composite_rect(
                        &enc,
                        &t.images[0],
                        t.sampler,
                        Blend::Disabled,
                        1,
                        FBO_MVP,
                        rect,
                        [1.0; 3],
                        1.0,
                    )?;
                    enc.endEncoding();
                    let _ = frame_copy.insert(name.clone(), out.clone());
                    let _ = composites.insert(name.clone(), out);
                    main = Some(gpu::begin(cb, scene_target, msaa.as_deref(), None)?);
                    continue;
                }
                // A compose layer without effects would redraw what is already behind it.
                if compose || composite.is_some() {
                    continue;
                }
                if self.layers[li].base.as_ref().is_some_and(|b| b.reads_frame) {
                    main = Some(self.copy_frame(
                        cb,
                        main.take(),
                        scene_target,
                        msaa.as_deref(),
                        &mut frame_copy,
                    )?);
                }
                let enc = main
                    .as_ref()
                    .ok_or_else(|| Error::Metal("main pass".into()))?;
                match &self.layers[li].base {
                    _ if is_puppet => {
                        // Puppet vertices are in design units, y up: the layer transform without the
                        // box scale, flipped into the y-down design space.
                        let flip = mul(&world, &scale(1.0, -1.0, 1.0));
                        let pctx = DrawCtx {
                            mvp: mul(&view_projection, &flip),
                            ..ctx
                        };
                        self.draw_puppet(enc, li, &pctx, input, self.samples)?;
                    }
                    Some(item) if visible_effects.is_empty() => {
                        self.draw(enc, item, &ctx, uv, input, None, &frame_copy, None);
                        // Copied again by the next reader, so it need not stay alive meanwhile.
                        if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                            self.pool.give(t);
                        }
                    }
                    _ => {
                        if let Some(t) = &image {
                            self.composite(
                                enc,
                                &t.images[0],
                                t.sampler,
                                self.layers[li].blend,
                                &ctx,
                                uv,
                            )?;
                        }
                    }
                }
                continue;
            }

            // Per axis, so a layer stretched in one direction gets a buffer of its screen shape.
            let k = axis_scale(&world).map(|s| (fit * s).clamp(0.05, 1.0));
            let (fw, fh) = (
                (size[0] * k[0]).round().max(1.0) as usize,
                (size[1] * k[1]).round().max(1.0) as usize,
            );
            if let Some(cached) = self.layers[li]
                .cached
                .clone()
                .filter(|c| composite.is_none() && c.width() == fw && c.height() == fh)
            {
                let enc = main
                    .as_ref()
                    .ok_or_else(|| Error::Metal("main pass".into()))?;
                self.composite(enc, &cached, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?;
                continue;
            }

            // Effects: base -> A, each pass A -> B (or a named buffer), swap; then composite A.
            if self.layers[li]
                .base_fx
                .as_ref()
                .is_some_and(|b| b.reads_frame)
            {
                main = Some(self.copy_frame(
                    cb,
                    main.take(),
                    scene_target,
                    msaa.as_deref(),
                    &mut frame_copy,
                )?);
            }
            if let Some(enc) = main.take() {
                enc.endEncoding();
            }
            let mut prev = self.pool.take(&self.gpu, fw, fh)?;
            // Effects only need to run where the layer can show, plus a margin for effects that
            // sample a little way off; a cached layer keeps all of it, the view may change later.
            let clip = if is_puppet || self.layers[li].still {
                [0.0, 0.0, 1.0, 1.0]
            } else {
                visible_uv(&ctx.mvp, 1.25)
            };
            let fbo_ctx = DrawCtx {
                mvp: FBO_MVP,
                model: IDENTITY,
                view_projection: IDENTITY,
                target: size,
                color,
                alpha: 1.0,
                buffer_scale: k,
                ..ctx
            };
            {
                let enc = gpu::begin(cb, &prev, None, Some([0.0; 4]))?;
                scissor(&enc, &prev, clip);
                if is_puppet {
                    // The buffer spans the layer box, so map design units (y up) onto the unit quad (y down).
                    let inv = scale(1.0 / size[0].max(1.0), -1.0 / size[1].max(1.0), 1.0);
                    let pctx = DrawCtx {
                        mvp: mul(&FBO_MVP, &inv),
                        color: [1.0; 3],
                        alpha: 1.0,
                        ..ctx
                    };
                    self.draw_puppet(&enc, li, &pctx, input, 1)?;
                } else if let Some(item) = &self.layers[li].base_fx {
                    // A compose layer samples the screen behind it, so it keeps its real placement.
                    let base_ctx = if compose {
                        DrawCtx {
                            color: [1.0; 3],
                            ..ctx
                        }
                    } else {
                        DrawCtx {
                            color: [1.0; 3],
                            ..fbo_ctx
                        }
                    };
                    self.draw(&enc, item, &base_ctx, uv, input, None, &frame_copy, None);
                }
                enc.endEncoding();
            }
            if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                self.pool.give(t);
            }
            for &ei in &visible_effects {
                let effect = &self.layers[li].effects[ei];
                let mut named = frame_copy.clone();
                for (name, div) in &effect.fbos {
                    let (w, h) = (
                        ((fw as f32) / div).max(1.0) as usize,
                        ((fh as f32) / div).max(1.0) as usize,
                    );
                    let _ = named.insert(name.clone(), self.pool.take(&self.gpu, w, h)?);
                }
                for pass in &effect.passes {
                    let out = match &pass.target {
                        Some(name) => named
                            .get(name)
                            .cloned()
                            .ok_or_else(|| Error::Format(format!("unknown buffer {name}")))?,
                        None => self.pool.take(&self.gpu, fw, fh)?,
                    };
                    let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
                    scissor(&enc, &out, clip);
                    let pctx = DrawCtx {
                        target: [out.width() as f32 / k[0], out.height() as f32 / k[1]],
                        ..fbo_ctx
                    };
                    self.draw(
                        &enc,
                        &pass.item,
                        &pctx,
                        [1.0, 1.0],
                        input,
                        Some(&prev),
                        &named,
                        None,
                    );
                    enc.endEncoding();
                    if pass.target.is_none() {
                        self.pool.give(std::mem::replace(&mut prev, out));
                    }
                }
                for (name, _) in &effect.fbos {
                    if let Some(t) = named.remove(name) {
                        self.pool.give(t);
                    }
                }
            }
            if self.layers[li].still {
                // Keep a copy outside the transient heap; later frames composite it directly.
                let keep = self.gpu.render_target(fw, fh, gpu::FBO_FORMAT, 1)?;
                let blit = cb
                    .blitCommandEncoder()
                    .ok_or_else(|| Error::Metal("blit encoder".into()))?;
                // SAFETY: same size and format.
                unsafe { blit.copyFromTexture_toTexture(&prev, &keep) };
                blit.endEncoding();
                self.layers[li].cached = Some(keep);
            }
            if let Some(name) = composite {
                // Materials and effects of later layers find it among the frame's named buffers.
                let _ = frame_copy.insert(name.clone(), prev.clone());
                let _ = composites.insert(name, prev);
                main = Some(gpu::begin(cb, scene_target, msaa.as_deref(), None)?);
                continue;
            }
            // With a colour blend mode, the layer's own material blends the result with the screen.
            // A compose layer's own shader covers the whole target, so its result is composited
            // into the layer's box instead.
            let blended = self.layers[li]
                .base
                .as_ref()
                .filter(|b| b.reads_frame && !compose);
            let enc = match blended {
                Some(_) => {
                    self.copy_frame(cb, None, scene_target, msaa.as_deref(), &mut frame_copy)?
                }
                None => gpu::begin(cb, scene_target, msaa.as_deref(), None)?,
            };
            match &self.layers[li].base {
                Some(item) if item.reads_frame && !compose => {
                    self.draw(
                        &enc,
                        item,
                        &ctx,
                        [1.0, 1.0],
                        input,
                        None,
                        &frame_copy,
                        Some(&prev),
                    );
                    if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                        self.pool.give(t);
                    }
                }
                _ => self.composite(&enc, &prev, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?,
            }
            self.pool.give(prev);
            main = Some(enc);
        }
        if let Some(enc) = main {
            enc.endEncoding();
        }
        for (_, t) in composites {
            self.pool.give(t);
        }
        if let Some(scene_tex) = scene_tex.as_ref().filter(|_| bloom) {
            let glow = self.bloom(cb, scene_tex)?;
            let tint = floats(&self.scene.bloom.tint.get(&self.props));
            let tint = [0, 1, 2].map(|i| tint.get(i).copied().unwrap_or(1.0));
            let enc = gpu::begin(cb, scene_tex, None, None)?;
            self.composite_rect(
                &enc,
                &glow,
                0,
                Blend::Additive,
                1,
                FBO_MVP,
                [0.0, 0.0, 1.0, 1.0],
                tint,
                1.0,
            )?;
            enc.endEncoding();
            self.pool.give(glow);
        }
        if let Some(scene_tex) = scene_tex.clone().filter(|_| !blurred) {
            let enc = gpu::begin(cb, target, None, None)?;
            self.composite_rect(
                &enc,
                &scene_tex,
                0,
                Blend::Disabled,
                1,
                FBO_MVP,
                [0.0, 0.0, 1.0, 1.0],
                [1.0; 3],
                1.0,
            )?;
            enc.endEncoding();
            self.pool.give(scene_tex);
        } else if let Some(scene_tex) = scene_tex {
            // The scene is on its own texture; put a blurred copy of it behind and the sharp
            // picture on top, so the empty part of the target is not bare.
            let (x, y, cw, ch) = self.content_rect(tw, th);
            let bg = self.blur_frame(cb, &scene_tex, [x / tw, y / th, cw / tw, ch / th])?;
            let enc = gpu::begin(cb, target, None, Some([0.0, 0.0, 0.0, 1.0]))?;
            // The blurred copy covers the whole target.
            let crop = cover_crop(cw / ch, tw / th);
            self.composite_rect(&enc, &bg, 0, Blend::Normal, 1, FBO_MVP, crop, [1.0; 3], 1.0)?;
            // The picture itself keeps its place.
            let mvp = sub_rect_mvp(x, y, cw, ch, tw, th);
            self.composite_rect(
                &enc,
                &scene_tex,
                0,
                Blend::Normal,
                1,
                mvp,
                [x / tw, y / th, (x + cw) / tw, (y + ch) / th],
                [1.0; 3],
                1.0,
            )?;
            enc.endEncoding();
            self.pool.give(bg);
            self.pool.give(scene_tex);
        }
        for (_, t) in frame_copy {
            self.pool.give(t);
        }
        self.pool.end_frame(&self.gpu);
        // The zoom moved far enough that the text bitmaps are the wrong size; redraw them at
        // the new scale for the next frame.
        if self.text_dirty {
            self.text_dirty = false;
            self.text_scale = fit;
            self.refresh_texts();
        }
        Ok(())
    }

    /// Ends the main pass, copies the target into `_rt_FullFrameBuffer` and reopens the pass.
    fn copy_frame(
        &mut self,
        cb: &gpu::CommandBuffer,
        main: Option<Retained<gpu::Encoder>>,
        target: &Texture,
        msaa: Option<&Texture>,
        frame_copy: &mut HashMap<String, Retained<Texture>>,
    ) -> Result<Retained<gpu::Encoder>, Error> {
        if let Some(enc) = main {
            enc.endEncoding();
        }
        let copy = match frame_copy.remove("_rt_FullFrameBuffer") {
            Some(t) => t,
            None => self.pool.take(&self.gpu, target.width(), target.height())?,
        };
        let blit = cb
            .blitCommandEncoder()
            .ok_or_else(|| Error::Metal("blit encoder".into()))?;
        // SAFETY: same size and format; the target is not framebuffer-only when this runs
        // (see `reads_framebuffer`).
        unsafe { blit.copyFromTexture_toTexture(target, &copy) };
        blit.endEncoding();
        let _ = frame_copy.insert("_rt_FullFrameBuffer".into(), copy);
        gpu::begin(cb, target, msaa, None)
    }

    /// Whether some draw samples the screen; the drawable must then be readable.
    pub fn reads_framebuffer(&self) -> bool {
        self.layers
            .iter()
            .flat_map(|l| l.base.iter().chain(&l.base_fx))
            .any(|i| i.reads_frame)
    }

    fn composite(
        &mut self,
        enc: &gpu::Encoder,
        tex: &Texture,
        sampler: usize,
        blend: Blend,
        ctx: &DrawCtx,
        uv: [f32; 2],
    ) -> Result<(), Error> {
        self.composite_rect(
            enc,
            tex,
            sampler,
            blend,
            self.samples,
            ctx.mvp,
            [0.0, 0.0, uv[0], uv[1]],
            ctx.color,
            ctx.alpha,
        )
    }

    /// Draws a texture over the area the matrix maps the unit quad onto, taking the part of the
    /// texture the rectangle names.
    #[allow(clippy::too_many_arguments)]
    fn composite_rect(
        &mut self,
        enc: &gpu::Encoder,
        tex: &Texture,
        sampler: usize,
        blend: Blend,
        samples: usize,
        mvp: Mat4,
        rect: [f32; 4],
        color: [f32; 3],
        alpha: f32,
    ) -> Result<(), Error> {
        let pipeline = self.gpu.composite(blend, TARGET_FORMAT, samples)?;
        enc.setRenderPipelineState(&pipeline);
        let mut u = [0f32; 20];
        u[..16].copy_from_slice(&mvp);
        u[16..19].copy_from_slice(&color);
        u[19] = alpha;
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &bytes, 0);
        gpu::set_bytes(enc, false, &bytes, 0);
        gpu::set_bytes(
            enc,
            true,
            &quad_rect(rect),
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        // SAFETY: slot 0 exists in the composite shader; the texture outlives the encoder's use.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(tex), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    /// The scene's glow: bright parts at a quarter of the size, blurred twice. Bloom is
    /// low-frequency, so the small buffers lose nothing visible.
    fn bloom(
        &mut self,
        cb: &gpu::CommandBuffer,
        src: &Texture,
    ) -> Result<Retained<Texture>, Error> {
        let b = &self.scene.bloom;
        let num = |v: Value, d: f32| floats(&v).first().copied().unwrap_or(d);
        let threshold = num(b.threshold.get(&self.props), 0.65);
        let strength = num(b.strength.get(&self.props), 2.0);
        let (w, h) = ((src.width() / 4).max(1), (src.height() / 4).max(1));
        let a = self.pool.take(&self.gpu, w, h)?;
        let enc = gpu::begin(cb, &a, None, Some([0.0; 4]))?;
        let texel = (
            1.0 / src.width().max(1) as f32,
            1.0 / src.height().max(1) as f32,
        );
        self.blur_library_pass(
            &enc,
            "lw_bright_fs",
            src,
            [0.0, 0.0, 1.0, 1.0],
            texel,
            [threshold, strength],
        )?;
        enc.endEncoding();
        let out = a;
        for radius in [1.0f32, 2.5] {
            let tmp = self.pool.take(&self.gpu, w, h)?;
            let enc = gpu::begin(cb, &tmp, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &out, [0.0, 0.0, 1.0, 1.0], (radius / w as f32, 0.0))?;
            enc.endEncoding();
            let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &tmp, [0.0, 0.0, 1.0, 1.0], (0.0, radius / h as f32))?;
            enc.endEncoding();
            self.pool.give(tmp);
        }
        Ok(out)
    }

    /// A blurred copy of the part of `src` the rectangle names. The picture is halved four
    /// times, each step averaging a 4x4 block so nothing aliases, then blurred at that size;
    /// drawn back up with linear filtering it gives a soft, even backdrop.
    fn blur_frame(
        &mut self,
        cb: &gpu::CommandBuffer,
        src: &Texture,
        rect: [f32; 4],
    ) -> Result<Retained<Texture>, Error> {
        let mut w = (src.width() as f32 * rect[2]).round().max(1.0) as usize;
        let mut h = (src.height() as f32 * rect[3]).round().max(1.0) as usize;
        let mut cur: Option<Retained<Texture>> = None;
        for _ in 0..4 {
            (w, h) = ((w / 2).max(1), (h / 2).max(1));
            let next = self.pool.take(&self.gpu, w, h)?;
            let (input, area): (&Texture, [f32; 4]) = match &cur {
                Some(t) => (t, [0.0, 0.0, 1.0, 1.0]),
                None => (src, rect),
            };
            let texel = (
                1.0 / input.width().max(1) as f32,
                1.0 / input.height().max(1) as f32,
            );
            let enc = gpu::begin(cb, &next, None, Some([0.0; 4]))?;
            self.blur_library_pass(&enc, "lw_bright_fs", input, area, texel, [0.0, 1.0])?;
            enc.endEncoding();
            if let Some(t) = cur.replace(next) {
                self.pool.give(t);
            }
        }
        let out = cur.ok_or_else(|| Error::Metal("blur".into()))?;
        for radius in [1.0f32, 2.0] {
            let tmp = self.pool.take(&self.gpu, w, h)?;
            let enc = gpu::begin(cb, &tmp, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &out, [0.0, 0.0, 1.0, 1.0], (radius / w as f32, 0.0))?;
            enc.endEncoding();
            let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &tmp, [0.0, 0.0, 1.0, 1.0], (0.0, radius / h as f32))?;
            enc.endEncoding();
            self.pool.give(tmp);
        }
        Ok(out)
    }

    /// One blur pass: samples the source along `dir` (in source texels).
    fn blur_pass(
        &mut self,
        enc: &gpu::Encoder,
        src: &Texture,
        rect: [f32; 4],
        dir: (f32, f32),
    ) -> Result<(), Error> {
        self.blur_library_pass(enc, "lw_blur_fs", src, rect, dir, [0.0; 2])
    }

    #[allow(clippy::too_many_arguments)]
    fn blur_library_pass(
        &mut self,
        enc: &gpu::Encoder,
        fragment: &'static str,
        src: &Texture,
        rect: [f32; 4],
        dir: (f32, f32),
        tp: [f32; 2],
    ) -> Result<(), Error> {
        let pipeline = self.gpu.blur_pipeline(fragment, 1)?;
        enc.setRenderPipelineState(&pipeline);
        let mut u = [0f32; 24];
        u[..16].copy_from_slice(&FBO_MVP);
        u[16..20].copy_from_slice(&rect);
        u[20] = dir.0;
        u[21] = dir.1;
        u[22] = tp[0];
        u[23] = tp[1];
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &bytes, 0);
        gpu::set_bytes(enc, false, &bytes, 0);
        gpu::set_bytes(
            enc,
            true,
            &quad_rect([0.0, 0.0, 1.0, 1.0]),
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        // SAFETY: slot 0 exists in the blur shader; the texture outlives the encoder's use.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(src), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(
        &self,
        enc: &gpu::Encoder,
        item: &DrawItem,
        ctx: &DrawCtx,
        uv: [f32; 2],
        input: FrameInput,
        prev: Option<&Retained<Texture>>,
        named: &HashMap<String, Retained<Texture>>,
        tex0: Option<&Texture>,
    ) {
        enc.setRenderPipelineState(&item.pipeline);
        // Resolve textures first: their sizes feed the resolution uniforms.
        let mut bound: Vec<(u8, usize, &Texture, usize, [f32; 4])> = Vec::new();
        let mut sprite: Option<(Frame, [f32; 4])> = None;
        for (slot, index, src) in &item.textures {
            if let (0, Some(t)) = (*index, tex0) {
                let (w, h) = (t.width() as f32, t.height() as f32);
                bound.push((*slot, 0, t, 0, [w, h, w, h]));
                continue;
            }
            match src {
                TexSource::Image(t) => {
                    let mut img = 0;
                    if *index == 0 {
                        if let Some(f) = t.frame(input.time) {
                            img = f.image.min(t.images.len() - 1);
                            sprite = Some((*f, t.res));
                        }
                    }
                    bound.push((*slot, *index, &t.images[img], t.sampler, t.res));
                }
                TexSource::Target(name) => {
                    let tex = if name == "previous" {
                        prev
                    } else {
                        named.get(name)
                    };
                    let tex = tex.map(|t| &**t).unwrap_or(&*self.black.images[0]);
                    // The screen copy is real size; effect buffers report their native size.
                    let k = if name == "_rt_FullFrameBuffer" {
                        [1.0, 1.0]
                    } else {
                        ctx.buffer_scale
                    };
                    let (w, h) = (tex.width() as f32 / k[0], tex.height() as f32 / k[1]);
                    bound.push((*slot, *index, tex, 0, [w, h, w, h]));
                }
            }
        }
        let res = |n: usize| bound.iter().find(|b| b.1 == n).map_or([1.0; 4], |b| b.4);

        let mut vs = item.vs.clone();
        let mut fs = item.fs.clone();
        // Effect passes draw a full-target quad. Some effect shaders skip the matrix and use
        // the position as clip space, so the quad is given in clip space with an identity matrix.
        let full_target = ctx.mvp == FBO_MVP;
        let mvp = if full_target { IDENTITY } else { ctx.mvp };
        // In an effect pass the pointer is unprojected into the layer: its pixels (y up, centred)
        // for the model-view-projection inverse, its [-1, 1] square (y up) for the texture
        // projection inverse. Both are the identity for a layer that exactly fills the view.
        let [w, h] = ctx.size.map(|s| s.max(0.001));
        let (mvp_inv, tex_proj_inv) = if full_target {
            (
                invert_affine_2d(&mul(&ctx.screen_mvp, &scale(1.0 / w, -1.0 / h, 1.0))),
                invert_affine_2d(&mul(&ctx.screen_mvp, &scale(0.5, -0.5, 1.0))),
            )
        } else {
            (invert_affine_2d(&mvp), IDENTITY)
        };
        for (vertex, u, d) in &item.dynamic {
            let v: Vec<f32> = match d {
                Dyn::Mvp => mvp.to_vec(),
                Dyn::Model => ctx.model.to_vec(),
                Dyn::ModelInverse => invert_affine_2d(&ctx.model).to_vec(),
                Dyn::ViewProjection => ctx.view_projection.to_vec(),
                Dyn::MvpInverse => mvp_inv.to_vec(),
                Dyn::TexProjectionInverse => tex_proj_inv.to_vec(),
                Dyn::Identity => IDENTITY.to_vec(),
                Dyn::Time => vec![input.time],
                Dyn::FrameTime => vec![input.frame_time],
                Dyn::DayTime => vec![day_time()],
                Dyn::Screen => vec![
                    ctx.target[0],
                    ctx.target[1],
                    ctx.target[0] / ctx.target[1].max(1.0),
                ],
                Dyn::Pointer => input.pointer.to_vec(),
                Dyn::Parallax => input.parallax.to_vec(),
                Dyn::TexResolution(n) => res(*n).to_vec(),
                Dyn::TexTexel(n) => {
                    let r = res(*n);
                    vec![1.0 / r[0].max(1.0), 1.0 / r[1].max(1.0), r[0], r[1]]
                }
                Dyn::TexelSize => vec![1.0 / ctx.target[0].max(1.0), 1.0 / ctx.target[1].max(1.0)],
                Dyn::TexelSizeHalf => {
                    vec![0.5 / ctx.target[0].max(1.0), 0.5 / ctx.target[1].max(1.0)]
                }
                Dyn::Color4 => vec![ctx.color[0], ctx.color[1], ctx.color[2], ctx.alpha],
                Dyn::Color3 => ctx.color.to_vec(),
                Dyn::Alpha => vec![ctx.alpha],
                Dyn::SpriteRotation => match sprite {
                    Some((f, r)) => vec![
                        f.width_x / r[0],
                        f.width_y / r[1],
                        f.height_x / r[0],
                        f.height_y / r[1],
                    ],
                    None => vec![1.0, 0.0, 0.0, 1.0],
                },
                Dyn::SpriteTranslation => match sprite {
                    Some((f, r)) => vec![f.x / r[0], f.y / r[1]],
                    None => vec![0.0, 0.0],
                },
                Dyn::Audio(right, n) => bands(&self.audio[*right as usize], *n),
            };
            write_uniform(if *vertex { &mut vs } else { &mut fs }, u, &v);
        }
        gpu::set_buffer_or_bytes(&self.gpu, enc, true, &vs, 0);
        gpu::set_buffer_or_bytes(&self.gpu, enc, false, &fs, 0);
        let verts = if full_target { clip_quad(uv) } else { quad(uv) };
        gpu::set_bytes(enc, true, &verts, shader::VERTEX_BUFFER_SLOT as usize);
        for (slot, _, tex, sampler, _) in bound {
            let slot = slot as usize;
            // SAFETY: slots come from the program's own binding map; resources outlive the frame.
            unsafe {
                enc.setVertexTexture_atIndex(Some(tex), slot);
                enc.setFragmentTexture_atIndex(Some(tex), slot);
                enc.setVertexSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), slot.min(15));
                enc.setFragmentSamplerState_atIndex(
                    Some(&self.gpu.samplers[sampler]),
                    slot.min(15),
                );
            }
        }
        // SAFETY: a 4-vertex strip from the bytes set above.
        unsafe {
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4)
        };
    }

    /// Whether any video texture is playing; such a scene keeps drawing.
    fn videos_playing(&self) -> bool {
        self.videos.iter().any(|(_, w)| {
            w.upgrade()
                .is_some_and(|t| t.video.as_ref().is_some_and(|p| p.state().0))
        })
    }

    /// Advances every video to `time` (the scene clock) and uploads the frames that changed.
    /// Sequential frames step the playhead; a jump (the offscreen recorder) seeks instead, and
    /// `wait` gives the decoder a moment to catch up.
    fn step_videos(&mut self, time: f32, wait: bool) {
        self.show_videos_at(time, u64::from(wait) * 250, true);
    }

    /// Offscreen entry point: videos show their frame at `time`, waiting for the decoder.
    pub fn offscreen_videos(&mut self, time: f32) {
        self.show_videos_at(time, 500, false);
    }

    /// Rewinds every video; the loop stopped, and play resumes from the start.
    pub fn reset_videos(&mut self) {
        for (_, weak) in &self.videos {
            if let Some(entry) = weak.upgrade() {
                if let Some(player) = &entry.video {
                    player.stop();
                }
            }
        }
        self.last_input_time = None;
    }

    fn show_videos_at(&mut self, time: f32, wait_ms: u64, stepping: bool) {
        if self.videos.is_empty() {
            self.last_input_time = Some(time);
            return;
        }
        let delta = self.last_input_time.map(|last| time - last);
        let step = stepping && delta.is_some_and(|d| (0.0..=1.0).contains(&d));
        self.last_input_time = Some(time);
        let entries: Vec<Rc<TexEntry>> = self
            .videos
            .iter()
            .filter_map(|(_, w)| w.upgrade())
            .filter(|t| t.video.is_some())
            .collect();
        for entry in &entries {
            let Some(player) = entry.video.as_ref() else {
                continue;
            };
            let changed = if step {
                player.advance(delta.unwrap_or(0.0))
            } else {
                player.show_at(time as f64, wait_ms)
            };
            if changed {
                self.upload_video_frame(entry);
            }
        }
    }

    /// Copies the player's current frame into the entry's texture.
    fn upload_video_frame(&self, entry: &Rc<TexEntry>) {
        let Some(player) = entry.video.as_ref() else {
            return;
        };
        let Some(texture) = entry.images.first() else {
            return;
        };
        let region = MTLRegion {
            origin: MTLOrigin { x: 0, y: 0, z: 0 },
            size: MTLSize {
                width: texture.width(),
                height: texture.height(),
                depth: 1,
            },
        };
        // The player locks the pixel buffer for the call and hands us one BGRA row.
        let _ = player.with_pixels(|ptr, row| {
            let Some(ptr) = NonNull::new(ptr as *mut c_void) else {
                return;
            };
            // SAFETY: replaceRegion copies `width * 4` bytes from each of `height` rows now.
            unsafe { texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(region, 0, ptr, row) };
        });
    }

    /// A script's video command for a layer's video texture (`getVideoTexture()` writes).
    fn video_command(&mut self, layer_id: i64, cmd: &str, value: &Value) {
        let Some(index) = self.scene.layers.iter().position(|l| l.id == layer_id) else {
            return;
        };
        let Some(entry) = self.layers.get(index).and_then(|l| l.image.clone()) else {
            return;
        };
        let Some(player) = entry.video.as_ref() else {
            return;
        };
        match cmd {
            "play" => player.play(),
            "pause" => player.pause(),
            "stop" => player.stop(),
            "time" => {
                if let Some(t) = value.as_f64() {
                    player.seek(t);
                }
            }
            "rate" => {
                if let Some(r) = value.as_f64() {
                    player.set_rate(r as f32);
                }
            }
            "loop" => player.set_looping(crate::scene::truthy(value)),
            _ => {}
        }
    }

    /// Every layer with a video texture: (layer id, playhead, playing), for the scripts.
    fn video_states(&self) -> Vec<(i64, f64, bool)> {
        self.layers
            .iter()
            .zip(self.scene.layers.iter())
            .filter_map(|(g, l)| {
                let player = g.image.as_ref()?.video.as_ref()?;
                let (playing, time) = player.state();
                Some((l.id, time, playing))
            })
            .collect()
    }

    /// Whether frames differ over time. Static scenes draw once and then idle.
    pub fn is_animated(&self) -> bool {
        let items = self.layers.iter().flat_map(|l| {
            l.base.iter().chain(
                l.effects
                    .iter()
                    .flat_map(|e| e.passes.iter().map(|p| &p.item)),
            )
        });
        let moving = |d: &Dyn| d.moves();
        let sprites = self
            .layers
            .iter()
            .filter_map(|l| l.image.as_ref())
            .any(|t| t.frames.len() > 1);
        sprites
            || self.videos_playing()
            || !self.particles.is_empty()
            || self.puppets.iter().any(|p| !p.animations.is_empty())
            || self.scripts_animated()
            || self.parallax_now().is_some()
            || items
                .into_iter()
                .any(|i| i.dynamic.iter().any(|(_, _, d)| moving(d)))
    }

    pub fn texture_memory(&self) -> usize {
        self.textures
            .values()
            .flat_map(|t| &t.images)
            .map(|t| MTLAllocation::allocatedSize(&**t))
            .sum()
    }
}

/// A spectrum regrouped into `n` bands, each the mean of the bins it covers.
pub(crate) fn bands(src: &[f32], n: usize) -> Vec<f32> {
    let m = src.len();
    (0..n)
        .map(|i| {
            if m == 0 {
                return 0.0;
            }
            let a = i * m / n;
            let b = ((i + 1) * m / n).max(a + 1).min(m);
            src[a..b].iter().sum::<f32>() / (b - a) as f32
        })
        .collect()
}

/// Length of the world matrix's x and y axes, the larger one.
fn world_scale(m: &Mat4) -> f32 {
    let [x, y] = axis_scale(m);
    x.max(y)
}

/// Length of the matrix's x and y axes: how much it scales each.
fn axis_scale(m: &Mat4) -> [f32; 2] {
    [m[0].hypot(m[1]), m[4].hypot(m[5])]
}

/// The part of the centred unit quad that `mvp` puts inside clip space grown to `reach` (1 is the
/// target itself), as texture coordinates `[u0, v0, u1, v1]` of the quad.
fn visible_uv(mvp: &Mat4, reach: f32) -> [f32; 4] {
    let inv = invert_affine_2d(mvp);
    let p = [
        [-reach, -reach],
        [reach, -reach],
        [-reach, reach],
        [reach, reach],
    ]
    .map(|[x, y]| {
        [
            inv[0] * x + inv[4] * y + inv[12] + 0.5,
            inv[1] * x + inv[5] * y + inv[13] + 0.5,
        ]
    });
    let lo = |a: usize| {
        p.iter()
            .map(|c| c[a])
            .fold(f32::INFINITY, f32::min)
            .clamp(0.0, 1.0)
    };
    let hi = |a: usize| {
        p.iter()
            .map(|c| c[a])
            .fold(f32::NEG_INFINITY, f32::max)
            .clamp(0.0, 1.0)
    };
    [lo(0), lo(1), hi(0), hi(1)]
}

/// Limits drawing to the `uv` part of the target.
fn scissor(enc: &gpu::Encoder, target: &Texture, uv: [f32; 4]) {
    let (w, h) = (target.width() as f32, target.height() as f32);
    let x = (uv[0] * w).floor() as usize;
    let y = (uv[1] * h).floor() as usize;
    let x1 = ((uv[2] * w).ceil() as usize).clamp(x + 1, target.width());
    let y1 = ((uv[3] * h).ceil() as usize).clamp(y + 1, target.height());
    let x = x.min(target.width() - 1);
    let y = y.min(target.height() - 1);
    enc.setScissorRect(MTLScissorRect {
        x,
        y,
        width: x1 - x,
        height: y1 - y,
    });
}

/// Whether the centred unit quad, put through `mvp` (an orthographic one), lies wholly outside
/// clip space.
fn off_target(mvp: &Mat4) -> bool {
    let corners = [[-0.5f32, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]].map(|[x, y]| {
        [
            mvp[0] * x + mvp[4] * y + mvp[12],
            mvp[1] * x + mvp[5] * y + mvp[13],
        ]
    });
    (0..2).any(|a| corners.iter().all(|c| c[a] > 1.0) || corners.iter().all(|c| c[a] < -1.0))
}

/// Centred unit quad as a triangle strip, y down; texcoord (0, 0) is the image's top-left.
fn quad(uv: [f32; 2]) -> Vec<u8> {
    quad_rect([0.0, 0.0, uv[0], uv[1]])
}

/// The unit quad already in clip space: what `FBO_MVP` would make of it.
fn clip_quad(uv: [f32; 2]) -> Vec<u8> {
    let (l, r, b, t) = (-1.0f32, 1.0, -1.0, 1.0);
    let v = [
        [l, b, 0.0, 0.0, uv[1]],
        [r, b, 0.0, uv[0], uv[1]],
        [l, t, 0.0, 0.0, 0.0],
        [r, t, 0.0, uv[0], 0.0],
    ];
    v.iter()
        .flatten()
        .flat_map(|f: &f32| f.to_le_bytes())
        .collect()
}

/// The same quad, but taking the part of the texture the rectangle names: left, top, right,
/// bottom in texture coordinates.
fn quad_rect(r: [f32; 4]) -> Vec<u8> {
    let (l, r_, b, t) = (-0.5f32, 0.5, 0.5, -0.5);
    let (u0, v0, u1, v1) = (r[0], r[1], r[2], r[3]);
    let v = [
        [l, b, 0.0, u0, v1],
        [r_, b, 0.0, u1, v1],
        [l, t, 0.0, u0, v0],
        [r_, t, 0.0, u1, v0],
    ];
    v.iter()
        .flatten()
        .flat_map(|f: &f32| f.to_le_bytes())
        .collect()
}

/// The part of a picture that covers a target of another shape: the wider axis is cropped.
fn cover_crop(content: f32, target: f32) -> [f32; 4] {
    if content > target {
        let d = (1.0 - target / content) / 2.0;
        [d, 0.0, 1.0 - d, 1.0]
    } else {
        let d = (1.0 - content / target) / 2.0;
        [0.0, d, 1.0, 1.0 - d]
    }
}

/// Matrix that maps the unit quad onto a rectangle of the target, in target pixels.
fn sub_rect_mvp(x: f32, y: f32, w: f32, h: f32, tw: f32, th: f32) -> Mat4 {
    // Metal's clip space has y up, the target's rows count from the top.
    let (nx0, nx1) = (2.0 * x / tw - 1.0, 2.0 * (x + w) / tw - 1.0);
    let (ny0, ny1) = (1.0 - 2.0 * (y + h) / th, 1.0 - 2.0 * y / th);
    let sx = (nx1 - nx0) / 2.0;
    let sy = (ny1 - ny0) / 2.0;
    let tx = (nx0 + nx1) / 2.0;
    let ty = (ny0 + ny1) / 2.0;
    mul(&scale(sx, sy, 1.0), &mul(&translate(tx, ty, 0.0), &FBO_MVP))
}

/// Whether the design, placed at `rect` (x, y, width, height in target pixels), leaves part of the
/// `tw`×`th` target empty. Half a pixel of slack keeps a rounded exact fit from counting as a gap.
fn leaves_gaps(rect: (f32, f32, f32, f32), tw: f32, th: f32) -> bool {
    let (x, y, w, h) = rect;
    x > 0.5 || y > 0.5 || x + w < tw - 0.5 || y + h < th - 0.5
}

/// Magnification while camera parallax is on. It hides a band at each edge for moved layers to
/// travel into; 1.06 leaves 3% of the scene per side.
const PARALLAX_ZOOM: f32 = 1.06;

/// How far a layer of depth 1 moves for this pointer, in design units: the pointer's offset from
/// the centre times amount and influence times the scene width (the scale scene authors tune
/// `amount` against; e.g. 0.1 x 0.1 is a few pixels, 0.5 x 1 is a hundred or more). Layers move
/// against the pointer, as if the camera followed it; a negative influence reverses that.
// shortcut: direction and scale follow the formula the format's authors use, not measured against
// Wallpaper Engine; compare side by side with a parallax scene there and adjust if they differ.
fn camera_shift(p: &scene::ParallaxNow, pointer: [f32; 2], reference: f32) -> [f32; 2] {
    let k = p.amount * p.mouse_influence;
    [0, 1].map(|i| -(pointer[i] - 0.5) * k * reference)
}

/// The camera's offset at `time` for a scene's shake settings (amplitude, roughness, speed): slow
/// smooth noise, two incommensurate sines per axis, with roughness adding a faster octave.
// shortcut: magnitude (amplitude x 1% of the scene) and the noise shape are a guess, not measured
// against Wallpaper Engine; tune against a scene that enables the shake.
fn camera_shake([amplitude, roughness, speed]: [f32; 3], time: f32, size: [f32; 2]) -> [f32; 2] {
    let t = time * speed;
    let axis = |phase: f32, extent: f32| {
        let smooth = (t * 0.9 + phase).sin() + 0.6 * (t * 1.7 + phase * 2.3).sin();
        let rough = roughness.clamp(0.0, 4.0) * 0.25 * (t * 4.1 + phase * 3.1).sin();
        (smooth + rough) / 1.6 * amplitude * 0.01 * extent
    };
    [axis(0.0, size[0]), axis(1.7, size[0])]
}

/// One layer's own parallax offset: its depth times the camera shift, kept inside the margin.
fn parallax_offset(depth: [f32; 2], shift: [f32; 2], margin: [f32; 2]) -> [f32; 2] {
    [0, 1].map(|i| (depth[i] * shift[i]).clamp(-margin[i], margin[i]))
}

fn day_time() -> f32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let offset = objc2_foundation::NSTimeZone::localTimeZone().secondsFromGMT() as i64;
    (secs + offset).rem_euclid(86_400) as f32 / 86_400.0
}

/// Writes `v` into a std140 block slot, element by element.
fn write_uniform(bytes: &mut [u8], u: &Uniform, v: &[f32]) {
    let per = (u.rows * u.cols) as usize;
    if per == 0 || v.is_empty() {
        return;
    }
    let mut put = |offset: usize, x: f32| {
        if let Some(dst) = bytes.get_mut(offset..offset + 4) {
            let raw = if u.is_int {
                (x as i32).to_le_bytes()
            } else {
                x.to_le_bytes()
            };
            dst.copy_from_slice(&raw);
        }
    };
    // Matrices may come as 4x4 for smaller uniforms (mat3 from a mat4).
    let per_src = if u.cols > 1 && v.len() == 16 * u.count as usize {
        16
    } else {
        per
    };
    for e in 0..u.count as usize {
        let src = match v.get(e * per_src..(e + 1) * per_src) {
            Some(s) => s,
            None if e == 0 => v,
            None => break,
        };
        let base = u.offset as usize + e * u.stride as usize;
        if u.cols > 1 {
            // Source is column-major 4x4 when it has 16 values; take the top-left block.
            let src_rows = if src.len() == 16 { 4 } else { u.rows as usize };
            for c in 0..u.cols as usize {
                for r in 0..u.rows as usize {
                    if let Some(&x) = src.get(c * src_rows + r) {
                        put(base + c * u.col_stride as usize + r * 4, x);
                    }
                }
            }
        } else {
            for (r, &x) in src.iter().take(u.rows as usize).enumerate() {
                put(base + r * 4, x);
            }
        }
    }
}

/// Where an animation is after `t` seconds, by its play mode: `mirror` plays forward then back,
/// `single` plays once and holds the last frame, anything else loops.
fn anim_seconds(mode: &str, t: f32, duration: f32) -> f32 {
    if duration <= 0.0 {
        return 0.0;
    }
    match mode {
        "mirror" => {
            let x = t.rem_euclid(2.0 * duration);
            if x > duration {
                2.0 * duration - x
            } else {
                x
            }
        }
        "single" => t.clamp(0.0, duration),
        _ => t.rem_euclid(duration),
    }
}

impl PuppetGpu {
    /// Skinning matrices for `time`: each animation layer samples its bone tracks, the layers
    /// combine in order (additive ones as deltas from the bind pose), then the skeleton is walked
    /// and the bind-pose world is undone with `bind_inverse`.
    fn bones_at(&self, time: f32) -> Vec<mat::M4> {
        let world = self.pose_at(time);
        (0..world.len())
            .map(|i| mat::mul(&self.bind_inverse[i], &world[i]))
            .collect()
    }

    /// Animated world matrix of a named attachment point, in the puppet's design units.
    fn attachment_at(&self, name: &str, time: f32) -> Option<Mat4> {
        let att = self.model.attachments.iter().find(|a| a.name == name)?;
        let bone = self
            .pose_at(time)
            .get(att.bone)
            .copied()
            .unwrap_or(mat::IDENTITY);
        let m = mat::mul(&att.matrix, &bone);
        // Row-vector rows laid end to end are the column-major array the engine uses.
        let mut out = [0.0f32; 16];
        for (i, v) in m.iter().flatten().enumerate() {
            out[i] = *v;
        }
        // Puppet space is y up; mirror the matrix into the y-down render space.
        out[1] = -out[1];
        out[4] = -out[4];
        out[13] = -out[13];
        Some(out)
    }

    /// World matrix of every bone at `time`, animation layers applied.
    fn pose_at(&self, time: f32) -> Vec<mat::M4> {
        let n = self.model.bones.len();
        let mut local = Vec::with_capacity(n);
        for (i, (bt, br, bs)) in self.bind.iter().copied().enumerate() {
            let (mut t, mut r, mut s) = (bt, br, bs);
            let mut replaced = false;
            for &(ai, rate, blend, additive) in &self.animations {
                let Some(anim) = self.model.animations.get(ai) else {
                    continue;
                };
                let Some(track) = anim.tracks.iter().find(|t| t.bone == i) else {
                    continue;
                };
                let frame =
                    anim_seconds(&anim.flag, time * rate, anim.duration_seconds()) * anim.fps;
                let sample = track.sample(frame);
                if additive {
                    for k in 0..3 {
                        t[k] += (sample.translation[k] - bt[k]) * blend;
                        r[k] += (sample.rotation[k] - br[k]) * blend;
                    }
                    for k in 0..3 {
                        let base = bs[k].abs().max(1e-6);
                        s[k] *= (sample.scale[k] / base).max(1e-6).powf(blend);
                    }
                } else if !replaced {
                    (t, r, s) = (sample.translation, sample.rotation, sample.scale);
                    replaced = true;
                }
            }
            local.push(mat::from_trs(t, r, s));
        }
        let mut world = vec![mat::IDENTITY; n];
        for (i, bone) in self.model.bones.iter().enumerate() {
            world[i] = match bone.parent {
                Some(p) if p < i => mat::mul(&local[i], &world[p]),
                _ => local[i],
            };
        }
        world
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blurred_backdrop_only_when_the_design_leaves_gaps() {
        // 16:9 design on a 16:9 target: no gap, no blur needed.
        assert!(!leaves_gaps((0.0, 0.0, 1920.0, 1080.0), 1920.0, 1080.0));
        // The same design fitted to a 16:10 target is letterboxed top and bottom.
        assert!(leaves_gaps((0.0, 38.5, 1728.0, 972.0), 1728.0, 1117.0));
        // ... and pillarboxed on a portrait target.
        assert!(leaves_gaps((0.0, 656.25, 1080.0, 607.5), 1080.0, 1920.0));
        // Zoomed in or panned past the edges: covered, unless the pan opens a gap.
        assert!(!leaves_gaps(
            (-100.0, -50.0, 2120.0, 1180.0),
            1920.0,
            1080.0
        ));
        assert!(leaves_gaps((100.0, -50.0, 2120.0, 1180.0), 1920.0, 1080.0));
    }

    #[test]
    fn camera_shake_is_bounded_and_zero_without_amplitude() {
        let size = [1920.0, 1080.0];
        assert_eq!(camera_shake([0.0, 1.0, 3.0], 2.0, size), [0.0, 0.0]);
        let mut moved = false;
        for i in 0..200 {
            let o = camera_shake([0.5, 1.0, 3.0], i as f32 * 0.1, size);
            assert!(
                o[0].abs() <= 0.5 * 0.01 * 1920.0 * 1.2 && o[1].abs() <= 0.5 * 0.01 * 1920.0 * 1.2,
                "{o:?}"
            );
            moved |= o[0] != 0.0;
        }
        assert!(moved);
    }

    #[test]
    fn parallax_and_shake_follow_user_properties() {
        let json: Value = serde_json::json!({
            "cameraparallax": {"user": "p", "value": true},
            "cameraparallaxamount": {"user": "amt", "value": 0.2},
            "camerashake": {"user": "s", "value": false},
        });
        let bound = |k: &str, d: Value| scene::Bound::parse_for_test(json.get(k), d);
        let parallax = scene::Parallax {
            enabled: bound("cameraparallax", Value::Bool(false)),
            amount: bound("cameraparallaxamount", Value::from(0.5)),
            delay: bound("cameraparallaxdelay", Value::from(0.1)),
            mouse_influence: bound("cameraparallaxmouseinfluence", Value::from(1.0)),
        };
        let mut props = HashMap::new();
        // Defaults from the file: on, amount 0.2, influence 1 when absent.
        let on = parallax.now(&props).expect("default is on");
        assert!((on.amount - 0.2).abs() < 1e-6 && (on.mouse_influence - 1.0).abs() < 1e-6);
        // The user switches it off and moves the slider.
        props.insert("p".into(), Value::Bool(false));
        assert!(parallax.now(&props).is_none());
        props.insert("p".into(), Value::Bool(true));
        props.insert("amt".into(), Value::from(0.9));
        assert!((parallax.now(&props).unwrap().amount - 0.9).abs() < 1e-6);
    }

    #[test]
    fn parallax_moves_layers_against_the_pointer_within_the_margin() {
        let p = scene::ParallaxNow {
            amount: 0.5,
            delay: 0.1,
            mouse_influence: 1.0,
        };
        let (w, margin) = (1920.0, [54.4, 30.6]);
        // Centred pointer: nothing moves.
        assert_eq!(camera_shift(&p, [0.5, 0.5], w), [0.0, 0.0]);
        // Pointer at the right edge: against it, by 0.5 * amount * width.
        let shift = camera_shift(&p, [1.0, 0.5], w);
        assert!(
            (shift[0] + 480.0).abs() < 1e-3 && shift[1] == 0.0,
            "{shift:?}"
        );
        // A layer's offset is depth times that, kept inside the margin; depth 0 stays fixed.
        assert_eq!(parallax_offset([0.0, 0.0], shift, margin), [0.0, 0.0]);
        assert!((parallax_offset([1.0, 1.0], shift, margin)[0] + 54.4).abs() < 1e-3);
        // A weak scene (0.1 x -0.1, like a scene that barely moves) is small and reversed.
        let weak = scene::ParallaxNow {
            amount: 0.1,
            delay: 1.1,
            mouse_influence: -0.1,
        };
        let s = camera_shift(&weak, [1.0, 0.5], w);
        assert!((s[0] - 9.6).abs() < 1e-3, "{s:?}");
        assert!((parallax_offset([1.2, 1.2], s, margin)[0] - 11.52).abs() < 1e-3);
    }

    #[test]
    fn visible_part_of_a_layer_hanging_off_the_right() {
        // Quad spanning clip x 0..2: its left half shows.
        let m = mul(&translate(1.0, 0.0, 0.0), &scale(2.0, 2.0, 1.0));
        let uv = visible_uv(&m, 1.0);
        assert!(
            (uv[0] - 0.0).abs() < 1e-5 && (uv[2] - 0.5).abs() < 1e-5,
            "{uv:?}"
        );
        assert!(
            (uv[1] - 0.0).abs() < 1e-5 && (uv[3] - 1.0).abs() < 1e-5,
            "{uv:?}"
        );
        assert_eq!(visible_uv(&FBO_MVP, 1.0), [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn a_layer_wholly_beside_the_target_is_off_target() {
        // Unit quad scaled to 0.1 wide, centred at x = 1.1 in clip space: entirely right of it.
        let beside = mul(&translate(1.1, 0.0, 0.0), &scale(0.1, 1.0, 1.0));
        assert!(off_target(&beside));
        // Overlapping the right edge by a little still counts as on target.
        let edge = mul(&translate(0.98, 0.0, 0.0), &scale(0.1, 1.0, 1.0));
        assert!(!off_target(&edge));
        assert!(!off_target(&FBO_MVP));
    }

    #[test]
    fn mirrored_animations_play_back_instead_of_jumping() {
        assert_eq!(anim_seconds("mirror", 1.5, 2.0), 1.5);
        assert_eq!(anim_seconds("mirror", 2.5, 2.0), 1.5);
        assert_eq!(anim_seconds("mirror", 4.5, 2.0), 0.5);
        assert_eq!(anim_seconds("loop", 2.5, 2.0), 0.5);
        assert_eq!(anim_seconds("single", 9.0, 2.0), 2.0);
    }

    #[test]
    fn mat3_uniform_takes_top_left_of_mat4() {
        let u = Uniform {
            name: "m".into(),
            offset: 0,
            rows: 3,
            cols: 3,
            col_stride: 16,
            count: 1,
            stride: 0,
            is_int: false,
        };
        let mut bytes = vec![0u8; 48];
        let m: Vec<f32> = (0..16).map(|i| i as f32).collect();
        write_uniform(&mut bytes, &u, &m);
        let read = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        assert_eq!(
            [read(0), read(4), read(8), read(16), read(32), read(40)],
            [0.0, 1.0, 2.0, 4.0, 8.0, 10.0]
        );
    }

    #[test]
    fn affine_inverse_round_trips() {
        let m = mul(
            &translate(3.0, 4.0, 0.0),
            &mul(&rotate_z(0.7), &scale(2.0, 5.0, 1.0)),
        );
        let p = mul(&m, &invert_affine_2d(&m));
        for (a, b) in p.iter().zip(IDENTITY.iter()) {
            assert!((a - b).abs() < 1e-5);
        }
    }
}
