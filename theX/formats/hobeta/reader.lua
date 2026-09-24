---@class HobetaReader
local hobeta_reader = {}

local MAX_HOBETA_SIZE = 17 + (255 * 256)

-- Вспомогательная функция проверки печатных символов ASCII
---@param byte integer
---@return boolean
local function is_printable(byte)
    return byte >= 33 and byte <= 126
end

---@param hobeta_path string Absolute path to the source file on disk
---@return boolean is_valid True if the file matches strict HoBeta header criteria
---@return string|nil error_code The descriptive uppercase text token if validation fails
function hobeta_reader.is_valid(hobeta_path)
    local file_handle = io.open(hobeta_path, "rb")
    if not file_handle then
        return false, "ERR_CANNOT_OPEN_FILE"
    end

    -- 1. Проверяем минимальный размер файла под HoBeta-заголовок (17 байт)
    local file_len = file_handle:seek("end")
    file_handle:seek("set", 0)

    if file_len > MAX_HOBETA_SIZE then
        file_handle:close()
        return false, "ERR_FILE_TOO_LARGE"
    end

    if file_len < 17 then
        file_handle:close()
        return false, "ERR_FILE_TOO_SMALL"
    end

    local header = file_handle:read(17)
    file_handle:close()

    if not header or string.len(header) < 17 then
        return false, "ERR_CORRUPTED_HEADER_CATALOG"
    end

    -- 2. Проверяем целостность за счет валидации CRC
    local raw_15_bytes = string.sub(header, 1, 15)
    local original_crc = string.sub(header, 16, 17)
    local calculated_crc = hobeta_reader.calculate_crc(raw_15_bytes)

    if original_crc ~= calculated_crc then
        return false, "ERR_CHECKSUM_MISMATCH"
    end

    -- 3. Проверяем соответствие секторов физическому размеру файла на диске ПК
    local sectors = string.byte(header, 15)
    local expected_file_size = 17 + (sectors * 256)
    if file_len < expected_file_size then
        return false, "ERR_DATA_SIZE_MISMATCH"
    end

    return true, nil
end

---@param target_files_list table[] Sequential array to accumulate decoded files
---@param hobeta_path string Absolute path to the source file on disk
---@param object table The active parent plugin panel context mapping states
---@return boolean success True if file loaded successfully
function hobeta_reader.process(target_files_list, hobeta_path, object)
    if object then
        object.hobeta_info = { archive_type = "HoBeta File" }
    end
    local file_handle = io.open(hobeta_path, "rb")
    if not file_handle then return false end

    local header = file_handle:read(17)
    if not header or string.len(header) < 17 then file_handle:close() return false end

    local raw_name = string.sub(header, 1, 8)
    local raw_type = string.sub(header, 9, 9)

    -- Извлекаем сырые байты из заголовка
    local b9  = string.byte(raw_type)
    local b10 = string.byte(header, 10)
    local b11 = string.byte(header, 11)

    local start_addr = b10 + b11 * 256
    local file_size  = string.byte(header, 12) + string.byte(header, 13) * 256
    local sectors    = string.byte(header, 15)
    local binary_data = file_handle:read(sectors * 256) or ""
    file_handle:close()

    local final_ext = raw_type
    if is_printable(b9) and is_printable(b10) and is_printable(b11) then
        final_ext = string.char(b9, b10, b11)
    end
    local first_byte = string.byte(raw_name, 1, 1)
    local is_deleted = (first_byte == 0x01)
    table.insert(target_files_list, {
        header = header,
        data   = binary_data,
        meta   = {
            name    = raw_name,
            type    = raw_type,
            start   = start_addr,
            size    = file_size,
            sectors = sectors,
            ext     = final_ext,
            deleted = is_deleted
        }
    })
    return true
end

--- Calculates the correct 16-bit TR-DOS HoBeta checksum for a 15-byte header buffer block.
--- Uses the strict native Spectrum specification algorithm: (sum * 257) + 105.
---@param buffer string The raw 15-byte base header string to evaluate
---@return string crc_bytes A 2-byte Little-Endian binary string representation of the calculated CRC
function hobeta_reader.calculate_crc(buffer)
    if not buffer or string.len(buffer) < 15 then
        -- Safe fallback returns zeroed checksum bytes if buffer is truncated
        return string.char(0, 0)
    end

    local sum = 0
    -- Iterate strictly across the first 15 base bytes of the HoBeta layout
    for i = 1, 15 do
        sum = sum + string.byte(buffer, i)
    end

    -- [[ NATIVE TR-DOS ARITHMETIC ALGORITHM ]]
    -- Apply the classic Spectrum mathematical transformation matrix
    local final_crc = (sum * 257) + 105

    -- Extract Little-Endian Low and High 8-bit unsigned integer byte weights
    local crc_low = final_crc % 256
    local crc_high = math.floor(final_crc / 256) % 256

    return string.char(crc_low, crc_high)
end


return hobeta_reader
