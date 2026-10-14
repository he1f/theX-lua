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
---@param palette_rgb table {r,g,b} list (power-of-two padded preferred)
---@param delay_cs integer delay in 1/100 sec per frame
---@param opts table|nil { disposal = 1|2, color_table_bits = 4..8 }
---@return string gif_bytes
function gif_writer.encode(frames, width, height, palette_rgb, delay_cs, opts)
  delay_cs = delay_cs or 64
  if delay_cs < 1 then
    delay_cs = 1
  end
  opts = opts or {}
  local disposal = opts.disposal or 1
  if disposal < 0 then
    disposal = 0
  end
  if disposal > 3 then
    disposal = 3
  end

  local ncolors = #palette_rgb
  if ncolors < 2 then
    ncolors = 2
  end
  local bits = opts.color_table_bits
  if not bits then
    bits = 1
    while (2 ^ bits) < ncolors and bits < 8 do
      bits = bits + 1
    end
  end
  if bits < 2 then
    bits = 2 -- GIF min practical with LZW min_code_size
  end
  if bits > 8 then
    bits = 8
  end
  local table_size = 2 ^ bits

  local parts = {}
  parts[#parts + 1] = "GIF89a"
  parts[#parts + 1] = u16le(width)
  parts[#parts + 1] = u16le(height)
  -- GCT flag | color res 7 | GCT size bits-1
  parts[#parts + 1] = string.char(bit64.bor(0x80, 0x70, bits - 1))
  parts[#parts + 1] = string.char(0) -- background
  parts[#parts + 1] = string.char(0) -- aspect

  for i = 1, table_size do
    local c = palette_rgb[i] or { 0, 0, 0 }
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

  local min_code_size = bits
  if min_code_size < 2 then
    min_code_size = 2
  end

  local transparent_index = opts.transparent_index -- 0-based, or nil
  local use_gce = (#frames > 1) or (transparent_index ~= nil)
  local gce_flags = bit64.band(bit64.lshift(disposal, 2), 0x1C)
  if transparent_index ~= nil then
    gce_flags = bit64.bor(gce_flags, 0x01)
  end

  for _, frame in ipairs(frames) do
    if use_gce then
      -- Graphic Control Extension
      parts[#parts + 1] = string.char(0x21, 0xF9, 0x04)
      parts[#parts + 1] = string.char(gce_flags)
      parts[#parts + 1] = u16le(delay_cs)
      if transparent_index ~= nil then
        parts[#parts + 1] = string.char(bit64.band(transparent_index, 0xFF))
      else
        parts[#parts + 1] = string.char(0x00)
      end
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

--- Build palette + indexed frames from RGB24 frame list (quantize to <=256).
---@param rgb_frames string[] each width*height*3 bytes
---@param width integer
---@param height integer
---@param max_colors integer|nil default 256
---@return string[] indexed_frames
---@return table palette_rgb
function gif_writer.quantize_rgb_frames(rgb_frames, width, height, max_colors)
  max_colors = max_colors or 256
  if max_colors > 256 then
    max_colors = 256
  end
  if max_colors < 2 then
    max_colors = 2
  end

  local pixel_n = width * height
  local color_count = {}
  local color_order = {}

  local function key_of(r, g, b)
    return bit64.bor(bit64.lshift(r, 16), bit64.lshift(g, 8), b)
  end

  for _, rgb in ipairs(rgb_frames) do
    local need = pixel_n * 3
    if #rgb < need then
      need = #rgb - (#rgb % 3)
    end
    for i = 1, need, 3 do
      local r = string.byte(rgb, i) or 0
      local g = string.byte(rgb, i + 1) or 0
      local b = string.byte(rgb, i + 2) or 0
      local k = key_of(r, g, b)
      if not color_count[k] then
        color_count[k] = 1
        color_order[#color_order + 1] = k
      else
        color_count[k] = color_count[k] + 1
      end
    end
  end

  local palette = {}
  local map = {} -- key -> index 0-based

  if #color_order <= max_colors then
    for i, k in ipairs(color_order) do
      local r = bit64.band(bit64.rshift(k, 16), 0xFF)
      local g = bit64.band(bit64.rshift(k, 8), 0xFF)
      local b = bit64.band(k, 0xFF)
      palette[i] = { r, g, b }
      map[k] = i - 1
    end
  else
    -- popularity + 5-bit RGB buckets as fallback palette seeds
    table.sort(color_order, function(a, b)
      return (color_count[a] or 0) > (color_count[b] or 0)
    end)

    local used_bucket = {}
    for _, k in ipairs(color_order) do
      if #palette >= max_colors then
        break
      end
      local r = bit64.band(bit64.rshift(k, 16), 0xFF)
      local g = bit64.band(bit64.rshift(k, 8), 0xFF)
      local b = bit64.band(k, 0xFF)
      local bucket = bit64.bor(
        bit64.lshift(bit64.rshift(r, 3), 10),
        bit64.lshift(bit64.rshift(g, 3), 5),
        bit64.rshift(b, 3)
      )
      if not used_bucket[bucket] then
        used_bucket[bucket] = true
        palette[#palette + 1] = { r, g, b }
        map[k] = #palette - 1
      end
    end
    -- fill remaining slots with next popular colors
    for _, k in ipairs(color_order) do
      if #palette >= max_colors then
        break
      end
      if map[k] == nil then
        local r = bit64.band(bit64.rshift(k, 16), 0xFF)
        local g = bit64.band(bit64.rshift(k, 8), 0xFF)
        local b = bit64.band(k, 0xFF)
        palette[#palette + 1] = { r, g, b }
        map[k] = #palette - 1
      end
    end
  end

  if #palette == 0 then
    palette[1] = { 0, 0, 0 }
  end

  ---@param r integer
  ---@param g integer
  ---@param b integer
  ---@return integer
  local function nearest(r, g, b)
    local k = key_of(r, g, b)
    local hit = map[k]
    if hit then
      return hit
    end
    local best_i = 0
    local best_d = 1e18
    for i = 1, #palette do
      local c = palette[i]
      local dr = r - c[1]
      local dg = g - c[2]
      local db = b - c[3]
      local d = dr * dr + dg * dg + db * db
      if d < best_d then
        best_d = d
        best_i = i - 1
      end
    end
    map[k] = best_i
    return best_i
  end

  local indexed = {}
  for fi, rgb in ipairs(rgb_frames) do
    local parts = {}
    local need = pixel_n * 3
    if #rgb < need then
      need = #rgb - (#rgb % 3)
    end
    local pi = 1
    for i = 1, need, 3 do
      local r = string.byte(rgb, i) or 0
      local g = string.byte(rgb, i + 1) or 0
      local b = string.byte(rgb, i + 2) or 0
      parts[pi] = string.char(nearest(r, g, b))
      pi = pi + 1
    end
    while pi <= pixel_n do
      parts[pi] = string.char(0)
      pi = pi + 1
    end
    indexed[fi] = table.concat(parts)
  end

  return indexed, palette
end

--- Encode RGB24 frames as GIF (quantized global palette).
---@param rgb_frames string[]
---@param width integer
---@param height integer
---@param delay_cs integer|nil
---@param opts table|nil
---@return string gif_bytes
function gif_writer.encode_rgb(rgb_frames, width, height, delay_cs, opts)
  opts = opts or {}
  local indexed, pal = gif_writer.quantize_rgb_frames(rgb_frames, width, height, opts.max_colors or 256)
  if opts.disposal == nil then
    opts.disposal = 2
  end
  return gif_writer.encode(indexed, width, height, pal, delay_cs or 60, opts)
end

return gif_writer
