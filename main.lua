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
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local SyncService = require("frontend/apps/cloudstorage/syncservice")
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

local SETTINGS_DIR = DataStorage:getSettingsDir()
local DATA_DIR = DataStorage:getDataDir()
local PLUGIN_SETTINGS_PATH = SETTINGS_DIR .. "/settingsync.lua"

-- Temp directory for downloaded cloud files during diff
local TEMP_DIR = DATA_DIR .. "/cache/settingsync"

local SettingSync = WidgetContainer:extend{
    name = "settingsync",
    is_doc_only = false,
}

--- Syncable source definitions.
-- Each source describes a settings file that can be synced.
local SOURCES = {
    {
        id = "global",
        label = "settings.reader.lua",
        description = _("Global KOReader settings"),
        local_path = DATA_DIR .. "/settings.reader.lua",
        remote_name = "settings.reader.lua",
        -- Keys to exclude from sync (device-specific)
        exclude_keys = {
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
    },
}

--- Dynamically discover plugin settings files in the settings/ directory.
local function discoverPluginSettings()
    local sources = {}
    if lfs.attributes(SETTINGS_DIR, "mode") ~= "directory" then
        return sources
    end
    for filename in lfs.dir(SETTINGS_DIR) do
        if filename:match("%.lua$") and filename ~= "settingsync.lua" then
            table.insert(sources, {
                id = "plugin:" .. filename,
                label = "settings/" .. filename,
                description = string.format(_("Plugin settings: %s"), filename:gsub("%.lua$", "")),
                local_path = SETTINGS_DIR .. "/" .. filename,
                remote_name = "settings/" .. filename,
                exclude_keys = {},
            })
        end
    end
    table.sort(sources, function(a, b) return a.label < b.label end)
    return sources
end

--- Discover plugin configuration.lua files.
local function discoverPluginConfigs()
    local sources = {}
    local plugins_dir = DATA_DIR .. "/plugins"
    if lfs.attributes(plugins_dir, "mode") ~= "directory" then
        return sources
    end
    for dirname in lfs.dir(plugins_dir) do
        if dirname:match("%.koplugin$") then
            local config_path = plugins_dir .. "/" .. dirname .. "/configuration.lua"
            if lfs.attributes(config_path, "mode") == "file" then
                table.insert(sources, {
                    id = "config:" .. dirname,
                    label = "plugins/" .. dirname .. "/configuration.lua",
                    description = string.format(_("Plugin config: %s"), dirname:gsub("%.koplugin$", "")),
                    local_path = config_path,
                    remote_name = "configs/" .. dirname .. "/configuration.lua",
                    exclude_keys = {},
                })
            end
        end
    end
    table.sort(sources, function(a, b) return a.label < b.label end)
    return sources
end

--- Get all syncable sources based on user's scope settings.
function SettingSync:getSources()
    local sources = {}
    local scope = self.settings:readSetting("sync_scope", {
        global = true,
        plugin_settings = true,
        plugin_configs = true,
    })

    if scope.global then
        for _, s in ipairs(SOURCES) do
            table.insert(sources, s)
        end
    end
    if scope.plugin_settings then
        for _, s in ipairs(discoverPluginSettings()) do
            table.insert(sources, s)
        end
    end
    if scope.plugin_configs then
        for _, s in ipairs(discoverPluginConfigs()) do
            table.insert(sources, s)
        end
    end
    return sources
end

function SettingSync:init()
    self.settings = LuaSettings:open(PLUGIN_SETTINGS_PATH)
    self.ui.menu:registerToMainMenu(self)
end

function SettingSync:addToMainMenu(menu_items)
    menu_items.settingsync = {
        text = _("SettingSync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    local server = self.settings:readSetting("sync_server")
                    if server then
                        return _("Cloud service: ") .. server.name
                    end
                    return _("Configure cloud service")
                end,
                callback = function(touchmenu_instance)
                    self:showCloudConfig(touchmenu_instance)
                end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text_func = function()
                    return string.format(_("Device: %s"),
                        Devices.currentName(self.settings))
                end,
                callback = function()
                    self:showDeviceNameDialog()
                end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text = _("Sync by category"),
                enabled_func = function()
                    return self.settings:readSetting("sync_server") ~= nil
                end,
                sub_item_table_func = function()
                    return self:buildCategoryMenu()
                end,
            },
            {
                text = _("Diff & sync settings…"),
                callback = function()
                    self:diffAndSync()
                end,
                enabled_func = function()
                    return self.settings:readSetting("sync_server") ~= nil
                end,
            },
            {
                text = _("Quick push all to cloud"),
                callback = function()
                    self:quickSync("push")
                end,
                enabled_func = function()
                    return self.settings:readSetting("sync_server") ~= nil
                end,
            },
            {
                text = _("Quick pull all from cloud"),
                callback = function()
                    self:quickSync("pull")
                end,
                enabled_func = function()
                    return self.settings:readSetting("sync_server") ~= nil
                end,
                separator = true,
            },
            {
                text = _("Sync scope"),
                sub_item_table = self:buildScopeMenu(),
            },
        },
    }
