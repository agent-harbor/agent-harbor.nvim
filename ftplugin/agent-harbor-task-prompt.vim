" Copyright 2026 Schelling Point Labs Inc
" SPDX-License-Identifier: AGPL-3.0-only
"
" Vim 9 buffer setup for an Agent Harbor task or plan prompt.
"
" Neovim loads both `ftplugin/<ft>.vim` and `ftplugin/<ft>.lua`, so bail out
" here and let the Lua ftplugin own the buffer under Neovim. Vim 9 gets the
" read-and-complete path only: `omnifunc` is synchronous, with no auto-trigger,
" matching this extension's "Vim 9 is read-mostly" stance.

if has('nvim')
  finish
endif

setlocal commentstring=#\ %s
setlocal omnifunc=agent_harbor#task_prompt_omnifunc
setlocal noswapfile

nnoremap <buffer> <silent> <C-s> :call agent_harbor#task_prompt_finish()<CR>
nnoremap <buffer> <silent> <leader>ak :call agent_harbor#task_prompt_abort()<CR>
inoremap <buffer> <silent> <C-Space> <C-x><C-o>
