-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local models = require("agent-harbor.models")

local M = {}

-- Per-request REST timeout used by every editor-side daemon poll path.
--
-- 5 s is the deliberate ceiling for editor panel refreshes under realistic
-- load. The editor panels are not real-time UIs; their convergence loops
-- already cap how often they refresh, so a single REST call is allowed to
-- spend up to 5 s without hurting interactivity. Under the full
-- `just test-rust` parallel matrix the host load routinely exceeds 200 —
-- the daemon is healthy but its tokio workers are scheduled against the
-- background CPU storm. The previous 2 s default (and the explicit 1.5 s
-- overrides scattered across panel.lua / scm.lua / branchfs.lua) routinely
-- surfaced as `curl: (28) Operation timed out after 1503 milliseconds with
-- 0 bytes received` in the panel error and `tasks: []` in panel state,
-- which is the entire `ide-e2e-*` failure cluster — the daemon never
-- replies because its accept loop hasn't been scheduled, not because the
-- request itself is slow. See
-- `docs/contributors/how-to-solve-test-concurrency-issues.md` for the
-- general policy on workspace-load-sensitive deadlines.
M.default_timeout_ms = 5000

-- A probe's budget must bound the probe.
--
-- `M.health` walks three candidate URLs and `M.probe` then asks for
-- capabilities, and each of those calls used to be handed the FULL `timeout_ms`
-- independently: a probe documented as spending at most `M.default_timeout_ms`
-- could block its caller for four times that. `daemon.start_monitor` runs this
-- probe *synchronously* from a libuv timer whose period is
-- `daemon.poll_interval_ms` (100 ms in the editor e2e suites), so an unbounded
-- probe owns Neovim's main loop for as long as it runs. That is how a
-- `vim.wait(15000, …)` convergence loop in `scenario_neovim_share_task` was
-- measured still polling 38.7 s after it started, and why the panel's own
-- asynchronous fetches expired against their 5 s ceiling while the loop was
-- blocked and never loaded a task.
--
-- Give a probe one deadline and spend the *remaining* budget on each call, so
-- `timeout_ms` bounds the whole probe rather than each of its parts. This only
-- tightens an operation to its own declared bound; no budget grows.
local PROBE_MIN_CALL_TIMEOUT_MS = 250

-- Monotonic milliseconds. Deliberately `hrtime` and not `uv.now()`: the loop
-- clock is refreshed once per loop iteration, so it does not advance across a
-- blocking `vim.system(...):wait()` — exactly the interval a deadline here has
-- to measure.
local function monotonic_ms()
  local uv = vim.uv or vim.loop
  return math.floor(uv.hrtime() / 1e6)
end

local function deadline_from(opts)
  opts = opts or {}
  return opts.deadline_ms or (monotonic_ms() + (opts.timeout_ms or M.default_timeout_ms))
end

-- `opts` with `timeout_ms` reduced to whatever is left of `deadline_ms`, never
-- below a floor: a nearly-exhausted budget still issues a bounded call rather
-- than a zero or negative one, so the remaining candidates are still tried.
local function within_deadline(opts, deadline_ms)
  local remaining = deadline_ms - monotonic_ms()
  if remaining < PROBE_MIN_CALL_TIMEOUT_MS then
    remaining = PROBE_MIN_CALL_TIMEOUT_MS
  end
  return vim.tbl_extend("force", opts or {}, { timeout_ms = remaining })
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.normalize_url(url)
  if type(url) ~= "string" or trim(url) == "" then
    error("daemon URL is empty")
  end
  local normalized = trim(url)
  if not normalized:match("^[%a][%w+.-]*://") then
    normalized = "http://" .. normalized
  end
  return normalized:gsub("/+$", "")
end

function M.api_base_url(base_url)
  return M.normalize_url(base_url) .. "/api/v1"
end

