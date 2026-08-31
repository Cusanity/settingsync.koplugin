--[[--
Category definitions for SettingSync.

Each category describes a logical group of settings keys that can be synced
independently.  Categories provide human-readable key labels and value
formatters so the diff viewer shows meaningful text instead of raw Lua dumps.
--]]

local DataStorage = require("datastorage")
local logger = require("logger")
local Diff = require("settingsync_diff")
local _ = require("settingsync_gettext")

local Categories = {}

local SETTINGS_DIR = DataStorage:getSettingsDir()
local READER_SETTINGS = DataStorage:getDataDir() .. "/settings.reader.lua"

-- Raw-file categories expose the whole file under one "__file_content" key.
local function formatFileContent(val)
    if type(val) ~= "string" then return Diff.prettyValue(val) end
    local n_newlines = select(2, val:gsub("\n", "\n"))
    return string.format(_("%d bytes, %d lines"), #val, n_newlines + 1)
end

local FILE_CONTENT_LABELS = { __file_content = _("File contents") }
local FILE_CONTENT_FORMATTERS = { __file_content = formatFileContent }

-- Key-name patterns that never sync. Applied to every category whose keys are KOReader
-- setting names (see isExcluded), so a device-specific key upstream adds tomorrow is
-- dropped by shape instead of needing a hand-maintained list here.
local UNSYNCABLE_KEY_PATTERNS = {
    -- Per-install locations and volatile state.
    "_dirs?$", "_paths?$", "_folders?$", "^last", "^dev_",
    -- Files keyed by absolute path (settings/directory_defaults.lua) describe one device's
    -- filesystem, so they are matched by the key's shape rather than by file name.
    "^/", "^%a:[/\\]",
    -- Per-device identity: sharing it breaks progress sync and annotation attribution.
    "^device_id$",
}

-- Credential-shaped key names. Grouping them by shape means a password or API key
-- upstream adds tomorrow is carried across with the rest of an account's setup.
local CREDENTIAL_KEY_PATTERNS = {
    "password", "passwd", "token", "secret", "credential", "api_?key",
    -- Server lists (opds_servers, …) embed a login per entry.
    "_servers?$",
}

--- Names of settings/ files holding volatile per-device state rather than configuration.
--- Matched by shape so future history/queue/cache dumps are skipped without maintenance.
--- Anchored to whole name parts so a real settings file like "history_view" is not caught.
local VOLATILE_FILE_PATTERNS = { "history", "queue", "cache", "stats" }

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
    -- gestures.lua lives in settings/, not the data root, and this plugin only ever
    -- stores these keys in it, so the whole file can be synced wholesale.
    local_path       = DataStorage:getSettingsDir() .. "/gestures.lua",
    remote_name      = "gestures.lua",
    all_keys         = true,
    key_labels       = GESTURE_KEY_LABELS,
    value_formatters = GESTURE_VALUE_FORMATTERS,
}

-- Plugin categories. Each captures *every* config key for one plugin so a user
-- can back up or restore that plugin's full setup in one step.
--
-- Extraction modes (see Categories.owns / Categories.extract):
--   keys        = { "a", "b" }        -- only these top-level keys
--   key_prefix  = "xray_"             -- every key starting with this prefix
--   key_prefix  = { "a_", "b_" }      -- every key starting with any of these prefixes
--   key_patterns = { "password" }     -- every key matching any of these Lua patterns
--   all_keys    = true                -- the entire settings file
--
-- Storage modes (see readSettingsData / writeSettingsData in main.lua):
--   (default)          -- a LuaSettings dump, merged key by key
--   raw_file  = true   -- hand-edited source, synced verbatim under "__file_content"
--   dir_files = "%.css$"  -- a directory: key = relative path, value = file contents
--
-- UNSYNCABLE_KEY_PATTERNS is applied to every category below without being named; only
-- keys that are unsyncable *and* not path-shaped need an explicit exclude_keys entry.
--
-- Prefer key_prefix over an explicit keys list whenever a plugin/feature owns a whole
-- namespace (e.g. all "screensaver_*" keys) -- it makes the category pick up new keys
-- automatically instead of needing a manual update here every time upstream adds one.

