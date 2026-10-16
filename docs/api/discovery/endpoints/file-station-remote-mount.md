# File Station 远程挂载内部接口

## 标识

| 字段 | 值 |
| --- | --- |
| 端点组 / 组件 | `file-station-remote-mount` / `file-station` |
| 范围 / 能力 | File Station；SMB/NFS 连接、重连和断开 |
| 分类 / 操作 / 风险 | internal / mixed / high |

## 请求契约

来源：[2026-09-20 只读核查](../environments/INDEX.md#2026-09-20-remote-mount-read-observation)。
当前环境 DSM 7.2.1-69057 Update 12、File Station 1.4.1-1559，设备待归属。
Mount 和 Mount.List 都由 API.Info 发现 entry.cgi、JSON、v1；通过 DSM 会话认证，
不记录凭据值、不将远程凭据放 URL。发送形态为 POST 表单内按声明编码参数。

| API / 方法 | 已确认参数形态 | 等级 |
| --- | --- | --- |
| SYNO.FileStation.Mount / mount_remote | mount_type:CIFS/NFS、server_ip、mount_point、user_set:bool、auto_mount:bool | static |
| CIFS 专用 | account、passwd | static |
| NFS 专用 | nfs_version:3/4 字符串、protocol:tcp/udp；默认 3/tcp，v4 固定 tcp | static |
| SYNO.FileStation.Mount.List / get | 无业务参数 | read-verified（空列表） |
| Mount.List / unmount、reconnect | mount_point:array of paths | static |
| Mount / unmount | mount_type、is_mount_point、mount_point | static，文件树变体 |

不发送旧 Windows create/update/delete，不复制旧 Mac 的 server/remote_folder/
src_folder/dst_folder/username/password 等重复别名。当前没有只读参数证据，不把
read_only=true 当作远端权限保证。修改配置不是直接 reconnect，必须独立规划旧、新
目标与失败恢复。禁止根据 UI 译文或偶然请求顺序生成参数。

## 响应与错误

Mount.List.get 当前成功 data 为 isoList、remoteList 数组和 mountConfig 对象；
enable_iso_mount/enable_remote_mount 是布尔。非空行字段仅 static：type、source、
mount_point、actor、date、auto_mount。actor/真实路径不进入记录或日志。
写回执和非空列表的完整类型、每项失败语义未进行真实验证。

认证/权限失败立即停止；网络或解析失败不得当成目标消失。未知写结果不重放，不能
盲目回滚卸载“新目标”；用户需核查新旧连接。仅凭 getinfo 返回非 normal 类型不能
确认目标是本次预期远程连接。读取只失败降级，不影响普通文件/收藏。

## 版本验证

| 环境 | 等级 | 范围 | 日期 |
| --- | --- | --- | --- |
| 旧 lab-a 基线 | observed/candidate | 历史方法候选，不能支持旧别名字段 | 2026-07-27 |
| 待归属当前环境 | static | 官方请求参数和非空行字段名 | 2026-09-20 |
| 待归属当前环境 | read-verified | 能力缓存、套件版本及空 Mount.List.get | 2026-09-20 |

## 安全与未验证范围

远程密码仅在当次输入和 HTTPS 正文，不持久化、日志化或在调试字符串中展开。
断开不得调用 FileStation.Delete，不暗中清理本地或远程目录。默认自动挂载/开机
重连、域账号、只读策略、并发占用、真实路径映射、升级与失败恢复尚未验证。
不新增 NAS 权限或绕过证书。后续用户验收需专用可恢复远程共享和清晰目标。

## ISO 静态补充

[官方 FileBrowser.js](../environments/INDEX.md#2026-10-02-file-station-live-observation)确认 `Mount.mount_iso v1` 参数 source、mount_point、auto_mount、user_set。来源和挂载点均为 NAS 路径；客户端只允许明确选定现有空目录、user_set=true，不照搬隐式创建/卸载后删除目录。列表仍是 Mount.List.get 的 isoList，断开仅指定 mount_point。auto_mount 为持久行为，需单独确认；未挂载或卸载真实 ISO，证据仅 static，不提升历史验证。



## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
