local M = {}
local FILE_ATTRIBUTE_DIRECTORY = (far and far.Flags and far.Flags.FILE_ATTRIBUTE_DIRECTORY) or 0x10
local FILE_ATTRIBUTE_HIDDEN = (far and far.Flags and far.Flags.FILE_ATTRIBUTE_HIDDEN) or 0x2
local trd_reader = require("theX.formats.trd_reader")

local function ensure_selection_state(object)
  if type(object.SelectionState) ~= "table" then
    object.SelectionState = {
      next_seq = 0,
      selected_keys = {},
      order_by_key = {},
    }
  end
  return object.SelectionState
end
local function get_dirsys_meta(object)
  local meta = type(object) == "table" and object.Meta or nil
  local dirsys = type(meta) == "table" and meta.dirsys or nil
  if type(dirsys) ~= "table" or dirsys.present ~= true then
    return nil
  end
  return dirsys
end

local function get_dir_table(object)
  local dirsys = get_dirsys_meta(object)
  local directories = type(dirsys) == "table" and dirsys.directories or nil
  if type(directories) ~= "table" then
    return nil
  end
  return directories
end

local function normalize_dir_index(value)
  local dir_index = tonumber(value)
  if type(dir_index) ~= "number" then
    return 0
  end
  dir_index = math.floor(dir_index)
  if dir_index < 0 then
    return 0
  end
  return dir_index
end

local function ensure_current_dir_index(object)
  local directories = get_dir_table(object)
  local current_dir_index = normalize_dir_index(object.CurrentDirIndex)
  if current_dir_index == 0 then
    object.CurrentDirIndex = 0
    return 0
  end
  if type(directories) ~= "table" or type(directories[current_dir_index]) ~= "table" then
    object.CurrentDirIndex = 0
    return 0
  end
  object.CurrentDirIndex = current_dir_index
  return current_dir_index
end

local function get_directory_name(directory_node, fallback_index)
  local raw_name = type(directory_node) == "table" and directory_node.name or nil
  if type(raw_name) == "string" and raw_name ~= "" then
    return raw_name
  end
  return "dir" .. tostring(fallback_index or 0)
end

