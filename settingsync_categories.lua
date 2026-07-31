--[[--
Category definitions for SettingSync.

Each category describes a logical group of settings keys that can be synced
independently.  Categories provide human-readable key labels and value
formatters so the diff viewer shows meaningful text instead of raw Lua dumps.
--]]

local DataStorage = require("datastorage")
local Diff = require("settingsync_diff")
local _ = require("settingsync_gettext")

local Categories = {}

-- Keys belonging to the Gestures category (all live in settings/gestures.lua).
local GESTURE_KEYS = {
    "gesture_fm",
    "gesture_reader",
    "custom_multiswipes",
}

-- Translated display labels for each gesture key.
local GESTURE_KEY_LABELS = {
    gesture_fm         = _("File manager gesture map"),
    gesture_reader     = _("Reader gesture map"),
    custom_multiswipes = _("Custom multiswipe gestures"),
}

local function formatGestureMap(val)
    if type(val) ~= "table" then return Diff.prettyValue(val) end
    local count = 0
    for _k in pairs(val) do count = count + 1 end
    return string.format(_("%d gestures defined"), count)
end

local function formatCustomMultiswipes(val)
    if type(val) ~= "table" then return Diff.prettyValue(val) end
    local count = 0
    for _k in pairs(val) do count = count + 1 end
    return string.format(_("%d custom multiswipes"), count)
end

local GESTURE_VALUE_FORMATTERS = {
    gesture_fm         = formatGestureMap,
    gesture_reader     = formatGestureMap,
    custom_multiswipes = formatCustomMultiswipes,
}

Categories.GESTURES = {
    id               = "gestures",
    label            = _("Gestures"),
    description      = _("Touch gesture action mappings"),
    is_device_specific = true,
    -- gestures.lua lives in settings/, not the data root
    local_path       = DataStorage:getSettingsDir() .. "/gestures.lua",
    remote_name      = "gestures.lua",
    keys             = GESTURE_KEYS,
    key_labels       = GESTURE_KEY_LABELS,
    value_formatters = GESTURE_VALUE_FORMATTERS,
}

--- All registered categories in display order.
Categories.ALL = { Categories.GESTURES }

--- Extract only the keys belonging to a category from a full settings table.
function Categories.extract(settings_data, category)
    local result = {}
    for _, key in ipairs(category.keys) do
        if settings_data[key] ~= nil then
            result[key] = settings_data[key]
        end
    end
    return result
end

--- Return the display label for a settings key within a category.
-- Falls back to the raw key name if not defined.
function Categories.keyLabel(category, key)
    return (category and category.key_labels and category.key_labels[key]) or key
end

--- Format a value for display, using the category's formatter or Diff.prettyValue.
function Categories.formatValue(category, key, val)
    if val == nil then return _("(none)") end
    if category and category.value_formatters and category.value_formatters[key] then
        return category.value_formatters[key](val)
    end
    return Diff.prettyValue(val)
end

return Categories
