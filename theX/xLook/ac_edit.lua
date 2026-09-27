local ACEdit = {}
ACEdit.__index = ACEdit

function ACEdit.new(body_bytes, header_type, header_start, header_length)
  local Object = {
    _body = body_bytes or "",
    header_type = header_type,
    header_start = tonumber(header_start) or 0,
  }
  return setmetatable(Object, ACEdit)
end

function ACEdit:detect()
  if self.header_type == "W" and self.header_start == 0 then
    return true, "AC Edit text"
  end
  return false, nil
end

function ACEdit:get_text()
    return string.gsub(self._body, "[\1-\8]", " ")
end

return ACEdit
