# macOS 账号与多 NAS 工作区修复

## 范围与基线

- 本轮由用户明确要求修改 macOS，不属于移动端或 Windows 对齐任务。
- 开始时 `git status --short` 为空；不修改 Android、Windows、移动端工程或公开契约。
- 截图仅作为问题线索，不复制其中的账号、设备地址或文件路径。

| 用户结果 | 当前源码证据 | 实施与验收范围 |
| --- | --- | --- |
| 文件区不出现整块蓝框 | `WorkspaceView.swift` 的文件网格与空状态使用 `.focusable()` | 仅关闭整块焦点效果；保留文件选择、键盘与无障碍行为 |
| 无权限应用不出现入口 | `WorkspaceModel.swift` 的模块开关与 `WorkspaceView.swift` 的菜单、功能设置 | 权限按每个工作区独立记录；依据既有只读请求，不推测管理员身份，不把网络失败或登录失效当作无权限 |
| 多级背景一致 | `MacAppearance.swift` 的内容色与 `MacGlassSurface`，设置与聊天的嵌套侧栏 | 内部页面统一内容底色；窗口外壳仍保留用户选择的透明度 |
| 多 NAS 不串登录状态 | `LoginViewModel.swift` 的异步连接、缓存工作区，`LoginView.swift` 的视图身份 | 检查账号快照、取消、迟到结果、工作区生命周期和错误归属；不修改凭据持久化格式 |
| NAS 列表清晰易用 | `WorkspaceView.swift` 的设备 popover | 去除列表独立底色，增加行高和选中态；保留排序与键盘操作 |

## 实际实现与关键决策

- 文件网格和空状态关闭整块焦点效果，保留焦点、选择、复制等键盘处理。
- 账号可用功能与原有按 NAS 保存的手动开关分离，仍使用原偏好键，不迁移数据。确认无权限、接口不可用或版本不支持时隐藏入口；网络错误、登录失效等单独保留恢复路径，不当作权限结论。
- 可用功能检查仅调用已有只读 Repository：文件共享目录、照片空间、聊天会话、系统概览、下载任务、容器与虚拟机清单。不新增 API，不按用户名推断管理员。首选功能就绪后先进入工作区，无关套件检查不阻塞主流程。
- 当前照片库基于 File Station 的可访问照片目录，不声称验证了独立 Synology Photos 套件权限。没有可访问照片空间时不显示照片入口。
- 菜单、功能设置、导航和关联入口使用相同判断。无权限时不显示新增本机挂载入口；已有本机挂载仍保留清理入口。
- 内部页面与二级侧栏统一内容底色；窗口外壳保留透明度设置。原生背景视图显式跟随 App 浅深色，选择条仍保留独立层次。
- NAS 选择列表使用统一底色、完整行点击区域、设备图标和选中标记；保留排序，不再使用固定时间的切换锁。
- 登录提交时固定账号、密码、验证码和保存选项；连接切换、取消、恢复登录均检查所属尝试，旧结果不能覆盖新工作区。
- 工作区视图按对象身份隔离弹窗、焦点和任务；旧工作区的重新登录回调不能清理当前设备。缓存工作区重新显示时保留当前页面。
- 恢复登录时，文件应用无权限或不可用不再导致整个账号的会话被清除；真正的登录失效仍要求重新登录，不做静默重放写操作。

## 独立集成与只读安全复核

- 实现完成后重新检查组合根、工作区切换、异步返回、菜单/设置/导航、权限分类及双语资源差异。
- 确认新增权限查询均为已有只读方法；没有新增写请求、凭据格式、会话存储、证书信任规则、依赖、签名或权限配置。
- 确认权限结果不落盘，不以译文判断业务，也不影响另一台 NAS 的偏好与权限结果。
- 用不响应取消的延迟认证替身检查旧连接返回与账号快照；用不同工作区检查旧错误回调不会退出当前设备。
- 没有访问真实 NAS，没有保存用户截图或复制其中的设备、账号和路径信息。

## 自动化验证

- `swift test --package-path apple --filter 'ConnectionFlowTests|WorkspaceNavigationTests|MacAppearanceTests' --jobs 4`：首轮 34 项通过。
- `swift test --package-path apple --jobs 4 --filter 'ConnectionFlowTests|WorkspaceModuleAccessTests|WorkspaceNavigationTests|MacAppearanceTests'`：当时 41 项通过。
- `swift test --package-path apple --jobs 4 --filter DsmMacTests --skip WorkspacePresentationTests`：236 项通过。
- `bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-workspace-ui.a6z9Qe`：完整界面套件 34 项通过，覆盖双语浅深色、大小窗口、放大文字、文件五态、设置/聊天/下载/容器/虚拟机/NAS 二级页与弹窗、键盘操作及 NAS 切换。只使用合成数据，渲染不代表真实 NAS 验收。
- `python3 tools/localization/check_localization.py`：双语、占位符、引用及硬编码扫描通过。
- `git diff --check`：通过。
- 有一次等待构建锁的重跑在源文件继续更新时中止，错误为 `input file ... was modified during the build`，不计作通过；停止源文件修改后重跑最终门禁。
- 最终 `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：818 项 XCTest 中 816 项通过、2 项跳过、0 失败；另 12 项 Swift Testing 全部通过。跳过项分别为未显式启用的十万条目录性能基准，以及未提供测试 ID 的真实 QuickConnect 中继测试；不计为验证通过。
- 最后运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test受限账号菜单功能设置与多NAS列表双语主题绘制|WorkspacePresentationTests.test无应用权限时保留本机设置并隐藏应用入口|WorkspacePresentationTests.test设置窗口保留原生按钮且不恢复白色标题栏' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-workspace-ui.a6z9Qe`：3 项通过，包含末次新增的全无权限场景；与之前完整套件有重叠，不直接相加。
- 已查看文件焦点、受限功能设置、无可用应用及 NAS 选择列表的实际浅深色合成截图。603 个临时合成产物已随专用临时目录删除，可由正式测试重建；用户提供的原始截图没有删除。
- 最终资源扫描：Apple 3804、Android 2082、Windows 1881，双语、占位符、引用及硬编码检查通过。

