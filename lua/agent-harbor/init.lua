-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local highlights = require("agent-harbor.highlights")
local panel = require("agent-harbor.panel")
local reply = require("agent-harbor.reply")
local task_entry = require("agent-harbor.task-entry")
local mux = require("agent-harbor.mux")
local scm = require("agent-harbor.scm")
local uri = require("agent-harbor.uri")
local voice = require("agent-harbor.voice")
local branchfs = require("agent-harbor.branchfs")

local M = {}

local function icon_for_state(state)
  local icons = config.get().statusline.icons
  if state == "connected" then
    return icons.connected
  end
  if state == "starting" then
    return icons.starting
  end
  return icons.disconnected
end

function M.statusline()
  local suffix = vim.env.AH_SANDBOXED == "1" and " sandboxed" or ""
  return ("AH %s %s%s"):format(icon_for_state(daemon.state), daemon.state, suffix)
end

function M.native_statusline()
  return ("%%#%s#%s%%*"):format(highlights.group_for_state(daemon.state), M.statusline())
end

function M.lualine_component()
  return M.statusline()
end

local function define_commands()
  vim.api.nvim_create_user_command("AgentHarbor", function()
    panel.open()
  end, {})

  vim.api.nvim_create_user_command("AgentHarborNew", function()
    task_entry.open()
  end, {})

  vim.api.nvim_create_user_command("AgentHarborOpenNew", function(opts)
    mux.open_new(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
  })

  vim.api.nvim_create_user_command("AgentHarborShareTask", function(opts)
    panel.share_task(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
  })

  vim.api.nvim_create_user_command("AgentHarborGoto", function(opts)
    uri.open(opts.args)
  end, {
    nargs = 1,
  })

  vim.api.nvim_create_user_command("AgentHarborChanges", function()
    scm.open()
  end, {})

  vim.api.nvim_create_user_command("AgentHarborDocs", function()
    local url = config.get().docs.url
    if type(vim.ui.open) == "function" then
      vim.ui.open(url)
    else
      vim.fn.jobstart({ "xdg-open", url }, { detach = true })
    end
  end, {})

  vim.api.nvim_create_user_command("AgentHarborReply", function(opts)
    if opts.bang then
      reply.open_popup()
    else
      reply.submit_text(vim.fn.input("Agent Harbor reply: "))
    end
  end, { bang = true })

  vim.api.nvim_create_user_command("AgentHarborVoiceReply", function()
    voice.reply_submit()
  end, {})

  vim.api.nvim_create_user_command("AgentHarborVoice", function(opts)
    local mode = opts.args
    if mode == "start" then
      voice.always_on_start()
      return
    end
    if mode == "stop" then
      voice.always_on_stop()
      return
    end
    if mode == "finalize" then
      voice.always_on_finalize()
      return
    end
    if mode == "click-to-talk" or mode == "hold-to-talk" or mode == "always-on" or mode == "disabled" then
      config.get().voice.mode = mode
      return
    end
    error("unsupported AgentHarborVoice subcommand: " .. mode)
  end, {
    nargs = 1,
    complete = function()
      return { "click-to-talk", "hold-to-talk", "always-on", "disabled", "start", "stop", "finalize" }
    end,
  })

  vim.api.nvim_create_user_command("AgentHarborDaemon", function(opts)
    local subcommand = opts.args == "" and "status" or opts.args
    if subcommand ~= "status" then
      error("unsupported AgentHarborDaemon subcommand: " .. subcommand)
    end
    print(daemon.status_message())
  end, {
    nargs = "?",
    complete = function()
      return { "status" }
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  highlights.setup()
  define_commands()
  scm.setup()
  branchfs.setup()
  uri.register_ui_open()
  daemon.start_monitor()
  return M
end

M.config = config
M.daemon = daemon
M.rest = require("agent-harbor.rest")
M.sse = require("agent-harbor.sse")
M.events = require("agent-harbor.events")
M.models = require("agent-harbor.models")
M.highlights = highlights
M.mux = mux
M.panel = panel
M.reply = reply
M.voice = voice
M.task_entry = task_entry
M.scm = scm
M.branchfs = branchfs
M.uri = uri
M.workspace = require("agent-harbor.workspace")

return M
