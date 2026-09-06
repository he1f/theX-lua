-- %FARPROFILE%\Macros\scripts\xscl.lua
local macro_file = ...
if type(macro_file) ~= "string" then
  return
end

local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local xSCL = require("theX.xSCL")
local config = require("theX.xSCL.config")

local function split_cli_args(text)
  local args = {}
  local i = 1
  local len = #text
  while i <= len do
    while i <= len and string.sub(text, i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end
    if string.sub(text, i, i) == "\"" then
      local j = i + 1
      while j <= len and string.sub(text, j, j) ~= "\"" do
        j = j + 1
      end
      if j <= len then
        args[#args + 1] = string.sub(text, i + 1, j - 1)
        i = j + 1
      else
        args[#args + 1] = string.sub(text, i + 1)
        break
      end
    else
      local j = i
      while j <= len and not string.sub(text, j, j):match("%s") do
        j = j + 1
      end
      args[#args + 1] = string.sub(text, i, j - 1)
      i = j
    end
  end
  return args
end

CommandLine {
  description = "xSCL: open .scl from command line";
  prefixes = config.command_prefix;
  action = function(prefix, text)
    local text_value = text or ""
    local cmd, rest = text_value:match("^%s*([^%s]+)%s*(.-)%s*$")
    if cmd and cmd:lower() == "convert-types" then
      local args = split_cli_args(rest or "")
      if #args < 2 then
        local usage_msg = "Usage:\n" .. tostring(config.command_prefix) .. ":convert-types \"<input TYPES.INI>\" \"<output types.lua>\""
        far.Message(usage_msg, "xSCL", nil, "w")
        return
      end

      local result, convert_error = xSCL.types_ini_converter.convert_file(args[1], args[2])
      if not result then
        far.Message(convert_error or "xSCL: conversion failed", "xSCL", nil, "w")
        return
      end

      far.Message("Converted formats: " .. tostring(result.formats_count) .. "\nSaved: " .. tostring(result.output_path), "xSCL", nil, "w")
      return
    end
    local obj = xSCL.panel_factory.from_path(text)
    if obj then
      return xSCL.panel_module, obj
    end
  end;
}

MenuItem {
  description = "xSCL: open current .scl";
  menu = "Plugins";
  area = "Shell";
  guid = config.menu_item_guid;
  text = "xSCL";
  action = function()
    local obj = xSCL.panel_factory.from_active_panel()
    if obj then
      return xSCL.panel_module, obj
    end
  end;
}

PanelModule(xSCL.panel_module)
