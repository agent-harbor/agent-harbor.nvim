# agent-harbor.nvim

Agent Harbor integration for Neovim and Vim 9.

[Agent Harbor](https://agent-harbor.com) runs coding agents in isolated
workspaces and records every session. This plugin is the editor half of that:
it talks to the local `ah` daemon over its REST and SSE endpoints, so tasks
can be started, watched, replied to and reviewed without leaving the editor.

**Version 0.6.8**, published from [`ide-plugins/nvim`][source] at
[`9857c39e103e`][commit] in the Agent Harbor monorepo. This repository is
generated — see [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull
request.

## Requirements

- **Neovim 0.10+** (the plugin calls `vim.system()`), or **Vim 9.0+** for the
  reduced Vim 9 implementation.
- **The `ah` CLI**, version **0.6.8 or newer**, on `PATH`.
  [Install instructions](https://docs.agent-harbor.com/installation).

No Lua dependencies: the plugin uses only Neovim's own standard library.

## Install

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "agent-harbor/agent-harbor.nvim",
  version = "*", -- latest release tag; omit to track the default branch
  cmd = { "AgentHarbor", "AgentHarborNew", "AgentHarborChanges", "AgentHarborReply" },
  ft = "agent-harbor-task-prompt",
  opts = {},
}
```

The `ftdetect/` rule that recognises an `ah` prompt file only runs once the
plugin is loaded. If you want `ah task` to open its scratch file with
completion already live in a fresh Neovim, add the file patterns as a load
event too:

```lua
  event = { "BufReadPre *.ahtask", "BufReadPre *.ahplan" },
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use({
  "agent-harbor/agent-harbor.nvim",
  config = function()
    require("agent-harbor").setup({})
  end,
})
```
</details>

<details>
<summary><b>vim-plug</b></summary>

```vim
Plug 'agent-harbor/agent-harbor.nvim'
```

Then, for Neovim, `lua require('agent-harbor').setup({})` after `plug#end()`.
Vim 9 needs no setup call.
</details>

<details>
<summary><b>rocks.nvim</b></summary>

```vim
:Rocks install agent-harbor.nvim
```

Installs from the rockspec at the root of this repository.
</details>

<details>
<summary><b>Nix</b></summary>

The monorepo flake exposes the plugin as a package, built from the same
sources this mirror is generated from:

```
nix build github:agent-harbor/agent-harbor#agent-harbor-nvim
```

In a home-manager configuration:

```nix
programs.neovim.plugins = [
  inputs.agent-harbor.packages.${pkgs.system}.agent-harbor-nvim
];
```
</details>

## Setup

Neovim defines no commands until `setup()` runs:

```lua
require("agent-harbor").setup({
  daemon = { auto_start = true },
  panel = { mode = "float" },
  task_entry = { agent_type = "claude", model = "sonnet" },
})
```

Everything is optional; the table is deep-merged over the defaults in
`lua/agent-harbor/config.lua`. See `:help agent-harbor-configuration` for the
groups and their keys.

## Commands

| Command | |
|---|---|
| `:AgentHarbor` | Open the task panel |
| `:AgentHarborNew` | Open the task entry form (the editor's `ah task`) |
| `:AgentHarborChanges` | Source-control view for the current task |
| `:AgentHarborReply[!] [text]` | Reply to the running agent; `!` opens the overlay |
| `:AgentHarborVoiceReply` | Record a reply and send its transcript |
| `:AgentHarborVoice {mode}` | Set or drive voice capture |
| `:AgentHarborGoto {uri}` | Open an `agent-harbor://` URI |
| `:AgentHarborShareTask [id]` | Copy a shareable URI for a task |
| `:AgentHarborOpenNew [ws]` | New multiplexer window on a workspace |
| `:AgentHarborDaemon [status]` | Echo the daemon connection state |
| `:AgentHarborDocs` | Open the online documentation |

## Task prompts in your editor

`ah task` and `ah plan` can hand the prompt to `$EDITOR`. They name the
scratch file `ah-task-prompt-*.ahtask` / `ah-plan-prompt-*.ahplan`, this
plugin recognises those names, and inside such a buffer `/`, `~` and `@`
complete against `ah autocomplete --json` — the same command the `ah` dashboard editor
uses, so the two cannot drift apart on what a trigger offers.

Write and quit to submit; leave the buffer empty to abort.

## Diagnosing

```vim
:checkhealth agent-harbor
```

Reports the Neovim version, this plugin's version, whether `ah` is present
and new enough, whether `ah autocomplete` exists, and the daemon state.
Include its output in any bug report.

## Documentation

- `:help agent-harbor` — the full reference, shipped with the plugin
- <https://docs.agent-harbor.com/editor-support/vim> — online

## Versioning

Releases track the `ah` binary: plugin 0.6.8 is published from the same
monorepo tag as `ah` 0.6.8. The two are installed separately, though, so
the plugin declares the oldest `ah` it works with
(`require("agent-harbor.version").ah_min`, currently **0.6.8**) and
`:checkhealth` reports a mismatch. Keeping the two within a release of each
other is the supported configuration.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).

[source]: https://github.com/agent-harbor/agent-harbor/tree/main/ide-plugins/nvim
[commit]: https://github.com/agent-harbor/agent-harbor/commit/9857c39e103e09f95f7af92be4bef4a5a917d369
