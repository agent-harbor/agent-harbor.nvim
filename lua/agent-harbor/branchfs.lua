-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {}

M.last_error = nil

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

local function decode_segment(value)
  local decoded = (value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return decoded
end

local function split_path(value)
  local out = {}
  for segment in tostring(value or ""):gmatch("[^/]+") do
    table.insert(out, decode_segment(segment))
  end
  return out
end

local function join_tail(parts, start_index)
  local out = {}
  for index = start_index, #parts do
    table.insert(out, parts[index])
  end
  return table.concat(out, "/")
end

local function parse_uri(uri)
  local body = tostring(uri or ""):match("^agent%-harbor://(.+)$")
  if not body then
    error("unsupported Agent Harbor BranchFS URI: " .. tostring(uri))
  end
  body = body:gsub("%?.*$", "")
  local parts = split_path(body)
  local kind = parts[1]
  if kind == "branch" or kind == "branches" then
    return { kind = "branch", id = parts[2], path = join_tail(parts, 3), read_only = false }
  end
  if kind == "snapshot" or kind == "snapshots" then
    return { kind = "snapshot", id = parts[2], path = join_tail(parts, 3), read_only = true }
  end
  if kind == "base" or kind == "branch-base" or kind == "branch-bases" then
    return { kind = "branch-base", id = parts[2], path = join_tail(parts, 3), read_only = true }
  end
  if kind == "share" and (parts[3] == "branch" or parts[3] == "branches") then
    return {
      kind = "share",
      token = parts[2],
      source_kind = "branch",
      id = parts[4],
      path = join_tail(parts, 5),
      read_only = true,
    }
  end
  if kind == "share" and (parts[3] == "snapshot" or parts[3] == "snapshots") then
    return {
      kind = "share",
      token = parts[2],
      source_kind = "snapshot",
      id = parts[4],
      path = join_tail(parts, 5),
      read_only = true,
    }
  end
  error("unsupported Agent Harbor BranchFS URI kind: " .. tostring(kind))
end

local function ensure_daemon()
  if daemon.state ~= "connected" or not daemon.endpoint then
    daemon.refresh()
  end
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("Agent Harbor daemon is not connected")
  end
end

local function branch_base_snapshot_id(branch_id)
  local branch = rest.get_branch(daemon.endpoint, branch_id, { timeout_ms = 5000 })
  local base = get(branch, "baseSnapshot")
  return get(base, "id") or get(branch, "baseSnapshotId") or error("branch has no base snapshot: " .. branch_id)
end

local function manifest(resource)
  if resource.kind == "branch" then
    return rest.agentharborfs_branch_manifest(daemon.endpoint, resource.id, { timeout_ms = 2000 })
  end
  if resource.kind == "snapshot" then
    return rest.agentharborfs_snapshot_manifest(daemon.endpoint, resource.id, { timeout_ms = 2000 })
  end
  if resource.kind == "branch-base" then
    return rest.agentharborfs_snapshot_manifest(daemon.endpoint, branch_base_snapshot_id(resource.id), { timeout_ms = 2000 })
  end
  if resource.kind == "share" and resource.source_kind == "branch" then
    return rest.agentharborfs_branch_manifest(daemon.endpoint, resource.id, { token = resource.token, timeout_ms = 2000 })
  end
  if resource.kind == "share" and resource.source_kind == "snapshot" then
    return rest.agentharborfs_snapshot_manifest(daemon.endpoint, resource.id, { token = resource.token, timeout_ms = 2000 })
  end
  error("unsupported BranchFS resource kind: " .. tostring(resource.kind))
end

local function entry_for(resource)
  if resource.path == nil or resource.path == "" then
    return { kind = "directory", path = "" }
  end
  for _, entry in ipairs(manifest(resource).entries or {}) do
    if entry.path == resource.path then
      return entry
    end
  end
  return nil
end

local function read_bytes(resource, allow_missing)
  if resource.kind == "branch" then
    local status = rest.branch_status(daemon.endpoint, resource.id, { timeout_ms = 5000 })
    if status.writable == true then
      local ok, bytes = pcall(rest.branch_file_content, daemon.endpoint, resource.id, resource.path, { timeout_ms = 3000 })
      if not ok then
        local message = tostring(bytes)
        if allow_missing == true and (message:find("404", 1, true) or message:lower():find("not found", 1, true)) then
          return "", status.headSnapshotId or status.head_snapshot_id, true
        end
        error(bytes)
      end
      return bytes, status.headSnapshotId or status.head_snapshot_id, true
    end
    if status.import ~= nil then
      rest.agentharborfs_branch_prefetch(daemon.endpoint, resource.id, {
        prefixes = { resource.path },
        limit = 1,
        timeout_ms = 5000,
      })
    end
  end
  local doc = manifest(resource)
  local found
  for _, entry in ipairs(doc.entries or {}) do
    if entry.path == resource.path then
      found = entry
      break
    end
  end
  if not found then
    error("BranchFS path not found: " .. tostring(resource.path))
  end
  if found.kind == "directory" then
    error("BranchFS path is a directory: " .. tostring(resource.path))
  end
  return rest.agentharborfs_blob(daemon.endpoint, doc.algorithm or "b3", found.hash, {
    token = resource.token,
    timeout_ms = 3000,
  }),
    doc.snapshotId or doc.snapshot_id,
    false
end

local function set_buffer_lines(bufnr, bytes)
  local lines = vim.split(bytes or "", "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

function M.read(uri, bufnr)
  ensure_daemon()
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  uri = uri or vim.api.nvim_buf_get_name(bufnr)
  local resource = parse_uri(uri)
  local bytes, head, writable = read_bytes(resource, true)
  set_buffer_lines(bufnr, bytes)
  vim.b[bufnr].agent_harbor_branchfs_uri = uri
  vim.b[bufnr].agent_harbor_branchfs_kind = resource.kind
  vim.b[bufnr].agent_harbor_branchfs_branch_id = resource.id
  vim.b[bufnr].agent_harbor_branchfs_path = resource.path
  vim.b[bufnr].agent_harbor_branchfs_expected_head = head
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].readonly = not writable
  vim.bo[bufnr].modifiable = writable
  vim.bo[bufnr].modified = false
  return { uri = uri, branchId = resource.id, path = resource.path, expectedHead = head, writable = writable }
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n") .. "\n"
end

local function ensure_writable(resource, bufnr)
  if resource.kind ~= "branch" then
    error("Agent Harbor BranchFS resource is read-only")
  end
  local status = rest.branch_status(daemon.endpoint, resource.id, { timeout_ms = 5000 })
  if status.writable ~= true then
    error("Agent Harbor BranchFS branch is " .. tostring(status.mutationMode or status.mutation_mode) .. "; writes are disabled")
  end
  return vim.b[bufnr].agent_harbor_branchfs_expected_head or status.headSnapshotId or status.head_snapshot_id
end

local function response_head(response)
  return response
    and (
      response.headSnapshotId
      or response.head_snapshot_id
      or (response.head and (response.head.headSnapshotId or response.head.head_snapshot_id))
    )
end

local function record_current_head(response)
  local head = response_head(response)
  if head then
    vim.b.agent_harbor_branchfs_expected_head = head
  end
  return response
end

function M.write(uri, bufnr)
  ensure_daemon()
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  uri = uri or vim.api.nvim_buf_get_name(bufnr)
  local resource = parse_uri(uri)
  local expected = ensure_writable(resource, bufnr)
  local ok, response = pcall(rest.write_branch_file, daemon.endpoint, resource.id, resource.path, buffer_text(bufnr), {
    timeout_ms = 3000,
    expected_head = expected,
  })
  if not ok then
    M.last_error = tostring(response)
    vim.bo[bufnr].modified = true
    error("Agent Harbor BranchFS write failed: " .. M.last_error)
  end
  vim.b[bufnr].agent_harbor_branchfs_expected_head = response_head(response)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].modified = false
  return response
