--[[--
Settings diff engine for SettingSync.

Compares two Lua settings tables at the per-key level and produces
a structured diff that the UI can present for selective sync.
--]]

local dump = require("dump")

local Diff = {}

--- Status constants for diff entries.
Diff.ADDED       = "added"       -- key exists only on one side
Diff.REMOVED     = "removed"     -- key exists only on the other side
Diff.MODIFIED    = "modified"    -- key exists on both sides with different values
Diff.UNCHANGED   = "unchanged"   -- key exists on both sides with the same value

--- Deep-compare two values for equality.
-- Tables are compared recursively by value.  Other types use ==.
-- @param a any
-- @param b any
-- @return boolean
function Diff.deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end

    -- Both tables: compare keys
    for k, v in pairs(a) do
        if not Diff.deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Drop a trailing UTF-8 sequence that a byte-wise cut left incomplete, so truncating
--- never emits a broken character.
local function trimPartialUtf8(s)
    local tail = s:match("([\194-\244][\128-\191]*)$")
    if not tail then return s end
    local lead = tail:byte(1)
    local needed = lead < 0xE0 and 2 or (lead < 0xF0 and 3 or 4)
    if #tail >= needed then return s end
    return s:sub(1, #s - #tail)
end

--- Produce a human-readable rendering of a value.
-- Tables are serialized via dump(); scalars are tostring()'d.
-- Values are complete by default; callers may request an explicit byte limit.
-- @param val any
-- @param max_len number  (optional)
-- @return string
function Diff.prettyValue(val, max_len)
    local s
    if type(val) == "table" then
        s = dump(val, nil, true)
    elseif type(val) == "string" then
        s = string.format("%q", val)
    else
        s = tostring(val)
    end
    if max_len and #s > max_len then
        s = trimPartialUtf8(s:sub(1, max_len)) .. "…"
    end
    return s
end

local json

local function decodeJsonTable(val)
    if type(val) ~= "string" or not val:match("^%s*[%[{]") then return nil end
    if not json then
        local ok, module = pcall(require, "json")
        if not ok then return nil end
        json = module
    end
    local ok, decoded = pcall(json.decode, val)
    if ok and type(decoded) == "table" then return decoded end
end

--- Return values normalized for structured display and whether either is table-shaped.
-- JSON strings are decoded only for rendering; sync operations retain the originals.
function Diff.displayValues(local_val, remote_val)
    local local_display = type(local_val) == "table" and local_val or decodeJsonTable(local_val)
    local remote_display = type(remote_val) == "table" and remote_val or decodeJsonTable(remote_val)
    local structured = local_display ~= nil or remote_display ~= nil
    return local_display or local_val, remote_display or remote_val, structured
end

local function sortedUnionKeys(a, b)
    local keys = {}
    local seen = {}
    for key in pairs(a or {}) do
        seen[key] = true
        table.insert(keys, key)
    end
    for key in pairs(b or {}) do
        if not seen[key] then table.insert(keys, key) end
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) and (type(left) == "number" or type(left) == "string") then
            return left < right
        end
        return type(left) .. tostring(left) < type(right) .. tostring(right)
    end)
    return keys
end

local function appendPath(path, key)
    if type(key) == "string" and key:match("^[%a_][%w_]*$") then
        return path == "" and key or path .. "." .. key
    end
    local segment = type(key) == "string" and string.format("%q", key) or tostring(key)
    return path .. "[" .. segment .. "]"
end

local function appendValueRows(rows, local_val, remote_val, path)
    if Diff.deepEqual(local_val, remote_val) then return end
    local local_is_table = type(local_val) == "table"
    local remote_is_table = type(remote_val) == "table"
    if local_is_table and remote_is_table
            or local_is_table and remote_val == nil
            or remote_is_table and local_val == nil then
        local keys = sortedUnionKeys(
            local_is_table and local_val or nil,
            remote_is_table and remote_val or nil)
        if #keys == 0 then
            table.insert(rows, {
                path = path,
                local_val = local_val,
                remote_val = remote_val,
            })
            return
        end
        for _, key in ipairs(keys) do
            appendValueRows(rows,
                local_is_table and local_val[key] or nil,
                remote_is_table and remote_val[key] or nil,
                appendPath(path, key))
        end
        return
    end
    table.insert(rows, {
        path = path,
        local_val = local_val,
        remote_val = remote_val,
    })
end

--- Flatten table-shaped values into aligned leaf rows for side-by-side display.
-- Both sides use the same nested key path; unchanged leaves are omitted.
function Diff.valueRows(local_val, remote_val)
    local rows = {}
    appendValueRows(rows, local_val, remote_val, "")
    return rows
end

--- Compare two settings tables and return a list of per-key diff entries.
--
-- Each entry is a table:
--   { key = string, status = Diff.*, local_val = any, remote_val = any }
--
-- @param local_data  table  The local settings data
-- @param remote_data table  The remote (cloud) settings data
-- @return table  Array of diff entries, sorted by key name
function Diff.compare(local_data, remote_data)
    local_data = local_data or {}
    remote_data = remote_data or {}
    local result = {}
    local seen = {}

    for k, lv in pairs(local_data) do
        seen[k] = true
        local rv = remote_data[k]
        if rv == nil then
            table.insert(result, {
                key = k,
                status = Diff.ADDED,
                local_val = lv,
                remote_val = nil,
            })
        elseif Diff.deepEqual(lv, rv) then
            table.insert(result, {
                key = k,
                status = Diff.UNCHANGED,
                local_val = lv,
                remote_val = rv,
            })
        else
            table.insert(result, {
                key = k,
                status = Diff.MODIFIED,
                local_val = lv,
                remote_val = rv,
            })
        end
    end

    for k, rv in pairs(remote_data) do
        if not seen[k] then
            table.insert(result, {
                key = k,
                status = Diff.REMOVED,
                local_val = nil,
                remote_val = rv,
            })
        end
    end

    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

--- Filter a diff to only changed entries.
-- @param diff table  As returned by compare()
-- @return table  Array of diff entries where status ~= UNCHANGED
function Diff.changesOnly(diff)
    local changes = {}
    for _, entry in ipairs(diff) do
        if entry.status ~= Diff.UNCHANGED then
            table.insert(changes, entry)
        end
    end
    return changes
end

--- Apply selected diff entries to produce a merged table.
--
-- Starts from base_data.  For each selected entry:
--   direction == "pull": take remote_val  (cloud → local)
--   direction == "push": take local_val   (local → cloud)
--
-- @param base_data  table   The starting data to merge into (deep-copied)
-- @param selections table   Array of { entry = diff_entry, direction = "pull"|"push" }
-- @return table  The merged settings data
function Diff.applySelections(base_data, selections)
    -- Shallow copy of base
    local merged = {}
    for k, v in pairs(base_data) do
        merged[k] = v
    end
    for _, sel in ipairs(selections) do
        local key = sel.entry.key
        if sel.direction == "pull" then
            merged[key] = sel.entry.remote_val
        elseif sel.direction == "push" then
            merged[key] = sel.entry.local_val
        end
    end
    return merged
end

return Diff
