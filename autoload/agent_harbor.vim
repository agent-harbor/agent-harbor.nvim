" Copyright 2026 Schelling Point Labs Inc
" SPDX-License-Identifier: AGPL-3.0-only

let s:defaults = {
      \ 'daemon': {
      \   'url': v:null,
      \   'pid_file': v:null,
      \   'probe_timeout_ms': 1000,
      \ },
      \ 'panel': {
      \   'history_limit': 200,
      \   'mode': 'popup',
      \   'width': 82,
      \ },
      \ 'workspace': {
      \   'on_switch_modified': 'prompt',
      \ },
      \ 'docs': {
      \   'url': 'https://docs.agent-harbor.com/editor-support/vim',
      \ },
      \ }

let s:config = deepcopy(s:defaults)

let s:state = {
      \ 'daemon': {'state': 'disconnected', 'endpoint': v:null, 'error': v:null},
      \ 'panel_popup': 0,
      \ 'panel_bufnr': 0,
      \ 'tasks': [],
      \ 'branches': [],
      \ 'task_sessions': {},
      \ 'full_sessions': {},
      \ 'session_events': {},
      \ 'session_history_counts': {},
      \ 'task_diff_files': {},
      \ 'task_diff_status': {},
      \ 'selected_task_id': v:null,
      \ 'selected_stream_session_id': v:null,
      \ 'accordion_collapsed': v:false,
      \ 'timeline_cards': [],
      \ 'modified_files': [],
      \ 'last_share': v:null,
      \ 'last_error': v:null,
      \ 'workspace': {
      \   'taskId': v:null,
      \   'branchId': v:null,
      \   'root': v:null,
      \   'lastRetarget': v:null,
      \ },
      \ 'prompt': {'visible': v:false, 'text': v:null, 'bufnr': 0, 'winnr': 0},
      \ }

function! s:Get(value, key, ...) abort
  if type(a:value) != v:t_dict || !has_key(a:value, a:key) || a:value[a:key] is v:null
    return a:0 ? a:1 : v:null
  endif
  return a:value[a:key]
endfunction

function! s:MergeConfig(base, override) abort
  let l:out = deepcopy(a:base)
  if type(a:override) != v:t_dict
    return l:out
  endif
  for [l:key, l:value] in items(a:override)
    if has_key(l:out, l:key) && type(l:out[l:key]) == v:t_dict && type(l:value) == v:t_dict
      let l:out[l:key] = s:MergeConfig(l:out[l:key], l:value)
    else
      let l:out[l:key] = l:value
    endif
  endfor
  return l:out
endfunction

function! s:Trim(value) abort
  return substitute(substitute(a:value, '^\s\+', '', ''), '\s\+$', '', '')
endfunction

