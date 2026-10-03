<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-10-03 -->

# Android 原生客户端长期计划

## Chat 契约影响（2026-10-03）

本轮只更新 macOS 与共享 Apple 的五组日常聊天能力，Android 未修改实现。后续 Android 切片需核实 Post.list 定位分页、投票 choices/options 对象编码及 props.vote 解析，并单独决定搜索、编辑、线程、投票参与、媒体和阅读同步范围；不得把 macOS 构建或官方网页写入结果当成 Android 完成。新请求样例、失败语义和版本证据见[消息交互契约](../api/discovery/endpoints/chat-message-interaction.md)，待办保持实现阶段，不伪装成仅缺真机。


## NAS 设置与套件中心契约影响（2026-10-03）

本轮只实现 macOS，Android 未改代码、未排入当前工作。后续若获授权接入，需同步 enable_zram、提示音 support_*、风扇模式位、防火墙通知 enable_port_check、200 条电源计划完整保存以及 available_operation 对象的含义。安装/更新不能只接一个按钮：须一起实现依赖确认、目标卷、签名/许可、队列互斥、任务查询、未知结果不重放及最终版本核对；手动上传使用 SAF URI 与受控临时文件，长任务遵循 Android 前台/后台限制。自动更新和来源信任须保留具体风险确认。本轮共享样本与静态结构不是 Android 或 NAS 真实验收，资料见 [NAS 设置账本](NAS_SETTINGS_WEB_AUDIT_20261002_ZH.md)。

同日反馈修复补充：套件预检成功可以没有 data；Setting.get 的 update_channel 为 Boolean，set 仍为 stable/beta，单卷 default_vol 可缺省。macOS 已修正并同步应用实际加载的双语资源；其他平台实现范围保持上述取舍。官方单个 MediaServer 更新已成功，但不能代替任何目标客户端的真实提交验收。详见[反馈修复账本](PACKAGE_CENTER_FIX_20261003_ZH.md)。 后续确认 system/system_hidden 可以缺省普通存储列表；安装准备取消须丢弃迟到结果，已提交安装只关闭窗口后台继续。照片过期操作反馈修复仅涉及 macOS 模型，不改变五端照片读取/写入契约。见[二次反馈账本](PHOTOS_PACKAGE_FOLLOWUP_20261003_ZH.md)。

## File Station 后续适配影响

macOS 的高级条件搜索、分享日期及密码 keep/set/remove、包内分页/所选解压、指定后台任务清理已有公开请求样本；全文、具名分享/收集、权限、ISO、VFS 和设置另有私有端点、合成请求与只读证据。后续 Android 须保留实际版本能力、权限、确认和未知结果只读核查，开关策略遵循目标平台当次授权，不能从 macOS 合成结果推定 NAS 兼容。本轮不改 Android 实现。目录上传另按 SAF 与前台/后台限制设计；macOS 已接入正式云授权回调、远程 URI 浏览下载、域/LDAP 挂载名单与分享页换图；接口仍只有静态/合成及已注明的只读证据，云服务采用系统浏览器和一次性本机回调，成功回调与 NAS 写入待用户验证。范围见 [File Station 账本](../../apple/Apps/DsmMac/README.md)。


## Office 本机编辑的后续影响

macOS 新增 Office 预览和本机应用编辑自动回传，只扩展 macOS 展示/会话层，没有新增 NAS API 契约。Android 本轮未实现同类功能，不能由 macOS 测试或页面推定已对齐。若后续进入 Android 范围，应按系统文件选择器、内容 URI 授权、外部编辑器返回及前台/后台限制单独设计，保持内容不变不上传、原目标绑定、冲突暂停及未知结果不重放；不能照搬 macOS 本机路径轮询。本轮仅同步影响说明，不新增 Android 开发或真机验收任务，证据见 [Office 账本](../../apple/Apps/DsmMac/README.md)。

## 用途与事实来源