## 首次本地交付状态

- 修改范围为 6 个 macOS 源文件、3 个 macOS 测试文件、2 个语言资源文件和本记录，共 12 个文件。
- 工作区仅保留本任务修改；没有暂存、提交、推送或替换用户正在运行的 App。
- 已完成本机 Debug 构建与自动化；没有执行正式签名发布、Release 打包或真实 NAS 验收。

### 本地打包准备（2026-09-08）

- 用户请求生成本地测试包。检查发现新增 `WorkspaceModuleAccess.swift` 尚未进入 Xcode 打包目标；已使用项目 CI 固定的 XcodeGen 2.46.0（校验发布归档 SHA-256）重新生成工程，只增加该源码的 4 处成员记录。当前交付范围因此增加 1 个生成的工程文件，共 13 个文件。
- `git diff --check` 通过；未安装或升级本机工具链，没有修改 Bundle ID、权限或签名配置。
- 已安装版本使用 Developer ID 签名，但本机缺少其可用签名身份；本机存在 Apple Development 身份。按项目规则，改变签名方式前需用户明确同意。尚未执行 Release 打包、安装覆盖或启动测试 App。

### 正式签名测试包授权（2026-09-08）

- 用户确认正式版由 GitHub 构建，并明确授权将本次 macOS 修改提交、推送至独立测试分支，调用现有正式签名流程后下载到本机。
- 专用分支：`codex/macos-account-workspace-test-20260908`。只纳入本任务 13 个文件，不合并 `main`，不创建发布标签、PR 或公开版本，不替换正在运行的 App。
- 使用现有 `macOS Release` 工作流和 `macos-release` 环境，参数固定为 `package_mode=release`、`enable_updates=false`、`publish_to_github=false`、`publish_validation=false`。证书及私钥仅由既有工作流在 Runner 内使用，不导出到本机、日志或安装附件。
- 保留现有版本与签名身份配置；通过候选包的来源提交和独立下载目录区分本次测试包。签名、公证、下载及本地校验结果以实际工作流和后续交付记录为准。

## PENDING_USER_VALIDATION

### 用户复测失败后的本地诊断轮次（2026-09-08）

- 用户报告上一轮正式签名测试包仍会提示登录过期，并补充“最先登录的 NAS 能播放视频，报错的是后续 NAS”；上一轮自动化和签名通过不代表此实机问题解决。
- 用户明确授权加入测试诊断代码，由用户运行后提供线索。后续开发测试改为本机临时签名，只有正式版才走 GitHub；该约定已写入根 `AGENTS.md`。本轮不提交、不推送、不触发 GitHub，也不改变 NAS 设置。
- 只读进程检查当时发现 1 个岚仓主进程；这不能证明故障发生时没有其他登录，也不据此排除服务端的重复登录中断。
- 依据 [Synology DSM Login Web API Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf) 区分 106（超时）、107（重复登录中断）、119（无效登录）。截图没有具体错误编号，因此当前根因仍未验证，不把并行请求、编码或账号切换中的任意一项直接定为根因。
- 已核对正式登录 → 文件 Repository → 请求构造链路，以及按 profile 保存会话的实现；没有发现所有 NAS 共用一个 SID 的静态实现。新增双 NAS 首次文件请求测试，覆盖 FORM/JSON、不同主机与端口、第二台登录后再次读取第一台，并验证 POST 正文和认证 Header 的对应关系、URL 不包含认证信息。这只是合成请求证据，不是 NAS 实机证据。
- 上一版会同时探测全部模块，容器与虚拟机探测还会展开为多条请求。本轮改为文件优先、模块顺序检查，首个认证错误立即停止余下检查，保留错误本身供诊断；不添加猜测的重新登录或认证参数 fallback。
- 初始文件加载不再自动进入第一个共享目录后再返回根目录；防止加载中重复进入。重试按当前目录真正发起读取，成功后清理旧认证提示，不因为共享目录缓存非空就跳过。
- 认证提示新增“复制问题详情”：仅复制版本、静态操作标签、问题分类、NAS/HTTP 编号、随机请求参考编号、登录/API 版本、请求编码、新登录/恢复登录及验证令牌是否返回。绝不包含 SID、SynoToken、Cookie、密码、账号、主机、文件路径或响应正文，也不把技术详情直接混入默认提示。
- 用户追加要求移除视频预览的外层系统界面。视频预览不再预留系统标题栏高度、12 点外边距和第二层描边，隐藏系统窗口按钮，保留原自带关闭与全屏入口及窗口拖动；其他预览类型及主窗口保持原行为。
- 已运行 `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：823 项 XCTest 中 821 项通过、2 项原条件跳过，另 12 项 Swift Testing 通过。
- 已运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test视频预览没有外层系统按钮和留白且自带关闭有效|WorkspacePresentationTests.test照片预览与视频控制区继承主题且不发起写操作|WorkspacePresentationTests.test文件五态与双语双主题快照|WorkspacePresentationTests.test文件与设置往返保持窗口及当前目录' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-login-preview-ui.tai0BX`：4 项通过。视频外壳使用合成失败状态检查，不代表真实视频流或全屏实机播放已经验证。
- 第一轮聚焦测试有 1 个关于认证错误等同普通失败的旧期望失败；已改为严格断言保留独立认证错误及其内容，并增加顺序、停止和隐私检查，后续聚焦 49 项与上述全量通过。未降低权限、身份校验或真实环境门禁。
- 本地化扫描（Apple 3821）与 `git diff --check` 通过。首次本地 Debug 编译成功，但打包脚本只在主可执行文件寻找 Chat 符号，而当前 Xcode 将代码放在 `LanStash.debug.dylib`，因此既有校验中止；已确认动态库包含对应界面，没有跳过校验或修改发布脚本。
- 改用既定 `package.sh` 的 Release 配置、当前 Mac 架构、构建号 `20260908.2` 生成独立临时签名诊断包。诊断代码没有被编译条件关闭；应用标识沿用已安装版本，不包含本地磁盘挂载扩展。打包与最终清理结果以实际执行为准。
- 本机 Release/arm64 临时签名打包完成，版本 `1.0.0 (20260908.2)`；`codesign --verify --deep --strict`、`hdiutil verify`、镜像内版本/双语诊断资源及无扩展检查通过，并用不跟随符号链接的 rsync dry-run 确认镜像与输出 App 内容一致。DMG SHA-256 为 `92a40ebe5691d1a4f4eeb2f5808a67fdb2eba2ceca4210ddc6b1f0893c9b7494`。独立输出目录为用户“下载”中的 `LanStash-local-diagnostic-20260908-2`，保留 App、DMG 与诊断说明；未自动安装或启动。
- 本轮 34 张临时合成截图与约 744 MiB 的打包中间目录已清理，可由正式脚本重建；旧正式包、用户截图、已安装应用及共享 SwiftPM 缓存未删除。真实根因仍等待用户运行本地诊断包后返回白名单详情，本轮改动保持未提交。

