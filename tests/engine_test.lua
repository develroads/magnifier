-- Exercises hypr/magnifier.lua against a stubbed `hl`, outside Hyprland.
-- Run: lua tests/engine_test.lua   (from the plugin directory)

local dir = arg[0]:match("^(.*)/tests/") or "."
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")

local real_getenv = os.getenv
os.getenv = function(k)
  if k == "XDG_STATE_HOME" or k == "XDG_RUNTIME_DIR" then return tmp end
  return real_getenv(k)
end

local failures = 0
local function check(cond, msg)
  if not cond then failures = failures + 1; print("FAIL: " .. msg) else print("ok   " .. msg) end
end

local function new_hl()
  local h = { cfg = { ["binds.scroll_event_delay"] = 300 }, binds = {}, timers = {}, zoom_sets = 0, anim = nil }
  h.config = function(t)
    for section, values in pairs(t) do
      for k, v in pairs(values) do
        h.cfg[section .. "." .. k] = v
        if section == "cursor" and k == "zoom_factor" then h.zoom_sets = h.zoom_sets + 1 end
      end
    end
  end
  h.get_config = function(k) return h.cfg[k] end
  h.curve = function() end
  h.animation = function(a) h.anim = a end
  h.unbind = function(keys)
    for i = #h.binds, 1, -1 do if h.binds[i].keys == keys then table.remove(h.binds, i) end end
  end
  h.bind = function(keys, fn, opts)
    local b = { keys = keys, fn = fn, opts = opts or {} }
    function b:remove() for i, x in ipairs(h.binds) do if x == self then table.remove(h.binds, i) return end end end
    h.binds[#h.binds + 1] = b
    return b
  end
  h.find = function(keys) for _, b in ipairs(h.binds) do if b.keys == keys then return b end end end
  h.timer = function(cb, opts)
    local t = { cb = cb, enabled = true, opts = opts }
    function t:set_enabled(v) self.enabled = v end
    function t:is_enabled() return self.enabled end
    h.timers[#h.timers + 1] = t
    return t
  end
  h.run = function(ticks)
    for _ = 1, ticks do for _, t in ipairs(h.timers) do if t.enabled then t.cb() end end end
  end
  h.dispatch = function() h.dispatched = (h.dispatched or 0) + 1 end
  h.dsp = { focus = function(x) return x end, group = { next = function() return "n" end, prev = function() return "p" end } }
  return h
end

_G.hl = new_hl()
local M = dofile(dir .. "/hypr/magnifier.lua")

check(hl.cfg["binds.scroll_event_delay"] == 0, "scroll_event_delay forced to 0")
check(hl.cfg["cursor.zoom_factor"] == 1, "starts at 1x with no saved zoom")
check(hl.anim and hl.anim.enabled and hl.anim.leaf == "zoomFactor", "native zoom animation enabled")
check(hl.find("SUPER + CTRL + mouse_up") ~= nil, "default scroll chord bound")
check(hl.find("SUPER + CTRL + Z") ~= nil, "Omarchy zoom-in key taken over")

-- One notch zooms in by one step.
hl.find("SUPER + CTRL + mouse_up").fn()
hl.run(1)
local z1 = hl.cfg["cursor.zoom_factor"]
check(z1 > 1.1 and z1 < 1.14, "one notch is about x1.12 (" .. z1 .. ")")

-- A burst of 8 hi-res events in one tick is far less than 8 notches.
local before = hl.cfg["cursor.zoom_factor"]
for _ = 1, 8 do M.scroll(1) end
hl.run(1)
local ratio = hl.cfg["cursor.zoom_factor"] / before
check(ratio < math.exp(0.11 * 8 * 0.6), "burst is compressed (x" .. string.format("%.3f", ratio) .. ")")

-- Ticker stops once idle and the zoom is saved.
hl.run(20)
check(not hl.timers[1].enabled, "ticker stops when idle")
local saved = io.open(tmp .. "/smooth-magnifier/zoom"):read("a")
check(math.abs(tonumber(saved) - hl.cfg["cursor.zoom_factor"]) < 1e-3, "zoom persisted on settle")

-- Max clamp.
for _ = 1, 400 do M.scroll(1); hl.run(1) end
check(math.abs(hl.cfg["cursor.zoom_factor"] - 15) < 1e-6, "clamped at max zoom")

-- Zooming all the way out lands exactly on 1.
for _ = 1, 400 do M.scroll(-1); hl.run(1) end
hl.run(20)
check(hl.cfg["cursor.zoom_factor"] == 1, "zoom out settles exactly at 1x")

-- Toggle uses min zoom, then remembers the last level.
M.toggle()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 2) < 1e-6, "toggle on goes to min zoom 2x")
M.set_zoom(5.5)
M.toggle()
check(hl.cfg["cursor.zoom_factor"] == 1, "toggle off")
M.toggle()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 5.5) < 1e-3, "toggle back to last level 5.5x")

