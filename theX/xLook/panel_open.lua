local M = {}

local function sanitize_temp_name(value)
  local safe_name = type(value) == "string" and value or ""
  safe_name = safe_name:gsub('[<>:"/\\|%?%*]', "_")
  safe_name = safe_name:gsub("%s+", "_")
  safe_name = safe_name:gsub("[%. ]+$", "")
  if safe_name == "" then
    safe_name = "entry.bin"
  end
  return safe_name
end

local function build_temp_file_path(entry, temp_prefix, path_join)
  local temp_root = win.GetEnv("TEMP") or win.GetEnv("TMP") or "."
  local unique = ("%d_%06d"):format(os.time(), math.random(0, 999999))
  local pc_name = type(entry) == "table" and entry.pc_name or nil
  local safe_name = sanitize_temp_name(pc_name)
  local prefix = type(temp_prefix) == "string" and temp_prefix or "entry"
  local file_name = prefix .. "_" .. unique .. "." .. safe_name
  if type(path_join) == "function" then
    return path_join(temp_root, file_name)
  end
  if type(temp_root) ~= "string" or temp_root == "" then
    return file_name
  end
  return temp_root .. "\\" .. file_name
end

local function should_open_with_xlook(entry)
  local detected_group = type(entry) == "table" and entry.detected_group or nil
  if type(detected_group) ~= "string" or detected_group == "" then
    return false
  end
  return detected_group:lower() == "asm"
end

local function open_in_viewer(temp_file, title)
  if viewer and type(viewer.Viewer) == "function" then
    return viewer.Viewer(temp_file, title, nil, nil, nil, nil, "VF_DELETEONCLOSE")
  end
  if far and type(far.Viewer) == "function" then
    return far.Viewer(temp_file, title, nil, nil, nil, nil, "VF_DELETEONCLOSE")
  end
  return nil
end

local function open_in_editor(temp_file, title)
  if editor and type(editor.Editor) == "function" then
    return editor.Editor(temp_file, title, nil, nil, nil, nil, "EF_DELETEONCLOSE", 1, 1)
  end
  if far and type(far.Editor) == "function" then
    return far.Editor(temp_file, title, nil, nil, nil, nil, "EF_DELETEONCLOSE", 1, 1)
  end
  return nil
end

local function resolve_hobeta_data_for_xlook(entry, pack_hobeta, resolve_open_data)
  if type(entry) ~= "table" then
    return ""
  end
  if type(pack_hobeta) == "function" then
    local packed_hobeta = pack_hobeta(entry)
    if type(packed_hobeta) == "string" and packed_hobeta ~= "" then
      return packed_hobeta
    end
  end
  if type(entry.hobeta) == "string" and entry.hobeta ~= "" then
    return entry.hobeta
  end
  if type(resolve_open_data) == "function" then
    return resolve_open_data(entry)
  end
  return ""
end

function M.open_entry_from_temp(params)
  if type(params) ~= "table" then
    return nil
  end
  local entry = params.entry
  if type(entry) ~= "table" then
    return nil
  end
  local resolve_open_data = params.resolve_open_data
  local write_file = params.write_file
  if type(resolve_open_data) ~= "function" or type(write_file) ~= "function" then
    return nil
  end

  local xlook_module = params.xlook
  local use_xlook = should_open_with_xlook(entry)
    and type(xlook_module) == "table"
    and type(xlook_module.run) == "function"
  local temp_file = build_temp_file_path(entry, params.temp_prefix, params.path_join)
  local data = use_xlook
      and resolve_hobeta_data_for_xlook(entry, params.pack_hobeta, resolve_open_data)
    or resolve_open_data(entry)
  local ok_write = write_file(temp_file, data)
  if not ok_write then
    if type(params.on_temp_write_failed) == "function" then
      params.on_temp_write_failed()
    end
    return 1
  end

  if use_xlook then
    local ok_run, handled = pcall(xlook_module.run, temp_file, { quiet = true, require_output = true })
    if ok_run and handled ~= false then
      return 1
    end
  end

  if params.mode == "view" then
    local opened = open_in_viewer(temp_file, entry.name)
    if (opened == nil or opened == false) and type(params.on_viewer_unavailable) == "function" then
      params.on_viewer_unavailable()
    end
    return 1
  end
  if params.mode == "edit" then
    local opened = open_in_editor(temp_file, entry.name)
    if (opened == nil or opened == false) and type(params.on_editor_unavailable) == "function" then
      params.on_editor_unavailable()
    end
    return 1
  end
  return nil
end

return M
