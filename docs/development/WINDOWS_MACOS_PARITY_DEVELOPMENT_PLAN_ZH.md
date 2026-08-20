<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-08-20 -->

# Windows 对齐 macOS 功能长期计划

## 目标

Windows 使用 C# 与 WinUI 3，目标是在符合 Windows 键鼠、触控、窗口、资源管理器和系统
通知习惯的前提下，对齐 macOS 已承诺的业务与安全语义。当前状态见
[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
总控规则见[macOS 对齐总控计划](MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)。

## 不变量

- 保持 `IDsmApiClient`、`DsmApiClient`、DI、`HttpClient` 生命周期和证书策略。
- 不新增程序集引用、不删除 Windows Application 项目、不重做 solution 架构。
- 保持 profile、会话、证书、能力、模块、导航、缓存和传输的隔离边界。
- 保持公开 API 的固定版本、参数编码、错误映射和 `MutationResult` 语义；私有写在未知
  DSM build 或套件版本默认关闭。
- 不改变当前发布形态、签名、Identity、最低系统版本或数据格式；这些变更必须单独批准。
- 所有新增用户可见文案同时提供英语和简体中文 `.resw` 资源。

## 当前结构与拆分方向

```text
windows/src/LanStash.Domain/          领域模型和跨模块契约
windows/src/LanStash.Infrastructure/  DSM 传输、会话、Repository 和平台无关实现
windows/src/LanStash.App/             WinUI Shell、页面、ViewModel 和平台适配
windows/tests/LanStash.Tests/         自动化测试
```

保留 `DsmApiClient` 门面，按现有 partial 文件方向拆分以下职责：

1. transport；
2. authentication；
3. discovery；
4. multipart upload；
5. download stream；
6. response decoding；
7. certificate policy。

拆分只能移动既有实现，不改变 API、DI 注册、`HttpClient` 复用、证书校验或异常语义。每个
partial 文件保持单一领域边界，并以源级契约、fixture 或 xUnit 证明行为不变。

## 实施优先级

### W0：基础与安全

- 固定认证、会话、证书、QuickConnect、公开请求契约和错误映射。
- 对私有 API 建立能力探测、环境记录、只读降级和写入口默认关闭策略。
- 为高影响写操作建立确认、权限、重复提交保护、提交未知处理和最终状态复查。

### W1：Files 与传输

- 完成 Files、预览、前台上传/下载、可解释取消、恢复与 Activity 的 macOS 业务语义。
- 跨 NAS、背景恢复、Cloud Files 和系统集成路径先保证唯一所有者与失败恢复，再考虑开放。
- 不把 Windows Explorer 或 Cloud Files 的未验证系统行为写成已完成。

### W2：Photos、Chat 与 Download Station

- 对齐明确范围内的 Photos 浏览、主动导入/分享和基础管理；后续候选不因 macOS 实现而
  自动进入 Windows。
- Chat 按文字、受限附件和明确的低风险操作推进；加密、语音、实时通话和未验证服务器写
  保持关闭或后续。
- Download Station 先推进公开只读与明确单任务语义；设置写、RSS 写、批量与删除数据作为
  独立危险写决策。

### W3：只读 NAS、Container 与 VMM

- NAS 健康、存储、服务、套件和日志优先提供有界只读摘要与独立失败降级。
- Container/VMM 生命周期、删除、网络和 noVNC 等高风险功能必须由独立 capability、
  确认、任务轮询、会话清理和真实专用 NAS 验证解锁。

### W4：系统集成与发布

- 在 Windows 设备验证 Explorer、Cloud Files、通知、托盘、安装、更新、外接卷、恢复和
  辅助功能。
- 发布前只在批准的形态下处理签名、安装、更新和卸载；如需改变形态，单独提供迁移与
  回滚方案并取得用户批准。

## 验证策略

| 范围 | 自动化 / 构建 | 用户验证 |
| --- | --- | --- |
| Domain / Infrastructure | xUnit、fixture、source contract、公开/私有 API 边界。 | 真实 DSM、套件版本、权限和断线。 |
| WinUI | XAML、资源、ViewModel 状态与目标架构构建。 | Narrator、高对比、缩放、键鼠、触控和窗口尺寸。 |
| Cloud Files / Explorer | 可重跑的领域和恢复测试。 | 系统回调、取消、文件打开、固定/释放、重启和外接卷。 |
| 认证、证书、危险写 | 静态安全门、结果映射和只读对抗复核。 | 专用 Windows 与 NAS 上的确认、重复提交、回读和清理。 |

完整 Windows 验证由托管 Windows Runner 运行 x64、ARM64、xUnit 和 WinUI XAML。非 Windows
环境中的源码阅读或部分项目编译不能替代该结果。缺少真机时标记
`PENDING_USER_VALIDATION`，不阻塞不依赖设备的源码切片。

## 关闭态与真实环境

以下条件未具备时保持关闭、只读或 capability 门保护：

- 私有写 API 在未记录的 DSM build / 套件版本；
- 删除数据、账号、套件、网络、电源、磁盘和跨 NAS move；
- Container/VMM 生命周期、网络、删除和 noVNC；
- 未验证的 Cloud Files 写回、安装、通知注册和 Explorer 系统回调；
- 需要正式证书、Windows 身份或系统注册的发布功能。

用户回传只包括系统/架构类别、步骤、预期/实际可见结果、清理状态和脱敏失败语义；不得
包含主机、账号、NAS 地址、路径、Cookie、SID、SynoToken、真实文件名或原始响应。

## 交付要求

每个 Windows 切片报告实际改动、关键决策、运行命令与结果、未验证风险、工作区状态、
剩余步骤和禁止触碰的并发改动。不得降低断言、删除既有测试或将真实环境缺失变成静默
跳过；完成后执行独立集成审查和高风险路径的只读对抗复核。
