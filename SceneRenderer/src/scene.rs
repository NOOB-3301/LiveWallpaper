//! `scene.json` and the model/material/effect files it points to, reduced to what the renderer draws.

use std::collections::{BTreeMap, HashMap};

use serde_json::Value;

use crate::vfs::Vfs;
use crate::Error;

/// A value that a user property may override: `{"user": "name", "value": v}` or
/// `{"user": {"name": "name", "condition": "1"}, "value": v}` (a combo-property comparison).
#[derive(Debug, Clone)]
pub struct Bound {
    pub value: Value,
    pub user: Option<String>,
    pub condition: Option<String>,
}

/// A JSON object whose fields may be user bindings (`{"user": .., "value": ..}`), with each one
/// replaced by what the user set, or its default. Used for overrides, which are read as plain values.
pub fn resolve_user_values(value: &Value, props: &HashMap<String, Value>) -> Value {
    let Some(map) = value.as_object() else {
        return value.clone();
    };
    let resolved = map
        .iter()
        .map(|(key, field)| {
            let field = match field.as_object() {
                Some(inner) if inner.contains_key("value") || inner.contains_key("user") => {
                    Bound::parse(Some(field), Value::Null).get(props)
                }
                _ => field.clone(),
            };
            (key.clone(), field)
        })
        .collect();
    Value::Object(resolved)
}

impl Bound {
    #[cfg(test)]
    pub fn parse_for_test(v: Option<&Value>, default: Value) -> Self {
        Self::parse(v, default)
    }

    fn parse(v: Option<&Value>, default: Value) -> Self {
        let Some(v) = v else {
            return Self {
                value: default,
                user: None,
                condition: None,
            };
        };
        let Some(obj) = v
            .as_object()
            .filter(|o| o.contains_key("user") || o.contains_key("value") || o.contains_key("script"))
        else {
            return Self {
                value: v.clone(),
                user: None,
                condition: None,
            };
        };
        let value = obj.get("value").cloned().unwrap_or(default);
        let (user, condition) = match obj.get("user") {
            Some(Value::String(s)) => (Some(s.clone()), None),
            Some(Value::Object(u)) => (
                u.get("name").and_then(Value::as_str).map(str::to_string),
                u.get("condition")
                    .map(|c| c.as_str().map_or_else(|| c.to_string(), str::to_string)),
            ),
            _ => (None, None),
        };
        Self {
            value,
            user,
            condition,
        }
    }

    /// The effective value given the current user property values.
    pub fn get(&self, props: &HashMap<String, Value>) -> Value {
        let Some(p) = self.user.as_ref().and_then(|u| props.get(u)) else {
            return self.value.clone();
        };
        match &self.condition {
            Some(cond) => {
                let current = p.as_str().map_or_else(|| p.to_string(), str::to_string);
                Value::Bool(&current == cond)
            }
            None => p.clone(),
        }
    }

    pub fn truthy(&self, props: &HashMap<String, Value>) -> bool {
        truthy(&self.get(props))
    }
}

/// An image's `alignment` as the shift from its origin to its centre, in sizes, y down.
pub fn alignment(name: &str) -> [f32; 2] {
    let name = name.to_ascii_lowercase();
    let x = if name.contains("left") {
        0.5
    } else if name.contains("right") {
        -0.5
    } else {
        0.0
    };
    let y = if name.contains("top") {
        0.5
    } else if name.contains("bottom") {
        -0.5
    } else {
        0.0
    };
    [x, y]
}

pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty() && s != "0" && s != "false",
        _ => false,
    }
}

/// Numbers from `1.0`, `"1 2 3"` or `[1, 2, 3]`.
pub fn floats(v: &Value) -> Vec<f32> {
    match v {
        Value::Number(n) => vec![n.as_f64().unwrap_or(0.0) as f32],
        Value::Bool(b) => vec![f32::from(u8::from(*b))],
        // Shader defaults and some scene values separate components with commas: "0.0, 1.0".
        Value::String(s) => s
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter_map(|x| x.parse().ok())
            .collect(),
        Value::Array(a) => a.iter().flat_map(floats).collect(),
        Value::Object(o) => o.get("value").map(floats).unwrap_or_default(),
        Value::Null => Vec::new(),
    }
}

