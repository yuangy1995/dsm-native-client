# DSM 兼容矩阵

> 只记录版本和验证结论，不记录 NAS 地址、序列号、账号或真实共享名。
>
> 当前匿名发现基线：[`lab-a-dsm-7-2-1-69057-u12-20260729`](../api/discovery/environments/2026-07-29-lab-a-dsm-69057-u12.md)。
>
> 本文件记录维护者验证结论。用户自愿提交的结果单独显示在[社区兼容矩阵](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)，不会自动提升本文件或私有 API 契约的证据等级。

| DSM build | File Station | 证书类型 | 平台 | 登录 | 浏览 | 下载 | 上传 | 删除 | 恢复 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | File Station 1.4.1-1559 | 公共 CA | macOS | 官方网页会话已通过；岚仓待复验 | 官方网页可见；岚仓基础浏览已有反馈 | 未验证 | 未验证 | 未验证 | 未验证 | 2026-07-29 |

## 连接方式验证

| 连接方式 | 平台 | 地址发现 | 公开登录入口 | 完整登录 | 备注 |
| --- | --- | --- | --- | --- | --- |
| QuickConnect ID 直连 | macOS | 已通过 | 已通过 | 待用户复测 | 局域网与公网候选会在提交凭据前逐一探测；不记录 ID、解析地址和证书指纹 |
| QuickConnect 中继 | macOS | 已通过 | 已通过 | 待用户使用新密码复测 | 已完成真实环境的隧道建立、NAS 身份核对和 `SYNO.API.Info` 探测；`request_tunnel` 属于内部、可降级契约 |
| QuickConnect ID / 中继 | iPhone、iPad | 共享解析器已通过 | Release 模拟器构建、登录路由、冷启动自动登录测试和两种设备形态启动通过 | 待真机输入密码复测 | 保存资料保留原始 ID；可选密码存入 Keychain，自动登录和会话恢复均重新解析临时连接地址 |
| QuickConnect ID / 中继 | Android | 已通过真机探测 | 已通过真机 `SYNO.API.Info` 能力发现 | 待用户在修复版输入密码复测 | Release 启动崩溃已修复；可选密码由 Keystore 保护，探测不发送账号、密码或验证码 |
| QuickConnect ID / 中继 | Windows | 已通过真实服务探测 | .NET Release 测试已通过 `SYNO.API.Info` 能力发现 | 待 Windows 设备输入密码复测 | 可选密码由 Credential Locker 保护；登录和恢复均使用临时解析地址，完整 WinUI 构建须在 Windows 执行 |

## 文件操作验证

