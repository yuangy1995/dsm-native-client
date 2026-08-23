# DsmMac

岚仓（LanStash）的 macOS 参考 App，使用 SwiftUI 并通过 Apple 共享 Swift Package 引用 `DsmCore` 与 `DsmNetwork`。`DsmMac` 作为内部 target 和 scheme 名保留，安装产物为 `LanStash.app`。

当前客户端支持：

- 多 NAS 配置和安全会话恢复；登录后可以从工作区侧栏新增或切换 NAS。
- NAS 地址支持 IP、域名、QuickConnect ID，以及从浏览器地址栏粘贴完整 HTTPS 地址。
- 端口默认自动选择；完整 URL 或高级连接设置可以提供用户端口覆盖。
- QuickConnect 会在发送登录信息前依次验证局域网和公网直连候选，失败后建立中继并核对 NAS 身份。
- `SYNO.API.Info` 能力发现。
- 账号密码登录与 OTP 状态切换；用户可选择将密码写入应用沙盒内的 AES-GCM 加密文件，并为每台 NAS 单独开启自动登录。
- 主 App 的 SID、SynoToken 和可选密码写入应用沙盒内的 AES-GCM 加密文件，其主密钥仅保存在应用私有 Keychain。只有用户创建 Finder 云盘映射后，最小必要会话才会共享到系统钥匙串，密码不会写入共享钥匙串。
- 自签名证书 SHA-256 指纹审核、钉扎和证书变化阻断。
- 共享目录、分页目录、文件夹大小统计和文件详情浏览；文件浏览器默认使用图标视图，并可切换列表视图及按类型、时间或大小分组。
- 当前目录或所有子文件夹搜索、正则筛选、收藏夹、最近访问和已挂载远程位置入口。
- 图片与视频缩略图、图片前后切换/旋转/缩放/全屏、受限文本、PDFKit 本地安全预览、音乐播放和视频流式预览；含糊扩展名会读取少量文件头识别内容，不按文件大小猜测格式。
- 常见文本和代码文件支持编辑、覆盖保存、未保存修改保护，以及 JSON、GeoJSON、XML、JavaScript、TypeScript 和 CSS 格式整理。
- 系统文件选择器上传、由 NAS 打包的 ZIP 文件夹下载、可选的保留目录结构递归下载、支持 Range 续传的文件下载，以及可暂停、取消、继续和重试的传输中心。
- 多选项目批量压缩下载；复制和移动会直接开始，仅在目标位置实际存在同名项目时提示跳过或替换，替换前再次确认。
- 文件和文件夹可直接在 NAS 上压缩为 ZIP 或 7z；常见压缩包支持密码解压、保留目录结构、创建同名文件夹和受确认保护的同名替换。
- 创建带可选密码和有效期的分享链接；分享管理支持复制链接和取消已创建的分享。
- 同一 NAS 内复制/移动，以及通过有界内存流实现的跨 NAS 文件和文件夹复制/移动；真实 NAS 之间不生成整文件磁盘暂存。
- 传输任务支持右键暂停、继续、重试、取消和删除；删除下载任务时同步清理对应的未完成分片。
- 上传、下载和文件操作完成或失败时发送 macOS 系统通知；失败通知会引导用户前往传输中心重试。
- 视频、音乐、PDF 和文本等较大内容在预览读取期间显示实时速度；侧栏底部显示当前连接方式并提供退出入口。
- 设置中的存储管理显示预览缓存、系统缓存和受保护数据占用，并只清理不影响登录和任务恢复的可再生缓存。
- 带确认、任务轮询和结果校验的删除。
- 回收站浏览与受兼容开关保护的恢复到原位置。

OTP 只保留在登录界面的内存状态中。密码默认不保存；只有用户明确选择“在这台 Mac 上记住密码”时才写入应用沙盒内的 AES-GCM 加密文件。“自动登录”依赖已保存密码，显式退出或关闭“记住密码”会同时关闭自动登录。回收站恢复必须先在目标 DSM build 上完成实机验证。

