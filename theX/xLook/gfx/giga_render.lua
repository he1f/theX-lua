-- Gigascreen blend helpers (truecolor RGB from two SCR index buffers).
-- Reuses scr_render.render_indexed for ZX attribute decode.

local giga_render = {}

local scr_render = require("theX.xLook.gfx.scr_render")
local palette = require("theX.xLook.gfx.palette")

local W, H = 256, 192
local N = W * H

---@param ci integer 0..15
---@return integer 0=Z black, 1=N normal, 2=B bright
local function brightness_group(ci)
  if (ci & 0x07) == 0 then
    return 0
  end
  if (ci & 0x08) ~= 0 then
    return 2
  end
  return 1
end

---@param group_a integer
---@param group_b integer
---@param base_levels integer[]
---@param mix_levels integer[]
---@return integer
local function pair_level(group_a, group_b, base_levels, mix_levels)
  local zz = base_levels[1] or 0
  local nn = base_levels[2] or 0xCD
  local bb = base_levels[3] or 0xFF
  local zn = mix_levels[1] or 0x76
  local nb = mix_levels[2] or 0xE9
  local zb = mix_levels[3] or 0x9F

  if group_a == group_b then
    if group_a == 0 then
      return zz
    end
    if group_a == 1 then
      return nn
    end
    return bb
  end

  local a, b = group_a, group_b
  if (a == 0 and b == 1) or (a == 1 and b == 0) then
    return zn
  end
  if (a == 1 and b == 2) or (a == 2 and b == 1) then
    return nb
  end
  return zb
end

---@param r integer
---@param g integer
---@param b integer
---@param matrix number[][]
---@return integer, integer, integer
local function apply_matrix(r, g, b, matrix)
  local rr = math.floor((r * matrix[1][1] + g * matrix[1][2] + b * matrix[1][3]) / 0x100)
  local gg = math.floor((r * matrix[2][1] + g * matrix[2][2] + b * matrix[2][3]) / 0x100)
  local bb = math.floor((r * matrix[3][1] + g * matrix[3][2] + b * matrix[3][3]) / 0x100)
  if rr < 0 then rr = 0 elseif rr > 255 then rr = 255 end
  if gg < 0 then gg = 0 elseif gg > 255 then gg = 255 end
  if bb < 0 then bb = 0 elseif bb > 255 then bb = 255 end
  return rr, gg, bb
end

---@param ci integer
---@return integer rbit, integer gbit, integer bbit
local function ci_bits(ci)
  local r = ((ci & 0x02) ~= 0) and 1 or 0
  local g = ((ci & 0x04) ~= 0) and 1 or 0
  local b = ((ci & 0x01) ~= 0) and 1 or 0
  return r, g, b
end

--- Indexed SCR → binary string one byte/pixel (0..15). Ignores flash phase.
---@param scr string 6912
---@return string indices
function giga_render.scr_indices(scr)
  local idx = scr_render.render_indexed(scr, false)
  return idx
end

--- Map indexed frame through palette16 to RGB24 string.
---@param indices string
---@param palette16 table
---@return string rgb
function giga_render.indices_to_rgb(indices, palette16)
  local parts = {}
  local n = #indices
  if n > N then
    n = N
  end
  for i = 1, n do
    local ci = string.byte(indices, i) or 0
    local c = palette16[ci + 1] or { 0, 0, 0 }
    parts[i] = string.char(c[1] or 0, c[2] or 0, c[3] or 0)
  end
  return table.concat(parts)
end

--- Blend two SCR buffers into truecolor gigascreen RGB24.
---@param scr_a string
---@param scr_b string
---@param parsed table|nil ParsedPalette
---@param palette16 table|nil
---@return string rgb24
function giga_render.render_preview_rgb(scr_a, scr_b, parsed, palette16)
  parsed = parsed or palette.default()
  palette16 = palette16 or palette.build_zx_palette16(parsed)

  local idx_a = giga_render.scr_indices(scr_a)
  local idx_b = giga_render.scr_indices(scr_b)
  local base_levels = parsed.base_levels or { 0, 0xCD, 0xFF }
  local mix_levels = parsed.mix_levels or { 0x76, 0xE9, 0x9F }
  local matrix = parsed.matrix

  local parts = {}
  for i = 1, N do
    local ci_a = string.byte(idx_a, i) or 0
    local ci_b = string.byte(idx_b, i) or 0
    local r, g, b

    if ci_a == ci_b then
      local c = palette16[ci_a + 1] or { 0, 0, 0 }
      r, g, b = c[1], c[2], c[3]
    else
      local group_a = brightness_group(ci_a)
      local group_b = brightness_group(ci_b)
      local level = pair_level(group_a, group_b, base_levels, mix_levels)

      local ar, ag, ab = ci_bits(ci_a)
      local br, bg, bb = ci_bits(ci_b)

      local function mix_chan(a, bbit)
        local s = a + bbit
        if s == 0 then
          return 0
        end
        if s == 2 then
          return level
        end
        return math.floor(level / 2)
      end

      local raw_r = mix_chan(ar, br)
      local raw_g = mix_chan(ag, bg)
      local raw_b = mix_chan(ab, bb)
      r, g, b = apply_matrix(raw_r, raw_g, raw_b, matrix)
    end

    parts[i] = string.char(r, g, b)
  end
  return table.concat(parts)
end

--- Three RGB frames: giga, scr_a, scr_b (Python order).
---@param scr_a string
---@param scr_b string
---@param parsed table|nil
---@return string[] rgb_frames
---@return table palette16
function giga_render.render_images_rgb(scr_a, scr_b, parsed)
  parsed = parsed or palette.default()
  local palette16 = palette.build_zx_palette16(parsed)
  local giga = giga_render.render_preview_rgb(scr_a, scr_b, parsed, palette16)
  local idx_a = giga_render.scr_indices(scr_a)
  local idx_b = giga_render.scr_indices(scr_b)
  local rgb_a = giga_render.indices_to_rgb(idx_a, palette16)
  local rgb_b = giga_render.indices_to_rgb(idx_b, palette16)
  return { giga, rgb_a, rgb_b }, palette16
end

giga_render.WIDTH = W
giga_render.HEIGHT = H

return giga_render
