local GigaScreen = {}
GigaScreen.__index = GigaScreen

local giga_render = require("theX.xLook.gfx.giga_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")
local palette = require("theX.xLook.gfx.palette")

local SCR_SIZE = 6912
local GIGA_SIZE = SCR_SIZE * 2
local SECTORS_GIGA = 0x1B * 2 -- 54
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
function GigaScreen.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    delay_ms = DEFAULT_DELAY_MS,
  }
  return setmetatable(Object, GigaScreen)
end

function GigaScreen:detect()
  local body = effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end

  if len == GIGA_SIZE then
    return true, "GigaScreen"
  end
  local secs = math.floor((len + 255) / 256)
  if secs == SECTORS_GIGA or len == SECTORS_GIGA * 256 then
    return true, "GigaScreen"
  end
  if #body >= GIGA_SIZE and self.header_length == GIGA_SIZE then
    return true, "GigaScreen"
  end
  return false, nil
end

--- Build animated GIF: giga blend + frame A + frame B.
---@return string|nil gif_bytes
---@return string|nil err
function GigaScreen:get_gif()
  local body = effective_body(self._body, self.header_length)
  if #body < GIGA_SIZE then
    -- pad/truncate like two SCR slots
    if #body < SCR_SIZE then
      return nil, "giga too small"
    end
    body = body .. string.rep("\0", GIGA_SIZE - #body)
  end

  local scr_a = string.sub(body, 1, SCR_SIZE)
  local scr_b = string.sub(body, SCR_SIZE + 1, GIGA_SIZE)
  local rgb = giga_render.render_preview_rgb(scr_a, scr_b, palette.default())

  -- Single static frame (no A/B flicker animation).
  return gif_writer.encode_rgb({ rgb }, giga_render.WIDTH, giga_render.HEIGHT, 1, {
    max_colors = 256,
  }), nil
end

---@return string
function GigaScreen:output_ext()
  return ".gif"
end

return GigaScreen
