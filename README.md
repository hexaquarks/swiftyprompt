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

<p align="center">
  <a href="https://github.com/hexaquarks/swiftyprompt/actions/workflows/tests.yml"><img alt="Tests" src="https://img.shields.io/github/actions/workflow/status/hexaquarks/swiftyprompt/tests.yml?branch=main&amp;label=tests" /></a>
  <a href="https://app.codecov.io/gh/hexaquarks/swiftyprompt"><img alt="Coverage" src="https://img.shields.io/codecov/c/github/hexaquarks/swiftyprompt/main" /></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/hexaquarks/swiftyprompt" /></a>
  <a href=".github/workflows/tests.yml"><img alt="Tested Neovim version" src="https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fhexaquarks%2Fswiftyprompt%2Fmain%2F.github%2Fworkflows%2Ftests.yml&amp;query=%24.jobs.test.env.NEOVIM_VERSION&amp;label=Neovim&amp;logo=neovim&amp;color=57A143" /></a>
</p>

SwiftPrompt is a small inline UI for asking Codex or Claude Code about a Visual
selection, the current file, or the current LSP symbol without leaving Neovim.

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

## Supported adapters

- Codex
- Claude

## Usage

- In Visual mode, press `<leader>aa` to ask about the selection.
- Press `<leader>af` to ask about the current file.
- Press `<leader>as` to ask about the current LSP symbol.

The prompt window opens beside the selected code. Press Enter to send. In a
response window, press `f` to ask a follow-up, `gY` to copy the complete response,
or `q`/Escape to close it. Closing a pending response cancels its request.

## Configuration

Select an adapter with `setup()` and optionally override its model:

```lua
require("swiftyprompt").setup({
  connector = "claude",
  connectors = {
    claude = {
      model = "haiku",
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
