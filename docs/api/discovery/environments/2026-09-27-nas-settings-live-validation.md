# NAS 设置与客户端权限摘要实测（2026-09-27）

## 环境快照

沿用 [前一日观察](2026-09-26-nas-settings-read-observation.md) 的现有浏览器会话继续核对。
完整版本已由官方信息中心及更新页面确认；仍不凭版本相同认定它就是历史 `lab-a`，
设备匿名归属待核实，不改写历史环境的验证等级。

| 字段 | 值 |
| --- | --- |
| 发现日期 | 2026-09-27（与前一日连续工作） |
| DSM 版本 | 7.2.1 |
| DSM build / Update | 69057 / 12 |
| 浏览器连接类别 | 现有 QuickConnect 直连 |
| 客户端连接类别 | 已保存的局域网连接 |
| 证书类别、设备架构 | 未独立核实 |
| 权限类别 | 官方页面可访问系统管理；修复包已恢复管理员菜单与读取 |
| 相关套件 | 本轮只验证 DSM Core；不将套件版本或写操作标为已验证 |

## 真实只读结果

| 接口/页面 | 证据 | 结论 |
| --- | --- | --- |
| CurrentConnection.list | 已观察成功响应，单项 `pid` 为数字，其他身份字段为文本，`is_current_connected/can_be_kicked` 为布尔值 | 上轮整数 PID 适配得到当前响应支持；未执行断开 |
| TaskScheduler.get v4 | 从官方界面打开已有脚本任务，成功取得 `schedule/extra`，开关为布尔值，时间/重复参数为整数，`monthly_week` 为数组，`week_day` 为文本 | 当前已有脚本任务结构与严格读取匹配；打开后取消，未保存/执行 |
| Hardware.PowerSchedule.load v1 | `poweron_tasks/poweroff_tasks` 数组、`hour/min` 整数、`enabled` 布尔值；重复编码包含 `0,1,2,3,4,5,6` 与 `6` | 与官方“每天”“周六”对应；补充该容器的数字星期解析，旧 `days` 数字数组仍不猜测 |
| System.Process.list v1 | 成功返回 `process[]`；单项有 `command/status` 文本、`pid/cpu/mem/mem_shared` 数字 | 上轮 process/command 兼容得到当前响应支持；界面只保留无目录、无参数的进程名 |
| System.ProcessGroup.list v1 | 成功返回 `slices[]`；每项有 `unit_name/name` 文本和 `process[]` | 上轮服务组兼容得到当前响应支持 |
| 独立测试 App | 已启动上一轮生成的包，并核对运行程序路径；恢复会话显示已连接，但刷新后仍提示没有可用 NAS 应用 | 复现客户端菜单缺失；不能据此断言账号没有权限 |

数字星期的其他单日、工作日和非法编码使用合成测试覆盖，不把未配置的计划说成真实
NAS 验证。打开官方新增电源计划仅查看星期选项，随后取消，没有提交。

## 权限摘要诊断范围

只比较当前 App 自身会话对已知 `get_user_service` 只读方法的 GET/POST 认证结果，
使用已有请求构造和证书检查；不复制浏览器凭据，不读取钥匙串内容到外部脚本。
临时诊断只输出固定应用权限键的布尔值、权限数量、登录/管理员布尔值和错误类别。
完成后必须移除诊断源码、临时输出与中间包，保留正式修复、合成测试和验证结论。

当前 App 已保存会话的实际结果：GET 和 POST 都返回成功包络，但 `isLogined=false`、
`is_admin=false`、权限表数量为 0，固定应用键全部缺失。因此没有把请求改成 POST，也
没有把空权限表改成全允许。该证据不能单独证明会话整体过期：还需原有文件接口核实，
并与重新登录后的行为区分。

已修复 `DsmDesktopAppPrivileges` 对显式 `isLogined=false` 的处理：将其判为无效摘要，
触发原有文件会话核实与可恢复提示；恢复登录时不再把这一响应直接当作有效会话。
`isLogined=true` 的合法空权限表仍保留拒绝语义。没有修改登录 session 名、鉴权格式、
持久化结构、公开方法签名，也没有提升普通账号或绕过明确权限拒绝。

