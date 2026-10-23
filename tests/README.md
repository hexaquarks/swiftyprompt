# Testing SwiftPrompt

The tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
Busted-style test harness. A test file ends in `_spec.lua`; `describe` groups a
feature and `it` states one behaviour we want to preserve.

Run the suite from the project root. Replace the path with wherever your plugin
manager installed `plenary.nvim`:

```sh
PLENARY_DIR=/Users/you/.local/share/nvim/lazy/plenary.nvim \
nvim --headless --noplugin -u NONE \
  --cmd "set rtp+=$PLENARY_DIR" \
  -c "runtime plugin/plenary.vim" \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```

`tests/minimal_init.lua` adds only SwiftPrompt to Neovim's runtime path. That
means tests cannot accidentally pass because of settings or plugins from your
normal Neovim configuration.

`swiftyprompt/reopen_spec.lua` covers reopening without another provider request,
repeated reopening, focusing an existing response, preserving follow-up context,
reopening after the source buffer is deleted, and retaining the completed answer
after cancellation or failure. It also checks the message shown when no answer
is available.
