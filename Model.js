.pragma library

// Pure helpers for the Smooth Magnifier panel: the settings schema shared
// with hypr/magnifier.lua, the Lua calls sent through `hyprctl repl`, and
// validation of what comes back. Nothing here touches QML or the network.

var MODIFIERS = ["SUPER + CTRL", "SUPER + SHIFT", "CTRL + ALT", "SUPER + CTRL + ALT"]
var FOLLOW = ["continuous", "edge", "center"]

var SCHEMA = {
  scroll_enabled:   { kind: "boolean", value: true },
  modifier:         { kind: "enum", values: MODIFIERS, value: "SUPER + CTRL" },
  scroll_speed:     { kind: "number", min: 0.25, max: 3.0, value: 1.0 },
  acceleration:     { kind: "boolean", value: true },
  inertia:          { kind: "boolean", value: false },
  invert_scroll:    { kind: "boolean", value: false },
  keyboard_enabled: { kind: "boolean", value: true },
  hold_enabled:     { kind: "boolean", value: true },
  follow:           { kind: "enum", values: FOLLOW, value: "continuous" },
  smooth_images:    { kind: "boolean", value: true },
  smoothness:       { kind: "number", min: 0.0, max: 1.0, value: 0.5 },
  min_zoom:         { kind: "number", min: 1.25, max: 10.0, value: 2.0 },
  max_zoom:         { kind: "number", min: 2.0, max: 40.0, value: 15.0 },
  restore_zoom:     { kind: "boolean", value: true },
  unzoom_on_lock:   { kind: "boolean", value: true }
}

var MAX_RESPONSE = 8192

function defaults() {
  var out = {}
  for (var k in SCHEMA) out[k] = SCHEMA[k].value
  return out
}

// The validated value, or undefined when it does not fit the schema.
function normalize(key, value) {
  if (!Object.prototype.hasOwnProperty.call(SCHEMA, key)) return undefined
  var spec = SCHEMA[key]
  if (spec.kind === "boolean") return typeof value === "boolean" ? value : undefined
  if (spec.kind === "number") {
    var n = Number(value)
    if (typeof value === "boolean" || !isFinite(n)) return undefined
    return Math.max(spec.min, Math.min(spec.max, n))
  }
  if (spec.kind === "enum") return spec.values.indexOf(value) >= 0 ? value : undefined
  return undefined
}

function luaLiteral(key, value) {
  var v = normalize(key, value)
  if (v === undefined) return ""
  var spec = SCHEMA[key]
  if (spec.kind === "boolean") return v ? "true" : "false"
  if (spec.kind === "number") return v.toFixed(4)
  // Enum values come from the whitelist above, so they hold no quotes or
  // backslashes; JSON quoting is valid Lua for them all the same.
  return JSON.stringify(v)
}

// `{ key = value, ... }` with only schema keys and checked values.
function luaTable(changes) {
  var parts = []
  var keys = Object.keys(changes || {}).sort()
  for (var i = 0; i < keys.length; i++) {
    var lit = luaLiteral(keys[i], changes[keys[i]])
    if (lit !== "") parts.push(keys[i] + " = " + lit)
  }
  return "{ " + parts.join(", ") + " }"
}

function zoomArg(z) {
  var n = Number(z)
  if (!isFinite(n)) n = 1
  return Math.max(1, Math.min(40, n)).toFixed(4)
}

function scrollArg(n) {
  var v = Math.round(Number(n))
  if (!isFinite(v)) return "0"
  return String(Math.max(-20, Math.min(20, v)))
}

var CALLS = {
  state: "SmoothMagnifier.state_json()",
  toggle: "SmoothMagnifier.toggle()",
  reset: "SmoothMagnifier.reset()",
  zoomIn: "SmoothMagnifier.zoom_in()",
  zoomOut: "SmoothMagnifier.zoom_out()",
  resetSettings: "SmoothMagnifier.reset_settings()",
  lockBegin: "SmoothMagnifier.lock_begin()",
  lockEnd: "SmoothMagnifier.lock_end()"
}

// Where hypr/magnifier.lua lives; set once by the panel. The path is written
// into Lua source, so only plain path characters are accepted.
var enginePath = ""

