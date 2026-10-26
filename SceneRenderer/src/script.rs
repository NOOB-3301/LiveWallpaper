//! SceneScript: the JavaScript a scene attaches to object values (clock text, audio-driven
//! scale, visualiser bars). One QuickJS runtime per scene runs every script; the environment the
//! scripts see is `script_prelude.js`. All traffic between Rust and JavaScript is JSON text, once
//! per script at load and once per frame, which keeps this file free of per-type bindings.

use std::cell::RefCell;
use std::rc::Rc;

use rquickjs::loader::{BuiltinLoader, BuiltinResolver};
use rquickjs::{CatchResultExt, Context, Function, Module, Object, Runtime};
use serde_json::{Map, Value};

use crate::Error;

const PRELUDE: &str = include_str!("script_prelude.js");

/// Helper modules a script may import by name: module name, prelude object, exported names.
const MODULES: [(&str, &str, &[&str]); 3] = [
    (
        "WEMath",
        "__WEMath",
        &[
            "PI",
            "deg2rad",
            "rad2deg",
            "clamp",
            "mix",
            "lerp",
            "smoothStep",
            "fract",
        ],
    ),
    (
        "WEVector",
        "__WEVector",
        &["Vec2", "Vec3", "Vec4", "angleVector2", "vectorAngle2"],
    ),
    (
        "WEColor",
        "__WEColor",
        &["rgb2hsv", "hsv2rgb", "normalizeColor", "expandColor"],
    ),
];

/// A layer a script created with `thisScene.createLayer`.
#[derive(Debug, Clone)]
pub struct Created {
    pub id: i64,
    pub path: String,
    /// The `__workshopId` of the creating script: its asset paths live under `workshop/<id>/`.
    pub workshop: String,
}

/// What scripts changed since the last call.
#[derive(Debug, Default)]
pub struct Events {
    /// New value of a scripted field, by script id.
    pub values: Vec<(usize, Value)>,
    /// Layer fields set through `thisLayer` / `thisScene` objects, by layer id.
    pub dirty: Vec<(i64, Map<String, Value>)>,
    /// Scene settings (`thisScene.bloom` and the like) written by scripts, by documented name.
    pub scene: Map<String, Value>,
    pub created: Vec<Created>,
    /// Draw-order moves: layer id, new index.
    pub moves: Vec<(i64, usize)>,
}

impl Events {
    fn parse(text: &str) -> Self {
        let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
        let values = v["values"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((k.parse().ok()?, v.clone())))
            .collect();
        let dirty = v["dirty"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((k.parse().ok()?, v.as_object()?.clone())))
            .collect();
        let scene = v["scene"].as_object().cloned().unwrap_or_default();
        let created = v["created"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| {
                Some(Created {
                    id: c["id"].as_i64()?,
                    path: c["path"].as_str()?.to_string(),
                    workshop: c["workshop"].as_str().unwrap_or("").to_string(),
                })
            })
            .collect();
        let moves = v["moves"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| Some((m["id"].as_i64()?, m["index"].as_u64()? as usize)))
            .collect();
        Self {
            values,
            dirty,
            scene,
            created,
            moves,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
            && self.dirty.is_empty()
            && self.scene.is_empty()
            && self.created.is_empty()
            && self.moves.is_empty()
    }
}

/// Per-frame input to the scripts.
#[derive(Debug, Clone)]
pub struct FrameState {
    pub time: f32,
    pub frame_time: f32,
    /// Fraction of the local day, 0..1.
    pub time_of_day: f32,
    pub screen: [f32; 2],
    pub canvas: [f32; 2],
    /// Pointer in screen pixels and in scene units.
    pub cursor: [f32; 2],
    pub cursor_world: [f32; 2],
    /// Left button held.
    pub cursor_down: bool,
    /// Audio spectrum, 0..1 per band, any band count.
    pub left: Vec<f32>,
    pub right: Vec<f32>,
    /// Video textures this frame: (layer id, playhead seconds, playing).
    pub videos: Vec<(i64, f64, bool)>,
}

pub struct Host {
    // Field order matters: the context must drop before its runtime.
    ctx: Context,
    _rt: Runtime,
    log: Rc<RefCell<Vec<String>>>,
    count: usize,
}

impl std::fmt::Debug for Host {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Host")
            .field("scripts", &self.count)
            .finish()
    }
}

