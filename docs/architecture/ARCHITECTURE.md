# 总体架构

五端共享业务语义和安全规则，使用原生界面、网络、安全存储与系统集成。功能范围与验证等级只在[平台矩阵](../progress/PLATFORM_MATRIX.md)维护；平台转换与恢复规则见[平台集成](../development/PLATFORM_INTEGRATION.md)，协议见[功能 API](../api/README.md)。

## 分层与依赖

```text
原生 UI → Presentation / ViewModel → Repository
                                  → Official / Internal API Adapter
                                  → Capability / HTTP / TLS / Session
```

领域模型与 Repository 接口不依赖 UI 或平台 HTTP；基础设施实现接口，界面负责本地化。非秘密配置、能力缓存和任务摘要与安全存储分离；凭据不进入领域结果、普通持久化或日志。Apple 三端共享 Swift Package，macOS 独立 App，iPhone/iPad 使用通用移动 App。

## API 边界

- 官方 API 优先；公开 Chat 集成仅服务 Bot/Webhook，不能代替普通用户会话。
- 内部 API 使用独立 Adapter，遵循[发现流程](../api/discovery/README.md)，记录方法、参数、权限、降级及版本证据，禁止猜测接口。
- 运行时按实际 API 能力、账号/对象权限、确认、防重复与结果复查开放操作；DSM/build/套件版本只界定证据范围，不作为精确白名单，不为版本匹配增加系统管理权限。
- 只读失败不阻断无关流程；未知写结果只回读，不自动重放。涉及数据丢失、凭据泄露或不可逆副作用而尚未验证的相关入口仍须保护。
- 公开 File Station 没有专用 Restore API；回收恢复使用已记录的回收站和 CopyMove 语义，不假设删除可恢复。

## 已接受的架构决策

以下 ADR 编号和 2026-07-16 接受日期保持有效；变更须说明必要性、影响、迁移与回滚，并遵循 [AGENTS.md](../../AGENTS.md) 的授权要求。

| 编号 | 决策 | 约束 |
| --- | --- | --- |
| ADR-0001 | 单仓库 | Apple、Android、Windows、契约与文档共同维护，构建产物独立，不使用 Submodule |
| ADR-0002 | 平台原生技术栈 | Apple：Swift/SwiftUI/URLSession；Android：Kotlin/Compose/OkHttp；Windows：C#/WinUI 3/HttpClient |
| ADR-0003 | 官方 API 优先 | 内部能力必须有可追溯契约、运行时发现、失败降级及写保护 |
| ADR-0004 | 中文“岚仓”、英文 LanStash，以 macOS 为业务参考 | 保持各平台原生交互；显示名称变化不迁移已有应用、安全存储或会话身份 |

## 应用身份

| 平台 | 已确定标识 |
| --- | --- |
| Apple 基础命名空间 / Android applicationId | `io.github.qwertyuiop1995.dsmnativeclient` |
| macOS Bundle ID | `io.github.qwertyuiop1995.dsmnativeclient.macos` |
| iPhone/iPad Bundle ID | `io.github.qwertyuiop1995.dsmnativeclient.mobile` |
| Windows MSIX Identity Name | `qwertyuiop1995.DsmNativeClient` |

Windows Publisher 与 Apple 发布身份由真实证书及发布配置决定，不预填虚假值。更改身份须单独评估数据、安全存储和升级兼容，不能随品牌或界面修改迁移。
