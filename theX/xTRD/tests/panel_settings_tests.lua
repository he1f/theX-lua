local M = {}

local function run()
  local function assert_equal(actual, expected, message)
    if actual ~= expected then
      error((message or "assertion failed") .. ": expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
  end

  local storage = {}
  local last_saved = nil
  local panel_info_state = {
    ViewMode = 5,
    SortMode = 123,
    Flags = 0x1000,
  }

  win = {
    Uuid = function(value)
      return value
    end,
    GetEnv = function(_name)
      return ""
    end,
    MultiByteToWideChar = function(value, _cp)
      return value
    end,
    Utf16ToUtf8 = function(value)
      return value
    end,
  }

  far = {
    GetConfig = function(_key)
      return "English"
    end,
    ConvertPath = function(path_value, _mode)
      return path_value
    end,
    Message = function()
      return 1
    end,
    Flags = {
      PMFLAGS_ALIGNEXTENSIONS = 0x1,
      SM_UNSORTED = 0,
      OPIF_SHORTCUT = 0x2,
      FE_REDRAW = 1,
      FE_GOTFOCUS = 2,
      FE_IDLE = 3,
      FE_CHANGEVIEWMODE = 4,
      FE_CHANGESORTPARAMS = 5,
      PFLAGS_REVERSESORTORDER = 0x1000,
      FILE_ATTRIBUTE_DIRECTORY = 0x10,
      FILE_ATTRIBUTE_HIDDEN = 0x2,
    },
  }

  panel = {
    GetPanelInfo = function(_handle, _active)
      return panel_info_state
    end,
    GetColumnTypes = function()
      return "C0,S,C1,C7,C2"
    end,
    GetColumnWidths = function()
      return "0,6,6,4,4"
    end,
    UpdatePanel = function()
      return true
    end,
    RedrawPanel = function()
      return true
    end,
  }

  mf = {
    mload = function(key, name)
      return storage[key .. ":" .. name]
    end,
    msave = function(key, name, value)
      storage[key .. ":" .. name] = value
      last_saved = value
    end,
  }

  package.loaded["theX"] = {}
  package.loaded["theX.xTRD.config"] = nil
  package.loaded["theX.xTRD.i18n"] = nil
  package.loaded["theX.xTRD.i18n.en"] = nil
  package.loaded["theX.xTRD.i18n.ru"] = nil
  package.loaded["theX.xTRD.core.archive"] = nil
  package.loaded["theX.xTRD.panel.factory"] = nil
  package.loaded["theX.xTRD.panel.module"] = nil
  local source_info = debug.getinfo(1, "S")
  local source_path = type(source_info) == "table" and source_info.source or ""
  source_path = type(source_path) == "string" and source_path:gsub("^@", "") or ""
  local normalized_path = source_path:gsub("\\", "/")
  local scripts_root = normalized_path:match("^(.*)/theX/xTRD/tests/[^/]+$")
  if type(scripts_root) ~= "string" or scripts_root == "" then
    scripts_root = "d:/lua"
  end
  package.path = scripts_root .. "/?.lua;" .. scripts_root .. "/?/init.lua;" .. package.path

  local module = require("theX.xTRD.panel.module")

  local initial_info = module.GetOpenPanelInfo({
    HostFile = "disk.trd",
    Meta = {},
    Entries = {},
    IndexByName = {},
  }, nil)
  assert_equal(initial_info.StartPanelMode, 0x34, "default StartPanelMode")
  assert_equal(initial_info.StartSortMode, far.Flags.SM_UNSORTED, "default StartSortMode")
  assert_equal(initial_info.StartSortOrder, 0, "default StartSortOrder")

  local closing_object = {
    Entries = {},
    IndexByName = {},
    SelectionState = {},
  }
  module.ClosePanel(closing_object, nil)

  if type(last_saved) ~= "table" then
    error("settings were not saved on ClosePanel")
  end
  assert_equal(last_saved.LastPanelMode, 0x35, "saved LastPanelMode")
  assert_equal(last_saved.LastSortMode, 123, "saved LastSortMode")
  assert_equal(last_saved.LastSortOrder, 1, "saved LastSortOrder")
  assert_equal(last_saved.UseSavedSort, true, "saved UseSavedSort")

  local restored_info = module.GetOpenPanelInfo({
    HostFile = "disk.trd",
    Meta = {},
    Entries = {},
    IndexByName = {},
  }, nil)
  assert_equal(restored_info.StartPanelMode, 0x35, "restored StartPanelMode")
  assert_equal(restored_info.StartSortMode, 123, "restored StartSortMode")
  assert_equal(restored_info.StartSortOrder, 1, "restored StartSortOrder")

  return {
    ok = true,
    message = "OK: xTRD panel settings persistence test passed",
  }
end

M.run = run
return M
