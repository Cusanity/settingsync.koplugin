--[[--
SettingSync – Synchronize KOReader settings across devices via WebDAV.

Provides per-key diffing between local and cloud settings with selective
push/pull so users have full control over which settings are synced.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("settingsync_gettext")

local Categories = require("settingsync_categories")
local Devices = require("settingsync_devices")
local Diff = require("settingsync_diff")
local DiffViewer = require("settingsync_ui")

-- Prioritize SettingSync in the Tools menu without a generic helper module name that can
-- collide with another plugin in Lua's global package.loaded cache.
table.insert(require("ui/elements/reader_menu_order").tools, 1, "settingsync")
table.insert(require("ui/elements/filemanager_menu_order").tools, 1, "settingsync")

local SETTINGS_DIR = DataStorage:getSettingsDir()
local DATA_DIR = DataStorage:getDataDir()
local PLUGIN_SETTINGS_PATH = SETTINGS_DIR .. "/settingsync.lua"
local READER_SETTINGS = DATA_DIR .. "/settings.reader.lua"

-- Temp directory for downloaded cloud files during diff
local TEMP_DIR = DATA_DIR .. "/cache/settingsync"

local function get_webdav_api()
    return require("webdavapi")
end

-- KOReader used to ship a standalone frontend/apps/cloudstorage/syncservice module;
-- newer versions removed it and folded its logic into the cloudstorage.koplugin
-- plugin instance (self.ui.cloudstorage) instead. Support both so this plugin keeps
-- working regardless of which KOReader version the user is on. Returns a table with
-- .getReadablePath(server) and :onShowCloudStorageList(callback), or nil.
local function get_cloud_sync(ui)
    local ok, OldSyncService = pcall(require, "frontend/apps/cloudstorage/syncservice")
    if ok and OldSyncService then
        return {
            getReadablePath = OldSyncService.getReadablePath,
            onShowCloudStorageList = function(_, callback)
                local dialog = OldSyncService:new{}
                dialog.onClose = function(this) UIManager:close(this) end
                dialog.onConfirm = callback
                UIManager:show(dialog)
            end,
        }
    end
    return ui and ui.cloudstorage
end

local SettingSync = WidgetContainer:extend{
    name = "settingsync",
    is_doc_only = false,
}

function SettingSync:init()
    self.settings = LuaSettings:open(PLUGIN_SETTINGS_PATH)
    self.ui.menu:registerToMainMenu(self)
end

--- All sync categories: the static list plus per-plugin settings files discovered on disk.
function SettingSync:getAllCategories()
    return Categories.all()
end

--- Whether a category is currently selected for sync. Categories the user never saw fall
--- back to their last "select/deselect all" choice, so plugins installed later inherit it
--- instead of silently switching themselves on.
local function categoryEnabled(scope, category, default_all)
    local choice = scope[category.id]
    if choice ~= nil then return choice ~= false end
    return default_all ~= false
end

--- The fallback state for categories with no explicit choice yet.
function SettingSync:categoryDefault()
    return self.settings:readSetting("sync_categories_default")
end

--- Return the categories the user has enabled for sync.
function SettingSync:getEnabledCategories()
    local scope = self.settings:readSetting("sync_categories", {})
    local default_all = self:categoryDefault()
    local enabled = {}
    for _, cat in ipairs(self:getAllCategories()) do
        if categoryEnabled(scope, cat, default_all) then
            table.insert(enabled, cat)
        end
    end
    return enabled
end

function SettingSync:addToMainMenu(menu_items)
    menu_items.settingsync = {
        text = _("SettingSync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:buildMainMenu() end,
    }
end

--- Build the top-level menu, laid out like a typical consumer sync screen:
--- one primary "Sync now" action, a status line, account/device setup,
--- a "What to sync" chooser, and an "Advanced" drawer for power features.
function SettingSync:buildMainMenu()
    local server_ok = function()
        return self.settings:readSetting("sync_server") ~= nil
    end

    return {
        {
            text = _("Sync now"),
            enabled_func = server_ok,
            keep_menu_open = true,
            callback = function() self:syncNow() end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Compares this device with the cloud and merges the differences automatically. If the same setting was changed in both places, you decide which version to keep."),
                })
            end,
        },
        {
            text_func = function() return self:statusText() end,
            enabled_func = function() return false end,
            separator = true,
        },
        {
            text_func = function()
                local sv = self.settings:readSetting("sync_server")
                return sv and (_("Cloud account: ") .. sv.name) or _("Set up cloud account…")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showCloudConfig(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return _("This device: ") .. Devices.currentName(self.settings)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showDeviceSelector(touchmenu_instance)
            end,
        },
        {
            text = _("Devices in cloud…"),
            help_text = _("Every device profile in the cloud folder and what each one has uploaded."),
            enabled_func = server_ok,
            keep_menu_open = true,
            callback = function() self:showCloudDevices() end,
            separator = true,
        },
        {
            text = _("What to sync"),
            sub_item_table_func = function() return self:buildWhatToSyncMenu() end,
            separator = true,
        },
        {
            text = _("Advanced"),
            sub_item_table_func = function() return self:buildAdvancedMenu() end,
        },
    }
end

--- Human-readable sync status shown under the "Sync now" button.
function SettingSync:statusText()
    if not self.settings:readSetting("sync_server") then
        return _("Not set up yet")
    end
    local ts = self.settings:readSetting("last_sync")
    if not ts then
        return _("Not synced yet")
    end
    return _("Last synced: ") .. os.date("%Y-%m-%d %H:%M", ts)
end

--- "What to sync": one checkbox per defined category so users can toggle individual groups.
function SettingSync:buildWhatToSyncMenu()
    local scope = self.settings:readSetting("sync_categories", {})
    local function isOn(category)
        return categoryEnabled(scope, category, self:categoryDefault())
    end
    local function toggle(category)
        scope[category.id] = not isOn(category)
        self.settings:saveSetting("sync_categories", scope)
        self.settings:flush()
    end
    local function anyEnabled()
        for _, cat in ipairs(self:getAllCategories()) do
            if isOn(cat) then return true end
        end
        return false
    end
    local items = {
        {
            text_func = function()
                return anyEnabled() and _("Deselect all") or _("Select all")
            end,
            callback = function(touchmenu_instance)
                local enable = not anyEnabled()
                for _, cat in ipairs(self:getAllCategories()) do
                    scope[cat.id] = enable
                end
                self.settings:saveSetting("sync_categories", scope)
                self.settings:saveSetting("sync_categories_default", enable)
                self.settings:flush()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            keep_menu_open = true,
            separator = true,
        },
    }
    for _, cat in ipairs(self:getAllCategories()) do
        local c = cat
        table.insert(items, {
            text = c.label,
            help_text = c.description,
            checked_func = function() return isOn(c) end,
            callback = function() toggle(c) end,
        })
    end
    return items
end

--- "Advanced": power-user features kept out of the main flow.
function SettingSync:buildAdvancedMenu()
    local server_ok = function()
        return self.settings:readSetting("sync_server") ~= nil
    end
    return {
        {
            text = _("Review and choose each change…"),
            help_text = _("See every differing setting and pick push or pull per item."),
            enabled_func = server_ok,
            callback = function() self:diffAndSync() end,
            separator = true,
        },
        {
            text = _("Restore from another device"),
            help_text = _("Copy a group of settings from another device's backup."),
            enabled_func = server_ok,
            sub_item_table_func = function() return self:buildRestoreMenu() end,
            separator = true,
        },
        {
            text = _("Force upload — overwrite cloud"),
            enabled_func = server_ok,
            callback = function() self:quickSync("push") end,
        },
        {
            text = _("Force download — overwrite this device"),
            enabled_func = server_ok,
            callback = function() self:quickSync("pull") end,
        },
    }
end

--- Per-category restore entries (device-specific groups such as gestures).
function SettingSync:buildRestoreMenu()
    local items = {}
    for _, cat in ipairs(self:getAllCategories()) do
        local c = cat
        table.insert(items, {
            text = c.label,
            help_text = c.description,
            callback = function() self:syncCategory(c) end,
        })
    end
    if #items == 0 then
        items = { { text = _("Nothing available to restore"), enabled_func = function() return false end } }
    end
    return items
end

--- Ensure the temp directory exists.
local function ensureTempDir()
    if lfs.attributes(TEMP_DIR, "mode") ~= "directory" then
        lfs.mkdir(TEMP_DIR)
    end
end

--- Evaluate a LuaSettings dump as data rather than running it. The file is often a copy
-- just downloaded from the cloud, and this happens during diffing, before the user has
-- approved anything -- dofile() would execute it either way. A dump is nothing but
-- literals, so an empty environment costs a legitimate file nothing and neuters the rest.
-- Returns the table, or nil plus a message.
local function loadDump(path)
    local util = require("util")
    local content = util.readFromFile(path, "rb")
    if not content then return nil, "cannot read file" end
    -- A leading ESC marks a precompiled chunk, which LuaJIT would map in unchecked.
    if content:byte(1) == 27 then return nil, "precompiled chunk rejected" end
    local chunk, err
    if setfenv then
        chunk, err = loadstring(content, "@" .. path)
        if chunk then setfenv(chunk, {}) end
    else
        chunk, err = load(content, "@" .. path, "t", {})
    end
    if not chunk then return nil, err end
    local ok, data = pcall(chunk)
    if not ok then return nil, data end
    return data
end

--- Read a Lua settings file and return its data table.
-- Returns the table plus an `ok` flag. `ok` is false only when the file exists but could
-- not be read or parsed: callers must then skip the category, since an unreadable file is
-- indistinguishable from an empty one and writing it back would truncate it.
local function loadSettingsData(path, category)
    if path == READER_SETTINGS then
        -- Settings changed this session live only in memory; without this the diff would
        -- be computed against a stale file and the merge would revert them.
        G_reader_settings:flush()
    end
    if lfs.attributes(path, "mode") ~= "file" then
        return {}, true
    end
    local data, err = loadDump(path)
    if type(data) == "table" then
        return data, true
    end
    logger.warn("SettingSync: cannot parse", path, err)
    return {}, false
end

--- True when `path` is the category's own on-device file rather than a downloaded copy.
local function isSourcePath(path, category)
    return path == (category and category.local_path or READER_SETTINGS)
end

--- Cached contents of the on-device source files, for the duration of one sync run.
-- A dozen categories share settings.reader.lua, and re-reading it per category means a
-- G_reader_settings:flush() (a full write + fsync) and a dofile() each time. Worse, a
-- flush between two category merges writes the in-memory copy back over the merge just
-- made, so caching is what keeps consecutive merges into the same file consistent.
local source_cache = {}

--- Drop the cache at the start of each user-initiated sync, so a run always begins from
-- what is actually on disk.
local function resetSourceCache()
    source_cache = {}
end

local function readSettingsData(path, category)
    if not isSourcePath(path, category) then
        return loadSettingsData(path, category)
    end
    local cached = source_cache[path]
    if not cached then
        local data, ok = loadSettingsData(path, category)
        cached = { data = data, ok = ok }
        source_cache[path] = cached
    end
    return cached.data, cached.ok
end

--- Write a Lua settings table to a file.
local function writeSettingsData(path, data, category)
    local util = require("util")
    if isSourcePath(path, category) then
        source_cache[path] = { data = data, ok = true }
    end
    local dir = path:match("(.*/)")
    if dir and lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    util.writeToFile(dump(data, nil, true), path, true, true)
end

--- Mirror a category's merged keys into the live G_reader_settings object.
-- Needed for settings.reader.lua: without this, G_reader_settings:flush() on
-- app exit overwrites the file we just wrote, discarding the sync.
local function syncToGlobalSettings(merged_data)
    for key, val in pairs(merged_data) do
        G_reader_settings:saveSetting(key, val)
    end
end

--- Set when a pull rewrote a file some other plugin already has open as a LuaSettings
--- object. Only settings.reader.lua is mirrored back into memory (syncToGlobalSettings);
--- for every other file the new values are invisible until restart, and the owning plugin
--- overwrites them when it flushes on exit.
local restart_needed = false

local function showRestartNoticeIfNeeded()
    if not restart_needed then return end
    restart_needed = false
    UIManager:askForRestart(_("Some downloaded settings live in files KOReader already has open. Restart to apply them — otherwise they will be overwritten when you exit."))
end

--- Merge pulled category data back into its source file.
-- Purely additive: pulled keys are added or overwritten, everything already in the file is
-- left alone. A setting that exists only on this device therefore survives even a force
-- pull -- the cloud copy is a backup of another device's setup, not an inventory of what
-- this one is allowed to keep, and the catch-all categories own enough of
-- settings.reader.lua that deleting by absence would reset the device wholesale.
-- Returns false without writing if the source file could not be read.
local function mergeCategoryIntoFile(category, merged_data)
    local path = category.local_path or READER_SETTINGS
    local full, ok = readSettingsData(path, category)
    if not ok then return false end
    for key, val in pairs(merged_data) do
        full[key] = val
    end
    writeSettingsData(path, full, category)
    if path == READER_SETTINGS then
        syncToGlobalSettings(merged_data)
    else
        restart_needed = true
    end
    return true
end


--- Select this device's identity from cloud profiles or enter a custom name.
function SettingSync:showDeviceSelector(touchmenu_instance)
    local server = self.settings:readSetting("sync_server")
    if not server then
        self:showDeviceNameDialog(touchmenu_instance)
        return
    end

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text = _("Reading device list from cloud…"),
            timeout = 1,
        })
        UIManager:scheduleIn(0.5, function()
            local names = Devices.listFromCloud(server)
            local current = Devices.currentName(self.settings)
            local buttons = {}
            for _i, name in ipairs(names) do
                local selected_name = name
                table.insert(buttons, {
                    {
                        text = selected_name == current
                            and string.format(_("%s (this device)"), selected_name)
                            or selected_name,
                        callback = function()
                            Devices.setName(self.settings, selected_name)
                            UIManager:close(self._device_selector)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            UIManager:show(Notification:new{
                                text = _("Device name saved."),
                                timeout = 2,
                            })
                        end,
                    },
                })
            end
            table.insert(buttons, {
                {
                    text = _("Enter a custom name…"),
                    callback = function()
                        UIManager:close(self._device_selector)
                        self:showDeviceNameDialog(touchmenu_instance)
                    end,
                },
            })
            table.insert(buttons, {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(self._device_selector) end,
                },
            })

            self._device_selector = ButtonDialog:new{
                title = _("Select this device"),
                buttons = buttons,
            }
            UIManager:show(self._device_selector)
        end)
    end)
