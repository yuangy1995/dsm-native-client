# Windows / Apple 移动端功能对齐账本：第 1 波

> 状态：整理后的单一简体中文功能提交 `641852b408ae24f8819e4a49cd70df4c8d9e5011` 已合并到 `main`；云端门禁已通过，真机与真实 NAS 验收后置
> 基线提交：`bd809f8b6854258ac3c0d9370468b82536b7c34d`（`完善 Windows、iPhone 与 iPad 跨平台功能闭环`）
> 当前范围：Windows `FND-03/W1 证书安全与连接来源说明`、Windows/Apple `FILE-03 新建文件夹与重命名`、Apple 移动端 `PHOTO-02 只读查看增强`、iPad 当前范围自动化
> 禁止范围：`android/**`、`apple/Apps/DsmMac/**`；空文件、递归目录统计、MD5、批量重命名、私有 Foto API、照片编辑、后台整库扫描、自动备份和所有未列入本波的危险写

## 1. 账本口径

- `完整`：源码、聚焦自动化与目标平台构建均覆盖用户主流程；只能依赖真机、签名或真实 NAS 的验收另记 `PENDING_USER_VALIDATION`。
- `部分`：已有可用流程，但契约、状态、错误恢复、自动化或目标平台构建证据仍不完整。
- `关闭`：缺少稳定契约、行为证据或本波授权，生产入口保持隐藏、只读或能力门关闭。
- 写操作只有在稳定目标、写前基线、一次提交、提交边界、独立写后回读和提交后零自动重放均成立时才允许进入 UI。
- 证书安全只有在系统信任优先、合格叶证书、按 profile 固定、变化阻断、relay 仅系统信任和发现阶段零凭据均成立时才允许完成连接。
- 本地轻量检查不替代 GitHub 的 Windows x64/ARM64、Apple iPhone/iPad 与共享 Package 大型门禁；云端结果必须对应最终候选提交的精确 SHA。

## 2. 本波用户结果与边界

| 用户结果 | macOS / 计划事实来源 | 当前基线 | 本波目标 | 安全与数据边界 | 明确非目标 |
| --- | --- | --- | --- | --- | --- |
| Windows 首次自签名证书核对 | `DsmCertificateTrust.swift`、总控 `FND-03`、Windows `W1` | 只有系统默认信任；自签名直接失败，无核对模型、pin store 或 UI | 系统信任证书直接通过；合格自签名叶证书进入一次性核对，用户确认后按 profile 固定 | 不记录证书正文或私钥；只保存 SHA-256 指纹；密码、OTP、SID、Token 与 pin 分离 | 全局忽略证书错误、安装系统根证书、relay 手动固定、自动接受变化 |
| Windows 证书变化阻断 | 同上 | 无旧/新指纹比较 | 变化时显示旧/新指纹，默认阻断；只有显式再次核对才更新 pin 并继续同一冻结连接尝试 | profile、原始 NAS 身份、direct endpoint 与 attempt generation 同时匹配；迟到结果零回写 | 静默更新 pin、把普通重试当重新确认 |
| Windows 连接来源与能力说明 | Windows `W1` | 连接阶段只有瞬时状态文案；成功后没有稳定来源摘要 | 保留局域网/公网直连/QuickConnect relay 的稳定、通俗说明；能力缺失给原因与下一步 | relay 只走系统信任；路由发现阶段不发送登录凭据；不显示内部 API/build | 暴露原始路由字段、凭据、诊断地址或私有协议 |
| Apple/Windows 新建文件夹 | 总控 `FILE-03`、现有公开 CreateFolder | 两端只有 `void` 旧契约；专用 Files 页面生产入口关闭 | 公开 v2、单目标、写前不存在、一次提交、独立回读唯一同路径目录后才确认；结果完整呈现 | canonical 绝对父路径、单段名称、profile 绑定、目标锁、提交后零重放；remote/recycle 及后代保持只读 | 空文件、批量创建、模板、自动重试、内部 API fallback |
| Apple/Windows 重命名 | 总控 `FILE-03`、现有公开 Rename | 两端只有 `void` 旧契约；新页面未开放 | 冻结原对象身份与目标名称；写前源精确存在且目标不存在；一次提交；写后证明旧路径消失、新路径同类型唯一存在 | 源/目标锁、profile/repository/generation 门；权限、冲突、提交未知与取消后复查可区分 | 批量/规则重命名、跨目录移动、覆盖、永久删除 |
| iPhone/iPad PHOTO-02 查看增强 | 总控 `PHOTO-02`、现有安全 Preview/Range/Inspector | 图片/视频安全预览、保存副本、系统分享、基础文件详情已可用；缺同一快照前后导航和照片元数据白名单 | 冻结当前可见相册/时间线快照；前后浏览；iPhone 沉浸查看；iPad Inspector；基础元数据只读呈现 | 只读取有界、版本一致的本机 artifact 或严格 Range 前缀；只显示白名单字段；保存/分享始终绑定当前 canonical item | GPS、MakerNote、设备序列号、EXIF 写回、编辑、人物/地点/标签、私有 Foto、后台扫描、PHOTO-03 导入/移动 |
| iPad 当前范围自动化 | Apple `M8/M9` | 已有自适应 Sidebar/Inspector，但键盘与宽度变化证据不足 | 左右键导航、Return/Space 打开、Escape 返回、Command-S 保存副本；紧凑/常规宽度保持选择和详情 | 可见按钮仍是主入口；指针/快捷键只是增强；44pt、VoiceOver、Dynamic Type、Reduce Motion | 多窗口、拖放唯一入口、桌面级批量运维 |

