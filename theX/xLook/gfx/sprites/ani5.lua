local Ani5 = {}
Ani5.__index = Ani5

local palette = require("theX.xLook.gfx.palette")
local gif_writer = require("theX.xLook.gfx.gif_writer")
local sprite_common = require("theX.xLook.gfx.sprites.sprite_common")

local MASK = sprite_common.MASK
-- Python mask[7-i] for LSB-first flag bits in cell unpackers
local MASK_REV = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80 }

local ANI_SIGNATURE = "GIF animation"
local TICK_MS = 20
local MIN_FRAME_MS = 20
local OVERWRITE = 0
local XOR_UPDATE = 1

---@param body_bytes string
---@param header_type string|nil
---@param header_start integer|nil
---@param header_length integer|nil
---@param meta table|nil
---@return table
function Ani5.new(body_bytes, header_type, header_start, header_length, meta)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
    header_length = tonumber(header_length) or 0,
    meta = meta or {},
  }
  return setmetatable(Object, Ani5)
end

function Ani5:detect()
  local body = sprite_common.effective_body(self._body, self.header_length)
  if #body < 16 then
    return false, nil
  end
  if string.sub(body, 1, #ANI_SIGNATURE) ~= ANI_SIGNATURE then
    return false, nil
  end
  return true, "ani-file v.5-"
end

---@param pix table 1-based 8 bytes
---@param index integer 0-based
---@param value integer
---@param write_mode integer
local function write_pix_byte(pix, index, value, write_mode)
  local i = index + 1
  if write_mode == OVERWRITE then
    pix[i] = value
  else
    pix[i] = bit64.bxor(pix[i] or 0, value)
  end
end

--- pack types 1,3,5,7
---@param pix table
---@param body string
---@param ptr integer 0-based
---@param write_mode integer
---@return integer new_ptr
local function unpack_cell_1_3(pix, body, ptr, write_mode)
  local flags = string.byte(body, ptr + 1) or 0
  ptr = ptr + 1
  local b = 0
  local xb = 0
  for i = 0, 7 do
    if bit64.band(flags, MASK_REV[i + 1]) ~= 0 then
      xb = string.byte(body, ptr + 1) or 0
      ptr = ptr + 1
    end
    b = bit64.bxor(b, xb)
    write_pix_byte(pix, i, b, write_mode)
  end
  return ptr
end

--- pack types 2,4,6,8
---@param pix table
---@param body string
---@param ptr integer 0-based
---@param write_mode integer
---@return integer new_ptr
local function unpack_cell_2_4(pix, body, ptr, write_mode)
  local flags = string.byte(body, ptr + 1) or 0
  ptr = ptr + 1
  local b = 0
  for i = 0, 7 do
    if bit64.band(flags, MASK_REV[i + 1]) ~= 0 then
      local x = string.byte(body, ptr + 1) or 0
      ptr = ptr + 1
      b = bit64.bxor(b, x)
    end
    write_pix_byte(pix, i, b, write_mode)
  end
  return ptr
end

local DECODER_BY_PACK = {
  [1] = { unpack_cell_1_3, OVERWRITE },
  [2] = { unpack_cell_2_4, OVERWRITE },
  [3] = { unpack_cell_1_3, XOR_UPDATE },
  [4] = { unpack_cell_2_4, XOR_UPDATE },
  [5] = { unpack_cell_1_3, OVERWRITE },
  [6] = { unpack_cell_2_4, OVERWRITE },
  [7] = { unpack_cell_1_3, XOR_UPDATE },
  [8] = { unpack_cell_2_4, XOR_UPDATE },
}

---@param cells table[]
---@param palette16 table
---@param w integer
---@param h integer
---@return string rgb24
local function frame2rgb(cells, palette16, w, h)
  local h_cells = math.floor((h + 7) / 8)
  local width_px = 8 * w
  local parts = {}
  local pi = 0
  -- pre-size conceptually row-major
  for y = 0, h - 1 do
    for x = 0, width_px - 1 do
      pi = pi + 1
      parts[pi] = string.char(0, 0, 0)
    end
  end

  local color_cache = {}

  for cy = 0, h_cells - 1 do
    local maxline = 8
    if cy == h_cells - 1 and (h % 8) ~= 0 then
      maxline = h % 8
    end

    for cx = 0, w - 1 do
      local cell = cells[w * cy + cx + 1]
      local color = cell.color or 7
      local cached = color_cache[color]
      local paper, ink
      if not cached then
        paper = bit64.band(bit64.rshift(color, 3), 0x0F)
        ink = bit64.bor(bit64.band(color, 0x07), bit64.band(paper, 0x08))
        color_cache[color] = { paper, ink }
      else
        paper = cached[1]
        ink = cached[2]
      end

      for i = 0, maxline - 1 do
        local dots = cell.pix[i + 1] or 0
        local row = 8 * cy + i
        for bit = 0, 7 do
          local m = MASK[bit + 1]
          local ci = paper
          if bit64.band(dots, m) ~= 0 then
            ci = ink
          end
          local c = palette16[ci + 1] or { 0, 0, 0 }
          local pixel_x = 8 * cx + bit
          local pixel_index = row * width_px + pixel_x
          parts[pixel_index + 1] = string.char(c[1] or 0, c[2] or 0, c[3] or 0)
        end
      end
    end
  end

  return table.concat(parts)
end

---@param body string
---@param length integer
---@param palette16 table
---@return string[] rgb_frames
---@return integer[] delays_cs
---@return integer width
---@return integer height
local function convert_ani5(body, length, palette16)
  if length <= 0 or length > #body then
    length = #body
  end

  local w = string.byte(body, 15) or 0
  local h = string.byte(body, 16) or 0
  if w < 1 or h < 1 then
    return {}, {}, 0, 0
  end

  local h_cells = math.floor((h + 7) / 8)
  local cells_count = w * h_cells
  local cells = {}
  for i = 1, cells_count do
    local pix = {}
    for j = 1, 8 do
      pix[j] = 0
    end
    cells[i] = { pix = pix, color = 7 }
  end

  local ptr = 16 -- 0-based
  local rgb_frames = {}
  local delays_cs = {}
  local guard = 0
  local guard_max = length * 4 + 1024

  while ptr < length do
    guard = guard + 1
    if guard > guard_max then
      break
    end

    local delay = string.byte(body, ptr + 1) or 0
    ptr = ptr + 1
    local pack_type_raw = string.byte(body, ptr + 1) or 0
    ptr = ptr + 1

    local has_color = bit64.band(pack_type_raw, 0x80) ~= 0
    local packed_colors = bit64.band(pack_type_raw, 0x40) ~= 0
    local pack_type = bit64.band(pack_type_raw, 0x3F)

    if pack_type > 8 or delay == 255 then
      break
    end

    if pack_type == 0 then
      for cy = 0, h_cells - 1 do
        local maxline = 8
        if cy == h_cells - 1 and (h % 8) ~= 0 then
          maxline = h % 8
        end
        for i = 0, maxline - 1 do
          for cx = 0, w - 1 do
            local v = string.byte(body, ptr + 1) or 0
            ptr = ptr + 1
            cells[w * cy + cx + 1].pix[i + 1] = v
          end
        end
        if has_color then
          for cx = 0, w - 1 do
            local c = string.byte(body, ptr + 1) or 0
            ptr = ptr + 1
            cells[w * cy + cx + 1].color = c
          end
        end
      end
    else
      local second_level_flag = 0
      local color_flag = 0
      local idx = 0
      local info = DECODER_BY_PACK[pack_type]
      if not info then
        break
      end
      local decoder = info[1]
      local write_mode = info[2]

      for cy = 0, h_cells - 1 do
        for cx = 0, w - 1 do
          local cell = cells[w * cy + cx + 1]

          if idx % 8 == 0 then
            if pack_type > 4 then
              second_level_flag = string.byte(body, ptr + 1) or 0
              ptr = ptr + 1
            end
            if has_color and packed_colors then
              color_flag = string.byte(body, ptr + 1) or 0
              ptr = ptr + 1
            end
            idx = 0
          end

          if pack_type <= 4 then
            ptr = decoder(cell.pix, body, ptr, write_mode)
          else
            if bit64.band(second_level_flag, MASK_REV[idx + 1]) ~= 0 then
              ptr = decoder(cell.pix, body, ptr, write_mode)
            elseif pack_type == 5 or pack_type == 6 then
              for j = 1, 8 do
                cell.pix[j] = 0
              end
            end
          end

          if has_color then
            if not packed_colors then
              cell.color = string.byte(body, ptr + 1) or 0
              ptr = ptr + 1
            elseif bit64.band(color_flag, MASK_REV[idx + 1]) ~= 0 then
              cell.color = string.byte(body, ptr + 1) or 0
              ptr = ptr + 1
            end
          end

          idx = idx + 1
        end
      end
    end

    rgb_frames[#rgb_frames + 1] = frame2rgb(cells, palette16, w, h)
    local ms = delay * TICK_MS
    if ms < MIN_FRAME_MS then
      ms = MIN_FRAME_MS
    end
    local cs = math.floor(ms / 10)
    if cs < 1 then
      cs = 1
    end
    delays_cs[#delays_cs + 1] = cs
  end

  return rgb_frames, delays_cs, 8 * w, h
end

---@return string|nil gif_bytes
---@return string|nil err
function Ani5:get_gif()
  local body = sprite_common.effective_body(self._body, self.header_length)
  local len = self.header_length
  if len <= 0 then
    len = #body
  end

  local palette16 = palette.build_zx_palette16(palette.default())
  local rgb_frames, delays_cs, width, height = convert_ani5(body, len, palette16)
  if #rgb_frames < 1 or width < 1 or height < 1 then
    return nil, "ani5 unpack failed"
  end

  return gif_writer.encode_rgb(rgb_frames, width, height, delays_cs[1] or 2, {
    disposal = 2,
    max_colors = 256,
    frame_delays_cs = delays_cs,
  }), nil
end

---@return string
function Ani5:output_ext()
  return ".gif"
end

return Ani5
