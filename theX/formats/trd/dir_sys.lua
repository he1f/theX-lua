local dir_sys = {}

-- [[ SPECIFICATION OFFSET AND CONSTANTS ]]
-- 9 sectors * 256 bytes = 2304 bytes from track start (Sector 10)
local SECTOR_SIZE = 256
local DS_SECTOR_OFFSET = 9 * SECTOR_SIZE
local SIGNATURE = "DirSys100"

--- Stateful 64-bit implementation of the custom DirSys CRC-16 algorithm.
--- Fully compliant with the bit64 constraints of Far Manager 3.
---@param bytes_str string The binary string buffer slice to scan
---@return integer crc 16-bit unsigned integer value representing calculated checksum
function dir_sys.calculate_crc(bytes_str)
    local crc = 0
    local len = string.len(bytes_str)

    for i = 1, len do
        local byte_val = string.byte(bytes_str, i) or 0

        -- Exact C++ mirror: BYTE tmp = crc ^ *ptr++;
        -- Extract strictly the lower 8 bits of the current XOR accumulation state
        local tmp_byte = bit64.band(bit64.bxor(crc, byte_val), 0xFF)
        local b_crc = 0

        for bit_idx = 0, 7 do
            local l_bit = bit64.band(b_crc, 1)

            -- C++: bCRC >>= 1; bCRC |= l_bit << 15; (RRA execution simulation)
            b_crc = bit64.rshift(b_crc, 1)
            b_crc = bit64.bor(b_crc, bit64.lshift(l_bit, 15))

            -- C++: if ((tmp & 1) ^ l_bit) bCRC ^= 0xA001;
            local tmp_bit = bit64.band(tmp_byte, 1)
            if bit64.bxor(tmp_bit, l_bit) ~= 0 then
                b_crc = bit64.bxor(b_crc, 0xA001)
            end

            -- C++: tmp >>= 1;
            tmp_byte = bit64.rshift(tmp_byte, 1)
        end

        -- C++: crc = bCRC ^ (crc << 8 | crc >> 8);
        local crc_lshift = bit64.band(bit64.lshift(crc, 8), 0xFF00)
        local crc_rshift = bit64.band(bit64.rshift(crc, 8), 0x00FF)
        local swop_crc   = bit64.bor(crc_lshift, crc_rshift)

        crc = bit64.band(bit64.bxor(b_crc, swop_crc), 0xFFFF)
    end

    -- Final return statement inversion mirror: return (crc << 8 | crc >> 8);
    local final_lshift = bit64.band(bit64.lshift(crc, 8), 0xFF00)
    local final_rshift = bit64.band(bit64.rshift(crc, 8), 0x00FF)

    return bit64.bor(final_lshift, final_rshift)
end

--- Validates and parses the optional DirSys directory structure layout from raw disk data bytes.
---@param trd_bytes string Monolithic continuous binary buffer containing the whole TRD track sectors image data
---@return table|nil directories sequential array of directory names (1-based index maps to DirSys numeric token ID)
---@return table|nil file_assignments map linking file index position -> parent folder token ID
function dir_sys.parse(trd_bytes)
    if string.len(trd_bytes) < (DS_SECTOR_OFFSET + 256) then return nil, nil end

    -- Verify the authentic string signature footprint "DirSys" at offset +2 of sector 10
    local check_sig = string.sub(trd_bytes, DS_SECTOR_OFFSET + 2 + 1, DS_SECTOR_OFFSET + 2 + 9)
    if check_sig ~= SIGNATURE then
        return nil, nil -- DirSys is missing on this disk image layout, abort quietly
    end

    -- Extract original CRC bytes from positions +0, +1
    local crc_l = string.byte(trd_bytes, DS_SECTOR_OFFSET + 0 + 1) or 0
    local crc_h = string.byte(trd_bytes, DS_SECTOR_OFFSET + 1 + 1) or 0
    local original_crc = (crc_h * 256) + crc_l

    -- Count total active directory elements by looping strings until the 0x00 end marker anchor is hit
    local folders = {}
    local folders_count = 0
    local names_base_offset = DS_SECTOR_OFFSET + 0x10B

    while true do
        local check_offset = names_base_offset + (folders_count * 11)
        if check_offset + 1 > string.len(trd_bytes) then break end

        local first_char = string.byte(trd_bytes, check_offset + 1)
        if not first_char or first_char == 0x00 then
            break -- End of system marker found safely
        end

        folders_count = folders_count + 1
        local raw_name = string.sub(trd_bytes, check_offset + 1, check_offset + 11)
        local clean_name = string.match(raw_name, "^(.-)%s*$")
        -- Check if this folder item is marked with deletion byte 0x01
        local is_deleted = (first_char == 0x01)
        table.insert(folders, {
            id      = folders_count,
            name    = clean_name,
            deleted = is_deleted
        })
    end

    -- [[ CRITICAL FIX: READ HIERARCHICAL PATHS ASSIGNMENTS FOR DIRECTORIES TREE ]]
    -- Offset 0x8B (139) represents the native start of folders parent links array matrix.
    -- We loop precisely up to the collected folders count to map their active parent nodes.
    for idx, folder in ipairs(folders) do
        -- Catalog 1 parent sits at +0x8B, Catalog 2 parent sits at +0x8C, etc.
        local parent_folder_id = string.byte(trd_bytes, DS_SECTOR_OFFSET + 0x8B + (idx - 1) + 1) or 0

        -- Dynamically bind the resolved parent reference variable directly to our folder instance table
        folder.parent_id = parent_folder_id -- Value 0 strictly marks that the folder belongs to the Root directory
    end

    -- [[ CRITICAL SYSTEM INTEGRITY AND VALIDATION CHECK ]]
    -- CRC covers bytes from +02 up to the last character of the last specified directory name
    local crc_payload_len = 256 + 9 + (folders_count * 11)
    local crc_payload = string.sub(trd_bytes, DS_SECTOR_OFFSET + 2 + 1, DS_SECTOR_OFFSET + 2 + crc_payload_len)
    local calculated_crc = dir_sys.calculate_crc(crc_payload)

    if original_crc ~= calculated_crc then
        -- Integrity corruption detected, drop safely to protect file tree matrix mappings
        return nil, nil
    end

    -- Unpack file placement tokens mapping layouts rows from byte +0x0B up to +0x8A (128 files max)
    local file_assignments = {}
    for i = 0, 127 do
        local parent_folder_id = string.byte(trd_bytes, DS_SECTOR_OFFSET + 0x0B + i + 1) or 0
        file_assignments[i] = parent_folder_id -- 0 means root directory entry mapping
    end

    return folders, file_assignments