end

function M.mkdir(uri)
  ensure_daemon()
  local resource = parse_uri(uri)
  local expected = ensure_writable(resource, vim.api.nvim_get_current_buf())
  return record_current_head(rest.create_branch_directory(daemon.endpoint, resource.id, resource.path, {
    timeout_ms = 3000,
    expected_head = expected,
  }))
end

function M.delete(uri)
  ensure_daemon()
  local resource = parse_uri(uri)
  local expected = ensure_writable(resource, vim.api.nvim_get_current_buf())
  return record_current_head(rest.delete_branch_path(daemon.endpoint, resource.id, resource.path, {
    timeout_ms = 3000,
    expected_head = expected,
  }))
end

function M.rename(from_uri, to_uri, overwrite)
  ensure_daemon()
  local from = parse_uri(from_uri)
  local to = parse_uri(to_uri)
  if from.kind ~= "branch" or to.kind ~= "branch" or from.id ~= to.id then
    error("Agent Harbor BranchFS rename requires one mutable branch")
  end
  local expected = ensure_writable(from, vim.api.nvim_get_current_buf())
  return record_current_head(rest.move_branch_path(daemon.endpoint, from.id, from.path, to.path, overwrite == true, {
    timeout_ms = 3000,
    expected_head = expected,
  }))
