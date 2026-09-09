## macOS 1.0.1

- 修复多台 NAS 切换时的账号状态隔离，改善部分账号登录后出现登录失效提示的问题。
- 按当前账号权限显示可用应用，隐藏的应用不再自动加载；NAS 设置仅向管理员开放。
- 新 NAS 首次默认开启有权限的文件和照片，其他模块按需手动开启；已有设置和用户选择继续保留。
- 传输中心与应用设置统一放在侧边栏底部，与 NAS 组件分组。
- 更新提示改为紧凑窗口，下载显示横向进度条和百分比；优化视频预览，移除重复窗口按钮和多余边框。
- 保留正常错误提示与恢复操作，移除本轮临时诊断入口。

本次仅发布 macOS 客户端，支持 macOS 14 或更新系统，安装包同时适用于 Apple 芯片与 Intel Mac。

- 已安装支持在线更新的正式版：在 LanStash 菜单或“应用设置 → 岚仓更新”中检查更新。
- 首次安装、旧版不支持在线更新或正在使用本地测试包：下载正式 DMG，将 LanStash 拖入“应用程序”；之后可继续在线更新。
- 安装重启前请保存工作，并等待应用内及 Finder 文件传输完成。
- 更新仅替换客户端，不升级 NAS 系统或套件，不重置已经保存的模块选择。

Android、Windows、iPhone 和 iPad 不包含在此次发布中。应用入口授权与具体操作权限分别由 NAS 决定；官方网页也拒绝的操作，客户端不会绕过限制。

## English — macOS 1.0.1

- Improved account isolation when switching between NAS connections and addressed session-expired prompts affecting some accounts after sign-in.
- Available apps now follow the current account's permissions. Hidden apps no longer load automatically, and NAS Settings is available only to administrators.
- A newly connected NAS enables authorized Files and Photos by default. Other modules are opt-in; existing settings and manual choices are preserved.
- Transfer Center and App Settings now share the bottom section of the sidebar, separate from NAS modules.
- Compact update dialogs show download progress with a horizontal bar and percentage. Video previews no longer have duplicate window controls or unnecessary outer borders.
- Retained normal error recovery while removing temporary diagnostic controls.

This release contains only the macOS client. Requires macOS 14 or later; the universal DMG supports Apple silicon and Intel Macs.

- Existing official versions with online updates: check for updates from the LanStash menu or App Settings → LanStash Update.
- First installation, versions without online updates, or local test builds: install the official DMG into Applications once to enable future online updates.
- Save your work and finish app and Finder transfers before installing and restarting.
- Updates replace the client only, not the NAS system or packages, and do not reset saved module choices.

Other platforms are not included. NAS application access and permissions for individual operations remain separate; the client does not bypass restrictions enforced by the official web interface.
