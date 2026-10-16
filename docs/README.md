<!-- doc-role: documentation-index -->
<!-- last-reviewed: 2026-10-16 -->

# 项目文档

| 问题 | 唯一维护位置 |
| --- | --- |
| 五端做了什么、还有什么没做 | [功能表](progress/PLATFORM_MATRIX.md) |
| 当前缺陷、限制与待用户验证 | [限制与待办](progress/KNOWN_LIMITATIONS.md) |
| API 如何调用、依据是什么 | [API 目录](api/README.md)、[内部 API 发现规范](api/discovery/README.md)、[环境证据](api/discovery/environments/INDEX.md) |
| 契约与样例如何校验 | [跨端契约](../contracts/README.md) |
| 架构与系统集成约束 | [架构](architecture/ARCHITECTURE.md)、[平台集成](development/PLATFORM_INTEGRATION.md)、[Android UI 规范](design/ANDROID_UI_SPEC_ZH.md) |
| 如何构建和测试 | [Apple](../apple/README.md)、[Android](../android/README.md)、[Windows](../windows/README.md)、[验证原则](quality/VERIFICATION_LEVELS_ZH.md) |
| 如何发布、签名和升级 | [Apple 发布说明](releases/MACOS_GITHUB_RELEASE_ZH.md)、[发行记录](../CHANGELOG.md) |
| 兼容范围与社区反馈 | [DSM 证据范围](compatibility/DSM_COMPATIBILITY_MATRIX.md)、[社区指南](compatibility/COMMUNITY_COMPATIBILITY_GUIDE_ZH.md)、[社区矩阵](compatibility/COMMUNITY_COMPATIBILITY_MATRIX_ZH.md) |
| 安全要求 | [安全基线](security/SECURITY_BASELINE.md)、[报告安全问题](../SECURITY.md) |

## 维护方式

先核对源码、契约和证据，再更新对应现行文档。同一事实只写一处；普通开发与测试流水通过 Git 历史追溯，不新增日期账本或重复计划。必要的接口环境历史保留在证据索引，现存问题不能随历史删除。

复核日期统一使用北京时间。文档检查只确认链接、结构、生成结果和复核日期，不能证明接口或设备行为正确。API 证据必须区分静态、观察、读取验证和行为验证；未验证的版本与场景明确标出。

```bash
python3 tools/codex/check_documentation.py --strict-release
python3 tools/contract-validation/validate_fixtures.py
python3 tools/request-contract/validate_contracts.py
```

请求样例目录通过 `python3 tools/codex/generate_api_reference.py` 更新；社区矩阵通过 `python3 tools/community-compatibility/generate.py` 更新。Android 质量事实维护在 `tools/codex/android_quality_baseline.json`，可运行 `python3 tools/codex/generate_android_quality_baseline.py` 按需生成本机报告；不把生成报告作为另一份人工状态表。
