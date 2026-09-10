## macOS 1.0.4

- 退出岚仓后，不再主动中断已有本地磁盘挂载；网络与登录状态有效时，可继续通过 Finder 访问。手动暂停和退出 NAS 登录的行为保持不变。
- 修复照片跳转到较早月份后无法向上继续加载的问题，保留按日期准确定位；去掉滚动条实色轨道框。
- 修复容器活动记录无法显示、网络关联容器数量不正确、无项目时误报加载失败，以及网络删除失败的问题。
- 网络列表可展开查看子网、网关、IPv6 状态和关联容器；改进日志搜索、筛选和列对齐。
- 关于窗口只显示版本号，不再显示构建次数。

本次包含挂载扩展，适用于 macOS 14 及以上版本。在线更新会自动选择 Apple 芯片或 Intel 安装包。首次打开新版本并确认挂载正常后，再退出主应用测试继续访问；会话过期或网络不可达时仍可能需要重新连接。

主应用加密密钥和挂载共享会话的存储方式未变。本次未包含移除钥匙串依赖的迁移。完整网络创建表单已对齐，但正式版创建入口仍默认关闭，需进一步完成实际写入验收；不影响已有网络的读取。

安装前请保存工作并等待应用内和 Finder 传输完成。不会升级 NAS 系统或套件，也不会重置账号、设置或已有映射。

## English — macOS 1.0.4

- Quitting LanStash no longer deliberately disconnects existing mounted drives. Finder access can continue while the network and session remain valid. Manual pause and NAS sign-out behavior are unchanged.
- Fixed loading newer photos after jumping to an older month, while preserving date-based navigation. Removed the solid scrollbar track.
- Fixed missing container activity logs, incorrect network connection counts, empty-project loading errors, and network deletion requests.
- Expand networks to view subnets, gateways, IPv6 status, and connected containers. Improved log search, filtering, and column alignment.
- The About window now displays only the release version, without the build number.

Includes the File Provider extension and requires macOS 14 or later. Online updates select the appropriate Apple silicon or Intel installer. Launch the updated app once and confirm the mount works before testing access after quitting. Expired sessions or unavailable networks may still require reconnecting.

Private encryption-key storage and shared mount sessions are unchanged; this release does not migrate away from Keychain. The full network-creation form is included, but creation remains disabled in official builds pending further real-world write validation. Existing-network reads are unaffected.

Save your work and finish app and Finder transfers before updating. This update does not upgrade DSM or NAS packages or reset accounts, settings, or mappings.
