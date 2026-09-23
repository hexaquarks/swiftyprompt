# swiftyprompt.nvim

Learn how to build a tiny Neovim tool that lets you ask an AI about a visual
selection without leaving the flow of editing.

## Status

Starting at zero. It deliberately does only one thing: prove that Neovim can
load a plugin and run its Lua code.

## Local development

Add this directory to Neovim's runtime path while developing:

```lua
vim.opt.rtp:append("/Users/mihailanghelici/dev/projects/swiftyprompt")
require("swiftyprompt")
```

Then run `:SwiftPromptHello`. You should see `SwiftPrompt is loaded`.

## Planned shape

1. Make a visual-mode keymap that prints “pressed”.
2. Read and print the selected text.
3. Replace `print` with a tiny one-line floating prompt.
4. Send its question plus the selected text to a backend.
5. Show the response.

Do one milestone at a time. No agent loop, model provider, or async code until
you understand why the preceding step works.
