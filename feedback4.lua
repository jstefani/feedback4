-- feedback4
-- 4-op FM, custom algorithm
--
-- clone of Organelle
-- Feedback4 (PD / FM8 expert)
--
-- E1 page
-- PLAY  E2 preset  E3 trans
-- ENV   E2 atk     E3 dec+rel
--       K2 rnd env K3 shape
-- OP    E2 ratio   E3 out
--       hold K2+E  A/D
--       hold K3+E  S/R
--       K1+E  pan / env amt
-- ALGO  E2 cell    E3 amt
-- MACRO E2 dest    E3 scale
--       hold K2 which
-- K2 tweak (near current)
-- K3 randomize patch
-- panic: PARAMS all notes off
-- midi in. pitchbend + mod wheel.
-- PARAMS for rest.

engine.name = "Feedback4"

local MusicUtil = require "musicutil"
local factory = include "lib/presets"

local OPS = 4
local PAGES = { "play", "env", "op1", "op2", "op3", "op4", "algo", "macro" }
local ENVSRC = { "off", "op1", "op2", "op3", "op4" }
local PNAMES = {
  "atk", "dec", "sus", "rel",
  "m1", "m2", "m3", "m4",
  "ratio", "out", "--", "envsrc", "envamt", "pan"
}

local page = 1
local k2, k3, k1 = false, false, false
local k2_used, k3_used = false, false
local algo_cell = 1 -- 1..16, row-major from->to
local macro_i = 1
local shape_i = 0 -- env page: last shape applied, 0 = none
local loading = false
local applying_macro = false
local hud = nil
local hud_t = 0

local active = {}
local held = {}
local next_id = 1
local screen_dirty = true
local bend = 0 -- -1..1 from MIDI pitchbend

local function pid(op, name)
  return string.format("op%d_%s", op, name)
end

local function sq(x)
  return x * x
end

-- operator-edit.pd: slider squared, then OSC-yo scales to ms
local function atk_sec(x)
  return (sq(x) * 300 + 0.5) / 1000
end

local function dec_sec(x)
  return sq(x)
end

local function sus_lvl(x)
  return sq(x)
end

local function rel_sec(x)
  return (sq(x) * 2000 + 10) / 1000
end

local function out_lvl(x)
  return sq(x)
end

local function fmt_ms(sec)
  if sec < 0.001 then return "0.5ms" end
  if sec < 1 then return string.format("%.0fms", sec * 1000) end
  return string.format("%.2fs", sec)
end

local function fmt_num(x, digits)
  digits = digits or 2
  local m = 10 ^ digits
  local v = math.floor(x * m + (x >= 0 and 0.5 or -0.5)) / m
  if math.abs(v - math.floor(v + 0.5)) < 1e-9 then
    return string.format("%.0f", v)
  end
  return string.format("%." .. digits .. "f", v)
end

local function dest_name(d)
  d = math.floor(d + 0.5)
  if d < 1 or d > 56 then return "off" end
  local op = math.floor((d - 1) / 14) + 1
  local p = ((d - 1) % 14) + 1
  if PNAMES[p] == "--" then return "off" end
  return string.format("op%d %s", op, PNAMES[p])
end

local RANGES = {
  atk = {0, 32}, dec = {0, 32}, sus = {0, 32}, rel = {0, 32},
  m1 = {-200, 200}, m2 = {-200, 200}, m3 = {-200, 200}, m4 = {-200, 200},
  ratio = {-32, 32}, out = {0, 4},
  envsrc = {0, 4}, envamt = {-100, 100}, pan = {0, 1},
}

local function dest_id(d)
  d = math.floor(d + 0.5)
  if d < 1 or d > 56 then return nil end
  local op = math.floor((d - 1) / 14) + 1
  local p = ((d - 1) % 14) + 1
  if PNAMES[p] == "--" then return nil end
  return pid(op, PNAMES[p]), PNAMES[p]
end

local function dirty()
  screen_dirty = true
end

local function send_op(op)
  engine.op(
    op,
    atk_sec(params:get(pid(op, "atk"))),
    dec_sec(params:get(pid(op, "dec"))),
    sus_lvl(params:get(pid(op, "sus"))),
    rel_sec(params:get(pid(op, "rel"))),
    params:get(pid(op, "m1")),
    params:get(pid(op, "m2")),
    params:get(pid(op, "m3")),
    params:get(pid(op, "m4")),
    params:get(pid(op, "ratio")),
    out_lvl(params:get(pid(op, "out"))),
    params:get(pid(op, "envsrc")),
    params:get(pid(op, "envamt")),
    params:get(pid(op, "pan"))
  )
end

local function apply_macro(i)
  if loading or applying_macro then return end
  local dest = params:get("macro_" .. i .. "_dest")
  local id, name = dest_id(dest)
  if id == nil then return end
  local val = params:get("macro_" .. i) * params:get("macro_" .. i .. "_scale")
  if name == "envsrc" then
    val = math.floor(val + 0.5)
  end
  local r = RANGES[name]
  if r then val = util.clamp(val, r[1], r[2]) end
  applying_macro = true
  params:set(id, val)
  applying_macro = false
