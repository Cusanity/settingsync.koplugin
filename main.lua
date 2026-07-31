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

function SettingSync:init()
    self.settings = LuaSettings:open(PLUGIN_SETTINGS_PATH)
    self.ui.menu:registerToMainMenu(self)
end

--- Return the categories the user has enabled for sync (defaults to all on).
function SettingSync:getEnabledCategories()
    local scope = self.settings:readSetting("sync_categories", {})
    local enabled = {}
    for _, cat in ipairs(Categories.ALL) do
        if scope[cat.id] ~= false then
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
                    text = _("Compares this device with the cloud and merges the differences"
                        .. " automatically. If the same setting was changed in both places,"
                        .. " you decide which version to keep."),
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
            callback = function() self:showDeviceNameDialog() end,
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
    local function toggle(id)
        scope[id] = (scope[id] == false) and nil or false
        self.settings:saveSetting("sync_categories", scope)
        self.settings:flush()
    end
    local items = {}
    for _, cat in ipairs(Categories.ALL) do
        local c = cat
        table.insert(items, {
            text = c.label,
            help_text = c.description,
            checked_func = function() return scope[c.id] ~= false end,
            callback = function() toggle(c.id) end,
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
    for _, cat in ipairs(Categories.ALL) do
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
        lfs.mkdir(dir)
    end
    util.writeToFile(dump(data, nil, true), path, true, true)
end

--- Merge pulled category data back into its source file.
-- For partial-key categories this preserves all unrelated keys in the file.
-- Excluded keys (device-specific) are always kept from local.
local function mergeCategoryIntoFile(category, merged_data)
    local full = readSettingsData(category.local_path)
    local excluded = {}
    if category.exclude_keys then
        for _, ek in ipairs(category.exclude_keys) do excluded[ek] = true end
    end
    for key in pairs(full) do
        if Categories.owns(category, key) and not excluded[key] then
            full[key] = nil
        end
    end
    for key, val in pairs(merged_data) do
        full[key] = val
    end
    writeSettingsData(category.local_path, full)
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
        local source_path = category.local_path or (DATA_DIR .. "/settings.reader.lua")
        local full_local = readSettingsData(source_path)
        local merged_category = Diff.applySelections(local_data, selections)
        -- Replace this category's portion of the file: drop its old keys, then
        -- write back the merged set (covers keys/key_prefix/all_keys modes).
        for key in pairs(full_local) do
            if Categories.owns(category, key) then
                full_local[key] = nil
            end
        end
        for key, val in pairs(merged_category) do
            full_local[key] = val
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
        local all_diffs = {}
        local my_name = Devices.currentName(self.settings)

        for _, cat in ipairs(categories) do
            local remote_path = Devices.remotePath(my_name, cat.remote_name)
            local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_")
            local ok = self:downloadFromCloud(remote_path, temp_path)

            local full_local = readSettingsData(cat.local_path)
            local local_data = Categories.extract(full_local, cat)
            local remote_data = ok and readSettingsData(temp_path) or {}

            if cat.exclude_keys then
                for _, ek in ipairs(cat.exclude_keys) do
                    local_data[ek] = nil
                    remote_data[ek] = nil
                end
            end

            local diff = Diff.compare(local_data, remote_data)
            local changes = Diff.changesOnly(diff)

            if #changes > 0 then
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
        source_label = item.source.label .. " (" .. #item.changes .. _(" changes") .. ")",
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
        -- Category-aware merge-back: preserves unrelated keys and excluded keys.
        mergeCategoryIntoFile(item.source, merged)
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
    local categories = self:getEnabledCategories()
    local my_name = Devices.currentName(self.settings)
    local success_count = 0
    local fail_count = 0

    for _, cat in ipairs(categories) do
        local remote_path = Devices.remotePath(my_name, cat.remote_name)
        if direction == "push" then
            local full_local = readSettingsData(cat.local_path)
            local cat_data = Categories.extract(full_local, cat)
            if cat.exclude_keys then
                for _, ek in ipairs(cat.exclude_keys) do cat_data[ek] = nil end
            end
            if next(cat_data) then
                local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_") .. ".push"
                writeSettingsData(temp_path, cat_data)
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
                local remote_data = readSettingsData(temp_path)
                if next(remote_data) then
                    if cat.exclude_keys then
                        for _, ek in ipairs(cat.exclude_keys) do remote_data[ek] = nil end
                    end
                    mergeCategoryIntoFile(cat, remote_data)
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
        local items = {}
        local conflicts = {}
        local my_name = Devices.currentName(self.settings)

        for _, cat in ipairs(categories) do
            local remote_path = Devices.remotePath(my_name, cat.remote_name)
            local temp_path = TEMP_DIR .. "/" .. cat.remote_name:gsub("/", "_")
            local ok = self:downloadFromCloud(remote_path, temp_path)
            local full_local = readSettingsData(cat.local_path)
            local local_data = Categories.extract(full_local, cat)
            local remote_data = ok and readSettingsData(temp_path) or {}
            os.remove(temp_path)

            if cat.exclude_keys then
                for _, ek in ipairs(cat.exclude_keys) do
                    local_data[ek] = nil
                    remote_data[ek] = nil
                end
            end

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

require("insert_menu")

return SettingSync