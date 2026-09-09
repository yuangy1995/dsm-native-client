## macOS 1.0.2

- 统一页面、弹窗和卡片的主题背景，修复加载中、聊天、虚拟机创建、连接卡片及容器统计等区域的白底。
- 列表、表格、侧栏、页签和文件网格改用低饱和选中背景，保留键盘、多选和焦点操作。
- 文件网格新增小、中、大三档图标大小，文件夹、文件和缩略图同步调整；默认使用更紧凑的中档。
- 重做文件详情布局，打开文件夹详情时自动计算大小，重新打开会刷新结果，保留取消与失败重试。
- 本机存储统计加入挂载盘缓存，支持确认后统一释放临时缓存，保留离线文件和未上传修改。
- 更新窗口隐藏重复标题，标题栏与内容区使用同一主题背景，同时保留系统按钮和拖动功能。
- 优化登录底栏、侧栏间距及排序菜单按钮，补齐卡片模式的浅深主题回归检查。

本次仅发布 macOS 客户端，支持 macOS 14 或更新系统，通用安装包适用于 Apple 芯片与 Intel Mac。

- 已安装支持在线更新的正式版：在菜单或“应用设置 → 岚仓更新”中检查更新。
- 本地测试版与正式版分别保存资料；从测试版切换到正式版不会自动导入测试资料。
- 安装重启前请保存工作，并等待应用内及 Finder 文件传输完成。
- 缓存释放只针对这台 Mac 的临时下载内容，不删除 NAS 文件；正在使用、离线保留或尚未上传的内容不会强制删除。
- 本次不升级 NAS 系统或套件，不重置正式版已有账号及设置。其他平台不包含在此次发布中。

## English — macOS 1.0.2

- Unified themed page, dialog, and card backgrounds, including loading states, chats, virtual machine creation, connection cards, and container summaries.
- Replaced bright blue and unrelated gray selection fills with subtle theme-aware colors while preserving keyboard, multi-selection, and focus behavior.
- Added small, medium, and large file-grid sizes. Folders, files, and thumbnails scale together, with a more compact medium default.
- Redesigned file properties with a denser layout. Folder sizes calculate automatically when opened and refresh on reopening, with cancellation and retry available.
- Added mounted-drive cache usage to local storage reporting and a confirmed action to release temporary cache while retaining offline files and unuploaded changes.
- Removed the duplicate update-window title and unified the title bar with the content background, keeping system controls and window dragging.
- Improved login-footer layout, sidebar spacing, and sorting-menu buttons, with additional light/dark card-view regression coverage.

This release contains only the macOS client. Requires macOS 14 or later; the universal DMG supports Apple silicon and Intel Macs.

- Existing official versions with online updates can check from the menu or App Settings → LanStash Update.
- Local test builds and official builds store their data separately. Installing the official build does not import test-build data.
- Save your work and finish app and Finder transfers before installing and restarting.
- Cache cleanup releases temporary downloads on this Mac only. It does not delete NAS files or forcibly remove open, offline-kept, or unsynced contents.
- This update does not upgrade DSM or NAS packages, reset existing official-build accounts or settings, or release other platforms.