本计划记录 Android 后续源码拆分、验证和发布条件，不记录动态完成率、CI 标识或历史测试
数量。当前状态见[开发进度](../progress/STATUS.md)，跨端范围见[平台功能矩阵](../progress/PLATFORM_MATRIX.md)，
已结束的对齐记录见[历史归档](../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)。

源码、契约、脱敏 fixture、自动化与可重现命令是事实来源；真实 NAS、签名或真机未执行时
必须明确标记 `PENDING_USER_VALIDATION`，不得把模拟器或静态阅读写成通过。

## 不变量

- 保持 `DsmRepository` 为兼容门面，不能改变公开签名、DSM API 名称/版本/参数、错误语义
  或 `MutationResult` 映射。
- 保持持久化键、状态顺序、StateFlow 身份、导航、WorkManager 唯一任务名以及取消、重试、
  退出和恢复语义。
- 不新增 Gradle 模块、第三方依赖、最低系统版本、包名、Bundle ID、签名配置或数据格式。
- 写操作必须保留确认、权限检查、重复提交保护和最终状态校验；未验证内部写默认关闭。
- 用户可见文案只通过英语和简体中文资源提供，不能加入 Kotlin/Compose 硬编码显示文案。

## 当前代码边界

```text
AppViewModel.kt                 Compose 兼容入口与跨领域协调
ChatFeatureModel.kt             Chat 读取、轮询、实时连接与资料代次所有权
NasAdministrationFeatureModel.kt NAS 设置读取 Job、代次与同步边界所有权
data/DsmRepository.kt           兼容门面与共享网络能力
data/downloads/                 已拆出的 Download Station Repository
data/container/                 已拆出的 Container Repository
data/PhotoRepository.kt         File Station 照片文件／备份兼容能力
data/SynologyPhotos*.kt         正式 Synology Photos Repository 与门面委托
photos/SynologyPhotosSession.kt 照片模型、会话与父作用域的唯一所有者
PhotoBackup*.kt                 照片备份与唯一后台任务所有权
*ViewModelState.kt              按领域状态与纯策略函数
ui/                             Compose 页面与组件
```

`AppViewModel` 和 `DsmRepository` 已是结构债务热点。任何拆分都应缩小其行数，不得让
既有巨型文件增长；新生产 Kotlin 文件超过行数上限时必须在质量基线中声明清晰理由。

`ChatFeatureModel` 只拥有 Chat 的读取、轮询、实时连接、本地已读叠加和资料代次；Chat 写操作仍在
`AppViewModel` 的既有确认、权限、重复提交和结果复查边界中。`NasAdministrationFeatureModel` 只拥有
NAS 设置读取 Job、请求代次及其与设置刷新共用的同步边界；其他 NAS 管理写操作仍通过兼容门面执行。
二者均直接发布既有 `WorkspaceState`，不复制 UI 状态、公开方法、持久化键或 WorkManager 名称。

## 质量基线

[Android 质量基线](../quality/ANDROID_QUALITY_BASELINE_ZH.md) 由
`tools/codex/android_quality_baseline.json` 生成，记录：

- 每个写调用点的调用文件、所属函数、`Result` 方法、开放状态、适用场景和测试证据；
- 页面五态、点击目标与显式时间动效的机器数据；
- 既有大文件上限和新增超大文件例外；
- 对新增或移动写入口的人工审查要求，而不是整文件 SHA-256 比较。

修改相关代码前后均运行：

```bash
python3 tools/codex/generate_android_quality_baseline.py --check
python3 tools/codex/check_android_write_test_matrix.py
python3 tools/codex/check_android_page_state_matrix.py
python3 tools/codex/check_android_touch_targets.py
python3 tools/codex/check_android_motion_audit.py
python3 tools/codex/check_android_structure_debt.py
python3 tools/localization/check_localization.py
```

## 源码拆分顺序

### 1. DsmRepository 共享底座

