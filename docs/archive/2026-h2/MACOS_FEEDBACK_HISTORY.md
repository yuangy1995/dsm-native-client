<!-- doc-role: historical-record -->

# macOS 功能与使用反馈历史

本页合并 2026-10-02 至 2026-10-03 的八份一次性账本，保留当时的范围、验证、失败和设备待办。文中的“当前”“下一步”和授权均指记录当时，不能作为新任务的授权或最新状态。当前入口见[开发状态](../../progress/STATUS.md)、[平台矩阵](../../progress/PLATFORM_MATRIX.md)及[macOS 说明](../../../apple/Apps/DsmMac/README.md)。

## NAS 设置网页核对与修正账本

状态：源码、网页核对、本机回归与独立测试包交付完成；真实 NAS 写入待用户验证。开始日期：2026-10-02，跨至 2026-10-03。基线：`8e6b0f3e`，分支 `codex/nas-settings-web-audit`。该基线为用户要求先提交的上一轮修复；本轮不自动推送、发布或提交新增改动。

### 目标与范围

- 对照用户已登录 Chrome 中的官方 DSM 页面，检查 macOS NAS 设置所有 21 个页面及其已有子项；同步修正代码、双语文案、相关私有 API 记录和兼容矩阵。
- 用户追加要求：取消仅因尚未实测而设置的禁用门槛，便于用户自行测试；保留实际权限、设备能力、输入有效性、危险操作确认、重复提交和结果核对。已实现功能的测试入口与尚未实现的操作分别记录，不用伪造按钮代替实现。
- 网页发现只读；不保存 NAS 配置，不触发权限、网络、运行状态或数据变更。涉及网页自动后台行为时如实记录，不把全部自然请求一概称为只读。
- 不更改其他平台代码、身份、签名、工具链、持久化格式或 DSM 公开 API；共享 Apple 新协议方法提供默认实现并做 macOS 回归，并记录 Windows、Android、iPhone、iPad 的适配影响。

### 用户追加范围（2026-10-03）

- 明确选择本轮补齐内存压缩开关及电源计划新增、编辑、删除；其他尚未实现的系统管理操作另做。
- 追加完整套件中心主流程：已安装管理、搜索与浏览、安装、卸载、更新及相应详情、预检、进度、错误恢复与结果核对。原先升级只读提示不再作为本轮目标。
- 后续安全操作及隔离测试数据已获授权，但不得影响真实数据。继续使用官方页面只读观察及本地合成测试，不在当前 NAS 执行真实配置、套件或系统控制操作。

### 证据与实施顺序

环境快照见[本轮只读记录](../../api/discovery/environments/2026-10-02-nas-settings-web-audit.md)。源码以 `apple/Apps/DsmMac/Sources/NasAdministrationView.swift`、`NasAdministrationModel.swift`、`apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository*.swift` 及已有专项 View 为准。单一负责人修改本轮共享模型、语言资源、契约及状态文件。

按“基础状态/存储 → 服务/网络/硬件/安全 → 任务/账号/套件 → 日志/连接”分组核对。每个页面记录正常、缺权限、不支持或无内容的真实边界，不将设备缺项记为通过；代码修复后执行聚焦测试、界面回归、独立只读集成复核及本地测试包构建。

### 页面核对清单

| 页面标识 | macOS 页面 | 官方对应位置 | 证据与差异 | 状态 |
| --- | --- | --- | --- | --- |
| `overview` | 总览与性能 | 信息中心 / 资源监控 | 官方信息中心确认 DSM 7.2.1-69057 Update 12；资源监控分开表示 CPU/内存。客户端面积图错误叠加，已改独立折线；原生双语浅深色回归通过。 | 网页已核对；本机回归通过 |
| `storage` | 存储管理 | 存储管理器 | 已打开存储管理器总览、HDD/SSD、状况信息，确认健康状态与 S.M.A.R.T./历史入口；未启动检测。修正错误响应误显示区域与时间错误。 | 网页已核对；本机回归通过 |
| `externalStorage` | 外接存储 | 外接设备 | 官方外接设备页面为空；没有外设可做容量/格式化/弹出实测。修正错误文案，保留实际无内容限制。 | 网页已核对；本机回归通过 |
| `zram` | 内存压缩 | 硬件和电源 / 资源监控 | get v1 成功返回 enable_zram:Boolean，原代码漏读；已修正。官方前端 set v1 使用同名布尔值，另调用 NeedReboot.set，重启由独立系统操作触发。已实现开关、保存确认、当前值冲突保护及两项结果回读，不自动重启；新增合成测试通过。 | 网页已核对；本机回归通过 |
| `fileServices` | 文件服务 | 文件服务各标签 | 已核对 SMB/NFS、FTP/FTPS/SFTP、Bonjour、SSDP 与 Time Machine 播送控件；修正将播送误称完整备份服务的标签。没有保存。 | 网页已核对；本机回归通过 |
| `terminal` | 远程连接 | 终端机和 SNMP | 已核对 SSH/Telnet、SSH 端口；网页说明管理员登录限制。原客户端保存入口已实现，没有仅因未实测关闭的常量。 | 网页已核对；本机回归通过 |
| `network` | 网络与代理 | 网络 → 常规/代理 | 官方网络常规包含代理开关、地址、端口；本页仅实现代理编辑，其他网络摘要来自总览。无配置保存。 | 网页已核对；本机回归通过 |
| `interfaces` | 网络接口 | 网络 → 网络界面 | 已打开物理局域网编辑窗口核对 DHCP、地址、掩码、网关、DNS、MTU、VLAN 后取消；本轮未验证 Bond/VPN/IPv6 写入。 | 网页已核对；本机回归通过 |
| `hardware` | 硬件与电源 | 硬件和电源各标签 | 已核对常规/休眠/UPS；成功响应及前端证实 support_* 控制提示音可用性，cool_fan 与 fan_type 位标记控制风扇档位。已修正客户端枚举全模式与显示不支持提示音问题。当前无 UPS。 | 网页已核对；本机回归通过 |
| `powerSchedule` | 电源计划 | 硬件和电源 → 电源计划 | 已核对官方列表的开/关机、启停、每天/每周显示；前端 save v1 整表提交 poweron_tasks/poweroff_tasks，每项 enabled/weekdays/hour/min，最多 200 条。已实现新增/编辑/移除及整体保存；完整清单预检、重叠检查、并发保护和结果回读测试通过。 | 网页已核对；本机回归通过 |
| `remoteAccess` | 远程访问 | 外部访问 → QuickConnect/路由器 | 已打开 QuickConnect 高级设置核对中继服务后取消；中继依赖保护属于当前连接限制。未改变路由器或 QuickConnect 设置。 | 网页已核对；本机回归通过 |
| `security` | 安全防护 | 安全性 / 安全防护 | 官方前端字段绑定和语言表共同证实 enable_port_check 是防火墙通知，不是防端口扫描；已修正 UI 标签，已同步契约说明。自动封锁阈值/期限与防火墙依赖已核对。 | 网页已核对；本机回归通过 |
| `region` | 区域与时间 | 区域选项 | 官方前端日期集合为 9 种 Y/m/d 排列分隔符组合，时间为 h:i a/H:i；已将原始格式代码输入改为双语选择器。没有改时或校时。 | 网页已核对；本机回归通过 |
| `ddns` | 动态域名 | 外部访问 → DDNS | 已打开新增表单核对供应商、主机、账号/密码、IPv4/IPv6、测试连接并取消；不发送测试或保存。 | 网页已核对；本机回归通过 |
| `packages` | 套件 | 套件中心 | 已核对官方目录、详情、已安装、常规设置、自动更新及来源页；实现原生搜索分类、详情、安装/更新/手动上传、依赖队列、进度、设置与来源，原只读升级入口改走安装计划。真实写入未执行。 | 网页已核对；本机回归通过 |
| `tasks` | 计划任务 | 任务计划 | 已核对列表和新增分类（计划/触发），官方存在用户脚本；客户端脚本任务与任务历史保持原范围，不执行任务。 | 网页已核对；本机回归通过 |
| `accounts` | 账号与权限 | 用户与群组 | 已核对用户/组列表及用户编辑信息、组、权限、空间配额、速度限制标签后取消；沿用上一轮 UID/GID 与权限修复。 | 网页已核对；本机回归通过 |
| `shareAccess` | 共享访问 | 共享文件夹权限 | 已核对控制面板共享文件夹管理入口；客户端本页是当前用户可见共享及有效访问权限摘要，不等同于新增/删除共享文件夹。 | 网页已核对；本机回归通过 |
| `processes` | 系统活动 | 资源监控 → 任务管理器 | 已切换资源监控任务管理器的服务/进程页；客户端提供摘要，不执行进程控制。 | 网页已核对；本机回归通过 |
| `logs` | 系统日志 | 日志中心 | 已打开日志中心当前日志，核对来源/类别、时间、用户、事件及分页；不读取或保存日志正文，不清除日志。 | 网页已核对；本机回归通过 |
| `connections` | 当前连接 | 资源监控 → 连接用户 | 已打开资源监控已连接用户页；客户端保留运行时 can_be_kicked 和目标确认，不进行断开。 | 网页已核对；本机回归通过 |

### 禁用门槛与文案

已追踪 NAS 设置现有禁用条件：保留忙碌、字段/能力缺失、权限不足、当前连接依赖、未修改、无效输入和结果未知等实际限制；旧套件升级的固定关闭由完整安装流程替代，ZRAM 和电源计划从原摘要补成真实保存能力。外接存储弹出、进程控制等未实现能力按用户“其余另做”保持非目标，不用空按钮假装开放。

修正了防火墙通知、Time Machine 播送、高级休眠、DSM 版本、套件停止等用户用语，以及存储、外接存储、ZRAM、硬盘检测/套件读取误显示区域时间错误的问题。去除重复只读标记；日期/时间改为可理解的选择器。技术字段仅保留在契约和源码注释。

### 验证与交付

本轮没有在真实 NAS 上安装、上传、卸载、清理、保存配置或执行电源操作；官方页面的自然后台请求不等同于客户端行为验收。浏览器设置窗口已取消，开发者工具已关闭。

