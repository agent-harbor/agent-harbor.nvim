-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local panel = require("agent-harbor.panel")

vim.bo.readonly = true
vim.bo.modifiable = false
vim.bo.swapfile = false
vim.wo.foldmethod = "manual"
vim.wo.foldenable = true

local function map(lhs, rhs)
  vim.keymap.set("n", lhs, rhs, { buffer = true, silent = true })
end

map("<CR>", panel.select_task_at_cursor)
map("n", function()
  require("agent-harbor.task-entry").open()
end)
map("a", function()
  panel.quick_approve()
end)
map("r", function()
  panel.quick_reject()
end)
map("R", function()
  require("agent-harbor.reply").open_popup()
end)
map("s", function()
  panel.share_task()
end)
map("za", panel.toggle_accordion)
map("zo", panel.open_accordion)
map("zc", panel.close_accordion)
map("q", function()
  vim.cmd("close")
end)