先抽出以下无 UI 依赖的内部组件，并由门面委托：

1. response decoder；
2. request builder；
3. capability resolver；
4. mutation verifier。

组件只接受现有网络、会话和模型依赖。不得复制请求、增加 fallback、提高 API 版本或改变
参数编码。每次移动后运行受影响 fixture、契约和 Repository 聚焦测试。

### 2. 领域 Repository

在共享底座稳定后，按以下顺序从门面提取实现：

1. VMM；
2. NAS Administration；
3. Chat；
4. File Station。

正式 Photos 路由已按[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)使用 `SynologyPhotosRepository`；`PhotoRepository` 只保留文件／备份兼容范围，不回退旧扫描库。复用既有 `DownloadStationRepository` 和 `ContainerRepository`，不再为
同一能力建立平行 Repository。门面仅保留向后兼容的委托；每个领域均保持相同 API 名称、
版本、参数和 `MutationResult` 语义。

### 3. AppViewModel 任务所有权

已迁移 Transfer、Photo Backup、Chat 读取/实时会话和 NAS 设置读取等 Job、锁及序列号所有者明确的
路径。后续依次迁移：

1. Files；
2. Downloads；
3. Container；
4. VMM；
5. Chat 与 NAS Administration 中未迁移的高风险写操作，仅在既有安全契约可独立验证时拆分。

每个任务只保留一个 owner。迁移时必须证明 `onCleared`、取消、重试、进程恢复、迟到结果
拒绝、持久化和 WorkManager 名称均未改变。跨 NAS、后台、认证和危险写路径在平台构建或
实机验收前需要额外只读对抗复核。

### 4. Compose 机械拆分

在状态和事件边界稳定后，按“状态输入 / 事件输出”机械拆分 Chat、Files 和 Photos 大型
页面文件。拆分不改变布局、文案、动效、导航、可访问性或交互。

每个页面继续覆盖加载、空内容、筛选后为空、错误和正常内容。新增页面、弹窗、自定义点击
或时间动效必须先更新 JSON 基线与生成报告。

- [x] 每页覆盖加载、空内容、筛选后为空、错误和正常内容五种状态；

## 验证策略

| 范围 | 本机 | 托管 Runner | 用户验证 |
| --- | --- | --- | --- |
| 纯 Kotlin / Repository | 聚焦单测、fixture、契约与增量编译。 | 完整 JVM 与 Release/R8。 | 仅真实 DSM/套件行为。 |
| Compose | 静态质量门、聚焦页面策略测试。 | Debug、仪器 APK 与 lint。 | TalkBack、动态字体、触控、横竖屏与 OEM 行为。 |
| WorkManager / 传输 | 取消、唯一任务名、恢复策略和持久化测试。 | 构建与仪器包。 | Doze、低电量、重启、系统选择器与实际后台限制。 |
| 危险写 / 私有 API | fixture、能力门、结果映射与只读对抗复核。 | 完整契约和 Android 门禁。 | 专用 NAS 的权限、断线、重复提交和最终回读。 |

完整 Android JVM、Debug、Release/R8、仪器 APK 与 lint 默认由 GitHub 托管 Runner 执行。
用户已授权仅为验证创建并推送专用 `codex/` 分支；其中不能含凭据、本机设置、临时日志或
无关更改。完成验证后应整理当前功能分支的临时提交，不改写共享历史。

## 发布与真实环境

以下项目均是 `PENDING_USER_VALIDATION`，不是源码阻塞：

- Android 真机登录、认证恢复、证书确认与网络切换；
- 真实 DSM / 套件 build 的公开与内部 API 行为；
- WorkManager、后台传输、照片备份和跨 NAS 的系统行为；
- 高风险写操作的权限、确认、重复提交保护、断线、取消和最终回读；
- TalkBack、最大字体、显示缩放、折叠屏、平板和 OEM 触控。

