-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

function M.side_panel_state()
  return require("agent-harbor.panel").side_panel_state()
end

function M.workspace_state()
  return require("agent-harbor.workspace").test_state()
end

function M.task_prompt_state()
  return require("agent-harbor.task-prompt").test_state()
end

function M.scm_state(root)
  return require("agent-harbor.scm").test_state(root)
end

function M.cross_task_preview_state()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  return {
    buffer = bufnr,
    window = vim.api.nvim_get_current_win(),
    tab = vim.api.nvim_get_current_tabpage(),
    tabCount = vim.fn.tabpagenr("$"),
    tabCwd = vim.fn.getcwd(-1, 0),
    name = vim.api.nvim_buf_get_name(bufnr),
    cwd = vim.fn.getcwd(0, 0),
    readOnly = vim.bo[bufnr].readonly,
    modifiable = vim.bo[bufnr].modifiable,
    preview = vim.b[bufnr].agent_harbor_preview == true,
    banner = vim.b[bufnr].agent_harbor_preview_banner,
    branchId = vim.b[bufnr].agent_harbor_preview_branch_id,
    path = vim.b[bufnr].agent_harbor_preview_path,
    root = vim.b[bufnr].agent_harbor_preview_root,
    workspace = require("agent-harbor.workspace").current_state(),
    content = table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""),
  }
end

return M
