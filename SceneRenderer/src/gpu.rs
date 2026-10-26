//! Thin Metal helpers: device, textures, samplers, pipelines, render-target pool.

use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_foundation::NSString;
use objc2_metal::*;

use crate::scene::Blend;
use crate::shader::{Program, VERTEX_BUFFER_SLOT};
use crate::tex::{Format, Tex};
use crate::Error;

pub type Device = ProtocolObject<dyn MTLDevice>;
pub type Texture = ProtocolObject<dyn MTLTexture>;
pub type Queue = ProtocolObject<dyn MTLCommandQueue>;
pub type Pipeline = ProtocolObject<dyn MTLRenderPipelineState>;
pub type Sampler = ProtocolObject<dyn MTLSamplerState>;
pub type Encoder = ProtocolObject<dyn MTLRenderCommandEncoder>;
pub type CommandBuffer = ProtocolObject<dyn MTLCommandBuffer>;

/// Render targets and intermediate effect buffers. Colour math happens in gamma space, like the
/// original engine, so nothing is sRGB-tagged.
pub const TARGET_FORMAT: MTLPixelFormat = MTLPixelFormat::BGRA8Unorm;
/// Same as the target so pipelines are shared between direct and intermediate draws.
pub const FBO_FORMAT: MTLPixelFormat = TARGET_FORMAT;

/// Interleaved vertex: position xyz, texcoord uv.
pub const VERTEX_STRIDE: usize = 20;

/// Particle vertex: position xy, texcoord uv, straight colour rgba.
pub const PARTICLE_STRIDE: usize = 32;

/// One textured, coloured quad per particle; the quad corners are built on the CPU so a
/// particle can be rotated and scaled without per-instance work on the GPU.
const PARTICLE_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; float4 col [[attribute(2)]]; };
struct VOut { float4 pos [[position]]; float2 uv; float4 col; };
struct U { float4x4 mvp; };
vertex VOut lw_particle_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o;
    o.pos = u.mvp * float4(v.pos, 0.0, 1.0);
    o.uv = v.uv;
    o.col = v.col;
    return o;
}
fragment float4 lw_particle_fs(VOut i [[stage_in]], texture2d<float> t [[texture(0)]],
                               sampler s [[sampler(0)]]) {
    float4 c = t.sample(s, i.uv);
    return float4(c.rgb * i.col.rgb, c.a * i.col.a);
}
"#;

const COMPOSITE_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float4x4 mvp; float4 color; };
vertex VOut lw_composite_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o; o.pos = u.mvp * float4(v.pos, 1.0); o.uv = v.uv; return o;
}
fragment float4 lw_composite_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                                texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, i.uv) * u.color;
}
"#;

/// Blur for the background of the blurred-fit mode. Five taps along one axis, using the
/// hardware's bilinear filtering to reach twice as far.
const BLUR_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float4x4 mvp; float4 rect; float2 dir; float2 tp; };
vertex VOut lw_blur_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o; o.pos = u.mvp * float4(v.pos, 1.0); o.uv = v.uv; return o;
}
fragment float4 lw_blur_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                           texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 c = u.rect.xy + i.uv * u.rect.zw;
    float3 sum = t.sample(s, c).rgb * 0.2270270270;
    sum += t.sample(s, c + u.dir * 1.3846153846).rgb * 0.3162162162;
    sum += t.sample(s, c - u.dir * 1.3846153846).rgb * 0.3162162162;
    sum += t.sample(s, c + u.dir * 3.2307692308).rgb * 0.0702702703;
    sum += t.sample(s, c - u.dir * 3.2307692308).rgb * 0.0702702703;
    return float4(sum, 1.0);
}
// Bloom source: a four-tap box average (for downsampling) keeping only what is brighter than
// the threshold `tp.x`, scaled by `tp.y`.
fragment float4 lw_bright_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                             texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 c = u.rect.xy + i.uv * u.rect.zw;
    float3 x = (t.sample(s, c + u.dir).rgb + t.sample(s, c - u.dir).rgb
              + t.sample(s, c + float2(u.dir.x, -u.dir.y)).rgb
              + t.sample(s, c + float2(-u.dir.x, u.dir.y)).rgb) * 0.25;
    float b = max(max(x.r, x.g), x.b);
    return float4(x * (max(b - u.tp.x, 0.0) / max(b, 1e-4)) * u.tp.y, 1.0);
}
"#;

