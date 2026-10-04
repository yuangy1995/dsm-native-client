<!-- doc-role: status -->
<!-- last-reviewed: 2026-10-05 -->

# 当前开发进度

更新至 2026-10-05。本页只记录当前结论和下一步；精确提交/构建/测试/包记录集中在[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。源码、契约与实际结果优先于历史描述。

## 当前结论

| 平台 / 功能 | 当前实现与验证边界 | 下一步 |
| --- | --- | --- |
| macOS Photos | 已登记网页对齐开发及本机可执行验证完成，包含管理、上传恢复和预览；有部分版本只读及受控单项写证据，不能推定所有功能/版本真实通过 | 已修复局部操作误报图库失败及刷新残留；原始触发步骤与真实 NAS/辅助功能按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS File Station | 高级搜索/全文、逐项分享、目录上传、归档、权限、ISO/VFS/云授权、设置与任务控制已接入；本机合成与 Release 测试包完成 | 专用数据下验证权限、回调、连接和最终结果；见[macOS 说明](../../apple/Apps/DsmMac/README.md) |
| macOS NAS 设置 / 套件中心 | 21 页网页核对及读取、硬件支持位、文案修正完成；内存压缩、电源计划和套件安装/更新/上传/设置/来源已形成主流程及本机回归 | 预检/设置及资源覆盖修复后，补齐系统套件缺省位置与准备取消；真实客户端更新按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS Office | 系统预览、本机应用编辑、保存后自动回传、冲突/未知核查已完成本机验证 | 真实 Office/Pages/Numbers/Keynote、旧格式、正式签名沙盒及 NAS 验收 |
| macOS UI / 远程位置 | 完整 WebDAV URL、工具栏/路径、照片来源、连接成功结束、保存进度及外置浏览入口已修正并有原生回归 | 用户实际连接、窄窗口与完整辅助功能反馈 |
| Windows | 2026-09-21 范围的业务对齐、云盘写回/恢复及 x64/ARM64 云端验证完成；后续 Mac 增量未自动移植 | Photos 管理、File Station 增量、Office 按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)逐项开发 |
| iPhone / iPad | 默认文件/App 设置及按账号权限开启六模块已通过两端回归；M0/M1 基础、M2a 恢复传输/目录上传、M2b 高级搜索、M2c 归档/NAS 任务、M2d 分享/收集、M2e 权限/所有者、M2f 远程位置/ISO/云授权、M2g 收藏/文件管理设置、M2h1 文件夹批量复制移动、M2h2 批量删除/恢复、M2h3 打包下载、M2h4 跨 NAS 复制/分步移动、M2i Office 预览/主动回传已通过两端单元/实际 UI；M2 源码范围收口，M3a 照片选择上传与恢复、M3b1 多选与普通相册管理、M3b2 相册分享设置、M3b3 临时分享生命周期、M3b4 照片收集、M3b5 条件相册、M3b6 冻结相册恢复、M3c 资料/日期/标签编辑、M3d 目录/移动复制恢复、M3e 目录权限/后台任务、M3f1 照片偏好/旋转、M3f2 手动预览重建/恢复、M3f3 自动预览/图库维护、M3f4 管理员设置/共享成员、M3g 人物/主题/手工人脸、M3h1 原件批量删除/持久恢复及 M3h2 相似分组/代表照片/拆组/撤销及 M3h3a 批量/整集合导出、幻灯片与浏览补齐和 M3h3b 旧图库清理/唯一开发格式均已验证；M3 源码收口；M4a 搜索/本人编辑/线程、M4b1 投票、M4b2 提醒/定时、M4b3a 公告/关闭会话、M4b3b 批量转发/新联系人恢复及 M4b3c 本人单条/批量删除与恢复、M4b4a/b/c 普通/线程/附件发送与建群分步恢复均通过；M4c 语音播放/录制发送、录音中旋转与自适应分栏已通过；M4d 前台整个工作区、实际可见位置已读、通知设置及本地到期提醒已完成；最新两端各 1158 项单元（各 3 条明确设备条件跳过）及六项最终聊天实际 UI 零失败，共享完整回归与 Mac 双架构构建通过；M4 源码收口 | 按[移动主计划](../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)继续 M5–M8；移动端按未发布开发阶段实现，不保留旧开发数据兼容，两种设备分别验证 |
| Android | Compose 客户端、导航改版、后台/传输、Synology Photos 与质量门已建立；下载 destination v2 修复已通过完整云端门禁 | 按[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)继续结构收敛与目标设备验证；Mac 新增只作接口参考 |

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