end

local function bend_st()
  if bend >= 0 then return bend * params:get("bend_up") end
  return bend * params:get("bend_down")
end

local function note_hz(note)
  return MusicUtil.note_num_to_freq(note + params:get("transpose") + bend_st())
end

local function retune()
  for note, id in pairs(active) do
    engine.freq(id, note_hz(note))
  end
end

local function note_on(note, vel)
  local id = next_id
  next_id = next_id + 1
  if active[note] then engine.noteKill(active[note]) end
  active[note] = id
  held[note] = true
  engine.noteOn(id, note_hz(note), vel or 0.85)
  dirty()
end

local function note_off(note)
  if active[note] then
    engine.noteOff(active[note])
    active[note] = nil
  end
  held[note] = nil
  dirty()
end

local function all_off()
  engine.stopAll()
  active = {}
  held = {}
  dirty()
end

local function flash(msg)
  hud = msg
  hud_t = util.time()
  dirty()
end

local function pset(op, name, val)
  local r = RANGES[name]
  if name == "envsrc" then
    val = math.floor(val + 0.5)
  end
  params:set(pid(op, name), util.clamp(val, r[1], r[2]))
end

-- harmonic ratio table (DX-style integers and simple rationals).
-- carriers stay near 1/2/4 so stacked outs don't beat; modulators roam the table.
local HARMONIC = {
  0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 10, 12, 16
}
local CARRIER_R = { 0.5, 1, 1, 1, 1, 2, 2, 3, 4 }
local MOD_R = { 0.5, 1, 1, 1.5, 2, 2, 3, 3, 4, 5, 6, 7, 8 }
-- wild-mode weighted bag (duplicates = more likely)
local RND_RATIOS = {
  0.5, 1, 1, 1, 1, 1.5, 2, 2, 2, 3, 4, 4, 5, 6, 7, 8, 0.25, 12, 16
}

local function musical()
  return params:get("musical") == 2
end

local function nearest_harmonic(x)
  local ax = math.abs(x)
  local best, bd = HARMONIC[1], math.huge
  for i = 1, #HARMONIC do
    local d = math.abs(HARMONIC[i] - ax)
    if d < bd then best, bd = HARMONIC[i], d end
  end
  return best
end

