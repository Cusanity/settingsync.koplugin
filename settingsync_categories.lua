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

local SETTINGS_DIR = DataStorage:getSettingsDir()
local READER_SETTINGS = DataStorage:getDataDir() .. "/settings.reader.lua"

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
    for _ in pairs(val) do count = count + 1 end
    return string.format(_("%d gestures defined"), count)
end

local function formatCustomMultiswipes(val)
    if type(val) ~= "table" then return Diff.prettyValue(val) end
    local count = 0
    for _ in pairs(val) do count = count + 1 end
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

-- Plugin categories. Each captures *every* config key for one plugin so a user
-- can back up or restore that plugin's full setup in one step.
--
-- Extraction modes (see Categories.owns / Categories.extract):
--   keys       = { "a", "b" }  -- only these top-level keys
--   key_prefix = "xray_"       -- every key starting with this prefix
--   all_keys   = true          -- the entire settings file

Categories.GLOBAL = {
    id                 = "global",
    label              = _("KOReader core settings"),
    description        = _("Reading, display and behaviour settings (settings.reader.lua)."),
    is_device_specific = false,
    local_path         = READER_SETTINGS,
    remote_name        = "settings.reader.lua",
    all_keys           = true,
    exclude_keys       = {
        "device_id",
        "screen_mode",
        "home_dir",
        "lastdir",
        "lastfile",
        "inbox_dir",
        "screensaver_dir",
        "screenshot_dir",
        "last_migration_date",
        "quickstart_shown_version",
        "wifi_was_on",
        "SSH_port",
        "SSH_allow_no_password",
    },
}

Categories.CLOUD_STORAGE = {
    id                 = "cloudstorage",
    label              = _("Cloud storage & WebDAV"),
    description        = _("Cloud servers, WebDAV list and default upload/download folders."),
    is_device_specific = true,
    local_path         = SETTINGS_DIR .. "/cloudstorage.lua",
    remote_name        = "cloudstorage.lua",
    all_keys           = true,
}

Categories.EXPORTER = {
    id                 = "exporter",
    label              = _("Highlight export"),
    description        = _("Export formats and destinations."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "exporter.lua",
    keys               = { "exporter" },
}

Categories.STATISTICS = {
    id                 = "statistics",
    label              = _("Reading statistics"),
    description        = _("Reading statistics options (not the history database)."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "statistics.lua",
    keys               = { "statistics" },
}

Categories.KOSYNC = {
    id                 = "kosync",
    label              = _("Progress sync"),
    description        = _("Progress sync server, account and options."),
    is_device_specific = true,
    local_path         = SETTINGS_DIR .. "/kosync.lua",
    remote_name        = "kosync.lua",
    all_keys           = true,
}

Categories.XRAY = {
    id                 = "xray",
    label              = _("X-Ray"),
    description        = _("All X-Ray options and its sync server settings."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "xray.lua",
    key_prefix         = "xray_",
}

Categories.HIGHLIGHT_SYNC = {
    id                 = "highlightsync",
    label              = _("Highlight sync"),
    description        = _("Highlight sync server and options."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "highlightsync.lua",
    keys               = { "highlight_sync" },
}

Categories.ASSISTANT = {
    id                 = "assistant",
    label              = _("AI assistant"),
    description        = _("AI assistant preferences, provider and model selection."),
    is_device_specific = true,
    local_path         = SETTINGS_DIR .. "/assistant.lua",
    remote_name        = "assistant.lua",
    all_keys           = true,
}

--- All registered categories in display order.
Categories.ALL = {
    Categories.GLOBAL,
    Categories.GESTURES,
    Categories.CLOUD_STORAGE,
    Categories.EXPORTER,
    Categories.STATISTICS,
    Categories.KOSYNC,
    Categories.XRAY,
    Categories.HIGHLIGHT_SYNC,
    Categories.ASSISTANT,
}

--- Return true if a settings key belongs to the given category.
function Categories.owns(category, key)
    if category.all_keys then
        return true
    end
    if category.key_prefix and type(key) == "string"
            and key:sub(1, #category.key_prefix) == category.key_prefix then
        return true
    end
    if category.keys then
        for _, k in ipairs(category.keys) do
            if k == key then return true end
        end
    end
    return false
end

--- Extract only the keys belonging to a category from a full settings table.
function Categories.extract(settings_data, category)
    local result = {}
    for key, val in pairs(settings_data) do
        if Categories.owns(category, key) then
            result[key] = val
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