function setEnginePath(path) {
  var p = String(path || "")
  enginePath = /^\/[A-Za-z0-9._\/+-]+\.lua$/.test(p) && p.indexOf("..") < 0 ? p : ""
  return enginePath !== ""
}

// Every call loads the engine first when Hyprland does not have it (after
// login, a config reload, or a shell restart), so nothing has to be added to
// hyprland.lua. A load failure answers "error: ..." instead of raising, which
// would otherwise sit in `hyprctl configerrors` until the next reload.
function loader() {
  if (enginePath === "") return ""
  return "if not SmoothMagnifier then local ok, err = pcall(dofile, " + JSON.stringify(enginePath)
    + ") if not ok then return 'error: ' .. tostring(err) end end "
}

// A guarded expression: answers `null` instead of an error when the engine
// is still not loaded, so the panel can say so.
function guarded(call) {
  return loader() + "return SmoothMagnifier and " + call + " or 'null'"
}

// The reason a load failed, from a reply like "error: ...", or "".
function loadError(text) {
  var raw = String(text || "").trim()
  return raw.indexOf("error:") === 0 ? raw.slice(6).trim().slice(0, 300) : ""
}

function callFor(action) {
  return Object.prototype.hasOwnProperty.call(CALLS, action) ? guarded(CALLS[action]) : ""
}

function setCall(changes) { return guarded("SmoothMagnifier.set(" + luaTable(changes) + ")") }
function zoomCall(z) { return guarded("SmoothMagnifier.set_zoom(" + zoomArg(z) + ")") }
function scrollCall(n) { return guarded("SmoothMagnifier.scroll(" + scrollArg(n) + ")") }

// { ok, zoom, settings } from `hyprctl repl` output; ok is false when the
// engine is missing or the reply does not look like ours.
function parseState(text) {
  var raw = String(text || "").trim()
  if (raw.length === 0 || raw.length > MAX_RESPONSE) return { ok: false }
  var data
  try { data = JSON.parse(raw) } catch (e) { return { ok: false } }
  if (!data || typeof data !== "object" || data.engine !== "smooth-magnifier") return { ok: false }
  var settings = defaults()
  var src = data.settings && typeof data.settings === "object" ? data.settings : {}
  for (var k in SCHEMA) {
    var v = normalize(k, src[k])
    if (v !== undefined) settings[k] = v
  }
  return {
    ok: true,
    zoom: parseZoom(data.zoom),
    lockActive: data.lock_active === true,
    version: typeof data.version === "string" ? data.version.slice(0, 16) : "",
    settings: settings
  }
}

function parseZoom(value) {
  var n = Number(String(value === undefined ? "" : value).trim().slice(0, 32))
  if (!isFinite(n) || n < 1) return 1
  return Math.min(40, n)
}

// The panel's zoom slider runs in log space, the way the engine zooms.
function zoomToSlider(z, max) {
  var hi = Math.log(Math.max(1.0001, max))
  return Math.max(0, Math.min(1, Math.log(Math.max(1, z)) / hi))
}

function sliderToZoom(pos, max) {
  var p = Math.max(0, Math.min(1, Number(pos) || 0))
  var z = Math.exp(p * Math.log(Math.max(1.0001, max)))
  return z < 1.02 ? 1 : z
}

function zoomDecimals(z) {
  return z >= 10 ? 0 : 1
}

function chordParts(chord) {
  return String(chord).split(" + ").map(function(k) {
    if (k === "SUPER") return "Super"
    if (k === "CTRL") return "Ctrl"
    if (k === "ALT") return "Alt"
    if (k === "SHIFT") return "Shift"
    return k
  })
}

// True when Hyprland holds a session lock: an active lock is one of the
// reasons a monitor cannot go solitary (`LOCK` in solitaryBlockedBy), which
// is also how Omarchy's omarchy-hyprland-session-locked detects it.
function sessionLocked(monitorIpcObjects) {
  var list = monitorIpcObjects || []
  for (var i = 0; i < list.length && i < 32; i++) {
    var b = list[i] && list[i].solitaryBlockedBy
    if (Array.isArray(b) && b.indexOf("LOCK") >= 0) return true
  }
  return false
}
