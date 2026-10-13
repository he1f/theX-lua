-- Hrust 1.x depacker (port of Python dehrust / HrustStream).
-- Lua 5.1 compatible (no goto / no bit operators).

local dehrust_mod = {}

local OFFSET_MASKS = { [0] = 0, [1] = 0, [2] = 0xFC, [3] = 0xF8, [4] = 0xF0, [5] = 0xE0, [6] = 0xC0, [7] = 0x80, [8] = 0 }

---@param value integer
---@return integer
local function to_signed_16(value)
  if value >= 0x8000 then
    return value - 0x10000
  end
  return value
end

---@param n integer
---@param m integer
---@return integer
local function band(n, m)
  if bit32 then
    return bit32.band(n, m)
  end
  if bit then
    return bit.band(n, m)
  end
  local r, p = 0, 1
  n = math.floor(n)
  m = math.floor(m)
  while n > 0 and m > 0 do
    local nb = n % 2
    local mb = m % 2
    if nb == 1 and mb == 1 then
      r = r + p
    end
    n = math.floor(n / 2)
    m = math.floor(m / 2)
    p = p * 2
  end
  return r
end

---@param a integer
---@param b integer
---@return integer
local function bxor(a, b)
  if bit32 then
    return bit32.bxor(a, b)
  end
  if bit then
    return bit.bxor(a, b)
  end
  local r, p = 0, 1
  a = math.floor(a)
  b = math.floor(b)
  while a > 0 or b > 0 do
    local ab = a % 2
    local bb = b % 2
    if ab ~= bb then
      r = r + p
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    p = p * 2
  end
  return r
end

---@param data string
---@param block_size integer
---@return table
local function new_stream(data, block_size)
  local end_pos = block_size
  if end_pos > #data then
    end_pos = #data
  end
  local stream = {
    data = data,
    pos = 0,
    end_pos = end_pos,
    eof = false,
    bits = 0,
    bit_mask = 0x8000,
  }

  local function get_byte()
    if stream.pos >= stream.end_pos then
      stream.eof = true
      return 0
    end
    local v = string.byte(stream.data, stream.pos + 1)
    stream.pos = stream.pos + 1
    return v
  end

  stream.get_byte = get_byte
  stream.bits = get_byte() + (get_byte() * 256)
  stream.bit_mask = 0x8000

  function stream.get_bit()
    local bit = 0
    if math.floor(stream.bits / stream.bit_mask) % 2 == 1 then
      bit = 1
    end
    stream.bit_mask = math.floor(stream.bit_mask / 2)
    if stream.bit_mask == 0 then
      stream.bits = stream.get_byte() + (stream.get_byte() * 256)
      stream.bit_mask = 0x8000
    end
    return bit
  end

  function stream.get_bits(n)
    local result = 0
    for _ = 1, n do
      result = result * 2 + stream.get_bit()
    end
    return result
  end

  function stream.error()
    return stream.eof
  end

  return stream
end

---@param dst table
---@param dst_pos integer
---@param offset integer
---@param count integer
---@param dst_len integer
---@return integer
local function copy_match(dst, dst_pos, offset, count, dst_len)
  local src_pos = dst_pos + offset
  if src_pos < 0 or src_pos >= dst_pos then
    return -1
  end
  if dst_pos + count > dst_len then
    return -1
  end
  local end_pos = dst_pos + count
  while dst_pos < end_pos do
    dst[dst_pos + 1] = dst[src_pos + 1]
    dst_pos = dst_pos + 1
    src_pos = src_pos + 1
  end
  return dst_pos
end

