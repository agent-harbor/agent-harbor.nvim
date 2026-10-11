-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {
  last_result = nil,
  last_error = nil,
}

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function percent_decode(value)
  return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function segment(value, label)
  value = percent_decode(value)
  if trim(value) == "" then
    error("agent-harbor URI is missing " .. label)
  end
  if value:find("[/\\]") then
    error("agent-harbor URI " .. label .. " must be a single path segment")
  end
  return value
end

local function parse_query(query)
  local params = {}
  for pair in tostring(query or ""):gmatch("[^&]+") do
    local key, value = pair:match("^([^=]*)=?(.*)$")
    if key and key ~= "" then
      params[percent_decode(key)] = percent_decode(value or "")
    end
  end
  return params
end

local validate_import_host

function M.parse(uri)
  if type(uri) ~= "string" then
    error("agent-harbor URI must be a string")
  end
  local without_scheme = uri:match("^agent%-harbor://(.+)$")
  if not without_scheme then
    local scheme = uri:match("^([%a][%w+.-]*):")
    error("unsupported URI scheme: " .. tostring(scheme or ""))
  end
  if without_scheme:match("^[^/?#]*@") then
    error("agent-harbor URI credentials are not supported")
  end

  local path_part, query = without_scheme:match("^([^?#]*).*%?([^#]*)")
  path_part = path_part or without_scheme:gsub("[?#].*$", "")
  local params = parse_query(query)
  if params.host then
    validate_import_host(params.host)
  end

  local parts = {}
  for part in path_part:gmatch("[^/]+") do
    table.insert(parts, percent_decode(part))
  end

  if parts[1] == "task" and #parts == 2 then
    return { kind = "task", taskId = segment(parts[2], "task id") }
  end
  if parts[1] == "fs" and parts[2] == "branch" and #parts == 3 then
    return { kind = "fs-branch", branchId = segment(parts[3], "branch id"), host = params.host, token = params.token }
  end
  if parts[1] == "fs" and parts[2] == "snapshot" and #parts == 3 then
    return { kind = "fs-snapshot", snapshotId = segment(parts[3], "snapshot id"), host = params.host, token = params.token }
  end
  error("unsupported agent-harbor URI path: " .. table.concat(parts, "/"))
end

function validate_import_host(host)
  if type(host) ~= "string" or host == "" then
    error("unsupported Agent Harbor import host: expected a rendezvous host id or explicit HTTP URL")
  end
  local scheme, authority = host:match("^([%a][%w+.-]*)://([^/?#]+)")
  if not scheme then
    return
  end
  if scheme ~= "http" and scheme ~= "https" then
    error("unsupported Agent Harbor import host " .. vim.inspect(host) .. ": explicit URLs must use HTTP or HTTPS")
  end
  local raw_authority = tostring(authority or "")
  local hostname = raw_authority:match("^%[([^%]]+)%]") or raw_authority:match("^([^:]+)") or ""
  hostname = hostname:lower()
  local loopback = hostname == "localhost" or hostname == "127.0.0.1" or hostname == "::1" or hostname:match("^127%.")
  if not loopback then
    error(
      "unsupported Agent Harbor import host "
        .. vim.inspect(host)
        .. ": direct HTTP imports must use a loopback URL; use a rendezvous host id for cross-machine imports"
    )
  end
end

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

local function session_id(session)
  return get(session, "id")
end

local function session_branch_id(session)
  return get(session, "agentharborfsBranchId") or get(session, "agentharborfs_branch_id")
end

local function branch_id(branch)
  return get(branch, "id")
end

local function branch_session_id(branch)
  return get(branch, "sessionId") or get(branch, "session_id")
end

local function branch_root(branch)
  return get(branch, "workspacePath") or get(branch, "workspace_path")
end

local function branch_updated_at(branch)
  return get(branch, "updatedAt") or get(branch, "updated_at") or ""
end

local function snapshot_root(snapshot)
  return get(snapshot, "workspacePath") or get(snapshot, "workspace_path")
end

local function ensure_daemon()
  if daemon.state ~= "connected" or not daemon.endpoint then
    daemon.refresh()
  end
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("Agent Harbor daemon is not connected")
  end
end

local function branches_for_sessions(session_ids)
  local wanted = {}
  for _, id in ipairs(session_ids) do
    wanted[id] = true
  end
  local branches = {}
  for _, branch in ipairs(rest.list_branches(daemon.endpoint, { timeout_ms = 5000 }) or {}) do
    if wanted[branch_session_id(branch)] then
      table.insert(branches, branch)
    end
  end
  table.sort(branches, function(left, right)
    return branch_updated_at(right) < branch_updated_at(left)
  end)
  return branches
end

