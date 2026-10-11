-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  bufnr = nil,
  winid = nil,
  line_map = {},
  expanded = {},
  current = nil,
  last_error = nil,
  last_checkpoint_response = nil,
  checkpoint_bufnr = nil,
  previous_root = nil,
  bridge = {
    gitsigns = { refreshed = 0, available = false, error = nil },
    fugitive = { refreshed = 0, available = false, error = nil },
    neogit = { refreshed = 0, available = false, error = nil },
  },
}

M.state = state
M.checkpoint_message_provider = nil

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

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local full = vim.fn.fnamemodify(path, ":p")
  local resolved = uv.fs_realpath(full)
  if resolved and resolved ~= "" then
    full = resolved
  end
  return full
end

local function normalize_dir(path)
  local full = normalize_path(path)
  if not full then
    return nil
  end
  if not full:match("/$") then
    full = full .. "/"
  end
  return full
end

local function in_root(path, root)
  local normalized = normalize_dir(root)
  if type(path) ~= "string" or path == "" or not normalized then
    return false
  end
  local full = normalize_path(path)
  if not full then
    return false
  end
  return full:sub(1, #normalized) == normalized
end

local function join(root, relative)
  return normalize_dir(root) .. relative
end

local function snapshot_id(snapshot)
  return get(snapshot, "id")
end

local function branch_id(branch)
  return get(branch, "id")
end

local function branch_root(branch)
  return get(branch, "workspacePath") or get(branch, "workspace_path")
end

local function branch_session_id(branch)
  return get(branch, "sessionId") or get(branch, "session_id")
end

local function session_id(session)
  return get(session, "id")
end

local function session_branch_id(session)
  return get(session, "agentharborfsBranchId") or get(session, "agentharborfs_branch_id")
end

local function ensure_daemon()
  if daemon.state ~= "connected" or not daemon.endpoint then
    daemon.refresh()
  end
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("Agent Harbor daemon is not connected")
  end
end

local function task_id_for_session(session_id_value)
  for _, task in ipairs(rest.list_tasks(daemon.endpoint, { timeout_ms = 5000 }) or {}) do
    local task_id = get(task, "id")
    if task_id then
      for _, session in ipairs(rest.task_sessions(daemon.endpoint, task_id, { timeout_ms = 5000 }) or {}) do
        if session_id(session) == session_id_value then
          return task_id
        end
      end
    end
  end
  return nil
end

local function branch_for_workspace(root, selected_branch_id)
  local normalized = normalize_dir(root or vim.fn.getcwd(0, 0))
  for _, branch in ipairs(rest.list_branches(daemon.endpoint, { timeout_ms = 5000 }) or {}) do
    if selected_branch_id and branch_id(branch) == selected_branch_id then
      return branch
    end
  end
  for _, branch in ipairs(rest.list_branches(daemon.endpoint, { timeout_ms = 5000 }) or {}) do
    local candidate = normalize_dir(branch_root(branch))
    if candidate and normalized and (candidate == normalized or normalized:sub(1, #candidate) == candidate) then
      return branch
    end
  end
  return nil
end

local function selected_session_for_task(task_id, branch_id_value)
  if not task_id then
    return nil
  end
  local sessions = rest.task_sessions(daemon.endpoint, task_id, { timeout_ms = 5000 }) or {}
  for _, session in ipairs(sessions) do
    if session_branch_id(session) == branch_id_value then
      return session
    end
  end
  return sessions[#sessions]
end

local function sorted_files(files)
  local out = vim.deepcopy(files or {})
  table.sort(out, function(left, right)
    return tostring(get(left, "path") or "") < tostring(get(right, "path") or "")
  end)
  return out
end

function M.current_state(root)
  ensure_daemon()
  local workspace = require("agent-harbor.workspace").current_state()
  local selected_root = normalize_dir(root or workspace.root or vim.fn.getcwd(0, 0))
  local branch = branch_for_workspace(selected_root, workspace.branchId)
  local selected_session = selected_session_for_task(workspace.taskId, branch and branch_id(branch) or workspace.branchId)
  local session_id_value = selected_session and session_id(selected_session) or (branch and branch_session_id(branch))
  if not session_id_value then
    return nil
  end
  local files_response = rest.session_files(daemon.endpoint, session_id_value, { timeout_ms = 5000, per_page = 100 })
  local task_id = workspace.taskId or task_id_for_session(session_id_value)
  local resolved_root = normalize_dir(branch and branch_root(branch) or selected_root)
  return {
    sessionId = session_id_value,
    taskId = task_id,
    branchId = branch and branch_id(branch) or workspace.branchId,
    root = resolved_root,
    baseSnapshot = get(files_response, "baseSnapshot") or get(files_response, "base_snapshot") or (branch and get(branch, "baseSnapshot")),
    snapshot = get(files_response, "snapshot") or (branch and (get(branch, "headSnapshot") or get(branch, "head_snapshot"))),
    files = sorted_files(get(files_response, "items") or {}),
  }
end

local function file_path(file)
  return get(file, "path")
end

local function file_status(file)
  return get(file, "status") or "modified"
end

local function snapshot_content(current, file, snapshot)
  local id = snapshot_id(snapshot)
  if not id then
    error("Agent Harbor snapshot id is unavailable")
  end
  return rest.session_file_content(daemon.endpoint, current.sessionId, file_path(file), id, { timeout_ms = 5000 })
end

local function file_diff(current, file)
  local path = file_path(file)
  local status = file_status(file)
  local base = status == "added" and "" or snapshot_content(current, file, current.baseSnapshot)
  local head = status == "deleted" and "" or snapshot_content(current, file, current.snapshot)
  local diff = vim.diff(base or "", head or "", { result_type = "unified", ctxlen = 3 }) or ""
  local lines = {
    ("--- base:%s/%s"):format(snapshot_id(current.baseSnapshot) or "", path or ""),
    ("+++ head:%s/%s"):format(snapshot_id(current.snapshot) or "", path or ""),
  }
  if diff == "" then
    table.insert(lines, "(no textual changes)")
  else
    for line in diff:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
  end
  return lines
end

local function render_summary(lines, current)
  table.insert(lines, "Agent Harbor Changes")
  table.insert(lines, "")
  if state.last_error then
    table.insert(lines, "Error: " .. state.last_error)
    table.insert(lines, "")
  end
  table.insert(lines, "Session: " .. tostring(current.sessionId or ""))
  if current.taskId then
    table.insert(lines, "Task: " .. current.taskId)
  end
  if current.branchId then
    table.insert(lines, "Branch: " .. current.branchId)
  end
  if current.baseSnapshot then
    table.insert(
      lines,
      ("Base: %s  %s"):format(snapshot_id(current.baseSnapshot) or "", get(current.baseSnapshot, "contentId") or "")
    )
  end
  if current.snapshot then
    table.insert(
      lines,
      ("Head: %s  %s"):format(snapshot_id(current.snapshot) or "", get(current.snapshot, "contentId") or "")
    )
  end
  table.insert(lines, "")
  table.insert(lines, "Changes")
end

function M.render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  local lines = {}
  state.line_map = {}
  if not state.current then
    table.insert(lines, "Agent Harbor Changes")
    table.insert(lines, "")
    table.insert(lines, "No daemon-reported branch metadata for this workspace.")
  else
    render_summary(lines, state.current)
    if #state.current.files == 0 then
      table.insert(lines, "  No daemon-reported changes.")
    else
      for _, file in ipairs(state.current.files) do
        local row = #lines + 1
        table.insert(lines, ("  %-10s %s"):format(file_status(file), file_path(file) or ""))
        state.line_map[row] = { file = file, state = state.current }
        local path = file_path(file)
        if path and state.expanded[path] then
          local ok, diff_lines = pcall(file_diff, state.current, file)
          if ok then
            for _, line in ipairs(diff_lines) do
              table.insert(lines, "    " .. line)
            end
          else
            table.insert(lines, "    Error: " .. tostring(diff_lines))
          end
        end
      end
    end
    table.insert(lines, "")
    table.insert(lines, "<CR> open   <Tab> diff   <C-c> checkpoint   g refresh   q close")
  end
  vim.bo[state.bufnr].readonly = false
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].readonly = true
end

function M.refresh()
  local ok, current = pcall(M.current_state)
  if ok then
    state.current = current
    state.last_error = nil
  else
    state.current = nil
    state.last_error = tostring(current)
  end
  M.render()
  return state.current
end

local function row()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[line]
end

function M.open_file()
  local entry = row()
  if not entry or not entry.file then
    error("No Agent Harbor file at cursor")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(join(entry.state.root, file_path(entry.file))))
end

function M.toggle_diff()
  local entry = row()
  if not entry or not entry.file then
    error("No Agent Harbor file at cursor")
  end
  local path = file_path(entry.file)
  state.expanded[path] = not state.expanded[path]
  M.render()
end

local function checkpoint_buffer(session_id_value)
  local bufnr = vim.api.nvim_create_buf(false, true)
  state.checkpoint_bufnr = bufnr
  vim.api.nvim_buf_set_name(bufnr, "Agent Harbor Checkpoint")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "gitcommit"
  vim.b[bufnr].agent_harbor_checkpoint_session_id = session_id_value
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "",
    "# <C-c> creates an Agent Harbor checkpoint.",
  })
  vim.keymap.set("n", "<C-c>", M.submit_checkpoint, { buffer = bufnr, silent = true })
  vim.keymap.set("i", "<C-c>", function()
    vim.cmd("stopinsert")
    M.submit_checkpoint()
  end, { buffer = bufnr, silent = true })
  return bufnr
