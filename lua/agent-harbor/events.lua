-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

function M.new_sink()
  return { callbacks = {} }
end

function M.subscribe(sink, callback)
  table.insert(sink.callbacks, callback)
  return function()
    for index, candidate in ipairs(sink.callbacks) do
      if candidate == callback then
        table.remove(sink.callbacks, index)
        return
      end
    end
  end
end

function M.emit(sink, event)
  for _, callback in ipairs(vim.deepcopy(sink.callbacks)) do
    callback(event)
  end
end

return M
