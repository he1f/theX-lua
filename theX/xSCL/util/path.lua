local M = {}

function M.trim(s)
  if type(s) ~= "string" then
    return nil
  end
  local v = s:match("^%s*(.-)%s*$")
  if v == "" then
    return nil
  end
  return v
end

function M.unquote(s)
  if type(s) ~= "string" then
    return nil
  end
  local q = s:match('^"(.*)"$')
  return q or s
end

function M.join(dir_path, name)
  if dir_path:match("[\\/]$") then
    return dir_path .. name
  end
  return dir_path .. "\\" .. name
end

return M
