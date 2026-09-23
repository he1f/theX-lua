local writer = {}

function writer.save(file_path, hobeta_file_obj)
    local file_handle = io.open(file_path, "wb")
    if not file_handle then return false end

    file_handle:write(hobeta_file_obj.header)
    file_handle:write(hobeta_file_obj.data)
    file_handle:close()
    return true
end

return writer
