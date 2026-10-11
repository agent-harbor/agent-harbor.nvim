-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local rest = require("agent-harbor.rest")

local uv = vim.uv or vim.loop

local M = {
  state = "disconnected",
  endpoint = nil,
  last_health = nil,
  last_capabilities = nil,
  last_error = nil,
  timer = nil,
  refresh_scheduled = false,
  process = nil,
}

local function env(name)
  local value = vim.env[name]
  if value == nil or value == "" then
    return nil
  end
  return value
end

local function process_env(extra)
  local result = {}
  for key, value in pairs(vim.fn.environ()) do
    table.insert(result, key .. "=" .. tostring(value))
  end
  for key, value in pairs(extra or {}) do
    table.insert(result, key .. "=" .. tostring(value))
  end
  return result
end

local function schedule_status_redraw()
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end

function M.resolve_pid_file()
  local opts = config.get().daemon
  if opts.pid_file then
    return opts.pid_file
  end
  if env("AH_WEBUI_PID_FILE") then
    return env("AH_WEBUI_PID_FILE")
  end
  if env("AH_HOME") then
    return env("AH_HOME") .. "/webui.pid"
  end
  if vim.fn.has("mac") == 1 then
    return vim.fn.expand("~/Library/Application Support/agent-harbor/webui.pid")
  end
  if vim.fn.has("win32") == 1 then
    local appdata = env("APPDATA") or vim.fn.expand("~/AppData/Roaming")
    return appdata .. "/agent-harbor/webui.pid"
  end
  local data_home = env("XDG_DATA_HOME") or vim.fn.expand("~/.local/share")
  return data_home .. "/agent-harbor/webui.pid"
end

function M.read_pid_file(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error("PID file missing: " .. path)
  end
  local lines = vim.fn.readfile(path)
  local ok, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(parsed) ~= "table" then
    error("webui.pid is not valid JSON")
  end
  if type(parsed.pid) ~= "number" or parsed.pid <= 0 then
    error("webui.pid has an invalid pid")
  end
  if type(parsed.port) ~= "number" or parsed.port <= 0 or parsed.port > 65535 then
    error("webui.pid has an invalid port")
  end
  if type(parsed.host) ~= "string" or parsed.host == "" then
    error("webui.pid has an invalid host")
  end
  if type(parsed.started_at) ~= "string" or parsed.started_at == "" then
    error("webui.pid has an invalid started_at timestamp")
  end
  return parsed
end

function M.pid_alive(pid)
  local ok, result, err = pcall(uv.kill, pid, 0)
  if not ok then
    return false
  end
  return result == 0 or result == true or err == "EPERM"
end

function M.endpoint_from_pid_file(pid_file)
  return rest.normalize_url(("http://%s:%d"):format(pid_file.host, pid_file.port))
end

function M.discover()
  local opts = config.get().daemon
  local pid_file_path = M.resolve_pid_file()
  local override = opts.url or env("AH_DAEMON_URL")
  if override and override ~= "" then
    local endpoint = rest.normalize_url(override)
    return {
      ok = true,
      endpoint = endpoint,
      pidFilePath = pid_file_path,
      pidFile = { pid = 0 },
      probe = rest.probe(endpoint, { timeout_ms = opts.probe_timeout_ms }),
    }
  end

  local pid_file = M.read_pid_file(pid_file_path)
  if not M.pid_alive(pid_file.pid) then
    error(("daemon pid %d is not alive"):format(pid_file.pid))
  end
  local endpoint = M.endpoint_from_pid_file(pid_file)
  return {
    ok = true,
    endpoint = endpoint,
    pidFilePath = pid_file_path,
    pidFile = pid_file,
    probe = rest.probe(endpoint, { timeout_ms = opts.probe_timeout_ms }),
  }
end

function M.start_process()
  local opts = config.get().daemon
  if vim.fn.executable(opts.executable) ~= 1 then
    error("Cannot find Agent Harbor executable: " .. opts.executable)
  end
  local pid_file = M.resolve_pid_file()
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle, pid_or_err = uv.spawn(opts.executable, {
    args = opts.start_args,
    env = process_env({ AH_WEBUI_PID_FILE = pid_file }),
    stdio = { nil, stdout, stderr },
    detached = true,
  }, function()
    if stdout and not stdout:is_closing() then
      stdout:close()
    end
    if stderr and not stderr:is_closing() then
      stderr:close()
    end
  end)
  if not handle then
    error("failed to start Agent Harbor daemon: " .. tostring(pid_or_err))
  end
  handle:unref()
  M.process = handle
  return handle
end

function M.refresh()
  M.state = "starting"
  local ok, discovery = pcall(M.discover)
  if ok then
    local probe = discovery.probe
    M.endpoint = discovery.endpoint
    M.last_health = probe.health
    M.last_capabilities = probe.capabilities
    M.last_error = nil
    M.state = "connected"
  else
    M.last_error = tostring(discovery)
    M.state = "disconnected"
    local opts = config.get().daemon
    if opts.auto_start and M.process == nil then
      local started, err = pcall(M.start_process)
      if started then
        M.state = "starting"
      else
        M.last_error = tostring(err)
      end
    end
  end
  schedule_status_redraw()
  return M.state
end

function M.status_message()
  M.refresh()
  if M.state == "connected" then
    return "Agent Harbor daemon connected: " .. tostring(M.endpoint)
  end
  if M.state == "starting" then
    return "Agent Harbor daemon starting"
  end
  return "Agent Harbor daemon disconnected: " .. tostring(M.last_error or "unknown error")
end

function M.start_monitor()
  if M.timer ~= nil then
    return M.timer
  end
  M.state = "starting"
  M.timer = uv.new_timer()
  M.timer:start(0, config.get().daemon.poll_interval_ms, function()
    if M.timer == nil or M.refresh_scheduled then
      return
    end
    M.refresh_scheduled = true
    vim.schedule(function()
      M.refresh_scheduled = false
      if M.timer == nil then
        return
      end
      M.refresh()
    end)
  end)
  return M.timer
end

function M.stop_monitor()
  M.refresh_scheduled = false
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
end

return M
