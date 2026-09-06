local M = {}

local locales = {
  en = require("theX.xTRD.i18n.en"),
  ru = require("theX.xTRD.i18n.ru"),
}

function M.get(lang)
  if type(lang) == "string" and locales[lang] then
    return locales[lang]
  end
  return locales.en
end

function M.format(template, params)
  if type(template) ~= "string" then
    return ""
  end
  if type(params) ~= "table" then
    return template
  end
  return (template:gsub("{([%w_]+)}", function(key)
    local value = params[key]
    if value == nil then
      return "{" .. key .. "}"
    end
    return tostring(value)
  end))
end

return M
