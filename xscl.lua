local macro_file = ...
if type(macro_file) ~= "string" then
  return
end
local script_dir = macro_file:match("^(.*[\\/])") or ""
package.path = script_dir .. "?\\init.lua;" .. script_dir .. "?.lua;" .. package.path


local F = far.Flags
local ffi = require("ffi")

local L = require("theX.ui.localization")

local scl_reader = require("theX.formats.scl.reader")
local scl_writer = require("theX.formats.scl.writer")
local hobeta_reader = require("theX.formats.hobeta.reader")
local loader = require("theX.formats.loader")

local io_manager = require("theX.io_manager")
local manager = require("theX.dialog.manager")

local detector = require("theX.detector")
local vfs_core = require("theX.trdos_vfs_core")
local gui = require("theX.utils.gui_operations")

local settings_manager = require("theX.settings_manager")
local plugin_settings = settings_manager.new("xscl")


-- Справочник UUID и констант
local plugin_guid = win.Uuid("6A7B8C9D-E1F2-3A4B-5C6D-7E8F9A0B1C2D")
local SECTOR_SIZE = 256

-- Публичный неймспейс плагина (сюда пишем ТОЛЬКО экспортируемые методы)
local M = {}

M.Info = {
  Guid = plugin_guid,
  Version = "0.1.0",
  Title = "xSCL",
  Description = "SCL eXplorer",
  Author = "Dima Kozlov",
}

-- Безопасное получение директории панели (с обработкой плагинового хост-файла)
local function get_panel_dir(panel_type_flag)
    local p_info = panel.GetPanelInfo(nil, panel_type_flag)
    if not p_info then return "" end

    -- Если это плагиновая панель, берем путь её хост-файла и отрезаем имя
    if (p_info.Flags & F.PFLAGS_PLUGIN) ~= 0 then
        local host_file = panel.GetPanelHostFile(nil, panel_type_flag)
        if host_file and host_file ~= "" then
            -- Отрезаем имя файла через string.match, оставляя только путь каталога
            local dir = string.match(host_file, "^(.*)[\\/][^\\/]+$")
            return dir or ""
        end
    else
        -- Если это обычная панель, запрашиваем её директорию штатно
        local dir_obj = panel.GetPanelDirectory(nil, panel_type_flag)
        if dir_obj and dir_obj.Name then
            return dir_obj.Name
        end
    end
    return ""
end

local function scan_directory_flat(dir_path, result_list)
    local win_items = win.GetFileInfo(dir_path .. "\\*")
    if not win_items then return end

    for _, item in ipairs(win_items) do
        if item.FileName ~= "." and item.FileName ~= ".." then
            local full_item_path = dir_path .. "\\" .. item.FileName
            if string.find(item.FileAttributes, "d") then
                scan_directory_flat(full_item_path, result_list)
            else
                table.insert(result_list, full_item_path)
            end
        end
    end
end

local function find_hobeta_by_display_name(files_list, display_name)
    for _, hobeta_file in ipairs(files_list) do
        -- Строгое сравнение с учетом регистра символов
        if hobeta_file.meta.display_name == display_name then
            return hobeta_file
        end
    end
    return nil
end

