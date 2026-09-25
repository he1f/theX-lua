local detector = {}

-- [[ Import the Knowledge Base from definitions module ]]
local rules = require("theX.types")

---@param str string|nil The raw source string extracted from binary data
---@return string The sanitized clean string without trailing garbage
local function clean_extracted_string(str)
    if not str then return "" end
    local null_pos = string.find(str, "%z")
    if null_pos then
        str = string.sub(str, 1, null_pos - 1)
    end
    local cleaned = string.match(str, "^(.-)%s*$")
    return cleaned or str
end

---@param binary_data string The raw binary payload of the file
---@param sig table The single signature validation rule
---@return boolean is_matching True if the binary bytes match the signature pattern
local function match_signature(binary_data, sig)
    local base_offset = sig.offset or 0
    local pattern = sig.pattern
    if not pattern then return false end

    local pattern_length = 0
    for k, _ in pairs(pattern) do
        if type(k) == "number" and k > pattern_length then
            pattern_length = k
        end
    end

    for idx = 1, pattern_length do
        local char_or_byte = pattern[idx]
        if char_or_byte ~= nil then
            local pos = base_offset + idx
            if pos > string.len(binary_data) then return false end

            local file_byte = string.byte(binary_data, pos)
            local pattern_byte = type(char_or_byte) == "string" and string.byte(char_or_byte) or char_or_byte

            if file_byte ~= pattern_byte then return false end
        end
    end
    return true
end

---@param binary_data string The raw binary payload of the file
---@param rule table The active rule container dictionary
---@return string The populated description string with tokens replaced
local function parse_description_vars(binary_data, rule)
    local desc = rule.description or ""
    if not rule.description_vars then return desc end

    for var_name, var_info in pairs(rule.description_vars) do
        local offset = var_info.offset or 0
        local length = var_info.length or 0

        if offset + length <= string.len(binary_data) then
            local raw_val = string.sub(binary_data, offset + 1, offset + length)

            if var_info.type == "ascii" or var_info.type == "string" then
                local clean_val = clean_extracted_string(raw_val)
                clean_val = string.gsub(clean_val, "%%", "%%%%")
                desc = string.gsub(desc, "{" .. var_name .. "}", clean_val)
            end
        end
    end
    return desc
end

---@param hobeta_file table The core file dictionary mapping metadata and content buffers
function detector.enrich_file_meta(hobeta_file)
    if not hobeta_file or not hobeta_file.meta then return end

    local meta = hobeta_file.meta
    local binary_data = hobeta_file.data or ""

    local size       = tonumber(meta.size) or 0
    local start_addr = tonumber(meta.start) or 0
    local sectors    = tonumber(meta.sectors) or 0

    -- Инициализируем свойства отображения по умолчанию оригинальными значениями TR-DOS
    meta.prefix = "$"

    -- Очищаем оригинальный тип от пробелов для строгого регистрового сопоставления
    local current_type = string.match(meta.type or "C", "^%s*(.-)%s*$") or "C"

    for _, rule in ipairs(rules) do
        local is_match = true

        -- Строго регистрозависимое сравнение типов TR-DOS
        if rule.type then
            local rule_type_clean = string.match(rule.type, "^%s*(.-)%s*$") or rule.type
            if rule_type_clean ~= current_type then
                is_match = false
            end
        end

        -- Сверка числовых параметров
        if is_match and rule.size and tonumber(rule.size) ~= size then is_match = false end
        if is_match and rule.no_secs and tonumber(rule.no_secs) ~= sectors then is_match = false end
        if is_match and rule.start and tonumber(rule.start) ~= start_addr then is_match = false end
        if is_match and rule.start_lt and start_addr >= tonumber(rule.start_lt) then is_match = false end

        -- Сигнатурный анализ бинарного тела
        if is_match and rule.signatures then
            local sig_ok = false
            for _, sig in ipairs(rule.signatures) do
                if match_signature(binary_data, sig) then
                    sig_ok = true
                    break
                end
            end
            if not sig_ok then is_match = false end
        end

        -- Если все критерии сошлись — обогащаем метаданные
        if is_match then
            if rule.description then
                meta.description = parse_description_vars(binary_data, rule)
            end

            if rule.group then meta.group = rule.group end

            if rule.comment and rule.comment.offset and rule.comment.length then
                local c_off = tonumber(rule.comment.offset) or 0
                local c_len = tonumber(rule.comment.length) or 0
                if c_off + c_len <= string.len(binary_data) then
                    meta.comment = clean_extracted_string(string.sub(binary_data, c_off + 1, c_off + c_len))
                end
            end

            if rule.author and rule.author.offset and rule.author.length then
                local a_off = tonumber(rule.author.offset) or 0
                local a_len = tonumber(rule.author.length) or 0
                if a_off + a_len <= string.len(binary_data) then
                    meta.author = clean_extracted_string(string.sub(binary_data, a_off + 1, a_off + a_len))
                end
            end

            if rule.special_char then meta.special_char = rule.special_char end
            if rule.show_header ~= nil then meta.show_header = rule.show_header end
            if rule.new_type then meta.new_type = rule.new_type end
            break
        end
    end
end

return detector
