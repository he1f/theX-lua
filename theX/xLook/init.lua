xlook_plugin = {}

local hobeta_reader = require("theX.formats.hobeta.reader")
local detector = require("theX.utils.detector")
local asm_pipeline = require("theX.xLook.decoder_pipeline")
local basic_decoder = require("theX.xLook.basic")
local L = require("theX.ui.localization")

local F = far.Flags

--- Processes the physical HoBeta file asset pipeline, performs transformation and fires up the Far Editor screen.
---@param file_path string Absolute filesystem disk path targeting the input binary asset file
---@return boolean success Returns true if the file was valid and the Editor window successfully spawned
function xlook_plugin.process_and_edit_file(file_path)
    -- [[ STAGE 1: STRICT HOBETA STRUCTURE VALIDATION ]]
    -- Enforce native structural header criteria evaluation (size, CRC and sector mapping matching)
    local is_valid_hobeta, error_code = hobeta_reader.is_valid(file_path)

    if not is_valid_hobeta then
        local token = string.lower(error_code or "xl_err_open_failed")
        -- Safely query isolated namespaced error token index from merged localization author matrices
        local lang_key = L["hobeta_" .. token] and ("hobeta_" .. token) or "xl_err_open_failed"
        far.Message(L[lang_key], L.xl_err_title, L.m_btn_cancel, "w")
        return false
    end

    local temp_files_list = {}
    hobeta_reader.process(temp_files_list, file_path, {})

    -- In HoBeta single-file reading flows, the first index element represents our active entry
    local target_file = temp_files_list[1]
    if not target_file or not target_file.meta then
        far.Message(L.xl_err_open_failed, L.xl_err_title, L.m_btn_cancel, "w")
        return false
    end

    local m = target_file.meta
    local raw_data = target_file.data or ""
    local true_size = tonumber(m.size) or 0

    -- [[ STAGE 3: RUN THE TRANSLATED DETECTOR LAYER ]]

    detector.enrich_file_meta(target_file) -- Evaluates m.group, m.new_type, m.show_header

    -- Evaluate bounds: item must belong to the asm group OR have show_header = false explicitly mapped
    local is_asm_or_basic_group = (m.group == "asm" or m.group == "basic")
    local is_raw_stream = (m.show_header == false)

    if not (is_asm_or_basic_group or is_raw_stream) then
        far.Message(L.xl_err_not_supported, L.xl_err_title, L.m_btn_cancel, "w")
        return false
    end

    -- [[ STAGE 4: CONVERTING VIA DECODER PIPELINES ]]
    local text_payload = nil
    local type_label = nil
    if m.description then
        type_label = m.description
    end

    if is_asm_or_basic_group then
        -- Execute clean DRY call passing pure body string bytes (sectors payload without any headers)
        local decoded_txt, asm_name = asm_pipeline.decode_text_stream(raw_data, m)
        if decoded_txt then
            text_payload = decoded_txt
            type_label = asm_name or type_label
        end
    end

    -- Slicing tail residues if working with raw undecoded text fallback buffers
    if not text_payload and true_size > 0 and true_size < string.len(raw_data) then
        raw_data = string.sub(raw_data, 1, true_size)
    end

    -- [[ STAGE 5: DUMP TEMPORARY FILE AND LAUNCH THE EDITOR ]]
    local temp_dir = win.GetEnv("TEMP") or "."
    local base_name = file_path:match("([^\\/]+)$") or "xlook_temp"
    base_name = base_name:match("^(.-)%.[^%.]+$") or base_name

    local target_ext = ""
    if m.group == "asm" then
        target_ext = ".a80"
    elseif m.group == "basic" then
        target_ext = ".bas"
    else
        target_ext = m.ext or m.new_type or m.type or "C"
    end
    local target_filename = base_name .. target_ext

    local full_dest_path = win.JoinPath(temp_dir, target_filename)

    local out_fh = io.open(full_dest_path, "wb")
    if not out_fh then return false end
    out_fh:write(text_payload or raw_data)
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

    editor.Editor(full_dest_path, custom_title, nil, nil, nil, nil, F.EF_NONMODAL + F.EF_DELETEONCLOSE)
    return true
end

return xlook_plugin