| 能力 | 使用契约 | macOS 状态 | 实机要求 |
| --- | --- | --- | --- |
| 同 NAS 复制/移动 | `SYNO.FileStation.CopyMove` 官方 API | 已实现 | 验证文件夹、冲突、取消和权限不足 |
| 文件与文件夹重命名 | `SYNO.FileStation.Rename` 官方 API | macOS 已实现；iOS/Android 待接入同一契约 | 验证同名冲突、无写入权限和特殊字符 |
| NAS 端压缩与解压缩 | `SYNO.FileStation.Compress` v3、`SYNO.FileStation.Extract` v2 官方 API | macOS 已实现；共享契约包含压缩包预读、密码检测和文件名编码，iOS/Android UI 待接入 | 验证 ZIP/7z 创建、简体中文旧版 ZIP、加密包密码循环、常见压缩格式、空间不足、同名覆盖和取消任务 |
| 跨 NAS 复制/移动 | Download + CreateFolder + Upload + 可选 Delete 官方 API | Apple 已实现 12 MiB 有界中转；Android 已实现文件复制/移动与文件夹复制，文件夹移动因递归删除竞态关闭 | 验证递归文件夹与背压；移动必须确认目标完成且源未变化后才删除，Android 需先补齐文件夹冻结或安全删除方案 |
| 下载断点续传 | Download 响应的 HTTP Range | 已实现、待验证 | 确认目标 DSM 返回 `206`，以及中断后字节一致 |
| 含糊扩展名识别 | Download 的 4 KiB Range 文件头 + 文件签名 | macOS 已实现；三端共享识别契约 | 验证 `.ts` 的 MPEG 传输流与 TypeScript；禁止按文件大小猜测 |
| 上传断点续传 | Upload multipart | 不支持字节续传 | 公开 API 未提供 offset/token；暂停后从头重新上传 |
| 子目录搜索 | `SYNO.FileStation.Search` 官方 API | 已实现 | 验证任务清理、中文、正则结果上限和无权限目录 |
| NAS 后台文件任务摘要 | `SYNO.FileStation.BackgroundTask.list` v3 官方 API | Apple 共享领域、Adapter、macOS 传输中心以及 Android Repository、Workspace 和传输中心已实现：App 传输/NAS 文件任务使用独立数据源，NAS 任务支持全部/进行中/已结束筛选、刷新、有限分页及加载/空/筛选空/错误/正常五态；每页 `limit=1...100`、按 `crtime desc` 排序，只请求 CopyMove/Delete/Extract/Compress 四类任务，敏感参数和路径在解码边界丢弃，`clear_finished` 保持关闭 | 尚未实机验证 API 发现、普通用户/管理员可见范围、分页变化、任务字段差异，以及“已结束”与实际成功/失败的判定来源 |
| 文件夹大小计算 | `SYNO.FileStation.DirSize` v2 官方 API 的 `start/status/stop` | Apple 共享仓库与 macOS 属性窗口已实现显式计算、重新计算和取消；窗口关闭后允许后台继续，关闭 File Station 模块或断连时取消；同路径防重复、有界轮询、`start` 禁止自动重放，仅能力缺失时回退客户端递归；路径和任务 ID 不进入领域结果、错误或持久化 | 尚未实机验证 API 发现、普通用户权限、大目录/远程挂载/加密目录、计数与逻辑字节语义、并发变化、超时、取消和任务丢失；官方 `stop` 表格疑似把 `taskid` 误写为 `tasked`，客户端按示例使用 `taskid` |
| 收藏夹 | `SYNO.FileStation.Favorite` 官方 API | 已实现 | 验证新增、移除和失效路径 |
| 分享链接管理 | `SYNO.FileStation.Sharing` 官方 API | 已实现 | 验证密码、有效期、批量路径、复制和取消分享 |
| 当前账号可见空间 | `SYNO.FileStation.List.list_share` 官方 API 的 `real_path` 与 `volume_status` | 已实现并按卷去重 | 验证多共享同卷、多卷、配额账号和字段缺失；结果不代表物理硬盘容量 |
| 当前账号共享访问 | `SYNO.FileStation.List.list_share` 官方 API 的 `adv_right` | macOS 只读页已实现；只解释可见条目的有效读写/删除能力，不展示物理路径，也不冒充管理员权限矩阵 | 验证管理员、普通账号、隐藏共享、只读共享、权限字段缺失、File Station 停用和 QuickConnect；不得记录真实共享名或响应 |
| 远程位置浏览 | `SYNO.FileStation.Info.get` 的 `support_virtual_protocol` + `SYNO.FileStation.VirtualFolder.list` v2 官方 API | 本批按能力返回的 `cifs`、`nfs`、`iso` 分协议只读枚举，以“协议 + 路径”去重；单次请求最多 500 条、每协议读取窗口最多 5,000 条，最终返回最多 5,000 个结果并明确提示截断（三协议最坏排序前处理 15,000 条）；不发送未公开的 `type=all`；ISO 只显示，不提供编辑或删除 | 尚未实机验证协议大小写、空能力、CIFS/SMB、NFS、ISO、失效位置、跨协议同路径、分页合并、普通用户权限和旧 DSM 行为 |
| 文件详情批量读取 | `SYNO.FileStation.List.getinfo` v2 官方 API | 本批按输入路径字符串去重并保持首次输入顺序，以每批最多 100 条分块，只请求功能所需最小字段；100 条是客户端保守上限，不是官方服务端上限 | 尚未实机验证大批量、部分路径不存在、无权限、返回乱序或缺项、QuickConnect 与不同 DSM build 的响应差异 |
| 远程位置创建、修改、删除 | `SYNO.FileStation.Mount` v1 内部实验性 API；公开 `getinfo` 只用于辅助回读 | macOS 已实现、默认由能力发现控制，尚未实机验收；ISO 不提供编辑或删除；`SYNO.FileStation.VFS.Connection` 与 `SYNO.Entry.Request` 继续关闭且未验证 | 必须记录 DSM build；验证管理员/普通账号权限、只读、错误密码、重复提交、修改回滚和断开后远端文件不受影响；不得把 `getinfo` 成功单独当作连接写操作已完成 |
| 基础照片空间与时间线 | `SYNO.FileStation.List`、`Thumb` 官方 API | macOS 文件夹扫描已获实机确认；时间线改为目录分页渐进扫描，待完整验收 | 分别验证 `/home/Photos`、`/photo` 权限，1 千/1 万/10 万项目、取消、弱网和深层目录 |

