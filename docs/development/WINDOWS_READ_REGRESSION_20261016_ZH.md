<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-16 -->

# Windows 真实使用反馈修复账本

基线为 `90abeb17`，现有 Windows 全模块开发已独立提交并推送。本轮处理用户反馈的设置布局、文件搜索重复入口，以及照片、Chat、下载和 VMM 读取失败。macOS、Apple 共享层与 Android 保持只读；不改变公开契约、持久格式、工具链、签名或权限，不执行 NAS 写操作。

下表保留实施前基线；完成结论以本页后续验证记录为准。

| 功能 | macOS 证据 | Windows 等价结果与交互 | 契约依赖与安全 | 当前证据 | 非目标 |
| --- | --- | --- | --- | --- | --- |
| 设置与文件搜索 | `apple/Apps/DsmMac/Sources` 的设置与文件搜索视图 | 原生分组设置；常规筛选与高级搜索各有清晰入口 | 既有本机设置、File Station 搜索；只读布局调整 | 源码核查 | 不移除高级搜索，不改变存储格式 |
| Photos | `apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift` | 时间线、文件夹、相册、共享可以读取；未操作时不出现操作失败提示 | 已记录 Photos 内部读取；只读观察 | 源码核查、等待官方页面结构 | 不执行照片修改或导出真实内容 |
| Chat / 下载 | `apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift` | 消息历史与下载列表能读取，异常字段不伪造成功 | 已记录 Post.list v5、公开 DownloadStation.Task.list v1 | 源码核查、等待官方页面结构 | 不发送消息、创建或删除下载 |
| VMM | 同上及 `apple/Apps/DsmMac/Sources/ServiceManagementView.swift` | 已有资源可见，读取错误反馈对应实际分区 | 官方公开 API 优先，既有内部资源契约；只读 | 源码核查、等待官方页面结构 | 不启停虚拟机、不修改网络或连接控制台 |

所有权：Photos、Chat/下载、设置/文件 UI 分属独立实施范围；双语资源仅由设置/文件负责人修改，VMM、发现记录、共享客户端和最终集成由主负责人修改。正式测试由所属功能维护，构建由主负责人串行执行。

真实 NAS 观察记录见 `docs/api/discovery/environments/2026-10-16-windows-read-regression.md`；只保存参数名、类型、非敏感协议枚举和错误码，不保存原始响应、地址、用户名称、路径或消息。浏览器成功不等于 Windows 应用实机通过。

## 基线验证

