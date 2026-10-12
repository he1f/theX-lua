local gif_writer = {}

---@param n integer
---@return string
local function u16le(n)
  n = n % 65536
  return string.char(n % 256, math.floor(n / 256))
end

--- GIF LZW encode for indexed image (codes 0..clear-1).
---@param indices string one byte per pixel, values 0..color_count-1
---@param min_code_size integer usually 4 for 16 colors
---@return string
local function lzw_encode(indices, min_code_size)
  local clear = 2 ^ min_code_size
  local eoi = clear + 1
  local code_size = min_code_size + 1
  local next_code = eoi + 1
  local max_code = 2 ^ code_size

  -- dictionary: key = prefix_code * 4096 + suffix_byte -> code
  local dict = {}

  local function reset_dict()
    dict = {}
    code_size = min_code_size + 1
    next_code = eoi + 1
    max_code = 2 ^ code_size
  end

  local bit_buf = 0
  local bit_len = 0
  local out = {}

  local function emit(code)
    bit_buf = bit_buf + code * (2 ^ bit_len)
    bit_len = bit_len + code_size
    while bit_len >= 8 do
      out[#out + 1] = string.char(bit_buf % 256)
      bit_buf = math.floor(bit_buf / 256)
      bit_len = bit_len - 8
    end
  end

  reset_dict()
  emit(clear)

  local len = #indices
  if len == 0 then
    emit(eoi)
    if bit_len > 0 then
      out[#out + 1] = string.char(bit_buf % 256)
    end
    return table.concat(out)
  end

  local w = string.byte(indices, 1) or 0
  for i = 2, len do
    local k = string.byte(indices, i) or 0
    local key = w * 4096 + k
    local found = dict[key]
    if found then
      w = found
    else
      emit(w)
      if next_code < 4096 then
        dict[key] = next_code
        next_code = next_code + 1
        if next_code > max_code and code_size < 12 then
          code_size = code_size + 1
          max_code = 2 ^ code_size
        end
      else
        emit(clear)
        reset_dict()
      end
      w = k
    end
  end
  emit(w)
  emit(eoi)
  if bit_len > 0 then
    out[#out + 1] = string.char(bit_buf % 256)
  end
  return table.concat(out)
end

--- Pack LZW bytes into GIF sub-blocks.
---@param data string
---@return string
local function subblocks(data)
  local parts = {}
  local i = 1
  local n = #data
  while i <= n do
    local chunk = math.min(255, n - i + 1)
    parts[#parts + 1] = string.char(chunk)
    parts[#parts + 1] = string.sub(data, i, i + chunk - 1)
    i = i + chunk
  end
  parts[#parts + 1] = string.char(0)
  return table.concat(parts)
end

--- Write animated or static GIF (global palette, no transparency).
---@param frames string[] each: indexed pixels width*height
---@param width integer
---@param height integer
---@param palette16 table {r,g,b} x16
---@param delay_cs integer delay in 1/100 sec per frame
---@return string gif_bytes
function gif_writer.encode(frames, width, height, palette16, delay_cs)
  delay_cs = delay_cs or 64
  if delay_cs < 1 then
    delay_cs = 1
  end

  local parts = {}
  parts[#parts + 1] = "GIF89a"
  parts[#parts + 1] = u16le(width)
  parts[#parts + 1] = u16le(height)
  -- GCT flag, color res 7, sorted 0, GCT size 2^4-1 = 15 -> 16 colors
  parts[#parts + 1] = string.char(0xF3)
  parts[#parts + 1] = string.char(0) -- background
  parts[#parts + 1] = string.char(0) -- aspect

  for i = 1, 16 do
    local c = palette16[i] or { 0, 0, 0 }
    parts[#parts + 1] = string.char(c[1] or 0, c[2] or 0, c[3] or 0)
  end

  -- Netscape loop extension (infinite)
  if #frames > 1 then
    parts[#parts + 1] = string.char(0x21, 0xFF, 0x0B)
    parts[#parts + 1] = "NETSCAPE2.0"
    parts[#parts + 1] = string.char(0x03, 0x01)
    parts[#parts + 1] = u16le(0) -- loop forever
    parts[#parts + 1] = string.char(0x00)
  end

  local min_code_size = 4 -- 16 colors

  for _, frame in ipairs(frames) do
    if #frames > 1 then
      -- Graphic Control Extension
      parts[#parts + 1] = string.char(0x21, 0xF9, 0x04)
      parts[#parts + 1] = string.char(0x04) -- disposal 1 (do not dispose)
      parts[#parts + 1] = u16le(delay_cs)
      parts[#parts + 1] = string.char(0x00) -- no transparent
      parts[#parts + 1] = string.char(0x00)
    end

    -- Image descriptor
    parts[#parts + 1] = string.char(0x2C)
    parts[#parts + 1] = u16le(0) -- left
    parts[#parts + 1] = u16le(0) -- top
    parts[#parts + 1] = u16le(width)
    parts[#parts + 1] = u16le(height)
    parts[#parts + 1] = string.char(0x00) -- no local palette

    parts[#parts + 1] = string.char(min_code_size)
    local lzw = lzw_encode(frame, min_code_size)
    parts[#parts + 1] = subblocks(lzw)
  end

  parts[#parts + 1] = string.char(0x3B) -- trailer
  return table.concat(parts)
end

return gif_writer
