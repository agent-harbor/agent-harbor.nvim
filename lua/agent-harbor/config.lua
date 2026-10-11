-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

local defaults = {
  daemon = {
    url = nil,
    pid_file = nil,
    poll_interval_ms = 1000,
    probe_timeout_ms = 5000,
    auto_start = false,
    executable = "ah",
    start_args = { "daemon", "serve", "--daemon-child", "--no-acp", "--no-recording" },
  },
  statusline = {
    icons = {
      connected = "●",
      starting = "◐",
      disconnected = "○",
    },
  },
  panel = {
    mode = "split",
    side = "right",
    width = 82,
    refresh_interval_ms = 500,
    history_limit = 200,
    floating = {
      width = 0.42,
      height = 0.86,
      row = 0.07,
      col = 0.56,
      border = "single",
    },
  },
  task_entry = {
    agent_type = "claude",
    agent_version = "latest",
    model = "sonnet",
    agent_count = 1,
    working_copy_mode = "in_place",
    task_executor_engine = "agent-harbor",
    acp_command_binary = nil,
    acp_command_args = {},
    llm_provider = nil,
    floating = {
      width = 0.58,
      height = 0.42,
      row = 0.12,
      col = 0.21,
      border = "single",
    },
  },
  reply = {
    overlay_height = 5,
  },
  voice = {
    mode = "click-to-talk",
    fixture_wav = nil,
    record_seconds = 2,
  },
  cross_task_files = "preview",
  workspace = {
    on_switch_modified = "prompt",
    floating = {
      width = 54,
      height = 8,
      border = "single",
    },
  },
  mux = {
    ah_command = "ah",
    nvim_client_command = "nvim",
    nvim_client_args = { "." },
    open_new_mode = "mux",
  },
  docs = {
    url = "https://docs.agent-harbor.com/editor-support/vim",
  },
}

M.options = vim.deepcopy(defaults)

local function deep_extend(base, override)
  return vim.tbl_deep_extend("force", base or {}, override or {})
end

local function validate_cross_task_files(mode)
  if mode == nil or mode == "preview" or mode == "switch" or mode == "new-tab" then
    return
  end
  error("unsupported agent-harbor cross_task_files mode: " .. tostring(mode))
end

function M.setup(opts)
  M.options = deep_extend(vim.deepcopy(defaults), opts or {})
  validate_cross_task_files(M.options.cross_task_files)
  return M.options
end

function M.get()
  return M.options
end

return M
