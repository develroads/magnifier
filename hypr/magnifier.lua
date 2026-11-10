-- Smooth Magnifier: the Hyprland half of the Omarchy shell plugin.
--
-- Loaded from ~/.config/hypr/hyprland.lua. It owns the zoom binds and the zoom
-- animation, and exposes `SmoothMagnifier` so the shell panel can read and
-- change settings through `hyprctl repl`.
--
-- How the motion stays smooth:
--   * Scroll events are not applied one by one. They are counted, and a 16 ms
--     tick turns whatever arrived since the last tick into one step, so a
--     high-resolution wheel sending a burst of tiny events zooms as evenly as
--     a notched wheel.
--   * The engine only ever sets a *target* zoom. Hyprland's own zoomFactor
--     animation glides the picture toward it on every rendered frame, in sync
--     with the display, so nothing steps at the tick rate.
--   * Zoom is worked in log space, so each notch scales by the same ratio at
--     1.2x as at 12x, which is what makes macOS zoom feel even.
--
-- Why scrolling no longer leaks into windows:
--   Hyprland's binds:scroll_event_delay (300 ms by default) makes it fire a
--   wheel bind at most once per delay and hand every event inside that delay
--   to the window under the pointer, with the zoom modifiers still held:
--   browsers zoom the page and terminals resize their font. The engine sets
--   the delay to 0 so every zoom-chord wheel event is consumed, and re-binds
--   Omarchy's other wheel binds (workspace and group cycling) with the same
--   rate limit they had, so those behave exactly as before.

local prev = rawget(_G, "SmoothMagnifier")
local prev_zoom = nil
if type(prev) == "table" then
  if type(prev._zoom) == "function" then
    local ok, z = pcall(prev._zoom)
    if ok and type(z) == "number" then prev_zoom = z end
  end
  if type(prev._teardown) == "function" then pcall(prev._teardown) end
end

local M = { version = "1.0.0" }

local HOME = os.getenv("HOME") or ""
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/smooth-magnifier"
local SETTINGS_FILE = STATE_DIR .. "/settings.lua"
local ZOOM_FILE = STATE_DIR .. "/zoom"

local MODIFIERS = { "SUPER + CTRL", "SUPER + SHIFT", "CTRL + ALT", "SUPER + CTRL + ALT" }
local FOLLOW = { "continuous", "edge", "center" }

local SCHEMA = {
  scroll_enabled   = { kind = "boolean", default = true },
  modifier         = { kind = "enum", values = MODIFIERS, default = "SUPER + CTRL" },
  scroll_speed     = { kind = "number", min = 0.25, max = 3.0, default = 1.0 },
  acceleration     = { kind = "boolean", default = true },
  inertia          = { kind = "boolean", default = false },
  invert_scroll    = { kind = "boolean", default = false },
  keyboard_enabled = { kind = "boolean", default = true },
  hold_enabled     = { kind = "boolean", default = true },
  follow           = { kind = "enum", values = FOLLOW, default = "continuous" },
  smooth_images    = { kind = "boolean", default = true },
  smoothness       = { kind = "number", min = 0.0, max = 1.0, default = 0.5 },
  min_zoom         = { kind = "number", min = 1.25, max = 10.0, default = 2.0 },
  max_zoom         = { kind = "number", min = 2.0, max = 40.0, default = 15.0 },
  restore_zoom     = { kind = "boolean", default = true },
}

