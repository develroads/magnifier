// Run: node tests/model_test.js   (from the plugin directory)
// Checks that only schema keys with checked values ever reach `hyprctl repl`,
// and that replies are validated before the panel shows them.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const M = {}
vm.runInNewContext(src + "\nthis.M = { MODIFIERS, normalize, luaTable, setCall, zoomCall, scrollCall, callFor, parseState, parseZoom, zoomToSlider, sliderToZoom, chordParts }", M)
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

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
