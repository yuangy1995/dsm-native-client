# DsmMac

岚仓（LanStash）的 macOS 参考 App，使用 SwiftUI 并通过 Apple 共享 Swift Package 引用 `DsmCore` 与 `DsmNetwork`。`DsmMac` 作为内部 target 和 scheme 名保留，安装产物为 `LanStash.app`。

当前客户端支持：

- 多 NAS 配置和安全会话恢复；登录后可以从工作区侧栏新增或切换 NAS。
- NAS 地址支持 IP、域名、QuickConnect ID，以及从浏览器地址栏粘贴完整 HTTPS 地址。
- 端口默认自动选择；完整 URL 或高级连接设置可以提供用户端口覆盖。
- QuickConnect 会在发送登录信息前依次验证局域网和公网直连候选，失败后建立中继并核对 NAS 身份。
- `SYNO.API.Info` 能力发现。
- 原生消息支持普通一对一、私人群聊、文字与单附件、提醒、定时消息和投票创建；加密会话不开放收发。2026-10-03 的发送状态、重复提交、删除、未读、图片预览及无障碍修复见[Chat 修复账本](../../../docs/development/MACOS_CHAT_FIX_20261003_ZH.md)。
- 账号密码登录与 OTP 状态切换；用户可选择将密码写入应用沙盒内的 AES-GCM 加密文件，并为每台 NAS 单独开启自动登录。
- 主 App 的 SID、SynoToken 和可选密码写入应用沙盒内的 AES-GCM 加密文件，其主密钥仅保存在应用私有 Keychain。只有用户添加本地磁盘挂载后，最小必要会话才会共享到 Data Protection Keychain，密码不会写入共享钥匙串。
- 本地磁盘挂载：在 Finder 中按需浏览、下载和保留 NAS 文件。默认只读；指定文件夹和全部共享挂载均可按映射开启编辑与上传，删除需另外确认授权；不自动下载整个 NAS，也不创建独立的 `/Volumes` 块设备。
- 自签名证书 SHA-256 指纹审核、钉扎和证书变化阻断。
- 共享目录、分页目录、文件夹大小统计和文件详情浏览；文件浏览器默认使用图标视图，并可切换列表视图及按类型、时间或大小分组。
- 当前目录或所有子文件夹搜索、正则筛选、收藏夹、最近访问和已挂载远程位置入口。
- 图片与视频缩略图、图片前后切换/旋转/缩放/全屏、受限文本、PDFKit 本地安全预览、音乐播放和视频流式预览；含糊扩展名会读取少量文件头识别内容，不按文件大小猜测格式。
- 常见文本和代码文件支持编辑、覆盖保存、未保存修改保护，以及 JSON、GeoJSON、XML、JavaScript、TypeScript 和 CSS 格式整理。
- Word、Excel、PowerPoint 支持系统 Quick Look 预览，以及默认或自选本机应用编辑；本机保存后自动更新 NAS 原文件，内容不变不上传。
- 系统文件选择器上传、由 NAS 打包的 ZIP 文件夹下载、可选的保留目录结构递归下载、支持 Range 续传的文件下载，以及可暂停、取消、继续和重试的传输中心。
- 多选项目批量压缩下载；复制和移动会直接开始，仅在目标位置实际存在同名项目时提示跳过或替换，替换前再次确认。
- 文件和文件夹可直接在 NAS 上压缩为 ZIP 或 7z；常见压缩包支持密码解压、保留目录结构、创建同名文件夹和受确认保护的同名替换。
- 创建带可选密码和有效期的分享链接；分享管理支持复制链接和取消已创建的分享。
- 同一 NAS 内复制/移动，以及通过有界内存流实现的跨 NAS 文件和文件夹复制/移动；真实 NAS 之间不生成整文件磁盘暂存。
- 传输任务支持右键暂停、继续、重试、取消和删除；删除下载任务时同步清理对应的未完成分片。
- 上传、下载和文件操作完成或失败时发送 macOS 系统通知；失败通知会引导用户前往传输中心重试。
- 视频、音乐、PDF 和文本等较大内容在预览读取期间显示实时速度；侧栏底部显示当前连接方式并提供退出入口。
- 设置中的存储管理显示预览缓存、系统缓存和受保护数据占用，并只清理不影响登录和任务恢复的可再生缓存。
- NAS 设置支持健康/性能、存储、服务、网络、安全、账号、日志与连接等页面；内存压缩开关和电源计划可编辑，保留风险确认、当前状态检查和保存结果核对。
- 原生套件中心支持目录/搜索/分类/详情、安装/更新、手动 `.spk`、依赖与安装位置确认、进度、下载取消、启停/卸载，以及通知、自动更新与来源管理；首次测试版协议、付费激活和浏览器专属安装向导在 DSM 完成。官方网页单套件更新已完成，客户端真实提交仍待用户验证；空预检响应、设置频道和旧语言资源覆盖的修复见[反馈修复账本](../../../docs/development/PACKAGE_CENTER_FIX_20261003_ZH.md)。
- 带确认、任务轮询和结果校验的删除。
- 回收站浏览与受兼容开关保护的恢复到原位置。