end

--- Show the free-text fallback for creating or renaming a device profile.
function SettingSync:showDeviceNameDialog(touchmenu_instance)
    local current = Devices.currentName(self.settings)
    local dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        input = current ~= Devices.DEFAULT_NAME and current or "",
        input_hint = _("e.g. Kindle PW5"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = dialog:getInputText()
                        name = name and name:match("^%s*(.-)%s*$")
                        Devices.setName(self.settings, (name ~= "") and name or nil)
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        UIManager:show(Notification:new{
                            text = _("Device name saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Human label for a file in the cloud, so the device list reads like "What to sync"
--- rather than like a directory listing. A name this device has no category for (a plugin
--- it does not have installed) falls back to the file name.
function SettingSync:remoteLabel(remote_name)
    for _, cat in ipairs(self:getAllCategories()) do
        if cat.remote_name == remote_name then return cat.label end
    end
    return remote_name
end

--- List every device profile in the cloud folder, with what each has backed up.
function SettingSync:showCloudDevices()
    local server = self.settings:readSetting("sync_server")
    if not server then return end

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text = _("Reading device list from cloud…"),
            timeout = 1,
        })
        UIManager:scheduleIn(0.5, function()
            local names = Devices.listFromCloud(server)
            if #names == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("No device backups found in the cloud yet. Sync once to create one."),
                    timeout = 3,
                })
                return
            end

            local my_name = Devices.currentName(self.settings)
            local kv_pairs = {}
            -- Not "for _, name": `_` is the gettext alias, and shadowing it breaks the
            -- _() calls in this loop body.
            for _i, name in ipairs(names) do
                local labels = {}
                for _j, file in ipairs(Devices.listUploads(server, name)) do
                    table.insert(labels, self:remoteLabel(file))
                end
                table.sort(labels)
                table.insert(kv_pairs, {
                    name == my_name and string.format(_("%s (this device)"), name) or name,
                    #labels > 0 and string.format(_("%d groups"), #labels) or _("nothing uploaded"),
                    callback = function()
                        UIManager:show(TextViewer:new{
                            title = name,
                            text = #labels > 0 and table.concat(labels, "\n")
                                or _("This device has not uploaded anything yet."),
                        })
                    end,
                })
            end

            UIManager:show(KeyValuePage:new{
                title = _("Devices in cloud"),
                kv_pairs = kv_pairs,
            })
        end)
    end)
