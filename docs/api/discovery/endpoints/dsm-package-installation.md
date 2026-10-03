# DSM 套件中心内部 API

## 标识与当前范围

- 稳定标识：`dsm-package-installation`；组件：`dsm-core`；分类：`internal`；操作：`mixed`；风险：`high`。
- macOS 实现目录、搜索、分类、详情、安装、更新（含依赖队列）、手动上传、进度、取消下载、默认安装位置、通知、自动更新与套件来源管理。启停与卸载继续使用 [`dsm-package-control`](dsm-package-control.md) 的确认、可行性检查和结果链路。
- 2026-10-02/03 的用户授权取消仅因未实测设置的入口禁用，但不取消运行时能力、服务器权限、签名、许可、确认、并发及结果检查。旧 `.upgrade` 直接控制接口继续拒绝；更新统一进入安装计划。
- 本轮环境为 DSM 7.2.1-69057 Update 12，设备匿名归属待确认。目录、设置 get、可行性预检与队列为 `read-verified`；2026-10-03 按本轮明确授权通过官方网页完成 MediaServer 2.2.1-3406 → 2.2.2-3412，最终“已启动”，此单目标官方更新为 `behavior-verified`。其他写流程和岚仓客户端真实提交仍未验证，不提升既有 lab-a 等级。
- 发现记录：[首次环境快照](../environments/2026-10-02-nas-settings-web-audit.md)、[2026-10-03 单套件更新与设置类型更正](../environments/2026-10-03-package-center-followup.md)。

## 能力、版本与传输

全部路径、版本范围和编码格式来自运行时 `SYNO.API.Info`；不固定 NAS 地址。HTTP 使用 `POST`，DSM JSON 请求格式仍通过表单键值承载逐值 JSON 编码，不能把对象或 Boolean 编码成普通显示字符串。认证保持现有会话请求构造器策略，不把会话放入下载、图标或第三方来源 URL。

| API | 方法与版本 | 主要参数 / 返回字段 | 证据 |
| --- | --- | --- | --- |
| `SYNO.Core.Package` | `list` v2 | `additional` 中请求状态、描述、可用操作；自动更新设置另请求 `silent_upgrade/autoupdate/status` | 目录结构只读核对，自动更新附加字段为 static |
| `SYNO.Core.Package.Server` | `list` v2 | `blforcereload=false`、`blloadothers=false/true`；返回 `packages[]/beta_packages[]/categories[]` | 官方目录成功响应 read-verified；第三方分支 static |
| `SYNO.Core.Package` | `feasibility_check` v1 | `type=install_check`、`packages:[id]`；成功可以没有 data | read-verified |
| `SYNO.Core.Package.Installation` | `get_queue` v1 | `pkgs:[{pkg,operation:"install",version,beta}]` | read-verified |
| 同上 | `check` v2 | `id/ver/size/depsers/deppkgs/conflictpkgs/breakpkgs/replacepkgs/blupgrade/install_type/install_on_cold_storage/blCheckDep`，按源数据存在性传参 | 本次更新前检查 read-verified |
| 同上 | `install/upgrade` v1 | 快速与分步参数见下文 | upgrade 的单目标分步更新已观察；其余 static |
| 同上 | `status` v1 | `task_id`；返回 `finished:Boolean/progress:Number/success:Boolean` | read-verified（本次更新） |
| 同上 | `cancel` v1 | **`taskid`**，与 status 字段名不同 | static |
| `SYNO.Core.Package.Installation.Download` | `check` v1 | `taskid="@SYNOPKG_DOWNLOAD_" + id` | static |
| `SYNO.Core.Package.Installation` | `upload` v1 | multipart `file`，`additional` 为 JSON 数组文本 | static |
| 同上 | `clean/delete` v1 | `clean:{task_id}`；`delete:{path}` | static |
| `SYNO.Core.Package.Info` | `get` v1 | `config/term/prerelease`；测试版依赖 `prerelease.success/agreed` | static |
| `SYNO.Core.Package.Setting` | `get/set` v1 | get 的频道为 Boolean；set 为 stable/beta；通知与自动更新策略 | get 为 read-verified，set 为 static |
| `SYNO.Core.Package.Setting.Volume` | `get` v1 | `default_vol` | static |
| `SYNO.Core.Package.Feed` | `list/add/set/delete` v1 | `items:[{name,feed}]`；写入 `list` 是 **JSON 字符串** | static；客户端仍要求运行时发现该版本 |