OTP 只保留在登录界面的内存状态中。密码默认不保存；只有用户明确选择“在这台 Mac 上记住密码”时才写入应用沙盒内的 AES-GCM 加密文件。“自动登录”依赖已保存密码，显式退出或关闭“记住密码”会同时关闭自动登录。回收站恢复按实际接口能力开放点击测试，保留恢复确认、同名冲突保护和结果复查；目标 NAS 的真实恢复行为仍待用户验证。

上传和下载由各 NAS 工作区独立管理，切换 NAS 或离开“传输中心”后仍会继续；传输中心会显示进度、速度和预计剩余时间。下载暂停后保留隐藏分片并通过 HTTP Range 继续。群晖公开 Upload API 没有字节偏移续传契约，因此暂停的上传会明确显示“重新上传”，继续时从头发送。当前版本要求应用保持运行，退出应用会取消尚未完成的任务。

音乐和视频预览使用 AVFoundation 按需请求 NAS 的字节区间，不会先下载完整文件。NAS 必须为下载请求返回有效的 `206 Partial Content` 和 `Content-Range`；不支持 Range 的连接会显示明确提示。媒体会话只保留在内存中，并继续核对当前 NAS 的证书。

## Office 文档预览与自动保存

文件页支持 `doc/docx/xls/xlsx/ppt/pptx` 的系统预览，单纯预览不会开始自动回传。选择“用本机应用编辑”→“打开并自动保存”，选定本机副本位置后，用默认应用或菜单中选定的应用打开；在编辑器中保存原副本，岚仓会等待保存稳定后回传到 NAS 原路径。

文件工具栏的“文档自动保存”可查看状态、显示或打开副本、重试暂停、核对未知结果及停止。检测到 NAS 文件已更改时暂停自动覆盖；保存结果不明时只核对，不自动重复上传。本功能没有多人协作锁，无法完全消除其他客户端同时保存的覆盖竞态。

请保持岚仓运行。关闭预览或主窗口不结束会话；停止、断开 NAS 或退出后不再回传，本机副本保留，重启不会自动恢复。另存为到其他路径不会自动跟踪新文件。此流程使用用户选择的本机文件，不依赖 Finder 挂载扩展。

Office 流程只使用既有文件读取、校验和 Upload API。权限预检只核查目录新建能力，现有文件覆盖仍由正式上传结果决定；每次上传固定原 NAS 目标，使用协调读取的独立快照并在完成后核对大小、MD5 与版本。超时后先核对，不自动重放。

测试包与既有执行证据集中在[验证历史](../../../docs/archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)；真实编辑器、旧格式、复杂排版、正式沙盒和辅助功能仍待用户验证。

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