## 统一存储管理（新增组合功能）

> 该功能由群晖“存储管理器”和“存储空间分析器”两个官方组件的能力合并而成，是岚仓 Mac 端新增的统一入口，不应记录成群晖某个单一官方套件已有的功能。

| 能力 | 使用契约 | macOS 状态 | 实机要求 |
| --- | --- | --- | --- |
| 容量与健康总览 | `SYNO.Storage.CGI.Storage.load_info` 内部只读接口 | 已与空间分析合并到同一入口；卷、存储池和硬盘详情保留 | 验证多卷、多存储池、SSD、扩展柜、异常状态和字段缺失 |
| 文件占用报告 | `SYNO.FileStation.List`、`SYNO.FileStation.Search` 官方 API | 已实现当前账号可见共享、文件类型、所有者、大文件及时间维度；用户主动开始并可取消 | 验证大目录、无权限共享、加密未挂载共享、远程挂载、回收站和网络中断 |
| 重复内容校验 | `SYNO.FileStation.MD5` v2 官方 API | 已实现先按大小筛选、再校验内容；当前每次优先校验较大的 400 个候选文件，取消时停止后台任务 | 验证同名不同内容、不同名相同内容、零字节、大文件、接口缺失和任务取消 |
| Storage Analyzer 套件历史报告 | 套件内部接口尚未固化 | 当前不读取或修改已有报告配置；已确认官方套件首页包含卷用量、报告配置和历史报告入口 | 取得脱敏契约后验证版本、权限、报告类型、时间线与套件停用；未验证前不得猜测接口 |

存储分析兼容记录不得包含真实共享名、文件路径、文件名、所有者、校验值或报告配置名称。

## 记录要求

- 私有 API 的环境、端点和升级差异必须按 [`DSM 与套件私有 API 发现规范`](../api/discovery/README.md) 留档，并同步更新机器可读的 [`compatibility.json`](../../contracts/private-api/compatibility.json)。
- 每次 DSM 或 File Station 升级后重新执行关键契约测试。
- 证书类型只记录“公共 CA”“自签名”或“私有 CA”，不记录证书正文、主机名或指纹。
- 内部 API 必须精确记录验证版本。
- “API 可发现”不能替代行为验证。
- 恢复必须完成删除、进入 `#recycle`、恢复和冲突测试。

## Synology Photos 兼容记录

> 照片内部接口未完成真实版本契约测试前保持关闭；基础照片库只使用官方登录和 File Station 能力。

| DSM build | Synology Photos 版本 | 平台 | 个人空间 | 共享空间 | 基础照片库 | 时间轴 | 相册 | 人物/主题 | 地点/标签 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | 1.8.2-10090 | macOS | 内部接口未验证 | 内部接口未验证 | File Station 基础照片库已实现，待完整实机验收 | 内部接口未验证 | 内部接口未验证 | 未验证 | 未验证 | 2026-07-29 |

照片兼容记录必须满足：

- 只记录 DSM build、套件版本、平台和结论，不记录 NAS 地址、账号、真实路径、相册名、人物或地点。
- 个人空间与共享空间分别验证不存在、无权限、只读和完整访问场景。
- 基础照片库验证套件未安装、停用和内部接口不可用时的文件夹浏览与管理。
- 时间轴、相册、人物、主题、地点和标签分别记录，不能用一个总开关代替逐项能力判断。
- 每次 DSM 或 Synology Photos 套件升级后重新运行内部 Adapter 契约测试。
- 内部写操作只有在对应版本、权限、确认、幂等和结果校验全部通过后才能启用。

## Synology Chat 兼容记录

> 普通用户聊天使用独立的 `SYNO.Chat.*` 内部适配器。当前开发联调版只在 `SYNO.API.Info` 明确返回兼容路径和版本时启用第一批能力；未完成实机记录前不得作为发布兼容结论。`SYNO.Chat.External` 的 Bot/Webhook 能力不能替代普通用户会话验证。

| DSM build | Chat Server 版本 | 平台 | 用户会话 | 一对一/建群 | 文字/Emoji | 媒体/文件 | 语音 | 提醒/投票 | 加密 | 日期 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 7.2.1-69057 Update 12 | 2.4.1-22111 | macOS | 官方网页客户端已登录；岚仓待复验 | 首次单聊和建群静态契约已确认；写入待验收 | 静态契约已确认；岚仓待复验 | 上传/读取契约已确认；实际送达待新构建验收 | 音频附件播放可见；录音未确认 | 提醒/投票契约已确认；写入待验收 | 能力存在；密钥协议未验证 | 2026-07-23 |

