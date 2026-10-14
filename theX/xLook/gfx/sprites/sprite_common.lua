-- Shared helpers for sprite editors → multi-frame GIF.

local sprite_common = {}

local gif_writer = require("theX.xLook.gfx.gif_writer")
local palette = require("theX.xLook.gfx.palette")

-- MSB-first bit masks (Python common.mask).
sprite_common.MASK = { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 }

local DEFAULT_FRAME_DELAY_CS = 50 -- 0.5 s per sprite frame

---@param body string
---@param header_length integer
---@return string
function sprite_common.effective_body(body, header_length)
  local size = #body
  if header_length > 0 and header_length < size then
    return string.sub(body, 1, header_length)
  end
  return body
end

---@return table palette16
function sprite_common.palette16()
  return palette.build_zx_palette16(palette.default())
end

--- Encode sprite frames as animated GIF (one sprite = one frame).
---@param frames string[] indexed pixels
---@param width integer
---@param height integer
---@param palette_rgb table
---@param opts table|nil { delay_cs, transparent_index, disposal }
---@return string gif_bytes
function sprite_common.encode_sprite_gif(frames, width, height, palette_rgb, opts)
  opts = opts or {}
  local delay_cs = opts.delay_cs or DEFAULT_FRAME_DELAY_CS
  if delay_cs < 1 then
    delay_cs = 1
  end
  local enc_opts = {
    disposal = opts.disposal or 2,
    transparent_index = opts.transparent_index,
  }
  -- Always emit multi-frame GCE when >1 sprite; single sprite still ok.
  if #frames == 1 and opts.transparent_index == nil then
    -- still one frame GIF without loop
  end
  return gif_writer.encode(frames, width, height, palette_rgb, delay_cs, enc_opts)
end

sprite_common.DEFAULT_FRAME_DELAY_CS = DEFAULT_FRAME_DELAY_CS

return sprite_common
