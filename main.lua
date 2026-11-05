local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local GestureDetector = require("device/gesturedetector")
local util = require("util")
local _ = require("gettext")

local WhoIsX = WidgetContainer:extend{
    name = "whoisx",
    fullname = _("Who is X"),
    description = _("Shows the first and last appearances of a selected character name."),
    is_doc_only = true,
}

-- Search and preview settings.
local MAX_HITS = 5000
local INITIAL_HITS = 50    -- First probe of the progressive search.
local GROWTH_MARGIN = 1.3  -- Safety margin when estimating hits needed to reach the selection.
local PREVIEW_CONTEXT_WORDS = 150
local LIST_CONTEXT_WORDS = 42
local SEARCH_FLAGS = 0x10FF -- CRE default search flags plus MATCH_WHOLE_WORDS.
local HOLD_THRESHOLD_DEFAULT = 3.0

-- Only these fields are kept from each search result.
local TEXT_FIELDS = {
    "prev_text", "matched_word_prefix", "matched_text",
    "matched_word_suffix", "next_text",
}

local function getHoldThreshold()
    return G_reader_settings:readSetting("highlight_long_hold_threshold_s")
        or GestureDetector.LONG_HOLD_INTERVAL_S
        or HOLD_THRESHOLD_DEFAULT
end

local function getInitialHoldDelay()
    local hold_interval_ms = G_reader_settings:readSetting("ges_hold_interval_ms")
        or GestureDetector.HOLD_INTERVAL_MS
        or 500
    return hold_interval_ms / 1000
end

