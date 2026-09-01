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

--- Produce a human-readable preview of a value.
-- Tables are serialized via dump(); scalars are tostring()'d.
-- Long strings are truncated.
-- @param val any
-- @param max_len number  (optional, default 120)
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
    -- Collapse to single line for display
    s = s:gsub("\n%s*", " ")
    max_len = max_len or 120
    if #s > max_len then
        s = trimPartialUtf8(s:sub(1, max_len)) .. "…"
    end
    return s
end

--- Split file text into lines, dropping carriage returns so a file last written on
--- another platform does not diff as entirely changed.
local function splitLines(text)
    local lines = {}
    local pos = 1
    while true do
        local nl = text:find("\n", pos, true)
        if not nl then
            local last = text:sub(pos)
            if last ~= "" then lines[#lines + 1] = (last:gsub("\r$", "")) end
            break
        end
        lines[#lines + 1] = (text:sub(pos, nl - 1):gsub("\r$", ""))
        pos = nl + 1
    end
    return lines
end

--- Cap on the LCS table size. Beyond it the changed region is reported as one block
--- replacement instead: still a correct diff, but without the quadratic cost of aligning
--- thousands of lines on a device with no memory to spare.
local DIFF_CELL_BUDGET = 250000

--- Classic LCS length table for a[a0..a1] against b[b0..b1], used to backtrack an
--- alignment that keeps as many unchanged lines as possible.
local function lcsTable(a, b, a0, n, b0, m)
    local c = {}
    c[0] = {}
    for j = 0, m do c[0][j] = 0 end
    for i = 1, n do
        local row, prev_row = {}, c[i - 1]
        row[0] = 0
        local ai = a[a0 + i - 1]
        for j = 1, m do
            if ai == b[b0 + j - 1] then
                row[j] = prev_row[j - 1] + 1
            else
                local up, left = prev_row[j], row[j - 1]
                row[j] = up >= left and up or left
            end
        end
        c[i] = row
    end
    return c
end

local function appendAlignment(ops, c, a, b, a0, n, b0, m)
    local rev, i, j = {}, n, m
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and a[a0 + i - 1] == b[b0 + j - 1] then
            rev[#rev + 1] = { sign = " ", text = a[a0 + i - 1] }
            i, j = i - 1, j - 1
        elseif j > 0 and (i == 0 or c[i][j - 1] >= c[i - 1][j]) then
            rev[#rev + 1] = { sign = "+", text = b[b0 + j - 1] }
            j = j - 1
        else
            rev[#rev + 1] = { sign = "-", text = a[a0 + i - 1] }
            i = i - 1
        end
    end
    for k = #rev, 1, -1 do ops[#ops + 1] = rev[k] end
end

--- Line-diff two whole-file values (raw_file / dir_files categories), the way git does:
--- "-" is a line only the local file has, "+" a line only the cloud copy has.
-- A missing side (added/removed file) is treated as empty text, so its lines all show up
-- on one side.
-- @return table  { ops = {{sign=" "|"-"|"+", text=string}, …}, added = n, removed = n }
function Diff.textDiff(local_val, remote_val)
    local a = splitLines(type(local_val) == "string" and local_val or "")
    local b = splitLines(type(remote_val) == "string" and remote_val or "")

    -- Trim the identical head and tail first: a typical edit touches a few lines, and this
    -- keeps the LCS table down to the region that actually changed.
    local head = 0
    while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
    local tail = 0
    while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do tail = tail + 1 end

    local ops = {}
    for i = 1, head do ops[#ops + 1] = { sign = " ", text = a[i] } end

    local n, m = #a - tail - head, #b - tail - head
    if n > 0 and m > 0 and n * m <= DIFF_CELL_BUDGET then
        appendAlignment(ops, lcsTable(a, b, head + 1, n, head + 1, m), a, b, head + 1, n, head + 1, m)
    else
        for i = head + 1, head + n do ops[#ops + 1] = { sign = "-", text = a[i] } end
        for j = head + 1, head + m do ops[#ops + 1] = { sign = "+", text = b[j] } end
    end

    for i = #a - tail + 1, #a do ops[#ops + 1] = { sign = " ", text = a[i] } end

    local added, removed = 0, 0
    for _, op in ipairs(ops) do
        if op.sign == "+" then added = added + 1
        elseif op.sign == "-" then removed = removed + 1 end
    end
    return { ops = ops, added = added, removed = removed }
end

--- Reduce a textDiff() to unified-diff hunks: changed lines plus `context` unchanged lines
--- around them, each run preceded by an `@@ -local +cloud @@` header (sign "@").
-- @return table  Array of { sign = " "|"-"|"+"|"@", text = string }
function Diff.unifiedHunks(diff, context)
    context = context or 3
    local ops = diff.ops
    local keep = {}
    for i, op in ipairs(ops) do
        if op.sign ~= " " then
            for j = math.max(1, i - context), math.min(#ops, i + context) do keep[j] = true end
        end
    end

    local out = {}
    local a_line, b_line, i = 1, 1, 1
    while i <= #ops do
        if keep[i] then
            local j, a_count, b_count = i, 0, 0
            while j <= #ops and keep[j] do
                if ops[j].sign ~= "+" then a_count = a_count + 1 end
                if ops[j].sign ~= "-" then b_count = b_count + 1 end
                j = j + 1
            end
            out[#out + 1] = {
                sign = "@",
                -- git prints line 0 for an empty side, e.g. a file that exists on one side only.
                text = string.format("@@ -%d,%d +%d,%d @@",
                    a_count > 0 and a_line or 0, a_count,
                    b_count > 0 and b_line or 0, b_count),
            }
            for k = i, j - 1 do
                out[#out + 1] = { sign = ops[k].sign, text = ops[k].text }
            end
            a_line, b_line, i = a_line + a_count, b_line + b_count, j
        else
            if ops[i].sign ~= "+" then a_line = a_line + 1 end
            if ops[i].sign ~= "-" then b_line = b_line + 1 end
            i = i + 1
        end
    end
    return out
end

--- Render unified hunks back into plain text for a full-screen viewer.
function Diff.unifiedText(hunks)
    local parts = {}
    for _, line in ipairs(hunks) do
        parts[#parts + 1] = line.sign == "@" and line.text or (line.sign .. line.text)
    end
    return table.concat(parts, "\n")
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
