# macOS 本地测试包数据隔离（2026-09-09）

## 授权与范围

用户明确批准测试版使用独立应用标识、配置、登录资料、密钥和缓存。此改动仅改变临时签名包；正式签名包、移动端及正式版现有目录名称不变，不迁移、复制或删除正式版资料。

此前外观测试包仍与正式版共用身份和存储，不属于隔离测试包。应使用本次新包重新添加 NAS，不继续使用旧临时包测试登录。

## 隔离边界

| 内容 | 测试版处理 |
| --- | --- |
| 应用身份 | `io.github.qwertyuiop1995.dsmnativeclient.macos.localtest`，跨本地测试版本保持稳定 |
| 应用文件与显示名称 | `LanStash Test.app`；简体中文“岚仓测试版”，英语“LanStash Test” |
| 配置、语言、外观、自动登录和 NAS 列表 | `UserDefaults.standard` 随独立应用标识分开保存 |
| 加密登录文件与主密钥名称 | 原名称加 `-LocalTest`；仍使用系统钥匙串保存 AES 主密钥、AES-GCM 加密文件，保持原权限检查 |
| 照片缓存、缩略图、文件预览与文本编辑目录 | 固定目录名称加 `-LocalTest`，读写与缓存清理使用同一名称 |
| 系统网络缓存 | 使用测试包独立的应用标识 |
| 旧登录资料迁移 | 测试版不创建默认迁移器，不读取、导入或清理旧版共享密码与会话 |
| File Provider | 使用独立组标识；临时包继续移除扩展，不启用本地磁盘挂载 |
| 更新与启动 | 临时包保持在线升级关闭；打包完成不自动启动 |

其他按 UUID 创建、只清理自身的临时文件不共用固定目录，没有新增迁移或全局清理逻辑。

## 验证

- `swift test --package-path apple --skip WorkspacePresentationTests`：841 项 XCTest 中 839 通过、2 项既有环境测试未运行；另有 12 项 Swift Testing 通过。未运行项为真实 QuickConnect 与显式开启的桌面云盘性能基准。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：21 项通过，包含正式/临时打包分支隔离、禁止修改正式包资源、双语测试名称、签名权限边界。
- `bash tools/release/verify_macos_local_storage.sh`：通过。链接真实 `LocalFileSecureStore` 实现，使用测试版应用标识及同样的临时签名权限，在随机测试钥匙串服务和临时目录中加密保存合成会话、密码；退出后由第二个进程重新读取。未访问实际主密钥、账号或 NAS，随机密钥与临时文件在结束时清理。
- 聚焦 UI：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test登录双语双主题及连接状态不触发认证|WorkspacePresentationTests.test文件与设置往返保持窗口及当前目录' bash tools/codex/run_macos_ui_checks.sh <临时输出目录>`，2 项通过。
- `python3 tools/localization/check_localization.py`、`bash -n` 脚本语法检查、`git diff --check` 均通过。
- 打包使用 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`，并为本次提供新建的 `LANSTASH_BUILD_ROOT` 与 `LANSTASH_DIST_DIR`。最初的 Debug 打包被既有 Chat 二进制成员检查拦截，未降低该门禁，改用正常 Release 打包配置。
- 最终 arm64 Release 构建、签名/权限/隔离标识检查、Sparkle 实际加载与 DMG 校验全部通过。输出位于 `apple/Apps/DsmMac/dist/isolated-test-20260909.KDJPBa/`，含 `LanStash Test.app` 与 `LanStash-1.0.1-arm64.dmg`。未安装或启动主 App，构建中间文件与合成截图已清理。

## 集成与安全复核

- 核对所有固定凭据/缓存目录的写入与清理引用，正式名称在非测试应用身份下不变。
- 未改 AES 算法、钥匙串授权、文件保护级别、登录错误门禁与正式签名权限；没有明文或固定密钥回退。
- 探针的可注入钥匙串服务仅为模块内部测试入口，不改变生产初始化默认值。
- 测试包不会隔离用户主动选择的外部文件或 NAS 服务端数据；对同一 NAS 的实际文件操作仍会作用于该 NAS。

## PENDING_USER_VALIDATION 与回滚

1. 打开新的“岚仓测试版”，确认 NAS 列表初始为空，重新添加 NAS 并登录。
2. 保存后退出测试版，再次打开，确认测试版自己的配置与登录状态可读取；同时检查正式版资料保持不变。
3. 真实 NAS 登录、本机钥匙串交互、后续不同二进制版本的访问授权仍需用户验证。若系统要求钥匙串授权，应仅核对测试版对应提示；不建议删除或放宽正式版密钥权限。
4. 失败时回传 macOS 版本、触发步骤和脱敏提示，不回传密码、会话、密钥或真实主机地址。

回滚只需停止使用新测试 App；正式包及其存储未迁移，无需数据回滚。保留测试版独立资料即可在以后继续使用，不自动删除旧包或任何用户资料。所有改动保持未提交、未推送。
