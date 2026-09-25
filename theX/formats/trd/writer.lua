local writer = {}

-- [[ TR-DOS Disk Geometry Authoritative Constants ]]
local SECTOR_SIZE       = 256
local TRACK_SECTORS     = 16
local SYS_SECTOR_OFFSET = 2048 -- Track 0, Sector 8 (0x800)
local DS_SECTOR_OFFSET = 9 * SECTOR_SIZE


-- Import the cross-module CRC component to reuse logic on demand
local hobeta_reader = require("theX.formats.hobeta.reader")
local dir_sys = require("theX.formats.trd.dir_sys")

--- Map native TR-DOS disk type flags (byte 0xE3) to total physical sector counts.
---@param type_byte integer The raw byte read from 0xE3 offset inside sector 9
---@return integer total_sectors Total number of 256-byte sectors matching this geometry
local function resolve_total_sectors(type_byte)
    if type_byte == 0x16 then return 80 * 2 * 16 -- 0x19: 80 tracks, double-sided (640KB - Standard Default)
    elseif type_byte == 0x17 then return 40 * 2 * 16 -- 40 tracks, double-sided (320KB)
    elseif type_byte == 0x18 then return 80 * 1 * 16 -- 80 tracks, single-sided (320KB)
    end
    return 40 * 1 * 16   -- 40 tracks, single-sided (160KB)
end

