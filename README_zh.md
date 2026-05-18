# SettingSync – KOReader 插件

通过 WebDAV 跨设备同步 KOReader 设置，支持逐项对比和选择性同步。

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-AGPL--v3-blue.svg)

---

## 功能

- **逐项对比** – 查看本地与云端设置的每一项差异
- **选择性同步** – 可单独推送或拉取每个设置项，也可批量操作
- **WebDAV 后端** – 支持任何 WebDAV 服务器（Nextcloud、群晖等）
- **自动发现** – 自动扫描 `settings/` 目录中的插件配置文件
- **设备专属排除** – `device_id`、`lastdir`、`home_dir` 等设备相关键值不会被覆盖
- **同步范围控制** – 可选择同步的类别：全局设置、插件设置、插件配置

## 安装

1. 将本仓库下载或克隆到 KOReader 的 `plugins` 目录中：
   ```
   /mnt/us/koreader/plugins/settingsync.koplugin/   # Kindle
   /mnt/onboard/.adds/koreader/plugins/settingsync.koplugin/   # Kobo
   ```
2. 重启 KOReader。

## 配置

1. 从 KOReader 菜单打开插件：**☰ → 设置同步**
2. 点击 **云服务** 配置服务器地址、用户名和密码
3. 选择 **同步范围**（全局设置、插件设置、插件配置）

## 使用方法

### 对比并同步（推荐）

1. 点击 **对比并同步设置…** 比较本地与云端的差异
2. 对比视图会显示所有变更项及其本地和云端的值
3. 点击单行切换推送/拉取，或使用 **全部推送** / **全部拉取**
4. 点击 **应用** 执行所选的同步操作

### 快速同步

- **快速推送全部到云端** – 上传所有本地设置（覆盖云端）
- **快速从云端拉取全部** – 下载所有云端设置（覆盖本地）

两者均会在执行前显示确认对话框。

## 排除的键值

以下设备专属键值会自动排除，不参与同步：

| 键名 | 原因 |
|------|------|
| `device_id` | 每台设备唯一 |
| `screen_mode` | 与显示屏相关 |
| `home_dir`、`lastdir`、`lastfile` | 设备文件系统路径 |
| `inbox_dir`、`screensaver_dir`、`screenshot_dir` | 设备文件系统路径 |
| `last_migration_date` | 设备迁移状态 |
| `quickstart_shown_version` | 设备 UI 状态 |
| `wifi_was_on` | 临时设备状态 |
| `SSH_port`、`SSH_allow_no_password` | 设备 SSH 配置 |

## 许可证

[GNU Affero 通用公共许可证 v3.0](LICENSE)
