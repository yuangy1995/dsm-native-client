# 私有 API 索引

`compatibility.json` 保存稳定环境/端点、接口元数据、历史 verification 与证据路径；请求及结果语义只维护于 documentRef 指向的[当前接口定义](../../docs/api/discovery/endpoints/INDEX.md)。结构由[Schema](../schemas/private-api-compatibility.schema.json)约束。

- lab-a、lab-b 为匿名稳定设备；同设备升级保留旧 historical 基线，以 supersedes 关联，每设备最多一个 current。归属未知的观察仅进入[证据索引](../../docs/api/discovery/environments/INDEX.md)，不冒用既有 environmentId。
- 保留原日期、版本、权限、来源和证据等级。历史 verification 的状态描述不是当前运行开关，当前功能状态只维护于[平台矩阵](../../docs/progress/PLATFORM_MATRIX.md)。
- capability/fallback 只提供定位与必要边界，不复制各端施工日志。apiNames/versionMatrix 的旧候选项不自动成为可调用协议，未知方法以正文证据为准；实际请求必须有明确参数和能力依据。
- 新观察追加记录；不得以 static、observed 或合成测试升级行为证据。接口开放按实际能力/权限、确认、去重与结果规则；未实测不等于已验证，也不产生精确版本白名单。
- 不保存秘密、真实用户数据或原始响应。fixture 的来源与证据等级必须如实标记。

修改索引和文档引用后运行 `tools/contract-validation/validate_fixtures.py`。Schema、API 字段或 fixture 的变更需独立评估，不因文档整理顺手迁移。