end

--- Show a dialog letting the user choose which remote device to compare against.
-- Calls callback(device_name) with the chosen name.
function SettingSync:showDevicePicker(available_devices, callback)
    local my_name = Devices.currentName(self.settings)
    local buttons = {}

    for _, name in ipairs(available_devices) do
        if name ~= my_name then
            local n = name  -- capture
            table.insert(buttons, {
                {
                    text = n,
                    callback = function()
                        UIManager:close(self._device_picker)
                        callback(n)
                    end,
                },
            })
        end
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(self._device_picker) end,
        },
    })

    self._device_picker = ButtonDialog:new{
        title = _("Select source device"),
        buttons = buttons,
    }
    UIManager:show(self._device_picker)
end

--- Entry point for syncing a single category.
-- Downloads device list from cloud, then triggers diff workflow.
function SettingSync:syncCategory(category)
    NetworkMgr:runWhenOnline(function()
        local server = self.settings:readSetting("sync_server")
        if not server then return end

        UIManager:show(InfoMessage:new{
            text = _("Reading device list from cloud…"),
            timeout = 1,
        })
        UIManager:scheduleIn(0.5, function()
            local devices = Devices.listFromCloud(server)
            local my_name = Devices.currentName(self.settings)
            local others = {}
            for _, name in ipairs(devices) do
                if name ~= my_name then table.insert(others, name) end
            end

            if #others == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("No backups from other devices were found in the cloud."),
                    timeout = 3,
                })
                return
            end
            self:showDevicePicker(others, function(target)
                self:_doCategorySync(category, target)
            end)
        end)
    end)
