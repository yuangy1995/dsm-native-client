# DSM 物理网卡设置内部 API

## 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-ethernet-settings` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 控制面板网络设置 |
| 能力名称 | 物理网卡读取与配置 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `critical` |

## 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Network.Ethernet` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 列表 v2；详情与设置 v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

参数：

| 参数 | 类型 | 必需 | 含义 | 脱敏示例 |
| --- | --- | --- | --- | --- |
| `ifname` | `string` | 详情读取需要 | 稳定网卡标识 | `eth0` |
| `configs` | `object[]` | 设置需要 | 只包含目标网卡的一项配置 | 使用完全合成的 DHCP 配置 |
| `use_dhcp` | `boolean` | 设置需要 | 是否自动获取 IPv4 设置 | `true` |
| `ip`、`mask`、`gateway`、`dns` | `string` | 静态 IPv4 时需要 | 地址配置 | Fixture 不保存地址值 |
| `is_default_gateway` | `boolean` | 设置需要 | 是否作为默认网关 | `false` |
| `mtu` | `integer` | 设置需要 | MTU | `1500` |
| `enable_vlan`、`vlan_id` | 多类型 | 按 VLAN 状态 | VLAN 开关与标识 | `false` / 不提交 |

设置只发送用户正在编辑的单张网卡，不得把读取到的其他网卡配置整体回写。

## 响应与错误

成功响应结构：

```json
{
  "success": true,
  "data": {
    "ifname": "eth0",
    "use_dhcp": true,
    "mtu": 1500,
    "enable_vlan": false
  }
}
```

| 字段 | 类型 | 必需 | 版本差异 | 客户端处理 |
| --- | --- | --- | --- | --- |
| `interfaces` | `array` | 列表需要 | 部分响应直接返回数组 | 兼容两种容器后逐项读取 |
| `ifname` | `string` | 是 | 无已知差异 | 只接受 `eth` 开头的安全标识 |
| `use_dhcp` | `boolean` | 详情需要 | 无已知差异 | 决定是否读取静态 IPv4 字段 |
| `mtu` / `mtu_config` | `number` | 否 | 字段名可能不同 | 兼容读取，提交统一使用 `mtu` |

错误与权限：

| 场景 | 错误语义 | 是否可重试 | 降级或恢复 |
| --- | --- | --- | --- |
| API 或版本未发现 | 当前环境不支持 | 否 | 关闭网卡编辑入口 |
| 权限不足 | 当前账号不能修改网络 | 否 | 提示使用具备网络管理权限的账号 |
| 提交前读取失败 | 未发送设置 | 按错误类型 | 保留编辑内容，修复连接后重试 |
| 提交时断网或超时 | 可能已经应用 | 否 | 使用新地址或原地址重新连接并核对 |
| 提交后回读失败或不一致 | 最终状态未确认 | 否 | 重新连接并刷新，不自动再次提交 |

## 版本验证

| 环境标识 | 证据等级 | 接口版本 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `observed` | list v2；get/set v1 | 只读结构和网页请求已记录；未执行写行为验收 | 2026-07-27 | `docs/api/DSM_WEB_API_REFERENCE_ZH.md` |

## 能力探测与降级

- 启用条件：运行时发现 `SYNO.Core.Network.Ethernet` 且版本范围可用。
- 新版本默认行为：未记录的新 DSM build 默认关闭内部写入口。
- 接口缺失：网卡页独立降级，不阻断文件浏览等主流程。
- 字段缺失或类型变化：无法构造完整网卡时忽略该项，不提交猜测字段。
- 权限不足：不提升权限，不尝试其他账号。
- 网络失败：提交前失败可以修复后重试；提交后失败必须先重新连接并回读。
- 替代的官方 API：当前项目未找到满足 DSM 物理网卡配置需求的公开 API。
- 功能开关：NAS 设置模块开关、运行时能力发现与网卡编辑入口共同控制。

## 客户端与测试

- Apple Adapter：`DsmNasAdministrationRepository`。
- Android Adapter：`DsmRepository.saveEthernetInterfaceResult`；列表 v2 与详情/设置 v1 均按发现范围严格校验，版本不足时关闭写入口。
- Windows Adapter：已接 list v2 与按安全 ifname 的 get v1，兼容对象/直接数组列表；
  保留缺失默认网关、VLAN、MTU、DNS 为未知，按快照报告部分读取失败。原生只读
  入口及单网卡 configs 保存核心已接线；完整基线、输入校验、单请求/回读与地址变化
  恢复有合成证据。新地址拒绝旧 SID，重新登录后还需确认同一 NAS；不自动探测新地址
  或重发设置。网络生产行为门独立关闭，未做真实网络变更。
- Schema：复用 `MutationResult` 与请求 Fixture Schema。
- 脱敏 fixture：`contracts/request-fixtures/network/set-ethernet/synthetic-interface/request.json`。
- 自动化测试：Android `EthernetMutationResultTest` 的 10 项合成测试覆盖共享 Fixture、DHCP/静态 IPv4/VLAN、直接数组列表、版本不足零请求、输入拒绝、无变化、权限拒绝、提交响应丢失、回读断线和同网卡重复提交；Apple 既有测试覆盖确认成功、提交断网、回读超时、重复提交和提交后取消。
- 产品兼容矩阵条目：`NAS 设置`、`统一写操作结果 MR0/MR1/MR2`。

## 安全与副作用

- 会读取的数据类别：网卡状态、地址配置、默认网关、MTU 与 VLAN 设置。
- 可能产生的副作用：当前连接中断、NAS 地址变化、默认路由或 VLAN 改变。
- 所需权限：由 DSM 返回的能力和当前会话权限决定。
- 重复提交保护：Android/Apple Repository 与 macOS 模型均按稳定网卡标识阻止并发保存。
- 写后结果校验：按 `ifname` 回读所有已提交字段；未知结果不得自动重放。
- 临时数据清理：不生成 HAR、响应转储或含地址的 Fixture。

## 未验证事项

- 当前环境未在专用测试网络完成 DHCP/静态地址、默认网关、MTU、VLAN、权限不足、
  连接中断和回滚行为验收。
- 不同 DSM build 的地址生效时序、旧地址保留时间和错误码差异尚未验证。
- Android 调用链已迁移但尚未做设备及真实 DSM 写操作验收；Windows 读取/只读界面
  与单目标保存/重连恢复有合成证据，生产行为门关闭；iPhone、iPad 用户调用链尚未迁移。
