# macOS 退出主应用保留已有挂载

## 目标与范围

用户明确要求保留当前挂载设计，但从 Dock、菜单或快捷键退出 App 时，不中断已有挂载。仅改变主 App 退出处理，不改 File Provider 存储格式、App Group、共享钥匙串、认证、NAS 请求、签名或权限。Windows 与移动端不在本次范围。

## 原因与修改

- 原 `DesktopDriveMenuBarController.prepareForTermination()` 写入 `providerAvailable=false` 并逐个 disconnect；扩展 `ProviderRuntime.makeContext()` 据此在读取共享会话前返回不可达。这解释了用户观察到的“退出不能读，启动后又能读”。
- 普通退出现在仅结束主应用菜单状态，不停用提供器、不断开域、不清除会话。App 启动时的既有恢复流程保留，能够恢复旧版本留下的不可用状态。
- 手动暂停/恢复、移除映射、退出 NAS 登录仍沿原路径执行；扩展仍检查暂停状态、服务可用状态与会话，不取消这些安全边界。
- 为退出回归注入临时配置目录；不操作用户的真实配置、挂载或钥匙串。

## 已运行验证

`swift test --package-path apple --jobs 4 --filter 'DesktopCloudDriveManagerTests|ProviderRuntimeTests|SharedKeychainSessionStoreTests|ConnectionFlowTests'`：78 项通过。

`swift test --package-path apple --jobs 4 --filter 'DesktopDriveMappingTransactionCoordinatorTests|DesktopCloudDriveTests'`：65 项通过，相关回归共 143 项。

`xcodebuild -quiet -workspace apple/DsmNativeClient.xcworkspace -scheme DsmMac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath <独立临时目录> CODE_SIGNING_ALLOWED=NO build`：通过。核对产物同时包含主 App 和 `LanStashFileProvider.appex` 可执行文件。未签名、未安装、未启动；构建临时目录清理，不作为可安装验收包交付。

新增回归覆盖：退出后重新打开配置存储仍保持可用、映射/连接/缓存状态不变；用户已暂停的映射不被恢复；服务仍可用时，新的扩展实例可以枚举和下载合成文件。既有缺会话、暂停及退出 NAS 登录回归保留。

源码复核确认普通退出路径不再调用 setProviderAvailable(false)、disconnect 或会话删除。此为源码与合成测试证据，不是已安装版本的 Finder 实机验收。

## PENDING_USER_VALIDATION

- 前置条件：带本次修改、有效正式签名/共享权限且实际包含 File Provider 扩展的构建；已有映射及有效 NAS 会话。普通临时签名包会移除挂载扩展，不能替代该验收。
- 先启动新版本并确认已有挂载正常，恢复旧版退出留下的停用状态；从 Dock 菜单退出主 App，再在 Finder 打开此前未缓存的目录与文件。
- 预期：无需主 App 常驻即可列目录和按需读取文件。已手动暂停的映射仍不可在线访问；重新打开 App、恢复暂停后再可访问。主动退出 NAS 登录后应要求重新认证。
- 还需检查正在读取时退出、系统重新拉起扩展、会话过期、断网及 QuickConnect 地址变化；主 App 的主动批量任务不承诺随其进程退出继续运行。
- 失败反馈仅需版本、操作顺序、错误类型和脱敏状态，不回传凭据、真实主机、路径或文件正文。