-- Вспомогательная функция физического сохранения файлов наружу
-- Возвращает: успех (true/false), карту_успешно_записанных_файлов (table)
local function execute_export_logic(object, items_to_move, is_move, final_dest_path, export_as_scl, skip_headers)
    local files_to_export = {}
    local processed_map = {} -- Карта для отслеживания: [display_name] = true (если записан)

    for i = 1, #items_to_move do
        local item = items_to_move[i]
        if item and item.FileName then
            local hobeta_file = find_hobeta_by_display_name(object.files_list, item.FileName)
            if hobeta_file then
                table.insert(files_to_export, hobeta_file)
            end
        end
    end

    if #files_to_export == 0 then return false, processed_map end

    if export_as_scl then
        local first_file_meta = files_to_export[1].meta
        local first_file_name = first_file_meta.name

        first_file_name = string.lower(string.match(first_file_name, "^%s*(.-)%s*$") or first_file_name)
        if first_file_name == "" then first_file_name = "exported_archive" end

        local extension = skip_headers and ".raw" or ".scl"
        local output_scl_name = win.JoinPath(final_dest_path, first_file_name .. extension)

        local prepared_scl_list = {}
        for _, hobeta_file in ipairs(files_to_export) do
            if skip_headers then
                local clean_data = string.sub(hobeta_file.data, 1, hobeta_file.meta.size)
                local new_sectors = math.ceil(hobeta_file.meta.size / SECTOR_SIZE)
                local aligned_size = new_sectors * SECTOR_SIZE

                if string.len(clean_data) < aligned_size then
                    clean_data = clean_data .. string.rep(string.char(0), aligned_size - string.len(clean_data))
                end

                local raw_desc = string.sub(hobeta_file.header, 1, 13) .. string.char(new_sectors)
                local raw_15_bytes = raw_desc .. string.char(0)
                local crc_bytes = hobeta_reader.calculate_crc(raw_15_bytes)
                local new_header = raw_15_bytes .. crc_bytes .. string.char(new_sectors)

                table.insert(prepared_scl_list, { header = new_header, data = clean_data, meta = hobeta_file.meta })
            else
                table.insert(prepared_scl_list, hobeta_file)
            end
        end

        local conflict_state = { abort = false }
        local fake_data = string.rep(" ", 1024) -- Буфер-пустышка для оценки конфликта размеров в диалоге

        local allowed, _, was_skipped = io_manager.safe_write_file(output_scl_name, fake_data, conflict_state, true)

        if allowed then
            -- Если диалог подтвержден, райтером пишем настоящую структуру поверх
            scl_writer.save(output_scl_name, prepared_scl_list, object)
            -- Маркируем ВСЕ файлы этой группы как успешно обработанные
            for _, hobeta_file in ipairs(files_to_export) do
                processed_map[hobeta_file.meta.display_name] = true
            end
        else
            if was_skipped then
                -- Если SCL был пропущен, файлы остаются выделенными (processed_map пустая)
                return true, processed_map
            end
            return false, processed_map -- Отмена операции
        end
    else
        local conflict_state = { overwrite_all = false, skip_all = false, abort = false }

        for _, hobeta_file in ipairs(files_to_export) do
            if conflict_state.abort then break end

            local current_filename = hobeta_file.meta.display_name
            if skip_headers then
                current_filename = hobeta_file.meta.name .. "." .. hobeta_file.meta.type
            end

            local full_output_path = win.JoinPath(final_dest_path, current_filename)

            local data_to_write = ""
            if skip_headers then
                data_to_write = string.sub(hobeta_file.data, 1, hobeta_file.meta.size)
            else
                data_to_write = hobeta_file.header .. hobeta_file.data
            end

            -- Вызываем safe_write_file (is_scl = false)
            local write_ok, updated_state, was_skipped = io_manager.safe_write_file(full_output_path, data_to_write, conflict_state, false)
            conflict_state = updated_state

            if write_ok then
                -- ПРАВИЛО 1: Файл успешно записан, заносим его в карту для снятия выделения
                processed_map[hobeta_file.meta.display_name] = true
            else
                if was_skipped then
                    -- Файл пропущен по кнопке "Пропустить/Пропустить Все".
                    -- Мы НЕ добавляем его в processed_map, поэтому он ОСТАНЕТСЯ выделенным!
                elseif not conflict_state.abort then
                    far.Message(L.m_err_write_failed, L.m_err_title, L.m_btn_cancel, "w")
                end
            end
        end

        if conflict_state.abort then
            return false, processed_map
        end
    end

    -- Логика перемещения (F6) удаляет только реально скопированные файлы
    if is_move then
        local kept_files = {}
        for _, hobeta_file in ipairs(object.files_list) do
            if not processed_map[hobeta_file.meta.display_name] then
                table.insert(kept_files, hobeta_file)
            end
        end
        object.files_list = kept_files
        scl_writer.save(object.archive_path, object.files_list, object)
    end

    return true, processed_map
end