本轮用户操作：先完全退出其他岚仓版本，打开构建号 `20260908.2`；先登录正常 NAS，再登录报错 NAS。弹出问题时选择“复制问题详情”并回传内容，不需要提供任何凭据或原始网络响应。根据编号和登录上下文继续确认根因；如未报错，继续来回切换两台 NAS 并检查文件目录。此诊断轮次没有把真实问题标为已修复。

### 本地临时包启动检查补充

- 用户报告打开即失败。提供的报告标注旧版 `0.2.8 (20260907.2)`，终止原因是 DYLD 无法加载 Sparkle，库与进程签名团队不匹配。没有将原始报告中的设备、事件标识和路径复制到仓库。
- 对本轮 `1.0.0 (20260908.2)` 重新检查：主 App、Sparkle 与其辅助组件均为 ad hoc 签名且无 Team ID，同时主 App 开启 Hardened Runtime。签名完整性通过并不证明运行时库验证能够通过。
- 在一次性、无 NAS/账号访问的 C 加载器中复现：使用与测试 App 相同的 ad hoc + runtime 签名，加载系统库成功，加载本轮包内 Sparkle 失败，并返回同一类 Team ID 不匹配错误。
- 仅在该一次性加载器上添加 `com.apple.security.cs.disable-library-validation` 后，保持 runtime，实际加载同一 Sparkle 成功。依据为 [Apple 库验证说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)。没有修改系统安全设置、产品包权限或正式签名流程。
- 这确认了临时包启动问题，不是 NAS 登录根因。已将该包的说明标记为暂勿使用；更改测试 App 权限前仍需用户明确同意。一次性加载器源码、二进制及测试权限文件在检查后清理。
- 用户随后明确同意仅本地临时包增加库验证例外。已添加独立测试权限文件和临时签名/加载校验脚本，原正式 App 与扩展权限文件不改；正式分发门禁新增拒绝该测试例外。系统 Gatekeeper、SIP、NAS TLS 校验均未修改。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：18 项通过，含真实合成动态库加载前失败/后成功、保留 runtime、测试权限仅一个键、正式分支隔离与正式门禁拒绝回归。首次新测试遇到 `codesign` 默认输出不是 plist XML，已改为显式 `--xml`，保留完整字段断言。
- 本轮业务代码没有继续变化，复制上一诊断版的已验证业务二进制，仅提高产物构建号至 `20260908.3` 并使用新的临时签名脚本重新签名；不覆盖 `20260908.2` 或正式版。重新打包前已运行 `verify_macos_local_test.sh`，用实际包内权限在隔离程序中成功加载实际 Sparkle 组件。完整 App 界面与真实 NAS 仍由用户手动运行验证，未自动读取用户登录资料。
- `20260908.3` 的 App 和 DMG 已生成；镜像完整性、镜像内签名、单一测试权限、实际 Sparkle 加载、构建号、诊断资源与输出 App 一致性均通过。SHA-256：`73aa4e42be0351709bf1bc8222775a77e4076103d0c1dad0ab5b592345b55f2a`。产物保存在用户“下载”中的 `LanStash-local-diagnostic-20260908-3`；隔离加载器和镜像暂存目录已自动清理，旧包保留为失败基线。本轮没有提交、推送或触发 GitHub。

### 用户返回首次有效诊断（2026-09-09）

- 用户运行 `1.0.0 (20260908.3)` 后返回：操作 `files.list`，分类 `authenticationRequired`，NAS 编号 `119`，登录 API v6、文件 API v2/JSON、本次新登录、验证令牌已返回。未记录无诊断必要的随机请求参考编号。
- 这证明此次错误发生在文件夹读取阶段，不能继续称为“没有返回验证令牌”或“恢复了过期旧登录”。119 是无效会话，不等同于 106 超时或 105 权限不足；但该元数据并未记录实际发出的认证字段，也不足以确认会话在何时变为无效。
- 已重新核对 `listShares` 与 `listFolder`：两者使用同一 Repository 的不可变凭据和同一请求构造器；文件夹请求另带目录参数，当前 JSON 编码依据既有能力信息。未据此降版本、变更认证参数或改变 NAS 安全设置。
- 下一步无需换包：保持同一次登录，返回最外层共享目录并主动刷新，再打开文件夹，分别观察结果。根目录仅显示缓存不算成功，必须执行刷新。用于区分共享列表也拒绝登录与只有目录读取失败，再决定是否需要进一步请求轨迹；根因尚未确认。

