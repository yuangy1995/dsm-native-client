## macOS 1.0.14

- 修复本地磁盘挂载开启编辑、删除后仍显示只读的问题，并改善修改授权后 Finder 的权限刷新。
- 完善 Chat：支持搜索历史消息、编辑本人消息、回复讨论及参与单选和多选投票。
- 支持 Chat 音视频播放，以及语音录制、试听和发送；仅在主动录音时请求麦克风权限。
- Chat 启用后，在切换到文件、照片等页面时继续接收消息；增加新消息通知，并在实际阅读最新消息后同步已读状态。
- 改善 Chat 发送、附件、删除、转发及断线恢复，减少状态残留，避免结果不明确时重复发送；切换会话保留各自草稿。
- 修复容器镜像搜索及下载状态刷新，临时连接失败后继续读取进度，NAS 明确下载失败时正确显示错误。
- 完善 NAS 设置与套件中心，改善安装准备取消、设置保存和错误提示；修复部分文件权限与设置读取问题。
- 改善 QuickConnect 区域连接、照片操作反馈与文件浏览位置，简化重复控件和提示，并同步中英文文案。

挂载编辑和删除仍需分别授权，并遵循 NAS 权限。部分功能取决于 NAS 套件和账号权限；Chat 加密会话的收发暂不支持。镜像仓库限额或 NAS 网络连接失败仍需在对应仓库或 NAS 上处理。覆盖、删除及权限变更的确认和保护保持不变。

## English — macOS 1.0.14

- Fixed local disk mounts remaining read-only after editing and deletion were enabled, and improved Finder permission refresh after authorization changes.
- Expanded Chat with message history search, editing of your own messages, threaded replies, and participation in single-choice and multiple-choice polls.
- Added Chat audio and video playback, plus voice recording, preview, and sending. Microphone access is requested only when you choose to record.
- Chat continues receiving messages while you browse files, photos, or other pages. Added new-message notifications and read-state synchronization after the latest messages are actually viewed.
- Improved Chat sending, attachments, deletion, forwarding, and connection recovery. Uncertain operations are not automatically sent again, and each conversation retains its own draft.
- Fixed container image search and download status refresh. Progress checks resume after temporary connection failures, and confirmed NAS download failures are shown correctly.
- Expanded NAS settings and Package Center, including cancellation during installation preparation, settings saves, and clearer errors. Fixed several file permission and settings reads.
- Improved QuickConnect regional connections, feedback for photo operations, and file browsing position. Simplified repeated controls and messages, with matching English and Simplified Chinese text.

Mount editing and deletion still require separate authorization and respect NAS permissions. Some features depend on installed packages and account permissions. Sending and receiving in encrypted Chat conversations is not supported yet. Registry rate limits and NAS network failures must still be resolved with the relevant registry or NAS. Confirmation and protection for overwriting, deletion, and permission changes remain in place.