--- Commits the current active VFS memory cache state onto physical TRD track sector image storage.
---@param archive_path string Absolute physical filesystem path targeting the destination TRD file
---@param files_list table[] Sequential array containing the current session files descriptors
---@param object table The parent stateful plugin instance table mapping disk environment data
---@param update_headers boolean? If true, enforces on-the-fly regeneration of internal headers from meta variables
---@return boolean success Returns true if the image was safely flushed to storage, false on I/O reject
function writer.save(archive_path, files_list, object, update_headers)
    -- Resolve discrete variables properties straight from our compact cached object register
    local disk_info   = object and object.trd_info or {}
    local disk_type   = disk_info.disk_type or 0x19
    local disk_label  = disk_info.label or "EMPTY"
    local deleted_qty = disk_info.deleted_files or 0

    local total_disk_sectors = resolve_total_sectors(disk_type)
    local target_image_size = total_disk_sectors * SECTOR_SIZE

    -- Prepare clear flat sector arrays structure
    local sectors_array = {}
    for i = 1, total_disk_sectors do
        sectors_array[i] = string.rep(string.char(0), SECTOR_SIZE)
    end

    -- Try to preserve unchanged track/sector matrices data streams if rewriting an existing file resource
    local fh_in = io.open(archive_path, "rb")
    if fh_in then
        local trd_bytes = fh_in:read("*a") or ""
        fh_in:close()
        if string.len(trd_bytes) >= target_image_size then
            for i = 1, total_disk_sectors do
                local offset = (i - 1) * SECTOR_SIZE
                sectors_array[i] = string.sub(trd_bytes, offset + 1, offset + SECTOR_SIZE)
            end

            -- If trd_info was missing on object, dynamically resolve it from the existing disk stream
            if not object or not object.trd_info then
                local sys_sec = sectors_array[SYS_SECTOR_OFFSET / SECTOR_SIZE + 1] or string.rep(string.char(0), SECTOR_SIZE)
                disk_type   = string.byte(sys_sec, 0xE3 + 1) or 0x19
                deleted_qty = string.byte(sys_sec, 0xF4 + 1) or 0
                disk_label  = string.sub(sys_sec, 0xF5 + 1, 0xFF + 1) or string.rep(" ", 11)
                total_disk_sectors = resolve_total_sectors(disk_type)
                target_image_size = total_disk_sectors * SECTOR_SIZE
            end
        end
    end

    -- [[ STAGE A: CLEAR THE ENTIRE CATALOG AREA SECTORS 0..7 ]]
    for i = 1, 8 do
        sectors_array[i] = string.rep(string.char(0), SECTOR_SIZE)
    end

    -- Initialize tracking metrics pointers for TR-DOS sequential layout packing configurations
    -- Files allocation data segments strictly start writing from Track 1, Sector 0
    local next_free_track  = 1
    local next_free_sector = 0
    local accumulated_used_sectors = 0

    local current_catalog_byte_offset = 0
    local current_catalog_sector_idx = 1

    -- [[ STAGE B: REGENERATE HEADERS AND REPACK DIRECTORY METADATA ROWS ]]
    for _, hobeta_file in ipairs(files_list) do
        local m = hobeta_file.meta

        if update_headers and m then
            local base_name = m.name or "noname"
            base_name = string.sub(base_name, 1, 8)
            if string.len(base_name) < 8 then
                base_name = base_name .. string.rep(" ", 8 - string.len(base_name))
            end

            local file_type = string.sub(m.type or "C", 1, 1)
            local st_h, st_l = math.floor((m.start or 0) / 256) % 256, (m.start or 0) % 256
            local sz_h, sz_l = math.floor((m.size or 0) / 256) % 256, (m.size or 0) % 256

            -- Calculate sectors metric dynamically based on physical data buffer payload length
            local sectors_count = m.sectors or math.ceil(string.len(hobeta_file.data or "") / SECTOR_SIZE)
            if sectors_count == 0 then sectors_count = 1 end
            m.sectors = sectors_count

            local h_base_15bytes = base_name .. file_type .. string.char(st_l, st_h, sz_l, sz_h, 0, sectors_count)
            local header_checksum = hobeta_reader.calculate_crc(h_base_15bytes)

            hobeta_file.header = h_base_15bytes .. header_checksum
            m.track = next_free_track
            m.sector = next_free_sector
        end

        local raw_header = hobeta_file.header or ""
        if string.len(raw_header) >= 17 and m then
            -- [[ CONSTRUCT THE 16-BYTE NATIVE FileHdr STRUCTURE ]]
            local file_hdr_16bytes = string.sub(raw_header, 1, 13) ..
                                     string.char(m.sectors or 1) ..
                                     string.char(m.sector or 0) ..
                                     string.char(m.track or 1)

            -- Pack the compiled descriptor binary row into the current active directory sector segment slice
            local sector_str = sectors_array[current_catalog_sector_idx]
            local left_chunk = string.sub(sector_str, 1, current_catalog_byte_offset)
            local right_chunk = string.sub(sector_str, current_catalog_byte_offset + 17)
            sectors_array[current_catalog_sector_idx] = left_chunk .. file_hdr_16bytes .. right_chunk

            -- [[ STAGE C: RE-ALLOCATE AND OVERWRITE DISK DATA TRACKS SECTORS ]]
            local data_start_sector_idx = (m.track * TRACK_SECTORS + m.sector) + 1
            local raw_payload = hobeta_file.data or ""
            local total_bytes_to_write = (m.sectors or 1) * SECTOR_SIZE

            -- Pad or trim payload strings arrays to exactly align with sector size step thresholds bounds
            if string.len(raw_payload) < total_bytes_to_write then
                raw_payload = raw_payload .. string.rep(string.char(0), total_bytes_to_write - string.len(raw_payload))
            elseif string.len(raw_payload) > total_bytes_to_write then
                raw_payload = string.sub(raw_payload, 1, total_bytes_to_write)
            end

            -- Disassemble raw data stream down into independent sector blocks segments writes
            for s_offset = 0, (m.sectors or 1) - 1 do
                local target_write_index = data_start_sector_idx + s_offset
                if target_write_index <= total_disk_sectors then
                    local chunk_offset = s_offset * SECTOR_SIZE
                    sectors_array[target_write_index] = string.sub(raw_payload, chunk_offset + 1, chunk_offset + SECTOR_SIZE)
                end
            end

            -- Increment sequential tracking bounds trackers dynamically to safeguard non-fragmentation parameters
            accumulated_used_sectors = accumulated_used_sectors + (m.sectors or 1)
            next_free_sector = next_free_sector + (m.sectors or 1)
            next_free_track  = next_free_track + math.floor(next_free_sector / TRACK_SECTORS)
            next_free_sector = next_free_sector % TRACK_SECTORS

            -- Shift pointer positions arrays offsets indices for next catalog loop iteration
            current_catalog_byte_offset = current_catalog_byte_offset + 16
            if current_catalog_byte_offset >= SECTOR_SIZE then
                current_catalog_byte_offset = 0
                current_catalog_sector_idx = current_catalog_sector_idx + 1
            end
        end
    end

    -- [[ STAGE D: SYNTHESIZE SECTOR 9 FROM COMPACT STATE FIELDS ]]
    local orig_sys_sector = sectors_array[SYS_SECTOR_OFFSET / SECTOR_SIZE + 1] or string.rep(string.char(0), SECTOR_SIZE)
    local sys_sec_chars = {}

    for i = 1, SECTOR_SIZE do
        sys_sec_chars[i] = string.sub(orig_sys_sector, i, i)
    end

    -- Write updated metrics according to fresh specification bounds mapping parameters
    sys_sec_chars[0xE1 + 1] = string.char(next_free_sector)
    sys_sec_chars[0xE2 + 1] = string.char(next_free_track)
    sys_sec_chars[0xE3 + 1] = string.char(disk_type)

    -- Flat #files_list length already perfectly contains both active and deleted items slots counters
    sys_sec_chars[0xE4 + 1] = string.char(#files_list)

    -- Geometry-aware free space calculation
    local max_payload_sectors = total_disk_sectors - 16
    local remaining_free_sectors = max_payload_sectors - accumulated_used_sectors
    if remaining_free_sectors < 0 then remaining_free_sectors = 0 end

    sys_sec_chars[0xE5 + 1] = string.char(remaining_free_sectors % 256)
    sys_sec_chars[0xE6 + 1] = string.char(math.floor(remaining_free_sectors / 256) % 256)
    sys_sec_chars[0xE7 + 1] = string.char(0x10) -- TR-DOS signature constant anchor

    sys_sec_chars[0xE8 + 1] = string.char(0x00)
    sys_sec_chars[0xE9 + 1] = string.char(0x00)

    for i = 0xEA, 0xF2 do sys_sec_chars[i + 1] = string.char(0x20) end
    sys_sec_chars[0xF3 + 1] = string.char(0x00)
    sys_sec_chars[0xF4 + 1] = string.char(deleted_qty)

    -- Format and fill the disk name/header token string precisely up to 11 bytes bounds from 0xF5 offset
    local final_label = disk_label
    if string.len(final_label) < 11 then
        final_label = final_label .. string.rep(" ", 11 - string.len(final_label))
    end

    for i = 0xF5, 0xFF do
        local char_byte = string.byte(final_label, i - 0xF5 + 1) or 0x20
        sys_sec_chars[i + 1] = string.char(char_byte)
    end
    -- Put the compiled 9th system sector string right back into the sectors table
    sectors_array[SYS_SECTOR_OFFSET / SECTOR_SIZE + 1] = table.concat(sys_sec_chars)

    -- [[ CRITICAL ARCHITECTURAL GEOMETRY SYNC REFRESH ]]
    if object and object.trd_info then
        object.trd_info.initial_free = remaining_free_sectors
        object.trd_info.next_free_sector = next_free_sector
        object.trd_info.next_free_track  = next_free_track
        object.trd_info.deleted_files    = deleted_qty
    end

    -- [[ STAGE E: FLUSH COMPLETE COMPILED STREAM MAP TO HOST HARD DRIVE ]]
    local file_handle = io.open(archive_path, "wb")
    if not file_handle then return false end

    file_handle:write(table.concat(sectors_array))

    local ds_patch = dir_sys.compile(files_list, object)
    if ds_patch then
        file_handle:seek("set", DS_SECTOR_OFFSET)
        file_handle:write(ds_patch)
    end
    file_handle:close()
    return true
end

return writer