### 第二轮请求诊断包（2026-09-09）

- 用户补充最外层主动刷新也返回 `files.operation` / `119`。之前可见共享目录可能来自缓存，不能据此把问题限定为文件夹参数。用户已授权自行完成本地打包，不再等待额外确认。
- 新增仅在本地临时包显式开启的内存请求轨迹，分别使用当前工作区的登录结果核对凭据是否缺少、匹配或不匹配；记录白名单 API、方法、版本、请求顺序和数值错误，附加模块检查与聊天同步起止标记。最多保留 40 条请求和 40 个标记，保留最初请求与近期请求；复制时取最新状态。
- 不记录真实凭据、地址、账号、目录、请求正文或响应正文，不写磁盘，不上传；不增加网络请求，不改认证参数、TLS、Cookie、重试及下载上传行为。正式分发校验拒绝开启该诊断标记。根因仍未确认，不宣称修复 119。
- 通过项目固定 XcodeGen 2.46.0 重新生成工程，新增轨迹源码成员；没有安装全局工具或修改工程身份。新增 6 项合成测试覆盖透明转发、隐私白名单、凭据匹配、URL 与正文区分、工作区隔离、有界记录及网络失败不重试。
- `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：829 项 XCTest 中 827 项通过、2 项既有条件跳过，另 12 项 Swift Testing 通过；`python3 -m unittest discover -s tools/release -p 'test_*.py'`：18 项通过。`python3 tools/localization/check_localization.py`：Apple 3822 项资源及双语完整性、占位符、引用、硬编码扫描通过。本轮未重跑界面截图套件，上轮 4 项仅作为原有界面变更证据。
- `LANSTASH_CONNECTION_TRACE=1` 配合既定 `package.sh` 的 Release、native/arm64、临时签名、禁止自动运行配置生成 `1.0.0 (20260909.4)`。App 与 DMG 均完成；`verify_macos_local_test.sh` 在输出包及只读镜像内均通过签名、唯一测试权限、runtime、无挂载扩展、禁用在线更新及实际 Sparkle 加载检查。
- `hdiutil verify`、镜像内构建号/诊断开关/双语资源检查通过；rsync checksum dry-run 无差异。DMG SHA-256：`debfa0d665ed2845d94f304a2bbeee01409871285301dcf85e521f9a39093ca3`。独立输出目录为下载中的 `LanStash-local-diagnostic-20260909-4`，保留 App、DMG 与复测说明；没有安装覆盖、自动启动、访问真实 NAS、提交、推送或触发 GitHub。

- 收尾 `python3 tools/codex/check_documentation.py --strict-release`、本地化扫描与 `git diff --check` 通过；只读镜像已卸载，约 18 MiB 临时工具与 743 MiB 编译中间文件已删除，可重新生成。新旧交付包、用户资料、已安装版本和共享 SwiftPM 缓存保留；源码改动未暂存、未提交。

本轮复测使用 `20260909.4`：完全退出旧岚仓，直接运行新 App，先连接正常 NAS，再连接报错 NAS；在报错 NAS 最外层主动刷新，出现提示后复制问题详情并回传。详情应包含新增请求顺序，凭据仅显示匹配状态；不需要提供密码、原始响应或更改 NAS 安全设置。若无报错，继续往返切换并读取文件夹。完整启动与真实 NAS 验证仍为 `PENDING_USER_VALIDATION`。

### 文件单独运行对照（2026-09-09）

- 用户返回 `20260909.4` 的轨迹：共享目录请求 2、4 成功，目录请求 7、12 也成功；容器请求 27 返回 119，随后用户打开目录的请求 32 同样返回 119。上述请求的正文会话、Cookie 会话、正文令牌与 Header 令牌均匹配该工作区本次登录结果。请求序号为发起顺序，不代表并行请求的完成顺序；这些证据不证明容器检查导致会话失效。
- 用户同意继续做隔离对照。本轮仅新增本地诊断开关 `LANSTASH_DIAGNOSTIC_FILES_ONLY=1`：工作区只检查文件权限，其他套件入口在内存中不可用；聊天后台任务沿用原有入口开关，不会启动。文件请求构造、认证、重试、TLS、用户功能偏好和存储格式不变。文件功能自身的已有辅助读取保留，不将此次对照称为“只有一条请求”。
- 轨迹 JSON 增加 `filesOnly` 布尔标记。没有新增用户可见文案或修改语言资源；输出说明解释本包只显示文件属于预期限制。正式分发拒绝携带该限制，打包只允许临时签名且同时开启请求排查；未开启时行为不变。
- 修改范围：`WorkspaceModel.swift`、`LoginViewModel.swift`、`WorkspaceRequestTrace.swift`、两个聚焦测试文件、`package.sh`、正式分发检查及其测试、本记录。没有改动其他平台、API 契约或应用身份，也没有复制原始用户诊断或随机请求标识到仓库。
- 独立集成与只读安全复核：只检查文件的筛选覆盖初次启动、手动刷新可用功能和错误恢复后的复查；入口可见性同时控制导航与聊天同步，不持久写入套件禁用值；默认参数为 false，正常多模块测试继续覆盖原行为。没有新增凭据输出、网络请求或自动重新登录。
- `swift test --package-path apple --jobs 4 --filter 'WorkspaceModuleAccessTests|WorkspaceRequestTraceTests'`：16 项通过，覆盖只检查文件、其他套件导航不可用、聊天入口关闭、用户偏好恢复、认证错误保留及轨迹标记。`python3 -m unittest discover -s tools/release -p 'test_*.py'`：19 项通过，含诊断开关签名限制和正式包拒绝的可执行 shell 测试。`bash -n apple/Apps/DsmMac/package.sh tools/release/verify_macos_distribution.sh` 与 `git diff --check` 通过。

- 完整 `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：832 项 XCTest 中 830 项通过、2 项既有条件跳过，另 12 项 Swift Testing 通过。`python3 tools/localization/check_localization.py`：Apple 3822 项及双语、占位符、引用、硬编码检查通过；`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。本轮未运行界面截图或真实 NAS 测试。
- 本地 `package.sh` 以 Release/native/arm64、临时签名、禁止自动运行、构建号 `20260909.5` 及两个诊断开关完成打包，沿用安装版身份。`verify_macos_local_test.sh` 在输出 App 与只读 DMG 内均通过签名、唯一测试权限、runtime、无扩展、禁用在线更新及实际 Sparkle 加载；镜像内构建号与两个开关核对正确，rsync checksum dry-run 无差异，`hdiutil verify` 通过。
- 输出目录为下载中的 `LanStash-local-diagnostic-20260909-5`，包含 App、DMG 与复测说明。DMG SHA-256：`40fbf7ab728dd0e5e5422c73d882c94f219dd13bb2336c405b443910bb859be4`。镜像已卸载，744 MiB 本轮编译中间文件已删除，可重新构建；旧交付包、已安装版、用户文件与共享缓存均保留。全部改动未暂存、未提交；没有推送、GitHub 构建、自动安装或启动。

`PENDING_USER_VALIDATION`：使用新登录运行 `20260909.5` 文件对照包（自动恢复时先退出对应 NAS 登录再重新登录），先正常 NAS 后故障 NAS，打开之前失败的目录并刷新，往返切换两台 NAS；如失败，复制问题详情（应含 `filesOnly: true`）。如果稳定，只能支持“后台套件检查／同步路径与问题相关”的方向，不能直接指定某个套件为根因；下一步逐项恢复验证。如果仍失败，则继续定位文件请求与登录有效性。无需改变 NAS 设置或执行写操作。

这表示待用户验证，不是已通过或阻塞其他独立功能。

前置条件：使用本轮源码构建的 macOS App；至少两台真实 NAS，以及有权限差异的账号。保留现有签名与运行权限配置，不需要提供密码、令牌或原始响应。

1. 分别连接两台 NAS，来回切换文件、照片、消息和具备权限的套件页面；返回第一台再切到第二台，刷新、打开目录并查看只读详情。预期页面、账号、目录与选中 NAS 一致，不因切换而出现另一台设备的登录提示。
2. 在连接尚未结束时取消或选择另一台 NAS。预期最终只显示当前选择的设备，旧连接的完成、失败或证书提示不能覆盖新连接。
3. 使用非管理员账号检查菜单及“应用设置 → 功能”。已确认无权限的应用不出现；有权限的应用仍可进入。权限变化后选择“刷新可用功能”，或重新登录，再核对入口。
4. 检查文件区点击、方向键与复制，确认没有整块蓝框但仍能辨认所选文件。切换浅深色，查看设置二级页、聊天侧栏与详情背景；核对两台/多台 NAS 列表的选择和排序。
5. 如有既存本机挂载，在文件权限撤销后确认仍能移除该本机挂载，而不能新增挂载。不要为本轮验收执行 NAS 删除、关机或其他危险写操作。

需回传的失败信息：NAS 使用 `lab-a`、`lab-b` 等匿名标识；描述连接顺序、连接方式类别、发生问题的页面、DSM 与套件版本、账号是否具有对应应用权限，并提供隐藏设备地址、账号、路径及内容的截图。禁止回传密码、Cookie、会话标识、原始 HAR 或未脱敏日志。

影响范围：macOS 工作区、账号可用入口、连接生命周期及新增中英资源；其他平台代码没有修改。真实环境下的权限判定、长时间保持连接、原生背景合成与辅助功能体验仍待上述验证。

## 权限摘要替代逐组件试探（2026-09-09）

### 用户确认的规则与范围

- 用户确认先限制为岚仓已有模块，未知第三方应用完全忽略；文件、Chat、下载、VMM 仅明确授权才显示，缺项/false 隐藏；NAS 设置整体只对已确认管理员开放，容器按已观察的管理员管理入口处理，显式 false 不得被管理员身份覆盖。
- 用户补充容器和 VMM 为手动安装且机型官方不支持；不据此添加机型或安装渠道拦截。仍要求既有接口能力，不把菜单可见等同于业务及危险写操作已通过验证。
- 本机设置始终保留。照片沿用现有 File Station 文件视图语义，继承文件授权，不读取 Synology Photos 内部接口。
- 用户决定先修正不该发出的请求，若已授权模块仍出现 119 再继续针对性定位。不宣称 NAS 因越权主动踢出登录的猜测已被证明。

### 实际修改与安全复核

- `DsmDesktopAppPrivilegesService` 只读内部 get_user_service，v1 通过现有能力发现协商；使用已观察 GET/launch_app=null，复用现有 GET Header 认证与 TLS，不把凭据写 URL，不重试或猜测不同参数。
- 解码只保留已有模块应用键与 is_admin；忽略未知应用、完整 Session、UserSettings 和其他私密内容。空权限表有效，整表缺失/已知字段类型错误则失败，不伪造“全部无权限”。
- `WorkspaceModuleAccessReader` 一次读摘要，不再依赖聊天/系统/服务 Repository，不再调用容器、虚拟机、下载列表来探测权限。摘要失败只保留原文件只读确认，其他套件关闭；安全错误和取消不追加请求。文件 119 原样保留。
- `WorkspaceModel` 整体替换权限结果，避免上次授权残留；可见性同时限制导航及后台模型。本机设置里的摘要失败提示同步中英资源，并提供原有刷新入口。
- `ServiceManagementModel` 增加启用模块限制，拒绝隐藏模块的旧页面加载、设置读取、控制台和操作回调；权限撤回后不接纳迟到的加载结果。原确认、重复提交及结果校验保持不变。已发出的服务端操作不能被本地隐藏逆转，本次不据此宣称自动回滚。
- 恢复登录优先读取权限摘要，已知无文件权限时不再通过文件列表试探登录；摘要不可用时保留既有只读文件确认。普通新登录的权限摘要在工作区内独立读取，无账号名或机型推断。
- `20260909.6` 打包关闭 files-only 限制，保留仅测试包可用的脱敏请求详情；正式分发仍拒绝诊断标记和测试签名例外。
- 只读对抗复核覆盖：非管理员即便返回管理应用键 true 也不显示 NAS 设置/容器；管理员不能覆盖明确 false；未知第三方键类型异常不影响白名单；有效空表零业务请求；摘要失败不尝试其他套件；隐藏模块直接收到旧回调仍零请求；两台 NAS 和用户本机偏好互相隔离。

### 五端影响与验证

- macOS 接入新摘要服务；共享 DsmNetwork 只增加能力和服务，DsmAPIClient 新增内部可选 GET 参数，默认 POST 不变。iPhone/iPad 的能力发现可登记新名称，但移动 App 未调用摘要服务；Android/Windows 无代码或请求变更。未修改 DsmCore 领域契约、依赖、工具链、身份、签名策略、持久化结构或写权限。
- 发现文档、机器索引与产品矩阵已同步实现状态；设备匿名归属及 App 会话实机验证仍待确认，不把网页观察升级为 App 已验证。
- 首轮编译发现 App 层误引用网络内部 DsmEndpoint，已将 URL 组装留在网络服务初始化器中；下一轮发现合成文件传输替身缺少 DsmBinaryHTTPTransport 协议方法，补齐为记录后拒绝的测试实现。未放宽断言。
- `swift test --package-path apple --jobs 4 --filter 'DsmDesktopAppPrivilegesTests|WorkspaceModuleAccessTests|WorkspaceRequestTraceTests|ConnectionFlowTests'`：46 项通过。
- `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：840 项 XCTest 中 838 项通过、2 项原条件跳过，另 12 项 Swift Testing 通过。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：19 项通过。`python3 tools/localization/check_localization.py`：Apple 3823 项及双语、占位符、引用、硬编码检查通过。
- `python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture 与 20 项私有 API 文档引用通过；严格文档与 git diff --check 通过。系统和已有打包运行环境均无 jsonschema，额外的 Draft202012Validator 检查未能运行；未因此新增依赖，不能将引用检查表述为完整 JSON Schema 验证。

### PENDING_USER_VALIDATION

运行 build 20260909.6，重新登录普通账号和管理员账号分别对照：普通账号隐藏 NAS 设置和容器及未授权应用，本机设置保留；管理员按已授权应用显示，容器/NAS 设置遵循原本机功能偏好（如曾关闭需在本机设置开启）。先浏览文件，停留并刷新，再逐个进入允许显示的模块，返回文件继续浏览，往返切换 NAS。失败时回传“复制问题详情”和发生步骤，不提供凭据、账号、主机、路径或原始响应。摘要不可读时应看到可用功能刷新提示，其他套件保持关闭，不进入写操作来验权。

未验证风险：App 登录会话与网页会话的权限摘要读取兼容性；管理员与普通账号在真实 NAS 的入口及后台活动；已授权 Chat 的既有读取失败是否仍存在；手工安装套件的业务兼容性；原 119 是否彻底不再出现。不要通过删除、启停服务、修改权限或 NAS 设置进行本轮验收。

### 本轮打包与收尾结果

- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test受限账号菜单功能设置与多NAS列表双语主题绘制|WorkspacePresentationTests.test无应用权限时保留本机设置并隐藏应用入口|WorkspacePresentationTests.test文件五态与双语双主题快照' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-permissions-ui.mpBBl1`：3 项通过。已查看无应用权限浅色设置与受限账号深色功能设置截图；34 张合成产物已清理，可由正式测试重建。
- 本地 Release/arm64 `package.sh` 完成 `1.0.0 (20260909.6)`，保留现有安装身份，仅启用连接轨迹、不启用 files-only。输出 App 与只读 DMG 内的 `verify_macos_local_test.sh` 均通过，含签名、唯一测试权限、runtime、无挂载扩展、禁用在线更新和实际 Sparkle 加载。
- 镜像内构建号、两个诊断开关状态、双语新资源检查通过；`nm | swift-demangle` 确认权限摘要代码进入二进制，`get_user_service` 字符串存在。直接搜索未还原的 Swift 符号名首次未命中，不作为代码缺失结论；随后使用还原符号核验。
- `hdiutil verify` 通过，rsync checksum dry-run 无差异；DMG SHA-256：`2ef9a912f14e0d156ef17bfa4ebe74872db127c142c8ee8daa3566aa2e2cad2e`。输出目录为下载中的 `LanStash-local-diagnostic-20260909-6`，保留 App、DMG 与验证说明。
- 镜像已卸载，744 MiB 本轮编译目录和 4.4 MiB 合成截图目录已删除，可重新生成；旧包、用户文件、已安装应用与共享 SwiftPM 缓存保留。仅通过 Finder 定位新包，未自动运行、安装覆盖或连接 NAS；全部修改未暂存、未提交、未推送。

