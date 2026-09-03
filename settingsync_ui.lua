--[[--
Diff viewer UI for SettingSync.

Presents per-key differences between local and cloud settings,
letting the user select which keys to pull (cloud → local) or push (local → cloud).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("settingsync_gettext")

local Categories = require("settingsync_categories")
local Diff = require("settingsync_diff")

local DiffViewer = InputContainer:extend{
    width = nil,
    height = nil,
    diff = nil,          -- array of diff entries from Diff.compare()
    source_label = nil,  -- e.g. "settings.reader.lua"
    category = nil,      -- optional Categories.* table for display labels/formatters
    on_apply = nil,      -- callback(selections) called when user confirms
    on_skip = nil,       -- callback() called when the user leaves this group unchanged
    on_cancel = nil,     -- callback() called when the user stops here
    selections = nil,    -- { [idx] = "pull"|"push"|nil }
    scrollable = nil,    -- ScrollableContainer reference for scroll-position preservation
}

function DiffViewer:init()
    self.width = self.width or Screen:getWidth() - Size.margin.default * 2
    self.height = self.height or Screen:getHeight() - Size.margin.default * 2
    self.selections = {}
    self.changes = Diff.changesOnly(self.diff or {})

    if #self.changes == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No differences found between local and cloud settings."),
            timeout = 3,
        })
        return
    end

    self:buildUI()

    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = function() return self.dimen end,
        },
    }
end

function DiffViewer:buildUI()
    local title_font = Font:getFace("smallinfofontbold")
    local text_font = Font:getFace("smallinfofont")
    local key_font = Font:getFace("smallinfofontbold")
    local status_font = Font:getFace("smallinfofont")
    local padding = Size.padding.default
    local inner_width = self.width - padding * 2

    local function sideBySideValues(local_val, remote_val)
        local separator_width = Size.line.thin
        local gap_width = Size.padding.default
        local values_width = inner_width - separator_width - gap_width * 2
        local local_width = math.floor(values_width / 2)
        local remote_width = values_width - local_width
        local value_rows = VerticalGroup:new{ align = "left" }

        local function columns(local_text, remote_text, face)
            local local_widget = TextBoxWidget:new{
                text = local_text,
                face = face,
                width = local_width,
            }
            local remote_widget = TextBoxWidget:new{
                text = remote_text,
                face = face,
                width = remote_width,
            }
            local row_height = math.max(local_widget:getSize().h, remote_widget:getSize().h)
            return HorizontalGroup:new{
                align = "top",
                local_widget,
                HorizontalSpan:new{ width = gap_width },
                LineWidget:new{
                    dimen = Geom:new{ w = separator_width, h = row_height },
                    background = Blitbuffer.COLOR_GRAY,
                },
                HorizontalSpan:new{ width = gap_width },
                remote_widget,
            }
        end

        table.insert(value_rows, columns(_("Local:"), _("Cloud:"), key_font))
        for _, value_row in ipairs(Diff.valueRows(local_val, remote_val)) do
            if value_row.path ~= "" then
                table.insert(value_rows, TextBoxWidget:new{
                    text = value_row.path,
                    face = key_font,
                    width = inner_width,
                })
            end
            table.insert(value_rows, columns(
                Categories.formatValue(nil, nil, value_row.local_val),
                Categories.formatValue(nil, nil, value_row.remote_val),
                text_font))
        end
        return value_rows
    end

    -- Title bar
    local title_text = self.source_label or _("Settings Diff")
    local title_widget = TextWidget:new{
        text = title_text,
        face = title_font,
        max_width = inner_width,
    }

    -- Summary line
    local n_added, n_removed, n_modified = 0, 0, 0
    for _, entry in ipairs(self.changes) do
        if entry.status == Diff.ADDED then n_added = n_added + 1
        elseif entry.status == Diff.REMOVED then n_removed = n_removed + 1
        elseif entry.status == Diff.MODIFIED then n_modified = n_modified + 1
        end
    end
    local summary = string.format(_("%d changed: %d ≠ modified, %d ↑ local only, %d ↓ cloud only"),
        #self.changes, n_modified, n_added, n_removed)
    local summary_widget = TextWidget:new{
        text = summary,
        face = status_font,
        max_width = inner_width,
    }

    -- Usage hint
    local hint_widget = TextBoxWidget:new{
        text = _("Tap a row to select: ⬇ Pull = take cloud value · ⬆ Push = send local value"),
        face = text_font,
        width = inner_width,
    }

    -- Build per-key rows
    local rows = VerticalGroup:new{ border_size = 0 }
    for idx, entry in ipairs(self.changes) do
        local status_icon
        if entry.status == Diff.MODIFIED then
            status_icon = "≠"  -- modified on both sides
        elseif entry.status == Diff.ADDED then
            status_icon = "↑"  -- local only (natural to push)
        elseif entry.status == Diff.REMOVED then
            status_icon = "↓"  -- cloud only (natural to pull)
        end

        -- Key name and status
        local key_display = Categories.keyLabel(self.category, entry.key)
        local key_line = HorizontalGroup:new{
            TextWidget:new{
                text = status_icon .. " ",
                face = key_font,
            },
            TextWidget:new{
                text = key_display,
                face = key_font,
                max_width = inner_width - Size.padding.large * 6,
            },
        }

        local local_display, remote_display, structured =
            Diff.displayValues(entry.local_val, entry.remote_val)
        local value_group
        if structured then
            value_group = sideBySideValues(local_display, remote_display)
        else
            value_group = VerticalGroup:new{
                align = "left",
                TextBoxWidget:new{
                    text = _('Local:') .. '  '
                        .. Categories.formatValue(self.category, entry.key, entry.local_val),
                    face = text_font,
                    width = inner_width,
                },
                TextBoxWidget:new{
                    text = _('Cloud:') .. '  '
                        .. Categories.formatValue(self.category, entry.key, entry.remote_val),
                    face = text_font,
                    width = inner_width,
                },
            }
        end

        -- Selection indicator
        local sel = self.selections[idx]
        local sel_text
        if sel == "pull" then
            sel_text = _("⬇ Pull from cloud")
        elseif sel == "push" then
            sel_text = _("⬆ Push to cloud")
        else
            sel_text = _("  ─ tap to select")
        end
        local sel_widget = TextWidget:new{
            text = sel_text,
            face = status_font,
            max_width = inner_width,
            fgcolor = sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }

        -- Wrap row in a tappable group
        local row = VerticalGroup:new{
            key_line,
            value_group,
            sel_widget,
            VerticalSpan:new{ width = Size.span.vertical_default },
        }

        -- We store the entry index so the tap callback can cycle the selection
        local row_container = InputContainer:new{
            dimen = Geom:new{ w = inner_width, h = row:getSize().h },
        }
        row_container[1] = row
        row_container._entry_idx = idx

        local this = self
        row_container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return row_container.dimen end,
                },
            },
        }
        row_container.onTap = function()
            this:cycleSelection(idx)
            return true
        end
        table.insert(rows, row_container)
        table.insert(rows, LineWidget:new{
            dimen = Geom:new{ w = inner_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        })
    end

    -- Buttons (built first so we can measure their height)
    local action_row = {
        {
            text = _("Cancel"),
            callback = function() self:onClose() end,
        },
        {
            text = _("Apply"),
            callback = function() self:onApply() end,
            enabled = true,
        },
    }
    -- Only offered when the caller has somewhere to go next; otherwise Cancel is the same thing.
    if self.on_skip then
        table.insert(action_row, 1, {
            text = _("Skip"),
            callback = function() self:onSkip() end,
        })
    end
    local buttons = ButtonTable:new{
        width = inner_width,
        buttons = {
            {
                {
                    text = _("Pull all"),
                    callback = function() self:selectAll("pull") end,
                },
                {
                    text = _("Push all"),
                    callback = function() self:selectAll("push") end,
                },
                {
                    text = _("Clear"),
                    callback = function() self:clearSelections() end,
                },
            },
            action_row,
        },
        show_parent = self,
    }

    -- Scrollable content area (use measured button height)
    local content_height = self.height
        - title_widget:getSize().h
        - summary_widget:getSize().h
        - hint_widget:getSize().h
        - Size.padding.default * 4
        - Size.line.thick  -- separator
        - buttons:getSize().h

    local scrollable = ScrollableContainer:new{
        dimen = Geom:new{ w = inner_width, h = content_height },
        show_parent = self,
        VerticalGroup:new{
            VerticalSpan:new{ width = Size.span.vertical_default },
            rows,
        },
    }
    self.scrollable = scrollable
    self.cropping_widget = scrollable

    local content = VerticalGroup:new{
        align = "left",
        CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = title_widget:getSize().h },
            title_widget,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = summary_widget:getSize().h },
            summary_widget,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = hint_widget:getSize().h },
            hint_widget,
        },
        VerticalSpan:new{ width = Size.padding.default },
        LineWidget:new{
            dimen = Geom:new{ w = inner_width, h = Size.line.thick },
            background = Blitbuffer.COLOR_BLACK,
        },
        scrollable,
        VerticalSpan:new{ width = Size.padding.default },
        buttons,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = padding,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.frame,
    }
    self.dimen = Screen:getSize()
