local manager = {}
local F = far.Flags
local L = require("theX.ui.localization")

-- [[ DIALOG INDEX MAPPINGS CONSTRAINTS ]]
local ID_DEST_EDIT = 3
local ID_RAD_SCL   = 7
local ID_CHK_SKIP  = 9

local ID_NAME  = 3
local ID_PEXT  = 5
local ID_TYPE  = 7
local ID_START = 9

local is_updating = false
local current_meta_ref = nil

--- Private handler executing strict field linking constraints on changes with infinite loop protection.
---@param h_dlg userdata Low-level Far Manager dialog frame context pointer
---@param msg integer Triggered dialog event message ID (F.DN_*)
---@param param1 integer Targeted item index ID layout matching dialog arrays
---@param param2 any Low-level event context tracking parameter (contains string on DN_EDITCHANGE)
---@return any status Returns specific message actions or nil
local function rename_dialog_handler(h_dlg, msg, param1, param2)
    if msg == F.DN_EDITCHANGE then
        if is_updating then return nil end

        if param1 == ID_PEXT then
            local text = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_PEXT, nil) or ""
            local clean_ext = string.match(text, "^%s*(.-)%s*$") or text

            if string.len(clean_ext) == 3 then
                local t_char = string.sub(clean_ext, 1, 1)
                local b2 = string.byte(clean_ext, 2)
                local b3 = string.byte(clean_ext, 3)
                local start_val = (b2 * 256) + b3

                is_updating = true
                far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_TYPE, t_char)
                far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_START, tostring(start_val))
                is_updating = false
            elseif string.len(clean_ext) == 1 then
                is_updating = true
                far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_TYPE, clean_ext)
                is_updating = false
            end

        elseif param1 == ID_TYPE or param1 == ID_START then
            local ty_str = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_TYPE, nil) or "C"
            local st_str = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_START, nil) or "0"
            local current_type = string.sub(string.match(ty_str, "^%s*(.-)%s*$") or "C", 1, 1)
            local current_start = tonumber(st_str) or 0

            if current_type == "C" and current_start > 0 then
                local b2 = math.floor(current_start / 256) % 256
                local b3 = current_start % 256

                if b2 >= 32 and b2 <= 126 and b3 >= 32 and b3 <= 126 then
                    local calculated_ext = "C" .. string.char(b2, b3)
                    is_updating = true
                    far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_PEXT, calculated_ext)
                    is_updating = false
                else
                    is_updating = true
                    far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_PEXT, current_type)
                    is_updating = false
                end
            else
                is_updating = true
                far.SendDlgMessage(h_dlg, F.DM_SETTEXT, ID_PEXT, current_type)
                is_updating = false
            end
        end
    end

    if msg == F.DN_CLOSE and param1 > 0 then
        if current_meta_ref then
            local new_name  = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_NAME, nil) or ""
            local new_type  = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_TYPE, nil) or "C"
            local new_start_str = far.SendDlgMessage(h_dlg, F.DM_GETTEXT, ID_START, nil) or "0"
            local new_start = tonumber(new_start_str) or 0

            new_name = string.match(new_name, "^%s*(.-)%s*$") or new_name
            new_name = string.sub(new_name, 1, 8)
            if string.len(new_name) < 8 then
                new_name = new_name .. string.rep(" ", 8 - string.len(new_name))
            end

            new_type = string.sub(string.match(new_type, "^%s*(.-)%s*$") or new_type, 1, 1) or "C"

            current_meta_ref.name = new_name
            current_meta_ref.type = new_type
            current_meta_ref.start = new_start
            current_meta_ref.new_type = nil
            current_meta_ref.special_char = nil
        end
        return 1
    end

    return nil
end

