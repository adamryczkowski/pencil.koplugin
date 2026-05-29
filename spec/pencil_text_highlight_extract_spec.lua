--[[--
Unit tests for `lib/dispatch_predicate.extractWordSet`.

Validates the contract that CRengine's selection-dict return value
(from `document:getTextFromPositions` at main.lua:945 and
`document:getWordFromPosition` at main.lua:907) reduces to a
non-empty word list when the stroke covered real text. The helper is
called inside the Path-A integration after the pcall-wrapped CRengine
call returns; its return value is the "did we get something to
highlight?" signal that gates `rh.selected_text` assignment.

Pure-Lua test — no main.lua require, no CRengine require, no
UIManager. The CRengine return shape is faked by passing tables that
mirror the production dict (text + pos0 + pos1 + sboxes/pboxes).

Run with: busted spec/pencil_text_highlight_extract_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local DispatchPredicate = require("lib/dispatch_predicate")

describe("DispatchPredicate.extractWordSet — positive cases", function()

    it("returns a non-empty word list for a multi-word selection", function()
        -- Mock shape mirrors what document:getTextFromPositions returns
        -- on EPUB (xpointer pos0/pos1, no sbox array required for the
        -- pure word-extraction step).
        local selection = {
            text = "quick brown fox",
            pos0 = "/body/p[1]/text()[1].0",
            pos1 = "/body/p[1]/text()[1].15",
        }
        local words = DispatchPredicate.extractWordSet(selection)
        assert.is_table(words)
        assert.equals(3, #words)
        assert.equals("quick", words[1])
        assert.equals("brown", words[2])
        assert.equals("fox", words[3])
    end)

    it("returns a single-element list for a single-word selection", function()
        local words = DispatchPredicate.extractWordSet{ text = "hello" }
        assert.is_table(words)
        assert.equals(1, #words)
        assert.equals("hello", words[1])
    end)

    it("collapses runs of whitespace (no empty entries)", function()
        local words = DispatchPredicate.extractWordSet{ text = "  quick   brown  fox  " }
        assert.equals(3, #words)
        for _, w in ipairs(words) do
            assert.is_true(#w > 0, "every word must be non-empty")
        end
    end)

    it("treats tabs and newlines as whitespace separators", function()
        local words = DispatchPredicate.extractWordSet{ text = "alpha\tbeta\ngamma" }
        assert.equals(3, #words)
        assert.equals("alpha", words[1])
        assert.equals("beta",  words[2])
        assert.equals("gamma", words[3])
    end)

    it("preserves punctuation attached to a word (whitespace-only split)", function()
        -- The contract is "whitespace-separated words", not "tokenize at
        -- punctuation". Trailing punctuation rides with the word.
        local words = DispatchPredicate.extractWordSet{ text = "fox, jumps." }
        assert.equals(2, #words)
        assert.equals("fox,",   words[1])
        assert.equals("jumps.", words[2])
    end)

    it("preserves unicode multibyte characters intact", function()
        -- Lua's %S+ is byte-class but treats all >= 0x80 bytes as non-space,
        -- so multibyte UTF-8 words survive without re-encoding.
        local words = DispatchPredicate.extractWordSet{ text = "naïve résumé café" }
        assert.equals(3, #words)
        assert.equals("naïve",   words[1])
        assert.equals("résumé",  words[2])
        assert.equals("café",    words[3])
    end)

    it("does not throw on well-formed input", function()
        assert.has_no.errors(function()
            DispatchPredicate.extractWordSet{ text = "x" }
        end)
    end)

end)
