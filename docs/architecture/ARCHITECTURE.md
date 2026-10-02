# 总体架构

## 架构目标

- 五个平台保持相同业务语义和安全规则。
- 各平台使用原生 UI、网络、存储和后台任务能力。
- Apple 三端共享 Swift 协议层与业务层。
- Android 和 Windows 独立实现，但共同遵循 `contracts`。
- 官方 API 与内部 API 使用不同 Adapter。

## 分层

```text
原生 UI
  -> ViewModel / Presentation
    -> Repository
      -> Official API Adapter / Internal API Adapter
        -> Capability Discovery
          -> HTTP / TLS / Session / Encoding
            -> Synology DSM
```

## 模块

| 模块 | 职责 |
| --- | --- |
| Core Domain | NAS、会话、文件、任务和错误领域模型 |
| Network | HTTPS、证书、表单、multipart、流式传输 |
| Auth | 能力发现、登录、OTP、退出和会话恢复 |
| Files | 共享目录、分页、详情、缩略图和预览 |
| Transfer | 下载、上传、进度、取消和后台状态 |
| Recycle | 回收站发现、恢复计划、冲突和校验 |
| Chat | 普通用户聊天、附件、提醒、投票和实时同步；加密与通话不属于当前已实现承诺 |
| Local Storage | 非秘密配置、能力缓存和任务元数据 |
| Secure Storage | SID、SynoToken、DID 和证书绑定 |

## 依赖方向

领域层不依赖平台 HTTP 或 UI。平台基础设施实现领域层定义的接口，UI 只依赖业务 Repository。

## API 边界

- 官方：`SYNO.API.*`、公开 File Station API。
- 官方 Chat 集成：`SYNO.Chat.External`，仅用于 Bot、Webhook 和机器人可见数据。
- 内部：`SYNO.Core.*` 等未公开接口。
- 普通用户聊天所需的未公开接口属于内部能力，默认关闭，必须按 DSM build 和 Chat Server 套件版本逐项验证。

当前范围见[路线图](../progress/ROADMAP.md)，API 实现与跨端语义见[功能参考](../api/README.md)。

## 架构决策

以下决策均已接受，日期均为 2026-07-16；编号持续有效。改变决策需记录原因、影响及迁移/回滚方案。

## ADR-0001：使用单仓库

状态：已接受
日期：2026-07-16

### 决策

Apple、Android、Windows、协议契约和开发文档放在同一个 Git 仓库。

### 原因

- API 变更能在同一提交中同步更新三端和文档。
- GitHub Actions 可以统一检查契约与安全规则。
- 当前项目由同一所有者维护，不需要独立权限或发布节奏。

### 结果

- 平台构建产物独立。
- 不使用 Git Submodule。
- 如果未来团队和发布权限真正独立，再评估拆仓。

## ADR-0002：使用平台原生技术栈

状态：已接受
日期：2026-07-16

### 决策

- Apple：Swift、SwiftUI、URLSession。
- Android：Kotlin、Jetpack Compose、OkHttp。
- Windows：C#、WinUI 3、HttpClient。

### 原因

需要原生文件选择器、安全存储、后台传输、窗口和设备形态体验，不使用跨平台 UI 运行时。

### Apple 代码共享

macOS 使用独立 App，iPhone/iPad 使用通用移动 App；三者共享 Swift Package。这属于 Apple 原生代码复用，不引入跨平台框架。

## ADR-0003：官方 API 优先

状态：已接受
日期：2026-07-16

### 决策

核心文件功能优先使用官方 DSM Login 与 File Station API。内部 API 只在官方 API 无法实现必要功能时使用。

### 内部接口准入

1. `SYNO.API.Info` 能发现。
2. 已记录 DSM build 和套件版本。
3. 有脱敏契约样本。
4. 有失败降级和功能开关。
5. 写操作有确认和结果校验。

### 回收站

公开 File Station API 没有专用 Restore API。第一阶段通过 `#recycle` 和官方 `CopyMove` 做验证，不猜测接口名称。

## ADR-0004：应用身份与首个参考平台

状态：已接受
日期：2026-07-16

### 决策

项目中文应用名确定为“岚仓”，英文应用名确定为 `LanStash`，首个参考实现平台确定为 macOS。

平台标识如下：

| 平台 | 标识 |
| --- | --- |
| 中文显示名称 | `岚仓` |
| 英文显示名称 | `LanStash` |
| Apple 基础命名空间 | `io.github.qwertyuiop1995.dsmnativeclient` |
| macOS Bundle ID | `io.github.qwertyuiop1995.dsmnativeclient.macos` |
| iPhone/iPad 通用 App Bundle ID | `io.github.qwertyuiop1995.dsmnativeclient.mobile` |
| Android applicationId | `io.github.qwertyuiop1995.dsmnativeclient` |
| Windows MSIX Identity Name | `qwertyuiop1995.DsmNativeClient` |

Windows 的 Publisher 和各平台签名身份由证书或商店账号决定，不在源码中预填虚假值。平台商店若分配不同包身份，必须通过新的 ADR 记录迁移方案。

### 原因

- 中英文名称形成独立、统一的用户品牌，不把 DSM 产品名作为客户端品牌。
- 反向域名使用公开 GitHub 所有者命名空间，避免依赖尚未拥有的域名。
- macOS 便于验证 URLSession、Keychain、文件系统和 DSM API，完成的 Swift Package 可继续服务 iPhone/iPad。

### 结果

- 先初始化独立 macOS SwiftUI App 和 Apple 共享 Swift Package。
- 品牌更名只影响显示名称和安装产物名；既有 Bundle ID、包名、Keychain service、会话名和工程命名保持不变。
- Android 与 Windows 后续按本 ADR 使用已确定的包标识初始化工程。
- 发布前仍需检查应用名称、商标、签名和商店保留状态。
