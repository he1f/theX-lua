local ScreenCrasher = {}
ScreenCrasher.__index = ScreenCrasher

local palette = require("theX.xLook.gfx.palette")
local scr_render = require("theX.xLook.gfx.scr_render")
local gif_writer = require("theX.xLook.gfx.gif_writer")

local SCR_SIZE = 6912
local PIXELS = 6144
local DEPACKER_SKIP = 0xC2
local DEFAULT_FLASH_DELAY_MS = 640
local DEFAULT_SCALE = 1

local SCREEN_CRASHER_SIGNATURE = {
  0xf3, 0xcd, 0x52, 0x00, 0x3b, 0x3b, 0xc1, 0x21, 0x97, 0x00,
  0x09, 0xeb, 0x21, 0x66, 0x00, 0x09, 0x73, 0x23, 0x72,
}

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

---@param data string
---@param sig integer[]
---@param base_off integer|nil 0-based
---@return boolean
local function check_signature(data, sig, base_off)
  base_off = base_off or 0
  if #data < base_off + #sig then
    return false
  end
  for i = 1, #sig do
    if string.byte(data, base_off + i) ~= sig[i] then
      return false
    end
  end
  return true
end

--- Unpack Screen Crasher stream into linear SCR (6912).
---@param source string packed bytes (already sliced past depacker if any)
---@param packed_size integer expected packed payload size
---@return string|nil scr
local function decrash(source, packed_size)
  if type(source) ~= "string" or packed_size < 1 then
    return nil
  end

  local buf = {}
  for i = 1, SCR_SIZE do
    buf[i] = 0
  end

  local from_pos = 0 -- 0-based into source
  local to_pos = 0

  while from_pos < #source do
    local b = string.byte(source, from_pos + 1)
    if b == 0x80 then
      break
    end
    from_pos = from_pos + 1

    if from_pos > packed_size then
      return nil
    end

    local command = b & 0xC0

    if command == 0x80 then
      -- copy literals
      local length = b & 0x3F
      if to_pos > SCR_SIZE - length then
        return nil
      end
      if from_pos > packed_size - length then
        return nil
      end
      for _ = 1, length do
        buf[to_pos + 1] = string.byte(source, from_pos + 1)
        to_pos = to_pos + 1
        from_pos = from_pos + 1
      end

    elseif command == 0xC0 then
      -- RLE
      local length = (b & 0x3F) + 3
      if to_pos > SCR_SIZE - length then
        return nil
      end
      if from_pos >= #source then
        return nil
      end
      local value = string.byte(source, from_pos + 1)
      from_pos = from_pos + 1
      for _ = 1, length do
        buf[to_pos + 1] = value
        to_pos = to_pos + 1
      end

    else
      -- LZ backreference
      local length = ((b & 0xF8) >> 3) + 3
      if from_pos >= #source then
        return nil
      end
      local offset = (256 * (b & 0x07)) + string.byte(source, from_pos + 1)
      from_pos = from_pos + 1

      if to_pos > SCR_SIZE - length then
        return nil
      end
      if to_pos - offset < 0 then
        return nil
      end

      for _ = 1, length do
        buf[to_pos + 1] = buf[to_pos - offset + 1]
        to_pos = to_pos + 1
      end
    end
  end

  -- Success criteria from Python
  if not (from_pos == packed_size - 1 and to_pos == SCR_SIZE) then
    return nil
  end

  local dest = {}
  for i = 1, SCR_SIZE do
    dest[i] = 0
  end

  -- Attributes direct
  for i = PIXELS + 1, SCR_SIZE do
    dest[i] = buf[i]
  end

  -- Columnar pixels → Speccy layout
  for segment = 0, 2 do
    local segment_dest = segment << 11
    local segment_src = 2048 * segment

    for x = 0, 31 do
      local src_base = segment_src + 64 * x

      for y = 0, 63 do
        local line = (y % 8) << 8
        local row = (math.floor(y / 8) % 8) << 5
        local d_off = segment_dest | line | row | x
        dest[d_off + 1] = buf[src_base + y + 1]
      end
    end
  end

  local parts = {}
  for i = 1, SCR_SIZE do
    parts[i] = string.char(dest[i] & 0xFF)
  end
  return table.concat(parts)
end

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@return table
function ScreenCrasher.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    scale = DEFAULT_SCALE,
    flash_delay_ms = DEFAULT_FLASH_DELAY_MS,
    _unpacked = nil,
  }
  return setmetatable(Object, ScreenCrasher)
end

function ScreenCrasher:detect()
  local body = effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end

  -- Python: file_size < header_length - 1 → reject (body must cover stream)
  if #body < len - 1 and len > 0 then
    -- allow if body is at least len
  end
  if #body < 1 or len < 2 then
    return false, nil
  end
  if len > SCR_SIZE then
    return false, nil
  end

  local last_idx = len
  if last_idx > #body then
    last_idx = #body
  end
  if string.byte(body, last_idx) ~= 0x80 then
    return false, nil
  end

  local packed_size = len
  local start = 0
  if len > DEPACKER_SKIP and check_signature(body, SCREEN_CRASHER_SIGNATURE, 0) then
    packed_size = packed_size - DEPACKER_SKIP
    start = DEPACKER_SKIP
  end

  if packed_size < 1 or start >= #body then
    return false, nil
  end

  local slice = string.sub(body, start + 1)
  local scr = decrash(slice, packed_size)
  if not scr then
    return false, nil
  end

  self._unpacked = scr
  return true, "Screen Crusher 2.6 by ASC"
end

---@return string|nil gif_bytes
---@return string|nil err
function ScreenCrasher:get_gif()
  local scr = self._unpacked
  if not scr then
    -- re-detect path
    local ok = self:detect()
    if not ok then
      return nil, "screen crasher unpack failed"
    end
    scr = self._unpacked
  end
  if not scr or #scr < SCR_SIZE then
    return nil, "screen crasher unpack failed"
  end

  local pal = palette.build_zx_palette16(palette.default())
  local frame0, flash = scr_render.render_indexed(scr, false)
  local frames = { frame0 }
  if flash then
    frames[2] = scr_render.render_indexed(scr, true)
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

---@return string
function ScreenCrasher:output_ext()
  return ".gif"
end

return ScreenCrasher
