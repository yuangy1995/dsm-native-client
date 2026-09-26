# NAS 设置回归只读观察（2026-09-26）

## 环境与范围

本记录从环境模板建立。当前浏览器会话尚未与 `lab-a` 基线重新核对，不创建猜测的设备别名，
不修改已有版本验证等级。

| 项目 | 观察 |
| --- | --- |
| 日期 | 2026-09-26 |
| DSM 版本 / build / Update | 未完整核实；官方已加载静态资源版本为 `69057-s12`，不能代替系统版本读取 |
| 相关套件 | 本次只涉及 DSM Core；未读取或验证套件版本 |
| 连接类别 | Chrome 中现有 QuickConnect 直连页面 |
| 权限类别 | 可打开官方系统管理页面；未独立核实账号角色 |
| 证书类别 | 未独立核实 |
| 设备归属 | 待核实，不据历史会话认定同一设备 |

## 证据来源

通过已登录官方控制面板导航，观察页面自动发出的只读请求。
浏览器最初阻止粘贴，用户手动允许后才启用临时观察器。观察器仅保留字段名、类型与
启停枚举；不保存原始响应、凭据、账号、主机、路径、脚本正文或用户数据，不导出 HAR。
没有点击应用、运行、删除、创建确认等 NAS 写操作按钮。

| 端点 | 成功读取结构 | 范围 |
| --- | --- | --- |
| `SYNO.Core.User.list` v1 | `users[]` 中 `description/email/name` 为文本；`expired` 使用 `normal/now`；官方列表未带 `can_edit/can_delete` | 当前浏览器的读取观察；账号写入未验证 |
| `SYNO.Core.Hardware.PowerSchedule.load` v1 | `poweron_tasks[]/poweroff_tasks[]`，每项有布尔 `enabled`、数字 `hour/min`、文本 `weekdays` | 来自 `SYNO.Entry.Request` 的逐项响应；保存未验证 |
| `SYNO.Core.CurrentConnection.list` | 已观察成功请求及 `items/systime/total` 容器 | 单项 PID 类型尚未在该会话输出核对，不冒充实机字段验证 |

官方硬件页面导航过程中还观察到 `Led.Brightness.update` 自动请求；未手动调用该接口，
没有取得它的副作用证据，不能把所有网页后台请求一概宣称为只读。

## 补充静态线索

原始开源观察项目发布的 Schema 用于补齐兼容候选，不属于 Synology 官方契约，
也不证明当前 NAS 的系统活动接口已验证：

