# AGENTS.md

Guidance for AI coding agents working in `settingsync.koplugin`. Read this before touching any file.

## Global rule: search KOReader core first

Before writing ANY code including a new Lua utility, UI pattern, or API call, **always search
the sibling `koreader/` folder** for existing implementations.
KOReader ships a large frontend library (`frontend/`, `plugins/`) — reuse its helpers, widgets,
and conventions rather than reinventing them.

## What this plugin is

A KOReader plugin that **synchronizes KOReader settings across devices via WebDAV** with
per-key diffing and selective sync. It reads and writes `.lua` settings files (LuaSettings
format), downloads the remote copies into a temp dir for comparison, then lets the user
choose which individual keys to push or pull before applying changes.

## File map

- `main.lua` — plugin entry point: menu registration, WebDAV upload/download orchestration,
  quick push/pull, source discovery (`SOURCES`, `discoverPluginSettings`,
  `discoverPluginConfigs`), scope settings, per-key excluded-key filtering, device profile
  management, and category-based sync workflow.
- `settingsync_diff.lua` — **pure, stateless** diff engine. `Diff.compare(local, remote)`
  returns an array of `{key, status, local_val, remote_val}` entries sorted by key name.
  Status values: `ADDED`, `REMOVED`, `MODIFIED`, `UNCHANGED`.
- `settingsync_ui.lua` — `DiffViewer` widget: scrollable per-key diff table, tap to toggle
  push/pull per row, **Push all** / **Pull all** bulk actions, and **Apply** callback.
  Accepts an optional `category` field; when set, key names and values are rendered using
  the category's human-readable labels and value formatters instead of raw Lua dumps.
- `settingsync_categories.lua` — category definitions. Each category describes a logical
  group of settings keys that can be synced independently (e.g., `Categories.GESTURES`
  extracts gesture keys from `settings.reader.lua`).  Provides `Categories.extract()`,
  `Categories.keyLabel()`, and `Categories.formatValue()` helpers used by `DiffViewer`.
- `settingsync_devices.lua` — device profile utilities. `Devices.currentName()` reads the
  user-assigned device name from plugin settings.  `Devices.remotePath()` builds cloud
  paths like `devices/{device_name}/{remote_name}`.  `Devices.listFromCloud()` discovers
  device names by listing the `devices/` folder on the WebDAV server.
- `insert_menu.lua` — injects the `"settingsync"` entry into both the File Manager and
  Reader tool menus, after the `"statistics"` item.
- `settingsync_gettext.lua` — pure-Lua gettext subset (adapted from `assistant.koplugin`).
  Loads `.po` files from `l10n/` at runtime.
- `l10n/zh_CN/koreader.po`, `l10n/zh_TW/koreader.po` — Simplified and Traditional Chinese
  translation catalogs.
- `_meta.lua` — plugin metadata (name / version / description).
- `.luacheckrc` — Luacheck config: `std = "luajit"`, `globals = {"G_reader_settings"}`,
  line-length warning 631 suppressed.

## Sync source model

Syncable files are described by **source tables** with these fields:

```lua
{
    id           = string,   -- unique identifier, e.g. "global" or "plugin:foo.lua"
    label        = string,   -- display name shown in menus
    description  = string,   -- human-readable description (translated via _())
    local_path   = string,   -- absolute path on device
    remote_name  = string,   -- relative path on the WebDAV server
    exclude_keys = {string}, -- per-source list of keys never synced
}
```

- `SOURCES` (static) defines `settings.reader.lua` with the device-specific exclusion list.
- `discoverPluginSettings()` scans `SETTINGS_DIR` for `*.lua` files (excluding
  `settingsync.lua` itself).
- `discoverPluginConfigs()` scans installed plugins for `configuration.lua` files.
- The **sync scope** setting (`sync_scope.global`, `sync_scope.plugin_settings`,
  `sync_scope.plugin_configs`) gates which source groups are active.

Never add device-specific keys to the sync path — add them to the `exclude_keys` list of the
relevant source instead.

## Category-based sync model

Categories are defined in `settingsync_categories.lua`.  Each category:

```lua
{
    id               = string,   -- e.g. "gestures"
    label            = string,   -- translated display name, e.g. _("Gestures")
    description      = string,   -- translated description
    is_device_specific = bool,   -- if true, stored under devices/{device_name}/ in cloud
    remote_name      = string,   -- filename in cloud, e.g. "gestures.lua"
    keys             = {string}, -- keys extracted from settings.reader.lua
    key_labels       = {[key]=string},  -- translated human-readable names per key
    value_formatters = {[key]=fn},      -- optional per-key value display functions
}
```