| 验证 | 实际命令或范围 | 结果 |
| --- | --- | --- |
| Swift 全量 | `swift test --package-path apple --jobs 4` | 2325 项，161 项按运行条件跳过，0 失败；另有 Swift Testing 12 项通过。最终全量完成时间 2026-10-03 02:24，已包括确认窗口衔接及后台完成不切走当前页的修正；原生确认/取消另做独立 GUI 回归。 |
| 套件专项 | `swift test --package-path apple --jobs 4 --filter DsmPackageCenterTests`（全量中同样运行） | 26 项通过：目录、依赖顺序、两种编码、许可、签名、上传/清理、未知结果、同版本重装、取消、防重复、设置和来源。 |
| 原生 UI | `LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/testNAS各二级页面双语主题绘制不触发控制操作|WorkspacePresentationTests/testNAS网络与账号弹窗双语主题不保存配置|WorkspacePresentationTests/test套件中心目录搜索与安装设置双语主题不自动写入' bash tools/codex/run_macos_ui_checks.sh <隔离合成输出目录>` | 3 项检查退出码 0；152 组界面场景，分别生成原生窗口和布局快照。包含 21 页 × 双语 × 浅深色及编辑/安装/设置窗口；搜索实际输入，断言没有自动写请求；最终套件窗口回归另在 02:15 通过 1 项检查，覆盖详情进入停止确认并取消、控制请求为零。已目视核对目录、英文安装选项、深色设置、电源计划和 ZRAM。 |
| 本地化 | `python3 tools/localization/check_localization.py` | Apple 5485、Android 2188、Windows 3402；双语、参数、资源引用、硬编码检查通过。 |
| 请求契约 | `python3 tools/request-contract/validate_contracts.py` | 158 个请求样本、1 个写结果示例通过。 |
| 脱敏与索引 | `python3 tools/contract-validation/validate_fixtures.py` | 26 组样本、47 项私有 API 文档引用通过。 |
| 文档 | `python3 tools/codex/generate_api_reference.py` 与 `python3 tools/codex/check_documentation.py --strict-release` | 已按既定流程更新请求目录；链接、锚点、角色、时效与动态证据检查通过。 |
| 工程生成 | `xcodegen generate`（macOS 工程目录） | 通过；既定生成流程将 4 个新原生界面源文件加入工程，没有手改生成文件。 |
| Release 测试包 | 现有 `package.sh`，独立目录、arm64、本机临时签名、不启动 | 通过：Release 构建、严格签名校验、权限与 Sparkle 实际加载、arm64 检查、DMG 校验；包内不含 File Provider 扩展。 |

部分通用测试出现 Contacts 系统服务连接告警，测试断言通过；未导出联系人资料。GUI 检查由独立原生测试运行覆盖，不能把普通全量中的跳过当作通过。JSON Schema 白名单及合成样本已同步；本机未安装独立 jsonschema 校验器，实际执行的是仓库契约/隐私校验与 Swift 解析测试，没有另装依赖。

### 独立集成与只读对抗复核

源码实现完成后单独复查请求生成、权限/签名/许可边界、目标 ID/版本、安装与控制互斥、未知结果、清理所有权、参数类型、错误文案和平台影响。复查修正：缺进度的提交响应归未知；任务记录不可读时通过精确版本恢复；同版本重装未知不能靠旧版本误报成功；重复取消不重发；第三方目录失败保留官方目录；非法数值不截断/溢出；详情窗口退出后再展示控制确认；后台安装完成只刷新套件数据，不改变用户当前页面。没有凭据、真实地址、真实列表、HAR 或 NAS 截图进入仓库。

### 五端实施边界

| 平台 | 本轮实际范围 | 后续 |
| --- | --- | --- |
| macOS | 21 页核对与修正；ZRAM、电源计划和原生套件中心完整主流程 | 用户验证真实 NAS 写入与不同设备/权限 |
| iPhone | 共享模型和默认 Repository 方法兼容增量；无新管理界面 | 复杂运维当前不做，继续只读摘要和浏览器 DSM 替代，不新增移动 DAG |
| iPad | 与 iPhone 同范围 | 不因屏幕较大扩大为桌面运维；当前不做不标为待真机验证 |
| Windows | 未改代码 | 后续按 WinUI 对齐新契约，不能把旧更新提示称为安装功能 |
| Android | 未改代码 | 后续单独授权，按 SAF/前后台限制设计上传及队列 |

对应总控、Windows、Android 与 Apple 移动长期计划已同步影响说明，没有创建跨端实现任务。

### PENDING_USER_VALIDATION

以下只记录真实设备前置条件，不作为本轮测试入口的固定禁用门槛。

| 范围 | 前置条件与步骤 | 预期与需回传信息 |
| --- | --- | --- |
| 读取与文案 | 连接原 NAS，逐页查看；重点检查 ZRAM、提示音、风扇档位、日期/时间、防火墙通知、套件列表与搜索 | 与 DSM 对应；缺硬件/权限时说明真实限制。失败只回传脱敏页面、DSM 版本和错误文字 |
| 电源计划 | 先创建一条停用计划，保存后在 DSM 核对，再编辑/移除；真实开关机另选维护时段 | 星期/时分/启用状态一致，取消本地草稿不改 NAS，保存未知时只能刷新 |
| 内存压缩 | 在可维护环境切换并保存；重启由用户单独安排 | 保存后显示待重启，不能自动重启；重启后实际开关和服务表现待验 |
| 套件安装/更新 | 使用不承载真实业务的可信测试套件，查看依赖和位置后确认；分别测新装、更新、手动文件、许可、停止/启动/卸载 | 版本与 DSM 一致；未确认/权限/签名错误不执行；服务中断和数据迁移实际影响需用户确认 |
| 套件队列与恢复 | 测试套件安装中断开/恢复连接，点击检查结果；不要重复点击安装 | 仅查询既有任务；已有依赖不自动回滚；退出 App 后先在 DSM 检查任务 |
| 套件设置/来源 | 用专用来源或现有测试来源核对默认卷、通知和自动更新，明确接受来源证书信任的后果 | 设置保存后回读一致，移除来源不卸载套件；未知保存须刷新 |

确定的产品限制：付费/激活、首次测试版服务协议，以及带浏览器脚本、远程选项或无法等价呈现字段的专属安装向导在 DSM 完成；不执行脚本、不绕过许可或签名。UPS、外设、扩展网卡、其他 DSM build/权限和真实危险写入未在本轮验证。跨应用重启的安装任务恢复尚无持久化承诺。

### 最终测试包与工作区

在 `apple/Apps/DsmMac` 执行：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/dist/nas-settings-package-center-20261003" ./package.sh
```

- DMG：`apple/Apps/DsmMac/dist/nas-settings-package-center-20261003/LanStash-1.0.13-arm64.dmg`。
- 大小：26,189,182 字节；SHA-256：`6179089bc0a18d05efbd60d1481d86c3e8466f5e56ba1ed36066d78dd3840568`。
- App：同目录 `LanStash Test.app`，1.0.13 (23)，本机临时签名，沿用既定独立测试身份。
- 包中 `LanStashSourceCommit` 为基线 `8e6b0f3ec743e91cd43b315ca4aed7b2bd2d4d4f`，包含本轮未提交源码，不等同于仅该提交的内容。
- `codesign --verify --deep --strict`、包内权限与 Sparkle 加载探针、`hdiutil verify` 均通过；只验证主 App，Finder 挂载扩展不在临时签名包中。没有自动安装或启动。
- 保留此前测试包；只清理本轮临时日志、合成截图及打包中间目录，保留正式源码测试、彻底合成样本和最终 App/DMG。
- 上一轮修复已按用户要求先提交为 `8e6b0f3e`，没有推送。本轮留在 `codex/nas-settings-web-audit`，未执行提交、推送或正式发布。

## 套件中心反馈修复账本（2026-10-03）

源码、回归和独立本机测试包已完成。沿用 `codex/nas-settings-web-audit`；上一轮全部未提交改动和安装包保留，本轮未暂存、提交、推送或发布。

### 实际修复

| 用户反馈 | 确认的原因 | 修复结果 |
| --- | --- | --- |
| 点击更新立即报错 | 官方 `Package.feasibility_check` v1 成功只有 `success:true`，客户端通用读取要求存在 data，将成功误判为损坏 | 使用已有 `callVoid`；仍拒绝服务器错误、畸形响应和权限拒绝。套件设置及取消/清理等不读取返回正文的命令同样使用此通道，结果复查保留 |
| 设置数据无法读出 | `Setting.get.update_channel` 实际是 Boolean；原解析要求 stable/beta 字符串 | get 严格读取布尔，set 按官方保存函数继续发送 stable/beta；单卷响应缺少 default_vol 可正常显示，只有多个位置才显示选择器 |
| 设置弹窗标题、按钮漂到中间 | 错误分支只占内容固有高度，没有填满弹窗剩余空间 | 所有状态共用伸展内容区，标题顶部对齐，底部操作固定；错误标题改为“无法载入设置”；失败清除可写基线，保存需数据读取成功且确有修改 |
| 内存压缩仍称只读，其他修正文案未生效 | L10n 先读 App 主资源，而旧副本覆盖了共享包的新文案 | 同步两层中英文资源，覆盖内存压缩、电源计划、硬盘休眠、防火墙通知等旧说明；检查器增加主应用双语与共享同名值一致性检查 |

主要代码：

- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageCatalog.swift`
- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageSettings.swift`
- `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageInstallation.swift`
- `apple/Apps/DsmMac/Sources/PackageCenterSettingsView.swift`
- `apple/Apps/DsmMac/Resources/{en,zh-Hans}.lproj/Localizable.strings`
- `apple/Packages/DsmLocalization/Sources/Resources/{en,zh-Hans}.lproj/Localizable.strings`
- `tools/localization/check_localization.py`

全局文案复核针对实际 macOS 引用与条件判断：存储卷不可写、远程只读连接、权限编辑不允许修改、新挂载默认只读、尚未实现的 DSM 系统更新等仍保留其准确限制。后台任务等旧只读资源键已经没有界面引用，不据此改变功能。电源计划缺失快照时的旧“去 DSM 创建”提示改成读取失败的刷新路径；正常空清单继续提供本机新增计划入口。

### 官方环境实际观察

- DSM：7.2.1-69057 Update 12，信息中心当日重新核对；匿名设备与历史 lab-a 关系未确认，不改写历史验证等级。
- 唯一真实写动作：用户明确授权的官方 MediaServer 更新，**2.2.1-3406 → 2.2.2-3412**；官方最终安装版本与在线版本一致，状态“已启动”。未批量更新、安装其他套件或保存系统/套件设置。
- 实际观察预检、队列、check v2、upgrade v1 的任务回执、status v1，以及 Setting.get v1。此单目标官方更新为 behavior-verified；不等于修复后的岚仓客户端已经完成真实提交。
- 不保存地址、账号、真实路径、任务编号、响应正文或 HAR；浏览器临时请求记录已清除并关闭开发者工具。

最小字段、静态写格式与证据边界见[环境记录](../../api/discovery/environments/2026-10-03-package-center-followup.md)和[套件中心内部接口](../../api/discovery/endpoints/dsm-package-installation.md)。新增两个完全合成响应样本分别覆盖无 data 成功和布尔频道/缺省安装位置；五端计划、兼容矩阵及 Schema 已同步。iPhone/iPad、Windows、Android 没有新实现或新增验收声明。

### 实际验证

以下命令均在仓库根目录运行：

| 命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter DsmPackageCenterTests` | 首轮 26 项通过；随后补充 3 项回归，最终 29 项随完整测试通过 |
| `swift test --package-path apple --jobs 4` | 2328 项，161 项按既定条件跳过，0 失败；另 12 项 Swift Testing 测试通过 |
| `LANSTASH_UI_NATIVE_SCREENSHOTS=1 LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test套件中心目录搜索与安装设置双语主题不自动写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-package-center-fix.WImXNN/ui` | 1 项原生 UI 检查通过，40 个合成场景、80 张普通/原生截图；含双语双主题、正常/错误设置与真实 sheet 容器、目录和搜索空结果；确认不触发写入 |
| `python3 tools/localization/check_localization.py` | 通过；Apple 5486、Android 2188、Windows 3402；新增 App 主资源覆盖检查通过 |
| `python3 tools/contract-validation/validate_fixtures.py` | 28 组响应 fixture、47 项私有 API 引用通过 |
| `python3 tools/request-contract/validate_contracts.py` | 158 个请求 fixture、1 个写结果示例通过 |
| `git diff --check` | 通过 |

