-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local accordion = require("agent-harbor.accordion")
local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")
local reply = require("agent-harbor.reply")
local sse = require("agent-harbor.sse")
local timeline = require("agent-harbor.timeline")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  bufnr = nil,
  winid = nil,
  timer = nil,
  tasks = {},
  branches = {},
  task_sessions = {},
  full_sessions = {},
  session_events = {},
  session_history_counts = {},
  task_diff_files = {},
  task_diff_status = {},
  task_feedback = {},
  last_share = nil,
  sse_clients = {},
  sse_event_count = 0,
  refresh_scheduled = false,
  refreshing = false,
  -- Async refresh bookkeeping.
  inflight = 0,
  last_refresh_time = nil,
  tasks_loaded = false,
  diff_loaded = {},
  history_loaded = {},
  live_session_ids = nil,
  spinner_index = 0,
  selected_task_id = nil,
  selected_stream_session_id = nil,
  accordion_collapsed = false,
  last_error = nil,
  -- Newest-last ring of sweep-leaf failures; see `record_rest_failure`.
  rest_errors = {},
  line_map = {},
  render = {
    timeline_cards = {},
    modified_files = {},
  },
}

M.state = state
M.preview_namespace = vim.api.nvim_create_namespace("agent-harbor-preview")

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

local function task_id(task)
  return get(task, "id")
end

local function session_id(session)
  return get(session, "id")
end

local function branch_id(session)
  return get(session, "agentharborfsBranchId") or get(session, "agentharborfs_branch_id")
end

local function branch_metadata_id(branch)
  return get(branch, "id")
end

local function branch_name(branch)
  return get(branch, "name")
end

local function branch_workspace_path(branch)
  return get(branch, "workspacePath") or get(branch, "workspace_path")
end

local function branch_session_id(branch)
  return get(branch, "sessionId") or get(branch, "session_id")
end

local function branch_updated_at(branch)
  return get(branch, "updatedAt") or get(branch, "updated_at") or ""
end

local function session_status(session)
  return get(session, "status") or "unknown"
end

local function latest_event_status_for_session(session)
  local sid = session_id(session)
  if not sid then
    return nil
  end
  local latest_status = nil
  local latest_timestamp = nil
  for _, event in ipairs(state.session_events[sid] or {}) do
    local effective = timeline.effective_event(event)
    if timeline.text_field("type", effective) == "status" then
      local timestamp = timeline.event_timestamp(event)
      if latest_timestamp == nil or timestamp >= latest_timestamp then
        latest_timestamp = timestamp
        latest_status = timeline.text_field("status", effective)
      end
    end
  end
  return latest_status
end

local function effective_session_status(session)
  return latest_event_status_for_session(session) or session_status(session)
end

local function is_active_session(session)
  local status = effective_session_status(session)
  return status == "running" or status == "queued" or status == "provisioning" or status == "paused"
end

local function session_role(session)
  return get(session, "role")
end

local function is_startup_session(session)
  return session_role(session) == "startup"
end

local function normalized_session_role(session)
  local role = session_role(session)
  if type(role) ~= "string" then
    return ""
  end
  return role:gsub("[%-%. ]", "_"):lower()
end

local function session_role_priority(session)
  local role = normalized_session_role(session)
  if role == "implementation" or role == "implementer" then
    return 1
  elseif role == "manager" or role == "manager_agent" then
    return 2
  elseif role == "coordinator" then
    return 3
  elseif role == "reviewer" or role:match("^reviewer_") then
    return 4
  elseif role == "supervisor" then
    return 5
  end
  return 100
end

local function preferred_role_session(sessions, predicate)
  local best = nil
  local best_priority = nil
  for _, session in ipairs(sessions) do
    if predicate == nil or predicate(session) then
      local priority = session_role_priority(session)
      if best == nil or priority < best_priority then
        best = session
        best_priority = priority
      end
    end
  end
  return best
end

local function session_has_timeline(session)
  local sid = session_id(session)
  if not sid then
    return false
  end
  return #(state.session_events[sid] or {}) > 0 or (state.session_history_counts[sid] or 0) > 0
end

local function is_failure_status(status)
  return status == "failed" or status == "cancelled" or status == "stopped"
end

-- `finished` and `reclaimed` are the resource-axis terminal states: the work
-- ended with its resources still held, or released. Terminal but NOT failures,
-- so they belong here and not in `is_failure_status`.
local function is_terminal_status(status)
  return status == "completed"
    or status == "finished"
    or status == "reclaimed"
    or is_failure_status(status)
end

local function task_sessions_for(id)
  return state.task_sessions[id] or {}
end

local function session_ids_for_task(id)
  local ids = {}
  for _, session in ipairs(task_sessions_for(id)) do
    if session_id(session) then
      table.insert(ids, session_id(session))
    end
  end
  return ids
end

local function task_id_for_session(sid)
  for _, task in ipairs(state.tasks) do
    local id = task_id(task)
    for _, session in ipairs(task_sessions_for(id)) do
      if session_id(session) == sid then
        return id
      end
    end
  end
  return nil
end

local function labels_from_full_session(id)
  local session = state.full_sessions[id]
  local task = get(session, "task")
  return get(task, "labels")
end

local function label(labels, key)
  if type(labels) ~= "table" then
    return nil
  end
  return labels[key] or labels[key:gsub("%.", "")]
end

