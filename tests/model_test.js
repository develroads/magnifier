// Run: node tests/model_test.js   (from the plugin directory)
// Checks that only schema keys with checked values ever reach `hyprctl repl`,
// and that replies are validated before the panel shows them.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const M = {}
vm.runInNewContext(src + "\nthis.M = { MODIFIERS, normalize, luaTable, setCall, zoomCall, scrollCall, callFor, parseState, parseZoom, zoomToSlider, sliderToZoom, chordParts, setEnginePath, loadError, sessionLocked }", M)
const m = M.M

let failures = 0
function check(cond, msg) { if (cond) console.log("ok   " + msg); else { failures++; console.log("FAIL: " + msg) } }

check(m.setCall({ scroll_speed: 1.5 }) === "return SmoothMagnifier and SmoothMagnifier.set({ scroll_speed = 1.5000 }) or 'null'", "set call shape")
check(m.luaTable({ modifier: "SUPER + CTRL\") os.execute(\"rm -rf ~" }) === "{  }", "injection via enum rejected")
check(m.luaTable({ "x = os.exit()": true, scroll_enabled: true }) === "{ scroll_enabled = true }", "unknown keys dropped")
check(m.luaTable({ scroll_speed: "1); os.exit(" }) === "{  }", "non-numeric number rejected")
check(m.luaTable({ scroll_speed: Infinity, smoothness: NaN }) === "{  }", "non-finite numbers rejected")
check(m.luaTable({ inertia: "true" }) === "{  }", "string boolean rejected")
check(m.luaTable({ max_zoom: 999 }) === "{ max_zoom = 40.0000 }", "number clamped")
check(m.zoomCall("1e309").includes("set_zoom(1.0000)"), "infinite zoom falls back to 1")
check(m.scrollCall(1e9).includes("scroll(20)"), "scroll clamped")
check(m.callFor("os.exit") === "", "unknown action rejected")

const good = JSON.stringify({ engine: "smooth-magnifier", version: "1.0.0", zoom: 2.5, settings: { modifier: "CTRL + ALT", scroll_speed: 2, inertia: true, bogus: 1 } })
const st = m.parseState(good + "\n")
check(st.ok && st.zoom === 2.5 && st.settings.modifier === "CTRL + ALT" && st.settings.inertia === true, "valid state parsed")
check(st.settings.bogus === undefined, "unknown state keys dropped")
check(!m.parseState("null").ok, "missing engine detected")
check(!m.parseState("error: attempt to index nil").ok, "lua error is not state")
check(!m.parseState("x".repeat(9000)).ok, "oversized reply rejected")
check(m.parseState(JSON.stringify({ engine: "smooth-magnifier", zoom: 1, settings: { modifier: "<img src=x>" } })).settings.modifier === "SUPER + CTRL", "markup-shaped enum replaced by default")
check(m.parseZoom("abc") === 1 && m.parseZoom("3.5\n") === 3.5 && m.parseZoom("1000") === 40, "zoom file parsing")
check(Math.abs(m.sliderToZoom(m.zoomToSlider(4, 15), 15) - 4) < 1e-9, "slider log mapping round-trips")
check(m.sliderToZoom(0.001, 15) === 1, "slider snaps to 1x near the start")
check(m.chordParts("SUPER + CTRL").join(" ") === "Super Ctrl", "chord labels")

// Self-loading: the engine path is checked before it is written into Lua.
check(!m.setEnginePath("/tmp/x\"); os.execute(\"id\") --.lua"), "path with quotes rejected")
check(!m.setEnginePath("relative/magnifier.lua"), "relative path rejected")
check(!m.setEnginePath("/home/u/../../etc/x.lua"), "path with .. rejected")
check(!m.setEnginePath("/home/u/plugins/x/hypr/magnifier.sh"), "non-lua path rejected")
check(m.callFor("state").startsWith("return SmoothMagnifier"), "no loader while the path is unset")
const P = "/home/u/.config/omarchy/plugins/io.github.develroads.smooth-magnifier/hypr/magnifier.lua"
check(m.setEnginePath(P), "plugin path accepted")
check(m.callFor("state") === "if not SmoothMagnifier then local ok, err = pcall(dofile, \"" + P + "\") if not ok then return 'error: ' .. tostring(err) end end return SmoothMagnifier and SmoothMagnifier.state_json() or 'null'", "state call loads the engine first")
check(m.setCall({ inertia: true }).includes("pcall(dofile,") && m.setCall({ inertia: true }).endsWith("SmoothMagnifier.set({ inertia = true }) or 'null'"), "every call self-loads")
check(m.loadError("error: cannot open file") === "cannot open file" && m.loadError("{\"engine\":1}") === "", "load errors surfaced")
check(m.loadError("error: " + "x".repeat(1000)).length === 300, "load error text bounded")

// Screen lock detection, from monitors' lastIpcObject.
check(m.sessionLocked([{ solitaryBlockedBy: ["WINDOWS", "LOCK"] }]), "LOCK detected")
check(!m.sessionLocked([{ solitaryBlockedBy: ["WINDOWS"] }, { solitaryBlockedBy: [] }]), "no lock")
check(!m.sessionLocked([null, undefined, {}, { solitaryBlockedBy: "LOCK" }]), "missing or malformed data is not a lock")
check(m.sessionLocked([{}, { solitaryBlockedBy: ["LOCK"] }]), "lock on any monitor counts")
check(m.parseState(JSON.stringify({ engine: "smooth-magnifier", zoom: 1, lock_active: true, settings: {} })).lockActive === true, "lock state parsed")
check(m.parseState(JSON.stringify({ engine: "smooth-magnifier", zoom: 1, lock_active: "yes", settings: {} })).lockActive === false, "lock state must be boolean")
check(m.callFor("lockBegin").endsWith("SmoothMagnifier.lock_begin() or 'null'"), "lock call")

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