原生 UI 首次运行因测试在 sheet 动画及异步加载结束前点击仍禁用的“关闭”，出现 4 个关闭断言失败。测试改为等待明确错误状态，并继续断言标题/底部位置、保存禁用与最终关闭；没有删减断言，重跑通过。已人工查看中文深色真实错误弹窗、英文浅色错误窗口及中文浅色正常表单。

额外尝试 Draft 2020-12 通用 Schema 引擎校验时，系统和内置 Python 均缺少 jsonschema，未安装新依赖，不能将此项称为通过。Schema 已同步字段并保持有效 JSON；现有 fixture/请求门禁和 Swift 实际解析回归均已通过。

### 单独集成复核与只读对抗检查

- 本轮仅复用无正文命令通道；该通道仍校验 HTTP 成功、有效 JSON、success=true，并在出现 DSM error 时拒绝。读取方法仍强制存在数据及必需字段，未加入笼统布尔/字符串转换或吞错 fallback。
- 预检通过只生成计划，不触发安装；目录变更、缺失依赖、权限拒绝、并发、签名失败、未知提交不重放及最终目标版本核对的原回归保留并通过。
- 设置读取失败后旧草稿不能作为可写基线；sources 与 settings 的错误状态分别保留，保存仍先比较最新基线并回读。
- 没有改认证、会话/持久化格式、第三方依赖、工具链、签名规则或运行时权限。文案同步不改变真实只读/能力限制。
- 此为单独的源码集成复核，未声称经过其他模型审查或真实客户端写入验收。

### 测试包

按现有本机临时签名流程生成，使用独立输出目录 `apple/Apps/DsmMac/dist/package-center-fix-20261003`；保留旧包，不自动安装或启动，不含 Finder 本地磁盘挂载扩展。

构建命令：

```bash
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release \
LANSTASH_TARGET_ARCH=arm64 LANSTASH_SIGNING_IDENTITY=- \
LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_BUILD_ROOT=/tmp/dsm-package-center-fix.WImXNN/package-build \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/package-center-fix-20261003" \
bash apple/Apps/DsmMac/package.sh
```

产物：`apple/Apps/DsmMac/dist/package-center-fix-20261003/LanStash-1.0.13-arm64.dmg`，1.0.13 (23)，arm64，26,194,862 字节。

SHA-256：`74c77b62c664cb9a3a7e3702ad539ff4fc86442ce92bdc7718adf925d110c00a`。

Release 构建成功；既定打包脚本的严格签名、实际 Sparkle 加载、临时权限与架构、`hdiutil verify` 均通过。直接读取成品 App 的 Info.plist 确认在线更新关闭、无 File Provider 扩展。通过 `plutil` 读取成品主资源与共享 bundle：每种语言 2202 个主资源键、5486 个共享键全部匹配当前源码；重点检查 ZRAM、电源计划、防火墙通知、进阶休眠及设置错误标题。未启动真实应用或读取其账号。

旧 `nas-settings-package-center-20261003` 和 `settings-read-ui-fix-20261002` 测试包均保留。包内源码提交字段沿用基线 `8e6b0f3e`，实际包含当前未提交修复。交付前清理本轮临时日志、80 张合成截图与打包中间目录，保留源码、合成 fixture、账本及最终包。

### PENDING_USER_VALIDATION

标签表示尚待用户验收，不代表平台构建或真实写行为已通过。

- 前置条件：运行本次新测试包，连接对应 NAS；旧测试应用先退出。当前账号须具有相关权限。普通读取检查不需要更新其他套件。
- 先检查设置页常规、自动更新和套件来源，与 DSM 当前值比较；预期能正常加载，未修改时保存禁用，单卷不显示多余位置选择器。
- 检查内存压缩和电源计划；预期有编辑能力时没有旧只读/前往 DSM 修改说明，真实能力不足或只读权限仍明确受限。
- 客户端真实更新、设置保存、其他套件/依赖、断线/取消/恢复，以及正式签名、Intel、VoiceOver 真实操作仍未验证。后续由用户选定愿意更改的目标进行验证；本轮不继续更新第二个套件。
- 预期更新须经过明确目标/风险确认，最终版本正确；未知状态只刷新核对，不重复提交。设置保存后与 DSM 一致。
- 若失败，仅回传 DSM/套件版本、使用的测试包、操作步骤和脱敏错误文案；不要提供密码、会话、原始 HAR 或真实文件路径。

## 照片与套件更新二次反馈修复（2026-10-03）

源码、聚焦与完整回归、独立测试包均已完成。工作区沿用 `codex/nas-settings-web-audit`，保留前轮全部未提交改动与测试包；本轮没有暂存、提交或推送。

### 反馈、证据与修复

#### 照片底部“无法加载照片库”

在用户正在运行的上一轮 `package-center-fix-20261003/LanStash Test.app` 中只读复现：时间线与照片已经显示，点击“刷新”后，底部旧提示仍在。该位置属于操作反馈，区别于图库滚动区域内的读取错误。

源码确认：

- 通用解析失败的 AppError 在局部管理、保存、自动预览等路径被直接显示为“无法加载照片库”，错误范围被扩大。
- refresh 重置了图库 errorMessage，却没有清理已经结束的 managementMessage/saveMessage，因此用户照提示刷新仍不能消除旧反馈。

本轮修正为按操作上下文使用已有双语错误文案；保留权限/登录等具体错误。明确刷新时清理终态反馈，但待确认操作、分批继续、临时分享清理仍保留。自动预览有独立反馈，不阻挡图库清理旧的管理提示。图库本身真正读取失败时继续显示图库错误，不把错误简单吞掉。

**限制：**用户尚未补充截图最初由哪一次照片操作触发。本轮没有据此推断某个具体保存、分享或转换接口损坏，也没有修改照片 API。已验证的是错误归属、残留反馈与恢复保护。

#### 套件更新仍提示信息不完整

官方已安装清单中，截图的 Active Insight 更新候选为 `install_type=system`。官方前端 `_onCheckInstall` 明确允许 `system/system_hidden` 缺省普通 `volume_list`；客户端原实现先强制解析列表，再判断是否系统套件，合法系统形状也会抛出“信息不完整”。

现在只对这两种已知系统类型接受缺省/null 的普通存储列表；普通套件仍须返回合法安装位置，已占用状态仍拒绝。目标、版本、依赖、权限、签名与许可、提交前重查和最终版本确认均保留。

证据边界：安装类型为真实只读观察；缺省列表的分支为官方静态证据，已用合成样本和完整更新流程回归。本轮没有点击官方更新按钮，也没有取得该目标的真实 check 响应或完成新客户端实际更新。前轮一次 MediaServer 更新不被重复使用为本轮行为证据。

#### 更新检查窗口无法取消

原来准备阶段仅显示 ProgressView，触发读取的 Task 没有可取消句柄。现在：

- 只读准备显示“取消”，支持按钮及 Esc，立即关闭窗口并取消读取。
- 模型通过请求代次丢弃取消后的迟到成功或失败，旧请求不能恢复计划、覆盖新计划或弹出旧错误。
- 离开安装窗口、关闭模块也取消只读准备；Repository 保留互斥，不能强行绕过仍在退出的请求。
- 用户已经确认、正在提交安装或上传时显示“后台继续”，允许关闭窗口；不会把窗口关闭说成已经取消 NAS 安装。下载阶段继续沿用已有的真实取消与状态核对。

### 修改位置

| 范围 | 文件 |
| --- | --- |
| 照片反馈归属与生命周期 | `apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift` |
| 准备取消、请求代次与关闭模块 | `apple/Apps/DsmMac/Sources/NasAdministrationModel.swift` |
| 取消按钮、后台继续与取消静默收尾 | `apple/Apps/DsmMac/Sources/PackageInstallationSheet.swift`、`PackageCenterView.swift` |
| 系统安装类型与取消读取 | `apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+PackageCatalog.swift` |
| 聚焦回归 | `SynologyPhotosModelTests.swift`、`NasAdministrationModelTests.swift`、`DsmPackageCenterTests.swift`、`WorkspacePresentationTests.swift` |
| 契约 | `contracts/fixtures-redacted/packages/installation-check/synthetic-system-no-volume/`、`contracts/schemas/nas-package-center.schema.json`、既有套件中心端点与兼容矩阵 |

未增加依赖、资源键、持久化结构、权限、应用身份或公共方法；使用已有中英文资源。Apple 共享网络层对系统套件的形状兼容已同步五端计划；Windows/Android 未移植，iPhone/iPad 复杂运维的原取舍不变。照片修复只在 macOS 模型层，不改变任何平台的照片读取或写入契约。

### 实际验证

所有命令从仓库根目录运行，合成资料不连接 NAS。命令中的 LANSTASH_CHECK_DIR 表示本轮临时目录；机器专属随机路径已脱敏，复验时重新创建。

