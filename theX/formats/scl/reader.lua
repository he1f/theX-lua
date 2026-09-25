---@class SclReader
local scl_reader = {}
local hobeta_reader = require("theX.formats.hobeta.reader")

local SECTOR_SIZE = 256
local MAX_SCL_FILES = 255
local MAX_SCL_SIZE = 9 + (MAX_SCL_FILES * 14) + (MAX_SCL_FILES * 255 * 256) + 4

-- Helper function checking whether a byte is a printable ASCII character
---@param byte integer
---@return boolean
local function is_printable(byte)
    return byte >= 33 and byte <= 126
end

--- Enforces strict maximum size bounds and verifies standard SCL container parameters.
---@param scl_path string Absolute path to the source file on disk
---@return boolean is_valid True if the archive passes baseline checks, false otherwise
---@return string|nil error_code The descriptive uppercase text token if validation fails
function scl_reader.is_valid(scl_path)
    local file_handle = io.open(scl_path, "rb")
    if not file_handle then
        return false, "ERR_CANNOT_OPEN_FILE"
    end

    local file_len = file_handle:seek("end")
    file_handle:seek("set", 0)

    -- [[ CHRONOLOGICAL INDEPENDENT SIZE BOUNDARIES VERIFICATION ]]
    if file_len < 10 then
        file_handle:close()
        return false, "ERR_FILE_TOO_SMALL"
    end

    if file_len > MAX_SCL_SIZE then
        file_handle:close()
        return false, "ERR_FILE_TOO_LARGE"
    end

    -- 2. Verify native signature "SINCLAIR" marker bytes alignment
    local signature = file_handle:read(8)
    if signature ~= "SINCLAIR" then
        file_handle:close()
        return false, "ERR_INVALID_SIGNATURE"
    end

    -- 3. Quick structural evaluation of directory catalog size limits
    local num_files_raw = file_handle:read(1)
    if not num_files_raw then
        file_handle:close()
        return false, "ERR_CORRUPTED_HEADER_CATALOG"
    end

    local num_files = string.byte(num_files_raw)
    local catalog_size = num_files * 14

    -- Verify that the catalog descriptors array and 4-byte tracking checksum fit tightly within physical file limits
    if file_len < (9 + catalog_size + 4) then
        file_handle:close()
        return false, "ERR_CORRUPTED_HEADER_CATALOG"
    end

    file_handle:close()
    return true, nil
end

---@param target_files_list table[] Sequential array to accumulate decoded files
---@param scl_path string Absolute path to the source .scl archive
---@param object table The active parent plugin panel context mapping states
---@return boolean success True if archive catalog parsed cleanly
function scl_reader.process(target_files_list, scl_path, object)
    local file_handle = io.open(scl_path, "rb")
    if not file_handle then return false end

    local signature = file_handle:read(8)
    local num_files_raw = file_handle:read(1)
    if not num_files_raw then file_handle:close() return false end

    local num_files = string.byte(num_files_raw)
    local directory_buffer = file_handle:read(num_files * 14)

    if not directory_buffer or string.len(directory_buffer) < (num_files * 14) then
        file_handle:close()
        return false
    end

    local files_data = {}
    for i = 1, num_files do
        local offset = (i - 1) * 14
        local chunk_sectors = string.byte(directory_buffer, offset + 14)
        local data_size = chunk_sectors * SECTOR_SIZE
        local chunk_data = file_handle:read(data_size) or string.rep(string.char(0), data_size)
        table.insert(files_data, chunk_data)
    end
    file_handle:close()

    for i = 1, num_files do
        local offset = (i - 1) * 14
        local raw_name = string.sub(directory_buffer, offset + 1, offset + 8)
        local raw_type = string.sub(directory_buffer, offset + 9, offset + 9)

        -- Raw bytes following the type (the 10th and 11th descriptor bytes)
        local b10 = string.byte(directory_buffer, offset + 10)
        local b11 = string.byte(directory_buffer, offset + 11)

        local start_addr = b10 + b11 * 256
        local file_size  = string.byte(directory_buffer, offset + 12) + string.byte(directory_buffer, offset + 13) * 256
        local chunk_sectors = string.byte(directory_buffer, offset + 14)

        local raw_desc = raw_name .. raw_type ..
                         string.char(b10, b11) ..
                         string.char(file_size % 256, math.floor(file_size / 256) % 256) ..
                         string.char(0)

        local raw_15_bytes = raw_desc .. string.char(chunk_sectors)
        local crc_bytes = hobeta_reader.calculate_crc(raw_15_bytes)
        local hobeta_header = raw_15_bytes .. crc_bytes

        local final_ext = raw_type
        local b9 = string.byte(raw_type)

        if is_printable(b9) and is_printable(b10) and is_printable(b11) then
            final_ext = string.char(b9, b10, b11)
        end

        local first_char_byte = string.byte(raw_name, 1, 1)
        local is_deleted = (first_char_byte == 0x01)
        table.insert(target_files_list, {
            header = hobeta_header,
            data   = files_data[i],
            meta   = {
                name    = raw_name,
                type    = raw_type,
                start   = start_addr,
                size    = file_size,
                sectors = chunk_sectors,
                ext     = final_ext,
                deleted = is_deleted
            }
        })
    end
    -- target_files_list is fully populated and #target_files_list returns the true files count.
    if object then
        object.scl_info = {
            archive_type = "SCL Container",
            total_files  = #target_files_list
        }
    end
    return true
end

return scl_reader
