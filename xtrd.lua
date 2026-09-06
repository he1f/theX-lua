-- %FARPROFILE%\Macros\scripts\xtrd.lua
local macro_file = ...
if type(macro_file) ~= "string" then
  return
end

local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local xTRD = require("theX.xTRD")
local config = require("theX.xTRD.config")

CommandLine {
  description = "xTRD: open .trd from command line";
  prefixes = config.command_prefix;
  action = function(prefix, text)
    local obj = xTRD.panel_factory.from_path(text)
    if obj then
      return xTRD.panel_module, obj
    end
  end;
}

MenuItem {
  description = "xTRD: open current .trd";
  menu = "Plugins";
  area = "Shell";
  guid = config.menu_item_guid;
  text = "TRD eXplorer";
  action = function()
    local obj = xTRD.panel_factory.from_active_panel()
    if obj then
      return xTRD.panel_module, obj
    end
  end;
}

PanelModule(xTRD.panel_module)
