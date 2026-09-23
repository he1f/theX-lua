local writer = {}

-- [[ Import the cross-module CRC component directly to reuse logic ]]
local hobeta_reader = require("theX.formats.hobeta.reader")

--- Commits the current active in-memory virtual filesystem cache onto physical SCL storage.
---@param archive_path string Absolute physical file path targeting the destination SCL image
---@param files_list table[] Sequential array containing the current session files descriptors
---@param object table The active parent plugin panel context mapping states
---@param update_headers boolean? If true, enforces on-the-fly regeneration of 17-byte headers from current meta variables
---@return boolean success Returns true if the archive was safely flushed to storage, false on I/O reject
function writer.save(archive_path, files_list, object, update_headers)
    local file_handle = io.open(archive_path, "wb")
    if not file_handle then return false end

    local buffer = {}
    table.insert(buffer, "SINCLAIR")
    table.insert(buffer, string.char(#files_list))

    -- [[ STAGE A: PROCESS AND APPEND SCL DIRECTORY RECORD ATTRIBUTES ]]
    for _, hobeta_file in ipairs(files_list) do
        local m = hobeta_file.meta

        -- [[ REGENERATION TRIGGER PIPELINE ]]
        -- If the change request layer explicitly enforces header refreshes (e.g. after Shift+F6)
        if update_headers and m then
            -- Enforce standard padding configurations for native 8-byte TR-DOS naming strings
            local base_name = m.name or "noname"
            base_name = string.sub(base_name, 1, 8)
            if string.len(base_name) < 8 then
                base_name = base_name .. string.rep(" ", 8 - string.len(base_name))
            end

            local file_type = string.sub(m.type or "C", 1, 1)

            -- Disassemble 16-bit meta integer parameters down to standard Little-Endian layout bytes
            local st_h, st_l = math.floor((m.start or 0) / 256) % 256, (m.start or 0) % 256
            local sz_h, sz_l = math.floor((m.size or 0) / 256) % 256, (m.size or 0) % 256
            local sectors_count = m.sectors or 1

            -- Build the fundamental 15-byte base structure of the HoBeta record schema
            local h_base_15bytes = base_name .. file_type .. string.char(st_l, st_h, sz_l, sz_h, 0, sectors_count)

            -- [[ CALL THE VALIDATED CROSS-MODULE CRC ACCUMULATOR ]]
            local header_checksum = hobeta_reader.calculate_crc(h_base_15bytes)

            -- Re-cache the fresh compiled 17-byte string container back to active session object
            hobeta_file.header = h_base_15bytes .. header_checksum
        end

        -- Extract the canonical 14-byte SCL directory slice (Bytes 1..13 + Byte 15)
        -- SCL completely ignores the HoBeta data length metric bytes (14) and 2-byte header CRC (16..17)
        local raw_header = hobeta_file.header or ""
        if string.len(raw_header) >= 15 then
            table.insert(buffer, string.sub(raw_header, 1, 13) .. string.sub(raw_header, 15, 15))
        else
            -- Robust recovery fallback block to prevent memory indexing collapses on blank entries
            table.insert(buffer, string.rep(string.char(0), 14))
        end
    end

    -- [[ STAGE B: APPEND RAW DATA SECTORS BLOCKS ]]
    for _, hobeta_file in ipairs(files_list) do
        table.insert(buffer, hobeta_file.data or "")
    end

    local full_data = table.concat(buffer)

    -- [[ STAGE C: CALCULATE MONOLITHIC SCL ARITHMETIC CHECKSUM SUM ]]
    local scl_checksum = 0
    for i = 1, string.len(full_data) do
        scl_checksum = scl_checksum + string.byte(full_data, i)
    end

    -- Split 32-bit accumulated sum into a standard 4-byte Little-Endian binary trailer
    local b1 = scl_checksum % 256
    local b2 = math.floor(scl_checksum / 256) % 256
    local b3 = math.floor(scl_checksum / 65536) % 256
    local b4 = math.floor(scl_checksum / 16777216) % 256

    file_handle:write(full_data)
    file_handle:write(string.char(b1, b2, b3, b4))
    file_handle:close()

    return true
end

return writer
