<!-- doc-role: platform-integration -->
<!-- last-reviewed: 2026-10-16 -->

# 平台集成与恢复边界

功能状态见[矩阵](../progress/PLATFORM_MATRIX.md)，已知问题和设备步骤见[当前限制](../progress/KNOWN_LIMITATIONS.md)。本页只维护平台差异和不能从通用 API 推导的行为。

## Office、文件入口与缓存

| 平台 | 系统入口与编辑方式 | 生命周期与限制 |
| --- | --- | --- |
| macOS | Quick Look 预览；用户选择本机副本及编辑器，保存稳定后回传。Finder 使用复制式 File Provider | 关闭预览/主窗口不结束编辑；停止、断开或退出后保留副本且不再回传，重启不自动接手。另存为不跟踪新路径 |
| iPhone/iPad | Quick Look/系统副本后主动保存；Files 使用非复制式 `NSFileProviderExtension`，共用 `DsmFileProviderRuntime` | 远端刷新不能覆盖本机修改；本地副本保留取回时版本与摘要。iOS 没有 Mac 的保留脏数据域移除模式 |
| Android | DocumentsProvider 默认只读；单独授权 Office 编辑后接收外部修改，由原账号主动保存 | 关闭文件入口不能收回已交付外部 App 的内容。当前在线读取，不承诺离线目录或编辑器关闭后自动上传 |
| Windows | 系统进程外预览组件与默认/自选应用副本；Explorer 使用 Cloud Files | 自动覆盖默认保护；无预览组件可打开副本。Office 副本不能放进受管理同步根，同一目标不能由两条写回链同时接管 |

Office 格式为 doc/docx、xls/xlsx、ppt/pptx；旧格式、加密/损坏文件与复杂排版由实际系统组件决定。原目标身份、内容版本/摘要、当前权限及本次结果共同参与保存判断。公开 Upload 不提供条件替换事务，写前检查不能消除另一客户端随后保存的竞态。未知覆盖只读取恢复，不自动重复上传。

Finder/Files/Cloud Files 的本机缓存不是备份。映射根及共享根不可修改/删除，编辑和删除分别授权；移除位置、释放缓存、清任务记录不等于删 NAS 文件。未保存或未知写的副本不能被常规缓存清理，移除前先导出或结束对应操作。注销原账号或改变信任撤销相应远端访问，不自动销毁系统副本。Mac 退出主 App 保留既有挂载、共享会话和用户暂停状态，由系统扩展继续处理；这与上表中 Office 编辑会话退出后停止回传是不同生命周期。

Windows Cloud Files 保留 v10 日志；旧包拒绝新格式并保留内容。v10 未保存可用于恢复认领的移动/删除接受事实，丢回执后即使路径消失或目标出现也保持未知；“使用现有目录继续同步”只选择后续目标，不宣称本次创建成功。iOS 的副本与域记录属于移动独立存储，不迁移已发布 Mac 格式。

## 后台执行与系统分享

iOS/iPadOS 26 在前台明确开始时申请 `BGContinuedProcessingTask`，采用即时执行策略；系统拒绝或 17–25 使用有限后台时间。保留原传输的证书和同源重定向拦截，未改为会自动跟随重定向的后台 URLSession。到期先取消原网络任务、保存恢复结果，再归还执行资格；旧回调不能取消新执行。照片上传/导出、跨 NAS 与 Office 均使用各自已有执行器，不由系统回调新建写操作。

Apple 分享扩展在扩展内选择已登录 NAS/目录并上传；普通 Share 扩展不通过私有方法强开主 App。主 App 只接手已经释放跨进程所有权的任务。共享账号使用独立会话编号，发布/撤销和每次请求都核对原身份；密码及 DID 不进入共享快照。

Android 使用现有 WorkManager/前台执行与系统通知，省电、超时、权限拒绝或进程结束可能中止。照片、Office 覆盖及跨 NAS 删源不会因重新启动自动重放。桌面任务随所属工作区保留，关闭窗口与明确退出分别处理。任何平台都不承诺脱离实际系统资格无限执行。

## 恢复与升级

恢复记录保存继续处理所需的原账号/目标身份、阶段和摘要；需要继续发送的草稿、附件及编辑副本另受平台保护。保存失败不能发送下一步，未知请求不因改操作编号、重登、换页面或换名重发；新账号不能接管旧记录。

Windows 使用独立的 CrossNas、PhotosUpload/PhotosManagement、OfficeEditing、DownloadActions 和 NasManagement 受保护记录，登录与 Cloud Files 格式不因此迁移。Apple 移动端采用当前开发格式，不为旧开发资料保留平行实现；旧/损坏记录仍须保留并拒绝重放，不能当作空记录覆盖。Android 保留登录/偏好和现有 Worker 任务身份，新恢复资料按原账号隔离。

升级或回退前先导出需要保留的编辑/录音副本、处理未结束操作；旧包不能接管无法理解的新记录。系统保护资料丢失后的解密不保证可恢复，不能靠清空数据库掩盖失败。协议与各操作结果语义只维护在[API 文档](../api/README.md)。

## 虚拟机控制台

控制台只允许固定虚拟机、单窗口来源与必要资源；精确路径见[VMM接口](../api/discovery/endpoints/vmm-internal.md#控制台)。Apple 使用非持久WebKit，Android使用隔离WebView；HTTP/WSS由原生传输沿原会话与证书读取，网页无NAS凭据且不能直接联网。Windows系统信任连接使用隔离WebView2并只向固定页面安装一次Secure/HttpOnly Cookie；固定指纹连接改用原生资源/WSS桥，不向网页安装Cookie，不能靠WebView证书错误事件冒充指纹检查。

原生桥保留NAS CSP并阻止其他来源、frame/object/worker和重定向；语言JSON只读桥不是通用代理。Apple/Android启动HTML限4 MiB、其他静态资源8 MiB、语言1 MiB，画面按256 KiB有序交付，输入单条1 MiB/队列4 MiB；Apple单条原生消息上限32 MiB，Android接收缓冲32 MiB/4帧是在OkHttp完整帧回调后检查，不能宣称分配前保护。关闭、退出账号、切换账号、移动退到后台会停止连接，丢弃迟到结果；重连须主动重新准备原目标，不自动重发输入。窗口缓存由对应宿主清理；Windows等待自己的浏览进程退出后删除其独立目录。Apple现有连接配置只提供主机/端口根地址，策略层的别名测试不等于已提供非根门户入口。

## 构建与系统能力

- 构建、测试和本地包命令分别在 [Apple](../../apple/README.md)、[macOS](../../apple/Apps/DsmMac/README.md)、[移动](../../apple/Apps/DsmMobile/README.md)、[Android](../../android/README.md)、[Windows](../../windows/README.md)。
- Mac 本机临时签名沿用既有独立测试身份及 App Group/Keychain，不访问或迁移正式数据，也不含 Finder 扩展，命令和输出见 [macOS README](../../apple/Apps/DsmMac/README.md)。正式主 App/扩展需要一致团队、App Group 和共享会话权限，见[Apple 签名与发布](../releases/MACOS_GITHUB_RELEASE_ZH.md)。签名检查不能替代实际组件加载及系统注册。
- Windows ZIP 包含 .NET 与 Windows App Runtime，控制台另需本机 WebView2；Office/媒体组件由系统提供，物理 ARM64 另验。
- 无真实设备不是独立源码工作的阻塞；未实现能力与系统待验分开，涉及数据安全的相关入口继续遵守其实际保护。
