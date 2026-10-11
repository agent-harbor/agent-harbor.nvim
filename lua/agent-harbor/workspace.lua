-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local uv = vim.uv or vim.loop

local M = {}

local metadata_timeout_ms = 10000

local state = {
  current_task_id = nil,
  current_branch_id = nil,
  current_root = nil,
  last_retarget = nil,
  retarget_call_count = 0,
  watch_cycle_count = 0,
  stashed_paths = {},
  watches = {},
  prompt = {
    bufnr = nil,
    winid = nil,
    text = nil,
    visible = false,
  },
}

M.state = state
M.prompt_function = nil

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
    return path
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
  if not full:match("/$") then
    full = full .. "/"
  end
  return full
end

local function normalize_file(path)
  return normalize_path(path)
end

local function in_root(path, root)
  if type(path) ~= "string" or path == "" or type(root) ~= "string" or root == "" then
    return false
  end
  local root_dir = normalize_dir(root)
  local full = normalize_file(path)
  return full:sub(1, #root_dir) == root_dir
end

local function relative_path(path, root)
  return normalize_file(path):sub(#normalize_dir(root) + 1):gsub("\\", "/")
end

local function join(root, relative)
  return normalize_dir(root) .. relative
end

local function is_regular_file(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file"
end

local function branch_id(branch)
  return get(branch, "id")
end

local function branch_session_id(branch)
  return get(branch, "sessionId") or get(branch, "session_id")
end

local function branch_updated_at(branch)
  return get(branch, "updatedAt") or get(branch, "updated_at") or ""
end

local function branch_root(branch)
  return get(branch, "workspacePath") or get(branch, "workspace_path")
end

local function sandboxed()
  return vim.env.AH_SANDBOXED == "1"
end

local function session_id(session)
  return get(session, "id")
end

local function session_branch_id(session)
  return get(session, "agentharborfsBranchId") or get(session, "agentharborfs_branch_id")
end

local function session_ids_for_task(task_id)
  local sessions = rest.task_sessions(daemon.endpoint, task_id, { timeout_ms = metadata_timeout_ms })
  local ids = {}
  for _, session in ipairs(sessions or {}) do
    if session_id(session) then
      table.insert(ids, session_id(session))
    end
  end
  return ids, sessions
end

local function session_id_set(session_ids)
  local wanted = {}
  for _, id in ipairs(session_ids or {}) do
    wanted[id] = true
  end
  return wanted
end

local function branches_for_sessions(session_ids, all_branches)
  local wanted = session_id_set(session_ids)
  local branches = {}
  for _, branch in ipairs(all_branches or rest.list_branches(daemon.endpoint, { timeout_ms = metadata_timeout_ms }) or {}) do
    if wanted[branch_session_id(branch)] then
      table.insert(branches, branch)
    end
  end
  return branches
end

local function find_branch_by_id(branches, id)
  if not id then
    return nil
  end
  for _, branch in ipairs(branches or {}) do
    if branch_id(branch) == id then
      return branch
    end
  end
  return nil
end

local function latest_branch(branches)
  table.sort(branches, function(left, right)
    return branch_updated_at(right) < branch_updated_at(left)
  end)
  return branches[1]
end

local function resolve_branch(task_id, requested_branch_id)
  if daemon.state ~= "connected" or not daemon.endpoint then
    daemon.refresh()
  end
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("Agent Harbor daemon is not connected")
  end

  local session_ids, sessions = session_ids_for_task(task_id)
  local all_branches = rest.list_branches(daemon.endpoint, { timeout_ms = metadata_timeout_ms }) or {}
  local branches = branches_for_sessions(session_ids, all_branches)
  if requested_branch_id then
    local branch = find_branch_by_id(branches, requested_branch_id)
    if branch then
      return branch
    end

    local direct_branch = find_branch_by_id(all_branches, requested_branch_id)
    local direct_session_id = direct_branch and branch_session_id(direct_branch) or nil
    local wanted = session_id_set(session_ids)
    if direct_branch and (#session_ids == 0 or (direct_session_id and wanted[direct_session_id])) then
      -- Task-session metadata can lag branch creation briefly under full-suite load.
      -- An explicit branch id is still authoritative once the daemon lists that branch.
      return direct_branch
    elseif direct_branch then
      error(
        "Branch "
          .. tostring(requested_branch_id)
          .. " is not associated with task "
          .. tostring(task_id)
      )
    end
  end
  for _, session in ipairs(sessions or {}) do
    local id = session_branch_id(session)
    if id then
      for _, branch in ipairs(branches) do
        if branch_id(branch) == id then
          return branch
        end
      end
    end
  end
  return latest_branch(branches)
end

local function manifest_changes(manifest)
  return type(manifest) == "table" and (manifest.changes or {}) or {}
end

local function change_path(change)
  return get(change, "path")
end

local function change_kind(change)
  local kind = tostring(get(change, "kind") or "")
  kind = kind:gsub("(%l)(%u)", "%1-%2"):gsub("_", "-"):lower()
  return kind
end

local function path_matches_change(relative, change)
  local path = change_path(change)
  if not path then
    return false
  end
  if change_kind(change) == "tree-replaced" then
    return relative == path or relative:sub(1, #path + 1) == path .. "/"
  end
  return relative == path
end

local function change_for_relative(relative, manifest)
  for _, change in ipairs(manifest_changes(manifest)) do
    if path_matches_change(relative, change) then
      return change
    end
  end
  return nil
end

local function root_file_buffers(root)
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if in_root(name, root) then
        table.insert(buffers, bufnr)
      end
    end
  end
  return buffers
end

local function force_bdelete(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.cmd("silent bdelete! " .. tostring(bufnr))
  end
end

local function modified_root_buffers(root)
  local buffers = {}
  for _, bufnr in ipairs(root_file_buffers(root)) do
    if vim.bo[bufnr].modified then
      table.insert(buffers, bufnr)
    end
  end
  return buffers
end

local function close_prompt()
  if state.prompt.winid and vim.api.nvim_win_is_valid(state.prompt.winid) then
    vim.api.nvim_win_close(state.prompt.winid, true)
  end
  state.prompt.visible = false
  state.prompt.winid = nil
end

local function open_prompt_dialog()
  close_prompt()
  local lines = {
    "Modified buffers are open in this Agent Harbor branch.",
    "",
    "[s] stash and switch   [k] keep buffers",
    "[d] kill buffers       [a] abort switch",
  }
  local bufnr = vim.api.nvim_create_buf(false, true)
  state.prompt.bufnr = bufnr
  state.prompt.text = table.concat(lines, "\n")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local floating = config.get().workspace.floating
  local width = math.max(44, math.min(floating.width or 54, vim.o.columns - 4))
  local height = math.max(6, math.min(floating.height or 8, vim.o.lines - 4))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = floating.border or "single",
  })
  state.prompt.winid = winid
  state.prompt.visible = true
  local choices = {
    s = "stash",
    k = "keep",
    d = "kill",
    a = "abort",
  }
  for key, action in pairs(choices) do
    vim.keymap.set("n", key, function()
      vim.b[bufnr].agent_harbor_prompt_action = action
    end, { buffer = bufnr, silent = true })
  end
  return bufnr
end

local function prompt_action()
  open_prompt_dialog()
  if M.prompt_function then
    local action = M.prompt_function()
    return action or "abort"
  end

  local key = vim.fn.getcharstr()
  local actions = { s = "stash", k = "keep", d = "kill", a = "abort" }
  return actions[key] or "abort"
end

local function policy_action(buffers)
  if #buffers == 0 then
    return "none"
  end
  local policy = config.get().workspace.on_switch_modified
  if policy == "prompt" then
    return prompt_action()
  end
  if policy == "stash" or policy == "keep" or policy == "kill" then
    return policy
  end
  error("Unsupported Agent Harbor modified-buffer policy: " .. tostring(policy))
end

local function record_stashed_path(task_id, relative)
  state.stashed_paths[task_id] = state.stashed_paths[task_id] or {}
  state.stashed_paths[task_id][relative] = true
end

local function buffer_bytes(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n") .. "\n"
end

local function stash_buffer(task_id, root, bufnr)
  local relative = relative_path(vim.api.nvim_buf_get_name(bufnr), root)
  rest.stash_buffer(daemon.endpoint, task_id, relative, buffer_bytes(bufnr), { timeout_ms = 3000 })
  record_stashed_path(task_id, relative)
  return relative
end

local function handle_modified_buffers(task_id, root)
  local buffers = modified_root_buffers(root)
  local action = policy_action(buffers)
  if action == "abort" then
    error("Agent Harbor task switch aborted")
  elseif action == "stash" then
    for _, bufnr in ipairs(buffers) do
      stash_buffer(task_id, root, bufnr)
      vim.bo[bufnr].modified = false
    end
  elseif action == "kill" then
    for _, bufnr in ipairs(buffers) do
      vim.bo[bufnr].modified = false
      pcall(force_bdelete, bufnr)
    end
  end
  return action
end

local function save_views(bufnr)
  local current = vim.api.nvim_get_current_win()
  local views = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      vim.api.nvim_set_current_win(winid)
      views[winid] = vim.fn.winsaveview()
    end
  end
  if vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
  return current, views
end

local function restore_views(current, views, bufnr)
  for winid, view in pairs(views or {}) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      vim.api.nvim_set_current_win(winid)
      vim.fn.winrestview(view)
    end
  end
  if vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

local function retarget_buffer_file(bufnr, new_root, relative)
  local new_file = join(new_root, relative)
  if vim.api.nvim_buf_get_name(bufnr) ~= new_file then
    vim.api.nvim_buf_set_name(bufnr, new_file)
  end
  return new_file
end

local function reload_or_delete(bufnr, new_root, relative)
  local new_file = retarget_buffer_file(bufnr, new_root, relative)
  if not is_regular_file(new_file) then
    pcall(force_bdelete, bufnr)
    return false
  end
  local current, views = save_views(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent keepalt edit!")
  end)
  restore_views(current, views, bufnr)
  return true
end

local function apply_manifest_to_buffers(old_root, new_root, manifest)
  for _, bufnr in ipairs(root_file_buffers(old_root)) do
    if vim.api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
      local relative = relative_path(vim.api.nvim_buf_get_name(bufnr), old_root)
      local change = change_for_relative(relative, manifest)
      if change and change_kind(change) == "deleted" then
        pcall(force_bdelete, bufnr)
      elseif change then
        reload_or_delete(bufnr, new_root, relative)
      else
        retarget_buffer_file(bufnr, new_root, relative)
      end
    end
  end
end

local function set_tab_cwd(root)
  vim.cmd("tcd " .. vim.fn.fnameescape(normalize_dir(root)))
end

local function cycle_fs_event_watches(old_root, new_root)
  state.watch_cycle_count = state.watch_cycle_count + 1
  local next_watches = {}
  for _, watch in ipairs(state.watches) do
    local path = watch.path
    local affected = in_root(path, old_root) or in_root(path, new_root)
    if affected and watch.handle then
      pcall(function()
        watch.handle:stop()
      end)
      pcall(function()
        watch.handle:close()
      end)
      if watch.callback then
        local relative = in_root(path, old_root) and relative_path(path, old_root) or relative_path(path, new_root)
        local new_path = join(new_root, relative)
        local handle = uv.new_fs_event()
        if handle then
          local ok = pcall(function()
            handle:start(new_path, watch.flags or {}, watch.callback)
          end)
          if ok then
            table.insert(next_watches, {
              handle = handle,
              path = new_path,
              callback = watch.callback,
              flags = watch.flags,
            })
          end
        end
      end
    else
      table.insert(next_watches, watch)
    end
  end
  state.watches = next_watches
end

function M.register_watch(handle, path, callback, flags)
  table.insert(state.watches, {
    handle = handle,
    path = path,
    callback = callback,
    flags = flags,
  })
  return handle
end

function M.watch(path, callback, flags)
  local handle = uv.new_fs_event()
  if not handle then
    error("vim.uv.fs_event is unavailable")
  end
  handle:start(path, flags or {}, callback)
  return M.register_watch(handle, path, callback, flags or {})
end

local function restore_stash(task_id, new_root)
  for relative in pairs(state.stashed_paths[task_id] or {}) do
    local ok, bytes = pcall(rest.get_stash_buffer, daemon.endpoint, task_id, relative, { timeout_ms = 3000 })
    if ok then
      local target = join(new_root, relative)
      local bufnr = vim.fn.bufnr(target)
      if bufnr <= 0 then
        vim.cmd("edit " .. vim.fn.fnameescape(target))
        bufnr = vim.api.nvim_get_current_buf()
      end
      vim.api.nvim_buf_call(bufnr, function()
        vim.bo[bufnr].modifiable = true
        local lines = vim.split(bytes, "\n", { plain = true })
        if lines[#lines] == "" then
          table.remove(lines, #lines)
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = true
      end)
    end
  end
end

local function update_lsp_clients(new_root, manifest)
  local changes = {}
  for _, change in ipairs(manifest_changes(manifest)) do
    local kind = change_kind(change)
    local lsp_kind = 2
    if kind == "added" then
      lsp_kind = 1
    elseif kind == "deleted" then
      lsp_kind = 3
    end
    local path = change_path(change)
    if path then
      table.insert(changes, {
        uri = vim.uri_from_fname(join(new_root, path)),
        type = lsp_kind,
      })
    end
  end
  if #changes == 0 then
    return
  end
  for _, client in ipairs(vim.lsp.get_clients({}) or {}) do
    pcall(function()
      client:notify("workspace/didChangeWatchedFiles", { changes = changes })
    end)
  end
end

local function fire_rerooted(task_id, branch_id_value, root, manifest)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "AgentHarborRerooted",
    data = {
      task_id = task_id,
      branch_id = branch_id_value,
      root = root,
      manifest = manifest,
    },
  })
end

local function initial_focus(task_id, target_branch_id, target_root)
  state.current_task_id = task_id
  state.current_branch_id = target_branch_id
  state.current_root = normalize_dir(target_root)
  state.last_retarget = {
    status = "not-requested",
    message = "initial focus only",
    retargeted = false,
    fallback = false,
    action = "initialized-current-task",
  }
  set_tab_cwd(target_root)
  restore_stash(task_id, target_root)
  fire_rerooted(task_id, target_branch_id, state.current_root, nil)
end

local function request_manifest(task_id, current_branch_id, target_branch_id, old_root, target_root)
  local response =
    rest.sandbox_diff(daemon.endpoint, task_id, current_branch_id, target_branch_id, { timeout_ms = 3000 })

  local retargeted = get(response, "retargeted") == true
  local status = get(response, "retarget_status") or get(response, "retargetStatus") or "not-requested"
  local message = get(response, "retarget_message") or get(response, "retargetMessage") or "sandbox-diff manifest only"
  local effective_root = retargeted and old_root or target_root
  state.last_retarget = {
    status = tostring(status),
    message = tostring(message),
    retargeted = retargeted,
    fallback = false,
    action = retargeted and "retargeted" or "sandbox-diff",
    fromBranchId = current_branch_id,
    toBranchId = target_branch_id,
    oldRoot = old_root,
    targetRoot = target_root,
    effectiveRoot = effective_root,
  }
  response.effectiveRoot = effective_root
  return response
end

function M.focus(task_id, opts)
  opts = opts or {}
  local branch = resolve_branch(task_id, opts.branch_id)
  local target_branch_id = branch and branch_id(branch) or nil
  local target_root = branch and branch_root(branch) or nil
  if not target_branch_id or not target_root then
    error("Branch metadata for task " .. tostring(task_id) .. " is incomplete")
  end

  if not state.current_branch_id or not state.current_root then
    initial_focus(task_id, target_branch_id, target_root)
  elseif target_branch_id ~= state.current_branch_id then
    local old_task_id = state.current_task_id
    local old_root = state.current_root
    local manifest = request_manifest(task_id, state.current_branch_id, target_branch_id, old_root, target_root)
    local effective_root = manifest.effectiveRoot or target_root
    handle_modified_buffers(old_task_id, old_root)
    cycle_fs_event_watches(old_root, effective_root)
    apply_manifest_to_buffers(old_root, effective_root, manifest)
    set_tab_cwd(effective_root)
    state.current_task_id = task_id
    state.current_branch_id = target_branch_id
    state.current_root = normalize_dir(effective_root)
    restore_stash(task_id, effective_root)
    update_lsp_clients(effective_root, manifest)
    fire_rerooted(task_id, target_branch_id, state.current_root, manifest)
  else
    state.current_task_id = task_id
    set_tab_cwd(target_root)
  end

  return M.current_state()
end

function M.current_state()
  local stashed = {}
  for task_id, paths in pairs(state.stashed_paths) do
    stashed[task_id] = {}
    for path in pairs(paths) do
      table.insert(stashed[task_id], path)
    end
    table.sort(stashed[task_id])
  end
  return {
    taskId = state.current_task_id,
    branchId = state.current_branch_id,
    root = state.current_root,
    sandboxed = sandboxed(),
    retargetCallCount = state.retarget_call_count,
    watchCycleCount = state.watch_cycle_count,
    lastRetarget = state.last_retarget,
    stashed = stashed,
  }
end

function M.test_state()
  return {
    workspace = M.current_state(),
    prompt = {
      visible = state.prompt.visible,
      text = state.prompt.text,
      bufnr = state.prompt.bufnr,
      winid = state.prompt.winid,
    },
  }
end

return M
