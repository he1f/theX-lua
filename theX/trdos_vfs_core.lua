local vfs_core = {}
local enc = require("theX.utils.encoding")
local detector = require("theX.detector")

-- [[ Authority local patterns registers mapping system constants ]]
local forbidden_chars_pattern = "[\\/%:%*%?\"<>|]"
local reserved_device_names = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true,
    LPT1 = true, LPT2 = true, LPT3 = true,
}

--- Sanitizes raw TR-DOS filename or DirSys directory chunk strings into an OS-safe representation.
---@param raw_name string The uncleaned filesystem name buffer from disk or memory
---@param fallback_default string The fallback string to use if the text collapses to empty
---@return string sanitized_name Clear text name without restricted symbols, reserved OS devices names, or padding spaces
function vfs_core.sanitize_name(raw_name, fallback_default)
    local default_lbl = fallback_default or "noname"
    if not raw_name or raw_name == "" then return default_lbl end

    -- Replace character layout mismatches matching our host OS forbidden patterns matrix
    local sanitized = string.gsub(raw_name, forbidden_chars_pattern, "_")

    -- Strip trailing spaces character paddings securely
    local clean_name = string.match(sanitized, "^%s*(.-)%s*$") or sanitized

    if clean_name == "" then
        clean_name = default_lbl
    end

    -- If the folder or file matches names like CON, NUL, PRN, COM1, prefix it to prevent OS locks
    if reserved_device_names[string.upper(clean_name)] then
        clean_name = "_" .. clean_name
    end

    return clean_name
end

--- Normalizes full active session array mapping unique, non-colliding layout filenames.
---@param files_list table[] Sequential file dictionary sequence matching active archive entries
---@return nil
function vfs_core.normalize_panel_filenames(files_list)
    if not files_list or #files_list == 0 then return end

    local used_names_registry = {}

    for index, hobeta_file in ipairs(files_list) do
        local m = hobeta_file.meta
        if m then
            -- Leverage our universal sanitization routine
            local base_name = vfs_core.sanitize_name(m.name, "")
            if base_name == "" then
                base_name = string.format("empty_%02d", index)
            end

            local ext = m.new_type or m.type or "C"
            local prefix_char = m.special_char or "$"

            local display_name = base_name .. "." .. prefix_char .. ext
            local counter = 1

            while used_names_registry[display_name] do
                display_name = string.format("%s.%s%s%d", base_name, prefix_char, ext, counter)
                counter = counter + 1
            end

            used_names_registry[display_name] = true
            m.display_name = display_name
        end
    end
end

--- Processes raw CP866 entries for both files and DirSys folders to set initial UTF-8 structures.
---@param files_list table[] Sequential array of files loaded from the TRD sectors
---@param folders_list table[] Sequential array of DirSys directory blocks
---@param detector table Enrichment plugin to parse Spectrum data types descriptions
function vfs_core.refresh_panel_metadata(files_list, folders_list, detector)
    -- [[ STAGE 1: CONVERT AND SANITIZE DIRECTORIES STRINGS FROM CP866 TO UTF-8 ]]
    if folders_list then
        for _, folder in ipairs(folders_list) do
            -- 1. Decode the raw CP866 string directly into clean UTF-8
            local utf8_name = enc.cp866_to_utf8(folder.name or "")

            -- 2. Run universal sanitization layer against forbidden characters and device words
            -- 3. Directly assign the pristine non-colliding result straight onto display_name field
            folder.display_name = vfs_core.sanitize_name(utf8_name, string.format("folder_%02d", folder.id))
        end
    end

    -- [[ STAGE 2: CONVERT FILES STRINGS FROM CP866 TO UTF-8 ]]
    if files_list then
        for _, hobeta_file in ipairs(files_list) do
            local m = hobeta_file.meta
            if m then
                -- Perform localized text translation decoding blocks on file names strings
                m.name = enc.cp866_to_utf8(m.name or "")
                detector.enrich_file_meta(hobeta_file)
            end
        end
    end

    -- [[ STAGE 3: EXECUTE STRICT UNIQUE FILENAMES NORMALIZATION PIPELINE ]]
    vfs_core.normalize_panel_filenames(files_list)
end

return vfs_core
