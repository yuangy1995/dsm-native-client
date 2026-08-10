# Synology DSM Web API 原生应用开发参考

> 文档版本：1.1.1
> 整理日期：2026-07-23
> 项目源码基线：`apaipai/dsm_helper` 的 `dev` 分支提交 `8c104e9a783a1acaf366a250e5fcd1d623f14eb2`
> 该提交日期：2024-06-25；本文不会把更晚的 DSM/套件行为推断为已经验证
> 适用范围：面向 Android、iOS、macOS 等原生客户端的 HTTP API 调用层设计

## 1. 文档目的与边界

本文将群晖 DSM Web API 分为三类：

| 标记 | 含义 | 维护策略 |
| --- | --- | --- |
| `官方` | 群晖提供正式开发文档，接口名称、方法和参数有公开说明 | 可作为核心功能依赖，但仍需运行时查询版本 |
| `混合` | 同一产品存在官方 API，但项目使用了不同名称、更新版本或额外方法 | 优先调用官方版本，内部变体单独适配 |
| `内部` | DSM 网页或套件自身使用，但没有找到对应的正式 API 规范 | 视为易变实现细节，必须做能力探测和降级 |

本文不是群晖官方文档的替代品。官方接口的完整字段、限制与错误码应以群晖原文为准；内部接口仅记录项目源码中观察到的调用方式，不代表群晖承诺兼容。

### 1.1 资料来源

