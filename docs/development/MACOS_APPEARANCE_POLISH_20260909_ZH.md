# macOS 外观一致性修正（2026-09-09）

## 范围与决策

- 仅修改 macOS 界面与回归测试，沿用现有圆角按钮、分类侧栏、蓝色选中态与双语文案；不引入设计依赖。
- 更新窗口使用原生标题栏、关闭与最小化按钮、窗口阴影；标题栏可拖动。关闭与 Escape 沿用原有取消语义，准备及安装阶段不可关闭。
- 工作区共用一层窗口背后的原生模糊，侧栏、内容区和工具栏只叠加轻量主题色。透明度调整不降低文字、图标或窗口整体的不透明度；系统“降低透明度”继续使用实底。
- 滚动区域清除实色背景并使用系统覆盖式滚动条，不改变滚动内容、滚动方向和现有显隐配置。
- NAS 二级导航对齐应用设置的分类样式，保留上下键切换；主题选择、下载来源、会话类型三处旧分段选择改用已有 `MacPageTabs`。
- 文件详情、日志栏、NAS 卡片及子页面背景统一接入现有外观机制。文本输入与媒体预览保留其必要的可读背景。
- 未修改 API、认证、更新签名策略、应用标识、权限源文件、持久化结构或其他平台。

## 验证记录

- macOS 单测：先执行 `swift test --package-path apple --filter DsmMacTests`；最终复跑 `swift test --package-path apple --skip-build --filter DsmMacTests --skip WorkspacePresentationTests`，251 项全部通过。合成界面另行启用，不将默认跳过视为通过。
- 合成界面：`bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-ui-snapshots.JgZIDQ`，最终 37 项全部通过，覆盖双语、浅深主题、文件五态、子页面、更新窗口及键盘操作；仅合成资料，不连接 NAS，不执行真实写操作。新增断言确认真实工作区只有一层窗口背后模糊，滚动区域无实色背景。
- 本机 arm64 Debug 构建：`xcodebuild -quiet -workspace apple/DsmNativeClient.xcworkspace -scheme DsmMac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath <本次临时构建目录> CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build`。
- 本地化：`python3 tools/localization/check_localization.py`；差异检查：`git diff --check`。
- 测试包使用 `tools/release/sign_macos_local_test.sh` 与 `tools/release/verify_macos_local_test.sh`，验证临时权限边界、签名及 Sparkle 实际加载。只移除新测试包内的 File Provider 扩展，不修改旧安装包。
- 上述 arm64 Debug 构建、本地化扫描、差异检查及测试包验证均通过。完成独立差异复核：未改动业务请求、数据结构、更新签名和取消门禁；既有测试保留，旧无边框窗口断言按新需求改为原生窗口断言。
- 第一轮合成检查暴露了系统关闭未经过取消回调及全局按钮样式放大文字链接的问题；已改用窗口关闭委托，并取消全局按钮覆盖，保留聚焦回归。

## PENDING_USER_VALIDATION

以下是待用户验收，不代表已通过真机验证。

| 场景 | 前置条件与步骤 | 预期结果 |
| --- | --- | --- |
| 原先出现白条的电脑 | 使用新测试包；在系统滚动条“始终显示”和自动显示下，浏览文件网格、列表及 NAS 设置 | 无白色轨道；滚动和选中正常 |
| 玻璃透明度 | 分别选择雾白、烟墨，将窗口移到明暗不同的桌面背景上，拖动透明度滑杆两端 | 整体背景通透程度变化、背景保持模糊，文字不变淡；烟墨不变成白色面板 |
| 无障碍 | 打开降低透明度、增强对比度，使用键盘与 VoiceOver 操作分类和选择按钮 | 实底可读、选中态可辨认、键盘与读屏可操作 |
| 更新弹窗 | 临时包检查更新可检查提示窗口；实际检查、下载及安装阶段需正式更新渠道或合成回归 | 可拖动、系统按钮可见；可取消阶段只回调一次，安装阶段不能关闭 |
| 不同系统与硬件 | 在原问题电脑、其他受支持 macOS 版本及 Intel Mac 检查上述页面 | 与本机保持一致；当前构建仅验证 arm64 |

若失败，请回传 macOS 版本、芯片类别、App 主题、滚动条与无障碍设置，以及遮盖 NAS 名称、账号、地址和真实文件信息后的截图。测试包不自动安装或启动，不包含本地磁盘挂载扩展，在线自动升级保持关闭。
