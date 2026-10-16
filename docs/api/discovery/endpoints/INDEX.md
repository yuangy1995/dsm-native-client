# 内部 API 定义索引

本页只导航，不维护另一份启用状态、版本结论或平台进度。每个稳定标识的唯一正文如下；[通用标准](../../reference/common.md)、[证据索引](../environments/INDEX.md)及[平台矩阵](../../../progress/PLATFORM_MATRIX.md)分别维护通用行为、历史验证和实现状态。

| 稳定端点标识 | 定义 |
| --- | --- |
| `photos-similar-items` | [Synology Photos 相似照片分组](photos-library.md#photos-similar-items) |
| `photos-condition-albums` | [Photos 后续管理接口静态证据](photos-management.md#photos-condition-albums) |
| `photos-people-management` | [Photos 后续管理接口静态证据](photos-management.md#photos-people-management) |
| `photos-request-management` | [Photos 后续管理接口静态证据](photos-management.md#photos-request-management) |
| `photos-preview-regeneration` | [Photos 后续管理接口静态证据](photos-management.md#photos-preview-regeneration) |
| `photos-sharing-management` | [Photos 个人空间管理候选接口](photos-management.md#photos-sharing-management) |
| `photos-duplicate-settings` | [Photos 个人空间管理候选接口](photos-management.md#photos-duplicate-settings) |
| `photos-display-settings` | [Photos 个人空间管理候选接口](photos-management.md#photos-display-settings) |
| `photos-recognition-settings` | [Photos 个人空间管理候选接口](photos-management.md#photos-recognition-settings) |
| `photos-upload` | [Photos 个人空间管理候选接口](photos-management.md#photos-upload) |
| `photos-file-management` | [Photos 个人空间管理候选接口](photos-management.md#photos-file-management) |
| `photos-album-management` | [Photos 个人空间管理候选接口](photos-management.md#photos-album-management) |
| `photos-item-metadata` | [Photos 个人空间管理候选接口](photos-management.md#photos-item-metadata) |
| `photos-item-deletion` | [Photos 原件与目录删除](photos-management.md#photos-item-deletion) |
| `photos-library-read` | [Synology Photos 照片库只读接口](photos-library.md#photos-library-read) |
| `dsm-desktop-app-privileges` | [DSM 当前账号应用权限摘要（候选）](dsm-account-and-connection.md#dsm-desktop-app-privileges) |
| `quickconnect-relay-control` | [QuickConnect 控制面与区域转介](dsm-account-and-connection.md#quickconnect-relay-control) |
| `file-station-remote-mount` | [File Station 远程挂载内部接口](file-station.md#file-station-remote-mount) |
| `dsm-system-observability` | [DSM 基础读取接口](dsm-system-monitoring.md#dsm-system-observability) |
| `dsm-system-processes` | [DSM 系统进程与服务进程组内部 API](dsm-system-monitoring.md#dsm-system-processes) |
| `dsm-power-schedule` | [DSM 电源计划内部 API](dsm-hardware-and-power.md#dsm-power-schedule) |
| `dsm-external-storage` | [DSM USB 与 eSATA 外接存储内部 API](dsm-hardware-and-power.md#dsm-external-storage) |
| `dsm-zram` | [DSM 内存压缩（ZRAM）内部 API](dsm-hardware-and-power.md#dsm-zram) |
| `dsm-printer-bonjour-sharing` | [DSM 打印机 Bonjour 共享内部 API](dsm-network-and-security.md#dsm-printer-bonjour-sharing) |
| `dsm-storage-hardware` | [DSM 基础读取接口](dsm-system-monitoring.md#dsm-storage-hardware) |
| `dsm-account-directory` | [DSM 账号与群组目录内部 API](dsm-account-and-connection.md#dsm-account-directory) |
| `file-station-share-access` | [DSM 共享文件夹访问权限契约](file-station.md#file-station-share-access) |
| `dsm-share-permission-matrix` | [DSM 共享文件夹访问权限契约](file-station.md#dsm-share-permission-matrix) |
| `dsm-package-installation` | [DSM 套件中心内部 API](dsm-packages.md#dsm-package-installation) |
| `dsm-administration` | [DSM 基础读取接口](dsm-system-monitoring.md#dsm-administration) |
| `download-station2-fallback` | [Download Station 2 内部降级接口](download-station2-fallback.md) |
| `vmm-internal` | [Virtual Machine Manager 内部接口](vmm-internal.md) |
| `container-manager-internal` | [Container Manager 内部接口](container-manager-internal.md) |
| `chat-internal` | [Chat 会话基础接口](chat.md#chat-internal) |
| `chat-realtime` | [Chat 实时事件通道](chat.md#chat-realtime) |
| `photos-internal-candidate` | [Synology Photos 照片库只读接口](photos-library.md#photos-internal-candidate) |
| `photos-concept-visibility` | [Photos 后续管理接口静态证据](photos-management.md#photos-concept-visibility) |
| `photos-automatic-preview` | [Photos 后续管理接口静态证据](photos-management.md#photos-automatic-preview) |
| `photos-shared-space-settings` | [Photos 后续管理接口静态证据](photos-management.md#photos-shared-space-settings) |
| `photos-shared-space-members` | [Photos 后续管理接口静态证据](photos-management.md#photos-shared-space-members) |
| `photos-global-settings-cache` | [Photos 后续管理接口静态证据](photos-management.md#photos-global-settings-cache) |
| `photos-library-maintenance` | [Photos 后续管理接口静态证据](photos-management.md#photos-library-maintenance) |
| `photos-background-tasks` | [Synology Photos 后台任务中心](photos-library.md#photos-background-tasks) |
| `file-station-content-search` | [File Station 文件内容搜索](file-station.md#file-station-content-search) |
| `file-station-sharing-extended` | [File Station 具名分享与文件请求扩展](file-station.md#file-station-sharing-extended) |
| `file-station-file-permissions` | [File Station 所有者、POSIX 与 ACL](file-station.md#file-station-file-permissions) |
| `file-station-vfs-connections` | [File Station VFS 连接](file-station.md#file-station-vfs-connections) |
| `file-station-package-settings` | [File Station 套件设置与分享页面](file-station.md#file-station-package-settings) |
| `chat-message-interaction` | [Chat 消息搜索、编辑、线程、投票参与与已读](chat.md#chat-message-interaction) |

## 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