-- Hold to toggle: press then release returns to where it was.
M.reset()
M.hold_press()
check(hl.cfg["cursor.zoom_factor"] > 1, "hold press zooms in")
M.hold_release()
check(hl.cfg["cursor.zoom_factor"] == 1, "hold release zooms back out")
M.hold_release()
check(hl.cfg["cursor.zoom_factor"] == 1, "stray Z release does nothing")
check(hl.find("Z").opts.non_consuming == true, "Z release bind never eats the key")

-- Settings: validation, persistence, rebinding.
M.set({ modifier = "CTRL + ALT", scroll_speed = 99, follow = "center", bogus = 1, smooth_images = "yes" })
check(hl.find("CTRL + ALT + mouse_up") ~= nil and hl.find("SUPER + CTRL + mouse_up") == nil, "modifier change rebinds")
check(hl.cfg["cursor.zoom_rigid"] == true and hl.cfg["cursor.zoom_detached_camera"] == false, "center follow mode")
local st = M.state_json()
check(st:find('"scroll_speed":3.0000', 1, true) ~= nil, "speed clamped to 3")
check(st:find('"smooth_images":true', 1, true) ~= nil, "non-boolean rejected")
check(st:find("bogus", 1, true) == nil, "unknown key ignored")
M.set({ modifier = "rm -rf /" })
check(hl.find("CTRL + ALT + mouse_up") ~= nil, "unknown modifier rejected")
M.set({ min_zoom = 9, max_zoom = 4 })
check(M.state_json():find('"max_zoom":4.0000', 1, true) and M.state_json():find('"min_zoom":2.6667', 1, true), "min kept below max")

-- Workspace wheel binds are rate limited, not dropped.
hl.dispatched = 0
local ws = hl.find("SUPER + mouse_down")
ws.fn(); ws.fn(); ws.fn()
check(hl.dispatched == 1, "workspace wheel throttled within the delay")
hl.timers[2].cb()
ws.fn()
check(hl.dispatched == 2, "workspace wheel works again after the delay")

-- Reload: a second load keeps the live zoom and leaves no duplicate binds.
M.set_zoom(3)
local n_binds = #hl.binds
dofile(dir .. "/hypr/magnifier.lua")
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3) < 1e-3, "reload keeps current zoom")
check(#hl.binds == n_binds, "reload leaves no duplicate binds (" .. #hl.binds .. " vs " .. n_binds .. ")")
check(SmoothMagnifier.state_json():find('"modifier":"CTRL + ALT"', 1, true) ~= nil, "settings survive reload")

-- Fresh login: restored from file.
_G.SmoothMagnifier = nil
_G.hl = new_hl()
local anim_log = {}
hl.animation = function(a) anim_log[#anim_log + 1] = { enabled = a.enabled, zoom = hl.cfg["cursor.zoom_factor"] }; hl.anim = a end
dofile(dir .. "/hypr/magnifier.lua")
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3) < 1e-3, "zoom restored on fresh start")
check(anim_log[1].enabled == false and anim_log[1].zoom == nil, "restore happens with the glide off (no zoom-in animation)")
check(hl.anim.enabled == true, "glide back on after the restore")

-- Config reload in the same session (fresh Lua state): zoom kept even with
-- restore-at-login off, via the session file.
SmoothMagnifier.set({ restore_zoom = false })
SmoothMagnifier.set_zoom(3.5)  -- max_zoom is 4 from an earlier test
_G.SmoothMagnifier = nil
_G.hl = new_hl()
dofile(dir .. "/hypr/magnifier.lua")
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3.5) < 1e-3, "reload keeps zoom via the session file")

-- New session (runtime dir emptied at logout) with restore off: starts at 1x.
os.remove(tmp .. "/smooth-magnifier-zoom")
_G.SmoothMagnifier = nil
_G.hl = new_hl()
dofile(dir .. "/hypr/magnifier.lua")
check(hl.cfg["cursor.zoom_factor"] == 1, "new session starts at 1x when restore is off")
SmoothMagnifier.set({ restore_zoom = true })

