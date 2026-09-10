-- run from the script dir: lua test/harness.lua
local P = {v = {}, spec = {}, fmt = {}, actions = {}}
function P:add_separator() end
function P:add_group() end
function P:add_trigger(id)
  self.v[id] = 0
end
function P:add_number(id, _, mn, mx, d)
  self.v[id] = d or mn
  self.spec[id] = {mn, mx}
end
function P:add_control(id, _, cs, f)
  self.v[id] = cs.default
  self.spec[id] = {cs.minval, cs.maxval}
  self.fmt[id] = f
end
function P:set_action(id, fn) self.actions[id] = fn end
function P:bang()
  for id, fn in pairs(self.actions) do
    fn(self.v[id])
  end
end
function P:get(id) return self.v[id] end
function P:set(id, x)
  local s = self.spec[id]
  if s and (x < s[1] - 1e-9 or x > s[2] + 1e-9) then
    error(("OUT OF RANGE %s = %s not in [%s,%s]"):format(id, x, s[1], s[2]))
  end
  self.v[id] = x
  if self.actions[id] then self.actions[id](x) end
end
function P:delta(id, d)
  local s = self.spec[id]
  local x = self.v[id] + d
  if s then
    if x < s[1] then x = s[1] end
    if x > s[2] then x = s[2] end
  end
  self:set(id, x)
end
function P:string(id)
  local f = self.fmt[id]
  if f then return f({get = function() return self.v[id] end}) end
  return tostring(self.v[id])
end
params = P

controlspec = {new = function(mn, mx, w, st, d, u)
  return {minval = mn, maxval = mx, warp = w, default = d, units = u}
end}
util = {
  clamp = function(n, a, b) return math.min(math.max(n, a), b) end,
  round = function(n, q) return math.floor(n / (q or 1) + 0.5) * (q or 1) end,
  time = function() return 0 end,
}
screen = setmetatable({}, {__index = function() return function() end end})
engine = setmetatable({}, {__index = function() return function() end end})
metro = {init = function() return {start = function() end, stop = function() end} end}
midi = {
  connect = function() return {event = nil} end,
  to_msg = function() return {type = "clock"} end,
}
norns = {menu = {status = function() return false end}}

package.preload.musicutil = function()
  return {
    note_num_to_freq = function(n) return 440 * 2 ^ ((n - 69) / 12) end,
    note_num_to_name = function(n) return tostring(n) end,
  }
end

include = function(p)
  p = p:gsub("%.lua$", "")
  if p == "lib/presets" then
    return dofile("lib/presets.lua")
  end
  error("unexpected include " .. p)
end

local src = io.open("feedback4.lua"):read("a")
src = src:gsub("engine%.name%s*=%s*\"[^\"]*\"", "")
src = src:gsub("engine%.name%s*=%s*'[^']*'", "")
assert(load(src, "feedback4.lua"))()
init()

assert(pcall(redraw))
for i = 1, 25 do
  params:set("preset", i)
  assert(pcall(redraw))
end

-- walk pages with E1, then drive keys/encs on each
for _ = 1, 7 do
  for _ = 1, 20 do
    key(2, 1); key(2, 0)
    key(3, 1); key(3, 0)
    enc(2, 1); enc(2, -1)
    enc(3, 1); enc(3, -1)
    key(1, 1)
    enc(2, 1); enc(3, 1)
    key(1, 0)
    key(2, 1); enc(2, 1); enc(3, 1); key(2, 0)
    key(3, 1); enc(2, 1); enc(3, 1); key(3, 0)
    assert(pcall(redraw))
  end
  enc(1, 1)
end
enc(1, -20)
key(2, 1); key(2, 0)
key(3, 1); key(3, 0)
assert(pcall(redraw))

-- generative: many draws so every randomize branch is hit
for i = 1, 5000 do
  key(3, 1); key(3, 0)
  assert(pcall(redraw))
  key(2, 1); key(2, 0)
  assert(pcall(redraw))
end
print("PASS")
