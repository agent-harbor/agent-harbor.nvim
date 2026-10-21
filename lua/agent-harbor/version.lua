-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

-- Version identity of the Neovim plugin, and the `ah` releases it works with.
--
-- `version` is a placeholder in the monorepo and is rewritten when the plugin
-- is published to the agent-harbor/agent-harbor.nvim mirror, which is the only
-- place a released version number exists (see
-- `scripts/ide-publish-editor-mirrors.cjs`). A checkout of the monorepo
-- therefore reports `0.0.0-dev`, and `:checkhealth agent-harbor` says so
-- rather than claiming a release it is not.
--
-- `ah_min` is NOT generated. It is the oldest `ah` release that provides every
-- CLI surface this plugin calls, and it moves by hand when the plugin starts
-- depending on something newer. Raising it is a breaking change for users on
-- an older `ah`, so it carries the reason:
--
--   0.6.8  `ah autocomplete --json`, which backs `/` and `@` completion in the
--          task-prompt filetype (see `lua/agent-harbor/task-prompt.lua`).

local M = {}

M.version = "0.6.15"
M.ah_min = "0.6.8"

--- Is this anything other than a published release? True for a monorepo
--- checkout ("0.0.0-dev") and for a dev-channel publish ("0.6.8-dev+gabc123").
--- @return boolean
function M.is_dev()
  return M.version:match("%-dev") ~= nil
end

--- Parse `major.minor.patch` out of a version string, ignoring any prerelease
--- or build suffix. Returns nil when there is no numeric triple to compare,
--- which callers must treat as "unknown", never as "too old".
--- @param text string|nil
--- @return integer[]|nil
function M.parse(text)
  if type(text) ~= "string" then
    return nil
  end
  local major, minor, patch = text:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- Compare two parsed versions. -1 if a < b, 0 if equal, 1 if a > b.
--- @param a integer[]
--- @param b integer[]
--- @return integer
function M.compare(a, b)
  for index = 1, 3 do
    if a[index] ~= b[index] then
      return a[index] < b[index] and -1 or 1
    end
  end
  return 0
end

--- Does `reported` satisfy this plugin's `ah` floor?
---
--- Returns nil for "cannot tell", never false, in two cases: when there is no
--- version number to read, and when `ah` reports a development build. A build
--- from a branch carries the version of the last release it was branched past
--- -- "ah 0.6.5-dev" can be a build of a tree that has everything 0.6.8 has --
--- so its number says nothing about which surfaces it provides, and calling it
--- too old would be a guess dressed up as a verdict.
--- @param reported string|nil
--- @return boolean|nil satisfied
--- @return string floor
--- @return boolean development
function M.satisfies_ah_min(reported)
  local got = M.parse(reported)
  local want = M.parse(M.ah_min)
  if not got or not want then
    return nil, M.ah_min, false
  end
  local development = reported:match("%-dev") ~= nil or reported:match("%-rc") ~= nil
  if development and M.compare(got, want) < 0 then
    return nil, M.ah_min, true
  end
  return M.compare(got, want) >= 0, M.ah_min, development
end

return M