补充静态参考：[synocli 原始实现](https://github.com/looran/synocli/blob/main/synocli.py)
同样使用 FileStation 登录会话读取桌面摘要，但其浏览器式 Cookie 流程不能替代本轮
App 认证实测；没有照搬其把令牌放入 URL 的做法。

## 本机回归

```sh
swift test --package-path apple --jobs 4 --filter 'DsmNasAdministrationRepositoryTests.test电源计划'
swift test --package-path apple --jobs 4 --filter 'DsmDesktopAppPrivilegesTests|WorkspaceModuleAccessTests|DsmNasAdministrationRepositoryTests|NasAdministrationModelTests|DsmFileRepositoryTests|LoginViewModelTests'
```

结果分别为 5 项及 441 项通过、0 失败。后一条命令没有匹配到名为 LoginViewModelTests
的独立测试类，不把它计作登录模型测试覆盖；菜单权限模型包含 14 项实际执行的测试。
新增用例验证数字星期、非法/重复编码、未登录成功包络拒绝及已登录空授权保留。

诊断包最初尝试 Debug 打包，构建后未通过既有脚本的 Chat 符号检查，未用于实测；随后
按项目既有 Release 流程构建成功，签名、权限边界、Sparkle 实际加载与 DMG 校验通过，
仅该 Release 诊断包用于上述 App 会话核对。临时诊断源码已移除。

## 调试资料清理及更正

复验发现旧浏览器观察器对任务 `action` 字段保留过宽，可能包含任务说明；本轮已清空
旧缓存与控制台，改成仅输出字段类型，最后取消未保存表单并刷新 DSM 标签页，移除所有
临时观察器。前一日“仅保留字段名、类型与枚举”的表述不适用于该旧观察器的 `action`。
不在仓库记录任务说明或脚本，不导出原始响应、HAR、截图、主机、账号或任何凭据。

## 当前状态

修复权限摘要判断后，Release 测试包恢复会话时成功显示文件及 NAS 设置菜单，并读到
文件列表。结合既有恢复流程：显式未登录摘要现在会进入文件会话核实，认证失效后可用
已保存密码重新连接；没有改变凭据或把空权限强制改为允许。未记录重新连接的原始响应，
因此不单凭界面推断具体认证请求时序。

| 客户端真实操作 | 结果与边界 |
| --- | --- |
| 电源计划 | 显示四条真实计划；每天/星期六、时间和停用状态正确，无原区域时间错误 |
| 计划任务 | 列表显示七项；新建草稿可打开，已有脚本任务“修改”可打开且保存按钮可用；均取消，未保存或执行 |
| 账号与权限 | 账号/群组列表成功；已有账号修改表单及保存按钮可用；取消且未改凭据/权限 |
| 系统活动 | NAS 报告超过 500 个进程，按原有上限展示并提示；服务组正常；搜索无匹配状态正常、清除搜索可恢复 |
| 当前连接 | 成功显示连接列表；未触发断开 |

实测反馈“退出无反应”另定位到本地测试包的共享容器检查：测试包不包含挂载扩展，
退出前仍调用 `protectWritebackForSessionRemoval`，但失败提示此前只写入已隐藏的
登录页。首次仅捕获 `sharedContainerUnavailable` 的修复在实测中仍被阻止；新增工作区
通知已能显示该失败。源码显示系统也可能返回无法访问的共享路径，目录或锁操作会抛出
其他错误，不能假定缺少共享权限必然等于空 URL；未记录具体系统错误码，不将推测写成
实际异常类型。最终改为仅在独立测试包且挂载不可用时，事先跳过不适用的扩展目录检查。
正式版与可用挂载环境仍执行原有检查，待上传修改不可绕过。阻止退出时同步当前工作区
提示和通知。使用已有双语
`desktopDrive.writeback.pending`，没有更改存储、应用标识、正式版权限或凭据策略。

`swift test --package-path apple --jobs 4 --filter ConnectionFlowTests`：24 项通过、0 失败，
包含退出后保留应用密码、清理共享会话，以及待上传修改阻止退出且当前工作区显示错误。
最终回归命令及结果：

```sh
swift test --package-path apple --jobs 4 --filter 'DsmDesktopAppPrivilegesTests|WorkspaceModuleAccessTests|DsmNasAdministrationRepositoryTests|NasAdministrationModelTests|DsmFileRepositoryTests|ConnectionFlowTests'
python3 tools/localization/check_localization.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
git diff --check
```

465 项测试通过、0 失败；双语资源/占位符/硬编码扫描通过；3 组 fixture 与 22 项接口文档
引用通过；文档和差异检查通过。纯诊断用异常描述改用非界面英文，避免硬编码扫描误判，
界面错误仍通过原本地化映射展示。

调整测试包退出检查后重新运行 `ConnectionFlowTests`：24 项仍通过、0 失败；本地化、
文档和差异检查再次通过。正式版待上传保护用例保留，没有降低既有断言。

最终独立测试包使用项目既有流程（从仓库根目录）：

```sh
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release \
LANSTASH_TARGET_ARCH=native LANSTASH_SIGNING_IDENTITY=- LANSTASH_RUN_AFTER_PACKAGE=0 \
LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/nas-validated-20260927" \
LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/nas-validated-20260927" \
bash apple/Apps/DsmMac/package.sh
```

最终 Release 包 1.0.9 (19)、arm64 构建成功；Chat 构建产物、临时包权限、Sparkle 实际
加载、签名及 DMG 校验通过。用户处理系统保存信息访问确认后，Agent 在该包点击退出；
随后电脑控制工具报 `Sky Computer Use native pipe closed before response`，重连和重置
工具仍失败，App 进程保持运行。因此没有把该工具错误记为 App 崩溃或退出通过。
用户随后明确回传：“已回登录页，重新连接后菜单正常”。退出与重新连接结果来自用户
实际操作确认；前述五个页面和表单读取来自 Agent 实机点击，两者分别记录。

交付路径：`apple/Apps/DsmMac/dist/nas-validated-20260927/LanStash Test.app` 与同目录
`LanStash-1.0.9-arm64.dmg`。独立测试包不含本地磁盘挂载扩展，未覆盖已安装正式版。
临时诊断源码、诊断输出、浏览器观察器、失败/中间包及构建缓存均已清理；保留最终包、
必要脱敏记录及正式回归测试。

真实 NAS 配置写入仍未执行：没有专用测试任务、文件或账号的明确范围，不通过修改现有
业务任务、账号或断开连接来代替测试。这些写入验收保持 `PENDING_USER_VALIDATION`：
用户可使用专用任务/可恢复测试文件点击验证，预期保存后重新读取一致；失败回传脱敏提示、
操作类型和 DSM 版本即可，不回传脚本、账号、路径或凭据。