#[derive(Debug)]
pub struct Gpu {
    pub device: Retained<Device>,
    pub queue: Retained<Queue>,
    /// [linear clamp, linear repeat, nearest clamp, nearest repeat]
    pub samplers: [Retained<Sampler>; 4],
    composite: HashMap<(Blend, MTLPixelFormat, usize), Retained<Pipeline>>,
    composite_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
    blur: HashMap<(&'static str, usize), Retained<Pipeline>>,
    blur_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
    particle: HashMap<(Blend, MTLPixelFormat, usize), Retained<Pipeline>>,
    particle_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
}

impl Gpu {
    pub fn new() -> Result<Self, Error> {
        let device =
            MTLCreateSystemDefaultDevice().ok_or_else(|| Error::Metal("no Metal device".into()))?;
        let queue = device
            .newCommandQueue()
            .ok_or_else(|| Error::Metal("no command queue".into()))?;
        let sampler = |linear: bool, repeat: bool| {
            let d = MTLSamplerDescriptor::new();
            let filter = if linear {
                MTLSamplerMinMagFilter::Linear
            } else {
                MTLSamplerMinMagFilter::Nearest
            };
            let mode = if repeat {
                MTLSamplerAddressMode::Repeat
            } else {
                MTLSamplerAddressMode::ClampToEdge
            };
            d.setMinFilter(filter);
            d.setMagFilter(filter);
            d.setMipFilter(MTLSamplerMipFilter::Linear);
            d.setSAddressMode(mode);
            d.setTAddressMode(mode);
            device
                .newSamplerStateWithDescriptor(&d)
                .ok_or_else(|| Error::Metal("sampler".into()))
        };
        let samplers = [
            sampler(true, false)?,
            sampler(true, true)?,
            sampler(false, false)?,
            sampler(false, true)?,
        ];
        let composite_lib = library(&device, COMPOSITE_MSL)?;
        let blur_lib = library(&device, BLUR_MSL)?;
        let particle_lib = library(&device, PARTICLE_MSL)?;
        Ok(Self {
            device,
            queue,
            samplers,
            composite: HashMap::new(),
            composite_lib,
            blur: HashMap::new(),
            blur_lib,
            particle: HashMap::new(),
            particle_lib,
        })
    }

