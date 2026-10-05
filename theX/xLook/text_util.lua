local text_util = {}

--- Wraps a list of strings with ", " separators up to max_length per line.
---@param items string[]
---@param max_length integer
---@return string
function text_util.join_wrapped(items, max_length)
  local lines = {}
  local current = {}
  local current_len = 0

  for _, s in ipairs(items) do
    local added = (#current > 0) and (#s + 2) or #s
    if current_len + added <= max_length then
      current[#current + 1] = s
      current_len = current_len + added
    else
      if #current > 0 then
        lines[#lines + 1] = table.concat(current, ", ")
      end
      current = { s }
      current_len = #s
    end
  end

  if #current > 0 then
    lines[#lines + 1] = table.concat(current, ", ")
  end
  return table.concat(lines, "\n")
end

--- Formats one order entry: "01" or "01 (+3)" / "01 (-2)".
---@param pattern integer 1-based pattern number for display
---@param transposition integer
---@return string
function text_util.format_order_item(pattern, transposition)
  if transposition == 0 then
    return string.format("%02d", pattern)
  end
  local sign = transposition > 0 and "+" or ""
  return string.format("%02d (%s%d)", pattern, sign, transposition)
end

return text_util
