# macOS 本地磁盘挂载修复记录

## 范围与基线

- 用户目标：统一“云盘”说法为“本地磁盘挂载”，修复不能挂载或挂载后无法读取 NAS 文件的问题，提供本地测试包，由用户执行真实 NAS 验收。
- 基线：`9ca4d46`；开始时工作区干净。仅修改 macOS、相关 Apple 共享源码/双语资源及测试，不修改 Android、Windows、NAS API 契约或生成工程文件。
- 用户已同意调整本机共享登录状态的存储方式，并在后续明确同意补齐签名身份信息、使用同团队开发证书及由 Xcode 获取配套授权。NAS 写操作保持关闭；密码、私有加密存储、App Group、Keychain Group、Bundle ID、最低系统版本不变。
- 名称调整不改变 File Provider 原生位置与按需下载的实现，不新增 SMB/FUSE、独立块设备或全量同步。

## 原因与证据

1. `SharedKeychainSessionStore.baseQuery` 之前指定访问组却没有在 macOS 选择 Data Protection Keychain。旧式钥匙串不是该共享机制使用的存储；主 App 写入成功不能证明独立扩展可读取。依据：[Apple 访问组说明](https://developer.apple.com/documentation/security/ksecattraccessgroup)。本次统一增删读写的查询选择，不直接读取、迁移或删除旧式共享凭据；有效登录后重新发布当前会话。
2. `LoginViewModel.openWorkspace` 以 `try?` 忽略共享连接资料写入失败。主 App 继续使用内存里的新连接，而扩展只能读取缺失或过期的磁盘资料。本次把写入移至可重试的会话发布步骤，保存连接失败时不发布会话、不继续创建映射。
3. `ProviderRuntime.item(.rootContainer)` 和系统根目录重导入原先均调用 `makeContext`，使仅依赖本地配置的注册元数据也依赖登录与提供器在线状态。本次根信息独立读取；列目录、读取真实项目及下载仍经过原有登录、退出和暂停检查。登录恢复后同一 runtime 可以重新列目录、下载，不缓存认证失败。
4. `DesktopCloudDriveManager.verifyReadable` 检查主 App Repository，不是系统扩展进程的端到端验证。因此自动化通过不能证明 Finder 实机成功；此项明确交给签名包用户验收。
5. 额外发现签名链缺口：`package.sh` 使用源码 entitlement 文件重新签名，却未补入 `com.apple.application-identifier` 与团队身份字段。已安装版本的主 App/扩展签名也缺少前者，尽管包内存在 provisioning profile。Apple 要求该字段将程序和 profile 关联：[Apple DTS 说明](https://developer.apple.com/forums/thread/817268)。本次已补齐，且不再把 Apple Development 证书显示名中的个人后缀误用为团队 ID。截图的具体错误尚无可复现系统证据，不能断言只有此原因。

## 实际修改

- `SharedKeychainSessionStore.swift`：macOS 共享会话增删读写一致选择 Data Protection Keychain；不改变 iOS 行为及数据编码。
- `DesktopCloudDriveManager.swift`、`LoginViewModel.swift`：连接资料发布不再吞错；会话写入后读回确认；连接资料、共享登录、NAS 访问失败分别提供双语恢复提示，不显示内部错误正文。
- `ProviderRuntime.swift`：根信息与真实远端访问分离，不降低真实文件的认证、暂停或退出门禁。
- Apple 英语/简体中文资源、macOS README、打包提示：统一挂载名称，覆盖设置、创建、删除确认、状态、菜单、无障碍及兼容性反馈入口；保留稳定资源键与内部类型名称。
- 对应测试：共享查询选择、发布顺序、保存失败/读回失败、根项目无会话注册、认证恢复后的目录及内容读取、退出/暂停门禁、不存在的映射、错误提示分类和双语名称。
- `package.sh`：补齐主 App/扩展独立身份；初始化并严格提取签名团队；允许独立输出目录以保留旧包。新增签名字段合成测试与使用真实签名/profile 的双进程合成钥匙串检查。

## 验证

在仓库根目录执行：

```sh
swift test --package-path apple --jobs 4 --filter 'SharedKeychainSessionStoreTests|ConnectionFlowTests|ProviderRuntimeTests|DesktopCloudDriveManagerTests|DesktopDriveMappingTransactionCoordinatorTests'
swift test --package-path apple --jobs 4
python3 tools/localization/check_localization.py
bash -n apple/Apps/DsmMac/package.sh
git diff --check
```

- 首轮聚焦：99 项 XCTest，0 失败。
- 最终全量：776 项 XCTest，2 项原有条件跳过、0 失败；另 11 项 Swift Testing 通过。
- 跳过的是可选十万条目录性能基准、未提供测试环境的真实 QuickConnect 中继测试；未增加静默跳过。全量测试出现系统联系人服务不可用诊断，但测试断言均通过；该诊断不作 NAS 验证证据、不保存原始系统日志。
- 本地化完整性/占位符/硬编码扫描、shell 语法、差异空白检查通过。
- macOS Release / arm64 / 主 App 与扩展：首次与最终增量无签名构建均成功（退出码 0），两者可执行文件架构均为 arm64。构建使用现有已安装版本的身份配置作为命令行覆盖，未修改工程默认标识。构建号为 `20260907.1`。
- 首次编译新增查询测试遇到 actor 非 Sendable 返回值错误；已将无状态查询构造标为 `nonisolated`，之后聚焦和全量编译测试均通过。
- `python3 tools/release/test_macos_signing.py`：1 项测试通过，覆盖主 App/扩展分别补齐身份、重复执行以及其余权限字典完全不变。
- 已执行 `xcodebuild` 开发签名构建：第一次仅允许获取 profile 时因本机未登记失败；在用户批准的本机开发测试流程中允许登记当前 Mac 后成功，Xcode 获取两个对应 profile。未使用其他应用的 profile。
- `python3 tools/release/verify_macos_shared_keychain.py apple/Apps/DsmMac/dist/mount-repair-20260907/LanStash.app --identity <本机开发证书>`：使用最终包的签名权限与 profile，两个独立沙盒签名进程双向写入/读取合成钥匙串数据和 App Group 文件，删除及读空均成功（12 步返回 0）；自动清理合成条目、文件和临时程序。只证明本机签名/profile/共享访问组有效，不证明系统实际 File Provider 或 NAS 通信。
- 既定 `package.sh` 非交互 Release/arm64 打包完成，版本 `0.2.6 (20260907.1)`。使用签名构建所得主 App/扩展 profile，输出到独立目录，未覆盖旧包。
- `codesign --verify --deep --strict` 主应用/扩展、`codesign --verify --strict` DMG 和 `hdiutil verify` 均通过。只读挂载 DMG 后 `diff -qr` 验证包内 App 与输出 App 完全一致，再验证包内签名；验证挂载已卸载。
- 最终包内英中资源标题分别为 `Local disk mounts` 与 `本地磁盘挂载`，新增错误提示资源存在；最终手动签名未携带开发调试用 `get-task-allow`，未扩大原有文件和网络权限。

Release 构建命令（身份覆盖值来自已安装版本，下列读取方式复现相同参数，避免文档固定个人发布配置）：

```sh
mount_app=/Applications/LanStash.app
mount_extension="$mount_app/Contents/PlugIns/LanStashFileProvider.appex"
mount_app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mount_app/Contents/Info.plist")
mount_extension_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mount_extension/Contents/Info.plist")
mount_app_group=$(/usr/libexec/PlistBuddy -c 'Print :LanStashAppGroupIdentifier' "$mount_app/Contents/Info.plist")
mount_keychain_group=$(/usr/libexec/PlistBuddy -c 'Print :LanStashSharedKeychainAccessGroup' "$mount_app/Contents/Info.plist")
xcodebuild -quiet -workspace apple/DsmNativeClient.xcworkspace \
  -scheme DsmMac -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath apple/Apps/DsmMac/build/mount-repair-verification \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  "LANSTASH_MAC_APP_BUNDLE_ID=$mount_app_id" \
  "LANSTASH_MAC_FILE_PROVIDER_BUNDLE_ID=$mount_extension_id" \
  "LANSTASH_MAC_APP_GROUP_ID=$mount_app_group" \
  "LANSTASH_SHARED_KEYCHAIN_SUFFIX=${mount_keychain_group#*.}" \
  "SHARED_KEYCHAIN_ACCESS_GROUP=$mount_keychain_group" \
  CURRENT_PROJECT_VERSION=20260907.1 build
```

## 独立集成与只读对抗复核

- 重新核对实际差异和主 App → 共享配置/会话 → 扩展目录/下载链路，而非依据历史修复总结。
- 根项目返回仅含原有挂载元数据，不等于授权真实文件读取；新增测试证明未认证不能列目录/下载，退出或手动暂停仍拒绝列目录，不存在配置不伪造根目录。
- 未新增 NAS 写入、信任绕过、共享密码、旧凭据自动搬运或真实响应记录；共享会话仍使用现有访问组和仅限本机的可访问性策略。
- 未改动既有事务回滚和缓存保留语义；未以主 App 可访问来宣称扩展实机可访问。
- 没有执行提交、推送、安装覆盖、NAS 操作或已有挂载清理；只挂载并卸载了当前生成的 DMG 以核对内容。

## PENDING_USER_VALIDATION

### 签名与打包状态

- 使用同团队已有 Apple Development 身份；Xcode 已在本机测试授权流程中登记当前 Mac，获取主 App 与扩展配套的开发 profile。没有修改原 App ID 或访问组，也未混用旧 Developer ID profile。
- 独立输出目录为 `apple/Apps/DsmMac/dist/mount-repair-20260907`，包含 `LanStash.app` 和 `LanStash-0.2.6-arm64.dmg`；最终包检查已通过。旧 `dist` 顶层 App/DMG 和 `/Applications` 已安装版本未替换。
- DMG SHA-256：`799c15768c340712c83ba6403b37e6ce2da2c7a4949c98a71dd9500e0f5e3b58`。
- 已将本次签名验证/打包的临时构建目录、重复 DMG 暂存 App、解码 profile 和证书中间文件移入废纸篓，可恢复；最终 App/DMG、正式测试源码与 Xcode 获取的开发授权保留。
- 这是仅供已登记测试设备的开发签名包，不是 Developer ID 公证公开分发包。回滚为重新安装旧版并登录，不删除现有配置或缓存。

### 真实 NAS / Finder 操作

前置条件：先从菜单完全退出旧版岚仓，再将上述完整开发签名包安装到“应用程序”，允许对应文件扩展，确认构建号 `20260907.1` 并重新登录 NAS。不能从临时签名主应用包验收此功能；本包没有完成公开分发公证，仅供已登记设备测试。

1. 设置 → 本地磁盘挂载 → 添加挂载 → 全部共享文件夹，保留默认缓存磁盘。预期 Finder 出现挂载，可列共享目录并打开子文件夹。
2. 打开小型文本、图片与较大文件，核对内容可读；只下载访问的内容，不把空目录当作认证失败的成功结果。
3. 移除后重新挂载；再测试当前文件夹范围。预期挂载不重叠、不出现旧范围残留，NAS 文件不变。
4. 暂停/继续、断网/恢复、退出/重新启动、重新登录后读取；预期状态有恢复路径，认证恢复后可重新列目录和打开文件。
5. 若使用外置缓存磁盘，单独检查插拔与重新连接；未执行前不宣布外置盘验证通过。
6. 中英切换、浅深色、键盘、VoiceOver 与大文字：检查设置标题、创建框、错误提示和菜单不截断，按钮可操作。

失败时回传：App 构建号、macOS 版本、连接方式类别、失败步骤、脱敏截图及应用内诊断摘要。不要回传 NAS 地址、账号、密码、会话、真实路径、未脱敏日志或原始响应。

影响范围：macOS 本地磁盘挂载；Apple 共享资源名称同步，其他平台实现未修改。本机开发签名包已完成上述验证，可交给用户测试；实际 Finder 调度、NAS 文件访问、外置磁盘及界面人工验收仍为 `PENDING_USER_VALIDATION`，不得表述为已通过。
