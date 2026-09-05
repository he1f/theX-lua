local M = {}
local F = far.Flags

local DIALOG_GUID = win.Uuid("3D76A85F-7DB6-4EAB-B6D8-F9A5E42D786C")

local function resolve_dialog_index_base(items, result)
  if type(result) ~= "number" then
    return 1
  end
  local item_direct = items[result]
  if type(item_direct) == "table" and item_direct[1] == "DI_BUTTON" then
    return 1
  end
  local item_shifted = items[result + 1]
  if type(item_shifted) == "table" and item_shifted[1] == "DI_BUTTON" then
    return 0
  end
  return 1
end

local function item_from_result(items, result, index_base)
  if type(result) ~= "number" then
    return nil
  end
  local lua_index = index_base == 0 and (result + 1) or result
  return items[lua_index]
end

local function get_dialog_text(hdlg, item_index)
  local ok_get, value = pcall(far.SendDlgMessage, hdlg, "DM_GETTEXT", item_index, 0)
  if not ok_get then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value[1]) == "string" then
      return value[1]
    end
    if type(value.Text) == "string" then
      return value.Text
    end
  end
  if value == nil then
    return ""
  end
  return tostring(value)
end

function M.ask_file_info(params)
  local input = type(params) == "table" and params or {}
  local title = type(input.title) == "string" and input.title or "Edit file info"
  local file_name_label = type(input.file_name_label) == "string" and input.file_name_label or "File name"
  local file_type_label = type(input.file_type_label) == "string" and input.file_type_label or "File type"
  local start_address_label = type(input.start_address_label) == "string" and input.start_address_label or "Start address"
  local ok_button = type(input.ok_button) == "string" and input.ok_button or "OK"
  local cancel_button = type(input.cancel_button) == "string" and input.cancel_button or "Cancel"

  local initial_file_name = tostring(input.initial_file_name or "")
  local initial_file_type = tostring(input.initial_file_type or "")
  local initial_start_address = tostring(input.initial_start_address or "")

  local items = {
    { F.DI_DOUBLEBOX, 3, 1, 46, 7, 0, "", "", 0, title },
    { F.DI_TEXT, 5, 2, 19, 2, 0, "", "", 0, file_name_label },
    { F.DI_EDIT, 21, 2, 44, 2, 0, "", "", 0, initial_file_name },
    { F.DI_TEXT, 5, 3, 19, 3, 0, "", "", 0, file_type_label },
    { F.DI_EDIT, 21, 3, 44, 3, 0, "", "", 0, initial_file_type },
    { F.DI_TEXT, 5, 4, 19, 4, 0, "", "", 0, start_address_label },
    { F.DI_EDIT, 21, 4, 44, 4, 0, "", "", 0, initial_start_address },
    { F.DI_TEXT, 5, 5, 0, 5, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_BUTTON, 0, 6, 0, 6, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, ok_button },
    { F.DI_BUTTON, 0, 6, 0, 6, 0, "", "", F.DIF_CENTERGROUP, cancel_button },
  }

  local hdlg = far.DialogInit(DIALOG_GUID, -1, -1, 50, 9, nil, items, 0, nil)
  if not hdlg then
    local error_msg = "DialogInit failed"
    return nil, error_msg
  end

  local ok_run, result = pcall(far.DialogRun, hdlg)
  if not ok_run then
    far.DialogFree(hdlg)
    local error_msg = tostring(result)
    return nil, error_msg
  end
  if result == -1 then
    far.DialogFree(hdlg)
    return false
  end

  local index_base = resolve_dialog_index_base(items, result)
  local ok_button_index = index_base == 0 and 8 or 9
  local cancel_button_index = index_base == 0 and 9 or 10
  if result ~= ok_button_index then
    local clicked_item = item_from_result(items, result, index_base)
    if result == cancel_button_index
      or (type(clicked_item) == "table" and clicked_item[1] == "DI_BUTTON" and clicked_item[10] == cancel_button)
    then
      far.DialogFree(hdlg)
      return false
    end
  end

  local file_name_index = index_base == 0 and 2 or 3
  local file_type_index = index_base == 0 and 4 or 5
  local start_address_index = index_base == 0 and 6 or 7
  local payload = {
    file_name = get_dialog_text(hdlg, file_name_index),
    file_type = get_dialog_text(hdlg, file_type_index),
    start_address = get_dialog_text(hdlg, start_address_index),
  }
  far.DialogFree(hdlg)

  return payload
end

return M
