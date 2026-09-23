local trd_reader = {}
local hobeta_reader = require("theX.formats.hobeta.reader")
local dir_sys = require("theX.formats.trd.dir_sys")
local settings_manager = require("theX.settings_manager")
local plugin_settings = settings_manager.new("xtrd")


-- [[ TR-DOS Disk Geometry Constants Constraints ]]
local SECTOR_SIZE   = 256
local TRACK_SECTORS = 16
-- Minimum target boundary layout: 40 tracks * 1 side * 16 sectors * 256 bytes = 163840 bytes (160KB)
local MIN_TRD_SIZE  = 40 * 1 * 16 * 256
-- 80 tracks * 2 sides * 16 sectors * 256 bytes = 655360 bytes (Standard double-sided TRD)
local MAX_TRD_SIZE  = 80 * 2 * 16 * 256

--- Instantly fetches file size metadata from OS to reject huge assets before loading memory stack.
---@param trd_path string Absolute physical filesystem path to the target TRD image
---@return boolean is_valid True if the file matches strict TRD container layout boundaries, false otherwise
---@return string|nil error_code The descriptive uppercase validation token string if processing collapses
function trd_reader.is_valid(trd_path)
    local file_handle = io.open(trd_path, "rb")
    if not file_handle then
        return false, "ERR_CANNOT_OPEN_FILE"
    end

    local file_len = file_handle:seek("end")
    file_handle:seek("set", 0)

    -- Reject files that are smaller than a 40-track single-sided disk or larger than an 80-track double-sided disk
    if file_len < MIN_TRD_SIZE then
        file_handle:close()
        return false, "ERR_FILE_TOO_SMALL"
    end

    if file_len > MAX_TRD_SIZE then
        file_handle:close()
        return false, "ERR_FILE_TOO_LARGE"
    end

    -- Read the 9th system sector (Track 0, Sector 8) to verify native TR-DOS signature identity
    -- Offset: 8 sectors * 256 bytes = 2048 bytes (0x800)
    file_handle:seek("set", 2048)
    local sys_sector = file_handle:read(256)
    file_handle:close()

    if not sys_sector or string.len(sys_sector) < 256 then
        return false, "ERR_CORRUPTED_HEADER_CATALOG"
    end

    -- Byte 0xE7 (231 in 1-based index) must strictly contain the constant service marker 0x10
    local trdos_marker = string.byte(sys_sector, 0xE7 + 1)
    if trdos_marker ~= 0x10 then
        return false, "ERR_INVALID_SIGNATURE"
    end

    return true, nil
end

--- Processes a pre-verified physical TRD disk image and unpacks it into clean virtual HoBeta elements array.
---@param target_files_list table[] Sequential destination file dictionary array mapping workspace storage
---@param trd_path string Absolute physical filesystem path to the target TRD image
---@param object table The active parent plugin panel context mapping states
---@return nil
function trd_reader.process(target_files_list, trd_path, object)
    if not target_files_list or not trd_path then return end

    local file_handle = io.open(trd_path, "rb")
    if not file_handle then return end
    local trd_bytes = file_handle:read("*a") or ""
    file_handle:close()

    if string.len(trd_bytes) < 4096 then return end

    if object then
        local sys_sec = string.sub(trd_bytes, 2048 + 1, 2048 + 256)

        -- Extract properties strictly following updated structural map parameters
        local next_free_sector = string.byte(sys_sec, 0xE1 + 1) or 0
        local next_free_track  = string.byte(sys_sec, 0xE2 + 1) or 1

        local disk_type   = string.byte(sys_sec, 0xE3 + 1) or 0x16
        local free_sec_l  = string.byte(sys_sec, 0xE5 + 1) or 0
        local free_sec_h  = string.byte(sys_sec, 0xE6 + 1) or 0
        local deleted_qty = string.byte(sys_sec, 0xF4 + 1) or 0

        -- Extract authentic 11-byte disk header stream from 0xF5 up to 0xFF offsets bounds
        local raw_label   = string.sub(sys_sec, 0xF5 + 1, 0xFF + 1) or string.rep(" ", 11)

        object.trd_info = {
            disk_type        = disk_type,
            deleted_files    = deleted_qty,
            label            = raw_label, -- Safely holds exactly 11 raw authentic bytes
            initial_free     = (free_sec_h * 256) + free_sec_l,
            next_free_sector = next_free_sector,
            next_free_track  = next_free_track
        }
    end

    local total_files_count = string.byte(trd_bytes, 2048 + 0xE4 + 1) or 0
    if total_files_count == 0 then return end

    local processed_files = 0
    for offset = 0, 2047, 16 do
        if processed_files >= total_files_count then break end

        local first_char_byte = string.byte(trd_bytes, offset + 1)
        processed_files = processed_files + 1

        local h_name    = string.sub(trd_bytes, offset + 1, offset + 8)
        local h_type    = string.sub(trd_bytes, offset + 9, offset + 9)
        local st_l      = string.byte(trd_bytes, offset + 10) or 0
        local st_h      = string.byte(trd_bytes, offset + 11) or 0
        local sz_l      = string.byte(trd_bytes, offset + 12) or 0
        local sz_h      = string.byte(trd_bytes, offset + 13) or 0
        local no_secs   = string.byte(trd_bytes, offset + 14) or 0
        local start_sec = string.byte(trd_bytes, offset + 15) or 0
        local start_trk = string.byte(trd_bytes, offset + 16) or 0

        local start_val = (st_h * 256) + st_l
        local size_val  = (sz_h * 256) + sz_l

        local data_start_offset = (start_trk * TRACK_SECTORS + start_sec) * SECTOR_SIZE
        local data_len_bytes    = no_secs * SECTOR_SIZE

        local file_data = ""
        if data_start_offset + data_len_bytes <= string.len(trd_bytes) then
            file_data = string.sub(trd_bytes, data_start_offset + 1, data_start_offset + data_len_bytes)
        end
        local is_deleted = (first_char_byte == 0x01)
        local meta = {
            name    = h_name,
            type    = h_type,
            start   = start_val,
            size    = size_val,
            sectors = no_secs,
            track   = start_trk,
            sector  = start_sec,
            deleted = is_deleted,
        }

        local h_base_15bytes = h_name .. h_type .. string.char(st_l, st_h, sz_l, sz_h, 0, no_secs)
        local header_checksum = hobeta_reader.calculate_crc(h_base_15bytes)
        local compiled_header = h_base_15bytes .. header_checksum

        table.insert(target_files_list, {
            meta   = meta,
            header = compiled_header,
            data   = file_data
        })

    end
    if object then
        local use_dirsys = plugin_settings.get("use_dirsys", true)
        if use_dirsys then
            -- [[ DYNAMICALLY ATTACH THE OPTIONAL DIRSYS SUB-LAYER MATRIX ]]
            local trd_folders, trd_file_maps = dir_sys.parse(trd_bytes)

            if trd_folders and trd_file_maps then
                -- Cache active subdirectories state mappings directly onto the panel object instance!
                object.trd_folders = trd_folders
                object.trd_file_maps = trd_file_maps
            end
        else
            object.trd_folders = nil
            object.trd_file_maps = nil
        end
    end
end

return trd_reader
