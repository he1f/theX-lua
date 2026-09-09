local M = {}

local function default_file_exists(path_value)
  if type(path_value) ~= "string" or path_value == "" then
    return false
  end
  local fp = io.open(path_value, "rb")
  if fp then
    fp:close()
    return true
  end
  return false
end

local function normalize_action(action_value)
  if type(action_value) ~= "string" then
    return "cancel"
  end
  local action = action_value:lower()
  if action == "overwrite" or action == "overwrite_all" or action == "skip" or action == "skip_all" or action == "cancel" then
    return action
  end
  return "cancel"
end

function M.new_session(params)
  local input = type(params) == "table" and params or {}
  local file_exists_fn = input.file_exists
  if type(file_exists_fn) ~= "function" then
    file_exists_fn = default_file_exists
  end
  local confirm_fn = input.confirm_overwrite
  if type(confirm_fn) ~= "function" then
    confirm_fn = nil
  end
  return {
    mode = nil,
    cancelled = false,
    file_exists = file_exists_fn,
    confirm_overwrite = confirm_fn,
  }
end

function M.resolve_write_decision(session, target_path)
  local state = session
  if type(state) ~= "table" then
    state = M.new_session(nil)
  end
  if type(target_path) ~= "string" or target_path == "" then
    return "write"
  end

  local exists = false
  local ok_exists, exists_result = pcall(state.file_exists, target_path)
  if ok_exists and exists_result == true then
    exists = true
  end
  if not exists then
    return "write"
  end

  if state.mode == "overwrite_all" then
    return "write"
  end
  if state.mode == "skip_all" then
    return "skip"
  end
  if type(state.confirm_overwrite) ~= "function" then
    return "write"
  end

  local ok_confirm, raw_action = pcall(state.confirm_overwrite, target_path)
  if not ok_confirm then
    state.cancelled = true
    return "cancel"
  end
  local action = normalize_action(raw_action)
  if action == "overwrite_all" then
    state.mode = "overwrite_all"
    return "write"
  end
  if action == "overwrite" then
    return "write"
  end
  if action == "skip_all" then
    state.mode = "skip_all"
    return "skip"
  end
  if action == "skip" then
    return "skip"
  end
  state.cancelled = true
  return "cancel"
end

return M
