# 套件中心安装与控制

同一功能域的内部接口定义合并于此；每个端点以稳定标识锚点定位，总览与证据入口见[端点索引](INDEX.md)。

<a id="dsm-package-control"></a>
## DSM 套件启动、停止与卸载内部 API


### 标识

| 字段 | 值 |
| --- | --- |
| 端点或端点组标识 | `dsm-package-control` |
| 项目组件标识 | `dsm-core` |
| 所属范围 | DSM 套件中心 |
| 能力名称 | 已安装套件列表、操作可行性检查、启动、停止与卸载 |
| 分类 | `internal` |
| 操作性质 | `read / write` |
| 风险等级 | `high` |

### 请求契约

| 字段 | 值 |
| --- | --- |
| API 名称 | `SYNO.Core.Package`、`SYNO.Core.Package.Control`、`SYNO.Core.Package.Uninstallation` |
| 路径 | 运行时通过 `SYNO.API.Info` 发现 |
| HTTP 方法 | `POST` |
| API 版本 | 套件列表 v2；可行性检查、启动、停止与卸载 v1 |
| 鉴权机制 | DSM 会话 Cookie/表单与令牌请求头/表单，不记录值 |
| 内容类型 | `application/x-www-form-urlencoded` |

| API / 方法 | 参数 | 类型 | 必需 | 含义 |
| --- | --- | --- | --- | --- |
| `Package.list` | `offset`、`limit`、`additional` | 多类型 | 是 | 读取稳定套件 ID、状态、可用操作和桌面应用标识 |
| `Package.feasibility_check` | `type` | `string` | 是 | 启动、停止、卸载分别使用 `start_check`、`stop_check`、`uninstall_check` |
| `Package.feasibility_check` | `packages` | `stringArray` | 是 | 只包含当前目标的稳定套件 ID |
| `Package.Control.start` | `id` | `string` | 是 | 启动目标套件 |
| `Package.Control.start` | `dsm_apps` | `stringArray` | 是 | 使用列表返回的桌面应用标识，不接受用户输入 |
| `Package.Control.stop` | `id` | `string` | 是 | 停止目标套件 |
| `Package.Uninstallation.uninstall` | `id` | `string` | 是 | 卸载目标套件 |
| `Package.Uninstallation.uninstall` | `dsm_apps` | `stringArray` | 是 | 使用列表返回的桌面应用标识，不接受用户输入 |

客户端不得根据界面行号、显示名称或翻译后的状态选择目标。每次启动、停止或卸载都先重新
读取列表，确认稳定套件 ID 仍存在且当前动作明确可用，再执行 `feasibility_check`。卸载还
必须确认套件不是系统类型，并且 `ctl_uninstall=true` 或可用操作包含 `uninstall`；字段缺失
时默认关闭。任何预检失败都不得发送写请求。

### 结果语义与写后回读

1. 同一稳定套件 ID 的启动、停止和卸载共享 Repository 互斥，不能并行提交。
2. 写请求明确成功后最多读取套件列表十次，每次间隔一秒，确认目标达到运行或停止状态。
3. 写请求超时、断线、响应无效或服务繁忙时，不重放原写请求，只读取列表核对；普通
   模糊失败最多核对三次。
4. 提交阶段取消后使用独立的只读任务尝试一次状态核对；无法确认时保留“提交后取消”
   语义。
5. 只有列表确认目标状态后才返回 `confirmedSuccess`。列表仍是旧状态、目标意外消失或
   回读失败时返回 `submittedButUnverified`，要求用户刷新后再决定下一步。

| 场景 | 结果语义 | 恢复方式 |
| --- | --- | --- |
| API 未发现或版本不可用 | 不支持、未提交 | 关闭对应操作入口 |
| 套件不存在或当前状态不允许动作 | 预检失败、未提交 | 刷新列表并核对套件状态 |
| 可行性检查权限不足 | 权限拒绝、未提交 | 使用具备套件管理权限的账号 |
| 写请求明确权限不足或会话失效 | 明确失败 | 重新登录或更换有权限的账号 |
| 写请求后列表确认目标状态 | 确认成功 | 更新界面状态 |
| 写请求超时后列表确认目标状态 | 确认成功 | 不重放写请求 |
| 卸载后列表确认目标消失 | 确认成功 | 更新界面并移除目标 |
| 写请求后无法确认目标状态 | 已提交结果未确认 | 刷新列表，确认前不得再次执行同一动作 |
| 提交前取消 | 未提交取消 | 不需要状态恢复 |
| 提交阶段取消 | 已提交结果未确认 | 先刷新套件列表 |
| 同一套件已有操作 | 重复提交冲突 | 等待当前操作完成 |