    /// Uploads one image of `tex`. With `color`, a one- or two-channel texture reads as grey
    /// (and alpha): that is what such a file holds when it is drawn as a picture, such as a
    /// particle sprite. Masks and flow maps keep their raw channels.
    pub fn upload(&self, tex: &Tex, image: usize, color: bool) -> Result<Retained<Texture>, Error> {
        let mips = tex
            .images
            .get(image)
            .ok_or_else(|| Error::Format("texture image index".into()))?;
        let first = mips
            .first()
            .ok_or_else(|| Error::Format("texture has no mips".into()))?;
        let format = match tex.format {
            Format::Rgba8 => MTLPixelFormat::RGBA8Unorm,
            Format::Rg8 => MTLPixelFormat::RG8Unorm,
            Format::R8 => MTLPixelFormat::R8Unorm,
            Format::Bc1 => MTLPixelFormat::BC1_RGBA,
            Format::Bc2 => MTLPixelFormat::BC2_RGBA,
            Format::Bc3 => MTLPixelFormat::BC3_RGBA,
        };
        // SAFETY: plain descriptor construction with in-range sizes.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                format,
                first.width.max(1),
                first.height.max(1),
                false,
            )
        };
        // Stop at the first mip whose size does not halve properly (some files carry odd chains).
        let levels = mips
            .iter()
            .enumerate()
            .take_while(|(i, m)| {
                m.width == (first.width >> i).max(1) && m.height == (first.height >> i).max(1)
            })
            .count();
        // SAFETY: `levels` is at least 1 and matches the chain we upload below.
        unsafe { desc.setMipmapLevelCount(levels) };
        desc.setUsage(MTLTextureUsage::ShaderRead);
        let gray = |alpha| MTLTextureSwizzleChannels {
            red: MTLTextureSwizzle::Red,
            green: MTLTextureSwizzle::Red,
            blue: MTLTextureSwizzle::Red,
            alpha,
        };
        match tex.format {
            Format::R8 if color => desc.setSwizzle(gray(MTLTextureSwizzle::One)),
            Format::Rg8 if color => desc.setSwizzle(gray(MTLTextureSwizzle::Green)),
            _ => {}
        }
        let texture = self
            .device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("texture alloc".into()))?;
        for (level, mip) in mips.iter().take(levels).enumerate() {
            let region = MTLRegion {
                origin: MTLOrigin { x: 0, y: 0, z: 0 },
                size: MTLSize {
                    width: mip.width.max(1),
                    height: mip.height.max(1),
                    depth: 1,
                },
            };
            let ptr = NonNull::new(mip.data.as_ptr() as *mut c_void)
                .ok_or_else(|| Error::Format("empty mip".into()))?;
            // SAFETY: decode() checked that `data` holds at least `bytes(width, height)` bytes.
            unsafe {
                texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
                    region,
                    level,
                    ptr,
                    tex.format.row_bytes(mip.width.max(1)),
                )
            };
        }
        Ok(texture)
    }

    /// 1x1 texture of one colour, for shader defaults such as `util/white`.
    pub fn solid(&self, rgba: [u8; 4]) -> Result<Retained<Texture>, Error> {
        let tex = Tex {
            texture_width: 1,
            texture_height: 1,
            image_width: 1,
            image_height: 1,
            format: Format::Rgba8,
            clamp: false,
            nearest: false,
            images: vec![vec![crate::tex::Mip {
                width: 1,
                height: 1,
                data: rgba.to_vec(),
            }]],
            frames: Vec::new(),
            video: None,
        };
        self.upload(&tex, 0, false)
    }

    /// A BGRA texture a video's decoded frames are uploaded into, one per shown frame.
    pub fn video_texture(&self, w: u32, h: u32) -> Result<Retained<Texture>, Error> {
        // SAFETY: plain descriptor construction with in-range sizes.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                MTLPixelFormat::BGRA8Unorm,
                w.max(1) as usize,
                h.max(1) as usize,
                false,
            )
        };
        desc.setUsage(MTLTextureUsage::ShaderRead);
        self.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("video texture alloc".into()))
    }

    /// Fills a texture with transparent black, row by row, so an undecoded video frame shows
    /// nothing rather than whatever the allocator left behind.
    pub fn clear_texture(&self, texture: &Texture) {
        let row = texture.width() * 4;
        let zeros = vec![0u8; row];
        let Some(ptr) = NonNull::new(zeros.as_ptr() as *mut c_void) else {
            return;
        };
        for y in 0..texture.height() {
            let region = MTLRegion {
                origin: MTLOrigin { x: 0, y, z: 0 },
                size: MTLSize {
                    width: texture.width(),
                    height: 1,
                    depth: 1,
                },
            };
            // SAFETY: `zeros` holds `width * 4` bytes, one row of the region.
            unsafe { texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(region, 0, ptr, row) };
        }
    }

    pub fn render_target(
        &self,
        w: usize,
        h: usize,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Texture>, Error> {
        // SAFETY: plain descriptor construction.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                format,
                w.max(1),
                h.max(1),
                false,
            )
        };
        desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
        desc.setStorageMode(MTLStorageMode::Private);
        if samples > 1 {
            desc.setTextureType(MTLTextureType::Type2DMultisample);
            // SAFETY: sample counts are 2 or 4, both supported on every Mac GPU.
            unsafe { desc.setSampleCount(samples) };
            desc.setUsage(MTLTextureUsage::RenderTarget);
        }
        self.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("render target alloc".into()))
    }

    pub fn pipeline(
        &self,
        program: &Program,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let vs_lib = library(&self.device, &program.vertex.msl)?;
        let fs_lib = library(&self.device, &program.fragment.msl)?;
        let vs = function(&vs_lib, &program.vertex.entry)?;
        let fs = function(&fs_lib, &program.fragment.entry)?;
        let vd = MTLVertexDescriptor::new();
        for (name, loc) in &program.attributes {
            // Position-like attributes read xyz, everything else uv; vec4 inputs get w = 1.
            let (format, offset) = if name.starts_with("a_Position") {
                (MTLVertexFormat::Float3, 0)
            } else {
                (MTLVertexFormat::Float2, 12)
            };
            // SAFETY: attribute indices come from our own location assignment (< 31).
            let attr = unsafe { vd.attributes().objectAtIndexedSubscript(*loc as usize) };
            attr.setFormat(format);
            // SAFETY: offsets lie inside the 20-byte vertex.
            unsafe {
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, VERTEX_STRIDE)
    }

    pub fn composite(
        &mut self,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        if let Some(p) = self.composite.get(&(blend, format, samples)) {
            return Ok(p.clone());
        }
        let vs = function(&self.composite_lib, "lw_composite_vs")?;
        let fs = function(&self.composite_lib, "lw_composite_fs")?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [(MTLVertexFormat::Float3, 0), (MTLVertexFormat::Float2, 12)]
            .into_iter()
            .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, VERTEX_STRIDE)?;
        let _ = self.composite.insert((blend, format, samples), p.clone());
        Ok(p)
    }

    /// Pipeline for a blur-library pass (`lw_blur_fs` or `lw_bright_fs`), without blending.
    pub fn blur_pipeline(
        &mut self,
        fragment: &'static str,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        if let Some(p) = self.blur.get(&(fragment, samples)) {
            return Ok(p.clone());
        }
        let vs = function(&self.blur_lib, "lw_blur_vs")?;
        let fs = function(&self.blur_lib, fragment)?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [(MTLVertexFormat::Float3, 0), (MTLVertexFormat::Float2, 12)]
            .into_iter()
            .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(
            &vs,
            &fs,
            &vd,
            Blend::Normal,
            FBO_FORMAT,
            samples,
            VERTEX_STRIDE,
        )?;
        let _ = self.blur.insert((fragment, samples), p.clone());
        Ok(p)
    }

    /// Pipeline for particle quads, one draw per particle system.
    pub fn particle_pipeline(
        &mut self,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let key = (blend, format, samples);
        if let Some(p) = self.particle.get(&key) {
            return Ok(p.clone());
        }
        let vs = function(&self.particle_lib, "lw_particle_vs")?;
        let fs = function(&self.particle_lib, "lw_particle_fs")?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [
            (MTLVertexFormat::Float2, 0),
            (MTLVertexFormat::Float2, 8),
            (MTLVertexFormat::Float4, 16),
        ]
        .into_iter()
        .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the 32-byte vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, PARTICLE_STRIDE)?;
        let _ = self.particle.insert(key, p.clone());
        Ok(p)
    }

    #[allow(clippy::too_many_arguments)]
    fn finish_pipeline(
        &self,
        vs: &ProtocolObject<dyn MTLFunction>,
        fs: &ProtocolObject<dyn MTLFunction>,
        vd: &MTLVertexDescriptor,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        stride: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        // SAFETY: fixed slot index inside the 31 buffer slots.
        unsafe {
            vd.layouts()
                .objectAtIndexedSubscript(VERTEX_BUFFER_SLOT as usize)
                .setStride(stride)
        };
        let desc = MTLRenderPipelineDescriptor::new();
        desc.setVertexFunction(Some(vs));
        desc.setFragmentFunction(Some(fs));
        desc.setVertexDescriptor(Some(vd));
        desc.setRasterSampleCount(samples.max(1));
        // SAFETY: attachment 0 always exists.
        let color = unsafe { desc.colorAttachments().objectAtIndexedSubscript(0) };
        color.setPixelFormat(format);
        let (src, dst) = match blend {
            Blend::Normal | Blend::Disabled => (None, None),
            Blend::Translucent => (
                Some(MTLBlendFactor::SourceAlpha),
                Some(MTLBlendFactor::OneMinusSourceAlpha),
            ),
            Blend::Additive => (Some(MTLBlendFactor::SourceAlpha), Some(MTLBlendFactor::One)),
        };
        if let (Some(src), Some(dst)) = (src, dst) {
            color.setBlendingEnabled(true);
            color.setSourceRGBBlendFactor(src);
            color.setDestinationRGBBlendFactor(dst);
            color.setSourceAlphaBlendFactor(MTLBlendFactor::One);
            color.setDestinationAlphaBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);
        }
        self.device
            .newRenderPipelineStateWithDescriptor_error(&desc)
            .map_err(|e| Error::Metal(format!("pipeline: {}", e.localizedDescription())))
    }
}

