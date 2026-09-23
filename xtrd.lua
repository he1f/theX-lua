local macro_file = ...
if type(macro_file) ~= "string" then
  return
end
local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path

local F = far.Flags
local L = require("theX.ui.localization")
local trd_reader = require("theX.formats.trd.reader")
local dir_sys = require("theX.formats.trd.dir_sys")
local trd_writer = require("theX.formats.trd.writer")
local vfs_core = require("theX.trdos_vfs_core")
local detector = require("theX.detector")
local dialog_manager = require("theX.dialog.manager")

local settings_manager = require("theX.settings_manager")
local plugin_settings = settings_manager.new("xtrd")

-- Справочник UUID и констант
local plugin_guid = win.Uuid("B4C1D2A3-E5F6-4A7B-8C9D-0E1F2A3B4C5D")
local SECTOR_SIZE = 256

--- Private helper to recursively trace parent IDs and compile a multi-level nested folder path string.
---@param folders table[] The sequential cached array of active DirSys directories mapping properties
---@param folder_id integer The targeted subdirectory entry identifier we want to trace from
---@return string full_path Compiled string containing backslash-delimited path (e.g. "SOURCES\ASM\LIBS")
local function compile_nested_folder_path(folders, folder_id)
    if not folders or not folder_id or folder_id == 0 then
        return ""
    end

    local path_parts = {}
    local current_id = folder_id

    -- Safe circuit breaker to protect against infinite loops in corrupted circular directory trees
    local max_depth_safety = 128

    while current_id ~= 0 and max_depth_safety > 0 do
        max_depth_safety = max_depth_safety - 1
        local found = false

        for _, folder in ipairs(folders) do
            if folder.id == current_id then
                local f_name = folder.name or "UNKNOWN"
                f_name = string.match(f_name, "^%s*(.-)%s*$") or f_name -- Trim trailing spaces

                table.insert(path_parts, 1, f_name) -- Insert at the beginning to reverse the upward walk
                current_id = folder.parent_id or 0  -- Hop up to parent node location
                found = true
                break
            end
        end

        if not found then
            break
        end
    end

    return table.concat(path_parts, "\\")
end

--- Executes full TR-DOS MOVE compaction process, physically erasing 0x01 flagged assets
--- and shifting sectors arrays blocks down to eliminate fragmentation gaps.
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@return nil
local function execute_trdos_move_compaction(object, handle)
    if not object or not object.files_list then return end

    -- Verify if there are any deleted assets present before initiating disk heavy operations
    local has_deleted_files = (object.trd_info and (object.trd_info.deleted_files or 0) > 0)
    local has_deleted_folders = false

    if object.trd_folders then
        for _, folder in ipairs(object.trd_folders) do
            if folder.deleted then
                has_deleted_folders = true
                break
            end
        end
    end

    if not (has_deleted_files or has_deleted_folders) then
        far.Message(L.trd_msg_move_no_deleted, L.m_plugin_menu_title, L.m_btn_ok, "i")
        return
    end

    -- [[ STEP 1: COMPACT FILES ROSTER MEMORY ARRAYS ]]
    local active_files_buffer = {}
    -- Keep tracking original-to-new index translations maps to reconstruct DirSys mappings safely
    local file_index_migration_map = {}
    local original_file_counter = 0
    local migrated_file_counter = 0

    for idx, hobeta_file in ipairs(object.files_list) do
        local m = hobeta_file.meta
        local is_file_deleted = m and (m.deleted or string.byte(m.name or "", 1) == 0x01)

        if not is_file_deleted then
            table.insert(active_files_buffer, hobeta_file)
            file_index_migration_map[original_file_counter] = migrated_file_counter
            migrated_file_counter = migrated_file_counter + 1
        else
            file_index_migration_map[original_file_counter] = -1 -- Marked as dead node
        end
        original_file_counter = original_file_counter + 1
    end

    -- [[ STEP 2: COMPACT DIRSYS FOLDERS ROSTER MEMORY ARRAYS ]]
    local active_folders_buffer = {}
    local folder_id_migration_map = { [0] = 0 } -- Root index preservation anchor
    local migrated_folder_counter = 0

    if object.trd_folders then
        for _, folder in ipairs(object.trd_folders) do
            if not folder.deleted and string.byte(folder.name, 1) ~= 0x01 then
                migrated_folder_counter = migrated_folder_counter + 1
                folder_id_migration_map[folder.id] = migrated_folder_counter

                -- Temporarily staging data properties
                table.insert(active_folders_buffer, {
                    old_id = folder.id,
                    old_parent_id = folder.parent_id or 0,
                    name = folder.name
                })
            end
        end

        -- Re-serialize clean packed folders structures fixing updated parental tree relationships IDs
        object.trd_folders = {}
        for new_idx, staged_folder in ipairs(active_folders_buffer) do
            local newly_assigned_parent = folder_id_migration_map[staged_folder.old_parent_id] or 0

            table.insert(object.trd_folders, {
                id        = new_idx,
                name      = staged_folder.name,
                parent_id = newly_assigned_parent,
                deleted   = false
            })
        end
    end

    -- [[ STEP 3: RE-MAP ACTIVE DIRSYS FILE FILE_ASSIGNMENTS LOOKUPS ]]
    if object.trd_file_maps then
        local packed_file_maps = {}
        for old_file_idx = 0, (original_file_counter - 1) do
            local new_file_idx = file_index_migration_map[old_file_idx]

            if new_file_idx and new_file_idx ~= -1 then
                local old_parent_folder_id = object.trd_file_maps[old_file_idx] or 0
                local new_parent_folder_id = folder_id_migration_map[old_parent_folder_id] or 0
                packed_file_maps[new_file_idx] = new_parent_folder_id
            end
        end
        object.trd_file_maps = packed_file_maps
    end

    -- Swop the transient files list buffer straight into main active panel context storage
    object.files_list = active_files_buffer

    -- Reset the native TR-DOS system deleted metrics counter parameter back to 0
    if object.trd_info then
        object.trd_info.deleted_files = 0
    end

    -- [[ STEP 4: PHYSICAL SECTORS SHIFT DEFRAGMENTATION AND FLUSH REWRITE ]]
    -- We pass true as 4th parameter to update_headers to enforce dynamic reallocation
    -- of tracks and sectors parameters for remaining active items sequentially!
    local flush_success = trd_writer.save(object.archive_path, object.files_list, object, true)

    if flush_success then
        far.Message(L.trd_msg_move_success, L.m_trd_menu_title, L.m_btn_ok, "i")
        -- Force low-level frame update queues triggers to surface shifts rows results
        panel.UpdatePanel(handle, F.PANEL_ACTIVE)
        panel.RedrawPanel(handle, F.PANEL_ACTIVE)
    else
        far.Message(L.m_err_write_failed, L.m_err_title, L.m_btn_cancel, "w")
    end
