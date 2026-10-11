-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {}

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

function M.host()
  if vim.env.TMUX then
    return "tmux"
  end
  if vim.env.ZELLIJ or vim.env.ZELLIJ_SESSION_NAME then
    return "zellij"
  end
  if vim.env.WEZTERM_PANE then
    return "wezterm"
  end
  if vim.env.STY then
    return "screen"
  end
  if vim.env.KITTY_LISTEN_ON then
    return "kitty"
  end
  if vim.env.ITERM_SESSION_ID then
    return "iterm2"
  end
  return "bare"
end

local function task_id(task)
  return get(task, "id")
end

local function task_workspace(task)
  return get(task, "workspace_path") or get(task, "workspacePath")
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

local function ensure_daemon()
  if daemon.state ~= "connected" or not daemon.endpoint then
    daemon.refresh()
  end
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("Agent Harbor daemon is not connected")
  end
end

local function selected_task(task_id_override)
  local panel = require("agent-harbor.panel")
  if task_id_override then
    panel.select_task(task_id_override)
    for _, task in ipairs(panel.state.tasks or {}) do
      if task_id(task) == task_id_override then
        return task
      end
    end
  end
  panel.refresh()
  if task_id_override then
    panel.select_task(task_id_override)
  end
  local selected = panel.selected_task_id()
  for _, task in ipairs(panel.state.tasks or {}) do
    if task_id(task) == selected then
      return task
    end
  end
  if task_id_override then
    local ok, tasks = pcall(rest.list_tasks, daemon.endpoint, { timeout_ms = 10000 })
    if ok then
      for _, task in ipairs(tasks or {}) do
        if task_id(task) == task_id_override then
          return task
        end
      end
    end
    return { id = task_id_override }
  end
  return panel.state.tasks[1]
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

local function resolve_root(task)
  local id = task_id(task)
  if not id then
    error("No Agent Harbor task is selected")
  end
  local sessions = rest.task_sessions(daemon.endpoint, id, { timeout_ms = 5000 }) or {}
  local session_ids = {}
  for _, session in ipairs(sessions) do
    if session_id(session) then
      table.insert(session_ids, session_id(session))
    end
  end
  local branches = branches_for_sessions(session_ids)
  local selected_branch = nil
  for _, session in ipairs(sessions) do
    local wanted = session_branch_id(session)
    if wanted then
      for _, branch in ipairs(branches) do
        if branch_id(branch) == wanted then
          selected_branch = branch
          break
        end
      end
    end
    if selected_branch then
      break
    end
  end
  selected_branch = selected_branch or branches[1]
  local root = selected_branch and branch_root(selected_branch) or task_workspace(task)
  if type(root) ~= "string" or root == "" or vim.fn.isdirectory(root) ~= 1 then
    error("Selected task has no local branch/workspace root: " .. tostring(id))
  end
  return {
    task_id = id,
    branch_id = selected_branch and branch_id(selected_branch) or nil,
    root = vim.fn.fnamemodify(root, ":p"),
  }
end

local function open_in_current_tab(target)
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(target.root))
  vim.cmd("edit " .. vim.fn.fnameescape(target.root))
end

local function call_cli(host, target)
  local opts = config.get().mux
  local args = {
    opts.ah_command,
    "editor-mux",
    "open-new",
    "--host",
    host,
    "--cwd",
    target.root,
    "--title",
    "AH " .. target.task_id,
    opts.nvim_client_command,
  }
  vim.list_extend(args, opts.nvim_client_args or {})
  local result = vim.system(args, { text = true }):wait(10000)
  if not result then
    error("ah editor-mux timed out")
  end
  if result.code ~= 0 then
    error("ah editor-mux failed: " .. tostring(result.stderr or result.stdout or result.code))
  end
end

function M.open_new(task_id_override)
  ensure_daemon()
  local task = selected_task(task_id_override)
  local target = resolve_root(task)
  local opts = config.get().mux
  local host = M.host()
  if opts.open_new_mode == "tab" then
    open_in_current_tab(target)
  else
    call_cli(host, target)
  end
  return {
    host = host,
    taskId = target.task_id,
    branchId = target.branch_id,
    root = target.root,
  }
end

return M
