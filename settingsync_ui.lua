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

local Diff = require("settingsync_diff")

local DiffViewer = InputContainer:extend{
    width = nil,
    height = nil,
    diff = nil,          -- array of diff entries from Diff.compare()
    source_label = nil,  -- e.g. "settings.reader.lua"
    on_apply = nil,      -- callback(selections) called when user confirms
    selections = nil,    -- { [idx] = "pull"|"push"|nil }
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
    local summary = string.format(_("%d changed: %d modified, %d local only, %d cloud only"),
        #self.changes, n_modified, n_added, n_removed)
    local summary_widget = TextWidget:new{
        text = summary,
        face = status_font,
        max_width = inner_width,
    }

    -- Build per-key rows
    local rows = VerticalGroup:new{ border_size = 0 }
    for idx, entry in ipairs(self.changes) do
        local status_icon
        if entry.status == Diff.MODIFIED then
            status_icon = "≠"
        elseif entry.status == Diff.ADDED then
            status_icon = "+"  -- local only
        elseif entry.status == Diff.REMOVED then
            status_icon = "−"  -- cloud only
        end

        -- Key name and status
        local key_line = HorizontalGroup:new{
            TextWidget:new{
                text = status_icon .. " ",
                face = key_font,
            },
            TextWidget:new{
                text = tostring(entry.key),
                face = key_font,
                max_width = inner_width - Size.padding.large * 6,
            },
        }

        -- Value previews
        local local_preview = entry.local_val ~= nil
            and ("  Local:  " .. Diff.prettyValue(entry.local_val))
            or  ("  Local:  (none)")
        local remote_preview = entry.remote_val ~= nil
            and ("  Cloud:  " .. Diff.prettyValue(entry.remote_val))
            or  ("  Cloud:  (none)")

        local local_val_widget = TextBoxWidget:new{
            text = local_preview,
            face = text_font,
            width = inner_width,
        }
        local remote_val_widget = TextBoxWidget:new{
            text = remote_preview,
            face = text_font,
            width = inner_width,
        }

        -- Selection indicator
        local sel = self.selections[idx]
        local sel_text
        if sel == "pull" then
            sel_text = _("⬇ PULL from cloud")
        elseif sel == "push" then
            sel_text = _("⬆ PUSH to cloud")
        else
            sel_text = _("  (tap to select action)")
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
            local_val_widget,
            remote_val_widget,
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
            {
                {
                    text = _("Cancel"),
                    callback = function() self:onClose() end,
                },
                {
                    text = _("Apply"),
                    callback = function() self:onApply() end,
                    enabled = true,
                },
            },
        },
        show_parent = self,
    }

    -- Scrollable content area (use measured button height)
    local content_height = self.height
        - title_widget:getSize().h
        - summary_widget:getSize().h
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
    UIManager:close(self)
    self:buildUI()
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

function DiffViewer:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    return true
end

function DiffViewer:onSwipe(_, ges)
    if ges.direction == "south" or ges.direction == "east" then
        self:onClose()
        return true
    end
end

return DiffViewer
