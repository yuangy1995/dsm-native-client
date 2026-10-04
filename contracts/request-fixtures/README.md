# 请求 Fixture

本目录保存完全合成的客户端请求快照，用于发现 API 名称、方法、版本、CGI 路径、
参数编码、认证材料位置和安全策略的意外漂移。

请求 Fixture 只证明客户端生成的请求语义稳定，不证明某个 DSM build 已兼容。真实
兼容性仍需脱敏发现记录和专用测试环境验证。

## 规则

- 每个样本目录只能包含一个 `request.json`。
- 不得保存 base URL、原始请求头、原始请求体、Cookie、SID、SynoToken、账号、
  主机、真实路径、文件名或用户数据。
- `encodedValue` 只允许固定合成值；路径使用 `<synthetic-path>`。密码、OTP 等敏感业务
  参数只记录 `"redacted": true`，不得保存任何占位值或编码值。
- 高风险和破坏性写操作不得启用自动重试，只能不重试或先查询最终状态再决定。
- 私有写接口还必须满足 `contracts/private-api/compatibility.json` 的环境开关。

`policy` 是调用链必须满足的安全要求，不是单个 HTTP 请求可以自行证明的事实。请求
快照测试负责验证可观察请求语义；写操作结果测试负责验证回读、取消和未确认状态。
两类证据都通过后，才可把对应操作标记为已迁移。

## 已知实现偏差

`download-station/edit-destination/synthetic-task` 是 Android 当前生成的 Task.edit v1 请求快照，
只标记 `sourceReviewed`，不是受官方字段表支持的推荐请求。官方指南第 26–27 页要求 v2，
其示例 URL 的 v1 与字段表冲突；正确版本另记录为 `synthetic-task-v2`。Android 修正属于后续
授权切片，保留旧快照用于揭示当前源码事实，不修改断言掩盖差异。移动 Apple 后续实现使用 v2；
接口尚未实现时不能从样本存在推定功能完成。详见[下载接口说明](../../docs/api/reference/download-station.md)。
