--[[--
Device profile management for SettingSync.

A device profile is a user-assigned name for the current device
(e.g. "Kindle PW5", "Kobo Elipsa", "PC").  Device-specific settings are
stored in the cloud under  devices/{device_name}/  so each device keeps
its own copy and can be compared against any other device.
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local logger = require("logger")

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
    local WebDavApi = require("webdavapi")
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

local PROPFIND_BODY =
    [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/></a:prop></a:propfind>]]

local function trimSlashes(s)
    return (s:gsub("^/+", ""):gsub("/+$", ""))
end

--- Depth-1 PROPFIND of `url`, returning { files = {name…}, folders = {name…} }, or nil.
-- WebDavApi:listFolder() cannot answer this: it drops every file KOReader has no reader
-- for, and everything this plugin uploads is a .lua.
local function propfindNames(url, user, pass)
    if url:sub(-1) ~= "/" then url = url .. "/" end
    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, http.request{
        url      = url,
        method   = "PROPFIND",
        headers  = {
            ["Content-Type"]   = "application/xml",
            ["Depth"]          = "1",
            ["Content-Length"] = #PROPFIND_BODY,
        },
        user     = user,
        password = pass,
        source   = ltn12.source.string(PROPFIND_BODY),
        sink     = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if headers == nil or type(code) ~= "number" or code < 200 or code > 299 then
        logger.dbg("SettingSync: PROPFIND failed for", url, code)
        return nil
    end

    local self_path = trimSlashes(util.urlDecode(url:match("^https?://[^/]*(.*)$") or url))
    local result = { files = {}, folders = {} }
    for item in table.concat(sink):gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local href = item:match("<[^:]*:href[^>]*>(.-)</[^:]*:href>") or ""
        local path = trimSlashes(util.htmlEntitiesToUtf8(util.urlDecode(href)))
        local name = path:match("([^/]+)$")
        -- The collection itself is always part of a Depth-1 response.
        if name and path ~= self_path then
            local is_folder = item:find("<[^:]*:collection[^<]*/>")
                or item:find("<[^:]*:collection>%s*</[^:]*:collection>")
            table.insert(is_folder and result.folders or result.files, name)
        end
    end
    return result
end

--- List what a device has uploaded, as remote names relative to its folder
--- ("gestures.lua", "plugin_configs/assistant_configuration.lua"). Sub-folders are walked
--- within a request budget, so a stray deep tree in the cloud cannot stall the UI.
function Devices.listUploads(server, device_name)
    local WebDavApi = require("webdavapi")
    local base_url = WebDavApi:getJoinedPath(server.address, server.url or "")
    local device_url = WebDavApi:getJoinedPath(base_url, Devices.remotePath(device_name, ""))

    local files, budget = {}, 8
    local function walk(url, prefix)
        if budget <= 0 then return end
        budget = budget - 1
        local listing = propfindNames(url, server.username, server.password)
        if not listing then return end
        for _, name in ipairs(listing.files) do
            table.insert(files, prefix .. name)
        end
        for _, name in ipairs(listing.folders) do
            walk(WebDavApi:getJoinedPath(url, name), prefix .. name .. "/")
        end
    end
    walk(device_url, "")

    table.sort(files)
    return files
end

return Devices
