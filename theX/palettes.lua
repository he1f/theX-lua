-- Named ZX Spectrum display palettes (base levels + 3x3 color matrix).
-- Same layout as Python ParsedPalette / theXimg / Unreal Speccy [COLORS].
-- Unreal string: ZZ,ZN,NN,NB,BB,ZB:rr,rg,rb;gr,gg,gb;br,bg,bb
--   base_levels = { ZZ, NN, BB }
--   mix_levels  = { ZN, NB, ZB }  (scanline / mix; reserved in gfx path)

local palettes = {}

--- Identity RGB matrix (no crosstalk).
local IDENTITY_MATRIX = {
  { 0xFF, 0x00, 0x00 },
  { 0x00, 0xFF, 0x00 },
  { 0x00, 0x00, 0xFF },
}

--- @type table<string, table>
palettes.by_name = {
  -- Default theXimg / Pulsar-style levels
  pulsar = {
    name = "pulsar",
    base_levels = { 0x00, 0xCD, 0xFF }, -- ZZ, NN, BB
    mix_levels = { 0x76, 0xE9, 0x9F }, -- ZN, NB, ZB (reserved / future)
    matrix = IDENTITY_MATRIX,
  },

  -- Unreal Speccy presets (from unreal.ini [COLORS])
  -- Mars=00,80,C0,E0,FF,C8:FF,00,00;40,C0,00;00,40,C0
  mars = {
    name = "mars",
    base_levels = { 0x00, 0xC0, 0xFF },
    mix_levels = { 0x80, 0xE0, 0xC8 },
    matrix = {
      { 0xFF, 0x00, 0x00 },
      { 0x40, 0xC0, 0x00 },
      { 0x00, 0x40, 0xC0 },
    },
  },

  -- Ocean=20,80,A0,C0,E0,A8:D0,00,30;00,D0,30;00,00,FF
  ocean = {
    name = "ocean",
    base_levels = { 0x20, 0xA0, 0xE0 },
    mix_levels = { 0x80, 0xC0, 0xA8 },
    matrix = {
      { 0xD0, 0x00, 0x30 },
      { 0x00, 0xD0, 0x30 },
      { 0x00, 0x00, 0xFF },
    },
  },

  -- Grey=00,80,C0,E0,FF,C8:49,92,24;49,92,24;49,92,24
  grey = {
    name = "grey",
    base_levels = { 0x00, 0xC0, 0xFF },
    mix_levels = { 0x80, 0xE0, 0xC8 },
    matrix = {
      { 0x49, 0x92, 0x24 },
      { 0x49, 0x92, 0x24 },
      { 0x49, 0x92, 0x24 },
    },
  },

  -- alone=00,60,A0,E0,FF,A0:FF,00,00;00,FF,00;00,00,FF
  alone = {
    name = "alone",
    base_levels = { 0x00, 0xA0, 0xFF },
    mix_levels = { 0x60, 0xE0, 0xA0 },
    matrix = IDENTITY_MATRIX,
  },

  -- ATM=00,55,AA,E0,FF,80:FF,00,00;00,FF,00;00,00,FF
  atm = {
    name = "atm",
    base_levels = { 0x00, 0xAA, 0xFF },
    mix_levels = { 0x55, 0xE0, 0x80 },
    matrix = IDENTITY_MATRIX,
  },
}

palettes.DEFAULT_NAME = "pulsar"

--- Sorted list of registered palette names (lowercase keys).
---@return string[] names
function palettes.list_names()
  local names = {}
  for key, _ in pairs(palettes.by_name) do
    table.insert(names, key)
  end
  table.sort(names)
  return names
end

--- Resolve palette table by name (case-insensitive). Falls back to default.
---@param name string|nil
---@return table parsed_palette
function palettes.get(name)
  local key = string.lower(tostring(name or palettes.DEFAULT_NAME))
  local p = palettes.by_name[key]
  if p then
    return p
  end
  return palettes.by_name[palettes.DEFAULT_NAME]
end

return palettes
