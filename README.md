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
- **Nothing left behind** – a catch-all category covers every reader setting no other
  group claims, and `settings/*.lua`, plugin configuration files, `styletweaks/*.css` and
  `patches/*.lua` files are discovered on disk, so settings added by a KOReader update or a
  newly installed plugin sync without waiting for this plugin to be updated
- **Device-specific exclusions** – paths and per-install state are filtered by name shape
- **Sync scope control** – one checkbox per category under **What to sync**

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
4. Tap **Apply** to execute the selected sync actions, **Skip** to leave this group of
   settings untouched and move on to the next one, or **Cancel** to stop there

### Quick Sync

- **Quick push all to cloud** – uploads all local settings (overwrites cloud)
- **Quick pull all from cloud** – downloads all cloud settings (overwrites local)

Both show a confirmation dialog before executing.

## What never syncs

Rather than a hand-maintained key list, keys are filtered by the shape of their name, so
a setting added by a future KOReader release is covered on day one:

| Rule | Examples | Reason |
|------|----------|--------|
| `*_dir`, `*_path`, `*_folder` | `home_dir`, `screensaver_dir`, `cover_image_path` | Device filesystem paths |
| `last*` | `lastfile`, `last_migration_date` | Per-device state |
| `dev_*` | `dev_abort_on_crash` | Developer/debug toggles |
| `device_id` | – | Unique per device; sharing it breaks progress sync |

Accounts, passwords, Wi-Fi credentials and API keys **do** sync – they are part of the
setup you want on a new device. They are grouped into their own categories (**Saved
passwords**, **Saved Wi-Fi networks**, per-plugin settings and configuration files) so you
can switch them off if you would rather not, but they are on by default. Note that this
means your cloud folder holds them in plain text; keep the WebDAV account private.

## Off by default

| Group | Why |
|-------|-----|
| User patches | `patches/*.lua` is executed by KOReader at startup, so pulling one runs code from your cloud on this device |

## License

[GNU Affero General Public License v3.0](LICENSE)
