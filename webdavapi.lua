-- Vendored copy of KOReader's WebDAV API.
--
-- KOReader removed the standalone frontend/apps/cloudstorage/webdavapi module
-- (folded into plugins/cloudstorage.koplugin/providers/webdav.lua, which is not
-- requirable from other plugins). Older KOReader versions still ship the original
-- module, so prefer that (it tracks upstream fixes) and only fall back to this
-- self-contained copy when it's gone.
local ok, upstream = pcall(require, "apps/cloudstorage/webdavapi")
if ok then
    return upstream
end

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local DocumentRegistry = require("document/documentregistry")

local WebDavApi = {}

-- Trim leading & trailing slashes from string `s` (based on util.trim)
function WebDavApi:trim_slashes(s)
    local from = s:match"^/*()"
    return from > #s and "" or s:match(".*[^/]", from)
end

-- Trim trailing slashes from string `s` (based on util.rtrim)
function WebDavApi:rtrim_slashes(s)
    local n = #s
    while n > 0 and s:find("^/", n) do
        n = n - 1
    end
    return s:sub(1, n)
end

-- Append path to address with a slash separator, trimming any unwanted slashes in the process.
function WebDavApi:getJoinedPath(address, path)
    local path_encoded = util.urlEncode(path, "/") or ""
    local sane_path = self.trim_slashes(self, path_encoded)
    local sane_address = self.rtrim_slashes(self, address)
    return sane_address .. "/" .. sane_path
end

-- List a WebDAV folder's contents (files and sub-folders).
function WebDavApi:listFolder(address, user, pass, folder_path)
    local path = folder_path or ""
    path = self.trim_slashes(self, path)
    address = self.rtrim_slashes(self, address)
    local webdav_url = address .. "/" .. util.urlEncode(path, "/")
    if webdav_url:sub(-1) ~= "/" then
        webdav_url = webdav_url .. "/"
    end
    local webdav_url_path = self.trim_slashes(self, util.urlDecode(webdav_url:match("^https?://[^/]*(.*)$") or webdav_url))

    local sink = {}
    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/></a:prop></a:propfind>]]
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url      = webdav_url,
        method   = "PROPFIND",
        headers  = {
            ["Content-Type"]   = "application/xml",
            ["Depth"]          = "1",
            ["Content-Length"] = #data,
        },
        user     = user,
        password = pass,
        source   = ltn12.source.string(data),
        sink     = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if headers == nil or not code or code < 200 or code > 299 then
        logger.dbg("WebDavApi:listFolder: Request failed:", status or code)
        return nil
    end

    local res_data = table.concat(sink)
    if res_data == "" then return {} end

    local items = {}
    for item in res_data:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local item_fullpath = item:match("<[^:]*:href[^>]*>(.*)</[^:]*:href>")
        local item_name = ffiutil.basename(util.htmlEntitiesToUtf8(util.urlDecode(item_fullpath)))
        local is_current_dir = self.trim_slashes(self, item_fullpath) == webdav_url_path
        local is_not_collection = item:find("<[^:]*:resourcetype%s*/>") or
                                  item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
        local item_path = path .. "/" .. item_name
        local item_filesize = item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")

        if item:find("<[^:]*:collection[^<]*/>") or item:find("<[^:]*:collection>%s*</[^:]*:collection>") then
            if not is_current_dir then
                table.insert(items, {
                    text = item_name .. "/",
                    url = item_path,
                    type = "folder",
                })
            end
        elseif is_not_collection and (DocumentRegistry:hasProvider(item_name) or (G_reader_settings and G_reader_settings:isTrue("show_unsupported"))) then
            table.insert(items, {
                text = item_name,
                url = item_path,
                type = "file",
                filesize = tonumber(item_filesize),
            })
        end
    end
    return items
end

function WebDavApi:downloadFile(file_url, user, pass, local_path, progress_callback)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    logger.dbg("WebDavApi: downloading file: ", file_url)
    local handle = ltn12.sink.file(io.open(local_path, "w"))
    if progress_callback then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_callback)
    end
    local code, headers, status = socket.skip(1, http.request {
        url      = file_url,
        method   = "GET",
        sink     = handle,
        user     = user,
        password = pass,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("WebDavApi: cannot download file:", status or code)
        logger.dbg("WebDavApi: Response headers:", headers)
    end
    return code, headers and headers.etag
end

function WebDavApi:uploadFile(file_url, user, pass, local_path, etag)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    -- If-Match uses strong comparison (RFC 7232 §3.1), so a weak validator
    -- (W/"…", returned e.g. for gzip-compressed responses) can never match and
    -- would 412 forever. Strip the weak prefix; proxies keep the same value.
    if type(etag) == "string" then
        etag = etag:gsub("^%s*[Ww]/", "")
    end
    local code, _, status = socket.skip(1, http.request{
        url      = file_url,
        method   = "PUT",
        source   = ltn12.source.file(io.open(local_path, "r")),
        user     = user,
        password = pass,
        headers  = {
            ["Content-Length"] = lfs.attributes(local_path, "size"),
            ["If-Match"] = etag,
        },
    })
    socketutil:reset_timeout()
    if type(code) == "number" and code >= 200 and code <= 299 then
        code = 200
    else
        logger.warn("WebDavApi: cannot upload file:", status or code)
    end
    return code
end

function WebDavApi:deleteFile(file_url, user, pass)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url      = file_url,
        method   = "DELETE",
        user     = user,
        password = pass,
    })
    socketutil:reset_timeout()
    if type(code) == "number" and code >= 200 and code <= 299 then
        return true
    end
    logger.warn("WebDavApi: cannot delete file:", status or code)
end

function WebDavApi:createFolder(folder_url, user, pass)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url      = folder_url,
        method   = "MKCOL",
        user     = user,
        password = pass,
    })
    socketutil:reset_timeout()
    if type(code) == "number" and code >= 200 and code <= 299 then
        return true
    end
    logger.warn("WebDavApi: cannot create folder:", status or code)
end

return WebDavApi