提交前已实际执行完整 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore --verbosity minimal`：6598 通过、0 失败、0 跳过。WinUI Release 的 win-x64 / win-arm64、对应 Platform=x64 / ARM64 均零警告零错误。使用已有独立 .NET 10 SDK；本地化、请求契约、脱敏 fixture、严格文档、生成目录与 `git diff --check` 通过。此记录只证明基线，不预先宣布本轮修复通过。

## 根因与修改

- 设置页带点的 `x:Uid` 未命中 PRI 属性资源，静态标题/按钮/无障碍文案为空。仅将本页静态 UID 改为现有无点命名模式；动态资源读取不变。页面改为常规、可折叠侧边栏、本机存储，保留语言/主题、四个模块、缓存、云盘与本机录音。
- 文件页删除重复常驻的子文件夹开关；普通输入仍筛选已加载内容，更多菜单中的完整高级搜索保留子目录及原有全部条件。
- Photos 的 `indexed_time` 是整数 Unix 毫秒，旧秒转换使真实列表越界。普通项目、原件快照和自动预览身份统一修正且保留毫秒精度；授权未完成、刷新或撤权时不启动操作记录恢复。
- Chat 的 `file_props` 已属于原消息树，重挂新 JsonArray 会抛异常并使整页失败。改为只读枚举，保留消息/线程身份和分页检查。
- 下载可选数值兼容十进制字符串和 null，未知不补零，分页与回执仍严格校验。当前新旧包的真实读取均成功，截图中的下载失败未稳定复现，不把兼容修改冒称已证实的唯一根因。
- VMM 官方成功的 `protect_ids=[]` 作为无保护计划；非空编号、畸形或冲突仍失败，不猜详情请求。旧包同会话保护分区失败、修复后六资源分区成功。

## 五端影响

Windows 纠正已有内部字段解释，不增加 API/写入口，不改变领域日期类型或持久格式；旧错误日期若形成恢复记录，仍须与正确回读完全匹配，不自动换算、认领或重放。macOS、iPhone、iPad 共用 Apple Repository，需独立复核最近添加、原件身份和恢复匹配；Android 同样只记录复核影响。本轮不修改其他四端源码，也不提升其验证等级。请求名称、版本、路径和参数、依赖、最低系统、签名与权限均未改变。

端点、私有 API 索引、Photos 参考、跨端计划和产品/平台矩阵已同步。没有真实 NAS 写操作。

## 本轮实际验证

使用已有 .NET SDK 10.0.402 与 Codex Python；未安装或改变项目工具链。

- 完整 `dotnet test windows/tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore --verbosity minimal`：6626 通过，0 失败/跳过，14 秒。新增 Photos 7、Chat 4、下载 10、VMM 7 个用例。
- 最后设置资源修正后，同命令增加 `--filter FullyQualifiedName~Settings`：511 通过，0 失败/跳过，1 秒。
- 中文原生：`./windows/tests/UiSmoke/run.ps1 -Language zh-CN -Scenarios @('files-search','cloud-settings','photos','chat','downloads','vms') -States @('form','content','empty','error','loading','cloud-back','')`，16/16 通过，报告 `ui-review-20261016-215650`。
- 英文原生：同场景 `-SkipBuild -Language en-US -WindowWidth 900 -PaneState cycle`；States 为 form/content/empty/error/loading/cloud-refresh-leave/photo-error/photo-loading/photo-empty/filtered-empty/空字符串，21/21 通过，报告 `215921`。截图发现设置静态文字为空，说明原断言覆盖不足，不能把场景退出成功当成该页正确。
- UID 修复及实际文案/无障碍断言后，中文宽窗口、英文窄窗口的 `-Scenarios cloud-settings -States cloud-refresh-leave` 各 1/1 通过（`220440`、`220558`）。中文子页截图又显示横向偏移；新增相对 Page 的边界断言失败两次（首轮 `220857`），后续按共同根窗口坐标检查，完整窗口截图和最终结果另列，保留真实失败记录。
- 生产 ARM64 Release 构建在最后设置资源变更前通过，0 警告/错误，47.23 秒；最终构建不沿用较早结果。
- 应用原会话只读生产链路：Photos 授权、时间线、项目、首张缩略图、个人文件夹、相册和本人分享列表成功；Chat 三个会话消息页成功；下载任务、活动、设置、RSS 成功；VMM 六资源分区成功。详见环境记录，界面操作不能由 Repository 成功替代。
- 本地化/硬编码（Windows 5054 对）、请求契约（180+1）、fixture（29 组/48 引用）、严格文档及 API 目录一致性检查通过；收尾文档后再次检查。

独立集成与只读对抗复核覆盖设置资源/布局、搜索入口保留、照片授权/迟到结果/毫秒精度、Chat 节点身份、下载未知值与严格分页、VMM 空结果/不完整结果隔离。没有降低既有断言或安全门。

基线 `90abeb17` 的 Windows Build、Repository Check、Documentation & Quality Preflight 已在 GitHub 通过；这些云端结果只覆盖基线，不能替代本轮修复提交后的云端门禁。

### 最终设置布局与独立测试包

设置布局边界检查最终确认存在宽窗口溢出，改用根滚动内容与内容栈左对齐，保留宽度上限及窄窗口收缩。三轮失败的坐标与截图观察结论保留在本记录，不把拉伸尝试或坐标检查改写成通过。最终中文 1280 与英文 900 窗口的 `cloud-settings / cloud-refresh-leave` 各 1/1 通过（`221806`、`221849`）；展开四个侧边栏开关的实际文字、开/关状态文案、无障碍名称及控件左右边界均有断言，再恢复原折叠状态。完整窗口截图已目视确认，标题、两个选择框、清理缓存及云盘/录音入口均完整可见。

另用同一正式合成宿主的既有环境入口执行中文深色：`LANSTASH_SMOKE_SCENARIO=cloud-settings`、`LANSTASH_SMOKE_STATE=cloud-refresh-leave`、`LANSTASH_SMOKE_THEME=Dark`、`LANSTASH_SMOKE_LANGUAGE=zh-CN`、宽1280/高820/侧栏open，以隐藏窗口启动测试宿主；完成标记、文字/无障碍/边界断言通过，截图已查看，专用测试进程已结束。未启动用户生产会话。

最终打包命令：设置 `LANSTASH_NON_INTERACTIVE=1`、`LANSTASH_TARGET_PLATFORM=both`、`LANSTASH_RUN_TESTS=0`、`LANSTASH_LAUNCH_AFTER=0` 后执行 `./windows/package.ps1`。此前完整测试及最后设置聚焦已通过，打包不重复运行相同测试；脚本明确以 `LanStashUiSmoke=false` 生成两个自包含 Release 包，两个平台发布构建成功，没有启动或覆盖原包。

交付目录为 `windows/dist/20261016-221927/`；包构建时基于 `main/90abeb17` 加本轮未提交改动，包内来源记录保留当时状态，不是正式发布：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `LanStash-0.1.0-x64.zip` | 97743149 | `bb57643232a372ef617d121e94f82c0721bf6fc9a49bfd513cdb657465a61595` |
| `LanStash-0.1.0-arm64.zip` | 94885879 | `4abe95091790ea2c11ee64d2aaf593738e1c98d0a763adaadbef6e3037e82e51` |

每包附既有构建来源记录及外部校验文件；没有将合成宿主、临时只读诊断或真实用户数据放入包。临时诊断源码、编译产物和浏览器观察状态已清理；本轮合成截图复核后清理，正式测试源码与上述可复现记录保留。旧用户测试包和旧波次产物不删除。

## 待用户验证

`PENDING_USER_VALIDATION`：使用新独立测试包重连原 NAS，验证设置及高级搜索入口、照片四分区与实际预览/分页、聊天附件、下载持续刷新及 VMM 空保护状态。下载若再次失败，仅回传模块、复现步骤、套件版本和脱敏错误，不回传原始请求或用户内容。物理 ARM64、Narrator、触控、高 DPI 与危险写操作未验；相关专项保护保持。新生产包不自动启动或覆盖原包。

## 提交交付

2026-10-16 用户要求将本轮修复提交并推送到 `origin/main`。提交前重新读取仓库规则、差异和远端；远端与本地基线均为 `90abeb17`，没有新提交需要整合。源码保持前述已验证内容，本轮只追加交付状态；提交前再次执行本地化/硬编码、契约、fixture、文档、生成一致性与差异检查。测试包和临时产物不纳入提交，不创建分支、PR、标签或发布。
