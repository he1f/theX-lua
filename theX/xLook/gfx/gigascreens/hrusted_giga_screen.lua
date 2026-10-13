local HrustedGigaScreen = {}
HrustedGigaScreen.__index = HrustedGigaScreen

local dehrust_mod = require("theX.xLook.gfx.dehrust")
local giga_render = require("theX.xLook.gfx.giga_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")
local palette = require("theX.xLook.gfx.palette")

local SCR_SIZE = 6912
local GIGA_SIZE = SCR_SIZE * 2
local HR_OFF = 0x103 -- 0-based
local DEFAULT_DELAY_MS = 600

---@param body string
---@param header_length integer
---@return string
local function effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function HrustedGigaScreen.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    delay_ms = DEFAULT_DELAY_MS,
  }
  return setmetatable(Object, HrustedGigaScreen)
end

--- Detect Hrust1-packed gigascreen: "HR" at body+0x103, unpacked size 13824 at +0x105.
function HrustedGigaScreen:detect()
  local body = effective_body(self._body, self.header_length)
  if #body < HR_OFF + 12 then
    return false, nil
  end

  -- HR at file start or at hobeta-style +0x103
  local at_start = string.byte(body, 1) == string.byte("H") and string.byte(body, 2) == string.byte("R")
  local at_off = string.byte(body, HR_OFF + 1) == string.byte("H")
    and string.byte(body, HR_OFF + 2) == string.byte("R")

  if not at_start and not at_off then
    return false, nil
  end

  local base = at_start and 0 or HR_OFF
  -- data_size at base+2 (bytes 2,3 of HR header) — Python: data_size at 0x105 relative body = HR+2
  local data_lo = string.byte(body, base + 2 + 1) or 0
  local data_hi = string.byte(body, base + 3 + 1) or 0
  local data_size = data_lo | (data_hi << 8)
  if data_size ~= GIGA_SIZE then
    return false, nil
  end

  return true, "Hrusted GigaScreen"
end

---@return string|nil gif_bytes
---@return string|nil err
function HrustedGigaScreen:get_gif()
  local body = effective_body(self._body, self.header_length)
  local unpacked, written = dehrust_mod.dehrust(body, GIGA_SIZE)
  if not unpacked or not written or written <= 0 then
    return nil, "dehrust failed"
  end
  if #unpacked < GIGA_SIZE then
    unpacked = unpacked .. string.rep("\0", GIGA_SIZE - #unpacked)
  end

  local scr_a = string.sub(unpacked, 1, SCR_SIZE)
  local scr_b = string.sub(unpacked, SCR_SIZE + 1, GIGA_SIZE)
  local rgb = giga_render.render_preview_rgb(scr_a, scr_b, palette.default())

  -- Single static frame (no A/B flicker animation).
  return gif_writer.encode_rgb({ rgb }, giga_render.WIDTH, giga_render.HEIGHT, 1, {
    max_colors = 256,
  }), nil
end

---@return string
function HrustedGigaScreen:output_ext()
  return ".gif"
end

return HrustedGigaScreen
