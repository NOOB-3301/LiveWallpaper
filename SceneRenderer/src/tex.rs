//! `.tex` decoding. Block-compressed data (DXT1/3/5) is returned as stored so it stays compressed
//! on the GPU: a 4K DXT5 layer is 16 MB instead of 64 MB as RGBA.

use crate::vfs::Reader;
use crate::Error;

const MAX_DIM: i32 = 16_384;
const MAX_MIP_BYTES: usize = 512 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Rgba8,
    Rg8,
    R8,
    Bc1,
    Bc2,
    Bc3,
}

impl Format {
    fn from_raw(raw: i32) -> Self {
        match raw {
            4 => Self::Bc3,
            6 => Self::Bc2,
            7 => Self::Bc1,
            8 => Self::Rg8,
            9 => Self::R8,
            _ => Self::Rgba8,
        }
    }

    pub fn bytes(self, w: usize, h: usize) -> usize {
        let blocks = w.div_ceil(4).max(1) * h.div_ceil(4).max(1);
        match self {
            Self::Rgba8 => w * h * 4,
            Self::Rg8 => w * h * 2,
            Self::R8 => w * h,
            Self::Bc1 => blocks * 8,
            Self::Bc2 | Self::Bc3 => blocks * 16,
        }
    }

    pub fn row_bytes(self, w: usize) -> usize {
        self.bytes(w, if self.is_block() { 4 } else { 1 })
    }

    pub fn is_block(self) -> bool {
        matches!(self, Self::Bc1 | Self::Bc2 | Self::Bc3)
    }
}

#[derive(Debug, Clone)]
pub struct Mip {
    pub width: usize,
    pub height: usize,
    pub data: Vec<u8>,
}

/// One sprite-sheet frame, in texture pixels. `(width_x, width_y)` and `(height_x, height_y)` are the
/// frame's edge vectors, so frames can be stored rotated in the sheet.
#[derive(Debug, Clone, Copy)]
pub struct Frame {
    pub image: usize,
    pub seconds: f32,
    pub x: f32,
    pub y: f32,
    pub width_x: f32,
    pub width_y: f32,
    pub height_x: f32,
    pub height_y: f32,
}

#[derive(Debug, Clone)]
pub struct Tex {
    pub texture_width: usize,
    pub texture_height: usize,
    pub image_width: usize,
    pub image_height: usize,
    pub format: Format,
    pub clamp: bool,
    pub nearest: bool,
    /// Mip chains, one per image. Sprite sheets may have several images.
    pub images: Vec<Vec<Mip>>,
    pub frames: Vec<Frame>,
    /// A video texture: the movie file bytes (mp4) instead of images.
    pub video: Option<Vec<u8>>,
}