-- Screen lock: 1x at once, nothing saved while locked, zoom back on unlock.
SmoothMagnifier.set_zoom(3.5)
local saved_before = io.open(tmp .. "/smooth-magnifier/zoom"):read("a")
anim_log = {}
hl.animation = function(a) anim_log[#anim_log + 1] = { enabled = a.enabled, zoom = hl.cfg["cursor.zoom_factor"] }; hl.anim = a end
SmoothMagnifier.lock_begin()
check(hl.cfg["cursor.zoom_factor"] == 1, "lock: zoomed out")
check(anim_log[1].enabled == false and hl.anim.enabled == true, "lock: instant (glide off for that change), glide back on")
check(SmoothMagnifier.state_json():find('"lock_active":true', 1, true) ~= nil, "lock: state reports lock")
SmoothMagnifier.lock_begin()
SmoothMagnifier.reset()
check(io.open(tmp .. "/smooth-magnifier/zoom"):read("a") == saved_before, "lock: saved zoom untouched while locked")
SmoothMagnifier.lock_end()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3.5) < 1e-3, "unlock: zoom restored")
check(SmoothMagnifier.state_json():find('"lock_active":false', 1, true) ~= nil, "unlock: state clear")
SmoothMagnifier.lock_end()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3.5) < 1e-3, "stray unlock does nothing")
SmoothMagnifier.set({ unzoom_on_lock = false })
SmoothMagnifier.lock_begin()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3.5) < 1e-3, "lock handling can be turned off")
SmoothMagnifier.set({ unzoom_on_lock = true })
check(hl.find("SUPER + CTRL + ALT + Z").opts.locked == true, "reset key works at the lock screen")
check(hl.find("SUPER + ALT + equal").opts.locked == true and hl.find("CTRL + ALT + mouse_up").opts.locked == true, "zoom keys work at the lock screen by default")

-- The flow at the lock screen: 1x on lock, zoom in and out while locked,
-- then unlock returns to the zoom from before the lock.
SmoothMagnifier.set_zoom(3)
local saved_pre = io.open(tmp .. "/smooth-magnifier/zoom"):read("a")
SmoothMagnifier.lock_begin()
check(hl.cfg["cursor.zoom_factor"] == 1, "lock flow: lock screen opens at 1x")
hl.find("SUPER + ALT + equal").fn()
hl.find("SUPER + ALT + equal").fn()
check(hl.cfg["cursor.zoom_factor"] > 1.5, "lock flow: zoom in works while locked")
for _ = 1, 3 do hl.find("CTRL + ALT + mouse_down").fn(); hl.run(1) end
hl.run(20)
check(hl.cfg["cursor.zoom_factor"] < 1.5, "lock flow: scroll zoom out works while locked")
check(io.open(tmp .. "/smooth-magnifier/zoom"):read("a") == saved_pre, "lock flow: lock-screen zoom is not saved")
SmoothMagnifier.lock_end()
check(math.abs(hl.cfg["cursor.zoom_factor"] - 3) < 1e-3, "lock flow: unlock returns to the zoom from before the lock")
SmoothMagnifier.set({ lock_screen_zoom = true })
check(hl.find("SUPER + ALT + equal").opts.locked == true and hl.find("CTRL + ALT + mouse_up").opts.locked == true and hl.find("SUPER + ALT + code:17").opts.locked == true, "lock screen zoom: zoom keys and scroll work while locked")
check(not hl.find("SUPER + mouse_down").opts.locked, "lock screen zoom: workspace scrolling still blocked at the lock screen")
SmoothMagnifier.set({ lock_screen_zoom = false })
check(not hl.find("SUPER + ALT + equal").opts.locked, "lock screen zoom can be turned back off")

-- Users who turned Omarchy's default bindings off do not get them back.
_G.SmoothMagnifier = nil
_G.hl = new_hl()
_G.omarchy_default_bindings = false
dofile(dir .. "/hypr/magnifier.lua")
check(hl.find("SUPER + mouse_down") == nil and hl.find("SUPER + CTRL + Z") == nil, "disabled Omarchy binds stay disabled")
check(hl.find("CTRL + ALT + mouse_up") ~= nil, "zoom scroll still bound")
_G.omarchy_default_bindings = nil

os.execute("rm -rf '" .. tmp .. "'")
print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