fn library(device: &Device, src: &str) -> Result<Retained<ProtocolObject<dyn MTLLibrary>>, Error> {
    let opts = MTLCompileOptions::new();
    // Release-mode math like the original engine's driver compilers.
    opts.setMathMode(MTLMathMode::Fast);
    device
        .newLibraryWithSource_options_error(&NSString::from_str(src), Some(&opts))
        .map_err(|e| Error::Metal(format!("MSL compile: {}", e.localizedDescription())))
}

fn function(
    lib: &ProtocolObject<dyn MTLLibrary>,
    name: &str,
) -> Result<Retained<ProtocolObject<dyn MTLFunction>>, Error> {
    lib.newFunctionWithName(&NSString::from_str(name))
        .ok_or_else(|| Error::Metal(format!("missing function {name}")))
}

/// Intermediate render targets. They live in one Metal heap: a buffer handed back mid-frame is
/// marked aliasable, so the next layer's buffers reuse its memory. The heap is sized to the
/// largest set of buffers alive at the same time, not the sum over layers, and grows only when a
/// frame needs more.
#[derive(Debug, Default)]
pub struct Pool {
    heap: Option<Retained<ProtocolObject<dyn MTLHeap>>>,
    heap_size: usize,
    live: usize,
    peak: usize,
}