pub fn decode(data: &[u8]) -> Result<Tex, Error> {
    let mut r = Reader::new(data);
    let (v, i) = (r.cstring()?, r.cstring()?);
    if !v.starts_with("TEXV") || !i.starts_with("TEXI") {
        return Err(Error::Format("not a .tex file".into()));
    }
    let format_raw = r.i32()?;
    let flags = r.u32()?;
    let mut dims = [0usize; 4];
    for d in &mut dims {
        let x = r.i32()?;
        if !(0..=MAX_DIM).contains(&x) {
            return Err(Error::Format("texture size is out of range".into()));
        }
        *d = x as usize;
    }
    let _ = r.u32()?;
    let container = r.cstring()?;
    let version: u32 = container
        .strip_prefix("TEXB")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if !(1..=4).contains(&version) {
        return Err(Error::Format(format!(
            "unknown texture container {container}"
        )));
    }
    let image_count = r.u32()? as usize;
    if !(1..=64).contains(&image_count) {
        return Err(Error::Format("texture image count is out of range".into()));
    }
    let mut image_format = -1;
    let mut mp4 = 0;
    if version >= 3 {
        image_format = r.i32()?;
    }
    if version >= 4 {
        mp4 = r.i32()?;
    }
    // The three signatures of a video texture: its one "mip" holds a movie file.
    let video =
        flags & 32 != 0 || image_format == 35 || (version >= 4 && mp4 == 1 && image_format == -1);

    let mut format = Format::from_raw(format_raw);
    let mut images = Vec::with_capacity(image_count);
    for _ in 0..image_count {
        let mip_count = r.u32()? as usize;
        if !(1..=16).contains(&mip_count) {
            return Err(Error::Format("texture mip count is out of range".into()));
        }
        let mut mips = Vec::with_capacity(mip_count);
        for _ in 0..mip_count {
            let (w, h) = (r.i32()?, r.i32()?);
            if !(0..=MAX_DIM).contains(&w) || !(0..=MAX_DIM).contains(&h) {
                return Err(Error::Format("mip size is out of range".into()));
            }
            let (mut lz4, mut raw_size) = (false, 0);
            if version >= 2 {
                lz4 = r.u32()? == 1;
                raw_size = r.u32()? as usize;
            }
            let n = r.u32()? as usize;
            let bytes = r.bytes(n)?;
            let bytes = if lz4 {
                lz4_block(bytes, raw_size)?
            } else {
                bytes.to_vec()
            };
            mips.push(Mip {
                width: w as usize,
                height: h as usize,
                data: bytes,
            });
        }
        images.push(mips);
    }

    // A video: the first mip is the movie file, and nothing else follows that concerns us.
    if video {
        let file = images
            .first()
            .and_then(|m| m.first())
            .map(|m| m.data.clone())
            .unwrap_or_default();
        return Ok(Tex {
            texture_width: dims[0],
            texture_height: dims[1],
            image_width: dims[2].min(dims[0]),
            image_height: dims[3].min(dims[1]),
            format: Format::Rgba8,
            clamp: flags & 2 != 0,
            nearest: flags & 1 != 0,
            images: Vec::new(),
            frames: Vec::new(),
            video: Some(file),
        });
    }

    // Embedded PNG/JPEG: decode the first mip of each image to RGBA; the GPU builds no extra mips.
    if image_format >= 0 {
        for mips in &mut images {
            let first = mips.swap_remove(0);
            let img = image::load_from_memory(&first.data)
                .map_err(|e| Error::Format(format!("texture image: {e}")))?;
            let rgba = img.into_rgba8();
            *mips = vec![Mip {
                width: rgba.width() as usize,
                height: rgba.height() as usize,
                data: rgba.into_raw(),
            }];
        }
        format = Format::Rgba8;
    }
    for mip in images.iter().flatten() {
        if mip.data.len() < format.bytes(mip.width, mip.height) {
            return Err(Error::Format("mip data is smaller than its size".into()));
        }
    }

    let frames = if flags & 4 != 0 {
        read_frames(&mut r).unwrap_or_default()
    } else {
        Vec::new()
    };
    // The header may name a padded size (4096x4096) while the stored mip is only the image
    // (3840x2160); uvs are fractions of what the GPU actually holds, so trust the mip.
    let (texture_width, texture_height) = images
        .first()
        .and_then(|m| m.first())
        .map_or((dims[0], dims[1]), |m| (m.width, m.height));
    Ok(Tex {
        texture_width,
        texture_height,
        image_width: dims[2].min(texture_width),
        image_height: dims[3].min(texture_height),
        format,
        clamp: flags & 2 != 0,
        nearest: flags & 1 != 0,
        images,
        frames,
        video: None,
    })
}

fn read_frames(r: &mut Reader<'_>) -> Result<Vec<Frame>, Error> {
    let magic = r.cstring()?;
    let count = r.u32()? as usize;
    if !magic.starts_with("TEXS") || count > 4096 {
        return Ok(Vec::new());
    }
    if magic == "TEXS0003" {
        let _ = (r.u32()?, r.u32()?);
    }
    let old = magic == "TEXS0001";
    let num = |r: &mut Reader<'_>| -> Result<f32, Error> {
        if old {
            Ok(r.i32()? as f32)
        } else {
            r.f32()
        }
    };
    (0..count)
        .map(|_| {
            let image = r.u32()? as usize;
            let seconds = r.f32()?;
            let (x, y, width_x, width_y, height_x, height_y) =
                (num(r)?, num(r)?, num(r)?, num(r)?, num(r)?, num(r)?);
            Ok(Frame {
                image,
                seconds,
                x,
                y,
                width_x,
                width_y,
                height_x,
                height_y,
            })
        })
        .collect()
}

