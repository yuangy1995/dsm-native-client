# 脱敏契约样本

这里只能保存专用测试数据生成并彻底脱敏的 DSM 请求/响应样本。

提交前必须替换：

- 账号、密码、OTP。
- SID、SynoToken、Cookie、DID。
- NAS 地址、IP、QuickConnect ID、MAC 和序列号。
- 用户名、共享名、路径、文件名和 URL。
- 容器变量、系统日志和任何用户内容。

当前仅提交人工构造的合成样本；完成首台专用测试 NAS 的协议验证后再添加真实脱敏样本。

## 目录与元数据

每组样本使用以下结构：

```text
<模块>/<端点>/<fixtureId>/
  metadata.json
  response.json
```

`metadata.json` 遵循 `contracts/schemas/fixture-metadata.schema.json`。合成样本使用 `synthetic` 环境别名；真实脱敏样本只能使用 `lab-a`、`lab-b` 等稳定别名，不得使用设备名、型号、地址或序列号。

仓库当前包含用于验证解析容错和工具链的合成样本。它们不是实际 DSM 行为证据。真实响应只有在完成自动脱敏、人工复核和严格校验后才能进入本目录。

当前29组样本均明确标为 `synthetic/static`，目录名称不表示它们来自真实 NAS。真实观察证据单独见[环境索引](../../docs/api/discovery/environments/INDEX.md)；不得将样例校验成功当作目标版本响应或行为验收。
