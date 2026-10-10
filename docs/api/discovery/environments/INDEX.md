# 私有 API 发现环境索引

本页是面向人工阅读的匿名环境入口。机器和 AI 应同时读取 [`contracts/private-api/compatibility.json`](../../../../contracts/private-api/compatibility.json)，不要根据“当前”文字猜测版本。

## 设备别名

| 匿名设备 | 用途 | 当前基线 |
| --- | --- | --- |
| `lab-a` | 首台私有 API 发现基准 NAS | `lab-a-dsm-7-2-1-69057-u12-20260729` |

新增 NAS 时依次使用 `lab-b`、`lab-c`。同一 NAS 升级后沿用设备别名，新建环境 ID，并将旧环境标记为 `historical`。

## 环境基线

| 环境 ID | 匿名设备 | DSM | 观察日期 | 状态 | 记录 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `lab-a` | `7.2.1-69057 Update 12` | 2026-07-29 | `current` | [查看基线](2026-07-29-lab-a-dsm-69057-u12.md) |

环境 ID 和设备别名都不得替换成设备名、型号、序列号、地址、账号或 QuickConnect ID。

## 待归属观察

- [2026-10-06 容器与 VMM API 缺口核查](2026-10-06-container-vmm-api-read-observation.md)：重新核实 DSM/两套件完整版本，容器/网络/映像/仓库列表及空项目读取；补容器 profile、项目 CRUD/流式操作与 VMM 精确版本/参数，发现 Apple 内部电源/删除等差距。新增写均为 static，未操作真实资源或连接 VM；临时观察器已清理。

- [2026-10-03 Chat 五组交互补全](2026-10-03-chat-five-features-observation.md)：分页、搜索和编辑设置只读验证；指定合成会话内完成编辑、线程回复、投票与会话已读回读；线程已读仅有接受回执，不能提升其最终状态证据。

- [2026-10-03 容器镜像搜索与下载](2026-10-03-container-image-pull-observation.md)：Registry.search v1 成功、v2 返回 103；用户授权小体积镜像测试，观察到任务启动和运行，随后 NAS 返回 1202 且无新增目标镜像。成功下载仍未验证。

- [2026-10-02 File Station 设置读取故障核查](2026-10-02-file-station-settings-read-fix.md)：DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559；本机用户和群组名单的 uid/gid 数字字符串、原生权限布尔及限速 notexist 未配置状态已只读核对。临时草稿已取消，没有保存设置或权限，不提升历史设备基线或写验证等级。

- [2026-10-02 File Station 官方包静态核查](2026-10-02-file-station-official-package.md)：浏览器会话不可访问；官方包无法用标准归档读取，未获得新字段证据，不改变历史兼容等级。

- [2026-10-01 Photos 后台任务与冻结相册续查](2026-10-01-photos-remaining-observation.md)：浏览器恢复后的官方静态资源只读核对，完整版本仍未知，不执行真实NAS写入。

- [2026-09-26 NAS 设置读取回归](2026-09-26-nas-settings-read-observation.md)：观察到账号启停枚举和分离的电源计划容器；系统活动仅静态候选，未提升历史设备等级，写入待用户验证。

- [2026-09-21 VMM 控制台资源与别名](2026-09-21-vmm-console-resource-observation.md)：只读核实 app_alias/app_id 地址规则及语言、铃声、图标资源；没有连接 VM 或修改门户配置。

- [2026-09-20 VMM 高级创建续查](2026-09-20-vmm-creation-read-observation.md)：初次绑定失败后已恢复，只读字段及后续获授权的单台隔离创建样本均已记录；明确任务身份及内存读写单位，不提升历史设备基线。

- [2026-09-20 VMM 网络契约核查](2026-09-20-vmm-network-read-observation.md)：浏览器恢复后核实 DSM/VMM 版本、管理员、Network.list/get v2 与 list_avail_interface v1；set/delete v1 和接口增删数组为官方静态线索，未修改网络或创建虚拟机。

- [2026-09-20 VMM 高级设置与控制台核查](2026-09-20-vmm-parity-read-observation.md)：DSM/VMM 版本、Guest 能力及 get/get_setting 已只读核查；三态启动、五档 CPU 优先级、set v1 和控制台路径仅有静态线索，未保存配置或连接控制台。

