<!-- doc-role: status -->
<!-- last-reviewed: 2026-10-03 -->

# 当前开发进度

更新至 2026-10-03。本页只记录当前结论和下一步；精确提交/构建/测试/包记录集中在[验证历史](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。源码、契约与实际结果优先于历史描述。

## 当前结论

| 平台 / 功能 | 当前实现与验证边界 | 下一步 |
| --- | --- | --- |
| macOS Photos | 已登记网页对齐开发及本机可执行验证完成，包含管理、上传恢复和预览；有部分版本只读及受控单项写证据，不能推定所有功能/版本真实通过 | 已修复局部操作误报图库失败及刷新残留；原始触发步骤与真实 NAS/辅助功能按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS File Station | 高级搜索/全文、逐项分享、目录上传、归档、权限、ISO/VFS/云授权、设置与任务控制已接入；本机合成与 Release 测试包完成 | 专用数据下验证权限、回调、连接和最终结果；见[macOS 说明](../../apple/Apps/DsmMac/README.md) |
| macOS NAS 设置 / 套件中心 | 21 页网页核对及读取、硬件支持位、文案修正完成；内存压缩、电源计划和套件安装/更新/上传/设置/来源已形成主流程及本机回归 | 预检/设置及资源覆盖修复后，补齐系统套件缺省位置与准备取消；真实客户端更新按[二次反馈账本](../development/PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)继续验收 |
| macOS Office | 系统预览、本机应用编辑、保存后自动回传、冲突/未知核查已完成本机验证 | 真实 Office/Pages/Numbers/Keynote、旧格式、正式签名沙盒及 NAS 验收 |
| macOS UI / 远程位置 | 完整 WebDAV URL、工具栏/路径、照片来源、连接成功结束、保存进度及外置浏览入口已修正并有原生回归 | 用户实际连接、窄窗口与完整辅助功能反馈 |
| Windows | 2026-09-21 范围的业务对齐、云盘写回/恢复及 x64/ARM64 云端验证完成；后续 Mac 增量未自动移植 | Photos 管理、File Station 增量、Office 按[Windows 计划](../development/WINDOWS_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)逐项开发 |
| iPhone / iPad | 核心/受限移动流程与共享层已有模拟器验证；保持精选范围 | 真实系统交互与 NAS 验收；桌面新管理能力未进入移动 DAG |
| Android | Compose 客户端、导航改版、后台/传输、Synology Photos 与质量门已建立；下载 destination v2 修复已通过完整云端门禁 | 按[Android 计划](../development/ANDROID_CLIENT_COMPLETION_PLAN_ZH.md)继续结构收敛与目标设备验证；Mac 新增只作接口参考 |

## 系统集成与发布

桌面挂载默认只读，按映射启用编辑，删除另外确认；当前平台差异、根保护、日志兼容与恢复见[桌面云盘计划](../development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)。历史版本已有正式发布及部分用户升级/挂载反馈；未覆盖场景仍独立验收。本机临时签名测试包不含 Finder 扩展，不自动安装或启动，也不替代正式分发。

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