fn js(e: impl std::fmt::Display) -> Error {
    Error::Unsupported(format!("script: {e}"))
}

impl Host {
    pub fn new() -> Result<Self, Error> {
        let rt = Runtime::new().map_err(js)?;
        // Scene scripts are small; these bounds stop a runaway script from taking the process.
        rt.set_memory_limit(64 << 20);
        rt.set_max_stack_size(1 << 20);
        let mut resolver = BuiltinResolver::default();
        let mut loader = BuiltinLoader::default();
        for (name, global, exports) in MODULES {
            // Named exports one by one: QuickJS drops destructured `export const { .. } = m`.
            let mut source = format!("const m = globalThis.{global};\nexport default m;\n");
            for e in exports {
                source.push_str(&format!("export const {e} = m.{e};\n"));
            }
            resolver.add_module(name);
            loader.add_module(name, source);
        }
        rt.set_loader(resolver, loader);
        let ctx = Context::full(&rt).map_err(js)?;
        let log = Rc::new(RefCell::new(Vec::new()));
        let sink = log.clone();
        ctx.with(|ctx| -> Result<(), Error> {
            let f = Function::new(ctx.clone(), move |s: String| {
                let mut l = sink.borrow_mut();
                // Keep the log bounded: a script logging every frame must not grow memory.
                if l.len() < 64 {
                    l.push(s);
                }
            })
            .map_err(js)?;
            ctx.globals().set("__lw_log", f).map_err(js)?;
            ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(js)?;
            Ok(())
        })?;
        Ok(Self {
            ctx,
            _rt: rt,
            log,
            count: 0,
        })
    }

    /// Replaces the scripts' view of the scene's layers (draw order, current values).
    pub fn set_layers(&mut self, layers: &Value) -> Result<(), Error> {
        let text = layers.to_string();
        self.call("__lw_layers", text).map(|_| ())
    }

    /// Evaluates one script module and runs its `init`. Returns the events it caused, with the
    /// script's starting value under its id.
    pub fn add(
        &mut self,
        id: usize,
        layer_id: i64,
        field: &str,
        source: &str,
        properties: &Value,
        value: &Value,
    ) -> Result<Events, Error> {
        self.count += 1;
        let props = if properties.is_object() {
            properties.to_string()
        } else {
            "{}".into()
        };
        let out = self.ctx.with(|ctx| -> Result<String, Error> {
            let begin: Function = ctx.globals().get("__lw_begin").map_err(js)?;
            begin
                .call::<_, ()>((layer_id, props))
                .catch(&ctx)
                .map_err(js)?;
            let name = format!("layer{layer_id}/{field}");
            let module = Module::declare(ctx.clone(), name, source)
                .catch(&ctx)
                .map_err(js)?;
            let (module, done) = module.eval().catch(&ctx).map_err(js)?;
            done.finish::<()>().catch(&ctx).map_err(js)?;
            let ns: Object = module.namespace().catch(&ctx).map_err(js)?;
            let register: Function = ctx.globals().get("__lw_register").map_err(js)?;
            register
                .call::<_, String>((id, ns, layer_id, field, value.to_string()))
                .catch(&ctx)
                .map_err(js)
        })?;
        Ok(Events::parse(&out))
    }