开发证书必须使用包含测试 Mac 的 Mac App Development profile，不能混用
Developer ID profile。手动签名会补齐与 profile 一致的应用和团队身份字段；
签名验证成功仍不能代替 Finder 的真实挂载验收。

```bash
LANSTASH_MAC_APP_PROVISIONING_PROFILE_PATH="/安全路径/MacApp.provisionprofile" \
LANSTASH_MAC_FILE_PROVIDER_PROVISIONING_PROFILE_PATH="/安全路径/FileProvider.provisionprofile" \
  ./package.sh
```

macOS 的 App Group 可使用 Apple 官方支持的 `<TeamID>.<名称>` 格式；这种格式不需要在
Developer 门户单独注册，脚本会检查 Team ID 前缀必须与签名证书一致。已在门户注册的
`group.<名称>` 格式也仍受支持。

确认设置后，脚本会生成 `dist/LanStash.app` 和 `dist/LanStash-<版本>-<架构>.dmg`。每一步直接按回车即可使用推荐选项，输入 `q` 可以随时退出。构建前会显示当前分支和提交，并检查主 App 与 File Provider 扩展的 Swift 文件是否全部加入构建目标；产物的 `Info.plist` 会记录 `LanStashSourceCommit`，便于确认安装包对应的源码版本。选择打包后运行时会启动新实例，避免仍在运行的旧版本被误认为新产物。

本地修复测试可通过 `LANSTASH_DIST_DIR` 指定独立输出目录，保留之前的安装包。
`python3 tools/release/test_macos_signing.py` 在仓库根目录验证身份字段与原权限保持一致；
`tools/release/verify_macos_shared_keychain.py` 可对完整签名包做合成双进程共享检查，
只处理每次新建的合成条目并自动清理，不读取真实 NAS 会话。

新 DMG 成功生成并通过完整性验证后，脚本会自动删除 `dist` 中更早版本的安装包；同一版本的不同架构会保留。构建或验证失败时不会清理已有安装包。

临时签名产物适合在本机开发测试，不应作为公开下载版本发布。使用 Developer ID 正式签名后，公开分发前仍需完成 Apple 公证。

本机临时签名没有 Team ID，因此仅主 App 使用独立的
`SupportingFiles/DsmMacLocalTest.entitlements` 添加库验证例外，以加载包内 Sparkle；
保留其他 Hardened Runtime 保护，不修改系统安全设置。该例外不进入正式主 App 或扩展权限。
临时打包会运行 `tools/release/verify_macos_local_test.sh`，在不启动真实 App、不读取账号和 NAS
资料的隔离进程中，用包内实际权限验证 Sparkle 加载。正式分发校验会拒绝携带该本地例外的包。

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

## GitHub 发布与在线升级

macOS 可独立通过 GitHub Releases 发布，并使用 Sparkle 检查、下载和安装签名更新。
正式发布保留上述签名与公证流程，首次上线前须完成真实签名升级验收；配置、标签规则、
独立验收通道和回滚步骤见 [macOS 发布指南](../../../docs/releases/MACOS_GITHUB_RELEASE_ZH.md)。

## 文件功能与源码入口

