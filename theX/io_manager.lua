local io_manager = {}
local F = far.Flags
local L = require("theX.ui.localization")

--- Recursively checks tree boundaries and creates deep directory path structures.
---@param dir_path string Target filesystem directory path to construct safely
---@return boolean success Returns true if directory path exists or was safely allocated
function io_manager.create_directories(dir_path)
    if not dir_path or dir_path == "" then return false end
    if win.GetFileInfo(dir_path) then return true end

    local parent_dir = string.match(dir_path, "^(.*)[\\/][^\\/]+$")
    if parent_dir and parent_dir ~= "" and parent_dir ~= dir_path then
        io_manager.create_directories(parent_dir)
    end
    return win.CreateDirectory(dir_path) or false
end

--- Serializes a low-level Win32 FILETIME 64-bit structure tracking ticks since Jan 1, 1601 into a localized date string.
---@param win_filetime number|userdata The bit64 or standard timestamp metric tracking bytes from file info
---@return string formatted_time Date layout mapping e.g. "23.09.2026 15:22" or localized "N/A"
local function format_file_time(win_filetime)
    if not win_filetime then
        return L.io_time_not_available
    end

    -- [[ CRITICAL FIX: CONVERT NATIVE 1601 Win32 FILETIME UNMANAGED PAYLOADS ]]
    -- We pass the raw bit64 userdata ticks parameter straight to LuaFAR system converters
    local sys_time = win.FileTimeToSystemTime(win_filetime) or win.FileTime2SystemTime(win_filetime)
    if not sys_time then
        return L.io_time_not_available
    end

    -- Return formatted elements using localized order bounds
    return string.format("%02d.%02d.%04d %02d:%02d",
        sys_time.wDay or sys_time.Day or 0,
        sys_time.wMonth or sys_time.Month or 0,
        sys_time.wYear or sys_time.Year or 0,
        sys_time.wHour or sys_time.Hour or 0,
        sys_time.wMinute or sys_time.Minute or 0)
end


--- Safely writes binary payload arrays protecting against host OS naming collision traps across VFS extraction steps.
---@param full_path string Destination absolute host OS path targeting the writing file
---@param data string Monolithic binary array string payload containing target file contents
---@param conflict_state table Stateful reference transaction hash map tracking previous selections
---@param is_scl boolean If true, enforces a strict 3-button layout stripping "All" execution options triggers
---@return boolean success Returns true if file was physically updated, false if skipped or cancelled
---@return table conflict_state Updated stateful context hash tracker parameters
---@return boolean was_skipped Returns true strictly if the target write action was cleanly skipped by choice
function io_manager.safe_write_file(full_path, data, conflict_state, is_scl)
    local base_dir = string.match(full_path, "^(.*)[\\/][^\\/]+$")
    if base_dir then
        io_manager.create_directories(base_dir)
    end

    local file_info = win.GetFileInfo(full_path)

    if not file_info then
        local file_handle = io.open(full_path, "wb")
        if not file_handle then return false, conflict_state, false end
        file_handle:write(data)
        file_handle:close()
        return true, conflict_state, false
    end

    -- If user previously engaged a blanket skip operation across single assets extraction steps
    if not is_scl and conflict_state.skip_all then
        return false, conflict_state, true
    end

    -- Evaluate whether user requires interactive message box intervention layer
    if is_scl or not conflict_state.overwrite_all then
        local filename = string.match(full_path, "([^\\/]+)$") or full_path
        local existing_size = file_info.FileSize or 0
        local existing_time = format_file_time(file_info.LastWriteTime)

        -- [[ SYNTHESIZE DYNAMIC LOCALIZED TEXTS CONTAINER MATRICES ]]
        local message_lines = {
            L.io_msg_file_exists,
            L.io_msg_filename .. filename,
            string.format(L.io_msg_current_on_disk, existing_size, existing_time),
            string.format(L.io_msg_new_from_archive, string.len(data)),
            L.io_msg_overwrite_prompt
        }

        local buttons, code, dialog_title
        if is_scl then
            -- RULE 2: Rigid 3-button prompt layout without any "All" multi-transactions parameters
            buttons = L.io_btn_overwrite .. ";" .. L.io_btn_skip .. ";" .. L.m_btn_cancel
            dialog_title = L.io_title_scl_conflict
            code = far.Message(table.concat(message_lines, "\n"), dialog_title, buttons, "w")

            if code == 2 then return false, conflict_state, true end
            if code ~= 1 then conflict_state.abort = true return false, conflict_state, false end
        else
            -- Standard 5-button package cascade prompt utilized during bulk single HoBeta extraction cycles
            buttons = string.format("%s;%s;%s;%s;%s",
                L.io_btn_overwrite, L.io_btn_skip, L.io_btn_overwrite_all, L.io_btn_skip_all, L.m_btn_cancel)
            dialog_title = L.io_title_name_conflict
            code = far.Message(table.concat(message_lines, "\n"), dialog_title, buttons, "w")

            if code == 2 then
                return false, conflict_state, true
            elseif code == 3 then
                conflict_state.overwrite_all = true
            elseif code == 4 then
                conflict_state.skip_all = true
                return false, conflict_state, true
            elseif code ~= 1 then
                conflict_state.abort = true
                return false, conflict_state, false
            end
        end
    end

    -- Final execution lock flushing binary stream to host storage
    local file_handle = io.open(full_path, "wb")
    if not file_handle then return false, conflict_state, false end
    file_handle:write(data)
    file_handle:close()

    return true, conflict_state, false
end

return io_manager
