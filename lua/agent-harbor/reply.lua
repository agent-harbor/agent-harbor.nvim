-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {}

local state = {
  bufnr = nil,
  winid = nil,
  task_id = nil,
  feedback = nil,
  last_error = nil,
  last_response = nil,
  popup_bufnr = nil,
}

M.state = state

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

function M.feedback_id(feedback)
  return get(feedback, "id")
end

function M.feedback_type(feedback)
  return get(feedback, "type") or "question"
end

function M.feedback_question(feedback)
  return get(feedback, "question") or "Feedback required"
end

local function trim(value)
  return vim.trim(tostring(value or ""))
end

function M.build_payload(feedback, text)
  local body = trim(text)
  local feedback_type = M.feedback_type(feedback)
  if feedback_type == "question" or feedback_type == "custom_form" then
    if body == "" then
      return nil
    end
    return { response = { text = body } }
  end
  if feedback_type == "confirmation" then
    if body == "" then
      return nil
    end
    return { response = { confirmed = true }, comment = body }
  end
  if feedback_type == "information" then
    local payload = { response = { acknowledged = true } }
    if body ~= "" then
      payload.comment = body
    end
    return payload
  end
  return nil
end

function M.quick_payload(feedback, approved, comment)
  if M.feedback_type(feedback) ~= "confirmation" then
    error("Quick approve/reject is available only for confirmation feedback")
  end
  local payload = { response = { confirmed = approved and true or false } }
  local body = trim(comment)
  if body ~= "" then
    payload.comment = body
  end
  return payload
end

local function current_target()
  local panel = require("agent-harbor.panel")
  local task_id = panel.selected_task_id()
  local feedback = task_id and panel.pending_feedback_for_task(task_id) or nil
  if not task_id or not feedback then
    error("No pending Agent Harbor feedback for the selected task")
  end
  return task_id, feedback
end

function M.submit_payload(task_id, feedback, payload)
  daemon.refresh()
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("daemon endpoint is not discovered")
  end
  local response = rest.respond_feedback(
    daemon.endpoint,
    task_id,
    M.feedback_id(feedback),
    payload,
    { timeout_ms = 10000 }
  )
  state.last_response = response
  state.last_error = nil
  require("agent-harbor.panel").refresh()
  return response
end

function M.submit_text(text, task_id, feedback)
  if not (task_id and feedback) then
    task_id, feedback = current_target()
  end
  local payload = M.build_payload(feedback, text)
  if not payload then
    error("Feedback response is required or unsupported")
  end
  return M.submit_payload(task_id, feedback, payload)
end

function M.quick_approve(comment)
  local task_id, feedback = current_target()
  return M.submit_payload(task_id, feedback, M.quick_payload(feedback, true, comment))
end

function M.quick_reject(comment)
  local task_id, feedback = current_target()
  return M.submit_payload(task_id, feedback, M.quick_payload(feedback, false, comment))
end

local function overlay_lines(task_id, feedback)
  local lines = {
    ("Feedback required for %s (%s)"):format(task_id or "", M.feedback_id(feedback) or ""),
    M.feedback_question(feedback),
    "Reply: :AgentHarborReply! for multi-line",
  }
  if M.feedback_type(feedback) == "confirmation" then
    table.insert(lines, "Actions: [Approve] [Reject]")
  end
  if state.last_error then
    table.insert(lines, "Error: " .. state.last_error)
  end
  return lines
end

function M.clear_overlay()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
  state.bufnr = nil
  state.task_id = nil
  state.feedback = nil
end

function M.render_overlay(panel_winid, task_id, feedback)
  if not feedback or not panel_winid or not vim.api.nvim_win_is_valid(panel_winid) then
    M.clear_overlay()
    return
  end
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, "Agent Harbor Reply Overlay")
    vim.bo[state.bufnr].buftype = "nofile"
    vim.bo[state.bufnr].bufhidden = "wipe"
    vim.bo[state.bufnr].swapfile = false
  end
  state.task_id = task_id
  state.feedback = feedback
  local height = math.max(3, config.get().reply.overlay_height or 5)
  local width = math.max(24, vim.api.nvim_win_get_width(panel_winid) - 2)
  local panel_pos = vim.api.nvim_win_get_position(panel_winid)
  local panel_height = vim.api.nvim_win_get_height(panel_winid)
  local panel_width = vim.api.nvim_win_get_width(panel_winid)
  local row = panel_pos[1] + math.max(0, panel_height - height - 1)
  local col = panel_pos[2] + math.max(0, panel_width - width - 1)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    state.winid = vim.api.nvim_open_win(state.bufnr, false, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "single",
      focusable = false,
      zindex = 60,
    })
  else
    vim.api.nvim_win_set_config(state.winid, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "single",
      focusable = false,
      zindex = 60,
    })
  end
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, overlay_lines(task_id, feedback))
  vim.bo[state.bufnr].modifiable = false
end

function M.open_popup()
  local task_id, feedback = current_target()
  local bufnr = vim.api.nvim_create_buf(false, true)
  state.popup_bufnr = bufnr
  vim.api.nvim_buf_set_name(bufnr, "Agent Harbor Reply")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "agent-harbor-reply"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.b[bufnr].agent_harbor_task_id = task_id
  vim.b[bufnr].agent_harbor_feedback = feedback
  vim.keymap.set("n", "<C-c><C-c>", M.popup_submit, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<C-c><C-k>", function()
    vim.cmd("close")
  end, { buffer = bufnr, silent = true })
  return bufnr
end

function M.popup_submit()
  local bufnr = vim.api.nvim_get_current_buf()
  local task_id = vim.b[bufnr].agent_harbor_task_id
  local feedback = vim.b[bufnr].agent_harbor_feedback
  if not task_id or not feedback then
    error("Agent Harbor reply buffer is not bound to feedback")
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local ok, response = pcall(M.submit_text, text, task_id, feedback)
  if not ok then
    state.last_error = tostring(response)
    error(response)
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return response
end

function M.test_state()
  return {
    visible = state.winid and vim.api.nvim_win_is_valid(state.winid) or false,
    taskId = state.task_id,
    feedbackId = state.feedback and M.feedback_id(state.feedback) or nil,
    voiceEnabled = require("agent-harbor.config").get().voice.mode ~= "disabled",
    lastError = state.last_error,
    lastResponse = state.last_response,
    popupVisible = state.popup_bufnr and vim.api.nvim_buf_is_valid(state.popup_bufnr) or false,
  }
end

return M
