# 远程挂载契约只读核查

依据环境模板建立；本轮不创建、修改或断开真实远程位置。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不建立 current 基线 |
| 匿名设备别名 | 未确认，不推断为 lab-a |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-09-20 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12；当前官方 Session 的 productversion/version/fullversion 白名单字段 |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户登录的 Chrome DSM，QuickConnect；直连/中继未验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 管理员；当前官方 Session.is_admin 为 true |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| file-station | File Station | 1.4.1-1559 | 官方页面已加载 | 官方套件中心自然 Package.list 响应 |

## 证据来源与范围

- 现有 `file-station-remote-mount` 索引仅记录方法候选，没有字段级官方证据。
- Mac `DsmFileRepository.mountRemote` 使用多组重复别名，仅为客户端源码，不等于官方契约。
- Windows 尚使用 create/update/delete，与已有方法记录不一致，不能直接开放。
- 拟只读检查官方页面已加载资源/自然请求；不导出 HAR，不保存会话、主机、账号、路径或响应正文。
- 不发送 mount_remote/unmount，不输入远程账号密码，不绕过登录或证书界面。

## 初始源码发现

- Mac verifyRemoteMount 用 try? getInfo，把读取失败当作 isMounted=false；可能错误报告已断开。
- Mac 改位置失败时盲目 unmount 新目标，没有可靠证据证明它仍属于本次创建，需独立修复。
- 字段契约、权限和完整状态回读未验证，源代码修复不能提升真实环境证据等级。

## 官方静态参数与只读响应

官方已加载 `/webman/3rdparty/FileBrowser/FileBrowser.js` 静态确认：

| API / 方法 | 参数 | 证据范围 |
| --- | --- | --- |
| Mount v1 / mount_remote | mount_type 为 CIFS/NFS；server_ip 为完整远程地址；mount_point；user_set:boolean；auto_mount:boolean | static |
| CIFS 附加参数 | account、passwd | static；不发送重复 username/password/domain 等别名 |
| NFS 附加参数 | nfs_version 为字符串 3/4，protocol 为 tcp/udp；默认 3/tcp，v4 固定 tcp | static |
| Mount.List v1 / get | 无业务参数 | observed/read-verified，自然打开 Mount List |
| Mount.List v1 / unmount | mount_point 为路径数组 | static，列表批量/单项断开 |
| Mount.List v1 / reconnect | mount_point 为路径数组 | static，列表原连接重连，不代表配置编辑 |
| Mount v1 / unmount | mount_type、is_mount_point、mount_point | static，文件树单项断开；不能使用三组路径别名 |

能力缓存白名单核对：Mount、Mount.List 都是 entry.cgi、minVersion=maxVersion=1、JSON。
Mount.List.get 当前成功返回 isoList/remoteList 数组及 mountConfig 对象，两个 enable
字段为原生布尔。remoteList 为空，只确认空列表；非空行字段 type/source/mount_point/
actor/date/auto_mount 来自官方静态 JsonStore，不能据此升级为非空类型已实测。

官方创建远程表单没有 read_only 字段；当前客户端发送它不能当作只读保证。user_set
区分用户明确选择的现有目标与官方自动建目录路径；自动建目录还调用 CreateFolder。
本客户端后续应使用明确目标，不隐含创建/清理目录。官方卸载后可能根据 UseDefPath
调用 FileStation.Delete 清理自动目录，应用的“断开”不得暗中复制该删除动作。
域字段、只读要求、目标路径表示/映射及 NFS 选项的迁移必须明确，不能靠补别名猜测。

无 mount_remote/unmount/reconnect 写请求，无远程凭据输入或读取。已关闭本轮打开的
两个 File Station 窗口（双击入口产生两份）和套件中心，保留原 Container Manager 与
用户浏览器；停止 Network/Debugger 观察，清空原始响应引用。无 HAR、脚本或截图落盘。
设备归属仍未知，历史 lab-a 等级不变。

额外静态类型线索：官方文件树 mountType 来自 additional.mount_point_type；远程正常
为 remote，失败态为 remotefail，ISO 为 iso。失败态/ISO 不能冒充正常远程挂载。
