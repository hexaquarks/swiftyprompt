<p align="center">
  <img
    width="250"
    alt="Swiftyprompt"
    src="https://github.com/user-attachments/assets/f3d45527-1e5f-4c9e-84c6-550f081d99d9"
  />
</p>
<h1 align="center">
  Swiftyprompt
</h1>

SwiftPrompt is a small inline UI for asking Codex about a Visual selection, the
current file, or the current LSP symbol without leaving Neovim.

## Install

With lazy.nvim:

```lua
{
  "hexaquarks/swiftyprompt",
  config = function()
    require("swiftyprompt").setup()
  end,
}
```

SwiftPrompt uses the `codex` command and Codex login by default. To authenticate
with an API key instead, set the key in your shell environment and configure the
connector:

```lua
require("swiftyprompt").setup({
  connectors = {
    codex = {
      auth = "api_key",
      api_key_env = "OPENAI_API_KEY",
    },
  },
})
```

## Usage

- In Visual mode, press `<leader>aa` to ask about the selection.
- Press `<leader>af` to ask about the current file.
- Press `<leader>as` to ask about the current LSP symbol.

The prompt window opens beside the selected code. Press Enter to send. In a
response window, press `f` to ask a follow-up or `q`/Escape to close it.

## Configuration

Configure SwiftPrompt in your own Neovim configuration. Do not edit or ignore
the plugin's `lua/swiftyprompt/config.lua`; it is version-controlled source that
provides shared defaults.

```lua
require("swiftyprompt").setup({
  selection_keymap = "<leader>aa",
  current_file_keymap = "<leader>af",
  current_symbol_keymap = "<leader>as",
  connectors = {
    codex = {
      command = "codex",
      model = "gpt-6-luna",
      reasoning_effort = "none",
      sandbox = "read-only",
      auth = "codex_login",
      api_key_env = "OPENAI_API_KEY",
    },
  },
})
```

## Local development

To test an unpushed checkout, point your plugin specification at its directory:

```lua
{
  dir = "/path/to/swiftyprompt",
  name = "swiftyprompt",
  config = function()
    require("swiftyprompt").setup()
  end,
}
```

Restart Neovim after changing plugin Lua files. Plugin-manager reloads can leave
Lua modules cached.

## Tests

The test suite uses plenary.nvim:

```sh
PLENARY_DIR=/path/to/plenary.nvim \
nvim --headless --noplugin -u NONE \
  --cmd "set rtp+=$PLENARY_DIR" \
  -c "runtime plugin/plenary.vim" \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```
