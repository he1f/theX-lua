local M = {}

function M.concat_entries(entries)
  local chunks = {}
  for i = 1, #entries do
    chunks[#chunks + 1] = entries[i].data or string.rep("\0", entries[i].size or 0)
  end
  return table.concat(chunks)
end

function M.write_file(target_path, data)
  local fp, err = io.open(target_path, "wb")
  if not fp then
    return nil, err
  end

  fp:write(data)
  fp:close()
  return true
end

return M
