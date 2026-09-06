local M = {}

function M.trim(value)
  if type(value) ~= "string" then
    return nil
  end
  local out = value:match("^%s*(.-)%s*$")
  if out == "" then
    return nil
  end
  return out
end

function M.unquote(value)
  if type(value) ~= "string" then
    return nil
  end
  local quoted = value:match("^\"(.*)\"$")
  return quoted or value
end

function M.join(dir_path, file_name)
  if dir_path:match("[\\/]$") then
    return dir_path .. file_name
  end
  return dir_path .. "\\" .. file_name
end

return M