end

local function checkpoint_message(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kept = {}
  for _, line in ipairs(lines) do
    if not vim.trim(line):match("^#") then
      table.insert(kept, line)
    end
  end
  return vim.trim(table.concat(kept, "\n"))
end

function M.open_checkpoint()
  local current = state.current or M.refresh()
  if not current or not current.sessionId then
    error("No Agent Harbor session for checkpoint")
  end
  if M.checkpoint_message_provider then
    return M.submit_checkpoint(M.checkpoint_message_provider(), current.sessionId)
  end
  local bufnr = checkpoint_buffer(current.sessionId)
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("startinsert")
  return bufnr
end

function M.submit_checkpoint(message, session_id_value)
  local bufnr = vim.api.nvim_get_current_buf()
  local resolved_session = session_id_value or vim.b[bufnr].agent_harbor_checkpoint_session_id
  if not resolved_session then
    local current = state.current or M.refresh()
    resolved_session = current and current.sessionId
  end
  if not resolved_session then
    error("No Agent Harbor session for checkpoint")
  end
  local resolved_message = vim.trim(message or checkpoint_message(bufnr))
  if resolved_message == "" then
    error("Checkpoint message is empty")
  end
  state.last_checkpoint_response =
    rest.checkpoint_session(daemon.endpoint, resolved_session, resolved_message, { timeout_ms = 5000 })
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "nofile" then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  M.refresh()
  return state.last_checkpoint_response
end

function M.open()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
      if vim.api.nvim_win_get_buf(state.winid) ~= state.bufnr then
        vim.api.nvim_win_set_buf(state.winid, state.bufnr)
      end
    else
      vim.cmd("botright vertical 48new")
      state.winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.winid, state.bufnr)
    end
  else
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, "Agent Harbor Changes")
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "hide"
    vim.bo[state.bufnr].swapfile = false
    vim.bo[state.bufnr].filetype = "agent-harbor-changes"
    vim.cmd("botright vertical 48new")
    state.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.winid, state.bufnr)
    vim.keymap.set("n", "<CR>", M.open_file, { buffer = state.bufnr, silent = true })
    vim.keymap.set("n", "<Tab>", M.toggle_diff, { buffer = state.bufnr, silent = true })
    vim.keymap.set("n", "<C-c>", M.open_checkpoint, { buffer = state.bufnr, silent = true })
    vim.keymap.set("n", "g", M.refresh, { buffer = state.bufnr, silent = true })
    vim.keymap.set("n", "q", function()
      vim.cmd("close")
    end, { buffer = state.bufnr, silent = true })
  end
  M.refresh()
  return state.bufnr
