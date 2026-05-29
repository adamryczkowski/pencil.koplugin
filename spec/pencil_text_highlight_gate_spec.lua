--[[--
Unit tests for `lib/settings_defaults.experimentalTextHighlight`.

Covers M4 G1-FLIP-DEFAULT: the `experimental_text_highlight` default
must flip from `false` to `true` for empty/absent settings, while the
menu kill-switch (explicit user `false`) must continue to return
`false` so users can opt out of Path A.

Pure-Lua test against the extracted lib/ module — no main.lua require,
no G_reader_settings require, no UIManager. Settings shapes mirror the
production shape produced by
`G_reader_settings:readSetting('pencil_annotation_settings')` at
main.lua:1107.

Run with: busted spec/pencil_text_highlight_gate_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local SettingsDefaults = require("lib/settings_defaults")
local f = SettingsDefaults.experimentalTextHighlight

describe("SettingsDefaults.experimentalTextHighlight — M4 G1-FLIP-DEFAULT", function()

    describe("new build default (absent key)", function()

        it("returns true for empty settings table (fresh install / never-toggled)", function()
            -- VERBATIM the M4 spec ① acceptance criterion:
            --   Given: default plugin config post-flip; no manual toggle;
            --          no user settings override
            --   When:  plugin initializes (lib/ function with settings={})
            --   Then:  experimental_text_highlight == true
            assert.is_true(f({}))
        end)

        it("returns true when the key is explicitly nil (= absent)", function()
            assert.is_true(f({ experimental_text_highlight = nil }))
        end)

        it("returns true for a settings table populated with unrelated keys", function()
            -- Mimics a partial settings file: other experimental flags set
            -- but text-highlight key absent because the user never visited
            -- that menu item before the M4 flip shipped.
            assert.is_true(f({
                experimental_color_picker = true,
                experimental_pen_width = false,
                swap_eraser_and_highlighter = false,
                pen_color_name = "Black",
            }))
        end)

    end)

    describe("kill-switch preservation (M4 spec ① — explicit false)", function()

        it("returns false when user has explicitly set experimental_text_highlight = false", function()
            -- VERBATIM the M4 spec ① also-test criterion:
            --   settings = {experimental_text_highlight = false} -> returns false
            assert.is_false(f({ experimental_text_highlight = false }))
        end)

        it("returns false even when other experimental flags are true (independence)", function()
            assert.is_false(f({
                experimental_text_highlight = false,
                experimental_color_picker = true,
                experimental_pen_width = true,
            }))
        end)

    end)

    describe("idempotent for explicit true (M4 spec ① — already-on)", function()

        it("returns true when user has explicitly set experimental_text_highlight = true", function()
            -- VERBATIM the M4 spec ① also-test criterion:
            --   settings = {experimental_text_highlight = true} -> returns true
            assert.is_true(f({ experimental_text_highlight = true }))
        end)

    end)

    describe("input robustness", function()

        it("returns true for nil settings (uninitialised G_reader_settings call)", function()
            -- Per main.lua:1107: `settings = G_reader_settings:readSetting(key) or {}`
            -- already protects against nil, but the lib helper must
            -- itself tolerate nil for unit testing and for any future
            -- caller that omits the `or {}`.
            assert.is_true(f(nil))
        end)

        it("returns true for non-table settings (corrupt SDR file)", function()
            assert.is_true(f("oops"))
            assert.is_true(f(42))
            assert.is_true(f(false))
        end)

        it("returns true when the value is a non-boolean truthy (corrupt settings)", function()
            -- A settings file tampered to a non-boolean (e.g. 1, "yes",
            -- a table) is treated as new-default-on rather than
            -- preserving the corrupt value. The only way to get false
            -- is the explicit boolean `false`.
            assert.is_true(f({ experimental_text_highlight = 1 }))
            assert.is_true(f({ experimental_text_highlight = "yes" }))
            assert.is_true(f({ experimental_text_highlight = {} }))
        end)

        it("returns false when the value is a non-boolean falsy that is also `false`", function()
            -- Sanity: the only falsy value that triggers the kill-switch
            -- is the explicit boolean false. `nil` does NOT (nil collapses
            -- to the new default; see absent-key tests).
            assert.is_false(f({ experimental_text_highlight = false }))
        end)

        it("does not throw on any of these inputs", function()
            assert.has_no.errors(function()
                f(nil)
                f({})
                f({ experimental_text_highlight = false })
                f({ experimental_text_highlight = true })
                f({ experimental_text_highlight = 1 })
                f("oops")
            end)
        end)

    end)

    describe("integration contract — load -> toggle -> save -> reload cycle", function()

        it("a fresh user toggling OFF via the menu, then reloading, stays OFF", function()
            -- Mirror the menu kill-switch flow at main.lua:1424-1426:
            --   user clicks toggle -> self.experimental_text_highlight = false
            --   plugin saves       -> settings.experimental_text_highlight = false
            --   plugin reloads     -> f(settings) reads back as false
            -- Without this contract the kill-switch would silently fail
            -- after the flip (user would see the feature come back on).
            local saved = { experimental_text_highlight = false }
            assert.is_false(f(saved))
        end)

        it("a fresh user toggling ON via the menu, then reloading, stays ON", function()
            -- Pre-M4 user who had explicitly enabled the experiment.
            -- Their explicit `true` is preserved (idempotent with the flip).
            local saved = { experimental_text_highlight = true }
            assert.is_true(f(saved))
        end)

        it("an upgrading user who never toggled gets the new default on first reload", function()
            -- They had a settings file from before the flip with
            -- text-highlight unset. Post-flip they reload and the
            -- feature comes on.
            local saved = {
                pen_color_name = "Black",
                experimental_color_picker = false,
                -- experimental_text_highlight absent
            }
            assert.is_true(f(saved))
        end)

    end)

end)