当前开发联调契约：

| 能力 | 内部 API | 客户端状态 | 首轮实机检查 |
| --- | --- | --- | --- |
| 用户目录 | `SYNO.Chat.User.list` | 已兼容根数组、单数/复数容器、对象字典和常见字段别名 | 复验当前 NAS 的用户数量、显示名、停用账号和当前账号标记 |
| 用户头像 | `SYNO.Chat.User.Avatar.get` | 仅在能力发现存在且用户声明有头像时读取；限制响应为图片且最大 2 MiB | 复验有头像、无头像、无权限和 QuickConnect 场景 |
| 会话列表 | `SYNO.Chat.Channel.list` | 已接线，按成员和名称区分已有单聊/群聊；Android 首次单聊把列表同时用于写前查重和模糊提交后的最终确认，提交后取消只回读且不重放；打开会话后以进程内时间/预览快照压制相同活动的旧未读数，时间推进或同秒预览变化时恢复服务器值，切换连接时清理；不冒充服务器已读 | 空名称双人会话、首次联系模糊提交、服务器已读回写方法、未读数、最后消息和时间单位 |
| 历史消息 | `SYNO.Chat.Post.list` | 已接线 offset/limit 向上分页、消息 ID 去重、原阅读位置恢复；连接工作区每 5 秒刷新会话列表，消息页面可见时刷新当前消息，进入页面立即刷新；空发送者名称由用户目录回填 | 复验发送者、顺序、总数、跨页重复、增量遗漏和消息时间单位 |
| 会话置顶/星标 | 本地 `UserDefaults`；群晖官方客户端提供 Star，但未公开写入 API | macOS 已实现按 NAS 配置隔离的本地持久化置顶、固定顺序、原生右键菜单和可访问图钉状态；关闭会话时清理本地记录。当前不会猜测调用群晖内部星标写接口 | 验证重启、多个 NAS、刷新和实时事件后的顺序；取得脱敏官方请求后再增加云端星标同步与冲突规则 |
| 文字/Emoji | `SYNO.Chat.Post.create` | 已接线客户端请求 ID 进程内去重、发送中/失败状态、手动重试和重试前结果复查；每个会话保留独立内存草稿 | 发送返回字段、超时最终状态、重试去重、组合 Emoji 和权限错误 |
| 消息转发 | `SYNO.Chat.Post.forward` v5，`post_id`、`channel_ids`；无已有会话的联系人先使用 `SYNO.Chat.Channel.Anonymous.initiate` v2（内部接口） | 已按 Chat Server `2.4.1-22111` 官方网页客户端确认并接入；可选择已有会话或联系人，后者先创建并复查一对一会话；NAS 直接复制文字和附件，不经过客户端下载；投票和加密消息保持关闭 | 实机验证无历史联系人的首次转发、跨单聊/群聊、多个目标、图片/视频/大文件、机器人消息、部分失败、权限与 QuickConnect 行为 |
| 群成员 | `SYNO.Chat.Channel.Member.get` v1，`channel_id`（内部接口） | macOS 已提供群成员列表，并使用用户目录补齐名称、头像、当前账号和停用状态 | 实机验证群主/普通成员、成员较多、退出成员、无权限和 `broken_user_ids` |
| 群公告 | `SYNO.Chat.Post.pin/unpin/search` v5（内部接口） | macOS 已提供消息右键设置/移除公告和群公告列表；写入后用 `Post.search(has=["pin"])` 复查 | 实机验证普通成员权限、公告排序、文字/附件、移除、重复提交和实时更新 |
| 图片/视频/文件上传 | `SYNO.Chat.Post.create` v5，multipart `file`（内部接口） | 已按官方网页客户端静态实现接线；仅在运行时版本范围覆盖 v5 时开放；一次一附件，支持进度、取消、失败重试、临时文件权限保护和响应解析 | 在新构建中分别发送虚构图片、视频、文本文件；验证送达、取消、弱网、超时去重、空间不足和特殊文件名 |
| 附件读取/缩略图 | `SYNO.Chat.Post.File.get(post_id)`、`thumbnail(post_id,type)` v2（内部接口） | 已接入按需缩略图、下载进度和另存为；图片单击显示无元数据的纯图片预览，不再显示重复的打开入口；HEIC/HEIF 在 NAS 无缩略图时于 64 MiB 上限内下载原图并由 macOS 生成预览；附件辅助空记录不进入消息列表，分页游标按服务器原始记录推进；认证信息只放请求头，临时文件即时清理 | 实机确认图片预览、HEIC/HEIF 本机兜底、辅助记录形态、`type=sm`、响应类型、权限、缓存、特殊文件名、大文件和 QuickConnect 行为 |
| 内置贴纸 | `SYNO.Chat.Post.create`，`type=sticker`，`message=:贴纸令牌:`（内部接口） | 已确认当前版本令牌与三组套件静态资源；因资源文件带版本哈希且许可/跨版本策略未完成，岚仓暂不提供贴纸面板 | 验证不同版本资源定位、素材许可、令牌兼容和接收端显示后实现 |
| 私人群聊 | `SYNO.Chat.Channel.Named.create/join/invite` | 已接线，创建前去重、邀请后复查成员；Android 保存本进程稳定频道 ID，成员不完整报告部分成功，创建提交后取消不继续加入或邀请，只执行最终回读 | 三账号创建、117 已加入语义、部分邀请失败、取消临界点和重复提交 |
| 提醒 | `SYNO.Chat.Post.Reminder.set/list/delete/get` v1 | 已接入设置、列表、修改式覆盖、取消、重复提交保护和取消后结果复查；列表按官方契约携带当前 `channel_id`，失败在弹窗内提供重试 | 实机验证时间单位、列表容器、修改语义、取消、权限和到期行为 |
| 定时消息 | `SYNO.Chat.Post.Schedule.create/set/list/delete` v1 | 已接入纯文字定时消息创建、列表、取消、创建前查重、取消后复查和原生表单；列表按官方契约携带当前 `channel_id`，修改与附件未实现 | 实机验证时间单位、返回结构、重复提交、取消、离线发送和权限 |
| 投票 | `SYNO.Chat.Post.Vote.create/close/delete/set/get_choices/vote/create_option` v1 | 已接入无附件投票创建、输入校验、重复提交保护、结果回读、历史投票结构解析和原生创建表单；参与、关闭、删除、附图和结果实时同步未实现 | 用虚构数据验证创建返回、历史字段、截止时间单位、单选/多选、匿名、权限、投票与关闭 |
| 删除本人消息 | `SYNO.Chat.Post.delete` 内部联调契约 | 已实现单个/批量确认、只允许本人消息、请求 ID 去重和删除后复查；兼容成功响应仅含 `success`、不含 `data` 的实机形态；未完成更多版本实机记录前不作为通用发布兼容结论 | 管理员允许/禁止、24 小时/全部消息策略、无权限、重复提交、部分失败和 QuickConnect |
| 关闭会话 | `SYNO.Chat.Channel.close` 内部联调契约 | 已实现单个/批量确认、归档说明、请求 ID 去重和关闭后复查；兼容成功响应仅含 `success`、不含 `data` 的实机形态；未完成更多版本实机记录前不作为通用发布兼容结论 | 单聊/群聊、普通成员/所有者、无权限、归档可见性、重复提交和部分失败 |
| 首次一对一会话 | `SYNO.Chat.Channel.Anonymous.initiate` v2 | `user_ids`, `encrypted`, `channel_key_encs` 已由官方客户端确认；岚仓已实现先查重、创建、再回读复查，尚未对测试 NAS 提交写请求 | 由两个从未聊天的测试账号验证权限、重复提交、返回结构和最终会话唯一性 |
| 实时增量 | `sc/socket.io`（内部协议） | macOS 已接入同源 WebSocket、Engine.IO 4/3 协商、心跳、指数退避重连、200 ms 事件合并刷新和 5 秒轮询降级；连接稳定时保留 30 秒 API 校准。认证仅使用 Cookie/请求头，事件正文不进入业务层和日志 | 用 DSM 7.2.x 与不同 Chat Server 版本验证路径、Origin、Engine.IO 版本、登录续期、睡眠唤醒、QuickConnect 中继和事件覆盖；失败时确认 5 秒同步继续可用 |
| 语音 | `SYNO.Chat.Post.File.get` 可播放音频附件 | 官方网页可播放音频附件，但未确认独立录音消息的创建语义；岚仓不显示录音按钮 | 确认录制编码、消息类型、时长、取消和跨端显示后实现 |
| 加密 | `Channel.Anonymous.initiate` 的 `encrypted/channel_key_encs` 及官方前端密钥流程 | 保持关闭；接口字段存在不代表密钥协议已安全验证 | 完成设备密钥、恢复、轮换、撤销和附件加密全流程后再启用 |