function M.GetFiles(object, handle, items_to_move, is_move, dest_path, op_flags)
    local is_view = (op_flags & F.OPM_VIEW) ~= 0
    local is_edit = (op_flags & F.OPM_EDIT) ~= 0

    local is_internal_op = is_view or is_edit

    if is_internal_op then
        -- Берём текущий выделенный файл/элемент под курсором для вывода в UI
        local current_item = items_to_move[1]

        if current_item then
            local ui_success = gui.process_view_edit(object, current_item, dest_path, is_view, is_edit)
            return ui_success and 1 or 0
        end
        return 0
    end

    local panel_info = panel.GetPanelInfo(handle, F.PANEL_ACTIVE)
    if not panel_info or panel_info.SelectedItemsNumber == 0 then return 0 end

    -- Собираем выделенные элементы в чистую Lua-таблицу из items_to_move
    -- [[ STEP 2: REORDERED PHYSICAL FILES EXPORT MULTI-SELECTION LOGIC ]]
    gui.sync_selection_order(object, handle)
    local selected_items_table = {}
    local item_map = {}

    -- Hash all items requested by Far Manager for quick cross-referencing lookups
    for i = 1, #items_to_move do
        local item = items_to_move[i]
        if item and item.FileName then
            item_map[item.FileName] = item
        end
    end

    -- 1. First, insert items strictly matching the user's manual selection order history
    if object.selection_order then
        for _, ordered_name in ipairs(object.selection_order) do
            if item_map[ordered_name] then
                table.insert(selected_items_table, item_map[ordered_name])
                item_map[ordered_name] = nil -- Clear to prevent duplicate packing
            end
        end
    end

    -- 2. Fallback: append any remaining highlighted items (e.g., if selected via wildcards or mouse)
    for _, item in pairs(item_map) do
        table.insert(selected_items_table, item)
    end

    -- Определяем путь назначения (пассивная панель)
    local default_dest = dest_path or ""
    if default_dest == "" then default_dest = get_panel_dir(F.PANEL_PASSIVE) end

    local passive_info = panel.GetPanelInfo(nil, F.PANEL_PASSIVE)

    local final_dest_path, export_as_scl, skip_headers

    -- ПРОВЕРКА: Если пассивная панель — это ПЛАГИН, копируем БЕЗ диалогов
    if passive_info and (passive_info.Flags & F.PFLAGS_PLUGIN) ~= 0 then
        final_dest_path = default_dest
        export_as_scl = false
        skip_headers = false
    else
        -- Если пассивная панель обычная — показываем наш вынесенный диалог
        final_dest_path, export_as_scl, skip_headers = manager.show_export_dialog(default_dest, is_move)
        if not final_dest_path then
            return 0 -- Нажали отмену
        end
    end

    -- Запускаем физический экспорт
    local success, processed_map = execute_export_logic(object, selected_items_table, is_move, final_dest_path, export_as_scl, skip_headers)

    if success then
        local total_selected = panel_info.SelectedItemsNumber
        local successfully_written = 0
        for _, _ in pairs(processed_map) do
            successfully_written = successfully_written + 1
        end

        -- Транзакционный обход для точечного снятия выделения
        panel.BeginSelection(handle, F.PANEL_ACTIVE)
        for i = 1, panel_info.ItemsNumber do
            local item = panel.GetPanelItem(handle, F.PANEL_ACTIVE, i)
            if item and item.Flags then
                local is_selected = (ffi.cast("uint64_t", item.Flags) & F.PPIF_SELECTED) ~= 0
                if is_selected and processed_map[item.FileName] then
                    panel.SetSelection(handle, F.PANEL_ACTIVE, i, false)
                end
            end
        end
        panel.EndSelection(handle, F.PANEL_ACTIVE)

        panel.RedrawPanel(handle, F.PANEL_ACTIVE)
        panel.RedrawPanel(nil, F.PANEL_PASSIVE)

        if successfully_written < total_selected then
            return 0
        end
        return 1
    end

    return 0
end


