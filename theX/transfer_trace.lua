local M = {}

local trace_file_path = nil

local function join_path(left, right)
  local lhs = type(left) == "string" and left or ""
  local rhs = type(right) == "string" and right or ""
  if lhs == "" then
    return rhs
  end
  if rhs == "" then
    return lhs
  end
  local tail = lhs:sub(-1)
  if tail == "\\" or tail == "/" then
    return lhs .. rhs
  end
  return lhs .. "\\" .. rhs
end

local function is_enabled()
  local env_value = win.GetEnv and win.GetEnv("THEX_TRANSFER_TRACE") or nil
  if type(env_value) ~= "string" or env_value == "" then
    return true
  end
  local lowered = env_value:lower()
  if lowered == "0" or lowered == "false" or lowered == "no" or lowered == "off" then
    return false
  end
  return true
end

local function resolve_file_path()
  if type(trace_file_path) == "string" and trace_file_path ~= "" then
    return trace_file_path
  end
  local temp_root = win.GetEnv and (win.GetEnv("TEMP") or win.GetEnv("TMP")) or nil
  if type(temp_root) ~= "string" or temp_root == "" then
    temp_root = "."
  end
  trace_file_path = join_path(temp_root, "thex_transfer_trace.log")
  return trace_file_path
end

local function value_to_text(value)
  local value_type = type(value)
  if value == nil then
    return "nil"
  end
  if value_type == "string" then
    return value:gsub("[\r\n]", " ")
  end
  if value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end
  if value_type == "table" then
    return "<table>"
  end
  return "<" .. value_type .. ">"
end

local function fields_to_text(fields)
  if type(fields) ~= "table" then
    return ""
  end
  local keys = {}
  for key, _ in pairs(fields) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  local out = {}
  for i = 1, #keys do
    local key = keys[i]
    out[#out + 1] = key .. "=" .. value_to_text(fields[key])
  end
  return table.concat(out, " ")
end

function M.trace(event_name, fields)
  if not is_enabled() then
    return
  end
  local trace_path = resolve_file_path()
  local file_handle = io.open(trace_path, "a")
  if file_handle == nil then
    return
  end
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local line = "[" .. tostring(timestamp) .. "] " .. tostring(event_name)
  local fields_text = fields_to_text(fields)
  if fields_text ~= "" then
    line = line .. " " .. fields_text
  end
  file_handle:write(line .. "\n")
  file_handle:close()
end

return M