local KEYS = {}
for k in pairs(SCHEMA) do KEYS[#KEYS + 1] = k end
table.sort(KEYS)

----------------------------------------------------------------- tuning --
local TICK_MS    = 16                -- scroll batching tick (one 60 Hz frame)
local LOG_STEP   = 0.11              -- log zoom per wheel notch at speed 1 (about x1.12)
local KEY_STEP   = math.log(1.25)    -- log zoom per keyboard press
local FRICTION   = 7.0               -- inertia decay per second
local IDLE_TICKS = 6                 -- ticks without input before the ticker stops
local ACCEL_MAX  = 0.9               -- extra speed at the end of a long, fast scroll
local ACCEL_RAMP = 12                -- ticks of continuous scrolling to reach ACCEL_MAX
---------------------------------------------------------------------------

local S = {}               -- current settings
local L = 0                -- target zoom, natural log (0 = 1x, off)
local applied = -1         -- last zoom_factor handed to Hyprland
local saved_zoom = nil     -- last zoom written to ZOOM_FILE
local last_on = nil        -- zoom to return to when toggling back on
local pending = 0          -- signed wheel notches since the last tick
local vel = 0              -- inertia velocity, log zoom per second
local streak = 0           -- signed count of recent ticks with input
local idle = 0
local holding = false
local cooling = false      -- rate limit for the re-bound workspace wheel binds
local binds = {}
local ticker, cooler
local throttle_ms = 300

------------------------------------------------------------------ files --
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write_file(path, text)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function ensure_dir()
  local probe = io.open(STATE_DIR .. "/.probe", "w")
  if probe then
    probe:close()
    os.remove(STATE_DIR .. "/.probe")
    return
  end
  -- Runs once on first load only.
  os.execute("mkdir -p " .. shell_quote(STATE_DIR))
end

--------------------------------------------------------------- settings --
local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function normalize(key, value)
  local spec = SCHEMA[key]
  if not spec then return nil end
  if spec.kind == "boolean" then
    if type(value) == "boolean" then return value end
    return nil
  elseif spec.kind == "number" then
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
    return math.max(spec.min, math.min(spec.max, value))
  elseif spec.kind == "enum" then
    if type(value) == "string" and contains(spec.values, value) then return value end
    return nil
  end
  return nil
end

local function defaults()
  local t = {}
  for k, spec in pairs(SCHEMA) do t[k] = spec.default end
  return t
end

local function fix_range()
  if S.min_zoom >= S.max_zoom then
    S.min_zoom = math.max(SCHEMA.min_zoom.min, math.min(SCHEMA.min_zoom.max, S.max_zoom / 1.5))
  end
end

local function load_settings()
  local t = defaults()
  local src = read_file(SETTINGS_FILE)
  if src and #src < 16384 then
    -- Data only: an empty environment, text mode, no access to anything.
    local chunk = load(src, "=smooth-magnifier-settings", "t", {})
    if chunk then
      local ok, data = pcall(chunk)
      if ok and type(data) == "table" then
        for k in pairs(SCHEMA) do
          local v = normalize(k, data[k])
          if v ~= nil then t[k] = v end
        end
      end
    end
  end
  return t
end

local function lua_literal(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "number" then return string.format("%.4f", v) end
  return tostring(v)
end

local function save_settings()
  local lines = { "-- Smooth Magnifier settings. Edited by the shell panel.", "return {" }
  for _, k in ipairs(KEYS) do
    lines[#lines + 1] = "  " .. k .. " = " .. lua_literal(S[k]) .. ","
  end
  lines[#lines + 1] = "}"
  write_file(SETTINGS_FILE, table.concat(lines, "\n") .. "\n")
end

------------------------------------------------------------------- zoom --
local function lmax() return math.log(S.max_zoom) end

local function current_zoom()
  if L < 0.005 then return 1 end
  return math.exp(L)
end

local function apply()
  local z = current_zoom()
  if math.abs(z - applied) < 1e-4 then return end
  applied = z
  hl.config({ cursor = { zoom_factor = z } })
end

local function persist_zoom()
  local z = current_zoom()
  if saved_zoom and math.abs(z - saved_zoom) < 1e-4 then return end
  if write_file(ZOOM_FILE, string.format("%.4f\n", z)) then saved_zoom = z end
end

local function clamp_target()
  local hi = lmax()
  if L <= 0 then
    L = 0
    if vel < 0 then vel = 0 end
  elseif L >= hi then
    L = hi
    if vel > 0 then vel = 0 end
  end
end

local function tick()
  local dt = TICK_MS / 1000
  local n = pending
  pending = 0

  if n ~= 0 then
    idle = 0
    local dir = n > 0 and 1 or -1
    local k = math.abs(n)
    -- One notch is one step. A burst (a fast spin or a high-resolution
    -- wheel) grows more slowly than linearly, so it cannot leap.
    local units = k <= 1 and k or (1 + math.sqrt(k - 1))
    if S.acceleration then
      if streak * dir < 0 then streak = 0 end
      streak = streak + dir
      units = units * (1 + ACCEL_MAX * math.min(math.abs(streak) / ACCEL_RAMP, 1))
    end
    local step = dir * units * LOG_STEP * S.scroll_speed
    if S.inertia then
      -- Part lands now, the rest as velocity that friction spends; the total
      -- travel per notch is the same as without inertia.
      L = L + step * 0.4
      vel = vel + step * 0.6 * FRICTION
    else
      L = L + step
    end
  else
    idle = idle + 1
    if idle > IDLE_TICKS then streak = 0 end
  end

  if vel ~= 0 then
    L = L + vel * dt
    vel = vel * math.exp(-FRICTION * dt)
    if math.abs(vel) < 0.01 then vel = 0 end
  end

  clamp_target()
  -- Zooming out settles exactly on 1x so Hyprland leaves the zoom path.
  if L < 0.01 and n <= 0 and vel <= 0 then L = 0 end
  if L > 0 then last_on = math.exp(L) end
  apply()

  if n == 0 and vel == 0 and idle > IDLE_TICKS then
    ticker:set_enabled(false)
    persist_zoom()
  end
end

local function set_target(z)
  pending = 0
  vel = 0
  z = tonumber(z) or 1
  if z ~= z then z = 1 end
  z = math.max(1, math.min(S.max_zoom, z))
  if z < 1.02 then z = 1 end
  L = math.log(z)
  if L > 0 then last_on = z end
  apply()
  persist_zoom()
end

---------------------------------------------------------------- actions --
function M.scroll(n)
  n = tonumber(n)
  if not n or n ~= n or n == 0 then return M.state_json() end
  n = math.max(-20, math.min(20, n))
  if S.invert_scroll then n = -n end
  pending = pending + n
  if not ticker:is_enabled() then
    idle = 0
    ticker:set_enabled(true)
  end
  return M.state_json()
end

function M.zoom_in() set_target(math.exp(L + KEY_STEP)); return M.state_json() end
function M.zoom_out() set_target(math.exp(L - KEY_STEP)); return M.state_json() end
function M.set_zoom(z) set_target(z); return M.state_json() end

function M.toggle()
  if L > 0.001 then
    last_on = math.exp(L)
    set_target(1)
  else
    set_target(math.max(S.min_zoom, last_on or S.min_zoom))
  end
  return M.state_json()
end

function M.reset()
  if L > 0.001 then last_on = math.exp(L) end
  set_target(1)
  return M.state_json()
end

function M.hold_press()
  if holding then return end
  holding = true
  M.toggle()
end

function M.hold_release()
  if not holding then return end
  holding = false
  M.toggle()
end

------------------------------------------------------------- appearance --
local function apply_appearance()
  pcall(hl.config, { cursor = {
    zoom_rigid = S.follow == "center",
    zoom_detached_camera = S.follow == "edge",
    zoom_disable_aa = not S.smooth_images,
  } })
end

local function apply_animation()
  pcall(hl.curve, "smoothMagnifier", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
  if S.smoothness <= 0.001 then
    pcall(hl.animation, { leaf = "zoomFactor", enabled = false })
  else
    local ms = 70 + S.smoothness * 380 -- 70..450 ms per glide
    pcall(hl.animation, { leaf = "zoomFactor", enabled = true, speed = ms / 100, bezier = "smoothMagnifier" })
  end
end

function M.toggle_smooth()
  S.smooth_images = not S.smooth_images
  apply_appearance()
  save_settings()
  return M.state_json()
end

------------------------------------------------------------------ binds --
local function bind(keys, fn, opts, description)
  opts = opts or {}
  if description then opts.description = description end
  local ok, handle = pcall(hl.bind, keys, fn, opts)
  if ok and handle then binds[#binds + 1] = handle end
end

local function clear_binds()
  for _, h in ipairs(binds) do
    if not pcall(function() h:remove() end) then pcall(function() h:unbind() end) end
  end
  binds = {}
end

local function throttled(fn)
  return function()
    if cooling then return end
    cooling = true
    cooler:set_enabled(true)
    fn()
  end
end

local function configure_binds()
  clear_binds()

  -- Only when Omarchy's default bindings are in use (the user has not set
  -- `omarchy_default_bindings = false`), so binds a user turned off stay off.
  if rawget(_G, "omarchy_default_bindings") ~= false then
    -- Omarchy's own zoom keys, routed through the smooth engine.
    pcall(hl.unbind, "SUPER + CTRL + Z")
    pcall(hl.unbind, "SUPER + CTRL + ALT + Z")
    bind("SUPER + CTRL + Z", M.zoom_in, { repeating = true }, "Zoom in")
    bind("SUPER + CTRL + ALT + Z", M.reset, nil, "Reset zoom")

    -- Omarchy's other wheel binds, with the rate limit scroll_event_delay gave them.
    for _, b in ipairs({
      { "SUPER + mouse_down", "Scroll active workspace forward", function() hl.dispatch(hl.dsp.focus({ workspace = "m+1" })) end },
      { "SUPER + mouse_up", "Scroll active workspace backward", function() hl.dispatch(hl.dsp.focus({ workspace = "m-1" })) end },
      { "SUPER + ALT + mouse_down", "Next window in group", function() hl.dispatch(hl.dsp.group.next()) end },
      { "SUPER + ALT + mouse_up", "Previous window in group", function() hl.dispatch(hl.dsp.group.prev()) end },
    }) do
      pcall(hl.unbind, b[1])
      bind(b[1], throttled(b[3]), nil, b[2])
    end
  end

  if S.scroll_enabled then
    bind(S.modifier .. " + mouse_up", function() M.scroll(1) end, nil, "Zoom in (scroll)")
    bind(S.modifier .. " + mouse_down", function() M.scroll(-1) end, nil, "Zoom out (scroll)")
  end

  if S.keyboard_enabled then
    bind("SUPER + ALT + code:17", M.toggle, nil, "Toggle zoom")
    bind("SUPER + ALT + equal", M.zoom_in, { repeating = true }, "Zoom in")
    bind("SUPER + ALT + minus", M.zoom_out, { repeating = true }, "Zoom out")
    bind("SUPER + ALT + backslash", M.toggle_smooth, nil, "Toggle smooth zoom images")
  end

  if S.hold_enabled then
    bind("SUPER + ALT + Z", M.hold_press, nil, "Hold to toggle zoom")
    -- Fires on any Z release, whatever modifiers are left, and passes the
    -- release on to the app; it does nothing unless a hold is in progress.
    bind("Z", M.hold_release, { release = true, ignore_mods = true, non_consuming = true })
  end
end

------------------------------------------------------------------- state --
local function json_string(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function json_value(v)
  if type(v) == "boolean" then return tostring(v) end
  if type(v) == "number" then return string.format("%.4f", v) end
  return json_string(v)
end

function M.state_json()
  local parts = {}
  for _, k in ipairs(KEYS) do
    parts[#parts + 1] = json_string(k) .. ":" .. json_value(S[k])
  end
  return "{" .. table.concat({
    '"engine":"smooth-magnifier"',
    '"version":' .. json_string(M.version),
    '"zoom":' .. json_value(current_zoom()),
    '"settings":{' .. table.concat(parts, ",") .. "}",
  }, ",") .. "}"
end

function M.set(t)
  if type(t) ~= "table" then return M.state_json() end
  for k, v in pairs(t) do
    local nv = normalize(k, v)
    if nv ~= nil then S[k] = nv end
  end
  fix_range()
  apply_appearance()
  apply_animation()
  configure_binds()
  if L > lmax() then set_target(S.max_zoom) end
  save_settings()
  return M.state_json()
end

function M.reset_settings()
  S = defaults()
  return M.set({})
end

-------------------------------------------------------------- lifecycle --
function M._zoom() return current_zoom() end

function M._teardown()
  if ticker then pcall(function() ticker:set_enabled(false) end) end
  if cooler then pcall(function() cooler:set_enabled(false) end) end
  clear_binds()
end

ensure_dir()
S = load_settings()
fix_range()

local configured_delay = tonumber(hl.get_config("binds.scroll_event_delay"))
if configured_delay and configured_delay > 0 then
  throttle_ms = math.max(50, math.min(1000, configured_delay))
end
hl.config({ binds = { scroll_event_delay = 0 } })

ticker = hl.timer(tick, { timeout = TICK_MS, type = "repeat" })
ticker:set_enabled(false)
cooler = hl.timer(function()
  cooling = false
  cooler:set_enabled(false)
end, { timeout = throttle_ms, type = "repeat" })
cooler:set_enabled(false)

apply_appearance()
apply_animation()
configure_binds()

-- A config reload keeps the zoom you had; a fresh login restores the saved
-- one when that is turned on.
local start = prev_zoom
if not start and S.restore_zoom then start = tonumber((read_file(ZOOM_FILE) or ""):match("[%d%.]+")) end
saved_zoom = tonumber((read_file(ZOOM_FILE) or ""):match("[%d%.]+"))
set_target(start or 1)

_G.SmoothMagnifier = M
return M
