local M = {}
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

local function entry_key(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local entry_id = tonumber(entry.__xscl_entry_id)
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
  local name = panel_item.FileName
  if type(name) == "string" and name ~= "" then
    return object.IndexByName[name]
  end
  return nil
end

local function sorted_entries_by_selection_order(object, entries)
  local state = ensure_selection_state(object)
  local decorated = {}
  for i = 1, #entries do
    local e = entries[i]
    local key = entry_key(e)
    local seq = key and state.order_by_key[key] or nil
    decorated[#decorated + 1] = {
      entry = e,
      original_index = i,
      seq = seq,
    }
  end

  table.sort(decorated, function(a, b)
    local sa = a.seq
    local sb = b.seq
    if sa ~= nil and sb ~= nil then
      if sa ~= sb then
        return sa < sb
      end
      return a.original_index < b.original_index
    end
    if sa ~= nil then
      return true
    end
    if sb ~= nil then
      return false
    end
    return a.original_index < b.original_index
  end)

  local out = {}
  for i = 1, #decorated do
    out[i] = decorated[i].entry
  end
  return out
end

function M.new(host_file, entries)
  local index_by_name = {}
  for i = 1, #entries do
    local entry = entries[i]
    entry.__xscl_entry_id = i
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
    SelectionState = {
      next_seq = 0,
      selected_keys = {},
      order_by_key = {},
    },
  }
end

function M.to_panel_items(object)
  local out = {
    {
      FileName = "..",
      FileSize = 0,
      FileAttributes = 0,
      Description = "",
      CustomColumnData = { "..", "", "", "", "", "" },
    },
  }
  for i = 1, #object.Entries do
    local e = object.Entries[i]
    local trdos_name = e.trdos_name or e.name or ""
    local trdos_start = e.trdos_start and tostring(e.trdos_start) or ""
    local trdos_sectors = e.trdos_sectors and tostring(e.trdos_sectors) or ""
    local trdos_format = e.trdos_description or e.trdos_type_description or ""
    local trdos_comment = e.comment or ""
    local pc_name = e.pc_name or ""
    local panel_description = trdos_format
    local file_attributes = e.attributes
    if file_attributes == nil or file_attributes == "" then
      file_attributes = e.file_attributes or 0
    end

    out[#out + 1] = {
      FileName = e.pc_name or e.name,
      FileSize = e.size or #(e.data or ""),
      FileAttributes = file_attributes,
      Description = panel_description,
      CustomColumnData = {
        e.name or "",
        trdos_start,
        trdos_sectors,
        trdos_format,
        trdos_comment,
        pc_name,
      },
    }
  end
  return out
end

function M.select_entries(object, panel_items)
  local selected = {}
  for i = 1, #panel_items do
    local e = resolve_entry(object, panel_items[i])
    if e then
      selected[#selected + 1] = e
    end
  end
  return sorted_entries_by_selection_order(object, selected)
end

function M.track_selection(object, panel_items)
  if type(object) ~= "table" or type(object.IndexByName) ~= "table" then
    return
  end

  local state = ensure_selection_state(object)
  local current_selected = {}

  for i = 1, #panel_items do
    local e = resolve_entry(object, panel_items[i])
    local key = entry_key(e)
    if key and not current_selected[key] then
      current_selected[key] = true
      if not state.selected_keys[key] then
        state.next_seq = state.next_seq + 1
        state.order_by_key[key] = state.next_seq
      end
    end
  end

  state.selected_keys = current_selected
end

return M