fn vec_n<const N: usize>(v: Option<&Value>, default: [f32; N]) -> [f32; N] {
    let f = v.map(floats).unwrap_or_default();
    let mut out = default;
    for (o, x) in out.iter_mut().zip(f) {
        *o = x;
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Blend {
    Normal,
    Translucent,
    Additive,
    Disabled,
}

impl Blend {
    fn parse(s: Option<&str>) -> Self {
        match s.unwrap_or("translucent") {
            "normal" => Self::Normal,
            "additive" => Self::Additive,
            "disabled" => Self::Disabled,
            _ => Self::Translucent,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Material {
    pub shader: String,
    pub blend: Blend,
    /// Texture names by slot; `None` keeps the shader default or the bound render target.
    pub textures: Vec<Option<String>>,
    pub combos: BTreeMap<String, i64>,
    /// `constantshadervalues`, keyed by the uniform annotation's `material` name.
    pub constants: HashMap<String, Bound>,
}

impl Material {
    pub(crate) fn load(vfs: &Vfs, path: &str) -> Result<Self, Error> {
        let json = vfs.json(path)?;
        let pass = &json["passes"][0];
        let mut m = Self {
            shader: pass["shader"]
                .as_str()
                .unwrap_or("genericimage2")
                .to_string(),
            blend: Blend::parse(pass["blending"].as_str()),
            textures: Vec::new(),
            combos: BTreeMap::new(),
            constants: HashMap::new(),
        };
        m.apply_overrides(pass);
        Ok(m)
    }

    /// Applies a pass object's `textures`, `combos` and `constantshadervalues` on top.
    fn apply_overrides(&mut self, pass: &Value) {
        if let Some(textures) = pass["textures"].as_array() {
            for (i, t) in textures.iter().enumerate() {
                if let Some(name) = t.as_str() {
                    if self.textures.len() <= i {
                        self.textures.resize(i + 1, None);
                    }
                    self.textures[i] = Some(name.to_string());
                }
            }
        }
        if let Some(combos) = pass["combos"].as_object() {
            for (k, v) in combos {
                let _ = self
                    .combos
                    .insert(k.clone(), floats(v).first().copied().unwrap_or(0.0) as i64);
            }
        }
        if let Some(values) = pass["constantshadervalues"].as_object() {
            for (k, v) in values {
                let _ = self
                    .constants
                    .insert(k.clone(), Bound::parse(Some(v), Value::Null));
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct EffectPass {
    pub material: Material,
    pub target: Option<String>,
    /// (render target name or `previous`, texture slot).
    pub binds: Vec<(String, usize)>,
}

#[derive(Debug, Clone)]
pub struct Fbo {
    pub name: String,
    pub scale: f32,
}

#[derive(Debug, Clone)]
pub struct Effect {
    pub name: String,
    pub visible: Bound,
    pub passes: Vec<EffectPass>,
    pub fbos: Vec<Fbo>,
}

/// A text object's own fields; placement, colour and effects come from the layer.
#[derive(Debug, Clone)]
pub struct TextLayer {
    /// A package font path (`fonts/...otf`) or a system family name.
    pub font: String,
    pub point_size: f32,
    pub horizontal_align: String,
    pub vertical_align: String,
    pub padding: f32,
    /// The static value; scripts would replace it every tick.
    pub value: String,
}

/// A particle object: the system JSON to simulate and its per-instance overrides.
#[derive(Debug, Clone)]
pub struct ParticleLayer {
    pub system: String,
    pub instance_override: Option<Value>,
}

/// One animation layer of a puppet, as the scene object lists it.
#[derive(Debug, Clone)]
pub struct PuppetAnimation {
    pub id: i64,
    /// `rate`, `blend` and `visible` may follow user properties like the rest of the scene.
    pub rate: Bound,
    pub blend: Bound,
    pub additive: bool,
    pub visible: Bound,
}

/// A puppet object: the model file and the animations that move it.
#[derive(Debug, Clone)]
pub struct PuppetLayer {
    pub model: String,
    pub animations: Vec<PuppetAnimation>,
}

#[derive(Debug, Clone)]
pub struct Layer {
    pub id: i64,
    pub name: String,
    pub parent: Option<i64>,
    /// Named attachment point of a puppet parent the layer follows.
    pub attachment: Option<String>,
    pub origin: Bound,
    pub scale: Bound,
    pub angles: Bound,
    pub size: [f32; 2],
    /// Where `origin` sits on an image, as a shift of the image centre in sizes (y down):
    /// `bottomleft` is `[0.5, -0.5]`, `center` is zero.
    pub alignment: [f32; 2],
    pub parallax_depth: Bound,
    pub alpha: Bound,
    pub color: Bound,
    pub brightness: f32,
    pub visible: Bound,
    /// Group objects only position their children.
    pub material: Option<Material>,
    /// Set for text objects; such layers have no material and are drawn from a bitmap.
    pub text: Option<TextLayer>,
    /// Set for particle objects; such layers have no material of their own.
    pub particles: Option<ParticleLayer>,
    /// Set for puppet models; the layer keeps its material but draws a skinned mesh.
    pub puppet: Option<PuppetLayer>,
    pub effects: Vec<Effect>,
}

/// A script on one value of a scene object, e.g. `{"script": "...", "value": ...}` under `text`.
#[derive(Debug, Clone)]
pub struct ScriptSpec {
    pub layer_id: i64,
    /// Path of the value inside the object: `origin`, `text`, `instanceoverride.rate`, ...
    pub field: String,
    pub source: String,
    /// The `scriptproperties` the scene stores for this script.
    pub properties: Value,
}

/// Collects every `{"script": ...}` value under a scene object.
fn find_scripts(layer_id: i64, path: &str, v: &Value, out: &mut Vec<ScriptSpec>) {
    match v {
        Value::Object(map) => {
            if let Some(source) = map.get("script").and_then(Value::as_str) {
                out.push(ScriptSpec {
                    layer_id,
                    field: path.to_string(),
                    source: source.to_string(),
                    properties: map.get("scriptproperties").cloned().unwrap_or(Value::Null),
                });
                return;
            }
            for (k, child) in map {
                let p = if path.is_empty() { k.clone() } else { format!("{path}.{k}") };
                find_scripts(layer_id, &p, child, out);
            }
        }
        Value::Array(items) => {
            for (i, child) in items.iter().enumerate() {
                find_scripts(layer_id, &format!("{path}[{i}]"), child, out);
            }
        }
        _ => {}
    }
}

/// The scene's camera parallax settings, as authored (each may follow a user property).
#[derive(Debug, Clone)]
pub struct Parallax {
    pub enabled: Bound,
    pub amount: Bound,
    pub delay: Bound,
    pub mouse_influence: Bound,
}

/// Camera shake settings, as authored (each may follow a user property).
#[derive(Debug, Clone)]
pub struct CameraShake {
    pub enabled: Bound,
    pub amplitude: Bound,
    pub roughness: Bound,
    pub speed: Bound,
}

impl CameraShake {
    /// (amplitude, roughness, speed) in effect, or `None` while the shake is off.
    pub fn now(&self, props: &HashMap<String, Value>) -> Option<[f32; 3]> {
        if !self.enabled.truthy(props) {
            return None;
        }
        let num = |b: &Bound, d: f32| floats(&b.get(props)).first().copied().unwrap_or(d);
        Some([num(&self.amplitude, 0.5), num(&self.roughness, 1.0), num(&self.speed, 3.0)])
    }
}

/// Camera parallax with the user's property values applied.
#[derive(Debug, Clone, Copy)]
pub struct ParallaxNow {
    pub amount: f32,
    pub delay: f32,
    pub mouse_influence: f32,
}

impl Parallax {
    /// The settings in effect, or `None` while camera parallax is off.
    pub fn now(&self, props: &HashMap<String, Value>) -> Option<ParallaxNow> {
        if !self.enabled.truthy(props) {
            return None;
        }
        let num = |b: &Bound, d: f32| floats(&b.get(props)).first().copied().unwrap_or(d);
        Some(ParallaxNow {
            amount: num(&self.amount, 0.5),
            delay: num(&self.delay, 0.1),
            mouse_influence: num(&self.mouse_influence, 1.0),
        })
    }
}

/// Scene-wide glow around bright parts, from `general`.
#[derive(Debug, Clone)]
pub struct Bloom {
    pub enabled: Bound,
    pub strength: Bound,
    pub threshold: Bound,
    pub tint: Bound,
}

#[derive(Debug, Clone)]
pub struct Scene {
    /// SceneScript programs attached to object values, in file order.
    pub scripts: Vec<ScriptSpec>,
    pub sounds: Vec<crate::sound::SoundSpec>,
    pub bloom: Bloom,
    pub width: f32,
    pub height: f32,
    pub clear_color: Bound,
    pub parallax: Parallax,
    pub shake: CameraShake,
    pub layers: Vec<Layer>,
    /// Object kinds this renderer does not draw yet, with counts (reported as load warnings).
    pub skipped: BTreeMap<String, usize>,
}

impl Scene {
    pub fn load(vfs: &Vfs, warnings: &mut Vec<String>) -> Result<Self, Error> {
        let json = vfs.json("scene.json")?;
        let general = &json["general"];
        let ortho = &general["orthogonalprojection"];
        let width = ortho["width"].as_f64().unwrap_or(1920.0) as f32;
        let height = ortho["height"].as_f64().unwrap_or(1080.0) as f32;
        // Every one of these may be bound to a user property, like the scene's own sliders.
        let parallax = Parallax {
            enabled: Bound::parse(general.get("cameraparallax"), Value::Bool(false)),
            amount: Bound::parse(general.get("cameraparallaxamount"), Value::from(0.5)),
            delay: Bound::parse(general.get("cameraparallaxdelay"), Value::from(0.1)),
            // Scenes that never touched the slider leave it out; full influence is the default.
            mouse_influence: Bound::parse(general.get("cameraparallaxmouseinfluence"), Value::from(1.0)),
        };
        let mut scene = Self {
            width,
            height,
            clear_color: Bound::parse(general.get("clearcolor"), Value::from("0 0 0")),
            parallax,
            shake: CameraShake {
                enabled: Bound::parse(general.get("camerashake"), Value::Bool(false)),
                amplitude: Bound::parse(general.get("camerashakeamplitude"), Value::from(0.5)),
                roughness: Bound::parse(general.get("camerashakeroughness"), Value::from(1.0)),
                speed: Bound::parse(general.get("camerashakespeed"), Value::from(3.0)),
            },
            layers: Vec::new(),
            skipped: BTreeMap::new(),
            scripts: Vec::new(),
            sounds: Vec::new(),
            bloom: Bloom {
                enabled: Bound::parse(general.get("bloom"), Value::Bool(false)),
                strength: Bound::parse(general.get("bloomstrength"), Value::from(2.0)),
                threshold: Bound::parse(general.get("bloomthreshold"), Value::from(0.65)),
                tint: Bound::parse(general.get("bloomtint"), Value::from("1 1 1")),
            },
        };
        for obj in json["objects"].as_array().into_iter().flatten() {
            find_scripts(obj["id"].as_i64().unwrap_or(-1), "", obj, &mut scene.scripts);
            let kind = ["image", "particle", "text", "sound", "light", "model"]
                .into_iter()
                .find(|k| obj.get(*k).is_some_and(|v| !v.is_null()));
            match kind {
                Some("image") | Some("text") | Some("particle") | None => {
                    match Self::layer(vfs, obj, kind.is_none(), warnings) {
                        Ok(layer) => scene.layers.push(layer),
                        Err(e) => warnings.push(format!(
                            "layer {}: {e}",
                            obj["name"].as_str().unwrap_or("?")
                        )),
                    }
                }
                Some("sound") => scene.sounds.extend(crate::sound::SoundSpec::parse(obj)),
                Some(other) => *scene.skipped.entry(other.to_string()).or_default() += 1,
            }
        }
        // An auto projection is as big as the largest image (the reference renderer's rule); the
        // fixed 1920x1080 would crop or letterbox such a scene.
        if ortho["auto"].as_bool() == Some(true) || width <= 0.0 || height <= 0.0 {
            let area = |l: &&Layer| l.size[0] * l.size[1];
            if let Some(l) = scene.layers.iter().max_by(|a, b| area(a).total_cmp(&area(b))).filter(|l| area(l) > 0.0) {
                (scene.width, scene.height) = (l.size[0], l.size[1]);
            }
        }
        Ok(scene)
    }

    /// One drawable object; also used for layers a script creates at run time.
    pub fn layer(
        vfs: &Vfs,
        obj: &Value,
        group: bool,
        warnings: &mut Vec<String>,
    ) -> Result<Layer, Error> {
        let name = obj["name"].as_str().unwrap_or("").to_string();
        let text = obj
            .get("text")
            .filter(|v| !v.is_null())
            .map(|t| TextLayer {
                font: obj["font"].as_str().unwrap_or("Helvetica").to_string(),
                point_size: obj["pointsize"].as_f64().unwrap_or(32.0) as f32,
                horizontal_align: obj["horizontalalign"]
                    .as_str()
                    .unwrap_or("left")
                    .to_string(),
                vertical_align: obj["verticalalign"].as_str().unwrap_or("top").to_string(),
                padding: obj["padding"].as_f64().unwrap_or(0.0) as f32,
                value: t["value"].as_str().unwrap_or("").to_string(),
            });
        let particles = obj
            .get("particle")
            .and_then(Value::as_str)
            .map(|system| ParticleLayer {
                system: system.to_string(),
                instance_override: obj
                    .get("instanceoverride")
                    .filter(|v| !v.is_null())
                    .cloned(),
            });
        let mut puppet = None;
        let material = if group || text.is_some() || particles.is_some() {
            None
        } else {
            let model = vfs.json(obj["image"].as_str().unwrap_or(""))?;
            if let Some(path) = model["puppet"].as_str() {
                let animations = obj["animationlayers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|a| PuppetAnimation {
                        id: a["animation"].as_i64().unwrap_or(-1),
                        rate: Bound::parse(a.get("rate"), Value::from(1.0)),
                        blend: Bound::parse(a.get("blend"), Value::from(1.0)),
                        additive: a["additive"].as_bool().unwrap_or(false),
                        visible: Bound::parse(a.get("visible"), Value::Bool(true)),
                    })
                    .collect();
                puppet = Some(PuppetLayer {
                    model: path.to_string(),
                    animations,
                });
            }
            let path = model["material"]
                .as_str()
                .ok_or_else(|| Error::Format("model has no material".into()))?;
            let mut material = Material::load(vfs, path)?;
            // The layer's colour blend mode blends it with what is behind it (reads the frame).
            if let Some(mode) = obj["colorBlendMode"].as_i64().filter(|&m| m != 0) {
                let _ = material.combos.insert("BLENDMODE".into(), mode);
            }
            Some(material)
        };
        let mut effects = Vec::new();
        for e in obj["effects"].as_array().into_iter().flatten() {
            match Self::effect(vfs, e) {
                Ok(effect) => effects.push(effect),
                Err(err) => {
                    warnings.push(format!("layer {name}: effect {} skipped: {err}", e["file"]))
                }
            }
        }
        Ok(Layer {
            id: obj["id"].as_i64().unwrap_or(-1),
            name,
            parent: obj["parent"].as_i64(),
            attachment: obj["attachment"].as_str().filter(|a| !a.is_empty()).map(str::to_string),
            origin: Bound::parse(obj.get("origin"), Value::String("0 0 0".into())),
            scale: Bound::parse(obj.get("scale"), Value::String("1 1 1".into())),
            angles: Bound::parse(obj.get("angles"), Value::String("0 0 0".into())),
            size: vec_n(obj.get("size"), [0.0, 0.0]),
            // Text lays itself out in its box; only images are anchored by `alignment`.
            alignment: if text.is_some() {
                [0.0; 2]
            } else {
                alignment(obj["alignment"].as_str().unwrap_or(""))
            },
            parallax_depth: Bound::parse(obj.get("parallaxDepth"), Value::from("0 0")),
            alpha: Bound::parse(obj.get("alpha"), Value::from(1.0)),
            color: Bound::parse(obj.get("color"), Value::String("1 1 1".into())),
            brightness: floats(obj.get("brightness").unwrap_or(&Value::from(1.0)))
                .first()
                .copied()
                .unwrap_or(1.0),
            visible: Bound::parse(obj.get("visible"), Value::Bool(true)),
            material,
            text,
            particles,
            puppet,
            effects,
        })
    }

    fn effect(vfs: &Vfs, obj: &Value) -> Result<Effect, Error> {
        let file = obj["file"].as_str().unwrap_or("");
        let json = vfs.json(file)?;
        let overrides = obj["passes"].as_array().cloned().unwrap_or_default();
        let mut passes = Vec::new();
        for (i, p) in json["passes"].as_array().into_iter().flatten().enumerate() {
            let path = p["material"]
                .as_str()
                .ok_or_else(|| Error::Format("effect pass has no material".into()))?;
            let mut material = Material::load(vfs, path)?;
            if let Some(o) = overrides.get(i) {
                material.apply_overrides(o);
            }
            let binds = p["bind"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|b| {
                    Some((
                        b["name"].as_str()?.to_string(),
                        b["index"].as_u64()? as usize,
                    ))
                })
                .collect();
            passes.push(EffectPass {
                material,
                target: p["target"].as_str().map(str::to_string),
                binds,
            });
        }
        let fbos = json["fbos"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|f| {
                Some(Fbo {
                    name: f["name"].as_str()?.to_string(),
                    scale: f["scale"].as_f64().unwrap_or(1.0) as f32,
                })
            })
            .collect();
        Ok(Effect {
            name: json["name"].as_str().unwrap_or(file).to_string(),
            visible: Bound::parse(obj.get("visible"), Value::Bool(true)),
            passes,
            fbos,
        })
    }
}

/// A user property from `project.json` (`general.properties`).
#[derive(Debug, Clone)]
pub struct Property {
    pub name: String,
    pub kind: String,
    pub label: String,
    pub value: Value,
    pub order: i64,
}

pub fn project_properties(project: &Value) -> Vec<Property> {
    let mut out: Vec<Property> = project["general"]["properties"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(name, p)| Property {
            name: name.clone(),
            kind: p["type"].as_str().unwrap_or("").to_string(),
            label: p["text"].as_str().unwrap_or(name).to_string(),
            value: p["value"].clone(),
            order: p["order"].as_i64().unwrap_or(0),
        })
        .collect();
    out.sort_by_key(|p| p.order);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn bound_values_follow_user_properties() {
        let props: HashMap<String, Value> = [
            ("bg".to_string(), json!("2")),
            ("on".to_string(), json!(false)),
        ]
        .into();
        let combo = Bound::parse(
            Some(&json!({"user": {"name": "bg", "condition": "1"}, "value": true})),
            Value::Null,
        );
        assert!(!combo.truthy(&props));
        let plain = Bound::parse(Some(&json!({"user": "on", "value": true})), Value::Null);
        assert!(!plain.truthy(&props));
        let fixed = Bound::parse(Some(&json!("1 2 3")), Value::Null);
        assert_eq!(floats(&fixed.get(&props)), vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn comma_separated_values_keep_every_component() {
        assert_eq!(floats(&json!("0.0, 1.0")), vec![0.0, 1.0]);
        assert_eq!(floats(&json!("0.05,0.00")), vec![0.05, 0.0]);
    }
}