-- Keep result-list excerpts compact while retaining the full context for previews.
local function trimContextWords(text, max_words, keep_last)
    if not text or text == "" then
        return text
    end

    local words = {}
    for word in text:gmatch("%S+") do
        words[#words + 1] = word
    end

    if #words <= max_words then
        return text
    end

    local first = keep_last and (#words - max_words + 1) or 1
    local last = keep_last and #words or max_words
    local trimmed = {}
    for i = first, last do
        trimmed[#trimmed + 1] = words[i]
    end
    return table.concat(trimmed, " ")
end

-- Copy only the text fields we display, dropping everything else.
local function compactResult(result)
    local out = {}
    for _idx, field in ipairs(TEXT_FIELDS) do
        out[field] = result[field]
    end
    return out
end

-- Find the last search result that ends at or before the selected word.
-- findAllText() returns matches in document order, so binary search avoids
-- thousands of XPointer comparisons on large books.
local function findLastMatchBefore(document, results, selected_position)
    if not selected_position or type(document.compareXPointers) ~= "function" then
        return 0
    end

    local low, high = 1, #results
    local last_before = 0

    while low <= high do
        local middle = math.floor((low + high) / 2)
        local match_end = results[middle] and results[middle]["end"]
        if type(match_end) ~= "string" then
            return 0
        end

        local ok, comparison = pcall(
            document.compareXPointers,
            document,
            match_end,
            selected_position
        )
        if not ok or comparison == nil then
            return 0
        end

        -- compareXPointers(a, b) returns 1 when b follows a, 0 when equal.
        if comparison >= 0 then
            last_before = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end

    return last_before
end

-- Runs inside the search subprocess: reduces the full result set to the few
-- entries that will actually be displayed, so only those cross back to the
-- main process and nothing large is kept in memory afterwards.
local function pickEntries(document, results, selected_position)
    local total = #results
    local entries = {}

    -- Short documents: show every occurrence.
    if total < 6 then
        for i = 1, total do
            entries[#entries + 1] = { group = "all", n = i, result = compactResult(results[i]) }
        end
        return entries
    end

    -- Longer books: first three matches plus up to three before the selection.
    for i = 1, 3 do
        entries[#entries + 1] = { group = "first", n = i, result = compactResult(results[i]) }
    end

    local last_before = findLastMatchBefore(document, results, selected_position)
    -- Start at 4 so "Last" never repeats rows already shown under "First".
    local first_last = math.max(4, last_before - 2)
    for i = first_last, last_before do
        entries[#entries + 1] = {
            group = "last",
            n = i - first_last + 1,
            result = compactResult(results[i]),
        }
    end

    return entries
end

-- Runs inside the search subprocess. findAllText() always scans from the start
-- of the book and stops once max_hits is reached, so ask for few hits first and
-- grow the cap only until the last hit lies after the selected word. Everything
-- displayed (first 3 + last 3 before the selection) is then already in the results.
-- Returns the results and whether the search stopped early (total not exact).
local function searchUpToSelection(document, name, selected_position)
    local can_compare = selected_position and type(document.compareXPointers) == "function"

    local selected_page
    if can_compare then
        local ok, page = pcall(document.getPageFromXPointer, document, selected_position)
        selected_page = ok and page or nil
    end

    local hits = INITIAL_HITS
    while true do
        local results = document:findAllText(
            name,
            true, -- Case-insensitive search.
            PREVIEW_CONTEXT_WORDS,
            hits,
            false, -- Literal text, not a regular expression.
            SEARCH_FLAGS
        ) or {}
        local count = #results

        -- Fewer hits than requested: the whole book was scanned, the total is exact.
        if count < hits then
            return results, false
        end
        -- Same hard cap as before; reaching it is reported as "limit reached".
        if hits >= MAX_HITS then
            return results, false
        end
        -- Without a way to compare positions no "last" section is built, so stop.
        if not can_compare then
            return results, true
        end

        -- compareXPointers(a, b) returns -1 when a is after b: the last hit is
        -- already past the selection, so all hits before it are in the results.
        local last_end = results[count]["end"]
        local ok, comparison = pcall(document.compareXPointers, document, last_end, selected_position)
        if not ok or comparison == nil or comparison < 0 then
            return results, true
        end

        -- Estimate how many hits are needed from how far into the book we got.
        local next_hits = math.ceil(count * 1.5)
        local ok_page, last_page = pcall(document.getPageFromXPointer, document, last_end)
        if selected_page and ok_page and last_page and last_page > 0 then
            next_hits = math.max(next_hits, math.ceil(count * (selected_page / last_page) * GROWTH_MARGIN))
        end
        hits = math.min(MAX_HITS, next_hits)
    end
end

function WhoIsX:init()
    -- Register with ReaderMenu so addToMainMenu() is called when reader tabs are built.
    self.ui.menu:registerToMainMenu(self)

    if self:isEnabled() then
        self:installHighlightHook()
    end
end

function WhoIsX:isEnabled()
    -- Enabled by default; a single global setting controls all books.
    return G_reader_settings:nilOrTrue("whoisx_enabled")
end

function WhoIsX:setEnabled(enabled)
    G_reader_settings:saveSetting("whoisx_enabled", enabled)

    if enabled then
        self:installHighlightHook()
    else
        self:removeHighlightHook()
    end
end

function WhoIsX:addToMainMenu(menu_items)
    menu_items.whoisx_enabled = {
        text = _("Who is X"),
        -- Add this as a sibling of Document settings in the Typeset tab.
        sorting_hint = "typeset",
        keep_menu_open = true,
        checked_func = function()
            return self:isEnabled()
        end,
        callback = function()
            self:setEnabled(not self:isEnabled())
            -- TouchMenu refreshes checked items after their callback.
        end,
    }
end

function WhoIsX:installHighlightHook()
    local highlight = self.ui and self.ui.highlight
    if not highlight or highlight._whoisx_owner then
        return
    end

    local original_on_hold = highlight.onHold
    local original_on_hold_release = highlight.onHoldRelease
    local original_on_hold_pan = highlight.onHoldPan
    local plugin = self

    if type(original_on_hold_release) ~= "function" then
        return
    end

    -- Remember what the instance itself owned (nil when the method is inherited
    -- from the class), so removal restores the exact original state.
    self._whoisx_raw = {
        onHold = rawget(highlight, "onHold"),
        onHoldRelease = rawget(highlight, "onHoldRelease"),
        onHoldPan = rawget(highlight, "onHoldPan"),
    }

    -- A single timer function is reused for every hold, so it can be unscheduled
    -- precisely and no closure is created per gesture.
    local timer_fn
    timer_fn = function()
        if plugin._whoisx_closed
            or plugin.ui ~= highlight.ui
            or not highlight.ui.document
            or highlight.select_mode
            or not highlight.is_word_selection
            or not highlight.selected_text
            or type(highlight.selected_text.text) ~= "string" then
            return
        end

        local name = util.cleanupSelectedText(highlight.selected_text.text)
        if not name or name == "" then
            return
        end

        -- Consume the gesture while the finger is still down.
        -- Preserve the selected word's document position before clear() resets it.
        local selected_position = highlight.selected_text.pos0
            or highlight.selected_text_start_xpointer

        plugin._whoisx_hold_triggered = true
        if type(highlight._resetHoldTimer) == "function" then
            highlight:_resetHoldTimer(true)
        end
        highlight:clear()
        plugin:searchCharacter(name, selected_position)
    end
    self._whoisx_timer_fn = timer_fn

    -- Start a cancellable timer when KOReader recognizes the initial hold.
    if type(original_on_hold) == "function" then
        highlight.onHold = function(hl, ...)
            local result = original_on_hold(hl, ...)
            plugin._whoisx_hold_triggered = false

            local delay = math.max(0.05, getHoldThreshold() - getInitialHoldDelay())
            UIManager:unschedule(timer_fn)
            UIManager:scheduleIn(delay, timer_fn)

            return result
        end
    end

    -- A release before the threshold cancels the pending action.
    highlight.onHoldRelease = function(hl, ...)
        UIManager:unschedule(timer_fn)
        if plugin._whoisx_hold_triggered then
            plugin._whoisx_hold_triggered = false
            return true
        end
        return original_on_hold_release(hl, ...)
    end

    -- Moving the finger turns the gesture into text selection; not a character lookup.
    if type(original_on_hold_pan) == "function" then
        highlight.onHoldPan = function(hl, ...)
            UIManager:unschedule(timer_fn)
            plugin._whoisx_hold_triggered = false
            return original_on_hold_pan(hl, ...)
        end
    end

    highlight._whoisx_owner = self
    self._whoisx_highlight = highlight
end

function WhoIsX:removeHighlightHook()
    -- Cancel any pending long-hold timer before restoring KOReader handlers.
    if self._whoisx_timer_fn then
        UIManager:unschedule(self._whoisx_timer_fn)
    end
    self._whoisx_hold_triggered = false

    local highlight = self._whoisx_highlight
    if highlight and highlight._whoisx_owner == self then
        local raw = self._whoisx_raw or {}
        -- Assigning nil lets the instance fall back to the class method again.
        highlight.onHold = raw.onHold
        highlight.onHoldRelease = raw.onHoldRelease
        highlight.onHoldPan = raw.onHoldPan
        highlight._whoisx_owner = nil
    end

    self._whoisx_highlight = nil
    self._whoisx_raw = nil
    self._whoisx_timer_fn = nil
end

function WhoIsX:searchCharacter(name, selected_position)
    if not self:isEnabled() then
        return
    end
    local ui = self.ui
    local document = ui and ui.document

    -- This version targets reflowable CRE documents such as EPUB and KEPUB.
    if not document or not ui.rolling or type(document.findAllText) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("Who is X currently supports reflowable text books only."),
        })
        return
    end

    local Trapper = require("ui/trapper")
    local searching_message = InfoMessage:new{
        text = _("Searching for character appearances…"),
    }
    UIManager:show(searching_message)
    UIManager:forceRePaint()

    -- Run the document-wide search outside the UI thread.
    Trapper:wrap(function()
        local completed, payload = Trapper:dismissableRunInSubprocess(function()
            local ok, data_or_error = pcall(function()
    local results, partial = searchUpToSelection(document, name, selected_position)
    -- Only the few displayed entries are sent back to the main process.
    return {
        total = #results,
        partial = partial,
        entries = pickEntries(document, results, selected_position),
    }
end)

            if ok then
                return data_or_error
            end
            return { error = tostring(data_or_error) }
        end, searching_message)

        if not completed then
            return
        end

        UIManager:close(searching_message)

        -- The book may have been closed while the search was running.
        if self._whoisx_closed or not self.ui or not self.ui.document then
            return
        end

        if not payload or payload.error then
            UIManager:show(InfoMessage:new{
                text = _("Who is X could not search this document.")
                    .. (payload and payload.error and ("\n" .. payload.error) or ""),
            })
            return
        end

        if (payload.total or 0) == 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("No occurrences found for “%s”."), name),
            })
            return
        end

        self.ui.document:clearSelection()
        self:showResults(name, payload)
    end)