--- Compiles and displays the stateful VFS export routing interface configuration frame.
---@param default_dest string Initial target directory layout on the host OS file tree
---@param is_move boolean Action flag constraint: true indicates Move (F6), false indicates Copy (F5)
---@return string|nil final_dest_path Destination target string path path, or nil if cancelled
---@return boolean? export_as_scl Output bit flag state indicating target image repackaging mode
---@return boolean? skip_headers Output bit flag state enforcing unheadered RAW exports splits
function manager.show_export_dialog(default_dest, is_move)
    local title_text = is_move and L.dlg_export_title_move or L.dlg_export_title_copy
    local label_text = is_move and L.dlg_export_label_move or L.dlg_export_label_copy
    local button_text = is_move and L.m_btn_move or L.m_btn_copy

    local dialog_items = {
        { F.DI_DOUBLEBOX,   3,  1, 68, 11, 0, "", "", 0, title_text },
        { F.DI_TEXT,        5,  2,  0,  2, 0, "", "", 0, label_text },
        { F.DI_EDIT,        5,  3, 66,  3, 0, "xscl_dest_history", "", F.DIF_HISTORY + F.DIF_FOCUS, default_dest },
        { F.DI_TEXT,        5,  4,  0,  4, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_TEXT,        5,  5,  0,  5, 0, "", "", 0, L.dlg_export_format_lbl },
        { F.DI_RADIOBUTTON, 5,  6,  0,  6, 1, "", "", F.DIF_GROUP, "&HoBeta" },
        { F.DI_RADIOBUTTON, 5,  7,  0,  7, 0, "", "", 0, "&SCL" },
        { F.DI_TEXT,        5,  8,  0,  8, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_CHECKBOX,    5,  9,  0,  9, 0, "", "", 0, L.dlg_export_chk_skip },
        { F.DI_BUTTON,      0, 10,  0, 10, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, button_text },
        { F.DI_BUTTON,      0, 10,  0, 10, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
    }

    local dialog_id = win.Uuid("8B9C0D1E-F2A3-4B5C-6D7E-8F9A0B1C2D3E")
    local dlg_result = far.Dialog(dialog_id, -1, -1, 72, 13, nil, dialog_items)

    if dlg_result == -1 or dlg_result == 11 then return nil end

    local final_dest_path = dialog_items[ID_DEST_EDIT][10] or default_dest
    local export_as_scl   = (dialog_items[ID_RAD_SCL] == 1 or dialog_items[ID_RAD_SCL] == true)
    local skip_headers    = (dialog_items[ID_CHK_SKIP] == 1 or dialog_items[ID_CHK_SKIP] == true)
    final_dest_path = string.match(final_dest_path, '^%s*"?([^"]+)"?%s*$') or final_dest_path

    return final_dest_path, export_as_scl, skip_headers
end

--- Displays the interactive SCL image creator layout frame (F11 Menu).
---@return string|nil target_filename Returns input name or nil if cancelled
function manager.show_create_scl_dialog()
    local dialog_items = {
        { F.DI_DOUBLEBOX,   3,  1, 60,  6, 0, "", "", 0, L.dlg_create_scl_title },
        { F.DI_TEXT,        5,  2,  0,  2, 0, "", "", 0, L.dlg_enter_scl_name },
        { F.DI_EDIT,        5,  3, 58,  3, 0, "", "", F.DIF_FOCUS, "new_disk.scl" },
        { F.DI_TEXT,        5,  4,  0,  4, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, L.m_btn_create },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
    }

    local dialog_id = win.Uuid("7A8B9C0D-E1F2-3A4B-5C6D-7E8F9A0B1C2D")
    local dlg_result = far.Dialog(dialog_id, -1, -1, 64, 8, nil, dialog_items)

    if dlg_result == -1 or dlg_result == 6 then return nil end
    return dialog_items[3][10]
end

--- Displays the standalone 4-field TR-DOS file attributes editor (Shift+F6).
---@param m table Target file metadata reference block dict
---@return boolean success Returns true if attributes were changed, false on abort
function manager.show_attribute_dialog(m)
    current_meta_ref = m

    local current_name = m.name or ""
    local current_pext = m.ext or m.type or "C"
    local current_type = m.type or "C"
    local current_start = tostring(m.start or 0)

    local dialog_items = {
        { F.DI_DOUBLEBOX,   3,  1, 56, 11, 0, "", "", 0, L.dlg_rename_title },
        { F.DI_TEXT,        5,  2,  0,  2, 0, "", "", 0, L.dlg_lbl_filename },
        { F.DI_EDIT,        5,  3, 22,  3, 0, "", "", F.DIF_FOCUS, current_name },
        { F.DI_TEXT,       30,  2,  0,  2, 0, "", "", 0, L.dlg_lbl_pc_ext },
        { F.DI_EDIT,       30,  3, 54,  3, 0, "", "", 0, current_pext },
        { F.DI_TEXT,       30,  5,  0,  5, 0, "", "", 0, L.dlg_lbl_trdos_type },
        { F.DI_EDIT,       30,  6, 54,  6, 0, "", "", 0, current_type },
        { F.DI_TEXT,        5,  5,  0,  5, 0, "", "", 0, L.dlg_lbl_trdos_start },
        { F.DI_EDIT,        5,  6, 22,  6, 0, "", "", 0, current_start },
        { F.DI_TEXT,        5,  8,  0,  8, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_BUTTON,      0, 10,  0, 10, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, L.m_btn_save },
        { F.DI_BUTTON,      0, 10,  0, 10, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
    }

    local dialog_id = win.Uuid("9C8B7A6D-E5F4-3A2B-1C0D-E1F23A4B5C6D")

    local dialog_result = far.Dialog(dialog_id, -1, -1, 60, 13, nil, dialog_items, 0, rename_dialog_handler)
    if dialog_result == 11 then
        local scl_should_be_updated = false
        if m.name ~= current_name or m.type ~= current_type or m.start ~= current_start then
            scl_should_be_updated = true
        end
        if scl_should_be_updated then
            return true
        end
    end
    return false
end

--- Displays the interactive TRD plugin configuration frame layout.
---@param current_dirsys_state boolean The current dynamic status of Use DirSys flag loaded from macro registry
---@return boolean|nil new_dirsys_state Returns updated boolean state flag, or nil if cancelled
function manager.show_trd_settings_dialog(current_dirsys_state)
    -- Map boolean truth parameters straight into native low-level Far check states indices (1 or 0)
    local check_state = current_dirsys_state and 1 or 0

    local dialog_items = {
        { F.DI_DOUBLEBOX,   3,  1, 60,  6, 0, "", "", 0, L.dlg_trd_settings_title },
        { F.DI_CHECKBOX,    5,  2,  0,  2, check_state, "", "", F.DIF_FOCUS, L.dlg_trd_use_dirsys },
        { F.DI_TEXT,        5,  4,  0,  4, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, L.m_btn_save },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
    }

    local dialog_id = win.Uuid("A3B4C5D6-E7F8-4A9B-0C1D-E2F3A4B5C6D7")
    local dlg_result = far.Dialog(dialog_id, -1, -1, 64, 8, nil, dialog_items, 0)

    -- If user aborted via Escape or clicked Cancel button (index 5), drop updates cascade
    if dlg_result == -1 or dlg_result == 5 then
        return nil
    end

    -- Return the checked state strictly converted back to authentic Lua boolean format type
    return dialog_items[2][6] == 1 or dialog_items[2][6] == true
end

--- Displays the interactive folder input string creation frame dialog (F7).
---@return string|nil target_foldername Returns text path string or nil if cancelled
function manager.show_create_folder_dialog()
    local dialog_items = {
        { F.DI_DOUBLEBOX,   3,  1, 60,  6, 0, "", "", 0, L.dlg_create_folder_title },
        { F.DI_TEXT,        5,  2,  0,  2, 0, "", "", 0, L.dlg_create_folder_lbl },
        { F.DI_EDIT,        5,  3, 58,  3, 0, "xtrd_folder_history", "", F.DIF_HISTORY + F.DIF_FOCUS, "" },
        { F.DI_TEXT,        5,  4,  0,  4, 0, "", "", F.DIF_SEPARATOR, "" },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, L.m_btn_ok },
        { F.DI_BUTTON,      0,  5,  0,  5, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
    }

    local dialog_id = win.Uuid("F7A8B9C0-D1E2-3F4A-5B6C-7D8E9F0A1B2C")
    local dlg_result = far.Dialog(dialog_id, -1, -1, 64, 8, nil, dialog_items)

    if dlg_result == -1 or dlg_result == 6 then return nil end
    return dialog_items[3][10]
end


return manager