end

--- Download and diff a category's settings against a remote device.
function SettingSync:_doCategorySync(category, target_device_name)
    ensureTempDir()
    local remote_path = Devices.remotePath(target_device_name, category.remote_name)
    local temp_path = TEMP_DIR .. "/" .. target_device_name .. "_" .. category.remote_name:gsub("/", "_")

    UIManager:show(InfoMessage:new{
        text = _("Downloading settings from cloud…"),
        timeout = 1,
    })

    UIManager:scheduleIn(0.5, function()
        resetSourceCache()
        local ok = self:downloadFromCloud(remote_path, temp_path)
        if not ok then
            os.remove(temp_path)
            UIManager:show(InfoMessage:new{
                text = string.format(_("Could not download %s from device %s."),
                    category.label, target_device_name),
                timeout = 3,
            })
            return
        end

        -- Extract local category data from the category's source file
        local source_path = category.local_path or READER_SETTINGS
        local full_local, readable = readSettingsData(source_path, category)
        local remote_data = Categories.extract(readSettingsData(temp_path, category), category)
        os.remove(temp_path)
        if not readable then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Could not read the local file for %s. Skipping it."), category.label),
                timeout = 3,
            })
            return
        end
        local local_data = Categories.extract(full_local, category)

        local diff = Diff.compare(local_data, remote_data)
        local changes = Diff.changesOnly(diff)

        if #changes == 0 then
            UIManager:show(InfoMessage:new{
                text = _("All settings are in sync!"),
                timeout = 3,
            })
            return
        end

        local my_name = Devices.currentName(self.settings)
        local label = string.format(_("Sync: %s"), category.label)
            .. " (" .. target_device_name .. " → " .. my_name .. ")"
            .. " — " .. #changes .. _(" changes")

        local viewer = DiffViewer:new{
            diff = diff,
            source_label = label,
            category = category,
            on_apply = function(selections)
                self:_applyCategorySelections(
                    category, local_data, remote_data, selections, target_device_name)
            end,
        }
        UIManager:show(viewer)
    end)
