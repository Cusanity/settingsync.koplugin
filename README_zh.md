# SettingSync – KOReader 插件

通过 WebDAV 跨设备同步 KOReader 设置，支持逐项对比和选择性同步。

![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-AGPL--v3-blue.svg)

---

## 功能

- **逐项对比** – 查看本地与云端设置的每一项差异
- **选择性同步** – 可单独推送或拉取每个设置项，也可批量操作
- **WebDAV 后端** – 支持任何 WebDAV 服务器（Nextcloud、群晖等）
- **不漏项** – 「其他阅读器设置」兜底类别会接管所有未被其他类别 认领的键值；`settings/*.lua`、插件的配置文件、`styletweaks/*.css` 与 `patches/*.lua` 均自动扫描发现。因此 KOReader 升级新增的设置或新装插件的配置无 需等待本插件更新即可同步
- **设备专属排除** – 按键名形态过滤路径类和每台设备独有的状态
- **同步范围控制** – 在 **同步范围** 中逐个类别开关

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

## 不参与同步的键值

这里不维护固定的键名清单，而是按键名的形态过滤，因此 KOReader 今后新增的设置也能自动被覆盖：

| 规则 | 示例 | 原因 |
|------|------|------|
| `*_dir`、`*_path`、`*_folder` | `home_dir`、`screensaver_dir`、`cover_image_path` | 设备文件系统路径 |
| `last*` | `lastfile`、`last_migration_date` | 每台设备独有的状态 |
| `dev_*` | `dev_abort_on_crash` | 开发调试开关 |
| `device_id` | – | 每台设备唯一，共用会破坏进度同步 |

账号、密码、Wi-Fi 凭据和 API 密钥**会**同步——这些正是新设备需要的配置。它们被归入各自的类别（**已保存的密码**、**已保存的 Wi-Fi 网络**、各插件的设置与配置文件），默认开启，如不需要可在 **同步范围** 中关闭。请注意：这意味着云端目录以明文保存这些内容，请妥善保管 WebDAV 账号。

## 默认关闭的类别

| 类别 | 原因 |
|------|------|
| 用户补丁 | `patches/*.lua` 会在 KOReader 启动时执行，拉取即意味着在本设备上运行来自云端的代码 |

## 许可证

[GNU Affero 通用公共许可证 v3.0](LICENSE)
