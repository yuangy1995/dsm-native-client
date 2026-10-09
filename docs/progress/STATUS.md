<!-- doc-role: status -->
<!-- last-reviewed: 2026-10-09 -->

# 当前开发进度

更新至 2026-10-09。本页只记录当前结论和下一步；精确提交/构建/测试/包记录集中在[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。源码、契约与实际结果优先于历史描述。

## 当前结论

| 平台 / 功能 | 当前实现与验证边界 | 下一步 |
| --- | --- | --- |
| macOS Photos | 已登记网页对齐开发及本机可执行验证完成，包含管理、上传恢复和预览；有部分版本只读及受控单项写证据，不能推定所有功能/版本真实通过 | 已修复局部操作误报图库失败及刷新残留，照片入口改按 Synology Photos 独立授权，不继承文件权限；原始触发步骤与真实 NAS/辅助功能按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS File Station | 高级搜索/全文、逐项分享、目录上传、归档、权限、ISO/VFS/云授权、设置与任务控制已接入；上传详情已合并传输中心，修正跳过进度与批次清理，聚焦测试及 arm64 临签包通过 | 专用数据下验证权限、回调、连接和最终结果；见[macOS 说明](../../apple/Apps/DsmMac/README.md) |
| macOS NAS 设置 / 套件中心 | 21 页网页核对及读取、硬件支持位、文案修正完成；内存压缩、电源计划和套件安装/更新/上传/设置/来源已形成主流程及本机回归 | 预检/设置及资源覆盖修复后，补齐系统套件缺省位置与准备取消；真实客户端更新按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS 服务删除反馈 | 下载、容器/网络和虚拟机通用反馈已纠正：明确拒绝、未提交或已有失败项不能被列表消失覆盖；VMM 公开删除进一步保存接受回执、检查完整清单，Mac 所有 VMM 删除不再由页面刷新覆盖未知/部分结果；VM 电源/删除现共用严格原身份、状态与回执流水线，内部命令和逐项固定版本已纠正，证书错误停止后续请求；基础设置也共用原快照、精确字段、回执与交叉互斥，Mac 不新增持久恢复；创建也已改为原任务/新 ID/完整配置归属、资源和交叉写保护，Mac 表单磁盘最低 10 GiB；网络改名/删除现保留原拓扑与关联 VM、逐项回执和普通刷新恢复；映像删除已纠正内部 v2 参数并补完整副本/挂载检查、回执与创建互锁；最终完整 3069 XCTest/12 Swift Testing 与 Mac 主 App/扩展双架构通过 | 实际删除仍只在专用可丢弃目标验证，结果与实际 NAS 分别记录 |
| macOS 虚拟机控制台 | M7d5 共享原 VM/默认键盘准备、受限原生资源/WSS 与非持久 WebKit；按 VM 绑定独立窗口，账号退出/切换/关闭模块及时清理，不自动重发输入。原生 TLS、实际 WK、生命周期与窗口主题有本机合成证据，Release 双架构通过 | 专用 VM 验证真实 noVNC/RFB、键鼠、代理与长连接，未将合成握手当作真实画面已验证 |
| macOS Office | 系统预览、本机应用编辑、保存后自动回传、冲突/未知核查已完成本机验证 | 真实 Office/Pages/Numbers/Keynote、旧格式、正式签名沙盒及 NAS 验收 |
| macOS UI / 远程位置 | 完整 WebDAV URL、工具栏/路径、照片来源、连接成功结束、保存进度及外置浏览入口已修正并有原生回归 | 用户实际连接、窄窗口与完整辅助功能反馈 |
| Windows | 2026-09-21 范围的业务对齐、云盘写回/恢复及 x64/ARM64 云端验证完成；后续 Mac 增量未自动移植 | Photos 管理、File Station 增量、Office 按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)逐项开发 |
| iPhone / iPad | M0–M7 已批准源码范围及 M8 普通文件/照片/跨 NAS/Office 后台、系统分享与 Files 已实现；正式 Files 保留共享读写、安全与恢复逻辑，全新两端的默认只读、编辑回传及中文权限原三项系统流程均通过 | M6–M8 整体仍未完成。`4864a08d` 的[Apple 检查](https://github.com/yuangy1995/dsm-native-client/actions/runs/37829368327)已全部结束：两端工作区各 166 项、服务各 46 项、管理各 88 项 UI 全部通过、0 跳过；两端模块仍有系统及其他模块 UI 实际失败。M8ap 交互修正本机两端各七项通过；M8ar 相关十一项 iPhone 全通过，iPad 10 通过/1 失败，失败用例在单模拟器下独立通过，原整组不改为通过。Files 保存的系统读访问占用保留原检查。共享源码回归零失败，工具环境缺失已由 M8al 修正并通过本机 48 项工具回归，原来源 Mac 后续构建/打包未执行。整轮仍失败，本机修正与八张两端截图已完成复核，新来源云端复验尚未完成。证据与原失败见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。真实 NAS、正式签名设备与生命周期按具体 PENDING_USER_VALIDATION 验收，保留实际权限、危险确认、防重复与未知恢复；范围见[移动主计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)及[Files 账本](../development/APPLE_MOBILE_FILES_PROVIDER_ZH.md) |
| Android | Compose 客户端、导航改版、后台/传输、Synology Photos 与质量门已建立；当前 Task.edit 仍使用 v1，需独立修正为官方字段表要求的 v2；既有 Chat 投票请求差异造成云端单测失败 | 按[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)继续结构收敛与目标设备验证；Mac 新增只作接口参考 |

## 系统集成与发布

M4d 已完成前台工作区聊天更新、实际阅读位置同步、通知授权及本地定时提醒。最终两端各 1158 项单元（各 3 条既有设备条件跳过）、6 项关键实际 UI 零失败；此前 5 项语音回归均通过。共享 2636 项 XCTest / 12 项 Swift Testing、Mac 双架构及本地化/契约/文档检查通过。后台新消息远程推送不在本轮范围；已安排的本地提醒、系统权限/终止/锁屏与真实多客户端阅读待用户验证；后续系统后台与扩展进展见上表 M8 边界。证据见[移动 M4d](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4d-前台实时阅读同步与本地提醒)。

桌面挂载默认只读，按映射启用编辑，删除另外确认；当前平台差异、根保护、日志兼容与恢复见[桌面云盘计划](../development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)。历史版本已有正式发布及部分用户升级/挂载反馈；未覆盖场景仍独立验收。本机临时签名测试包不含 Finder 扩展，不自动安装或启动，也不替代正式分发。

当前正式版本为 [macOS 1.0.17（27）](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.17)，已修复 1.0.16 将正常照片入口误隐藏的问题，保留 Photos 独立权限判断；Apple Silicon/Intel 双架构签名、公证、公开安装包及正式更新源独立回读均通过。精确结果见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-07-macos-1017-正式发布与公开回读)。Android 投票契约的既有失败仍未纳入本轮修复，不代表 Android 已完成适配。