## 移除临时诊断并重新打包（2026-09-09）

- 用户确认 VMM 官方网页也拒绝该账号的具体操作，本轮不改 VMM 权限规则或空列表展示；随后明确要求删除测试代码并重新打包验证。
- 本次删除的是临时诊断实现，不是正式测试体系：移除 WorkspaceRequestTrace.swift、专用轨迹测试、诊断传输包装、登录元数据、工作区诊断状态、复制详情按钮及双语资源、files-only 对照分支和打包注入开关。仅服务于已删除临时功能的测试相应删除或改为“不再注入诊断开关”回归。
- 正式账号隔离、权限摘要、非管理员管理入口关闭、隐藏模块零请求、错误恢复及隐私断言保留；原断言从“诊断详情存在”改为“正常错误提示和恢复状态正确”，不减少实际业务验证。保留项目本地签名脚本、唯一测试权限及实际组件加载校验，以免复现旧临时包启动问题；正式分发仍拒绝旧诊断产物。
- 使用仓库固定 XcodeGen 2.46.0，核对下载归档 SHA-256 后重新生成工程，移除已删除源码的成员记录；未手改生成工程或安装全局工具。
- 网络请求回到各 Repository 原有独立 transport；权限摘要服务继续使用相同的 TLS 与 Header 认证配置。没有改变应用身份、会话持久化、权限读取或业务功能。
- `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：832 项 XCTest 中 830 项通过、2 项既有条件跳过，另 12 项 Swift Testing 通过。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：19 项通过；`python3 tools/localization/check_localization.py`：Apple 3807 项及双语、占位符、引用、硬编码扫描通过；bash -n 与 git diff --check 通过。
- 历史章节中的临时源码及复制详情操作仅对应旧诊断包；新包不再提供该按钮。新的失败反馈只需说明操作步骤并提供脱敏截图，不要求原始响应或凭据。

`PENDING_USER_VALIDATION`：运行 20260909.7，分别用普通账号和管理员登录，核对入口与上一版一致、本机设置保留，来回切换 NAS 并浏览文件；已授权应用若官方也拒绝具体操作，保留权限提示，不将其视为整个登录失效。不通过 NAS 写操作验证权限。此轮仅清理诊断，仍需确认普通 transport 与上一版相同行为。

### 无临时诊断包交付结果

- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test受限账号菜单功能设置与多NAS列表双语主题绘制|WorkspacePresentationTests.test无应用权限时保留本机设置并隐藏应用入口|WorkspacePresentationTests.test已有共享列表时重试仍重新读取当前目录并清除旧认证错误' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-clean-ui.75a145` 实际匹配并通过 2 项 UI 测试；重试测试属于另一个测试类，另行执行 `swift test --package-path apple --jobs 4 --filter WorkspaceConnectionRecoveryTests`，1 项通过（与全量回归有重叠）。
- 查看受限账号功能设置合成截图；14 张合成截图已删除，可重建。临时 XcodeGen 工具约 18 MiB 与本轮编译目录 743 MiB 已清理，用户原图、旧包和共享构建缓存不删除。
- `package.sh` 本地 Release/arm64 完成 `1.0.0 (20260909.7)`；输出路径为下载中的 `LanStash-local-test-20260909-7`，包含 App、DMG、验证说明。仍为已授权的本地临时签名方式，不冒充正式签名或公证。
- 输出与镜像内 `verify_macos_local_test.sh` 均通过；版本、Info 无两个诊断键、二进制无临时轨迹/复制详情字符串、双语资源无诊断键检查通过。`hdiutil verify` 通过，rsync checksum dry-run 无差异，镜像已卸载。
- DMG SHA-256：`7b2590f2dcf6f49da444293a518f46060dcc262f3109f5bde16a8d8988b4920d`。
- 严格文档、fixture/私有 API 文档引用、双语及差异检查通过；未自动安装、启动或连接真实 NAS，未暂存、提交或推送。已通过 Finder 定位新包供用户运行。

