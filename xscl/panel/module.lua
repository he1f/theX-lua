local F = far.Flags
local config = require("xscl.config")
local path_util = require("xscl.util.path")
local archive = require("xscl.core.archive")
local factory = require("xscl.panel.factory")
local raw_writer = require("xscl.formats.raw_writer")

local M = {}
local panel_modes = {
  {
    ColumnTypes = "N,S,C2",
    ColumnWidths = "0,5,3",
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "N,S,C2",
    ColumnWidths = "0,5,3",
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "N,S,C2",
    ColumnWidths = "0,5,3",
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "N,C2,N,C2",
    ColumnWidths = "0,3,0,3",
    ColumnTitles = { "Name", "Sec", "Name", "Sec" },
    StatusColumnTypes = "C5,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "C0,S,C1,C2",
    ColumnWidths = "0,5,5,3",
    ColumnTitles = { "Name", "Size", "Start", "Sec" },
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "C0,C3",
    ColumnWidths = "12,0",
    ColumnTitles = { "Name", "Format" },
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
  {
    ColumnTypes = "C0,C4",
    ColumnWidths = "12,0",
    ColumnTitles = { "Name", "Comment" },
    StatusColumnTypes = "N,S,C2",
    StatusColumnWidths = "0,5,3",
    AlignExtensions = true,
    FullScreen = false,
  },
}

M.Info = {
  Guid = config.panel_module_guid,
  Version = "0.1.0",
  Title = config.name,
  Description = "xSCL panel module",
  Author = "xSCL",
}

function M.Analyse(data)
  return type(data.FileName) == "string" and data.FileName:lower():match("%.scl$") ~= nil
end

function M.Open(open_from, guid, item)
  if open_from == F.OPEN_ANALYSE then
    return factory.from_analyse_item(item)
  end

  if open_from == F.OPEN_SHORTCUT and type(item) == "table" then
    return factory.from_shortcut(item.ShortcutData)
  end
end

function M.GetFindData(object, handle, op_mode)
  return archive.to_panel_items(object)
end

function M.GetOpenPanelInfo(object, handle)
  return {
    HostFile = object.HostFile,
    Format = "TR-DOS SCL",
    PanelTitle = config.panel_title,
    PanelModesArray = panel_modes,
    PanelModesNumber = #panel_modes,
    StartPanelMode = 3,
    StartSortMode = F.SM_UNSORTED,
    StartSortOrder = 0,
    ShortcutData = object.HostFile or "",
    Flags = bit64.bor(F.OPIF_SHORTCUT, F.OPIF_ADDDOTS),
  }
end

function M.SetDirectory(object, handle, dir, op_mode)
  if dir == ".." then
    return false
  end
  return true
end

function M.GetFiles(object, handle, panel_items, move, dest_path, op_mode)
  local entries = archive.select_entries(object, panel_items)
  local out_dir = far.ConvertPath(dest_path, "CPM_FULL")

  for i = 1, #entries do
    local entry = entries[i]
    local target_name = entry.pc_name or entry.name
    local target = path_util.join(out_dir, target_name)
    local data = entry.data or string.rep("\0", entry.size or 0)
    local ok = raw_writer.write_file(target, data)
    if not ok then
      return false
    end
  end

  return true
end
local function get_current_entry(object)
  if type(object) ~= "table" or type(object.IndexByName) ~= "table" then
    return nil
  end
  local pinfo = panel.GetPanelInfo and panel.GetPanelInfo(nil, 1) or nil
  local item_index = pinfo and pinfo.CurrentItem
  if type(item_index) ~= "number" then
    return nil
  end

  local item = panel.GetPanelItem and panel.GetPanelItem(nil, 1, item_index) or nil
  local file_name = item and item.FileName
  if type(file_name) ~= "string" or file_name == ".." then
    return nil
  end

  return object.IndexByName[file_name]
end

local function build_temp_file_path(entry_name)
  local temp_root = win.GetEnv("TEMP") or win.GetEnv("TMP") or "."
  local safe_name = (entry_name or "entry.bin"):gsub('[<>:"/\\|%?%*]', "_")
  if safe_name == "" then
    safe_name = "entry.bin"
  end
  local unique = ("%d_%06d"):format(os.time(), math.random(0, 999999))
  return path_util.join(temp_root, "xscl_" .. unique .. "_" .. safe_name)
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

local function open_entry_from_temp(object, mode)
  local entry = get_current_entry(object)
  if not entry then
    return nil
  end

  local temp_file = build_temp_file_path(entry.name)
  local data = entry.data or string.rep("\0", entry.size or 0)
  local ok = raw_writer.write_file(temp_file, data)
  if not ok then
    far.Message("xSCL: failed to create temporary file", config.name, nil, "w")
    return 1
  end

  if mode == "view" then
    local opened = open_in_viewer(temp_file, entry.name)
    if opened == nil or opened == false then
      far.Message("xSCL: viewer is unavailable", config.name, nil, "w")
    end
    return 1
  end

  if mode == "edit" then
    local opened = open_in_editor(temp_file, entry.name)
    if opened == nil or opened == false then
      far.Message("xSCL: editor is unavailable", config.name, nil, "w")
    end
    return 1
  end

  return nil
end

function M.ProcessPanelInput(object, handle, rec)
  if type(rec) ~= "table" then
    return nil
  end

  local key_rec = type(rec.KeyEvent) == "table" and rec.KeyEvent or rec
  local event_type = rec.EventType
  if event_type ~= nil and event_type ~= 1 and event_type ~= "KEY_EVENT" then
    return nil
  end

  local key_down = key_rec.KeyDown
  if key_down == nil then
    key_down = key_rec.bKeyDown
  end
  if not key_down or key_down == 0 then
    return nil
  end

  local virtual_key_code = key_rec.VirtualKeyCode or key_rec.wVirtualKeyCode
  if virtual_key_code == 114 then
    return open_entry_from_temp(object, "view")
  end

  if virtual_key_code == 115 then
    return open_entry_from_temp(object, "edit")
  end

  return nil
end

return M
