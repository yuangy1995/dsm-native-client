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