local function decode_json(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then
    error("failed to decode daemon JSON response: " .. tostring(decoded))
  end
  return decoded
end

local function encode_json(body)
  if body == nil then
    return nil
  end
  return vim.json.encode(body)
end

local function path_escape(value)
  value = tostring(value or "")
  if type(vim.uri_encode) == "function" then
    local ok, encoded = pcall(vim.uri_encode, value, "rfc3986")
    if ok then
      return encoded
    end
    ok, encoded = pcall(vim.uri_encode, value)
    if ok then
      return encoded
    end
  end
  return (value:gsub("([^A-Za-z0-9_.~-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

-- Sentinel returned by `plenary_request` to indicate that plenary itself
-- is not available (or its API does not expose the calls we need); this is
-- the only condition under which `json_request` falls back to the `curl`
-- subprocess path. Any other failure (timeout, HTTP non-2xx, transport
-- error) is propagated as-is — retrying with `curl` after plenary already
-- spent its full `timeout_ms` budget only doubled the worst-case wall
-- clock per call and made the editor panel refresh exceed its 15 s wait
-- deadline under the full-suite parallel load.
local PLENARY_UNAVAILABLE = "plenary.curl is unavailable"

local function plenary_request(method, url, body, timeout_ms, expected_head)
  local ok, curl = pcall(require, "plenary.curl")
  if not ok then
    return nil, PLENARY_UNAVAILABLE
  end

  local opts = {
    url = url,
    method = method,
    timeout = timeout_ms,
    headers = { ["Accept"] = "application/json" },
  }
  if body ~= nil then
    opts.body = encode_json(body)
    opts.headers["Content-Type"] = "application/json"
  end
  if expected_head then
    opts.headers["If-Match"] = '"' .. tostring(expected_head) .. '"'
  end

  local response
  if type(curl.request) == "function" then
    response = curl.request(opts)
  elseif method == "GET" and type(curl.get) == "function" then
    response = curl.get(url, opts)
  elseif method == "POST" and type(curl.post) == "function" then
    response = curl.post(url, opts)
  else
    return nil, PLENARY_UNAVAILABLE
  end

  local status = tonumber(response.status or response.status_code or 0)
  if status < 200 or status >= 300 then
    error(("daemon request failed for %s with HTTP %s: %s"):format(url, status, response.body or ""))
  end
  return decode_json(response.body or "")
end

local function system_request(method, url, body, timeout_ms, expected_head)
  if type(vim.system) ~= "function" then
    error("vim.system is required when plenary.curl is unavailable")
  end

  local args = {
    "curl",
    "--noproxy",
    "*",
    "--fail-with-body",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    string.format("%.3f", timeout_ms / 1000),
    "--request",
    method,
    "--header",
    "Accept: application/json",
  }
  if body ~= nil then
    vim.list_extend(args, {
      "--header",
      "Content-Type: application/json",
      "--data-binary",
      encode_json(body),
    })
  end
  if expected_head then
    vim.list_extend(args, { "--header", 'If-Match: "' .. tostring(expected_head) .. '"' })
  end
  table.insert(args, url)

  local result = vim.system(args, { text = true }):wait(timeout_ms + 500)
  if not result then
    error(("curl request timed out for %s"):format(url))
  end
  if result.code ~= 0 then
    error(
      ("curl request failed for %s: %s%s"):format(
        url,
        result.stderr or result.code,
        result.stdout and result.stdout ~= "" and ("\n" .. result.stdout) or ""
      )
    )
  end
  return decode_json(result.stdout or "")
end

local function system_bytes_request(method, url, body, timeout_ms, content_type, expected_head)
  if type(vim.system) ~= "function" then
    error("vim.system is required for daemon byte requests")
  end

  local args = {
    "curl",
    "--noproxy",
    "*",
    "--fail-with-body",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    string.format("%.3f", timeout_ms / 1000),
    "--request",
    method,
  }
  if body ~= nil then
    vim.list_extend(args, {
      "--header",
      "Content-Type: " .. (content_type or "application/octet-stream"),
      "--data-binary",
      "@-",
    })
  end
  if expected_head then
    vim.list_extend(args, { "--header", 'If-Match: "' .. tostring(expected_head) .. '"' })
  end
  table.insert(args, url)

  local result = vim.system(args, { stdin = body, text = false }):wait(timeout_ms + 500)
  if not result then
    error(("curl byte request timed out for %s"):format(url))
  end
  if result.code ~= 0 then
    error(
      ("curl byte request failed for %s: %s%s"):format(
        url,
        result.stderr or result.code,
        result.stdout and result.stdout ~= "" and ("\n" .. result.stdout) or ""
      )
    )
  end
  return result.stdout or ""
end

function M.json_request(method, url, body, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or M.default_timeout_ms
  -- Try the in-process plenary.curl path first.  Three outcomes:
  --   1. Success (`ok=true, result~=nil`) -> return immediately.
  --   2. plenary is genuinely unavailable (`ok=true, result==nil` plus the
  --      `PLENARY_UNAVAILABLE` sentinel in `err`) -> fall back to the
  --      `curl` subprocess path so the editor still works on minimal
  --      configs (e.g. Neovim without plenary).
  --   3. Any other failure (timeout, HTTP non-2xx, transport error) ->
  --      fall back to `system_request` as well, but with a 1 s budget so
  --      the worst-case per-call wall clock stays bounded.  Retrying
  --      through `system_request` with the full `timeout_ms` after
  --      plenary already consumed it doubled the per-call cost under
  --      heavy load and was what surfaced the full-suite editor
  --      timeouts.  See `M.default_timeout_ms` rationale above.
  local ok, result, err = pcall(plenary_request, method, url, body, timeout_ms, opts.expected_head)
  if ok and result ~= nil then
    return result
  end
  if ok and err == PLENARY_UNAVAILABLE then
    return system_request(method, url, body, timeout_ms, opts.expected_head)
  end
  -- plenary errored on this call (HTTP failure / curl exit / transport).
  -- Give system_request a short rescue window — long enough to catch a
  -- transient SO_REUSEPORT race or a momentary plenary glitch, but
  -- short enough that the wait-state loop still re-tries the full
  -- refresh on the next iteration.
  local rescue_timeout = math.min(timeout_ms, 1000)
  return system_request(method, url, body, rescue_timeout, opts.expected_head)
end

-- Asynchronous GET that returns control to the caller immediately. The
-- response is delivered to `callback(ok, result_or_error)` on the main loop
-- via `vim.schedule`, so callers can mutate editor state / redraw safely. When
-- plenary.curl is unavailable we fall back to `vim.system` (its callback form
-- already runs off the main loop) and marshal the decoded result back with
-- `vim.schedule`. This is the non-blocking counterpart to `M.json_request`
-- used by the panel's refresh sweep; the synchronous path is retained for the
-- action/command code paths that still need an immediate value.
function M.get_json_async(url, callback, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or M.default_timeout_ms

  local function finish(ok, value)
    vim.schedule(function()
      callback(ok, value)
    end)
  end

  local ok_curl, curl = pcall(require, "plenary.curl")
  if ok_curl and type(curl.request) == "function" then
    local request_ok, request_err = pcall(curl.request, {
      url = url,
      method = "GET",
      timeout = timeout_ms,
      headers = { ["Accept"] = "application/json" },
      callback = function(response)
        local status = tonumber(response and (response.status or response.status_code) or 0)
        if status < 200 or status >= 300 then
          finish(false, ("daemon request failed for %s with HTTP %s"):format(url, status))
          return
        end
        local decode_ok, decoded = pcall(decode_json, response.body or "")
        if not decode_ok then
          finish(false, tostring(decoded))
        else
          finish(true, decoded)
        end
      end,
    })
    if not request_ok then
      finish(false, tostring(request_err))
    end
    return
  end

  if type(vim.system) ~= "function" then
    finish(false, "no async HTTP backend available (need plenary.curl or vim.system)")
    return
  end

  local args = {
    "curl",
    "--noproxy",
    "*",
    "--fail-with-body",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    string.format("%.3f", timeout_ms / 1000),
    "--request",
    "GET",
    "--header",
    "Accept: application/json",
    url,
  }
  local spawn_ok, spawn_err = pcall(vim.system, args, { text = true }, function(result)
    if not result or result.code ~= 0 then
      finish(false, ("curl request failed for %s: %s"):format(url, result and (result.stderr or result.code) or "no result"))
      return
    end
    local decode_ok, decoded = pcall(decode_json, result.stdout or "")
    if not decode_ok then
      finish(false, tostring(decoded))
    else
      finish(true, decoded)
    end
  end)
  if not spawn_ok then
    finish(false, tostring(spawn_err))
  end
end

function M.bytes_request(method, url, body, opts)
  opts = opts or {}
  return system_bytes_request(method, url, body, opts.timeout_ms or M.default_timeout_ms, opts.content_type, opts.expected_head)
end

function M.get_json(url, opts)
  return M.json_request("GET", url, nil, opts)
end

function M.post_json(url, body, opts)
  return M.json_request("POST", url, body or {}, opts)
end

function M.delete_json(url, opts)
  return M.json_request("DELETE", url, nil, opts)
end

-- Probe the daemon's health, trying each documented endpoint in turn.
--
-- The three candidates share one budget (see `PROBE_MIN_CALL_TIMEOUT_MS`): an
-- unreachable daemon must cost the caller `timeout_ms`, not three times it.
function M.health(base_url, opts)
  opts = opts or {}
  local deadline = deadline_from(opts)
  local normalized = M.normalize_url(base_url)
  local candidates = {
    normalized .. "/api/v1/healthz",
    normalized .. "/api/health",
    normalized .. "/health",
  }
  local last_error
  for _, url in ipairs(candidates) do
    local ok, response = pcall(M.get_json, url, within_deadline(opts, deadline))
    if ok then
      return response
    end
    last_error = response
  end
  error(last_error or "daemon health probe failed")
end

function M.capabilities(base_url, opts)
  opts = opts or {}
  local call_opts = opts.deadline_ms and within_deadline(opts, opts.deadline_ms) or opts
  return M.get_json(M.api_base_url(base_url) .. "/platform/capabilities", call_opts)
end

-- Health plus capabilities, bounded as a whole by `timeout_ms`.
function M.probe(base_url, opts)
  opts = opts or {}
  local normalized = M.normalize_url(base_url)
  local budgeted = vim.tbl_extend("force", opts, { deadline_ms = deadline_from(opts) })
  return {
    baseUrl = normalized,
    apiBaseUrl = M.api_base_url(normalized),
    health = M.health(normalized, budgeted),
    capabilities = M.capabilities(normalized, budgeted),
    probedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

function M.list_tasks(base_url, opts)
  local response = M.get_json(M.api_base_url(base_url) .. "/tasks", opts)
  local tasks = response.tasks or {}
  return vim.tbl_map(models.task_from_json, tasks)
end

function M.list_sessions(base_url, opts)
  local response = M.get_json(M.api_base_url(base_url) .. "/sessions?perPage=100", opts)
  return response.items or {}
end

function M.task_sessions(base_url, task_id, opts)
  local response = M.get_json(M.api_base_url(base_url) .. "/tasks/" .. path_escape(task_id) .. "/sessions", opts)
  local sessions = response.sessions or {}
  return vim.tbl_map(models.task_session_from_json, sessions)
end

function M.session_history(base_url, session_id, opts)
  opts = opts or {}
  local limit = opts.limit or 200
  return M.get_json(
    M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/events/history?limit=" .. tostring(limit),
    opts
  )
end

function M.task_diff(base_url, task_id, opts)
  return M.get_json(M.api_base_url(base_url) .. "/tasks/" .. path_escape(task_id) .. "/diff", opts)
end

function M.session_files(base_url, session_id, opts)
  opts = opts or {}
  local per_page = opts.per_page or opts.perPage or 100
  return M.get_json(
    M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/files?perPage=" .. tostring(per_page),
    opts
  )
end

function M.session_file_content(base_url, session_id, path, snapshot_id, opts)
  local url = M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/files/content/" .. path_escape(path)
  if snapshot_id then
    url = url .. "?snapshotId=" .. path_escape(snapshot_id)
  end
  return M.bytes_request("GET", url, nil, opts)
end

function M.branch_file_content(base_url, branch_id, path, opts)
  return M.bytes_request(
    "GET",
    M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id) .. "/files/" .. path_escape(path),
    nil,
    opts
  )
end

local function query_string(params)
  local parts = {}
  for key, value in pairs(params or {}) do
    if value ~= nil then
      table.insert(parts, path_escape(key) .. "=" .. path_escape(value))
    end
  end
  table.sort(parts)
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

function M.agentharborfs_branch_manifest(base_url, branch_id, opts)
  opts = opts or {}
  return M.get_json(
    M.api_base_url(base_url)
      .. "/agentharborfs/branches/"
      .. path_escape(branch_id)
      .. "/manifest"
      .. query_string({
        prefix = opts.prefix,
        cursor = opts.cursor,
        limit = opts.limit,
        token = opts.token,
      }),
    opts
  )
end

function M.agentharborfs_snapshot_manifest(base_url, snapshot_id, opts)
  opts = opts or {}
  return M.get_json(
    M.api_base_url(base_url)
      .. "/agentharborfs/snapshots/"
      .. path_escape(snapshot_id)
      .. "/manifest"
      .. query_string({
        prefix = opts.prefix,
        cursor = opts.cursor,
        limit = opts.limit,
        token = opts.token,
      }),
    opts
  )
end

function M.agentharborfs_blob(base_url, algorithm, hash, opts)
  opts = opts or {}
  return M.bytes_request(
    "GET",
    M.api_base_url(base_url)
      .. "/agentharborfs/blobs/"
      .. path_escape(algorithm or "b3")
      .. "/"
      .. path_escape(hash)
      .. query_string({ token = opts.token }),
    nil,
    opts
  )
end

function M.agentharborfs_branch_prefetch(base_url, branch_id, opts)
  opts = opts or {}
  return M.post_json(
    M.api_base_url(base_url) .. "/agentharborfs/branches/" .. path_escape(branch_id) .. "/prefetch",
    {
      prefixes = opts.prefixes,
      globs = opts.globs,
      limit = opts.limit,
    },
    opts
  )
end

function M.write_branch_file(base_url, branch_id, path, bytes, opts)
  return decode_json(M.bytes_request(
    "PUT",
    M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id) .. "/files/" .. path_escape(path),
    bytes,
    vim.tbl_extend("force", opts or {}, { content_type = "application/octet-stream" })
  ))
end

function M.create_branch_directory(base_url, branch_id, path, opts)
  return M.post_json(
    M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id) .. "/directories/" .. path_escape(path),
    nil,
    opts
  )
end

function M.delete_branch_path(base_url, branch_id, path, opts)
  return decode_json(M.bytes_request(
    "DELETE",
    M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id) .. "/files/" .. path_escape(path),
    nil,
    opts
  ))
end

function M.move_branch_path(base_url, branch_id, from, to, overwrite, opts)
  return M.post_json(
    M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id) .. "/moves",
    { from = from, to = to, overwrite = overwrite == true },
    opts
  )
end

function M.session_file_diff(base_url, session_id, path, opts)
  return M.get_json(
    M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/diff/" .. path_escape(path),
    opts
  )
end

function M.session_diff(base_url, session_id, opts)
  return M.get_json(M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/diff", opts)
end

function M.checkpoint_session(base_url, session_id, message, opts)
  return M.post_json(
    M.api_base_url(base_url) .. "/sessions/" .. path_escape(session_id) .. "/checkpoint",
    { message = message },
    opts
  )
end

function M.create_task(base_url, payload, opts)
  return M.post_json(M.api_base_url(base_url) .. "/tasks", payload, opts)
end

function M.list_feedback(base_url, task_id, opts)
  local response = M.get_json(M.api_base_url(base_url) .. "/tasks/" .. path_escape(task_id) .. "/feedback", opts)
  return response.items or {}
end

function M.respond_feedback(base_url, task_id, feedback_id, payload, opts)
  return M.post_json(
    M.api_base_url(base_url)
      .. "/tasks/"
      .. path_escape(task_id)
      .. "/feedback/"
      .. path_escape(feedback_id)
      .. "/respond",
    payload,
    opts
  )
end

function M.transcribe_wav(base_url, wav_bytes, opts)
  local response = M.bytes_request(
    "POST",
    M.api_base_url(base_url) .. "/voice/transcriptions",
    wav_bytes,
    vim.tbl_extend("force", opts or {}, { content_type = "audio/wav" })
  )
  return decode_json(response)
end

function M.voice_always_on_start(base_url, opts)
  return M.post_json(M.api_base_url(base_url) .. "/voice/always-on", opts or { threshold = 0.02, silenceMs = 25 })
end

function M.voice_always_on_chunk(base_url, stream_id, wav_bytes, sequence, last, opts)
  local payload = {
    audioBase64 = vim.base64.encode(wav_bytes),
    contentType = "audio/wav",
    sequence = sequence,
    last = last == true,
  }
  return M.post_json(
    M.api_base_url(base_url) .. "/voice/always-on/" .. path_escape(stream_id) .. "/chunks",
    payload,
    opts
  )
end

function M.voice_always_on_stop(base_url, stream_id, opts)
  return M.delete_json(M.api_base_url(base_url) .. "/voice/always-on/" .. path_escape(stream_id), opts)
end

function M.list_branches(base_url, opts)
  local response = M.get_json(M.api_base_url(base_url) .. "/branches", opts)
  return response.branches or {}
end

function M.get_branch(base_url, branch_id, opts)
  return M.get_json(M.api_base_url(base_url) .. "/branches/" .. path_escape(branch_id), opts)
end

function M.get_snapshot(base_url, snapshot_id, opts)
  return M.get_json(M.api_base_url(base_url) .. "/snapshots/" .. path_escape(snapshot_id), opts)
end

function M.create_agentharborfs_import(base_url, source_url, token, opts)
  local body = { url = source_url }
  if token then
    body.token = token
  end
  if opts and opts.materialization_mode then
    body.materializationMode = opts.materialization_mode
  end
  return M.post_json(M.api_base_url(base_url) .. "/agentharborfs/imports", body, opts)
end

function M.create_agentharborfs_share(base_url, identifier, scope, ttl, opts)
  return M.post_json(M.api_base_url(base_url) .. "/agentharborfs/share", {
    identifier = identifier,
    scope = scope,
    ttl = ttl,
  }, opts)
end

function M.branch_status(base_url, branch_id, opts)
  return M.get_json(M.api_base_url(base_url) .. "/agentharborfs/branches/" .. path_escape(branch_id) .. "/status", opts)
end

function M.sandbox_diff(base_url, task_id, from_branch_id, to_branch_id, opts)
  return M.post_json(
    M.api_base_url(base_url)
      .. "/sessions/"
      .. path_escape(task_id)
      .. "/sandbox-diff?from="
      .. path_escape(from_branch_id)
      .. "&to="
      .. path_escape(to_branch_id),
    {},
    opts
  )
end

function M.stash_buffer(base_url, task_id, path, bytes, opts)
  local pid = vim.uv and vim.uv.os_getpid() or vim.loop.os_getpid()
  local body = M.bytes_request(
    "POST",
    M.api_base_url(base_url)
      .. "/sessions/"
      .. path_escape(task_id)
      .. "/stash?editor_pid="
      .. path_escape(pid)
      .. "&path="
      .. path_escape(path),
    bytes,
    vim.tbl_extend("force", opts or {}, { content_type = "application/octet-stream" })
  )
  return decode_json(body)
end

function M.get_stash_buffer(base_url, task_id, path, opts)
  local pid = vim.uv and vim.uv.os_getpid() or vim.loop.os_getpid()
  return M.bytes_request(
    "GET",
    M.api_base_url(base_url)
      .. "/sessions/"
      .. path_escape(task_id)
      .. "/stash?editor_pid="
      .. path_escape(pid)
      .. "&path="
      .. path_escape(path),
    nil,
    opts
  )
end

M.path_escape = path_escape

return M