Categories.SCREEN = {
    id                 = "screen",
    label              = _("Screen"),
    description        = _("Screen and display settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "screen.lua",
    -- Screensaver, night-mode auto-warmth, auto-dim and cover-image settings each own a
    -- key namespace, so new sub-settings under them are picked up automatically.
    key_prefix         = { "screensaver_", "autowarmth_", "autodim_", "cover_image_" },
    -- Swept in by the prefixes above but not path-shaped, so the global filter misses
    -- them: an absolute image path and per-device cycle state. Neither ports.
    exclude_keys       = { "screensaver_image", "screensaver_cycle_index" },
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
    },
}

Categories.NETWORK = {
    id                 = "network",
    label              = _("Network"),
    description        = _("Network and Wi-Fi settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "network.lua",
    keys               = {
        "http_proxy", "http_proxy_enabled",
        "wifi_enable_action", "wifi_disable_action",
        "network_powersave",
        "auto_standby_timeout_seconds",
    },
}

-- Claimed explicitly so it does not also surface as an auto-discovered "Network settings"
-- entry next to the category above.
Categories.WIFI_NETWORKS = {
    id                 = "wifi_networks",
    label              = _("Saved Wi-Fi networks"),
    description        = _("Access points remembered by KOReader, with their passwords, so another device joins the same networks."),
    local_path         = SETTINGS_DIR .. "/network.lua",
    remote_name        = "wifi_networks.lua",
    all_keys           = true,
    -- Keys are SSIDs, so the setting-name filter would drop an access point named
    -- e.g. "lastfloor" or "Home_paths".
    opaque_keys        = true,
}

Categories.NAVIGATION = {
    id                 = "navigation",
    label              = _("Navigation"),
    description        = _("Navigation, button and gesture settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "navigation.lua",
    -- Page-turn key/gsensor inversion and tap-zone sizing each share a key namespace.
    key_prefix         = { "input_", "page_turns_tap_zone" },
    keys               = {
        "back_to_exit", "back_in_filemanager", "back_in_reader",
        "backspace_as_back",
        "opening_page_location_stack",
        "skim_dialog_position",
        "android_ignore_back_button", "android_ignore_volume_keys",
        "activate_menu",
        "ignore_hold_corners",
        "disable_double_tap",
        "pageturn_power",
        "scroll_method", "inertial_scroll", "scroll_activation_delay",
        "haptic_feedback_override",
    },
}

Categories.DOCUMENT = {
    id                 = "document",
    label              = _("Document"),
    description        = _("Document handling and metadata settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "document.lua",
    key_prefix         = { "document_metadata_", "end_document_" },
    keys               = {
        "auto_save_settings_interval_minutes",
        "collate",
        "partial_rerendering",
    },
}

Categories.LANGUAGE = {
    id                 = "language",
    label              = _("Language"),
    description        = _("Language, units and time format."),
    local_path         = READER_SETTINGS,
    remote_name        = "language.lua",
    key_prefix         = { "dimension_units" },
    keys               = {
        "language",
        "duration_format",
        "twelve_hour_clock",
    },
}

Categories.DEVICE = {
    id                 = "device",
    label              = _("Device"),
    description        = _("Device-specific hardware settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "device.lua",
    -- Keyboard layout/appearance and battery/memory monitor thresholds each own a
    -- key namespace, so new sub-settings under them are picked up automatically.
    key_prefix         = { "keyboard_", "device_status_" },
    keys               = {
        "font_ui_fallbacks",
        "file_ext_assoc",
        "enable_charging_led",
        "ignore_power_sleepcover", "ignore_open_sleepcover",
        "auto_suspend_timeout_seconds", "autoshutdown_timeout_seconds",
    },
}

Categories.CLOUD_STORAGE = {
    id                 = "cloudstorage",
    label              = _("Cloud storage & WebDAV"),
    description        = _("Cloud servers and the WebDAV list. The local upload/download folders stay per-device."),
    local_path         = SETTINGS_DIR .. "/cloudstorage.lua",
    remote_name        = "cloudstorage.lua",
    all_keys           = true,
}

Categories.EXPORTER = {
    id                 = "exporter",
    label              = _("Highlight export"),
    description        = _("Export formats and destinations."),
    local_path         = READER_SETTINGS,
    remote_name        = "exporter.lua",
    keys               = { "exporter" },
}

Categories.STATISTICS = {
    id                 = "statistics",
    label              = _("Reading statistics"),
    description        = _("Reading statistics options (not the history database)."),
    local_path         = READER_SETTINGS,
    remote_name        = "statistics.lua",
    keys               = { "statistics" },
}

Categories.KOSYNC = {
    id                 = "kosync",
    label              = _("Progress sync"),
    description        = _("Progress sync server, account and options."),
    local_path         = SETTINGS_DIR .. "/kosync.lua",
    remote_name        = "kosync.lua",
    all_keys           = true,
}

Categories.XRAY = {
    id                 = "xray",
    label              = _("X-Ray"),
    description        = _("All X-Ray options and its sync server settings."),
    local_path         = READER_SETTINGS,
    remote_name        = "xray.lua",
    key_prefix         = "xray_",
}

Categories.HIGHLIGHT_SYNC = {
    id                 = "highlightsync",
    label              = _("Highlight sync"),
    description        = _("Highlight sync server and options."),
    local_path         = READER_SETTINGS,
    remote_name        = "highlightsync.lua",
    keys               = { "highlight_sync" },
}

Categories.ASSISTANT = {
    id                 = "assistant",
    label              = _("AI assistant"),
    description        = _("AI assistant preferences, provider and model selection."),
    local_path         = SETTINGS_DIR .. "/assistant.lua",
    remote_name        = "assistant.lua",
    all_keys           = true,
}

Categories.STATUS_BAR = {
    id                 = "statusbar",
    label              = _("Status bar"),
    description        = _("Status bar layout, enabled items and saved presets."),
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

-- Groups every credential-shaped key in settings.reader.lua so accounts port to a new
-- device in one switch, and so the catch-all below stays about plain preferences.
-- Residual, so a credential-shaped key a feature category already owns (xray_sync_server
-- matches "_servers?$") stays with that category instead of being claimed twice.
Categories.READER_SECRETS = {
    id                 = "reader_secrets",
    label              = _("Saved passwords"),
    description        = _("Logins kept in settings.reader.lua, such as the Calibre password and OPDS server accounts."),
    local_path         = READER_SETTINGS,
    remote_name        = "reader_secrets.lua",
    residual_of        = READER_SETTINGS,
    key_patterns       = CREDENTIAL_KEY_PATTERNS,
}

-- Catch-all for settings.reader.lua. Without it, any key upstream adds that no category
-- above happens to claim would silently never sync until someone edited this file.
Categories.READER_OTHER = {
    id                 = "reader_other",
    label              = _("Other reader settings"),
    description        = _("Everything in settings.reader.lua that no other category covers. New KOReader settings land here automatically."),
    local_path         = READER_SETTINGS,
    remote_name        = "reader_other.lua",
    residual_of        = READER_SETTINGS,
    exclude_keys       = { "ko_version" },
}

-- LuaDefaults writes defaults.custom.lua with the same dump() call LuaSettings uses, so it
-- merges key by key and picks up new overrides on its own. (The pre-9546 bare-assignment
-- file was defaults.persistent.lua, which upstream migrated away years ago.)
Categories.DEFAULTS_CUSTOM = {
    id                 = "defaults_custom",
    label              = _("Custom defaults"),
    description        = _("Advanced settings that override KOReader's built-in defaults. New overrides are picked up automatically."),
    local_path         = DataStorage:getDataDir() .. "/defaults.custom.lua",
    remote_name        = "defaults.custom.lua",
    all_keys           = true,
}

-- `dir_files` categories mirror a whole directory of hand-written files: each key is a
-- path relative to the directory and each value that file's contents, so a tweak or patch
-- added later shows up as a new key with no change here.
Categories.STYLE_TWEAKS = {
    id                 = "styletweaks",
    label              = _("Style tweaks"),
    description        = _("Your own CSS files from styletweaks/. The setting that switches them on syncs with the reader settings, so both sides stay in step."),
    local_path         = DataStorage:getDataDir() .. "/styletweaks",
    remote_name        = "styletweaks.lua",
    dir_files          = "%.css$",
    all_keys           = true,
    value_formatter    = formatFileContent,
}

Categories.USER_PATCHES = {
    id                 = "userpatches",
    label              = _("User patches"),
    description        = _("Lua files from patches/, which KOReader runs at startup. Off by default: pulling one means executing code from your cloud on this device."),
    default_off        = true,
    local_path         = DataStorage:getDataDir() .. "/patches",
    remote_name        = "userpatches.lua",
    dir_files          = "%.lua$",
    all_keys           = true,
    value_formatter    = formatFileContent,
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
    Categories.WIFI_NETWORKS,
    Categories.STYLE_TWEAKS,
    Categories.DEFAULTS_CUSTOM,
    Categories.READER_SECRETS,
    Categories.READER_OTHER,
    Categories.USER_PATCHES,
}

----------------------------------------------------------------------
-- Dynamic discovery: plugin settings and configuration files
----------------------------------------------------------------------

--- "assistant.koplugin" / "kosync.lua" -> "Assistant" / "Kosync".
local function readableLabel(name)
    local id = name:gsub("%.koplugin$", ""):gsub("%.lua$", ""):gsub("_", " ")
    return (id:gsub("^%l", string.upper))
end

--- Volatile-state files are named for what they hold, with the word last
--- ("bookinfo_cache.lua"), so only the trailing name part is matched -- otherwise a real
--- settings file like "cache_policy.lua" would be skipped.
local function isVolatileFile(name)
    local stem = name:gsub("%.lua$", "")
    local tail = stem:match("([^_%.%-]+)$") or stem
    for _, word in ipairs(VOLATILE_FILE_PATTERNS) do
        if tail == word then return true end
    end
    return false
end

--- True if `path` looks like a LuaSettings dump: util.writeToFile's dofile-ready form,
--- a "-- <path>" line followed by a table literal. Re-serializing anything else
--- (hand-edited source, bare assignments) would destroy the file on the first pull.
--- Checked by reading the header rather than running the file, so discovery never
--- executes settings/ code just to learn its shape.
local function isSettingsDump(path)
    local f = io.open(path, "r")
    if not f then return false end
    local is_dump = false
    -- Line-wise, so a header comment longer than any fixed read size still parses.
    for _ = 1, 20 do
        local line = f:read("*l")
        if not line then break end
        if line:match("^%s*%-%-%[%[") then break end -- block comment: hand-written source
        if not line:match("^%s*$") and not line:match("^%s*%-%-") then
            is_dump = line:match("^%s*return%s*{") ~= nil
            break
        end
    end
    f:close()
    return is_dump
end

--- True for the top-level file names a plugin uses for user configuration rather than code:
--- "configuration.lua", "config.lua" and prefixed variants such as
--- "appstore_configuration.lua". The prefixed short form "<plugin>_config.lua" is *not*
--- matched, because that is the usual name for an internal source module
--- (assistant_config.lua), which must never be replaced by a pull. Sample files are skipped:
--- they hold placeholders, not the user's keys.
local function isPluginConfigFile(name)
    local stem = name:match("^(.+)%.lua$")
    if not stem or stem:match("%.sample$") then return false end
    return stem == "config" or stem == "configuration" or stem:match("_configuration$") ~= nil
end

--- Scan one plugins root directory for `*.koplugin/<config>.lua` files and append a
--- raw-file category for each one, skipping plugins already in `seen` (keyed by folder
--- name, so the same plugin found via multiple roots is only added once).
local function scanPluginConfigs(root, found, seen)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for name in lfs.dir(root) do
        local plugin_dir = root .. "/" .. name
        if name:match("%.koplugin$") and not seen[name]
                and lfs.attributes(plugin_dir, "mode") == "directory" then
            local plugin_id = name:gsub("%.koplugin$", "")
            for file in lfs.dir(plugin_dir) do
                local config_path = plugin_dir .. "/" .. file
                if isPluginConfigFile(file) and lfs.attributes(config_path, "mode") == "file" then
                    seen[name] = true
                    local stem = file:gsub("%.lua$", "")
                    local slug = stem:sub(1, #plugin_id + 1) == plugin_id .. "_"
                        and stem or (plugin_id .. "_" .. stem)
                    table.insert(found, {
                        id                 = "pluginconfig_" .. slug,
                        label              = string.format(_("%s configuration file"), readableLabel(name)),
                        description        = _("Whole-file backup of this plugin's hand-edited configuration file, which is where its API keys live. Pulling it replaces the local file with Lua the plugin will execute."),
                        local_path         = config_path,
                        remote_name        = "plugin_configs/" .. slug .. ".lua",
                        raw_file           = true,
                        keys               = { "__file_content" },
                        key_labels         = FILE_CONTENT_LABELS,
                        value_formatters   = FILE_CONTENT_FORMATTERS,
                    })
                end
            end
        end
    end
end

--- Discover the configuration files shipped by installed plugins (e.g. assistant.koplugin's
--- provider/API-key file, which is where settings like the Tavily search API key normally
--- live). Unlike the static categories above, these are hand-edited Lua source files, not
--- machine-generated LuaSettings dumps, so they're synced as opaque whole files
--- (raw_file = true) instead of being merged key-by-key -- that would require
--- re-serializing the file and would destroy the user's comments. New plugins that ship a
--- configuration file, and new keys added inside an existing one, are picked up
--- automatically with no changes needed here.
function Categories.discoverPluginConfigs()
    local found, seen = {}, {}

    scanPluginConfigs(DataStorage:getDataDir() .. "/plugins", found, seen)
    scanPluginConfigs("plugins", found, seen)

    local extra = G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then extra = { extra } end
    if type(extra) == "table" then
        for _, p in ipairs(extra) do scanPluginConfigs(p, found, seen) end
    end

    table.sort(found, function(a, b) return a.label < b.label end)
    return found
end

--- Recursively scan `dir` for unclaimed LuaSettings dumps, appending one category each.
--- `rel` is the path so far relative to SETTINGS_DIR, so a plugin that nests its settings
--- in a sub-folder is covered as well.
local function scanPluginSettings(dir, rel, claimed, found)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:sub(1, 2) ~= "._" then
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                scanPluginSettings(path, rel .. name .. "/", claimed, found)
            elseif mode == "file" and name:match("%.lua$") and not claimed[path] then
                if isVolatileFile(name) or not isSettingsDump(path) then
                    -- Logged so a settings file the heuristics wrongly reject is
                    -- traceable instead of silently never syncing.
                    logger.dbg("SettingSync: not a syncable settings dump, skipping", path)
                else
                    local relname = rel .. name
                    local flat = relname:gsub("/", "_")
                    table.insert(found, {
                        id                 = "pluginsettings_" .. flat:gsub("%.lua$", ""),
                        label              = string.format(_("%s settings"), readableLabel(name)),
                        description        = string.format(_("All settings stored in settings/%s by an installed plugin, including any accounts or tokens it keeps there."), relname),
                        local_path         = path,
                        remote_name        = "plugin_settings/" .. flat,
                        all_keys           = true,
                    })
                end
            end
        end
    end
end

--- Discover LuaSettings files in settings/ that no static category above claims, so a
--- newly installed plugin's settings sync without needing a code change here. These are
--- machine-generated dumps, so they can be synced key-by-key with all_keys.
function Categories.discoverPluginSettings()
    local found = {}
    local claimed = { [SETTINGS_DIR .. "/settingsync.lua"] = true }
    for _, cat in ipairs(Categories.ALL) do
        if cat.local_path then claimed[cat.local_path] = true end
    end
    scanPluginSettings(SETTINGS_DIR, "", claimed, found)
    table.sort(found, function(a, b) return a.label < b.label end)
    return found
end

local function hasClaimRules(category)
    return (category.all_keys or category.key_prefix or category.key_patterns or category.keys) ~= nil
end

--- Categories competing for the keys of `path`, split by precedence:
--- `direct` are ordinary owners; `residual` are catch-alls that still narrow their claim
--- (e.g. READER_SECRETS' credential patterns) and so outrank the last-resort catch-all.
local claimants_cache = {}
local function claimantsOf(path)
    if not claimants_cache[path] then
        local direct, residual = {}, {}
        for _, cat in ipairs(Categories.all()) do
            if (cat.local_path or READER_SETTINGS) == path then
                if not cat.residual_of then
                    table.insert(direct, cat)
                elseif hasClaimRules(cat) then
                    table.insert(residual, cat)
                end
            end
        end
        claimants_cache[path] = { direct = direct, residual = residual }
    end
    return claimants_cache[path]
end

--- The full category list: static definitions plus everything found on disk. Cached for
--- the process lifetime, since neither the installed plugin set nor the settings/ layout
--- changes without an app restart, and each plugin instance would otherwise rescan.
local all_cache
function Categories.all()
    if not all_cache then
        all_cache = {}
        for _, cat in ipairs(Categories.ALL) do
            table.insert(all_cache, cat)
        end
        for _, cat in ipairs(Categories.discoverPluginSettings()) do
            table.insert(all_cache, cat)
        end
        for _, cat in ipairs(Categories.discoverPluginConfigs()) do
            table.insert(all_cache, cat)
        end
    end
    return all_cache
end

--- Inclusion rules only: whether a category lays claim to a key's namespace.
local function claims(category, key)
    if category.all_keys then
        return true
    end
    if category.key_prefix and type(key) == "string" then
        local prefixes = type(category.key_prefix) == "table" and category.key_prefix or { category.key_prefix }
        for _, prefix in ipairs(prefixes) do
            if key:sub(1, #prefix) == prefix then return true end
        end
    end
    if category.key_patterns and type(key) == "string" then
        for _, pat in ipairs(category.key_patterns) do
            if key:match(pat) then return true end
        end
    end
    if category.keys then
        for _, k in ipairs(category.keys) do
            if k == key then return true end
        end
    end
    return false
end

--- True when a category's keys are KOReader setting names, and so can be judged by
--- UNSYNCABLE_KEY_PATTERNS. False where the keys mean something else: relative file paths
--- (`dir_files`), the synthetic whole-file key (`raw_file`), or arbitrary user strings such
--- as Wi-Fi SSIDs (`opaque_keys`).
local function usesSettingKeyNames(category)
    return not (category.dir_files or category.raw_file or category.opaque_keys)
end

--- Exclusion rules only: keys a category claims but must never sync.
local function isExcluded(category, key)
    if category.exclude_keys then
        for _, ek in ipairs(category.exclude_keys) do
            if ek == key then return true end
        end
    end
    if type(key) == "string" then
        if usesSettingKeyNames(category) then
            for _, pat in ipairs(UNSYNCABLE_KEY_PATTERNS) do
                if key:match(pat) then return true end
            end
        end
        if category.exclude_patterns then
            for _, pat in ipairs(category.exclude_patterns) do
                if key:match(pat) then return true end
            end
        end
    end
    return false
end

--- Return true if a settings key belongs to the given category.
function Categories.owns(category, key)
    if isExcluded(category, key) then return false end
    if category.residual_of then
        local competing = claimantsOf(category.residual_of)
        -- A key another category claims *or* deliberately excludes is not residual --
        -- otherwise excluding a key from its owner would hand it to the catch-all.
        for _, other in ipairs(competing.direct) do
            if claims(other, key) or isExcluded(other, key) then return false end
        end
        if hasClaimRules(category) then return claims(category, key) end
        -- Last-resort catch-all: yields to any narrower residual category.
        for _, other in ipairs(competing.residual) do
            if claims(other, key) and not isExcluded(other, key) then return false end
        end
        return true
    end
    return claims(category, key)
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
    if category then
        local formatter = (category.value_formatters and category.value_formatters[key])
            or category.value_formatter
        if formatter then return formatter(val) end
    end
    return Diff.prettyValue(val)
end

return Categories