| 命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter NasAdministrationModelTests` | 96 项通过；含准备立即取消、迟到成功/失败、新计划保护和模块关闭 |
| `swift test --package-path apple --jobs 4 --filter DsmPackageCenterTests` | 31 项通过；含系统缺省位置、普通套件拒绝、占用拒绝、单次提交及最终版本确认 |
| `swift test --package-path apple --jobs 4 --filter SynologyPhotosModelTests` | 250 项通过；含局部失败范围、刷新清理、待确认/部分完成保留、原件保存错误 |
| `swift test --package-path apple --jobs 4` | 2337 项，163 项按既定条件跳过，2174 项通过，0 失败；另 12 项 Swift Testing 通过 |
| 下方原生 UI 命令 | 2 项通过，12 个场景、24 张合成/原生截图；双语浅深色，按钮与 Esc 取消，照片错误与刷新后状态 |
| `python3 tools/localization/check_localization.py` | 通过，Apple 5486、Android 2188、Windows 3402；主应用覆盖资源一致 |
| `python3 tools/contract-validation/validate_fixtures.py` | 29 组响应样本、47 项私有引用通过 |
| `python3 tools/request-contract/validate_contracts.py` | 158 个请求样本、1 个写结果示例通过 |
| `git diff --check` | 通过 |

```sh
LANSTASH_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lanstash-check.XXXXXX")"
LANSTASH_UI_NATIVE_SCREENSHOTS=1 \
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test套件准备窗口双语主题可取消且不提交安装|WorkspacePresentationTests/test照片局部错误双语主题不误报图库且刷新清除提示' \
bash tools/codex/run_macos_ui_checks.sh "$LANSTASH_CHECK_DIR/ui"
```

新增保存失败测试首次误用了测试替身和方法名称，造成测试编译失败；改为既有 PhotoServiceStub 与 save 方法后通过，未改业务断言。最后的完整回归包含该修正。人工查看中文深色取消窗口与英文浅色照片错误状态，位置和文字正确。

### 单独集成复核与只读对抗检查

- 系统位置兼容仅依赖明确目录类型；未知类型、普通套件缺少位置、占用、版本变化和依赖失败没有放宽。
- 取消只发生在未提交的准备 Task；已确认提交不冒充取消。取消或停用后的旧成功/错误不触发界面恢复，旧 defer 不清掉新请求状态。
- 照片清理仅处理终态提示；未知写结果、剩余目标和分享清理记录不被刷新丢弃，也不自动重放操作。
- 不根据翻译后的字符串判断行为；照片错误按 AppError.category 区分，套件按稳定安装类型和阶段判断。
- 本轮为单独的源码与集成复核，没有宣称其他模型复核、完整 VoiceOver 或真实新客户端更新已通过。

### 测试包

独立输出目录：`apple/Apps/DsmMac/dist/photos-package-fix-20261003`。沿用本机临时签名与 arm64 Release，不自动安装或启动；保留上一轮包，不包含 Finder 本地磁盘挂载扩展。

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=arm64 \
LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_BUILD_ROOT="$LANSTASH_CHECK_DIR/package-build" \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-package-fix-20261003" \
bash apple/Apps/DsmMac/package.sh
```

最终包：`apple/Apps/DsmMac/dist/photos-package-fix-20261003/LanStash-1.0.13-arm64.dmg`，1.0.13 (23) arm64，26,185,471 字节。

SHA-256：`2f585372c284a50d721bc72c439b6848f7dcc7427cc9170d7699649833894db3`。

Release 构建、严格签名、专用临时权限与 Sparkle 实际加载检查通过，`hdiutil verify` 校验有效。成品 Info.plist 确认在线更新关闭、无 File Provider 扩展。通过 plutil 逐项读取成品资源：每种语言主资源 2202 键、共享资源 5486 键，全部与当前源码一致；取消、后台继续和照片局部错误的双语文案正确。源码基线为 `8e6b0f3e`，产物包含当前全部未提交改动，旧测试包保留。

严格文档检查 `python3 tools/codex/check_documentation.py --strict-release` 通过。交付前删除本轮临时日志、24 张合成截图与打包中间目录；不删除用户截图或旧包。

### PENDING_USER_VALIDATION

前置条件：退出旧测试应用，打开本次新包，连接有相应权限的 NAS。标签仅标记待办，不是验证等级。

1. 打开照片页并刷新，预期正常内容保持可浏览，不残留已结束操作的旧图库错误。若再次出现，请说明刚才执行的具体操作；这用于继续定位最初的实际失败点。
2. 在套件更新检查窗口点击“取消”或按 Esc，预期立即关闭，稍后不弹回旧错误、不自动开始安装；之后可重新检查。
3. 如用户选择实际更新，确认列表与目标版本后再提交；系统套件不应因没有普通存储列表被拦截，最终版本须与 DSM 一致。正式安装关闭窗口应显示后台继续，不能声称已取消。
4. 新客户端真实更新、复杂依赖、网络中断、其他 DSM/套件版本、正式签名、Intel 和真实 VoiceOver 仍未验证。仅回传版本、触发步骤和脱敏错误；不要发送凭据、原始 HAR 或真实照片/文件路径。

观察记录见[环境快照](../../api/discovery/environments/2026-10-03-photos-package-followup.md)。浏览器临时记录已清除并关闭开发者工具；交付前清理本轮临时日志、合成截图与打包中间目录。

## macOS Chat 正确性修复账本

### 范围与基线

- 用户于 2026-10-03 授权修复此前审查发现的问题；真实发送测试仅限已指定的主账号与测试账号之间的会话，不删除原有消息。
- 起点：`main` / `2fada4af`，工作区干净。修改范围为 macOS Chat、共享 Apple Chat Adapter、相关正式测试和英中资源。
- 沿用 `ChatRepository` 及既有消息/会话创建结果接口；不新增 NAS API、公开类型、持久化格式、依赖、权限或应用标识。
- 独立测试包不覆盖旧包，不自动安装或启动；正式发布和 Git 提交/推送不在本轮范围。
- 非目标：新增搜索、线程、投票参与、录音、频道管理、通知或完整加密能力；不修改 Windows、Android 或移动端 App 源码。

### 修复顺序与证据

| 顺序 | 用户结果 / 缺陷 | 源码基线 | 安全约束与验收 |
|---|---|---|---|
| 1 | 发送结果不明与失败分开；附件断线不重复上传；结果核对只认稳定消息身份 | `ChatWorkspaceModel.send/retryMessage`、`DsmChatRepository.sendMessage*` | 保留原草稿和请求 ID；未知不重放；补丢回执与跨会话回调回归 |
| 2 | 加密会话不提供未经实现的收发；本人身份不以昵称判断 | `canSendText/canDelete`、`isOwnedByCurrentUser` | 明确他人身份优先；未知归属不开放本人操作 |
| 3 | 较早消息删除有完整定位与回读；异常列表不能伪装空列表 | `deleteMessage/listMessages` | 完整分页或明确拒绝；删除确认、权限与重复保护保持 |
| 4 | 投票及转发不误报结果、不在未知时重新创建 | `createPoll/forwardMessage` | 固定原操作、内容和目标；验证不足保留待核对 |
| 5 | 刷新处理删除、未读以实际读到的内容为界；切换会话隔离消息和附件 | `refreshCurrentConversation/applyingLocalReadState`、`ChatConversationView` | 迟到结果不串入新会话；保留历史与独立草稿 |
| 6 | 建群重试继续原操作；错误态、预览和无障碍提示准确 | `NewChatSheet`、消息行与预览 | 双语、浅深色、合成 UI；真实 VoiceOver 待用户验收 |

### 验证状态

源码、自动化、共享 Apple 构建与独立 macOS 包已完成。未安装或启动新包；修复后的真实 NAS 行为不以自动化或构建替代。

#### 实际改动与关键决策

- macOS 文字和附件均接入既有 `ChatMessageSendOutcome`；内部结果不明时仅续读原请求，不按正文/文件名/180 秒时间窗认领另一条消息，不直接丢弃有可能已经提交的消息。
- 认证写回执提供稳定 ID 时，精确回读同一会话和内容；本人标记缺失不会单独造成误报，但明确他人身份、加密内容、正文或附件不符均拒绝成功。昵称不再作为本人身份依据。
- 附件旧入口也走相同结果流程；切换会话后失败回调更新原会话分桶。附件草稿按会话保留，选择器与预览任务绑定所属视图，迟到提交不使用新会话。
- 删除查遍分页定位旧消息并复查删除结果；历史、提醒、定时和置顶列表不再把结构错误当成空列表。破损分页和跨会话记录拒绝继续，内部历史扫描不额外缓存全部消息正文。
- 投票回读实际投票、选项和设置，保留真实选项 ID；提醒回读消息及时间；定时消息保留稳定任务 ID；表单重新打开与重试沿用原草稿。转发先检查来源/接收人，成功回执后检查目标新增记录，丢回执不重放；批量重试复用各项请求 ID。
- 自动刷新替换已覆盖的最新范围，保留更早历史和本地发送；未读只按可见详情实际成功读取的时间更新，失败、空内容、加密和未知活动时间不清零。
- 一对一置顶消息提供只读入口，不扩张原群聊置顶写范围。原图预览使用既有下载接口，已知大小不超过 64 MiB；超限、大小未知或预览失败时提示另存为。原件和临时文件及时清理。
- 普通消息辅助功能包含正文；发送操作的恢复入口可单独访问。错误与加密状态有独立页面，不伪装空会话。遵守用户追加文案规则：内部结果分类不出现在界面，不把用户当作测试人员。

#### 已运行验证

| 命令 | 结果 |
|---|---|
| `swift test --package-path apple --jobs 4 --filter 'Chat'` | 最终 120 项通过、0 失败；包括刷新操作实际重新读取消息且保持原请求身份 |
| `swift test --package-path apple --jobs 4` | 最终源码 2,382 项 XCTest，2,215 通过、167 按原门禁跳过、0 失败；另 12 项 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test消息' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-chat-fix-ui` | 4 项通过，覆盖中英、浅深色、消息恢复、错误/加密状态、原有表单，以及正文和恢复入口的辅助功能属性 |
| `python3 tools/localization/check_localization.py` | 通过；Apple 5,509 项资源，双语、参数、引用与硬编码扫描通过 |
| `python3 tools/codex/check_documentation.py`、`git diff --check` | 通过 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-fix-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | iPhone/iPad 通用模拟器构建通过；不代表真机行为验收 |
| 既有 `apple/Apps/DsmMac/package.sh`，`LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`，独立 build/dist 目录 | Release arm64 构建、临时签名、Hardened Runtime 权限检查、Sparkle 实际加载、架构及 DMG 完整性检查均通过 |

全量测试的跳过项为项目原有显式 UI/环境门禁；Chat 的四项 UI 用例已另行执行，没有把跳过计作通过。旧测试中以昵称覆盖明确他人身份的预期已纠正，并新增权威身份正反例；投票、附件与定时用例补入真实对象回读，未删除原字段、进度或去重断言。

#### 独立测试包

- 版本：1.0.13（23），Release / arm64，本机临时签名。
- App：`apple/Apps/DsmMac/dist/chat-reliability-20261003/LanStash Test.app`。
- 安装镜像：`apple/Apps/DsmMac/dist/chat-reliability-20261003/LanStash-1.0.13-arm64.dmg`。
- 镜像 SHA-256：`e9f657146495fa2bfe8e6b5de2cfb22161516b01ad5ea28293b45c1b3258f908`。
- 沿用项目本机测试包标识和权限，不覆盖旧包，不自动启动。按既定流程移除临时签名不支持的本地磁盘挂载扩展；正式 App/扩展权限和源码未改变。
- 临时日志、合成截图及本轮独立构建中间目录在保存此记录后清理；正式回归源码和交付包保留。工作区变更未提交或推送。

#### 独立集成与只读对抗复核

