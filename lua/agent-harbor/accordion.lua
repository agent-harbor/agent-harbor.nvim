-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

function M.header(collapsed, count)
  return ("%s Active Tasks (%d)"):format(collapsed and "[+]" or "[-]", count or 0)
end

function M.candidates(tasks, title_fn, id_fn)
  local candidates = {}
  for _, task in ipairs(tasks or {}) do
    local id = id_fn(task)
    if id then
      table.insert(candidates, {
        id = id,
        label = ("%s  %s"):format(title_fn(task) or id, id),
      })
    end
  end
  return candidates
end

function M.select_with_ui(tasks, title_fn, id_fn, on_select)
  local candidates = M.candidates(tasks, title_fn, id_fn)
  vim.ui.select(candidates, {
    prompt = "Agent Harbor task:",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item and item.id then
      on_select(item.id)
    end
  end)
end

return M
