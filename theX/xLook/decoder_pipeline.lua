local pipeline = {}

-- [[ Single global authority registry: module path relative to theX.xLook ]]
local decoders_registry = {
    "asm.alasm",
    "asm.xas",
    "asm.zxasm",
    "asm.masm",
    "asm.masm3",
    "asm.storm",
    "asm.tasm",
    "asm.tasm2",
    "basic",
    "ac_edit",
    "trackers.pt3",
    "trackers.st1",
    "trackers.stc",
    "trackers.stp",
    "trackers.ft",
    "trackers.psc",
    "trackers.gt",
    "trackers.sqt",
    "trackers.pt2",
    "trackers.pt1",
    "trackers.asc",
}

--- Universal decoupled pipeline executing search, detection and translation for Z80 text sources.
---@param hobeta_bytes string Monolithic 17-byte header + data sectors stream buffer
---@param m table Target file metadata block tracking parameters
---@return string|nil decoded_text Clean ASCII string payload, or nil if all decoders drop
---@return string|nil assembler_name Official compiler label token string (e.g. "Alasm"), or nil on mismatch
function pipeline.decode_text_stream(hobeta_bytes, m)
    if not hobeta_bytes or not m then return nil, nil end

    local h_type = m.type or "C"
    local h_start = tonumber(m.start) or 0
    local h_len = tonumber(m.size) or 0

    for _, decoder_path in ipairs(decoders_registry) do
        local success, decoder_class = pcall(require, "theX.xLook." .. decoder_path)
        if success and decoder_class and decoder_class.new then
            local decoder_instance = decoder_class.new(hobeta_bytes, h_type, h_start, h_len)
            local detected, detected_name = decoder_instance:detect(h_type, h_start)
            if detected then
                local text = decoder_instance:get_text()
                if text then
                    local short_name = decoder_path:match("([^.]+)$") or decoder_path
                    return text, detected_name or short_name
                end
            end
        end
    end
    return nil, nil
end

return pipeline