    /// Runs every script's `update` for one frame.
    pub fn frame(&mut self, s: &FrameState) -> Result<Events, Error> {
        let videos: Map<String, Value> = s
            .videos
            .iter()
            .map(|(id, time, playing)| (id.to_string(), serde_json::json!([time, playing])))
            .collect();
        let input = serde_json::json!({
            "time": s.time,
            "dt": s.frame_time,
            "tod": s.time_of_day,
            "screen": s.screen,
            "canvas": s.canvas,
            "cursor": s.cursor,
            "cursorWorld": s.cursor_world,
            "down": s.cursor_down,
            "left": s.left,
            "right": s.right,
            "videos": videos,
        });
        let out = self.call("__lw_frame", input.to_string())?;
        Ok(Events::parse(&out))
    }

    /// Whether any script wants to run every frame.
    pub fn animated(&self) -> bool {
        self.ctx.with(|ctx| {
            ctx.globals()
                .get::<_, Function>("__lw_animated")
                .and_then(|f| f.call::<_, bool>(()))
                .unwrap_or(false)
        })
    }

    /// Messages scripts printed, and errors they threw, since the last call.
    pub fn take_log(&mut self) -> Vec<String> {
        std::mem::take(&mut *self.log.borrow_mut())
    }

    fn call(&self, name: &str, arg: String) -> Result<String, Error> {
        self.ctx.with(|ctx| {
            let f: Function = ctx.globals().get(name).map_err(js)?;
            f.call::<_, String>((arg,)).catch(&ctx).map_err(js)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn host_with_layer() -> Host {
        let mut h = Host::new().expect("runtime");
        h.set_layers(
            &json!([{ "id": 7, "name": "clock", "origin": "10 20 0", "scale": "1 1 1",
            "angles": "0 0 0", "color": "1 1 1", "alpha": 1.0, "visible": true, "text": "" }]),
        )
        .expect("layers");
        h
    }

    fn frame(h: &mut Host, time: f32) -> Events {
        h.frame(&FrameState {
            time,
            frame_time: 1.0 / 30.0,
            time_of_day: 0.5,
            screen: [1920.0, 1080.0],
            canvas: [1920.0, 1080.0],
            cursor: [0.0, 0.0],
            cursor_world: [0.0, 0.0],
            cursor_down: false,
            left: vec![1.0; 64],
            right: vec![0.0; 64],
            videos: vec![],
        })
        .expect("frame")
    }

    #[test]
    fn a_text_script_returns_its_value_and_reads_its_properties() {
        let mut h = host_with_layer();
        let src = "'use strict';\n\
            export var scriptProperties = createScriptProperties()\n\
              .addText({ name: 'delimiter', value: ':' }).finish();\n\
            export function update(value) { return 'a' + scriptProperties.delimiter + 'b'; }";
        let e = h
            .add(0, 7, "text", src, &json!({ "delimiter": "-" }), &json!("x"))
            .expect("add");
        assert_eq!(e.values, vec![(0, json!("x"))]);
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!("a-b"))]);
    }

    #[test]
    fn scene_settings_written_by_scripts_are_reported() {
        let mut h = host_with_layer();
        let src = "export function init() { thisScene.bloomstrength = 3; thisScene.clearcolor = '0.1 0.2 0.3'; }";
        let e = h
            .add(0, 7, "alpha", src, &Value::Null, &json!(1))
            .expect("add");
        assert_eq!(e.scene.get("bloomstrength"), Some(&json!(3)));
        assert_eq!(e.scene.get("clearcolor"), Some(&json!("0.1 0.2 0.3")));
    }

