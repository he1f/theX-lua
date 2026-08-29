local M = {}

function M.new(host_file, entries)
  local index_by_name = {}
  for i = 1, #entries do
    index_by_name[entries[i].name] = entries[i]
  end

  return {
    HostFile = host_file,
    Entries = entries,
    IndexByName = index_by_name,
  }
end

function M.to_panel_items(object)
  local out = {}
  for i = 1, #object.Entries do
    local e = object.Entries[i]
    local trdos_name = e.trdos_name or e.name or ""
    local trdos_start = e.trdos_start and tostring(e.trdos_start) or ""
    local trdos_sectors = e.trdos_sectors and tostring(e.trdos_sectors) or ""
    local trdos_format = e.trdos_type_description or ""
    local trdos_comment = e.comment or ""
    local pc_name = e.pc_name or ""
    local file_attributes = e.attributes
    if file_attributes == nil or file_attributes == "" then
      file_attributes = e.file_attributes or 0
    end

    out[#out + 1] = {
      FileName = entry.pc_name or entry.name,
      FileSize = e.size or #(e.data or ""),
      FileAttributes = file_attributes,
      Description = e.is_deleted and "[deleted]" or nil,
      CustomColumnData = {
        e.name or "",
        trdos_start,
        trdos_sectors,
        trdos_format,
        trdos_comment,
        pc_name,
      },
    }
  end
  return out
end

function M.select_entries(object, panel_items)
  local selected = {}
  for i = 1, #panel_items do
    local name = panel_items[i].FileName
    local e = object.IndexByName[name]
    if e then
      selected[#selected + 1] = e
    end
  end
  return selected
end

return M
