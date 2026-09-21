# File Station 远程挂载内部接口

## 标识

| 字段 | 值 |
| --- | --- |
| 端点组 / 组件 | `file-station-remote-mount` / `file-station` |
| 范围 / 能力 | File Station；SMB/NFS 连接、重连和断开 |
| 分类 / 操作 / 风险 | internal / mixed / high |

## 请求契约

来源：[2026-09-20 只读核查](../environments/2026-09-20-remote-mount-read-observation.md)。
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

## 能力与客户端

Windows 原生挂载管理已按此契约接入目标确认、权限预检、重复保护和最终状态核查，
按会话/接口开放用户验证。Mac 同类别名与只读保证缺口已在源码修正，仍需源身份
核查/恢复及目标构建，不能作为已验证基线复制。用户授权可测试入口不代表 Agent
可执行真实挂载。
无等价公开写 API；可用公开 List.getinfo 辅助确认，但读取失败和缺字段不是“断开”。

Apple：DsmFileRepository.swift；Windows：DsmRepository.FileRemoteMounts.cs。
正式测试：DsmFileRepositoryTests.swift、FileRemoteMountContractTests.cs。新增写请求
fixture 与模型迁移随后续适配切片更新；目前不把旧合成测试当新官方契约证据。
五端影响：Mac/Windows 需修正，iPhone/iPad 保持既有受限范围，Android 只记录不改代码。

2026-09-20 Windows 协议依赖已实现：RemoteMountProtocol 构建规范 CIFS/NFS 地址及
固定字段，专用 transport 支持 mount_remote 与 Mount.List.unmount，布尔/数组不
重复 JSON 编码；拒绝旧 create/update/delete、别名注入和隐含 auto_mount。独立
Mount.List.get 读取返回绑定 profile 的严格清单，重复路径/缺字段/错误类型不冒充
空列表。新构造器保留兼容默认 NFS 3/tcp，v4 不允许 UDP；未知只读要求明确不支持，
不静默忽略。该协议层不等于创建/编辑/断开的确认与结果编排完成，旧 UI 仍关闭。

新增四份合成 fixture：file-station 下 mount-cifs、mount-nfs、unmount-remote、
list-remote-mounts；账户/密码只标记 redacted，Windows 实际传输测试校验非敏感字段。
没有执行真实写操作，没有因此提高当前或历史环境验证等级。

2026-09-20 Windows 新增阶段式核心：固定请求编号、目标身份及用户确认快照，创建/
断开/同位置修改/换位置修改逐阶段执行；未知只回查，修改下一阶段要求重新明确继续。
完整清单和公开 getinfo 共同核查源/协议/自动挂载标志与目录状态，读取异常不代表
断开成功。外部身份替换、嵌套挂载和未知路径互斥有正式合成回归，不自动回滚或删目录。
39 项新案例与全量 3068 项通过均为客户端合成证据，非空清单与真实写行为仍未验证。
随后 Windows 原生管理窗口已迁移，按绑定会话与三组接口能力开放用户确认测试，
未知仅核查、修改分步确认和密码重新输入均接正式入口。旧无确认接口只保留不发送
的兼容返回，错误参数发送路径已移除；这不提升真实环境验证等级。Mac 别名修复仍
是剩余工作，不能将 Windows 适配或测试结果当作 Mac 通过。

随后 Mac 协议源码已修正：mount_remote 固定 CIFS/NFS、server_ip、mount_point、
user_set=true、auto_mount=false 与两种协议专用字段；断开 Mount.List.unmount
仅挂载点数组。兼容构造器新增默认 NFS 3/TCP，v4+UDP 和 readOnly 要求明确拒绝，
不暗中增加权限保证；域账号合并且不发送别名。三份请求 fixture 绑定实际 Swift
调用测试，但本机缺 Swift，8 个新测试方法未执行，Mac App 未构建。源身份核查/
恢复仍需补齐，不改变 verifications 中历史或当前环境的真实证据等级。

Mac 后续已补严格 Mount.List.get 读取及写后来源证明：按原生布尔/字符串/数组解码，
缺失自动挂载键保留未知，重复路径或畸形来源不冒充空清单；忽略 actor 等非必要字段。
连接成功需清单精确来源/协议/位置/auto_mount=false 与公开目录类型共同证明；断开
需清单目标消失与正常目录/明确 408 共同证明。新增 7 个测试方法和既有响应序列已
更新，但 Swift/Mac 未运行；确认前旧连接绑定和恢复仍待实施，不提高环境验证等级。

Mac 后续确认前绑定已接源码：窗口加载并展示来源后传递固定身份重载，首次提交前
核查原连接，换位置时断开前再次核查新旧身份，最后确认新连接仍存在。新建/新位置
必须是未占用的现有目录，禁止隐式覆盖或断开嵌套连接；旧无身份签名只保留不支持。
这些客户端安全检查和 14 个未运行的新 Swift/Mac 测试不构成 NAS 行为证据；未知
结果恢复仍是后续代码工作，无实际写请求、无新的环境兼容结论。

Mac 后续恢复源码已接：相同 Repository 内记录操作编号和非密码配置，保留提交/
待核查/待继续阶段并互斥关联路径。只读核查不补写，用户确认才继续；明确第二步
失败可重新提供密码，未知不能重放或直接遗忘，仅已知未执行的剩余步骤可明确结束。
原生窗口接入恢复入口并说明重连/退出不保留记录。没有新增 NAS 请求方法，仍复用
本端点组及公开 getinfo；15 个新 Swift/Mac 方法未运行，未提升真实环境验证等级。

## 安全与未验证范围

远程密码仅在当次输入和 HTTPS 正文，不持久化、日志化或在调试字符串中展开。
断开不得调用 FileStation.Delete，不暗中清理本地或远程目录。默认自动挂载/开机
重连、域账号、只读策略、并发占用、真实路径映射、升级与失败恢复尚未验证。
不新增 NAS 权限或绕过证书。后续用户验收需专用可恢复远程共享和清晰目标。
