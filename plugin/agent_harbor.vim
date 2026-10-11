" Copyright 2026 Schelling Point Labs Inc
" SPDX-License-Identifier: AGPL-3.0-only

if has('nvim') || exists('g:loaded_agent_harbor_vim9')
  finish
endif
let g:loaded_agent_harbor_vim9 = 1

command! AgentHarbor call agent_harbor#open()
command! AgentHarborNew call agent_harbor#new_task()
command! -nargs=1 AgentHarborGoto call agent_harbor#select_task(<q-args>)
command! -nargs=? AgentHarborShareTask call agent_harbor#share_task(<q-args>)
command! -nargs=? -bang AgentHarborReply call agent_harbor#reply(<q-args>)
command! -nargs=? AgentHarborVoice call agent_harbor#voice(<q-args>)
command! AgentHarborDocs call agent_harbor#open_docs()
command! AgentHarborDaemon echo agent_harbor#setup({})

augroup AgentHarborBranchFS
  autocmd!
  autocmd BufReadCmd,FileReadCmd agent-harbor://* call agent_harbor#branchfs_read(expand('<amatch>'))
  autocmd BufWriteCmd,FileWriteCmd agent-harbor://* call agent_harbor#branchfs_write(expand('<amatch>'))
augroup END
