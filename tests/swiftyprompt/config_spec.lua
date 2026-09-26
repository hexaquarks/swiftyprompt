local config = require("swiftyprompt.config")

describe("SwiftPrompt configuration", function()
    after_each(function()
        config.setup({})
    end)

    it("keeps defaults when only one option is changed", function()
        config.setup({
            connector = "test_connector",
        })

        assert.equals("test_connector", config.values.connector)
        assert.equals("<leader>aa", config.values.selection_keymap)
        assert.equals("codex", config.values.connectors.codex.command)
        assert.equals("gpt-6-luna", config.values.connectors.codex.model)
        assert.equals("none", config.values.connectors.codex.reasoning_effort)
    end)

    it("merges connector options without losing the other defaults", function()
        config.setup({
            connectors = {
                codex = {
                    command = "my-codex",
                    model = "my-codex-model",
                },
            },
        })

        assert.equals("my-codex", config.values.connectors.codex.command)
        assert.equals("my-codex-model", config.values.connectors.codex.model)
        assert.equals("none", config.values.connectors.codex.reasoning_effort)
        assert.equals("read-only", config.values.connectors.codex.sandbox)
    end)

    it("starts fresh for every setup call", function()
        config.setup({ connector = "first" })
        config.setup({})

        assert.equals("codex", config.values.connector)
    end)
end)
