// The SceneScript environment: the globals a scene script expects, written for this renderer.
// The API surface (names and behaviour) follows Wallpaper Engine's public SceneScript
// documentation and the scripts found in real scenes. The host talks to this file through the
// `__lw_*` functions only, always with JSON strings.
'use strict';

function __num(v, d) {
	const n = Number(v);
	return Number.isFinite(n) ? n : d;
}

class Vec2 {
	constructor(x, y) {
		if (x !== null && typeof x === 'object') { y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
	}
	copy() { return new Vec2(this.x, this.y); }
	add(o) { o = __vec2(o); return new Vec2(this.x + o.x, this.y + o.y); }
	subtract(o) { o = __vec2(o); return new Vec2(this.x - o.x, this.y - o.y); }
	multiply(o) { o = __vec2(o); return new Vec2(this.x * o.x, this.y * o.y); }
	divide(o) { o = __vec2(o); return new Vec2(this.x / o.x, this.y / o.y); }
	dot(o) { o = __vec2(o); return this.x * o.x + this.y * o.y; }
	length() { return Math.sqrt(this.x * this.x + this.y * this.y); }
	lengthSqr() { return this.x * this.x + this.y * this.y; }
	normalize() { const l = this.length(); return l > 0 ? new Vec2(this.x / l, this.y / l) : new Vec2(0, 0); }
	mix(o, t) { o = __vec2(o); return new Vec2(this.x + (o.x - this.x) * t, this.y + (o.y - this.y) * t); }
	perpendicular() { return new Vec2(-this.y, this.x); }
	reflect(n) { n = __vec2(n); const d = 2 * this.dot(n); return new Vec2(this.x - d * n.x, this.y - d * n.y); }
	equals(o) { o = __vec2(o); return this.x === o.x && this.y === o.y; }
	toString() { return `${this.x} ${this.y}`; }
	static fromString(s) { const p = String(s).trim().split(/\s+/).map(Number); return new Vec2(p[0], p[1] === undefined ? p[0] : p[1]); }
}

class Vec3 {
	constructor(x, y, z) {
		if (x !== null && typeof x === 'object') { z = x.z; y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
		this.z = z === undefined ? (y === undefined ? this.x : 0) : __num(z, 0);
	}
	copy() { return new Vec3(this.x, this.y, this.z); }
	add(o) { o = __vec3(o); return new Vec3(this.x + o.x, this.y + o.y, this.z + o.z); }
	subtract(o) { o = __vec3(o); return new Vec3(this.x - o.x, this.y - o.y, this.z - o.z); }
	multiply(o) { o = __vec3(o); return new Vec3(this.x * o.x, this.y * o.y, this.z * o.z); }
	divide(o) { o = __vec3(o); return new Vec3(this.x / o.x, this.y / o.y, this.z / o.z); }
	dot(o) { o = __vec3(o); return this.x * o.x + this.y * o.y + this.z * o.z; }
	cross(o) { o = __vec3(o); return new Vec3(this.y * o.z - this.z * o.y, this.z * o.x - this.x * o.z, this.x * o.y - this.y * o.x); }
	length() { return Math.sqrt(this.lengthSqr()); }
	lengthSqr() { return this.x * this.x + this.y * this.y + this.z * this.z; }
	normalize() { const l = this.length(); return l > 0 ? new Vec3(this.x / l, this.y / l, this.z / l) : new Vec3(0, 0, 0); }
	mix(o, t) { o = __vec3(o); return new Vec3(this.x + (o.x - this.x) * t, this.y + (o.y - this.y) * t, this.z + (o.z - this.z) * t); }
	reflect(n) { n = __vec3(n); const d = 2 * this.dot(n); return new Vec3(this.x - d * n.x, this.y - d * n.y, this.z - d * n.z); }
	equals(o) { o = __vec3(o); return this.x === o.x && this.y === o.y && this.z === o.z; }
	toString() { return `${this.x} ${this.y} ${this.z}`; }
	static fromString(s) { const p = String(s).trim().split(/\s+/).map(Number); return new Vec3(p[0], p[1] === undefined ? p[0] : p[1], p[2] === undefined ? (p[1] === undefined ? p[0] : 0) : p[2]); }
}

class Vec4 {
	constructor(x, y, z, w) {
		if (x !== null && typeof x === 'object') { w = x.w; z = x.z; y = x.y; x = x.x; }
		this.x = __num(x, 0);
		this.y = y === undefined ? this.x : __num(y, 0);
		this.z = z === undefined ? this.x : __num(z, 0);
		this.w = w === undefined ? this.x : __num(w, 0);
	}
	copy() { return new Vec4(this.x, this.y, this.z, this.w); }
	toString() { return `${this.x} ${this.y} ${this.z} ${this.w}`; }
}

function __vec2(o) { return typeof o === 'number' ? new Vec2(o, o) : o; }
function __vec3(o) { return typeof o === 'number' ? new Vec3(o, o, o) : o; }

globalThis.Vec2 = Vec2;
globalThis.Vec3 = Vec3;
globalThis.Vec4 = Vec4;

// Scene values arrive as strings ("1 2 3"); scripts see vectors for the vector fields.
const __vecFields = { origin: 3, scale: 3, angles: 3, color: 3, parallaxDepth: 2 };
function __toScript(field, v) {
	const last = field.split('.').pop();
	const n = __vecFields[last] || (/^color/.test(last) ? 3 : 0);
	if (n && typeof v === 'string') return n === 2 ? Vec2.fromString(v) : Vec3.fromString(v);
	return v;
}
function __fromScript(v) {
	if (v instanceof Vec2 || v instanceof Vec3 || v instanceof Vec4) return v.toString();
	if (Array.isArray(v)) return v.join(' ');
	return v;
}

// --- user properties declared by a script -------------------------------------------------

let __overrides = {};
function __override(name, fallback) {
	if (!Object.prototype.hasOwnProperty.call(__overrides, name)) return fallback;
	const v = __overrides[name];
	return v !== null && typeof v === 'object' && 'value' in v ? v.value : v;
}

class ScriptProperties {
	constructor() { this.__defs = []; }
	__add(def, value) { this.__defs.push(def); this[def.name] = __override(def.name, value); return this; }
	addCheckbox(d) { return this.__add(d, !!d.value); }
	addSlider(d) { return this.__add(d, __num(d.value, 0)); }
	addCombo(d) { return this.__add(d, d.value !== undefined ? d.value : (d.options && d.options.length ? d.options[0].value : '')); }
	addText(d) { return this.__add(d, d.value === undefined ? '' : String(d.value)); }
	addTextInput(d) { return this.addText(d); }
	addColor(d) { return this.__add(d, d.value instanceof Vec3 ? d.value : Vec3.fromString(d.value || '1 1 1')); }
	addFile(d) { return this.__add(d, d.value || ''); }
	addDirectory(d) { return this.__add(d, d.value || ''); }
	finish() {
		const out = {};
		for (const d of this.__defs) {
			let v = this[d.name];
			if (d.integer && typeof v === 'number') v = Math.round(v);
			if (d.name && /^color/i.test(d.name) && typeof v === 'string') v = Vec3.fromString(v);
			out[d.name] = v;
		}
		return out;
	}
}
globalThis.createScriptProperties = () => new ScriptProperties();

// --- layers -------------------------------------------------------------------------------

const __layers = new Map();   // id -> Layer
let __order = [];             // ids in draw order
const __dirty = new Map();    // id -> {field: value}
const __created = [];         // {id, path, workshop}
const __moves = [];           // {id, index}
let __nextId = 1 << 30;

function __mark(layer, field, value) {
	let d = __dirty.get(layer.id);
	if (!d) { d = {}; __dirty.set(layer.id, d); }
	d[field] = __fromScript(value);
}

// Stands in for an animation or texture-sheet handle the renderer does not drive yet.
function __noopAnimation() {
	let frame = 0;
	return {
		play() {}, pause() {}, stop() {}, isPlaying() { return false; },
		getFrame() { return frame; }, setFrame(f) { frame = Math.trunc(__num(f, 0)); },
	};
}

// IVideoTexture: the host drives the movie; commands travel as `video:*` writes on the layer and
// the playhead and duration come back in the layer state each frame.
class VideoTexture {
	constructor(layer) { this._layer = layer; this._volume = 1; this._looping = undefined; }
	play() { __mark(this._layer, 'video:play', true); }
	pause() { __mark(this._layer, 'video:pause', true); }
	stop() { __mark(this._layer, 'video:stop', true); }
	restart() { this.setCurrentTime(0); this.play(); }
	isPlaying() { return !!this._layer._s.videoPlaying; }
	get playing() { return this.isPlaying(); }
	get duration() { return __num(this._layer._s.videoDuration, 0); }
	getDuration() { return this.duration; }
	getCurrentTime() { return __num(this._layer._s.videoTime, 0); }
	setCurrentTime(t) { __mark(this._layer, 'video:time', __num(t, 0)); }
	get rate() { return __num(this._layer._s.videoRate, 1); }
	set rate(v) { __mark(this._layer, 'video:rate', __num(v, 1)); }
	get speed() { return this.rate; }
	set speed(v) { this.rate = v; }
	get volume() { return this._volume; }
	set volume(v) { this._volume = Math.max(0, Math.min(1, __num(v, 1))); }
	getVolume() { return this._volume; }
	setVolume(v) { this.volume = v; }
	get looping() { return this._looping === undefined ? this._layer._s.videoLooping !== false : this._looping; }
	set looping(v) { this._looping = !!v; __mark(this._layer, 'video:loop', !!v); }
	isLooping() { return this.looping; }
	setLooping(v) { this.looping = v; }
	get width() { return this._layer.size.x; }
	get height() { return this._layer.size.y; }
	getWidth() { return this.width; }
	getHeight() { return this.height; }
	getName() { return this._layer.name; }
}

class Layer {
	constructor(s) { this._s = s; }
	get id() { return this._s.id; }
	get name() { return this._s.name; }
	get debug() { return false; }
	get size() { return Vec2.fromString(this._s.size || '0 0'); }
	get origin() { return Vec3.fromString(this._s.origin); }
	set origin(v) { this._s.origin = __fromScript(__vec3(v)); __mark(this, 'origin', this._s.origin); }
	get scale() { return Vec3.fromString(this._s.scale); }
	set scale(v) { this._s.scale = __fromScript(__vec3(v)); __mark(this, 'scale', this._s.scale); }
	get angles() { return Vec3.fromString(this._s.angles); }
	set angles(v) { this._s.angles = __fromScript(__vec3(v)); __mark(this, 'angles', this._s.angles); }
	get color() { return Vec3.fromString(this._s.color); }
	set color(v) { this._s.color = __fromScript(__vec3(v)); __mark(this, 'color', this._s.color); }
	get alpha() { return __num(this._s.alpha, 1); }
	set alpha(v) { this._s.alpha = __num(v, 1); __mark(this, 'alpha', this._s.alpha); }
	get visible() { return !!this._s.visible; }
	set visible(v) { this._s.visible = !!v; __mark(this, 'visible', this._s.visible); }
	get text() { return this._s.text || ''; }
	set text(v) { this._s.text = String(v); __mark(this, 'text', this._s.text); }
	get parallaxDepth() { return Vec2.fromString(this._s.parallaxDepth || '0 0'); }
	set parallaxDepth(v) { this._s.parallaxDepth = __fromScript(__vec2(v)); __mark(this, 'parallaxDepth', this._s.parallaxDepth); }
	// Kept for scripts that set it; this renderer centres layers on their origin.
	get alignment() { return this._s.alignment || 'center'; }
	set alignment(v) { this._s.alignment = String(v); }
	getEffectCount() { return (this._s.effects || []).length; }
	getEffect(key) {
		const list = this._s.effects || [];
		const index = typeof key === 'number' ? key : list.findIndex((e) => e.name === key);
		return index >= 0 && index < list.length ? new Effect(this, index, list[index]) : null;
	}
	getParent() { return this._s.parent === undefined || this._s.parent === null ? null : (__layers.get(this._s.parent) || null); }
	// Playback is not driven from scripts yet; the stubs keep scripts that call them from throwing.
	getAnimation() { return __noopAnimation(); }
	getTextureAnimation() { return __noopAnimation(); }
	// A stand-in video handle: it carries the commands to the renderer, which has the real movie.
	getVideoTexture() { return new VideoTexture(this); }
	play() {}
	pause() {}
	stop() {}
	isPlaying() { return true; }
}

// IEffect: one material effect on a layer. `visible` is applied by the renderer each frame.
class Effect {
	constructor(layer, index, s) { this._layer = layer; this._index = index; this._s = s; }
	get name() { return this._s.name || ''; }
	get visible() { return this._s.visible !== false; }
	set visible(v) { this._s.visible = !!v; __mark(this._layer, `effect:${this._index}:visible`, this._s.visible); }
}

// ITextLayer and IImageLayer fields from the WE docs. Each write is sent to the renderer, which
// applies the ones it supports; the rest are stored so scripts that set them keep running.
const __layerFields = {
	pointsize: 0, font: '', padding: 0, horizontalalign: 'center', verticalalign: 'center',
	opaquebackground: false, backgroundcolor: '0 0 0', limitwidth: false, maxwidth: 0,
	limitrows: false, maxrows: 0, anchor: 'none', perspective: false, solid: false,
};
for (const [field, fallback] of Object.entries(__layerFields)) {
	Object.defineProperty(Layer.prototype, field, {
		get() { return this._s[field] === undefined ? fallback : this._s[field]; },
		set(v) { this._s[field] = v; __mark(this, field, v); },
	});
}

// IScene properties from the WE docs. The renderer does not read these yet; they are kept on the
// scene so scripts that set them keep running.
const __sceneFields = {
	bloom: false, bloomstrength: 2, bloomthreshold: 0.65, clearenabled: true, clearcolor: '0 0 0',
	ambientcolor: '0.3 0.3 0.3', skylightcolor: '0.3 0.3 0.3', fov: 50, nearz: 0.01, farz: 10000,
	camerafade: true, camerashake: false, camerashakespeed: 3, camerashakeamplitude: 0.5,
	camerashakeroughness: 1, cameraparallax: false, cameraparallaxamount: 0.5,
	cameraparallaxdelay: 0.1, cameraparallaxmouseinfluence: 0.5,
};
const __sceneValues = { ...__sceneFields };
const __sceneDirty = {};       // scene fields written since the last flush

const thisScene = {
	getLayer(key) {
		if (typeof key === 'number') return __layers.get(__order[key]) || null;
		for (const id of __order) { const l = __layers.get(id); if (l && l.name === key) return l; }
		return null;
	},
	getLayerIndex(layer) { return layer ? __order.indexOf(layer.id) : -1; },
	getLayerCount() { return __order.length; },
	enumerateLayers() { return __order.map((id) => __layers.get(id)).filter(Boolean); },
	createLayer(src) {
		const path = typeof src === 'string' ? src : (src && (src.image || src.path)) || '';
		const id = __nextId++;
		const base = typeof src === 'object' && src ? src : {};
		const s = {
			id, name: base.name || path, origin: __fromScript(base.origin || '0 0 0'), scale: __fromScript(base.scale || '1 1 1'),
			angles: __fromScript(base.angles || '0 0 0'), color: '1 1 1', alpha: 1, visible: true, text: '', size: '0 0',
		};
		const layer = new Layer(s);
		__layers.set(id, layer);
		__order.push(id);
		__created.push({ id, path, workshop: __currentWorkshop });
		return layer;
	},
	destroyLayer(layer) {
		if (!layer) return;
		layer.visible = false;
	},
	sortLayer(layer, index) {
		if (!layer) return;
		const from = __order.indexOf(layer.id);
		if (from < 0) return;
		__order.splice(from, 1);
		const to = Math.max(0, Math.min(__order.length, Math.trunc(__num(index, __order.length))));
		__order.splice(to, 0, layer.id);
		__moves.push({ id: layer.id, index: to });
	},
	getCameraTransforms() { return { eye: new Vec3(0, 0, 0), center: new Vec3(0, 0, -1), up: new Vec3(0, 1, 0) }; },
	clearColor: new Vec3(0, 0, 0),
	bloom: false,
};
for (const field of Object.keys(__sceneFields)) {
	Object.defineProperty(thisScene, field, {
		get() { return __sceneValues[field]; },
		set(v) { __sceneValues[field] = v; __sceneDirty[field] = __fromScript(v); },
	});
}
globalThis.thisScene = thisScene;
globalThis.thisLayer = null;

// --- engine, input, audio -----------------------------------------------------------------

const __audio = [];
const engine = {
	frametime: 0,
	runtime: 0,
	timeOfDay: 0,
	screenResolution: new Vec2(1920, 1080),
	canvasSize: new Vec2(1920, 1080),
	userProperties: {},
	AUDIO_RESOLUTION_16: 16,
	AUDIO_RESOLUTION_32: 32,
	AUDIO_RESOLUTION_64: 64,
	registerAudioBuffers(resolution) {
		const n = [16, 32, 64].includes(resolution) ? resolution : 16;
		const b = { resolution: n, left: new Float32Array(n), right: new Float32Array(n), average: new Float32Array(n) };
		__audio.push(b);
		return b;
	},
	isDesktopDevice() { return true; },
	isMobileDevice() { return false; },
	isWallpaper() { return true; },
	isScreensaver() { return false; },
	isRunningInEditor() { return false; },
	isPortrait() { return this.screenResolution.y > this.screenResolution.x; },
	isLandscape() { return !this.isPortrait(); },
	openUserShortcut() {},
	setTimeout(fn, ms) { __timers.push({ at: engine.runtime + __num(ms, 0) / 1000, fn, every: 0 }); },
	setInterval(fn, ms) { const every = Math.max(__num(ms, 0) / 1000, 0.001); __timers.push({ at: engine.runtime + every, fn, every }); },
};
const __timers = [];
globalThis.engine = engine;

const input = {
	cursorWorldPosition: new Vec3(0, 0, 0),
	cursorScreenPosition: new Vec2(0, 0),
	cursorLeftDown: false,
};
globalThis.input = input;

globalThis.shared = {};

const __store = new Map();
globalThis.localStorage = {
	get(k) { return __store.has(k) ? __store.get(k) : undefined; },
	set(k, v) { __store.set(k, v); },
	delete(k) { __store.delete(k); },
	clear() { __store.clear(); },
	LOCATION_GLOBAL: 0,
	LOCATION_SCREEN: 1,
};

globalThis.console = {
	log(...a) { __lw_log(a.map(String).join(' ')); },
	info(...a) { __lw_log(a.map(String).join(' ')); },
	warn(...a) { __lw_log(a.map(String).join(' ')); },
	error(...a) { __lw_log(a.map(String).join(' ')); },
};

// Helper modules some scripts import by name.
globalThis.__WEMath = {
	PI: Math.PI,
	deg2rad: Math.PI / 180,
	rad2deg: 180 / Math.PI,
	clamp: (v, a, b) => Math.min(Math.max(v, a), b),
	mix: (a, b, t) => a + (b - a) * t,
	lerp: (a, b, t) => a + (b - a) * t,
	smoothStep: (a, b, v) => { const t = Math.min(Math.max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t); },
	fract: (v) => v - Math.floor(v),
};
globalThis.__WEVector = {
	Vec2, Vec3, Vec4,
	// Direction for an angle in degrees: x = cos, y = sin.
	angleVector2: (angle) => { const r = __num(angle, 0) * Math.PI / 180; return new Vec2(Math.cos(r), Math.sin(r)); },
	// Angle in degrees of a direction, counter-clockwise from +x.
	vectorAngle2: (direction) => { const d = __vec2(direction); return Math.atan2(d.y, d.x) * 180 / Math.PI; },
};
globalThis.__WEColor = {
	rgb2hsv(c) {
		c = __vec3(c);
		const max = Math.max(c.x, c.y, c.z), min = Math.min(c.x, c.y, c.z), d = max - min;
		let h = 0;
		if (d > 0) {
			if (max === c.x) h = ((c.y - c.z) / d) % 6;
			else if (max === c.y) h = (c.z - c.x) / d + 2;
			else h = (c.x - c.y) / d + 4;
			h /= 6; if (h < 0) h += 1;
		}
		return new Vec3(h, max > 0 ? d / max : 0, max);
	},
	hsv2rgb(c) {
		c = __vec3(c);
		const h = (c.x % 1 + 1) % 1 * 6, s = c.y, v = c.z, i = Math.floor(h), f = h - i;
		const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
		return [new Vec3(v, t, p), new Vec3(q, v, p), new Vec3(p, v, t), new Vec3(p, q, v), new Vec3(t, p, v), new Vec3(v, p, q)][i % 6];
	},
	normalizeColor(c) { c = __vec3(c); return new Vec3(c.x / 255, c.y / 255, c.z / 255); },
	expandColor(c) { c = __vec3(c); return new Vec3(c.x * 255, c.y * 255, c.z * 255); },
};

// --- host interface -----------------------------------------------------------------------

const __scripts = [];
let __currentWorkshop = '';

// Replaces the layer table, e.g. after a property change rebuilt the scene.
globalThis.__lw_layers = function (json) {
	const list = JSON.parse(json);
	__order = list.map((s) => s.id);
	for (const s of list) {
		const l = __layers.get(s.id);
		if (l) Object.assign(l._s, s); else __layers.set(s.id, new Layer(s));
	}
	return '';
};

// Called before a script module is evaluated: its layer and its stored properties.
globalThis.__lw_begin = function (layerId, propsJson) {
	globalThis.thisLayer = __layers.get(layerId) || null;
	__overrides = JSON.parse(propsJson) || {};
};

globalThis.__lw_register = function (id, ns, layerId, field, valueJson) {
	const s = {
		id, ns, field, layer: __layers.get(layerId) || null, failed: false,
		value: __toScript(field, JSON.parse(valueJson)),
	};
	__currentWorkshop = ns.__workshopId ? String(ns.__workshopId) : '';
	globalThis.thisLayer = s.layer;
	if (typeof ns.init === 'function') {
		try {
			const r = ns.init(s.value);
			if (r !== undefined) s.value = r;
		} catch (e) {
			s.failed = true;
			__lw_log(`script ${field}: init: ${e}`);
		}
	}
	__currentWorkshop = '';
	__scripts.push(s);
	return __takeEvents({ values: { [id]: __fromScript(s.value) } });
};

function __takeEvents(out) {
	out.dirty = {};
	for (const [id, d] of __dirty) out.dirty[id] = d;
	__dirty.clear();
	out.scene = { ...__sceneDirty };
	for (const k of Object.keys(__sceneDirty)) delete __sceneDirty[k];
	out.created = __created.splice(0);
	out.moves = __moves.splice(0);
	return JSON.stringify(out);
}

function __fill(buffer, src) {
	const n = buffer.length, m = src.length || 1;
	for (let i = 0; i < n; i++) {
		const a = Math.floor((i * m) / n), b = Math.max(a + 1, Math.floor(((i + 1) * m) / n));
		let sum = 0;
		for (let k = a; k < b; k++) sum += src[k] || 0;
		buffer[i] = sum / (b - a);
	}
}

// The layer's box in scene units: its origin and scale carried through its parents (rotation
// is ignored, which is enough to tell whether the pointer is over it).
// shortcut: camera parallax offsets are not included, so a click on a moved layer can miss by up
// to 3% of the scene; send each layer's offset in the frame input if a clickable scene needs it.
function __contains(layer, p) {
	let o = layer.origin, s = layer.scale;
	for (let q = layer.getParent(); q; q = q.getParent()) {
		const qs = q.scale, qo = q.origin;
		o = new Vec3(qo.x + o.x * qs.x, qo.y + o.y * qs.y, 0);
		s = new Vec3(s.x * qs.x, s.y * qs.y, 1);
	}
	const size = layer.size;
	return Math.abs(p.x - o.x) <= Math.abs(size.x * s.x) / 2 && Math.abs(p.y - o.y) <= Math.abs(size.y * s.y) / 2;
}

let __wasDown = false;
let __pressed = [];

function __send(s, name, event) {
	if (s.failed || typeof s.ns[name] !== 'function') return;
	globalThis.thisLayer = s.layer;
	try { s.ns[name](event); } catch (e) { __lw_log(`script ${s.field}: ${name}: ${e}`); }
}

// cursorDown/cursorUp/cursorClick go to scripts whose layer is under the pointer when the button
// is pressed; cursorMove goes to every script, so a drag keeps following the pointer.
function __cursorEvents(down) {
	const event = { worldPosition: input.cursorWorldPosition, screenPosition: input.cursorScreenPosition };
	input.cursorLeftDown = down;
	if (down && !__wasDown) {
		__pressed = __scripts.filter((s) => s.layer && s.layer.visible && __contains(s.layer, event.worldPosition));
		for (const s of __pressed) __send(s, 'cursorDown', event);
	}
	for (const s of __scripts) __send(s, 'cursorMove', event);
	if (!down && __wasDown) {
		for (const s of __pressed) {
			__send(s, 'cursorUp', event);
			if (__contains(s.layer, event.worldPosition)) __send(s, 'cursorClick', event);
		}
		__pressed = [];
	}
	__wasDown = down;
}

globalThis.__lw_frame = function (json) {
	const f = JSON.parse(json);
	engine.frametime = f.dt;
	engine.runtime = f.time;
	engine.timeOfDay = f.tod;
	engine.screenResolution = new Vec2(f.screen[0], f.screen[1]);
	engine.canvasSize = new Vec2(f.canvas[0], f.canvas[1]);
	input.cursorScreenPosition = new Vec2(f.cursor[0], f.cursor[1]);
	input.cursorWorldPosition = new Vec3(f.cursorWorld[0], f.cursorWorld[1], 0);
	// Video playheads, as { layer id: [seconds, playing] }.
	if (f.videos) {
		for (const key in f.videos) {
			const l = __layers.get(Number(key));
			if (!l) continue;
			const v = f.videos[key];
			l._s.videoTime = __num(v[0], 0);
			l._s.videoPlaying = !!v[1];
		}
	}
	__cursorEvents(!!f.down);
	for (const b of __audio) {
		__fill(b.left, f.left);
		__fill(b.right, f.right);
		for (let i = 0; i < b.resolution; i++) b.average[i] = (b.left[i] + b.right[i]) / 2;
	}
	for (let i = 0; i < __timers.length; i++) {
		const t = __timers[i];
		if (engine.runtime < t.at) continue;
		try { t.fn(); } catch (e) { __lw_log(`timer: ${e}`); }
		if (t.every > 0) t.at += t.every; else { __timers.splice(i, 1); i--; }
	}
	const values = {};
	for (const s of __scripts) {
		if (s.failed || typeof s.ns.update !== 'function') continue;
		globalThis.thisLayer = s.layer;
		try {
			const r = s.ns.update(s.value);
			if (r !== undefined) {
				s.value = r;
				values[s.id] = __fromScript(r);
			}
		} catch (e) {
			s.failed = true;
			__lw_log(`script ${s.field}: update: ${e}`);
		}
	}
	return __takeEvents({ values });
};

// A script that needs nothing per frame lets the renderer stop drawing a still scene.
globalThis.__lw_animated = function () {
	return __scripts.some((s) => !s.failed && typeof s.ns.update === 'function') || __timers.length > 0;
};