end

-- Публичный неймспейс плагина (сюда пишем ТОЛЬКО экспортируемые методы)
local M = {}

M.Info = {
  Guid = plugin_guid,
  Version = "0.1.0",
  Title = "xTRD",
  Description = "TRD eXplorer",
  Author = "Dima Kozlov",
}

---@param object table The plugin instance table
---@param handle userdata The low-level Far Manager panel handle
---@return table info Configuration layout properties for Far Manager to render
function M.GetOpenPanelInfo(object, handle)
  -- 1. Принудительно обновляем данные из реестра/базы Far Manager перед выдачей инфо
  plugin_settings.load_settings()

  -- [[ ПРАВИЛО: Вычисляем числовой ASCII-код режима БЕЗ приведения к строке string.char ]]
  local saved_mode_num = tonumber(plugin_settings.last_panel_mode) or 4
  if saved_mode_num < 3 or saved_mode_num > 6 then
      saved_mode_num = 4
  end
  -- Маппим индекс режима на ASCII код символа: Режим 4 -> 0x30 + (4 - 1) = 0x33 ('3')
  local start_mode_char_code = 0x30 + saved_mode_num

  -- Описываем структуру колонок для каждого кастомного режима (m3, m4, m5, m6)
  local m3 = {
    ColumnTypes = "N,C3,N,C3",
    ColumnWidths = "0,3,0,3",
    ColumnTitles = { L.col_title_name, L.col_title_sectors_sz, L.col_title_name, L.col_title_sectors_sz },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  local m4 = {
    ColumnTypes = "C0,C1,C2,C3,C4,C5",
    ColumnWidths = "0,5,5,3,3,3",
    ColumnTitles = {
        L.col_title_name,
        L.col_title_size,
        L.col_title_start,
        L.col_title_sectors_sz,
        L.col_title_track,
        L.col_title_sector_st
    },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  local m5 = {
    ColumnTypes = "C0,C6",
    ColumnWidths = "12,0",
    ColumnTitles = { L.col_title_name, L.col_title_description },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  local m6 = {
    ColumnTypes = "C0,C7",
    ColumnWidths = "12,0",
    ColumnTitles = { L.col_title_name, L.col_title_comments },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  -- Массив режимов для LuaFAR (m3 встает на 4-ю позицию, m4 - на 5-ю)
  local trd_panel_modes = {
    {}, {}, {}, m3, m4, m5, m6
  }

  local host_file = object.archive_path or ""
  local base_file_name = host_file:match("([^\\/]+)$") or host_file
  local panel_title = "TRD"
  if base_file_name ~= "" then
    panel_title = "TRD:" .. base_file_name
  end

  -- [[ MULTI-LEVEL DYNAMIC DIRSYS SUBDIRECTORY TITLE GENERATION ]]
  local current_id = object.current_folder_id or 0
  local nested_trail = ""
  if current_id ~= 0 and object.trd_folders then
    -- Run the upward-walking compiler to resolve deep paths seamlessly
    nested_trail = compile_nested_folder_path(object.trd_folders, current_id)
    if nested_trail ~= "" then
      panel_title = panel_title .. "\\" .. nested_trail
    end
  end

  return {
    HostFile         = host_file,
    Format           = "TR-DOS TRD",
    PanelTitle       = panel_title,
    PanelModesArray  = trd_panel_modes,
    PanelModesNumber = #trd_panel_modes,
    StartPanelMode   = start_mode_char_code,
    StartSortMode    = plugin_settings.last_sort_mode,
    StartSortOrder   = plugin_settings.last_sort_order,
    Flags            = F.OPIF_ADDDOTS,
    CurDir           = nested_trail,
  }
end

--- Core VFS orchestration callback triggered to mount and open the virtual TRD file list panel.
---@param open_from integer Native activation context origin code key (maps to standard F.OPEN_*)
---@param guid string System unique registry 128-bit GUID identification token mapping string
---@param item any Input parameter object matching signature properties constraints defined by the active OpenFrom origin context mode
---@return any ret Handled response evaluation result parameter passed right back to the Far Manager core execution layout
function M.Open(open_from, guid, item)
    if not item or item == "" then return nil end

    if open_from == F.OPEN_ANALYSE then
        item = item.FileName
    end

    -- Execute safe atomic geometry boundary validations first
    local is_valid, error_code = trd_reader.is_valid(item)
    if not is_valid then
        local token = string.lower(error_code or "err_cannot_open_file")
        local lang_key = L["trd_" .. token] and ("trd_" .. token) or "err_cannot_open_file"
        far.Message(L[lang_key], L.m_err_title, L.m_btn_cancel, "w")
        return nil
    end

    -- Create the persistent session object instance mapping workspace panel properties
    local object = {
        archive_path  = item,
        format_type   = "trd",
        files_list    = {},
        selection_order = {}
    }

    -- Unpack sectors layout data down to virtual element containers arrays
    trd_reader.process(object.files_list, item, object)

    -- Run the global normalizer pipeline to resolve display name collisions and enrich metadata
    vfs_core.refresh_panel_metadata(object.files_list, object.trd_folders, detector)

    -- Return the compiled session context object pointer.
    -- Far Manager core natively transforms this table to construct active VFS frames
    return object
end

--- Compiles, parses and renders files and DirSys directories list with advanced column alignment.
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param key_flags integer Native operation mode mask flags passed by Far core (F.OPM_*)
---@return table[]|nil panel_items Array of PluginPanelItem structures ready to render on screen
function M.GetFindData(object, handle, key_flags)
    if not object then return nil end

    -- [[ STAGE 1: LIVE RELOAD CACHE TRANSACTION IF NOT IN BACKGROUND SEARCH ]]
    if (key_flags & F.OPM_FIND) == 0 then
        for i = #object.files_list, 1, -1 do
            object.files_list[i] = nil
        end
        -- Re-read actual sectors tracking metrics and re-run detector normalizers
        trd_reader.process(object.files_list, object.archive_path, object)
        vfs_core.refresh_panel_metadata(object.files_list, object.trd_folders, detector)
    end

    if not object.current_folder_id then
        object.current_folder_id = 0
    end

    -- [[ STAGE 2: DYNAMIC RESOLUTION OF THE C0 COLUMN PHYSICAL CHARACTER WIDTH ]]
    local c0_width = 0
    local col_types_str = panel.GetColumnTypes(handle, F.PANEL_ACTIVE)
    local col_widths_str = panel.GetColumnWidths(handle, F.PANEL_ACTIVE)

    if col_types_str and col_widths_str then
        local next_type = string.gmatch(col_types_str, "([^,]+)")
        local next_width = string.gmatch(col_widths_str, "([^,]+)")

        while true do
            local col_type = next_type()
            local col_width = next_width()
            if not col_type or not col_width then break end

            col_type = string.match(col_type, "^%s*(.-)%s*$") or col_type
            if col_type == "C0" then
                c0_width = tonumber(col_width) or 0
                break
            end
        end
    end

    local far_items = {}

    -- [[ STAGE 3: RENDER VIRTUALLY GENERATED DIRSYS SUBDIRECTORIES ]]
    if object.trd_folders then
        for _, folder in ipairs(object.trd_folders) do
            -- Display folders belonging to the current navigation viewport level
            local is_active_layer = (folder.parent_id == object.current_folder_id)
            if is_active_layer then
                local folder_name = folder.display_name or "new_folder"

                -- [[ INTELLECTUAL DELETION BLENDING VIA OBJECT PROPERTY ]]
                -- Read the native flag parameter strictly from object attributes.
                -- Remap logically deleted folders into hidden items ("dh")
                local attr_string = folder.deleted and "dh" or "d"

                table.insert(far_items, {
                    FileName        = folder_name,
                    AlternateFileName = "",
                    FileAttributes  = attr_string,
                    FileSize        = 0,
                    AllocationSize  = 0,
                    _dir_sys_id     = folder.id,
                    _is_dir_sys     = true,

                    CustomColumnData = {
                        folder_name,
                        "", "", "", "", "", "", ""
                    }
                })
            end
        end
    end

    -- [[ STAGE 4: RENDER ACTIVE FILES MATCHING THE VIEWPORT LEVEL WITH DETECTOR DATA ]]
    for idx, hobeta_file in ipairs(object.files_list) do
        local m = hobeta_file.meta
        if m and m.display_name then
            local file_trdos_idx = idx - 1

            local file_parent_id = 0
            -- Resolve which folder this file belongs to via our parsed file maps registry
            if object.trd_file_maps then
                file_parent_id = object.trd_file_maps[file_trdos_idx] or 0
            end
            -- Filter constraint: append only items matching current folder viewport level
            if file_parent_id == object.current_folder_id then

                -- [[ INTELLECTUAL EXTENSION DESIGN RIGGING ]]
                -- Process exact 3-character virtual extension representation blocks
                local type_str = ""
                local ext_str = m.ext or m.type or "C"
                if string.len(ext_str) == 3 then
                    type_str = ext_str
                else
                    type_str = "<" .. ext_str .. ">"
                end

                -- Precise whitespace-padding alignment execution inside C0 column space boundaries
                local combined_name_and_type = ""
                local raw_name = m.name or ""
                raw_name = string.match(raw_name, "^%s*(.-)%s*$") or raw_name -- trim edges

                if c0_width > 0 then
                    local name_len = string.len(raw_name)
                    local type_len = string.len(type_str)
                    local spaces_count = c0_width - name_len - type_len
                    if spaces_count < 1 then spaces_count = 1 end
                    combined_name_and_type = raw_name .. string.rep(" ", spaces_count) .. type_str
                else
                    combined_name_and_type = raw_name .. " " .. type_str
                end

                -- Assemble enriched descriptive text parameters pulling from the detector layer
                local desc_str = m.description or ""
                local meta_str = m.comment or ""
                if m.author and m.author ~= "" then
                    if meta_str ~= "" then meta_str = meta_str .. " by " .. m.author
                    else meta_str = "by " .. m.author end
                end
                table.insert(far_items, {
                    FileName       = m.display_name,
                    AlternateFileName = "",
                    FileAttributes = m.deleted and "h" or "",
                    -- Logical export size maps to standard HoBeta payload structure: 17 bytes header + raw body bytes
                    FileSize       = 17 + ((m.sectors or 1) * SECTOR_SIZE),
                    AllocationSize = 17 + ((m.sectors or 1) * SECTOR_SIZE),
                    _trdos_index   = file_trdos_idx,
                    _is_dir_sys    = false,

                    -- [[ FILL COMPLETE AUTHORITY CUSTOMCOLUMNDATA CODES ]]
                    CustomColumnData = {
                        combined_name_and_type,       -- C0: Smart aligned name + extension
                        tostring(m.size or 0),        -- C1: Size
                        tostring(m.start or 0),       -- C2: Start Address
                        tostring(m.sectors or 1),     -- C3: Sectors Count
                        tostring(m.track or 1),       -- C4: Start Track index position
                        tostring(m.sector or 0),      -- C5: Start Sector index position
                        desc_str,                     -- C6: Advanced Detector description line
                        meta_str                      -- C7: Author comments / Special signatures tags
                    }
                })
            end
        end
    end

    return far_items
end

--- Handles VFS file tree navigation steps inside DirSys directories layout.
--- Triggered natively by Far Manager core whenever user changes directories inside the plugin panel.
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param dir string Target destination directory path or layout command string (e.g. "..", "\", or folder name)
---@param op_mode integer Operation mode bitmask flags passed natively by Far Manager (F.OPM_*)
---@param user_data any Custom user data value passed via panel transaction contexts
---@return boolean success Returns true/false for navigation updates
function M.SetDirectory(object, handle, dir, op_mode, user_data)
    if not object then return false end

    -- Initialize baseline tracking indices registers if missing on context entry
    if not object.current_folder_id then
        object.current_folder_id = 0
    end

    -- Trim boundary spaces from the incoming target directory name string tightly
    local clean_dir = string.match(dir or "", "^(.-)%s*$") or dir or ""

    -- [[ CASE A: NAVIGATE TO ROOT FILESYSTEM TREE DIRECTORY ]]
    if clean_dir == "" or clean_dir == "\\" or clean_dir == "/" then
        object.current_folder_id = 0
        return true
    end

    -- [[ CASE B: STEP ONE LEVEL UP IN NAVIGATION HIERARCHY ]]
    if clean_dir == ".." then
        if object.current_folder_id == 0 then
            -- to unmount the active virtual TRD VFS layer and gracefully restore the native OS file panel view
            return true
        else
            -- Locate the active directory element we reside in right now to fetch its native parent index
            local target_parent_id = 0

            if object.trd_folders then
                for _, folder in ipairs(object.trd_folders) do
                    if folder.id == object.current_folder_id then
                        target_parent_id = folder.parent_id or 0
                        break
                    end
                end
            end

            -- Seamlessly shift the active navigation viewport up exactly one level bounds
            object.current_folder_id = target_parent_id
            return true -- Tell Far Manager to refresh the view via GetFindData

        end
    end

    -- [[ CASE C: STEP INSIDE A VIRTUAL DIRSYS SUBDIRECTORY ]]
    -- Scan the cached directories dictionary to resolve matching name tokens IDs
    if object.trd_folders then
        for _, folder in ipairs(object.trd_folders) do
            -- Verify directory identity matches and check it is not marked as deleted
            if not folder.deleted and folder.name == clean_dir then
                -- Perform the stateful hop transition lock live
                object.current_folder_id = folder.id
                return true -- Navigation handled successfully, tell Far to re-trigger GetFindData
            end
        end
    end

    -- Fallback safety valve: if target path token was not found inside the active schema, reject execution
    return false
end

--- Native Far VFS callback triggered to create new subdirectory nodes inside the panel (F7).
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param dir_name any Target path directory layout
---@param op_mode integer Operation mode bitmask flags passed natively by Far Manager
---@return integer result Returns 1 on success, 0 to abort, or -1 if directory exists or loading collapsed
function M.MakeDirectory(object, handle, dir_name, op_mode)
    if not object then return 0 end

    -- [[ STEP 1: VERIFY CONFIGURATION CONTROL SHIELD ]]
    local use_dirsys = plugin_settings and plugin_settings.get("use_dirsys", true)
    if use_dirsys == nil then use_dirsys = true end

    if not use_dirsys then
        far.Message(L.trd_err_dirsys_disabled, L.m_err_title, L.m_btn_cancel, "w")
        return -1
    end

    -- [[ STEP 2: CHECK FOR EXISTING DIRSYS INSTANCE AND PROMPT INITIALIZATION ]]
    if not object.trd_folders or not object.trd_file_maps then
        local msg_buttons = L.m_btn_ok .. ";" .. L.m_btn_cancel
        local choice = far.Message(L.trd_msg_init_dirsys_body, L.trd_msg_init_dirsys_title, msg_buttons, "w")

        if choice ~= 1 then
            return -1
        end

        dir_sys.initialize_empty_system(object)
    end

    -- [[ STEP 3: SHOW GRAPHICAL STRING INPUT DIALOG WINDOW WITH RIGID NIL PROTECTION ]]
    local input_path = dir_name
    if not input_path or input_path == "" then
        input_path = dialog_manager.show_create_folder_dialog()
    end

    -- [[ CRITICAL FIX 1: SECURE ATOMIC SHIELD AGAINST NIL STRINGS COMPARISONS ]]
    -- Instantly halt execution if user pressed Escape/Cancel inside show_create_folder_dialog
    if not input_path or input_path == "" then
        return -1
    end

    -- [[ STEP 4: PARSE AND ITERATE NESTED SECTIONS PATH CHUNKS WITH HONEST STEP-DOWN ]]
    -- Secure the starting operational folder node ID position context
    local active_parent_id = object.current_folder_id or 0
    local is_tree_changed = false

    -- Loop across delimited string layout segments sequentially (e.g. "GAMES\ACTION\CHESS")
    for segment in string.gmatch(input_path, "[^\\]+") do
        segment = string.match(segment, "^(.-)%s*$") or segment

        if segment ~= "" then
            -- Normalize and pad string up to standard DirSys 11 character limits requirements
            local normalized_name = string.sub(segment, 1, 11)

            local resolved_folder_id = nil
            if object.trd_folders then
                for _, existing_folder in ipairs(object.trd_folders) do
                    -- Enforce strict dual bounds: parent link must match current loop tier, name must match
                    if not existing_folder.deleted and
                       existing_folder.parent_id == active_parent_id and
                       existing_folder.name == normalized_name then

                        resolved_folder_id = existing_folder.id
                        break
                    end
                end
            end

            -- If the folder is missing at this specific level, create it cleanly
            if not resolved_folder_id then
                -- DirSys permits a hard architectural ceiling limit of 127 folders total
                local next_id = #object.trd_folders + 1
                if next_id > 127 then
                    far.Message(L.trd_err_dirsys_limit, L.m_err_title, L.m_btn_cancel, "w")
                    return 0
                end
                local new_node = {
                    id        = next_id,
                    name      = normalized_name,
                    parent_id = active_parent_id, -- [[ STRICLY LINKED TO THE ACTIVE LEVEL TIER ]]
                    deleted   = false
                }
                table.insert(object.trd_folders, new_node)
                resolved_folder_id = next_id
                is_tree_changed = true
            end

            -- Shift pointer downward to use the newly found/created folder's ID as the parent for the NEXT segment!
            active_parent_id = resolved_folder_id
        end
    end

    -- [[ STEP 5: PHYSICAL FLUSH REWRITE TRANSACTIONS CASCASE ]]
    if is_tree_changed then
        local commit_success = trd_writer.save(object.archive_path, object.files_list, object, false)
        if not commit_success then
            far.Message(L.m_err_write_failed, L.m_err_title, L.m_btn_cancel, "w")
            return 0
        end
    end

    -- Force low-level frame update queues triggers to surface updates on screens lists rows
    panel.UpdatePanel(handle, F.PANEL_ACTIVE)
    panel.RedrawPanel(handle, F.PANEL_ACTIVE)
    return 1
end

local trd_writer = require("theX.formats.trd.writer")

--- Collects all nested subdirectory IDs under the specified target folder nodes recursively.
---@param folders table[] Cached list array of active DirSys directories mapping properties
---@param initial_delete_ids table<integer, boolean> Lookup hash set containing folder IDs selected for deletion
---@return table<integer, boolean> cascade_delete_ids Complete populated lookup map of all target deleted catalog IDs
local function collect_cascade_folder_ids(folders, initial_delete_ids)
    local deleted_map = {}
    for id, state in pairs(initial_delete_ids) do
        deleted_map[id] = state
    end

    local scan_needed = true
    -- Loop down the tree layout branches layer by layer until no more children are gathered
    while scan_needed do
        scan_needed = false
        for _, folder in ipairs(folders) do
            local f_id = folder.id
            local p_id = folder.parent_id or 0

            -- [[ FIXED: Replaced string byte lookup with clean object property evaluation ]]
            -- If parent folder is already marked for deletion, but child isn't collected yet
            if deleted_map[p_id] and not deleted_map[f_id] and not folder.deleted then
                deleted_map[f_id] = true
                scan_needed = true -- Trigger another deep scan iteration loop sweep
            end
        end
    end

    return deleted_map
end

--- Native Far Manager VFS callback triggered whenever a user attempts to delete items (F8).
--- Supports full deep cascading tree deletion for DirSys folders and target sub-assets.
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param panel_items tPluginPanelItem[] Sequential array containing items checked or focused for deletion
---@param op_mode integer Operation mode bitmask flags passed natively by Far Manager core (F.OPM_*)
---@return boolean success Returns true if deletion was handled successfully, false to abort
function M.DeleteFiles(object, handle, panel_items, op_mode)
    if not object or not panel_items or #panel_items == 0 then return false end

    -- [[ STAGE 1: USER CONFIRMATION DIALOG INTERCEPT ]]
    if (op_mode & F.OPM_SILENT) == 0 then
        local msg_buttons = L.m_btn_ok .. ";" .. L.m_btn_cancel
        local choice = far.Message(L.trd_dlg_delete_confirm, L.trd_dlg_delete_title, msg_buttons, "w")
        if choice ~= 1 then return false end
    end
    local is_state_mutated = false
    local folder_ids_to_delete = {}
    local files_to_delete = {}

    -- [[ STAGE 2: INITIAL HARVESTING OF SELECTED TARGETS ]]
    for _, item in ipairs(panel_items) do
        local filename = item.FileName
        local attr_str = item.FileAttributes or ""
        local is_dir = string.match(attr_str, "d") ~= nil

        if is_dir then
            if object.trd_folders then
                for _, folder in ipairs(object.trd_folders) do
                    -- [[ FIXED: Replaced string byte lookup with clean object property evaluation ]]
                    -- Identify selected folder currently focused inside active workspace layer viewport
                    if not folder.deleted and
                       folder.parent_id == object.current_folder_id and
                       folder.name == filename then

                        folder_ids_to_delete[folder.id] = true
                        break
                    end
                end
            end
        else
            -- Queue files immediately using standard target index lookups
            table.insert(files_to_delete, item)
        end
    end

    -- [[ STAGE 3: EXECUTE CASCADE EVALUATION DOWN FOR SUB-DIRECTORIES ]]
    if object.trd_folders and next(folder_ids_to_delete) then
        -- Run the tree-walking crawler to collect all child folder IDs down to the leaf nodes
        folder_ids_to_delete = collect_cascade_folder_ids(object.trd_folders, folder_ids_to_delete)

        -- Apply soft 0x01 deletion markers and logical flags to all collected directories nodes
        for _, folder in ipairs(object.trd_folders) do
            -- [[ FIXED: Replaced string byte lookup with clean object property evaluation ]]
            if folder_ids_to_delete[folder.id] and not folder.deleted then
                folder.name = string.char(0x01) .. string.sub(folder.name, 2)
                folder.deleted = true
                is_state_mutated = true
            end
        end
    end

    -- [[ STAGE 4: PROCESS FILES MARKED DIRECTLY AND INDIRECTLY VIA CASCADE LOOKUPS ]]
    if object.files_list then
        for idx, hobeta_file in ipairs(object.files_list) do
            local m = hobeta_file.meta
            -- [[ FIXED: Replaced string byte lookup with clean object property evaluation ]]
            if m and not m.deleted then
                local file_trdos_idx = idx - 1

                -- Resolve file parent directory container index position
                local file_parent_id = 0
                if object.trd_file_maps and object.trd_file_maps[file_trdos_idx] then
                    file_parent_id = object.trd_file_maps[file_trdos_idx]
                end

                -- Match if file is contained inside any nested directories slated for deletion
                local is_orphaned_by_cascade = folder_ids_to_delete[file_parent_id] == true

                -- Check if file was explicitly selected by user highlights rows
                local is_explicitly_selected = false
                for _, f_item in ipairs(files_to_delete) do
                    if f_item._trdos_index == file_trdos_idx or (not f_item._trdos_index and m.display_name == f_item.FileName) then
                        is_explicitly_selected = true
                        break
                    end
                end

                -- If file triggers any execution boundaries rules conditions, perform soft delete sequence
                if is_explicitly_selected or is_orphaned_by_cascade then
                    local raw_trdos_name = m.name or ""
                    m.name = string.char(0x01) .. string.sub(raw_trdos_name, 2)
                    m.deleted = true

                    if object.trd_info then
                        object.trd_info.deleted_files = (object.trd_info.deleted_files or 0) + 1
                    end
                    is_state_mutated = true
                end
            end
        end
    end

    -- [[ STAGE 5: PHYSICAL TRANSACTION COMMIT LOCK ]]
    if is_state_mutated then
        local flush_success = trd_writer.save(object.archive_path, object.files_list, object, true)
        if flush_success then
            panel.UpdatePanel(handle, F.PANEL_ACTIVE)
            panel.RedrawPanel(handle, F.PANEL_ACTIVE)
            return true
        else
            far.Message(L.trd_err_delete_failed, L.m_err_title, L.m_btn_cancel, "w")
            return false
        end
    end

    return false
end

function M.Analyse(data)
    return data.FileName:lower():match("%.trd$") ~= nil
end

---@param object table The plugin instance table
---@param handle userdata The low-level Far Manager panel handle
---@param event integer The event code passed by Far Manager (F.FE_*)
---@param param any Additional event parameter data
---@return boolean handled Returns true if the plugin fully processed the event, false otherwise
function M.ProcessPanelEvent(object, handle, event, param)
    -- ПРАВИЛО: Ловим событие смены режима панели (Ctrl+3 - Ctrl+6)
    if event == F.FE_CHANGEVIEWMODE then
        -- Принудительно заставляем Far Manager сбросить кэш CustomColumnData
        -- Третий аргумент true заставляет ядро полностью зачистить старые строки C0
        panel.UpdatePanel(handle, F.PANEL_ACTIVE, true)
        panel.RedrawPanel(handle, F.PANEL_ACTIVE)
        return true -- Событие успешно обработано
    -- elseif event == F.FE_REDRAW then
    --     local panel_info = panel.GetPanelInfo(nil, F.PANEL_ACTIVE)
    --     local panel_mode = panel_info.ViewMode
    --     if panel_mode == 4 then
    --         panel.UpdatePanel(nil, F.PANEL_ACTIVE, true)
    --         -- panel.RedrawPanel(nil, F.PANEL_ACTIVE)
    --         return false
    --     end
    --     return false
    end

    return false
end


function M.ClosePanel(object, handle)
    -- Вызываем GetPanelInfo СТРОГО с одним аргументом, как в оригинале!
    local info = panel.GetPanelInfo(handle)

    if info then
        plugin_settings.last_panel_mode = info.ViewMode
        plugin_settings.last_sort_mode = info.SortMode

        -- Сверяем флаги с использованием правильной константы PFLAGS_REVERSESORTORDER
        if info.Flags and F.PFLAGS_REVERSESORTORDER then
            plugin_settings.last_sort_order = (info.Flags & F.PFLAGS_REVERSESORTORDER) == 0 and 0 or 1
        else
            plugin_settings.last_sort_order = 0
        end

        -- Физически пишем плоские данные в реестр макросов
        plugin_settings.save_settings()
    end
end


-- [[ DECLARATIVE LUA_FAR INTERFACE INTEGRATION LAYER ]]
MenuItem {
    menu   = "Plugins",
    area   = "Shell",
    guid   = "8C9D0E1F-A2B3-4C5D-6E7F-8A9B0C1D2E3F",
    text   = L.m_trd_menu_title,
    action = function()
        -- Query active viewport parameters safely via canonical nil-handle API
        local p_info = panel.GetPanelInfo(nil, 1)

        -- Run hierarchical context walking chain to check if inside a TRD VFS session
        local active_module_guid = nil
        if p_info and p_info.PluginObject and p_info.PluginObject.module and p_info.PluginObject.module.Info then
            active_module_guid = p_info.PluginObject.module.Info.Guid
        end
        -- Boolean condition tracking whether the currently focused pane is our native TRD VFS panel
        local is_trd_active_panel = (active_module_guid == win.Uuid("B4C1D2A3-E5F6-4A7B-8C9D-0E1F2A3B4C5D"))

        local menu_properties = {
            X     = -1,
            Y     = -1,
            Flags = F.FMENU_AUTOHIGHLIGHT,
            Title = L.m_plugin_menu_title,
            Id    = "F8E7D6C5-B4A3-2B1C-0D1E-2F3A4B5C6D7E"
        }

        -- [[ INTELLECTUAL DYNAMIC SUBMENU INTERFACE BLOCK ]]
        -- Replaced flat visibility constraints with explicit conditional disable/grayed properties!
        local menu_items = {
            {
                text    = L.m_menu_trd_move,
                -- Disable compaction operation unless user is currently inside an opened TRD container view
                disable = not is_trd_active_panel,
                grayed  = not is_trd_active_panel
            },
            {
                text    = L.m_menu_trd_create,
            }
        }

        local chosen_item, chosen_pos = far.Menu(menu_properties, menu_items)
        if not chosen_pos then return nil end

        -- [[ ROUTING INTERNAL SELECTIONS ACTION EXECUTION ]]
        if chosen_pos == 1 and is_trd_active_panel then
            -- Double check protection to bypass macro injections bounds drops
            execute_trdos_move_compaction(p_info.PluginObject.object, nil)

        elseif chosen_pos == 2 then
            -- [[ ACTION 2: TRD FILE GENERATOR FALLBACK PLACEHOLDER ]]
            far.Message(L.trd_msg_not_implemented, L.m_menu_trd_create, L.m_btn_ok, "i")
        end

        return nil
    end}

-- [[ DECLARATIVE LUA_FAR CONFIGURATION REGISTRY LINK ]]
MenuItem {
    -- [[ CRITICAL FIX: PLACE STRICKLY INSIDE OPTIONS -> PLUGINS CONFIGURATION MENU ]]
    menu   = "Config",
    area   = "Shell",
    -- Persistent unique RFC 4122 Version 4 UUID tracking registered specifically for our TRD VFS component
    guid   = "B4C1D2A3-E5F6-4A7B-8C9D-0E1F2A3B4C5D",
    text   = L.m_trd_menu_title, -- "TRD Image Options" / "Настройки TRD образов"
    action = function()
        -- Load the most up-to-date states entries context maps straight from database
        -- We assume plugin_settings for TRD context is required or instantiated locally at the top
        plugin_settings.load_settings()

        -- Fetch the active boolean parameter state layer
        local current_use_dirsys = plugin_settings.get("use_dirsys", true)

        -- Trigger the standalone modular graphical window interface from our decoupled manager layer
        local updated_state = dialog_manager.show_trd_settings_dialog(current_use_dirsys)

        if updated_state ~= nil then
            -- Commit modifications live using our transactional pairs-based dynamic write helper
            plugin_settings.set("use_dirsys", updated_state)
        end

        return nil
    end
}


PanelModule(M)
