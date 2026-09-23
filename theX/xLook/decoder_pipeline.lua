local pipeline = {}

-- [[ Single global authority registry for all assembler text decoders ]]
local asm_decoders_registry = {
    "alasm",
    "xas",
    "zxasm",
    "masm",
    "masm3",
    "storm",
    "tasm",
    "tasm2",
    "basic"
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

    -- Loop through unified authority table registry
    for _, decoder_name in ipairs(asm_decoders_registry) do
        local success, decoder_class = pcall(require, "theX.xLook." .. decoder_name)
        if success and decoder_class and decoder_class.new then
            local decoder_instance = decoder_class.new(hobeta_bytes, h_type, h_start, h_len)
            local detected, assembler_name = decoder_instance:detect(h_type, h_start)
            if detected then
                local text = decoder_instance:get_text()
                if text then
                    return text, assembler_name or decoder_name
                end
            end
        end
    end
    return nil, nil
end

return pipeline
