local raw_writer = require("xscl.formats.raw_writer")
local hobeta_writer = require("xscl.formats.hobeta_writer")
local scl_writer = require("xscl.formats.scl_writer")

local M = {}

function M.copy_one_to_raw(entry, target_file)
  local data = entry.data or string.rep("\0", entry.size or 0)
  return raw_writer.write_file(target_file, data)
end

function M.copy_many_to_raw(entries, target_file)
  local data = raw_writer.concat_entries(entries)
  return raw_writer.write_file(target_file, data)
end

function M.copy_one_to_hobeta(entry, target_file)
  local packed, err = hobeta_writer.pack_single_entry(entry)
  if not packed then
    return nil, err
  end
  return raw_writer.write_file(target_file, packed)
end

function M.copy_many_to_scl(entries, target_file)
  local packed, err = scl_writer.pack_entries(entries)
  if not packed then
    return nil, err
  end
  return raw_writer.write_file(target_file, packed)
end

return M