| 切片 | 源码证据 | 已接入语义与交互 | 契约 / 风险 / 当前验证 |
|---|---|---|---|
| P0 多选分享 | `FileShareBatch.swift`、`FileShareCreationView.swift`、`WorkspaceModel.createShareLinks` | 每目标独立创建；成功链接保留并复制；逐项失败、未知及停止后续；结果页可批量复制 | Sharing v3；复用身份、权限、重复保护和回读；`IMPLEMENTED`、`AUTOMATED`，真实 NAS 待验 |
| P1 文件夹上传 | `FileUploadPlan.swift`、`FileUploadBatch.swift`、`FileUploadViews.swift` | 选择/拖放混选；目录清单、父级优先、空目录/隐藏文件、符号链接跳过；同名目录合并、文件默认跳过、类型冲突独立报告；单工作区新增批次串行、批次内最多两文件 | 公开 CreateFolder/Upload；`IMPLEMENTED`、`AUTOMATED`；替换须明确确认 |
| P2 高级搜索 | `FileSearchRequest.swift`、`FileAdvancedSearchView.swift`、`DsmFileRepository.search` | 类型化 AND 条件、名称/扩展名/类型/字节/三日期/owner/group/多位置/子目录；名称正则本地过滤；完整分页、去重、代次隔离、取消及任务清理 | Search v2；只读结果流程，start 不自动重放；`IMPLEMENTED`、`AUTOMATED` |
| P3 分享管理 | `FileShareLinkEdit.swift`、`FileShareManagementView.swift`、网络适配 | 自定义开始/结束与快捷期限；保留/设置/移除密码；筛选、状态、本机 QR、系统分享、批量编辑/取消逐项反馈 | Sharing v3；回读日期及可见状态；`IMPLEMENTED`、`AUTOMATED`；移除密码须明确确认 |
| P4 压缩包 | `FileArchiveRequest.swift`、`FileArchiveBrowserModel.swift`、`ArchiveExtractionView.swift`、`FileLocationPicker.swift` | 根/子目录分页、全部/选择、明确目标、编码/密码；提交前再读所选子树，空选择拒绝；完成后核对输出 | Extract v2；`IMPLEMENTED`、`AUTOMATED`；替换须明确确认 |
| P5 全文 | `FileSearchRequest.swift`、`DsmFileRepository.searchWithReport`、`FileAdvancedSearchView.swift` | 内容搜索、索引覆盖提示、完整分页；全文结果不再按名称二次过滤；名称正则保持独立 | [内容搜索契约](../../../docs/api/discovery/endpoints/file-station-content-search.md)；`IMPLEMENTED`、`AUTOMATED`；网页请求/未索引提示只读验证，实际正文召回待验 |
| P5 具名分享/次数/收集 | `FileStationAdvanced.swift`、`FileShareAdvancedView.swift`、`FileStationPrincipalPicker.swift`、`DsmFileRepository+Advanced.swift` | 用户/群组分页选择、访问次数、收集链接创建及信息编辑；沿分享取消关闭收集链接；未知不重放 | [增强分享契约](../../../docs/api/discovery/endpoints/file-station-sharing-extended.md)；`IMPLEMENTED`、`AUTOMATED`；按实际权限开放，确认后提交 |
| P5 权限/所有者 | `FilePermissionEditing.swift`、`FilePermissionEditor.swift`、`DsmFileRepository+Permissions.swift` | 当前项默认范围、显式/继承规则、受影响账号和差异、ACL/POSIX/所有者；递归、移除访问、所有者分别确认；任务状态和目标回读 | [权限契约](../../../docs/api/discovery/endpoints/file-station-file-permissions.md)；`IMPLEMENTED`、`AUTOMATED`；POSIX 首轮限管理员，按实际权限开放；部分应用不以根目录成功冒充全部成功 |
| P6 SMB/NFS 与 ISO | `FileISOMountView.swift`、`DsmFileRepository+ISO.swift`、`WorkspaceRemoteMountIdentityTests` | 既有 SMB/NFS 身份绑定恢复回归；ISO 文件到空目录挂载、准确来源卸载及自动挂载选择 | [挂载契约](../../../docs/api/discovery/endpoints/file-station-remote-mount.md)；`IMPLEMENTED`、`AUTOMATED`；新增 ISO/自动挂载受保护，真实连接未写 |
| P6 VFS 管理 | `FileVFSConnection.swift`、`FileVFSViews.swift`、`FileVFSBrowserView.swift`、`FileVFSCloudAuthorizationView.swift`、`FileVFSCloudAuthorizationSession.swift`、`DsmFileRepository+VFS.swift` | NAS 声明的 FTP/SFTP/WebDAV(S) 新建/修改，既有配置连接/断开/移除；连接与保存配置分步核对，不删除远端文件 | [VFS 契约](../../../docs/api/discovery/endpoints/file-station-vfs-connections.md)；已实现管理流程 `AUTOMATED`；云盘新授权/原账号续授权、远程 URI 分页浏览下载已接入；真实各服务授权待验 |
| P7 后台任务 | `FileBackgroundTaskActions.swift`、`DsmFileRepository.controlBackgroundTask` | 已确认四类任务的详情与单项控制；停止前后身份核对；清理明确单 ID，坏列表不冒充空列表 | 公开 BackgroundTask v3 及对应 stop；`IMPLEMENTED`、`AUTOMATED`；没有批量全清入口 |
| P7 套件设置 | `FileStationSettings.swift`、`FileStationSettingsView.swift`、`FileStationBandwidthView.swift`、`FileStationMountAccountList.swift`、`FileStationThemeImagePicker.swift`、`DsmFileRepository+Settings.swift`、`DsmFileRepository+ThemeImages.swift` | 日志/默认权限/账号显示、分享与收集授权差量、SMB/ISO 权限、VFS 范围和本机用户/组、六类来源限速/每周时间表、分享页总开关及现有布局/颜色/页脚；各项独立保存回读 | [设置契约](../../../docs/api/discovery/endpoints/file-station-package-settings.md)；已实现子项 `IMPLEMENTED`、`AUTOMATED`；本机/域/LDAP 挂载名单与 NAS/历史/本机/默认背景选图已接入；按实际管理员权限开放 |
| 跨切片未知结果 | `FileStationPendingChange.swift`、`FileStationPendingChangesView.swift`、`DsmFileRepository+PendingChanges.swift` | 关闭原表单后仍可从文件工具栏核查权限/ISO/VFS/设置；只读核查、与提交互斥、不自动重放 | 会话内状态，不新增持久格式、不保存密码；分享仍沿既有独立核查机制 |

