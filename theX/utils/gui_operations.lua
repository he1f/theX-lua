local gui_operations = {}
local F = far.Flags
local pipeline = require("theX.xLook.decoder_pipeline") -- Dedicated target text encoding/decoding pipeline

--- Stateful transactional extractor that handles F3 View and F4 Edit requests for SCL and TRD panels.
--- Conducts automatic on-the-fly text decoders conversions and sets up native Far non-modal viewer/editor blocks.
---@param object table The active parent plugin panel context mapping states (SCL or TRD instance)
---@param item tPluginPanelItem Single selected PluginPanelItem structure focused under the cursor passed by Far core
---@param dest_path string Temporary destination root directory on the host PC filesystem (e.g. win.GetEnv("TEMP"))
---@param is_view boolean Active state bit flag for standard non-modal F3 Viewer requests
---@param is_edit boolean Active state bit flag for standard non-modal F4 Editor requests
---@return boolean success Returns true if the temporary file was safely generated and UI window successfully spawned
function gui_operations.process_view_edit(object, item, dest_path, is_view, is_edit)
    if not object or not item or not item.FileName then return false end

    local filename = item.FileName
    if filename == ".." then return false end

    -- [[ STAGE 1: RESOLVE THE TARGET FILE ENTRY FROM ACTIVE SESSION WORKSPACE ]]
    local target_file = nil

    if object.files_list then
        -- TRD specific acceleration path: extract entry directly using cached index token if present
        local target_idx = item._trdos_index
        if target_idx then
            target_file = object.files_list[target_idx + 1]
        else
            -- SCL and fallback path: sequential visual filename string comparison lookup sweep
            for _, hobeta_file in ipairs(object.files_list) do
                if hobeta_file.meta and hobeta_file.meta.display_name == filename then
                    target_file = hobeta_file
                    break
                end
            end
        end
    end

    if not target_file or not target_file.meta or target_file.meta.deleted then
        return false
    end

    local m = target_file.meta
    local raw_data = target_file.data or ""

    -- [[ STAGE 2: RUN INTERACTIVE COMPILER TEXT DECODING PIPELINES ]]
    local text_payload = nil
    local assembler_label = nil
    if m.group == "asm" or m.group == "basic" or m.show_header == false then
        text_payload, assembler_label = pipeline.decode_text_stream(raw_data, m)
    end

    -- [[ STAGE 3: DYNAMICALLY RESOLVE TEMPORARY DISK PATH & EXTENSION SUBSITUTIONS ]]
    local base_file_name = filename:match("^(.-)%.[^%.]+$") or filename
    local target_filename = filename

    -- If a decoder returned a clean string text buffer, override extension to ensure syntax highlights triggers
    if m.group == "asm" then
        target_filename = base_file_name .. ".a80"
    elseif m.group == "basic" then
        target_filename = base_file_name .. ".bas"
    else
        local target_ext = m.ext or m.new_type or m.type or "C"
        target_filename = base_file_name .. "." .. string.lower(target_ext)
        if m.description then
            assembler_label = m.description
        end
    end

    local full_dest_path = win.JoinPath(dest_path, target_filename)

    -- [[ STAGE 4: WRITE ENCODED PAYLOAD STREAM BUFFER TO PHYSICAL HARD DRIVE ]]
    local file_handle = io.open(full_dest_path, "wb")
    if not file_handle then return false end

    if text_payload then
        file_handle:write(text_payload)
    else
        if m.show_header == false then
            file_handle:write(raw_data)
        else
            local header_bytes = target_file.header or ""
            file_handle:write(header_bytes .. raw_data)
        end
    end
    file_handle:close()

    -- [[ STAGE 5: COMPILE CUSTOM NON-MODAL VIEWPORT TITLE LAYOUT DESCRIPTORS ]]
    local custom_title = ""
    local ext_str = m.ext or m.type or "C"

    if string.len(ext_str) == 3 then
        -- Rule 1: Display clean 3-letter custom virtual extension format boundaries
        custom_title = string.format("%s.%s", m.name, ext_str)
    else
        -- Rule 2: Fallback to standard 1-character native TR-DOS classification tags
        local native_type = string.sub(m.type or "C", 1, 1)
        custom_title = string.format("%s.<%s>", m.name, native_type)
    end

    custom_title = string.format("[%s]", custom_title)
    if assembler_label then
        custom_title = custom_title .. "[" .. assembler_label .. "]"
    end

    -- [[ STAGE 6: DISPLAY NON-MODAL CONTAINER ENGINES WINDOWS FRAMES ]]
    -- We pass F.VF_NONMODAL + F.VF_DELETEONCLOSE / EF flags to completely hand off file disposal to Far core
    if is_view then
        viewer.Viewer(full_dest_path, custom_title, nil, nil, nil, nil, F.VF_NONMODAL + F.VF_DELETEONCLOSE)
        return true
    elseif is_edit then
        editor.Editor(full_dest_path, custom_title, nil, nil, nil, nil, F.EF_NONMODAL + F.EF_DELETEONCLOSE)
        return true
    end

    return false
end

--- Synchronizes and maintains the chronological history sequence of items selected by user.
--- Eliminates mismatch gaps between Far Manager internal state lists and sequential extraction passes.
---@param object table The active parent plugin panel context mapping states (SCL or TRD instance)
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@return nil
function gui_operations.sync_selection_order(object, handle)
    if not object or not handle then return end

    -- Fetch active panel configuration boundaries metadata
    local p_info = panel.GetPanelInfo(handle, 1) -- 1 strictly denotes active panel target
    if not p_info or p_info.SelectedItemsNumber == 0 then
        object.selection_order = nil
        return
    end

    -- Initialize tracking buffer array state if missing from session data register
    if not object.selection_order then
        object.selection_order = {}
    end

    -- Create transient lookup maps to clear out unchecked item elements entries
    local active_selection_set = {}

    -- [[ ITERATE ACROSS DISK ENTRIES PANELS ROWS ]]
    for i = 1, p_info.ItemsNumber do
        local item = panel.GetPanelItem(handle, 1, i)
        if item and item.FileName and item.FileName ~= ".." then
            -- Verify if the item is explicitly flagged with native selected attributes masks
            -- PPIF_SELECTED bit constant maps to 0x0001 value boundaries properties
            local is_marked = (item.Flags & 0x0001) ~= 0 or item.Selected == true

            if is_marked then
                active_selection_set[item.FileName] = true

                -- Check if this newly selected element is already logged inside our historical tracking path
                local already_logged = false
                for _, existing_name in ipairs(object.selection_order) do
                    if existing_name == item.FileName then
                        already_logged = true
                        break
                    end
                end

                -- Append the new element token to the end of historical chronologic sequence
                if not already_logged then
                    table.insert(object.selection_order, item.FileName)
                end
            end
        end
    end

    -- [[ INVERSE TRANSACTION CLEANUP CASCADE ]]
    -- Purge elements from our historical table that were manually unselected/unchecked by the user
    for idx = #object.selection_order, 1, -1 do
        local logged_name = object.selection_order[idx]
        if not active_selection_set[logged_name] then
            table.remove(object.selection_order, idx)
        end
    end

    -- Safely clear tracking memory leaks pointers blocks if total checks falls down to absolute zero
    if #object.selection_order == 0 then
        object.selection_order = nil
    end
end

return gui_operations