## 侧边栏分组、首次默认与紧凑更新窗口（2026-09-09）

### 用户确认的变化

- 传输中心移至应用设置上方，与上方 NAS 组件分组；作为应用级入口始终保留。文件模块关闭时可以查看本地传输状态，但原 NAS 后台任务读取仍受文件模块开关限制，不新增网络活动或扩大操作权限。
- 默认只用于首次登录、尚无该 NAS 模块设置的情况：有权限的文件和照片默认开启，其余模块默认关闭。有权限但关闭的模块可手动开启；无权限的模块仍隐藏。
- 用户手动选择按 NAS 保存，重新登录、重启和切换不重置；权限撤回时隐藏并停止活动，权限恢复后沿用原偏好。旧 NAS 的显式选择及旧版隐式默认都保留，不批量重置。
- 更新窗口按用户参考改为紧凑卡片，无系统标题栏、红黄绿按钮或额外外框。直接展示状态图标、标题、说明与通栏操作按钮；下载使用横向进度条和百分比，未知总量时显示不定进度；长更新说明单独滚动。
- 用户指出下载上下空白后，移除填满固定高度的布局，改为测量实际内容高度并调整真实窗口，仅保留 24 点内边距；不再以大尺寸合成宿主的高度代表实际窗口。

### 实现与复核

