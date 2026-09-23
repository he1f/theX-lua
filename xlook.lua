local macro_file = ...
if type(macro_file) ~= "string" then
  return
end
local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local M = {}
local F = far.Flags


local L = require("theX.ui.localization")
local xlook_core = require("theX.xLook.init")

---@param open_from integer
---@param guid any
---@param command_line_str string The exact tail string parameters typed after prefix identifier
function M.Open(open_from, guid, command_line_str)
    if open_from == F.OPEN_COMMANDLINE and command_line_str and command_line_str ~= "" then
        local cleaned_path = string.match(command_line_str, '^%s*"?([^"]+)"?%s*$') or command_line_str
        xlook_core.process_and_edit_file(cleaned_path)
    end
    return nil
end
-- [[ DECLARATIVE LUA_FAR INTERFACE MENU AND COMMAND LINE REGISTRY ]]

MenuItem {
    menu   = "Plugins",
    area   = "Shell",
    guid   = "7B8C9D0E-A1F2-3B4C-5D6E-7F8A9B0C1D2E",
    text   = L.xl_menu_title, -- "xLook Viewer"
    action = function(OpenFrom, Item)
        -- F11 Menu Interactive Selection Mode
        local current_dir = panel.GetPanelDirectory(nil, F.PANEL_ACTIVE)
        local current_item = panel.GetCurrentPanelItem(nil, F.PANEL_ACTIVE)

        if current_dir and current_dir.Name and current_item and current_item.FileName then
            local attr_str = current_item.FileAttributes or ""
            local is_dir = string.match(attr_str, "d") ~= nil

            if not is_dir then
                local full_path = win.JoinPath(current_dir.Name, current_item.FileName)
                xlook_core.process_and_edit_file(full_path)
                return nil
            end
        end
        return nil
    end
}

CommandLine {
  description = "xLook";
  prefixes = "xlook";
  action = function(prefix,text)
    return M, M.Open(F.OPEN_COMMANDLINE, nil, text)
  end;
}

PanelModule(M)