end

--- Apply category diff selections: push uploads to cloud, pull merges into local file.
function SettingSync:_applyCategorySelections(
        category, local_data, remote_data, selections, target_device_name)
    local has_pulls, has_pushes = false, false
    for _, sel in ipairs(selections) do
        if sel.direction == "pull" then has_pulls = true end
        if sel.direction == "push" then has_pushes = true end
    end

    if has_pulls then
        local merged_category = Diff.applySelections(local_data, selections)
        if mergeCategoryIntoFile(category, merged_category) then
            logger.info("SettingSync: pulled", category.id, "category from", target_device_name)
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Could not read the local file for %s. Nothing was changed."), category.label),
                timeout = 3,
            })
        end
    end

    if has_pushes then
        -- Upload the merged category data to  devices/{my_name}/{remote_name}
        local my_name = Devices.currentName(self.settings)
        local push_sels = {}
        for _, sel in ipairs(selections) do
            if sel.direction == "push" then table.insert(push_sels, sel) end
        end
        local merged_remote = Diff.applySelections(remote_data, push_sels)
        ensureTempDir()
        local temp_path = TEMP_DIR .. "/" .. my_name .. "_" .. category.remote_name:gsub("/", "_") .. ".push"
        writeSettingsData(temp_path, merged_remote, category)
        local remote_path = Devices.remotePath(my_name, category.remote_name)
        self:ensureRemoteDirs(remote_path)
        local ok = self:uploadToCloud(temp_path, remote_path)
        os.remove(temp_path)
        if ok then
            logger.info("SettingSync: pushed", category.id, "to cloud as", my_name)
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to upload %s to cloud."), category.label),
                timeout = 3,
            })
        end
    end

    showRestartNoticeIfNeeded()
end