- WorkspaceModel 沿用既有 LanStash_Module_<模块>_<profileID> 键，不增加持久化格式或版本标记；旧版总会保存的 NASSettings 及其他现有模块键用于识别旧 NAS。初始化前一次判定新旧，然后将默认/迁移后的结果固定到已有键；新 NAS 不继承旧全局开关，已存在的按 NAS 明确值优先。
- 传输中心从组件滚动区移到底部工具组，新增稳定无障碍标识；路由归属不再属于文件模块，进入传输中心仍不绕过文件后台读取的开关。
- AppUpdateWindow 仅用于更新卡片，允许键盘焦点；根视图按内容自适应尺寸并保留拖动。关闭、Escape、Command-W 均调用既有受阶段约束的关闭逻辑；准备/安装阶段原不可取消规则保留。不改变 Sparkle 版本、更新来源、安装策略、签名或 entitlement。
- 现有文案全部复用中英资源，无新增界面硬编码。涉及文件为 WorkspaceView.swift、WorkspaceModel.swift、AppUpdateController.swift、对应模块测试和合成界面测试、本记录。其他平台与 API 契约不变。
- 新增 4 项回归：首次授权组合默认、用户选择跨重建及权限恢复、旧 NAS/全局迁移不影响新 NAS、文件关闭后传输中心零读取。权限撤回测试显式模拟用户开启模块；综合 UI 样例也显式开启其测试模块，不用旧默认替代测试前提。
- 新增实际更新窗口检查：无系统外框、内容/窗口尺寸、自带关闭按钮、Escape、检查及下载阶段尺寸和 40% 进度；保留原中英浅深色各阶段不会自动安装、取消或重启的断言。
- 开发期间首次键盘事件检查失败，修正为原生快捷键派发；一次调用使用旧参数名导致测试编译失败，改为 performKeyEquivalent(with:)。自适应阶段发现首次视图测量早于窗口绑定，已先绑定窗口，再在实际尺寸变化时更新窗口；最终关闭及尺寸测试通过。未降低真实关闭断言。
- 为响应用户最后的留白调整，主动中止了一次尚未完成的本地 Release 构建（退出 75），修改后重新构建；中止不算成功。没有交付该中间产物。