end

function SettingSync:buildScopeMenu()
    local scope = self.settings:readSetting("sync_scope", {
        global = true,
        plugin_settings = true,
        plugin_configs = true,
    })
    return {
        {
            text = _("Global settings (settings.reader.lua)"),
            checked_func = function() return scope.global end,
            callback = function()
                scope.global = not scope.global
                self.settings:saveSetting("sync_scope", scope)
                self.settings:flush()
            end,
        },
        {
            text = _("Plugin settings (settings/*.lua)"),
            checked_func = function() return scope.plugin_settings end,
            callback = function()
                scope.plugin_settings = not scope.plugin_settings
                self.settings:saveSetting("sync_scope", scope)
                self.settings:flush()
            end,
        },
        {
            text = _("Plugin configs (configuration.lua)"),
            checked_func = function() return scope.plugin_configs end,
            callback = function()
                scope.plugin_configs = not scope.plugin_configs
                self.settings:saveSetting("sync_scope", scope)
                self.settings:flush()
            end,
        },
    }
end

--- Ensure the temp directory exists.
local function ensureTempDir()
    if lfs.attributes(TEMP_DIR, "mode") ~= "directory" then
        lfs.mkdir(TEMP_DIR)
    end
end

--- Read a Lua settings file and return its data table.
-- Returns empty table if file doesn't exist or is unreadable.
local function readSettingsData(path)
    if lfs.attributes(path, "mode") ~= "file" then
        return {}
    end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

--- Write a Lua settings table to a file.
local function writeSettingsData(path, data)
    local util = require("util")
    local dir = path:match("(.*/)")
    if dir and lfs.attributes(dir, "mode") ~= "directory" then
        os.execute('mkdir -p "' .. dir .. '"')
    end
    util.writeToFile(dump(data, nil, true), path, true, true)
end

--- Build per-category menu items for the "Sync by category" submenu.
function SettingSync:buildCategoryMenu()
    local items = {}
    for _i, category in ipairs(Categories.ALL) do
        local cat = category  -- capture for closure
        table.insert(items, {
            text = string.format(_("Sync: %s"), cat.label),
            callback = function()
                self:syncCategory(cat)
            end,
        })
    end
    return items
end

--- Show the InputDialog for setting/changing the device name.
function SettingSync:showDeviceNameDialog()
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
                        name = name and name:match("^%s*(.-)%s*$")  -- trim
                        if name and name ~= "" then
                            Devices.setName(self.settings, name)
                            UIManager:show(Notification:new{
                                text = _("Device name saved."),
                                timeout = 2,
                            })
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Show a dialog letting the user choose which remote device to compare against.
-- Calls callback(device_name) with the chosen name.
function SettingSync:showDevicePicker(available_devices, callback)
    local my_name = Devices.currentName(self.settings)
    local buttons = {}

    -- Always offer "My backup" as first option.
    table.insert(buttons, {
        {
            text = string.format(_("My backup (%s)"), my_name),
            callback = function()
                UIManager:close(self._device_picker)
                callback(my_name)
            end,
        },
    })

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

        local devices = Devices.listFromCloud(server)
        local my_name = Devices.currentName(self.settings)

        -- If there are other devices available, let the user pick the source.
        local others = {}
        for _, n in ipairs(devices) do
            if n ~= my_name then table.insert(others, n) end
        end

        if #others > 0 then
            self:showDevicePicker(devices, function(target)
                self:_doCategorySync(category, target)
            end)
        else
            -- No other devices: compare against own backup.
            self:_doCategorySync(category, my_name)
        end
    end)
