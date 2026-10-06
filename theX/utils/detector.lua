local detector = {}

-- [[ Import the Knowledge Base from definitions module ]]
local rules = require("theX.types")

-- TR-DOS logical sector size (bytes). scan_sectors on a rule is measured in these.
local SECTOR_SIZE = 256
-- Default scan window when rule.scan_sectors is set / sig.scan is true but no count given.
local DEFAULT_SCAN_SECTORS = 4

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
---@param base_offset integer 0-based start offset to test
---@return boolean is_matching True if the binary bytes match the signature pattern at base_offset
local function match_signature_at(binary_data, sig, base_offset)
    local pattern = sig.pattern
    if not pattern then return false end

    local pattern_length = 0
    if type(pattern) == "string" then
        pattern_length = string.len(pattern)
    else
        for k, _ in pairs(pattern) do
            if type(k) == "number" and k > pattern_length then
                pattern_length = k
            end
        end
    end

    local data_len = string.len(binary_data)
    for idx = 1, pattern_length do
        local pattern_byte
        if type(pattern) == "string" then
            local byte_code = string.byte(pattern, idx)
            -- ? in the string works the same as nil in binary pattern
            if byte_code ~= string.byte("?") then
                pattern_byte = byte_code
            end
        else
            local char_or_byte = pattern[idx]
            if char_or_byte ~= nil then
                pattern_byte = type(char_or_byte) == "string" and string.byte(char_or_byte) or char_or_byte
            end
        end

        if pattern_byte ~= nil then
            local pos = base_offset + idx
            if pos > data_len then return false end

            local file_byte = string.byte(binary_data, pos)

            if file_byte ~= pattern_byte then return false end
        end
    end
    return true
end

--- Max byte length of the scan window for a rule/signature.
---@param rule table|nil
---@param sig table|nil
---@param data_len integer
---@return integer window_len
local function scan_window_len(rule, sig, data_len)
    local sectors = nil
    if sig and sig.scan_sectors ~= nil then
        sectors = tonumber(sig.scan_sectors)
    elseif rule and rule.scan_sectors ~= nil then
        sectors = tonumber(rule.scan_sectors)
    elseif sig and sig.scan then
        sectors = DEFAULT_SCAN_SECTORS
    end
    if not sectors or sectors <= 0 then
        return data_len
    end
    local win = math.floor(sectors) * SECTOR_SIZE
    if win > data_len then
        return data_len
    end
    return win
end

--- Matches a signature at a fixed offset, or by scanning the first N sectors.
---@param binary_data string
---@param sig table {offset?=int, pattern=string|table, scan?=bool, scan_sectors?=int}
---@param rule table|nil parent rule (may define scan_sectors)
---@return integer|nil matched_offset 0-based offset of the match, or nil
local function match_signature(binary_data, sig, rule)
    if not sig or not sig.pattern then return nil end

    local data_len = string.len(binary_data)
    local want_scan = sig.scan or (sig.offset == nil)

    -- Fixed offset (default when offset is set and scan is not requested)
    if sig.offset ~= nil and not sig.scan then
        local off = tonumber(sig.offset) or 0
        if match_signature_at(binary_data, sig, off) then
            return off
        end
        return nil
    end

    if not want_scan then
        return nil
    end

    local window = scan_window_len(rule, sig, data_len)

    -- Scan mode: search for a string pattern inside the first N sectors.
    if type(sig.pattern) == "string" then
        local haystack = binary_data
        if window < data_len then
            haystack = string.sub(binary_data, 1, window)
        end
        local pos = string.find(haystack, sig.pattern, 1, true)
        if pos then
            return pos - 1 -- 0-based
        end
        return nil
    end

    -- Scan mode for byte-table patterns: slide across the window only.
    local pat_len = 0
    for k, _ in pairs(sig.pattern) do
        if type(k) == "number" and k > pat_len then
            pat_len = k
        end
    end
    if pat_len <= 0 or pat_len > window then
        return nil
    end
    for off = 0, window - pat_len do
        if match_signature_at(binary_data, sig, off) then
            return off
        end
    end
    return nil
end

--- Resolves an absolute 0-based field offset.
--- Supports:
---   field.offset              — absolute
---   field.offset_from_sig     — relative to matched signature (±)
---   field.offset + offset_from_sig together: absolute base is ignored if offset_from_sig is set
---@param field table|nil
---@param sig_offset integer|nil 0-based matched signature offset
---@return integer|nil abs_offset
---@return integer|nil length
local function resolve_field_span(field, sig_offset)
    if not field then return nil, nil end
    local length = tonumber(field.length) or 0
    if length <= 0 then return nil, nil end

    local from_sig = field.offset_from_sig
    if from_sig ~= nil then
        if sig_offset == nil then return nil, nil end
        local rel = tonumber(from_sig) or 0
        return sig_offset + rel, length
    end

    if field.offset ~= nil then
        return tonumber(field.offset) or 0, length
    end

    return nil, nil
end

--- Reads a cleaned ASCII span from binary data.
---@param binary_data string
---@param abs_offset integer 0-based
---@param length integer
---@return string|nil
local function read_ascii_span(binary_data, abs_offset, length)
    if abs_offset < 0 then return nil end
    if abs_offset + length > string.len(binary_data) then return nil end
    return clean_extracted_string(string.sub(binary_data, abs_offset + 1, abs_offset + length))
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

    -- Initialize default display properties using the original TR-DOS values
    meta.prefix = "$"

    -- Strip whitespace from the original type for strict case-sensitive matching
    local current_type = string.match(meta.type or "C", "^%s*(.-)%s*$") or "C"

    for _, rule in ipairs(rules) do
        local is_match = true

        -- Strictly case-sensitive comparison of TR-DOS types
        if rule.type then
            local rule_type_clean = string.match(rule.type, "^%s*(.-)%s*$") or rule.type
            if rule_type_clean ~= current_type then
                is_match = false
            end
        end

        -- Cross-check numeric parameters
        if is_match and rule.size and tonumber(rule.size) ~= size then is_match = false end
        if is_match and rule.no_secs and tonumber(rule.no_secs) ~= sectors then is_match = false end
        if is_match and rule.start and tonumber(rule.start) ~= start_addr then is_match = false end
        if is_match and rule.start_lt and start_addr >= tonumber(rule.start_lt) then is_match = false end

        -- Signature analysis of the binary body; remember matched 0-based offset
        local matched_sig_offset = nil
        if is_match and rule.signatures then
            for _, sig in ipairs(rule.signatures) do
                local off = match_signature(binary_data, sig, rule)
                if off ~= nil then
                    matched_sig_offset = off
                    break
                end
            end
            if matched_sig_offset == nil then
                is_match = false
            end
        end

        -- If all criteria matched, enrich the metadata
        if is_match then
            if rule.description then
                meta.description = parse_description_vars(binary_data, rule)
            end

            if rule.group then meta.group = rule.group end

            -- comment / author: absolute offset OR offset_from_sig (± relative to matched signature)
            local c_off, c_len = resolve_field_span(rule.comment, matched_sig_offset)
            if c_off and c_len then
                local text = read_ascii_span(binary_data, c_off, c_len)
                if text then meta.comment = text end
            end

            local a_off, a_len = resolve_field_span(rule.author, matched_sig_offset)
            if a_off and a_len then
                local text = read_ascii_span(binary_data, a_off, a_len)
                if text then meta.author = text end
            end

            if rule.special_char then meta.special_char = rule.special_char end
            if rule.show_header ~= nil then meta.show_header = rule.show_header end
            if rule.new_type then meta.new_type = rule.new_type end
            break
        end
    end
end

return detector
