# 套件中心更新与设置修复观察（2026-10-03）

根据模板建立。用户明确授权观察一次已安装套件更新；只记录兼容必要结构，不导出原始抓包或会话材料。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不注册 current 基线 |
| 匿名设备别名 | 与既有 lab-a 的关系未确认 |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-10-03 |
| DSM 版本 | 7.2.1 |
| DSM build | 69057 |
| Update | 12 |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户已登录 Chrome；QuickConnect 直连地址类别，不保存地址 |
| 证书类别 | 未验证 |
| 账号权限类别 | 可访问管理页面并完成本次套件更新；角色未另行读取 |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| dsm-core | DSM | 7.2.1-69057 Update 12 | 不改变系统运行状态 | 信息中心当日重新读取 |
| MediaServer | 媒体服务器 | 2.2.1-3406 → 2.2.2-3412 | 更新后官方页面显示“已启动” | 唯一获授权更新目标，Synology Inc. 官方套件 |

## 证据来源

- [ ] `SYNO.API.Info` 脱敏能力发现。
- [x] 已登录官方网页的必要网络请求；仅更新动作例外获得明确授权。
- [ ] 官方公开文档。
- [x] 官方前端静态资源中的候选接口。
- [ ] 客户端自动化契约测试。
- [x] 用户在当前已登录环境明确授权的一次单套件更新；不外推其他套件或操作。

相关文档或 fixture：

- `docs/api/discovery/endpoints/dsm-package-installation.md`
- `docs/development/PACKAGE_CENTER_FIX_20261003_ZH.md`

## 发现范围

- 本次目标：核对官方套件更新的预检、队列、安装和状态请求，以及套件中心设置的真实字段。
- 明确不检查：批量更新、卸载、网络/权限/电源修改、用户文件及日志正文。
- 当前限制：仅执行 MediaServer 的一次官方更新；其他操作保持读取。先核对发行者及起止版本，再点击更新；没有批量更新、安装其他套件、接受新协议或修改设置。

## 安全检查

- [x] 未将 Cookie、SID、SynoToken、DID、OTP 或密码保存到文件或仓库。
- [x] 未将 NAS 地址、IP、QuickConnect ID、序列号或证书指纹保存到文件或仓库。
- [x] 未将用户名、真实路径、文件名、消息或日志正文保存到文件或仓库。
- [x] 未执行授权范围外的写操作。
- [x] 没有导出 HAR、原始响应或真实 NAS 截图；仅保存完全合成 fixture。

## 结论

- 已确认：官方 MediaServer 单套件更新为 `behavior-verified`，旧版本 2.2.1-3406，最终安装版本 2.2.2-3412，状态“已启动”。没有把点击或下载开始当作完成。
- 未验证：修复后的岚仓客户端在真实 NAS 提交更新、设置保存、取消/中断、手动安装、来源管理、其他套件及依赖组合。客户端合成测试不能替代这些验证。
- 需要在其他版本或权限下复验：其他 DSM build、套件版本和普通/受限账号；不能提升匿名归属未确认的历史 lab-a 基线。

## 最小结构与本次差异

- `SYNO.Core.Package.feasibility_check` v1：官方发送 `type:"install_check"` 与套件 ID 数组；实际成功仅为 `{"success":true}`，**没有 data**。这是原客户端点击更新即报错的直接原因。拒绝响应仍必须阻止继续。
- `Installation.get_queue` v1：实际 `queue` 项含 `pkg:String/beta:Boolean/volume:String`，并返回 `broken_pkgs/cause_pausing_pkgs/conflicted_pkgs/non_exist_pkgs/paused_pkgs/replaced_pkgs` 数组。本次均无附加依赖影响；不据此推断复杂队列安全性。
- `Installation.check` v2：官方传 id/ver、blupgrade=true、blCheckDep=false、size、depsers 和可空的依赖/冲突字段；返回 `is_occupied:Boolean`、`volume_count:Number`、`volume_list` 和 `volume_path:String`。仅记录字段与类型，位置值不保存。
- `Installation.upgrade` v1：此次开始请求使用 `blqinst=false`；响应 data 为 `progress:Number/taskid:String`。实际 `Installation.status` v1 响应 data 包括 `finished/progress/success`，另外存在 `installing/blqinst/beta` 等布尔状态；任务编号及暂存位置只在官方页面中使用，不保存。
- `Setting.get` v1：`update_channel` 实际是 **Boolean**，通知与三个自动更新字段也是 Boolean。本次单卷返回 volume_list，但**不含 default_vol**；这些差异不可按畸形整页拒绝。
- `Setting.set` v1：官方静态保存函数将同一布尔开关转换为 **stable/beta 字符串**，通知与自动更新仍为 Boolean；本次没有保存设置，不能把读取类型直接套到写入参数。
- 合成 fixture：`packages/feasibility/synthetic-success-without-data`、`packages/settings/synthetic-boolean-channel`，均以 synthetic/static 标注，完全重建，不含真实响应值。
