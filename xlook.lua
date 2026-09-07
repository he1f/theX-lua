-- %FARPROFILE%\Macros\scripts\xlook.lua
local macro_file = ...
if type(macro_file) ~= "string" then
  return
end

local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local function load_xlook()
  package.loaded["theX.xLook.xlook"] = nil
  package.loaded["theX.xLook.alasm"] = nil
  package.loaded["theX.xLook.xas"] = nil
  package.loaded["theX.xLook.masm"] = nil
  package.loaded["theX.xLook.masm3"] = nil
  package.loaded["theX.xLook.storm"] = nil
  package.loaded["theX.xLook.tasm2"] = nil
  package.loaded["theX.xLook.tasm"] = nil
  package.loaded["theX.xLook.zxasm"] = nil
  return require("theX.xLook.xlook")
end

CommandLine {
  description = "xLook: open Hobeta/Alasm in editor";
  prefixes = "xlook";
  action = function(prefix, text)
    local xlook = load_xlook()
    return xlook.run(text)
  end;
}

MenuItem {
  description = "xLook: open current file";
  menu = "Plugins";
  area = "Shell";
  guid = "16A711B9-176A-4AB2-9242-68D0A7A4694D";
  text = "xLook";
  action = function()
    local xlook = load_xlook()
    return xlook.run("")
  end;
}
