" Copyright 2026 Schelling Point Labs Inc
" SPDX-License-Identifier: AGPL-3.0-only
"
" Detect the scratch file `ah task create` / `ah plan` open in `$EDITOR`.
"
" The basename prefix and the extension must BOTH match, so a user's own
" `notes.ahtask` is left alone. These patterns contain no `/`, so Vim matches
" them against the file name tail; the scratch file lives in a temp directory
" whose location varies per platform, which is exactly why the contract puts
" the recognizable part in the basename.
"
" See `specs/CLI/task.md` ("Editor scratch-file contract").

augroup AgentHarborTaskPrompt
  autocmd!
  autocmd BufRead,BufNewFile ah-task-prompt-*.ahtask
        \ setfiletype agent-harbor-task-prompt
  autocmd BufRead,BufNewFile ah-plan-prompt-*.ahplan
        \ setfiletype agent-harbor-task-prompt
augroup END
