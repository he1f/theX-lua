local hobeta_reader = require("theX.formats.hobeta.reader")

local raw_reader = {}
local SECTOR_SIZE = 256
local MAX_RAW_SIZE = 256 * 255 * 4 -- Maximum structural limit (261,120 bytes)

--- Packs a 3-character PC extension into 1-byte TR-DOS type and 2-byte start address.
---@param m table The target metadata structure to process
---@param pc_ext string PC extension to pack
---@return nil
local function assign_meta(m, pc_ext)
    local clean = string.match(pc_ext, "^%s*(.-)%s*$") or pc_ext
    if string.len(clean) == 3 then
        m.type = string.sub(clean, 1, 1)
        m.start = (string.byte(clean, 2) * 256) + string.byte(clean, 3)
        m.ext = pc_ext
    else
        m.type = string.sub(clean, 1, 1) or "C"
        m.start = 0
    end
end

--- Splits a continuous PC binary buffer into clean 256-byte TR-DOS disk sectors.
---@param raw_buffer string The continuous unaligned binary string layout from host file
---@return string padded_data The continuous binary stream padded with null zeroes to 256 multiple bounds
---@return integer sectors_count Total physical TR-DOS disk sectors occupied by padded blocks
local function align_sectors(raw_buffer)
    local data = raw_buffer or ""
    local size = string.len(data)
    local count = math.ceil(size / SECTOR_SIZE)
    if count == 0 then count = 1 end
    local padding = (count * SECTOR_SIZE) - size
    if padding > 0 then
        data = data .. string.rep(string.char(0), padding)
    end
    return data, count
end

--- Validates file existence and enforces strict maximum size constraints for TR-DOS VFS import mappings.
---@param file_path string The absolute physical file path location on the host PC system disk storage
---@return boolean is_valid Returns true if the raw binary file fits within size limit parameters, false otherwise
---@return string|nil error_code Returns "ERR_FILE_TOO_LARGE" if validation thresholds are broken, nil on success
function raw_reader.is_valid(file_path)
    -- Use native Far win API to query file metrics without shifting binary buffers to memory prematurely
    local file_info = win.GetFileInfo(file_path)
    if not file_info then
        return false, "ERR_CANNOT_OPEN_FILE"
    end

    -- [[ CRITICAL SIZE ENFORCEMENT BOUNDARY ]]
    -- Reject files that geometrically cannot fit inside target TR-DOS disk layouts allocations bounds
    if file_info.FileSize > MAX_RAW_SIZE then
        return false, "ERR_FILE_TOO_LARGE"
    end

    return true, nil
end

--- Main processing workflow to decode archive metadata or split and inject physical PC raw disk files.
---@param target_files_list table[] Sequential target file dictionary array mapping panel workspace
---@param raw_path string The absolute physical file path location on the host PC system disk storage
---@return boolean success True if archive catalog parsed cleanly
function raw_reader.process(target_files_list, raw_path)
    local fh = io.open(raw_path, "rb")
    if not fh then return false end
    local raw_bytes = fh:read("*a") or ""
    fh:close()

    -- Extract base filename string chunk and extension boundaries from disk path
    local path_name = raw_path:match("([^\\/]+)$") or raw_path
    local base, ext = string.match(path_name, "^(.-)%.([^%.]+)$")
    base, ext = base or path_name, ext or "C"

    -- Ensure name padding exactly up to 8 bytes using trailing spaces mapping rules
    base = string.sub(base, 1, 8)
    if string.len(base) < 8 then
        base = base .. string.rep(" ", 8 - string.len(base))
    end
    ext = string.sub(ext, 1, 3)

    local remaining_bytes = raw_bytes
    local max_chunk_bytes = 256 * 255 -- Exactly 65,280 bytes per TR-DOS directory record

    -- [[ SPLITTING LOOP FOR MULTI-CHUNK RAW IMPORT ]]
    while string.len(remaining_bytes) > 0 do
        local chunk_payload = string.sub(remaining_bytes, 1, max_chunk_bytes)
        remaining_bytes = string.sub(remaining_bytes, max_chunk_bytes + 1)

        local is_last_chunk = string.len(remaining_bytes) == 0
        local padded_data, physical_sectors = align_sectors(chunk_payload)
        local trdos_logical_size = is_last_chunk and string.len(chunk_payload) or 0

        local meta = {
            name    = base,
            type    = "C", -- Code block format indicator identifier
            start   = 0,
            size    = trdos_logical_size,
            sectors = physical_sectors
        }

        assign_meta(meta, ext)

        -- [[ GENERATE RAW 17-BYTE HOBETA HEADER BINARY STREAM ]]
        -- Break down 16-bit meta values into standard Little-Endian byte chunks
        local st_h, st_l = math.floor(meta.start / 256) % 256, meta.start % 256
        local sz_h, sz_l = math.floor(meta.size / 256) % 256, meta.size % 256

        -- Assemble the first 15 bytes of the classic HoBeta structure layout container
        local h_bytes = meta.name .. meta.type .. string.char(st_l, st_h, sz_l, sz_h, 0, meta.sectors)

        local header_checksum = hobeta_reader.calculate_crc(h_bytes)
        local compiled_header = h_bytes .. header_checksum

        table.insert(target_files_list, {
            meta   = meta,
            header = compiled_header,
            data   = padded_data
        })
    end
    return true
end

return raw_reader