impl Pool {
    pub fn take(&mut self, gpu: &Gpu, w: usize, h: usize) -> Result<Retained<Texture>, Error> {
        let desc = texture_descriptor(w, h);
        let need = gpu.device.heapTextureSizeAndAlignWithDescriptor(&desc);
        self.live += need.size;
        self.peak = self.peak.max(self.live);
        if let Some(heap) = &self.heap {
            if heap.maxAvailableSizeWithAlignment(need.align) >= need.size {
                if let Some(t) = heap.newTextureWithDescriptor(&desc) {
                    return Ok(t);
                }
            }
        }
        // Heap too small this frame: allocate standalone; `end_frame` grows the heap.
        gpu.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("render target alloc".into()))
    }

    pub fn give(&mut self, t: Retained<Texture>) {
        let need = t
            .device()
            .heapTextureSizeAndAlignWithDescriptor(&texture_descriptor(t.width(), t.height()));
        self.live = self.live.saturating_sub(need.size);
        if t.heap().is_some() {
            // SAFETY: the texture is not used by any command encoded after this point.
            unsafe { t.makeAliasable() };
        }
    }

    pub fn end_frame(&mut self, gpu: &Gpu) {
        if self.peak > self.heap_size {
            let size = self.peak.next_multiple_of(1 << 20);
            let desc = MTLHeapDescriptor::new();
            desc.setSize(size);
            desc.setStorageMode(MTLStorageMode::Private);
            desc.setHazardTrackingMode(MTLHazardTrackingMode::Tracked);
            self.heap = gpu.device.newHeapWithDescriptor(&desc);
            self.heap_size = if self.heap.is_some() { size } else { 0 };
        }
        self.live = 0;
        self.peak = 0;
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }
}

