## macOS 1.0.5

- 修复正式版错误禁用“新建容器网络”的问题，正式版与测试版现在使用同一套创建逻辑。
- 填写有效网络名称并使用自动 IPv4、关闭 IPv6 时，可以点击创建；确认后才会向 NAS 提交。
- 保留权限与接口能力检查、地址校验、防重复提交和创建结果核对。
- 保留 1.0.4 的照片、容器日志/删除、版本显示及退出后继续访问已有挂载等修复。

适用于 macOS 14 及以上版本，包含正式签名的挂载扩展。在线更新会自动选择 Apple 芯片或 Intel 安装包。

升级前请保存工作并等待应用内和 Finder 传输完成。不会重置账号、设置或已有网络；新建网络只在你确认后执行。手动设置地址时，请避免与现有网络冲突。

## English — macOS 1.0.5

- Fixed an incorrect restriction that disabled container-network creation in official builds. Official and test builds now use the same creation logic.
- With a valid name, automatic IPv4, and IPv6 disabled, the Create button is available. The request is sent only after confirmation.
- Retained permission and API-capability checks, address validation, duplicate-submission protection, and result verification.
- Includes the Photos, container logs/deletion, version-display, and mounted-drive quit-behavior fixes from 1.0.4.

Requires macOS 14 or later and includes the signed File Provider extension. Online updates select the appropriate Apple silicon or Intel installer.

Save your work and finish app and Finder transfers before updating. Existing accounts, settings, and networks are not reset. Networks are created only after your confirmation; avoid address conflicts when entering a manual configuration.
