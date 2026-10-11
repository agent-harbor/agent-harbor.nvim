-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, "AgentHarborConnected", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AgentHarborStarting", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgentHarborDisconnected", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "AgentHarborPanelTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AgentHarborPanelMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AgentHarborPanelSelected", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "AgentHarborTimelineType", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AgentHarborTimelineSession", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AgentHarborTimelineStatus", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AgentHarborTimelineError", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "AgentHarborFeedbackBanner", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgentHarborFeedbackTaskRow", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "AgentHarborFeedbackAction", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AgentHarborPreviewBanner", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AgentHarborTaskEntryField", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AgentHarborTaskEntryEditable", { default = true, link = "String" })
end

function M.group_for_state(state)
  if state == "connected" then
    return "AgentHarborConnected"
  end
  if state == "starting" then
    return "AgentHarborStarting"
  end
  return "AgentHarborDisconnected"
end

return M
