-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Neovim buffer setup for an Agent Harbor task or plan prompt.

local task_prompt = require("agent-harbor.task-prompt")

-- The hint block `ah` writes is comment-prefixed and stripped on return.
vim.bo.commentstring = "# %s"
vim.bo.omnifunc = "v:lua.require'agent-harbor.task-prompt'.omnifunc"
vim.bo.swapfile = false

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = true, silent = true, desc = desc })
end

map("i", "<C-Space>", task_prompt.complete, "Agent Harbor: complete prompt token")
map("n", "<leader>ac", task_prompt.complete, "Agent Harbor: complete prompt token")
map("n", "<C-s>", task_prompt.finish, "Agent Harbor: submit prompt")
map("n", "<leader>ak", task_prompt.abort, "Agent Harbor: abort task creation")

-- Auto-trigger: fire only when the token under the cursor qualifies, and only
-- when no popup is already open, so typing prose costs nothing. `complete()`
-- filters the open popup as the user types further, which is why this does not
-- need to re-query on every keystroke.
if vim.g.agent_harbor_task_prompt_autotrigger ~= false then
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = 0,
    group = vim.api.nvim_create_augroup("AgentHarborTaskPromptComplete", { clear = false }),
    desc = "Agent Harbor: open prompt completion on / ~ @",
    callback = function()
      task_prompt.complete()
    end,
  })
end
