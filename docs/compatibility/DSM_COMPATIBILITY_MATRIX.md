# DSM API 兼容证据

本页只说明 API 证据覆盖范围与限制，不重复客户端施工进度。五端功能和验证等级见[平台矩阵](../progress/PLATFORM_MATRIX.md)，未完成风险见[已知限制](../progress/KNOWN_LIMITATIONS.md)。

## 证据来源

- 证据等级、设备归属与升级规则只维护于[私有 API 发现与证据](../api/discovery/README.md)；逐方法的版本、权限和副作用以[端点索引](../api/discovery/endpoints/INDEX.md)、[环境证据](../api/discovery/environments/INDEX.md)和[机器兼容索引](../../contracts/private-api/compatibility.json)为准，本文只是摘要。
- 运行时开放规则见[通用标准](../api/reference/common.md)；本页不设 DSM/build/套件的精确白名单，未测版本保持未验证。
- [社区矩阵](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)独立记录用户反馈，不能自动升级维护者证据或开放危险写能力。

## 环境范围

当前已归属基线为 [lab-a / 2026-07-29](../api/discovery/environments/INDEX.md#2026-07-29-lab-a-dsm-69057-u12)，DSM `7.2.1-69057 Update 12`。后续多次观察仍待匿名设备归属；以下版本是已有观察覆盖范围，不是支持白名单。

| 组件 | 已记录版本 | 证据入口与限制 |
| --- | --- | --- |
| DSM / File Station | 7.2.1-69057 Update 12 / 1.4.1-1559 | [文件 API](../api/reference/files.md)；公开契约、官方页面读取与静态扩展逐项区分，不能概括为文件读写全部通过 |
| Synology Photos | 1.8.2-10090 | [Photos API](../api/reference/photos.md)；个人读取及受控单项删除有观察，不能外推共享空间、管理员管理或其他写操作 |
| Chat Server | 2.4.1-22111 | [Chat API](../api/reference/chat.md)；读取、静态写参数、受控交互行为分项记录，不代表所有原生端和角色通过 |
| Download Station | 4.1.2-5012 | [下载 API](../api/reference/download-station.md)；公开指南优先，内部降级的读取证据不能外推完整任务和写兼容 |
| Container Manager | 24.0.2-1535 | [内部端点](../api/discovery/endpoints/container-manager-internal.md)；列表/搜索有读取证据，受控映像下载曾失败，不能标记成功下载 |
| Virtual Machine Manager | 2.6.5-12202 | [VMM API](../api/reference/virtual-machines.md)；读取与单台隔离创建样本不能外推高级硬件、网络、映像或电源操作 |
| Storage Analyzer | 2.1.0-0620 | 历史报告内部接口未固化，不登记猜测接口或继承 File Station 扫描结论 |

## 影响实现的证据边界

| 范围 | 必须保留的限制 | 详细记录 |
| --- | --- | --- |
| QuickConnect | 地址发现、中继建立、目标身份核对和 API 探测不等于完整登录；不得绕过 TLS 或改用 Bot 接口 | [中继协议](../api/discovery/endpoints/dsm-account-and-connection.md#quickconnect-relay-control) |
| File Station | Upload 无公开字节续传或条件替换事务；本机编辑回传仍有并发检查与写入竞态。回收恢复不能冒充永久删除可恢复 | [文件 API](../api/reference/files.md) |
| 文件设置与远程位置 | uid/gid 数字字符串、`policy=notexist` 是读取语义；`getinfo` 成功不能单独证明挂载或云授权写入完成 | [套件设置](../api/discovery/endpoints/file-station.md#file-station-package-settings)、[VFS](../api/discovery/endpoints/file-station.md#file-station-vfs-connections) |
| Photos | 单张合成照片删除只覆盖该目标；旋转静态成功条件、恢复格式与共享权限按当前端点记录处理，不能由布局或缩略图推断完整写兼容 | [删除](../api/discovery/endpoints/photos-management.md#photos-item-deletion)、[旋转观察](../api/discovery/environments/INDEX.md#2026-10-07-photos-rotation-observation) |
| Chat | 2026-10-03 合成会话的编辑、线程回复、投票及 Channel.view 有逐项行为证据；Post.Subscribe.view 仅接受回执。置顶过滤使用 `in` 数字数组；加密密钥协议尚未验证 | [消息交互](../api/discovery/endpoints/chat.md#chat-message-interaction)、[置顶复验](../api/discovery/environments/INDEX.md#2026-10-03-chat-pinned-read-observation) |
| 容器 | Registry.search v1 已读验证，v2 返回 103；受控 pull 启动后返回 1202 且无新增映像，成功终态仍未验证 | [下载观察](../api/discovery/environments/INDEX.md#2026-10-03-container-image-pull-observation) |
| VMM | 重启请求接受与完成分开；仍 running 不能证明重启完成，uptime 类型、单位和变化未验证。任务/原 VM 身份不可由同名替代 | [电源观察](../api/discovery/environments/INDEX.md#2026-10-07-vmm-power-read-observation)、[内部端点](../api/discovery/endpoints/vmm-internal.md) |
| NAS 系统 | 系统读取成功不覆盖电源计划、ZRAM、外接存储或其他管理写入；无稳定契约的打印机共享、系统升级写入和结束进程不得猜测 | [NAS 管理 API](../api/reference/system-management.md) |
| 套件中心 | 2026-10-03 官方页面单个 MediaServer 更新 2.2.1-3406 → 2.2.2-3412 最终已启动；不代表原生包、其他套件或复杂依赖通过。空 data、Boolean 频道与缺省卷字段按端点处理 | [套件安装](../api/discovery/endpoints/dsm-packages.md#dsm-package-installation) |
| 最近读取复验 | 2026-10-16 Photos 入库时间为 Unix 毫秒，VMM 空保护结果为 `protect_ids=[]`；此次没有 NAS 写入，不覆盖旧基线 | [Windows 读取观察](../api/discovery/environments/INDEX.md#2026-10-16-windows-read-regression) |

## 后续验证

需在明确授权的专用目标上验证的内容（会话、权限撤销、共享数据、断网/取消/重启、覆盖与删源、云授权回调，以及容器/VMM/系统设置的真实副作用）集中列于[已知限制](../progress/KNOWN_LIMITATIONS.md)的 `PENDING_USER_VALIDATION` 一节，回传规则同样见该处；macOS 系统云盘另按[发布验收](DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)。