-- Reduce a daemon-supplied title to its first non-empty line. Loop-driver and
-- manager-harness tasks routinely carry multi-line prompts ("# Implementation
-- Task\n\n## Original Task\n…") as the task title fallback, and feeding those
-- straight to `nvim_buf_set_lines` throws an "item contains newlines" error
-- that aborts the entire render pass. The accordion row is a single line by
-- design; truncating to the first line preserves the most informative summary
-- without breaking the buffer write.
local function sanitize_single_line(text)
  if type(text) ~= "string" then
    return text
  end
  local first = text:match("[^\r\n]+")
  return first or text
end

local function task_title(task)
  local id = task_id(task)
  local sessions = id and task_sessions_for(id) or {}
  -- Prefer labels from the full session list, but fall back to the per-task
  -- session summary's own labels. The full session list is bounded by the
  -- daemon, so a task that has accumulated many rows may have its
  -- title-bearing session paged out of it; the per-task `/sessions` summary
  -- is unbounded and carries the same labels.
  local labels = (sessions[1] and labels_from_full_session(session_id(sessions[1])))
    or (sessions[1] and get(sessions[1], "labels"))
    or nil
  return sanitize_single_line(
    label(labels, "agentHarbor.taskTitle")
      or label(labels, "agentHarborTaskTitle")
      or get(task, "prompt")
      or id
  )
end

local function selected_task()
  for _, task in ipairs(state.tasks) do
    if task_id(task) == state.selected_task_id then
      return task
    end
  end
  return state.tasks[1]
end

local function selected_task_id()
  local task = selected_task()
  return task and task_id(task) or nil
end

M.selected_task_id = selected_task_id

local function selected_sessions()
  local id = selected_task_id()
  return id and task_sessions_for(id) or {}
end

local function selected_session_id()
  local sessions = selected_sessions()
  local wanted = state.selected_stream_session_id
  if wanted then
    for _, session in ipairs(sessions) do
      if session_id(session) == wanted then
        return wanted
      end
    end
  end
  local non_startup_sessions = {}
  for _, session in ipairs(sessions) do
    if not is_startup_session(session) then
      table.insert(non_startup_sessions, session)
    end
  end
  for _, session in ipairs(non_startup_sessions) do
    if is_active_session(session) and session_has_timeline(session) then
      return session_id(session)
    end
  end
  for _, session in ipairs(non_startup_sessions) do
    if is_active_session(session) then
      return session_id(session)
    end
  end
  local preferred_with_timeline = preferred_role_session(non_startup_sessions, session_has_timeline)
  if preferred_with_timeline then
    return session_id(preferred_with_timeline)
  end
  for _, session in ipairs(non_startup_sessions) do
    if session_has_timeline(session) then
      return session_id(session)
    end
  end
  local preferred = preferred_role_session(non_startup_sessions, nil)
  if preferred then
    return session_id(preferred)
  end
  if #non_startup_sessions > 0 then
    return session_id(non_startup_sessions[#non_startup_sessions])
  end
  for _, session in ipairs(sessions) do
    if is_active_session(session) then
      return session_id(session)
    end
  end
  if #sessions > 0 then
    return session_id(sessions[#sessions])
  end
  return nil
end

local function selected_branch_id()
  for _, session in ipairs(selected_sessions()) do
    local id = branch_id(session)
    if id then
      return id
    end
  end
  local id = selected_session_id()
  local branch = id and branch_id(state.full_sessions[id]) or nil
  if branch then
    return branch
  end

  local wanted_sessions = {}
  for _, session in ipairs(selected_sessions()) do
    local sid = session_id(session)
    if sid then
      wanted_sessions[sid] = true
    end
  end
  local branches = {}
  for _, candidate in ipairs(state.branches or {}) do
    if wanted_sessions[branch_session_id(candidate)] then
      table.insert(branches, candidate)
    end
  end
  table.sort(branches, function(left, right)
    local left_updated = branch_updated_at(left)
    local right_updated = branch_updated_at(right)
    if left_updated ~= right_updated then
      return right_updated < left_updated
    end
    return tostring(branch_metadata_id(right) or "") < tostring(branch_metadata_id(left) or "")
  end)
  return branches[1] and branch_metadata_id(branches[1]) or nil
end

local function feedback_id(feedback)
  return get(feedback, "id")
end

local function feedback_status(feedback)
  return get(feedback, "status") or "unknown"
end

local function feedback_created_at(feedback)
  return get(feedback, "createdAt") or get(feedback, "created_at") or ""
end

local function pending_feedback_for_task(id)
  local pending = {}
  for _, feedback in ipairs(state.task_feedback[id] or {}) do
    if feedback_status(feedback) == "pending" then
      table.insert(pending, feedback)
    end
  end
  table.sort(pending, function(left, right)
    return feedback_created_at(left) < feedback_created_at(right)
  end)
  return pending[1]
end

M.pending_feedback_for_task = pending_feedback_for_task

local function selected_pending_feedback()
  local id = selected_task_id()
  return id and pending_feedback_for_task(id) or nil
end

local function pending_feedback_task_ids()
  local ids = {}
  for _, task in ipairs(state.tasks) do
    local id = task_id(task)
    if id and pending_feedback_for_task(id) then
      table.insert(ids, id)
    end
  end
  return ids
end

local function event_status(event)
  -- Intentionally DO NOT unwrap sub_agent envelopes here. The task's
  -- overall status is the OUTER task's status, owned by the manager
  -- session that hosts the task in the daemon. Child-session status
  -- transitions (a sub-agent flipping from running to completed and back)
  -- arrive as sub_agent envelopes on the parent's history; folding those
  -- into `task_status` would make the focused-task status oscillate
  -- whenever a late child status event lands, even after the manager's
  -- terminal status has settled. The card-text and modified-files paths
  -- still unwrap envelopes so the timeline surface mirrors all activity.
  if timeline.text_field("type", event) == "status" then
    return timeline.text_field("status", event)
  end
  return nil
end

local function latest_event_status_for_task(id)
  local latest_status = nil
  local latest_timestamp = nil
  for _, session in ipairs(task_sessions_for(id)) do
    local id_for_session = session_id(session)
    for _, event in ipairs(id_for_session and state.session_events[id_for_session] or {}) do
      local status = event_status(event)
      if status then
        local timestamp = timeline.event_timestamp(event)
        if latest_timestamp == nil or timestamp >= latest_timestamp then
          latest_status = status
          latest_timestamp = timestamp
        end
      end
    end
  end
  return latest_status
end

local function task_status(task)
  local id = task_id(task)
  local raw = get(task, "status") or "unknown"
  local event_state = id and latest_event_status_for_task(id) or nil
  if is_failure_status(event_state) then
    return event_state
  end

  local statuses = {}
  for _, session in ipairs(task_sessions_for(id)) do
    table.insert(statuses, session_status(session))
  end
  for _, status in ipairs(statuses) do
    if status == "failed" or status == "cancelled" or status == "stopped" then
      return status
    end
  end
  if is_terminal_status(raw) then
    return raw
  end
  -- A session's own status event may report progress, but it may not finish a
  -- task the daemon still calls unfinished. `latest_event_status_for_task`
  -- folds the status events of EVERY session bound to the task, so in the
  -- window between two loop-driver phases the newest one is the phase that just
  -- ended — and returning it here reported the whole task completed while its
  -- supervisor was still blocked on an unanswered feedback request. Failure
  -- statuses are already handled above and still win.
  if event_state and event_state ~= "completed" then
    return event_state
  end
  for _, status in ipairs(statuses) do
    if status == "running" or status == "provisioning" then
      return "running"
    end
  end
  -- A task is NOT promoted to "completed" just because every session this
  -- panel currently knows about is completed. The daemon owns a task's
  -- lifecycle, and for a loop-driver task that aggregate is wrong in an
  -- ordinary, recurring window: the driver runs one phase session at a time, so
  -- between two phases every session it has started is completed and the next
  -- one does not exist yet. Reading that as completion reported a finished task
  -- while its supervisor was still blocked on an unanswered feedback request,
  -- overriding a daemon that correctly said "running". Trust `raw`; the daemon
  -- already derives completion from sessions where that is sound. See
  -- `issues/2026-10-07-a-live-loop-driver-task-is-reported-completed-between-phases.md`.
  if raw == "pending" then
    for _, status in ipairs(statuses) do
      if status == "completed" then
        return "completed"
      end
    end
  end
  return raw
end

local function event_key(session, event)
  -- For sub_agent envelopes, fingerprint on the inner event so deduping is
  -- driven by the actual fan-out payload (the wrapper duplicates as the
  -- parent's history is re-fetched).
  local effective = timeline.effective_event(event)
  local event_type = timeline.event_type(effective)
  local function field(key)
    return timeline.text_field(key, effective) or ""
  end
  local fields = {}
  if event_type == "status" then
    fields = { field("status") }
  elseif event_type == "workspace" then
    fields = { field("status"), field("mount_path"), field("working_copy_mode"), field("provider"), field("error") }
  elseif event_type == "log" then
    fields = { field("level"), field("message"), field("tool_execution_id") }
  elseif event_type == "thought" then
    fields = { field("thought"), field("reasoning") }
  elseif event_type == "tool_use" then
    fields = { field("tool_name"), field("tool_args"), field("tool_execution_id"), field("status") }
  elseif event_type == "tool_result" then
    fields = { field("tool_name"), field("tool_output"), field("tool_execution_id"), field("status"), field("exit_code") }
  elseif event_type == "file_edit" then
    fields = { field("file_path"), field("lines_added"), field("lines_removed"), field("description") }
  elseif event_type == "file_read" then
    fields = { field("file_path"), field("start_line"), field("end_line") }
  elseif event_type == "diff" then
    fields = { field("path"), field("tool_execution_id"), field("oldText"), field("newText"), field("fullDiffUrl") }
  elseif event_type == "user_input" then
    fields = { field("content"), field("input_type"), field("user_id"), field("user_name") }
  else
    fields = { timeline.event_text(effective) }
  end
  return table.concat({
    session or "",
    tostring(timeline.event_timestamp(event)),
    event_type,
    table.concat(fields, "\31"),
  }, "\30")
end

local function merge_events(id, events)
  local combined = vim.deepcopy(state.session_events[id] or {})
  local seen = {}
  for _, event in ipairs(combined) do
    local key = event_key(id, event)
    seen[key] = (seen[key] or 0) + 1
  end
  local incoming = {}
  for _, event in ipairs(events or {}) do
    local key = event_key(id, event)
    incoming[key] = (incoming[key] or 0) + 1
    if incoming[key] > (seen[key] or 0) then
      seen[key] = (seen[key] or 0) + 1
      table.insert(combined, event)
    end
  end
  local indexed = {}
  for index, event in ipairs(combined) do
    table.insert(indexed, { event = event, order = index })
  end
  table.sort(indexed, function(left, right)
    local left_time = timeline.event_timestamp(left.event)
    local right_time = timeline.event_timestamp(right.event)
    if left_time == right_time then
      return left.order < right.order
    end
    return left_time < right_time
  end)
  local sorted = {}
  for _, entry in ipairs(indexed) do
    table.insert(sorted, entry.event)
  end
  state.session_events[id] = sorted
end

local function history_events(history)
  local events = vim.deepcopy(get(history, "events") or {})
  local out = {}
  for index = #events, 1, -1 do
    table.insert(out, events[index])
  end
  return out
end

local function path_escape_local(value)
  value = tostring(value or "")
  if type(vim.uri_encode) == "function" then
    local ok, encoded = pcall(vim.uri_encode, value, "rfc3986")
    if ok then
      return encoded
    end
  end
  return (value:gsub("([^A-Za-z0-9_.~-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function uri_unescape(value)
  local decoded = tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return decoded
end

local function encode_path_segments(value)
  local segments = {}
  for segment in tostring(value or ""):gmatch("[^/]+") do
    table.insert(segments, path_escape_local(segment))
  end
  return table.concat(segments, "/")
end

local function agentharborfs_uri_from_text(text)
  return tostring(text or ""):match("agentharborfs://[^%s%)%>'\"]+")
end

local function parse_agentharborfs_uri(uri)
  if type(uri) ~= "string" or not uri:find("^agentharborfs://") then
    return nil
  end
  local body = uri:sub(#"agentharborfs://" + 1)
  local parts = {}
  for segment in body:gmatch("[^/]+") do
    table.insert(parts, uri_unescape(segment))
  end
  local branch_ref = parts[1]
  local path_start = 2
  if branch_ref == "branches" then
    branch_ref = parts[2]
    path_start = 3
  end
  if not branch_ref or not parts[path_start] then
    return nil
  end
  local path_parts = {}
  for index = path_start, #parts do
    table.insert(path_parts, parts[index])
  end
  return {
    uri = uri,
    branchRef = branch_ref,
    path = table.concat(path_parts, "/"),
  }
end

-- Rewrite an `agentharborfs://branches/<name>/...` URI embedded in card text to its
-- canonical `agentharborfs://<branch-id>/...` form. Cross-task previews are keyed by
-- branch id, so a card that references another task's branch by NAME must be
-- normalized against the shared `state.branches` cache. Returns the URI
-- unchanged when it is already an id or the branch cannot be resolved yet.
local function normalize_agentharborfs_uri(uri)
  local parsed = parse_agentharborfs_uri(uri)
  if not parsed then
    return uri
  end
  local ref = parsed.branchRef
  for _, branch in ipairs(state.branches or {}) do
    if branch_metadata_id(branch) == ref or branch_name(branch) == ref then
      local id = branch_metadata_id(branch)
      if id and id ~= ref and parsed.path and parsed.path ~= "" then
        return "agentharborfs://" .. path_escape_local(id) .. "/" .. encode_path_segments(parsed.path)
      end
      return uri
    end
  end
  return uri
end

function M.preview_uri_for_card(card, session)
  local explicit = agentharborfs_uri_from_text(card and card.text)
  if explicit then
    return normalize_agentharborfs_uri(explicit)
  end
  local branch = branch_id(session)
  if card and card.type == "edited" and branch and card.filePath then
    return "agentharborfs://" .. path_escape_local(branch) .. "/" .. encode_path_segments(card.filePath)
  end
  return nil
end

local function branch_id_for_task(id)
  for _, session in ipairs(task_sessions_for(id)) do
    local branch = branch_id(session)
    if branch then
      return branch
    end
  end
  for _, sid in ipairs(session_ids_for_task(id)) do
    local full = state.full_sessions[sid]
    local branch = branch_id(full)
    if branch then
      return branch
    end
    for _, candidate in ipairs(state.branches or {}) do
      if branch_session_id(candidate) == sid then
        return branch_metadata_id(candidate)
      end
    end
  end
  return nil
end

local function branch_from_cache(branch_ref)
  for _, branch in ipairs(state.branches or {}) do
    if branch_metadata_id(branch) == branch_ref or branch_name(branch) == branch_ref then
      return branch
    end
  end
  return nil
end

local function branch_for_id_or_name(branch_ref)
  local cached = branch_from_cache(branch_ref)
  if cached then
    return cached
  end
  local ok, branches = pcall(rest.list_branches, daemon.endpoint, { timeout_ms = 5000 })
  if ok and type(branches) == "table" then
    state.branches = branches
    for _, branch in ipairs(branches) do
      if branch_metadata_id(branch) == branch_ref or branch_name(branch) == branch_ref then
        return branch
      end
    end
  end
  return nil
end

local function preview_banner(branch, path)
  return ("AgentHarborFS preview is read-only: %s/%s"):format(branch, path)
end

local function start_sse(id)
  if state.sse_clients[id] or not daemon.endpoint then
    return
  end
  local url = rest.api_base_url(daemon.endpoint) .. "/sessions/" .. rest.path_escape(id) .. "/events"
  state.sse_clients[id] = sse.open(url, function(frame)
    local data = get(frame, "data")
    if type(data) == "table" then
      state.sse_event_count = state.sse_event_count + 1
      merge_events(id, { data })
      M.render()
    end
  end, function() end)
end

local function stop_stale_sse(live_ids)
  for id, client in pairs(state.sse_clients) do
    if not live_ids[id] then
      client:close()
      state.sse_clients[id] = nil
    end
  end
end

local function api_url(...)
  return rest.api_base_url(daemon.endpoint) .. table.concat({ ... })
end

-- Register one outstanding async daemon request.
local function inflight_inc()
  state.inflight = state.inflight + 1
end

-- Mark one async request resolved and finalize the sweep once idle. The render
-- runs on every resolution so the panel converges as responses land; the
-- e2e harness's `vim.wait` pumps the event loop, firing these callbacks.
local function inflight_dec()
  state.inflight = math.max(0, state.inflight - 1)
  if state.refreshing and state.inflight == 0 then
    state.refreshing = false
    state.last_refresh_time = (vim.uv or vim.loop).now()
    stop_stale_sse(state.live_session_ids or {})
  end
  local ok, err = pcall(M.render)
  if not ok then
    state.last_error = tostring(err)
  end
end

-- Keep the reason a sweep leaf failed.
--
-- Swallowing a leaf *failure* is deliberate: one slow or missing endpoint must
-- not strand the whole sweep. Swallowing the leaf's *reason* was not, and it
-- made a panel that never converges impossible to diagnose — a failing
-- `scenario_neovim_share_task` dumped a state carrying `tasksLoaded = false`
-- after fifteen seconds of polling while the daemon's own log proved it had
-- answered twenty-nine `/tasks` fetches, and nothing anywhere recorded what
-- those fetches had replied. The ring is bounded and newest-last, so the
-- timestamps also show the sweep cadence, and it is published in the panel
-- test state: any assertion that dumps that state now names its own cause.
local REST_ERROR_RING_LIMIT = 16

local function record_rest_failure(url, err)
  state.rest_errors = state.rest_errors or {}
  table.insert(state.rest_errors, {
    url = tostring(url),
    error = tostring(err),
    -- `hrtime`, not `uv.now()`: the loop clock is refreshed once per loop
    -- iteration, so it does not advance across a blocking call — and a blocked
    -- main loop is precisely what these timestamps exist to expose.
    atMs = math.floor((vim.uv or vim.loop).hrtime() / 1e6),
  })
  while #state.rest_errors > REST_ERROR_RING_LIMIT do
    table.remove(state.rest_errors, 1)
  end
end

-- Issue an async GET, dispatching the decoded JSON to `on_success`. Failures
-- are swallowed at the leaf (mirroring the former per-call pcall guards) so a
-- single slow/missing endpoint cannot strand the whole sweep, but the reason is
-- always recorded via `record_rest_failure`.
local function async_get(url, on_success)
  inflight_inc()
  rest.get_json_async(url, function(ok, value)
    if ok then
      local handler_ok, handler_err = pcall(on_success, value)
      if not handler_ok then
        state.last_error = tostring(handler_err)
        record_rest_failure(url, handler_err)
      end
    else
      record_rest_failure(url, value)
    end
    inflight_dec()
  end, { timeout_ms = 5000 })
end

local function diff_files_from_response(diff)
  local files = {}
  local untracked = get(diff, "untrackedFiles") or get(diff, "untracked_files") or {}
  for _, file in ipairs(untracked) do
    files[file] = true
  end
  for line in tostring(get(diff, "stat") or ""):gmatch("[^\n]+") do
    local file = line:match("^%s*([^|]-)%s*|")
    if file and file ~= "" then
      files[vim.trim(file)] = true
    end
  end
  local out = {}
  for file in pairs(files) do
    table.insert(out, file)
  end
  table.sort(out)
  return out
end

local function store_diff_files(id, diff)
  if type(diff) ~= "table" then
    state.task_diff_status[id] = { ok = false, error = "daemon diff response was not an object" }
    state.diff_loaded[id] = true
    return
  end
  state.task_diff_files[id] = diff_files_from_response(diff)
  state.task_diff_status[id] = { ok = true, error = nil }
  state.diff_loaded[id] = true
end

local function refresh_diff_files(id)
  async_get(api_url("/tasks/", rest.path_escape(id), "/diff"), function(diff)
    store_diff_files(id, diff)
  end)
end

local function refresh_feedback(id)
  async_get(api_url("/tasks/", rest.path_escape(id), "/feedback"), function(json)
    state.task_feedback[id] = (type(json) == "table" and get(json, "items")) or {}
  end)
end

-- Async deep-refresh of a single focused task: pulls its sessions, diff,
-- feedback, and each session's history / branches into the local store via
-- non-blocking GETs. Expensive (5-7 REST round-trips per call), so the sweep
-- only runs it for the focused task to keep the panel responsive on daemons
-- that host many task records (the loop driver alone creates one sub-task per
-- role per iteration, and a PLANNING strategy run can easily expand the
-- per-tenant task count by an order of magnitude).
local function deep_refresh_sessions(id, sessions)
  state.task_sessions[id] = sessions
  refresh_diff_files(id)
  refresh_feedback(id)
  for _, session in ipairs(sessions) do
    local sid = session_id(session)
    if sid then
      if state.live_session_ids then
        state.live_session_ids[sid] = true
      end
      async_get(
        api_url("/sessions/", rest.path_escape(sid), "/events/history?limit=", tostring(config.get().panel.history_limit)),
        function(history)
          state.session_history_counts[sid] = get(history, "total_count") or 0
          state.history_loaded[sid] = true
          merge_events(sid, history_events(history))
        end
      )
      start_sse(sid)
    end
  end
end

local function deep_refresh_task(id)
  if not id then
    return
  end
  async_get(api_url("/tasks/", rest.path_escape(id), "/sessions"), function(json)
    local sessions = (type(json) == "table" and get(json, "sessions")) or {}
    deep_refresh_sessions(id, sessions)
  end)
end

-- Load just enough of a non-focused task for cross-task previews: one
-- `/sessions` summary GET plus a single history GET per session, and nothing
-- else. `timeline_cards()` surfaces a foreign task's preview-bearing cards (an
-- `edited` card resolves to `agentharborfs://<branch-id>/<path>`) into the focused
-- timeline, but only once that task's session ids and history are in the local
-- store. The focused-only `deep_refresh_task` never touches non-focused rows,
-- so without this trimmed pass the cross-task preview card never materialises.
-- Branch ids resolve from the shared `state.branches` cache, so this omits the
-- per-task diff / feedback / SSE fan-out the focused deep-refresh pays.
local function preview_refresh_task(id)
  if not id then
    return
  end
  async_get(api_url("/tasks/", rest.path_escape(id), "/sessions"), function(json)
    local sessions = (type(json) == "table" and get(json, "sessions")) or {}
    state.task_sessions[id] = sessions
    for _, session in ipairs(sessions) do
      local sid = session_id(session)
      if sid then
        async_get(
          api_url(
            "/sessions/",
            rest.path_escape(sid),
            "/events/history?limit=",
            tostring(config.get().panel.history_limit)
          ),
          function(history)
            state.session_history_counts[sid] = get(history, "total_count") or 0
            state.history_loaded[sid] = true
            merge_events(sid, history_events(history))
          end
        )
      end
    end
  end)
end

function M.refresh()
  -- Daemon discovery is a fast local PID-file handshake; keep it synchronous so
  -- the connected/disconnected gate is decided before any REST work is issued.
  local ok, err = pcall(daemon.refresh)
  if not ok then
    state.last_error = tostring(err)
  end

  if daemon.state ~= "connected" or not daemon.endpoint then
    local rendered, render_err = pcall(M.render)
    if not rendered then
      state.last_error = tostring(render_err)
    end
    return
  end

  -- Re-entrancy guard: while a sweep is settling, just re-render with whatever
  -- has landed instead of launching a duplicate, double-counted request set.
  if state.refreshing then
    local rendered, render_err = pcall(M.render)
    if not rendered then
      state.last_error = tostring(render_err)
    end
    return
  end

  state.last_error = nil
  state.refreshing = true
  state.live_session_ids = {}
  -- Hold the inflight count above zero across the whole sweep setup so an
  -- early-resolving leaf cannot finalize the sweep before later requests are
  -- even issued. The stores are NOT cleared up-front: each focused-task entry
  -- and full-session row is overwritten in place as fresh responses land, so a
  -- mid-sweep state read (the e2e poll loops read between refreshes) never sees
  -- the focused task momentarily stripped of its sessions / branches.
  inflight_inc()

  -- The focused task id usually carries over from the previous sweep, so kick
  -- off its deep-refresh immediately and in parallel with the `/tasks` list
  -- fetch rather than chaining behind it. This halves the sweep's critical
  -- path (tasks -> sessions -> history becomes sessions||tasks -> history),
  -- which matters under heavy load where each round-trip nears the 5 s ceiling:
  -- a faster sweep lets the focused session's event count keep advancing
  -- between the e2e poll loop's stability ticks instead of plateauing while a
  -- single long sweep is still in flight.
  local primed_focus = state.selected_task_id
  if primed_focus then
    deep_refresh_task(primed_focus)
  end

  async_get(api_url("/branches"), function(json)
    state.branches = (type(json) == "table" and get(json, "branches")) or {}
  end)

  async_get(api_url("/tasks"), function(json)
    state.tasks = (type(json) == "table" and get(json, "tasks")) or {}
    state.tasks_loaded = true
    -- Only auto-focus the first task when nothing is selected yet (initial
    -- open). Do NOT steal focus from an explicit selection just because it is
    -- momentarily absent from an in-flight `/tasks` response — a just-created
    -- task may not appear in a list fetched a beat earlier, and drifting focus
    -- to the first row (a loop-driver sub-agent task) was the new-task-flow
    -- regression.
    if state.selected_task_id == nil then
      state.selected_task_id = state.tasks[1] and task_id(state.tasks[1]) or nil
    end
    -- Deep-refresh the focused task unless we already primed the very same one
    -- above (avoid a duplicate fan-out). A selection change here still triggers
    -- the deep-refresh for the new focus.
    if state.selected_task_id and state.selected_task_id ~= primed_focus then
      deep_refresh_task(state.selected_task_id)
    end
    -- Lightly load non-focused tasks so their cross-task preview cards (another
    -- task's branch referenced via the agentharborfs scheme) can surface in the
    -- focused timeline. Trimmed pass (sessions + history only).
    for _, task in ipairs(state.tasks) do
      local tid = task_id(task)
      if tid and tid ~= state.selected_task_id then
        preview_refresh_task(tid)
      end
    end
  end)

  async_get(api_url("/sessions?perPage=100"), function(json)
    local items = (type(json) == "table" and get(json, "items")) or {}
    for _, session in ipairs(items) do
      if session_id(session) then
        state.full_sessions[session_id(session)] = session
      end
    end
  end)

  -- Release the setup hold; if everything above already resolved, this
  -- finalizes the sweep.
  inflight_dec()
end

local function timeline_session_events()
  local entries = {}
  local sid = selected_session_id()
  if sid then
    table.insert(entries, { sessionId = sid, events = state.session_events[sid] or {} })
  end
  return entries
end

local function channel_routing_indicator()
  local route = nil
  for _, session in ipairs(selected_sessions()) do
    local sid = session_id(session)
    if sid then
      for _, event in ipairs(state.session_events[sid] or {}) do
        -- Presence-change / notification-route signals can arrive as
        -- log/tool_output payloads inside a sub_agent envelope (child
        -- session's own messages). Unwrap before extracting the indicator
        -- text so the focused task header surfaces the live route.
        local effective = timeline.effective_event(event)
        local message = timeline.text_field("message", effective) or timeline.event_text(effective)
        if message then
          local channel = tostring(message):match('presence change:.*active_channel: "([^"]+)"')
            or tostring(message):match("notification_route=([%w_-]+)")
          if channel then
            route = channel
          end
        end
      end
    end
  end
  if not route then
    return nil
  end
  return "Notifications routed to: " .. route:gsub("^%l", string.upper)
end

local function timeline_cards()
  local selected = selected_task_id()
  local cards = {}
  for _, task in ipairs(state.tasks) do
    local id = task_id(task)
    local is_selected = id == selected
    for _, session in ipairs(task_sessions_for(id)) do
      local sid = session_id(session)
      local render_session = not is_selected or sid == selected_session_id()
      local session_cards = timeline.cards({
        { sessionId = sid, events = render_session and sid and state.session_events[sid] or {} },
      })
      for _, card in ipairs(session_cards) do
        card.sourceTaskId = id
        card.branchId = branch_id(session) or branch_id_for_task(id)
        card.previewUri = M.preview_uri_for_card(card, { agentharborfsBranchId = card.branchId })
        if is_selected or card.previewUri then
          card.__order = #cards + 1
          table.insert(cards, card)
        end
      end
    end
  end
  table.sort(cards, function(left, right)
    if left.timestamp == right.timestamp then
      return (left.__order or 0) < (right.__order or 0)
    end
    return left.timestamp < right.timestamp
  end)
  for _, card in ipairs(cards) do
    card.__order = nil
  end
  return cards
end

local function modified_files()
  local files = {}
  for _, session in ipairs(selected_sessions()) do
    local sid = session_id(session)
    for _, event in ipairs(sid and state.session_events[sid] or {}) do
      -- Unwrap sub_agent envelopes so a child session's file_edit / diff
      -- events still register as modified files under the parent task.
      local effective = timeline.effective_event(event)
      local event_type = timeline.event_type(effective)
      local file = nil
      if event_type == "file_edit" then
        file = timeline.text_field("file_path", effective)
      elseif event_type == "diff" then
        file = timeline.text_field("path", effective)
      end
      if file then
        files[file] = true
      end
    end
  end
  local selected = selected_task_id()
  for _, file in ipairs(selected and state.task_diff_files[selected] or {}) do
    files[file] = true
  end
  local out = {}
  for file in pairs(files) do
    table.insert(out, file)
  end
  table.sort(out)
  return out
end

local function selected_task_diff_status()
  local selected = selected_task_id()
  if not selected then
    return { ok = false, error = nil }
  end
  return state.task_diff_status[selected] or { ok = false, error = "daemon diff was not fetched" }
end

local function selected_task_diff_files()
  local selected = selected_task_id()
  return selected and state.task_diff_files[selected] or {}
end

local function add_line(lines, text, meta)
  -- `nvim_buf_set_lines` rejects any element that contains embedded `\n`,
  -- and a single bad line aborts the entire render. Daemon-supplied strings
  -- (task prompts, diff error messages, last-error stack traces) can be
  -- multi-line, so split them here defensively. Only the FIRST inserted line
  -- carries the `meta` (task_id, action handler, …) because subsequent
  -- continuation lines belong logically to the same row.
  text = tostring(text or "")
  if text:find("[\r\n]") then
    local first = true
    for part in text:gmatch("[^\r\n]+") do
      table.insert(lines, part)
      if first and meta then
        state.line_map[#lines] = meta
      end
      first = false
    end
    if first then
      table.insert(lines, "")
      if meta then
        state.line_map[#lines] = meta
      end
    end
  else
    table.insert(lines, text)
    if meta then
      state.line_map[#lines] = meta
    end
  end
end

local function render_task_row(lines, task, selected)
  local id = task_id(task)
  local pending_feedback = id and pending_feedback_for_task(id) or nil
  add_line(lines, ("%s %s  %s"):format(selected and "*" or " ", task_status(task), task_title(task)), { task_id = id })
  if pending_feedback then
    state.line_map[#lines].pending_feedback = true
  end
  add_line(lines, ("    task: %s"):format(id or ""))
  local sessions = session_ids_for_task(id)
  if #sessions > 0 then
    add_line(lines, ("    sessions: %s"):format(table.concat(sessions, ", ")))
  end
  local branches = {}
  local seen = {}
  for _, session in ipairs(task_sessions_for(id)) do
    local branch = branch_id(session)
    if branch and not seen[branch] then
      seen[branch] = true
      table.insert(branches, branch)
    end
  end
  if #branches > 0 then
    add_line(lines, ("    branches: %s"):format(table.concat(branches, ", ")))
  end
end

local function feedback_question(feedback)
  return get(feedback, "question") or "Response required"
end

local function feedback_type(feedback)
  return get(feedback, "type") or "question"
end

local function render_feedback_banner(lines, task_id_for_feedback, feedback)
  add_line(
    lines,
    "Feedback required: " .. feedback_question(feedback),
    { feedback_banner = true, task_id = task_id_for_feedback, feedback_id = feedback_id(feedback) }
  )
  add_line(
    lines,
    ("Feedback: %s  Task: %s"):format(feedback_id(feedback) or "", task_id_for_feedback or ""),
    { feedback_banner = true, task_id = task_id_for_feedback, feedback_id = feedback_id(feedback) }
  )
  if feedback_type(feedback) == "confirmation" then
    add_line(lines, "Actions: [Approve] [Reject]", {
      feedback_banner = true,
      task_id = task_id_for_feedback,
      feedback_id = feedback_id(feedback),
      quick_actions = true,
    })
  end
end

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function spinner_frame()
  return SPINNER_FRAMES[(state.spinner_index % #SPINNER_FRAMES) + 1]
end

local function last_refresh_seconds_ago()
  if not state.last_refresh_time then
    return nil
  end
  local now = (vim.uv or vim.loop).now()
  return math.max(0, math.floor((now - state.last_refresh_time) / 1000))
end

local function retry_seconds()
  return math.max(1, math.floor((config.get().daemon.poll_interval_ms or 1000) / 1000))
end

-- Balanced daemon status line: an animated spinner while requests are in
-- flight, a "updated Ns ago" idle line when connected, and a retry/backoff
-- line when disconnected.
local function daemon_progress_line()
  if daemon.state == "connected" then
    if state.inflight > 0 then
      return ("Daemon: connected   %s refreshing…"):format(spinner_frame())
    end
    local ago = last_refresh_seconds_ago()
    if ago then
      return ("Daemon: connected · updated %ds ago"):format(ago)
    end
    return "Daemon: connected"
  elseif daemon.state == "starting" then
    return ("Daemon: connecting   %s"):format(spinner_frame())
  end
  return ("Daemon: unreachable — retrying in %ds"):format(retry_seconds())
end

local function submitting_now()
  local entry_ok, entry = pcall(function()
    return require("agent-harbor.task-entry").test_state()
  end)
  if entry_ok and entry and entry.submitting == true then
    return true
  end
  local reply_ok, reply_state = pcall(function()
    return require("agent-harbor.reply").test_state()
  end)
  if reply_ok and reply_state and reply_state.submitting == true then
    return true
  end
  return false
end

function M.render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  -- Advance the animated spinner on every render while requests are in flight
  -- so the in-flight indicator visibly cycles even during a long sweep.
  if state.inflight > 0 then
    state.spinner_index = state.spinner_index + 1
  end
  state.line_map = {}
  local lines = {}
  add_line(lines, "Agent Harbor")
  add_line(lines, "")
  add_line(lines, ("Daemon: AH %s %s"):format((config.get().statusline.icons[daemon.state] or ""), daemon.state))
  add_line(lines, daemon_progress_line())
  if state.last_error then
    add_line(lines, "Error: " .. state.last_error)
  end
  if submitting_now() then
    add_line(lines, "Submitting…")
  end
  add_line(lines, "Help: [Docs]", { docs_action = true })
  add_line(lines, "")
  add_line(lines, accordion.header(state.accordion_collapsed, #state.tasks), { accordion_header = true })
  if state.accordion_collapsed then
    local task = selected_task()
    if task then
      add_line(lines, "  " .. (task_title(task) or ""))
    end
  elseif #state.tasks == 0 then
    add_line(lines, state.tasks_loaded and "  No active tasks." or "  Loading tasks…")
  else
    for _, task in ipairs(state.tasks) do
      render_task_row(lines, task, task_id(task) == selected_task_id())
    end
  end
  add_line(lines, "")

  local task = selected_task()
  if task then
    add_line(lines, "Focused: " .. (task_title(task) or ""))
    add_line(lines, "Status: " .. task_status(task))
    add_line(lines, "Task: " .. (task_id(task) or ""))
    if selected_session_id() then
      add_line(lines, "Session: " .. selected_session_id())
    end
    if selected_branch_id() then
      add_line(lines, "Branch: " .. selected_branch_id())
    end
    add_line(lines, "Actions: [Share Task] [Reply] [New Task]", { task_id = task_id(task), share_action = true })
  else
    add_line(lines, "Focused: none")
  end

  local feedback = selected_pending_feedback()
  if task and feedback then
    add_line(lines, "")
    render_feedback_banner(lines, task_id(task), feedback)
  end

  add_line(lines, "")
  add_line(lines, "Modified Files")
  local diff_status = selected_task_diff_status()
  if diff_status.error then
    add_line(lines, "  Daemon diff error: " .. diff_status.error)
  end
  state.render.modified_files = modified_files()
  local selected_id_for_diff = selected_task_id()
  local diff_known = selected_id_for_diff and state.diff_loaded[selected_id_for_diff] or false
  if #state.render.modified_files > 0 then
    for _, file in ipairs(state.render.modified_files) do
      add_line(lines, "  " .. file)
    end
  elseif diff_known then
    add_line(lines, "  None")
  else
    add_line(lines, "  Loading…")
  end
  add_line(lines, "")

  state.render.timeline_cards = timeline_cards()
  local selected_sid_for_history = selected_session_id()
  local history_known = (not selected_sid_for_history)
    or state.history_loaded[selected_sid_for_history]
  if #state.render.timeline_cards == 0 and not history_known then
    add_line(lines, "Loading activity…")
  end
  local timeline_lines, extmarks = timeline.render(state.bufnr, state.render.timeline_cards)
  local timeline_start = #lines
  for _, line in ipairs(timeline_lines) do
    add_line(lines, line)
  end
  for _, mark in ipairs(extmarks) do
    mark.line = mark.line + timeline_start
    if mark.card and mark.card.previewUri then
      state.line_map[mark.line + 1] = {
        preview_card = true,
        card = mark.card,
      }
    end
  end

  local cursor = nil
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    cursor = vim.api.nvim_win_get_cursor(state.winid)
  end
  vim.bo[state.bufnr].readonly = false
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].readonly = true
  timeline.apply_extmarks(state.bufnr, extmarks)
  for line, meta in pairs(state.line_map) do
    if meta.pending_feedback then
      vim.api.nvim_buf_set_extmark(state.bufnr, timeline.namespace, line - 1, 0, {
        line_hl_group = "AgentHarborFeedbackTaskRow",
      })
    elseif meta.feedback_banner then
      vim.api.nvim_buf_set_extmark(state.bufnr, timeline.namespace, line - 1, 0, {
        line_hl_group = meta.quick_actions and "AgentHarborFeedbackAction" or "AgentHarborFeedbackBanner",
      })
    end
  end
  reply.render_overlay(state.winid, selected_task_id(), feedback)
  if cursor and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_set_cursor(state.winid, { math.min(cursor[1], math.max(1, #lines)), cursor[2] })
  end
end

local function open_window(bufnr)
  local opts = config.get().panel
  if opts.mode == "float" or opts.mode == "floating" then
    local f = opts.floating
    local width = math.max(40, math.floor(vim.o.columns * f.width))
    local height = math.max(12, math.floor(vim.o.lines * f.height))
    return vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor(vim.o.lines * f.row),
      col = math.floor(vim.o.columns * f.col),
      style = "minimal",
      border = f.border,
    })
  end

  if opts.side == "left" then
    vim.cmd("topleft vertical " .. tostring(opts.width) .. "new")
  else
    vim.cmd("botright vertical " .. tostring(opts.width) .. "new")
  end
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_width(0, opts.width)
  return vim.api.nvim_get_current_win()
end

function M.open()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    else
      state.winid = open_window(state.bufnr)
    end
  else
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, "Agent Harbor")
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.bo[state.bufnr].swapfile = false
    vim.bo[state.bufnr].filetype = "agent-harbor"
    state.winid = open_window(state.bufnr)
  end
  vim.wo[state.winid].wrap = true
  vim.wo[state.winid].foldmethod = "manual"
  vim.wo[state.winid].foldenable = true
  daemon.start_monitor()
  M.start_refresh()
  M.refresh()
  return state.bufnr
end

function M.start_refresh()
  if state.timer then
    return state.timer
  end
  state.timer = uv.new_timer()
  state.timer:start(config.get().panel.refresh_interval_ms, config.get().panel.refresh_interval_ms, function()
    if state.refresh_scheduled or state.refreshing then
      return
    end
    state.refresh_scheduled = true
    vim.schedule(function()
      state.refresh_scheduled = false
      if state.timer then
        M.refresh()
      end
    end)
  end)
  return state.timer
end

function M.stop_refresh()
  state.refresh_scheduled = false
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  for id, client in pairs(state.sse_clients) do
    client:close()
    state.sse_clients[id] = nil
  end
end

function M.toggle_accordion()
  state.accordion_collapsed = not state.accordion_collapsed
  M.render()
end

function M.open_accordion()
  state.accordion_collapsed = false
  M.render()
end

function M.close_accordion()
  state.accordion_collapsed = true
  M.render()
end

-- Resolve the branch backing task ID from already-loaded data (the task's
-- session summaries carry agentharborfsBranchId; otherwise match the cached branch
-- list by session). Returns nil when nothing is loaded yet.
local function branch_id_for_task(id)
  local sessions = task_sessions_for(id)
  for _, session in ipairs(sessions) do
    local bid = branch_id(session)
    if bid then
      return bid
    end
  end
  local wanted = {}
  for _, session in ipairs(sessions) do
    local sid = session_id(session)
    if sid then
      wanted[sid] = true
    end
  end
  local candidates = {}
  for _, candidate in ipairs(state.branches or {}) do
    if wanted[branch_session_id(candidate)] then
      table.insert(candidates, candidate)
    end
  end
  table.sort(candidates, function(left, right)
    local left_updated = branch_updated_at(left)
    local right_updated = branch_updated_at(right)
    if left_updated ~= right_updated then
      return right_updated < left_updated
    end
    return tostring(branch_metadata_id(right) or "") < tostring(branch_metadata_id(left) or "")
  end)
  return candidates[1] and branch_metadata_id(candidates[1]) or nil
end

function M.select_task(id)
  if not id then
    return
  end
  state.selected_task_id = id
  state.selected_stream_session_id = nil
  state.accordion_collapsed = false
  M.refresh()

  -- Reroot the workspace to the target task's branch WITHOUT blocking the
  -- editor loop. The async refresh above does not synchronously populate this
  -- task's sessions / the branch list, so resolve them on demand via
  -- non-blocking GETs and fire workspace.focus (which runs the modified-buffer
  -- switch policy / prompt) from the callbacks once the branch is known. A
  -- previous synchronous hydration here could freeze the editor for several
  -- seconds per call under load.
  local function do_focus(branch)
    if not branch then
      return
    end
    local ok, err = pcall(require("agent-harbor.workspace").focus, id, { branch_id = branch })
    if not ok then
      state.last_error = tostring(err)
    end
  end

  local branch = branch_id_for_task(id)
  if branch then
    do_focus(branch)
    return
  end

  rest.get_json_async(api_url("/tasks/", rest.path_escape(id), "/sessions"), function(ok, json)
    if ok and type(json) == "table" then
      state.task_sessions[id] = get(json, "sessions") or {}
    end
    local resolved = branch_id_for_task(id)
    if resolved then
      do_focus(resolved)
      return
    end
    if state.branches and #state.branches > 0 then
      return
    end
    rest.get_json_async(api_url("/branches"), function(ok2, json2)
      if ok2 and type(json2) == "table" then
        state.branches = get(json2, "branches") or {}
      end
      do_focus(branch_id_for_task(id))
    end, { timeout_ms = 5000 })
  end, { timeout_ms = 5000 })
end

function M.focus_task_session(id, session_id_value, sessions)
  if not id then
    return nil
  end
  state.selected_task_id = id
  state.task_sessions[id] = sessions or state.task_sessions[id] or {}
  state.selected_stream_session_id = nil
  state.accordion_collapsed = false
  M.refresh()
  for _, sid in ipairs(session_ids_for_task(id)) do
    if sid == session_id_value then
      state.selected_stream_session_id = session_id_value
      M.render()
      return session_id_value
    end
  end
  return nil
end

function M.select_stream(session_id_value)
  for _, sid in ipairs(session_ids_for_task(selected_task_id())) do
    if sid == session_id_value then
      state.selected_stream_session_id = session_id_value
      M.render()
      return session_id_value
    end
  end
  error("Session " .. tostring(session_id_value) .. " is not part of the selected task")
end

local function set_preview_buffer_state(bufnr, branch_id_value, path, root)
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].agent_harbor_preview = true
  vim.b[bufnr].agent_harbor_preview_branch_id = branch_id_value
  vim.b[bufnr].agent_harbor_preview_path = path
  vim.b[bufnr].agent_harbor_preview_root = root
  vim.b[bufnr].agent_harbor_preview_banner = preview_banner(branch_id_value, path)
  vim.api.nvim_buf_clear_namespace(bufnr, M.preview_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, M.preview_namespace, 0, 0, {
    virt_lines = { { { vim.b[bufnr].agent_harbor_preview_banner, "AgentHarborPreviewBanner" } } },
    virt_lines_above = true,
  })
end

local function clear_preview_buffer_state(bufnr)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.b[bufnr].agent_harbor_preview = nil
  vim.b[bufnr].agent_harbor_preview_branch_id = nil
  vim.b[bufnr].agent_harbor_preview_path = nil
  vim.b[bufnr].agent_harbor_preview_root = nil
  vim.b[bufnr].agent_harbor_preview_banner = nil
  vim.api.nvim_buf_clear_namespace(bufnr, M.preview_namespace, 0, -1)
end

local function open_preview_window(file, root, branch_id_value, path, mode)
  if mode == "preview" or mode == nil then
    local width = math.max(48, math.floor(vim.o.columns * 0.72))
    local height = math.max(10, math.floor(vim.o.lines * 0.68))
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    local winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = "minimal",
      border = "single",
    })
    vim.api.nvim_win_call(winid, function()
      vim.cmd("lcd " .. vim.fn.fnameescape(root))
    end)
    set_preview_buffer_state(bufnr, branch_id_value, path, root)
    return bufnr, winid
  elseif mode == "new-tab" then
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(root))
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  elseif mode == "new-frame" then
    error("agent-harbor cross_task_files mode 'new-frame' is not supported by Neovim")
  else
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  end
  local bufnr = vim.api.nvim_get_current_buf()
  clear_preview_buffer_state(bufnr)
  return bufnr, vim.api.nvim_get_current_win()
end

function M.open_card_preview(card)
  if not card or not card.previewUri then
    return nil
  end
  local parsed = parse_agentharborfs_uri(card.previewUri)
  if not parsed then
    error("unable to parse AgentHarborFS preview URI: " .. tostring(card.previewUri))
  end
  local branch = branch_for_id_or_name(parsed.branchRef)
  local branch_id_value = branch and get(branch, "id") or nil
  local root = branch and branch_workspace_path(branch) or nil
  if not branch_id_value or not root then
    error("unable to resolve AgentHarborFS branch for preview URI: " .. tostring(card.previewUri))
  end
  local file = vim.fs.joinpath(root, parsed.path)
  local mode = config.get().cross_task_files or "preview"
  if mode == "switch" then
    local source_task = card.sourceTaskId or task_id_for_session(card.sessionId)
    if source_task then
      require("agent-harbor.workspace").focus(source_task, { branch_id = branch_id_value })
      state.selected_task_id = source_task
      state.accordion_collapsed = false
      M.render()
    end
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local bufnr = vim.api.nvim_get_current_buf()
    clear_preview_buffer_state(bufnr)
    return bufnr, vim.api.nvim_get_current_win()
  end
  return open_preview_window(file, root, branch_id_value, parsed.path, mode)
end

function M.open_preview_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local meta = state.line_map[row]
  if meta and meta.preview_card and meta.card then
    M.open_card_preview(meta.card)
    return true
  end
  return false
end

function M.select_task_at_cursor()
  if M.open_preview_at_cursor() then
    return
  end
  if state.accordion_collapsed then
    accordion.select_with_ui(state.tasks, task_title, task_id, M.select_task)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local meta = state.line_map[row]
  if meta and meta.docs_action then
    vim.cmd("AgentHarborDocs")
  elseif meta and meta.share_action then
    M.share_task(meta.task_id)
  elseif meta and meta.task_id then
    M.select_task(meta.task_id)
  elseif meta and meta.accordion_header then
    M.toggle_accordion()
  else
    accordion.select_with_ui(state.tasks, task_title, task_id, M.select_task)
  end
end

function M.quick_approve(comment)
  return reply.quick_approve(comment)
end

function M.quick_reject(comment)
  return reply.quick_reject(comment)
end

function M.share_task(id, ttl)
  local target_task_id = id or selected_task_id()
  if not target_task_id then
    error("No Agent Harbor task is selected")
  end
  local branch = branch_id_for_task(target_task_id)
  if not branch then
    error("Task " .. target_task_id .. " does not have an AgentHarborFS branch to share")
  end
  local response = rest.create_agentharborfs_share(daemon.endpoint, branch, "branch", ttl or "24h")
  local url = response and response.url or nil
  if type(url) ~= "string" or url == "" then
    error("Share response did not include a URL")
  end
  vim.fn.setreg('"', url)
  pcall(vim.fn.setreg, "+", url)
  state.last_share = {
    taskId = target_task_id,
    branchId = branch,
    scope = "branch",
    ttl = ttl or "24h",
    url = url,
    response = response,
  }
  vim.notify("Agent Harbor share URL copied", vim.log.levels.INFO)
  return url
end

function M.side_panel_state()
  local tasks = {}
  for _, task in ipairs(state.tasks) do
    local id = task_id(task)
    local session_ids = {}
    local branch_ids = {}
    local seen_branches = {}
    local seen_sessions = {}
    for _, session in ipairs(task_sessions_for(id)) do
      local sid = session_id(session)
      table.insert(session_ids, sid)
      if sid then
        seen_sessions[sid] = true
      end
      local branch = branch_id(session)
      if branch and not seen_branches[branch] then
        seen_branches[branch] = true
        table.insert(branch_ids, branch)
      end
    end
    for _, branch in ipairs(state.branches or {}) do
      local branch_ref = branch_metadata_id(branch)
      if branch_ref and seen_sessions[branch_session_id(branch)] and not seen_branches[branch_ref] then
        seen_branches[branch_ref] = true
        table.insert(branch_ids, branch_ref)
      end
    end
    table.insert(tasks, {
      id = id,
      status = task_status(task),
      title = task_title(task),
      sessionIds = session_ids,
      branchIds = branch_ids,
    })
  end
  local history_total = 0
  local selected_session = selected_session_id()
  if selected_session then
    history_total = state.session_history_counts[selected_session] or 0
  end
  local task = selected_task()
  local active_sse_count = 0
  for _ in pairs(state.sse_clients) do
    active_sse_count = active_sse_count + 1
  end
  local diff_status = selected_task_diff_status()
  local diff_files = vim.deepcopy(selected_task_diff_files())
  local feedback = selected_pending_feedback()
  local selected_id = selected_task_id()
  return {
    daemon = {
      state = daemon.state,
      endpoint = daemon.endpoint,
      error = daemon.last_error,
    },
    header = {
      newTaskButtonVisible = false,
    },
    progress = {
      inFlight = state.inflight,
      refreshing = state.inflight > 0,
      lastRefreshSecondsAgo = last_refresh_seconds_ago(),
      daemonLine = daemon_progress_line(),
      tasksLoaded = state.tasks_loaded == true,
      -- Why the sweep is not converging, when it is not. `lastError` is the
      -- panel's own handler error; `restErrors` is the bounded ring of leaf
      -- failures recorded by `record_rest_failure`.
      --
      -- Both are omitted when empty rather than reported as `nil`/`{}`. The
      -- editor e2e harnesses print this table through Neovim's message system,
      -- which drops the trailing newline of a sufficiently long message and so
      -- runs the payload into the harness's own end marker; a converging panel
      -- must not pay bytes for a diagnostic that has nothing to say.
      lastError = state.last_error,
      restErrors = (state.rest_errors and #state.rest_errors > 0) and state.rest_errors or nil,
      diffLoaded = (selected_id and state.diff_loaded[selected_id]) == true,
      historyLoaded = (selected_session and state.history_loaded[selected_session]) == true,
      submitting = submitting_now(),
    },
    tasks = tasks,
    activeTasks = {
      filter = nil,
      count = #tasks,
      dropdownAvailable = #tasks > 0,
    },
    selectedTaskId = selected_id,
    selectedSessionId = selected_session_id(),
    selectedBranchId = selected_branch_id(),
    focusedTask = {
      title = task and task_title(task) or nil,
      status = task and task_status(task) or nil,
      taskId = selected_id,
      agentCount = #selected_sessions(),
      streamOptions = selected_id and session_ids_for_task(selected_id) or {},
      actionRow = { "share", "reply", "new-task" },
      branchId = selected_branch_id(),
    },
    focusedTitle = task and task_title(task) or nil,
    focusedStatus = task and task_status(task) or nil,
    pendingFeedbackTaskIds = pending_feedback_task_ids(),
    feedbackBanner = feedback and {
      feedbackId = feedback_id(feedback),
      question = feedback_question(feedback),
      type = feedback_type(feedback),
    } or nil,
    replyRows = feedback and 1 or 0,
    quickActionIds = feedback and feedback_type(feedback) == "confirmation" and {
      "reply-quick-approve",
      "reply-quick-reject",
    } or {},
    replyOverlay = require("agent-harbor.reply").test_state(),
    taskEntry = require("agent-harbor.task-entry").test_state(),
    notifications = {
      channelRoutingIndicator = channel_routing_indicator(),
      bannerText = daemon.last_error or (feedback and feedback_question(feedback) or nil),
    },
    panel = {
      error = state.last_error,
      activeSseCount = active_sse_count,
    },
    lastShare = state.last_share,
    accordionCollapsed = state.accordion_collapsed and true or false,
    timelineEventCount = history_total,
    sseEventCount = state.sse_event_count,
    timeline = {
      autoFollow = true,
      searchQuery = nil,
    },
    timelineCards = state.render.timeline_cards or {},
    modifiedFiles = state.render.modified_files or {},
    daemonDiffModifiedFiles = diff_files,
    daemonDiff = {
      ok = diff_status.ok == true,
      error = diff_status.error,
      modifiedFiles = diff_files,
    },
  }
end

function M._test_diff_files_from_response(diff)
  return diff_files_from_response(diff)
end

return M