--- Decompress Hrust 1.x.
---@param source string
---@param dest_len integer
---@return string|nil unpacked
---@return integer|nil written_len
function dehrust_mod.dehrust(source, dest_len)
  if type(source) ~= "string" or #source < 2 then
    return nil, -1
  end
  dest_len = tonumber(dest_len) or 0
  if dest_len <= 0 then
    return nil, -1
  end

  local from_bytes = source
  if string.byte(from_bytes, 1) ~= string.byte("H") or string.byte(from_bytes, 2) ~= string.byte("R") then
    if #from_bytes <= 0x103 then
      return nil, -1
    end
    from_bytes = string.sub(from_bytes, 0x103 + 1)
  end

  if #from_bytes < 12 then
    return nil, -1
  end

  local block_size = string.byte(from_bytes, 5) + (string.byte(from_bytes, 6) * 256)
  local stream = new_stream(string.sub(from_bytes, 13), block_size)

  local dst = {}
  for i = 1, dest_len do
    dst[i] = 0
  end
  local dst_pos = 0
  local dst_len = dest_len

  local get_byte = stream.get_byte
  local get_bit = stream.get_bit
  local get_bits = stream.get_bits

  dst[dst_pos + 1] = get_byte()
  dst_pos = dst_pos + 1

  local no_bits = 2
  local guard = 0
  local guard_max = dest_len * 32 + #from_bytes * 8
  local done = false
  local failed = false

  while not stream.error() and not done and not failed do
    guard = guard + 1
    if guard > guard_max then
      failed = true
      break
    end

    while get_bit() == 1 do
      if dst_pos >= dst_len then
        failed = true
        break
      end
      dst[dst_pos + 1] = get_byte()
      dst_pos = dst_pos + 1
    end
    if failed then
      break
    end

    local length = 0
    while true do
      local bb = get_bits(2)
      length = length + bb
      if bb ~= 0x03 or length == 0x0F then
        break
      end
    end

    local cont = false

    if length == 0 then
      local offset = to_signed_16(0xFFF8 + get_bits(3))
      dst_pos = copy_match(dst, dst_pos, offset, 1, dst_len)
      if dst_pos < 0 then
        failed = true
      end
      cont = true
    elseif length == 1 then
      local code = get_bits(2)

      if code == 2 then
        local b = get_byte()

        if b >= 0xE0 then
          b = band(bxor((b * 2) + 1, 2), 0xFF)

          if b == 0xFF then
            no_bits = no_bits + 1
            cont = true
          else
            local offset = to_signed_16(0xFF00 + b - 0x0F)
            dst_pos = copy_match(dst, dst_pos, offset, 1, dst_len)
            if dst_pos < 0 then
              failed = true
            elseif dst_pos >= dst_len then
              failed = true
            else
              dst[dst_pos + 1] = get_byte()
              dst_pos = dst_pos + 1
              if dst_pos >= dst_len then
                failed = true
              else
                dst[dst_pos + 1] = dst[dst_pos - 2 + 1]
                dst_pos = dst_pos + 1
              end
            end
            cont = true
          end
        else
          local offset = to_signed_16(0xFF00 + b)
          dst_pos = copy_match(dst, dst_pos, offset, 2, dst_len)
          if dst_pos < 0 then
            failed = true
          end
          cont = true
        end

      elseif code == 0 or code == 1 then
        local offset = get_byte() + (code == 0 and 0xFD00 or 0xFE00)
        offset = to_signed_16(offset)
        dst_pos = copy_match(dst, dst_pos, offset, 2, dst_len)
        if dst_pos < 0 then
          failed = true
        end
        cont = true

      else
        local offset = to_signed_16(0xFFE0 + get_bits(5))
        dst_pos = copy_match(dst, dst_pos, offset, 2, dst_len)
        if dst_pos < 0 then
          failed = true
        end
        cont = true
      end
    end

    if not cont and not failed and length == 3 then
      if get_bit() == 1 then
        local offset = to_signed_16(0xFFF0 + get_bits(4))
        dst_pos = copy_match(dst, dst_pos, offset, 1, dst_len)
        if dst_pos < 0 then
          failed = true
        elseif dst_pos >= dst_len then
          failed = true
        else
          dst[dst_pos + 1] = get_byte()
          dst_pos = dst_pos + 1
          if dst_pos >= dst_len then
            failed = true
          else
            dst[dst_pos + 1] = dst[dst_pos - 2 + 1]
            dst_pos = dst_pos + 1
          end
        end
        cont = true
      elseif get_bit() == 1 then
        local total = 2 * (6 + get_bits(4))
        if dst_pos + total > dst_len then
          failed = true
        else
          for _ = 1, total do
            dst[dst_pos + 1] = get_byte()
            dst_pos = dst_pos + 1
          end
        end
        cont = true
      else
        length = get_bits(7)
        if length == 0x0F then
          done = true
          cont = true
        elseif length < 0x0F then
          length = length * 256 + get_byte()
        end
      end
    end

    if not cont and not failed and not done then
      if length == 2 then
        length = length + 1
      end

      local code = get_bits(2)
      local offset

      if code == 1 then
        local b = get_byte()

        if b >= 0xE0 then
          if length > 3 then
            done = true
          else
            b = band(bxor((b * 2) + 1, 3), 0xFF)
            offset = to_signed_16(0xFF00 + b - 0x0F)

            dst_pos = copy_match(dst, dst_pos, offset, 1, dst_len)
            if dst_pos < 0 then
              failed = true
            elseif dst_pos >= dst_len then
              failed = true
            else
              dst[dst_pos + 1] = get_byte()
              dst_pos = dst_pos + 1
              if dst_pos >= dst_len then
                failed = true
              else
                dst[dst_pos + 1] = dst[dst_pos - 2 + 1]
                dst_pos = dst_pos + 1
              end
            end
          end
        else
          offset = to_signed_16(0xFF00 + b)
          dst_pos = copy_match(dst, dst_pos, offset, length, dst_len)
          if dst_pos < 0 then
            failed = true
          end
        end

      elseif code == 0 then
        offset = to_signed_16(0xFE00 + get_byte())
        dst_pos = copy_match(dst, dst_pos, offset, length, dst_len)
        if dst_pos < 0 then
          failed = true
        end

      elseif code == 2 then
        offset = to_signed_16(0xFFE0 + get_bits(5))
        dst_pos = copy_match(dst, dst_pos, offset, length, dst_len)
        if dst_pos < 0 then
          failed = true
        end

      else
        if no_bits > 8 or no_bits < 0 then
          failed = true
        else
          local om = OFFSET_MASKS[no_bits] or 0
          offset = (om + get_bits(no_bits)) * 256 + get_byte()
          offset = to_signed_16(offset)
          dst_pos = copy_match(dst, dst_pos, offset, length, dst_len)
          if dst_pos < 0 then
            failed = true
          end
        end
      end
    end
  end

  if failed then
    return nil, -1
  end

  if dst_pos + 6 > dst_len then
    return nil, -1
  end

  for i = 0, 5 do
    dst[dst_pos + 1 + i] = string.byte(from_bytes, 7 + i)
  end
  dst_pos = dst_pos + 6

  local parts = {}
  for i = 1, dest_len do
    parts[i] = string.char(band(dst[i] or 0, 0xFF))
  end
  return table.concat(parts), dst_pos
end

return dehrust_mod