### 版本验证

| 环境标识 | 证据等级 | 结果 | 日期 | 证据路径 |
| --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `static` | 已核对能力范围、官方网页前端请求线索、合成请求和故障注入测试；本批未在真实 NAS 启动、停止或卸载套件 | 2026-07-31 | `docs/api/discovery/environments/INDEX.md` |

合成 Fixture 与源码测试只能证明客户端请求形态、预检顺序、互斥、回读和禁止重放策略，
不能把当前环境提升为 `behavior-verified`。

### 能力探测与降级

- 启停必须同时发现 `SYNO.Core.Package` 和 `SYNO.Core.Package.Control`；卸载必须同时发现
  `SYNO.Core.Package` 和 `SYNO.Core.Package.Uninstallation`，缺少任一所需能力时关闭对应入口。
- 列表字段缺失、目标不存在或无法判断 `canStart` / `canStop` / `canUninstall` 时禁止写入，
  不猜测套件状态或卸载许可。
- Android 普通套件快照在 `startable`、`available_operation` 或卸载类型缺失时默认关闭对应
  操作；读取失败将 `packagesAvailable` 标记为不可用，不把失败折叠成可信空列表。
- `feasibility_check` 是提交前的必要条件，但不替代目标写方法自身的权限判断。
- macOS 按用户明确授权提供测试入口，以实际接口版本、权限、输入、确认、防重复和结果核查判断可用性，不仅因未实测固定关闭。新 DSM build 的真实行为仍待验证；其他平台以其最新授权和实施状态为准。
- 套件控制失败只降级套件管理，不阻断文件、照片、消息或其他 NAS 设置读取。
- 当前项目未找到覆盖 DSM 套件启动、停止与卸载的统一公开 API。

### 安全与副作用

- 停止套件会中断该套件提供的功能和连接；启动也可能触发后台任务和资源占用；卸载还
  可能移除套件设置或数据。界面必须在提交前说明影响并要求确认。
- 请求只使用列表返回的稳定 ID 和 `dsm_apps`，不接受任意用户输入的 API 参数。
- 请求 Fixture 不记录真实套件、NAS 地址、账号、Cookie、SID、SynoToken 或响应。
- 未确认结果不得自动重试，也不得建议用户立即再次执行套件操作。
- 此历史切片未实现安装和升级；2026-10-03 macOS 新流程见独立套件中心记录，其他平台未在迁移。

### 未验证事项

- 不同 DSM build、管理员/普通账号、依赖套件、套件忙碌、启动失败、停止超时和
  QuickConnect 中继下的真实行为尚未验收。
- 部分套件可能返回过渡状态或需要超过十秒才能稳定，当前没有权威的统一任务 ID。
- 系统套件、依赖链和正在处理存储或备份任务的套件可能有额外拒绝语义。
- 套件控制源码与合成结果不等于目标设备或真实DSM副作用已验收；平台状态统一见平台矩阵。
- 第 53 批新增的 Android 严格基线、固定版本、权限失败关闭、专项回读和持久反馈均只通过
  合成响应与自动化故障注入验证，真实 NAS 上的启动、停止、卸载和取消行为仍未验证。

### 可用操作对象与安装互斥