| PENDING_USER_VALIDATION 条件 | 影响与验证路径 |
| --- | --- |
| 正式 Apple 签名、公证、共享权限与系统注册 | 按[发布/升级验收矩阵](../compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)执行；签名探针或构建不能代替 Finder 结果 |
| 未覆盖的真实 DSM/套件行为 | 使用专用账号和可丢弃目标逐项核对权限、取消、断网、重启与最终状态；按[发现流程](../api/discovery/README.md)保留版本证据 |
| 移动与 Windows 系统行为 | 系统选择器、后台/Doze、Explorer、通知、外接卷、安装升级与辅助功能按各端计划分别验收 |
| Office 与 Photos 恢复 | 正式沙盒书签、实际编辑器/媒体与真实 NAS 验证；结果未知只核查，不自动重复写入 |

## 后续工作顺序

1. 优先处理用户实际反馈的可复现问题，补聚焦回归与独立测试包。
2. 其他端开发从[功能 API 目录](../api/README.md)查当前 macOS 语义，再按平台范围分片实施；源码未实现与待用户验收分开记录。
3. 正式发布、私有写与系统集成遵循各自授权/安全边界，缺真机不阻塞无依赖源码切片。

文档只维护一份当前状态、一份平台范围、各功能长期计划及一份验证历史；不再把逐波施工日志追加到状态/矩阵。验证等级见[规则](../quality/VERIFICATION_LEVELS_ZH.md)，未来优先级见[路线图](ROADMAP.md)。
