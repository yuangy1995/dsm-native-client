# 本地磁盘挂载开启读写后仍只读：修复账本

## 范围与基线

用户报告开启编辑和删除、重新挂载后 Finder 仍只读；同时提供 Container Manager 导出日志要求只读分析。main 的既有 Chat/容器修改全部保留，不提交、不推送、不调整 NAS 设置，不触碰真实文件。

已安装正式 App 为 1.0.13（23），包含同版本 File Provider 扩展；App Group 声明一致。安装包来源提交与 HEAD 间的 File Provider/写回存储/设置源码无差异，因此不能仅以应用版本较旧解释该问题。

| 主流程 | 源码证据 | 目标与保护 |
| --- | --- | --- |
| 开关保存 | DesktopDriveWritebackSettingsSheet / DesktopDriveWritebackStore | 只更新当前挂载；保留编辑/删除的独立确认 |
| Finder 元数据 | ProviderItem / ProviderRuntime | 权限变化被系统观察到；内容版本不因权限变化失效 |
| 增量刷新 | ProviderChangeAnchor / DesktopDriveChangeJournal | 本地授权变化不能被未变化的 NAS 文件快照吞掉；旧锚点安全重新枚举 |
| 权限解析 | DsmFileRepository 的 perm / mount_point_type | 核实真实只读字段，不通过移除权限判断来解锁 |

## Container Manager 日志结论

用户提供的日志含 5 条本日下载错误：20:02:58 与 21:11:10 为 TLS handshake timeout；20:25:09、21:08:34、21:09:13 为 unauthenticated pull rate limit。前者为 NAS 连接仓库/认证服务超时，后者为镜像仓库拒绝超出匿名额度的拉取。与用户报告官方网页同样失败及先前浏览器受控下载失败一致，错误在 NAS 的 Docker 拉取链路，不能归因于 macOS UI 或请求状态显示。日志不证明所有镜像/仓库不可用，也不能据此指定 DNS、代理或证书配置为唯一原因。

两条超时均指向用户配置的镜像中转服务；限额错误来自 Docker Hub，但日志不足以区分限额归属 NAS 出口还是中转服务的共用上游额度。DSM 登录不等于镜像仓库认证；先检查该中转服务是否可用，再核对实际拉取链路的仓库认证与额度，不通过关闭 TLS 校验处理连接超时。

