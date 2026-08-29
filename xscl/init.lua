-- %FARPROFILE%\Macros\scripts\xscl\init.lua
return {
  panel_module = require("xscl.panel.module"),
  panel_factory = require("xscl.panel.factory"),
  export_ops = require("xscl.operations.export"),
  types_registry = require("xscl.formats.types_registry"),
  types_ini_converter = require("xscl.tools.types_ini_converter"),
}