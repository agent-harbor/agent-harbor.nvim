-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Task-prompt mode for the scratch file `ah task create` opens in `$EDITOR`.
--
-- The scratch file's name is a published contract:
--
--     <tmp>/agent-harbor/ah-task-prompt-<pid>-<nonce>.ahtask
--     <tmp>/agent-harbor/ah-plan-prompt-<pid>-<nonce>.ahplan
--
-- `ftdetect/agent-harbor-task-prompt.vim` maps those names to the
-- `agent-harbor-task-prompt` filetype, and `ftplugin/` wires this module up.
--
-- Completion uses the same trigger symbols as the TUI dashboard's prompt
-- textarea -- `/` and `~` for filesystem paths, `@` for workspace files -- and
-- the candidates come from `ah autocomplete --json`. That command is the single
-- authority for both the token rules (where a trigger counts, and what span a
-- candidate replaces) and the candidate vocabulary, which is what keeps this
-- mode from drifting away from the dashboard.

local config = require("agent-harbor.config")

local M = {}

--- Trigger characters, mirroring `ah_tui::view_model::autocomplete::Trigger`
--- minus the backtick command palette (a dashboard-only surface).
M.triggers = { ["/"] = true, ["~"] = true, ["@"] = true }

--- Return "task", "plan", or nil for `path`.
---
--- Both halves of the basename are required and must agree: the extension
--- alone would also match a user's own `notes.ahtask`, and the prefix alone
--- would match an unrelated file. Mirrors
--- `ah_core::editor::classify_prompt_path`.
function M.prompt_kind(path)
  if type(path) ~= "string" then
    return nil
  end
  local name = path:match("[^/\\]+$") or path
  local kind, extension = name:match("^ah%-(%a+)%-prompt%-%d+%-.+%.ah(%a+)$")
  if kind == nil then
    return nil
  end
  -- The prefix and the extension must agree: `ah-task-prompt-1-x.ahplan` is
  -- not a file `ah` would ever produce, so refuse it rather than guess.
  if kind ~= extension then
    return nil
  end
  if kind == "task" or kind == "plan" then
    return kind
  end
  return nil
end

--- Whether `path` is a prompt scratch file.
function M.is_prompt_file(path)
  return M.prompt_kind(path) ~= nil
end

--- Directory that `@` completions resolve against.
---
--- `ah` publishes it as AH_PROMPT_WORKSPACE, because the scratch file itself
--- lives in the temp directory and so the buffer's own directory is useless.
function M.workspace()
  local workspace = vim.env.AH_PROMPT_WORKSPACE
  if workspace ~= nil and workspace ~= "" then
    return workspace
  end
  return vim.fn.getcwd()
end

local function ah_command()
  local options = config.get()
  return (options.mux and options.mux.ah_command) or "ah"
end

--- Ask `ah autocomplete` about `line` at byte offset `cursor`.
---
--- Returns the decoded response table, or nil plus an error string.
function M.request(line, cursor)
  if type(vim.system) ~= "function" then
    return nil, "vim.system is required for Agent Harbor prompt completion"
  end
  local args = {
    ah_command(),
    "autocomplete",
    "--json",
    "--line",
    line,
    "--cursor",
    tostring(cursor),
    "--limit",
    "25",
  }
  local ok, result = pcall(function()
    return vim.system(args, { text = true, cwd = M.workspace() }):wait(5000)
  end)
  if not ok then
    return nil, tostring(result)
  end
  if result == nil then
    return nil, "ah autocomplete timed out"
  end
  if result.code ~= 0 then
    return nil, ("ah autocomplete exited with %s: %s"):format(result.code, result.stderr or "")
  end
  local decoded_ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not decoded_ok then
    return nil, ("ah autocomplete returned invalid JSON: %s"):format(tostring(decoded))
  end
  return decoded, nil
end

--- Convert an `ah` response into `complete()` items.
---
--- `word` is the full `replacement`, trigger character included, because the
--- client replaces the whole token -- the same contract the dashboard's
--- `commit_selection` has.
function M.completion_items(response)
  local items = {}
  if type(response) ~= "table" or type(response.items) ~= "table" then
    return items
  end
  for _, item in ipairs(response.items) do
    if type(item.replacement) == "string" then
      table.insert(items, {
        word = item.replacement,
        abbr = item.label or item.replacement,
        menu = item.kind or "",
        -- The candidates are already ranked and filtered by `ah`; letting Vim
        -- re-filter them would throw away every fuzzy hit.
        equal = 1,
        icase = 1,
      })
    end
  end
  return items
