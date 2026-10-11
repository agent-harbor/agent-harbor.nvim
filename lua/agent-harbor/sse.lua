-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local uv = vim.uv or vim.loop

local M = {}

local Client = {}
Client.__index = Client

local function decode_event(client, lines)
  local event = "message"
  local data_lines = {}
  local id = nil
  local retry = nil

  for _, line in ipairs(lines) do
    if line:sub(1, 1) ~= ":" then
      if line:sub(1, 6) == "event:" then
        event = vim.trim(line:sub(7))
      elseif line:sub(1, 5) == "data:" then
        table.insert(data_lines, vim.trim(line:sub(6)))
      elseif line:sub(1, 3) == "id:" then
        id = vim.trim(line:sub(4))
      elseif line:sub(1, 6) == "retry:" then
        retry = tonumber(vim.trim(line:sub(7)))
      end
    end
  end

  if id and id ~= "" then
    client.last_event_id = id
  end
  if retry and retry > 0 then
    client.retry_delay_ms = retry
  end
  if #data_lines == 0 then
    return nil
  end

  local raw = table.concat(data_lines, "\n")
  local ok, data = pcall(vim.json.decode, raw)
  return {
    event = event,
    data = ok and data or raw,
    id = id,
  }
end

local function dispatch_frame(client)
  local frame = decode_event(client, client.event_lines)
  client.event_lines = {}
  if frame then
    vim.schedule(function()
      if not client.closed then
        client.callback(frame)
      end
    end)
  end
end

local function handle_line(client, line)
  line = line:gsub("\r$", "")
  if vim.trim(line) == "" then
    dispatch_frame(client)
  else
    table.insert(client.event_lines, line)
  end
end

local function handle_chunk(client, chunk)
  local text = (client.partial or "") .. chunk
  local complete = text:sub(-1) == "\n"
  local lines = vim.split(text, "\n", { plain = true })
  if not complete then
    client.partial = table.remove(lines)
  else
    client.partial = nil
  end
  for _, line in ipairs(lines) do
    handle_line(client, line)
  end
end

function Client:schedule_reconnect()
  if self.closed then
    return
  end
  local delay = self.retry_delay_ms
  self.retry_delay_ms = math.min(self.max_retry_delay_ms, delay * 2)
  self.reconnect_timer = uv.new_timer()
  self.reconnect_timer:start(delay, 0, function()
    if self.reconnect_timer and not self.reconnect_timer:is_closing() then
      self.reconnect_timer:close()
    end
    self.reconnect_timer = nil
    vim.schedule(function()
      if not self.closed then
        self:start()
      end
    end)
  end)
end

function Client:start()
  if vim.fn.executable("curl") ~= 1 then
    error("curl is required for Agent Harbor SSE")
  end
  self:close_process_only()
  self.closed = false
  self.partial = nil
  self.event_lines = {}

  local args = {
    "--noproxy",
    "*",
    "--no-buffer",
    "--silent",
    "--show-error",
    "--location",
    "--header",
    "Accept: text/event-stream",
  }
  if self.last_event_id then
    vim.list_extend(args, { "--header", "Last-Event-ID: " .. self.last_event_id })
  end
  table.insert(args, self.url)

  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)
  self.handle = uv.spawn("curl", {
    args = args,
    stdio = { nil, self.stdout, self.stderr },
  }, function(code, signal)
    self:close_process_only()
    if not self.closed then
      if self.error_callback then
        vim.schedule(function()
          self.error_callback({ code = code, signal = signal })
        end)
      end
      self:schedule_reconnect()
    end
  end)
  if not self.handle then
    error("failed to start curl for Agent Harbor SSE")
  end

  self.stdout:read_start(function(err, data)
    if err and self.error_callback then
      vim.schedule(function()
        self.error_callback(err)
      end)
    end
    if data then
      handle_chunk(self, data)
    end
  end)
  self.stderr:read_start(function() end)
  return self
end

function Client:close_process_only()
  if self.stdout and not self.stdout:is_closing() then
    self.stdout:read_stop()
    self.stdout:close()
  end
  if self.stderr and not self.stderr:is_closing() then
    self.stderr:read_stop()
    self.stderr:close()
  end
  if self.handle and not self.handle:is_closing() then
    self.handle:kill("sigterm")
    self.handle:close()
  end
  self.stdout = nil
  self.stderr = nil
  self.handle = nil
end

function Client:close()
  self.closed = true
  if self.reconnect_timer and not self.reconnect_timer:is_closing() then
    self.reconnect_timer:stop()
    self.reconnect_timer:close()
  end
  self.reconnect_timer = nil
  self:close_process_only()
end

function M.open(url, callback, error_callback, opts)
  opts = opts or {}
  local client = setmetatable({
    url = url,
    callback = callback,
    error_callback = error_callback,
    retry_delay_ms = opts.retry_delay_ms or 250,
    max_retry_delay_ms = opts.max_retry_delay_ms or 5000,
    event_lines = {},
    closed = false,
  }, Client)
  return client:start()
end

return M