--- Show the cloud service configuration dialog (uses the cloudstorage plugin's picker).
function SettingSync:showCloudConfig(touchmenu_instance)
    local cs = get_cloud_sync(self.ui)
    if not cs then
        UIManager:show(InfoMessage:new{
            text = _("The Cloud storage plugin is required for syncing but isn't available."),
        })
        return
    end
    local server = self.settings:readSetting("sync_server")
    if server then
        -- Already configured: show info + edit/delete
        local FFIUtil = require("ffi/util")
        local T = FFIUtil.template
        local type_label = server.type == "dropbox" and " (Dropbox)" or " (WebDAV)"

        local dialogue
        dialogue = ButtonDialog:new{
            title = T(_("Cloud service:\n%1\n\nSync folder:\n%2"),
                server.name .. type_label, cs.getReadablePath(server)),
            buttons = {
                {
                    {
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(dialogue)
                            UIManager:show(ConfirmBox:new{
                                text = _("Remove cloud service configuration?"),
                                ok_text = _("Remove"),
                                ok_callback = function()
                                    self.settings:delSetting("sync_server")
                                    self.settings:flush()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Change"),
                        callback = function()
                            UIManager:close(dialogue)
                            self:openCloudPicker(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialogue)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialogue)
    else
        self:openCloudPicker(touchmenu_instance)
    end
end

function SettingSync:openCloudPicker(touchmenu_instance)
    local cs = get_cloud_sync(self.ui)
    if not cs then
        UIManager:show(InfoMessage:new{
            text = _("The Cloud storage plugin is required for syncing but isn't available."),
        })
        return
    end
    cs:onShowCloudStorageList(function(sv)
        self.settings:saveSetting("sync_server", sv)
        self.settings:flush()
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(Notification:new{
            text = _("Cloud service configured."),
            timeout = 2,
        })
    end)
end
--- Download a single file from cloud. Returns true on success.
function SettingSync:downloadFromCloud(remote_name, local_dest)
    local server = self.settings:readSetting("sync_server")
    if not server then return false end

    local WebDavApi = get_webdav_api()
    local file_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    file_url = WebDavApi:getJoinedPath(file_url, remote_name)

    local code = WebDavApi:downloadFile(file_url, server.username, server.password, local_dest)
    return code == 200
end

--- Upload a single file to cloud. Returns true on success.
function SettingSync:uploadToCloud(local_path, remote_name)
    local server = self.settings:readSetting("sync_server")
    if not server then return false end

    local WebDavApi = get_webdav_api()
    local file_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    file_url = WebDavApi:getJoinedPath(file_url, remote_name)

    local code = WebDavApi:uploadFile(file_url, server.username, server.password, local_path)
    return type(code) == "number" and code >= 200 and code < 300
end

--- Ensure remote directories exist for a given remote path.
function SettingSync:ensureRemoteDirs(remote_name)
    local server = self.settings:readSetting("sync_server")
    if not server then return end

    local WebDavApi = get_webdav_api()
    local base_url = WebDavApi:getJoinedPath(server.address, server.url or "")

    -- Split remote_name into path segments and create each directory
    local segments = {}
    for seg in remote_name:gmatch("([^/]+)") do
        table.insert(segments, seg)
    end
    -- Remove the filename (last segment)
    table.remove(segments)

    local current_path = base_url
    for _, seg in ipairs(segments) do
        current_path = WebDavApi:getJoinedPath(current_path, seg)
        -- MKCOL is idempotent for existing dirs (returns 405, which is fine)
        WebDavApi:createFolder(current_path .. "/", server.username, server.password)
    end
end

--- Full diff & sync workflow: download all sources from cloud, diff, show UI.
function SettingSync:diffAndSync()
    NetworkMgr:runWhenOnline(function()
        self:_doDiffAndSync()
    end)
end

function SettingSync:_doDiffAndSync()
    ensureTempDir()
    local categories = self:getEnabledCategories()
    if #categories == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No categories enabled. Open \"What to sync\" to choose."),
            timeout = 3,
        })
        return
    end

    -- Download all remote files to temp dir
    UIManager:show(InfoMessage:new{
        text = _("Downloading settings from cloud…"),
        timeout = 1,
    })

    -- We schedule the actual work to let the InfoMessage render
    UIManager:scheduleIn(0.5, function()
        resetSourceCache()
        local all_diffs = {}
        local my_name = Devices.currentName(self.settings)

        for _, cat in ipairs(categories) do
            local remote_path = Devices.remotePath(my_name, cat.remote_name)
            local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_")
            local ok = self:downloadFromCloud(remote_path, temp_path)

            local full_local, readable = readSettingsData(cat.local_path or READER_SETTINGS, cat)
            local local_data = Categories.extract(full_local, cat)
            local remote_data = ok and Categories.extract(readSettingsData(temp_path, cat), cat) or {}

            local diff = Diff.compare(local_data, remote_data)
            local changes = Diff.changesOnly(diff)

            if readable and #changes > 0 then
                table.insert(all_diffs, {
                    source = cat,
                    diff = diff,
                    changes = changes,
                    local_data = local_data,
                    remote_data = remote_data,
                })
            end

            os.remove(temp_path)
        end

        if #all_diffs == 0 then
            UIManager:show(InfoMessage:new{
                text = _("All settings are in sync!"),
                timeout = 3,
            })
            return
        end

        -- Show diff viewer for first source with changes, then chain to next
        self:showDiffChain(all_diffs, 1)
    end)
end

--- Show diff viewers one at a time for each source with changes.
function SettingSync:showDiffChain(all_diffs, index, skipped)
    skipped = skipped or 0
    if index > #all_diffs then
        UIManager:show(Notification:new{
            text = skipped > 0
                and string.format(_("Sync complete. %d group(s) skipped."), skipped)
                or _("Sync complete."),
            timeout = 2,
        })
        showRestartNoticeIfNeeded()
        return
    end

    local item = all_diffs[index]
    local viewer = DiffViewer:new{
        diff = item.diff,
        source_label = item.source.label .. " (" .. #item.changes .. _(" changes") .. ")",
        category = item.source,
        on_apply = function(selections)
            self:applyDiffSelections(item, selections)
            -- Continue to next source
            self:showDiffChain(all_diffs, index + 1, skipped)
        end,
        on_skip = function()
            self:showDiffChain(all_diffs, index + 1, skipped + 1)
        end,
        on_cancel = function()
            UIManager:show(Notification:new{
                text = string.format(_("Sync stopped. %d group(s) left unchanged."),
                    #all_diffs - index + 1),
                timeout = 3,
            })
            showRestartNoticeIfNeeded()
        end,
    }
    UIManager:show(viewer)
end

--- Apply user selections for a single source.
function SettingSync:applyDiffSelections(item, selections)
    local has_pulls = false
    local has_pushes = false

    for _, sel in ipairs(selections) do
        if sel.direction == "pull" then has_pulls = true end
        if sel.direction == "push" then has_pushes = true end
    end

    if has_pulls then
        -- Apply pull: merge remote values into local
        local merged = Diff.applySelections(item.local_data, selections)
        -- Category-aware merge-back: preserves unrelated keys and excluded keys.
        if mergeCategoryIntoFile(item.source, merged) then
            logger.info("SettingSync: pulled changes into", item.source.local_path)
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Could not read the local file for %s. Nothing was changed."), item.source.label),
                timeout = 3,
            })
        end
    end

    if has_pushes then
        -- Apply push: merge local values into remote and upload
        local push_selections = {}
        for _, sel in ipairs(selections) do
            if sel.direction == "push" then
                table.insert(push_selections, sel)
            end
        end
        local merged_remote = Diff.applySelections(item.remote_data, push_selections)
        -- Write to temp, upload, clean up
        ensureTempDir()
        local temp_path = TEMP_DIR .. "/" .. item.source.remote_name:gsub("/", "_") .. ".push"
        writeSettingsData(temp_path, merged_remote, item.source)
        local my_name = Devices.currentName(self.settings)
        local remote_path = Devices.remotePath(my_name, item.source.remote_name)
        self:ensureRemoteDirs(remote_path)
        local ok = self:uploadToCloud(temp_path, remote_path)
        os.remove(temp_path)
        if ok then
            logger.info("SettingSync: pushed changes to cloud for", item.source.remote_name)
        else
            logger.warn("SettingSync: failed to push", item.source.remote_name)
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to upload %s to cloud."), item.source.label),
                timeout = 3,
            })
        end
    end
end

--- Quick sync: push or pull all settings without diff UI.
function SettingSync:quickSync(direction)
    local msg = direction == "push"
        and _("Upload all local settings to cloud? This will overwrite cloud copies.")
        or  _("Download all settings from cloud? This will overwrite local copies.")

    UIManager:show(ConfirmBox:new{
        text = msg,
        ok_text = direction == "push" and _("Push") or _("Pull"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                self:_doQuickSync(direction)
            end)
        end,
    })
end

function SettingSync:_doQuickSync(direction)
    ensureTempDir()
    resetSourceCache()
    local categories = self:getEnabledCategories()
    local my_name = Devices.currentName(self.settings)
    local success_count = 0
    local fail_count = 0

    for _, cat in ipairs(categories) do
        local remote_path = Devices.remotePath(my_name, cat.remote_name)
        if direction == "push" then
            local full_local, readable = readSettingsData(cat.local_path or READER_SETTINGS, cat)
            local cat_data = Categories.extract(full_local, cat)
            if not readable then
                fail_count = fail_count + 1
            elseif next(cat_data) then
                local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_") .. ".push"
                writeSettingsData(temp_path, cat_data, cat)
                self:ensureRemoteDirs(remote_path)
                if self:uploadToCloud(temp_path, remote_path) then
                    success_count = success_count + 1
                else
                    fail_count = fail_count + 1
                end
                os.remove(temp_path)
            end
        elseif direction == "pull" then
            local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_")
            if self:downloadFromCloud(remote_path, temp_path) then
                local remote_data = Categories.extract(readSettingsData(temp_path, cat), cat)
                if next(remote_data) then
                    if mergeCategoryIntoFile(cat, remote_data) then
                        success_count = success_count + 1
                    else
                        fail_count = fail_count + 1
                    end
                end
            else
                fail_count = fail_count + 1
            end
            os.remove(temp_path)
        end
    end

    local text
    if fail_count == 0 then
        text = string.format(_("Synced %d settings group(s) successfully."), success_count)
    else
        text = string.format(_("Synced %d settings group(s), %d failed."), success_count, fail_count)
    end
    UIManager:show(Notification:new{
        text = text,
        timeout = 3,
    })
    showRestartNoticeIfNeeded()
end

--- Smart one-tap sync: merges one-sided changes automatically and only asks
--- the user when the same setting was changed on both the device and the cloud.
function SettingSync:syncNow()
    if not self.settings:readSetting("sync_server") then
        self:showCloudConfig()
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:_doSyncNow()
    end)