## 3. 冻结契约与实现顺序

1. **Windows 证书基础切片**：Domain challenge/trust decision、profile pin store、TLS transport gate、direct/relay 安全语义与合成测试先冻结；App/UI 不直接解析证书。
2. **Apple FILE-03 契约切片**：共享 `FileItemMutationOutcome` 与结果型 create/rename；旧 `void` API 保持兼容，生产移动 UI 只调用新接口。
3. **Windows FILE-03 契约切片**：复用既有 `MutationResult`，新增独立请求/结果与 transport 提交边界；旧 `IDsmRepository` 方法不得成为新 UI 数据源。
4. **PHOTO-02 只读切片**：复用现有严格 Range/Preview，不新增 NAS API；先建立 viewer/metadata 状态，再接 iPhone full-screen 与 iPad Inspector。
5. **UI 与组合根集成**：证书 ContentDialog、两端新建/重命名表单、PHOTO-02 查看器；Shell/AppModel、资源与工程文件由单一集成 owner 串行修改。
6. **复核与云端出口**：独立安全/写契约复核、本地轻量门、文档同步；创建 `codex/` 验证分支运行 GitHub 全量，全部通过后整理为一条简体中文正式提交并合并 `main`。

## 4. 文件所有权

| 热点 | 唯一 owner | 其他 owner 约束 |
| --- | --- | --- |
| Windows Auth Domain、TLS transport、pin store 与安全测试 | Windows 证书契约 owner | 不修改 Login UI、Files、资源、Shell、文档 |
| Apple `DsmCore/FileStation.swift`、`DsmNetwork/DsmFileRepository.swift` 与 FILE-03 契约测试 | Apple FILE-03 契约 owner | 不修改 Mobile、资源、工程、macOS App、Windows |
| Windows FILE-03 Domain/Transport/Repository 与契约测试 | Windows FILE-03 契约 owner；证书 transport 冻结后串行开始 | 不修改 FilesPage、资源、Shell、旧 Workspace UI |
| Apple PHOTO-02 Viewer/Metadata 功能目录、`MobilePhotosView.swift` 与聚焦测试 | Apple PHOTO-02 owner | 不修改共享 Package、AppModel/Session、资源、工程、macOS App |
| Windows Certificate/File Mutation UI 功能目录、LoginPage/FilesPage 最小接线 | Windows UI owner；对应契约冻结后开始 | 不修改 Domain/Transport/Repository、资源、Shell |
| Shell/AppModel/Session 组合根、两端双语资源、XcodeGen/工程、账本与最终集成 | 主 agent | 其他 owner 只提交接线需求与资源键清单 |

## 5. 验收门禁

### 5.1 Windows 证书

- 系统可信、首次合格自签名、变化、过期/结构无效、relay 不可信、取消、profile 切换和迟到 challenge 均有行为测试。
- 确认前零登录凭据；确认后仅同一冻结 attempt 登录一次；pin 只按 profile 保存。
- UI 使用原生 ContentDialog，旧/新指纹分别可读，默认焦点安全，Escape 取消，确认不可重入。

### 5.2 FILE-03

- 两端固定官方 v2 与 FORM 能力门；名称和路径规则一致；请求参数精确。
- 写前源/目标基线、目标锁、一次提交、写后独立回读、提交后取消/断网/坏响应只回读不重放。
- confirmed success、permission、conflict、unsupported、cancelled before submission、submitted but unverified 均有聚焦测试。
- UI 关闭重开不能绕过需核对 blocker；只读来源与 handler 双门；成功才刷新并移动焦点，失败/取消保留浏览 baseline。

### 5.3 PHOTO-02 / iPad

- 同一 canonical snapshot 前后导航边界、相册/时间线、筛选变化、profile/repository/generation 和迟到结果均有模型测试。
- 元数据读取有明确上限、版本一致性与字段白名单；无 GPS、MakerNote、序列号或私有 Foto 请求。
- iPhone full-screen、iPad Inspector、紧凑/常规宽度、键盘、VoiceOver、Dynamic Type 与 Reduce Motion 有聚焦或展示测试。
- 保存副本和系统分享始终使用当前 viewer item，不使用列表中可能已变化的 selection。

### 5.4 集成与发布

- 本地执行 Swift/C# 形态检查、本地化、请求契约、聚焦低负载测试和 `git diff --check`。
- GitHub 对候选 SHA 执行 Repository Check、Windows x64/ARM64、Apple iPhone/iPad/共享 Package 与 macOS 回归；Android 只验证未被改动并运行既定云端回归，不修改源码。
- 云端全绿后把本波整理为一条简体中文功能提交，快进合并并推送 `main`，再删除本地和远端验证分支。

