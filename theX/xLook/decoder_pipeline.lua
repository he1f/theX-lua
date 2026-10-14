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

-- Graphics decoders: produce binary image payloads (e.g. GIF).
local gfx_registry = {
    "gfx.screens.lc52",
    "gfx.screens.lc40",
    "gfx.screens.screen_crasher",
    "gfx.gigascreens.hrusted_giga_screen",
    "gfx.gigascreens.giga_screen",
    "gfx.rgb.rgb_888",
    "gfx.rgb.rgb_1in1",
    "gfx.rgb.rgb_2in1",
    "gfx.chunks.chunk_screen",
    "gfx.chunks.packed_chunk_screen",
    "gfx.fonts.rom_font",
    "gfx.fonts.font224",
    "gfx.fonts.font256",
    "gfx.fonts.udg_font",
    "gfx.fonts.font_4x8",
    "gfx.fonts.font_6x7",
    "gfx.sprites.sprite_generator_v5",
    "gfx.sprites.sprite_editor_21",
    "gfx.sprites.sprite_editor_11",
    "gfx.sprites.sprite_maker",
    "gfx.sprites.spwrite_maker",
    "gfx.sprites.ani5",
    "gfx.screens.color_screen",
    "gfx.screens.bw_screen",
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

--- Graphics pipeline: detect screen-like payloads and emit image file bytes.
---@param hobeta_bytes string Body bytes (no hobeta header)
---@param m table File metadata (type/start/size/group)
---@return string|nil image_bytes Encoded image file contents
---@return string|nil type_name Human label (e.g. "Color Screen")
---@return string|nil ext Extension including dot (e.g. ".gif")
function pipeline.decode_image_stream(hobeta_bytes, m)
    if not hobeta_bytes or not m then
        return nil, nil, nil
    end

    local h_type = m.type or "C"
    local h_start = tonumber(m.start) or 0
    local h_len = tonumber(m.size) or 0

    for _, decoder_path in ipairs(gfx_registry) do
        local success, decoder_class = pcall(require, "theX.xLook." .. decoder_path)
        if success and decoder_class and decoder_class.new then
            local decoder_instance = decoder_class.new(hobeta_bytes, h_type, h_start, h_len, m)
            local detected, detected_name = decoder_instance:detect()
            if detected and decoder_instance.get_gif then
                local gif_bytes = decoder_instance:get_gif()
                if gif_bytes and #gif_bytes > 0 then
                    local ext = ".gif"
                    if decoder_instance.output_ext then
                        ext = decoder_instance:output_ext() or ext
                    end
                    return gif_bytes, detected_name or "gfx", ext
                end
            end
        end
    end
    return nil, nil, nil
end

return pipeline