function M.Open(open_from, guid, item)
    local archive_path = nil

    if open_from == F.OPEN_COMMANDLINE then
        archive_path = item
    elseif open_from == F.OPEN_ANALYSE then
        archive_path = item.FileName
    else
        archive_path = item
    end
    if type(archive_path) ~= "string" or archive_path == "" then
        return nil
    end

    archive_path = string.match(archive_path, '^%s*"?([^"]+)"?%s*$') or archive_path

    if not string.find(archive_path, "^%a:") and not string.find(archive_path, "^\\\\") then
        local panel_folder = panel.GetPanelDirectory(nil, F.PANEL_ACTIVE).Name
        archive_path = win.JoinPath(panel_folder, archive_path)
    end

    local is_ok, err_code = scl_reader.is_valid(archive_path)

    if not is_ok then
        local lang_key = string.lower(err_code or "")
        local err_message_text = L[lang_key]

        -- Dialog container dynamically adapts text arrays tokens live
        far.Message(err_message_text, L.m_err_title, L.m_btn_cancel, "w")
        return nil
    end

    local panel_instance = {
        archive_path = archive_path,
        files_list = {}
    }

    scl_reader.process(panel_instance.files_list, archive_path, {})
    return panel_instance
end

---@param object table The plugin instance table
---@param handle userdata The low-level Far Manager panel handle
---@param key_flags integer System panel flags passed by Far
---@return table|nil far_items A sequential array of plugin panel file items
function M.GetFindData(object, handle, key_flags)
    if (key_flags & F.OPM_FIND) == 0 then
        for i = #object.files_list, 1, -1 do
            object.files_list[i] = nil
        end
        scl_reader.process(object.files_list, object.archive_path, object)
        vfs_core.refresh_panel_metadata(object.files_list, nil, detector)
    end

    ---@type integer Current physical character width of column C0
    local c0_width = 0 -- Ставим 0 как маркер того, что ширина еще не определена

    ---@type string|nil Comma-separated types layout string from LuaFAR
    local col_types_str = panel.GetColumnTypes(handle, F.PANEL_ACTIVE)
    ---@type string|nil Comma-separated widths layout string from LuaFAR
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
    for _, hobeta_file in ipairs(object.files_list) do
        local m = hobeta_file.meta

        -- Форматируем расширение/тип строго по правилу 3-х печатных символов
        local type_str = ""
        local ext_str = m.ext or m.type or "C"
        if string.len(ext_str) == 3 then
            type_str = ext_str
        else
            type_str = "<" .. ext_str .. ">"
        end

        local combined_name_and_type = ""
        local raw_name = m.name or ""

        if c0_width > 0 then
            local name_len = string.len(raw_name)
            local type_len = string.len(type_str)
            local spaces_count = c0_width - name_len - type_len
            if spaces_count < 1 then spaces_count = 1 end
            combined_name_and_type = raw_name .. string.rep(" ", spaces_count) .. type_str
        else
            -- Если c0_width == 0 (идет поиск OPM_FIND или фоновый кэш), выводим дефолт через 1 пробел
            combined_name_and_type = raw_name .. " " .. type_str
        end

        local desc_str = m.description or ""
        local meta_str = m.comment or ""
        if m.author and m.author ~= "" then
            if meta_str ~= "" then meta_str = meta_str .. " by " .. m.author
            else meta_str = "by " .. m.author end
        end

        table.insert(far_items, {
            FileName = m.display_name,
            FileSize = 17 + (m.sectors * SECTOR_SIZE),
            AllocationSize = m.sectors * SECTOR_SIZE,
            FileAttributes = F.FILE_ATTRIBUTE_ARCHIVE,

            CustomColumnData = {
                combined_name_and_type, -- C0
                tostring(m.size or 0),  -- C1
                tostring(m.start or 0), -- C2
                tostring(m.sectors),    -- C3
                desc_str,               -- C4
                meta_str                -- C5
            }
        })
    end
    return far_items
end