上传和下载由各 NAS 工作区独立管理，切换 NAS 或离开“传输中心”后仍会继续；传输中心会显示进度、速度和预计剩余时间。下载暂停后保留隐藏分片并通过 HTTP Range 继续。群晖公开 Upload API 没有字节偏移续传契约，因此暂停的上传会明确显示“重新上传”，继续时从头发送。当前版本要求应用保持运行，退出应用会取消尚未完成的任务。

音乐和视频预览使用 AVFoundation 按需请求 NAS 的字节区间，不会先下载完整文件。NAS 必须为下载请求返回有效的 `206 Partial Content` 和 `Content-Range`；不支持 Range 的连接会显示明确提示。媒体会话只保留在内存中，并继续核对当前 NAS 的证书。

## 一键打包并运行

需要安装完整 Xcode，并在 Xcode 设置中完成首次组件安装。进入本目录后执行：

```bash
./package.sh
```

脚本不接收命令行参数。启动后根据菜单依次选择：

1. Release 或 Debug 构建。
2. 当前 Mac、Apple 芯片、Intel Mac 或 Universal 通用架构。
3. 本机临时签名，或从钥匙串中选择已安装的签名证书。
4. 打包完成后直接启动，或只生成安装包。

选择 Apple Development 或 Developer ID 正式签名时，主 App 与 File Provider 使用了
共享 Keychain 权限，因此还必须通过环境变量提供两个与证书团队、Bundle ID 和权限匹配
的 provisioning profile：

```bash
LANSTASH_MAC_APP_PROVISIONING_PROFILE_PATH="/安全路径/MacApp.provisionprofile" \
LANSTASH_MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH="/安全路径/FileProvider.provisionprofile" \
  ./package.sh
```

macOS 的 App Group 可使用 Apple 官方支持的 `<TeamID>.<名称>` 格式；这种格式不需要在
Developer 门户单独注册，脚本会检查 Team ID 前缀必须与签名证书一致。已在门户注册的
`group.<名称>` 格式也仍受支持。

确认设置后，脚本会生成 `dist/LanStash.app` 和 `dist/LanStash-<版本>-<架构>.dmg`。每一步直接按回车即可使用推荐选项，输入 `q` 可以随时退出。构建前会显示当前分支和提交，并检查主 App 与 File Provider 扩展的 Swift 文件是否全部加入构建目标；产物的 `Info.plist` 会记录 `LanStashSourceCommit`，便于确认安装包对应的源码版本。选择打包后运行时会启动新实例，避免仍在运行的旧版本被误认为新产物。

新 DMG 成功生成并通过完整性验证后，脚本会自动删除 `dist` 中更早版本的安装包；同一版本的不同架构会保留。构建或验证失败时不会清理已有安装包。

临时签名产物适合在本机开发测试，不应作为公开下载版本发布。使用 Developer ID 正式签名后，公开分发前仍需完成 Apple 公证。

正式签名的 DMG 可使用以下流程提交公证。公证凭据必须预先保存在钥匙串中，不得
写入仓库或命令行历史：

```bash
LANSTASH_NOTARY_PROFILE="钥匙串配置名" \
  ./notarize.sh ./dist/LanStash-<版本>-<架构>.dmg
```

CI 也可设置 `LANSTASH_NOTARY_API_KEY_PATH`、`LANSTASH_NOTARY_API_KEY_ID` 和
`LANSTASH_NOTARY_API_ISSUER_ID` 直接使用临时 API Key 文件，避免持久化钥匙串凭据。

脚本会等待公证结果、装订票据，并调用
`tools/release/verify_macos_distribution.sh` 校验 Developer ID 签名、File
Provider 扩展、受限权限、Gatekeeper、DMG、DMG 内 App 与待发布 App 的一致性，以及票据。
