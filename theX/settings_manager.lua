local settings_manager = {}
local F = far.Flags
local mf = mf -- Built-in Far Manager macro functions engine

local SETTINGS_KEY = "he1f"

---@class PluginSettings
---@field last_panel_mode integer Current active panel layout mode index (3, 4, 5, 6)
---@field last_sort_mode integer Current column sorting code constraint from Far
---@field last_sort_order integer Current sorting direction identifier (0 or 1)
---@field load_settings function Forces re-reading values from the persistent registry
---@field save_settings function Serializes and saves current values back to the registry
---@field get function Safely extracts a dynamic key value with a provided fallback default
---@field set function Live updates or registers a dynamic key and instantly commits it to disk

---@param plugin_name string The unique identifier string assigned as the settings sub-key layer
---@return PluginSettings settings A stateful clean Lua table loaded directly via macro engine
function settings_manager.new(plugin_name)
    local settings_name = plugin_name

    -- Define authoritative internal tracking schema with standard baseline defaults
    local self = {
        last_panel_mode = 4,
        last_sort_mode  = F.SM_UNSORTED,
        last_sort_order = 0,
    }

    ---Forces a direct dynamic iteration reload of variables from the Far macro registry database
    ---@return nil
    function self.load_settings()
        local raw_data = mf.mload(SETTINGS_KEY, settings_name) or {}

        -- [[ DYNAMIC RESTORATION PIPELINE ]]
        -- Iterate across all saved fields inside the macro database slice on the fly.
        -- This automatically maps any newly introduced options without manual field extensions here.
        for key, value in pairs(raw_data) do
            self[key] = value
        end

        -- Enforce explicit sanitize baseline fallback bounds on crucial layout metrics
        if not self.last_panel_mode or self.last_panel_mode == 0 then
            self.last_panel_mode = 4
        end
        self.last_sort_mode  = self.last_sort_mode or F.SM_UNSORTED
        self.last_sort_order = self.last_sort_order or 0
    end

    ---Serializes and flushes all internal data properties automatically straight to disk
    ---@return nil
    function self.save_settings()
        local data_to_save = {}

        -- [[ AUTOMATED EXCLUSION ITERATION SHIELD ]]
        -- Pack only data value types (numbers, strings, booleans, sub-tables) into transient container,
        -- strictly filter-skipping active executable function method blocks pointers.
        for key, value in pairs(self) do
            if type(value) ~= "function" then
                data_to_save[key] = value
            end
        end

        mf.msave(SETTINGS_KEY, settings_name, data_to_save)
    end

    ---Universal getter abstraction helper to safely pull any dynamic option key
    ---@param key string Option identifier key token name
    ---@param default any Fallback value if the specified target key evaluates to nil
    ---@return any value
    function self.get(key, default)
        if self[key] == nil then
            return default
        end
        return self[key]
    end

    ---Universal setter abstraction helper that dynamically registers new keys and triggers immediate file commit
    ---@param key string Option identifier key token name
    ---@param value any New string, number or boolean state configuration parameter
    ---@return nil
    function self.set(key, value)
        self[key] = value
        self.save_settings() -- Transactional flush constraint to safeguard real-time storage sync
    end

    -- Perform initial dynamic direct load on module start
    self.load_settings()

    return self
end

return settings_manager