官方成功响应中 `additional.available_operation` 是对象，`upgrade` 是目录候选对象，
不应作为启停许可数组读取。macOS 对对象响应使用状态和 `startable` 判定启停，
`ctl_uninstall/install_type` 判定卸载；历史数组保留明确操作限制。安装/更新进入
[独立安装计划](dsm-packages.md#dsm-package-installation)，不用旧 controlPackage(.upgrade) 绕过预检。
安装、下载或未确认任务存在时，Repository 和模型都拒绝同时启停/卸载。其他平台
未修改，需同步对象形态及全局安装互斥；没有新的真实套件控制写入证据。

另将可行性检查固定为官方前端使用的 v1；`system_hidden` 与 `system` 一样不能由普通卸载入口删除。


### 套件图标读取

`SYNO.Core.Package.Thumb` 为内部API；只有能力明确覆盖v1才调用get，参数name=套件ID、ver=已安装版本、size=请求尺寸。返回二进制图像只保留内存，失败降级占位，不阻断套件清单；会话仅Cookie/请求头，不进入URL。当前调用可在`apple/Packages/DsmNetwork/Sources/DsmNasAdministrationRepository+Packages.swift`及`android/app/src/main/java/io/github/qwertyuiop1995/dsmnativeclient/data/DsmRepository.kt`的packageIcon核对。这里只确认现行源码形态，未增加真实版本验证。

<a id="dsm-package-installation"></a>
## DSM 套件中心内部 API


### 标识与当前范围

- 稳定标识：`dsm-package-installation`；组件：`dsm-core`；分类：`internal`；操作：`mixed`；风险：`high`。
- macOS 实现目录、搜索、分类、详情、安装、更新（含依赖队列）、手动上传、进度、取消下载、默认安装位置、通知、自动更新与套件来源管理。启停与卸载继续使用 [`dsm-package-control`](dsm-packages.md#dsm-package-control) 的确认、可行性检查和结果链路。
- 2026-10-02/03 的用户授权取消仅因未实测设置的入口禁用，但不取消运行时能力、服务器权限、签名、许可、确认、并发及结果检查。旧 `.upgrade` 直接控制接口继续拒绝；更新统一进入安装计划。
- 环境为 DSM 7.2.1-69057 Update 12，设备匿名归属待确认。目录、设置 get、可行性预检与队列为 `read-verified`；2026-10-03 按明确授权通过官方网页完成 MediaServer 2.2.1-3406 → 2.2.2-3412，最终“已启动”，此单目标官方更新为 `behavior-verified`。其他写流程和岚仓客户端真实提交仍未验证，不提升既有 lab-a 等级。
- 发现记录：[首次环境快照](../environments/INDEX.md#2026-10-02-nas-settings-web-audit)、[2026-10-03 单套件更新与设置类型更正](../environments/INDEX.md#2026-10-03-package-center-followup)。

### 能力、版本与传输

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

### 目录与操作解释

目录条目最小白名单：`id/dname/version/desc/changelog/source/maintainer`，分类数组和大小；下载地址、校验值与依赖元数据仅在当前 Repository 内存中用于预检和提交，不进入日志或持久化。描述、更新说明和许可仅呈现文字，不运行 HTML、脚本或加载嵌入资源。

`Package.list.additional.available_operation` 在实际响应中为对象，`upgrade` 值是完整候选对象。对象不等于启停许可列表：启停使用 `status/startable`，卸载使用 `install_type/ctl_uninstall`。保留历史字符串数组响应的显式操作限制。更新必须有 DSM 明确候选；不能只比较版本文本后自行升级或降级。

### 安装计划与依赖

1. 刷新目录及已安装版本，拒绝消失、无法识别或没有更新候选的目标。
2. `feasibility_check` 让 NAS 校验权限和业务可行性；成功可只有 `success:true`，复用无正文命令解析，拒绝不能被客户端改成继续。
3. `get_queue` 返回 `queue:[{pkg,beta,...}]`，并提供 `non_exist_pkgs/conflicted_pkgs/broken_pkgs/replaced_pkgs/paused_pkgs` 等数组。缺失依赖、冲突或畸形队列拒绝安装；额外依赖按服务端顺序纳入确认清单。暂停/替换目标进入风险摘要。
4. 每个目标 `check` 取得 `volume_list:[{mount_point,display,...}]`、`volume_path`、`is_occupied`。安装位置须来自当前返回；`system/system_hidden` 可以无普通卷；官方前端明确允许 volume_list 缺省或 null，客户端仅对这两种已确认安装类型接受该形状，普通套件仍必须有可选位置。
5. 用户确认套件、版本、依赖、位置与服务中断风险。提交前再次检查计划、候选元数据和已安装版本，变化即要求重新确认。
6. 只读准备阶段可取消；取消传播到当前读取，迟到成功/失败不恢复计划或弹出旧错误，Repository 互斥不被强行清除。确认之后的提交阶段只允许关闭窗口并在后台继续，不将关闭伪装成取消安装。
7. 全局安装队列与现有启停/卸载互斥。每个依赖核对成功后才提交下一项；中断时停止后续操作，不尝试回滚已经安装的依赖。

### 快速与分步安装

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

### 手动上传、自定义选项与清理

- 本地选择 `.spk` 正规文件；分块构建仅当前进程使用的 0600 临时 multipart 文件，固定上传文件名为 `package.spk`，不传本机目录。完成或失败删除本地暂存文件。
- `additional` 请求 `description/maintainer/distributor/startable/dsm_apps/status/install_reboot/install_type/install_on_cold_storage/break_pkgs/replace_pkgs`。
- 元数据按官方规则优先 `additional[key]`，其次根级字段。`install_pages` 支持数组或 URL 编码 JSON 文本。
- 原生表单支持说明、文本、密码、复选、单选、静态下拉；保存 `item.key` 对应的原生 String/Boolean，保留默认值、必填与长度约束。密码只存当次表单内存，不记录。
- 套件脚本校验、正则/专属 vtype、动态远程数据源和无法等价呈现的隐藏/禁用字段不能忽略，明确提示在 DSM 完成。此限制来自表单能力，不是缺少实测的发布开关。
- 许可协议必须展示并由用户同意；首次测试版协议需要在 DSM 完成，客户端只检查已有 `prerelease.agreed`，不代为接受。付费/激活步骤也留在 DSM。
- 仅取消本次下载或清理本次 `Download.check/upload` 返回的暂存目标。下载取消提交一次后继续查状态，不把接受取消误报为已取消。正式安装阶段不提供无法保证安全的取消。

### 设置与来源

Setting.get 返回 `update_channel:Boolean`、`enable_email/enable_dsm/enable_autoupdate/autoupdateall/autoupdateimportant:Boolean` 和 `volume_list`。`default_vol` 可缺省，特别是本次单卷响应；单卷不显示多余的位置选择器。自动更新单个套件状态来自 Package.list 的 `additional.autoupdate/autoupdate_important/silent_upgrade/status/limit_type`。`no_default_vol` 表示每次选择。

Setting.set 的 `update_channel` 仍为 `stable` 或 `beta`，不能照搬 get 的布尔类型。仅在完整基线复读一致后提交；命令使用 success 信封，不能要求一定返回 data。按套件设置时 `packages/packages_important` 为 JSON 数组**文本**，默认位置未修改不提交。保存后检查所有目标字段；结果未知须刷新，不自动重放。

Feed.add/set 的 `list` 为 JSON 文本 `{name,feed,orifeed?}`；delete 为 JSON 文本 `[feed]`。新增/编辑要显示“来源证书也将被信任”的具体风险，HTTP 地址另提示未加密连接；不接受带账号密码的 URL，不自动添加来源、不修改信任级别。删除前核对原条目，删除后确认该地址不再出现，不卸载套件。

### 结果、失败与恢复

- `finished/success` 不能代替结果确认：完整 Package.list 必须包含精确 ID、目标版本与终态，才显示成功。
- 网络异常、缺失任务编号或版本不符：`unverified`，仅允许查同一任务/当前版本，不重放 install/upgrade。
- 同版本手动重装在提交结果未知时不能仅靠旧版本相等确认成功。
- 权限/认证/API 不支持或明确 DSM 拒绝：失败，不继续队列；未知错误不显示原始 NAS 日志。
- 准备过程中发现不支持表单或签名错误：没有正式安装，只清理属于本次准备的暂存内容。
- macOS 返回值、任务与安装计划限当前连接内存，退出应用后请先在 DSM 检查已有任务。平台恢复状态见平台矩阵；不把摘要恢复等同于恢复旧提交或后台常驻。

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