- 单独复查 UI → 模型 → Adapter 的入口、原请求保留、重复提交、迟到结果和成功提示；通过无稳定身份、明确他人身份、旧同文消息、坏列表、历史分页、跨会话及传输中断的反例验证。
- Cookie/令牌、证书处理、附件临时文件权限、危险操作确认和公共 `ChatRepository` 签名均保留；没有引入新的公开类型、请求方法、依赖或存储格式。
- 新代码使用共享 Apple Adapter，因此 iPhone/iPad 的既有文字、附件、身份、列表解析和本人消息删除会受到修正影响；移动 App 源码没有扩张范围，构建已通过。Windows/Android 源码未改，不借用 Apple 结果宣称其对应缺陷已修复。
- Debug Xcode 构建已完成，但现有打包脚本只扫描主启动文件，未扫描 `LanStash.debug.dylib`，因而拒绝该次包。保持打包规则不变，改用项目默认 Release 配置重新打包；不以此失败的 Debug 包交付。
- Release 首次依赖解析遇到 GitHub 连接超时。构建进程临时通过 Git URL 映射复用 `apple/.build/repositories/Sparkle-09d89c53`；其 `2.9.6` 标签的 commit 为 `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`，与 `apple/Package.resolved` 完全一致。没有修改全局或仓库 Git 配置、依赖版本、网络设置、打包脚本或校验门禁。
- 状态仅在进程内保存，重启后不承诺恢复；没有扩大到真实断网、睡眠、其他 DSM/Chat 版本或加密协议验证。

#### PENDING_USER_VALIDATION

前置：独立 macOS 测试包、兼容 Chat Server 和可丢弃的专用测试会话。需要核对断网/取消后未知结果、真实附件和投票响应、历史删除权限、跨客户端删除、睡眠重连以及 VoiceOver。只回传 DSM/Chat 版本、连接类别、脱敏步骤和错误类别，不回传凭据、地址、消息正文或原始响应。

共享 Apple Adapter 的兼容修正会影响 iPhone/iPad 的既有 Chat 调用；须补共享包与可用的移动端构建/聚焦回归，不能以 macOS 通过替代移动设备验收。Windows/Android 只记录审查线索，不变更实现或提升验证等级。