end

--- Cheap local check: does the token before the cursor start with a trigger?
---
--- This only decides whether to spawn `ah` at all. The replacement span still
--- comes from `ah`, so the two surfaces cannot disagree about it.
function M.trigger_active(line, cursor)
  local prefix = line:sub(1, cursor)
  -- Token boundaries are whitespace and quotes, matching the dashboard.
  local token = prefix:match("([^%s\"']*)$") or ""
  if token == "" then
    return false
  end
  local first = token:sub(1, 1)
  if not M.triggers[first] then
    return false
  end
  local before = prefix:sub(#prefix - #token, #prefix - #token)
  if before ~= "" and not before:match("[%s\"']") then
    return false
  end
  -- `@` needs at least one character after it; `/` and `~` fire immediately.
  if first == "@" and #token < 2 then
    return false
  end
  return true
end

local function cursor_context()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  -- `nvim_win_get_cursor` returns a byte offset, which is exactly what
  -- `ah autocomplete --cursor` wants.
  return line, col
end

--- `omnifunc` implementation (`<C-x><C-o>`).
---
--- Phase 1 returns the byte column the replacement starts at; phase 2 returns
--- the items. Both come from `ah`, not from a local guess.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line, col = cursor_context()
    if not M.trigger_active(line, col) then
      return -3 -- cancel silently, leave the text alone
    end
    local response, err = M.request(line, col)
    if response == nil then
      vim.notify("Agent Harbor completion unavailable: " .. tostring(err), vim.log.levels.WARN)
      return -3
    end
    if response.trigger == nil or response.tokenStart == nil then
      return -3
    end
    M._pending = response
    return response.tokenStart
  end

  local response = M._pending
  M._pending = nil
  if response ~= nil then
    return M.completion_items(response)
  end
  -- Vim can call phase 2 without our phase 1 (for instance after the user
  -- edits the base), so fall back to a fresh query.
  _ = base
  local line, col = cursor_context()
  local fresh = M.request(line, col)
  if fresh == nil then
    return {}
  end
  return M.completion_items(fresh)
end

--- Complete the token at the cursor, asynchronously, and open the popup.
---
--- Used by the auto-trigger and by the `<C-Space>` mapping. Asynchronous so a
--- slow repository scan never blocks typing.
function M.complete()
  if vim.fn.pumvisible() == 1 then
    return
  end
  local line, col = cursor_context()
  if not M.trigger_active(line, col) then
    return
  end
  if type(vim.system) ~= "function" then
    return
  end
  local args = {
    ah_command(),
    "autocomplete",
    "--json",
    "--line",
    line,
    "--cursor",
    tostring(col),
    "--limit",
    "25",
  }
  vim.system(args, { text = true, cwd = M.workspace() }, function(result)
    if result == nil or result.code ~= 0 then
      return
    end
    local ok, response = pcall(vim.json.decode, result.stdout or "")
    if not ok or type(response) ~= "table" or response.tokenStart == nil then
      return
    end
    local items = M.completion_items(response)
    if #items == 0 then
      return
    end
    vim.schedule(function()
      -- Bail out if the user has moved on since the request was sent.
      if vim.fn.mode():sub(1, 1) ~= "i" then
        return
      end
      local now_line, now_col = cursor_context()
      if now_line ~= line or now_col ~= col then
        return
      end
      -- `complete()` takes a 1-based column; `tokenStart` is a 0-based byte
      -- offset.
      vim.fn.complete(response.tokenStart + 1, items)
    end)
  end)
end

--- Save the prompt and hand control back to `ah`.
function M.finish()
  vim.cmd("silent write")
  vim.cmd("quit")
end

--- Abort task creation by saving an empty prompt.
---
--- `ah` treats a prompt that is empty after comment stripping as an abort, so
--- emptying the buffer is the documented way to cancel.
function M.abort()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
  vim.cmd("silent write")
  vim.cmd("quit")
end

--- Structured state for page-object tests.
function M.test_state()
  local path = vim.api.nvim_buf_get_name(0)
  local line, col = cursor_context()
  return {
    promptFile = M.is_prompt_file(path),
    kind = M.prompt_kind(path),
    filetype = vim.bo.filetype,
    omnifunc = vim.bo.omnifunc,
    workspace = M.workspace(),
    triggerActive = M.trigger_active(line, col),
  }
end

return M