接口细节见[按功能 API 参考](../../../docs/api/README.md)；自动化不证明真实 NAS 行为。

## Office 待用户验证

前置条件：使用独立测试包、安装兼容编辑应用，在 NAS 建立可丢弃的三类测试文档；覆盖保存仅在选中文档的编辑会话中发生。

| 操作 | 预期结果 | 影响及回传信息 |
|---|---|---|
| 分别预览 docx/xlsx/pptx，再检查常用旧格式 doc/xls/ppt | 三类文档在窗口内显示；旧格式、复杂排版、加密或损坏文档以系统支持为准 | macOS 版本、脱敏扩展名、是否出现预览及脱敏错误；不上传真实文件 |
| 默认应用或“选择应用”打开，不编辑，随后关闭文档 | 不发生回传，不改变 NAS 文件内容 | 应用名称/版本与 NAS 修改时间是否变化 |
| 编辑并保存原本机副本，等待状态为“已保存到 NAS” | NAS 原路径内容更新；本机副本保留，连续保存最终内容正确 | 应用版本、状态文字、脱敏步骤；不发送真实路径、账号或凭据 |
| 编辑器连续原子保存、保存期间继续修改 | 每次使用稳定快照；后续版本最终保存，不能错误报告未上传内容已完成 | 特定编辑器的保存行为和复现步骤 |
| 先用其他客户端修改 NAS 文档，再保存本机版本 | 进入冲突状态，不自动覆盖；显示本机副本便于手动核对 | 只回传操作顺序与状态，不提供文档正文 |
| 保存前断网/撤销写权限，恢复后重试；上传途中断网后核对 | 未提交时可重试；结果未知时只核对，不自动重放 | 脱敏错误及状态转移，真实写兼容仍需该验证 |
| 关闭预览/主窗口、停止、断开、退出或尝试更新 | 关闭视图不丢失会话；停止后保留副本；在途保存受保护；退出后不再同步且重启不自动恢复 | 影响本次编辑会话，不改普通下载/传输策略 |
| 正式签名沙盒下用 Office/Pages/Numbers/Keynote 打开及保存，VoiceOver/键盘操作 | 用户选定副本可访问、保存可检测，操作可读可用 | 需正式签名、相应已安装应用；本机临时签名包不能代替该验收 |

