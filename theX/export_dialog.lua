local M = {}
local F = far.Flags

local DIALOG_GUID = win.Uuid("7C45AB9F-1F28-4C87-B2E6-1C2E0F2E9F16")

local function to_bool(value)
  return value ~= nil and value ~= false and value ~= 0
end

local function trim_spaces(value)
  local text = value
  if type(text) ~= "string" then
    text = tostring(text or "")
  end
  return text:match("^%s*(.-)%s*$")
end

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

function M.ask_export_options(params)
  local input = type(params) == "table" and params or {}
  local selected_count = tonumber(input.selected_count) or 0
  local default_hobeta = selected_count <= 1
  local default_scl = not default_hobeta
  local title = type(input.title) == "string" and input.title or "Copy"
  local copy_target_text = type(input.copy_target_text) == "string" and input.copy_target_text or "Copy to:"
  local format_hobeta_label = type(input.format_hobeta_label) == "string" and input.format_hobeta_label or "HoBeta"
  local format_scl_label = type(input.format_scl_label) == "string" and input.format_scl_label or "SCL"
  local skip_headers_label = type(input.skip_headers_label) == "string" and input.skip_headers_label or "Skip headers"
  local copy_button_label = type(input.copy_button_label) == "string" and input.copy_button_label or "Copy"
  local cancel_button_label = type(input.cancel_button_label) == "string" and input.cancel_button_label or "Cancel"
  local history_name = type(input.history_name) == "string" and input.history_name or "xSCLCopyPath"
  local initial_destination = trim_spaces(input.destination_path or "")

  local items = {
    { F.DI_DOUBLEBOX, 3, 1, 71, 11, 0, "", "", 0, title },
    { F.DI_TEXT, 5, 2, 69, 2, 0, "", "", 0, copy_target_text },
    { F.DI_EDIT, 5, 3, 69, 3, 0, history_name, "", F.DIF_HISTORY, initial_destination },
    { F.DI_TEXT, 5, 4, 0, 4, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_RADIOBUTTON, 5, 5, 0, 5, default_hobeta and 1 or 0, "", "", F.DIF_GROUP, format_hobeta_label },
    { F.DI_RADIOBUTTON, 5, 6, 0, 6, default_scl and 1 or 0, "", "", 0, format_scl_label },
    { F.DI_TEXT, 5, 7, 0, 7, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_CHECKBOX, 5, 8, 0, 8, 0, "", "", 0, skip_headers_label },
    { F.DI_TEXT, 5, 9, 0, 9, 0, "", "", F.DIF_SEPARATOR, "" },
    { F.DI_BUTTON, 0, 10, 0, 10, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, copy_button_label },
    { F.DI_BUTTON, 0, 10, 0, 10, 0, "", "", F.DIF_CENTERGROUP, cancel_button_label },
  }

  local hdlg = far.DialogInit(DIALOG_GUID, -1, -1, 75, 13, nil, items, 0, nil)
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
  local copy_button_index = index_base == 0 and 9 or 10
  local cancel_button_index = index_base == 0 and 10 or 11
  if result ~= copy_button_index then
    local clicked_item = item_from_result(items, result, index_base)
    if result == cancel_button_index
      or (type(clicked_item) == "table" and clicked_item[1] == "DI_BUTTON" and clicked_item[10] == cancel_button_label)
    then
      far.DialogFree(hdlg)
      return false
    end
  end

  local destination_index = index_base == 0 and 2 or 3
  local hobeta_radio_index = index_base == 0 and 4 or 5
  local skip_header_index = index_base == 0 and 7 or 8
  local out_dir = trim_spaces(get_dialog_text(hdlg, destination_index))
  local format_hobeta = to_bool(far.SendDlgMessage(hdlg, "DM_GETCHECK", hobeta_radio_index, 0))
  local skip_header = to_bool(far.SendDlgMessage(hdlg, "DM_GETCHECK", skip_header_index, 0))
  far.DialogFree(hdlg)

  return {
    format = format_hobeta and "hobeta" or "scl",
    skip_header = skip_header,
    out_dir = out_dir,
  }
end

return M