end

function SettingSync:_doSyncNow()
    ensureTempDir()
    local categories = self:getEnabledCategories()
    if #categories == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Nothing is selected to sync. Open \"What to sync\" to choose."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{ text = _("Syncing…"), timeout = 1 })
    UIManager:scheduleIn(0.5, function()
        resetSourceCache()
        local items = {}
        local conflicts = {}
        local my_name = Devices.currentName(self.settings)

        for _, cat in ipairs(categories) do
            local remote_path = Devices.remotePath(my_name, cat.remote_name)
            local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_")
            local ok = self:downloadFromCloud(remote_path, temp_path)
            local full_local, readable = readSettingsData(cat.local_path or READER_SETTINGS, cat)
            local local_data = Categories.extract(full_local, cat)
            local remote_data = ok and Categories.extract(readSettingsData(temp_path, cat), cat) or {}
            os.remove(temp_path)

            if readable then
                local item = {
                    source = cat,
                    local_data = local_data,
                    remote_data = remote_data,
                    selections = {},
                }
                for _, entry in ipairs(Diff.compare(local_data, remote_data)) do
                    if entry.status == Diff.ADDED then
                        -- local only → upload
                        table.insert(item.selections, { entry = entry, direction = "push" })
                    elseif entry.status == Diff.REMOVED then
                        -- cloud only → download
                        table.insert(item.selections, { entry = entry, direction = "pull" })
                    elseif entry.status == Diff.MODIFIED then
                        table.insert(conflicts, { item = item, entry = entry })
                    end
                end
                table.insert(items, item)
            end
        end

        if #conflicts == 0 then
            self:_finishSyncNow(items)
        else
            self:_resolveConflicts(items, conflicts)
        end
    end)