function M.PutFiles(object, handle, items_to_move, is_move, src_path, op_flags)
    local flat_files_paths = {}

    for _, item in ipairs(items_to_move) do
        local full_path = src_path .. "\\" .. item.FileName
        local item_info = win.GetFileInfo(full_path)

        if item_info and string.find(item_info.FileAttributes, "d") then
            -- Используем штатный far.RecursiveSearch для плоского сбора путей
            far.RecursiveSearch(full_path, "*", function(search_item, full_search_path)
                if not string.find(search_item.FileAttributes, "d") then
                    table.insert(flat_files_paths, full_search_path)
                end
            end, "FRS_RECUR")
        else
            table.insert(flat_files_paths, full_path)
        end
    end

    -- Создаем временную копию текущего списка файлов для валидации лимитов
    local temp_files_list = {}
    for _, existing_file in ipairs(object.files_list) do
        table.insert(temp_files_list, existing_file)
    end

    -- Прогоняем импорт во временный список
    for _, file_path in ipairs(flat_files_paths) do
        local success, error_code = loader.load_file(temp_files_list, file_path, object)
        if not success then
            -- The dispatcher maintains absolute graphical control layout formatting rules live
            local lang_key = string.lower(error_code or "err_cannot_open_file")
            far.Message(L[lang_key], L.m_err_title, L.m_btn_cancel, "w")
            return 0
        end
    end

    if #temp_files_list > 255 then
        far.Message(L.scl_err_max_files_limit, L.trd_title_import_err, L.m_btn_ok, "w")
        return 0
    end

    -- Если проверка пройдена, обновляем боевой список и сохраняем на диск
    object.files_list = temp_files_list
    scl_writer.save(object.archive_path, object.files_list, object)
    return 1
end

function M.DeleteFiles(object, handle, items_to_delete, op_flags)
    local msg_buttons = L.m_btn_ok .. ";" .. L.m_btn_cancel
    local code = far.Message(L.trd_dlg_delete_confirm, L.trd_dlg_delete_title, msg_buttons, "w")
    if code ~= 1 then
        return false
    end

    -- 1. Сбор карты имен с панели Far Manager (например, delete_map["DEMO.$C"] = true)
    local delete_map = {}
    local count = #items_to_delete
    for i = 1, count do
        local item = items_to_delete[i]
        if item and item.FileName then
            delete_map[item.FileName] = true
        end
    end

    -- 2. Фильтрация списка файлов по их точному display_name
    local kept_files = {}
    for _, hobeta_file in ipairs(object.files_list) do
        -- Теперь сравниваются абсолютно идентичные строки, коллизия устранена!
        if not delete_map[hobeta_file.meta.display_name] then
            table.insert(kept_files, hobeta_file)
        end
    end

    object.files_list = kept_files
    vfs_core.refresh_panel_metadata(object.files_list, nil, detector)
    -- Пересчитываем суффиксы для оставшихся файлов на панели
    -- normalize_panel_filenames(object.files_list)

    -- Физически сохраняем архив на диск через наш глобальный scl_writer
    local save_ok, new_scl_path = scl_writer.save(object.archive_path, object.files_list, object)
    if save_ok and new_scl_path then
        object.archive_path = new_scl_path
    end

    return true