Chat 兼容记录必须满足：

- 只记录 DSM build、Chat Server 版本、平台、连接方式类别和结论，不记录 NAS 地址、账号、频道名、成员名、消息、附件名或密钥。
- 套件未安装、停用、升级中、当前账号无权限和会话被撤销分别验证。
- 用户会话、Bot Token 和 DSM 会话分别记录能力结论，不能互相替代。
- 用户列表、一对一、建群、文字/Emoji、媒体/文件、语音、提醒、投票和加密分别记录，不能用一个总开关代替逐项能力判断。
- 每次 DSM 或 Chat Server 升级后重新运行内部 Adapter 契约测试；未覆盖的新版本默认关闭发送、建群、提醒、投票和加密写操作。
- 建群、文字发送、附件发送、本人消息删除和会话关闭必须验证权限、重复提交保护、超时后复查与最终结果。
- 图片、视频和文件分别验证大小限制、格式、取消、弱网、空间不足、特殊文件名和 QuickConnect 行为。
- 语音消息验证麦克风权限、编码、时长、取消、后台切换和临时文件清理。
- 提醒与投票验证权限、截止、重复提交、结果同步和锁屏隐私。
- 加密会话验证首次设备、设备加入、恢复、轮换、成员变化、撤销、附件加密和错误口令；任何失败不得回退明文。

