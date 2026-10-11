-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

-- Deterministic M13 mirror of the M0 shared REST schema source:
--   js-libs/rest-client/src/types.ts
--   webui/shared/src/api.ts
-- No Lua code generator exists in this repo yet. Keep the field lists below in
-- source order so the smoke test can assert the mirror is loaded and later
-- milestones can replace this module with generated output without changing
-- callers.
M.schemas = {
  TaskResponse = {
    "id",
    "prompt",
    "loop_type",
    "loop_state",
    "iteration",
    "status",
    "workspace_path",
    "session_count",
    "created_at",
    "updated_at",
    "links",
    "phase",
    "executive_summary",
    "elapsed_ms",
  },
  Session = {
    "id",
    "tenantId",
    "projectId",
    "status",
    "createdAt",
    "prompt",
    "vcs",
    "runtime",
    "workspace",
    "agent",
    "delivery",
    "labels",
    "parentSessionIds",
    "continuesFrom",
    "forkedFrom",
    "agentharborfsBranchId",
    "baseSnapshot",
    "headSnapshot",
    "links",
    "recent_events",
  },
  TaskSessionInfo = {
    "id",
    "role",
    "iteration",
    "status",
    "started_at",
    "ended_at",
    "parentSessionIds",
    "continuesFrom",
    "prompt",
    "forkedFrom",
    "agentharborfsBranchId",
    "baseSnapshot",
    "headSnapshot",
  },
  SessionEvent = {
    "type",
    "sessionId",
    "ts",
    "status",
    "level",
    "message",
    "progress",
    "stage",
    "thought",
    "tool_name",
    "tool_args",
    "tool_output",
    "tool_status",
    "last_line",
    "exit_code",
    "output_metrics",
    "pipeline_stages",
    "file_path",
    "lines_added",
    "lines_removed",
    "diff_preview",
    "start_line",
    "end_line",
    "content",
    "input_type",
    "entries",
    "is_update",
    "stop_reason",
    "input_tokens",
    "output_tokens",
    "path",
    "old_text",
    "new_text",
  },
}

local function pick(json, fields)
  local result = {}
  for _, field in ipairs(fields) do
    result[field] = json and json[field] or nil
  end
  return result
end

function M.task_from_json(json)
  return pick(json, M.schemas.TaskResponse)
end

function M.session_from_json(json)
  return pick(json, M.schemas.Session)
end

function M.task_session_from_json(json)
  return pick(json, M.schemas.TaskSessionInfo)
end

function M.activity_from_json(json)
  return vim.deepcopy(json or {})
end

return M