end

local function mark_bridge(name, ok, err)
  state.bridge[name].available = true
  if ok then
    state.bridge[name].refreshed = state.bridge[name].refreshed + 1
    state.bridge[name].error = nil
  else
    state.bridge[name].error = tostring(err)
  end
end

local function loaded_module(name)
  if package.loaded[name] then
    return pcall(require, name)
  end
  local ok, module = pcall(require, name)
  if ok then
    return true, module
  end
  return false, module
end

local function attach_gitsigns_buffer(gitsigns, bufnr, root)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if not in_root(vim.api.nvim_buf_get_name(bufnr), root) then
    return
  end
  pcall(gitsigns.detach, bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    if vim.fn.exists(":Gitsigns") == 2 then
      vim.cmd("silent! Gitsigns attach")
    elseif type(gitsigns.attach) == "function" then
      local file = vim.api.nvim_buf_get_name(bufnr)
      gitsigns.attach(bufnr, {
        file = file,
        toplevel = root:gsub("/$", ""),
        gitdir = root .. ".git",
      }, "AgentHarborRerooted")
    end
  end)
end

local function refresh_gitsigns(root)
  local ok, gitsigns = loaded_module("gitsigns")
  if not ok then
    state.bridge.gitsigns.available = false
    return
  end
  local matched = 0
  local refreshed, err = pcall(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if vim.api.nvim_buf_is_loaded(bufnr) and in_root(name, root) then
        matched = matched + 1
        vim.defer_fn(function()
          pcall(attach_gitsigns_buffer, gitsigns, bufnr, root)
          if type(gitsigns.refresh) == "function" then
            pcall(gitsigns.refresh)
          end
        end, 50)
      end
    end
  end)
  if refreshed and matched == 0 then
    state.bridge.gitsigns.available = true
    state.bridge.gitsigns.error = nil
  else
    mark_bridge("gitsigns", refreshed, err)
  end
