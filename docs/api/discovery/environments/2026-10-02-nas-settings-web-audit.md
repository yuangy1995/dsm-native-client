# NAS 设置全项网页核对（2026-10-02）

根据环境模板建立；只观察用户已登录的 Chrome 官方页面，不保存真实身份、地址、路径或响应正文。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不注册 current 基线 |
| 匿名设备别名 | 与既有 lab-a 的关系未确认 |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-10-02 至 2026-10-03 |
| DSM 版本 | 7.2.1 |
| DSM build | 69057 |
| Update | 12 |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户已登录 Chrome；QuickConnect 直连地址类别（不保存地址） |
| 证书类别 | 未验证 |
| 账号权限类别 | 可访问官方管理页面；角色待核对 |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| dsm-core | DSM | 7.2.1-69057 Update 12 | 不操作运行状态 | 套件按实际覆盖追加 |

## 证据来源

- [ ] `SYNO.API.Info` 脱敏能力发现。
- [x] 已登录官方网页的只读网络请求。
- [ ] 官方公开文档。
- [x] 官方前端静态资源中的候选接口。
- [x] 客户端自动化契约测试（完全合成，不提升真实行为证据）。
- [ ] 专用测试环境的受控行为验证。

相关文档或 fixture：

- [21 页核对账本](../../../development/NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)

## 发现范围

- 本次目标：对照 macOS NAS 设置全部 21 页的读取、字段含义、单位、状态、可编辑性和操作语义，修复已证实差异并同步 API 文档。
- 明确不执行：真实配置保存、权限/网络变更、创建/删除、服务启停、检测任务启动、重启或关机。
- 当前限制：只读页面和静态前端不能构成写行为验证；未接外设等条件缺口单独记录。

## 安全检查

- [x] 未将 Cookie、SID、SynoToken、DID、OTP 或密码保存到文件或仓库。
- [ ] 未保存 NAS 地址、IP、QuickConnect ID、序列号或证书指纹。
- [x] 未将用户名、共享名、真实路径、文件名、消息或日志正文保存到文件或仓库。
- [x] 未点击真实 NAS 的保存、安装、卸载、启停、重启、删除或权限变更按钮。
- [x] 未导出 HAR、原始响应或真实 NAS 截图；仅生成本机合成 UI 和测试日志，交付前清理。

## 结论

- 已确认：信息中心版本；21 个客户端页面的官方对应入口已逐项打开观察（细节见账本）。ZRAM 与硬件常规接口的成功响应已核对最小字段，安全/日期/风扇/电源计划与 ZRAM 写请求仅从官方前端静态绑定提取。
- 套件中心目录/安装/更新及设置已形成原生实现和合成测试；以实施账本记录最终验证结果。
- 未验证：全部真实写入。
- 需要在其他版本或权限下复验：其他 DSM/套件版本、普通账号与本环境未安装硬件。

## 最小契约观察

- `SYNO.Core.Hardware.ZRAM.get` v1：成功 `data.enable_zram` 为 Boolean；当前响应不含容量与算法。
- `BeepControl.get` v1：`support_fan_fail/support_volume_crash/support_poweron_beep/support_poweroff_beep/support_reset_beep` 为 Boolean；支持位为 false 时不应呈现写控件。
- `FanSpeed.get` v1：`cool_fan` 文本与 `fan_type` 数字。当前 `yes` + 位值 11 对应网页的全速/低温/静音三档。官方静态 `FAN_MODE_ENUM` 为高 1、低 2、低速停转 4、全速 8；`no` 使用 highfan/lowfan，`single` 仅全速与静音。
- `Firewall.Conf`：官方控件 `name=enable_port_check` 绑定 `firewall_enable_port_detect`，语言表为“启用防火墙通知”；描述为服务被阻挡时通知并提供解锁选项。字段不是防端口扫描。此含义由官方 UI 与静态绑定证实，本轮未发送 set。
- 区域格式：日期为 `Y-m-d/Y/m/d/Y.m.d/d-m-Y/d/m/Y/d.m.Y/m-d-Y/m/d/Y/m.d.Y`；时间集合由 `h:i` + ` a`、`H:i` + 空后缀构成。
- 电源计划：官方静态 `save` v1 整表提交 `poweron_tasks` 与 `poweroff_tasks`，数组项为 `enabled:Boolean`、`weekdays:String`、`hour:Int`、`min:Int`；最大 200 条。读取只证明现有每天/每周计划，未验证 save。
- 内存压缩写候选：官方 `set` v1 使用 `enable_zram`；另调用 `SYNO.Core.Hardware.NeedReboot.set` v1（无业务参数）登记需要重启，`get` 返回 `need_reboot`。页面随后通过独立重启流程提示用户，本轮没有执行这些写方法。

## 2026-10-03 套件中心追加观察