原始 HTML、账号、主机、真实镜像清单和日志正文不复制到仓库；本记录只保留必要时间和错误分类。参考 [Docker 官方故障说明](https://docs.docker.com/docker-hub/troubleshoot/)。未修改 NAS 网络、仓库配置或发起新的下载。

## 根因与实现

1. 在已有官方网页会话中，仅用 `SYNO.FileStation.List` v2 `list` 读取一个项目的 `perm/mount_point_type`，只记录字段类型和权限布尔值。代表性项目的 `acl.read/write/del/append/exec` 均为 `true`，`is_acl_mode=true`，`mount_point_type` 为精确空字符串。NAS 返回的编辑/删除权限并未关闭。
2. `DsmFileRepository.FileAdditionalPayload` 原先保留空字符串，但 `ProviderItem` 和写回预检使用 `mountPointType == nil` 区分普通项目与特殊挂载，因此普通文件也被拒绝编辑/删除。现在只将精确空串归一化为 `nil`，非空特殊挂载类型原样保留；目录列表和详情走同一解析路径。
3. 原先本地授权不进入 `ProviderItem.itemVersion.metadataVersion`，也不进入目录增量锚点。虽然设置页面已通知根和 working set 刷新，NAS 文件快照未变化时仍可得到空增量。现在元数据版本包含最终能力位；内容版本保持原值，避免触发无意义的文件内容重新下载。
4. `ProviderChangeAnchor` 的容器指纹纳入只读/编辑/编辑及删除三种状态，变化后旧锚点返回 `syncAnchorExpired`。根、普通目录和 working set 均适用；扫描后再核对授权，避免异步期间变化被错误写入下一锚点。沿用系统重新枚举，不调用会丢弃项目身份的 `reimportItems`，不扩张为扫描整个 NAS。

代码修改为 `DsmFileRepository.swift`、`ProviderItem.swift`、`ProviderRuntime.swift`；新增回归分别在 `DsmFileRepositoryTests.swift` 和 `ProviderWritebackTests.swift`。没有界面文案、工程成员、依赖、Bundle ID、entitlement 或公开接口变化。

锚点仍是原来的四段不透明字符串，变化日志和写回存储格式不变。旧版本锚点在升级后正常失效并重建；回退旧包同理。文件身份与内容版本保持稳定，未完成写回与删除记录保留。

## 五端影响

| 平台 | 本次影响 | 验证范围 |
| --- | --- | --- |
| macOS | 共享解析、File Provider 元数据和权限刷新修复 | 合成写回回归、扩展及主 App 构建；系统 Finder 待验 |
| iPhone | 共用 Apple 文件解析修复，无挂载页面或写回功能扩张 | 通用 iOS 模拟器 Debug 构建；无新增设备结论 |
| iPad | 与 iPhone 相同的共享解析影响；桌面挂载仍为非目标 | 同一通用构建覆盖目标，不代替 iPad 交互验收 |
| Android | 本轮不改代码；保留空类型与非空特殊挂载的语义参考 | 未验证 |
| Windows | 本轮不改代码；后续 Cloud Files 对齐时复核解析与授权刷新 | 未验证 |

本次没有 DSM 请求参数或私有 API 契约新增，不提升其他版本的兼容证据等级。

## 验证与风险

| 实际命令/检查 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter 'test普通文件空挂载类型\|test更改编辑删除授权'` | 2 项通过；覆盖空/非空挂载类型，指定文件夹/全部共享，编辑与删除独立启停，根/可见父目录/工作集锚点，以及内容不变、零上传和零删除 |
| `swift test --package-path apple --jobs 4` | 2,417 XCTest：2,248 通过、169 按既有界面/环境门禁跳过、0 失败；另 12 Swift Testing 通过 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/mount-writability-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | `BUILD SUCCEEDED`；共享 Apple 解析与完整移动 App 编译通过 |
| `LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/mount-writability-20261003" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/mount-writability-20261003" bash apple/Apps/DsmMac/package.sh` | 退出码 0；完整 macOS Release arm64 主 App 及内嵌 File Provider 扩展编译成功；打包时按既定流程移除扩展 |
| 打包流程内 `codesign --verify --deep --strict`、`tools/release/verify_macos_local_test.sh`、`hdiutil verify` | 均通过；专用临时权限精确匹配，Sparkle 实际加载成功，DMG 校验有效；不安装或启动主应用 |
| `python3 tools/localization/check_localization.py` | Apple 5,576 / Android 2,188 / Windows 3,402 资源；双语、占位符、引用和硬编码扫描通过 |
| `python3 tools/codex/check_documentation.py`、`python3 tools/codex/generate_api_reference.py --check`、`git diff --check` | 通过 |

构建在当前进程中将现有 Sparkle 上游 URL 映射到本机既有仓库缓存以避免重复下载；不修改 Git 全局/仓库配置或依赖版本。`file` 另行确认原始 Release 构建的主程序与内嵌 `LanStashFileProvider.appex` 主程序均为 arm64。构建成功不等于扩展已签名注册或在 Finder 执行。

保留主 App 回归包：`apple/Apps/DsmMac/dist/mount-writability-20261003/LanStash-1.0.13-arm64.dmg`，1.0.13（23），26,524,206 字节；SHA-256 为 `c63079e5d43190a42ceb5605f2ab501ed07143778569126822ef289a14f4be58`。此包不含挂载扩展，不能用于验证 Finder 修复，也未替换此前测试包。

## 集成与只读对抗复核

在实现后独立进行第二遍源码/差异复核：非空特殊挂载仍禁止写回；NAS 明确拒绝编辑/删除仍被尊重；共享根、越界、回收站和远程挂载祖先保护不变；删除授权仍独立，结果未知只核查；元数据版本前缀仍兼容已有冲突判断。完整测试中的只读共享、远程挂载深层子项、递归删除权限、跨实例去重、未知结果和同名新文件保护均通过。此复核是本次本地源码复核，不声称另一位审查者或真实设备已验收。

## PENDING_USER_VALIDATION

- 前置条件：包含本次修复的正式签名主 App 和 File Provider 扩展，App Group/系统注册有效；在 NAS 上选可丢弃测试目录，不使用重要文件。当前已安装的 App 未被替换。
- 在指定文件夹和全部共享两种映射下，各验证已有普通文件/文件夹不再因空挂载类型全部带锁；启用编辑后新增文件、保存修改、改名/范围内移动，确认 NAS 最终内容一致。共享根本身仍不可改名或删除。
- 单独启用删除后删除测试文件并核对 NAS；只启用编辑时仍不可删。关闭编辑应同时撤销删除，刷新或重新打开 Finder 后变为只读；重新挂载也应保留正确的授权状态。
- NAS 权限拒绝、特殊远程挂载、断网/会话过期、保存冲突和删除结果未知时应保持既有拒绝或恢复流程，不能强行写入、重复提交或删除同名新文件。正式签名注册与真实 NAS 写回未在本机自动执行。
- 失败反馈只含用例步骤、App/macOS/DSM/套件版本类别、是否能编辑/删除、脱敏错误类别；不回传账号、地址、真实路径、Cookie、令牌或原始响应。

本机临时签名包按既定流程移除 File Provider 扩展，只适合主 App 回归，不能用于验证本次 Finder 修复。真实系统验收不由合成测试或签名检查替代；现有授权、权限和危险操作保护继续生效。

交付保留源码、正式回归测试及独立测试包；本轮临时构建目录与日志在记录结果后清理，用户提供的日志/截图保留原位。工作仍在 `main`，保留此前全部 Chat/容器/规则改动；没有暂存、提交、推送或发布。
