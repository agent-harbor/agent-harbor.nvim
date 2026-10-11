-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

-- `:checkhealth agent-harbor`.
--
-- This is the consumer-visible half of the version coupling described in
-- `lua/agent-harbor/version.lua`: the plugin is published from the same
-- monorepo tag as the `ah` binary, but a user installs the two separately —
-- plugin through a plugin manager, `ah` through Homebrew, a release tarball or
-- Nix — so they drift. The failure that drift produces is a silent one: `/`
-- and `@` completion in a task prompt simply returns nothing, because
-- `ah autocomplete --json` is missing or too old. Reporting the mismatch here
-- is what turns that into a diagnosable condition.

local config = require("agent-harbor.config")
local version = require("agent-harbor.version")

local M = {}

-- `vim.health.start` and friends replaced the `report_*` spellings in Neovim
-- 0.10, which is also this plugin's floor (it uses `vim.system`). The shim
-- keeps `:checkhealth` usable on 0.9 instead of erroring out before it can
-- report that 0.9 is too old.
local health = vim.health or {}
local start = health.start or health.report_start
local ok_fn = health.ok or health.report_ok
local warn_fn = health.warn or health.report_warn
local error_fn = health.error or health.report_error

local NVIM_MIN = { 0, 10, 0 }

--- Run `ah --version` and return the raw first line, or nil plus a reason.
--- @param executable string
--- @return string|nil output
--- @return string|nil err
local function ah_version_output(executable)
  local resolved = vim.fn.exepath(executable)
  if resolved == "" then
    return nil, ("%q is not on PATH"):format(executable)
  end
  local completed = vim.system({ resolved, "--version" }, { text = true }):wait(5000)
  if completed.code ~= 0 then
    return nil, ("%s --version exited with %s: %s"):format(
      resolved,
      tostring(completed.code),
      vim.trim(completed.stderr or "")
    )
  end
  return vim.trim((completed.stdout or ""):gsub("\n.*", "")), nil
end

local function check_nvim()
  start("agent-harbor: Neovim")
  local v = vim.version()
  local got = { v.major, v.minor, v.patch }
  if version.compare(got, NVIM_MIN) < 0 then
    error_fn(
      ("Neovim %d.%d.%d is older than the required %d.%d.%d"):format(
        got[1], got[2], got[3], NVIM_MIN[1], NVIM_MIN[2], NVIM_MIN[3]
      ),
      { "Upgrade Neovim; the plugin calls vim.system(), added in 0.10." }
    )
  else
    ok_fn(("Neovim %d.%d.%d"):format(got[1], got[2], got[3]))
  end
end

local function check_plugin_version()
  start("agent-harbor: plugin")
  if version.is_dev() then
    warn_fn(
      ("plugin version %s (unreleased)"):format(version.version),
      { "This is a monorepo checkout, not a published release. Expected when developing the plugin." }
    )
  else
    ok_fn(("plugin version %s"):format(version.version))
  end
end

--- @return string|nil reported version, for the caller to reuse
local function check_ah_binary()
  start("agent-harbor: ah binary")
  local executable = config.get().daemon.executable
  local output, err = ah_version_output(executable)
  if not output then
    error_fn(err, {
      "Install the `ah` CLI: https://docs.agent-harbor.com/installation",
      ("Or point the plugin at it: require('agent-harbor').setup({ daemon = { executable = '/path/to/ah' } }), currently %q."):format(
        executable
      ),
    })
    return nil
  end

  ok_fn(("found %s — %s"):format(vim.fn.exepath(executable), output))

  local satisfied, floor, development = version.satisfies_ah_min(output)
  if satisfied == nil and development then
    warn_fn(
      ("%s is a development build, below the required ah %s"):format(output, floor),
      {
        "A build from a branch carries the version of the last release behind it,",
        "so its number cannot say whether it has what this plugin calls.",
        "The next check is the one that actually answers it.",
      }
    )
  elseif satisfied == nil then
    warn_fn(
      ("cannot read a version number out of %q"):format(output),
      { ("This plugin needs ah %s or newer; check it by hand."):format(floor) }
    )
  elseif not satisfied then
    error_fn(
      ("%s is older than the required ah %s"):format(output, floor),
      {
        "Completion in task prompts calls `ah autocomplete --json` and will return nothing.",
        "Upgrade `ah`, or install a plugin version matching your `ah`.",
      }
    )
  else
    ok_fn(("satisfies the ah >= %s requirement"):format(floor))
  end
  return output
end

local function check_autocomplete(ah_reported)
  start("agent-harbor: task-prompt completion")
  if not ah_reported then
    warn_fn("skipped: the `ah` binary was not found")
    return
  end
  local executable = vim.fn.exepath(config.get().daemon.executable)
  local completed = vim.system({ executable, "autocomplete", "--help" }, { text = true }):wait(5000)
  if completed.code ~= 0 then
    error_fn(
      ("`ah autocomplete --help` exited with %s"):format(tostring(completed.code)),
      { "`/` and `@` completion in *.ahtask and *.ahplan buffers depends on this subcommand." }
    )
  else
    ok_fn("`ah autocomplete` is available")
  end
end

local function check_daemon()
  start("agent-harbor: daemon")
  -- Required lazily: requiring it at module scope would make `:checkhealth`
  -- drag in the REST and SSE stack before it can report anything at all.
  local okay, daemon = pcall(require, "agent-harbor.daemon")
  if not okay then
    error_fn(("cannot load agent-harbor.daemon: %s"):format(tostring(daemon)))
    return
  end
  local okay_status, message = pcall(daemon.status_message)
  if not okay_status then
    warn_fn(("daemon status unavailable: %s"):format(tostring(message)))
    return
  end
  if message:match("^Agent Harbor daemon connected") then
    ok_fn(message)
  else
    -- Not an error: the plugin starts the daemon on demand, and a disconnected
    -- daemon is the normal state before the first task.
    warn_fn(message, { "Run `ah daemon serve`, or set daemon.auto_start = true." })
  end
end

function M.check()
  check_nvim()
  check_plugin_version()
  local ah_reported = check_ah_binary()
  check_autocomplete(ah_reported)
  check_daemon()
end

return M
