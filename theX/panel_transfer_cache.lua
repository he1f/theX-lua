local M = {}

local transfer_payload = nil
local TRANSFER_TTL_SECONDS = 120

local function clone_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, nested_value in pairs(value) do
    out[key] = clone_value(nested_value)
  end
  return out
end

local function is_payload_fresh(payload)
  if type(payload) ~= "table" then
    return false
  end
  local stored_at = tonumber(payload.stored_at)
  if type(stored_at) ~= "number" then
    return false
  end
  local age = os.time() - stored_at
  return age >= 0 and age <= TRANSFER_TTL_SECONDS
end

function M.store(payload)
  if type(payload) ~= "table" then
    transfer_payload = nil
    return nil
  end
  transfer_payload = clone_value(payload)
  transfer_payload.stored_at = os.time()
  return true
end

function M.consume(target_kind)
  local payload = transfer_payload
  transfer_payload = nil
  if not is_payload_fresh(payload) then
    return nil, nil
  end
  local payload_target = payload.target_kind
  if type(target_kind) == "string" and type(payload_target) == "string" and payload_target ~= target_kind then
    return nil, nil
  end
  return clone_value(payload.entries), clone_value(payload)
end

function M.clear()
  transfer_payload = nil
end

return M
