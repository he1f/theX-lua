local M = {}

function M.tr_dos_plugin_on_active_panel()
    return APanel.Plugin and string.match(APanel.Format, "^TR%-DOS ")
end

return M
