# File Station VFS 连接

端点组 `file-station-vfs-connections`，组件 file-station，internal / mixed / high。静态来源：[本轮官方 FileBrowser.js / FileBrowserUtil.js](../environments/2026-10-02-file-station-live-observation.md)，版本 DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。未连接、修改或断开实际远程位置。

## 契约候选

所有接口为 v1、POST、能力发现 entry.cgi、绑定会话：
- `SYNO.FileStation.VFS.Protocol/list` 返回 protocols：protocol/name/default_port/has_server。选择 NAS 返回的协议，不硬编码承诺所有云厂商。
- `VFS.Profile/list` 返回 profiles：protocol_name/protocol/uri/hostname/port/alias/account/codepage/connect_status。id 来自 JsonReader 默认 id 属性，作为不透明稳定标识；不能从主机、别名或 URI 自行拼接。实际非空连接身份仍待专用环境核对。
- `VFS.Profile/get` 参数 id；可返回密码，不为表单回显读取密码。网页用假密码占位，客户端不能把假密码提交回 NAS。
- `VFS.Connection/create` 与 `VFS.Profile/create` 使用 protocol、client_id、hostname、port、alias、account/password、codepage、uri_path、access_token/refresh_token/expires_in、max_connection、force=false；已保存连接可仅 profile_id。必须区分这两步的结果，不能盲重放 compound。
- Profile.set 为 id 与实际变化字段；Profile.delete 为指定 id。Connection 断开与保存配置删除不同，不自动连带删除配置。
- 2107/2112/2115 表示证书、主机身份或重新授权类警示；禁止自动 force 绕过。

## 云盘正式授权

官方前端通过 `synooauth.synology.com/FileStation/Cloud/login.php` 启动授权，传 type、host、callback 和系统版本字段，最终同源消息含 callback、account、access_token/refresh_token/client_id/expires_in。官方只将 google/dropbox/baidu/onedrive/box 视为云盘，实际入口仍以 NAS Protocol.list 为准。

2026-10-02 使用完全合成参数只读检查：major=7、minor=2、type=google、回调 host 为本机随机路径即可进入 Google 官方账号选择页；省略 major/minor 则服务报告不支持。Google 请求的 redirect_uri 仍是群晖官方 Cloud/redirect.php，state 保留原 host 与 callback。未选择账号、未提交授权、未取得令牌。此证据仅为授权启动 observed，不证明成功回调或云连接写入。

