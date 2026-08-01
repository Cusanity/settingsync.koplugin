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

Categories.SCREEN = {
    id                 = "screen",
    label              = _("Screen"),
    description        = _("Screen and display settings."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "screen.lua",
    keys               = {
        "night_mode",
        "screen_dpi", "custom_screen_dpi",
        "fm_rotation_mode",
        "color_rendering",
        "low_pan_rate",
        "no_refresh_on_second_chapter_page",
        "refresh_on_chapter_boundaries",
        "refresh_on_pages_with_images",
        "notification_sources_to_show_mask",
        "fullscreen",
        "screensaver_type", "screensaver_delay",
        "screensaver_extra_flash_count", "screensaver_extra_flash_delay",
        "screensaver_message_alpha", "screensaver_message_vertical_position",
        "screensaver_stretch_limit_percentage",
        "autowarmth_night_time", "autowarmth_day_time",
        "autodim_after_seconds", "autodim_pm",
        "coverimage_enabled", "coverimage_background", "coverimage_fallback",
        "coverimage_include_title", "coverimage_include_authors",
    },
}

Categories.NETWORK = {
    id                 = "network",
    label              = _("Network"),
    description        = _("Network and Wi-Fi settings."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "network.lua",
    keys               = {
        "http_proxy", "http_proxy_enabled",
        "wifi_enable_action", "wifi_disable_action",
        "network_powersave",
        "auto_standby_timeout_seconds",
    },
}

Categories.NAVIGATION = {
    id                 = "navigation",
    label              = _("Navigation"),
    description        = _("Navigation, button and gesture settings."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "navigation.lua",
    keys               = {
        "back_to_exit", "back_in_filemanager", "back_in_reader",
        "backspace_as_back",
        "opening_page_location_stack",
        "skim_dialog_position",
        "android_ignore_back_button", "android_ignore_volume_keys",
        "input_invert_page_turn_keys",
        "input_invert_left_page_turn_keys",
        "input_invert_right_page_turn_keys",
        "input_no_key_repeat", "input_lock_gsensor", "input_ignore_gsensor",
        "activate_menu",
        "ignore_hold_corners",
        "disable_double_tap",
        "page_turns_tap_zones",
        "page_turns_tap_zone_backward_size_ratio",
        "page_turns_tap_zone_forward_size_ratio",
        "pageturn_power",
        "scroll_method", "inertial_scroll", "scroll_activation_delay",
        "haptic_feedback_override",
    },
}

Categories.DOCUMENT = {
    id                 = "document",
    label              = _("Document"),
    description        = _("Document handling and metadata settings."),
    is_device_specific = false,
    local_path         = READER_SETTINGS,
    remote_name        = "document.lua",
    keys               = {
        "document_metadata_folder", "document_metadata_arc_folder",
        "document_metadata_arc_on_closing",
        "auto_save_settings_interval_minutes",
        "end_document_action", "end_document_auto_mark",
        "collate",
        "partial_rerendering",
    },
}

Categories.LANGUAGE = {
    id                 = "language",
    label              = _("Language"),
    description        = _("Language, units and time format."),
    is_device_specific = false,
    local_path         = READER_SETTINGS,
    remote_name        = "language.lua",
    keys               = {
        "language",
        "dimension_units", "dimension_units_append_px",
        "duration_format",
        "twelve_hour_clock",
    },
}

Categories.DEVICE = {
    id                 = "device",
    label              = _("Device"),
    description        = _("Device-specific hardware settings."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "device.lua",
    keys               = {
        "keyboard_layout_default", "keyboard_layouts",
        "keyboard_key_bold", "keyboard_key_border",
        "keyboard_key_compact", "keyboard_key_font_size",
        "font_ui_fallbacks",
        "file_ext_assoc",
        "device_status_battery_interval_minutes",
        "device_status_battery_threshold",
        "device_status_battery_threshold_high",
        "device_status_memory_interval_minutes",
        "device_status_memory_threshold",
        "enable_charging_led",
        "ignore_power_sleepcover", "ignore_open_sleepcover",
        "autostandby_timeout", "autosuspend_timeout", "autoshutdown_timeout",
        "pageturn_power",
        "screenshot_folder",
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

Categories.STATUS_BAR = {
    id                 = "statusbar",
    label              = _("Status bar"),
    description        = _("Status bar layout, enabled items and saved presets."),
    is_device_specific = true,
    local_path         = READER_SETTINGS,
    remote_name        = "statusbar.lua",
    keys               = {
        "footer",
        "reader_footer_mode",
        "reader_footer_custom_text",
        "reader_footer_custom_text_repetitions",
        "footer_presets",
    },
    key_labels         = {
        footer                              = _("Status bar settings"),
        reader_footer_mode                  = _("Active mode"),
        reader_footer_custom_text           = _("Custom text"),
        reader_footer_custom_text_repetitions = _("Custom text repetitions"),
        footer_presets                      = _("Saved presets"),
    },
}

--- All registered categories in display order.
Categories.ALL = {
    Categories.SCREEN,
    Categories.NETWORK,
    Categories.NAVIGATION,
    Categories.DOCUMENT,
    Categories.LANGUAGE,
    Categories.DEVICE,
    Categories.GESTURES,
    Categories.CLOUD_STORAGE,
    Categories.EXPORTER,
    Categories.STATISTICS,
    Categories.KOSYNC,
    Categories.XRAY,
    Categories.HIGHLIGHT_SYNC,
    Categories.ASSISTANT,
    Categories.STATUS_BAR,
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
