local path_util = require("xscl.util.path")
local archive = require("xscl.core.archive")
local scl_reader = require("xscl.formats.scl_reader")

local M = {}

local function is_scl_path(file_path)
  return type(file_path) == "string" and file_path:lower():match("%.scl$") ~= nil
end

function M.from_path(input_path)
  local trimmed = path_util.trim(input_path)
  if not trimmed then
    return nil
  end

  local unquoted = path_util.unquote(trimmed)
  local full_path = far.ConvertPath(unquoted, "CPM_FULL")
  if not is_scl_path(full_path) then
    return nil
  end

  local parsed, parse_error = scl_reader.read(full_path)
  if not parsed then
    far.Message(parse_error or "xSCL: parse error", "xSCL", nil, "w")
    return nil
  end

  return archive.new(parsed.host_file, parsed.entries)
end

function M.from_analyse_item(item)
  if type(item) ~= "table" then
    return nil
  end
  return M.from_path(item.FileName)
end

function M.from_shortcut(shortcut_data)
  return M.from_path(shortcut_data)
end

function M.from_active_panel()
  local current_name = APanel.Current
  return M.from_path(current_name)
end

return M
