# File Station 所有者、POSIX 与 ACL

端点组 `file-station-file-permissions`，组件 file-station，internal / mixed / high。来源为[本轮环境](../environments/2026-10-02-file-station-live-observation.md)的 FileProperty.js、Share/PermissionDialog.js。DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559；均 static，无权限写验证。

## 请求及结果结构

POST、能力发现的 entry.cgi 与编码方式、绑定 DSM 会话。公开 List.getinfo 的 additional.real_path 提供真实文件系统路径映射；不可猜 volume 路径，不日志化。
- `SYNO.Core.ACL/get v1`：file_path、type="all"、include_noname_rules=true。data 含 is_acl、change_permission、acl_editable、is_inherited、acl 数组。
- ACL 行：owner_type/name/id/is_internal、permission_type、level（0 为显式）、permission 对象和 inherit 对象。permission 包含 read_data/write_data/exe_file/append_data/delete/delete_sub/read_attr/write_attr/read_ext_attr/write_ext_attr/read_perm/change_perm/take_ownership；inherit 为 child_files/child_folders/this_folder/all_descendants。继承项保留只读，不能混入待写规则。
- `Core.ACL/check_self_denied v1` 与 set 使用同一权限草稿，返回 is_denied；失败或缺字段必须关闭写入，不能按网页宽松逻辑继续。
- `Core.ACL/set v1`：file_path、change_acl、rules（仅显式）、inherited、acl_recur。所有者变化增加 change_acl_owner、acl_owner_type、acl_owner、acl_owner_recur。
- `SYNO.FileStation.Property.ACLOwner/get v1`：file 为真实路径；返回 name/type/value/hasPrivilege。
- POSIX `SYNO.FileStation.Property/set v1`：files 数组、dir_paths 数组、mode 为三位权限数字字符串；-1 表示保持，owner/group 可 null 保持；posix_owner_recur、posix_mode_recur。不得把三位十进制文本误作八进制整数编码。
- Property 返回 running/taskid；同 API status/stop v1 管理该任务。Core.ACL.set 返回 task_id；Core.ACL.status/stop v1 参数 task_id。FileBrowser.js 的 onPropertySendDone/onPropertyDone 使用 finished、result="fail"、errno、errItems 区分进行中与失败。客户端仅读取错误项数量，不保存真实路径或正文；不把根目录回读当作递归任务完成。

## 安全与降级

默认当前项目；先显示当前所有者、显式与继承规则，再显示差异、账号和应用范围。递归、移除访问、修改所有者分别确认。写前再次核对映射/目标/完整权限快照和授权；跨快照变化拒绝，不覆盖新设置。未知只回查，不重放权限写。无法证明实际授权时保留只读详情；不修改相邻文件，不提供权限绕过。

端点静态存在不等于 native 完成，按专项账本记录。五端：Apple 共享只做兼容增量，macOS 为当前实施范围，其他四端只记录后续计划。真实权限、继承、自锁阻止、递归部分失败均需专用数据验收。


## 本轮客户端适配

ACL 规则 effect 为 allow/deny，permission 的十三个键与 inherit 的四个键必须完整，不丢弃未知规则。只修改显式项，继承项保留只读。内部路径仅存在当前会话快照；保存前读取两次权限及路径映射，成员查询与自锁检查失败均拒绝提交。未知请求不重放，只允许读取任务状态及权限；递归任务返回错误时明确可能已部分应用。

POSIX 的 additional.perm.posix 是前端按百位/十位/个位拆分的三位权限数字（例如 755）；不是把 755 再转八进制。首轮普通账号只读 POSIX，管理员可编辑当前项目或确认递归。ACL 依据 change_permission 开放权限编辑，所有者修改首轮限管理员。共享根、回收站和挂载对象保持只读，避免扩大至共享配置。以上均 synthetic/static，实际保存及继承行为 PENDING_USER_VALIDATION。

源码：`DsmFileRepository+Permissions.swift`、`FilePermissionEditor.swift`；合成自动化：`FileStationParityTests`。请求样本为 `contracts/request-fixtures/file-station/set-acl` 与 `set-posix`，响应为 `contracts/fixtures-redacted/file-station/permissions`，结构描述为 `contracts/schemas/file-station-permissions.schema.json`。部分失败在关闭表单后仍通过统一核查入口保留，不以稍后根项匹配清除子树失败。

## 2026-10-02 读取故障修复

