# AGENTS.md

Guidance for AI coding agents working in `settingsync.koplugin`. Read this before touching any file.

## Global rule: search KOReader core first

Before writing ANY code — a new Lua utility, UI pattern, or API call — **always search
the sibling `koreader/` folder** for existing implementations.
KOReader ships a large frontend library (`frontend/`, `plugins/`) — reuse its helpers,
widgets, and conventions rather than reinventing them.

## What this plugin is

A KOReader plugin that **synchronizes KOReader settings across devices via WebDAV** with
per-key diffing and selective sync. It reads and writes `.lua` settings files (LuaSettings
format), downloads the remote copies into a temp dir for comparison, then lets the user
choose which individual keys to push or pull before applying changes.

## File map

- `main.lua` — plugin entry point: menu registration (`buildMainMenu`), WebDAV upload /
  download orchestration, quick push/pull, source discovery (`SOURCES`,
  `discoverPluginSettings`, `discoverPluginConfigs`), scope settings, per-key
  excluded-key filtering, device profile management, and category sync workflow.
- `settingsync_diff.lua` — **pure, stateless** diff engine. `Diff.compare(local, remote)`
  returns an array of `{key, status, local_val, remote_val}` entries sorted by key name.
  Status values: `ADDED`, `REMOVED`, `MODIFIED`, `UNCHANGED`.
- `settingsync_ui.lua` — `DiffViewer` widget: scrollable per-key diff table, tap to cycle
  push/pull per row, **Push all** / **Pull all** bulk actions, and **Apply** callback.
  Accepts an optional `category` field; when set, key names and values are rendered using
  the category's human-readable labels and value formatters instead of raw Lua dumps.
  Stores a `scrollable` reference so `refreshUI()` can preserve the scroll offset across
  row-tap redraws.
- `settingsync_categories.lua` — category definitions. Each category describes a logical
  group of settings keys that can be synced independently (e.g., `Categories.GESTURES`
  covers gesture keys from `settings/gestures.lua`). Provides `Categories.extract()`,
  `Categories.keyLabel()`, and `Categories.formatValue()` helpers used by `DiffViewer`.
- `settingsync_devices.lua` — device profile utilities. `Devices.currentName()` reads the
  user-assigned device name from plugin settings. `Devices.remotePath()` builds cloud
  paths like `devices/{device_name}/{remote_name}`. `Devices.listFromCloud()` discovers
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

## Menu structure

`buildMainMenu()` returns the top-level `sub_item_table` for the SettingSync menu entry.
Items are laid out in three logical groups separated by `separator = true`:

```
SettingSync
├── Cloud: {server_name}        (tap → configure; text_func)
├── Device: {device_name}       (tap → rename; text_func)          [separator]
├── Sync: Gestures              (one item per Categories.ALL entry)
├── Compare & sync all settings… (full diff for all scope sources)  [separator]
├── Push all to cloud
├── Pull all from cloud                                              [separator]
└── Sync scope ▸               (checkboxes for global/plugin/config scope)
```

Category items are injected inline by iterating `Categories.ALL` — **do not add a
"Sync by category" wrapper submenu**. When adding a new category, add it to
`Categories.ALL` and it will appear automatically.

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

Never add device-specific keys to the sync path — add them to the `exclude_keys` list of
the relevant source instead.

## Category-based sync model

Categories are defined in `settingsync_categories.lua`. Each category:

```lua
{
    id               = string,   -- e.g. "gestures"
    label            = string,   -- translated display name, e.g. _("Gestures")
    description      = string,   -- translated description
    is_device_specific = bool,   -- if true, stored under devices/{device_name}/ in cloud
    local_path       = string,   -- absolute path to the source file on device
    remote_name      = string,   -- filename in cloud, e.g. "gestures.lua"
    keys             = {string}, -- keys extracted from the source file
    key_labels       = {[key]=string},  -- translated human-readable names per key
    value_formatters = {[key]=fn},      -- optional per-key value display functions
}
```

