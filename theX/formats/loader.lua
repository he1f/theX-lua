local loader = {}

-- [[ Strict sequential pipeline layout execution order constraint ]]
-- 1. SCL and HoBeta readers inspect headers first.
-- 2. RAW reader sits at the very end as the final boundary baseline fallback.
local format_readers = {
    require("theX.formats.scl.reader"),
    require("theX.formats.hobeta.reader"),
    require("theX.formats.raw.reader")
}

--- Sequentially loops through the format registry pipeline to validate and process binary assets.
--- Properly processes format mismatches and bubbles up the final RAW fallback evaluation results.
---@param target_files_list table[] Sequential destination file dictionary array mapping workspace storage
---@param file_path string Absolute filesystem disk path targeting the input binary asset file
---@param object table The active parent plugin panel context mapping states
---@return boolean success Returns true if any format plugin successfully ingested the asset, false otherwise
---@return string|nil error_code The descriptive uppercase validation token string if processing collapses
function loader.load_file(target_files_list, file_path, object)
    if not target_files_list or not file_path or file_path == "" then
        return false, "ERR_CANNOT_OPEN_FILE"
    end

    -- Keep track of the final fallback validation responses to bubble up if all steps mismatch
    local last_err_code = "ERR_CANNOT_OPEN_FILE"

    -- [[ AUTOMATED FORMAT PIPELINE REFRESH ITERATOR ]]
    for _, reader in ipairs(format_readers) do
        local is_matched, validation_error = reader.is_valid(file_path)
        if is_matched then
            -- Success path: the format matches physical markers perfectly. Extract payload data.
            reader.process(target_files_list, file_path, object)
            return true, nil
        end

        -- Cache the verification response. The final step (RAW) will overwrite this parameter,
        -- ensuring we safely surface "ERR_FILE_TOO_LARGE" or "ERR_FILE_TOO_SMALL" boundaries.
        if validation_error then
            last_err_code = validation_error
        end
    end

    -- If the continuous chain runs out of candidates, bubble up the final RAW validator outcome
    return false, last_err_code
end

return loader