## 系统、连接、VMM 与容器只读发现记录

| 范围 | 当前版本 | 证据 | 本轮结论 | 未验证 |
| --- | --- | --- | --- | --- |
| DSM 系统/系统活动/当前连接 | DSM 7.2.1-69057 Update 12 | 官方网页可见 + `SYNO.API.Info` + 已登录会话只读响应结构核对 + DSM 前端静态请求；进程 API 目前仅有静态目录 | 已确认 `System.info`、`System.Utilization.get(resource=all,type=current)`、`Upgrade.Server.check` v3、`CurrentConnection.list/kick_connection` 和 `SyslogClient.Log.list`；Android 已按固定 v1 接入每 2 秒采样、最近 120 点内存历史及离页停止的处理器/内存/网络/存储趋势，并与 macOS 对齐固定 v3 更新检查参数、候选版本/说明解析及无候选/失败边界；macOS 系统活动页已实现只接受运行时发现 v1、最多 500 项、字段白名单和服务组失败降级，但真实进程响应未验证；更新下载/安装和结束进程保持关闭；连接断开具备确认、防重复和复查 | Android 真实采样耗电/流量、后台切换、普通账号权限、多网卡与空字段；进程/服务组真实版本与响应、无更新/分阶段更新/重大版本、更新服务离线/代理、长时间采样和连接消失竞态；更新下载/安装和连接断开尚未对真实会话执行 |
| DSM 远程访问设置 | DSM 7.2.1-69057 Update 12 | 官方页面请求线索与已记录环境为 `observed / degraded`；Android 仅完成合成请求、故障注入、领域和 Compose 测试 | Android 第 55 批正式 Repository 固定 `SYNO.Core.QuickConnect.get_misc_config/set_misc_config` v3 与 `SYNO.Core.QuickConnect.Upnp.get/set` v1，严格 Boolean、单项 `null` 降级、已记录环境写门禁、可信中继关闭保护、实际变化字段提交、取消/断线不重放、专项回读与持久八状态/三计数反馈；专项 36 项 JVM 与 12 项 Compose 通过 | 未在真实 NAS 或路由器执行中继和自动端口映射写操作；不同 build、路由器、权限、断线与最终状态仍需专用目标验收；登录、QuickConnect 隧道和 `SYNO.API.Info` 证据不能外推为本设置写入证据 |
| DSM 电源计划 | DSM 7.2.1-69057 Update 12 | 仅有静态 API 目录与客户端合成响应；未保存真实响应 | macOS 已候选接入运行时发现的 v1 `load`，最多 128 条，只保留动作、启用状态、合法时间、命名星期、一次日期和可选时区；能力缺失零请求，`save` 保持关闭 | 真实版本、路径、字段、动作与重复枚举、时区/夏令时、权限、数量上限和排序；保存操作尚无版本化契约 |
| DSM USB/eSATA 外接存储 | DSM 7.2.1-69057 Update 12 | 仅有静态 API 目录与客户端合成响应；未保存真实设备响应 | macOS 已候选接入两个运行时发现的 v1 `list`，每类最多 64 项，只保留受限标识/名称、归一状态和单位明确的字节容量；单项失败独立降级，USB `eject` 保持关闭 | 真实版本、路径、容器、字段、权限、多分区/扩展坞/热插拔身份、容量单位与排序；安全弹出尚无版本化契约 |
| DSM 内存压缩（ZRAM） | DSM 7.2.1-69057 Update 12 | 静态目录确认 `get/set`；2026-08-03 已在官方 DSM 页面只读观察到设置，但未捕获 API 请求或响应 | macOS 已候选接入运行时发现的 v1 `get`，只保留启用状态、单位明确的字节容量和 `lz4`/`lzo`/`zstd` 算法白名单；能力缺失零请求，`set` 保持关闭 | 真实版本、路径、容器、字段、权限、禁用状态、算法枚举和不同硬件可用性；设置操作尚无版本化参数、资源影响、重启/即时生效与最终回读契约 |
| DSM 打印机 Bonjour 共享 | DSM 7.2.1-69057 Update 12 | 仅有静态目录中的 API 名称和 `get`；没有在当前环境观察或调用 | 客户端保持关闭，不注册版本、领域模型或 Adapter，不复用通用 Bonjour/Avahi 字段，零猜测请求 | 运行时 API 是否存在、版本、路径、参数、响应容器、布尔语义、权限，以及是否包含打印机/队列/设备/网络字段 |
| DSM 存储/套件/任务/账号 | DSM 7.2.1-69057 Update 12 | `SYNO.API.Info` + 已登录会话只读响应结构核对 + DSM 前端静态请求 | 已确认 `Storage.Disk.get_smart_test_log/disk_test_log_get/do_smart_test` v1：请求使用 `load_info.disks[].device`，状态取 `testInfo[0]`，历史取 `testLog`，并识别其他检测占用；同时确认 `EventScheduler.result_list/result_get_file` v1、套件管理、任务管理以及用户/群组管理；macOS 已实现硬盘检测启停、真实历史记录、任务运行记录和其他受保护流程；套件启动/停止另已实现列表状态与可行性预检、同 ID 防重复、写后轮询及提交异常只回读不重放；`available_operation=upgrade` 仅显示 DSM 只读提示，安装/升级保持关闭 | 不同 RAID/SSD/扩展柜、普通账号、空目录和大清单；硬盘检测、套件启停及其他写操作仍需用专用测试目标完成权限、依赖阻止、忙碌、重复提交、超时与最终状态实机验收；套件来源、安装队列、取消和最终版本回读未验证 |
| Virtual Machine Manager | 2.6.5-12202 | 官方网页可见 + `SYNO.API.Info` + Synology 官方 VMM API 指南 + 2026-07-27 已登录页面只读导航、创建/修改请求发送前拦截、日志页面与前端读取契约核对和 noVNC 地址生成逻辑核对 | macOS 已接入官方 `SYNO.Virtualization.API.*` v1 优先和内部接口隔离降级；Android 可创建总计最多 8 块空白/映像混合磁盘和多网卡（含未连接网卡），但 `Guest.get` 缺少源映像 ID，含映像盘结果只标记需刷新核对。Task.Info 最多读取 100 项，仅在任务页可见且仍有未结束任务时每 2 秒独立刷新；清理以全量 `list/get` 基线为准，只逐项 `clear` 未漂移的已结束任务。NAS 既有文件和系统 `OpenDocument` 本机文件均可沿公开 `Guest.Image.create` 创建；本机文件先经 File Station 无覆盖暂存，跨进程恢复记录使用加密存储，写边界不明时不重放，终态按完整基线删除临时文件 | 新增能力仅增加公开指南驱动的合成契约、JVM、编译与模拟器界面证据，不升级真实环境证据等级；真实 NAS 的多磁盘/多网卡字段、映像来源、任务字段、清理权限与副作用，以及系统文件授权、后台限制、格式、权限、存储和临时文件删除待用户打包验证。高级硬件编辑、迁移、克隆、映像编辑/导出和内部网络修改/删除仍需稳定契约或专用目标 |
| Container Manager | 24.0.2-1535 | 官方网页可见 + `SYNO.API.Info` + 2026-07-27 已登录页面只读导航、脱敏请求结构核对和下载请求发送前拦截 | 已确认 `SYNO.Docker.Container.list` v1 需要 `offset=0`、`limit=-1`、`type=all`；镜像仓库使用 `SYNO.Docker.Registry.search(offset,limit,page_size,q)` 与 `tags(repo)`，下载使用 `SYNO.Docker.Image.pull_start(repository,tag)`；macOS 已实现搜索、结果选择、标签筛选和下载启动，并将映像、网络、项目和活动记录隔离为可降级附属读取 | 下载请求在发送前终止，未对真实 NAS 执行拉取；其他写操作尚未在专用目标执行；环境变量、挂载路径、容器日志正文与 Registry 凭据未读取 |
| Download Station | 4.1.2-5012 | 官方公开指南 + 2026-07-27 已登录页面只读导航与脱敏字段核对 + 2026-07-29 套件中心版本复核 | macOS 官方 `SYNO.DownloadStation.*` 优先，当前 NAS 的 `SYNO.DownloadStation2.*` 独立降级；Android 已接入 Tracker/Peer、RSS 浏览/单站点刷新和结构化任务控制。Android、Apple shared/mobile 与 Windows Domain/Infrastructure/ViewModel/WinUI 均已按官方 `SYNO.DownloadStation.BTSearch` v1 接入提供方/类别目录、全部/仅启用/指定提供方范围、类别、标题、七类排序与方向、有界列表和临时任务清理，不回退到 `DownloadStation2`；Apple/Windows 候选提交 `53360d2` 已通过 Apple、Android、Windows 与 Repository 四组云端门禁，但不构成新的真实 NAS 证据。Android、Windows 与 Apple 公开 Download Station 路径的当前活动摘要使用官方 `SYNO.DownloadStation.Statistic.getinfo` v1；Apple 既有 `DownloadStation2` 降级路径仍 best-effort 使用内部 `SYNO.DownloadStation2.Task.Statistic.get`。两条 Apple 路径都只显示标准任务/eMule 当前聚合速率，读取失败不替换任务列表，也不升级真实 NAS 证据。第 78 批另新增官方 Task.edit v1 单任务保存位置：任务/可写目录双基线、单次提交、严格回读、断线/取消不重放及持久反馈 | 新增能力只增加公开指南驱动的合成请求、领域、自动化、模拟器和云端构建证据，不升级真实环境或写行为等级；真实 NAS 的搜索提供方/类别、清理、速率字段、权限与版本差异，以及文件移动副作用和断线边界待用户打包验收。官方指南仍未公开 RSS 完整编辑或文件优先级写参数；BT 协议高级设置、监听目录、NZB、RSS 与通知设置仍需契约和专用目标验收 |