`Package.Server`、`Installation` 客户端协商范围为 v1...2，但实际调用目录要求 v2、check 要求 v2、其他方法固定 v1。缺失某能力时只影响依赖该能力的操作。第三方目录加载失败保留官方目录，并在第三方分类明确显示错误。

## 目录与操作解释

目录条目最小白名单：`id/dname/version/desc/changelog/source/maintainer`，分类数组和大小；下载地址、校验值与依赖元数据仅在当前 Repository 内存中用于预检和提交，不进入日志或持久化。描述、更新说明和许可仅呈现文字，不运行 HTML、脚本或加载嵌入资源。

`Package.list.additional.available_operation` 在本轮实际响应中为对象，`upgrade` 值是完整候选对象。对象不等于启停许可列表：启停使用 `status/startable`，卸载使用 `install_type/ctl_uninstall`。保留历史字符串数组响应的显式操作限制。更新必须有 DSM 明确候选；不能只比较版本文本后自行升级或降级。

## 安装计划与依赖

1. 刷新目录及已安装版本，拒绝消失、无法识别或没有更新候选的目标。
2. `feasibility_check` 让 NAS 校验权限和业务可行性；成功可只有 `success:true`，复用无正文命令解析，拒绝不能被客户端改成继续。
3. `get_queue` 返回 `queue:[{pkg,beta,...}]`，并提供 `non_exist_pkgs/conflicted_pkgs/broken_pkgs/replaced_pkgs/paused_pkgs` 等数组。缺失依赖、冲突或畸形队列拒绝安装；额外依赖按服务端顺序纳入确认清单。暂停/替换目标进入风险摘要。
4. 每个目标 `check` 取得 `volume_list:[{mount_point,display,...}]`、`volume_path`、`is_occupied`。安装位置须来自当前返回；`system/system_hidden` 可以无普通卷；官方前端明确允许 volume_list 缺省或 null，客户端仅对这两种已确认安装类型接受该形状，普通套件仍必须有可选位置。
5. 用户确认套件、版本、依赖、位置与服务中断风险。提交前再次检查计划、候选元数据和已安装版本，变化即要求重新确认。
6. 只读准备阶段可取消；取消传播到当前读取，迟到成功/失败不恢复计划或弹出旧错误，Repository 互斥不被强行清除。确认之后的提交阶段只允许关闭窗口并在后台继续，不将关闭伪装成取消安装。
7. 全局安装队列与现有启停/卸载互斥。每个依赖核对成功后才提交下一项；中断时停止后续操作，不尝试回滚已经安装的依赖。

## 快速与分步安装

官方源且 `qinst/qupgrade`、`info.blqinst` 未明确关闭时使用快速路径：

```text
Installation.install/upgrade v1
{name, blqinst:true, volume_path, is_syno, beta, installrunpackage}
```

其余先下载：

```text
Installation.install/upgrade v1
{name, url, checksum, filesize, type, blqinst:false, operation:"install"|"upgrade"}
```

提交返回的 `taskid`（部分包装为 `data.taskid`）只在内存保存。轮询 `status`，不重复提交。下载完成后 `Download.check` 得到校验结果与安装选项。`codesign_error` 拒绝继续，绝不发送 `check_codesign=false`。

最终安装参数：`volume_path`、`extra_values`（JSON 文本）、`type`、`check_codesign=true`、`force=!manualUpload`、`installrunpackage`，以及由本次准备结果提供的 `task_id` 或 `path`。之前执行 check v2，手动上传使用 `blCheckDep=true`。本客户端不自动重启 NAS。

## 手动上传、自定义选项与清理