Category-based sync workflow in `main.lua`:
1. User selects a category (e.g., **Sync: Gestures**) from the **Sync by category** submenu.
2. If multiple device profiles exist in cloud, a device picker appears.
3. `_doCategorySync(category, target_device_name)` downloads
   `devices/{target_device}/{category.remote_name}` and diffs it against the locally
   extracted category keys from `settings.reader.lua`.
4. `DiffViewer` shows the diff with human-readable key labels and formatted values.
5. On Apply: pulls merge into `settings.reader.lua`; pushes upload to
   `devices/{my_device_name}/{category.remote_name}`.

## Device profile model

Device profiles are managed by `settingsync_devices.lua`:
- The current device name is stored in `settingsync.lua` as `device_name`.
  Default: `"default"`.
- Device-specific category files live at `devices/{device_name}/{remote_name}` in the
  cloud folder.  `Devices.remotePath(name, remote_name)` builds this path.
- `Devices.listFromCloud(server)` lists the `devices/` folder to discover known devices.
- Users set their device name via **Device: {name}** in the SettingSync menu.

## Diff / apply contract

`settingsync_diff.lua` is a **pure function module** — it must never require UI or
side-effectful modules.

- `Diff.compare(local_data, remote_data)` — returns sorted array of diff entries.
- `Diff.changesOnly(entries)` — filters to `ADDED | REMOVED | MODIFIED` only.
- `Diff.deepEqual(a, b)` — recursive value equality (used to classify `UNCHANGED`).
- `Diff.prettyValue(val)` — single-line human-readable preview for display.

`DiffViewer` calls `Diff.compare` then drives `on_apply(selections)` back into `main.lua`.
`selections` is `{[entry_index] = "pull"|"push"|nil}`.

## i18n rule

All user-visible strings **must** go through `settingsync_gettext.lua` (aliased as `_`).

- Load at the top of each Lua file that shows UI: `local _ = require("settingsync_gettext")`.
- Wrap every user-visible string: `_("Your string here")`.
- When you add a new string, add it to **both** `l10n/zh_CN/koreader.po` and
  `l10n/zh_TW/koreader.po`.
- Never hardcode a translated string directly in Lua files.

## Build / test / lint

- **No build step** — Lua files run directly in KOReader.
- **Lint**: `luacheck -q .` from inside `settingsync.koplugin/` (the `.luacheckrc` is
  already configured).
- **i18n check**: `python check_i18n.py` from inside `settingsync.koplugin/`.
  Scans every `_()` call in all `.lua` files and verifies each string has a `msgid` entry in
  **both** `l10n/zh_CN/koreader.po` and `l10n/zh_TW/koreader.po`. Exit 0 = clean.
  **Run this after every change that touches a `.lua` file or a `.po` file.**
- **Manual test**: configure WebDAV on two KOReader instances, change a setting on one,
  use Diff & Sync on the other, and confirm the diff view correctly shows the changed key
  and that applying push/pull updates the right file.

## Change checklist for agents

When editing diff logic in `settingsync_diff.lua`:

1. `Diff.compare` must remain a pure function — no I/O, no global state.
2. The status constants (`ADDED`, `REMOVED`, `MODIFIED`, `UNCHANGED`) must not be renamed
   without updating all consumers (`settingsync_ui.lua`, `main.lua`).
3. `changesOnly` must filter to non-`UNCHANGED` entries only — `DiffViewer` relies on this
   to detect the "no differences" early-exit case.

When editing sync orchestration in `main.lua`:

4. `exclude_keys` filtering must be applied **before** upload and **after** download — keys
   on the exclusion list must never travel in either direction.
5. Scope gates (`sync_scope`) must be checked in `getSources()`, not scattered in callers.
6. Cloud files must be downloaded to `TEMP_DIR` and cleaned up after the operation — never
   write directly to `SETTINGS_DIR` without going through the merge/apply path.

When adding a new category to `settingsync_categories.lua`:

7. Add the category table to `Categories.ALL`.
8. Use `_("English string")` for all `key_labels` values so check_i18n.py finds them.
9. Mark `is_device_specific = true` for settings that differ across device types.
10. All keys must live in a single source file (currently all categories use
    `settings.reader.lua`).

When adding UI strings:

11. Wrap with `_()` and add to both `l10n/zh_CN/koreader.po` and `l10n/zh_TW/koreader.po`.
12. **Run `python check_i18n.py` and fix all errors before committing.**
    Exit 0 = clean. Any missing msgid is a hard blocker.