### PENDING_USER_VALIDATION

在 20260909.8 检查侧边栏底部的传输中心/应用设置分组，已有 NAS 开关保持原状；有新 NAS 时再检查首次默认，勿为测试删除原配置。手动启停一个有权限模块，重启并重新登录后核对选择保留。打开更新窗口核对紧凑外观、拖动和关闭；本地临时包不启用在线更新，真实下载/安装仍需后续正式签名更新验证，不能用合成进度替代真实下载验证。权限和 119 修复不在本轮回退或重新扩展。

### 验证及交付

- 最终 `swift test --package-path apple --jobs 4 --skip WorkspacePresentationTests`：836 项 XCTest 中 834 项通过、2 项既有条件跳过，另 12 项 Swift Testing 通过。
- 最终 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test更新窗口无系统外框且自带关闭与Escape有效|WorkspacePresentationTests.test更新窗口双语主题各阶段不自动下载或重启|WorkspacePresentationTests.test受限账号菜单功能设置与多NAS列表双语主题绘制|WorkspacePresentationTests.test无应用权限时保留本机设置并隐藏应用入口' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-sidebar-update-ui.pecz1S`：4 项通过。查看了最终实际窗口的紧凑下载、深色结果卡片和底部分组截图，不以早期固定大宿主截图作为最终效果。
- `python3 -m unittest discover -s tools/release -p 'test_*.py'`：19 项通过；本地化扫描（Apple 3807）、严格文档和 git diff --check 通过。没有新增或更改文案键。
- 本地 Release/arm64 构建 `1.0.0 (20260909.8)` 完成。输出与只读镜像中的临时签名、唯一测试权限、runtime、无挂载扩展、禁用在线更新及实际 Sparkle 加载验证通过；镜像构建号和 fitWindow 实现符号正确，rsync checksum dry-run 无差异，hdiutil verify 通过。
- 输出目录：下载中的 `LanStash-local-test-20260909-8`，保留 App、DMG、验证说明及最终下载进度合成示例。DMG SHA-256：`4c98fdcd54a71813c2bf1e7bcbc79f4f1eff5b8d2c16d535e1269b418e4d2c70`。
- 镜像已卸载；744 MiB 本轮编译目录和 58 张临时合成截图（约 4.6 MiB）已清理，可重建。旧交付包、用户截图和共享缓存保留；没有自动安装/启动、真实更新、NAS 操作、提交或推送。

## 用户验收与版本库交付授权（2026-09-09）

- 用户确认 20260909.8 没有问题，并明确要求确认 main 最新、整合本次更新后，本地和远端仅保留 main 分支。
- fetch 后本地 main 与 origin/main 一致，基线为 b573eb3；本次工作整理为一个完整的 macOS 功能提交，遵循云端检查通过后再合并的规则。
- 分支清理仅删除分支引用，不删除 detached 工作区、用户文件、现有标签或发布记录；删除前建立本地 Git 备份。
- 上文“未提交、未推送”描述对应各次本地包交付阶段，本节记录用户随后授予的版本库交付范围；真实云端运行结果与最终提交以 Git/GitHub 记录为准。

### 云端签名回归环境差异修正

- 首轮 Apple Build 34305498773 的共享包测试通过，但签名回归中“添加库验证例外前必须加载失败”的断言失败：GitHub macOS 15.7.9 ARM64 / Xcode 16.4 环境在该步骤实际返回加载成功。仓库检查与文档质量检查均通过；当时没有合并或删除分支。
- 用户明确同意修正这项环境假设。测试现在先检查基线仍是 ad hoc + runtime：若基线可加载，必须确认实际加载输出；若拒绝，必须是预期的加载失败退出码及 Team ID/Library Validation 错误。
- 无论基线结果如何，最终签名后的真实加载成功、保留 runtime、ad hoc 身份及唯一测试权限断言都强制执行。不更改 App 代码、签名策略或正式分发安全门禁，不跳过该测试，也不推断系统安全配置的具体差异原因。