end

function M.copy(from_uri, to_uri, overwrite)
  ensure_daemon()
  local to = parse_uri(to_uri)
  local existing = entry_for(to)
  if existing and overwrite ~= true then
    error("Agent Harbor BranchFS copy target already exists: " .. tostring(to.path))
  end
  local expected = ensure_writable(to, vim.api.nvim_get_current_buf())
  local bytes = read_bytes(parse_uri(from_uri), false)
  return record_current_head(rest.write_branch_file(daemon.endpoint, to.id, to.path, bytes, {
    timeout_ms = 3000,
    expected_head = expected,
  }))
end

local function child_name(parent, path)
  if parent == "" then
    if path == "" then
      return nil
    end
    return path:match("^([^/]+)")
  end
  if path:sub(1, #parent + 1) ~= parent .. "/" then
    return nil
  end
  return path:sub(#parent + 2):match("^([^/]+)")
end

function M.listdir(uri)
  ensure_daemon()
  local resource = parse_uri(uri)
  local current = entry_for(resource)
  if not current or current.kind ~= "directory" then
    error("BranchFS path is not a directory: " .. tostring(resource.path))
  end
  local seen = {}
  for _, entry in ipairs(manifest(resource).entries or {}) do
    local name = child_name(resource.path or "", entry.path or "")
    if name then
      seen[name] = true
    end
  end
  local names = vim.tbl_keys(seen)
  table.sort(names)
  return names
end

function M.setup()
  local group = vim.api.nvim_create_augroup("AgentHarborBranchFS", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadCmd", "FileReadCmd" }, {
    group = group,
    pattern = "agent-harbor://*",
    callback = function(args)
      M.read(args.file, args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
    group = group,
    pattern = "agent-harbor://*",
    callback = function(args)
      M.write(args.file, args.buf)
    end,
  })
  vim.api.nvim_create_user_command("AgentHarborBranchFsMkdir", function(opts)
    M.mkdir(opts.args)
  end, { nargs = 1, complete = "file" })
  vim.api.nvim_create_user_command("AgentHarborBranchFsDelete", function(opts)
    M.delete(opts.args)
  end, { nargs = 1, complete = "file" })
  vim.api.nvim_create_user_command("AgentHarborBranchFsRename", function(opts)
    if #opts.fargs ~= 2 then
      error("AgentHarborBranchFsRename requires FROM and TO URIs")
    end
    M.rename(opts.fargs[1], opts.fargs[2], opts.bang)
  end, { nargs = "+", bang = true, complete = "file" })
  vim.api.nvim_create_user_command("AgentHarborBranchFsCopy", function(opts)
    if #opts.fargs ~= 2 then
      error("AgentHarborBranchFsCopy requires FROM and TO URIs")
    end
    M.copy(opts.fargs[1], opts.fargs[2], opts.bang)
  end, { nargs = "+", bang = true, complete = "file" })
  vim.api.nvim_create_user_command("AgentHarborBranchFsList", function(opts)
    print(table.concat(M.listdir(opts.args), "\n"))
  end, { nargs = 1, complete = "file" })
end

M.parse_uri = parse_uri

return M
