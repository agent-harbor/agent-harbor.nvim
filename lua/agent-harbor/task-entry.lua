-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {}

local ns = vim.api.nvim_create_namespace("agent-harbor-task-entry")

local state = {
  bufnr = nil,
  winid = nil,
  augroup = nil,
  fields = {},
  ranges = {},
  last_error = nil,
  last_response = nil,
  submitting = false,
}

M.state = state

local field_order = { "prompt", "title", "workspace", "branch", "agent_type", "model", "agent_count" }

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function git_output(args)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = vim.fn.getcwd() }):wait(1000)
  if not result or result.code ~= 0 then
    return nil
  end
  local output = trim(result.stdout or "")
  if output == "" then
    return nil
  end
  return output
end

local function default_workspace()
  return git_output({ "rev-parse", "--show-toplevel" }) or vim.fn.getcwd()
end

local function default_branch()
  return git_output({ "rev-parse", "--abbrev-ref", "HEAD" }) or ""
end

local function defaults()
  local opts = config.get().task_entry
  return {
    prompt = "",
    title = "",
    workspace = default_workspace(),
    branch = default_branch(),
    agent_type = opts.agent_type,
    model = opts.model,
    agent_count = opts.agent_count,
  }
end

local function field_label(field)
  local labels = {
    agent_type = "Agent",
    agent_count = "Count",
  }
  if labels[field] then
    return labels[field]
  end
  return (field:gsub("_", " "):gsub("^%l", string.upper))
end

local function field_value(field)
  local value = state.fields[field]
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function set_field(field, value)
  if field == "agent_count" then
    state.fields[field] = math.max(1, tonumber(value) or 1)
  else
    state.fields[field] = tostring(value or "")
  end
end

local function validate()
  local errors = {}
  if trim(field_value("prompt")) == "" then
    table.insert(errors, "Prompt is required")
  end
  if trim(field_value("workspace")) == "" then
    table.insert(errors, "Workspace is required")
  end
  if trim(field_value("agent_type")) == "" then
    table.insert(errors, "Agent is required")
  end
  if trim(field_value("model")) == "" then
    table.insert(errors, "Model is required")
  end
  if (tonumber(field_value("agent_count")) or 0) < 1 then
    table.insert(errors, "Agent count must be at least 1")
  end
  return errors
end

local function title_for(prompt)
  local title = trim(field_value("title"))
  if title ~= "" then
    return title
  end
  local first = trim(prompt):match("([^\r\n]+)") or trim(prompt)
  if #first > 80 then
    return first:sub(1, 80) .. "..."
  end
  return first
end

function M.build_payload()
  local errors = validate()
  if #errors > 0 then
    error(table.concat(errors, "; "))
  end

  local opts = config.get().task_entry
  local prompt = trim(field_value("prompt"))
  local title = title_for(prompt)
  local branch = trim(field_value("branch"))
  local agent_type = trim(field_value("agent_type"))
  local model = trim(field_value("model"))
  local agent = {
    type = agent_type,
    version = opts.agent_version,
    count = math.max(1, tonumber(field_value("agent_count")) or 1),
    settings = { model = model },
  }
  if agent_type:lower() == "acp" and opts.acp_command_binary then
    agent.acpStdioLaunchCommand = {
      binary = opts.acp_command_binary,
      args = opts.acp_command_args or {},
    }
  end
  local repo = { mode = "none" }
  if branch ~= "" then
    repo.branch = branch
  end
  local payload = {
    prompt = prompt,
    repo = repo,
    runtime = { type = "local" },
    workspace_path = trim(field_value("workspace")),
    working_copy_mode = opts.working_copy_mode,
    agents = { agent },
    output = {
      format = "stream-json",
      flavor = "ah",
      nonInteractive = true,
    },
    taskExecutor = { engine = opts.task_executor_engine },
    labels = {
      ["agentHarbor.source"] = "neovim",
      agentHarborTaskTitle = title,
      ["agentHarbor.taskTitle"] = title,
    },
  }
  if opts.llm_provider then
    payload.llmProvider = vim.deepcopy(opts.llm_provider)
    payload.llmProvider.model = model
  end
  return payload
end

local function update_fields_from_buffer()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  for field, range in pairs(state.ranges) do
    local start_pos = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, ns, range.start_id, {})
    local end_pos = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, ns, range.end_id, {})
    if #start_pos == 2 and #end_pos == 2 and start_pos[1] == end_pos[1] then
      local line = vim.api.nvim_buf_get_lines(state.bufnr, start_pos[1], start_pos[1] + 1, false)[1] or ""
      set_field(field, line:sub(start_pos[2] + 1, end_pos[2]))
    end
  end
end