local function build_dir_path_for_index(object, dir_index)
  local normalized_index = normalize_dir_index(dir_index)
  if normalized_index == 0 then
    return "/"
  end
  local directories = get_dir_table(object)
  if type(directories) ~= "table" then
    return "/"
  end

  local parts = {}
  local visited = {}
  local current_index = normalized_index
  while current_index > 0 do
    if visited[current_index] then
      parts[#parts + 1] = "<cycle>"
      break
    end
    visited[current_index] = true
    local node = directories[current_index]
    if type(node) ~= "table" then
      parts[#parts + 1] = "dir" .. tostring(current_index)
      break
    end
    parts[#parts + 1] = get_directory_name(node, current_index)
    local parent_value = normalize_dir_index(node.parent_index)
    if parent_value <= 0 then
      break
    end
    current_index = parent_value
  end

  local ordered = {}
  for i = #parts, 1, -1 do
    ordered[#ordered + 1] = parts[i]
  end
  if #ordered == 0 then
    return "/"
  end
  return "/" .. table.concat(ordered, "/")
end

local function is_directory_name_in_current_dir(object, name_value)
  if type(name_value) ~= "string" or name_value == "" then
    return false
  end
  local directories = get_dir_table(object)
  if type(directories) ~= "table" then
    return false
  end
  local current_dir_index = ensure_current_dir_index(object)
  for dir_index, directory_node in pairs(directories) do
    local parent_index = normalize_dir_index(type(directory_node) == "table" and directory_node.parent_index or 0)
    if parent_index == current_dir_index then
      if get_directory_name(directory_node, dir_index) == name_value then
        return true
      end
    end
  end
  return false
end

local function entry_key(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local entry_id = tonumber(entry.__xtrd_entry_id)
  if entry_id and entry_id >= 1 then
    return "id:" .. tostring(math.floor(entry_id))
  end
  if type(entry.pc_name) == "string" and entry.pc_name ~= "" then
    return "pc:" .. entry.pc_name
  end
  if type(entry.name) == "string" and entry.name ~= "" then
    return "name:" .. entry.name
  end
  return nil
end

local function resolve_entry(object, panel_item)
  if type(panel_item) ~= "table" then
    return nil
  end
  local file_name = panel_item.FileName
  if file_name == ".." then
    return nil
  end
  if is_directory_name_in_current_dir(object, file_name) then
    return nil
  end
  if type(file_name) == "string" and file_name ~= "" then
    return object.IndexByName[file_name]
  end
  return nil
end

local function sorted_entries_by_selection_order(object, entries)
  local selection_state = ensure_selection_state(object)
  local decorated = {}
  for i = 1, #entries do
    local entry = entries[i]
    local key = entry_key(entry)
    local seq = key and selection_state.order_by_key[key] or nil
    decorated[#decorated + 1] = {
      entry = entry,
      original_index = i,
      seq = seq,
    }
  end

  table.sort(decorated, function(left_item, right_item)
    local left_seq = left_item.seq
    local right_seq = right_item.seq
    if left_seq ~= nil and right_seq ~= nil then
      if left_seq ~= right_seq then
        return left_seq < right_seq
      end
      return left_item.original_index < right_item.original_index
    end
    if left_seq ~= nil then
      return true
    end
    if right_seq ~= nil then
      return false
    end
    return left_item.original_index < right_item.original_index
  end)

  local out = {}
  for i = 1, #decorated do
    out[i] = decorated[i].entry
  end
  return out
end

function M.new(host_file, entries, meta)
  local index_by_name = {}
  for i = 1, #entries do
    local entry = entries[i]
    entry.__xtrd_entry_id = i
    if type(entry.name) == "string" and entry.name ~= "" and index_by_name[entry.name] == nil then
      index_by_name[entry.name] = entry
    end
    if type(entry.pc_name) == "string" and entry.pc_name ~= "" then
      index_by_name[entry.pc_name] = entry
    end
  end

  return {
    HostFile = host_file,
    Entries = entries,
    IndexByName = index_by_name,
    Meta = type(meta) == "table" and meta or {},
    CurrentDirIndex = 0,
    SelectionState = {
      next_seq = 0,
      selected_keys = {},
      order_by_key = {},
    },
  }
end

function M.to_panel_items(object)
  local current_dir_index = ensure_current_dir_index(object)
  local dirsys = get_dirsys_meta(object)
  local directories = get_dir_table(object)
  local out = {
    {
      FileName = "..",
      FileSize = 0,
      FileAttributes = "d",
      Description = "",
      CustomColumnData = { "..", "", "", "", "", "", "", "" },
    },
  }
  if type(directories) == "table" and type(dirsys) == "table" and dirsys.present == true then
    local ordered_indexes = {}
    for dir_index, directory_node in pairs(directories) do
      if type(directory_node) == "table" and dir_index > 0 then
        local parent_index = normalize_dir_index(directory_node.parent_index)
        if parent_index == current_dir_index then
          ordered_indexes[#ordered_indexes + 1] = dir_index
        end
      end
    end
    table.sort(ordered_indexes, function(left_value, right_value)
      return left_value < right_value
    end)

    for i = 1, #ordered_indexes do
      local dir_index = ordered_indexes[i]
      local directory_node = directories[dir_index]
      local dir_name = get_directory_name(directory_node, dir_index)
      local dir_path = build_dir_path_for_index(object, dir_index)
      local is_deleted = type(directory_node) == "table" and directory_node.is_deleted == true
      local file_attributes = FILE_ATTRIBUTE_DIRECTORY
      local file_attr_text = "d"
      local comment_value = ""
      if is_deleted then
        file_attributes = FILE_ATTRIBUTE_DIRECTORY + FILE_ATTRIBUTE_HIDDEN
        file_attr_text = "dh"
        comment_value = "deleted directory"
      end

      out[#out + 1] = {
        FileName = dir_name,
        FileSize = 0,
        FileAttributes = file_attr_text,
        Description = "<DIR>",
        CustomColumnData = {
          dir_name,
          "",
          "",
          "<DIR>",
          "",
          comment_value,
          type(dir_path) == "string" and dir_path or "",
          "",
        },
        UserData = {
          xtrd_directory_index = dir_index,
          xtrd_directory = true,
          xtrd_file_attributes = file_attributes,
        },
      }
    end
  end

  for i = 1, #object.Entries do
    local entry = object.Entries[i]
    local entry_dir_index = normalize_dir_index(entry and entry.dirsys_dir_index or 0)
    local should_include = true
    if type(dirsys) == "table" and dirsys.present == true and entry_dir_index ~= current_dir_index then
      should_include = false
    end
    if (type(dirsys) ~= "table" or dirsys.present ~= true) and current_dir_index ~= 0 then
      should_include = false
    end
    if should_include then
      local start_value = entry.trdos_start and tostring(entry.trdos_start) or ""
      local sectors_value = entry.trdos_sectors and tostring(entry.trdos_sectors) or ""
      local type_value = entry.trdos_type or ""
      local comment_value = entry.comment or ""
      local dirsys_path_value = entry.dirsys_path or ""
      local track_value = ""
      if type(entry.trdos_params) == "table" and entry.trdos_params.trk ~= nil then
        track_value = tostring(entry.trdos_params.trk)
      end
      local panel_description = entry.trdos_description or entry.trdos_type_description or ""
      local file_attributes = entry.attributes
      if file_attributes == nil or file_attributes == "" then
        file_attributes = entry.file_attributes or 0
      end

      out[#out + 1] = {
        FileName = entry.pc_name or entry.name,
        FileSize = entry.size or #(entry.data or ""),
        FileAttributes = file_attributes,
        Description = panel_description,
        CustomColumnData = {
          entry.name or "",
          start_value,
          sectors_value,
          type_value,
          panel_description,
          comment_value,
          dirsys_path_value,
          track_value,
        },
      }
    end
  end

  return out
end

function M.get_current_dir_index(object)
  if type(object) ~= "table" then
    return 0
  end
  return ensure_current_dir_index(object)
end

function M.set_current_dir_index(object, dir_index)
  if type(object) ~= "table" then
    return 0
  end
  local normalized_index = normalize_dir_index(dir_index)
  local directories = get_dir_table(object)
  if normalized_index ~= 0 and (type(directories) ~= "table" or type(directories[normalized_index]) ~= "table") then
    normalized_index = 0
  end
  object.CurrentDirIndex = normalized_index
  return normalized_index
end

function M.resolve_parent_dir_index(object, dir_index)
  local normalized_index = normalize_dir_index(dir_index)
  if normalized_index == 0 then
    return 0
  end
  local directories = get_dir_table(object)
  local node = type(directories) == "table" and directories[normalized_index] or nil
  if type(node) ~= "table" then
    return 0
  end
  return normalize_dir_index(node.parent_index)
end

function M.find_child_dir_index(object, parent_dir_index, dir_name)
  if type(dir_name) ~= "string" or dir_name == "" then
    return nil
  end
  local directories = get_dir_table(object)
  if type(directories) ~= "table" then
    return nil
  end
  local target_parent = normalize_dir_index(parent_dir_index)
  local best_index = nil
  for dir_index, directory_node in pairs(directories) do
    if type(directory_node) == "table" and dir_index > 0 then
      local node_parent = normalize_dir_index(directory_node.parent_index)
      if node_parent == target_parent and get_directory_name(directory_node, dir_index) == dir_name then
        if best_index == nil or dir_index < best_index then
          best_index = dir_index
        end
      end
    end
  end
  return best_index
end

function M.get_current_dir_path(object)
  return build_dir_path_for_index(object, M.get_current_dir_index(object))
end

function M.select_entries(object, panel_items)
  local selected = {}
  for i = 1, #panel_items do
    local entry = resolve_entry(object, panel_items[i])
    if entry then
      selected[#selected + 1] = entry
    end
  end
  return sorted_entries_by_selection_order(object, selected)
end

function M.track_selection(object, panel_items)
  if type(object) ~= "table" or type(object.IndexByName) ~= "table" then
    return
  end

  local selection_state = ensure_selection_state(object)
  local current_selected = {}

  for i = 1, #panel_items do
    local entry = resolve_entry(object, panel_items[i])
    local key = entry_key(entry)
    if key and not current_selected[key] then
      current_selected[key] = true
      if not selection_state.selected_keys[key] then
        selection_state.next_seq = selection_state.next_seq + 1
        selection_state.order_by_key[key] = selection_state.next_seq
      end
    end
  end

  selection_state.selected_keys = current_selected
end

local function apply_parsed_archive_state(object, parsed, keep_dir_index)
  if type(object) ~= "table" or type(parsed) ~= "table" then
    return
  end
  local rebuilt = M.new(parsed.host_file, parsed.entries or {}, parsed.meta or {})
  object.HostFile = rebuilt.HostFile
  object.Entries = rebuilt.Entries
  object.IndexByName = rebuilt.IndexByName
  object.Meta = rebuilt.Meta
  object.SelectionState = rebuilt.SelectionState
  object.CurrentDirIndex = 0
  M.set_current_dir_index(object, keep_dir_index or 0)
end

function M.create_directory(object, dir_name, install_if_missing)
  if type(object) ~= "table" then
    return nil, "xTRD: invalid archive object"
  end
  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    return nil, "xTRD: archive path is empty"
  end

  local parent_dir_index = M.get_current_dir_index(object)
  local create_result, create_error = trd_reader.create_directory(
    host_file,
    parent_dir_index,
    dir_name,
    install_if_missing == true
  )
  if not create_result then
    return nil, create_error
  end

  local parsed = create_result.parsed
  if type(parsed) ~= "table" then
    parsed, create_error = trd_reader.read(host_file)
    if not parsed then
      return nil, create_error
    end
  end
  apply_parsed_archive_state(object, parsed, parent_dir_index)

  return {
    created_dir_index = create_result.created_dir_index,
    dirsys_installed = create_result.dirsys_installed == true,
  }
end

function M.update_entry_info(object, entry, trdos_name, trdos_type, trdos_start)
  if type(object) ~= "table" then
    return nil, "xTRD: invalid archive object"
  end
  if type(entry) ~= "table" then
    return nil, "xTRD: invalid entry"
  end

  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    return nil, "xTRD: archive path is empty"
  end

  local entry_slot = tonumber(entry.trdos_dir_slot)
  if type(entry_slot) ~= "number" then
    return nil, "xTRD: entry slot is missing"
  end
  entry_slot = math.floor(entry_slot)

  local current_dir_index = M.get_current_dir_index(object)
  local update_result, update_error = trd_reader.update_entry_header(
    host_file,
    entry_slot,
    trdos_name,
    trdos_type,
    trdos_start
  )
  if not update_result then
    return nil, update_error
  end

  local parsed = update_result.parsed
  if type(parsed) ~= "table" then
    parsed, update_error = trd_reader.read(host_file)
    if not parsed then
      return nil, update_error
    end
  end
  apply_parsed_archive_state(object, parsed, current_dir_index)
  return {
    updated_slot = entry_slot,
  }
end

function M.import_entries(object, entries)
  if type(object) ~= "table" then
    return nil, "xTRD: invalid archive object"
  end
  if type(entries) ~= "table" or #entries == 0 then
    return nil, "xTRD: no entries to import"
  end

  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    return nil, "xTRD: archive path is empty"
  end

  local current_dir_index = M.get_current_dir_index(object)
  local add_result, add_error = trd_reader.add_entries(host_file, current_dir_index, entries)
  if not add_result then
    return nil, add_error
  end

  local parsed = add_result.parsed
  if type(parsed) ~= "table" then
    parsed, add_error = trd_reader.read(host_file)
    if not parsed then
      return nil, add_error
    end
  end
  apply_parsed_archive_state(object, parsed, current_dir_index)
  return {
    added_count = tonumber(add_result.added_count) or #entries,
  }
end

function M.delete_entries_and_directories(object, entries, directory_indexes)
  if type(object) ~= "table" then
    return nil, "xTRD: invalid archive object"
  end

  local host_file = object.HostFile
  if type(host_file) ~= "string" or host_file == "" then
    return nil, "xTRD: archive path is empty"
  end

  local entry_slots = {}
  if type(entries) == "table" then
    for i = 1, #entries do
      local entry = entries[i]
      local slot_index = tonumber(type(entry) == "table" and entry.trdos_dir_slot or nil)
      if type(slot_index) == "number" then
        entry_slots[#entry_slots + 1] = math.floor(slot_index)
      end
    end
  end

  local current_dir_index = M.get_current_dir_index(object)
  local delete_result, delete_error = trd_reader.delete_entries_and_directories(
    host_file,
    entry_slots,
    type(directory_indexes) == "table" and directory_indexes or {},
    current_dir_index
  )
  if not delete_result then
    return nil, delete_error
  end

  local parsed = delete_result.parsed
  if type(parsed) ~= "table" then
    parsed, delete_error = trd_reader.read(host_file)
    if not parsed then
      return nil, delete_error
    end
  end
  local next_dir_index = tonumber(delete_result.current_dir_index)
  if type(next_dir_index) ~= "number" then
    next_dir_index = current_dir_index
  end
  apply_parsed_archive_state(object, parsed, next_dir_index)

  return {
    removed_files_count = tonumber(delete_result.removed_files_count) or 0,
    removed_dirs_count = tonumber(delete_result.removed_dirs_count) or 0,
  }
end

return M