本账本保留第一轮修复与旧测试包的历史记录。用户随后追加的五组功能、工作区常驻实时连接和容器修复统一交付于 [MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md](MACOS_FEEDBACK_HISTORY.md#macos-chat-五组功能补齐账本)，后者为本轮最新产物和验证入口。

## macOS Chat 五组功能补齐账本

### 授权、基线与变更边界

- 用户于 2026-10-03 明确要求补齐：旧消息搜索、消息编辑和回复、参与投票、音视频播放与录音发送、新消息通知与跨端已读同步。
- 在 `main` / `2fada4af` 的现有未提交修复上继续；保留 [历史账本](MACOS_FEEDBACK_HISTORY.md#macos-chat-正确性修复账本) 所述全部改动，不提交或推送。
- 必要变更：在现有 `ChatRepository` 和消息模型上追加兼容能力、默认关闭的旧提供者实现及可选字段；macOS 主 App 增加系统麦克风使用声明和录音所需权限。已在实现前向用户说明必要性、影响及回滚，并沿用本轮五项功能的明确授权。
- 只在点击录音时请求麦克风；开发过程中不替用户接受系统授权，不自动录音。音视频读取沿用既有附件接口，不将会话凭据交给播放器或消息中的任意 URL。
- 不变更依赖、最低系统版本、应用标识、凭据存储或既有持久化格式；新增接口为兼容增量，旧调用继续有效，无数据迁移。回滚移除新入口、增量能力和麦克风声明即可。
- Windows、Android 和 Apple 移动端只同步契约影响与兼容说明，不扩张 App 功能；共享 Apple 修改必须回归和构建。
- 用户追加要求：同步 API 文档；Chat 启用时持续保持实时连接，独立于当前页面，后台收到消息不自动已读。
- 界面只使用日常业务文案；内部协议、测试和结果复核不进入用户操作流程。

### 功能账本与依赖

| 顺序 | 用户可完成的结果 | 基线与依赖 | 当前证据 / 安全边界 |
|---|---|---|---|
| 1 | 搜索 NAS 上的旧消息并查看结果 | `ChatWorkspaceView/Model`；`Post.search` 的普通搜索形态 | 已实现；Post.search v5 真实只读验证，Post.list 改用锚点分页；合成回归通过 |
| 2 | 编辑本人消息，回复指定消息并查看讨论 | 既有消息身份、作者判断和发送结果；编辑/线程实际请求 | 已实现；指定合成消息编辑与线程回复有行为回读证据；尊重本人权限和管理员时间限制，未知不重放 |
| 3 | 单选/多选参与投票并显示自己的选择和票数 | `ChatPoll`；`Post.Vote.vote/get_choices` | 已实现；合成投票参与及选择回读已验证；单选/多选、关闭和过期、选项变化有回归 |
| 4 | 播放音视频，录制、试听、发送或丢弃语音 | `Post.File.get`、既有单附件发送、AVFoundation/AVKit | 已实现原生播放器、录音/试听/丢弃/发送；离线 AAC 解码与文件生命周期回归通过；真实麦克风与通知授权待用户 |
| 5 | 收到新消息通知，阅读后同步网页及其他设备 | 既有实时/轮询、UserNotifications、已读写接口 | 已实现工作区常驻实时连接、隐私通知与可见消息已读；Channel.view 的实际已读回读已验证，系统通知交互待用户 |

独立集成范围：本任务单一修改者负责 Chat UI/模型、共享 Core/Network、双语资源、工程生成及文档。每组同时补正式回归；完成后单独检查跨 NAS/会话、重复提交、取消、权限、通知隐私和已读边界。

### 发现与验收记录

网络观察记录见 `docs/api/discovery/environments/2026-10-03-chat-five-features-observation.md`。仅在用户指定的主账号与测试账号会话使用合成内容；不改原有真实消息，不导出原始 HAR、Cookie、令牌或真实资料。

#### 实际改动与关键决策

- `ChatDetailsViews.swift` 提供服务器旧消息搜索、本人编辑、线程讨论和单/多选投票；编辑与投票草稿绑定原始请求身份，结果未知只读取，不重复写。校验会话、消息作者、管理员编辑开关和允许时长。
- `DsmChatRepository` 修正 Post.list 使用 `post_id/prev_count/next_count/thread_id`，不再把 NAS 忽略的 offset/limit 当真实分页；搜索使用 search_results/total。修正创建投票的 choices 对象数组与 options 对象编码，保留真实选项字符串 ID。
- 新增共享领域能力为兼容增量，旧 Repository 默认不支持；依用户追加授权，新编辑、回复、投票和已读依据实际 API 能力开放，不按精确 DSM/Chat 版本拦截。移动只读包装器不开放新写入口。
- `ChatNativeMedia` 通过既有附件鉴权接口下载到私有临时目录供 AVPlayer 使用，不把凭据传给媒体 URL。可播放音视频；录音最长五分钟，AAC，先试听再发送。仅按钮操作请求麦克风授权；录音、已发送暂存与播放器文件按生命周期清理。
- `ChatNotificationService` 通知只含会话标题和本次连接的随机导航标识，不带正文、NAS 地址或凭据。历史基线、本人消息和加密会话不通知；点击后定位对应已连接 NAS。测试注入通知回调，不弹系统权限提示。
- 实时连接归属已连接工作区：登录后启用 Chat 即启动，切换文件/照片或 NAS 页面不中断，模块关闭、断开与退出才停止；停用和迟到连接回调有回归。
- 跨端已读使用服务器结果更新，移除本地清零掩码；只在消息页、活动窗口且实际布局显示最新已确认消息时推进。后台收到消息和正在查看旧历史都不清零；线程已读接受回执没有等价回读，只记录 observed。
- 主 App/本地测试包同步麦克风隐私声明与 audio-input 权限。四个新源文件通过项目既定 `xcodegen generate --spec apple/Apps/DsmMac/project.yml` 纳入 Xcode target；未手改生成工程。
- 双语资源齐全；容器修复并入同一新测试包，详见 [历史账本](MACOS_FEEDBACK_HISTORY.md#macos-容器映像搜索与下载修复)。

#### 已运行验证

| 实际命令 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter Chat` | 145 项通过、0 失败；包括实时连接生命周期、窗口/底部可见证据、跨端已读、编辑/线程/投票、通知与媒体临时文件 |
| `swift test --package-path apple --jobs 4` | 合并容器修复后最终 2,415 项 XCTest：2,246 通过、169 按既有 UI/环境门禁跳过、0 失败；另 12 项 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test消息' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-chat-five-ui` | 5 项通过；五种新增面板、英中/浅深色、辅助功能、无自动发送或录音。截图的原生合成存在局部缺失，不能代替真实系统窗口和 VoiceOver 验收 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test容器下载恢复与搜索错误' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-container-ui` | 1 项通过，覆盖 20 个状态/语言/主题组合；错误不冒充空结果，不自动写 |
| `python3 tools/localization/check_localization.py` | 最终 Apple 5,576、Android 2,188、Windows 3,402；双语、占位符、引用、硬编码扫描均通过 |
| `python3 tools/request-contract/validate_contracts.py` | 169 个请求 fixture、1 个写结果示例通过 |
| `python3 tools/contract-validation/validate_fixtures.py` | 29 组 fixture、48 项私有 API 引用通过 |
| `python3 tools/codex/generate_api_reference.py --check`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过；请求目录通过既定工具生成 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-five-features-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | 最终共享源码的 iPhone/iPad 通用模拟器构建通过；不等于设备运行验收 |

依赖解析只在构建进程中用临时 Git URL 映射复用既有 Sparkle 2.9.6 精确缓存，未改仓库/全局配置或依赖。首次打包门禁发现四个新文件未纳入 Xcode target，已由既定生成流程修复；本地化检查同时发现主 App 覆盖资源与共享资源不同，已同步英中两份，最终检查通过。

#### 独立集成与只读对抗复核

逐项复核 UI → 模型 → Adapter 的跨 NAS/会话、稳定身份、原草稿、取消、回调迟到、重复提交、权限和最终状态。读取失败不伪装空内容；未知写入不重放；附件只读既有凭据边界内内容；通知不泄露正文；背景同步不触发后台已读。聚焦回归、全量回归与共享移动构建通过。没有为测试降低断言或删除既有测试，系统/硬件条件以原门禁保留。

#### PENDING_USER_VALIDATION

前置：本轮独立 macOS 测试包、已安装 Chat 的 NAS 和可丢弃测试会话；其他版本的真实兼容性尚待核验；用户主动授予系统麦克风及通知权限。

1. 搜索历史、编辑本人消息、回复并参加单/多选投票，网页端应看到同一消息、线程与选择；编辑限制/关闭投票应明确不可提交，断网恢复不重复创建。
2. 录制一段语音，试听、丢弃与重新录制，发送后在官方网页或另一设备播放；视频/音频播放、音量与系统实际编解码仍需真实设备。只回传文件格式、近似大小和脱敏错误，不回传私密内容。
3. Chat 启用后切到文件/照片页，用测试账号来消息：应有未读/系统通知；点通知跳回目标会话；后台和旧历史阅读时不自动清零。活动窗口看到最新消息后，网页/另一设备已读同步。
4. 验证睡眠/唤醒、弱网、切换 NAS、关闭模块与重新启用；不会串号、重复通知或在退出后持续连接。真实 VoiceOver、动态文字和降低动态效果需用户系统验收。

线程已读没有等价回读证据；系统通知点击和麦克风授权不以合成测试替代。其他 DSM/套件版本按实际能力开放，并保留权限、去重及回读保护；Windows/Android 未修改实现，移动 App 未扩张功能。

#### 交付产物

- 版本：1.0.13（23），Release / arm64，本机临时签名，未安装或启动。
- App：`apple/Apps/DsmMac/dist/chat-and-container-20261003/LanStash Test.app`。
- DMG：`apple/Apps/DsmMac/dist/chat-and-container-20261003/LanStash-1.0.13-arm64.dmg`，26,502,223 字节。
- SHA-256：`c6384860a92db19339614390c45e3e22074040acc2d24eec45680283f333211c`；同目录 `SHA256SUMS` 可复核。
- 构建入口：`apple/Apps/DsmMac/package.sh`；环境 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0`，本轮专用 `LANSTASH_BUILD_ROOT=apple/Apps/DsmMac/build/chat-and-container-20261003` 和 `LANSTASH_DIST_DIR=apple/Apps/DsmMac/dist/chat-and-container-20261003`（运行时均传绝对路径）。临时 Git URL 映射复用精确 Sparkle 缓存，未改持久配置。
- 最终 Release 构建、严格递归签名校验、Hardened Runtime 与精确权限清单、Sparkle 实际加载（`library loaded`）、arm64 架构、DMG checksum 均通过。另检查包内中英覆盖资源，旧“检查下载状态”文案已替换，麦克风隐私说明已进入产物。
- 既定本机测试包标识与正式版隔离，保留此前 `chat-reliability-20261003` 交付包；临时签名包按既定流程移除本地磁盘挂载扩展。没有放开证书验证、正式权限或 NAS 访问控制。
- 打包曾因录音新增 audio-input 与旧测试包精确清单不一致而失败；现在清单只允许 audio-input 与既有库验证例外，不接受其他运行时例外，12 项签名回归及实际加载门禁通过。
- 临时日志、合成截图、音频源素材、静态脚本和本轮专用 Mac/iOS 构建中间目录已清理；保留正式自动化源码及 App/DMG/校验和。所有变更仍在 `main` 工作区，未暂存、提交或推送。


#### 用户追加：开放已实现功能与版本限制

用户明确选择“开放所有功能和版本限制，保留必要安全保护”。本轮范围为正在交付的 macOS App；不自动操作 NAS 设置、不修改其他端 App。

| 范围 | 代码核查 | 处理 |
| --- | --- | --- |
| Chat 新编辑/回复/投票/已读 | DsmChatRepository 的 DSM/Chat 精确版本白名单 | 移除额外白名单与版本元数据读取，依据实际 API 能力开放；保留会话访问、作者身份、编辑策略、并发和写后回读 |
| 照片管理与删除 | LoginViewModel 已传 deletionEnabled=true；Photos 按 API 与实际空间/账号权限 | 已开放，不改用户权限或共享空间设置 |
| 容器网络创建 | LoginViewModel 已传 containerNetworkCreationEnabled=true | 已开放；保留输入校验、确认、占用、状态回读 |
| 文件、下载、NAS 设置、VMM | 现有入口按 API 能力和目标可操作状态开放，没有发现额外 DSM/build 白名单 | 保留实际接口版本要求，不用 NAS 未声明的版本发请求 |
| 系统权限与本地测试包 | 麦克风权限、Hardened Runtime、唯一库验证例外、File Provider 正式授权 | 保留；签名检查允许录音这一必要权限，其余额外运行时例外继续拒绝 |
| 用户模块选择、删除/写回确认 | 属于用户设置与危险操作保护 | 保留，不替用户启用模块或批准删除/写回 |

此授权改变功能开放策略，不提升未知 DSM/Chat 版本的验证等级；真实兼容性按实际结果记录。

本地签名回归：`python3 tools/release/test_macos_signing.py` 12 项通过，含额外运行时例外拒绝、正式 App/扩展不携带库验证例外、麦克风仅用于主 App、英中隐私说明和合成动态库实际加载。首次新回归的管道输入与 Python 3.14 plist 读取方式不符，已改为与真实脚本相同的普通文件输入；未放宽权限断言。

## macOS 容器映像搜索与下载修复

### 范围与基线

用户报告搜索下载流程停在无法确认下载状态，并要求移除开发流程文案。保留同工作区的 Chat 修改；本切片仅修改容器搜索、标签、下载跟踪和相关双语文案。main 未提交；不创建分支，不自动推送，用户随后明确授权必要的 Chrome NAS 网页下载测试；仅下载独立小体积官方镜像，不运行容器或替换既有镜像。

| 主流程 | 现有证据 | 修复目标 | 风险与验证 |
| --- | --- | --- | --- |
| 搜索和标签选择 | DsmServiceManagementRepository / PullImageSheet | 区分空结果与读取失败，防止迟到结果覆盖当前选择 | 只读；聚焦合成测试 |
| 下载状态 | ContainerImagePullModel / DsmServiceManagementRepository | 读取暂时失败后继续自动恢复，绑定原 task_id，不重放启动 | 私有写入口保持确认、权限、防重与回读；真实写后验证待用户 |
| 界面表达 | 双语语言资源、ServiceManagementView | 清楚显示下载进度、错误原因和恢复操作 | 双语与浅深色检查 |

### 验证记录

发现见 `docs/api/discovery/environments/2026-10-03-container-image-pull-observation.md`。

### 根因与修改

- Registry 宣称最高 v2，但 search 方法只接受 v1。官方同关键词对照：v1 成功、v2 返回 103。共享 Apple Adapter 固定 search v1，严格读取 data 数组，格式错误不冒充没有匹配项。
- 模型原先仅刷新 downloading，首次失败进入 needsReview 后永远不自动刷新。现自动查询 downloading 和 needsReview，继续绑定原 task_id；无回执不能猜绑定或重发。
- 受控下载已取得 task_id 并读到 finished=false/downloaded，随后 NAS 返回 1202，最终完整清单没有测试标签，聚合任务中原 ID 消失。该明确 Docker 失败保存终态；传输或暂时状态错误继续恢复。只有 pull_status 的 1202 可判此终态，最终 Image.list 的同码仍是读取失败，补独立回归。
- 搜索错误单独展示原因与“重新搜索”；标签可“重新加载版本”，切换与关闭取消旧读取并隔离迟到结果。关闭按钮不再暗示能够取消 NAS 下载。
- 下载及相关容器操作的双语文案移除“检查下载状态”“结果尚未确认”“不要再次提交”等内部流程说法；确认、权限、重复提交和最终结果核对保留。共享资源与主 App 的覆盖资源同步。

### 实际验证

| 命令/操作 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter 'ContainerImagePull\|DsmServiceManagementRepositoryTests.test镜像仓库搜索'` | 当时 24 项通过、0 失败；后续补“完成后列表错误不得误判失败”一例，纳入最终全量测试 |
| `swift test --package-path apple --jobs 4` | 最终 2,415 XCTest：2,246 通过、169 按既有门禁跳过、0 失败；另 12 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test容器下载恢复与搜索错误' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-container-ui` | 1 项通过，20 种状态/语言/主题组合；验证错误/进度/完成/拒绝、辅助功能可读、搜索失败不冒充空结果、不自动再次下载 |
| `python3 tools/localization/check_localization.py` | Apple 5,576 资源；双语、占位符、引用、硬编码均通过 |
| `python3 tools/request-contract/validate_contracts.py`、`python3 tools/contract-validation/validate_fixtures.py` | 169 个请求快照、1 个写结果示例；29 组数据 fixture 和 48 项私有 API 引用通过 |
| `python3 tools/codex/generate_api_reference.py --check`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过 |
| iPhone/iPad 通用模拟器 Debug 构建 | 最终共享代码构建通过，完整命令见 Chat 五组功能账本 |
| 当前 Chrome NAS 官方页面请求入口 | search v1 与 tags 读取成功；小体积官方镜像下载启动并运行，之后 NAS 1202 失败；没有新增镜像、没有创建/运行容器，不声称成功下载通过 |

### 独立集成及只读对抗复核

完成 UI/模型/共享 Adapter 复核：同目标重复点击、无回执、任务编号类型、连续读取失败、1202 与传输错误、旧镜像存在、畸形结束标记、跨仓库/标签回显、最终清单不完整均有回归。保留下载/删除互斥，不加入跨账号任务认领或凭名称成功推断；最终清单失败不能覆盖为下载失败。依照项目生成流程更新 Xcode 文件成员、同步双语主 App 覆盖资源后再构建。

### PENDING_USER_VALIDATION

- 当前 NAS 已能搜索，真实下载在 NAS 端失败；此前 1202 返回值本身没有证明具体原因。用户随后提供的当日日志补充了 3 次匿名拉取限额、2 次镜像中转服务 TLS 握手超时，见[日志分析与挂载修复账本](MACOS_FEEDBACK_HISTORY.md#本地磁盘挂载开启读写后仍只读修复账本)。先解决 NAS 访问仓库的连通性与仓库认证/额度，再用此独立测试包下载可丢弃标签：应进入下载中，完成后只在最终镜像列表确实可用时显示完成。该日志不等于其他仓库或所有客户端路径均已验证。
- 弱网后自动恢复、窗口关闭重开、普通账号/权限撤销、长时间下载待验。只回传 DSM/Container Manager 版本、连接类别、脱敏步骤和错误类别，不回传地址、凭据、原始响应或用户镜像清单。
- 其他 NAS 版本不借用本次证据。Windows/Android 仅记录契约风险，未改代码；iPhone/iPad 只回归共享层。
- 测试包、签名验证、校验和与清理记录见 [历史账本](MACOS_FEEDBACK_HISTORY.md#macos-chat-五组功能补齐账本)。所有变更保留在 main 工作区，未提交或推送。


最终交付：与 Chat 五项补齐、常驻连接和开放策略合并在 `dist/chat-and-container-20261003` 的 1.0.13（23）Release arm64 本机测试包；签名、精确权限、Sparkle 实際加载与 DMG 校验均通过，未安装或启动。NAS 的成功下载仍未验证，不能以打包通过代替该结果。

## 本地磁盘挂载开启读写后仍只读：修复账本

### 范围与基线

用户报告开启编辑和删除、重新挂载后 Finder 仍只读；同时提供 Container Manager 导出日志要求只读分析。main 的既有 Chat/容器修改全部保留，不提交、不推送、不调整 NAS 设置，不触碰真实文件。

已安装正式 App 为 1.0.13（23），包含同版本 File Provider 扩展；App Group 声明一致。安装包来源提交与 HEAD 间的 File Provider/写回存储/设置源码无差异，因此不能仅以应用版本较旧解释该问题。

| 主流程 | 源码证据 | 目标与保护 |
| --- | --- | --- |
| 开关保存 | DesktopDriveWritebackSettingsSheet / DesktopDriveWritebackStore | 只更新当前挂载；保留编辑/删除的独立确认 |
| Finder 元数据 | ProviderItem / ProviderRuntime | 权限变化被系统观察到；内容版本不因权限变化失效 |
| 增量刷新 | ProviderChangeAnchor / DesktopDriveChangeJournal | 本地授权变化不能被未变化的 NAS 文件快照吞掉；旧锚点安全重新枚举 |
| 权限解析 | DsmFileRepository 的 perm / mount_point_type | 核实真实只读字段，不通过移除权限判断来解锁 |

### Container Manager 日志结论

用户提供的日志含 5 条本日下载错误：20:02:58 与 21:11:10 为 TLS handshake timeout；20:25:09、21:08:34、21:09:13 为 unauthenticated pull rate limit。前者为 NAS 连接仓库/认证服务超时，后者为镜像仓库拒绝超出匿名额度的拉取。与用户报告官方网页同样失败及先前浏览器受控下载失败一致，错误在 NAS 的 Docker 拉取链路，不能归因于 macOS UI 或请求状态显示。日志不证明所有镜像/仓库不可用，也不能据此指定 DNS、代理或证书配置为唯一原因。

两条超时均指向用户配置的镜像中转服务；限额错误来自 Docker Hub，但日志不足以区分限额归属 NAS 出口还是中转服务的共用上游额度。DSM 登录不等于镜像仓库认证；先检查该中转服务是否可用，再核对实际拉取链路的仓库认证与额度，不通过关闭 TLS 校验处理连接超时。

原始 HTML、账号、主机、真实镜像清单和日志正文不复制到仓库；本记录只保留必要时间和错误分类。参考 [Docker 官方故障说明](https://docs.docker.com/docker-hub/troubleshoot/)。未修改 NAS 网络、仓库配置或发起新的下载。

### 根因与实现

1. 在已有官方网页会话中，仅用 `SYNO.FileStation.List` v2 `list` 读取一个项目的 `perm/mount_point_type`，只记录字段类型和权限布尔值。代表性项目的 `acl.read/write/del/append/exec` 均为 `true`，`is_acl_mode=true`，`mount_point_type` 为精确空字符串。NAS 返回的编辑/删除权限并未关闭。
2. `DsmFileRepository.FileAdditionalPayload` 原先保留空字符串，但 `ProviderItem` 和写回预检使用 `mountPointType == nil` 区分普通项目与特殊挂载，因此普通文件也被拒绝编辑/删除。现在只将精确空串归一化为 `nil`，非空特殊挂载类型原样保留；目录列表和详情走同一解析路径。
3. 原先本地授权不进入 `ProviderItem.itemVersion.metadataVersion`，也不进入目录增量锚点。虽然设置页面已通知根和 working set 刷新，NAS 文件快照未变化时仍可得到空增量。现在元数据版本包含最终能力位；内容版本保持原值，避免触发无意义的文件内容重新下载。
4. `ProviderChangeAnchor` 的容器指纹纳入只读/编辑/编辑及删除三种状态，变化后旧锚点返回 `syncAnchorExpired`。根、普通目录和 working set 均适用；扫描后再核对授权，避免异步期间变化被错误写入下一锚点。沿用系统重新枚举，不调用会丢弃项目身份的 `reimportItems`，不扩张为扫描整个 NAS。

代码修改为 `DsmFileRepository.swift`、`ProviderItem.swift`、`ProviderRuntime.swift`；新增回归分别在 `DsmFileRepositoryTests.swift` 和 `ProviderWritebackTests.swift`。没有界面文案、工程成员、依赖、Bundle ID、entitlement 或公开接口变化。

锚点仍是原来的四段不透明字符串，变化日志和写回存储格式不变。旧版本锚点在升级后正常失效并重建；回退旧包同理。文件身份与内容版本保持稳定，未完成写回与删除记录保留。

### 五端影响

| 平台 | 本次影响 | 验证范围 |
| --- | --- | --- |
| macOS | 共享解析、File Provider 元数据和权限刷新修复 | 合成写回回归、扩展及主 App 构建；系统 Finder 待验 |
| iPhone | 共用 Apple 文件解析修复，无挂载页面或写回功能扩张 | 通用 iOS 模拟器 Debug 构建；无新增设备结论 |
| iPad | 与 iPhone 相同的共享解析影响；桌面挂载仍为非目标 | 同一通用构建覆盖目标，不代替 iPad 交互验收 |
| Android | 本轮不改代码；保留空类型与非空特殊挂载的语义参考 | 未验证 |
| Windows | 本轮不改代码；后续 Cloud Files 对齐时复核解析与授权刷新 | 未验证 |

本次没有 DSM 请求参数或私有 API 契约新增，不提升其他版本的兼容证据等级。

### 验证与风险

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

### 集成与只读对抗复核

在实现后独立进行第二遍源码/差异复核：非空特殊挂载仍禁止写回；NAS 明确拒绝编辑/删除仍被尊重；共享根、越界、回收站和远程挂载祖先保护不变；删除授权仍独立，结果未知只核查；元数据版本前缀仍兼容已有冲突判断。完整测试中的只读共享、远程挂载深层子项、递归删除权限、跨实例去重、未知结果和同名新文件保护均通过。此复核是本次本地源码复核，不声称另一位审查者或真实设备已验收。

### PENDING_USER_VALIDATION

- 前置条件：包含本次修复的正式签名主 App 和 File Provider 扩展，App Group/系统注册有效；在 NAS 上选可丢弃测试目录，不使用重要文件。当前已安装的 App 未被替换。
- 在指定文件夹和全部共享两种映射下，各验证已有普通文件/文件夹不再因空挂载类型全部带锁；启用编辑后新增文件、保存修改、改名/范围内移动，确认 NAS 最终内容一致。共享根本身仍不可改名或删除。
- 单独启用删除后删除测试文件并核对 NAS；只启用编辑时仍不可删。关闭编辑应同时撤销删除，刷新或重新打开 Finder 后变为只读；重新挂载也应保留正确的授权状态。
- NAS 权限拒绝、特殊远程挂载、断网/会话过期、保存冲突和删除结果未知时应保持既有拒绝或恢复流程，不能强行写入、重复提交或删除同名新文件。正式签名注册与真实 NAS 写回未在本机自动执行。
- 失败反馈只含用例步骤、App/macOS/DSM/套件版本类别、是否能编辑/删除、脱敏错误类别；不回传账号、地址、真实路径、Cookie、令牌或原始响应。

本机临时签名包按既定流程移除 File Provider 扩展，只适合主 App 回归，不能用于验证本次 Finder 修复。真实系统验收不由合成测试或签名检查替代；现有授权、权限和危险操作保护继续生效。

交付保留源码、正式回归测试及独立测试包；本轮临时构建目录与日志在记录结果后清理，用户提供的日志/截图保留原位。工作仍在 `main`，保留此前全部 Chat/容器/规则改动；没有暂存、提交、推送或发布。

## macOS 1.0.14 七项使用反馈修复

### 范围与基线

用户提供七张截图，要求修复语音播放、通知入口、置顶读取、本人消息未读残留、面包屑折叠、下载速度与剩余时间空值，以及 NAS 总览头部布局。基线为 `main` / `6141987e`，开始时工作区干净。截图只作本地定位，不复制其中账号、地址、路径或消息到源码和测试；本轮不自动提交、推送或发布新版本，不主动修改真实消息、文件和 NAS 设置；只读观察中的官方网页可能自行更新已读。

| 切片 | 现有证据 | 用户结果与边界 |
| --- | --- | --- |
| 语音 | ChatNativeMedia / ChatWorkspaceView | 点击后在消息内加载并开始播放；支持暂停/继续，离开会话停止和清理；沿用附件鉴权，不将会话交给外部播放器 |
| 通知 | ChatNotificationService / ChatWorkspaceView | 已授权时隐藏开启按钮；回到应用时更新状态，不自动请求系统权限 |
| 置顶 | DsmChatRepository.listPinnedMessages / PinnedMessagesSheet | 按当前会话读取，空列表与错误分开；保留原有置顶权限，不扩张一对一写入口 |
| 未读 | 可见位置、synchronizeVisibleReadState / Channel.view | 读到最新消息后同步服务器已读，后台/旧历史不提前已读，本人消息不产生错误通知 |
| 面包屑 | WorkspaceView.fileBreadcrumbs | 宽度足够时完整显示，不足才按需折叠；保留键盘、整块点击和完整路径入口 |
| 速度 | Download 管理列表 | 没有速度或剩余时间值显示 `--`；不伪造吞吐量，不把做种误判为停止传输 |
| 总览头部 | NasAdministrationView.PerformanceDashboard | 身份信息与操作紧凑排列，窄窗口自适应；危险电源确认保持原样 |

修改集中在现有 macOS 视图/模型及必要共享 Chat 解析，新增资源同步英中和主 App 覆盖资源。无新依赖、权限、应用身份或持久化迁移。共享层若需修正请求或响应，须同步契约与五端影响；Android/Windows 本轮只记录影响，不修改实现。

### 发现、验证与待验

#### 已落实的修改

- `ChatVoicePlayback` 在应用内使用已鉴权下载的本机临时音频，首次点击自动播放，暂停/继续复用同一文件，播完可重播；切换消息、关闭会话/讨论页停止并清理。主会话与讨论页共享播放控件，不请求麦克风权限。
- `ChatNotificationService` 只读系统通知状态；已允许时隐藏按钮，重新激活窗口时刷新；只有用户点击按钮才申请授权。
- `Post.search` 改用数字 `in` 数组，保留分页和逐项会话校验。旧 channel_id 在官方页面返回了其他会话，修正后全部属于请求会话；见[只读观察](../../api/discovery/environments/2026-10-03-chat-pinned-read-observation.md)。错误标题改为“无法载入置顶消息”。
- 最新消息可见位置改为直接跟踪消息行本身，避免检测消息后的空白和丢失的父层偏好更新；采用系统底部滚动锚点，修正首次打开窗口过早滚动。仍由 `Channel.view` 与回读确认清除未读；后台、读旧消息、读取/写入失败时不本地伪造已读。
- 面包屑以实际可用宽度选择显示数量，宽窗口完整显示，窄窗口只折叠放不下的前缀；保留完整父目录菜单、当前项中间截断、键盘与32点点击区域。
- 下载与上传速度，以及用户随后补充的剩余时间，缺失时显示 `--`；真实零速度仍显示零，字节等其他未知信息不随之改变。
- NAS 总览身份与版本独立排列，刷新/暂停/更新/电源集中在相邻控件中，窄窗口分组换行；电源危险操作确认与权限不变。

#### 已运行验证

| 命令 / 检查 | 实际结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4` | 2,425 项 XCTest，2,253 项执行通过，172 项按既有环境/UI门禁跳过，0失败；另12项 Swift Testing 通过。语音静音合成播放、暂停、继续、自然结束、重播、取消及临时文件清理通过 |
| `LANSTASH_UI_TEST_ISOLATED=1 LANSTASH_UI_ARTIFACTS=/tmp/lanstash-seven-ui swift test --package-path apple --skip-build --filter 'WorkspacePresentationTests.test反馈\|WorkspacePresentationTests.test文件面包屑从长目录返回时显示目标目录首项'` | 4项真实视图回归全部通过；中英文、浅深主题、宽窄路径与头部、通知授权入口、最新语音已读、上翻历史及新消息不抢滚动、文件父目录/根目录导航 |
| `python3 tools/localization/check_localization.py` | Apple 5,581 / Android 2,188 / Windows 3,402，双语、参数、引用与硬编码检查通过 |
| `python3 tools/request-contract/validate_contracts.py` | 170份请求样例、1份写结果示例通过；新增置顶数字会话数组 fixture |
| `python3 tools/contract-validation/validate_fixtures.py` | 29组响应样例、48项私有API引用通过 |
| `python3 tools/codex/generate_api_reference.py`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 请求参数目录按既定流程生成；文档和差异检查通过 |
| `xcodebuild -project apple/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/Apps/DsmMobile/build/chat-five-features-20261003 -jobs 4 CODE_SIGNING_ALLOWED=NO build` | 共享请求最终源码的 iPhone/iPad 通用模拟器 Debug 构建通过；不等于移动 UI 或实机验收 |

macOS Release / ARM64 构建与独立测试包已通过。实际命令：

```bash
LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_SIGNING_IDENTITY=- LANSTASH_TARGET_ARCH=arm64 \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/seven-feedback-20261003" \
LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/local-test" \
bash apple/Apps/DsmMac/package.sh
```

产物为 `apple/Apps/DsmMac/dist/seven-feedback-20261003/LanStash-1.0.14-arm64.dmg`，版本 `1.0.14 (24)`，包含本轮未提交修复，不是新的正式发布。主 App 临时签名、保留 Hardened Runtime 的专用测试权限、Sparkle 真实加载、ARM64 架构和 DMG 校验均通过；按既有流程移除 File Provider 挂载扩展。没有安装或启动 App，测试包使用现有独立配置与独立通知授权。

DMG 大小为 26,674,400 字节，SHA-256 为 `957834ef7834027fcc14327eeaeb225de669c251dab730f07a10a0d0452e184b`，输出目录内 `SHA256SUMS` 同步保存。

语音由静音合成文件测试，没有采集麦克风；界面使用合成资料，不连接真实 NAS。首次界面检查暴露并修复末条消息偏好更新失效、初始滚动时机和父目录菜单辅助功能识别问题，保留原回归断言及历史阅读不提前已读的断言。

#### 集成与只读对抗复核

另行逐项核对 UI → 模型 → 共享请求：置顶仍按返回消息归属拒绝越界，不忽略错误、吞掉其他会话条目来冒充正确过滤；已读必须是活动窗口实际可见的最新已发送消息，并保持服务器回读；语音保留既有附件认证、大小限制和下载取消路径，不生成携带凭据的外部播放地址。切换/退出后迟到下载不能再次播放，讨论页沿用同一控件，不新增另一套下载。通知只读查询不触发授权；电源确认与权限不变。

没有新增依赖、应用权限、正式标识、持久化格式或响应 Schema。Windows/Android 没有修改源码或运行目标构建；iOS/iPadOS 只接受共享修正，不扩张移动功能范围。工作保留在现有 main，未提交、推送或发布正式版。

#### PENDING_USER_VALIDATION

| 前置条件与操作 | 预期结果 | 影响与脱敏回传 |
| --- | --- | --- |
| 安装独立测试包，连接有语音附件的会话；点击播放、暂停、继续、切换另一段并离开会话 | 自动加载并播放，暂停保留位置，离开后停止，无外部播放器窗口 | macOS/Chat版本、音频格式与操作顺序；不发送真实音频或附件地址 |
| 系统设置已允许通知，打开消息页；切到系统设置改变授权后返回 | 已允许时无开启按钮，未允许时显示；不会自动请求权限 | 只回传授权类别和按钮是否变化 |
| 打开一对一及群聊的置顶列表，包含有置顶与空列表两种会话 | 仅显示当前会话，空列表和读取失败分别提示 | 只回传会话类别、数量、脱敏错误；不提供消息正文 |
| 发送测试语音后停留在最新消息；再滚到旧消息或离开窗口接收测试消息 | 最新消息可见时同步清除未读；后台和旧位置保留未读 | 操作顺序、未读计数和另一官方客户端的结果；不提供账号、消息或凭据 |
| 调整窗口宽度并切换语言、主题；检查下载完成任务与NAS总览头部 | 路径按需折叠、空速度/剩余时间为 --、操作紧凑且可读可点击 | 窗口宽度、语言/主题、脱敏局部截图；不含文件名、主机或账号 |

系统通知授权、实际音频设备、VoiceOver朗读和真实 NAS 的原生端到端结果不由合成检查替代。

## 跨端历史范围与决策补充

以下保留 2026-09 至 2026-10 初总控计划中的阶段授权与范围。移动端后来采用 M0–M8，旧“复杂管理不做”与 Office 限制不再代表当前范围；这些记录不自动授权新任务。

## 当前移动实施决策（2026-10-04）

用户已确认并要求执行 [Apple 移动主计划 M0→M8](../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)：iPhone/iPad 尽量完整对齐 macOS 1.0.15 业务、能力一致而布局各自原生；允许必要共享逻辑提取及 macOS 引用调整，须保持其行为并回归。Files、后台传输和分享扩展在 M8 独立实施。本页及历史条目中的“精选、复杂管理当前不做、Mac 完全只读”由本次范围取代，但不能据此宣布功能已经实现或移除权限/危险写/未知结果门禁。Windows/Android 实施范围不变，NAS 真实数据不得用于自动写测试。

## NAS 设置新基线与五端边界（2026-10-03）

本轮是用户单独授权的 macOS NAS 设置全项核对、内存压缩/电源计划补齐和套件中心实现。只有 macOS 形成新原生流程；共享 Apple 为兼容增量，Windows 与 Android 仅记录契约影响，iPhone/iPad 的复杂 NAS 运维仍为当前不做。后续跨端任务继续遵循 macOS 只读参考边界，不因本次授权解除未来只读限制。新私有写开放供用户测试不等于真实行为已验证；实际能力、权限、签名/许可、确认、互斥和结果核查不可移除。逐端取舍见对应计划，源码、私有端点、合成请求及验证证据集中在 [NAS 设置核对账本](MACOS_FEEDBACK_HISTORY.md#nas-设置网页核对与修正账本)。

同日反馈修复补充：套件预检成功可以没有 data；Setting.get 的 update_channel 为 Boolean，set 仍为 stable/beta，单卷 default_vol 可缺省。macOS 已修正并同步应用实际加载的双语资源；其他平台实现范围保持上述取舍。官方单个 MediaServer 更新已成功，但不能代替任何目标客户端的真实提交验收。详见[反馈修复账本](MACOS_FEEDBACK_HISTORY.md#套件中心反馈修复账本2026-10-03)。 后续确认 system/system_hidden 可以缺省普通存储列表；安装准备取消须丢弃迟到结果，已提交安装只关闭窗口后台继续。照片过期操作反馈修复仅涉及 macOS 模型，不改变五端照片读取/写入契约。见[二次反馈账本](MACOS_FEEDBACK_HISTORY.md#照片与套件更新二次反馈修复2026-10-03)。

## 决策摘要

macOS 是 Files、Photos、Chat、Download Station、NAS 管理、桌面云盘与安全行为的业务语义
基准。Windows 的目标是完整业务语义对齐；iPhone/iPad 按最新移动专项计划 M0→M8 实施同等用户结果及原生交互转换。Android 不属于本计划的一般实施线；2026-09-15 用户已单独授权四端 Photos 对齐，因此仅该历史波次包含 Android，详细账本集中在[照片计划](../../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)，不扩大其他模块范围。

当前状态见[开发进度](../../progress/STATUS.md)，能力边界见[平台功能矩阵](../../progress/PLATFORM_MATRIX.md)，
已结束的阶段性账本见[跨端功能对齐历史](RELEASE_VALIDATION_HISTORY.md)。

2026-09-16 Windows 用户明确授权按 macOS 浅深色截图重建视觉与原生交互；当前实现和验收集中在
[Windows 原生重建账本](../../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。这不改变 Apple 移动范围，也不开放未经验证的私有写操作。

## 基本规则

- 2026-10-02 macOS 文件基线追加：用户已单独授权并完成 [Office 预览与本机编辑自动回传](../../../apple/Apps/DsmMac/README.md) 的源码、本机自动化与独立测试包。后续 Windows 对齐须保留内容不变零上传、稳定快照、冲突暂停、未知结果只核查和会话退出边界；本轮没有实现 Windows 同类功能。iPhone/iPad 的外部编辑后自动回传不进入当前移动范围，仍采用既有前台下载/系统分享或另存流程，回传需用户主动上传，两端范围一致；不将未开发能力列为待真机验证。Android 仅记录影响，不扩张到本总控实施线。本次 macOS 授权仅适用于该独立波次，不解除后续跨端任务的只读参考边界。

- 2026-09-20 用户补充：后续所有不涉及真实数据的隔离测试均授权推进，不限于本次
  专用虚拟机测试，不重复询问普通测试步骤。该范围允许本次专用测试 VM 按官方
  最低值改为 10 GiB；继续保持断网、无 ISO、不开机，不改既有 VM/真实文件。
  外部工具要求的永久删除、扩大安全敏感权限、弱化保护等操作时确认仍保留；
  该授权不扩大到真实数据、提交/推送或正式发布，也不自动提升验证等级。

- 2026-09-19 用户进一步明确：待真实验证不计为剩余源码开发，不得在交付给用户验证的
  版本中仅因“尚无行为验证”将已实现功能永久禁用。后续交付前必须逐项收敛硬编码
  关闭门，改以已记录接口、能力/版本、实际权限、目标绑定、风险确认、防重复和结果
  核查决定是否可操作；缺接口、缺权限或尚未实现的能力不能伪装可用。此授权覆盖
  用户主动操作的验证入口，不授权 Agent 自动执行真实 NAS 高危操作，也不提升验证
  等级、不绕过证书或越权。历史“生产门关闭”属于当时事实，不能作为后续测试版
  继续永久禁用已实现功能的理由。代码开放尚需逐项实施与回归，不把本决策写成已开放。

- 2026-09-17 用户已明确批准后续兼容接口扩展及非高危操作；Windows 容器/VMM 请求、
  能力、结果模型可按已记录契约增量实施，不再等待此前的同项代码审批。此授权不含
  Agent 在真实 NAS 上执行删除、强制断电、权限/网络更改等高危操作，也不放宽既有
  危险写确认/重复保护/回读及真实验收门；不自动授权依赖、身份或持久化迁移。

- 2026-09-16 用户明确授权：修复本轮发现的 macOS Download Station `force_complete` 语义/
  文案错误，并一并修复后续有证据的同类 API 语义或误导性入口问题。此例外仅覆盖相应缺陷
  与必要回归，不解除其他 macOS 只读边界，不授权真实 NAS 危险写验证或提交/推送。
