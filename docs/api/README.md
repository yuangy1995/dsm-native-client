# 按功能分类的 API 实现参考

这是岚仓其他端对齐 macOS 时的统一 API 阅读入口。本目录区分官方指南、已记录观察、客户端实现与合成样例：reference维护公开接口和业务入口，endpoints维护内部请求/响应定义，环境索引维护证据。

这里的“标准”指本项目约定的请求、结果和跨端业务语义，不是新建一套服务器接口，也不把群晖内部接口改称官方 API。

## 阅读顺序

1. 先读[通用标准](reference/common.md)，实现能力发现、参数编码、会话、错误和写操作结果。
2. 按下表进入功能文档，遵循相同的输入、输出、权限和失败语义；界面遵循目标平台习惯。
3. 打开功能对应的[请求参数目录](reference/requests.md)、领域模型及私有接口证据。快照保存合成请求约束，可能含历史形状；真实兼容结论须按 DSM/套件版本查询。

| 功能 | 文档 | macOS/共享实现主入口 |
| --- | --- | --- |
| 登录、OTP、会话、QuickConnect | [认证与连接](reference/authentication.md) | `DsmAuthenticationService`、`DsmQuickConnectResolver` |
| 文件、传输、分享、归档、权限、远程位置 | [文件与远程连接](reference/files.md) | `DsmFileRepository` 及功能扩展 |
| Photos 浏览、相册、分享、上传、管理、预览 | [照片](reference/photos.md) | `SynologyPhotosRepository` |
| 普通用户 Chat、附件、群聊、提醒与实时事件 | [聊天](reference/chat.md) | `DsmChatRepository`、`DsmChatRealtimeClient` |
| Download Station、任务、BT 搜索及设置 | [下载管理](reference/download-station.md) | `DsmServiceManagementRepository` |
| Container Manager、映像、网络与任务结果 | [容器](reference/containers.md) | `DsmServiceManagementRepository` |
| VMM 清单、电源、创建、设置与控制台 | [虚拟机](reference/virtual-machines.md) | `DsmServiceManagementRepository` |
| NAS 概览、账号、套件、任务、日志、网络、安全与设置 | [系统管理](reference/system-management.md) | `DsmNasAdministrationRepository` 及功能扩展 |
| 磁盘、卷、SMART、外接存储及本地磁盘挂载边界 | [存储](reference/storage.md) | `DsmNasAdministrationRepository`、`DsmFileRepository` |
| 已有请求的精确字段、类型、版本、格式及执行策略 | [请求参数目录（生成）](reference/requests.md) | `contracts/request-fixtures` |

## 事实来源与边界

- [领域契约](../../contracts/README.md)：各端共同使用的业务模型；不是 DSM 原始响应格式。
- [原始请求快照](../../contracts/request-fixtures/README.md)：完全合成、可复验的编码样例；不包含真实凭据或环境数据。
- [私有接口端点记录](discovery/endpoints/INDEX.md)：原始参数、响应、权限、副作用及版本差异。
- [匿名环境索引](discovery/environments/INDEX.md)与[机器兼容索引](../../contracts/private-api/compatibility.json)：真实观察或验证的具体版本，不得用其他版本或其他权限账号替代。
- [DSM 兼容证据](../compatibility/DSM_COMPATIBILITY_MATRIX.md)：已有环境覆盖与未验证限制。
- [平台功能矩阵](../progress/PLATFORM_MATRIX.md)：某端是否已接入；本目录不代表所有端已经实现。

macOS界面是业务语义参考；Repository只证明当前客户端怎样请求，API存在性、版本、参数和响应事实须由官方指南或明确条件下的观察支持。源码与合成样例一致也可能共同偏离真实协议。页面存在、接口可发现、静态资料、合成测试和真实行为验证分别记录，不能互相替代。

## 维护要求

修改 macOS 网络调用时，同步对应功能文档、请求快照及受影响平台的范围说明；改变共享契约遵循仓库审批规则。发现新的私有接口继续使用[发现流程](discovery/README.md)，不要在本目录复制另一份版本历史。

```bash
python3 tools/codex/generate_api_reference.py
python3 tools/codex/generate_api_reference.py --check
python3 tools/request-contract/validate_contracts.py
python3 tools/contract-validation/validate_fixtures.py
python3 tools/codex/check_documentation.py
```

参数目录由现有快照生成，不得直接手改。功能文档只维护当前流程、跨端不变量和必要限制，不再逐次追加构建日志、临时包清单或已被替代的剩余任务。

## 官方来源

以下链接保留原审阅来源；文档整理没有重新联网复验其现行内容或可达性。公开指南不能用来证明未公开套件方法，旧示例版本须结合方法字段表核对。

- [DSM登录API指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf)
- [File Station API指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf)
- [Download Station API指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/DownloadStation/All/enu/Synology_Download_Station_Web_API.pdf)
- [Virtual Machine Manager API指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/Virtualization/All/enu/Synology_Virtual_Machine_Manager_API_Guide.pdf)
- [DSM 7开发指南](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf)
- [QuickConnect白皮书](https://global.download.synology.com/download/Document/Software/WhitePaper/Os/DSM/All/enu/Synology_QuickConnect_White_Paper_enu.pdf)
- [NAS外部访问说明](https://kb.synology.com/en-my/DSM/tutorial/Quick_Start_External_Access)

Photos及File Station官方包来源、未成功读取的边界保留在[环境索引](discovery/environments/INDEX.md)；Photos升级帮助的有限摘要证据保留在[高级相册定义](discovery/endpoints/photos-advanced-management.md)。第三方Schema仅是注明来源的静态线索，不能冒充Synology文档或成功响应。