local function task_branch(task_id)
  local sessions = rest.task_sessions(daemon.endpoint, task_id, { timeout_ms = 5000 }) or {}
  local session_ids = {}
  for _, session in ipairs(sessions) do
    if session_id(session) then
      table.insert(session_ids, session_id(session))
    end
  end
  local branches = branches_for_sessions(session_ids)
  for _, session in ipairs(sessions) do
    local wanted = session_branch_id(session)
    if wanted then
      for _, branch in ipairs(branches) do
        if branch_id(branch) == wanted then
          return branch, session_id(session), sessions
        end
      end
    end
  end
  local branch = branches[1]
  return branch, branch and branch_session_id(branch) or session_ids[1], sessions
end

local function open_root(root)
  if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
    error("Agent Harbor local path is not a directory: " .. tostring(root))
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(root))
  vim.cmd("edit " .. vim.fn.fnameescape(root))
end

local function query_escape(value)
  return rest.path_escape(value)
end

local function import_source_url(route)
  local host = route.host or daemon.endpoint
  validate_import_host(host)
  local source_kind = route.kind == "fs-branch" and "branch" or "snapshot"
  local source_id = route.kind == "fs-branch" and route.branchId or route.snapshotId
  return "agent-harbor://fs/"
    .. source_kind
    .. "/"
    .. query_escape(source_id)
    .. "?host="
    .. query_escape(host)
end

local function branch_status_evidence(branch_id)
  local ok, status = pcall(rest.branch_status, daemon.endpoint, branch_id, { timeout_ms = 5000 })
  if not ok then
    return { error = tostring(status) }
  end
  return status.import or status.fetch
end

local function import_fs_route(route)
  local source_url = import_source_url(route)
  vim.g.agent_harbor_last_import_status = {
    state = "fetching",
    label = "Fetching " .. (route.kind == "fs-branch" and "branch" or "snapshot") .. "...",
    sourceUrl = source_url,
  }
  local imported = rest.create_agentharborfs_import(daemon.endpoint, source_url, route.token, {
    timeout_ms = 50000,
    materialization_mode = "full-ahr",
  })
  local mount_path = get(imported, "mountPath") or get(imported, "mount_path")
  local import_id = get(imported, "importId") or get(imported, "import_id")
  local branch_id_value = get(imported, "branchId") or get(imported, "branch_id")
  if type(mount_path) ~= "string" or mount_path == "" then
    error("AgentHarborFS import " .. tostring(import_id) .. " did not return a mount path")
  end
  open_root(mount_path)
  local result = {
    kind = route.kind,
    branchId = branch_id_value,
    snapshotId = route.snapshotId,
    importId = import_id,
    mountPath = mount_path,
    root = mount_path,
    sourceUrl = get(imported, "sourceUrl") or get(imported, "source_url") or source_url,
    lazyFetchEvidence = branch_id_value and branch_status_evidence(branch_id_value) or nil,
  }
  vim.g.agent_harbor_last_import_status = {
    state = "ready",
    label = (route.kind == "fs-branch" and "branch" or "snapshot") .. " ready",
    importId = import_id,
    mountPath = mount_path,
    sourceUrl = result.sourceUrl,
  }
  return result
end

local function open_route(route)
  ensure_daemon()
  if route.kind == "task" then
    local branch, selected_session_id, sessions = task_branch(route.taskId)
    local root = branch and branch_root(branch) or nil
    local selected_branch_id = branch and branch_id(branch) or nil
    if not selected_branch_id or not root then
      error("task " .. route.taskId .. " does not have a local AgentHarborFS branch path")
    end
    vim.cmd("AgentHarbor")
    require("agent-harbor.panel").focus_task_session(route.taskId, selected_session_id, sessions)
    require("agent-harbor.workspace").focus(route.taskId, { branch_id = selected_branch_id })
    return {
      kind = "task",
      taskId = route.taskId,
      sessionId = selected_session_id,
      branchId = selected_branch_id,
      root = root,
    }
  elseif route.kind == "fs-branch" then
    return import_fs_route(route)
  elseif route.kind == "fs-snapshot" then
    return import_fs_route(route)
  end
  error("unsupported Agent Harbor URI route: " .. tostring(route.kind))
end

function M.open(uri)
  local ok, result = pcall(function()
    return open_route(M.parse(uri))
  end)
  if ok then
    M.last_result = result
    M.last_error = nil
    return result
  end
  M.last_error = tostring(result)
  error(result)
end

function M.register_ui_open()
  if type(vim.ui) ~= "table" or type(vim.ui.open) ~= "function" or vim.g.agent_harbor_ui_open_wrapped then
    return
  end
  local previous = vim.ui.open
  vim.g.agent_harbor_ui_open_wrapped = true
  vim.ui.open = function(path, opts)
    if type(path) == "string" and path:match("^agent%-harbor://") then
      return M.open(path)
    end
    return previous(path, opts)
  end
end

return M
