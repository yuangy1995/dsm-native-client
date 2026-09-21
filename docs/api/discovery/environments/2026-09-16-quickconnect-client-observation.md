# QuickConnect 客户端只读复验环境

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属客户端观察，不新建 DSM 版本基线 |
| 匿名设备别名 | 待核实，不推断与既有 lab-a 的关系 |
| 基线状态 / 替代旧基线 | 未归属 / none |
| 发现日期 | 2026-09-16 |
| DSM 版本 / build / Update | 未验证；未登录 NAS |
| 相关套件完整版本 | 未验证；本次访问未认证 QuickConnect 控制面与 SYNO.API.Info |
| 客户端平台 | Windows x64 / .NET 10 |
| 连接与证书类别 | 官方 QuickConnect HTTPS / 系统证书信任 |
| 权限类别 | 未认证，不发送 NAS 账号、密码或会话 |

## 证据来源与范围

基于环境模板字段记录。复验已记录的 `get_server_info` 请求，观察全球入口的 `errno=4`、`suberrno=0`、`sites: string[]`，随后访问其中经白名单检查的区域入口得到 `errno=0`、`ds_state=CONNECTED` 以及 HTTPS 端口、直连和控制主机字段。只输出错误码、字段类型和字段存在性，不保存地址、ID 或原始响应。

官方公开 `connect_lib.da3fae9c5d057ef58d3a.bundle.js` 的 `_addCandidateControlServer` / `_go` 展示后续 `sites` 查询；静态来源不提升 NAS 功能的验证等级。

相关端点：[QuickConnect 控制面](../endpoints/quickconnect-relay-control.md)。本次未触发认证、真实文件或管理操作，不取得或持久保存用户凭据。

## 结论

区域转介属于控制面只读成功复验；更新后的 Windows `OptionalRealQuickConnectDiscoveryDoesNotSendCredentials` 实际配置本次测试 ID 后运行通过（17 秒），确认存在认证接口。真实账号登录、DSM 版本与登录后业务未验证。原始响应仅存在一次调用的内存中；未生成 HAR、响应文件或含真实数据的 fixture。
