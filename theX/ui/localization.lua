local localization = {}

-- [[ Component-driven language registration arrays ]]
-- Simply append new paths here whenever you isolate a new sub-module
local component_modules = {
    "theX.ui.main_lang",       -- Core GUI labels (old general strings layout)
    "theX.dialog.lang",
    "theX.formats.raw.lang",   -- RAW format specific strings
}

--- Private helper to dynamically accumulate flat keys into a target runtime table.
---@param target table Destination dictionary in memory
---@param lang_suffix string Target language filename tail selector ("_en" or "_ru")
local function accumulate_dictionaries(target, lang_suffix)
    for _, base_path in ipairs(component_modules) do
        local full_require_path = base_path .. lang_suffix
        -- Use pcall to insulate against missing files in localized sub-folders
        local success, sub_dict = pcall(require, full_require_path)
        if success and type(sub_dict) == "table" then
            for key, text in pairs(sub_dict) do
                target[key] = text
            end
        end
    end
end

-- Pre-compile complete unified language maps in memory on first module load
local compiled_en = {}
local compiled_ru = {}

accumulate_dictionaries(compiled_en, "_en")
accumulate_dictionaries(compiled_ru, "_ru")

-- [[ Metatable Proxy Routing Layer ]]
setmetatable(localization, {
    __index = function(_, key)
        -- Live-query the active system interface language token from Far Manager core environment
        local current_far_lang = win.GetEnv("FARLANG") or "English"

        -- Bind the appropriate pre-compiled data map dynamically
        local active_dictionary = compiled_en -- Strict default fallback boundary

        if string.lower(current_far_lang) == "russian" then
            active_dictionary = compiled_ru
        end

        local translated_str = active_dictionary[key]

        -- Safe cross-dictionary fallback: if token is missing in Russian, pull from English cache
        if translated_str == nil and active_dictionary ~= compiled_en then
            translated_str = compiled_en[key]
        end

        return translated_str or ("{missing_token: " .. tostring(key) .. "}")
    end
})

return localization