end

function DiffViewer:onShow()
    UIManager:setDirty(nil, "full")
    return true
end

function DiffViewer:cycleSelection(idx)
    local cur = self.selections[idx]
    if cur == nil then
        -- Determine default direction based on entry status
        local entry = self.changes[idx]
        if entry.status == Diff.REMOVED then
            self.selections[idx] = "pull"  -- cloud-only → default pull
        else
            self.selections[idx] = "push"  -- local or modified → default push
        end
    elseif cur == "push" then
        self.selections[idx] = "pull"
    elseif cur == "pull" then
        self.selections[idx] = nil
    end
    self:refreshUI()
end

function DiffViewer:selectAll(direction)
    for idx in ipairs(self.changes) do
        self.selections[idx] = direction
    end
    self:refreshUI()
end

function DiffViewer:clearSelections()
    self.selections = {}
    self:refreshUI()
end

function DiffViewer:refreshUI()
    local saved_y = self.scrollable and self.scrollable._scroll_offset_y or 0
    UIManager:close(self)
    self:buildUI()
    if self.scrollable and saved_y > 0 then
        self.scrollable._scroll_offset_y = saved_y
    end
    UIManager:show(self)
end

function DiffViewer:onApply()
    local selections = {}
    for idx, direction in pairs(self.selections) do
        if direction then
            table.insert(selections, {
                entry = self.changes[idx],
                direction = direction,
            })
        end
    end
    if #selections == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No keys selected. Tap rows to select push/pull actions."),
            timeout = 3,
        })
        return
    end
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.on_apply then
        self.on_apply(selections)
    end
end

--- Leave this group exactly as it is on both sides and let the caller carry on with the
--- next one. Cancel, by contrast, stops the whole run.
function DiffViewer:onSkip()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.on_skip then
        self.on_skip()
    end
    return true
end

function DiffViewer:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.on_cancel then
        self.on_cancel()
    end
    return true
end

function DiffViewer:onSwipe(_, ges)
    if ges.direction == "south" or ges.direction == "east" then
        self:onClose()
        return true
    end
end

return DiffViewer