- [2026-09-20 远程挂载契约核查](2026-09-20-remote-mount-read-observation.md)：当前 File Station 1.4.1-1559 的官方静态参数与两端旧实现不同；空挂载列表和版本/能力元数据已只读验证，无挂载或断开行为验证。

- [2026-09-17 VMM 设置回读核查](2026-09-17-vmm-settings-read-observation.md)：浏览器连接失败，未获得新环境证据；仅完成已有字段的源码核查修正，不能视为真实读写验证。

- [2026-09-17 Container 映像下载契约核查](2026-09-17-container-image-pull-read-observation.md)：当前版本/能力与 Image.list 精确参数、字段类型已只读验证；pull_start/pull_status/聚合任务列表只有静态线索，没有执行下载，不提升写行为等级。

- [2026-09-16 Windows 对齐只读核查](2026-09-16-windows-parity-read-observation.md)：当前 DSM/Chat/Container/Photos 版本已核实；Chat 创建/成员及 Docker 容器/日志声明 JSON，只有能力元数据 read-verified，未执行建群或容器写操作。

- [2026-09-16 QuickConnect 客户端只读复验](2026-09-16-quickconnect-client-observation.md)：区域转介后得到在线连接候选，Windows 登录前认证接口发现通过；未提交凭据，DSM 版本和设备归属未确认。

- [2026-09-10 Container Manager 日志与网络读取观察](2026-09-10-container-read-observation.md)：官方日志 `load` 参数和网络关联数组已核对；版本与设备关系未重新确认，不归入历史基线；没有执行写操作。

- [2026-09-10 Photos 单项删除受控验证](2026-09-10-photos-deletion-observation.md)：唯一合成图已单次删除，任务完成，刷新后原件回读为空；macOS 按用户要求跨版本依接口能力开放供测试，App 重启和异常路径待验证。

- [2026-09-10 Photos 分类、筛选、共享与实况观察](2026-09-10-photos-filter-share-observation.md)：DSM/Photos 版本再次核对；系统分类、只读筛选／共享与独立实况视频单元已记录，未进行分享写入。

- [2026-09-09 Photos 只读观察](2026-09-09-photos-observation.md)：DSM 7.2.1-69057 Update 12、Photos 1.8.2-10090；管理员账号的个人空间读取，Photos 共享权限为 none；设备与 lab-a 的关系未确认，不冒用历史基线。

- [2026-09-09 管理员 Chat 入口观察](2026-09-09-admin-chat-observation.md)：DSM 7.2.1-69057 Update 12、Chat 2.4.1-22111；已核实新建会话 API 声明 JSON 编码，未创建真实会话，不提升写入证据等级。

- [2026-09-09 非管理员应用权限观察](2026-09-09-nonadmin-permission-observation.md)：DSM 7.2.1-69057 Update 12 已由官方初始化响应核实；尚未确认是否为既有 `lab-a`，不因版本相同推断设备相同，不建立第二个 current 基线。

- [2026-09-27 NAS 设置与客户端权限摘要实测](2026-09-27-nas-settings-live-validation.md)：补齐 DSM 完整版本、进程/服务组、任务详情、PID 和数字星期；复现并修复未登录空权限摘要误判，客户端验收继续进行。


- [2026-10-07 VMM 电源完成条件](2026-10-07-vmm-power-read-observation.md)：DSM 7.2.1-69057 Update 12 / VMM 2.6.5-12202；同版本官方静态回调没有消费重启任务身份，uptime 仅为显示候选；未发送电源写，设备待归属。

## 非设备静态来源读取尝试

- [2026-09-30 Photos 1.9.1-10928 官方公开包](2026-09-30-photos-1-9-1-official-package.md)与[1.7.0-0795归档包](2026-09-30-photos-1-7-0-official-package.md)：标准归档工具未能读取内部脚本，没有新增API证据或设备基线；未安装、执行、解密或访问NAS。

- [2026-10-02 File Station 官方页面续查](2026-10-02-file-station-live-observation.md)：DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559；待归属；全文 start 与设置读取、静态扩展契约，无真实写验证。

- [2026-10-03 置顶搜索复验](2026-10-03-chat-pinned-read-observation.md)：旧 channel_id 过滤失效，in 数字数组只读验证有效；待归属，不提升旧基线。

- [2026-10-07 Photos 旋转保存条件](2026-10-07-photos-rotation-observation.md)：官方静态成功分支更新布局并刷新缩略图；纠正显示尺寸与原始分辨率的混用，实际 NAS 旋转仍未验证。
