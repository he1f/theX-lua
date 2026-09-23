local encoding = {}

--- Safe transactional decoder that converts CP866 bytes into clean UTF-8 strings.
--- Skips console code page mutation layers entirely if the system is already configured under CP866.
---@param cp866_bytes string Raw binary string block read straight from TR-DOS track sectors catalog rows
---@return string utf8_str Pristine clean UTF-8 string ready for display onto Far Manager viewports
function encoding.cp866_to_utf8(cp866_bytes)
    if not cp866_bytes or cp866_bytes == "" then return "" end

    -- Extract current workspace interpretation layout metric first
    local current_cp = win.GetConsoleCP()

    -- [[ PERFORMANCE OPTIMIZATION SHIELD LOOP ]]
    -- If the console environment is already locked under CP866, bypass unmanaged API switches entirely
    if current_cp == 866 then
        return win.OemToUtf8(cp866_bytes) or cp866_bytes
    end

    -- Stateful transition block triggered only if current page shifts away from target
    local success, err_msg = win.SetConsoleCP(866)

    if not success then
        -- OS rejected the switch execution layer (fallback to native page translation to protect execution)
        return win.OemToUtf8(cp866_bytes) or cp866_bytes
    end

    local utf8_result = win.OemToUtf8(cp866_bytes) or cp866_bytes

    -- Rollback to restore original host session continuity safely
    win.SetConsoleCP(current_cp)

    return utf8_result
end

--- Safe transactional encoder that compiles UTF-8 panels strings down into pure CP866 binary arrays.
--- Skips console code page mutation layers entirely if the system is already configured under CP866.
---@param utf8_str string Focused user input filename or disk label string collected from the active viewport
---@return string cp866_bytes Packed binary string block matching standard TR-DOS catalog formatting rules
function encoding.utf8_to_cp866(utf8_str)
    if not utf8_str or utf8_str == "" then return "" end

    local current_cp = win.GetConsoleCP()

    -- [[ PERFORMANCE OPTIMIZATION SHIELD LOOP ]]
    if current_cp == 866 then
        return win.Utf8ToOem(utf8_str) or utf8_str
    end

    local success, err_msg = win.SetConsoleCP(866)

    if not success then
        return win.Utf8ToOem(utf8_str) or utf8_str
    end

    local cp866_result = win.Utf8ToOem(utf8_str) or utf8_str
    win.SetConsoleCP(current_cp)

    return cp866_result
end

return encoding
