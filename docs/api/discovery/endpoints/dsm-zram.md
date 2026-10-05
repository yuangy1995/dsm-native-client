# DSM 内存压缩（ZRAM）内部 API

## 当前契约

稳定标识 `dsm-zram`，组件 `dsm-core`，内部混合读写接口，风险 `high`。
2026-10-02/03 官方页面确认 DSM 7.2.1-69057 Update 12，成功读取
`SYNO.Core.Hardware.ZRAM.get` v1 的 `data.enable_zram:Boolean`。本次设备匿名归属待确认，
不提升旧 lab-a 记录。当前响应没有容量或算法，界面不显示没有信息的行。

| API / 方法 | 版本 | 业务参数 | 返回 / 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `SYNO.Core.Hardware.ZRAM.get` | 1 | 无 | `enable_zram:Boolean` | read-verified |
| `SYNO.Core.Hardware.ZRAM.set` | 1 | `enable_zram:Boolean` | 保存压缩开关 | static（官方前端） |
| `SYNO.Core.Hardware.NeedReboot.get` | 1 | 无 | `need_reboot:Boolean` | static（官方前端） |
| `SYNO.Core.Hardware.NeedReboot.set` | 1 | 无 | 标记重启后生效 | static（官方前端） |

路径、版本和请求格式来自运行时 `SYNO.API.Info`。当前环境使用 `entry.cgi` 及 JSON
参数格式，通过已有 POST 会话构造器发送，不能保存认证内容。

## 保存语义

用户已要求提供开关用于测试，macOS 不再因缺少真实写入验收而固定关闭。保存必须：

1. NAS 管理模块可用，ZRAM 与 NeedReboot v1 能力存在，当前启用值可信。
2. 确认压缩行为将在重启后改变，不在保存流程自动重启 NAS。
3. 复读 ZRAM，确认仍与编辑基线一致；复读 NeedReboot 确认字段完整。
4. 只提交一次 `ZRAM.set`，随后 `NeedReboot.set`；不自动重放任何写请求。
5. 重新读取 ZRAM 和 NeedReboot，开关符合目标且重启标记为 true 才确认保存。

中途断线、设置成功但标记失败或结果不符都显示结果待确认。模型保留刷新要求；失败刷新
不能解除重复提交保护，成功刷新后才允许按当前状态重新编辑。权限拒绝不绕过。

## 读取兼容与降级

- 主字段为 `enable_zram`；保留 `enable/enabled/zram_enable` 的历史兼容，原生 Boolean
  以外的值不解释为开关；同义字段冲突保持未知。
- 历史可选容量只接受单位明确的非负整数 `configured_bytes/capacity_bytes/size_bytes`；
  算法仅归一 `lz4/lzo/zstd`，缺失不猜默认值。
- 能力缺失、字段不完整、权限和读取失败只影响此页面。错误不能显示为“已关闭”。

## 五端影响与验证

macOS 实现开关、风险确认、保存、回读和恢复；共享 Apple 新方法有默认不支持实现，
iPhone/iPad 尚无对应写界面。Windows/Android 本轮未修改，不能将 macOS 新写能力当作
它们已经具备。未改变持久化、Bundle ID、认证或外部公开 API。

正式测试见 `DsmNasAdministrationRepositoryTests`、`NasAdministrationModelTests`，覆盖
当前字段、别名冲突、零写拒绝、保存与标记顺序、断线和刷新保护。Schema：
`contracts/schemas/nas-hardware-editing.schema.json`；请求样本位于
`contracts/request-fixtures/hardware/set-zram/` 与 `mark-reboot-required/`。

`PENDING_USER_VALIDATION`：在可维护的 NAS 上分别保存关闭/开启，确认提示需要重启、
保存本身不触发重启，再由用户单独安排重启并检查最终状态、服务和内存表现。回传仅需
脱敏错误文字、DSM 版本、步骤与结果；不要回传地址、账号、令牌或完整响应。

历史 2026-08-03 lab-a 仅观察控件，保持 static，不能继承本轮读证据。环境见
[本轮快照](../environments/2026-10-02-nas-settings-web-audit.md)。全部真实 set 行为未验证。

## 2026-10-05 移动 M6a1 接入

iPhone/iPad M6a1 已接内存压缩读取和明确未知状态，仅在返回时显示容量/算法；开关保存继续在 M6c 实施。未实现的写入口不列为待真机，实施后按实际能力/权限开放，不再另加仅因未实测而关闭的常量。当前环境命令与两端页面验证集中在[移动主计划](../../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md#m6a1-五项读取与筛选)及其验证历史；真实 NAS 证据不提升。
