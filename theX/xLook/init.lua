xlook_plugin = {}

local hobeta_reader = require("theX.formats.hobeta.reader")
local detector = require("theX.utils.detector")
local decode_pipeline = require("theX.xLook.decoder_pipeline")
local L = require("theX.ui.localization")

local F = far.Flags

local SCR_COLOR_SIZE = 6912
local SCR_BW_SIZE = 6144

--- True if buffer starts with DOS/Windows PE MZ signature.
---@param data string
---@return boolean
local function starts_with_mz(data)
    return type(data) == "string" and #data >= 2 and string.sub(data, 1, 2) == "MZ"
end

--- Build TR-DOS-like 8-char name from host path basename.
---@param file_path string
---@return string name_8
local function basename_as_trdos_name(file_path)
    local base = file_path:match("([^\\/]+)$") or "screen"
    base = base:match("^(.-)%.[^%.]+$") or base
    base = string.sub(base, 1, 8)
    if #base < 8 then
        base = base .. string.rep(" ", 8 - #base)
    end
    return base
end

--- Load raw .scr from disk when not HoBeta (6912 color / 6144 B/W). Rejects MZ/EXE.
---@param file_path string
---@return table|nil target_file { data, meta } or nil
local function try_load_raw_scr(file_path)
    local ext = file_path:match("%.([^%.\\/]+)$")
    if not ext or string.lower(ext) ~= "scr" then
        return nil
    end

    local file_handle = io.open(file_path, "rb")
    if not file_handle then
        return nil
    end
    local data = file_handle:read("*a") or ""
    file_handle:close()

    if starts_with_mz(data) then
        return nil
    end

    local len = #data
    if len ~= SCR_COLOR_SIZE and len ~= SCR_BW_SIZE then
        return nil
    end

    local is_bw = (len == SCR_BW_SIZE)
    return {
        data = data,
        meta = {
            name = basename_as_trdos_name(file_path),
            type = "C",
            start = 0x4000,
            size = len,
            sectors = math.floor((len + 255) / 256),
            ext = "scr",
            deleted = false,
            group = "gfx",
            new_type = "s",
            description = is_bw and "B/W screen" or "Color screen",
            special_char = "!",
        },
    }
end

--- Processes the physical HoBeta file asset pipeline, performs transformation and fires up the Far Editor screen.
---@param file_path string Absolute filesystem disk path targeting the input binary asset file
---@return boolean success Returns true if the file was valid and the Editor window successfully spawned
function xlook_plugin.process_and_edit_file(file_path)
    local target_file = nil
    local true_size = 0

    -- [[ STAGE 1: HOBETA OR LIMITED RAW (.scr) ]]
    local is_valid_hobeta, error_code = hobeta_reader.is_valid(file_path)

    if is_valid_hobeta then
        local temp_files_list = {}
        hobeta_reader.process(temp_files_list, file_path, {})
        target_file = temp_files_list[1]
    else
        target_file = try_load_raw_scr(file_path)
        if not target_file then
            local token = string.lower(error_code or "xl_err_open_failed")
            local lang_key = L["hobeta_" .. token] and ("hobeta_" .. token) or "xl_err_open_failed"
            far.Message(L[lang_key], L.xl_err_title, L.m_btn_cancel, "w")
            return false
        end
    end

    if not target_file or not target_file.meta then
        far.Message(L.xl_err_open_failed, L.xl_err_title, L.m_btn_cancel, "w")
        return false
    end

    local m = target_file.meta
    local raw_data = target_file.data or ""
    true_size = tonumber(m.size) or 0

    -- [[ STAGE 3: RUN THE TRANSLATED DETECTOR LAYER ]]

    detector.enrich_file_meta(target_file) -- Evaluates m.group, m.new_type, m.show_header

    -- Evaluate bounds: item must belong to the asm group OR have show_header = false explicitly mapped
    local is_to_be_decoded = (m.group == "asm" or m.group == "basic" or m.group == "ac_edit" or m.group == "trackers")
    local is_gfx = (m.group == "gfx")
    local is_raw_stream = (m.show_header == false)

    if not (is_to_be_decoded or is_gfx or is_raw_stream) then
        far.Message(L.xl_err_not_supported, L.xl_err_title, L.m_btn_cancel, "w")
        return false
    end

    -- [[ STAGE 4: CONVERTING VIA DECODER PIPELINES ]]
    local text_payload = nil
    local image_payload = nil
    local type_label = nil
    if m.description then
        type_label = m.description
    end

    if is_gfx then
        local gif_bytes, decoder_name, img_ext = decode_pipeline.decode_image_stream(raw_data, m)
        if gif_bytes then
            image_payload = gif_bytes
            type_label = decoder_name or type_label
            m._xlook_img_ext = img_ext or ".gif"
        end
    elseif is_to_be_decoded then
        -- Execute clean DRY call passing pure body string bytes (sectors payload without any headers)
        local decoded_txt, decoder_name = decode_pipeline.decode_text_stream(raw_data, m)
        if decoded_txt then
            text_payload = decoded_txt
            type_label = decoder_name or type_label
        end
    end

    -- Slicing tail residues if working with raw undecoded text fallback buffers
    if not text_payload and not image_payload and true_size > 0 and true_size < string.len(raw_data) then
        raw_data = string.sub(raw_data, 1, true_size)
    end

    -- [[ STAGE 5: DUMP TEMPORARY FILE AND LAUNCH THE EDITOR/VIEWER ]]
    local temp_dir = win.GetEnv("TEMP") or "."
    local base_name = file_path:match("([^\\/]+)$") or "xlook_temp"
    base_name = base_name:match("^(.-)%.[^%.]+$") or base_name

    local target_ext = ""
    if image_payload then
        target_ext = m._xlook_img_ext or ".gif"
    elseif m.group == "asm" then
        target_ext = ".a80"
    elseif m.group == "basic" then
        target_ext = ".bas"
    elseif m.group == "trackers" then
        target_ext = ".txt"
    else
        target_ext = m.ext or m.new_type or m.type or "C"
    end
    local target_filename = base_name .. target_ext

    local full_dest_path = win.JoinPath(temp_dir, target_filename)

    local out_fh = io.open(full_dest_path, "wb")
    if not out_fh then return false end
    out_fh:write(image_payload or text_payload or raw_data)
    out_fh:close()

    -- [[ STAGE 6: COMPILE FULL TR-DOS FILENAME TITLE FRAME LAYOUT ]]
    -- Compile custom scoped title frame layout exactly matching: [name][<type>]
    local clean_name = string.match(m.name or "", "^%s*(.-)%s*$") or m.name or "NONAME"
    -- Extract clean trailing-space stripped TR-DOS filename character bytes
    local custom_title = ""

    -- [[ UNIVERSAL EXTENSION MATCHING RULES ]]
    -- Evaluate strictly the dedicated virtual extension field parameter
    if m.ext and string.len(m.ext) == 3 then
        -- Rule 1: If a 3-letter virtual extension exists, display it inside angle brackets
        custom_title = string.format("%s.%s", clean_name, m.ext)
    else
        -- Rule 2: Fallback to standard 1-character native TR-DOS type layout inside angle brackets
        local native_type = string.sub(m.type or "C", 1, 1)
        custom_title = string.format("%s.<%s>", clean_name, native_type)
    end

    if type_label then
        custom_title = string.format("[%s][%s]", custom_title, type_label)
    else
        custom_title = string.format("[%s]", custom_title)
    end

    if image_payload then
        -- GIF/image: open via Far viewer (or associated handler for .gif)
        viewer.Viewer(full_dest_path, custom_title, nil, nil, nil, nil, F.VF_NONMODAL + F.VF_DELETEONCLOSE)
    else
        editor.Editor(full_dest_path, custom_title, nil, nil, nil, nil, F.EF_NONMODAL + F.EF_DELETEONCLOSE)
    end
    return true
end

return xlook_plugin

