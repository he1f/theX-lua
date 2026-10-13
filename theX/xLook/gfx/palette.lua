local palette = {}

local palettes = require("theX.palettes")
local settings_manager = require("theX.utils.settings_manager")
local xlook_settings = settings_manager.new("xlook")

--- Active palette name for gfx decoders (override via palette.set_name).
palette.name = string.lower(tostring(
  xlook_settings.get("palette_name", palettes.DEFAULT_NAME) or palettes.DEFAULT_NAME
))

--- Set current palette by name (looked up in theX.palettes).
---@param name string|nil
---@return nil
function palette.set_name(name)
  if name and name ~= "" then
    palette.name = string.lower(tostring(name))
  else
    palette.name = palettes.DEFAULT_NAME
  end
end

--- Resolved ParsedPalette table for the current name.
---@return table
function palette.default()
  return palettes.get(palette.name)
end

--- Build 16 ZX RGB triples from palette table or current name.
---@param parsed table|string|nil full table, name string, or nil for palette.name
---@return table palette16 list of {r,g,b} at indices 1..16 (ci 0..15)
function palette.build_zx_palette16(parsed)
  if type(parsed) == "string" then
    parsed = palettes.get(parsed)
  elseif not parsed then
    parsed = palettes.get(palette.name)
  end

  local zz = parsed.base_levels[1] or 0
  local nn = parsed.base_levels[2] or 0xCD
  local bb = parsed.base_levels[3] or 0xFF
  local m = parsed.matrix

  local out = {}
  for ci = 0, 15 do
    local bright = (ci >= 8) and 1 or 0
    local color = ci % 8
    local level = (bright == 1) and bb or nn
    local b = ((color % 2) == 1) and level or zz
    local r = ((math.floor(color / 2) % 2) == 1) and level or zz
    local g = ((math.floor(color / 4) % 2) == 1) and level or zz

    local rr = math.floor((r * m[1][1] + g * m[1][2] + b * m[1][3]) / 0x100)
    local gg = math.floor((r * m[2][1] + g * m[2][2] + b * m[2][3]) / 0x100)
    local bb2 = math.floor((r * m[3][1] + g * m[3][2] + b * m[3][3]) / 0x100)

    if rr < 0 then rr = 0 elseif rr > 255 then rr = 255 end
    if gg < 0 then gg = 0 elseif gg > 255 then gg = 255 end
    if bb2 < 0 then bb2 = 0 elseif bb2 > 255 then bb2 = 255 end
    out[ci + 1] = { rr, gg, bb2 }
  end
  return out
end

return palette