## 6. PENDING_USER_VALIDATION

- Windows 10/11 x64 与 ARM64：首次自签名、证书变化、系统可信、公网直连和 QuickConnect relay；Narrator、高对比、200% 缩放和键盘流程。
- 真实 NAS：CreateFolder/Rename v2 权限、冲突、断线、提交后取消、回读字段和服务端副作用；只回传脱敏 API 错误类别与结果，不回传真实路径、主机或凭据。
- iPhone/iPad：代表性 JPEG/HEIC/MOV/MP4 元数据、左右导航、旋转/分屏、外接键盘/指针、VoiceOver、最大动态文字和系统分享/保存副本。
- 缺少上述真机证据不阻塞其他源码与云端门禁；证书绕过、未确认 FILE-03 重放和未白名单元数据入口必须继续保持关闭。

## 7. 当前验证证据

- Apple FILE-03 共享契约固定公开 v2/FORM，覆盖写前类型与权限基线、目标互斥、单次提交、独立回读、提交后取消/异常不重放和同目标 review blocker；共享 Package 最新执行 645 项 XCTest，2 项按环境跳过、0 失败。
- Apple 移动端 FILE-03 与 PHOTO-02 已通过 iPhone 17 Pro / iOS 26.5 模拟器聚焦测试 60/60，0 失败、0 跳过；PHOTO-02 同时通过未参与实现者的只读复核，未发现 P0/P1/P2。当前主机没有可用 iPad Simulator，iPad 构建与布局运行证据交由 GitHub Apple 门禁和后续真机验收。
- Windows 证书链已完成 profile pin、变化阻断、relay 系统信任、稳定连接来源、每次尝试独立 transport、全部 NAS 请求上下文和原生核对对话框；独立对抗终审为 P0/P1/P2 均 0。
- Windows FILE-03 已完成 typed transport、Repository、session blocker、ViewModel 与 WinUI 主流程；请求契约校验通过 90 个 Fixture 与 1 个写结果示例，双语资源统计为 Apple 3255、Android 1985、Windows 849，XML、硬编码、本地化和差异格式门通过。
- Windows `FilesPage` 的本波新建/重命名页面逻辑已拆到独立 `FilesPage.Mutations.cs` partial 文件，主页面只保留组合根与生命周期调用点；该拆分不改变状态机、资源或写操作门禁。
- 当前机器没有 `dotnet`/Windows SDK；候选提交已由 GitHub Windows Runner 完成 756/756 xUnit 与 WinUI x64/ARM64 构建，因此候选状态为 `UNIT_TESTED / BUILD_VERIFIED_WINDOWS_CI_X64_ARM64`，但仍不等同真实 Windows 设备运行。
- 候选云端证据：`Apple Build` run `31306484946` 在 `e5ac397` 通过共享 Package 645 项 XCTest（2 项按环境跳过）、iPhone/iPad 通用应用构建和 macOS 回归；`Android Build` run `31306484965` 在同一提交完成单元测试、Debug、Release/R8、仪器测试 APK 编译与 Debug lint；`Windows Build` run `31306947634` 在 `f25508b` 通过 756/756 xUnit，x64/ARM64 均为 0 警告、0 错误；`Repository Check` run `31306947631` 在 `f25508b` 通过 90 个请求 Fixture、1 个写结果示例、本地化与隐私门禁。
- 上述候选修正历史已整理为单一简体中文功能提交 `641852b408ae24f8819e4a49cd70df4c8d9e5011`（`完善跨端证书安全、文件操作与照片查看`）并合并到 `main`；真实设备和真实 NAS 验收仍按 `PENDING_USER_VALIDATION` 后置。

## 8. 本波完成后继续对照的剩余项

- Windows：后续已完成 FILE-05 单文件复制/移动、FILE-09 回收站入口、Chat 纯文字发送、Download 单任务控制、链接/任务文件创建和单任务删除；仍需统一 ModuleAvailability 剩余原因、文件夹/批量传输、Chat 附件/实时、Download 高级能力、NAS 管理和 W5/W6 系统集成。
- iPhone/iPad：后续已完成 FILE-05 有界同 NAS复制/移动、FILE-09 回收站写、PHOTO-03A PhotosPicker 单项导入、Chat 纯文字发送、Download 创建与单任务控制；仍需 Chat 附件/实时、Download 高级能力，以及 M8/M9 其余生产力与自动化。
- Apple 共享层：`DsmFileRepository.swift` 是既有大型聚合实现；后续继续扩展 File Station 写能力前，单独做保持行为不变的功能拆分与共享 Package/macOS 回归，不在本波危险写验收中顺带扩大内部可见性。
- 两端：没有稳定公开或已记录私有契约的能力继续关闭；真实设备与真实 NAS 验收按用户安排后置，不用推测性防御代码替代验证。