function M.render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  state.ranges = {}
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  local lines = { "Agent Harbor New Task", "" }
  for _, field in ipairs(field_order) do
    local label = field_label(field) .. ":"
    table.insert(lines, string.format("%-10s %s", label, field_value(field)))
  end
  table.insert(lines, "")
  local errors = validate()
  if #errors > 0 then
    table.insert(lines, "Validation: " .. table.concat(errors, "; "))
  end
  if state.last_error then
    table.insert(lines, "Error: " .. state.last_error)
  end
  if state.last_response then
    table.insert(lines, "Created: " .. tostring(state.last_response.task_id or ""))
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  for index, field in ipairs(field_order) do
    local row = index + 1
    local prefix = string.format("%-10s ", field_label(field) .. ":")
    local start_col = #prefix
    local end_col = start_col + #field_value(field)
    local start_id = vim.api.nvim_buf_set_extmark(state.bufnr, ns, row, start_col, {
      right_gravity = false,
      hl_group = "AgentHarborTaskEntryEditable",
    })
    local end_id = vim.api.nvim_buf_set_extmark(state.bufnr, ns, row, end_col, {
      right_gravity = true,
    })
    state.ranges[field] = { start_id = start_id, end_id = end_id }
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, row, 0, {
      end_col = math.min(#prefix, #lines[row + 1]),
      hl_group = "AgentHarborTaskEntryField",
    })
  end
  vim.bo[state.bufnr].modifiable = true
end

local function current_field()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return field_order[1]
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for field, range in pairs(state.ranges) do
    local start_pos = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, ns, range.start_id, {})
    if #start_pos == 2 and start_pos[1] == row then
      return field
    end
  end
  return field_order[1]
end

local function field_index(field)
  for index, candidate in ipairs(field_order) do
    if candidate == field then
      return index
    end
  end
  return 1
end

local function move_field(direction)
  local index = field_index(current_field())
  local next_field = field_order[((index - 1 + direction) % #field_order) + 1]
  local range = state.ranges[next_field]
  if range then
    local pos = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, ns, range.start_id, {})
    if #pos == 2 then
      vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
    end
  end
  return next_field
end

function M.next_field()
  return move_field(1)
end

function M.previous_field()
  return move_field(-1)
end

local function open_window(bufnr)
  local f = config.get().task_entry.floating
  local width = math.max(44, math.floor(vim.o.columns * f.width))
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

function M.open()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, "Agent Harbor New Task")
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "wipe"
    vim.bo[state.bufnr].swapfile = false
    state.fields = defaults()
    state.last_error = nil
    state.last_response = nil
  end
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    state.winid = open_window(state.bufnr)
  else
    vim.api.nvim_set_current_win(state.winid)
  end
  M.render()
  vim.keymap.set("n", "<Tab>", M.next_field, { buffer = state.bufnr, silent = true })
  vim.keymap.set("i", "<Tab>", function()
    vim.cmd.stopinsert()
    M.next_field()
    vim.cmd.startinsert()
  end, { buffer = state.bufnr, silent = true })
  vim.keymap.set("n", "<S-Tab>", M.previous_field, { buffer = state.bufnr, silent = true })
  vim.keymap.set("n", "<C-c><C-c>", M.submit, { buffer = state.bufnr, silent = true })
  vim.keymap.set("n", "<C-c><C-k>", M.close, { buffer = state.bufnr, silent = true })
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("AgentHarborTaskEntry" .. state.bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    buffer = state.bufnr,
    callback = update_fields_from_buffer,
  })
  return state.bufnr
end

function M.set_field(field, value)
  local known = false
  for _, candidate in ipairs(field_order) do
    known = known or candidate == field
  end
  if not known then
    error("unknown Agent Harbor task-entry field: " .. tostring(field))
  end
  set_field(field, value)
  M.render()
end

function M.submit()
  state.last_error = nil
  state.submitting = true
  local ok, response = pcall(function()
    daemon.refresh()
    if daemon.state ~= "connected" or not daemon.endpoint then
      error("daemon endpoint is not discovered")
    end
    return rest.create_task(daemon.endpoint, M.build_payload(), { timeout_ms = 10000 })
  end)
  state.submitting = false
  if not ok then
    state.last_error = tostring(response)
    M.render()
    error(response)
  end
  state.last_response = response
  local task_id = response.task_id or response.taskId
  if not task_id then
    error("Task creation response did not include task_id")
  end
  local panel = require("agent-harbor.panel")
  panel.open()
  panel.select_task(task_id)
  M.render()
  return {
    taskId = task_id,
    sessionIds = response.session_ids or response.sessionIds or {},
    response = response,
  }
end

function M.close()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
end

function M.test_state()
  return {
    visible = state.winid and vim.api.nvim_win_is_valid(state.winid) or false,
    fields = vim.deepcopy(state.fields),
    lastError = state.last_error,
    lastResponse = state.last_response,
    submitting = state.submitting,
  }
end

return M