macOS 使用系统浏览器，符合 [Google 原生应用授权要求](https://developers.google.com/identity/protocols/oauth2/native-app)。主 App 只在授权期间监听 127.0.0.1 的系统分配端口；host 附一次性随机路径，callback 使用同一尝试的随机名称。回调 HTTP 解析仅支持 GET/query 或 POST/form、JSON/data 载荷，并保留官方已声明的账号/令牌字段；成功中继的实际传输封装尚未在真实账号验证，必须记录为 PENDING_USER_VALIDATION。未知或缺字段明确拒绝，不能伪造授权成功。

凭据只在授权/请求内存中，不日志化或复制到待核查模型。创建固定协议/账号/别名，续授权固定原 id/协议/URI/账号；两个请求分别核对。未知不重放，不自动撤销连接，不触发文件删除。协议能力、绑定会话权限、确认与回读仍保留，按用户要求取消测试环境开关及精确固件白名单。

五端影响：macOS 当前实施；iPhone/iPad 保持原移动范围，Android/Windows 只更新计划。真实行为均未验证。


## 进一步证据与当前边界

只读打开官方“连接设置”向导后观察 Protocol.list 自然响应：default_port 为数值、protocol/name 为字符串、has_server 为布尔。FTP 条目也可能 has_server=false；FileBrowser.js 的 createVFSRoot 仅在 has_server 时显示树根，因此该字段表示是否已有连接，不能作为“协议是否支持服务器输入”或能力关闭条件。协议名称来自 NAS，客户端只为静态表单已明确的 ftp/sftp/dav/davs 提供新建与修改。

Connection.set 与 Profile.set 必须分别调用并核对；create 同理。保存配置删除与断开分为不同操作，只有已断开配置才可删除。两个步骤中任一步未知，后续不自动重放；凭据不进入待核查记录。新建/修改凭据要求本机到 NAS 的 HTTPS，force 始终为 false。远程浏览按官方 FileBrowserUtil.js 的 getRemoteTreeParams 使用公开 List.list 与原始远程 URI；无需另猜 Entry.Request。客户端只接受原连接根下路径，完整分页、过滤、返回和下载均复用既有文件能力。

源码：`DsmFileRepository+VFS.swift`、`FileVFSViews.swift`、`FileVFSBrowserView.swift`、`FileVFSCloudAuthorizationView.swift`、`FileVFSCloudAuthorizationSession.swift`；自动化：`FileStationParityTests`。合成请求位于 `contracts/request-fixtures/file-station/create-vfs-connection`、`create-vfs-profile`，响应位于 `contracts/fixtures-redacted/file-station/vfs`，结构描述为 `contracts/schemas/file-station-vfs.schema.json`。公开核查入口与保存共享互斥状态，不持久化密码或自动补发第二步。

请求新增 create-vfs-cloud-connection/profile、reauthorize-vfs-connection/profile 合成样本；真实本机回调测试为 `FileVFSCloudAuthorizationTests`，无云账号登录、NAS 请求或浏览器数据读取。正式主 App 新增 network.server entitlement 仅满足 loopback 回调；取消/完成/超时关闭，不改变扩展、Bundle ID 或存储。


## 2026-10-04 移动 M2f 适配

iPhone/iPad 按[移动主计划](../../../development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)接入现有共享 Repository 的原对象校验、权限、阶段控制和最终回读，替代上文历史移动范围；未新增请求、参数或版本。移动恢复记录独立保存未结束目标身份，凭据仅用于当前请求，未知不重放。macOS 仅共享校验/云回调代码引用调整，Windows/Android 无请求变化。本机模拟器与合成回调证据不提高此端点在真实 DSM/套件上的等级，真实连接/断开及云授权仍未验证。


## 2026-10-12 Android A3m 适配

Android 沿用已记录的内部 v1 Profile/Connection/Protocol、Core.System.info 与公开 List.list/Download v2，不新增 API 参数。独立 `FileVFSFeatureModel` 已接正式文件菜单、动态连接类型、服务器表单、云授权、动作确认、持久恢复及原 URI 分页浏览。未知类型只展示已有信息，`has_server` 不控制表单是否开放；未知连接状态不伪装已连接或已断开。

- 写入要求原账号文件授权、管理员、精确版本与新鲜清单；新配置/凭据要求到 NAS 的 HTTPS，FTP/HTTP WebDAV 另需明确接受明文后果。编辑只发送变化字段，未更换密码不发送密码，明确换为空值时保留用户选择；Connection 使用 `force=false`，不绕过身份警示。
- Connection 与 Profile 的提交、回执逐步同步记录，恢复数据不含密码/令牌；第二步失败或未知不重放，只有真实回读符合且必要回执齐全才结束。断开与删除配置是两个动作，只能删除已断开的配置，均不调用文件删除。
- 云登录仅向官方中继发送版本、支持类型与随机本机回调，不发送 NAS 地址或会话。监听只绑定 loopback，验证 host/路径/尝试编号、原账号与协议；取消、超时和切换关闭监听并清空授权。回调后仍需明确保存，系统浏览器真实成功回调与云服务兼容保持 `PENDING_USER_VALIDATION`。
- 浏览使用原 URI、完整页偏移和总数；连接身份变化、缺字段、失败与空目录分开。单文件通过共用系统保存选择器和前台/Worker 下载执行；独立加密来源绑定原连接/父目录/文件大小与时间，执行/续传前重查，失败不打开或截断目标。没有远程目录 ZIP、上传、改名或删除的新增承诺。

当前聚焦 JVM、增量构建和模拟器证据见[验证历史](../../../archive/2026-h2/RELEASE_VALIDATION_HISTORY.md#2026-10-12-android-a3m-服务器与云盘连接)。iPhone/iPad/macOS/Windows 源码与既有范围不变；没有新依赖、系统权限或包名变更，旧任务字段不迁移。此条仅记录 Android 客户端适配，真实环境 `verifications` 与证据等级不变。

## 2026-10-14 五端写入策略更正

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。 Android已删除A10误加的限制；实际权限和恢复保护保留，见[功能参考](../../reference/files.md#写入可用性与版本策略五端统一)。真实环境证据等级不变。
