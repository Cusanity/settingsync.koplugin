--[[--
Device profile management for SettingSync.

A device profile is a user-assigned name for the current device
(e.g. "Kindle PW5", "Kobo Elipsa", "PC").  Device-specific settings are
stored in the cloud under  devices/{device_name}/  so each device keeps
its own copy and can be compared against any other device.
--]]

local Devices = {}

Devices.DEFAULT_NAME = "default"

--- Return the current device name stored in plugin settings.
function Devices.currentName(plugin_settings)
    return plugin_settings:readSetting("device_name") or Devices.DEFAULT_NAME
end

--- Save the current device name to plugin settings.
function Devices.setName(plugin_settings, name)
    plugin_settings:saveSetting("device_name", name)
    plugin_settings:flush()
end

--- Build the remote path for a device-specific category file.
-- e.g. Devices.remotePath("kindle", "gestures.lua") → "devices/kindle/gestures.lua"
function Devices.remotePath(device_name, remote_name)
    return "devices/" .. device_name .. "/" .. remote_name
end

--- List device names found in the cloud by listing the  devices/  folder.
-- Returns a sorted list of device name strings, or {} on any error.
function Devices.listFromCloud(server)
    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local base_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    local devices_url = WebDavApi:getJoinedPath(base_url, "devices")
    local ok, items = pcall(
        WebDavApi.listFolder, WebDavApi,
        devices_url, server.username, server.password, "")
    if not ok or type(items) ~= "table" then return {} end
    local names = {}
    for _, item in ipairs(items) do
        if item.type == "folder" or item.is_folder then
            local name = (item.text or item.name or ""):gsub("/$", "")
            if name ~= "" and name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
    end
    table.sort(names)
    return names
end

return Devices
