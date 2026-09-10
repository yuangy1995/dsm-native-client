## macOS 1.0.3

- 安装包区分 Apple Silicon（M 系列芯片）与 Intel Mac，在线更新自动选择适合当前设备的版本。
- 照片模块接入 Synology Photos，支持时间线、年月快速定位、相册、分类、搜索和更多筛选条件。
- 开放个人照片空间的单张原件删除，保留确认、权限检查和删除结果核对。
- 修复部分 MP4 无法播放的问题；普通视频与实况视频根据可用播放版本选择来源。
- 去掉年月时间轴的大蓝色边框，保留键盘定位；统一照片页面与筛选面板外观。
- 改进更新窗口、任务状态和部分套件操作的错误处理。

本次仅发布 macOS 客户端，最低 macOS 14。手动安装请选择：
- Apple Silicon：文件名以 `-arm64.dmg` 结尾。
- Intel：文件名以 `-x86_64.dmg` 结尾。

已有支持在线更新的正式版可直接检查更新，无需更换更新通道。安装前请保存工作并等待应用内及 Finder 传输完成；不会升级 NAS 系统或套件，也不会重置已有账号及设置。临时测试版与正式版资料保持隔离。视频播放仍受系统支持的编码限制；删除会影响 NAS 原件，请先确认所选照片。

## English — macOS 1.0.3

- Separate installers for Apple silicon and Intel Macs. Online updates automatically select the package suitable for your device.
- Integrated Synology Photos with a timeline, year/month navigation, albums, categories, search, and expanded filters.
- Enabled single-photo original deletion in personal space, retaining confirmation, permission checks, and result verification.
- Fixed playback of some MP4 files. Ordinary and Live Photo videos now select an available playback source.
- Removed the large blue timeline focus outline while preserving keyboard navigation, and refined Photos and filter-panel styling.
- Improved update windows, task states, and error handling for selected package operations.

macOS only; requires macOS 14 or later. Choose `-arm64.dmg` for Apple silicon or `-x86_64.dmg` for Intel when installing manually.

Existing official builds with online updates can upgrade without changing channels. Save your work and finish app and Finder transfers before installing. This update does not upgrade DSM or NAS packages or reset existing accounts and settings. Test-build data remains separate. Video decoding depends on system support; deleting a photo affects its NAS original, so review the selection first.
