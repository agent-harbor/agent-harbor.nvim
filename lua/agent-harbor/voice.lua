-- Copyright 2026 Schelling Point Labs Inc
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require("agent-harbor.config")
local daemon = require("agent-harbor.daemon")
local rest = require("agent-harbor.rest")

local M = {}

M.last_transcription = nil
M.always_on_stream_id = nil
M.last_mode = nil

local function readable(path)
  return type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1
end

local function fixture_path()
  local configured = config.get().voice and config.get().voice.fixture_wav or nil
  if readable(configured) then
    return configured
  end
  local env_path = vim.env.AH_VOICE_FIXTURE_WAV
  if readable(env_path) then
    return env_path
  end
  return nil
end

local function read_binary(path)
  local fd = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = assert(vim.uv.fs_read(fd, stat.size, 0))
  vim.uv.fs_close(fd)
  return data
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

local function recorder_command(output)
  local seconds = tostring((config.get().voice and config.get().voice.record_seconds) or 2)
  if executable("sox") then
    return { "sox", "-q", "-d", "-r", "16000", "-c", "1", "-b", "16", output, "trim", "0", seconds }
  end
  if executable("rec") then
    return { "rec", "-q", "-r", "16000", "-c", "1", "-b", "16", output, "trim", "0", seconds }
  end
  if executable("arecord") then
    return { "arecord", "-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-d", tostring(math.ceil(tonumber(seconds) or 2)), output }
  end
  return nil
end

function M.record_wav()
  local fixture = fixture_path()
  if fixture then
    return fixture
  end
  local output = vim.fn.tempname() .. ".wav"
  local command = recorder_command(output)
  if not command then
    error("No voice recorder found; install sox/rec or arecord")
  end
  local handle
  local done = false
  local exit_code = nil
  handle = vim.uv.spawn(command[1], {
    args = vim.list_slice(command, 2),
    stdio = { nil, nil, nil },
  }, function(code)
    exit_code = code
    done = true
    if handle then
      handle:close()
    end
  end)
  if not handle then
    error("failed to start voice recorder")
  end
  vim.wait(((tonumber(config.get().voice.record_seconds) or 2) * 1000) + 3000, function()
    return done
  end, 50)
  if exit_code ~= 0 then
    error("voice recorder failed with exit code " .. tostring(exit_code))
  end
  return output
end

function M.transcribe_file(path)
  daemon.refresh()
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("daemon endpoint is not discovered")
  end
  M.last_transcription = rest.transcribe_wav(daemon.endpoint, read_binary(path), { timeout_ms = 15000 })
  return M.last_transcription
end

function M.transcript_text(response)
  return vim.trim(tostring(response.correctedTranscript or response.transcript or ""))
end

function M.always_on_start()
  daemon.refresh()
  if daemon.state ~= "connected" or not daemon.endpoint then
    error("daemon endpoint is not discovered")
  end
  local response = rest.voice_always_on_start(daemon.endpoint, { threshold = 0.02, silenceMs = 25 })
  M.always_on_stream_id = response.streamId
  if type(M.always_on_stream_id) ~= "string" or M.always_on_stream_id == "" then
    error("always-on voice stream did not return a stream id")
  end
  return response
end

function M.always_on_stop()
  if type(M.always_on_stream_id) ~= "string" or M.always_on_stream_id == "" then
    error("No always-on voice stream is active")
  end
  local stream_id = M.always_on_stream_id
  local response = rest.voice_always_on_stop(daemon.endpoint, stream_id)
  M.always_on_stream_id = nil
  return response
end

function M.always_on_finalize()
  if type(M.always_on_stream_id) ~= "string" or M.always_on_stream_id == "" then
    M.always_on_start()
  end
  local stream_id = M.always_on_stream_id
  local wav_bytes = read_binary(M.record_wav())
  local chunk = rest.voice_always_on_chunk(daemon.endpoint, stream_id, wav_bytes, 0, true, { timeout_ms = 15000 })
  M.always_on_stop()
  M.last_transcription = (chunk.transcriptions or {})[1] or chunk
  return M.last_transcription
end

function M.reply_submit()
  if config.get().voice.mode == "disabled" then
    error("Agent Harbor voice input is disabled")
  end
  M.last_mode = config.get().voice.mode
  local response
  if config.get().voice.mode == "always-on" then
    response = M.always_on_finalize()
  else
    response = M.transcribe_file(M.record_wav())
  end
  local text = M.transcript_text(response)
  if text == "" then
    error("Voice transcription returned an empty transcript")
  end
  return require("agent-harbor.reply").submit_text(text)
end

return M
