local ColorScreen = {}
ColorScreen.__index = ColorScreen

local palette = require("theX.xLook.gfx.palette")
local scr_render = require("theX.xLook.gfx.scr_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local SCR_SIZE = 6912
local SECTORS_27 = 0x1B
-- Python flash_delay default 640 ms -> GIF cs = 64
local DEFAULT_FLASH_DELAY_MS = 640
local DEFAULT_SCALE = 1

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
function ColorScreen.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    scale = DEFAULT_SCALE,
    flash_delay_ms = DEFAULT_FLASH_DELAY_MS,
  }
  return setmetatable(Object, ColorScreen)
end

function ColorScreen:detect()
  local body = effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end
  -- Match Python ColorScreen: size 6912 or 27 sectors
  if len == SCR_SIZE then
    return true, "Color Screen"
  end
  local secs = math.floor((len + 255) / 256)
  if secs == SECTORS_27 or len == SECTORS_27 * 256 then
    return true, "Color Screen"
  end
  if #body >= SCR_SIZE and (len == 0 or len >= SCR_SIZE) then
    -- only if meta size says screen
    if self.header_length == SCR_SIZE then
      return true, "Color Screen"
    end
  end
  return false, nil
end

--- Build GIF binary for this screen.
---@return string|nil gif_bytes
---@return string|nil err
function ColorScreen:get_gif()
  local body = effective_body(self._body, self.header_length)
  if #body < 6144 then
    return nil, "screen too small"
  end

  local scr = scr_render.normalize_scr(body, #body >= SCR_SIZE)
  local pal = palette.build_zx_palette16(palette.default())

  local frame0, flash = scr_render.render_indexed(scr, false)
  local frames = { frame0 }
  if flash then
    local frame1 = scr_render.render_indexed(scr, true)
    frames[2] = frame1
  end

  local w, h = 256, 192
  local scale = self.scale or 1
  if scale > 1 then
    for i = 1, #frames do
      frames[i], w, h = scr_render.scale_indexed(frames[i], 256, 192, scale)
    end
  end

  local delay_cs = math.floor((self.flash_delay_ms or DEFAULT_FLASH_DELAY_MS) / 10)
  if delay_cs < 1 then
    delay_cs = 1
  end

  return gif_writer.encode(frames, w, h, pal, delay_cs), nil
end

--- File extension produced by this decoder.
---@return string
function ColorScreen:output_ext()
  return ".gif"
end

return ColorScreen
