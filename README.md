# SettingSync – KOReader Plugin

[中文说明](README_zh.md)

Synchronize KOReader settings across devices via WebDAV with per-key diff and selective sync.

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-AGPL--v3-blue.svg)

---

## Features

- **Per-key diff view** – see exactly which settings differ between local and cloud
- **Selective sync** – choose to push or pull individual keys, or bulk push/pull all
- **WebDAV backend** – works with any WebDAV server (Nextcloud, Synology, etc.)
- **Auto-discovery** – automatically scans `settings/` directory for plugin config files
- **Device-specific exclusions** – keys like `device_id`, `lastdir`, `home_dir` are never overwritten
- **Sync scope control** – choose which categories to sync: global settings, plugin settings, plugin configs

## Installation

1. Download or clone this repository into your KOReader `plugins` directory:
   ```
   /mnt/us/koreader/plugins/settingsync.koplugin/   # Kindle
   /mnt/onboard/.adds/koreader/plugins/settingsync.koplugin/   # Kobo
   ```
2. Restart KOReader.

## Configuration

1. Open the plugin from the KOReader menu: **☰ → Settings Sync**
2. Tap **WebDAV server** to configure your server URL, username, and password
3. Choose your **Sync scope** (global settings, plugin settings, plugin configs)

## Usage

### Diff & Sync (recommended)

1. Tap **Diff & sync settings…** to compare local vs. cloud
2. The diff viewer shows all changed keys with local and cloud values
3. Tap individual rows to toggle push/pull, or use **Push all** / **Pull all**
4. Tap **Apply** to execute the selected sync actions

### Quick Sync

- **Quick push all to cloud** – uploads all local settings (overwrites cloud)
- **Quick pull all from cloud** – downloads all cloud settings (overwrites local)

Both show a confirmation dialog before executing.

## Excluded Keys

The following device-specific keys are automatically excluded from sync:

| Key | Reason |
|-----|--------|
| `device_id` | Unique per device |
| `screen_mode` | Display-specific |
| `home_dir`, `lastdir`, `lastfile` | Device filesystem paths |
| `inbox_dir`, `screensaver_dir`, `screenshot_dir` | Device filesystem paths |
| `last_migration_date` | Per-device migration state |
| `quickstart_shown_version` | Per-device UI state |
| `wifi_was_on` | Transient device state |
| `SSH_port`, `SSH_allow_no_password` | Device-specific SSH config |

## License

[GNU Affero General Public License v3.0](LICENSE)