公开 Upload 不提供条件替换事务，上传前后校验不能消除检查瞬间之后另一客户端并发保存的覆盖竞态；不把本功能视为 Drive 协同编辑、版本历史或跨设备锁。其他四端、退出后的后台服务、自动恢复编辑会话及“另存为”路径跟踪均不在本轮范围内。

## 远程位置与界面约定

- 文件主页统一列出 SMB/NFS 挂载与 FTP/SFTP/WebDAV/云服务连接；“浏览文件”直接显示在列表操作区。保存并连接时按钮显示进度，阻止重复提交；成功后结束表单并刷新当前位置列表。
- WebDAV 支持粘贴带路径的完整 HTTPS 地址；路径归入连接目录，地址解析、身份和权限核对仍按同一连接模型处理。云服务使用系统浏览器与一次性本机回调；实际授权回调和 NAS 写入仍待用户验证。
- 工具栏按钮保持统一尺寸，面包屑整块可点并支持键盘和长路径；照片只有存在实际可切换来源时显示“我的照片／共享照片”。普通保存和连接不增加仪式式勾选，具体危险操作继续明确确认后果。
- 主窗口关闭不等于退出；退出需先处理在途任务，保留映射及可恢复状态。窗口销毁、重复打开、缓存清理、账号切换均沿既有生命周期与 profile 隔离，不通过重置用户配置掩盖错误。
- 新增 UI 同时检查双语、浅深色、五种内容状态、键盘、VoiceOver、动态文字和降低动态效果。原生合成截图只证明所测场景，完整辅助功能及真实系统行为由用户验收。

## 文件功能待用户验证

使用专用 NAS 账号和可丢弃目录，按功能执行正常保存、权限拒绝、断网、关闭表单和结果核对；预期每个目标只提交一次，未知写操作只查询，不伪造成功或重复执行。

| 功能 | 需要验证的实际行为 |
| --- | --- |
| 目录上传／分享／归档 | 空目录、同名冲突、取消、日期与密码修改、所选解压输出；取消不删除已完成内容。 |
| 搜索／权限／任务 | 全文索引覆盖、递归权限的逐项结果、任务停止及单项清理；根目录成功不能代替整树成功。 |
| SMB/NFS／ISO／VFS | 实际连接、卸载、重连、远程 URI 浏览下载；云服务新授权及原账号续授权的真实回调。 |
| 套件设置 | 用户/域/LDAP 名单、限速、权限差量、主题图选择及保存后刷新。 |
| UI 与恢复 | 窄窗口、长路径、键盘/VoiceOver、保存进度及迟到响应不覆盖新连接。 |

反馈仅提供系统/套件版本、操作步骤、功能与错误类别、实际/预期结果；不提供地址、账号、凭据、真实路径或原始响应。上述场景标为 `PENDING_USER_VALIDATION`，不改变当前能力/权限保护，也不宣称 NAS 全版本兼容。

- 2026-10-03 Chat 日常功能：旧消息搜索、本人编辑、文字线程回复、参与投票、音视频播放、AAC 录音试听发送、消息通知及跨端已读；Chat 启用且 NAS 连接时持续订阅，切换页面/NAS 不停止该工作区连接。麦克风由录音按钮请求，临时音频不进入持久化。真实 API 纠正、自动化、构建与待验证条件见[五组功能账本](../../../docs/development/MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md)。

- 2026-10-03 容器搜索与下载：修正搜索版本，读取暂时失败自动恢复，NAS 明确失败按下载失败显示，搜索错误提供重试并同步英中文案。当前 NAS 的受控下载失败与成功路径待验证范围见[修复账本](../../../docs/development/MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md)。