end

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
    ColumnTypes = "C0,C1,C2,C3",
    ColumnWidths = "0,5,5,3",
    ColumnTitles = {
        L.col_title_name,
        L.col_title_size,
        L.col_title_start,
        L.col_title_sectors_sz,
    },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  local m5 = {
    ColumnTypes = "C0,C4",
    ColumnWidths = "12,0",
    ColumnTitles = { L.col_title_name, L.col_title_description },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  local m6 = {
    ColumnTypes = "C0,C5",
    ColumnWidths = "12,0",
    ColumnTitles = { L.col_title_name, L.col_title_comments },
    StatusColumnTypes = "N,C1,C3",
    StatusColumnWidths = "0,5,3",
    Flags = 0,
  }

  -- Массив режимов для LuaFAR (m3 встает на 4-ю позицию, m4 - на 5-ю)
  local scl_panel_modes = {
    {}, {}, {}, m3, m4, m5, m6
  }

  local host_file = object.archive_path or ""
  local base_file_name = host_file:match("([^\\/]+)$") or host_file
  local panel_title = "SCL"
  if base_file_name ~= "" then
    panel_title = "SCL:" .. base_file_name
  end

  return {
    HostFile         = host_file,
    Format           = "TR-DOS SCL",
    PanelTitle       = panel_title,
    PanelModesArray  = scl_panel_modes,
    PanelModesNumber = #scl_panel_modes,

    StartPanelMode   = start_mode_char_code,

    StartSortMode    = plugin_settings.last_sort_mode,
    StartSortOrder   = plugin_settings.last_sort_order,
    Flags            = F.OPIF_ADDDOTS,
  }
end

function M.Analyse(data)
    return data.FileName:lower():match("%.scl$") ~= nil
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

--- Compiles and renders the stateful VFS attribute editor frame with standalone type field.
---@param object table The plugin instance table mapping panel state
---@param handle userdata The active panel pointer context
---@param m table Target file metadata reference block dict
---@return nil
local function show_rename_dialog(object, handle, m)
    local is_renamed = manager.show_attribute_dialog(m)
    if is_renamed then
        scl_writer.save(object.archive_path, object.files_list, object, true)
        vfs_core.refresh_panel_metadata(object.files_list, nil, detector)

        panel.RedrawPanel(handle, F.PANEL_ACTIVE)
        panel.UpdatePanel(handle, F.PANEL_ACTIVE, true)
    end
end



---@param object table The plugin instance table mapping panel state
---@param handle userdata The low-level Far Manager panel handle context pointer
---@param record table System structure carrying input event metrics
---@return boolean handled Always returns false to let Far complete its native updates natively
function M.ProcessPanelInput(object, handle, record)
    if record.EventType == F.KEY_EVENT and record.KeyDown then
        local v_key = record.VirtualKeyCode
        local ctrl_state = record.ControlKeyState

        -- [[ HOOK 1: INTERCEPT SINGLE ITEM INSERT SELECTION ]]
        if v_key == 0x2D then
            if not object.selection_order then
                object.selection_order = {}
            end
            local current_item = panel.GetCurrentPanelItem(handle, F.PANEL_ACTIVE)
            if current_item and current_item.FileName then
                local is_selected = (ffi.cast("uint64_t", current_item.Flags) & F.PPIF_SELECTED) ~= 0
                local existing_idx = nil
                for idx, name in ipairs(object.selection_order) do
                    if name == current_item.FileName then existing_idx = idx; break end
                end

                if is_selected then
                    if existing_idx then table.remove(object.selection_order, existing_idx) end
                else
                    if not existing_idx then table.insert(object.selection_order, current_item.FileName) end
                end
            end
        end

        -- [[ HOOK 2: INTERCEPT INTERACTIVE RENAME (Shift + F6) ]]
        -- F6 key code is 0x75. Verify that Shift state bitmask modifier is active
        local is_shift = (ctrl_state & F.SHIFT_PRESSED ~= 0)
        if v_key == 0x75 and is_shift then
            local current_item = panel.GetCurrentPanelItem(handle, F.PANEL_ACTIVE)
            if current_item and current_item.FileName then
                -- Locate the matched metadata dictionary inside cache using current filename string index
                local target_meta = nil
                for _, file in ipairs(object.files_list) do
                    if file.meta and file.meta.display_name == current_item.FileName then
                        target_meta = file.meta
                        break
                    end
                end

                if target_meta then
                    -- Trigger our linked interactive editor modal dialog
                    show_rename_dialog(object, handle, target_meta)
                    -- Return true to completely absorb the Shift+F6 event so Far doesn't spawn its native rename box
                    return true
                end
            end
        end
    end

    return false
end


CommandLine {
  description = "SCL eXplorer";
  prefixes = "scl";
  action = function(prefix,text)
    return M, M.Open(F.OPEN_COMMANDLINE, nil, text)
  end;
}

-- [[ DECLARATIVE LUA_FAR INTERFACE INTEGRATION LAYER ]]
MenuItem {
    menu   = "Plugins",
    area   = "Shell",
    guid   = "6A7B8C9D-A0E1-2B3C-4D5E-6F7A8B9C0D1E",
    text   = L.m_plugin_menu_title, -- "SCL eXplorer"
    action = function(OpenFrom, Item)
        -- Show an internal sub-menu inside Far Manager to choose the exact action cascade
        local menu_properties = {
            X     = -1,
            Y     = -1,
            Flags = F.FMENU_AUTOHIGHLIGHT,
            Title = L.m_plugin_menu_title,
            Id    = "1F2E3D4C-5B6A-7A8B-9C0D-E1F23A4B5C6D"
        }

        local menu_items = {
            { text = L.m_menu_open_scl },   -- Index 1: Open SCL archive...
            { text = L.m_menu_create_scl }  -- Index 2: Create SCL archive...
        }

        -- Execute the menu function strictly following the structured two-table layout constraint
        local chosen_item, chosen_pos = far.Menu(menu_properties, menu_items)
        if not chosen_pos then
            return nil
        end

        if chosen_pos == 1 then
            local target_path = nil

            local current_dir = panel.GetPanelDirectory(nil, F.PANEL_ACTIVE)
            local current_item = panel.GetCurrentPanelItem(nil, F.PANEL_ACTIVE)

            if current_dir and current_dir.Name and current_item and current_item.FileName then
                local filename = current_item.FileName

                local attr_str = current_item.FileAttributes or ""
                local is_dir = string.match(attr_str, "d") ~= nil

                if not is_dir and string.match(string.lower(filename), "%.scl$") then
                    target_path = win.JoinPath(current_dir.Name, filename)
                end
            end
            if not target_path then
                local open_dialog = {
                    { F.DI_DOUBLEBOX, 3, 1, 60, 6, 0, "", "", 0, L.m_open_dialog_title },
                    { F.DI_TEXT,      5, 2,  0, 2, 0, "", "", 0, L.m_open_dialog_lbl },
                    -- Pre-fill history descriptor log mapping lines
                    { F.DI_EDIT,      5, 3, 58, 3, 0, "xscl_open_history", "", F.DIF_HISTORY + F.DIF_FOCUS, "" },
                    { F.DI_TEXT,      5, 4,  0, 4, 0, "", "", F.DIF_SEPARATOR, "" },
                    { F.DI_BUTTON,    0, 5,  0, 5, 0, "", "", F.DIF_CENTERGROUP + F.DIF_DEFAULTBUTTON, L.m_btn_ok },
                    { F.DI_BUTTON,    0, 5,  0, 5, 0, "", "", F.DIF_CENTERGROUP, L.m_btn_cancel },
                }
                local dlg_id = win.Uuid("2A3B4C5D-6E7F-8A9B-0C1D-E2F3A4B5C6D7")
                local dlg_res = far.Dialog(dlg_id, -1, -1, 64, 8, nil, open_dialog)

                if dlg_res == 5 and open_dialog[3][10] ~= "" then
                    target_path = open_dialog[3][10]
                end
            end

            -- If a target path was successfully extracted either via cursor shortcut or dialog entries
            if target_path and target_path ~= "" then
                target_path = string.match(target_path, '^%s*"?([^"]+)"?%s*$') or target_path
                -- Invoke the core M.Open endpoint method to initialize the virtual panel workspace
                return M, M.Open(OpenFrom, nil, target_path)
            end
        elseif chosen_pos == 2 then
            -- [[ ACTION 2: CREATE EMPTY SCL ARCHIVE ]]
            local target_filename =   manager.show_create_scl_dialog()
            if target_filename and target_filename ~= "" then
                target_filename = string.match(target_filename, '^%s*"?([^"]+)"?%s*$') or target_filename
                if not string.match(string.lower(target_filename), "%.scl$") then
                    target_filename = target_filename .. ".scl"
                end

                local current_dir = panel.GetPanelDirectory(nil, F.PANEL_ACTIVE)
                if current_dir and current_dir.Name and current_dir.Name ~= "" then
                    local full_scl_path = win.JoinPath(current_dir.Name, target_filename)
                    if scl_writer.save(full_scl_path, {}, {}) then
                        panel.UpdatePanel(nil, F.PANEL_ACTIVE, true)
                        panel.RedrawPanel(nil, F.PANEL_ACTIVE)
                    else
                        far.Message(L.m_err_write_failed, L.m_err_title, L.m_btn_cancel, "w")
                    end
                end
            end
        end
        return nil
    end
}

-- Возвращаем модуль Far Manager напрямую
PanelModule(M)