未验证高风险入口必须保持关闭、只读或受能力开关保护。用户回传信息只包含环境类别、
步骤、预期/实际用户可见结果和脱敏失败语义，不能包含 SID、Cookie、地址、路径、账号、
真实文件名或原始响应。

## 交接要求

每个 Android 切片结束时记录：

1. 实际修改与单一文件边界；
2. 保持的契约、状态和任务所有权；
3. 实际运行命令及结果；
4. 未验证风险与 `PENDING_USER_VALIDATION` 条件；
5. 工作区状态、剩余步骤和不得触碰的并发修改。

## Photos 新增基线影响

macOS 上传、相册、分享、人物、目录、预览转换、任务恢复和设置管理的当前完整范围见[照片计划](NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)与[API 参考](../api/reference/photos.md)。Android 仍需逐项确认契约、权限、SAF/后台生命周期、逐阶段结果与用户恢复路径；本次文档整理不新增 Android 实现或真机待办。

## 已确认的界面标准

| 页面 | 必须实现的用户结果 | 保留的功能边界 |
| --- | --- | --- |
| 登录 | 已保存设备列表、独立连接表单、紧凑选项、全局连接遮罩、取消、验证码和失败恢复 | 现有认证/HTTPS/QuickConnect/保存偏好；不扩张证书信任策略 |
| 全局导航 | 默认首页/文件/照片/消息/设备；全部功能始终可达；0–5 个固定项；添加/隐藏/替换/拖动排序/保存/恢复默认 | 隐藏不禁用能力；导航必须通过原退出门；原页面链接仍可达 |
| 首页 | 最近访问、上传/备份/下载快捷操作、当前任务、常用位置 | 只使用已有本机记录与已获取数据，不用假数量补空白 |
| 文件 | 收藏位置/共享文件夹入口、紧凑目录浏览、独立搜索、排序筛选、文件操作面板、多选工具栏 | 上传/下载/预览/编辑/收藏/共享/归档/复制移动/回收站/远程位置及原写操作安全门 |
| 照片 | 照片优先布局、空间/时间线/文件夹、筛选和备份面板、查看与操作 | 现有缩略图/分页/查看器/备份/收藏/导出/共享/移动/删除/恢复路径 |
| 消息 | 会话列表、完整聊天页、输入区、上下文操作 | 未读/置顶/附件/群成员/提醒/定时/投票/发送与失败恢复 |
| 任务中心 | 区分手机传输与 NAS 下载；进行中/已结束筛选、详情、合理的操作入口 | 传输与 NAS 后台任务、Download Station、RSS/搜索/目的地/设置及安全确认 |
| 设备 | 状态摘要、存储/账户安全/网络连接/系统服务分组进入独立页面，套件入口 | NAS 十二分类、容器、VMM、应用设置全部可达；危险电源动作不放根页 |
| 详情与操作 | 顶栏仅显示必要名称；选择后展示关联操作；整页详情/底部面板；确认和结果可核对 | 不用展示层绕过权限、取消语义、重复提交保护或结果刷新 |

设计图的名称、图片、时间和数量是排版示例，不得作为运行数据。实现缺少数据时提供真实空状态。

导航偏好只保存本机模块标识与顺序，独立于 NAS/账号；可显示 0–5 项，隐藏不禁用能力，全部功能入口始终可达。保存前只改草稿，继续走原导航/退出保护。登录全局进度可取消，迟到结果不能保存旧连接。页面仍由原 ViewModel/Repository 提供业务，不建立第二套认证或数据层。

2026-10-03 容器契约补充：Registry.search 必须固定 v1（v2 实测 103）；下载任务 1202 为已观察的 Docker 失败路径，传输读取失败应保留原任务自动恢复。详见 `MACOS_CONTAINER_IMAGE_PULL_FIX_20261003_ZH.md` 和当日发现记录。本端未新增功能或私有写开放结论；Apple 共享层另做构建回归。