end

--- Apply every collected selection, stamp the sync time, and report a summary.
function SettingSync:_finishSyncNow(items)
    local n_push, n_pull = 0, 0
    for _, item in ipairs(items) do
        for _, sel in ipairs(item.selections) do
            if sel.direction == "push" then n_push = n_push + 1
            elseif sel.direction == "pull" then n_pull = n_pull + 1 end
        end
        if #item.selections > 0 then
            self:applyDiffSelections(item, item.selections)
        end
    end

    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()

    local text
    if n_push == 0 and n_pull == 0 then
        text = _("Everything is already up to date.")
    else
        text = string.format(_("Sync complete: %d uploaded, %d downloaded."), n_push, n_pull)
    end
    UIManager:show(Notification:new{ text = text, timeout = 3 })
    showRestartNoticeIfNeeded()
end

--- Ask the user how to resolve settings changed on both sides.
function SettingSync:_resolveConflicts(items, conflicts)
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            _("%d setting(s) were changed on both this device and the cloud.\n\nWhich version should be kept?"),
            #conflicts),
        buttons = {
            {{
                text = _("Keep this device"),
                callback = function()
                    UIManager:close(dialog)
                    for _, c in ipairs(conflicts) do
                        table.insert(c.item.selections, { entry = c.entry, direction = "push" })
                    end
                    self:_finishSyncNow(items)
                end,
            }},
            {{
                text = _("Keep cloud"),
                callback = function()
                    UIManager:close(dialog)
                    for _, c in ipairs(conflicts) do
                        table.insert(c.item.selections, { entry = c.entry, direction = "pull" })
                    end
                    self:_finishSyncNow(items)
                end,
            }},
            {{
                text = _("Choose for each…"),
                callback = function()
                    UIManager:close(dialog)
                    self:_reviewConflicts(items, conflicts)
                end,
            }},
            {{
                text = _("Skip them"),
                callback = function()
                    UIManager:close(dialog)
                    -- Conflicts stay as they are on both sides; one-sided changes still sync.
                    self:_finishSyncNow(items)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Apply the automatic (one-sided) changes, then open the diff viewer limited
--- to the conflicting keys so the user can pick a direction per item.
function SettingSync:_reviewConflicts(items, conflicts)
    for _, item in ipairs(items) do
        if #item.selections > 0 then
            self:applyDiffSelections(item, item.selections)
        end
    end

    local per_item = {}
    local order = {}
    for _, c in ipairs(conflicts) do
        if not per_item[c.item] then
            per_item[c.item] = {}
            table.insert(order, c.item)
        end
        table.insert(per_item[c.item], c.entry)
    end

    local all_diffs = {}
    for _, item in ipairs(order) do
        local entries = per_item[item]
        table.insert(all_diffs, {
            source = item.source,
            diff = entries,
            changes = entries,
            local_data = item.local_data,
            remote_data = item.remote_data,
        })
    end

    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()
    self:showDiffChain(all_diffs, 1)
end

return SettingSync