- [DSM Login Web API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf)
- [File Station Official API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)
- [Download Station Web API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)
- [Virtual Machine Manager API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/Virtualization/All/enu/Synology_Virtual_Machine_Manager_API_Guide.pdf)
- [DSM Developer Guide 7](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf)
- [Synology QuickConnect White Paper](https://global.download.synology.com/download/Document/Software/WhitePaper/Os/DSM/All/enu/Synology_QuickConnect_White_Paper_enu.pdf)
- [`dsm_helper` 项目源码](https://gitee.com/apaipai/dsm_helper/tree/dev/)
- 项目集中式接口实现：[`lib/utils/api.dart`](https://gitee.com/apaipai/dsm_helper/blob/dev/lib/utils/api.dart)
- 项目模型与分模块接口：[`lib/models/Syno`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno)

### 1.2 动态验证范围

本文已对当前 NAS 设置只读模块执行脱敏的实机响应结构核对，但没有对所有内部接口、权限组合和 DSM 版本逐项执行。正式发布前仍应补充以下验证矩阵：

- DSM 6 与 DSM 7 的具体版本及 build number。
- 安装的 File Station、Download Station、Container Manager、Synology Photos、VMM 版本。
- 管理员与普通用户的权限差异。
- 请求格式、返回字段和错误码的实际差异。

### 1.3 当前实机只读确认

2026-07-23 在一台已登录的测试 NAS 上完成了只读核对。为避免泄漏真实环境，本文只记录版本和能力结论：

- DSM `7.2.1-69057 Update 12`；Virtual Machine Manager `2.6.5-12202`；Container Manager `24.0.2-1535`；Chat Server `2.4.1-22111`。
- 使用无凭据的 `SYNO.API.Info query=all` 确认 API 名称、路径、版本范围与请求格式；通过已登录网页会话只读调用确认了系统利用率、存储、套件、计划任务、账号与群组、系统日志和当前连接的实际响应结构。
- 未导出或保存 Cookie、SID、SynoToken、DID、浏览器存储、真实主机地址、账号、消息、虚拟机名称、容器名称或文件路径；仓库只保留脱敏后的接口契约。
- 未执行删除、断开连接、网络修改、虚拟机电源控制、容器控制、消息发送等写操作。

本文把证据分成四级：`能力可发现`、`官方界面可见`、`官方前端静态契约确认`、`行为验证通过`。前三者都不能替代最后一级。

## 2. DSM Web API 通用协议

### 2.1 基础地址

推荐只使用 HTTPS：

```text
https://<NAS_HOST>:5001/webapi/<API_PATH>
```

常见路径：

| 路径 | 用途 |
| --- | --- |
| `/webapi/entry.cgi` | 当前登录指南中的 API 查询固定入口，也是 DSM 6/7 大量 API 的统一入口 |
| `/webapi/query.cgi` | 旧版 File Station/Download Station 指南中的 API 查询入口 |
| `/webapi/auth.cgi` | 旧文档中的认证入口；新登录文档通常返回 `entry.cgi` |
| `/webapi/FileStation/...` | 部分旧版 File Station 专用 CGI |
| `/webapi/DownloadStation/...` | 旧版 Download Station 专用 CGI |

不要硬编码业务 API 路径。启动时先在 `/webapi/entry.cgi` 调用 `SYNO.API.Info`；兼容较旧 DSM 时，如该入口明确不存在，再回退 `/webapi/query.cgi`。之后始终使用 NAS 返回的 `path`。

### 2.1.1 QuickConnect 地址解析 - 内部、可降级

群晖公开资料说明 QuickConnect ID 可以用于群晖移动应用，并会把浏览器入口重定向到可用的直连或中继地址，但没有找到面向第三方客户端的正式地址解析 API 规范：

- [Synology NAS External Access Quick Start Guide](https://kb.synology.com/en-my/DSM/tutorial/Quick_Start_External_Access)
- [Synology QuickConnect White Paper](https://global.download.synology.com/download/Document/Software/WhitePaper/Os/DSM/All/enu/Synology_QuickConnect_White_Paper_enu.pdf)

macOS 参考实现使用 QuickConnect Web Portal 自身的内部解析入口作为可降级适配器：

```text
POST https://global.quickconnect.<region>/Serv.php
command=get_server_info
id=mainapp_https
serverID=<QUICKCONNECT_ID>
```

直连候选均不可用时，参考实现会向解析结果中的控制服务器请求中继：

```text
POST https://<CONTROL_HOST>/Serv.php
command=request_tunnel
version=1
id=mainapp_https
serverID=<QUICKCONNECT_ID>
```

`request_tunnel` 的字段和响应结构来自 QuickConnect 当前客户端实现，属于未公开的内部契约。客户端只接受 `*.relay.*.quickconnect.to` 或 `*.relay.*.quickconnect.cn` 中继主机，并在发送登录信息前请求控制响应给出的 `pingpong_path`；返回的 `ezid` 必须等于 NAS 标识的小写 MD5，否则立即终止连接。中继 HTTPS 必须通过系统证书信任，不能使用自签名证书确认流程绕过异常证书。

安全与兼容边界：

- 该入口标记为 `内部`，不视为群晖承诺兼容的公开 API。
- 请求不携带 DSM 用户名、密码、SID、SynoToken、文件路径或其他会话数据。
- 只接受 `smartdns.lan` 或 `smartdns.host` 中以 `.direct.quickconnect.cn`、`.direct.quickconnect.to` 结尾的地址，并校验端口范围。
- 先验证直连候选；全部失败后才请求中继，并在中继身份核对成功后执行 DSM 能力发现。
- 解析失败时允许用户改为粘贴浏览器最终地址，或输入 NAS 的 IP、`.local`、DDNS 和自定义域名。
- 解析结果只用于当前连接，不替换界面和本地配置中保存的 QuickConnect ID，也不写入日志。

### 2.2 通用请求字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `api` | String | API 名称，例如 `SYNO.FileStation.List` |
| `version` | Int | API 版本，必须处于 `minVersion...maxVersion` 范围内 |
| `method` | String | API 方法，例如 `list`、`get`、`start` |
| `_sid` | String | POST 正文中的会话 ID；用于不依赖 Cookie 的兼容路径 |
| `Cookie: id=<SID>` | Header | 官方 Cookie 会话方式；SID 只能进入请求头，不得进入 URL |
| `SynoToken` | String | 开启 SynoToken 后的 CSRF 令牌，部分管理接口需要 |

建议默认采用 `POST` 和 `application/x-www-form-urlencoded`。虽然官方示例经常使用 GET，但 GET 会把密码、SID、文件路径等写入 URL、代理日志和浏览器历史。

macOS 参考实现使用 `format=sid` 登录，并在后续 HTTPS 请求中同时发送安全 Cookie 请求头和 POST 正文 `_sid`。两处必须是同一个 SID；这样既兼容 DSM 的 Cookie 会话，也兼容只识别 `_sid` 的版本。Cookie 不写入磁盘，由应用沙盒 AES-GCM 加密文件中的 SID 在内存中临时构造。

### 2.3 `requestFormat=JSON`

`SYNO.API.Info` 的响应可能包含：

```json
{
  "path": "entry.cgi",
  "minVersion": 1,
  "maxVersion": 2,
  "requestFormat": "JSON"
}
```

当 `requestFormat` 为 `JSON` 时，除 `api`、`version`、`method` 等控制字段外，数组、布尔值、对象和字符串参数应按 JSON 值编码后再作为表单字段发送。例如：

```text
path=["/video/a.mp4","/video/b.mp4"]
additional=["size","time","perm"]
overwrite=true
```

不要沿用旧项目中随处手工拼接双引号的方式，应由统一编码器根据 `requestFormat` 编码。

### 2.4 通用响应信封

成功响应：

```json
{
  "success": true,
  "data": {}
}
```

失败响应：

```json
{
  "success": false,
  "error": {
    "code": 105
  }
}
```

部分批处理、文件操作和内部接口会在 `error.errors` 或 `data.result` 中返回嵌套错误，客户端不能只检查 HTTP 状态码。

### 2.5 通用错误码

| 错误码 | 含义 | 建议处理 |
| --- | --- | --- |
| `100` | 未知错误 | 记录已脱敏上下文并提示重试 |
| `101` | 缺少 API、method 或 version | 客户端参数错误 |
| `102` | API 不存在 | 标记功能不支持，不要循环重试 |
| `103` | method 不存在 | 切换适配器或禁用功能 |
| `104` | 版本不支持 | 重新查询 `SYNO.API.Info` |
| `105` | 当前会话权限不足 | 提示权限，不要要求用户直接改用管理员 |
| `106` | 会话超时 | 清理 SID 并重新认证 |
| `107` | 重复登录导致会话中断 | 清理旧会话后重试一次 |
| `108` | 文件上传失败 | 检查大小、空间和传输状态 |
| `109`-`111` | 网络不稳定或系统繁忙 | 有上限地退避重试 |
| `114` | 缺少该 API 所需参数 | 客户端参数错误 |
| `115` | 不允许上传文件 | 提示权限或服务器策略 |
| `116` | 演示站点不允许执行 | 禁用对应操作 |
| `117`-`118` | 网络不稳定或系统繁忙 | 有上限地退避重试 |
| `119` | 会话无效 | 清理 SID 并重新认证 |
| `150` | 请求来源 IP 与登录 IP 不一致 | 不自动重试，检查网络切换或代理 |

## 3. API 能力发现

### 3.1 `SYNO.API.Info` - 官方

| 项目 | 值 |
| --- | --- |
| 当前固定路径 | `/webapi/entry.cgi`；旧 DSM 可回退 `/webapi/query.cgi` |
| version | `1` |
| method | `query` |
| 是否需要登录 | 否 |

请求参数：

| 参数 | 必需 | 说明 |
| --- | --- | --- |
| `query` | 是 | 逗号分隔的 API 名称，或 `all` |

安全的命令行示例：

```bash
curl --fail --silent --show-error \
  --request POST \
  --data-urlencode 'api=SYNO.API.Info' \
  --data-urlencode 'version=1' \
  --data-urlencode 'method=query' \
  --data-urlencode 'query=SYNO.API.Auth,SYNO.FileStation.List' \
  'https://nas.example.com:5001/webapi/entry.cgi'
```

典型响应字段：

| 字段 | 说明 |
| --- | --- |
| `path` | 实际 CGI 路径 |
| `minVersion` | 最低支持版本 |
| `maxVersion` | 最高支持版本 |
| `requestFormat` | 参数编码方式；可能为 `JSON` |

注意：`query=all` 能发现许多内部接口，但“能够发现”不等于“官方公开支持”。

### 3.2 推荐的客户端缓存结构

```json
{
  "nasId": "本地生成的设备标识",
  "dsmBuild": "72806",
  "packages": {
    "FileStation": "3.x",
    "ContainerManager": "24.x"
  },
  "apis": {
    "SYNO.FileStation.List": {
      "path": "entry.cgi",
      "minVersion": 1,
      "maxVersion": 2,
      "requestFormat": "JSON"
    }
  }
}
```

当 DSM build、套件版本或服务器地址变化时，应使能力缓存失效并重新查询。

## 4. 登录、令牌与会话

### 4.1 `SYNO.API.Auth` - 官方

当前登录指南给出的范围为 version 3-7，并推荐 version 6。实际使用前仍应通过 `SYNO.API.Info` 查询。

#### login

| 参数 | 必需 | 版本 | 说明 |
| --- | --- | --- | --- |
| `account` | 是 | 3+ | DSM 用户名 |
| `passwd` | 是 | 3+ | DSM 密码；默认只在内存中短暂存在，用户明确选择“记住密码”时才进入平台系统安全存储 |
| `session` | 否 | 3+ | 会话名，例如 `FileStation`、`DownloadStation` |
| `format` | 否 | 3+ | `cookie` 或 `sid`；macOS 参考实现使用 `sid` 并保留 Cookie 请求头兼容 |
| `otp_code` | 否 | 3+ | 双重验证 OTP |
| `enable_syno_token` | 否 | 6+ | 请求返回 SynoToken |
| `enable_device_token` | 否 | 6+ | 请求可信设备 ID |
| `device_name` | 否 | 6+ | 可信设备名称 |
| `device_id` | 否 | 6+ | 已获取的设备 ID |

推荐请求：

```bash
curl --fail --silent --show-error \
  --request POST \
  --data-urlencode 'api=SYNO.API.Auth' \
  --data-urlencode 'version=6' \
  --data-urlencode 'method=login' \
  --data-urlencode 'account=<USERNAME>' \
  --data-urlencode 'passwd=<PASSWORD>' \
  --data-urlencode 'session=FileStation' \
  --data-urlencode 'format=sid' \
  --data-urlencode 'enable_syno_token=yes' \
  'https://nas.example.com:5001/webapi/entry.cgi'
```

成功响应的关键字段：

| 字段 | 说明 | 存储建议 |
| --- | --- | --- |
| `sid` | 授权会话 ID | 各平台受保护存储；macOS 使用应用沙盒 AES-GCM 加密文件，退出后删除 |
| `did` | 可信设备 ID | 仅用户明确选择“信任设备”时安全存储 |
| `synotoken` | CSRF 令牌 | 与 SID 同生命周期安全存储 |
| `is_portal_port` | 门户端口标志 | 普通状态字段 |

#### token

version 6 的 `method=token` 可重新查询 SynoToken。若页面或会话重载导致令牌变化，应更新内存中的值。

#### logout

```text
api=SYNO.API.Auth
version=<已探测版本>
method=logout
_sid=<SID>
```

退出成功后，无论服务端响应如何，客户端都应清理本地 SID、SynoToken 和临时 Cookie。

#### 认证错误码

| 错误码 | 含义 |
| --- | --- |
| `400` | 账号不存在或密码错误 |
| `401` | 账号已禁用 |
| `402` | 权限被拒绝 |
| `403` | 需要双重验证 |
| `404` | OTP 验证失败 |
| `406` | 强制执行双重验证 |
| `407` | 来源 IP 被阻止 |
| `408` | 密码已过期且不能更改 |
| `409` | 密码已过期 |
| `410` | 必须修改密码 |

### 4.2 原生应用凭据规则

- 不持久化 DSM 明文密码。
- 不把 `passwd`、`otp_code`、`_sid`、Cookie、SynoToken、DID 写入日志、崩溃报告或分析平台。
- 不把 SID 放入图片 URL、通知文本或剪贴板。
- iOS 使用 Keychain；Android 使用 Keystore 加密后的存储。
- 生物识别只用于解锁本地令牌，不能代替 DSM 的服务端认证。
- 以普通用户完成日常文件操作，高权限操作按需提示并二次确认。

## 5. File Station 官方 API

官方要求使用 `SYNO.API.Auth` 登录；传统会话名为 `FileStation`。下表是适合客户端实现的索引，完整字段以官方 PDF 为准。

### 5.1 接口总览

| API | version | methods | 关键参数/用途 |
| --- | ---: | --- | --- |
| `SYNO.FileStation.Info` | 2 | `get` | File Station 能力、主机名、是否管理员 |
| `SYNO.FileStation.List` | 2 | `list_share`, `list`, `getinfo` | 共享文件夹、目录列表、文件详情 |
| `SYNO.FileStation.Search` | 2 | `start`, `list`, `stop`, `clean` | 异步搜索 |
| `SYNO.FileStation.VirtualFolder` | 2 | `list` | CIFS/NFS/ISO 等虚拟挂载点 |
| `SYNO.FileStation.Favorite` | 2 | `list`, `add`, `delete`, `clear_broken`, `edit`, `replace_all` | 收藏目录 |
| `SYNO.FileStation.Thumb` | 2 | `get` | 获取缩略图二进制 |
| `SYNO.FileStation.DirSize` | 2 | `start`, `status`, `stop` | 显式启动、查询或取消目录大小任务；Apple 已接入，真实 NAS 响应待验证 |
| `SYNO.FileStation.MD5` | 2 | `start`, `status`, `stop` | 异步计算文件 MD5 |
| `SYNO.FileStation.CheckPermission` | 3 | `write` | 上传或创建前检查写权限 |
| `SYNO.FileStation.Upload` | 2 | `upload` | multipart 文件上传 |
| `SYNO.FileStation.Download` | 2 | `download` | 文件原始流或多文件 ZIP 流 |
| `SYNO.FileStation.Sharing` | 3 | `getinfo`, `list`, `create`, `delete`, `clear_invalid`, `edit` | 共享链接 |
| `SYNO.FileStation.CreateFolder` | 2 | `create` | 创建目录 |
| `SYNO.FileStation.Rename` | 2 | `rename` | 重命名 |
| `SYNO.FileStation.CopyMove` | 3 | `start`, `status`, `stop` | 异步复制和移动 |
| `SYNO.FileStation.Delete` | 2 | `start`, `status`, `stop`, `delete` | 异步或同步删除 |
| `SYNO.FileStation.Extract` | 2 | `start`, `status`, `stop`, `list` | 解压和查看压缩包；`list` 用于开始前检测密码并比较文件名编码，`start` 必须沿用选定的 `codepage` |
| `SYNO.FileStation.Compress` | 3 | `start`, `status`, `stop` | 异步压缩 |
| `SYNO.FileStation.BackgroundTask` | 3 | `list`, `clear_finished` | 客户端只允许只读 `list`；清除已完成记录的 `clear_finished` 保持关闭 |

### 5.2 列出共享文件夹

```text
api=SYNO.FileStation.List
version=2
method=list_share
offset=0
limit=100
sort_by=name
sort_direction=asc
additional=["real_path","size","owner","time","perm","mount_point_type","volume_status"]
```

关键响应字段：`shares[]`、`offset`、`total`。每个共享对象至少关注 `name`、`path`、`isdir`、`additional`。

macOS 客户端使用公开的 `list_share` 响应中 `additional.volume_status` 显示当前账号可见的存储空间。相同 `real_path` 卷只汇总一次，因此多个共享目录位于同一存储空间时不会重复计算。这里表示当前账号可见卷的总量、已用量和剩余量，不等同于存储管理员页面中的物理硬盘容量；NAS 不返回该字段时，界面显示“暂时无法读取”，不会改用内部存储管理接口扩大权限范围。

### 5.3 列出目录与文件详情

`method=list` 常用参数：

| 参数 | 说明 |
| --- | --- |
| `folder_path` | 目录路径，例如 `/video` |
| `offset` / `limit` | 分页；不要假定目录最多 1000 项 |
| `sort_by` | `name`、`size`、`user`、`group`、`mtime`、`atime`、`ctime`、`crtime`、`posix` |
| `sort_direction` | `asc` 或 `desc` |
| `pattern` | 可选名称过滤 |
| `filetype` | `file`、`dir` 或全部 |
| `additional` | `real_path`、`size`、`owner`、`time`、`perm`、`mount_point_type`、`type` 等 |

`method=getinfo` 使用 `path=[...]` 批量读取详情，返回 `files[]`。该方法固定要求
`SYNO.FileStation.List` v2；客户端先按输入路径字符串去重并保留首次输入顺序，再以每批最多
100 条的保守上限分块请求。官方指南没有声明服务端批量上限，因此 100 条只是客户端的
防御性限制，不代表 DSM 契约。`additional` 只请求当前功能需要的最小字段，不使用
`volume_status` 等未列入 `getinfo` 官方参数表的字段。上述分块、字段兼容性和不同权限下的
部分缺失响应尚未在真实 NAS 上验证。

远程位置浏览使用 `SYNO.FileStation.Info.get` 返回的 `support_virtual_protocol` 决定读取
范围，再对其中受支持的 `cifs`、`nfs`、`iso` 分别调用
`SYNO.FileStation.VirtualFolder.list` v2，合并结果后去重；不发送公开指南未列出的
`type=all`。该流程只读，单次向 DSM 请求最多 500 条，每个协议的读取窗口最多 5,000 条，
最终排序返回最多 5,000 个结果（三种协议最坏会在排序前处理 15,000 条）；
超过上限时界面明确提示结果已截断。请求只使用最小 `additional` 字段。ISO 挂载可以显示，
但界面不提供编辑或删除入口。协议大小写、空能力、失效挂载、跨协议重复项和分页合并
仍需在真实 DSM / File Station 上验证。

### 5.4 搜索

1. `start`：传入 `folder_path`、`pattern`、`recursive`、`search_content`、`search_type`，返回 `taskid`。
2. `list`：使用 `taskid`、`offset`、`limit`、`additional` 轮询结果。
3. `stop`：停止搜索。
4. `clean`：释放搜索任务。

客户端离开搜索页面时应调用 `stop` 或 `clean`，避免服务器残留任务。

### 5.5 收藏、缩略图和校验

| API | 调用要点 |
| --- | --- |
| `Favorite.list` | 支持分页和 `additional` |
| `Favorite.add` | `path`、`name` |
| `Favorite.edit` | `path`、新 `name` |
| `Favorite.delete` | `path` |
| `Thumb.get` | `path` 和缩略图尺寸，响应是二进制而非 JSON |
| `DirSize.start` | v2；`path` 使用 JSON 数组，成功返回 `taskid` |
| `DirSize.status` | v2；提交 `taskid`，返回 `finished`、`num_dir`、`num_file` 和字节数 `total_size` |
| `DirSize.stop` | v2；提交 `taskid`，成功时为空响应 |
| `MD5.start` | `file_path`，返回 `taskid` |
| `MD5.status` | 返回 `finished` 和 `md5` |
| `CheckPermission.write` | `path`、`filename`，公开契约用于检查目录中新建项目的写入权限；`create_only` 默认为 `true` |

`SYNO.FileStation.DirSize` 是 File Station 官方 v2 非阻塞任务。官方 `stop` 参数表疑似把
`taskid` 误写成 `tasked`，但同章节的 `start` / `status` 契约和 `stop` 请求示例均使用
`taskid`，客户端按示例与一致契约提交 `taskid`，不发送猜测字段。`start` 会在 NAS 上
创建目录遍历任务，`stop` 会取消任务，因此不能当作无副作用的普通读取；客户端只允许
用户在 macOS 属性窗口明确选择“计算大小”或“重新计算”后启动，同一路径防重复，并以
有界退避轮询 `status`。提交结果不确定时不得自动重放 `start`。

属性窗口关闭后计算可以继续，用户重新打开时可以查看或取消；关闭 File Station 模块或
断开当前 NAS 时会取消本地任务并尝试一次 `stop`。只有运行时能力缺失时才回退现有的
客户端递归统计，权限、网络、超时或响应异常不得伪装成回退成功。请求路径和服务端
`taskid` 只在 Repository 内存中短暂使用，不进入领域结果、用户错误、日志、持久化或
遥测；领域层只保留非负的总字节数、文件数和目录数。当前 Apple 共享仓库与 macOS
属性窗口已经实现该流程，但尚未在真实 DSM / File Station 上验证版本、权限、计数语义、
取消和长任务行为。

### 5.6 上传

`SYNO.FileStation.Upload.upload` 必须使用 `multipart/form-data`，文件二进制部分必须位于最后。

覆盖已有文件时不要用已存在的文件名和 `create_only=false` 作为兼容性前置判断：部分 DSM 会返回未公开错误码。客户端应使用一次性名称检查目标目录的新建权限，再由带 `overwrite=true` 的 Upload 请求决定该文件能否被覆盖，并在响应成功后重新读取目标进行结果校验。

请求必须发送准确的 `Content-Length`。DSM 会核对声明长度与实际收到的数据；缺少该请求头或长度不一致时会返回错误 `1800`。客户端应保留上传临时文件直到服务器响应，并将 `1800` 至 `1805` 映射为可操作的用户提示。

| part | 必需 | 说明 |
| --- | --- | --- |
| `api` | 是 | `SYNO.FileStation.Upload` |
| `version` | 是 | 运行时探测，官方文档主版本为 2 |
| `method` | 是 | `upload` |
| `_sid` | 是 | SID 模式下 |
| `path` | 是 | 目标目录 |
| `create_parents` | 是 | 是否创建父目录 |
| `overwrite` | 否 | `true/false`，较新版本也可能接受 `overwrite/skip` |
| `mtime`、`crtime`、`atime` | 否 | 毫秒 Unix 时间戳 |
| `file` | 是 | 最后一个 multipart part |

不要在上传失败日志中打印完整本地路径、远程路径、文件内容或 SID。

### 5.7 下载

```text
api=SYNO.FileStation.Download
version=2
method=download
path=["/video/movie.mp4"]
mode=download
_sid=<SID>
```

- 单文件返回文件内容。
- 多文件或目录返回动态生成的 ZIP 流。
- `mode=open` 尝试返回真实 MIME；`mode=download` 返回附件。
- 原生客户端应以流式方式写入临时文件，不能一次性读入内存。
- 音乐和视频预览应通过受认证的请求头发送会话，并使用 `Range: bytes=<start>-<end>` 按需读取；服务端必须返回 `206 Partial Content`、正确的 `Content-Range` 和总长度。每次响应设置固定上限，避免 NAS 忽略 Range 时意外读取整个大文件。
- 对 `.ts` 等同一扩展名可能代表视频或代码的文件，应先读取少量文件头并按文件签名识别类型，不能以文件大小作为判断依据。
- 如果只能通过 URL 交给系统播放器，避免在 URL 中放 SID；优先使用应用内代理或带认证 Header 的播放器数据源。

### 5.8 共享链接

| method | 关键参数 | 结果 |
| --- | --- | --- |
| `getinfo` | `id` | 单个共享链接详情 |
| `list` | `offset`、`limit`、排序 | `links[]`、`total` |
| `create` | `path=[...]`、可选 `password`、`date_expired`、`date_available` | URL、ID、二维码 |
| `edit` | `id=[...]`、密码、日期 | 空成功响应 |
| `delete` | `id=[...]` | 删除指定链接 |
| `clear_invalid` | 无 | 删除失效和损坏链接 |

共享链接属于敏感数据，不应发送到分析、日志或第三方二维码服务。

### 5.9 文件变更与后台任务

| 操作 | start 关键参数 | 轮询 |
| --- | --- | --- |
| 创建目录 | `folder_path=[...]`、`name=[...]`、`force_parent` | 同步返回 |
| 重命名 | `path=[...]`、`name=[...]` | 同步返回 |
| 复制/移动 | `path=[...]`、`dest_folder_path`、`remove_src`、`overwrite`、`accurate_progress` | `CopyMove.status(taskid)` |
| 删除 | `path=[...]`、`recursive`、`accurate_progress` | `Delete.status(taskid)` |
| 解压 | `file_path`、`dest_folder_path`、`overwrite`、`keep_dir`、`create_subfolder`、`password` | `Extract.status(taskid)` |
| 压缩 | `path=[...]`、`dest_file_path`、`level`、`mode`、`format`、`password` | `Compress.status(taskid)` |

异步任务通用原则：

- `start` 成功后保存 `taskid`。
- 采用退避轮询，前台建议 500 ms、1 s、2 s，后台进一步降低频率。
- 页面销毁不等于取消服务端任务；用户明确取消时调用 `stop`。
- `finished=true` 后再刷新目录列表。

`BackgroundTask.list` 是 File Station 官方 v3 只读接口。本批客户端请求固定使用
`offset >= 0`、`limit=1...100`、`sort_by=crtime`、`sort_direction=desc`，并将
`api_filter` 限制为 `SYNO.FileStation.CopyMove`、`SYNO.FileStation.Delete`、
`SYNO.FileStation.Extract` 和 `SYNO.FileStation.Compress`。官方默认 `limit=0` 表示
读取全部任务，客户端不得使用该无界默认值。

响应中的 `params`、`path` 和 `processing_path` 可能包含源/目标路径、文件名，甚至压缩
任务提交过的密码，必须在解码边界直接丢弃，不得进入领域模型、界面、日志、遥测、
持久化数据或测试 Fixture。`finished=true` 只表示任务停止运行，不等于操作成功；在没有
独立成功/失败证据时只能显示“已结束”，不能显示“已完成”。同一 API 的
`clear_finished` 会删除已完成任务记录，且省略任务标识时可能清除全部记录，因此不进入
Repository 或界面。macOS 传输中心已将 App 传输与 NAS 文件任务作为独立数据源展示，
NAS 任务支持全部/进行中/已结束筛选、手动刷新、有限分页，以及加载、空内容、筛选后
为空、错误和正常内容五种状态。当前实现与聚焦自动化测试已经完成，但尚未在真实
DSM / File Station 只读响应上验收。

## 6. Download Station API

### 6.1 官方公开接口

群晖公开的 Download Station 文档使用 `SYNO.DownloadStation.*` 命名空间。它与项目源码中的 `SYNO.DownloadStation2.*` 不是同一套接口，不应混用参数或响应模型。

| API | version | methods | 用途 |
| --- | ---: | --- | --- |
| `SYNO.DownloadStation.Info` | 1 | `getinfo`, `getconfig`, `setserverconfig` | 套件信息与基础设置 |
| `SYNO.DownloadStation.Schedule` | 1 | `getconfig`, `setconfig` | 下载计划 |
| `SYNO.DownloadStation.Task` | 1 | `list`, `getinfo`, `create`, `delete`, `pause`, `resume`, `edit` | 下载任务生命周期 |
| `SYNO.DownloadStation.Statistic` | 1 | `getinfo` | 当前下载/上传速度 |
| `SYNO.DownloadStation.RSS.Site` | 1 | `list`, `refresh` | RSS 站点 |
| `SYNO.DownloadStation.RSS.Feed` | 1 | `list` | RSS 条目 |
| `SYNO.DownloadStation.BTSearch` | 1 | `start`, `list`, `getCategory`, `clean`, `getModule` | BT 搜索 |

调用前先通过 `SYNO.API.Info` 查询路径。旧版文档中的路径可能是 `DownloadStation/*.cgi`，不能假定新套件仍保持相同位置。

#### 任务列表

```text
api=SYNO.DownloadStation.Task
version=1
method=list
offset=0
limit=100
additional=["detail","transfer","file","tracker","peer"]
```

典型响应为 `tasks[]`、`offset`、`total`。任务状态可能包括等待、下载、暂停、完成、校验、做种和错误；UI 应保留未知状态，不要把未知值直接映射为“失败”。

#### 当前活动摘要

Android 与 Windows 只在 `SYNO.API.Info` 声明官方
`SYNO.DownloadStation.Statistic` v1 可用时调用 `getinfo`；Apple 在公开 Download
Station 路径使用同一 v1/getinfo，既有 `DownloadStation2` 降级路径仍会 best-effort
调用 `SYNO.DownloadStation2.Task.Statistic.get`。三端界面都只把结果表达为当前标准
下载、标准上传、eMule 下载和 eMule 上传的聚合字节速率，不得表述为历史流量、
单任务速度或传输结果。Android 与 Windows 严格要求原生、非负的 `speed_download`、`speed_upload`、
`emule_speed_download` 和 `emule_speed_upload`，缺字段、负数、错误类型或请求失败
进入独立可重试错误，不遮蔽任务列表。Apple 当前共享适配仍兼容既有字段别名，
读取失败时以 `hasActivitySummary=false` 隐藏摘要，缺失字段按 0 处理；因此不能把
Android/Windows 的严格四字段失败语义外推为 Apple 已实现。后续若收紧 Apple，必须
先补向后兼容契约与移动端独立错误态测试。

#### BT 搜索

Android、Apple 共享仓库与 Windows 已按同一公开 v1 语义实现 BT 搜索；调用前使用
无参数 `getModule` 和 `getCategory` 读取提供方与类别，目录解析拒绝重复或畸形标识。
Apple 移动状态机与 Windows ViewModel 在提交前进一步拒绝陈旧或不属于当前目录的
提供方/类别；Repository 仍独立执行格式、范围和稳定标识校验。`start` 的 `module`
只使用 `all`、`enabled` 或经当前目录成员校验后按标识排序、逗号连接的明确提供方；
`list` 固定使用 `offset=0`、`limit=200`，同时传递用户选择的 `sort_by`、
`sort_direction`、`filter_category` 和 `filter_title`。搜索完成、读取失败、
超时或取消后均以返回的 `taskid` 在非取消清理路径中最多尝试一次 `clean`；清理请求
只针对该临时搜索任务，清理失败不得覆盖成功结果、取消或原始错误，也不冒充服务端
记录已经移除。Apple 与 Windows 的新入口在规范化前拒绝搜索词与标题过滤中的控制
字符；Android 保持既有的规范化后校验，三端规范化后的输入均最多 200 个字符。
搜索词、标题过滤、提供方标识和搜索结果只驻留当前页面或 Workspace 内存，不进入
SavedState、偏好、磁盘或日志；界面须说明搜索词会发送到 NAS 及本次使用的搜索来源，
关闭后清除本地内容。这是公开 BT 搜索的高级查询选项，不等于套件的 BT 协议高级设置。

#### 创建任务

```text
api=SYNO.DownloadStation.Task
version=1
method=create
uri=<HTTP_URL_OR_MAGNET>
destination=<OPTIONAL_SHARED_FOLDER>
```

上传 `.torrent` 或 `.nzb` 时应按官方文档使用 multipart 请求。磁力链接、下载 URL、文件名和 tracker 地址都可能包含隐私，不得写入分析日志。

macOS 客户端同时接受 `.txt` 网址清单并作为官方 `file` 字段上传。`destination` 与 `unzip_password` 放在 multipart 正文中，任务文件保持为最后一个正文部分；解压密码不得进入请求地址或日志。

#### 基础设置

```text
api=SYNO.DownloadStation.Info
version=1
method=getconfig|setserverconfig
```

当前共享契约覆盖默认保存位置、eMule、自动解压，以及 BT、HTTP/FTP、NZB 和 eMule 的速度限制。下载计划通过 `SYNO.DownloadStation.Schedule.getconfig/setconfig` 独立读取和保存。HTTP 与 FTP 在官方接口中共用实际限速配置，客户端以一个“网页与 FTP 下载”字段呈现；所有保存操作完成后必须重新读取并核对结果。

#### 控制任务

```text
api=SYNO.DownloadStation.Task
version=1
method=pause|resume|delete
id=<逗号分隔或按服务器要求编码的任务 ID>
force_complete=false
```

`force_complete` 只适用于删除场景且会改变任务结果，必须由用户明确触发。

官方指南中的 `Task.edit` 只公开 `id` 与 `destination`，用于修改任务目标目录；
`Task_File.priority` 虽然可在列表和详情中读取，但官方写方法没有文件 ID 或优先级参数。
客户端不得把任务级 `priority`、目标目录修改或内部 `DownloadStation2` 参数冒充文件优先级编辑。
Android 正式入口固定使用 v1，并在写前分别复核用户所见任务基线和 File Station 可写目录基线；
提交后以严格完整任务列表核对 `detail.destination`。断线、取消或响应不明确时只能回读，
不得自动重放 `edit`。

#### RSS 站点与条目

`SYNO.DownloadStation.RSS.Site` v1 只公开 `list` 与 `refresh`，
`SYNO.DownloadStation.RSS.Feed` v1 只公开 `list`。Android 可对预检仍存在的单个站点调用
`refresh`，同一站点刷新中防重复，明确成功后重新读取站点与条目；提交断线只报告结果未确认，
不会自动重放。官方指南未公开 RSS 站点新增、修改、删除或下载过滤器写方法，相关入口保持关闭。

### 6.2 项目使用的 `DownloadStation2` - 内部接口

项目 `dev` 分支主要调用以下内部接口：

| API | 源码中观察到的方法 | 用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.DownloadStation2.Task` | `list`, `get`, `create` 以及动态动作方法 | 任务列表、详情、创建和控制 | 高 |
| `SYNO.DownloadStation2.Task.Statistic` | `get` | 速率统计 | 高 |
| `SYNO.DownloadStation2.Settings.Location` | `get` | 下载位置 | 高 |
| `SYNO.DownloadStation2.Task.List` | `get` | 列表初始化 | 高 |
| `SYNO.DownloadStation2.Task.List.Polling` | `download` | 增量轮询 | 高 |
| `SYNO.DownloadStation2.Task.BT.Tracker` | `list`, `add` | Tracker | 高 |
| `SYNO.DownloadStation2.Task.BT.Peer` | `list` | Peer | 高 |
| `SYNO.DownloadStation2.Task.BT.File` | `list` | BT 文件列表 | 高 |

建议原生应用优先实现官方 `SYNO.DownloadStation.*` 适配器。只有当目标套件实际查询到 `DownloadStation2` 且官方接口缺少必要能力时，才启用内部适配器，并将其与官方响应模型隔离。

## 7. Virtual Machine Manager API

### 7.1 官方公开接口

官方 VMM 指南使用 `SYNO.Virtualization.API.*` 命名空间，文档主版本为 1：

| API | methods | 用途 |
| --- | --- | --- |
| `SYNO.Virtualization.API.Task.Info` | `list`, `get`, `clear` | 异步任务 |
| `SYNO.Virtualization.API.Network` | `list` | 网络列表 |
| `SYNO.Virtualization.API.Storage` | `list` | 存储列表 |
| `SYNO.Virtualization.API.Host` | `list` | 主机列表 |
| `SYNO.Virtualization.API.Guest` | `list`, `get`, `set`, `create`, `delete` | 虚拟机生命周期与常规设置 |
| `SYNO.Virtualization.API.Guest.Action` | `poweron`, `poweroff`, `shutdown` | 电源控制 |
| `SYNO.Virtualization.API.Guest.Image` | `list`, `create`, `delete` | 镜像管理 |

创建、镜像导入等明确标记为非阻塞的操作返回任务 ID，应通过 `Task.Info.get` 轮询；公开 `Guest.delete` 与 `Guest.Image.delete` v1 返回空成功响应，不得虚构任务轮询。两类删除都必须通过对应资源列表回读，`Guest.Image.delete` 请求 Fixture 的 `readbackPolicy` 固定为 `required`，不能标成 `taskPoll`。公开 `Guest.set` v1 支持按虚拟机 ID 或名称修改名称、描述、vCPU、内存和自动启动；创建接口的未连接网卡按官方指南使用空 `network_id` 表示。`poweroff` 相当于强制断电，必须与正常 `shutdown` 在 UI 中清楚区分。

Android `Guest.create` 支持总计最多 8 块磁盘，可混合空白盘和既有映像盘，并支持多网卡及空 `network_id` 的未连接网卡。空白盘回读可核对数量和容量；`Guest.get` 的公开返回不包含创建时使用的源映像 ID，因此含映像盘时不得仅凭磁盘数量或容量宣称创建已确认成功，应返回需要刷新核对的结果。

从 NAS 已有文件创建映像使用官方 `SYNO.Virtualization.API.Guest.Image.create` v1，表单参数固定为
`auto_clean_task=false`、JSON 字符串数组 `storage_ids`、官方类型值 `type`（`disk`、`vdsm` 或
`iso`）、NAS 绝对路径 `ds_file_path` 和 `image_name`。Android 在提交前重新读取源文件完整变更基线、
稳定存储标识/名称/状态以及映像名称占用情况，同一名称只允许一个在途提交。`create` 只调用一次；
返回稳定 `task_id` 后使用 `SYNO.Virtualization.API.Task.Info.get` v1 跟踪，断线或取消仅继续回读，
不得重放 `create`。只有任务终态返回稳定 `image_id`，且 `Guest.Image.list` v1 中同一 ID 的名称与
类型均严格匹配，才能确认成功。列表尚未出现该 ID 时继续保持待核对且不清理任务；终态核对完成后
调用 `Task.Info.clear` v1，清理成功后才丢弃客户端保存的任务证据。

Android 任务中心固定先调用 Task.Info v1 `list`，最多接受 100 个唯一任务 ID，
再逐项调用 `get`。界面只展示是否结束及可选进度，列表稳定键由服务端任务标识
单向摘要得到；真实任务标识只在当前 Workspace 内存和请求边界内使用，不展示、
记录或持久化，内部状态、消息和日志正文也不进入领域或界面。

只有当列表中存在已结束任务时才显示清理入口。用户确认数量后，Android 重新执行
`list` 和逐项 `get`；只对用户确认基线中身份仍一致且仍为已结束的目标调用
`Task.Info.clear` v1。无关任务新增或进度变化不会扩大清理范围；目标变为进行中时零写。
任务页可见、VMM 能力可用且存在未结束任务时，Android 每 2 秒仅刷新该 Task.Info 分区；离页、任务全部结束、Repository/NAS 或观察代次变化立即停止。增量读取失败保留上次成功摘要，不把局部故障升级成整个 VMM 页面错误。

Android 本机映像导入先通过 File Station 将系统选择文件无覆盖上传到用户选定暂存目录，再调用公开 `Guest.Image.create`，随后只读跟踪 `Task.Info`、按稳定映像 ID/名称/类型回读、清理任务，最终按上传前后保存的完整文件基线删除临时文件。跨进程恢复记录保存在加密传输存储中；`UPLOAD_SUBMITTING`、缺少 task ID 的 `CREATE_SUBMITTING` 和已提交但未确认的任务清理均不得重放写请求。同资料同映像名的首次记录必须原子判重、插入并领取。
每个 `clear` 只提交一次；提交异常或取消后只严格回读一次、不重放，任务从列表
消失才计为确认清理，未消失目标保留待核对或部分结果。清理基线和结构化结果
可跨 Activity 配置重建保留，但不提供进程死亡或设备重启后的任务标识恢复。
上述映像创建流程持有的单个任务 ID 是写操作恢复证据，不进入任务中心，且只在
终态严格核对后调用 `clear`。Guest v1 `list(additional=true)` 的 `vdisks`/`vnics` 只映射
公开的磁盘容量、控制器、空间回收以及网络名称和型号；MAC 与资源 ID 不进入界面。

### 7.2 项目使用的 VMM 内部接口

项目调用的是另一套不带 `.API` 的命名空间：

| API | 方法 | 观察用途 |
| --- | --- | --- |
| `SYNO.Virtualization.Cluster` | `get` v2 | 集群摘要 |
| `SYNO.Virtualization.Host` | `list`, `get` v2 | 主机列表与详情 |
| `SYNO.Virtualization.Guest` | `list`, `get`, `get_basic`, `set`, `delete` v2 | 虚拟机列表、详情与配置 |
| `SYNO.Virtualization.Guest.Action` | `pwr_ctl`, `reset`, `clone`, `move`, `export`, `check_poweron` v1 | 电源和生命周期动作 |
| `SYNO.Virtualization.Guest.Image` | `list`, `create`, `delete`, `edit` v2 | 镜像管理 |
| `SYNO.Virtualization.Network` | `list`, `get` v2；`set`, `delete` 待专用目标验收 | 虚拟网络读取、修改与删除 |
| `SYNO.Virtualization.Repo` | `list`, `get` v2 | 存储库 |
| `SYNO.Virtualization.GuestProtect.Plan` | `list` / `get` 兼容读取 | 保护计划、计划策略与保留策略 |
| `SYNO.Virtualization.Log` | `list` v1；分页外必须提交 `loglevel`、`filter_content`、`datefrom`、`dateto`、`sort_by=time`、`sort_dir=DESC` | VMM 日志 |

上述读取方法由当前 VMM 官方网页前端静态代码和 `SYNO.API.Info` 交叉确认，但没有执行写操作。网络 `set/delete` 已按网页端具备对应能力接入隔离适配器，具体方法与参数仍必须在专用测试目标拦截核对后才能进入发布兼容范围。它们均应标记为内部接口，不能用官方 `SYNO.Virtualization.API.*` 文档来推断参数，也不能把“方法存在”写成“写操作已通过”。

## 8. 项目源码中的内部与混合接口目录

### 8.1 判定方法

本节的“内部”表示：在本文审阅的群晖公开 PDF 中没有找到相同 API 名称和方法，但在 `dsm_helper` 源码、DSM Web UI 或套件前端中可观察到。它不等于恶意接口，也不等于作者凭空创建；多数是作者观察 DSM 自身请求后进行的客户端复现。

风险等级：

| 等级 | 含义 |
| --- | --- |
| 低 | 只读、容易降级，字段变化影响有限 |
| 中 | 会改配置或依赖套件版本，需要强能力探测 |
| 高 | 管理、删除、关机、安装、远程连接等高影响操作 |

### 8.2 File Station 扩展 - 混合

| API | 方法 | 用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.FileStation.VFS.Connection` | `delete`（未验证） | 候选删除 VFS 连接；客户端保持关闭 | 中 |
| `SYNO.FileStation.Mount` | `mount_remote`, `unmount` | 远程挂载 | 高 |
| `SYNO.FileStation.Property.CompressSize` | `get` | 压缩大小属性 | 低 |
| `SYNO.Entry.Request` | `request`（未验证） | 候选复合批处理；客户端保持关闭 | 中 |

`SYNO.Entry.Request` 的子请求可能分别成功或失败，必须逐项检查结果。不要因为外层 `success=true` 就假定所有修改都完成。

`SYNO.FileStation.VFS.Connection` 和 `SYNO.Entry.Request` 在当前审阅的群晖公开 File
Station 指南中没有稳定契约，版本、参数、响应、权限和副作用均未验证。客户端继续保持
两者关闭，不用它们替代公开的 `VirtualFolder.list` 分协议枚举或 `List.getinfo` 客户端
分块；后续只有完成私有 API 发现记录和专用测试环境验收后才可重新评估。

#### `SYNO.FileStation.Mount` 使用边界

> **内部、实验性契约：** 当前审阅的群晖公开 File Station PDF 未提供 `SYNO.FileStation.Mount` 的稳定参数说明。客户端只在能力发现明确返回 v1 时显示创建、修改和删除远程位置入口，并且仍需在目标 DSM build 上实机验证。

- 创建使用 `mount_remote`，支持 SMB/CIFS 与 NFS；远程地址、目标目录和只读选项随请求提交。
- 修改不是假定存在稳定的 `edit` 方法：目标目录变化时先连接并确认新位置，再断开并确认旧位置；目标不变时明确提示会短暂断开后重连。
- 删除使用 `unmount`，语义仅为断开远程位置，不删除远端文件；提交前必须二次确认。
- SMB 密码只保留在当前表单内存和 HTTPS 请求正文中，不写入配置、日志、URL 或文档。修改连接时需要重新输入。
- 所有写操作必须防止重复提交，并通过公开的 `SYNO.FileStation.List.getinfo` 复查 `mount_point_type`；仅收到内部接口的 `success=true` 不算完成。
- API 未发现、权限不足或结果无法复查时必须关闭入口或给出可恢复提示，不能自动尝试更高权限账号。

### 8.3 系统状态、连接与日志 - 内部

| API | 方法 | 主要参数/用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Core.System` | `info` | 系统与网络信息；源码出现 v1/v3 | 低 |
| `SYNO.Core.System` | `shutdown`, `reboot` | 无业务参数；正常关机与重启 | 关键 |
| `SYNO.Core.System.Utilization` | `get` | `resource`, `type`；CPU、内存、网络等 | 低 |
| `SYNO.Core.System.Process` | `list` | 进程列表；客户端仅接受运行时发现的 v1，并只保留编号、名称、状态和服务组标识 | 中 |
| `SYNO.Core.System.ProcessGroup` | `list`, `service_info` | `list` 作为可失败降级的服务组摘要；`service_info` 参数与隐私边界未验证，保持关闭 | 中 |
| `SYNO.Core.CurrentConnection` | `list`, `download`, `kick_connection` | `list` 使用 `start`、`limit`、`sort_by` 和 `sort_direction` 读取当前连接；`kick_connection` 按网页会话和服务会话分别提交目标；导出未接入 | 高 |
| `SYNO.Core.FileHandle` | `kickable_list`, `export`, `delete_db` | 打开的文件、导出与强制断开 | 高 |
| `SYNO.Core.Service` | `get` | 服务状态 | 低 |
| `SYNO.Core.Service.PortInfo` | `load` | 服务端口 | 低 |
| `SYNO.Core.Desktop.Initdata` | `get` | DSM 桌面初始化数据 | 中 |
| `SYNO.Core.Desktop.SessionData` | `getjs` | 登录阶段的桌面会话数据 | 高 |
| `SYNO.Core.UserSettings` | `apply` | DSM 用户设置 | 中 |
| `SYNO.Core.DSMNotify` | `notify` | DSM 通知 | 中 |
| `SYNO.Core.DSMNotify.Strings` | `get` | 通知文本资源 | 低 |
| `SYNO.Core.SyslogClient.Status` | `latestlog_get` | 最新日志 | 中 |
| `SYNO.Core.SyslogClient.Log` | `list` | 系统日志 | 中 |
| `SYNO.Core.SyslogClient.FileTransfer` | `get`, `get_level`, `set_level` | 文件传输日志开关与级别 | 中 |
| `SYNO.LogCenter.History` | `list` | Log Center 历史 | 中 |
| `SYNO.Core.SecurityScan.Status` | `rule_get`, `system_get` | 仅静态确认名称与方法；组件归属、版本、参数和响应未知，客户端保持关闭 | 中 |

连接、进程、文件句柄和日志可能泄漏用户名、IP、共享路径、文件名与服务信息。客户端只应按需展示，默认禁止遥测上报。

`SYNO.Core.SecurityScan.Status` 当前只完成静态审计。`SYNO.Core.*` 命名不能证明它由 DSM 核心直接提供，也不能排除对“安全顾问”套件的依赖；仓库没有该套件版本、运行时路径、参数或响应证据。`rule_get` 可能包含规则正文或发现详情，`system_get` 也可能包含系统配置、账号、主机、网络、路径或套件信息，因此客户端不注册能力、不调用两个方法，也不把它并入现有自动封锁、DoS 和防火墙设置。

当前 macOS 的“NAS 设置”统一接入以下已核对的只读路径；原“服务与监控”入口已经合并，不再单独运行第二套性能采样：

- `System.info` v3：型号、DSM 版本、运行时间、处理器、内存容量和系统温度。
- `System.Utilization.get` v1：固定发送 `resource=all`、`type=current`；CPU 使用率来自 `user_load + system_load + other_load`，内存来自 `real_usage`，网络使用 `network` 数组中 `device=total` 的 `rx/tx`，磁盘与存储空间速率读取 `disk.total` 和 `space.total`。
- `CurrentConnection.list` v1：分页读取连接账号、来源、位置、协议、时间、设备/进程标识和可断开标记；断开操作使用 `kick_connection` v1，网页会话提交 `http_conn`，其他服务提交 `service_conn`。当前登录账号的连接会显示更强警告，所有断开操作都具备确认、防重复和结果复查。
- `SyslogClient.Log.list` v1：分页读取系统日志及信息、警告、错误计数；Log Center 没有记录时不把空结果误判为加载失败。
- `Upgrade.Server.check` v3：固定发送 `user_reading=true`、`need_auto_smallupdate=true`、`need_promotion=false`，只读取 `update.version` 和可选更新说明。没有 `update` 时才显示“没有发现更新”，不得用 `System.info` 的当前版本伪造检查结果；客户端不下载或安装 DSM 更新。

性能页每 2 秒读取一次当前采样，只在内存中保存最近 120 个点并绘制处理器、内存、网络与存储趋势。用户可暂停更新；离开页面、关闭模块或断开 NAS 后停止读取。刷新期间保留上一次成功结果，不提前显示空状态。原始响应、连接地址和日志正文不写入本地持久化存储。

关机与重启先调用 `System.info` 检查当前会话、权限和 API 可达性，再只发送一次
`shutdown` 或 `reboot`。明确成功只表示 DSM 已接受请求；关机不能据此宣称设备已经
完全断电，重启不能据此宣称设备已经重新上线。提交阶段断线、超时或取消均按结果未知
处理，提示用户检查设备或等待重新连接，禁止自动重放。完整稳定记录见
[`dsm-system-power-actions.md`](discovery/endpoints/dsm-system-power-actions.md)。

### 8.4 存储、硬盘与硬件控制 - 内部

| API | 方法 | 用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Storage.CGI.Storage` | `load_info` | 存储总览 | 低 |
| `SYNO.Storage.CGI.Smart` | `get_health_info` | SMART 健康摘要 | 低 |
| `SYNO.Core.Storage.Volume` | `list` | 存储空间列表 | 低 |
| `SYNO.Core.Storage.Disk` | `disk_test_log_get`, `get_smart_test_log`, `do_smart_test` | SMART 测试与日志 | 中 |
| `SYNO.Core.Hardware.ZRAM` | `get`, `set` | 客户端仅候选接入运行时发现的 v1 `get`，只保留启用状态、明确字节容量与算法白名单；`set` 保持关闭 | 高 |
| `SYNO.Core.Hardware.PowerRecovery` | `get`, `set` | 来电自启 | 高 |
| `SYNO.Core.Hardware.BeepControl` | `get`, `set` | 蜂鸣器 | 中 |
| `SYNO.Core.Hardware.FanSpeed` | `get`, `set` | 风扇模式 | 高 |
| `SYNO.Core.Hardware.Led.Brightness` | `get`, `set` | LED 亮度 | 中 |
| `SYNO.Core.Hardware.Hibernation` | `get`, `set` | 休眠设置 | 中 |
| `SYNO.Core.Hardware.PowerSchedule` | `load`, `save` | 客户端仅候选接入运行时发现的 v1 `load`，最多读取 128 条白名单摘要；`save` 保持关闭 | 高 |
| `SYNO.Core.ExternalDevice.UPS` | `get`, `set` | UPS 设置 | 高 |
| `SYNO.Core.ExternalDevice.Storage.USB` | `list`, `eject` | 客户端仅候选接入运行时发现的 v1 `list`，每类最多读取 64 项白名单摘要；`eject` 保持关闭 | 高 |
| `SYNO.Core.ExternalDevice.Storage.eSATA` | `list` | 客户端仅候选接入运行时发现的 v1 `list`，与 USB 独立降级 | 低 |
| `SYNO.Core.ExternalDevice.Printer.BonjourSharing` | `get` | 仅静态确认名称与方法；版本、参数和响应未知，客户端保持关闭 | 中 |

硬件操作必须使用精确的设备标识并在提交前显示摘要。不要根据数组索引选择硬盘或外接设备。

当前 macOS 已按设备能力接入断电恢复、LED 亮度、风扇模式、设备提示音、外接存储深度休眠、唤醒日志、SATA 深度休眠、休眠时忽略发现流量、闲置自动关机和 UPS 基础安全关机设置。UPS 支持 DSM 返回的 USB、网络从属与 SNMP 三种模式，以及等待时间、低电量策略和关机联动；不猜测未返回的 SNMP v3 密钥或 ACL 字段。只显示 DSM 实际返回的字段，保存后重新读取所有已修改字段。

内存压缩当前使用 `SYNO.Core.Hardware.ZRAM` 候选 v1 `get` 显示只读摘要。2026-08-03 已在官方 DSM 页面只读观察到该设置，但没有捕获对应 API 请求或响应，因此真实版本与字段仍未验证。客户端只接受布尔启用状态、字段名明确为字节的配置容量，以及 `lz4`、`lzo`、`zstd` 算法白名单；单位不明确的容量和其他算法均降级为不可用/未知，`set` 不进入 Repository 或界面。稳定记录见 [`dsm-zram.md`](discovery/endpoints/dsm-zram.md)。

打印机 Bonjour 共享目前只完成静态审计。既有目录仅列出 `SYNO.Core.ExternalDevice.Printer.BonjourSharing.get`，没有版本、路径、参数或响应证据；它不能与文件服务的通用 Bonjour/Avahi 设置混用。客户端不注册该能力、不发送请求，也不推断打印机清单、共享状态或设备字段。稳定记录见 [`dsm-printer-bonjour-sharing.md`](discovery/endpoints/dsm-printer-bonjour-sharing.md)。

当前 macOS 直接从 `Storage.load_info` v1 的 `disks`、`storagePools` 和 `volumes` 读取硬盘、S.M.A.R.T. 摘要、温度、型号、序列号、固件、位置、4Kn、寿命/坏扇区摘要、存储池成员、RAID、文件系统与容量，并在原生详情页按空间、存储池和硬盘分别展示。`Smart.get_health_info` 必须携带精确的 `device`，缺少硬盘参数时返回 `114`；`Storage.Volume.list` 在当前目标返回 `101`，因此客户端不会用失败接口覆盖 `load_info` 已返回的数据。

S.M.A.R.T. 检测使用能力发现返回的 `SYNO.Core.Storage.Disk` v1。`Storage.load_info` 返回的列表稳定标识 `id` 只用于界面选择，所有检测请求必须使用同一硬盘的 `device`，不得把两者混用。当前状态调用 `get_smart_test_log(device)` 并读取 `testInfo[0]` 的 `testing`、`remain`、`ihm_testing`、`perf_testing` 和 `latest_test_result`；历史记录另行调用 `disk_test_log_get(device,type=smart,sort_by=time,sort_direction=DESC)`，从 `testLog` 的 `test_type=quick/extend` 分别选择最近记录。历史读取失败必须显示可重试错误，不能伪装成“暂无记录”。

启动调用 `do_smart_test(device,type)`，快速检测的 `type=quick`，完整检测的 `type=extend`；停止正在运行的检测使用同一方法且 `type=stop`。开始和停止前都读取当前状态；`ihm_testing` 或 `perf_testing` 表示其他检测正在占用硬盘，此时不得提交 S.M.A.R.T. 写请求。界面再次确认影响，同一硬盘防重复提交，提交后最多等待 5 秒并重复读取状态，分别确认 `testing=true/false`，运行期间每 4 秒刷新状态和历史。当前不会为验证而在真实硬盘上自动启动或停止测试；修复、擦除和存储配置修改仍未接入。

### 8.5 终端、套件与计划任务 - 内部

| API | 方法 | 主要参数/用途 | 风险 |
| --- | --- | --- | --- |
| `SYNO.Core.Terminal` | `get`, `set` | `enable_ssh`, `enable_telnet`, `ssh_port` | 高 |
| `SYNO.Core.TrustDevice` | `delete`, `logout` | 删除可信设备或退出会话 | 高 |
| `SYNO.Core.Package` | `list`, `get`, `feasibility_check` | 套件与可行性检查 | 中 |
| `SYNO.Core.Package.Info` | `get` | 套件详情 | 低 |
| `SYNO.Core.Package.Server` | `list` | 套件源 | 中 |
| `SYNO.Core.Package.Thumb` | `get` | 已安装套件图标；`name`、`ver`、`size` | 中 |
| `SYNO.Core.Package.Control` | `start`, `stop` | 启停套件 | 高 |
| `SYNO.Core.Package.Installation` | `install`, `status`, `get_queue`, `cancel` | 安装队列 | 高 |
| `SYNO.Core.Package.Uninstallation` | `uninstall` | 卸载套件 | 高 |
| `SYNO.Core.TaskScheduler` | `list`, `run`, `delete`, `set_enable`, `view`, `result_list`, `result_get_file` | 计划任务及结果 | 高 |
| `SYNO.Core.EventScheduler` | `run`, `delete`, `set_enable`, `result_list`, `result_get_file` | 事件计划任务 | 高 |
| `SYNO.Core.Upgrade.Server` | `check` | DSM 更新检查；客户端使用 v3，只读参数为 `user_reading=true`、`need_auto_smallupdate=true`、`need_promotion=false` | 中 |

套件安装 URL、计划任务脚本和任务结果都可能包含秘密。源码中存在直接安装/执行能力，不应在普通功能页静默触发。系统更新当前只读取 `System.info` 与 `Upgrade.Server.check`；候选版本为空或与当前版本相同时不宣告更新，下载、安装、取消和重启任务没有稳定契约，保持关闭。

当前 macOS 与 Android 使用 `Package.list` v2，并请求 `status`、`description`、`install_type`、`startable`、`dsm_apps`、`available_operation` 和 `ctl_uninstall` 附加字段，展示真实套件名称、版本、状态与说明。两端套件图标使用 `Package.Thumb.get` v1 读取，认证信息只放在 Cookie 与请求头，不写入图片 URL；Android 另以 2 MiB 流式上限、PNG/JPEG/GIF/WebP 签名和 Bitmap 解码约束响应，只在内存保留 4 MiB LRU，失败时使用本地通用图标。

`available_operation` 明确包含 `upgrade` 时，macOS 与 Android 只显示“DSM 中有可用更新”的只读
提示，`canUpgrade` 仍保持关闭。`Package.Server.list` 和
`Package.Installation.install/status/get_queue/cancel` 目前只有静态方法目录，没有
版本化来源、参数、队列响应、取消和最终版本回读证据，客户端不探测也不调用。

启动与暂停每次都先重新调用 `Package.list` v2，按稳定套件 ID 核对目标仍存在且
`canStart/canStop` 与当前状态一致，再调用 `Package.feasibility_check` v2 和
`Package.Control.start/stop` v1。同一套件 ID 的启动、停止与卸载在 Repository 和
macOS 模型两层防重复；界面提交前说明影响并确认，执行中显示进度且禁用重复操作。
写请求明确成功后最多轮询列表十次；提交超时、断线或响应无效时只读取列表核对，不重放
原写请求。只有列表确认目标达到运行或停止状态才显示完成，无法确认时要求先刷新，确认
前不得再次执行同一动作。卸载继续使用独立的破坏性结果链路，先检查可行性和系统套件
限制，再调用 `Package.Uninstallation.uninstall` v1。当前 DSM 7.2.1-69057 Update 12
的能力发现与官方网页前端静态请求已核对，但本轮没有为验证而启动、停止或卸载真实套件；
发布兼容结论仍需使用专用测试套件完成管理员、普通账号、依赖阻止、超时和 QuickConnect
场景的行为验收。安装和升级需要来源、空间、依赖与安装队列流程，当前保持关闭。

计划任务列表继续使用 `TaskScheduler.list` v3 的 `start/limit` 分页字段；详情、新建和修改按 DSM 前端契约使用 `get/create/set` v4，运行、启停和删除使用 v3。运行记录使用 `EventScheduler.result_list(task_name)` v1，选择记录后再调用 `result_get_file(task_name,result_id)` v1 读取执行内容和输出；结果只保留在当前窗口内，不写入磁盘或日志。客户端必须按方法选择版本，不能把整个 API 一律升级到 v4。脚本任务界面具备详情、创建、修改、启停、立即运行、删除和运行记录入口，危险动作均要求确认并防止重复提交；脚本内容和通知地址只在当前请求中使用，不写入日志。

### 8.6 用户、群组、共享与配额 - 内部

| API | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Core.User` | `list`, `get`, `create`, `set`, `delete` | 高 |
| `SYNO.Core.Group` | `list`, `create`, `set`, `delete` | 高 |
| `SYNO.Core.Group.Member` | `add`, `remove` | 高 |
| `SYNO.Core.NormalUser` | `get`, `set` | 高 |
| `SYNO.Core.User.PasswordExpiry` | `get` | 中 |
| `SYNO.Core.Share.Permission` | `list_by_user` | 中 |
| `SYNO.Core.Quota` | `get` | 中 |
| `SYNO.Core.PersonalSettings` | 配额相关调用 | 中 |
| `SYNO.Core.OTP`, `SYNO.Core.OTP.Admin` | OTP 与管理员设置 | 高 |
| `SYNO.Core.Share` | `list`, `get`, `add`, `set`, `delete`, `get_all_move_task`, `move_status` | 高 |
| `SYNO.Core.RecycleBin` | `start`（清理回收站） | 高 |

当前 macOS 使用 `User.list` 与 `Group.list` 展示当前账号有权查看的账号、群组、说明、邮件地址、停用状态和数字标识，并分别保留账号与群组结果。账号与群组的新建、修改和删除已接入专用接口，密码只用于当次请求，所有删除均确认、防重复并回读。共享访问页面只使用公开 `SYNO.FileStation.List.list_share` 展示登录账号可见共享文件夹的有效读写权限；不可见条目不推断为拒绝访问，内部 `Share.Permission.list_by_user` 因缺少版本化参数与响应证据保持关闭。共享文件夹的加密、权限、WORM、配额、移动和删除存在相互依赖；在完成 `validate_set`、权限复合提交与移动任务轮询前不提供不完整写入口。

这些接口涉及账号、权限与数据删除。原生客户端应要求重新确认，并只发送用户改变的字段，避免把完整对象回写导致覆盖新设置。

### 8.7 网络、文件服务与 DDNS - 内部

| API 组 | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Core.Network` | `get`；网络总览 | 中 |
| `SYNO.Core.Network.Ethernet` | `list`, `get`, `set`；网卡 | 高 |
| `SYNO.Core.Network.PPPoE` | `list`；PPPoE | 高 |
| `SYNO.Core.Network.Proxy` | `get`, `set`；`enable`, `http_host`, `http_port` | 中 |
| `SYNO.Core.BandwidthControl` | `get`；账号带宽规则 | 中 |
| `SYNO.Core.Web.DSM` | `get`, `set`；DSM HTTP/HTTPS、门户与局域网发现设置 | 中 |
| `SYNO.Core.FileServ.SMB` | `get`, `set`；`enable_samba` | 中 |
| `SYNO.Core.FileServ.FTP` | `get`, `set`；`enable_ftp`, `enable_ftps`, `portnum` | 中 |
| `SYNO.Core.FileServ.FTP.SFTP` | `get`, `set`；`enable`, `portnum` | 中 |
| `SYNO.Core.FileServ.NFS` | `get`, `set`；`enable_nfs` | 中 |
| `SYNO.Core.FileServ.AFP` | `get`；AFP 设置 | 中 |
| `SYNO.Core.FileServ.ReflinkCopy` | `get`；写时复制能力 | 低 |
| `SYNO.Core.FileServ.ServiceDiscovery` | `get`, `set`；服务发现与 SMB Time Machine | 中 |
| `SYNO.Core.ACL` | `get_bypass_traverse` | 中 |
| `SYNO.Core.Security.Firewall` | `get`, `set`；防火墙状态 | 高 |
| `SYNO.Core.Security.Firewall.Conf` | `get`, `set`；端口扫描防护 | 高 |
| `SYNO.Core.Security.Firewall.Profile.Apply` | `start`, `status`, `stop`；应用当前配置 | 高 |
| `SYNO.Core.Security.Firewall.Rules.Serv` | `policy_check` | 中 |
| `SYNO.Backup.Service.NetworkBackup` | `get` | 中 |
| `SYNO.Core.DDNS.Provider` | `list` | 低 |
| `SYNO.Core.DDNS.Record` | `list`, `test`, `create`, `set`, `update_ip_address`, `delete` | 高 |
| `SYNO.Core.DDNS.ExtIP` | `list` | 中 |
| `SYNO.Core.DDNS.Synology` | `get_myds_account` | 高 |
| `SYNO.Core.QuickConnect` | `get` v2、`set` v2、`check_availability` v3、`get_misc_config` v3、`set_server_alias` v2、`status` v1 | 高 |
| `SYNO.Core.QuickConnect.Permission` | `get` v1 | 中 |
| `SYNO.Core.QuickConnect.Hostname` | `get_ip` v1 | 中 |

网络与 DDNS 响应可能包含公网 IP、域名、账号和代理配置。抓包样本必须删除这些字段后才能共享。

当前 macOS 已将 SMB、NFS、FTP/FTPS、SFTP、互联网代理、物理网卡、DDNS 和防火墙基础控制加入运行时能力发现。物理网卡编辑支持 DHCP/静态 IPv4、网关、DNS、默认网关、MTU 与 VLAN；提交前明确提示可能断开当前连接，提交时只发送目标网卡 `configs`，随后按 `ifname` 回读。DDNS 将服务商连接测试、记录新建/编辑、立即更新和删除拆为四个独立操作；密码/密钥仅用于当次测试或保存请求，保存和删除后重新列出记录核对，测试成功不代表已经保存，立即更新被接受也不代表公网 DNS 已完成传播。防火墙支持启停当前配置和端口扫描防护；启用通过 `Profile.Apply` 任务轮询，失败或超时不报告成功。完整防火墙规则编辑仍需服务端口、网卡策略、配置保存和应用任务组成原子流程，当前不提供半成品入口。

局域网服务发现同时接入 `SYNO.Core.Web.DSM` v2 的 `enable_ssdp`、`enable_avahi` 与 `SYNO.Core.FileServ.ServiceDiscovery` v1 的 `enable_smb_time_machine`，按实际变化分别提交并回读。

### 8.7.1 区域与时间 - 内部

`SYNO.Core.Region.NTP` 使用 v3 `get/set` 读取和保存日期格式、时间格式、时区、手动时间或网络校时方式；时区选项使用 v1 `listzone` 的真实 `zonedata`。客户端先保存并逐字段回读配置，只有网络校时模式或最多三个服务器发生变化且配置完整确认后，才调用 v2 `sync(servers)` 立即校时并再次回读配置。`sync` 成功只证明 DSM 接受请求且设置仍被保留，不证明 NAS 时钟已经达到权威时间精度。手动改时要求高风险确认；用户没有编辑时间时使用本次预检刚从 NAS 读取的值，不使用 Mac 当前时间或页面打开时的旧值。提交超时、断线或取消均不得自动重放。

### 8.7.2 DDNS - 内部

`SYNO.Core.DDNS.Provider` 与 `SYNO.Core.DDNS.Record` 使用 v1。连接测试只调用 `test`；
保存只调用 `create` 或 `set` 并按服务商、主机名、账号、启用状态和心跳设置回读；
立即更新调用 `update_ip_address` 后只确认 DSM 接受请求且记录列表可重新载入；删除调用
`delete` 后确认目标记录消失。保存或删除超时后仅允许一次列表回读，能够确认目标状态
时不重放请求，无法确认时提示用户重新读取。完整稳定记录见
[`dsm-ddns-settings.md`](discovery/endpoints/dsm-ddns-settings.md)。

### 8.8 Container Manager/Docker - 内部

| API | 观察到的方法 | 风险 |
| --- | --- | --- |
| `SYNO.Docker.Container` | `list`, `get`, `create`, `set`, `start`, `restart`, `stop`, `signal`, `delete`, `stats`, `get_process` | 高 |
| `SYNO.Docker.Container.Resource` | `get` | 低 |
| `SYNO.Docker.Container.Log` | `get`, `export` | 高 |
| `SYNO.Docker.Image` | `list`, `get`, `import`, `upload`, `export`, `delete`, `prune`, `pull`, `upgrade` | 高 |
| `SYNO.Docker.Registry` | `search`, `tags`, `get`, `create`, `set`, `delete`, `using` | 中 |
| `SYNO.Docker.Network` | `list`, `list_container`, `create`, `set`, `remove` | 高 |
| `SYNO.Docker.Project` | `list`, `get`, `create`, `update`, `delete`, `log`, `get_share_info` | 高 |
| `SYNO.Docker.Log` | `list` | 高 |

这些名称由当前 Container Manager 官方网页前端和能力清单确认；本轮只查看概览与列表，没有控制容器或读取环境变量、挂载路径和日志。套件升级时名称、字段和流式日志方式很容易改变。容器环境变量、挂载路径、Registry 凭据和日志应视为秘密。

### 8.9 Synology Photos - 内部

| API 组 | 观察到的方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.Foto.Browse.Album` / `SYNO.FotoTeam.Browse.Album` | 相册列表与详情 | 中 |
| `SYNO.Foto.Browse.Folder` / Team 变体 | 文件夹浏览 | 中 |
| `SYNO.Foto.Browse.Item` / Team 变体 | 照片项目列表 | 中 |
| `SYNO.Foto.Browse.Timeline` / Team 变体 | 时间线 | 中 |
| `SYNO.Foto.Browse.RecentlyAdded` / Team 变体 | 最近添加 | 中 |
| `SYNO.Foto.Browse.GeneralTag` / Team 变体 | 标签 | 高 |
| `SYNO.Foto.Browse.Geocoding` / Team 变体 | 地理位置聚合 | 高 |
| `SYNO.Foto.Thumbnail` / Team 变体 | 缩略图二进制 | 中 |
| `SYNO.Foto.Download` / Team 变体 | 原图下载 | 高 |

源码还包含 DSM 6 时代 Moments/Photo 相关变体，应按产品版本拆分适配。特别注意：项目中部分缩略图和下载 URL 把 `_sid` 拼在查询串中；新应用不要照搬，应使用带认证的请求数据源，避免 SID 出现在日志、历史或第三方播放器中。

### 8.10 Synology Chat - 内部

当前 Chat Server 官方网页客户端与 `SYNO.API.Info` 交叉确认以下契约。它们都不是公开的第三方普通用户聊天 API；公开的 `SYNO.Chat.External` 不能替代这些用户会话接口。

| API | 版本/方法 | 已确认参数或用途 |
| --- | --- | --- |
| `SYNO.Chat.Channel.Anonymous` | v2 `initiate` | `user_ids`, `encrypted`, `channel_key_encs`；首次一对一会话 |
| `SYNO.Chat.Channel.Named` | v1 `create`, `join`, `invite` | 私人群聊 |
| `SYNO.Chat.Post` | v5 `create` | 文字或 multipart `file` 附件 |
| `SYNO.Chat.Post.File` | v2 `get`, `thumbnail` | `get(post_id)`；`thumbnail(post_id,type)` |
| `SYNO.Chat.Post.Reminder` | v1 `set`, `list`, `delete`, `get` | `set(post_id,remind_at)`；`list(channel_id)`；`delete(post_id)` |
| `SYNO.Chat.Post.Schedule` | v1 `create`, `set`, `list`, `delete` | `list(channel_id)`；创建使用 `channel_id`, `message`, `send_at`；修改/删除使用 `cronjob_id` |
| `SYNO.Chat.Channel.Member` | v1 `get` | `channel_id`；返回 `user_ids` 与 `broken_user_ids` |
| `SYNO.Chat.Post` 消息转发 | v5 `forward` | `post_id`, `channel_ids`；由 NAS 直接转发原消息及附件 |
| `SYNO.Chat.Post` 群公告 | v5 `pin`, `unpin`, `search` | 写入使用 `post_id`；公告列表使用 `channel_id`, `has=["pin"]`, `sort_by=last_pin_at` |
| `SYNO.Chat.Post.Vote` | v1 `create`, `close`, `delete`, `set`, `get_choices`, `vote`, `create_option` | 创建时使用 `channel_id`, `message`, `choices`, `options`；`options` 含 `multiple`, `anonymous`, `add_option` 和可选 `expire_at` |

官方网页客户端的实时同步使用当前源站下的 Socket.IO 路径 `sc/socket.io`，初始化后取得连接标识，处理消息创建/更新/删除、频道加入/关闭、输入状态和用户更新等事件。认证字段属于秘密，不得写入本文、日志或 URL 遥测。岚仓 macOS 端已接入同源 WebSocket、Engine.IO 4/3 协商、心跳响应和指数退避重连；内部事件只触发会话与消息 API 回读，不解析或记录事件正文。连接未建立时每 5 秒同步，连接建立后每 30 秒校准一次，真实 DSM 与 Chat Server 版本兼容性仍需实机验证。

群晖官方帮助确认频道和会话支持 Star，并会显示在官方客户端的 Starred 区域，但当前公开 WebAPI 文档没有提供对应写入契约。岚仓目前只做按 NAS 配置隔离的本地会话置顶；取得脱敏请求、能力名称、版本、参数和结果复查方式前，不猜测调用内部写接口。

直接会话还存在 `encrypted` 与 `channel_key_encs`，官方前端包含密钥处理代码；这只证明加密能力存在，不足以安全复现密钥生成、恢复、轮换和设备撤销，因此保持关闭。网页端可播放音频附件，但没有确认独立的录音消息创建契约。

### 8.11 其他内部接口

| API | 方法/用途 | 风险 |
| --- | --- | --- |
| `SYNO.SynologyDrive.Index` | `get_native_client_status` | 低 |
| `SYNO.Core.MediaIndexing` | `reindex`, `status` | 中 |
| `SYNO.Core.MediaIndexing.ThumbnailQuality` | `get`, `set` | 中 |
| `SYNO.Core.MediaIndexing.MobileEnabled` | `get`, `set` | 中 |
| `SYNO.Core.MediaIndexing.MediaConverter` | `status` 及动态转换动作 | 中 |

### 8.12 内部接口的调用规则

每个内部 API 必须满足以下条件才能启用：

1. `SYNO.API.Info` 能查询到该 API。
2. 客户端选择 `maxVersion` 与已验证上限的较小值，不能盲目固定源码中的版本。
3. 套件已安装且运行，当前账号权限足够。
4. 对当前 DSM build/套件版本存在已通过的契约测试样本。
5. 接口失败时有明确降级，不自动切换成管理员账号。
6. 写操作有用户确认、幂等保护和审计摘要。

建议为内部适配器使用 feature flag，例如：

```json
{
  "feature": "container.list",
  "api": "SYNO.Docker.Container",
  "verifiedBuilds": ["DSM-7.2.2-72806"],
  "packageRange": "ContainerManager 24.x",
  "enabled": false
}
```

默认值应为关闭，动态探测和本地验证成功后才开启。

## 9. 合法合规的抓包与接口复现流程

只抓取自己拥有或已获得明确授权的 NAS、账号和测试设备。不要抓取他人的会话，不要尝试绕过访问控制，也不要把含秘密的 HAR/PCAP 上传到公共 Issue。

### 9.1 优先方案：浏览器开发者工具

用于观察 DSM Web UI 自己发出的请求，通常不需要中间人证书：

1. 新建专用普通测试账号，给最小权限，并准备无敏感内容的测试共享文件夹。
2. 在独立浏览器配置文件中登录 DSM。
3. 打开开发者工具的 Network，开启 Preserve log，筛选 `webapi`、`entry.cgi`、`query.cgi`。
4. 清空现有记录，只执行一个动作，例如“列出目录”或“暂停测试下载任务”。
5. 记录请求路径、HTTP 方法、Content-Type、`api`、`version`、`method`、业务参数和响应结构。
6. 比较操作前后两次请求，区分初始化请求、轮询请求和真正的写操作。
7. 导出 HAR 前先离线脱敏；更安全的做法是只人工复制所需字段。
8. 完成后退出 DSM、清除浏览器站点数据并删除测试账号或撤销权限。

### 9.2 原生客户端抓包

可使用 Charles、Proxyman 或 mitmproxy，流程相同：

1. 只在隔离测试网络和测试设备上配置 HTTP(S) 代理。
2. 只在测试设备中安装代理 CA；不要安装到生产设备或组织根证书库。
3. 将测试 NAS 主机加入抓取范围，排除其他域名以减少无关隐私。
4. 启动记录后只执行单一动作，立即停止记录。
5. 对照客户端日志中的本地请求 ID，但日志中不得含 SID、密码或响应正文。
6. 导出前按 9.4 的规则脱敏，验证文件中搜索不到秘密。
7. 删除代理 CA、关闭代理、退出会话并删除原始捕获文件。

如果系统或应用启用了证书固定，不要为了抓包在生产构建中关闭 TLS 校验。应使用专门的 Debug 构建，通过受控的调试网络安全配置允许测试 CA，Release 构建保持严格验证。

### 9.3 从单次动作还原 API 契约

对每个功能保留一份脱敏记录：

```yaml
feature: file.list
source: dsm-web-ui
dsm_build: 7.2.2-72806
package: FileStation
package_version: <已脱敏或实际版本>
request:
  path: entry.cgi
  content_type: application/x-www-form-urlencoded
  api: SYNO.FileStation.List
  version: 2
  method: list
  parameters:
    folder_path: /test-share
    offset: 0
    limit: 100
response:
  success: true
  required_fields:
    - data.files
    - data.offset
    - data.total
notes:
  - folder_path 需 URL 编码
```

复现顺序：

1. 先用 `SYNO.API.Info` 验证名称、路径和版本。
2. 用普通测试账号登录并获取独立 SID。
3. 用命令行或最小测试客户端重放一次只读请求。
4. 刻意测试无权限、会话过期、空结果、分页和未知字段。
5. 写操作只作用于可丢弃的测试对象，并先验证读取接口。
6. 将稳定字段设为必需，将版本相关字段设为可选。
7. 在两种 DSM/套件版本上复测后，才能标记为“已验证”。

### 9.4 必须脱敏的字段

| 类型 | 典型字段/内容 | 替换值 |
| --- | --- | --- |
| 凭据 | `account`, `passwd`, `otp_code` | `<REDACTED_CREDENTIAL>` |
| 会话 | `_sid`, `sid`, `SynoToken`, `did`, Cookie | `<REDACTED_SESSION>` |
| 网络身份 | NAS 域名、公网/内网 IP、QuickConnect ID、MAC | `<REDACTED_HOST>` |
| 用户隐私 | 用户名、邮箱、头像、相册、人脸、标签、地理位置 | `<REDACTED_PERSONAL>` |
| 文件数据 | 路径、文件名、共享链接、下载 URL、磁力链接 | `<REDACTED_PATH>` |
| 容器/系统 | 环境变量、Registry 凭据、日志、任务脚本 | `<REDACTED_SECRET>` |
| 设备信息 | 序列号、硬盘序列号、设备 ID | `<REDACTED_DEVICE>` |

脱敏完成后，应再次全文搜索：`sid`、`token`、`cookie`、`passwd`、`Authorization`、NAS 域名、用户名和常见共享目录名。仅把脱敏后的最小样本提交版本库。

## 10. 原生客户端实现建议

### 10.1 分层结构

```text
UI / ViewModel
    -> 业务 Repository
        -> 官方 API Adapter / 内部 API Adapter
            -> 能力发现与版本选择
                -> HTTP、TLS、会话与统一编码层
```

- 官方和内部接口使用不同 Adapter，不共享具体响应 DTO。
- HTTP 层统一负责表单/JSON 参数编码、SID 注入、SynoToken、超时和错误信封。
- Repository 只暴露业务语义，例如 `listFiles()`，不让 UI 接触 API 名称。
- 未知 JSON 字段应忽略；关键字段缺失要产生可诊断但不含隐私的错误。
- 二进制下载/缩略图不经过 JSON 解码器。

### 10.2 版本选择算法

```text
server = SYNO.API.Info 返回的能力
client = 客户端已实现并测试的版本范围
selected = min(server.maxVersion, client.maxVersion)

只有 selected >= max(server.minVersion, client.minVersion) 时才可调用
```

不要总是选择服务器最高版本。如果客户端只实现了 v2，而服务器最高为 v3，应使用 v2。

### 10.3 Swift `URLSession` 最小调用器

```swift
import Foundation

struct DsmEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: DsmError?
}

struct DsmError: Decodable, Error {
    let code: Int
}

final class DsmClient {
    private let baseURL: URL
    private let session: URLSession
    private var sid: String?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setSessionId(_ sid: String?) {
        self.sid = sid
    }

    func call<T: Decodable>(
        path: String,
        api: String,
        version: Int,
        method: String,
        parameters: [String: String] = [:],
        responseType: T.Type
    ) async throws -> T {
        let url = baseURL.appending(path: "webapi/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        var fields = parameters
        fields["api"] = api
        fields["version"] = String(version)
        fields["method"] = method
        if let sid { fields["_sid"] = sid }
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let envelope = try JSONDecoder().decode(DsmEnvelope<T>.self, from: data)
        if let error = envelope.error { throw error }
        guard envelope.success, let value = envelope.data else {
            throw URLError(.cannotParseResponse)
        }
        return value
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
```

生产实现还需补充：Keychain、信任策略、证书变化提示、超时、取消、上传/下载流、重认证互斥锁和错误码映射。不要在自定义 `URLProtocol` 或日志拦截器中输出请求体。

### 10.4 Android Kotlin/OkHttp 最小调用器

```kotlin
import kotlinx.serialization.json.Json
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request

class DsmClient(
    private val baseUrl: String,
    private val http: OkHttpClient,
    private val json: Json,
) {
    @Volatile
    private var sid: String? = null

    fun setSessionId(value: String?) {
        sid = value
    }

    fun call(
        path: String,
        api: String,
        version: Int,
        method: String,
        parameters: Map<String, String> = emptyMap(),
    ): String {
        val form = FormBody.Builder().apply {
            add("api", api)
            add("version", version.toString())
            add("method", method)
            sid?.let { add("_sid", it) }
            parameters.forEach { (key, value) -> add(key, value) }
        }.build()

        val request = Request.Builder()
            .url("${baseUrl.trimEnd('/')}/webapi/$path")
            .post(form)
            .build()

        http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "DSM HTTP 错误：${response.code}" }
            return requireNotNull(response.body).string()
        }
    }
}
```

Android 生产实现应使用协程/异步封装，SID 存在 Keystore 保护的存储中，Release 构建禁用明文流量和会泄密的网络日志拦截器。示例中的 `json` 用于实际项目解码统一响应，最小片段未展开 DTO。

### 10.5 登录状态机

```text
未认证
  -> 查询 Auth 能力
  -> 提交账号和密码
  -> 若 403/406：请求 OTP
  -> 若 409/410：引导用户在 DSM 官方界面修改密码
  -> 保存 SID/SynoToken
  -> 已认证
  -> 106/107/119：只允许一次受控重登录
  -> 退出：服务端 logout + 无条件清理本地秘密
```

不要在收到任意业务错误时自动重登，否则可能造成密码重试、账号锁定或重复写操作。

## 11. 安全与隐私基线

### 11.1 传输安全

- 默认仅允许 HTTPS；不要给用户一个长期有效的“忽略所有证书错误”开关。
- 自签名证书首次信任应显示主机名、SHA-256 指纹并要求明确确认；证书变化再次告警。
- 不在公网直接暴露 DSM 管理端口；优先使用受信任 VPN 或用户已配置的安全访问方式。
- 正确设置连接、读取和总体超时；写操作超时后先查询状态，不盲目重复提交。

### 11.2 最小权限

- 日常文件浏览使用独立普通账号，只授予需要的共享目录权限。
- 管理、套件、用户、终端和硬件控制功能与文件功能分离。
- UI 中显示当前账号及目标 NAS，危险操作要求再次确认目标。
- 不在应用内自动关闭 DSM 安全选项或降低防火墙策略。

### 11.3 日志与崩溃报告

允许记录：本地 request ID、API 分类、耗时、HTTP 状态、DSM 错误码、重试次数。

禁止记录：URL 查询串、完整请求体、完整响应体、Header、账号、SID、令牌、路径、文件名、相册、容器日志及系统日志。

建议日志样式：

```text
requestId=6F1C apiClass=FileList durationMs=184 http=200 dsmCode=0
```

### 11.4 项目源码中应避免照搬的做法

静态审阅发现项目若干调用会把 `_sid` 拼接到下载或缩略图 URL。URL 容易进入访问日志、播放器日志、崩溃报告和缓存键，因此新应用应改为认证请求数据源。

此外，项目大量硬编码 API 版本或手工为 JSON 参数加引号。新实现应以能力发现结果为准，并用统一编码器处理参数，避免版本或转义差异造成错误。

## 12. 开发优先级与兼容策略

推荐分三期实现：

| 阶段 | 范围 | 发布条件 |
| --- | --- | --- |
| 第一阶段 | 登录、能力发现、File Station 官方 API | DSM 6/7 各至少一个版本通过测试 |
| 第二阶段 | 官方 Download Station、官方 VMM | 对应套件存在时按能力开启 |
| 第三阶段 | Photos、Container、系统管理等内部 API | 每个 DSM build/套件版本有契约测试和降级 |

对于“基于 dsm_helper 继续开发还是独立开发”的决定：可以把该项目用作接口行为和 UI 功能参考，但原生客户端的网络层、数据模型、安全存储和平台 UI 应独立实现。不要逐行移植 Flutter/Dart 网络代码，也不要默认继承项目中对内部接口稳定性的假设。

## 13. 验证清单

### 13.1 每台 NAS 首次连接

- [ ] 验证 HTTPS 证书或完成可审计的首次信任。
- [ ] 查询 `SYNO.API.Auth` 与所需业务 API。
- [ ] 记录 DSM build 和套件版本，但不记录设备序列号。
- [ ] 使用普通账号验证最小权限。
- [ ] 缓存 `path`、版本范围和 `requestFormat`。

### 13.2 每个 API 适配器

- [ ] 成功、无权限、API 不存在、版本不支持和会话超时测试。
- [ ] 空列表、分页、非 ASCII 名称、特殊字符路径测试。
- [ ] 未知字段、字段缺失和数字范围测试。
- [ ] 取消、超时和重复提交测试。
- [ ] 日志与崩溃样本全文检索确认无秘密。
- [ ] 内部接口验证 DSM build 与套件版本，不匹配时自动关闭。

### 13.3 发布前

- [ ] Release 构建不信任调试代理 CA，不允许明文 HTTP。
- [ ] 密码默认只在认证请求期间存在于内存；只有用户明确选择“记住密码”时才进入平台系统安全存储，且不得写入普通配置或日志。
- [ ] SID、DID、SynoToken 使用系统安全存储。
- [ ] 登出和删除 NAS 配置会清理所有秘密与缓存。
- [ ] 危险写操作都有确认和明确的目标摘要。
- [ ] 没有把 HAR、PCAP、真实响应或测试账号提交到仓库。

## 14. 源码证据索引

本节便于后续追踪项目实现；行号可能随分支变化，链接固定到 `dev` 分支目录：

| 功能 | 项目位置 |
| --- | --- |
| 集中式 API 与旧实现 | [`lib/utils/api.dart`](https://gitee.com/apaipai/dsm_helper/blob/dev/lib/utils/api.dart) |
| DSM 模型化接口 | [`lib/models/Syno`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno) |
| Docker/Container | [`lib/models/Syno/Docker`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Docker) |
| 系统控制 | [`lib/models/Syno/Core`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Core) |
| VMM | [`lib/models/Syno/Virtualization`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/Syno/Virtualization) |
| Photos | [`lib/models/photos`](https://gitee.com/apaipai/dsm_helper/tree/dev/lib/models/photos) |

## 15. 结论

- “官方公开 API”主要包括认证与能力查询、File Station、旧 `SYNO.DownloadStation.*` 以及 `SYNO.Virtualization.API.*`。
- 项目大量功能依赖 DSM Web UI/套件内部接口；这些接口大多是通过观察请求、源码样本和实际响应摸索出来的，不受公开文档兼容承诺保护。
- 原生应用可以使用内部接口，但应把它们视为可选插件能力：运行时探测、按版本验证、默认关闭、失败可降级。
- 最稳妥的开发起点是独立实现安全的原生网络层，先覆盖官方 API，再按实际需求逐个加入经过抓包与契约测试的内部适配器。