end

local function fugitive_status_buffers()
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.bo[bufnr].filetype
      local name = vim.api.nvim_buf_get_name(bufnr)
      if ft == "fugitive" or ft == "git" or name:find("fugitive://", 1, true) then
        table.insert(out, bufnr)
      end
    end
  end
  return out
end

local function refresh_fugitive(root)
  if vim.fn.exists(":Git") ~= 2 and vim.fn.exists("*fugitive#DidChange") ~= 1 then
    state.bridge.fugitive.available = false
    return
  end
  local refreshed, err = pcall(function()
    local buffers = fugitive_status_buffers()
    if vim.fn.exists("*fugitive#DidChange") == 1 then
      pcall(vim.fn["fugitive#DidChange"], root)
    end
    if #buffers > 0 and vim.fn.exists(":Git") == 2 then
      local current = vim.api.nvim_get_current_buf()
      for _, bufnr in ipairs(buffers) do
        if bufnr == current then
          vim.cmd("enew")
          break
        end
      end
      for _, bufnr in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
      vim.cmd("lcd " .. vim.fn.fnameescape(root))
      vim.cmd("silent Git")
      if vim.api.nvim_buf_get_name(0):find("fugitive://", 1, true) then
        pcall(vim.fn["fugitive#BufReadStatus"], 0)
      end
    end
  end)
  mark_bridge("fugitive", refreshed, err)
end

local function neogit_status_open()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "NeogitStatus" then
      return true
    end
  end
  return false
end

local function refresh_neogit(root)
  local ok, neogit = loaded_module("neogit")
  if not ok then
    state.bridge.neogit.available = false
    return
  end
  local refreshed, err = pcall(function()
    if neogit_status_open() and type(neogit.open) == "function" then
      neogit.open({ cwd = root, kind = "replace" })
    elseif type(neogit.dispatch_refresh) == "function" then
      neogit.dispatch_refresh()
    elseif type(neogit.refresh) == "function" then
      neogit.refresh()
    end
  end)
  mark_bridge("neogit", refreshed, err)
end

function M.refresh_git_plugins(data)
  data = data or {}
  local root = normalize_dir(data.root)
  if not root then
    return
  end
  refresh_gitsigns(root)
  refresh_fugitive(root)
  refresh_neogit(root)
  state.previous_root = root
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    M.refresh()
  end
end

function M.setup()
  if state.augroup then
    return
  end
  state.augroup = vim.api.nvim_create_augroup("AgentHarborScm", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = state.augroup,
    pattern = "AgentHarborRerooted",
    callback = function(args)
      M.refresh_git_plugins(args.data or {})
    end,
  })
end

function M.test_state(root)
  return {
    state = M.current_state(root),
    bridge = vim.deepcopy(state.bridge),
    lastCheckpointResponse = state.last_checkpoint_response,
    buffer = {
      bufnr = state.bufnr,
      winid = state.winid,
      checkpointBufnr = state.checkpoint_bufnr,
    },
  }
end

return M
