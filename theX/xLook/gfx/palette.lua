local palette = {}

--- Default Pulsar-like palette (matches Python theXimg defaults).
---@return table
function palette.default()
  return {
    name = "pulsar",
    base_levels = { 0x00, 0xCD, 0xFF },
    matrix = {
      { 0xFF, 0x00, 0x00 },
      { 0x00, 0xFF, 0x00 },
      { 0x00, 0x00, 0xFF },
    },
  }
end

--- Build 16 ZX RGB triples from palette table.
---@param parsed table|nil
---@return table palette16 list of {r,g,b} at indices 1..16 (ci 0..15)
function palette.build_zx_palette16(parsed)
  parsed = parsed or palette.default()
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