end

--- Download and diff a category's settings against a remote device.
function SettingSync:_doCategorySync(category, target_device_name)
    ensureTempDir()
    local remote_path = Devices.remotePath(target_device_name, category.remote_name)
    local temp_path = TEMP_DIR .. "/" .. target_device_name .. "_" .. category.remote_name

    UIManager:show(InfoMessage:new{
        text = _("Downloading settings from cloud…"),
        timeout = 1,
    })

    UIManager:scheduleIn(0.5, function()
        local ok = self:downloadFromCloud(remote_path, temp_path)

        -- Extract local category data from the category's source file
        local source_path = category.local_path or (DATA_DIR .. "/settings.reader.lua")
        local full_local = readSettingsData(source_path)
        local local_data = Categories.extract(full_local, category)
        local remote_data = ok and readSettingsData(temp_path) or {}
        os.remove(temp_path)

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
            .. " — " .. #changes .. _(" changes)")

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
        local source_path = category.local_path or (DATA_DIR .. "/settings.reader.lua")
        local full_local = readSettingsData(source_path)
        local merged_category = Diff.applySelections(local_data, selections)
        for _, key in ipairs(category.keys) do
            if merged_category[key] ~= nil then
                full_local[key] = merged_category[key]
            end
        end
        writeSettingsData(source_path, full_local)
        logger.info("SettingSync: pulled", category.id, "category from", target_device_name)
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
        local temp_path = TEMP_DIR .. "/" .. my_name .. "_" .. category.remote_name .. ".push"
        writeSettingsData(temp_path, merged_remote)
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
end

--- Show the cloud service configuration dialog (reuses KOReader's SyncService picker).
function SettingSync:showCloudConfig(touchmenu_instance)
    local server = self.settings:readSetting("sync_server")
    if server then
        -- Already configured: show info + edit/delete
        local FFIUtil = require("ffi/util")
        local T = FFIUtil.template
        local type_label = server.type == "dropbox" and " (Dropbox)" or " (WebDAV)"

        local dialogue
        dialogue = ButtonDialog:new{
            title = T(_("Cloud service:\n%1\n\nSync folder:\n%2"),
                server.name .. type_label, SyncService.getReadablePath(server)),
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
    local sync_settings = SyncService:new{}
    sync_settings.onClose = function(this)
        UIManager:close(this)
    end
    sync_settings.onConfirm = function(sv)
        self.settings:saveSetting("sync_server", sv)
        self.settings:flush()
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(Notification:new{
            text = _("Cloud service configured."),
            timeout = 2,
        })
    end
    UIManager:show(sync_settings)
end
--- Download a single file from cloud. Returns true on success.
function SettingSync:downloadFromCloud(remote_name, local_dest)
    local server = self.settings:readSetting("sync_server")
    if not server then return false end

    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local file_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    file_url = WebDavApi:getJoinedPath(file_url, remote_name)

    local code = WebDavApi:downloadFile(file_url, server.username, server.password, local_dest)
    return code == 200
end

--- Upload a single file to cloud. Returns true on success.
function SettingSync:uploadToCloud(local_path, remote_name)
    local server = self.settings:readSetting("sync_server")
    if not server then return false end

    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local file_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    file_url = WebDavApi:getJoinedPath(file_url, remote_name)

    local code = WebDavApi:uploadFile(file_url, server.username, server.password, local_path)
    return type(code) == "number" and code >= 200 and code < 300
end

--- Ensure remote directories exist for a given remote path.
function SettingSync:ensureRemoteDirs(remote_name)
    local server = self.settings:readSetting("sync_server")
    if not server then return end

    local WebDavApi = require("apps/cloudstorage/webdavapi")
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
    local sources = self:getSources()
    if #sources == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No settings sources enabled. Check Sync scope settings."),
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
        local all_diffs = {}

        for _, source in ipairs(sources) do
            local temp_path = TEMP_DIR .. "/" .. source.remote_name:gsub("/", "_")
            local ok = self:downloadFromCloud(source.remote_name, temp_path)

            local local_data = readSettingsData(source.local_path)
            local remote_data = ok and readSettingsData(temp_path) or {}

            -- Remove excluded keys
            if source.exclude_keys then
                for _, ek in ipairs(source.exclude_keys) do
                    local_data[ek] = nil
                    remote_data[ek] = nil
                end
            end

            local diff = Diff.compare(local_data, remote_data)
            local changes = Diff.changesOnly(diff)

            if #changes > 0 then
                table.insert(all_diffs, {
                    source = source,
                    diff = diff,
                    changes = changes,
                    local_data = local_data,
                    remote_data = remote_data,
                })
            end

            -- Clean up temp file
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
function SettingSync:showDiffChain(all_diffs, index)
    if index > #all_diffs then
        UIManager:show(Notification:new{
            text = _("Sync complete."),
            timeout = 2,
        })
        return
    end

    local item = all_diffs[index]
    local viewer = DiffViewer:new{
        diff = item.diff,
        source_label = item.source.label .. " (" .. #item.changes .. _(" changes)"),
        on_apply = function(selections)
            self:applyDiffSelections(item, selections)
            -- Continue to next source
            self:showDiffChain(all_diffs, index + 1)
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
        -- Re-add excluded keys from original file
        local original = readSettingsData(item.source.local_path)
        if item.source.exclude_keys then
            for _, ek in ipairs(item.source.exclude_keys) do
                if original[ek] ~= nil then
                    merged[ek] = original[ek]
                end
            end
        end
        writeSettingsData(item.source.local_path, merged)
        logger.info("SettingSync: pulled changes into", item.source.local_path)
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
        writeSettingsData(temp_path, merged_remote)
        self:ensureRemoteDirs(item.source.remote_name)
        local ok = self:uploadToCloud(temp_path, item.source.remote_name)
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
    local sources = self:getSources()
    local success_count = 0
    local fail_count = 0

    for _, source in ipairs(sources) do
        if direction == "push" then
            if lfs.attributes(source.local_path, "mode") == "file" then
                self:ensureRemoteDirs(source.remote_name)
                if self:uploadToCloud(source.local_path, source.remote_name) then
                    success_count = success_count + 1
                else
                    fail_count = fail_count + 1
                end
            end
        elseif direction == "pull" then
            local temp_path = TEMP_DIR .. "/" .. source.remote_name:gsub("/", "_")
            if self:downloadFromCloud(source.remote_name, temp_path) then
                local remote_data = readSettingsData(temp_path)
                if next(remote_data) then
                    -- Preserve excluded keys from local
                    if source.exclude_keys then
                        local original = readSettingsData(source.local_path)
                        for _, ek in ipairs(source.exclude_keys) do
                            if original[ek] ~= nil then
                                remote_data[ek] = original[ek]
                            end
                        end
                    end
                    writeSettingsData(source.local_path, remote_data)
                    success_count = success_count + 1
                end
            else
                fail_count = fail_count + 1
            end
            os.remove(temp_path)
        end
    end

    local text
    if fail_count == 0 then
        text = string.format(_("Synced %d settings file(s) successfully."), success_count)
    else
        text = string.format(_("Synced %d file(s), %d failed."), success_count, fail_count)
    end
    UIManager:show(Notification:new{
        text = text,
        timeout = 3,
    })
end

require("insert_menu")

return SettingSync
