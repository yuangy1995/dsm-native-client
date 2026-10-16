# 协议契约

本目录定义 macOS、iPhone、iPad、Android 和 Windows 五端原生实现共同遵循的 DSM 领域语义。

## 内容

```text
schemas/             JSON Schema
error-codes/         DSM 通用错误映射
fixtures-redacted/   彻底脱敏的响应样本
request-fixtures/    完全合成的客户端请求快照
mutation-results/    统一写操作结果的合成示例
localization/        客户端语言注册表与回退规则
private-api/         DSM 与套件私有 API 的版本兼容索引
community-compatibility/  已审核的社区兼容性结构化报告
```

照片基础契约包括 `photo-space.schema.json`、`photo-item.schema.json` 和 `photo-page.schema.json`。其中照片页面的分页位置基于 NAS 原始目录项目计算，即使客户端过滤了非媒体文件，也必须使用 `nextOffset` 继续读取，避免重复或遗漏。

Chat 基础契约包括能力、用户、会话、消息、附件、投票、提醒和消息分页 Schema。它们定义岚仓五端共同使用的领域语义，不代表群晖内部 API 的原始字段；实际 Adapter 必须先经过脱敏实机契约验证，再映射到这些模型。

请求 Fixture 使用 `request-fixture.schema.json`，只证明客户端生成的请求语义稳定，不
证明真实 DSM 兼容性。写操作结果使用 `mutation-result.schema.json`，重点区分明确
失败与“已提交但最终状态未确认”，后者不得自动重放。

## 修改规则

- Schema 变更必须同步评估受影响的五端实现。
- 新增字段默认可选，除非所有已验证 DSM 版本都会返回。
- 未知 JSON 字段必须能够忽略。
- fixture 只能来自专用测试数据，并在提交前脱敏。
- 请求 Fixture 必须完全合成，不得包含凭据、主机、账号、真实路径或原始请求材料。
- 高风险与破坏性写操作不得配置自动重试，必须具备最终状态复查策略。
- 不允许保存真实 SID、主机、账号、共享名、路径或文件内容。
- 私有 API 发现必须同时维护版本化环境记录、端点文档和 `private-api/compatibility.json`，详细规则见 [`docs/api/discovery`](../docs/api/discovery/README.md)。
- 社区兼容性报告使用独立契约，不得据此提升私有 API 证据等级；详细规则见 [社区兼容性指南](../docs/compatibility/COMMUNITY_COMPATIBILITY_GUIDE_ZH.md)。