- [CurrentConnection 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.CurrentConnection-list.json)：`pid` 为整数。
- [Process 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.System.Process-list.json)：`process[]`、`pid/command/status`。
- [ProcessGroup 原始 Schema](https://github.mikespub.net/synology/tools/schemas/SYNO.Core.System.ProcessGroup-list.json)：`slices[]`、`unit_name/name/process[]`。

只取进程 command 的首个非空白片段再去掉目录，不向模型或界面复制命令参数。
这些候选必须继续接受运行时能力发现，并由用户在当前 NAS 上验证。

## 限制与后续

Mac 再次锁屏后，工具无法继续浏览器操作：尚未完成当前 DSM 版本、任务详情、系统活动
和星期编码的现场核对。临时观察器只在当前网页内存中存在，不上传数据；解锁后需移除，
或刷新该 DSM 标签页恢复官方原始运行状态。没有在本机保存真实响应、截图或 HAR 文件。

新建脚本任务改为使用项目已有默认值生成本地空白草稿；执行账号预填当前登录账号，
保存前仍要求名称、脚本与时间有效，并执行现有确认、重复提交保护和结果回读。
这不声称 NAS 返回了完整新建模板。已有任务编辑仍使用严格读取，不用新建默认值覆盖
已有任务；其实际详情待用户验证。

## 实现与集成复核

- 账号兼容已观察的状态枚举；资料完整且没有明确拒绝时允许打开编辑。删除许可、自身账号
  与保留账号保护不变；没有通过缺失字段猜测删除权限。
- 当前连接只对 PID 兼容整数表示，小数仍拒绝；断开前的身份复查和当前连接保护不变。
- 系统活动只保留进程名，不保存命令目录与参数；数量仍限制为 500，服务组失败独立降级。
- 电源计划合并读取开关机两个数组；未知星期编码保留未知，不编造重复规则。
- 新建任务只生成本地草稿；已有任务读取、保存前重新核对、重复提交保护和写后读取不变。
- 回收站恢复取消 `verified` 证据标记门禁，改按 List、CopyMove、CheckPermission 的实际能力
  开放；原有确认、冲突拒绝和结果复查保留。没有把兼容矩阵的验证等级改成实测通过。
- macOS 登录组装已开启容器网络创建和照片删除，并使用实际聊天适配器；没有再添加
  重复开关。电源计划保存、进程控制尚无实现，不生成不能完成操作的入口。
- 独立只读差异复核覆盖了上述权限、身份、防重复及隐私边界。未修改 Android、Windows
  实现；Apple 共享层影响与未验证平台已记录在平台矩阵。

## 可复现的本机验证

以下使用合成数据，不等同真实 NAS 写入验收：

```sh
swift test --package-path apple --jobs 4 --filter 'DsmNasAdministrationRepositoryTests|NasAdministrationModelTests|DsmFileRepositoryTests'
LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.testNAS网络与账号弹窗双语主题不保存配置|WorkspacePresentationTests.testNAS各二级页面双语主题绘制不触发控制操作' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-settings-ui-20260926
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

结果：418 项聚焦测试通过；2 项双语与浅深色合成界面检查通过；本地化资源、硬编码扫描、
3 组 fixture、22 项接口文档引用、文档完整性和差异空白检查通过。较早一轮混合执行的
55 项界面测试因未启用隔离环境跳过，不计入上述通过数量。已在隔离环境中重新运行与
本轮相关的 2 项界面检查，并查看系统活动正常内容和当前连接空状态的合成图。

独立测试包按既有流程构建：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/nas-settings-fix-20260926" bash apple/Apps/DsmMac/package.sh
```

结果：macOS Release arm64 构建成功，版本 `1.0.9 (19)`；主程序和嵌套组件签名校验、
临时权限边界、Sparkle 实际动态加载、DMG 校验均通过。交付目录为
`apple/Apps/DsmMac/dist/nas-settings-fix-20260926`，包含 `LanStash Test.app` 和
`LanStash-1.0.9-arm64.dmg`。未安装、未启动测试 App，没有提交或推送。中间构建、
合成截图和临时日志在记录结果后清理，只保留交付包及正式测试源码。

## PENDING_USER_VALIDATION

前提：独立 macOS 测试包连接当前 NAS，账号具有对应功能权限。测试包采用项目既有临时
签名隔离流程，不含 File Provider 挂载扩展，不能用来验收本地磁盘挂载。

| 操作 | 预期 | 未验证影响 |
| --- | --- | --- |
| 进入电源计划并与 DSM 页面比较 | 开机、关机、时间与启停状态可见 | 星期编码未核对，重复规则可能显示未知；保存无实现 |
| 进入账号与权限并打开编辑后取消 | 列表与当前资料可见，明确禁止的操作仍禁用 | 真实保存与删除未执行 |
| 进入计划任务并点击新建后取消 | 打开空白草稿，执行账号预填 | 真实创建、已有任务详情及保存后回读待验证 |
| 进入系统活动并刷新、搜索 | 有进程时显示列表，缺权限显示可恢复错误 | 当前 NAS 的 process/slices 容器尚无读取验证 |
| 进入当前连接 | 列表可见或合法空状态，不误报区域时间错误 | 当前会话的单项 PID 及断开行为未验证 |
| 对专用测试文件打开回收站恢复确认 | 能进入确认；取消不发送移动，确认后核对原位置 | 真正恢复与冲突处理需用户使用可丢弃文件验证 |

失败回传只需：页面名称、操作步骤、脱敏错误文字、DSM 完整版本及所用测试包；不要发送
账号、主机、路径、任务脚本、连接身份、会话凭据或原始响应。浏览器解锁后还需刷新 DSM
标签页，移除仅存于该页内存的临时观察器。