function! s:PathEscape(value) abort
  return substitute(string(a:value)[1:-2], '[^A-Za-z0-9_.~-]', '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
endfunction

function! s:NormalizeUrl(url) abort
  let l:url = s:Trim(a:url)
  if l:url ==# ''
    throw 'daemon URL is empty'
  endif
  if l:url !~# '^[A-Za-z][A-Za-z0-9+.-]*://'
    let l:url = 'http://' .. l:url
  endif
  return substitute(l:url, '/\+$', '', '')
endfunction

function! s:ApiBase() abort
  return s:state.daemon.endpoint .. '/api/v1'
endfunction

function! s:Request(method, path, body, ...) abort
  if s:state.daemon.endpoint is v:null
    throw 'Agent Harbor daemon is not connected'
  endif
  let l:timeout = a:0 && has_key(a:1, 'timeout_ms') ? a:1.timeout_ms : 2000
  let l:cmd = [
        \ 'curl',
        \ '--noproxy', '*',
        \ '--fail-with-body',
        \ '--silent',
        \ '--show-error',
        \ '--location',
        \ '--max-time', printf('%.3f', l:timeout / 1000.0),
        \ '--request', a:method,
        \ '--header', 'Accept: application/json',
        \ ]
  let l:stdin = ''
  if a:body isnot v:null
    call extend(l:cmd, ['--header', 'Content-Type: application/json', '--data-binary', '@-'])
    let l:stdin = json_encode(a:body)
  endif
  if a:0 && has_key(a:1, 'expected_head') && a:1.expected_head isnot v:null
    call extend(l:cmd, ['--header', 'If-Match: "' .. string(a:1.expected_head)[1:-2] .. '"'])
  endif
  call add(l:cmd, s:ApiBase() .. a:path)
  let l:out = systemlist(join(map(copy(l:cmd), 'shellescape(v:val)'), ' '), l:stdin)
  if v:shell_error != 0
    throw printf('daemon request failed for %s %s: %s', a:method, a:path, join(l:out, "\n"))
  endif
  let l:text = join(l:out, "\n")
  return l:text ==# '' ? {} : json_decode(l:text)
endfunction

function! s:RequestRaw(method, path, body, ...) abort
  if s:state.daemon.endpoint is v:null
    throw 'Agent Harbor daemon is not connected'
  endif
  let l:opts = a:0 ? a:1 : {}
  let l:timeout = has_key(l:opts, 'timeout_ms') ? l:opts.timeout_ms : 2000
  let l:cmd = [
        \ 'curl',
        \ '--noproxy', '*',
        \ '--fail-with-body',
        \ '--silent',
        \ '--show-error',
        \ '--location',
        \ '--max-time', printf('%.3f', l:timeout / 1000.0),
        \ '--request', a:method,
        \ ]
  let l:stdin = ''
  if a:body isnot v:null
    call extend(l:cmd, ['--header', 'Content-Type: application/octet-stream', '--data-binary', '@-'])
    let l:stdin = a:body
  endif
  if has_key(l:opts, 'expected_head') && l:opts.expected_head isnot v:null
    call extend(l:cmd, ['--header', 'If-Match: "' .. string(l:opts.expected_head)[1:-2] .. '"'])
  endif
  call add(l:cmd, s:ApiBase() .. a:path)
  let l:out = systemlist(join(map(copy(l:cmd), 'shellescape(v:val)'), ' '), l:stdin)
  if v:shell_error != 0
    throw printf('daemon raw request failed for %s %s: %s', a:method, a:path, join(l:out, "\n"))
  endif
  return join(l:out, "\n")
endfunction

function! s:BranchFsParse(uri) abort
  let l:body = substitute(a:uri, '^agent-harbor://', '', '')
  let l:body = substitute(l:body, '?.*$', '', '')
  let l:parts = split(l:body, '/')
  if len(l:parts) < 3 || index(['branch', 'branches'], l:parts[0]) < 0
    throw 'Vim fallback supports writable agent-harbor://branch/<id>/<path> buffers only'
  endif
  return {'kind': 'branch', 'id': l:parts[1], 'path': join(l:parts[2:], '/')}
endfunction

function! s:BranchFsStatus(branch_id) abort
  return s:Request('GET', '/agentharborfs/branches/' .. s:PathEscape(a:branch_id) .. '/status', v:null, {'timeout_ms': 5000})
endfunction

function! s:ResolvePidFile() abort
  if s:Get(s:config.daemon, 'pid_file') isnot v:null
    return s:config.daemon.pid_file
  endif
  if exists('$AH_WEBUI_PID_FILE') && $AH_WEBUI_PID_FILE !=# ''
    return $AH_WEBUI_PID_FILE
  endif
  if exists('$AH_HOME') && $AH_HOME !=# ''
    return $AH_HOME .. '/webui.pid'
  endif
  if has('mac')
    return expand('~/Library/Application Support/agent-harbor/webui.pid')
  endif
  let l:data_home = exists('$XDG_DATA_HOME') && $XDG_DATA_HOME !=# '' ? $XDG_DATA_HOME : expand('~/.local/share')
  return l:data_home .. '/agent-harbor/webui.pid'
endfunction

function! s:DiscoverDaemon() abort
  let l:override = s:Get(s:config.daemon, 'url')
  if (l:override is v:null || l:override ==# '') && exists('$AH_DAEMON_URL') && $AH_DAEMON_URL !=# ''
    let l:override = $AH_DAEMON_URL
  endif
  if l:override isnot v:null && l:override !=# ''
    return s:NormalizeUrl(l:override)
  endif
  let l:pid_file = s:ResolvePidFile()
  if !filereadable(l:pid_file)
    throw 'PID file missing: ' .. l:pid_file
  endif
  let l:pid = json_decode(join(readfile(l:pid_file), "\n"))
  return s:NormalizeUrl('http://' .. l:pid.host .. ':' .. string(l:pid.port))
endfunction

function! s:DaemonRefresh() abort
  try
    let l:endpoint = s:DiscoverDaemon()
    let s:state.daemon.endpoint = l:endpoint
    let s:state.daemon.state = 'connected'
    let s:state.daemon.error = v:null
    call s:Request('GET', '/platform/capabilities', v:null, {'timeout_ms': s:config.daemon.probe_timeout_ms})
  catch
    let s:state.daemon.state = 'disconnected'
    let s:state.daemon.error = v:exception
  endtry
  return s:state.daemon.state
endfunction

function! s:TaskId(task) abort
  return s:Get(a:task, 'id')
endfunction

function! s:SessionId(session) abort
  return s:Get(a:session, 'id')
endfunction

function! s:BranchIdFromSession(session) abort
  return s:Get(a:session, 'agentharborfsBranchId', s:Get(a:session, 'agentharborfs_branch_id'))
endfunction

function! s:BranchId(branch) abort
  return s:Get(a:branch, 'id')
endfunction

function! s:BranchSessionId(branch) abort
  return s:Get(a:branch, 'sessionId', s:Get(a:branch, 'session_id'))
endfunction

function! s:BranchRoot(branch) abort
  return s:Get(a:branch, 'workspacePath', s:Get(a:branch, 'workspace_path'))
endfunction

function! s:SessionStatus(session) abort
  return s:Get(a:session, 'status', 'unknown')
endfunction

function! s:SessionRole(session) abort
  return s:Get(a:session, 'role')
endfunction

function! s:IsStartupSession(session) abort
  return s:SessionRole(a:session) ==# 'startup'
endfunction

function! s:NormalizedSessionRole(session) abort
  let l:role = s:SessionRole(a:session)
  if type(l:role) != v:t_string
    return ''
  endif
  return tolower(substitute(l:role, '[-. ]', '_', 'g'))
endfunction

function! s:SessionRolePriority(session) abort
  let l:role = s:NormalizedSessionRole(a:session)
  if index(['implementation', 'implementer'], l:role) >= 0
    return 1
  elseif index(['manager', 'manager_agent'], l:role) >= 0
    return 2
  elseif l:role ==# 'coordinator'
    return 3
  elseif l:role ==# 'reviewer' || l:role =~# '^reviewer_'
    return 4
  elseif l:role ==# 'supervisor'
    return 5
  endif
  return 100
endfunction

function! s:SessionHasTimeline(session) abort
  let l:sid = s:SessionId(a:session)
  if l:sid is v:null
    return v:false
  endif
  return !empty(get(s:state.session_events, l:sid, []))
        \ || get(s:state.session_history_counts, l:sid, 0) > 0
endfunction

function! s:PreferredRoleSession(sessions, require_timeline) abort
  let l:best = v:null
  let l:best_priority = v:null
  for l:session in a:sessions
    if a:require_timeline && !s:SessionHasTimeline(l:session)
      continue
    endif
    let l:priority = s:SessionRolePriority(l:session)
    if l:best is v:null || l:priority < l:best_priority
      let l:best = l:session
      let l:best_priority = l:priority
    endif
  endfor
  return l:best
endfunction

function! s:TaskSessions(task_id) abort
  return get(s:state.task_sessions, a:task_id, [])
endfunction

function! s:SessionIdsForTask(task_id) abort
  let l:ids = []
  for l:session in s:TaskSessions(a:task_id)
    if s:SessionId(l:session) isnot v:null
      call add(l:ids, s:SessionId(l:session))
    endif
  endfor
  return l:ids
endfunction

function! s:Label(labels, key) abort
  if type(a:labels) != v:t_dict
    return v:null
  endif
  return s:Get(a:labels, a:key, s:Get(a:labels, substitute(a:key, '\.', '', 'g')))
endfunction

" Daemon-supplied task titles can carry multi-line prompts (loop-driver and
" manager-harness sub-tasks embed `# Implementation Task\n\n## …` as the
" title fallback). Accordion rows are single-line by design, so collapse
" to the first line to keep buffer writes well-formed.
function! s:SanitizeSingleLine(text) abort
  if type(a:text) != v:t_string
    return a:text
  endif
  let l:match = matchstr(a:text, '[^\r\n]\+')
  return empty(l:match) ? a:text : l:match
endfunction

function! s:TaskTitle(task) abort
  let l:id = s:TaskId(a:task)
  let l:sessions = l:id is v:null ? [] : s:TaskSessions(l:id)
  let l:first = empty(l:sessions) ? {} : get(s:state.full_sessions, s:SessionId(l:sessions[0]), {})
  let l:labels = s:Get(s:Get(l:first, 'task', {}), 'labels', {})
  return s:SanitizeSingleLine(s:Label(l:labels, 'agentHarbor.taskTitle') ?? s:Label(l:labels, 'agentHarborTaskTitle') ?? s:Get(a:task, 'prompt', l:id))
endfunction

function! s:SelectedTask() abort
  for l:task in s:state.tasks
    if s:TaskId(l:task) ==# s:state.selected_task_id
      return l:task
    endif
  endfor
  return empty(s:state.tasks) ? v:null : s:state.tasks[0]
endfunction

function! s:SelectedTaskId() abort
  let l:task = s:SelectedTask()
  return l:task is v:null ? v:null : s:TaskId(l:task)
endfunction

function! s:SelectedSessions() abort
  let l:id = s:SelectedTaskId()
  return l:id is v:null ? [] : s:TaskSessions(l:id)
endfunction

function! s:SelectedSessionId() abort
  let l:sessions = s:SelectedSessions()
  if s:state.selected_stream_session_id isnot v:null
    for l:session in l:sessions
      if s:SessionId(l:session) ==# s:state.selected_stream_session_id
        return s:state.selected_stream_session_id
      endif
    endfor
  endif
  let l:non_startup_sessions = []
  for l:session in l:sessions
    if !s:IsStartupSession(l:session)
      call add(l:non_startup_sessions, l:session)
    endif
  endfor
  for l:session in l:non_startup_sessions
    if index(['running', 'queued'], s:SessionStatus(l:session)) >= 0
          \ && s:SessionHasTimeline(l:session)
      return s:SessionId(l:session)
    endif
  endfor
  for l:session in l:non_startup_sessions
    if index(['running', 'queued'], s:SessionStatus(l:session)) >= 0
      return s:SessionId(l:session)
    endif
  endfor
  let l:preferred_with_timeline = s:PreferredRoleSession(l:non_startup_sessions, v:true)
  if l:preferred_with_timeline isnot v:null
    return s:SessionId(l:preferred_with_timeline)
  endif
  for l:session in l:non_startup_sessions
    if s:SessionHasTimeline(l:session)
      return s:SessionId(l:session)
    endif
  endfor
  let l:preferred = s:PreferredRoleSession(l:non_startup_sessions, v:false)
  if l:preferred isnot v:null
    return s:SessionId(l:preferred)
  endif
  if !empty(l:non_startup_sessions)
    return s:SessionId(l:non_startup_sessions[-1])
  endif
  for l:session in l:sessions
    if index(['running', 'queued'], s:SessionStatus(l:session)) >= 0
      return s:SessionId(l:session)
    endif
  endfor
  return empty(l:sessions) ? v:null : s:SessionId(l:sessions[-1])
endfunction

function! s:SelectedBranchId() abort
  for l:session in s:SelectedSessions()
    let l:branch = s:BranchIdFromSession(l:session)
    if l:branch isnot v:null
      return l:branch
    endif
  endfor
  let l:wanted = {}
  for l:sid in s:SessionIdsForTask(s:SelectedTaskId())
    let l:wanted[l:sid] = v:true
  endfor
  for l:branch in s:state.branches
    if has_key(l:wanted, s:BranchSessionId(l:branch))
      return s:BranchId(l:branch)
    endif
  endfor
  return v:null
endfunction

function! s:BranchIdForTask(task_id) abort
  if a:task_id is v:null
    return v:null
  endif
  for l:session in s:TaskSessions(a:task_id)
    let l:branch = s:BranchIdFromSession(l:session)
    if l:branch isnot v:null
      return l:branch
    endif
  endfor
  let l:wanted = {}
  for l:sid in s:SessionIdsForTask(a:task_id)
    let l:wanted[l:sid] = v:true
  endfor
  for l:branch in s:state.branches
    if has_key(l:wanted, s:BranchSessionId(l:branch))
      return s:BranchId(l:branch)
    endif
  endfor
  return v:null
endfunction

function! s:WorkspaceRootFrom(value) abort
  if type(a:value) != v:t_dict
    return v:null
  endif
  for l:key in ['workspacePath', 'workspace_path', 'workingDirectory', 'working_directory', 'cwd', 'root']
    let l:root = s:Get(a:value, l:key)
    if type(l:root) == v:t_string && l:root !=# ''
      return l:root
    endif
  endfor
  return v:null
endfunction

function! s:SelectedWorkspaceRoot() abort
  for l:session in s:SelectedSessions()
    let l:root = s:WorkspaceRootFrom(l:session)
    if l:root isnot v:null
      return l:root
    endif
    let l:full = get(s:state.full_sessions, s:SessionId(l:session), {})
    let l:root = s:WorkspaceRootFrom(l:full)
    if l:root isnot v:null
      return l:root
    endif
  endfor
  return s:WorkspaceRootFrom(s:SelectedTask())
endfunction

function! s:IsByteArray(value) abort
  if type(a:value) != v:t_list || empty(a:value)
    return v:false
  endif
  for l:item in a:value
    if type(l:item) != v:t_number || l:item < 0 || l:item > 255
      return v:false
    endif
  endfor
  return v:true
endfunction

function! s:TextField(event, key) abort
  let l:value = s:Get(a:event, a:key)
  if l:value is v:null
    return v:null
  endif
  if type(l:value) == v:t_string
    return l:value
  endif
  if s:IsByteArray(l:value)
    return join(map(copy(l:value), 'nr2char(v:val)'), '')
  endif
  if type(l:value) == v:t_dict || type(l:value) == v:t_list
    return json_encode(l:value)
  endif
  return string(l:value)
endfunction

" Decode the inner SessionEvent wrapped inside a sub_agent fan-out envelope.
" The REST contract serializes the wrapped event as a JSON byte vector
" (`innerEvent`). Round-trip it through `s:TextField` (which decodes byte
" arrays back into UTF-8) and `json_decode()` to recover the original event.
" Returns v:null when the field is missing or malformed.
function! s:UnwrapSubAgent(event) abort
  let l:raw = s:Get(a:event, 'innerEvent')
  if l:raw is v:null
    let l:raw = s:Get(a:event, 'inner_event')
  endif
  if l:raw is v:null
    return v:null
  endif
  let l:json = v:null
  if type(l:raw) == v:t_string
    let l:json = l:raw
  elseif type(l:raw) == v:t_list && s:IsByteArray(l:raw)
    let l:json = join(map(copy(l:raw), 'nr2char(v:val)'), '')
  endif
  if type(l:json) != v:t_string || empty(l:json)
    return v:null
  endif
  try
    let l:decoded = json_decode(l:json)
  catch
    return v:null
  endtry
  if type(l:decoded) != v:t_dict
    return v:null
  endif
  return l:decoded
endfunction

" Return the effective event seen by the user. For sub_agent envelopes
" (fan-out from a child session into the parent task's timeline), this returns
" the inner SessionEvent so the rest of the rendering pipeline acts on the
" actual agent output ("Review approved", "Supervisor marked …", a file_edit,
" a tool_use, …). For non-sub_agent events it returns the event unchanged.
function! s:EffectiveEvent(event) abort
  if type(a:event) != v:t_dict
    return a:event
  endif
  let l:raw_type = s:TextField(a:event, 'type')
  if l:raw_type ==# 'sub_agent'
    let l:inner = s:UnwrapSubAgent(a:event)
    if l:inner isnot v:null
      return l:inner
    endif
  endif
  return a:event
endfunction

function! s:EventType(event) abort
  return s:TextField(s:EffectiveEvent(a:event), 'type') ?? 'event'
endfunction

function! s:CardType(event) abort
  let l:type = s:EventType(a:event)
  if l:type ==# 'file_edit' || l:type ==# 'diff'
    return 'edited'
  endif
  if l:type ==# 'file_read'
    return 'read'
  endif
  if l:type ==# 'user_input'
    return 'user'
  endif
  if l:type ==# 'turn_complete'
    return 'completed'
  endif
  if l:type ==# 'tool_use'
    return 'ran'
  endif
  return l:type
endfunction

function! s:EventTimestamp(event) abort
  let l:ts = s:Get(a:event, 'timestamp', 0)
  return type(l:ts) == v:t_number ? l:ts : str2nr(string(l:ts))
endfunction

function! s:EventText(event) abort
  " Sub-agent envelopes are unwrapped via s:EffectiveEvent so the rendered
  " card text reflects the inner agent output (e.g. "Review approved",
  " "Supervisor marked …") rather than an opaque "sub_agent" placeholder.
  let l:effective = s:EffectiveEvent(a:event)
  let l:type = s:TextField(l:effective, 'type') ?? 'event'
  if l:type ==# 'status'
    return 'Status: ' .. (s:TextField(l:effective, 'status') ?? 'unknown')
  elseif l:type ==# 'thought'
    return s:TextField(l:effective, 'thought') ?? s:TextField(l:effective, 'reasoning') ?? 'Agent reasoning'
  elseif l:type ==# 'tool_use'
    return s:Trim(join(filter(['Tool started:', s:TextField(l:effective, 'tool_name'), s:TextField(l:effective, 'tool_args')], 'v:val isnot v:null'), ' '))
  elseif l:type ==# 'tool_result'
    return s:Trim(join(filter(['Tool finished:', s:TextField(l:effective, 'tool_name'), s:TextField(l:effective, 'tool_output')], 'v:val isnot v:null'), ' '))
  elseif l:type ==# 'file_edit'
    return s:Trim(join(filter(['Edited', s:TextField(l:effective, 'file_path'), s:TextField(l:effective, 'description')], 'v:val isnot v:null'), ' '))
  elseif l:type ==# 'diff'
    return s:Trim(join(filter(['Edited', s:TextField(l:effective, 'path'), s:TextField(l:effective, 'diff_preview')], 'v:val isnot v:null'), ' '))
  elseif l:type ==# 'file_read'
    return 'Read ' .. (s:TextField(l:effective, 'file_path') ?? 'file')
  elseif l:type ==# 'user_input'
    return s:TextField(l:effective, 'content') ?? 'User input'
  elseif l:type ==# 'log'
    return s:TextField(l:effective, 'message') ?? 'Log entry'
  elseif l:type ==# 'error'
    return 'Error: ' .. (s:TextField(l:effective, 'message') ?? 'unknown')
  elseif index(['orchestration', 'delegation', 'sub_agent'], l:type) >= 0
    return s:TextField(l:effective, 'description') ?? s:TextField(l:effective, 'kind') ?? l:type
  elseif l:type ==# 'turn_complete'
    return 'Turn complete: ' .. (s:TextField(l:effective, 'stop_reason') ?? 'complete')
  endif
  return json_encode(l:effective)
endfunction

function! s:CompareCards(left, right) abort
  if a:left.timestamp == a:right.timestamp
    return a:left.order == a:right.order ? 0 : (a:left.order > a:right.order ? 1 : -1)
  endif
  return a:left.timestamp > a:right.timestamp ? 1 : -1
endfunction

function! s:TimelineCards() abort
  let l:cards = []
  let l:order = 0
  let l:sid = s:SelectedSessionId()
  if l:sid isnot v:null
    let l:index = 0
    for l:event in get(s:state.session_events, l:sid, [])
      let l:index += 1
      let l:order += 1
      " Unwrap sub_agent envelopes so card metadata (type, file path) tracks
      " the child session's actual fan-out payload.
      let l:effective = s:EffectiveEvent(l:event)
      let l:type = s:EventType(l:event)
      call add(l:cards, {
            \ 'id': printf('%s:%s:%s:%s', l:sid, s:EventTimestamp(l:event), l:type, l:index),
            \ 'sessionId': l:sid,
            \ 'type': s:CardType(l:event),
            \ 'eventType': l:type,
            \ 'timestamp': s:EventTimestamp(l:event),
            \ 'filePath': s:TextField(l:effective, 'file_path') ?? s:TextField(l:effective, 'path'),
            \ 'text': s:EventText(l:event),
            \ 'order': l:order,
            \ })
    endfor
  endif
  call sort(l:cards, 's:CompareCards')
  for l:card in l:cards
    call remove(l:card, 'order')
  endfor
  return l:cards
endfunction

function! s:ChannelRoutingIndicator() abort
  " Presence-change / notification-route signals can arrive as log /
  " tool_output payloads inside a sub_agent envelope (the child session's
  " own message). Unwrap before extracting the indicator text so the
  " focused task header surfaces the live route.
  let l:route = v:null
  for l:session in s:SelectedSessions()
    let l:sid = s:SessionId(l:session)
    if l:sid is v:null
      continue
    endif
    for l:event in get(s:state.session_events, l:sid, [])
      let l:effective = s:EffectiveEvent(l:event)
      let l:message = s:TextField(l:effective, 'message') ?? s:EventText(l:effective)
      let l:match = matchlist(l:message, 'presence change:.*active_channel: "\([^"]\+\)"')
      if !empty(l:match)
        let l:route = l:match[1]
      endif
      let l:match = matchlist(l:message, 'notification_route=\([[:alnum:]_-]\+\)')
      if !empty(l:match)
        let l:route = l:match[1]
      endif
    endfor
  endfor
  return l:route is v:null ? v:null : 'Notifications routed to: ' .. toupper(l:route[0]) .. l:route[1:]
endfunction

function! s:TaskStatus(task) abort
  let l:id = s:TaskId(a:task)
  let l:latest = v:null
  let l:latest_ts = -1
  for l:session in s:TaskSessions(l:id)
    let l:sid = s:SessionId(l:session)
    for l:event in get(s:state.session_events, l:sid, [])
      " Intentionally DO NOT unwrap sub_agent envelopes here. The task's
      " overall status is the OUTER task's status, owned by the manager
      " session that hosts the task in the daemon. Child-session status
      " transitions (a sub-agent flipping from running to completed and
      " back) arrive as sub_agent envelopes on the parent's history;
      " folding those in would make the focused-task status oscillate
      " whenever a late child status event lands, even after the
      " manager's terminal status has settled.
      if s:TextField(l:event, 'type') ==# 'status'
        let l:ts = s:EventTimestamp(l:event)
        if l:ts >= l:latest_ts
          let l:latest_ts = l:ts
          let l:latest = s:TextField(l:event, 'status')
        endif
      endif
    endfor
  endfor
  if l:latest isnot v:null
    return l:latest
  endif
  let l:statuses = map(copy(s:TaskSessions(l:id)), 's:SessionStatus(v:val)')
  for l:status in l:statuses
    if index(['failed', 'cancelled', 'stopped'], l:status) >= 0
      return l:status
    endif
  endfor
  for l:status in l:statuses
    if index(['running', 'provisioning'], l:status) >= 0
      return 'running'
    endif
  endfor
  " `finished` and `reclaimed` are the resource-axis terminal states: the work
  " ended with its resources still held, or released. A task all of whose
  " sessions are in one of them is over, so it rolls up as 'completed' rather
  " than falling through to the task's own (often stale) status field.
  if !empty(l:statuses) && empty(filter(copy(l:statuses), 'index(["completed", "finished", "reclaimed"], v:val) < 0'))
    return 'completed'
  endif
  return s:Get(a:task, 'status', 'unknown')
endfunction

function! s:DiffFiles(diff) abort
  let l:files = {}
  let l:untracked = s:Get(a:diff, 'untrackedFiles', s:Get(a:diff, 'untracked_files', []))
  for l:file in l:untracked
    let l:files[l:file] = v:true
  endfor
  for l:line in split(s:Get(a:diff, 'stat', ''), "\n")
    let l:match = matchlist(l:line, '^\s*\([^|]\{-}\)\s*|')
    if !empty(l:match) && s:Trim(l:match[1]) !=# ''
      let l:files[s:Trim(l:match[1])] = v:true
    endif
  endfor
  return sort(keys(l:files))
endfunction

function! s:ModifiedFiles() abort
  let l:files = {}
  for l:session in s:SelectedSessions()
    let l:sid = s:SessionId(l:session)
    if l:sid is v:null
      continue
    endif
    for l:event in get(s:state.session_events, l:sid, [])
      let l:effective = s:EffectiveEvent(l:event)
      let l:type = s:EventType(l:event)
      if l:type ==# 'file_edit'
        let l:file = s:TextField(l:effective, 'file_path')
      elseif l:type ==# 'diff'
        let l:file = s:TextField(l:effective, 'path')
      else
        let l:file = v:null
      endif
      if l:file isnot v:null
        let l:files[l:file] = v:true
      endif
    endfor
  endfor
  let l:selected = s:SelectedTaskId()
  for l:file in get(s:state.task_diff_files, l:selected, [])
    let l:files[l:file] = v:true
  endfor
  return sort(keys(l:files))
endfunction

function! s:RenderLines() abort
  let l:lines = ['Agent Harbor', '', 'Daemon: AH ' .. s:state.daemon.state, '']
  call add(l:lines, 'Help: :AgentHarborDocs')
  let l:count = len(s:state.tasks)
  call add(l:lines, (s:state.accordion_collapsed ? '[+]' : '[-]') .. ' Active Tasks (' .. l:count .. ')')
  if s:state.accordion_collapsed
    let l:task = s:SelectedTask()
    if l:task isnot v:null
      call add(l:lines, '  ' .. s:TaskTitle(l:task))
    endif
  elseif empty(s:state.tasks)
    call add(l:lines, '  No active tasks.')
  else
    for l:task in s:state.tasks
      let l:id = s:TaskId(l:task)
      call add(l:lines, (l:id ==# s:SelectedTaskId() ? '* ' : '  ') .. s:TaskStatus(l:task) .. '  ' .. s:TaskTitle(l:task))
      call add(l:lines, '    task: ' .. l:id)
      let l:sessions = s:SessionIdsForTask(l:id)
      if !empty(l:sessions)
        call add(l:lines, '    sessions: ' .. join(l:sessions, ', '))
      endif
    endfor
  endif
  call add(l:lines, '')
  let l:task = s:SelectedTask()
  if l:task isnot v:null
    call add(l:lines, 'Focused: ' .. s:TaskTitle(l:task))
    call add(l:lines, 'Status: ' .. s:TaskStatus(l:task))
    call add(l:lines, 'Task: ' .. s:TaskId(l:task))
    if s:SelectedSessionId() isnot v:null
      call add(l:lines, 'Session: ' .. s:SelectedSessionId())
    endif
    if s:SelectedBranchId() isnot v:null
      call add(l:lines, 'Branch: ' .. s:SelectedBranchId())
    endif
    call add(l:lines, 'Actions: [Share Task] [Reply] [New Task]')
  else
    call add(l:lines, 'Focused: none')
  endif
  call extend(l:lines, ['', 'Modified Files'])
  if empty(s:state.modified_files)
    call add(l:lines, '  None')
  else
    for l:file in s:state.modified_files
      call add(l:lines, '  ' .. l:file)
    endfor
  endif
  call extend(l:lines, ['', 'Activity Timeline'])
  if empty(s:state.timeline_cards)
    call add(l:lines, '  No activity yet.')
  else
    for l:card in s:state.timeline_cards
      call add(l:lines, '> ' .. l:card.type .. '  ' .. l:card.sessionId)
      call add(l:lines, '  ' .. l:card.text)
      call add(l:lines, '')
    endfor
  endif
  return l:lines
endfunction

function! s:Render() abort
  let s:state.timeline_cards = s:TimelineCards()
  let s:state.modified_files = s:ModifiedFiles()
  let l:lines = s:RenderLines()
  if s:config.panel.mode ==# 'split'
    if !bufexists(s:state.panel_bufnr)
      botright vertical new
      let s:state.panel_bufnr = bufnr('%')
      file Agent\ Harbor
      setlocal buftype=nofile bufhidden=hide noswapfile nowrap
    endif
    let l:current = bufnr('%')
    execute 'buffer' s:state.panel_bufnr
    setlocal modifiable noreadonly
    call setline(1, l:lines)
    if line('$') > len(l:lines)
      execute (len(l:lines) + 1) .. ',$delete _'
    endif
    setlocal nomodifiable readonly
    execute 'buffer' l:current
  elseif exists('*popup_create')
    if s:state.panel_popup <= 0
      let s:state.panel_popup = popup_create(l:lines, {
            \ 'title': ' Agent Harbor ',
            \ 'minwidth': s:config.panel.width,
            \ 'maxwidth': s:config.panel.width,
            \ 'minheight': 20,
            \ 'border': [],
            \ 'padding': [0, 1, 0, 1],
            \ })
    else
      call popup_settext(s:state.panel_popup, l:lines)
    endif
  endif
endfunction

function! s:HistoryEvents(history) abort
  let l:events = deepcopy(s:Get(a:history, 'events', []))
  return reverse(l:events)
endfunction

function! s:RefreshTaskData() abort
  let l:task_response = s:Request('GET', '/tasks', v:null, {'timeout_ms': 5000})
  let s:state.tasks = s:Get(l:task_response, 'tasks', [])
  let l:sessions_response = s:Request('GET', '/sessions?perPage=100', v:null, {'timeout_ms': 5000})
  let s:state.full_sessions = {}
  for l:session in s:Get(l:sessions_response, 'items', [])
    if s:SessionId(l:session) isnot v:null
      let s:state.full_sessions[s:SessionId(l:session)] = l:session
    endif
  endfor
  let s:state.branches = s:Get(s:Request('GET', '/branches', v:null, {'timeout_ms': 5000}), 'branches', [])
  let l:selected_exists = v:false
  for l:task in s:state.tasks
    let l:selected_exists = l:selected_exists || s:TaskId(l:task) ==# s:state.selected_task_id
  endfor
  if !l:selected_exists
    let s:state.selected_task_id = empty(s:state.tasks) ? v:null : s:TaskId(s:state.tasks[0])
  endif
  " Only deep-refresh the currently focused task. Non-focused accordion rows
  " render from the cheap list_tasks summary so the panel stays responsive on
  " daemons that host many task records (loop-driver PLANNING runs alone can
  " push the per-tenant task count by an order of magnitude).
  if s:state.selected_task_id isnot v:null
    let l:id = s:state.selected_task_id
    let l:task_sessions = s:Get(s:Request('GET', '/tasks/' .. s:PathEscape(l:id) .. '/sessions', v:null, {'timeout_ms': 5000}), 'sessions', [])
    let s:state.task_sessions[l:id] = l:task_sessions
    try
      let l:diff = s:Request('GET', '/tasks/' .. s:PathEscape(l:id) .. '/diff', v:null, {'timeout_ms': 5000})
      let s:state.task_diff_files[l:id] = s:DiffFiles(l:diff)
      let s:state.task_diff_status[l:id] = {'ok': v:true, 'error': v:null}
    catch
      let s:state.task_diff_files[l:id] = []
      let s:state.task_diff_status[l:id] = {'ok': v:false, 'error': v:exception}
    endtry
    for l:session in l:task_sessions
      let l:sid = s:SessionId(l:session)
      if l:sid is v:null
        continue
      endif
      let l:history = s:Request('GET', '/sessions/' .. s:PathEscape(l:sid) .. '/events/history?limit=' .. s:config.panel.history_limit, v:null, {'timeout_ms': 5000})
      let s:state.session_history_counts[l:sid] = s:Get(l:history, 'total_count', 0)
      let s:state.session_events[l:sid] = s:HistoryEvents(l:history)
    endfor
  endif
endfunction

function! s:NormalizeDir(path) abort
  let l:path = fnamemodify(a:path, ':p')
  return l:path =~# '/$' ? l:path : l:path .. '/'
endfunction

function! s:RelativePath(path, root) abort
  return substitute(fnamemodify(a:path, ':p')[len(s:NormalizeDir(a:root)):], '\\', '/', 'g')
endfunction

function! s:InRoot(path, root) abort
  return a:path !=# '' && a:root !=# '' && fnamemodify(a:path, ':p')[:len(s:NormalizeDir(a:root)) - 1] ==# s:NormalizeDir(a:root)
endfunction

function! s:Join(root, relative) abort
  return s:NormalizeDir(a:root) .. a:relative
endfunction

function! s:RootFileBuffers(root) abort
  let l:buffers = []
  for l:bufnr in range(1, bufnr('$'))
    if bufloaded(l:bufnr) && s:InRoot(bufname(l:bufnr), a:root)
      call add(l:buffers, l:bufnr)
    endif
  endfor
  return l:buffers
endfunction

function! s:ChangeKind(change) abort
  return tolower(substitute(substitute(string(s:Get(a:change, 'kind', '')), "'", '', 'g'), '_', '-', 'g'))
endfunction

function! s:ChangeFor(relative, manifest) abort
  for l:change in s:Get(a:manifest, 'changes', [])
    let l:path = s:Get(l:change, 'path')
    if l:path is v:null
      continue
    endif
    if s:ChangeKind(l:change) ==# 'tree-replaced'
      if a:relative ==# l:path || a:relative[:len(l:path)] ==# l:path .. '/'
        return l:change
      endif
    elseif a:relative ==# l:path
      return l:change
    endif
  endfor
  return v:null
endfunction

function! s:OpenModifiedPrompt() abort
  let l:lines = [
        \ 'Modified buffers are open in this Agent Harbor branch.',
        \ '',
        \ '[s] stash and switch   [k] keep buffers',
        \ '[d] kill buffers       [a] abort switch',
        \ ]
  botright new
  let s:state.prompt.bufnr = bufnr('%')
  let s:state.prompt.winnr = winnr()
  let s:state.prompt.text = join(l:lines, "\n")
  let s:state.prompt.visible = v:true
  file Agent\ Harbor\ Modified\ Buffers
  setlocal buftype=nofile bufhidden=wipe noswapfile
  call setline(1, l:lines)
  setlocal nomodifiable readonly
endfunction

function! s:ModifiedAction(root) abort
  let l:modified = []
  for l:bufnr in s:RootFileBuffers(a:root)
    if getbufvar(l:bufnr, '&modified')
      call add(l:modified, l:bufnr)
    endif
  endfor
  if empty(l:modified)
    return 'none'
  endif
  let l:policy = s:config.workspace.on_switch_modified
  if l:policy ==# 'prompt'
    call s:OpenModifiedPrompt()
    if exists('g:agent_harbor_prompt_action')
      return g:agent_harbor_prompt_action
    endif
    let l:key = getcharstr()
    return get({'s': 'stash', 'k': 'keep', 'd': 'kill', 'a': 'abort'}, l:key, 'abort')
  endif
  return l:policy
endfunction

function! s:RetargetBuffer(bufnr, new_root, relative, reload) abort
  if !bufexists(a:bufnr)
    return v:false
  endif
  let l:current = bufnr('%')
  let l:view = winsaveview()
  execute 'buffer' a:bufnr
  let l:new_file = s:Join(a:new_root, a:relative)
  execute 'file ' .. fnameescape(l:new_file)
  if !filereadable(l:new_file)
    setlocal nomodified
    execute 'bdelete! ' .. a:bufnr
    if bufexists(l:current)
      execute 'buffer' l:current
      call winrestview(l:view)
    endif
    return v:false
  endif
  if a:reload
    silent keepalt edit!
  endif
  if bufexists(l:current)
    execute 'buffer' l:current
    call winrestview(l:view)
  endif
  return v:true
endfunction

function! s:ApplyManifest(old_root, new_root, manifest) abort
  for l:bufnr in s:RootFileBuffers(a:old_root)
    if !bufexists(l:bufnr) || getbufvar(l:bufnr, '&modified')
      continue
    endif
    let l:relative = s:RelativePath(bufname(l:bufnr), a:old_root)
    let l:change = s:ChangeFor(l:relative, a:manifest)
    if l:change is v:null
      call s:RetargetBuffer(l:bufnr, a:new_root, l:relative, v:false)
    elseif s:ChangeKind(l:change) ==# 'deleted'
      execute 'bdelete! ' .. l:bufnr
    else
      call s:RetargetBuffer(l:bufnr, a:new_root, l:relative, v:true)
    endif
  endfor
endfunction

function! s:ResolveBranch(task_id, requested_branch_id) abort
  if s:state.daemon.state !=# 'connected'
    call s:DaemonRefresh()
  endif
  let l:sessions = s:Get(s:Request('GET', '/tasks/' .. s:PathEscape(a:task_id) .. '/sessions', v:null, {'timeout_ms': 5000}), 'sessions', [])
  let l:wanted = {}
  for l:session in l:sessions
    let l:wanted[s:SessionId(l:session)] = v:true
  endfor
  let l:branches = s:Get(s:Request('GET', '/branches', v:null, {'timeout_ms': 5000}), 'branches', [])
  let l:fallback = v:null
  for l:branch in l:branches
    if has_key(l:wanted, s:BranchSessionId(l:branch))
      if a:requested_branch_id isnot v:null && s:BranchId(l:branch) ==# a:requested_branch_id
        return l:branch
      endif
      let l:fallback = l:branch
    endif
  endfor
  return l:fallback
endfunction

function! agent_harbor#setup(...) abort
  let s:config = s:MergeConfig(s:defaults, a:0 ? a:1 : {})
  call s:DaemonRefresh()
  return s:state.daemon.state
endfunction

function! agent_harbor#open_docs() abort
  let l:url = s:Get(s:config.docs, 'url', 'https://docs.agent-harbor.com/editor-support/vim')
  if has('win32') || has('win64')
    execute 'silent !start "" ' .. shellescape(l:url)
  elseif has('mac')
    call system('open ' .. shellescape(l:url))
  else
    call system('xdg-open ' .. shellescape(l:url))
  endif
  return l:url
endfunction

function! agent_harbor#open() abort
  call agent_harbor#refresh()
  return s:state.panel_popup > 0 ? s:state.panel_popup : s:state.panel_bufnr
endfunction

function! agent_harbor#refresh() abort
  call s:DaemonRefresh()
  if s:state.daemon.state ==# 'connected'
    try
      call s:RefreshTaskData()
      let s:state.last_error = v:null
    catch
      let s:state.last_error = v:exception
    endtry
  endif
  call s:Render()
  return agent_harbor#side_panel_state()
endfunction

function! agent_harbor#select_task(task_id) abort
  let s:state.selected_task_id = a:task_id
  let s:state.selected_stream_session_id = v:null
  let s:state.accordion_collapsed = v:false
  call agent_harbor#refresh()
  return agent_harbor#side_panel_state()
endfunction

function! agent_harbor#select_stream(session_id) abort
  let l:task_id = s:SelectedTaskId()
  if l:task_id is v:null || index(s:SessionIdsForTask(l:task_id), a:session_id) < 0
    throw 'Session ' .. a:session_id .. ' is not part of the selected task'
  endif
  let s:state.selected_stream_session_id = a:session_id
  call s:Render()
  return a:session_id
endfunction

function! agent_harbor#share_task(...) abort
  let l:task_id = a:0 && a:1 !=# '' ? a:1 : s:SelectedTaskId()
  if l:task_id is v:null || l:task_id ==# ''
    throw 'No Agent Harbor task is selected'
  endif
  let l:branch_id = s:BranchIdForTask(l:task_id)
  if l:branch_id is v:null || l:branch_id ==# ''
    throw 'Task ' .. l:task_id .. ' does not have an AgentHarborFS branch to share'
  endif
  let l:ttl = a:0 > 1 && a:2 !=# '' ? a:2 : '24h'
  let l:share = s:Request('POST', '/agentharborfs/share', {
        \ 'identifier': l:branch_id,
        \ 'scope': 'branch',
        \ 'ttl': l:ttl,
        \ }, {'timeout_ms': 3000})
  let l:url = s:Get(l:share, 'url')
  if type(l:url) != v:t_string || l:url ==# ''
    throw 'Share response did not include a URL'
  endif
  call setreg('"', l:url)
  if has('clipboard')
    call setreg('+', l:url)
  endif
  let s:state.last_share = {
        \ 'taskId': l:task_id,
        \ 'branchId': l:branch_id,
        \ 'scope': 'branch',
        \ 'ttl': l:ttl,
        \ 'url': l:url,
        \ 'response': l:share,
        \ }
  echom 'Agent Harbor share URL copied'
  return l:url
endfunction

function! agent_harbor#toggle_accordion() abort
  let s:state.accordion_collapsed = !s:state.accordion_collapsed
  call s:Render()
endfunction

function! agent_harbor#focus(task_id, ...) abort
  let l:opts = a:0 ? a:1 : {}
  let l:branch = s:ResolveBranch(a:task_id, s:Get(l:opts, 'branch_id'))
  if l:branch is v:null || s:BranchId(l:branch) is v:null || s:BranchRoot(l:branch) is v:null
    throw 'Branch metadata for task ' .. a:task_id .. ' is incomplete'
  endif
  let l:target_branch = s:BranchId(l:branch)
  let l:target_root = s:BranchRoot(l:branch)
  if s:state.workspace.branchId is v:null
    let s:state.workspace.taskId = a:task_id
    let s:state.workspace.branchId = l:target_branch
    let s:state.workspace.root = s:NormalizeDir(l:target_root)
    let s:state.workspace.lastRetarget = {'action': 'initialized-current-task', 'retargeted': v:false, 'fallback': v:false}
    execute 'cd ' .. fnameescape(l:target_root)
    return agent_harbor#workspace_state()
  endif
  if l:target_branch !=# s:state.workspace.branchId
    let l:old_root = s:state.workspace.root
    let l:manifest = s:Request('POST', '/sessions/' .. s:PathEscape(a:task_id) .. '/sandbox-diff?from=' .. s:PathEscape(s:state.workspace.branchId) .. '&to=' .. s:PathEscape(l:target_branch), {}, {'timeout_ms': 3000})
    let l:action = s:ModifiedAction(l:old_root)
    if l:action ==# 'abort'
      throw 'Agent Harbor task switch aborted'
    elseif l:action ==# 'kill'
      for l:bufnr in s:RootFileBuffers(l:old_root)
        if getbufvar(l:bufnr, '&modified')
          call setbufvar(l:bufnr, '&modified', 0)
          execute 'bdelete! ' .. l:bufnr
        endif
      endfor
    endif
    call s:ApplyManifest(l:old_root, l:target_root, l:manifest)
    execute 'cd ' .. fnameescape(l:target_root)
    let s:state.workspace.taskId = a:task_id
    let s:state.workspace.branchId = l:target_branch
    let s:state.workspace.root = s:NormalizeDir(l:target_root)
    let s:state.workspace.lastRetarget = {
          \ 'action': 'sandbox-diff',
          \ 'retargeted': v:false,
          \ 'fallback': v:false,
          \ 'fromBranchId': s:Get(l:manifest, 'from_branch_id', v:null),
          \ 'toBranchId': l:target_branch,
          \ 'oldRoot': l:old_root,
          \ 'targetRoot': l:target_root,
          \ 'manifest': l:manifest,
          \ 'modifiedAction': l:action,
          \ }
  else
    let s:state.workspace.taskId = a:task_id
    execute 'cd ' .. fnameescape(l:target_root)
  endif
  return agent_harbor#workspace_state()
endfunction

function! agent_harbor#reveal_file(path) abort
  let l:root = s:Get(s:state.workspace, 'root')
  if l:root is v:null
    let l:branch_id = s:SelectedBranchId()
    for l:branch in s:state.branches
      if s:BranchId(l:branch) ==# l:branch_id
        let l:root = s:BranchRoot(l:branch)
      endif
    endfor
  endif
  if l:root is v:null
    let l:root = s:SelectedWorkspaceRoot()
  endif
  if l:root is v:null && exists('g:agent_harbor_workspace_root')
    let l:root = g:agent_harbor_workspace_root
  endif
  if l:root is v:null
    throw 'No Agent Harbor branch root is selected'
  endif
  let l:file = s:Join(l:root, a:path)
  execute 'edit ' .. fnameescape(l:file)
  let l:content = join(getline(1, '$'), "\n") .. "\n"
  return {'path': a:path, 'file': expand('%:p'), 'content': l:content, 'sha256': sha256(l:content)}
endfunction

function! agent_harbor#side_panel_state() abort
  let l:tasks = []
  for l:task in s:state.tasks
    let l:id = s:TaskId(l:task)
    let l:branches = []
    for l:session in s:TaskSessions(l:id)
      if s:BranchIdFromSession(l:session) isnot v:null && index(l:branches, s:BranchIdFromSession(l:session)) < 0
        call add(l:branches, s:BranchIdFromSession(l:session))
      endif
    endfor
    call add(l:tasks, {
          \ 'id': l:id,
          \ 'status': s:TaskStatus(l:task),
          \ 'title': s:TaskTitle(l:task),
          \ 'sessionIds': s:SessionIdsForTask(l:id),
          \ 'branchIds': l:branches,
          \ 'selected': l:id ==# s:SelectedTaskId(),
          \ })
  endfor
  let l:history_total = 0
  let l:selected_session = s:SelectedSessionId()
  if l:selected_session isnot v:null
    let l:history_total = get(s:state.session_history_counts, l:selected_session, 0)
  endif
  let l:task = s:SelectedTask()
  let l:selected = s:SelectedTaskId()
  let l:diff_status = get(s:state.task_diff_status, l:selected, {'ok': v:false, 'error': v:null})
  let l:diff_files = deepcopy(get(s:state.task_diff_files, l:selected, []))
  return {
        \ 'daemon': deepcopy(s:state.daemon),
        \ 'header': {'newTaskButtonVisible': v:false},
        \ 'tasks': l:tasks,
        \ 'activeTasks': {'filter': v:null, 'count': len(l:tasks), 'dropdownAvailable': !empty(l:tasks)},
        \ 'selectedTaskId': l:selected,
        \ 'selectedSessionId': s:SelectedSessionId(),
        \ 'selectedBranchId': s:SelectedBranchId(),
        \ 'focusedTask': {
        \   'title': l:task is v:null ? v:null : s:TaskTitle(l:task),
        \   'status': l:task is v:null ? v:null : s:TaskStatus(l:task),
        \   'taskId': l:selected,
        \   'agentCount': len(s:SelectedSessions()),
        \   'streamOptions': s:SessionIdsForTask(l:selected),
        \   'actionRow': ['share', 'reply', 'new-task'],
        \   'branchId': s:SelectedBranchId(),
        \ },
        \ 'lastShare': deepcopy(s:state.last_share),
        \ 'focusedTitle': l:task is v:null ? v:null : s:TaskTitle(l:task),
        \ 'focusedStatus': l:task is v:null ? v:null : s:TaskStatus(l:task),
        \ 'replyRows': 0,
        \ 'quickActionIds': [],
        \ 'replyOverlay': {'visible': v:false, 'popupVisible': v:false},
        \ 'taskEntry': {'visible': v:false},
        \ 'notifications': {'channelRoutingIndicator': s:ChannelRoutingIndicator(), 'bannerText': s:state.last_error},
        \ 'panel': {'error': s:state.last_error, 'activeSseCount': 0},
        \ 'accordionCollapsed': s:state.accordion_collapsed,
        \ 'timelineEventCount': l:history_total,
        \ 'sseEventCount': 0,
        \ 'timeline': {'autoFollow': v:true, 'searchQuery': v:null},
        \ 'timelineCards': deepcopy(s:state.timeline_cards),
        \ 'modifiedFiles': deepcopy(s:state.modified_files),
        \ 'daemonDiffModifiedFiles': l:diff_files,
        \ 'daemonDiff': {'ok': s:Get(l:diff_status, 'ok') == v:true, 'error': s:Get(l:diff_status, 'error'), 'modifiedFiles': l:diff_files},
        \ }
endfunction

function! agent_harbor#workspace_state() abort
  return {'workspace': deepcopy(s:state.workspace), 'prompt': deepcopy(s:state.prompt)}
endfunction

function! agent_harbor#branchfs_read(uri) abort
  if s:state.daemon.state !=# 'connected'
    call s:DaemonRefresh()
  endif
  let l:resource = s:BranchFsParse(a:uri)
  let l:status = s:BranchFsStatus(l:resource.id)
  let l:bytes = s:RequestRaw(
        \ 'GET',
        \ '/branches/' .. s:PathEscape(l:resource.id) .. '/files/' .. s:PathEscape(l:resource.path),
        \ v:null,
        \ {'timeout_ms': 3000})
  setlocal modifiable noreadonly
  silent %delete _
  if l:bytes !=# ''
    call setline(1, split(l:bytes, "\n", 1))
    if getline('$') ==# ''
      silent $delete _
    endif
  endif
  let b:agent_harbor_branchfs_uri = a:uri
  let b:agent_harbor_branchfs_branch_id = l:resource.id
  let b:agent_harbor_branchfs_path = l:resource.path
  let b:agent_harbor_branchfs_expected_head = s:Get(l:status, 'headSnapshotId', s:Get(l:status, 'head_snapshot_id'))
  setlocal buftype=acwrite noswapfile
  if s:Get(l:status, 'writable') == v:true
    setlocal noreadonly modifiable
  else
    setlocal readonly nomodifiable
  endif
  setlocal nomodified
  return {'uri': a:uri, 'branchId': l:resource.id, 'path': l:resource.path, 'writable': s:Get(l:status, 'writable')}
endfunction

function! agent_harbor#branchfs_write(uri) abort
  if s:state.daemon.state !=# 'connected'
    call s:DaemonRefresh()
  endif
  let l:resource = s:BranchFsParse(a:uri)
  let l:status = s:BranchFsStatus(l:resource.id)
  if s:Get(l:status, 'writable') != v:true
    setlocal modified
    throw 'Agent Harbor BranchFS branch is ' .. string(s:Get(l:status, 'mutationMode', s:Get(l:status, 'mutation_mode'))) .. '; writes are disabled'
  endif
  let l:expected = exists('b:agent_harbor_branchfs_expected_head')
        \ ? b:agent_harbor_branchfs_expected_head
        \ : s:Get(l:status, 'headSnapshotId', s:Get(l:status, 'head_snapshot_id'))
  let l:bytes = join(getline(1, '$'), "\n") .. "\n"
  try
    let l:body = s:RequestRaw(
          \ 'PUT',
          \ '/branches/' .. s:PathEscape(l:resource.id) .. '/files/' .. s:PathEscape(l:resource.path),
          \ l:bytes,
          \ {'timeout_ms': 3000, 'expected_head': l:expected})
    let l:response = json_decode(l:body)
    let b:agent_harbor_branchfs_expected_head = s:Get(l:response, 'headSnapshotId',
          \ s:Get(s:Get(l:response, 'head', {}), 'headSnapshotId',
          \ s:Get(s:Get(l:response, 'head', {}), 'head_snapshot_id')))
    setlocal noreadonly modifiable nomodified
    return l:response
  catch
    let s:state.last_error = v:exception
    setlocal modified
    throw 'Agent Harbor BranchFS write failed: ' .. v:exception
  endtry
endfunction

function! agent_harbor#unsupported(feature) abort
  echohl WarningMsg
  echom 'Agent Harbor Vim 9 fallback is read-only; ' .. a:feature .. ' is available in Neovim only.'
  echohl None
  return v:false
endfunction

function! agent_harbor#new_task() abort
  return agent_harbor#unsupported('task entry')
endfunction

function! agent_harbor#reply(...) abort
  return agent_harbor#unsupported('reply input')
endfunction

function! agent_harbor#voice(...) abort
  return agent_harbor#unsupported('voice input')
endfunction

" --- Task-prompt mode ------------------------------------------------------
"
" Completion for the scratch file `ah task create` / `ah plan` open in
" `$EDITOR`. Candidates come from `ah autocomplete --json`, which is also the
" authority for the token rules, so this surface cannot drift away from the TUI
" dashboard's prompt textarea. See `specs/CLI/task.md`.

function! agent_harbor#task_prompt_workspace() abort
  " `ah` publishes the invoking directory because the scratch file itself lives
  " in the temp directory, so `getcwd()` alone would resolve `@` against it.
  if !empty($AH_PROMPT_WORKSPACE)
    return $AH_PROMPT_WORKSPACE
  endif
  return getcwd()
endfunction

" Cheap local check: does the token before byte offset a:cursor start with a
" trigger character? This only decides whether to spawn `ah`; the replacement
" span still comes from `ah`.
function! agent_harbor#task_prompt_trigger_active(line, cursor) abort
  let l:prefix = strpart(a:line, 0, a:cursor)
  " Token boundaries are whitespace and quotes, matching the dashboard.
  let l:token = matchstr(l:prefix, '[^[:space:]"'']*$')
  if empty(l:token)
    return v:false
  endif
  let l:first = l:token[0]
  if l:first !=# '/' && l:first !=# '~' && l:first !=# '@'
    return v:false
  endif
  " `@` needs at least one character after it; `/` and `~` fire immediately.
  if l:first ==# '@' && strlen(l:token) < 2
    return v:false
  endif
  return v:true
endfunction

function! agent_harbor#task_prompt_request(line, cursor) abort
  let l:cwd = getcwd()
  try
    call chdir(agent_harbor#task_prompt_workspace())
    " A List argument runs the command directly, with no shell quoting to get
    " wrong -- prompt text routinely contains quotes and spaces.
    let l:output = system(['ah', 'autocomplete', '--json',
          \ '--line', a:line,
          \ '--cursor', string(a:cursor),
          \ '--limit', '25'])
  finally
    call chdir(l:cwd)
  endtry
  if v:shell_error != 0
    throw 'ah autocomplete failed: ' .. trim(l:output)
  endif
  return json_decode(l:output)
endfunction

function! agent_harbor#task_prompt_omnifunc(findstart, base) abort
  let l:line = getline('.')
  " `col('.')` is 1-based; `ah autocomplete --cursor` wants a 0-based byte
  " offset.
  let l:cursor = col('.') - 1

  if a:findstart
    let b:agent_harbor_task_prompt_pending = v:null
    if !agent_harbor#task_prompt_trigger_active(l:line, l:cursor)
      return -3
    endif
    try
      let l:response = agent_harbor#task_prompt_request(l:line, l:cursor)
    catch
      echohl WarningMsg
      echom 'Agent Harbor completion unavailable: ' .. v:exception
      echohl None
      return -3
    endtry
    if type(l:response) != v:t_dict || get(l:response, 'tokenStart', v:null) is v:null
      return -3
    endif
    let b:agent_harbor_task_prompt_pending = l:response
    return l:response.tokenStart
  endif

  let l:response = get(b:, 'agent_harbor_task_prompt_pending', v:null)
  let b:agent_harbor_task_prompt_pending = v:null
  if l:response is v:null
    return []
  endif
  let l:items = []
  for l:item in get(l:response, 'items', [])
    " `word` is the full replacement, trigger character included, because the
    " client replaces the whole token.
    call add(l:items, {
          \ 'word': get(l:item, 'replacement', ''),
          \ 'abbr': get(l:item, 'label', get(l:item, 'replacement', '')),
          \ 'menu': get(l:item, 'kind', ''),
          \ 'equal': 1,
          \ 'icase': 1,
          \ })
  endfor
  return l:items
endfunction

function! agent_harbor#task_prompt_finish() abort
  silent write
  quit
endfunction

function! agent_harbor#task_prompt_abort() abort
  " `ah` treats a prompt that is empty after comment stripping as an abort, so
  " emptying the buffer is the documented way to cancel.
  silent %delete _
  silent write
  quit
endfunction
