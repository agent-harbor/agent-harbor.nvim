-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

M.namespace = vim.api.nvim_create_namespace("agent-harbor-timeline")

local function get(value, key)
  if type(value) ~= "table" then
    return nil
  end
  local found = value[key]
  if found == vim.NIL then
    return nil
  end
  return found
end

local function is_byte_array(value)
  if type(value) ~= "table" or #value == 0 then
    return false
  end
  for index, item in ipairs(value) do
    if value[index] ~= item or type(item) ~= "number" or item < 0 or item > 255 or item % 1 ~= 0 then
      return false
    end
  end
  return true
end

local function bytes_to_string(value)
  if type(value) == "string" then
    return value
  end
  if not is_byte_array(value) then
    return nil
  end
  local chunks = {}
  for index, byte in ipairs(value) do
    chunks[index] = string.char(byte)
  end
  return table.concat(chunks)
end

function M.text_field(key, event)
  local value = get(event, key)
  if value == nil then
    return nil
  end
  if type(value) == "string" then
    return value
  end
  local decoded = bytes_to_string(value)
  if decoded then
    return decoded
  end
  if type(value) == "table" then
    return vim.json.encode(value)
  end
  return tostring(value)
end

-- Decode the inner SessionEvent wrapped inside a sub_agent / SubAgent fan-out
-- envelope. The REST API contract serializes the wrapped event as a JSON byte
-- vector (`innerEvent`), so we round-trip it through `bytes_to_string` (which
-- turns `[u8]` payloads back into UTF-8 text) and `vim.json.decode` to recover
-- the original event structure. Returns nil when the field is missing,
-- malformed JSON, or not the expected byte/string shape. Exposed via `M.` so
-- the panel's render layer can also see inner events through sub-agent
-- envelopes (e.g. surfacing reviewer / supervisor text under the parent task
-- timeline).
function M.unwrap_sub_agent(event)
  if type(event) ~= "table" then
    return nil
  end
  local raw = event.innerEvent or event.inner_event
  if raw == nil or raw == vim.NIL then
    return nil
  end
  local json
  if type(raw) == "string" then
    json = raw
  elseif type(raw) == "table" then
    json = bytes_to_string(raw)
    if not json then
      return raw
    end
  end
  if type(json) ~= "string" or json == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, json)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