fn texture_descriptor(w: usize, h: usize) -> Retained<MTLTextureDescriptor> {
    // SAFETY: plain descriptor construction.
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            FBO_FORMAT,
            w.max(1),
            h.max(1),
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    desc.setStorageMode(MTLStorageMode::Private);
    desc
}

/// Begins a render pass on `target`, cleared to `clear` or loaded when `None`.
pub fn begin(
    cb: &CommandBuffer,
    target: &Texture,
    msaa: Option<&Texture>,
    clear: Option<[f64; 4]>,
) -> Result<Retained<Encoder>, Error> {
    let rp = MTLRenderPassDescriptor::new();
    // SAFETY: attachment 0 always exists.
    let att = unsafe { rp.colorAttachments().objectAtIndexedSubscript(0) };
    match msaa {
        Some(ms) => {
            att.setTexture(Some(ms));
            att.setResolveTexture(Some(target));
            // Kept (not memoryless) because layers with effects split the scene into several passes.
            att.setStoreAction(MTLStoreAction::StoreAndMultisampleResolve);
        }
        None => {
            att.setTexture(Some(target));
            att.setStoreAction(MTLStoreAction::Store);
        }
    }
    match clear {
        Some([r, g, b, a]) => {
            att.setLoadAction(MTLLoadAction::Clear);
            att.setClearColor(MTLClearColor {
                red: r,
                green: g,
                blue: b,
                alpha: a,
            });
        }
        None => att.setLoadAction(MTLLoadAction::Load),
    }
    cb.renderCommandEncoderWithDescriptor(&rp)
        .ok_or_else(|| Error::Metal("render encoder".into()))
}

/// Pushes small per-draw data (uniforms, the 4-vertex quad) without allocating buffers.
pub fn set_bytes(enc: &Encoder, vertex: bool, data: &[u8], slot: usize) {
    if data.is_empty() {
        return;
    }
    let Some(ptr) = NonNull::new(data.as_ptr() as *mut c_void) else {
        return;
    };
    // SAFETY: Metal copies `data.len()` bytes immediately; set*Bytes accepts up to 4 KB, and our
    // uniform blocks stay well below that (callers fall back to a buffer above it).
    unsafe {
        if vertex {
            enc.setVertexBytes_length_atIndex(ptr, data.len(), slot);
        } else {
            enc.setFragmentBytes_length_atIndex(ptr, data.len(), slot);
        }
    }
}

pub fn set_buffer_or_bytes(gpu: &Gpu, enc: &Encoder, vertex: bool, data: &[u8], slot: usize) {
    if data.len() <= 4096 {
        set_bytes(enc, vertex, data, slot);
        return;
    }
    let Some(ptr) = NonNull::new(data.as_ptr() as *mut c_void) else {
        return;
    };
    // SAFETY: the buffer copies `data`.
    let buffer = unsafe {
        gpu.device.newBufferWithBytes_length_options(
            ptr,
            data.len(),
            MTLResourceOptions::StorageModeShared,
        )
    };
    if let Some(buffer) = buffer {
        // SAFETY: offset 0 in a buffer we own.
        unsafe {
            if vertex {
                enc.setVertexBuffer_offset_atIndex(Some(&buffer), 0, slot);
            } else {
                enc.setFragmentBuffer_offset_atIndex(Some(&buffer), 0, slot);
            }
        }
    }
}