local function neighbor_harmonic(x)
  local ax = math.abs(x)
  local idx, bd = 1, math.huge
  for i = 1, #HARMONIC do
    local d = math.abs(HARMONIC[i] - ax)
    if d < bd then idx, bd = i, d end
  end
  idx = util.clamp(idx + (math.random(3) - 2), 1, #HARMONIC)
  return HARMONIC[idx]
end

-- sparse 4-op skeletons. {from,to} edges + which ops reach the output
local SKELS = {
  { e = {{4, 3}, {3, 2}, {2, 1}}, c = {1} },
  { e = {{3, 2}, {2, 1}, {4, 1}}, c = {1} },
  { e = {{2, 1}, {4, 3}}, c = {1, 3} },
  { e = {{4, 1}, {3, 1}, {2, 1}}, c = {1} },
  { e = {{4, 3}, {3, 1}, {2, 1}}, c = {1} },
  { e = {{4, 4}, {4, 3}, {3, 2}, {2, 1}}, c = {1} },
  { e = {}, c = {1, 2, 3, 4} },
  { e = {{4, 3}, {2, 1}}, c = {1, 3} },
  { e = {{3, 1}, {4, 2}}, c = {1, 2} },
  { e = {{4, 1}, {3, 2}, {2, 1}}, c = {1} },
}

local function pick(t)
  return t[math.random(#t)]
end

local function rnd_ratio(carrier)
  if musical() then
    if carrier then return pick(CARRIER_R) end
    return pick(MOD_R)
  end
  local r = math.random()
  if r < 0.7 then
    return pick(RND_RATIOS)
  elseif r < 0.9 then
    return 0.25 + math.random() * 8
  end
  local s = (math.random() < 0.5) and -1 or 1
  return s * (0.5 + math.random() * 4)
end

-- slider domain 0-1 (later squared). skew low, often instant attack
local function rnd_atk()
  if math.random() < 0.45 then return 0 end
  local x = math.random()
  return x * x * 0.6
end

local function rnd_dec()
  local x = math.random()
  return 0.05 + x * x * 0.9
end

local function rnd_sus()
  if math.random() < 0.15 then return 0 end
  return 0.2 + math.random() * 0.8
end

local function rnd_rel()
  local x = math.random()
  return 0.04 + x * x * 0.5
end

local function rnd_mod()
  if math.random() < 0.2 then return 0.04 + math.random() * 0.15 end
  return 0.15 + math.random() * 1.4
end

local function is_carrier(skel, op)
  for i = 1, #skel.c do
    if skel.c[i] == op then return true end
  end
  return false
end

-- K3: new patch. sparse algorithm, simple ratios, playable envelopes.
-- transpose / amp / macros left alone — those are performance controls.
local function randomize()
  local skel = pick(SKELS)
  for op = 1, OPS do
    for d = 1, 4 do pset(op, "m" .. d, 0) end
  end
  for i = 1, #skel.e do
    local from, to = skel.e[i][1], skel.e[i][2]
    local amt = rnd_mod()
    if from == to then amt = 0.05 + math.random() * 0.35 end
    pset(from, "m" .. to, amt)
  end
  -- occasional extra send, still sparse
  if math.random() < 0.25 then
    local from, to = math.random(OPS), math.random(OPS)
    if math.abs(params:get(pid(from, "m" .. to))) < 1e-6 then
      pset(from, "m" .. to, 0.05 + math.random() * 0.4)
    end
  end

  for op = 1, OPS do
    pset(op, "atk", rnd_atk())
    pset(op, "dec", rnd_dec())
    pset(op, "sus", rnd_sus())
    pset(op, "rel", rnd_rel())
    pset(op, "ratio", rnd_ratio(is_carrier(skel, op)))
    if is_carrier(skel, op) then
      pset(op, "out", 0.45 + math.random() * 0.55)
    else
      pset(op, "out", (math.random() < 0.7) and 0 or (math.random() * 0.35))
    end
    pset(op, "pan", 0.35 + math.random() * 0.3)
    -- ratio env sweeps the fundamental off the harmonic series
    if musical() or math.random() >= 0.2 then
      pset(op, "envsrc", 0)
      pset(op, "envamt", 0)
    else
      pset(op, "envsrc", math.random(0, 4))
      pset(op, "envamt", (math.random() * 0.8) * ((math.random() < 0.5) and 1 or -1))
    end
  end
  flash("RND")
end

-- K2: walk the current patch a little. zeros in the matrix stay zero so
-- the algorithm does not fill in. env src stays put.
local function morph()
  local function nudge(op, name, abs_amt, rel_amt)
    local cur = params:get(pid(op, name))
    local delta = (math.random() * 2 - 1) * abs_amt
    if rel_amt and rel_amt > 0 then
      delta = delta + cur * (math.random() * 2 - 1) * rel_amt
    end
    pset(op, name, cur + delta)
  end
  for op = 1, OPS do
    nudge(op, "atk", 0.05, 0.12)
    nudge(op, "dec", 0.06, 0.1)
    nudge(op, "sus", 0.06, 0.08)
    nudge(op, "rel", 0.05, 0.1)
    if musical() then
      pset(op, "ratio", neighbor_harmonic(params:get(pid(op, "ratio"))))
    else
      nudge(op, "ratio", 0.08, 0.06)
      nudge(op, "envamt", 0.12, 0.1)
    end
    nudge(op, "out", 0.06, 0.08)
    nudge(op, "pan", 0.04, 0)
    for d = 1, 4 do
      local id = pid(op, "m" .. d)
      local cur = params:get(id)
      if math.abs(cur) >= 0.001 then
        nudge(op, "m" .. d, 0.08, 0.12)
      end
    end
  end
  flash("TWEAK")
end

-- env page: ops that reach the output. falls back to all if none do.
local function audible_ops()
  local t = {}
  for op = 1, OPS do
    if params:get(pid(op, "out")) > 0.001 then t[#t + 1] = op end
  end
  if #t == 0 then
    for op = 1, OPS do t[op] = op end
  end
  return t
end

-- slider domain 0-1 (squared later, see atk_sec etc)
local SHAPES = {
  { n = "perc",     atk = 0,    dec = 0.35, sus = 0,    rel = 0.15 },
  { n = "pluck",    atk = 0,    dec = 0.6,  sus = 0.25, rel = 0.3 },
  { n = "stab",     atk = 0,    dec = 0.3,  sus = 0.6,  rel = 0.1 },
  { n = "gate",     atk = 0.05, dec = 0,    sus = 1,    rel = 0.08 },
  { n = "sustain",  atk = 0.15, dec = 0.4,  sus = 0.85, rel = 0.3 },
  { n = "pad",      atk = 0.7,  dec = 0.5,  sus = 0.8,  rel = 0.6 },
  { n = "swell",    atk = 1,    dec = 0.3,  sus = 1,    rel = 0.5 },
  { n = "long rel", atk = 0,    dec = 0.5,  sus = 0.5,  rel = 1 },
}

local function env_nudge(name, d)
  for _, op in ipairs(audible_ops()) do
    pset(op, name, params:get(pid(op, name)) + d)
  end
end

-- K2 on env page
local function env_random()
  for _, op in ipairs(audible_ops()) do
    pset(op, "atk", rnd_atk())
    pset(op, "dec", rnd_dec())
    pset(op, "sus", rnd_sus())
    pset(op, "rel", rnd_rel())
  end
  shape_i = 0
  flash("RND ENV")
end

-- K3 on env page
local function env_next_shape()
  shape_i = (shape_i % #SHAPES) + 1
  local sh = SHAPES[shape_i]
  for _, op in ipairs(audible_ops()) do
    pset(op, "atk", sh.atk)
    pset(op, "dec", sh.dec)
    pset(op, "sus", sh.sus)
    pset(op, "rel", sh.rel)
  end
  flash(sh.n)
end

-- mean of a slider across the audible ops, for the env page display
local function env_mean(name)
  local ops = audible_ops()
  local sum = 0
  for _, op in ipairs(ops) do sum = sum + params:get(pid(op, name)) end
  return sum / #ops
end

local function load_factory(idx)
  local p = factory[idx]
  if p == nil then return end
  local prev_loading = loading
  loading = true
  for op = 1, OPS do
    local o = p.ops[op]
    params:set(pid(op, "atk"), util.clamp(o.atk, 0, 32))
    params:set(pid(op, "dec"), util.clamp(o.dec, 0, 32))
    params:set(pid(op, "sus"), util.clamp(o.sus, 0, 32))
    params:set(pid(op, "rel"), util.clamp(o.rel, 0, 32))
    params:set(pid(op, "m1"), util.clamp(o.m1, -200, 200))
    params:set(pid(op, "m2"), util.clamp(o.m2, -200, 200))
    params:set(pid(op, "m3"), util.clamp(o.m3, -200, 200))
    params:set(pid(op, "m4"), util.clamp(o.m4, -200, 200))
    params:set(pid(op, "ratio"), util.clamp(o.ratio, -32, 32))
    params:set(pid(op, "out"), util.clamp(o.out, 0, 4))
    params:set(pid(op, "envsrc"), util.clamp(math.floor(o.envsrc + 0.5), 0, 4))
    params:set(pid(op, "envamt"), util.clamp(o.envamt, -100, 100))
    params:set(pid(op, "pan"), util.clamp(o.pan, 0, 1))
  end
  for i = 1, 3 do
    local m = p.macros[i]
    params:set("macro_" .. i .. "_dest", util.clamp(math.floor(m.dest + 0.5), 0, 56))
    params:set("macro_" .. i .. "_scale", util.clamp(m.scale, -100, 100))
  end
  loading = prev_loading
  for op = 1, OPS do send_op(op) end
  dirty()
end

local function add_op_params(op)
  params:add_group("op " .. op, 13)

  local function touch()
    send_op(op)
    dirty()
  end

  params:add_control(pid(op, "atk"), "attack",
    controlspec.new(0, 32, "lin", 0, 0, ""))
  params:set_action(pid(op, "atk"), function() touch() end)

  params:add_control(pid(op, "dec"), "decay",
    controlspec.new(0, 32, "lin", 0, 0.3, ""))
  params:set_action(pid(op, "dec"), function() touch() end)

  params:add_control(pid(op, "sus"), "sustain",
    controlspec.new(0, 32, "lin", 0, 0.7, ""))
  params:set_action(pid(op, "sus"), function() touch() end)

  params:add_control(pid(op, "rel"), "release",
    controlspec.new(0, 32, "lin", 0, 0.2, ""))
  params:set_action(pid(op, "rel"), function() touch() end)

  params:add_control(pid(op, "ratio"), "ratio",
    controlspec.new(-32, 32, "lin", 0, 1, "", 0.005))
  params:set_action(pid(op, "ratio"), function() touch() end)

  params:add_control(pid(op, "out"), "out",
    controlspec.new(0, 4, "lin", 0, 0.7, ""))
  params:set_action(pid(op, "out"), function() touch() end)

  for d = 1, 4 do
    params:add_control(pid(op, "m" .. d), "-> op" .. d,
      controlspec.new(-200, 200, "lin", 0, 0, "", 0.005))
    params:set_action(pid(op, "m" .. d), function() touch() end)
  end

  params:add_number(pid(op, "envsrc"), "freq env", 0, 4, 0, function(p)
    return ENVSRC[p:get() + 1]
  end)
  params:set_action(pid(op, "envsrc"), function() touch() end)

  params:add_control(pid(op, "envamt"), "env amt",
    controlspec.new(-100, 100, "lin", 0, 0, "", 0.005))
  params:set_action(pid(op, "envamt"), function() touch() end)

  params:add_control(pid(op, "pan"), "pan",
    controlspec.new(0, 1, "lin", 0, 0.5, ""))
  params:set_action(pid(op, "pan"), function() touch() end)
end

function init()
  params:add_separator("feedback4")

  params:add_number("preset", "preset", 1, #factory, 1)
  params:set_action("preset", function(x)
    load_factory(x)
  end)

  params:add_number("transpose", "transpose", -24, 24, 0)
  params:set_action("transpose", function()
    retune()
    dirty()
  end)

  params:add_control("amp", "amp",
    controlspec.new(0, 1, "lin", 0, 0.7, ""))
  params:set_action("amp", function(x)
    engine.amp(x)
    dirty()
  end)

  params:add_trigger("all_notes_off", "all notes off")
  params:set_action("all_notes_off", function() all_off() end)

  params:add_trigger("tweak", "tweak patch")
  params:set_action("tweak", function()
    if not loading then morph() end
  end)
  params:add_trigger("randomize", "randomize patch")
  params:set_action("randomize", function()
    if not loading then randomize() end
  end)

  params:add_option("musical", "musical fm", {"off", "on"}, 2)
  params:set_action("musical", function(x)
    if x == 2 and not loading then
      for op = 1, OPS do
        pset(op, "ratio", nearest_harmonic(params:get(pid(op, "ratio"))))
      end
    end
    dirty()
  end)

  params:add_number("midi_channel", "midi channel", 0, 16, 0, function(p)
    return p:get() == 0 and "all" or tostring(p:get())
  end)

  params:add_number("bend_up", "bend up", 0, 24, 2, function(p)
    return string.format("%.0f st", p:get())
  end)
  params:set_action("bend_up", function() retune() end)
  params:add_number("bend_down", "bend down", 0, 24, 2, function(p)
    return string.format("%.0f st", p:get())
  end)
  params:set_action("bend_down", function() retune() end)

  params:add_control("mod", "mod wheel",
    controlspec.new(0, 1, "lin", 0, 0, ""))
  params:set_action("mod", function(x)
    engine.fmMod(x)
    dirty()
  end)

  for op = 1, OPS do add_op_params(op) end

  params:add_group("macros", 9)
  for i = 1, 3 do
    params:add_control("macro_" .. i, "macro " .. i,
      controlspec.new(0, 1, "lin", 0, 0, ""))
    params:set_action("macro_" .. i, function()
      apply_macro(i)
      dirty()
    end)
    params:add_number("macro_" .. i .. "_dest", "m" .. i .. " dest", 0, 56, 0,
      function(p) return dest_name(p:get()) end)
    params:set_action("macro_" .. i .. "_dest", function() dirty() end)
    params:add_control("macro_" .. i .. "_scale", "m" .. i .. " scale",
      controlspec.new(-100, 100, "lin", 0, 1, "", 0.005))
    params:set_action("macro_" .. i .. "_scale", function() dirty() end)
  end

  -- load factory 1 without double-firing through the preset action
  loading = true
  params:bang()
  loading = false
  load_factory(params:get("preset"))
  engine.amp(params:get("amp"))
  engine.fmMod(params:get("mod"))

  local function midi_event(data)
    local msg = midi.to_msg(data)
    if msg.type == "clock" or msg.type == "start"
        or msg.type == "stop" or msg.type == "continue" then
      return
    end
    local ch = params:get("midi_channel")
    if ch ~= 0 and msg.ch ~= ch then return end
    if msg.type == "note_on" and msg.vel > 0 then
      note_on(msg.note, msg.vel / 127)
    elseif msg.type == "note_off"
        or (msg.type == "note_on" and msg.vel == 0) then
      note_off(msg.note)
    elseif msg.type == "pitchbend" then
      bend = util.clamp((msg.val - 8192) / 8192, -1, 1)
      retune()
    elseif msg.type == "cc" and msg.cc == 1 then
      params:set("mod", msg.val / 127)
    elseif msg.type == "cc" and msg.cc == 123 then
      all_off()
    end
  end

  for i = 1, 16 do
    local d = midi.connect(i)
    d.event = midi_event
  end

  local redraw_metro = metro.init(function()
    if page == 1 then screen_dirty = true end
    if screen_dirty then
      screen_dirty = false
      redraw()
    end
  end, 1 / 15)
  redraw_metro:start()
  dirty()
end

function cleanup()
  all_off()
end

local function op_page()
  if page >= 3 and page <= 6 then return page - 2 end
  return nil
end

function enc(n, d)
  if k2 then k2_used = true end
  if k3 then k3_used = true end
  if n == 1 then
    page = util.clamp(page + d, 1, #PAGES)
    dirty()
    return
  end

  local op = op_page()
  if page == 1 then
    if n == 2 then
      params:delta("preset", d)
    else
      if k1 then
        params:delta("amp", d)
      else
        params:delta("transpose", d)
      end
    end
  elseif PAGES[page] == "env" then
    if n == 2 then
      env_nudge("atk", d * 0.02)
    else
      env_nudge("dec", d * 0.02)
      env_nudge("rel", d * 0.02)
    end
    shape_i = 0
  elseif op then
    if k1 then
      if n == 2 then params:delta(pid(op, "pan"), d)
      else params:delta(pid(op, "envamt"), d) end
    elseif k2 then
      if n == 2 then params:delta(pid(op, "atk"), d)
      else params:delta(pid(op, "dec"), d) end
    elseif k3 then
      if n == 2 then params:delta(pid(op, "sus"), d)
      else params:delta(pid(op, "rel"), d) end
    else
      if n == 2 then params:delta(pid(op, "ratio"), d)
      else params:delta(pid(op, "out"), d) end
    end
  elseif PAGES[page] == "algo" then
    if n == 2 then
      algo_cell = util.clamp(algo_cell + d, 1, 16)
    else
      local from = math.floor((algo_cell - 1) / 4) + 1
      local to = ((algo_cell - 1) % 4) + 1
      params:delta(pid(from, "m" .. to), d)
    end
    dirty()
  elseif PAGES[page] == "macro" then
    if n == 2 then
      if k2 then
        macro_i = util.clamp(macro_i + (d > 0 and 1 or -1), 1, 3)
      else
        params:delta("macro_" .. macro_i .. "_dest", d)
      end
    else
      if k3 then
        params:delta("macro_" .. macro_i, d)
      else
        params:delta("macro_" .. macro_i .. "_scale", d)
      end
    end
    dirty()
  end
end

function key(n, z)
  if n == 1 then
    k1 = z == 1
  elseif n == 2 then
    if z == 1 then
      k2 = true
      k2_used = false
    else
      k2 = false
      if not k2_used then
        if PAGES[page] == "env" then env_random() else morph() end
      end
    end
  elseif n == 3 then
    if z == 1 then
      k3 = true
      k3_used = false
    else
      k3 = false
      if not k3_used then
        if PAGES[page] == "env" then env_next_shape() else randomize() end
      end
    end
  end
  dirty()
end

local function held_names()
  local notes = {}
  for n, _ in pairs(held) do notes[#notes + 1] = n end
  table.sort(notes)
  if #notes == 0 then return "-" end
  local s = {}
  local nshow = math.min(#notes, 4)
  for i = 1, nshow do
    s[i] = MusicUtil.note_num_to_name(notes[i], true)
  end
  if #notes > 4 then s[#s + 1] = "+" end
  return table.concat(s, " ")
end

local function row(y, label, value, hi)
  screen.level(hi and 15 or 4)
  screen.move(0, y)
  screen.text(label)
  screen.level(hi and 15 or 8)
  screen.move(128, y)
  screen.text_right(value)
end

local function env_bar(x, y, w, h, v)
  v = util.clamp(v, 0, 1)
  screen.level(2)
  screen.rect(x, y, w, h)
  screen.stroke()
  if v > 0 then
    local bh = math.max(1, math.floor(v * (h - 2)))
    screen.level(10)
    screen.rect(x + 1, y + h - 1 - bh, w - 2, bh)
    screen.fill()
  end
end

local function held_stats()
  local n, sum, lo, hi = 0, 0, 127, 0
  for note, _ in pairs(held) do
    n = n + 1
    sum = sum + note
    if note < lo then lo = note end
    if note > hi then hi = note end
  end
  if n == 0 then return 0, 60, 0 end
  return n, sum / n, hi - lo
end

-- unit cube
local CUBE_V = {
  {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
  {-1, -1,  1}, {1, -1,  1}, {1, 1,  1}, {-1, 1,  1},
}
local CUBE_E = {
  {1, 2}, {2, 3}, {3, 4}, {4, 1},
  {5, 6}, {6, 7}, {7, 8}, {8, 5},
  {1, 5}, {2, 6}, {3, 7}, {4, 8},
}
-- ops sit in a 2x2 that has depth, so rotation reads as 3d
local OP_HOME = {
  {-0.95,  0.45,  0.7},
  { 0.95,  0.45,  0.7},
  {-0.95, -0.55, -0.7},
  { 0.95, -0.55, -0.7},
}

local function rot3(x, y, z, yaw, pitch, roll)
  local c, s = math.cos(yaw), math.sin(yaw)
  local x1 = x * c - z * s
  local z1 = x * s + z * c
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local y1 = y * cp - z1 * sp
  local z2 = y * sp + z1 * cp
  roll = roll or 0
  local cr, sr = math.cos(roll), math.sin(roll)
  return x1 * cr - y1 * sr, x1 * sr + y1 * cr, z2
end

local DIST = 3.4
local function proj(x, y, z)
  local s = DIST / (DIST + z)
  return 64 + x * s * 36, 30 + y * s * 22, z, s
end

-- wireframe 3d of the 4-op patch: cubes = operators, lines = FM matrix
-- held MIDI notes steer the camera: low keys reverse and tilt up,
-- high keys spin the other way and look down; chord span adds roll.
-- mod wheel fades the drawing in place (gone at 1).
local function draw_patch3d(t)
  local fade = 1 - util.clamp(params:get("mod"), 0, 1)
  if fade < 0.02 then return end
  local function dim(lvl)
    return math.max(1, math.floor(lvl * fade + 0.5))
  end

  local nheld, mean, span = held_stats()
  local sounding = nheld > 0
  local nrm = util.clamp((mean - 60) / 24, -1.5, 1.5)
  local span_n = util.clamp(span / 24, 0, 2)
  local yaw, pitch, roll
  if sounding then
    local dir = (nrm >= 0) and 1 or -1
    yaw = t * dir * (0.5 + math.abs(nrm) * 1.15)
    pitch = 0.28 - nrm * 0.55 + 0.06 * math.sin(t * 0.4)
    roll = nrm * 0.65 + span_n * 0.28 * math.sin(t * 1.3)
  else
    yaw = t * 0.45
    pitch = 0.38 + 0.1 * math.sin(t * 0.35)
    roll = 0.07 * math.sin(t * 0.22)
  end
  local segs = {}

  local function addseg(x1, y1, z1, x2, y2, z2, lvl)
    local X1, Y1, Z1 = proj(x1, y1, z1)
    local X2, Y2, Z2 = proj(x2, y2, z2)
    segs[#segs + 1] = {(Z1 + Z2) * 0.5, X1, Y1, X2, Y2, dim(lvl)}
  end

  local ctr = {}
  for op = 1, OPS do
    local hx, hy, hz = OP_HOME[op][1], OP_HOME[op][2], OP_HOME[op][3]
    local out = util.clamp(params:get(pid(op, "out")), 0, 1)
    local pulse = sounding and (1 + 0.08 * math.sin(t * (7 + math.abs(nrm) * 6) + op)) or 1
    local sz = (0.16 + out * 0.22) * pulse
    local cx, cy, cz = rot3(hx, hy, hz, yaw, pitch, roll)
    ctr[op] = {cx, cy, cz}
    local near = util.clamp(math.floor(7 - cz * 3 + out * 4), 3, 15)
    for e = 1, #CUBE_E do
      local a = CUBE_V[CUBE_E[e][1]]
      local b = CUBE_V[CUBE_E[e][2]]
      local ax, ay, az = rot3(hx + a[1] * sz, hy + a[2] * sz, hz + a[3] * sz, yaw, pitch, roll)
      local bx, by, bz = rot3(hx + b[1] * sz, hy + b[2] * sz, hz + b[3] * sz, yaw, pitch, roll)
      addseg(ax, ay, az, bx, by, bz, near)
    end
  end

  for from = 1, OPS do
    for to = 1, OPS do
      local amt = params:get(pid(from, "m" .. to))
      if math.abs(amt) >= 0.02 then
        local a, b = ctr[from], ctr[to]
        local lvl = util.clamp(math.floor(4 + math.abs(amt) * 6), 4, 13)
        if from == to then
          -- self-feedback: small hoop around the cube
          local r = 0.34
          local nseg = 8
          local px, py, pz
          for i = 0, nseg do
            local ang = (i / nseg) * 6.28318 + t * 2
            local lx = a[1] + math.cos(ang) * r
            local ly = a[2] + math.sin(ang) * r * 0.55
            local lz = a[3]
            if i > 0 then addseg(px, py, pz, lx, ly, lz, lvl) end
            px, py, pz = lx, ly, lz
          end
        else
          addseg(a[1], a[2], a[3], b[1], b[2], b[3], lvl)
        end
      end
    end
  end

  table.sort(segs, function(a, b) return a[1] > b[1] end)
  screen.line_width(1)
  for i = 1, #segs do
    local s = segs[i]
    screen.level(s[6])
    screen.move(s[2], s[3])
    screen.line(s[4], s[5])
    screen.stroke()
  end

  -- op numbers at projected centers, plus a spark riding each mod edge
  for op = 1, OPS do
    local X, Y = proj(ctr[op][1], ctr[op][2], ctr[op][3])
    screen.level(dim(sounding and 15 or 8))
    screen.move(X - 2, Y + 3)
    screen.text(tostring(op))
  end
  for from = 1, OPS do
    for to = 1, OPS do
      if from ~= to then
        local amt = params:get(pid(from, "m" .. to))
        if math.abs(amt) >= 0.02 then
          local u = t * 0.7 + from * 0.19
          u = u - math.floor(u)
          local a, b = ctr[from], ctr[to]
          local X, Y = proj(
            a[1] + (b[1] - a[1]) * u,
            a[2] + (b[2] - a[2]) * u,
            a[3] + (b[3] - a[3]) * u)
          screen.level(dim(15))
          screen.rect(X, Y, 2, 2)
          screen.fill()
        end
      end
    end
  end
end

function redraw()
  if norns.menu.status() then return end
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  screen.level(5)
  screen.move(128, 8)
  if hud and (util.time() - hud_t) < 0.8 then
    screen.level(15)
    screen.text_right(hud)
  else
    screen.text_right(PAGES[page])
  end

  local op = op_page()
  if page == 1 then
    draw_patch3d(util.time())

    local tr = params:get("transpose")
    screen.level(k1 and 4 or 10)
    screen.move(0, 54)
    screen.text(string.format("P%.0f  T%s  A%s",
      params:get("preset"),
      (tr > 0 and "+" or "") .. tostring(tr),
      fmt_num(params:get("amp"), 2)))
    -- screen.level(8)
    -- screen.move(128, 54)
    -- screen.text_right(held_names())
  elseif PAGES[page] == "env" then
    local ops = audible_ops()
    local names = {}
    for i, o in ipairs(ops) do names[i] = tostring(o) end
    screen.level(6)
    screen.move(70, 8)
    screen.text(shape_i > 0 and SHAPES[shape_i].n or "-")

    screen.level(4)
    screen.move(0, 20)
    screen.text("audible ops " .. table.concat(names, " "))

    local a, dc, su, re = env_mean("atk"), env_mean("dec"), env_mean("sus"), env_mean("rel")
    env_bar(0, 27, 10, 20, util.clamp(a, 0, 1))
    env_bar(12, 27, 10, 20, util.clamp(dc, 0, 1))
    env_bar(24, 27, 10, 20, util.clamp(su, 0, 1))
    env_bar(36, 27, 10, 20, util.clamp(re, 0, 1))
    screen.level(15)
    screen.move(50, 34)
    screen.text("A " .. fmt_ms(atk_sec(a)))
    screen.move(50, 43)
    screen.text(string.format("D %s  R %s", fmt_ms(dec_sec(dc)), fmt_ms(rel_sec(re))))
    screen.level(4)
    screen.move(50, 52)
    screen.text("S " .. fmt_num(sus_lvl(su), 2))

    screen.level(3)
    screen.move(0, 63)
    screen.text("K2 rnd  K3 shape")
  elseif op then
    local focus
    if k1 then focus = "pan/env"
    elseif k2 then focus = "A/D"
    elseif k3 then focus = "S/R"
    else focus = "tone" end
    screen.level(6)
    screen.move(70, 8)
    screen.text(focus)

    row(20, "ratio", fmt_num(params:get(pid(op, "ratio")), 3), focus == "tone")
    row(29, "out", fmt_num(params:get(pid(op, "out")), 2), focus == "tone")

    env_bar(0, 33, 10, 14, util.clamp(params:get(pid(op, "atk")), 0, 1))
    env_bar(12, 33, 10, 14, util.clamp(params:get(pid(op, "dec")), 0, 1))
    env_bar(24, 33, 10, 14, util.clamp(params:get(pid(op, "sus")), 0, 1))
    env_bar(36, 33, 10, 14, util.clamp(params:get(pid(op, "rel")), 0, 1))
    screen.level(focus == "A/D" and 15 or (focus == "S/R" and 15 or 4))
    screen.move(50, 40)
    screen.text(string.format("A %s  D %s",
      fmt_ms(atk_sec(params:get(pid(op, "atk")))),
      fmt_ms(dec_sec(params:get(pid(op, "dec"))))))
    screen.move(50, 48)
    screen.text(string.format("S %s  R %s",
      fmt_num(sus_lvl(params:get(pid(op, "sus"))), 2),
      fmt_ms(rel_sec(params:get(pid(op, "rel"))))))

    local src = params:get(pid(op, "envsrc"))
    screen.level(focus == "pan/env" and 15 or 4)
    screen.move(0, 56)
    screen.text(string.format("pan %s  env %s %s",
      fmt_num(params:get(pid(op, "pan")), 2),
      ENVSRC[src + 1],
      fmt_num(params:get(pid(op, "envamt")), 2)))

    screen.level(3)
    screen.move(0, 63)
    local sends = {}
    for d = 1, 4 do
      sends[d] = fmt_num(params:get(pid(op, "m" .. d)), 2)
    end
    screen.text("-> " .. table.concat(sends, " "))
  elseif PAGES[page] == "algo" then
    local from_s = math.floor((algo_cell - 1) / 4) + 1
    local to_s = ((algo_cell - 1) % 4) + 1
    screen.level(6)
    screen.move(70, 8)
    screen.text(string.format("%d->%d", from_s, to_s))

    screen.level(3)
    screen.move(22, 18)
    screen.text("1    2    3    4")
    for from = 1, 4 do
      local y = 18 + from * 10
      screen.level(4)
      screen.move(0, y)
      screen.text(tostring(from))
      for to = 1, 4 do
        local x = 14 + (to - 1) * 28
        local sel = (from == from_s and to == to_s)
        local v = params:get(pid(from, "m" .. to))
        screen.level(sel and 15 or (math.abs(v) > 0.001 and 10 or 3))
        screen.move(x, y)
        screen.text(fmt_num(v, 2))
      end
    end
  elseif PAGES[page] == "macro" then
    for i = 1, 3 do
      local y = 14 + i * 14
      local hi = i == macro_i
      screen.level(hi and 15 or 4)
      screen.move(0, y)
      screen.text("M" .. i)
      screen.move(16, y)
      screen.text(dest_name(params:get("macro_" .. i .. "_dest")))
      screen.move(128, y)
      screen.text_right(string.format("x%s  %s",
        fmt_num(params:get("macro_" .. i .. "_scale"), 2),
        fmt_num(params:get("macro_" .. i), 2)))
    end
    screen.level(3)
    screen.move(0, 63)
    screen.text("K2 which  K3+E3 val")
  end

  screen.update()
end