end

function WhoIsX:buildContextText(name, result)
    local parts = { TextBoxWidget.PTF_HEADER }

    if result.prev_text and result.prev_text ~= "" then
        table.insert(parts, result.prev_text)
        if not result.prev_text:find("%s$") then
            table.insert(parts, " ")
        end
    end

    table.insert(parts, TextBoxWidget.PTF_BOLD_START)
    table.insert(parts, result.matched_word_prefix or "")
    table.insert(parts, result.matched_text or name)
    table.insert(parts, result.matched_word_suffix or "")
    table.insert(parts, TextBoxWidget.PTF_BOLD_END)

    if result.next_text and result.next_text ~= "" then
        if not result.next_text:find("^[%s%p]") then
            table.insert(parts, " ")
        end
        table.insert(parts, result.next_text)
    end

    return table.concat(parts)
end

function WhoIsX:showOccurrencePreview(name, result, label, data)
    -- Rebuild the results list when the preview closes, without moving the reader.
    -- `data` only holds the few displayed entries and is freed once both windows close.
    local preview = TextViewer:new{
        title = string.format(_("%s — %s"), name, label),
        text = self:buildContextText(name, result),
        text_type = "lookup",
        height = math.floor(Screen:getHeight() * 0.82),
        close_callback = function()
            if not self._whoisx_closed and self.ui and self.ui.document then
                self:showResults(name, data)
            end
        end,
    }
    UIManager:show(preview)
