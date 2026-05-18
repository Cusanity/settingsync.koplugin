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

--- Produce a human-readable preview of a value.
-- Tables are serialized via dump(); scalars are tostring()'d.
-- Long strings are truncated.
-- @param val any
-- @param max_len number  (optional, default 120)
-- @return string
function Diff.prettyValue(val)
    local s
    if type(val) == "table" then
        s = dump(val, nil, true)
    elseif type(val) == "string" then
        s = string.format("%q", val)
    else
        s = tostring(val)
    end
    -- Collapse to single line for display
    s = s:gsub("\n%s*", " ")
    return s
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