1.0.13 的权限读取要求 `additional.real_path`，但 `List.getinfo` 复用了未包含 `real_path` 的普通详情字段列表。NAS 按请求返回附加字段时，客户端在调用 ACL 之前即因缺少路径映射报错。新增请求回归已在旧实现复现此遗漏；修复只在权限读取中显式请求既有契约中的 `real_path`，不扩大普通详情读取、不猜测路径、不放宽缺字段校验。

共享根、挂载位置及回收站的已有写入范围限制同时用于生成只读快照，所有者和权限规则仍可读取；界面允许展开只读规则，修改控件保持禁用。字段名、版本、响应结构及公开接口保持原契约，证据等级仍为 synthetic/static。五端影响：共享 Apple 网络层为兼容修复，macOS 完成相应界面与回归；iPhone/iPad 没有新增入口，Android/Windows 无代码或契约变更。

`PENDING_USER_VALIDATION`：使用修复测试包，以原账号打开共享根和普通子目录的“所有者与权限”，确认所有者、显式和继承规则可显示；共享根只读，展开规则不会提交修改。若仍失败，仅反馈 DSM/File Station 版本、位置类别、操作步骤及脱敏提示，不提供真实路径、账号、会话或原始响应。本轮未连接真实 NAS，也未执行权限写入。


## 2026-10-04 iPhone / iPad 接入

移动 M2e 复用上述共享 Repository 与原契约，增加原生权限/所有者/群组表单、只读继承规则、具体后果确认及受保护的未知目标记录。写前保存失败不提交；确认草稿变化不沿用旧确认；相同配置下的不同账号也不共享恢复状态。写入结果使当前账号的目录与搜索缓存失效，刷新失败不能沿用旧权限再次编辑。内部映射路径、权限快照及凭据不持久保存；重启后不能恢复原任务证据时保持修改限制，允许读取当前权限。

五端影响：macOS 行为、Windows/Android 实现以及 API 字段/版本均不变；iPhone/iPad 分别有模拟器单元和实际界面证据。端点仍为 static/synthetic，未增加真实 NAS 权限写证据。具体结果和设备步骤见[移动 M2e 验证](../../../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-04-移动-m2e-所有者与权限)。

## 2026-10-12 Android 接入

Android A3j 沿用现有字段与版本，新增所有者、显式规则、继承只读详情、十三项动作与四项应用范围，以及 POSIX 所有者/群组和三组读写执行权限。界面分别显示修改前后、操作账号与当前项/子项范围，使用具体风险确认，不新增仪式式勾选。

授权摘要在内存中保留明确 File Station 授权和真实管理员角色。`Core.ACL` 仅归入文件模块，其他 Core 接口仍由管理模块限制；最小文件会话降级不会授予权限修改。管理员资格变化使旧表单和确认失效。写前两次刷新授权及完整目标快照，新增成员查询与自锁检查失败不提交；读写均保留原逻辑路径，不猜内部卷路径。

独立加密版本键保存原账号/目标、完整业务结果的不可逆摘要及原任务回执；不保存权限表、内部路径或可重放请求。新规则回读允许 NAS 补上成员编号，已有成员编号和完整继承规则必须保持；重复规则按数量比较。递归任务必须有明确回执和完成证据，子项错误只读取数量并持久保留部分失败，不能以根项相符清除。关闭表单和重启后仅回读，不重发 `set`。未结束操作同时互斥祖先/子目录的权限修改，兄弟目录仍可独立操作；相关项目可直接打开原修改并刷新。写后清理当前账号文件/搜索缓存。

五端 API 契约、依赖及系统权限不变，仅 Android 实现和对应合成测试/文档更新；Apple 三端与 Windows 源码只读。证据等级仍为 static/synthetic，实际权限及继承行为为 `PENDING_USER_VALIDATION`，设备步骤与结果按 [Android A3j 账本](../../../archive/2026-h2/ANDROID_REWRITE_IMPLEMENTATION_HISTORY_ZH.md#a3j-所有者与访问权限账本)执行。

2026-10-12 Android A3k 对照已有文件契约补充精确空 `mount_point_type` 的普通目录语义：空字符串可继续原权限检查，缺字段、特殊挂载、共享根与回收站仍不授予编辑。与 ISO 未结束操作的相交检查在取得路径锁后执行，防止交错提交；新增聚焦回归，不提高真实 NAS 验证等级。

## 2026-10-14 五端写入策略更正

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。 Android已删除A10误加的限制；实际权限和恢复保护保留，见[功能参考](../../reference/files.md#写入可用性与版本策略五端统一)。真实环境证据等级不变。