- 本地选择 `.spk` 正规文件；分块构建仅当前进程使用的 0600 临时 multipart 文件，固定上传文件名为 `package.spk`，不传本机目录。完成或失败删除本地暂存文件。
- `additional` 请求 `description/maintainer/distributor/startable/dsm_apps/status/install_reboot/install_type/install_on_cold_storage/break_pkgs/replace_pkgs`。
- 元数据按官方规则优先 `additional[key]`，其次根级字段。`install_pages` 支持数组或 URL 编码 JSON 文本。
- 原生表单支持说明、文本、密码、复选、单选、静态下拉；保存 `item.key` 对应的原生 String/Boolean，保留默认值、必填与长度约束。密码只存当次表单内存，不记录。
- 套件脚本校验、正则/专属 vtype、动态远程数据源和无法等价呈现的隐藏/禁用字段不能忽略，明确提示在 DSM 完成。此限制来自表单能力，不是缺少实测的发布开关。
- 许可协议必须展示并由用户同意；首次测试版协议需要在 DSM 完成，客户端只检查已有 `prerelease.agreed`，不代为接受。付费/激活步骤也留在 DSM。
- 仅取消本次下载或清理本次 `Download.check/upload` 返回的暂存目标。下载取消提交一次后继续查状态，不把接受取消误报为已取消。正式安装阶段不提供无法保证安全的取消。

## 设置与来源

Setting.get 返回 `update_channel:Boolean`、`enable_email/enable_dsm/enable_autoupdate/autoupdateall/autoupdateimportant:Boolean` 和 `volume_list`。`default_vol` 可缺省，特别是本次单卷响应；单卷不显示多余的位置选择器。自动更新单个套件状态来自 Package.list 的 `additional.autoupdate/autoupdate_important/silent_upgrade/status/limit_type`。`no_default_vol` 表示每次选择。

Setting.set 的 `update_channel` 仍为 `stable` 或 `beta`，不能照搬 get 的布尔类型。仅在完整基线复读一致后提交；命令使用 success 信封，不能要求一定返回 data。按套件设置时 `packages/packages_important` 为 JSON 数组**文本**，默认位置未修改不提交。保存后检查所有目标字段；结果未知须刷新，不自动重放。

Feed.add/set 的 `list` 为 JSON 文本 `{name,feed,orifeed?}`；delete 为 JSON 文本 `[feed]`。新增/编辑要显示“来源证书也将被信任”的具体风险，HTTP 地址另提示未加密连接；不接受带账号密码的 URL，不自动添加来源、不修改信任级别。删除前核对原条目，删除后确认该地址不再出现，不卸载套件。

## 结果、失败与恢复

- `finished/success` 不能代替结果确认：完整 Package.list 必须包含精确 ID、目标版本与终态，才显示成功。
- 网络异常、缺失任务编号或版本不符：`unverified`，仅允许查同一任务/当前版本，不重放 install/upgrade。
- 同版本手动重装在提交结果未知时不能仅靠旧版本相等确认成功。
- 权限/认证/API 不支持或明确 DSM 拒绝：失败，不继续队列；未知错误不显示原始 NAS 日志。
- 准备过程中发现不支持表单或签名错误：没有正式安装，只清理属于本次准备的暂存内容。
- 返回值、任务与安装计划限当前连接内存。退出应用后请先在 DSM 检查已有任务；没有跨应用重启的任务恢复存储。

## 五端影响、验证与定位

- macOS：上述原生主流程；真实写入、第三方来源、不同卷/DSM、断线和权限场景均为 `PENDING_USER_VALIDATION`。
- Apple 共享层：新增可选 Repository 方法与默认不支持实现，不改变认证、存储格式或既有控制方法；iPhone/iPad 未增加页面，需按各自范围迁移。
- Windows、Android：本轮没有改代码，仍保留原来的已安装管理/更新提示；迁移需采用本记录的对象字段、队列、确认、恢复与结果语义，不能照搬旧 `.upgrade` 控制。
- 正式自动化：`DsmPackageCenterTests`、`NasAdministrationModelTests`、`WorkspacePresentationTests`。合成测试不构成真实写行为验证。
- 源码：`NasPackageCenter.swift`、`DsmNasAdministrationRepository+Package*.swift`、`PackageCenterView.swift`、`PackageInstallationSheet.swift`、`PackageCenterSettingsView.swift`。
- Schema 与合成请求样本位于 `contracts/schemas/nas-package-center.schema.json`、`contracts/request-fixtures/packages/`；未保存真实响应正文或原始 HAR。

历史 lab-a 的 2026-07-31 记录只确认 API 方法名与升级提示，保持原等级。当前实现和用户授权以本节为准，不改写历史兼容证据。


2026-10-03 二次反馈：系统安装类型与准备取消的源码、合成样本和验证见[后续观察](../environments/2026-10-03-photos-package-followup.md)。本轮只观察清单和官方静态分支，没有执行新的 NAS 更新。
