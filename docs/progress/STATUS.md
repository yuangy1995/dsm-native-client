<!-- doc-role: status -->
<!-- last-reviewed: 2026-10-06 -->

# 当前开发进度

更新至 2026-10-06。本页只记录当前结论和下一步；精确提交/构建/测试/包记录集中在[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。源码、契约与实际结果优先于历史描述。

## 当前结论

| 平台 / 功能 | 当前实现与验证边界 | 下一步 |
| --- | --- | --- |
| macOS Photos | 已登记网页对齐开发及本机可执行验证完成，包含管理、上传恢复和预览；有部分版本只读及受控单项写证据，不能推定所有功能/版本真实通过 | 已修复局部操作误报图库失败及刷新残留，照片入口改按 Synology Photos 独立授权，不继承文件权限；原始触发步骤与真实 NAS/辅助功能按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS File Station | 高级搜索/全文、逐项分享、目录上传、归档、权限、ISO/VFS/云授权、设置与任务控制已接入；本机合成与 Release 测试包完成 | 专用数据下验证权限、回调、连接和最终结果；见[macOS 说明](../../apple/Apps/DsmMac/README.md) |
| macOS NAS 设置 / 套件中心 | 21 页网页核对及读取、硬件支持位、文案修正完成；内存压缩、电源计划和套件安装/更新/上传/设置/来源已形成主流程及本机回归 | 预检/设置及资源覆盖修复后，补齐系统套件缺省位置与准备取消；真实客户端更新按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS 服务删除反馈 | 下载、容器/网络和虚拟机通用反馈已纠正：明确拒绝、未提交或已有失败项不能被列表消失覆盖；36 项聚焦、完整 2915 XCTest/12 Swift Testing 与 Mac 双架构通过 | 实际删除仍只在专用可丢弃目标验证，结果与实际 NAS 分别记录 |
| macOS Office | 系统预览、本机应用编辑、保存后自动回传、冲突/未知核查已完成本机验证 | 真实 Office/Pages/Numbers/Keynote、旧格式、正式签名沙盒及 NAS 验收 |
| macOS UI / 远程位置 | 完整 WebDAV URL、工具栏/路径、照片来源、连接成功结束、保存进度及外置浏览入口已修正并有原生回归 | 用户实际连接、窄窗口与完整辅助功能反馈 |
| Windows | 2026-09-21 范围的业务对齐、云盘写回/恢复及 x64/ARM64 云端验证完成；后续 Mac 增量未自动移植 | Photos 管理、File Station 增量、Office 按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)逐项开发 |
| iPhone / iPad | M0–M5 已批准源码范围已完成；M6a1 五项读取、M6a2 存储分析/硬盘检测/日志、M6a3 区域时间/DDNS、M6b1 账号/群组、M6b2 文件服务/终端/代理、M6b3 远程访问、M6b4 网卡编辑与断连恢复、M6c1 内存压缩/电源计划、M6d1 计划任务、M6d2 连接/即时电源、M6e1 套件设置/来源、M6e3 安装/更新/SPK 恢复及 M7a 容器单项/多项启停重启、逐项恢复与活动详情、M7b 映像搜索/标签/下载和跨重启恢复、M7c1 映像单项/多项删除与逐项恢复已接入。最新两端完整单元各 1537 项（各 4 条既有跳过），网卡七项新 UI 和原终端回归全部通过；映像删除/下载回归已有两端证据。共享 2923 XCTest/12 Swift Testing 与 Mac 双架构通过；Photos-only 保存会话恢复和权限组合 UI 已通过，真实 NAS 行为未验证 | 按[移动主计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6-nas-与套件逐页账本)继续安全、硬件/UPS 及其余 M6 管理与套件，并继续 M7 容器删除、网络/VMM 与 M8；容器创建/编辑缺少现有 Mac 基线及契约，已单独记录范围缺口；已实现入口按能力、权限和操作保护开放。旧云端 iPhone/iPad 的导航、异步恢复及面板关闭失败均已逐项修复并在两端复测，另修聊天停止后迟到读取和 DMG 短暂占用。每设备拆为两个互补测试组，已核对分组完整性；上一批云端 macOS/共享和 iPhone 工作区通过，其余三组的 31 个设备/用例失败已按原日志、界面和输入证据修正，全部取得对应本机通过结果；最近完整云端共享/macOS 与 iPad 工作区通过，iPhone 工作区 1 项及两端模块组各 4 项失败；Office 面板、功能开关准备、聊天合成列表与电源表单定位已按原证据修复，相关十三项模块 UI 均有两端本机通过结果，修复提交 cdc889cc 的新云端共享/macOS 与 iPad 工作区已通过，iPhone 工作区失败、两个模块组仍在运行；人脸用例已按录屏/输入事件补齐就绪等待，两端相邻用例复测通过，云端复验待后续；本地后续提交暂不推送打断未完成组；真机条件按具体待办执行 |
| Android | Compose 客户端、导航改版、后台/传输、Synology Photos 与质量门已建立；当前 Task.edit 仍使用 v1，需独立修正为官方字段表要求的 v2；既有 Chat 投票请求差异造成云端单测失败 | 按[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)继续结构收敛与目标设备验证；Mac 新增只作接口参考 |

## 系统集成与发布

M4d 已完成前台工作区聊天更新、实际阅读位置同步、通知授权及本地定时提醒。最终两端各 1158 项单元（各 3 条既有设备条件跳过）、6 项关键实际 UI 零失败；此前 5 项语音回归均通过。共享 2636 项 XCTest / 12 项 Swift Testing、Mac 双架构及本地化/契约/文档检查通过。后台新消息远程推送不在本轮范围；已安排的本地提醒、系统权限/终止/锁屏与真实多客户端阅读待用户验证，继续 M5–M8。证据见[移动 M4d](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m4d-前台实时阅读同步与本地提醒)。

桌面挂载默认只读，按映射启用编辑，删除另外确认；当前平台差异、根保护、日志兼容与恢复见[桌面云盘计划](../development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)。历史版本已有正式发布及部分用户升级/挂载反馈；未覆盖场景仍独立验收。本机临时签名测试包不含 Finder 扩展，不自动安装或启动，也不替代正式分发。

当前正式版本为 [macOS 1.0.15（25）](https://github.com/yuangy1995/dsm-native-client/releases/tag/macos/v1.0.15)，已完成 Apple Silicon/Intel 双架构签名、公证、公开附件及正式更新源回读核对，包含七项使用反馈与剩余时间显示修正。精确结果见[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-macos-1015-正式发布)。Android 投票契约的既有失败仍未纳入本轮修复，不代表 Android 已完成适配。

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