本表只确认当前记录的发现范围。合并后的 NAS 设置已形成当前 DSM build 的既有读取结构兼容结论；新增系统活动、电源计划、外接存储与内存压缩适配仍只有静态目录、页面观察或合成测试，不继承其他系统接口的 `read-verified`；打印机 Bonjour 共享仅完成静态登记，客户端整体关闭。当前账号共享访问只使用公开 File Station 契约，内部管理员权限矩阵保持关闭。文件服务、远程终端、代理、物理网卡、DDNS、区域时间、远程访问、防火墙基础控制、UPS 和套件启停已按当前 DSM 前端契约接入客户端保护与写后回读，但尚未在专用测试设备上形成真实写操作兼容结论。Android 第 55 批远程访问合成测试不改变机器可读记录的 `observed / degraded`，也不把登录或 QuickConnect 连接证据外推为设置写行为证据。Android 第 56 批 Download Station 合成测试同样不升级套件兼容证据，不把任务消失外推为文件删除副作用已确认；真实暂停、继续与两类删除仍待专用目标验收。Android 第 67 批文本保存、压缩和解压只增加客户端基线、路径锁、结果保存及合成回读证据，不升级 File Station 兼容等级；顶层解压路径与类型核对不代表递归内容或校验和已验证。第 68 批 RSS 持久结果与 `DownloadStation2`/VMM 独立文档只修正客户端反馈和证据引用，不提升 `observed`、`read-verified` 或写行为等级；第 69 批后台上传持久结果只保留公开 File Station 调用的客户端语义，不形成新的真实 NAS 证据。真实任务字段、权限、断线、取消、挂载切换和副作用仍待专用目标验收。共享文件夹复合管理、完整防火墙规则、电源计划保存、USB 安全弹出和内存压缩设置仍保持关闭；其他 DSM build、套件版本与权限组合仍需验证。Download Station、VMM 与 Container Manager 已进入 macOS 实现，但内部接口写操作仍以专用目标验收为发布前置条件。