只读打开全部套件目录，确认 `SYNO.Core.Package.Server.list` v2 通过运行时发现的
`entry.cgi` 使用 JSON 请求格式，参数 `blforcereload=false`、`blloadothers=false`。
成功响应包含 `packages[]`、`beta_packages[]`、`categories[]` 等。条目白名单类型：
`id/dname/version/desc/changelog/link/md5/source/maintainer/depsers` 为 String，
`size/type/download_count` 为 Number，`qinst/qupgrade/qstart/start/beta` 为 Boolean，
`category/thumbnail/thumbnail_retina/snapshot` 为数组；依赖、冲突、替换字段可为 null。
仅记录类型，不保存实际套件列表、下载地址或响应正文。

已安装列表的 `additional.available_operation` 实际为 Object；其中 `upgrade` 是完整候选
Object，而不是旧合成测试中的字符串数组。官方按钮逻辑使用状态及 `startable` 控制启停、
`ctl_uninstall` 控制卸载；对象不是启停许可列表。Apple 已兼容对象并保留历史数组限制。

官方前端静态证据（不是实机写入验证）：

- Installation 支持 v1...2；Download 支持 v1。
- `Installation.check` v2：id/ver/size、depsers/deppkgs/conflictpkgs/breakpkgs/replacepkgs、
  blupgrade、install_type、install_on_cold_storage、blCheckDep=false。结果含 volume_count、
  volume_list[{mount_point,display,vol_desc,volume_features}]、volume_path、is_occupied。
- 快速安装 `install/upgrade` v1 参数 name、blqinst、volume_path、is_syno、beta、
  installrunpackage。官方依据 qinst/qupgrade 等选择快速安装，并使用同一进度任务。
- 分步下载 `install/upgrade` v1 参数 name/url/checksum/filesize/type/blqinst/operation；
  `Download.check` v1 以 taskid 检查下载结果。codesign_error 表示签名错误，客户端不得
  默认跳过；向导提交使用 check_codesign=true。
- `Installation.status` v1 参数 task_id；`cancel` v1 使用 taskid，名称不同不得混淆。
- `Installation.get_queue` v1 参数 pkgs，结果会检查 non_exist_pkgs、依赖和冲突；
  详细字段和响应类型已按以下补充记录。
- 手动上传 `Installation.upload` v1 是文件上传，字段 file 和 additional；向导正式提交
  以 task_id 或 path 标识准备内容；退出使用 clean/delete 清理对应暂存对象。
- 通用向导会读取套件自定义页面及字段；专属动态行为和许可证不得跳过或静默接受。

当前只完成来源读取与前端静态核对。安装、更新、上传、取消、清理与卸载均未在真实 NAS
执行，合成测试与客户端实现不提升真实写行为等级。

## 套件中心静态契约补充与收尾

- 任务提交的标识为 `taskid`，部分包装在 `data.taskid`；后台查询使用 `task_id`，
  状态字段为 `finished:Boolean`、`progress:Number`、`success:Boolean`。
- 队列请求 `pkgs:[{pkg,operation:"install",version,beta}]`；响应 `queue:[{pkg,beta,...}]`，
  以及 `non_exist_pkgs/conflicted_pkgs/broken_pkgs/replaced_pkgs/paused_pkgs/cause_pausing_pkgs`。
- 快速路径取决于官方源、qinst/qupgrade 和 info.blqinst；系统安装类型为
  `system/system_hidden`。元数据按 additional 字段优先、根字段其次。
- 手动/分步准备元数据包括 id/name/version、task_id 或 filename、licence、install_pages、
  install_reboot、startable 和依赖/替换信息。表单字段是 key/desc/defaultValue/validator，
  支持文本、密码、复选、单选与下拉；官方脚本校验不能在原生端跳过。
- 最终安装参数 extra_values 是 JSON 文本，check_codesign 必须为 true；上传向导
  force=false，目录下载向导 force=true。清理使用 delete 的 path 或 clean 的 task_id。
- 官方设置窗口已只读打开常规、自动更新、套件来源；没有更改控件，结束时点击“取消”。
  Setting.get/set v1 的通知、频道、默认位置与自动更新字段仍只记录 static 绑定，
  不声称已经核对实际响应。每套件更新策略来自 Package.list v2 additional。
- Feed.list v1 返回 items[{name,feed}]；add/set 的 list 为 JSON 对象文本，
  set 加 orifeed；delete 的 list 为地址数组 JSON 文本。路径仍依赖运行时发现；
  本轮没有额外导出 API.Info 来确认 Feed 目录，不把前端方法名等同于运行时可用。
- Info.get v1 的 prerelease.success/agreed 控制测试版协议；Legal.PreRelease.set
  只在官方接受协议后调用，岚仓不代为接受。

浏览器开发者工具与设置对话框已关闭，保留用户原有 DSM 页面；未在当前 NAS 进行
任何安装、上传、清理或配置保存。合成 UI 截图使用本机虚构资料，与真实 NAS 无关。