end

--- Compiles a clean serialized DirSys binary stream patch ready to split and merge back into disk track sectors.
---@param files_list table[] Active session file entities table descriptors
---@param object table Active parent panel component reference tracking metrics
---@return string? compiled_ds_data Serialized string block (multi-sector fitting bounds) or nil
function dir_sys.compile(files_list, object)
    -- If the image disk was loaded without any active DirSys context metadata wrappers, skip compilation
    if not object or not object.trd_folders or not object.trd_file_maps then
        return nil
    end

    local folders = object.trd_folders
    local file_maps = object.trd_file_maps

    -- Build clean flat bytes template containing basic definitions constants markers
    local ds_bytes_tbl = {}
    for i = 1, 267 do ds_bytes_tbl[i] = 0 end -- 11 bytes header descriptor + 256 bytes assignments table

    -- Inject structural labels
    for i = 1, 9 do
        ds_bytes_tbl[2 + i] = string.byte(SIGNATURE, i)
    end

    -- Refill assignment values mapping files array indices tokens safely
    -- Note: We hash names to match actual elements list indices updates dynamically
    for idx, hobeta_file in ipairs(files_list) do
        -- TR-DOS file positions are 0-based up to 127
        local file_trdos_idx = idx - 1
        if file_trdos_idx <= 127 then
            local parent_id = file_maps[file_trdos_idx] or 0
            ds_bytes_tbl[11 + file_trdos_idx + 1] = parent_id
        end
    end
    for idx, folder in ipairs(folders) do
        if idx <= 127 then
            -- Offset +0x8B relative to the start of sector 10 (11 header bytes + 128 file bytes)
            -- Inside ds_bytes_tbl this is the index: 11 + 128 + (idx - 1) + 1 = 139 + idx
            local dir_trdos_idx = 139 + idx
            ds_bytes_tbl[dir_trdos_idx] = folder.parent_id or 0
        end
    end
    -- Append directory name strings components sequential buffers chain
    local name_chunks = {}
    for _, folder in ipairs(folders) do
        local raw_name = folder.name or "new_folder"
        if folder.deleted then
            raw_name = string.char(0x01) .. string.sub(raw_name, 2)
        end
        if string.len(raw_name) < 11 then
            raw_name = raw_name .. string.rep(" ", 11 - string.len(raw_name))
        end
        table.insert(name_chunks, string.sub(raw_name, 1, 11))
    end

    local head_chars = {}
    for i = 1, 267 do
        head_chars[i] = string.char(ds_bytes_tbl[i] or 0)
    end

    local head_str = table.concat(head_chars)
    local names_str = table.concat(name_chunks)

    -- [[ CALCULATE AND WRITE VERIFIED SYSTEM CRC TRAILER ]]
    -- CRC targets parameters starting from string position index 3 up to the last char of directories array list
    local crc_payload = string.sub(head_str, 3) .. names_str
    local final_crc = dir_sys.calculate_crc(crc_payload)

    local crc_l = bit64.band(final_crc, 0xFF)
    local crc_h = bit64.band(bit64.rshift(final_crc, 8), 0xFF)

    -- Assemble monolithic unified string block and inject ending structural anchor 0x00 byte marker
    local complete_ds_block = string.char(crc_l, crc_h) .. crc_payload .. string.char(0)

    -- Pad the generated block out to match whole 256-byte sector limits perfectly
    local overflow = string.len(complete_ds_block) % SECTOR_SIZE
    if overflow > 0 then
        complete_ds_block = complete_ds_block .. string.rep(string.char(0), SECTOR_SIZE - overflow)
    end

    return complete_ds_block
end

--- Initializes a clean, empty DirSys structure layout inside the workspace memory object.
---@param object table The active parent plugin panel context mapping states
---@return nil
function dir_sys.initialize_empty_system(object)
    if not object then return end
    -- Setup initial empty state matrices
    object.trd_folders = {}
    object.trd_file_maps = {}
    -- Fill out placeholders inside assignments mapping up to 127 file entries
    for i = 0, 127 do
        object.trd_file_maps[i] = 0 -- All files initially reside inside the Root zone
    end
end

return dir_sys
