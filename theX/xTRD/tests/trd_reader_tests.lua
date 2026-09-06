local M = {}

local function run()
local function join_path(left_path, right_path)
  if left_path:match("[\\/]$") then
    return left_path .. right_path
  end
  return left_path .. "\\" .. right_path
end

local function ensure_dir(path_value)
  local command = 'mkdir "' .. path_value .. '" >nul 2>nul'
  os.execute(command)
end

local function set_read_only(path_value, enabled)
  local flag = enabled and "+R" or "-R"
  local command = 'attrib ' .. flag .. ' "' .. path_value .. '" >nul 2>nul'
  os.execute(command)
end

local function repeat_zeroes(count_value)
  if count_value <= 0 then
    return ""
  end
  return string.rep("\0", count_value)
end

local function write_at(file_handle, offset_zero_based, bytes_value)
  file_handle:seek("set", offset_zero_based)
  file_handle:write(bytes_value)
end

local function pack_le16(value)
  local low = value % 256
  local high = math.floor(value / 256) % 256
  return string.char(low, high)
end

local function right_pad(text_value, target_length)
  local out = text_value or ""
  if #out > target_length then
    return out:sub(1, target_length)
  end
  if #out < target_length then
    out = out .. string.rep(" ", target_length - #out)
  end
  return out
end

local function bxor_byte(left_value, right_value)
  local left_num = tonumber(left_value) or 0
  local right_num = tonumber(right_value) or 0
  local result = 0
  local bit_value = 1
  while left_num > 0 or right_num > 0 do
    local left_bit = left_num % 2
    local right_bit = right_num % 2
    if left_bit ~= right_bit then
      result = result + bit_value
    end
    left_num = math.floor(left_num / 2)
    right_num = math.floor(right_num / 2)
    bit_value = bit_value * 2
  end
  return result % 256
end

local function calc_dirsys_crc(payload)
  local crc_high = 0
  local crc_low = 0
  for pos = 1, #payload do
    local byte_value = string.byte(payload, pos) or 0
    local prev_high = crc_high
    local prev_low = crc_low
    local e_value = bxor_byte(prev_low, byte_value)

    crc_high = 0
    crc_low = 0
    for _ = 1, 8 do
      local old_high = crc_high
      local old_low = crc_low

      crc_high = math.floor(old_high / 2) + ((old_low % 2) * 128)
      crc_low = math.floor(old_low / 2) + ((old_high % 2) * 128)

      if (bxor_byte(e_value, old_low) % 2) == 1 then
        crc_high = bxor_byte(crc_high, 0xA0)
        crc_low = bxor_byte(crc_low, 0x01)
      end
      e_value = math.floor(e_value / 2)
    end

    crc_low = bxor_byte(prev_high, crc_low)
    crc_high = bxor_byte(prev_low, crc_high)
  end
  return crc_high, crc_low
end

local function build_trd(path_value, spec)
  local sector_size = 256
  local sectors_per_track = 16
  local image_size = 2 * 80 * 16 * sector_size
  local service_base = 8 * sector_size
  local dirsys_base = 9 * sector_size
  local first_sector = spec.first_sector
  local first_track = spec.first_track
  local payload = spec.payload or ""
  local enable_dirsys = spec.enable_dirsys == true
  local corrupt_crc = spec.corrupt_crc == true

  local file_handle = assert(io.open(path_value, "wb"))
  file_handle:write(repeat_zeroes(image_size))
  file_handle:close()

  file_handle = assert(io.open(path_value, "r+b"))

  write_at(file_handle, 0, right_pad("FILE", 8))
  write_at(file_handle, 8, string.char(string.byte("C")))
  write_at(file_handle, 9, pack_le16(0))
  write_at(file_handle, 11, pack_le16(#payload))
  write_at(file_handle, 13, string.char(1))
  write_at(file_handle, 14, string.char(first_sector))
  write_at(file_handle, 15, string.char(first_track))

  write_at(file_handle, ((first_track * sectors_per_track) + first_sector) * sector_size, payload)

  write_at(file_handle, service_base + 224, string.char(0x00))
  write_at(file_handle, service_base + 225, string.char(1))
  write_at(file_handle, service_base + 226, string.char(1))
  write_at(file_handle, service_base + 227, string.char(0x16))
  write_at(file_handle, service_base + 228, string.char(1))
  write_at(file_handle, service_base + 229, pack_le16(100))
  write_at(file_handle, service_base + 231, string.char(0x10))
  write_at(file_handle, service_base + 241, string.char(0))
  write_at(file_handle, service_base + 242, right_pad("TESTDISK", 8))

  if enable_dirsys then
    write_at(file_handle, dirsys_base + 2, "DirSys")
    write_at(file_handle, dirsys_base + 8, "1")
    write_at(file_handle, dirsys_base + 9, "00")

    write_at(file_handle, dirsys_base + 0x0B + 0, string.char(2))
    write_at(file_handle, dirsys_base + 0x8B + 0, string.char(0))
    write_at(file_handle, dirsys_base + 0x8B + 1, string.char(1))

    write_at(file_handle, dirsys_base + 0x10B, right_pad("GAMES", 11))
    write_at(file_handle, dirsys_base + 0x116, right_pad("ACTION", 11))
    write_at(file_handle, dirsys_base + 0x121, string.char(0))

    local crc_start = dirsys_base + 2
    local crc_end = dirsys_base + 0x120
    local crc_len = crc_end - crc_start + 1
    file_handle:seek("set", crc_start)
    local crc_payload = assert(file_handle:read(crc_len))
    local crc_high, crc_low = calc_dirsys_crc(crc_payload)
    if corrupt_crc then
      crc_high = bxor_byte(crc_high, 0x01)
    end
    write_at(file_handle, dirsys_base + 0, string.char(crc_high))
    write_at(file_handle, dirsys_base + 1, string.char(crc_low))
  end

  file_handle:close()
end

local function write_entry_header(path_value, slot_index, spec)
  local first_sector = tonumber(spec.first_sector) or 0
  local first_track = tonumber(spec.first_track) or 1
  local payload = type(spec.payload) == "string" and spec.payload or ""
  local file_type = type(spec.file_type) == "string" and spec.file_type ~= "" and spec.file_type:sub(1, 1) or "C"
  local sectors = tonumber(spec.sectors) or 1
  local start_value = tonumber(spec.start_value) or 0
  local size_value = tonumber(spec.size_value) or #payload

  local file_handle = assert(io.open(path_value, "r+b"))
  local header_offset = slot_index * 16
  write_at(file_handle, header_offset, right_pad(spec.file_name or "FILE", 8))
  write_at(file_handle, header_offset + 8, string.char(string.byte(file_type)))
  write_at(file_handle, header_offset + 9, pack_le16(start_value))
  write_at(file_handle, header_offset + 11, pack_le16(size_value))
  write_at(file_handle, header_offset + 13, string.char(sectors))
  write_at(file_handle, header_offset + 14, string.char(first_sector))
  write_at(file_handle, header_offset + 15, string.char(first_track))
  write_at(file_handle, ((first_track * 16) + first_sector) * 256, payload)
  file_handle:close()
end

local function find_entry_by_slot(parsed, slot_index)
  if type(parsed) ~= "table" or type(parsed.entries) ~= "table" then
    return nil
  end
  for i = 1, #parsed.entries do
    local entry = parsed.entries[i]
    if type(entry) == "table" and tonumber(entry.trdos_dir_slot) == slot_index then
      return entry
    end
  end
  return nil
end

local function count_entries_by_name_and_type(parsed, trdos_name, trdos_type)
  if type(parsed) ~= "table" or type(parsed.entries) ~= "table" then
    return 0
  end
  local count = 0
  for i = 1, #parsed.entries do
    local entry = parsed.entries[i]
    if type(entry) == "table" and entry.trdos_name == trdos_name and entry.trdos_type == trdos_type then
      count = count + 1
    end
  end
  return count
end

local function find_entry_by_name_and_type(parsed, trdos_name, trdos_type)
  if type(parsed) ~= "table" or type(parsed.entries) ~= "table" then
    return nil
  end
  for i = 1, #parsed.entries do
    local entry = parsed.entries[i]
    if type(entry) == "table" and entry.trdos_name == trdos_name and entry.trdos_type == trdos_type then
      return entry
    end
  end
  return nil
end

local temp_root = os.getenv("TEMP") or os.getenv("TMP") or "."
local test_root = join_path(temp_root, "xtrd_tests_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
ensure_dir(test_root)

build_trd(join_path(test_root, "sec0.trd"), { first_sector = 0, first_track = 1, payload = "SEC0" })
build_trd(join_path(test_root, "sec1.trd"), { first_sector = 1, first_track = 1, payload = "SEC1" })
build_trd(join_path(test_root, "sec15.trd"), { first_sector = 15, first_track = 1, payload = "S15!" })
build_trd(join_path(test_root, "sec16_invalid.trd"), { first_sector = 16, first_track = 1, payload = "BAD!" })
build_trd(join_path(test_root, "dirsys_ok.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "DIRS",
  enable_dirsys = true,
  corrupt_crc = false,
})
build_trd(join_path(test_root, "dirsys_bad_crc.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "DIRS",
  enable_dirsys = true,
  corrupt_crc = true,
})
build_trd(join_path(test_root, "dirsys_create.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "MKDR",
})
build_trd(join_path(test_root, "dirsys_ro.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "ROFS",
  enable_dirsys = true,
  corrupt_crc = false,
})
build_trd(join_path(test_root, "entry_edit.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "EDIT",
})
build_trd(join_path(test_root, "entry_add.trd"), {
  first_sector = 0,
  first_track = 1,
  payload = "BASE",
  enable_dirsys = true,
  corrupt_crc = false,
})
write_entry_header(join_path(test_root, "entry_edit.trd"), 1, {
  file_name = "SECOND",
  file_type = "B",
  start_value = 22222,
  size_value = 4,
  sectors = 1,
  first_sector = 1,
  first_track = 1,
  payload = "DUP2",
})

win = {
  Uuid = function(value)
    return value
  end,
  MultiByteToWideChar = function(value, _cp)
    return value
  end,
  Utf16ToUtf8 = function(value)
    return value
  end,
}
far = {
  ConvertPath = function(path_value, _mode)
    return path_value
  end,
  Flags = {
    FILE_ATTRIBUTE_HIDDEN = 0x2,
  },
}
mf = {
  printconsole = function()
  end,
}

package.loaded["theX"] = {}
local source_info = debug.getinfo(1, "S")
local source_path = type(source_info) == "table" and source_info.source or ""
source_path = type(source_path) == "string" and source_path:gsub("^@", "") or ""
local normalized_path = source_path:gsub("\\", "/")
local scripts_root = normalized_path:match("^(.*)/theX/xTRD/tests/[^/]+$")
if type(scripts_root) ~= "string" or scripts_root == "" then
  scripts_root = "d:/lua"
end
package.path = scripts_root .. "/?.lua;" .. scripts_root .. "/?/init.lua;" .. package.path

local trd_reader = require("theX.formats.trd_reader")
local xtrd_archive = require("theX.xTRD.core.archive")

local failed_count = 0

local function fail(message)
  io.stderr:write(message .. "\n")
  failed_count = failed_count + 1
end

local function expect(condition_value, error_msg)
  if not condition_value then
    fail(error_msg)
  end
end

local function read_case(case_name, expect_ok, expect_prefix)
  local file_path = join_path(test_root, case_name)
  local parsed, read_error = trd_reader.read(file_path)
  if expect_ok then
    if not parsed then
      fail(case_name .. ": expected open success, got error: " .. tostring(read_error))
      return
    end
    local first_entry = parsed.entries and parsed.entries[1] or nil
    local data_prefix = type(first_entry) == "table" and string.sub(first_entry.data or "", 1, 4) or ""
    expect(data_prefix == expect_prefix, case_name .. ": wrong payload prefix: " .. tostring(data_prefix))
  else
    if parsed then
      fail(case_name .. ": expected open error, got success")
      return
    end
  end
end

read_case("sec0.trd", true, "SEC0")
read_case("sec1.trd", true, "SEC1")
read_case("sec15.trd", true, "S15!")
read_case("sec16_invalid.trd", false, "")

local parsed_ok = trd_reader.read(join_path(test_root, "dirsys_ok.trd"))
if not parsed_ok then
  fail("dirsys_ok.trd: open failed")
else
  local ds_meta = parsed_ok.meta and parsed_ok.meta.dirsys or nil
  expect(type(ds_meta) == "table" and ds_meta.present == true, "dirsys_ok.trd: DirSys not detected")
  expect(ds_meta.crc_ok == true, "dirsys_ok.trd: CRC expected true")
  local first_entry = parsed_ok.entries and parsed_ok.entries[1] or nil
  expect(type(first_entry) == "table", "dirsys_ok.trd: missing first entry")
  if type(first_entry) == "table" then
    expect(first_entry.dirsys_dir_index == 2, "dirsys_ok.trd: wrong dir index")
    expect(first_entry.dirsys_path == "/GAMES/ACTION", "dirsys_ok.trd: wrong dir path")
  end
end

local parsed_bad_crc = trd_reader.read(join_path(test_root, "dirsys_bad_crc.trd"))
if not parsed_bad_crc then
  fail("dirsys_bad_crc.trd: open failed")
else
  local ds_meta = parsed_bad_crc.meta and parsed_bad_crc.meta.dirsys or nil
  expect(type(ds_meta) == "table" and ds_meta.present == true, "dirsys_bad_crc.trd: DirSys not detected")
  expect(ds_meta.crc_ok == false, "dirsys_bad_crc.trd: CRC expected false")
end

local add_case_path = join_path(test_root, "entry_add.trd")
local add_result, add_result_error = trd_reader.add_entries(add_case_path, 1, {
  {
    trdos_name = "NEWFILE",
    trdos_type = "C",
    trdos_start = 4096,
    raw_file = "HELLO",
    size = 5,
    trdos_params = { param1 = 4096, param2 = 5 },
  },
})
expect(type(add_result) == "table", "entry_add.trd: add_entries failed: " .. tostring(add_result_error))
local parsed_after_add = trd_reader.read(add_case_path)
if not parsed_after_add then
  fail("entry_add.trd: open failed after add_entries")
else
  expect(parsed_after_add.meta.files_count == 2, "entry_add.trd: expected files_count=2 after add")
  local added_entry = find_entry_by_name_and_type(parsed_after_add, "NEWFILE", "C")
  expect(type(added_entry) == "table", "entry_add.trd: added entry NEWFILE<C> not found")
  if type(added_entry) == "table" then
    expect(added_entry.trdos_start == 4096, "entry_add.trd: wrong start for added entry")
    expect(added_entry.data == "HELLO", "entry_add.trd: wrong payload for added entry")
    expect(added_entry.dirsys_dir_index == 1, "entry_add.trd: wrong DirSys parent for added entry")
  end
end

local duplicate_add, duplicate_add_error = trd_reader.add_entries(add_case_path, 0, {
  {
    trdos_name = "NEWFILE",
    trdos_type = "C",
    trdos_start = 1,
    raw_file = "DUPL",
  },
})
expect(type(duplicate_add) == "table", "entry_add.trd: duplicate add should be allowed: " .. tostring(duplicate_add_error))
local parsed_after_duplicate_add = trd_reader.read(add_case_path)
if not parsed_after_duplicate_add then
  fail("entry_add.trd: open failed after duplicate add")
else
  expect(parsed_after_duplicate_add.meta.files_count == 3, "entry_add.trd: expected files_count=3 after duplicate add")
  local duplicate_count = count_entries_by_name_and_type(parsed_after_duplicate_add, "NEWFILE", "C")
  expect(duplicate_count >= 2, "entry_add.trd: expected at least two NEWFILE<C> entries")
end

local too_large_payload = string.rep("A", 256 * 256)
local oversized_add, oversized_add_error = trd_reader.add_entries(add_case_path, 0, {
  {
    trdos_name = "BIGFILE",
    trdos_type = "C",
    trdos_start = 0,
    raw_file = too_large_payload,
  },
})
expect(oversized_add == nil, "entry_add.trd: oversized add must be rejected")
expect(
  type(oversized_add_error) == "string" and oversized_add_error:find("255 sectors", 1, true) ~= nil,
  "entry_add.trd: expected oversized-add error message"
)

local edit_case_path = join_path(test_root, "entry_edit.trd")
local updated_entry, updated_entry_error = trd_reader.update_entry_header(
  edit_case_path,
  0,
  "RENAMED",
  "D",
  16384
)
expect(type(updated_entry) == "table", "entry_edit.trd: update_entry_header failed: " .. tostring(updated_entry_error))
local parsed_after_update = trd_reader.read(edit_case_path)
if not parsed_after_update then
  fail("entry_edit.trd: open failed after header update")
else
  local updated_slot0 = find_entry_by_slot(parsed_after_update, 0)
  expect(type(updated_slot0) == "table", "entry_edit.trd: updated slot #0 not found")
  if type(updated_slot0) == "table" then
    expect(updated_slot0.trdos_name == "RENAMED", "entry_edit.trd: wrong updated name")
    expect(updated_slot0.trdos_type == "D", "entry_edit.trd: wrong updated type")
    expect(updated_slot0.trdos_start == 16384, "entry_edit.trd: wrong updated start")
  end
end

local duplicate_update, duplicate_update_error = trd_reader.update_entry_header(
  edit_case_path,
  0,
  "SECOND",
  "B",
  1
)
expect(type(duplicate_update) == "table", "entry_edit.trd: duplicate name+type should be allowed: " .. tostring(duplicate_update_error))
local parsed_after_duplicate_update = trd_reader.read(edit_case_path)
if not parsed_after_duplicate_update then
  fail("entry_edit.trd: open failed after duplicate update")
else
  local duplicate_count = count_entries_by_name_and_type(parsed_after_duplicate_update, "SECOND", "B")
  expect(duplicate_count >= 2, "entry_edit.trd: expected duplicate SECOND<B> entries")
end

local invalid_start_update, invalid_start_error = trd_reader.update_entry_header(
  edit_case_path,
  0,
  "SLOT0",
  "C",
  70000
)
expect(invalid_start_update == nil, "entry_edit.trd: invalid start must be rejected")
expect(
  type(invalid_start_error) == "string" and invalid_start_error:find("0..65535", 1, true) ~= nil,
  "entry_edit.trd: expected invalid-start error message"
)

local create_case_path = join_path(test_root, "dirsys_create.trd")
local create_without_install, create_without_install_error = trd_reader.create_directory(
  create_case_path,
  0,
  "GAMES",
  false
)
expect(create_without_install == nil, "dirsys_create.trd: expected create failure without DirSys install")
expect(
  type(create_without_install_error) == "string" and create_without_install_error:find("not installed", 1, true) ~= nil,
  "dirsys_create.trd: expected not-installed error"
)

local created_root, created_root_error = trd_reader.create_directory(create_case_path, 0, "GAMES", true)
expect(type(created_root) == "table", "dirsys_create.trd: root directory create failed: " .. tostring(created_root_error))
if type(created_root) == "table" then
  expect(created_root.dirsys_installed == true, "dirsys_create.trd: DirSys install flag expected true")
  expect(created_root.created_dir_index == 1, "dirsys_create.trd: root dir index expected 1")
end

local parsed_created = trd_reader.read(create_case_path)
if not parsed_created then
  fail("dirsys_create.trd: open failed after root create")
else
  local ds_meta = parsed_created.meta and parsed_created.meta.dirsys or nil
  expect(type(ds_meta) == "table" and ds_meta.present == true, "dirsys_create.trd: DirSys not detected after install")
  local root_dir = type(ds_meta) == "table" and ds_meta.directories and ds_meta.directories[1] or nil
  expect(type(root_dir) == "table", "dirsys_create.trd: missing root directory #1")
  if type(root_dir) == "table" then
    expect(root_dir.name == "GAMES", "dirsys_create.trd: wrong root dir name")
    expect(root_dir.parent_index == 0, "dirsys_create.trd: wrong root dir parent")
  end
end

local created_nested, created_nested_error = trd_reader.create_directory(create_case_path, 1, "ACTION", false)
expect(type(created_nested) == "table", "dirsys_create.trd: nested directory create failed: " .. tostring(created_nested_error))
if type(created_nested) == "table" then
  expect(created_nested.created_dir_index == 2, "dirsys_create.trd: nested dir index expected 2")
end

local parsed_nested = trd_reader.read(create_case_path)
if not parsed_nested then
  fail("dirsys_create.trd: open failed after nested create")
else
  local ds_meta = parsed_nested.meta and parsed_nested.meta.dirsys or nil
  local nested_dir = type(ds_meta) == "table" and ds_meta.directories and ds_meta.directories[2] or nil
  expect(type(nested_dir) == "table", "dirsys_create.trd: missing nested directory #2")
  if type(nested_dir) == "table" then
    expect(nested_dir.name == "ACTION", "dirsys_create.trd: wrong nested dir name")
    expect(nested_dir.parent_index == 1, "dirsys_create.trd: wrong nested dir parent")
  end
  local first_entry = type(parsed_nested.entries) == "table" and parsed_nested.entries[1] or nil
  if type(first_entry) == "table" then
    expect(first_entry.dirsys_dir_index == 0, "dirsys_create.trd: file dir index must stay at root")
    expect(first_entry.dirsys_path == "/", "dirsys_create.trd: file dir path must stay at root")
  end
end

local duplicate_result, duplicate_error = trd_reader.create_directory(create_case_path, 1, "ACTION", false)
expect(duplicate_result == nil, "dirsys_create.trd: duplicate directory must be rejected")
expect(
  type(duplicate_error) == "string" and duplicate_error:find("already exists", 1, true) ~= nil,
  "dirsys_create.trd: duplicate error text mismatch"
)

local long_name_result, long_name_error = trd_reader.create_directory(create_case_path, 0, "123456789012", false)
expect(long_name_result == nil, "dirsys_create.trd: long directory name must be rejected")
expect(
  type(long_name_error) == "string" and long_name_error:find("too long", 1, true) ~= nil,
  "dirsys_create.trd: long-name error text mismatch"
)

local function dir_exists(dirsys_meta, parent_index, dir_name)
  if type(dirsys_meta) ~= "table" or type(dirsys_meta.directories) ~= "table" then
    return false
  end
  for _, directory_node in pairs(dirsys_meta.directories) do
    if type(directory_node) == "table" and directory_node.is_deleted ~= true then
      if directory_node.parent_index == parent_index and directory_node.name == dir_name then
        return true
      end
    end
  end
  return false
end

local ro_case_path = join_path(test_root, "dirsys_ro.trd")
set_read_only(ro_case_path, true)
local ro_create_result, ro_create_error = trd_reader.create_directory(ro_case_path, 0, "ROTEST", false)
set_read_only(ro_case_path, false)
expect(ro_create_result == nil, "dirsys_ro.trd: create must fail on read-only file")
expect(
  type(ro_create_error) == "string" and ro_create_error ~= "",
  "dirsys_ro.trd: expected write error message"
)
local parsed_ro = trd_reader.read(ro_case_path)
if not parsed_ro then
  fail("dirsys_ro.trd: open failed after RO create attempt")
else
  local ro_meta = parsed_ro.meta and parsed_ro.meta.dirsys or nil
  expect(type(ro_meta) == "table" and ro_meta.present == true, "dirsys_ro.trd: DirSys should remain present")
  expect(not dir_exists(ro_meta, 0, "ROTEST"), "dirsys_ro.trd: ROTEST directory must not be created")
end

local function has_item(items, file_name)
  if type(items) ~= "table" then
    return false
  end
  for i = 1, #items do
    local item = items[i]
    if type(item) == "table" and item.FileName == file_name then
      return true
    end
  end
  return false
end

local dirsys_meta_for_panel = nil
if type(parsed_ok) == "table" and type(parsed_ok.meta) == "table" and type(parsed_ok.meta.dirsys) == "table" then
  dirsys_meta_for_panel = parsed_ok.meta.dirsys
else
  dirsys_meta_for_panel = { present = false }
end

local panel_obj = xtrd_archive.new("dummy.trd", {
  {
    name = "ROOT<C>",
    pc_name = "ROOT.$C",
    data = "ROOT",
    size = 4,
    trdos_start = 0,
    trdos_sectors = 1,
    trdos_type = "C",
    trdos_description = "Code",
    comment = "root",
    trdos_params = { trk = 1 },
    dirsys_dir_index = 0,
    dirsys_path = "/",
  },
  {
    name = "NEST<C>",
    pc_name = "NEST.$C",
    data = "NEST",
    size = 4,
    trdos_start = 0,
    trdos_sectors = 1,
    trdos_type = "C",
    trdos_description = "Code",
    comment = "nested",
    trdos_params = { trk = 7 },
    dirsys_dir_index = 2,
    dirsys_path = "/GAMES/ACTION",
  },
}, {
  dirsys = dirsys_meta_for_panel,
})

local root_items = xtrd_archive.to_panel_items(panel_obj)
expect(has_item(root_items, "GAMES"), "archive panel mapping: root must contain GAMES directory")
expect(has_item(root_items, "ROOT.$C"), "archive panel mapping: root must contain root file")
expect(not has_item(root_items, "NEST.$C"), "archive panel mapping: root must not contain nested file")

xtrd_archive.set_current_dir_index(panel_obj, 1)
local level1_items = xtrd_archive.to_panel_items(panel_obj)
expect(has_item(level1_items, "ACTION"), "archive panel mapping: /GAMES must contain ACTION directory")
expect(not has_item(level1_items, "ROOT.$C"), "archive panel mapping: /GAMES must not contain root file")
expect(not has_item(level1_items, "NEST.$C"), "archive panel mapping: /GAMES must not contain /GAMES/ACTION file")
expect(xtrd_archive.get_current_dir_path(panel_obj) == "/GAMES", "archive panel mapping: wrong current dir path for /GAMES")

xtrd_archive.set_current_dir_index(panel_obj, 2)
local level2_items = xtrd_archive.to_panel_items(panel_obj)
expect(has_item(level2_items, "NEST.$C"), "archive panel mapping: /GAMES/ACTION must contain nested file")
expect(not has_item(level2_items, "ACTION"), "archive panel mapping: /GAMES/ACTION must not contain itself as child")
expect(xtrd_archive.get_current_dir_path(panel_obj) == "/GAMES/ACTION", "archive panel mapping: wrong current dir path for /GAMES/ACTION")

local nested_entry = nil
for i = 1, #level2_items do
  local item = level2_items[i]
  if type(item) == "table" and item.FileName == "NEST.$C" then
    nested_entry = item
    break
  end
end
if type(nested_entry) ~= "table" then
  fail("archive panel mapping: missing nested panel file entry")
else
  local custom_columns = nested_entry.CustomColumnData
  local dir_column = type(custom_columns) == "table" and custom_columns[7] or nil
  local trk_column = type(custom_columns) == "table" and custom_columns[8] or nil
  expect(dir_column == "/GAMES/ACTION", "archive panel mapping: dir column mismatch")
  expect(trk_column == "7", "archive panel mapping: trk column mismatch")
end

if failed_count > 0 then
  error("FAILED: " .. tostring(failed_count) .. " checks")
end

return {
  ok = true,
  failed_count = 0,
  message = "OK: all xTRD parser tests passed",
}
end

M.run = run
return M