end

function WhoIsX:showResults(name, data)
    local total = data.total
    local menu_items = {}
    local current_group

    for _idx, entry in ipairs(data.entries) do
        -- Insert a section header whenever the group changes.
        if entry.group ~= current_group then
            current_group = entry.group
            if current_group == "first" then
                table.insert(menu_items, {
                    text = _("Earliest apparitions"),
                    bold = true,
                    dim = true,
                    is_section_header = true,
                })
            elseif current_group == "last" then
                table.insert(menu_items, {
                    text = _("Last apparitions"),
                    bold = true,
                    dim = true,
                    is_section_header = true,
                })
            end
        end

        local label
        if entry.group == "all" then
            label = string.format(_("Occurrence %d of %d"), entry.n, total)
        elseif entry.group == "first" then
            label = string.format(_("First %d of 3"), entry.n)
        else
            label = string.format(_("Last %d of 3"), entry.n)
        end

        -- Keep excerpts compact in the list; the tapped preview retains the
        -- full context returned by the single document-wide search.
        local result = entry.result
        local list_result = {
            prev_text = trimContextWords(result.prev_text, LIST_CONTEXT_WORDS, true),
            matched_word_prefix = result.matched_word_prefix,
            matched_text = result.matched_text,
            matched_word_suffix = result.matched_word_suffix,
            next_text = trimContextWords(result.next_text, LIST_CONTEXT_WORDS, false),
        }
        table.insert(menu_items, {
            text = self:buildContextText(name, list_result),
            result = result,
            label = label,
        })
    end

    local total_text = data.partial and (total .. "+") or tostring(total)
    local subtitle = string.format(_("%s — %s occurrences · Tap a passage to read more"), name, total_text)
    if total >= MAX_HITS then
        subtitle = subtitle .. _(" · Search limit reached; last matches may be incomplete")
    end

    -- No reference to the menu is stored on the plugin: once the widget is
    -- closed, the menu and everything it captured become collectable.
    local menu = Menu:new{
        title = _("Who is X"),
        subtitle = subtitle,
        item_table = menu_items,
        -- Keep the result set on one page to avoid splitting a section.
        items_per_page = math.max(6, #menu_items),
        items_max_lines = 8,
        multilines_forced = true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuChoice = function(this_menu, item)
            -- Section labels are non-actionable rows.
            if not item or item.is_section_header or not item.result then
                return
            end

            local result = item.result
            local label = item.label
            -- Close the results menu before creating another interactive window.
            UIManager:close(this_menu)
            UIManager:nextTick(function()
                if not self._whoisx_closed and self.ui and self.ui.document then
                    self:showOccurrencePreview(name, result, label, data)
                end
            end)
        end,
    }

    UIManager:show(menu)
end

function WhoIsX:onCloseWidget()
    -- Restore KOReader's original handlers and drop pending work when the reader closes.
    self._whoisx_closed = true
    self:removeHighlightHook()
end

return WhoIsX