Category-based sync workflow in `main.lua`:
1. User selects a category (e.g., **Sync: Gestures**) from the SettingSync menu.
2. If multiple device profiles exist in cloud, a device picker appears.
3. `_doCategorySync(category, target_device_name)` downloads
   `devices/{target_device}/{category.remote_name}` and diffs it against the locally
   extracted category keys from the category's `local_path`.
4. `DiffViewer` shows the diff with human-readable key labels and formatted values.
5. On Apply: pulls merge into the local source file; pushes upload to
   `devices/{my_device_name}/{category.remote_name}`.

## DiffViewer status icons

| Icon | Meaning | Natural default action |
|------|---------|----------------------|
| `≠`  | Key exists on both sides with different values | Either direction |
| `↑`  | Key exists **locally only** (not in cloud) | Push to cloud |
| `↓`  | Key exists **in cloud only** (not local) | Pull from cloud |

These icons appear in the row header (before the key name) and in the summary line at the
top of the diff viewer. The cycling order on tap: nil → direction-default → other → nil.

## Device profile model

Device profiles are managed by `settingsync_devices.lua`:
- The current device name is stored in `settingsync.lua` as `device_name`.
  Default: `"default"`.
- Device-specific category files live at `devices/{device_name}/{remote_name}` in the
  cloud folder. `Devices.remotePath(name, remote_name)` builds this path.
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
`selections` is an array of `{entry = diff_entry, direction = "pull"|"push"}`.

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
  use Compare & Sync on the other, and confirm the diff view correctly shows the changed
  key and that applying push/pull updates the right file.

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
7. Directory creation uses `lfs.mkdir(dir)` — **never** `os.execute('mkdir -p ...')`.

When editing the menu in `main.lua`:

8. Category items are generated by iterating `Categories.ALL` inside `buildMainMenu()`.
   Do **not** wrap them in a "Sync by category" submenu — they must appear at the top level.
9. The `server_ok` closure in `buildMainMenu` controls `enabled_func` for all cloud
   operations; do not duplicate the `readSetting("sync_server")` check elsewhere.
10. **Always use `sub_item_table_func`, never `sub_item_table = self:buildFoo()`.**
    KOReader's `filemanagermenu.lua` calls `addToMainMenu` inside a `pcall`. Any runtime
    error — including one thrown by an eagerly-called `buildFoo()` — is silently swallowed
    and the plugin's entire menu entry disappears without any log message. The lazy form:
    ```lua
    sub_item_table_func = function() return self:buildMainMenu() end
    ```
    defers execution to tap-time, so a bug in `buildMainMenu` shows an error dialog instead
    of silently erasing the menu. This applies to the root plugin entry **and** any nested
    submenu item whose table is built by a method call.

When adding a new category to `settingsync_categories.lua`:

10. Add the category table to `Categories.ALL`.
11. Use `_("English string")` for all `key_labels` values so `check_i18n.py` finds them.
12. Mark `is_device_specific = true` for settings that differ across device types.
13. All keys for one category should live in a single source file; set `local_path`
    explicitly (see `Categories.GESTURES` which points to `settings/gestures.lua`).

When editing `DiffViewer` in `settingsync_ui.lua`:

14. `buildUI()` must assign `self.scrollable` and `self.cropping_widget` to the
    `ScrollableContainer` it creates, so `refreshUI()` can read `_scroll_offset_y` to
    preserve the user's scroll position across row-tap redraws.
15. `refreshUI()` saves `_scroll_offset_y` before closing and restores it after rebuilding —
    do not call `UIManager:close` / `UIManager:show` without this save/restore pattern.
16. Status icon order: `≠` for MODIFIED, `↑` for ADDED (local only), `↓` for REMOVED
    (cloud only). Do not revert to `+` / `−` — the directional arrows are intentional.

When adding UI strings:

17. Wrap with `_()` and add to both `l10n/zh_CN/koreader.po` and `l10n/zh_TW/koreader.po`.
18. **Run `python check_i18n.py` and fix all errors before committing.**
    Exit 0 = clean. Any missing msgid is a hard blocker.