/// LZ4 block format (no frame header), bounds-checked on both buffers.
pub fn lz4_block(src: &[u8], size: usize) -> Result<Vec<u8>, Error> {
    if size > MAX_MIP_BYTES {
        return Err(Error::Format("LZ4 block is too large".into()));
    }
    let bad = || Error::Format("corrupt LZ4 block".into());
    let mut out = Vec::with_capacity(size);
    let mut i = 0;
    let byte = |i: &mut usize| -> Result<usize, Error> {
        let b = *src.get(*i).ok_or_else(bad)?;
        *i += 1;
        Ok(b as usize)
    };
    while out.len() < size {
        let token = byte(&mut i)?;
        let mut lit = token >> 4;
        if lit == 15 {
            loop {
                let b = byte(&mut i)?;
                lit += b;
                if b != 255 {
                    break;
                }
            }
        }
        let lits = src.get(i..i + lit).ok_or_else(bad)?;
        if out.len() + lit > size {
            return Err(bad());
        }
        out.extend_from_slice(lits);
        i += lit;
        if out.len() >= size {
            break;
        }
        let offset = byte(&mut i)? | byte(&mut i)? << 8;
        if offset == 0 || offset > out.len() {
            return Err(bad());
        }
        let mut len = token & 15;
        if len == 15 {
            loop {
                let b = byte(&mut i)?;
                len += b;
                if b != 255 {
                    break;
                }
            }
        }
        len += 4;
        if out.len() + len > size {
            return Err(bad());
        }
        let start = out.len() - offset;
        // Matches may overlap their own output, so copy byte by byte.
        for k in 0..len {
            out.push(out[start + k]);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lz4_literal_and_overlapping_match() {
        // "ab" literal, then a match of offset 2, length 6 -> "abababab".
        let block = [0x22, b'a', b'b', 2, 0, 0x00];
        assert_eq!(lz4_block(&block[..5], 8).unwrap(), b"abababab");
    }

    #[test]
    fn texture_size_is_the_stored_mip_not_the_padded_header() {
        // Header says 8x8 holding a 4x2 image, but only a 4x2 mip is stored (Dressing Room
        // is 4096x4096 over 3840x2160): uvs must be fractions of the 4x2 the GPU gets.
        let mut f = b"TEXV0005\0TEXI0001\0".to_vec();
        for v in [0i32, 0, 8, 8, 4, 2, 0] {
            f.extend(v.to_le_bytes());
        }
        f.extend(b"TEXB0001\0");
        for v in [1u32, 1, 4, 2, 32] {
            f.extend(v.to_le_bytes());
        }
        f.extend([0u8; 32]);
        let t = decode(&f).unwrap();
        assert_eq!((t.texture_width, t.texture_height), (4, 2));
        assert_eq!((t.image_width, t.image_height), (4, 2));
    }

    #[test]
    fn lz4_rejects_bad_offset() {
        assert!(lz4_block(&[0x10, b'a', 9, 0], 8).is_err());
    }

    #[test]
    fn a_video_tex_yields_the_movie_file() {
        // TEXB0004 with flag 32 set: one "mip" holding a fake movie file.
        let mut f = b"TEXV0005\0TEXI0001\0".to_vec();
        for v in [0i32, 32, 3840, 2160, 3840, 2160, 0] {
            f.extend(v.to_le_bytes());
        }
        f.extend(b"TEXB0004\0");
        for v in [1u32, 0xffff_ffffu32, 0, 1, 3840, 2160, 0, 0, 8] {
            f.extend(v.to_le_bytes());
        }
        f.extend(*b"12345678");
        let t = decode(&f).unwrap();
        assert!(t.images.is_empty());
        assert_eq!(t.video.as_deref(), Some(&b"12345678"[..]));
        assert_eq!((t.texture_width, t.texture_height), (3840, 2160));
    }
}