-- Returns the "effective" event seen by the user. For sub_agent envelopes
-- (fan-out from a child session into the parent task's timeline) this
-- returns the innermost SessionEvent so the rest of the render pipeline acts
-- on the actual agent output ("Review approved", "Supervisor marked …",
-- a file_edit, a tool_use, …). For non-sub_agent events it returns the
-- event unchanged.
function M.effective_event(event)
  if type(event) ~= "table" then
    return event
  end
  local current = event
  for _ = 1, 16 do
    local raw_type = M.text_field("type", current)
    if raw_type ~= "sub_agent" then
      return current
    end
    local inner = M.unwrap_sub_agent(current)
    if not inner then
      return current
    end
    current = inner
  end
  return current
end

function M.event_type(event)
  return M.text_field("type", M.effective_event(event)) or "event"
end

function M.card_type(event)
  local event_type = M.event_type(event)
  if event_type == "file_edit" or event_type == "diff" then
    return "edited"
  end
  if event_type == "file_read" then
    return "read"
  end
  if event_type == "user_input" then
    return "user"
  end
  if event_type == "turn_complete" then
    return "completed"
  end
  if event_type == "tool_use" then
    return "ran"
  end
  return event_type
end

function M.event_file_path(event)
  local effective = M.effective_event(event)
  return M.text_field("file_path", effective) or M.text_field("path", effective)
end

function M.event_timestamp(event)
  local timestamp = get(event, "timestamp")
  if type(timestamp) == "number" then
    return timestamp
  end
  if type(timestamp) == "string" then
    return tonumber(timestamp) or 0
  end
  return 0
end

function M.card_id(session_id, event, index)
  return ("%s:%s:%s:%s"):format(session_id or "", M.event_timestamp(event), M.event_type(event), index)
end

local function joined(parts)
  local out = {}
  for _, item in ipairs(parts) do
    if item and item ~= "" then
      table.insert(out, item)
    end
  end
  return table.concat(out, " ")
end

function M.event_text(event)
  -- Sub-agent events wrap a child session's original SessionEvent so the
  -- parent task's timeline can render fan-out activity inline. Recover the
  -- inner event up-front via `effective_event` so the rendered card text
  -- surfaces the actual agent output ("Review approved",
  -- "Supervisor marked …", a file edit, a tool use, …) instead of an
  -- opaque "sub_agent" placeholder. This is how the editor side panel sees
  -- content from manager → reviewer → supervisor sequential sub-agents,
  -- since each child's session id is registered against a separate task
  -- in the REST `/api/v1/tasks/{id}/sessions` listing.
  local effective = M.effective_event(event)
  local event_type = M.text_field("type", effective) or "event"
  local text
  if event_type == "status" then
    text = "Status: " .. (M.text_field("status", effective) or "unknown")
  elseif event_type == "thought" then
    text = M.text_field("thought", effective) or M.text_field("reasoning", effective) or "Agent reasoning"
  elseif event_type == "tool_use" then
    text = joined({ "Tool started:", M.text_field("tool_name", effective), M.text_field("tool_args", effective) })
  elseif event_type == "tool_result" then
    text = joined({ "Tool finished:", M.text_field("tool_name", effective), M.text_field("tool_output", effective) })
  elseif event_type == "file_edit" then
    text = joined({ "Edited", M.text_field("file_path", effective), M.text_field("description", effective) })
  elseif event_type == "diff" then
    text = joined({ "Edited", M.text_field("path", effective), M.text_field("diff_preview", effective) })
  elseif event_type == "file_read" then
    text = "Read " .. (M.text_field("file_path", effective) or "file")
  elseif event_type == "user_input" then
    text = M.text_field("content", effective) or "User input"
  elseif event_type == "log" then
    text = M.text_field("message", effective) or "Log entry"
  elseif event_type == "error" then
    text = "Error: " .. (M.text_field("message", effective) or "unknown")
  elseif event_type == "orchestration" or event_type == "delegation" or event_type == "sub_agent" then
    text = M.text_field("description", effective) or M.text_field("kind", effective) or event_type
  elseif event_type == "turn_complete" then
    text = "Turn complete: " .. (M.text_field("stop_reason", effective) or "complete")
  else
    text = vim.json.encode(effective)
  end
  return vim.trim(text or "")
end

function M.cards(session_events)
  local cards = {}
  local order = 0
  for _, entry in ipairs(session_events or {}) do
    local session_id = entry.sessionId or entry.session_id or entry[1]
    local events = entry.events or entry[2] or {}
    for index, event in ipairs(events) do
      order = order + 1
      table.insert(cards, {
        id = M.card_id(session_id, event, index),
        sessionId = session_id,
        type = M.card_type(event),
        eventType = M.event_type(event),
        timestamp = M.event_timestamp(event),
        filePath = M.event_file_path(event),
        text = M.event_text(event),
        order = order,
      })
    end
  end
  table.sort(cards, function(left, right)
    if left.timestamp == right.timestamp then
      return left.order < right.order
    end
    return left.timestamp < right.timestamp
  end)
  for _, card in ipairs(cards) do
    card.order = nil
  end
  return cards
end

local function add_wrapped(lines, text, indent)
  indent = indent or "  "
  text = tostring(text or "")
  if text == "" then
    table.insert(lines, indent)
    return
  end
  for part in text:gmatch("[^\n]+") do
    table.insert(lines, indent .. part)
  end
end

function M.render(bufnr, cards)
  local lines = { "Activity Timeline" }
  local extmarks = {}
  if #cards == 0 then
    table.insert(lines, "  No activity yet.")
  else
    for _, card in ipairs(cards) do
      local line_index = #lines
      table.insert(lines, ("> %s  %s"):format(card.type, card.sessionId or ""))
      add_wrapped(lines, card.text, "  ")
      table.insert(lines, "")
      table.insert(extmarks, { line = line_index, card = card })
    end
  end
  return lines, extmarks
end

function M.apply_extmarks(bufnr, extmarks)
  vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
  for _, mark in ipairs(extmarks or {}) do
    local card = mark.card
    local group = "AgentHarborTimelineType"
    if card.eventType == "status" then
      group = "AgentHarborTimelineStatus"
    elseif card.eventType == "error" then
      group = "AgentHarborTimelineError"
    end
    vim.api.nvim_buf_set_extmark(bufnr, M.namespace, mark.line, 0, {
      hl_group = group,
      end_line = mark.line,
      virt_text = { { " " .. (card.eventType or card.type), "AgentHarborTimelineSession" } },
      virt_text_pos = "eol",
    })
  end
end

return M