    #[test]
    fn a_vector_value_round_trips_as_text() {
        let mut h = host_with_layer();
        let src = "export function update(value) { return value.multiply(2); }";
        let _ = h
            .add(0, 7, "scale", src, &Value::Null, &json!("1 2 3"))
            .expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!("2 4 6"))]);
    }

    #[test]
    fn layer_writes_and_created_layers_are_reported() {
        let mut h = host_with_layer();
        let src = "let bar;\n\
            export function init() { bar = thisScene.createLayer('models/bar.json');\n\
              thisScene.sortLayer(bar, 0); }\n\
            export function update() { thisLayer.origin = new Vec3(1, 2, 3); bar.alpha = 0.5; }";
        let e = h
            .add(0, 7, "visible", src, &Value::Null, &json!(true))
            .expect("add");
        assert_eq!(e.created.len(), 1);
        assert_eq!(e.created[0].path, "models/bar.json");
        assert_eq!(e.moves, vec![(e.created[0].id, 0)]);
        let e = frame(&mut h, 1.0);
        let origin = e
            .dirty
            .iter()
            .find(|(id, _)| *id == 7)
            .map(|(_, d)| d["origin"].clone());
        assert_eq!(origin, Some(json!("1 2 3")));
        assert!(e
            .dirty
            .iter()
            .any(|(_, d)| d.get("alpha") == Some(&json!(0.5))));
        assert!(e.values.is_empty());
    }

    #[test]
    fn audio_buffers_follow_the_spectrum() {
        let mut h = host_with_layer();
        let src = "const a = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);\n\
            export function update() { return a.left[3] + a.average[3]; }";
        let _ = h
            .add(0, 7, "alpha", src, &Value::Null, &json!(0))
            .expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(1.5))]);
    }

    #[test]
    fn a_throwing_script_is_disabled_and_logged() {
        let mut h = host_with_layer();
        let src = "export function update() { throw new Error('boom'); }";
        let _ = h
            .add(0, 7, "alpha", src, &Value::Null, &json!(1))
            .expect("add");
        let _ = frame(&mut h, 1.0);
        assert!(h.take_log().iter().any(|l| l.contains("boom")));
        assert!(!h.animated());
    }

    #[test]
    fn a_layer_is_dragged_by_cursor_events() {
        let mut h = host_with_layer();
        let src = "let drag = false, off;\n\
            export function cursorDown(e) { drag = true; off = thisLayer.origin.subtract(e.worldPosition); }\n\
            export function cursorUp(e) { drag = false; }\n\
            export function cursorMove(e) { if (drag) thisLayer.origin = e.worldPosition.add(off); }";
        let _ = h
            .add(0, 7, "origin", src, &Value::Null, &json!("10 20 0"))
            .expect("add");
        let at = |h: &mut Host, x: f32, y: f32, down: bool| {
            h.frame(&FrameState {
                time: 1.0,
                frame_time: 1.0 / 30.0,
                time_of_day: 0.5,
                screen: [1920.0, 1080.0],
                canvas: [1920.0, 1080.0],
                cursor: [0.0, 0.0],
                cursor_world: [x, y],
                cursor_down: down,
                left: vec![],
                right: vec![],
                videos: vec![],
            })
            .expect("frame")
        };
        // A press away from the layer (it has no size, so only its origin hits) moves nothing.
        let e = at(&mut h, 500.0, 500.0, true);
        assert!(e.dirty.is_empty(), "{:?}", h.take_log());
        let _ = at(&mut h, 500.0, 500.0, false);
        // Press on it, drag by (5, 5), release.
        let _ = at(&mut h, 10.0, 20.0, true);
        let e = at(&mut h, 15.0, 25.0, true);
        let origin = e
            .dirty
            .iter()
            .find(|(id, _)| *id == 7)
            .map(|(_, d)| d["origin"].clone());
        assert_eq!(origin, Some(json!("15 25 0")), "{:?}", h.take_log());
        let _ = at(&mut h, 15.0, 25.0, false);
        let e = at(&mut h, 99.0, 99.0, false);
        assert!(e.dirty.is_empty());
    }

    #[test]
    fn helper_modules_can_be_imported() {
        let mut h = host_with_layer();
        let src = "import * as WEMath from 'WEMath';\n\
            export function update() { return WEMath.clamp(5, 0, 1); }";
        let _ = h
            .add(0, 7, "alpha", src, &Value::Null, &json!(0))
            .expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(1))], "{:?}", h.take_log());
    }
}
