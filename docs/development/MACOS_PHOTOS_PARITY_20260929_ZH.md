# macOS Photos 网页对齐：2026-09-29 交付与待验证账本

## 当前交付：三项统一收尾本机测试包（2026-10-01）

贡献者资料/标签/时间/评级/旋转及手动人脸资格已按官方静态证据对齐；上传队列和操作回执新增跨重启恢复，未知结果只核对、不重放，未开始项等待用户继续；列表20种、预览19种动作及全局设置已逐项映射并收尾。完整清单、实现、安全审查与真实NAS待验步骤见文末“三项收尾实施账本”。

统一验证通过：827项XCTest、6项本地化、4项原生UI/48张中英浅深色合成截图，本地化扫描、严格文档检查、生成临时移动端工程后的arm64/x86_64模拟器构建。仓库原移动端工程漏收已有源码导致首次构建失败，未修改该工程，具体命令与修复验证方式见文末。

最新独立Release包`apple/Apps/DsmMac/dist/photos-three-final-20261001/LanStash-1.0.11-arm64.dmg`，22,647,845字节，1.0.11(21)、arm64、localtest。严格签名、Hardened Runtime专用权限、Sparkle实际加载和DMG校验通过；无本地磁盘挂载扩展，未安装、启动或正式发布。

2026-10-02用户已授权并补齐正式主App的`com.apple.security.files.bookmarks.app-scope`；三个收尾项及该权限配置已完成，无待授权代码项。真实NAS、正式签名沙盒包的系统书签授权与完整辅助功能验收仍为PENDING_USER_VALIDATION。尚未正式签名发布或提交代码；原有移动端工程漏收源码问题仅在临时生成工程中完成兼容验证，未改动其工程文件。历史剩余清单以本节和文末为准。

## 前次交付：预览直接操作（2026-10-01）

预览更多菜单已补齐相册加入/新建/移出/封面、评级/说明/拍摄时间/时间偏移/标签、移动/复制，以及人物移出/重新分配/封面；主题操作并入同一菜单。表单固定当前预览照片与来源上下文，不使用列表多选。确认移出当前照片时关闭预览，其他照片、复制和待核对结果保留；当前相册/目录位置保持。

808项XCTest、6项本地化、3项原生UI/28张中英浅深色合成截图及本地化扫描通过。最新独立Release包`apple/Apps/DsmMac/dist/photos-preview-actions-20261001/LanStash-1.0.11-arm64.dmg`，22,486,900字节，1.0.11(21)、arm64、localtest，包含此前全部累计照片改动。严格签名、专用权限、Sparkle实际加载和DMG校验通过；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：共享相册贡献者其他元数据/旋转编辑资格的worker核对与对齐；待此前独立存储授权的上传跨重启恢复；其他全局设置及角色菜单最终查漏。真实NAS与完整辅助功能验收仍为PENDING_USER_VALIDATION。本轮仅macOS界面/模型/测试增量，无新API、资源键、持久化、依赖或权限变化。下文历史清单以本节与文末为准。


## 前次交付：预览重建角色与预览入口（2026-10-01）

共享普通目录下载角色、相册本人提供者可按实际资格重建预览；相册仅下载权不等于重建权，原件编辑权限保持不变。预览窗口新增直达确认入口，打开/取消不写入；冻结相册保留官方多选重建，仅预览入口不可用。本机转换后再次核对权限，未知结果沿原操作核对、不重复启动。

803项XCTest、6项本地化、最终8项聚焦及2项原生UI/12张中英浅深色合成截图通过。最新独立Release包`apple/Apps/DsmMac/dist/photos-preview-roles-20261001/LanStash-1.0.11-arm64.dmg`，22,465,220字节，1.0.11(21)、arm64、localtest，包含此前冻结相册恢复、后台任务等全部累计照片改动。严格签名、专用权限、Sparkle实际加载和DMG校验通过；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：预览窗口内加入/移出相册、相册封面、移动/复制和人物操作直接入口；共享相册贡献者其他编辑权限分支的worker核对与对齐；待此前独立存储授权的上传跨重启恢复；其他全局菜单最终查漏。主图库已有命令不代表预览直接操作已完成。真实NAS结果仍为PENDING_USER_VALIDATION，接口证据保持static。下文历史清单以本节与文末为准。

## 前次交付：冻结条件相册恢复（2026-10-01）

冻结相册新增“保存为普通相册”和编辑受支持条件后重建。普通恢复必须回读冻结标记已解除；重建先确认新相册的身份与完整条件，再清理旧相册，失败保留新旧对象，旧分享不自动继承。打开或取消表单只读，未知回执持续核对且不重复提交。

798项XCTest、6项本地化、1项原生UI及28张中英浅深色合成截图通过。最新独立Release包`apple/Apps/DsmMac/dist/photos-frozen-albums-20261001/LanStash-1.0.11-arm64.dmg`，23,376,987字节，1.0.11(21)、arm64、localtest，包含此前全部累计照片改动。严格签名、专用权限、Sparkle实际加载和DMG校验通过；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：最终菜单查漏中发现的共享目录/相册贡献者预览重建角色分支、其他菜单与设置的最终核对，以及待此前独立存储授权的上传跨重启恢复。真实NAS恢复/重建仍为PENDING_USER_VALIDATION，接口证据保持static。下文历史清单以本节与文末为准。

## 前次交付：NAS后台任务中心（2026-10-01）

新增NAS复制/移动任务窗口：全部/进行中/已结束筛选、进度与部分失败、取消确认、单项及确认快照批量清理、错误名称/原因、实际目标目录跳转。取消保留已完成部分，清理只移除记录；未知回执继续核对，同一操作不重复发送。允许取消本App待核对搬移，原回执证据未核对前不能清理。

780项XCTest、6项本地化、2项原生UI及56张合成截图通过。最新独立Release包`apple/Apps/DsmMac/dist/photos-background-tasks-20261001/LanStash-1.0.11-arm64.dmg`，22,262,350字节，1.0.11(21)、arm64、localtest，包含此前所有累计照片改动。严格签名、专用权限、Sparkle实际加载和DMG校验通过；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：冻结条件相册的普通相册恢复/条件重建、待此前独立存储授权的上传跨重启恢复，以及最终网页菜单查漏。冻结流程已补齐官方静态证据，尚未实现；不能以证据补齐当成功能完成。真实NAS按PENDING_USER_VALIDATION交由用户验收，接口证据仍为static。下文历史清单以本节与文末为准。

## 前次交付：上传任务后续操作（2026-10-01）

上传队列新增打开实际所在位置、前往相册、单项排队取消及终态记录移除；移除记录不删除NAS照片，未知/在途操作保留自动核对。位置先回读照片当前目录，再读取完整父目录路径；跨空间明确定位，直接相册贡献上传不提供无权原件入口。失败可重试、迟到结果不覆盖新页面。760项XCTest、6项本地化、2项原生UI/16张合成截图及独立Release包通过。

最新包`apple/Apps/DsmMac/dist/photos-upload-actions-20261001/LanStash-1.0.11-arm64.dmg`，22,040,123字节，1.0.11(21)、arm64、localtest，包含此前全部改动；无本地磁盘挂载扩展，未安装启动或正式发布。真实NAS由用户验收，不增设人为待实测功能锁。

明确剩余：冻结条件相册、NAS后台任务列表与后续管理、待此前独立存储授权的上传跨重启恢复，以及最终菜单查漏。不能以本机上传队列代替NAS后台任务列表。以下旧清单为历史，以本节与文末为准。

## 前次交付：分享列表快捷管理（2026-10-01）

“由我共享”列表可直接打开管理表单；打开和取消只读，保存或停止后按当前排序更新已加载列表，未知结果自动核对，刷新失败保留内容并只读重试，切换历史月份不被迟到结果覆盖。250项模型/外观XCTest、6项本地化、1项原生UI/16张合成截图及独立Release包通过。最新包`apple/Apps/DsmMac/dist/photos-sharing-list-20261001/LanStash-1.0.11-arm64.dmg`，22,015,788字节，1.0.11(21)、arm64、localtest，包含此前全部改动；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：冻结条件相册、后台/上传任务后续导航与单项操作、待此前独立存储授权的上传跨重启恢复，以及最终菜单查漏。真实NAS由用户验收；没有以未实测为由新增人为功能锁。以下旧清单为历史，以本节与文末为准。

## 前次交付：缩略图大小控制（2026-10-01）

新增五档滑杆及增减按钮，默认保持原尺寸；键盘方向键、拖动和首尾状态已接入。照片与封面同步调整，保持历史月份、选择与可见照片锚点，不刷新列表。246项模型/外观XCTest、6项本地化、3项原生UI/24张合成截图与独立Release包通过。会话内记忆，不新增持久化。冻结条件相册官方细节核对受Chrome锁屏影响，已请求解锁，期间先完成该独立功能。最新包`apple/Apps/DsmMac/dist/photos-thumbnail-size-20261001/LanStash-1.0.11-arm64.dmg`，21,996,598字节，1.0.11(21)、arm64、localtest，包含此前全部改动；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：冻结条件相册、分享列表快捷管理、后台/上传任务后续导航与单项操作、待此前独立存储授权的上传跨重启恢复，以及最终菜单查漏。以下旧清单为历史，以本节与文末为准。


## 前次交付：临时分享完整流程（2026-10-01）

临时分享创建、取消后停止/清理、停止并保留普通相册副本已接入macOS模型和表单。窗口关闭不遗失取消意图；副本确认后才停止，清理前再次比较完整成员。未知结果沿原操作自动核对，明确失败可重试或保留现有相册。748项XCTest、6项本地化、4项原生UI/74张合成截图及独立Release包通过。新包`apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,974,554字节，1.0.11(21)、arm64、localtest，包含此前累计改动；无本地磁盘挂载扩展，未安装启动或正式发布。真实NAS由用户验收。

明确剩余：冻结条件相册、缩略图大小、分享列表快捷管理、后台/上传任务后续导航与单项操作、待此前独立存储授权的上传跨重启恢复，以及最终菜单查漏。以下旧的剩余清单为历史记录，以本节与文末为准。

## 前次交付：独立新建文件夹（2026-10-01）

照片文件夹页面新增独立创建入口，支持个人/共享当前目录及空目录。固定父目录、校验名称，创建后只更新目录分页，保留照片与选择；未知回执持续自动核对，不重复创建。732项XCTest、6项本地化、2项原生UI/12张合成截图及独立Release包通过，真实NAS由用户验收。

最新包`apple/Apps/DsmMac/dist/photos-create-folder-20261001/LanStash-1.0.11-arm64.dmg`，21,791,872字节，1.0.11(21)、arm64、本机临时签名；包含此前全部累计照片改动，无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：临时分享取消清理/停止并保留副本、冻结条件相册、缩略图大小、分享列表快捷管理、后台/上传任务后续导航与单项操作、待此前独立存储授权的上传跨重启恢复，以及最终菜单查漏。现有选片分享是普通相册流程，不能当作临时分享已对齐。下文历史状态以本节与文末为准。

## 前次交付：选片直接创建共享链接（2026-10-01）

选择工具栏、照片右键及预览窗口均可直接发起分享。确认创建私有相册后，在同一窗口设置访问范围、成员、密码和有效期；仅最终保存才公开。创建/分享未知结果持续自动核对、不重复提交，个人及共享来源均保持历史月份。729项XCTest、6项本地化、2项原生UI/42张合成截图及独立Release包通过；真实NAS由用户验收。

最新测试包`apple/Apps/DsmMac/dist/photos-selection-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,757,043字节，1.0.11(21)、arm64、本机临时签名；包含此前照片改动，无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余（第二轮查漏修正）：临时分享取消清理及停止时保留副本、冻结条件相册处理、独立新建文件夹入口、缩略图大小、分享列表快捷管理、后台/上传任务完成后导航与单项管理，以及待此前独立存储授权的上传队列跨重启恢复。现有选片分享创建普通相册，不等于官方临时分享完整对齐。最终菜单审计仍未完成；下文保留历史波次，旧的剩余清单以本节与文末为准。

## 前次交付：自动预览失败同步（2026-10-01）

明确照片/视频转换失败按阶段同步状态；取消、断网、资源或权限变化及未知上传回执不误标记。标记成功仍计为生成失败并提示“重建预览”；同编号不重发，可见单元未知回执只接受实际broken字段，后台无直接状态证据保留核对。历史月份与选择保持，后续项目可继续。728项XCTest、6项本地化、1项UI/4张截图及独立Release包通过，真实NAS由用户验收。

最新测试包`apple/Apps/DsmMac/dist/photos-preview-failures-20261001/LanStash-1.0.11-arm64.dmg`，21,701,299字节，1.0.11(21)、arm64、本机临时签名；包含此前照片改动，无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：本轮查漏发现的选片直接“创建共享链接”组合流程、其他目录/分类/预览及共享/全局菜单最终复核，以及待此前独立存储授权的上传队列跨重启恢复。不能以先建相册再手动分享代替网页快捷流程。完整目标active，本轮progress。

## 前次交付：新格式提示与全用户补预览（2026-10-01）

新格式提示读取、稍后已读、管理员全用户/普通用户个人补生成预览已接入。生成请求接收与后台完成分开呈现；提示保存部分失败只补保存、不重复生成，未知回执持续只读核对。历史月份/多选/已加载内容保持。721项XCTest、6项本地化、1项原生UI/28张合成截图及独立Release包通过，真实NAS由用户验证。

最新测试包`apple/Apps/DsmMac/dist/photos-codec-prompt-20261001/LanStash-1.0.11-arm64.dmg`，21,705,865字节，1.0.11(21)、arm64、本机临时签名；包含此前所有照片改动，无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：自动预览失败状态同步、最终网页菜单查漏、待此前独立存储授权的上传队列跨重启恢复。失败状态broken已补静态证据，但尚未接入写入与结果核对；不得把候选消失或UI默认值当作成功。完整目标保持active，本轮progress。下文保留历史波次，以本节及文末为准。

## 前次交付：长断线删除持续恢复（2026-10-01）

照片单张/批量删除在初始六轮后持续自动核对，无手动核对按钮；目录与照片混选删除也加入持续管理核对。取消/离开/禁用不应用晚到结果，重进继续原目标；删除确认使旧偏移在途分页失效，月份和已加载照片保持。709项XCTest、6项本地化、2项UI/8张合成截图及独立Release包通过。

最新测试包`apple/Apps/DsmMac/dist/photos-deletion-continuing-20261001/LanStash-1.0.11-arm64.dmg`，21,613,407字节，1.0.11(21)、arm64、本机临时签名，包含整库维护及此前全部照片功能；无本地磁盘挂载扩展，未安装启动、未正式发布。真实NAS由用户验证。

明确剩余：新格式提示及全用户补预览（Wizard静态链已补齐）、自动预览失败状态同步及最终网页菜单查漏、待独立存储授权的上传跨重启恢复。没有把新格式全用户动作或失败上报当作已实现。本轮没有新增持久化，应用退出后的未决操作恢复不因此获得保证。下文为历史波次，当前状态以本节和文末为准。

## 前次交付：当前空间整库维护（2026-10-01）

个人/共享空间重新索引、异常预览生成、原生确认及自动核对已实现，保持历史月份和选择。705项XCTest、6项本地化、1项UI/24张合成截图及独立Release包通过。新包`apple/Apps/DsmMac/dist/photos-library-maintenance-20261001/LanStash-1.0.11-arm64.dmg`，21,608,749字节，1.0.11(21)、arm64、本机临时签名；无本地磁盘挂载扩展，未安装启动或正式发布。

明确剩余：优先补删除六轮短期核对之后的持续自动恢复（当前长断线仍可能要求手动）；全用户新编解码器欢迎流程；自动预览失败状态同步与最终网页菜单查漏；上传队列跨重启持久化仍待独立存储授权。短期删除自动核对已实现不能冒充长断线恢复也完成。维护无任务编号，丢失回执可能长期无法证明结果，只读等待、不重复启动。真实NAS与物理手势由用户验证，不设人工待实测禁用。下文为历史波次，以本节和文末为准。

## 前次交付：自动预览完整相邻与格式调度（2026-09-30）

完整前2/后3及小集合缩减、相邻视频排除、普通→HEVC/实况视频→VC1→后台顺序已实现。696项XCTest与6项本地化、Release/严格签名/Sparkle实际加载/DMG校验通过。新独立测试包`apple/Apps/DsmMac/dist/photos-preview-priority-20260930/LanStash-1.0.11-arm64.dmg`，21,509,854字节，1.0.11(21)、arm64、本机临时签名。包含全部此前照片改动，无本地磁盘挂载扩展，未安装启动或正式发布。

Chrome锁屏阻塞已解除；整库维护请求已有static证据，但原生入口/结果核对仍未实现，最终网页菜单审计未完成。上传跨重启持久化仍待此前独立存储授权。真实NAS与物理设备由用户测试，不作为人工禁用条件。下文历史剩余清单以本节与文末为准。

## 前次交付：默认排序确认（2026-09-30）

包含前轮共享成员管理全部功能，新增默认排序字段/方向变更确认；确认显示目标排序，取消保留草稿，普通显示设置仍直接保存。新独立测试包`apple/Apps/DsmMac/dist/photos-sort-confirm-20260930/LanStash-1.0.11-arm64.dmg`，21,503,209字节，1.0.11(21)、arm64、本机临时签名。2项原生UI/20张合成截图、4项相关XCTest、6项本地化、Release/严格签名/实际组件加载/DMG校验通过。无本地磁盘挂载扩展，未安装启动或正式发布。

剩余为整库重新索引/缺陷预览生成、自动预览完整相邻范围/格式优先级及最终网页菜单审计；上传跨重启存储仍待此前独立授权。浏览器本轮报告Mac锁屏，已请求解锁；官方公开包替代读取未成功，未新增接口证据，不猜测剩余请求。下文保留历史波次，早期“未实现”以本节与文末新记录为准。

## 前次交付：共享成员原生管理（2026-09-30）

共享成员增删、角色、自动备份及按成员两层目录权限已接入原生界面；最终确认后分阶段保存、后台自动核对并更新本人实际访问权限，保留个人历史月份/选择，权限撤回使在途旧分页失效。692项XCTest、6项本地化及2项原生UI/52张合成截图通过；实际NAS仍交给用户验收，已实现入口无待实测人工白名单。独立Release测试包`apple/Apps/DsmMac/dist/photos-shared-members-20260930/LanStash-1.0.11-arm64.dmg`，21,454,162字节，1.0.11(21)、arm64、本机临时签名。严格签名、Sparkle实际加载及DMG校验通过，无本地磁盘挂载扩展；未安装启动或正式发布。

剩余：整库重新索引/缺陷预览生成、自动预览完整相邻范围/格式优先级、默认排序变更确认及最终菜单审计。上传跨重启存储仍待独立授权。本页保留历次记录，早期“尚未实现”以本节和文末的新记录为准。

## 前次交付：全局设置与转换缓存（2026-09-30）

管理员全局识别、普通用户分享、访客照片信息、格式排除、原尺寸JPEG及缓存大小/清理已完成源码、本地回归和独立测试包。新包`apple/Apps/DsmMac/dist/photos-global-settings-20260930/LanStash-1.0.11-arm64.dmg`，21,122,652字节，1.0.11(21)、arm64、本机临时签名。最终660项XCTest与6项本地化通过，原生UI 1项/40张合成截图及实际开关/确认保存通过；Release、严格签名、实际Sparkle加载及DMG校验通过。无本地磁盘挂载扩展，未安装启动、未正式发布。原包保留，详细证据见文末。

剩余：共享成员/自动备份及其按成员目录权限主流程；整库重新索引/缺陷预览生成；自动预览完整相邻范围/格式优先级、默认排序变更确认与最终菜单审计。上传跨重启存储仍待独立授权。真实NAS/物理手势由用户验证，已实现入口无待实测人工白名单。下文早期记录为历史，当前状态以本节和文末为准。

## 前次交付：共享空间设置（2026-09-30）

共享空间启停、共享人物/主题/相似识别与顶层文件夹公开分享设置已完成源码及本地验证。新独立测试包`apple/Apps/DsmMac/dist/photos-shared-settings-20260930/LanStash-1.0.11-arm64.dmg`，20,879,215字节，1.0.11(21)，arm64、本机临时签名。646项完整XCTest与6项本地化通过，最后启用入口修正另有49项共享回归通过；1项原生UI/32张合成截图通过。Release、严格签名、专用测试权限、Sparkle实际加载和DMG校验通过，无本地磁盘挂载扩展，未自动安装/启动或正式发布。详细命令与已知限制见文末。

剩余：全局管理员设置、共享成员/自动备份权限、下载转换缓存、设置页整库重新索引/缺陷预览生成、自动预览完整相邻集合/编码优先级与最终菜单审计。上传跨重启存储仍待独立授权。真实NAS及物理手势由用户验收，已实现入口无待实测人工白名单。以下按波次保留历史记录，状态以本节和文末为准。


## 最新状态入口（批次外、共享目录与实况自动预览已接入，整体对齐继续）

本轮新增可见Item/实况Unit候选及原件身份/目录权限复查；共享entry只处理可下载照片，后台全库扫描仍限management。2秒去抖、相邻视频排除、当前实况双单元和跨来源去重已接入，保留历史月份和选择。637项XCTest及6项本地化通过，最终视频类型去重补测182项Model通过。最新独立测试包`apple/Apps/DsmMac/dist/photos-visible-sources-20260930/LanStash-1.0.11-arm64.dmg`，1.0.11(21)，20,733,190字节；Release arm64、临时签名、Sparkle实际加载及DMG校验通过，无本地磁盘挂载扩展，未自动安装/启动或正式发布。完整相邻集合与格式优先级仍审计，真实NAS兼容待用户验收。

2026-09-30新增个人空间人物、主题、相似照片识别开关；读取真实个人/全局条件，只保存变化字段并自动核对。关闭正在浏览的分类回到相册首页，时间线保持月份、选择与已加载照片，共享分类不变。包含此前显示设置、主题管理、捏合缩放、旋转及所有累计照片改动，无待实测白名单。

593项XCTest、6项本地化、1项原生UI测试（24张合成截图）及独立Release包通过。测试包：`apple/Apps/DsmMac/dist/photos-recognition-20260930/LanStash-1.0.11-arm64.dmg`，20,510,902字节，1.0.11(21)，本机临时签名，无本地磁盘挂载扩展。未自动安装/启动、未正式发布。具体命令和用户验收见文末。

剩余：共享/全局识别和分享管理设置、下载转换缓存管理；上传队列跨重启恢复仍待此前存储方案授权。自动预览完整相邻集合/编码优先级和最终网页菜单/设置审计继续，不宣称已完全对齐。真实NAS及物理手势由用户验收，下文历史证据以最新记录为准。

## 多目录与照片混选下载波次（已交付，真实NAS待验）

- 基线：main@5684170b3ccf，保留已有34个改动文件；当前任务独占 Photos 归档目标、Repository、Model/View、相关测试、双语资源及对应记录。
- 官方证据：2026-09-30 只读检查已登录页面的官方静态资源，下载处理同时传入非空 `item_id` 与 `folder_id` 数组、`force_download=true`、`download_type`；空间决定 Download 路由。仅属 static，没有下载真实照片或写入 NAS。
- 用户语义：同一目录选择多个子文件夹或混选照片，保存一个ZIP；工具栏和已选项目右键均固定整组选项。复用现有归档下载、取消、完整性校验和明确保存后的本机替换；保持图库位置。
- 契约：增量扩展既有归档目标，校验空间、目录身份、照片身份与下载权限；不新增依赖、持久化、其他端UI或人工未验证禁用。iPhone/iPad目录批量管理仍为后续，Windows/Android仅同步适配影响。
- 当前验证：530项XCTest、6项本地化、3项合成UI测试与独立Release测试包通过；真实NAS目录递归内容、压缩格式和权限组合为 PENDING_USER_VALIDATION。非目标：拖放移动、重复项设置及上传队列重启恢复。

## 最新状态入口（相册列表与分享排序波次）

本页下文按开发波次保留历史证据；早期“默认关闭”和“尚未实现”的清单已被后续记录更新，不能作为当前能力开关依据。用户承担真实NAS与物理设备验收，已实现入口按实际权限与接口能力开放。最新验证见文末相册列表与分享排序记录；共享人物、分类和本机预览生成交付保留。

- 本轮新增：原空间启用时，本人提供的相册项目可转加其他目标或用于新建相册；通过源相册回读身份与provider，不因原件owner属于他人而错误拒绝，也不因此授予原件修改权。原空间关闭时网页不提供转加，先前把这一点列为功能缺口的记录已更正；混合来源沿两空间及共享管理权限。前轮角色、上传、移除及照片捏合等实现保留。
- 本轮新增：个人→共享移动、个人↔共享复制，目标空间和目录选择、任务回执自动核对，完成后保留时间线月份。
- 本轮新增：混合个人/共享评级、绝对/相对日期与预览重建，分来源提交和逐项回读；跨空间搬移后相册按已加载范围自动更新新身份，保留其他选择，读取失败自动重试。混合标签及混合相册搬移不属于当前官方菜单功能，纠正历史待办。
- 本轮新增：预览重建在等待通知时短暂断线可自动重连，只重新订阅原照片，不重发重建。
- 本轮新增：读取个人/共享未完成预览任务，固定所选原件后继续重建；当前会话丢失通知时自动回读队列、原件身份和新预览版本，不能证明结果则保持待核对。
- 本轮新增：六类分类首页显示最多四张封面拼图，固定当前空间、支持加载与失败占位，不影响打开分类。
- 相似照片已接入分组浏览、推荐设置、移出/拆组及会话撤销；本轮补齐保留所选删除其他、主列表多组拆分与批量撤销，以及识别处理状态。
- 本轮网页菜单审计纠正此前遗漏：压缩JPEG下载已接入，原格式保留和相似组全成员下载一并处理。
- 本轮新增：完整相册和文件夹下载为ZIP，支持原件与压缩JPEG，可取消、失败保留旧文件，按真实下载权限开放。
- 本轮新增：独立全屏幻灯片，照片三秒切换、视频结束推进、暂停/继续、前后循环和键盘退出；独立分页保留图库月份。
- 本轮新增：原尺寸JPEG单张转换下载，按官方格式和实际NAS能力开放，完整校验后另存；真实转换仍待用户验收。
- 本轮新增：文件夹默认拼图/自定义封面、目录与照片入口、固定目标的子目录单选窗口；保存后自动核对、只更新封面，保留图库位置。
- 本轮新增：文件夹重命名表单，固定空间/目录身份，按完整新路径自动核对并局部更新卡片和后代路径；主文件夹页排序入口含根目录，复用封面选图的四字段/双向排序。
- 本轮新增：文件夹多选和照片混选删除，固定目标确认、后台任务/完整分页回读后自动局部更新；核对期间进入已删目录时回到父目录。
- 本轮新增：文件夹及照片混选移动复制、固定目标与目录冲突检查、递归任务结果自动核对；原地更新并保留父目录。
- 本轮新增：共享目录权限查看、成员及角色、链接复制、密码保护标志和父目录限制；固定目录读取，失败可重试；本轮新增访问范围、成员角色/增删、密码和子目录应用保存，确认后自动核对。
- 本轮新增：多个同级文件夹与照片混选下载为一个ZIP，工具栏和已选项目右键支持原件/压缩JPEG，固定全部目标、逐项预检，取消或失败保留本地旧文件与图库位置。
- 本轮新增：文件夹页单项/混选拖动至可见目录、上级按钮或路径导航，固定整组选项并预选移动确认表单；实际NAS预检和任务核对保留。
- 重复项默认设置及上传ignore/rename、移动复制skip/overwrite执行与结果核对已交付；相册内容排序与本轮相册列表显示范围/排序、分享列表独立排序均已接入。上传队列跨会话/重启恢复仍待持久化授权；完整范围继续复核，不凭当前清单宣布无其他缺口。本轮已补证网页预览旋转保存的完整动作链，当前客户端尚未接入，为明确下一项；真实NAS验收与代码待办分开。
- 总体网页对齐仍未完成，不能以本轮测试或可用测试包代替剩余功能。


## 标签与相对日期波次（进行中）

本波次继续使用现有 Photos 文件和双语资源，保留前次上传/封面以及 Download Station 改动。已获共享契约扩展和实际能力开放授权，不增加人工默认禁用。

| 流程 | 证据与实施方式 | 风险/验证 |
| --- | --- | --- |
| 新建标签并应用到选择照片 | 既有官方静态记录：GeneralTag.create v1(name) 返回 tag 对象；按返回 id 核对 GeneralTag.list，再沿用 Item.add_tag | 创建/应用分阶段；未知不重放，应用明确失败保留新标签 |
| 整体调整拍摄时间 | 按每张原始照片快照计算同一秒数偏移，逐项复用已记录 Item.set v2(time)；暂不猜测 shift_time 候选参数类型 | 保留间隔，逐项回读；部分完成只继续原目标中尚未完成项 |

2026-09-29 本次浏览器工具明确报告 Mac 锁屏，已请用户解锁。没有绕过锁屏或直接提取浏览器会话；在恢复页面观察前，仅使用仓库已记录结构，不提升私有接口证据等级。以上无依赖实现与合成测试继续推进，不将整项任务标为阻塞。

## 继续复刻波次（进行中）

本节为当前状态入口；下文此前交付的“默认关闭”描述为历史方案，已被用户后续明确授权取消。

| 本波次用户流程 | 既有源码与依赖 | 原生交互与写边界 | 当前状态 |
| --- | --- | --- | --- |
| 多文件上传队列 | Model.submitMutation、Upload.Item 单文件上传 | 系统多选、逐项进度、停止后续任务、失败单项重试；未知结果仅回读 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |
| 上传到当前相册或文件夹 | 既有 upload(folderID)、addToAlbum | 上传成功后按返回照片编号加入目标相册；保留原上传结果，加入失败不重新上传 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |
| 相册封面 | 已有 setAlbumCover 与 Album.set_cover | 在当前相册单选照片，确认后设置；回读封面编号 | 源码、聚焦测试与合成 UI 已通过；真实 NAS 待验 |

本波次由当前任务独占 Photos Model/View/Panel、相关测试与双语资源中的 Photos 键；Repository 修改封面身份、回读及缩略图读取相关分支；共享领域/服务仅增量加入可选相册缩略图与读取方法。既有 Download Station 文件不修改。以上复用已授权接口，没有新增依赖、持久化、系统权限或其他平台界面。

后续仍需推进：新建标签、相对拍摄时间、条件相册、具名分享成员及密码/有效期、照片请求、人物修正、预览重建、共享空间权限。逐项取得官方接口证据后实现，不以本波次范围缩小完整对齐目标。

## 授权、范围与基线

用户要求先解决批量删除、月份跳转漂移和删除后回到最新月份，再对齐官方网页。用户明确授权新增上传、相册管理、分享管理、标签/评级/日期编辑、移动/复制接口；同时同意增量修改、同步五端影响、不改其他端 UI/存储，未验证的写入口保持关闭。

本轮基线是已有未提交的 Download Station 界面工作，未回退或覆盖。实际修改集中在 Apple Photos 协议/Repository/macOS Model/View/新表单、双语资源、Photos 自动化和发现记录。没有提交、推送、PR、安装或启动真实 App，没有向 NAS 写入测试数据。

## 功能账本

| 用户流程 | macOS 实现证据 | 契约/安全边界 | 当前验证 |
| --- | --- | --- | --- |
| 勾选多张、按天勾选、范围选择、批量删除 | SynologyPhotosModel/View 的 selection、deletionCandidates、prepare/confirm | 原有删除入口；每项预检、确认快照、自动只读回查 | 单测与浅/深色合成 UI；真实 NAS 批量异常待验 |
| 跳转月份后不自动前移 | 显式“查看更新的照片”和非惯性真实向上滚轮触发，prepend 恢复锚点 | 无新 API | 单测与静置 UI 回归；真实触控板待验 |
| 删除不刷新整页 | confirmed 项局部移除、pagedPhotoIDs 修正偏移，保留月份 | 只有成功空回读确认消失；未知不重放 | 单测与 UI 通过 |
| 批量下载原件 | saveSelection、目录选择器、逐项原件保存 | 既有读取接口；本机同名自动另存、不覆盖 | 合成文件保存测试通过 |
| 评级/说明/绝对拍摄时间 | PhotoManagementPanel、Mutation.edit、Item.set/get | 个人空间、每项身份/权限；100 项上限 | static + 合成；新入口关闭 |
| 添加/移除已有标签 | tagsAdd/tagsRemove、additional.tag | 缺失字段不视为空列表 | static + 合成缺失字段回归；关闭 |
| 创建/重命名/删除相册、加入/移除成员 | 相册右键菜单与选择菜单，NormalAlbum/Album | 所有者检查；移除成员保留原件 | static + 创建、非所有者回归；关闭 |
| 移动/复制 | 原生文件夹选择表单、BackgroundTask | 目标目录权限、同名 skip、最终计数、移动编号回读 | static + skip 回归；关闭 |
| 上传个人照片 | 系统文件选择、multipart、返回编号回查 | 当前一次一个文件；改名保留同名文件；磁盘临时体0600 | static + multipart/回读回归；关闭 |
| 相册公开查看/下载、关闭分享 | 相册右键管理分享，Passphrase/Album | 明确访问范围确认、先关闭再配置再开启、不发送密码/有效期 | static + 分享顺序和中途失败回归；真实行为待验，关闭 |

源码证据：
- `apple/Packages/DsmCore/Sources/SynologyPhotosManagement.swift`
- `apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift`
- `apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift`
- `apple/Apps/DsmMac/Sources/SynologyPhotosView.swift`
- `apple/Apps/DsmMac/Sources/PhotoManagementPanel.swift`

## 完整网页对齐尚未完成的部分

不得将本轮称为“全部网页功能已经可用”。新增六类写入口没有开启；还没有覆盖多文件上传队列、上传到相册、创建新标签、相对时间调整、条件相册、具名成员/密码/有效期编辑、照片请求管理、人物修正/预览重建。部分候选方法已有静态线索，但参数或最终状态证据不足，不能猜测实现。共享空间正向权限和写行为也不在当前已验证范围。

相册封面底层有静态候选实现，原生入口尚未接入，回读证据仍需确认。现阶段仅作为 gated 接口保留，不计为用户可完成流程。

## 五端影响与迁移

| 平台 | 影响 | 实施边界 |
| --- | --- | --- |
| macOS | 新表单、选择菜单、局部结果更新；新服务协议默认关闭 | 本轮主体；无系统版本、依赖、Bundle ID、签名设置或持久化改动 |
| iPhone | 共享模型和 Repository 新增成员；协议默认实现保持源兼容 | 单项删除签名保留，自动核对新增时序仅 macOS；不添加移动 UI，不自动开放写能力 |
| iPad | 同上 | 未来应使用触控多选、系统选择器；不搬运右键/悬停交互 |
| Android | 仅影响记录 | 不修改代码；将来映射 typed mutation/结果与权限门禁 |
| Windows | 仅影响记录 | 不修改代码；将来使用 WinUI 原生选择与确认，不复制 SwiftUI 布局 |

回滚：移除新增管理表单/接口与默认关闭的能力注入，保留本轮首批照片缺陷修复可独立交付。协议新增默认实现，没有持久化迁移。未知状态目前只保存在会话中，重启恢复尚未实现，不能据此开放真实写入。

## 已执行验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：76 个 XCTest（28 Model、48 Repository）与 6 个 Swift Testing 本地化测试通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-management-ui`：2 个合成 UI 测试通过，浅/深色表单及选择/删除后月份；只打开表单不发写请求。
- 初版修复包：`apple/Apps/DsmMac/dist/photos-selection-timeline-20260928/LanStash-1.0.10-arm64.dmg` 已完成 Release 构建、临时签名、Sparkle 实际加载与 DMG 校验。此包早于新管理功能，不能当完整对齐版。
- 新功能最终 Release 包、当前资源/契约检查与独立复核结果见后续追加；不得以旧包或局部单测代替。

## PENDING_USER_VALIDATION

1. 首批缺陷：现有测试包打开真实照片库，定位一个旧月份，静置、手动向上/向下滚动、批量选择并对明确可丢弃的测试照片删除。预期自动核对、不跳到最新、不产生重复请求；确认 VoiceOver/键盘与实际触控板行为。
2. 新写功能：先明确专用合成照片/相册/目录与 DSM、Photos 完整版本，再制作限定目标的验证包。分别验证正常、无权限、断网、取消、部分成功和二次点击；分享单独确认范围。未满足条件不开放入口。
3. 反馈只需要脱敏步骤、版本、错误类别及结果变化，不发送凭据、真实照片、地址或文件路径。

## 独立集成复核（只读）

复核以最终差异重新检查：默认能力空、原有删除门禁未放宽、profile/空间/所有者检查、先确认再写、重复标识绑定、未知状态不重放、上传不把凭据放入 URL、保存不覆盖、其他端协议默认实现及先前 Download Station 差异保留。新增真实写行为仍未验证；不能以静态证据升级兼容结论。

### 最终静态门禁与工程生成

- `python3 tools/localization/check_localization.py`：通过，Apple 4232 个资源键，双语、参数、引用与硬编码检查无问题。
- `python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点文档引用通过。
- 使用项目 CI 固定的 XcodeGen 2.46.0 和既有 SHA-256 校验临时工具，执行 `xcodegen generate --spec apple/Apps/DsmMac/project.yml`；工程仅增加 PhotoManagementPanel 的 4 行引用，未手改生成文件、未升级工具链。
- `git diff --check`：通过。Chrome 临时静态检查变量已删除并核对，开发者工具已关闭。

### 最终 Release 测试包

- 实际打包：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-management-20260929" bash apple/Apps/DsmMac/package.sh`。临时命令包装仅为 xcodebuild 指定既有 `apple/.build` Sparkle 2.9.6 缓存与 `-skipPackageUpdates`，结束删除；未修改依赖、打包脚本或工具链。
- 首次预检发现新增视图未加入 Xcode 工程，按上述锁定生成流程补齐后重新打包成功，退出码 0。
- 产物：`apple/Apps/DsmMac/dist/photos-management-20260929/LanStash-1.0.10-arm64.dmg`；1.0.10 (20)，arm64。本机临时签名、Hardened Runtime 本地测试权限、Sparkle **实际加载**、架构与 DMG checksum 全部通过。
- 未安装或启动真实 App，未覆盖旧包。临时签名包不包含 Finder 本地磁盘挂载扩展；此限制与 Photos 无关。
- 首批修复与批量下载可测试；六类新增管理功能默认关闭，未声称真实环境已对齐。当前 NAS 专用合成资料的写验证范围已向用户提出，尚未收到答复，不以等待时间视为授权。
- 本轮临时测试日志、合成截图与临时工具已清理；正式测试源码、发现记录和两轮 DMG 交付物保留。工作区全部改动仍未提交，原有 Download Station 改动保持。

## 2026-09-29 后续：按用户要求移除默认禁用（当前状态）

用户明确回复“可以，代码中不要限制禁用功能”。该要求取代前面首轮新增功能保持关闭的安排，并授权仅使用新增合成资料的 NAS 验证。当前 Repository 已删除人工能力白名单字段与构造参数，六类功能按接口实际支持开放；没有追加新开关或版本白名单。身份/空间/所有者/目录权限、用户确认和未知结果不重放继续保留。未修改其他平台 UI 或存储，未提交、推送。

对应测试不再注入人工开放列表，而是使用默认真实服务入口；新增“接口齐全默认开放”“缺少上传接口不阻断其他功能”回归。`swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：77 项 XCTest（28 Model、49 Repository）和 6 项本地化测试通过。

受控网页验证只在个人空间操作：已上传两张 160×120 合成纯色 PNG；创建专用测试相册并命名；仅对合成照片设置评级和日期。保留新资料，不删除、不创建公开分享，不操作原有照片。最终回读和最新 Release 包结果继续追加。

### 当前启用版交付与复核

- 当前产物：`apple/Apps/DsmMac/dist/photos-enabled-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64；前面的 management 包是历史默认关闭版，请使用本路径。
- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-enabled-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0。继续用临时包装指定既有依赖缓存和 `-skipPackageUpdates`，未改打包脚本或依赖。
- 临时签名、Hardened Runtime 测试权限、Sparkle 实际加载（`library loaded`）和 arm64 架构均通过；额外执行 `codesign --verify --deep --strict`、`file`、`hdiutil verify`，签名、架构及 DMG checksum 通过。
- `python3 tools/localization/check_localization.py` 通过（Apple 4232、Android 2188、Windows 3402）；`python3 tools/contract-validation/validate_fixtures.py` 通过（3 组 fixture、27 项私有端点文档引用）。照片 77 项 XCTest 和 6 项 Swift Testing 全部通过。
- 独立复核：人工白名单字段和初始化参数已移除；API 版本/请求格式与空间权限仍按实际支持判断，缺失上传接口不阻断其他功能。未删除身份、所有者、确认、重复提交及未知结果不重放保护；macOS 原有删除入口保持开启。其他端 UI 与持久化、原有 Download Station 改动未改变。
- 官方网页合成资料验证：两次上传均完成，创建相册并命名；评级操作收到成功提示；修改日期为 2020-03-15 后刷新仍保持该日期。详细证据及限制见环境记录，不能代替本包的真实 NAS 写操作验收。
- PENDING_USER_VALIDATION：本包连接真实 NAS 后的完整上传、标签、相册、移动/复制、分享、断网恢复及权限失败流程尚未实测。用户已明确要求开放入口，这些待办不再用于人工禁用功能。公开分享与删除未在浏览器执行。
- 本包未自动安装、启动或覆盖旧包；临时签名包仍不包含 Finder 本地磁盘挂载扩展。当前源码未提交、未推送。


## 本波次剩余清单（当前）

| 功能 | 当前缺口 |
| --- | --- |
| 标签管理 | 新建并应用、添加/移除已有标签已接入；当前版本实机写入待验 |
| 批量时间调整 | 绝对日期与整体前移/后移已接入；部分失败只继续剩余原始目标，真实 NAS 待验 |
| 条件相册 | 个人空间创建、规则编辑、建议查找和数量预览已接入；共享空间来源随共享空间切片推进，真实 NAS 待验 |
| 分享高级设置 | 已有公开查看/下载/关闭；缺少指定成员、密码、有效期编辑及完整权限面板 |
| 照片请求 | 只有列表读取，尚无创建、修改、关闭和收集目标管理 |
| 人物整理 | 可浏览/筛选；缺少命名、合并、纠正人物识别等写操作 |
| 预览重建 | 尚未接入网页重建照片/视频预览的操作 |
| 共享空间 | 仍需确认真实正向权限枚举和完整写入契约，不能推测管理员权限 |
| 上传完整体验 | 已支持拖放、子目录媒体导入、保留目录层级与上传期间浏览；尚无跨会话续传和重启恢复 |
| 完整实机验收 | 本轮原生上传队列、相册封面、移动/复制、分享异常恢复等仍需真实 NAS 测试；不能用合成测试代替 |

此清单保持完整网页对齐目标，当前波次完成不代表总目标完成。标签、相对日期和导入体验已推进；接下来处理条件相册/分享高级设置等需要补充官方契约证据的流程。未引入默认禁用功能的人工白名单。


### 后续波次的实际验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：85 项 XCTest（33 Model、52 Repository）与 6 项 Swift Testing 全部通过。新增覆盖多文件顺序、相册成员失败只重试第二阶段、未知结果核对后继续、停止队列、单项预检失败、封面成员检查、重复设置不重发、按当前会话读取封面。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-remaining-ui`：3 项合成 UI 测试通过；修正上传表单重复目标文案、封面测试使用单选后，前两项再次通过。已查看浅/深色上传确认、队列与封面截图，无顶部留白错位或底部操作区挤压。
- `python3 tools/localization/check_localization.py`：双语资源、引用、占位符与硬编码扫描通过，Apple 4251、Android 2188、Windows 3402；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点引用通过。
- 独立集成与写操作复核：上传入队前保留文件快照，写后按返回照片编号确认；相册加入失败保留原件，不自动重传；未知结果保留操作编号，仅回读。停止按钮不假装取消已提交请求；封面按成员与所有者检查，读取时不用旧会话缩略图编号。未新增公开分享、真实上传或删除测试操作。
- 共享契约：SynologyPhotoCollection.thumbnail 默认 nil，thumbnail(for: collection) 有协议默认实现；五端影响同步记录。队列仍为内存状态，不改变持久化/签名/权限/最低版本。回滚可移除队列和封面入口及可选字段/默认方法，既有单文件上传、普通相册管理和首批时间轴修复保持独立。
- PENDING_USER_VALIDATION：用专用合成图片，在真实 NAS 上验证多文件上传至个人图库、当前文件夹和本人相册；制造加入相册失败后确认只重试加入；设置封面后返回相册列表确认图片更新。要求回传脱敏步骤、DSM/Photos 版本和失败类别，不提供凭据或原照片。未运行的 NAS 验收不计为通过；入口遵循用户要求不设人工默认禁用。


### 后续波次测试包

- `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-uploads-cover-20260929" bash apple/Apps/DsmMac/package.sh`：退出码 0；临时 xcodebuild 包装继续使用既有依赖缓存与 `-skipPackageUpdates`，未改变工具链。
- 新产物：`apple/Apps/DsmMac/dist/photos-uploads-cover-20260929/LanStash-1.0.10-arm64.dmg`；1.0.10 (20)、arm64。本机临时签名、Sparkle 实际加载、架构和 DMG checksum 通过；额外 `codesign --verify --deep --strict` 与 `file` 复核通过。
- 未自动安装或启动，未覆盖前次交付包；本地磁盘挂载扩展按既有临时签名流程排除。上传队列、目标相册/文件夹与封面入口按实际能力开放。
- 最终 `git diff --check` 通过；本轮临时测试日志、合成截图已清理，正式测试与交付包保留。源码仍未提交，原有 Download Station 改动保留。整体网页复刻目标仍在进行中，剩余清单见上节。


### 标签与相对日期波次验证

- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：最终 96 项 XCTest（36 Model、60 Repository）与 6 项 Swift Testing 全部通过。覆盖新标签创建/回读/应用、丢失回执不重建、缺少创建接口不影响已有标签、正负日期偏移、时间越界、部分失败及原目标续做。
- 只读集成复核发现“续做预检失败会丢失继续入口”。新增 `SynologyPhotosModelTests/test继续剩余照片预检失败仍保留原目标供再次继续` 首次运行失败（3 条断言），修复后纳入上述 96 项回归通过；没有降低原断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-tags-dates-ui`：2 项合成 UI 测试通过。表单测试已覆盖新建标签与相对时间的浅/深色；时间预览补充秒级显示后再次运行表单测试。
- `python3 tools/localization/check_localization.py`：通过，Apple 4267、Android 2188、Windows 3402。`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture 和 27 项端点文档引用通过。`git diff --check` 通过。
- 写操作复核：每张照片身份与目录权限先检查；标签创建回执丢失不按名称猜测；新标签应用失败保留编号；相对日期仅复用已记录绝对时间请求，保留原目标，未知只读，部分结果不累加已成功偏移。七类管理能力均按实际 API 支持开放，不设人工白名单。
- macOS 是本轮验证目标。DsmMobile 通过 project.yml 引用共享 Model，未发现移动 UI 的新命令调用或需同步修改的穷尽分支；本轮未运行 iOS 构建，不以 macOS 通过代替移动端构建。
- PENDING_USER_VALIDATION：在专用合成图片中创建/应用一个新标签；选择具有不同拍摄时间的两张合成图片，统一前移或后移，确认间隔保留；断网/权限失败后继续仅处理未完成项。真实 NAS 与网页参数核对仍等待 Mac 解锁，未新增真实写入或公开分享。

已实现项目现在包括新建标签与相对日期。尚未实现的已确认项：条件相册、分享高级设置、照片请求写管理、人物整理写操作、预览重建、共享空间完整权限/写操作，以及上传拖放/目录批量导入/后台浏览/重启恢复。整体对齐目标保持进行中。


### 标签与日期最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-tags-time-20260929" bash apple/Apps/DsmMac/package.sh`。修复续做预检失败和秒级预览后重新构建，最终退出码 0；临时命令包装仅指定既有 `apple/.build` 缓存与 `-skipPackageUpdates`，已自动删除。
- 最终产物：`apple/Apps/DsmMac/dist/photos-tags-time-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64。签名、Hardened Runtime 测试权限、Sparkle 实际加载（library loaded）、架构与 DMG checksum 均通过；`codesign --verify --deep --strict` 与 `file` 额外复核通过。
- 秒级预览修正后的 `WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐` 再次通过，浅/深色截图已查看。没有声称锁屏状态下完成真实 Chrome/NAS 验收。
- 本包未自动安装、启动或覆盖前轮已交付包；临时签名包仍不包含 Finder 本地磁盘挂载扩展。当前改动未提交、未推送，原有 Download Station 改动保留。
- 本轮临时日志、截图及失败回归日志已清理；正式测试、发现记录与 DMG 保留。整体目标仍在进行中，不能将当前两个功能交付当作完整网页复刻完成。

### 拖放与目录导入波次基线

- 范围：macOS 照片上传入口、上传确认表单和本地来源准备；复用既有上传及加入相册契约，不改变 NAS 写入参数或其他端界面。
- 交互：拖放文件/文件夹或选择目录后，展开支持的照片/视频供确认，上传到当前目标。目录层级不重建，确认页明确说明；不把该切片描述为完整目录同步。
- 安全：原始选择的目录访问授权保留到队列释放，忽略符号链接、隐藏项和软件包；读取错误不静默上传不完整清单；重叠来源去重。
- 当前证据：既有多文件上传实现与测试；新切片尚未验证。Chrome 已恢复，可继续只读网页核对。
- 非目标：此切片不改持久化，不做重启恢复、文件夹创建或用户真实资料写入。上传期间浏览另行拆分读写生命周期，集成结果见下节。


### 拖放、目录导入与上传期间浏览验证

- 实际修改：`SynologyPhotosModel.swift` 增加本地媒体清单准备、原始目录授权共享持有，图库读侧与上传队列生命周期分离；`SynologyPhotosView.swift` 增加 URL 拖放与目录选择；`PhotoManagementPanel.swift` 在后台准备清单并展示忽略数量、无媒体状态和目录汇总说明。双语资源与正式 Model/UI 测试同步。
- 上传期间可刷新、跳月份、切换照片内页面/文件夹、离开图库，队列保留原始目标并继续；退出当前连接或禁用模块仍沿用全部工作取消流程。刷新复用当前已确认访问范围，不重置 Repository 的在途写操作权限代数；新的上传文件不使正在读取的图库代数失效。写操作仍串行，未知结果仅回读。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：101 项 XCTest（41 Model、60 Repository）及 6 项 Swift Testing 通过。新增目录/重叠来源、链接循环/隐藏项/空文件、不完整读取失败、目录授权释放、离开图库继续上传、读取和下一文件上传交叉时序测试。
- 新增目录测试最初失败：对符号链接调用 skipDescendants 会跳过后续正常项目；已移除该调用，保留 FileManager 不遍历符号链接的行为，原断言通过。系统临时路径别名采用规范化后的文件身份比较，没有降低来源授权和去重断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录上传确认浅深色布局|WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-import-ui`：3 项通过；已查看目录确认浅/深色截图，标题、清单与底部按钮正常。
- `python3 tools/localization/check_localization.py`：Apple 4270、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、27 项私有端点引用通过；`git diff --check` 通过。
- 独立集成复核：读取和写入状态分别管控；未删所有者/权限、预检、确认、重复提交与结果核对保护；保留用户要求的按实际能力开放。未添加 NAS API、第三方依赖、持久化、权限或工具链变更。其他端不新增界面；移动端共享 Model 的编译影响仍需 iOS 构建，未运行。
- PENDING_USER_VALIDATION：在本包选择专用合成目录并拖放同一目录，确认文件数、忽略提示、重复文件处理；上传时跳转旧月份、打开其他相册/文件夹，确认上传持续且目标不变。真机拖放、沙盒目录授权与真实 NAS 上传尚未执行，不能以合成测试替代。目录层级保留和重启恢复仍未实现。


### 导入与浏览测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-import-browse-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0。临时 xcodebuild 包装仅指定既有 `apple/.build` 缓存和 `-skipPackageUpdates`，已自动删除。
- 产物：`apple/Apps/DsmMac/dist/photos-import-browse-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，约 17 MB。临时签名、权限检查、Sparkle 实际加载（library loaded）、arm64 架构和 DMG checksum 均通过；额外 `codesign --verify --deep --strict` 与 `file` 通过。
- 未自动安装、启动或覆盖既有包；本地磁盘挂载扩展仍按现有临时签名流程排除。当前源码未提交、未推送，既有 Download Station 修改保留。本轮临时日志和合成 UI 截图已清理，正式测试与交付包保留。
- Chrome 在后续确认时再次报告锁屏，未绕过；本轮没有新增 NAS 写入。网页完整参数核对继续等待可用会话，不将尚未完成的条件相册、分享高级设置等声明为完成。

### 剩余能力依赖复核与重启恢复方案（待授权）

2026-09-29 本轮重新读取源码、契约索引和 Photos 发现记录。前一波次属于实际进展：已交付目录导入/并行浏览及构建验证。当前 Chrome 再次明确报告锁屏，不能据旧控件文案猜测新请求。

| 剩余能力 | 当前权威证据 | 接入前缺口 |
| --- | --- | --- |
| 条件相册 | 现有 NormalAlbum 普通相册契约 | 条件表达式结构、创建/修改方法与回读规则 |
| 分享高级设置 | Passphrase.set_shared/update 仅有 public view/download 参数；官方控件已观察 | 成员身份/角色、密码更新与移除、有效期语义、完整现状回读 |
| 照片请求写管理 | PhotoRequest.list v1 与空响应 | 创建/编辑/关闭参数、收集目标权限与结果回读 |
| 人物整理 | Browse.Person.list v1 | 命名/合并/纠正参数与识别成员回读 |
| 预览重建 | 无已记录写方法 | 任务创建、进度、终态与权限 |
| 共享空间写操作 | 个人空间写权限已接入 | 共享空间正向权限和实际写端点组 |
| 导入保留目录层级 | Upload.Item.upload_to_folder 已有 | Browse.Folder 创建目录的准确契约与回读 |

重启恢复为独立的本地存储变更，尚未实施；先提供可审阅方案，再取得项目 AGENTS.md 要求的单独授权：

1. 范围仅 macOS Photos 上传队列。使用当前 NAS 配置 UUID 分区，新增独立 version=1 队列记录，不改已有文件传输、NAS 配置、认证或其他端存储。目录在应用私有 Application Support 下，文件权限 0600、原子替换。
2. 存储字段：队列项 UUID、源文件名/大小/修改时间、所选来源的系统访问书签与相对路径、个人空间目标文件夹/相册编号、状态、操作 UUID、已返回的照片编号及最小身份快照。密码、Cookie、SID、SynoToken、下载数据、分享链接和用户照片内容均不保存；书签不输出日志或提交仓库。
3. 原始源目录授权用系统书签延续；过期或不可访问时让用户重新选同一来源，并按原大小/修改时间核对，不能改为扫描其他目录。若需要新增系统权限配置，另行说明，不能借本次存储授权暗中改变 entitlement。
4. 顺序：入队先原子落盘；发送前落盘“在途”；获取返回照片编号即保存；核对成功后保存“已上传”；加入相册独立记录。写入失败先停止尚未开始项并给出可重试错误，不能显示已保存。
5. 重启后未开始项恢复为可继续；已确认上传项只核对/补加入相册；原件大小/修改时间变化时要求重新选择。已提交但没有收到照片编号的结果仍不可按文件名猜测成功，也不自动重复上传。没有服务端幂等证据时，不承诺字节级断点续传或恰好一次恢复。
6. 迁移：无旧 Photos 队列，首次读取为空；老版本忽略新增文件，不迁移已有数据。回滚移除新存储注入与恢复入口，保留或由用户清除新队列记录，绝不删除 NAS 文件；现有进程内队列可独立工作。
7. 验证：进程在各状态边界终止后恢复、跨 NAS 隔离、书签失效、文件变化、原子保存失败、部分相册加入成功与未知结果不重放。五端只记录影响：macOS 接入，iOS/iPadOS 不接入桌面书签恢复，Android/Windows 不修改代码或存储。

此方案不是已完成的功能，不改变现有测试包；批准后再实现、测试和打包。


### 目录层级与后续接口发现波次

Chrome 已恢复，静态接口证据已扩展至条件相册/高级分享/人物/照片请求/预览重建/目录创建，记录见 photos-advanced-management.md，仍不是实机写入验证。优先接入逐级目录导入，单一修改范围为 Photos 领域命令、Repository、macOS 队列/上传表单及对应测试/双语资源；其他端 UI 与持久化保持不变。复用已授权契约扩展，不涉及待授权重启存储。回滚本轮新建目录命令及层级开关即可保留原汇总上传流程。


### 目录层级上传实现与验证

- 实际修改：共享 SynologyPhotosManagement 的目录能力/命令/可选结果；Repository 的预检、创建、去重及精确回读；macOS Model 的逐级解析、同批目录缓存和未知结果恢复；PhotoManagementPanel 的默认保留层级开关、目标展示和准备目录状态；双语资源和正式测试同步。未变更权限、持久化、工具链或其他端 UI。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：109 项 XCTest（45 Model、64 Repository）和 6 项本地化测试通过。新增已有目录/逐级创建/同批复用/跨批隔离/平铺选择/未知暂停恢复/回执丢失/权限拒绝与身份不匹配回归。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录上传确认浅深色布局|WorkspacePresentationTests/test多文件上传确认与队列浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-hierarchy-ui`：3 项通过，浅深色截图已查看；发现重复同名文件说明后去重。
- `python3 tools/localization/check_localization.py`：Apple 4273、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、31 项私有端点引用通过；`git diff --check` 通过。
- 独立集成与写操作复核：目录缓存以批次/父编号/名称定位，跨批重新核对；创建结果未知只读，确认后继续原队列；清除已完成项可能改变数组下标，await 后按稳定队列编号重新定位；进入上传时清除照片选择，避免阻止浏览；上传仍进行来源快照和目标权限核对。同名文件不覆盖，失败不自动回滚删除目录。
- 五端影响已同步：macOS 接入；iOS/iPadOS 共享增量但无新 UI、未运行移动构建；Android/Windows 只记影响。用户授权不设默认禁用/环境白名单，保留真实能力、权限、确认和结果检查。
- PENDING_USER_VALIDATION：专用合成目录包含两级子目录及同名目标，选择/拖放后确认层级；上传中浏览旧月份，确认不跳回最新；断网后确认不重复新建/上传，恢复后目标正确；关闭保留层级后确认汇总到原目标。回传脱敏版本、步骤、错误类别及是否重复，不提供原照片/地址/凭据。本轮未做 NAS 写入，沙盒目录权限和真实行为仍待验。

当前剩余：条件相册、分享高级设置、照片请求写管理、人物整理、预览重建、共享空间完整权限/写操作、上传跨会话与重启恢复。高级接口已取得静态线索，仍需接入和验证；重启持久化继续等待已发出的独立授权，不阻塞其他功能。

去重说明后再次运行 `WorkspacePresentationTests/test目录上传确认浅深色布局`，1 项通过，浅/深色截图复查无截断或重复提示。本地化、fixture 引用和 `git diff --check` 再次通过。


### 目录层级上传测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-structure-20260929" bash apple/Apps/DsmMac/package.sh`，退出码 0；临时 xcodebuild 包装仅指定既有依赖缓存和 `-skipPackageUpdates`，已自动删除。
- 产物：`apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，约 17 MB；App 名为 `LanStash Test.app`。临时签名、权限、Sparkle 实际加载（library loaded）、arm64 架构与 DMG checksum 均通过。
- 额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-folder-structure-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 通过；首次复核误用 LanStash.app 路径报不存在，按打包输出的实际 Test.app 路径重跑成功，非构建失败。
- 未安装、启动或覆盖之前的交付包；本机临时签名包不含 Finder 本地磁盘挂载扩展。未改变 Bundle ID、权限、存储结构或其他端界面，未提交/推送，原有 Download Station 修改保留。
- 本轮临时测试日志、截图和打包日志已清理，正式测试、脱敏接口记录与交付包保留。完整网页复刻目标仍在进行中，下一切片优先条件相册；剩余清单见上节。

### 条件相册波次基线

范围为个人空间条件相册创建、规则读取/编辑、规则建议与数量预览，集成既有相册列表/删除/重命名。当前静态证据确认 Album.list 的 normal_share_with_me 也用于官方全部相册列表，type=condition 标识条件相册；ConditionAlbum.suggest v3 返回按字段分组的建议，规则引用回读为 id/name，范围/关键词/闪光灯原样。编辑保留完整规则，不静默丢弃未知或缺失名称的引用；不做官方自动迁移清理。新契约仅按既有授权增量扩展，五端同步影响；持久化和其他端界面非目标，NAS 不执行写入。上一轮目录层级上传已交付，为有效进展。


### 条件相册实现与验证

- 实际修改：SynologyPhotosManagement 的条件能力/值/命令，SynologyPhotos 的可选类型标记和默认读取方法，Repository 的创建/原条件快照冲突检测/完整回读/建议与数量请求；DsmJSONValue 增加 decimal/null 保留合法 JSON 值。macOS 相册加号菜单增加创建条件相册，条件相册右键菜单增加编辑规则，复用重命名/删除；选择源目录与相机等规则、关键词/人物/标签/主题匹配策略、预览数量均接入。双语资源、正式测试和五端影响同步。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests|DsmRequest'`：120 项 XCTest（47 Model、70 Repository、3 Request）和 6 项本地化测试通过。覆盖条件创建的 v3/类型编码/目录权限/集合顺序，完整回读、无名引用、未知字段、过期快照、创建回执丢失不重发、所有者/日期/策略拒绝、建议范围/地点与只读数量、列表插入类型。
- 独立集成复核发现未知数组被集合归一化，新增 `test条件回读保留缺名引用和未知字段编辑时不丢失` 的两条断言先失败（空数组丢失、顺序被改），限制归一化到已知集合字段后，完整 120 项通过；没有降低原断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test条件相册表单创建编辑错误浅深色布局|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-conditions-ui`：3 项通过。已查看创建/编辑/错误浅深色图，发现错误内容偏左后补齐可用区布局并单独复测该表单。
- `python3 tools/localization/check_localization.py`：Apple 4313、Android 2188、Windows 3402，通过；`python3 tools/contract-validation/validate_fixtures.py`：3 组 fixture、31 项私有端点引用通过；`git diff --check` 通过。
- 写操作只读对抗复核：条件来源绑定当前个人空间用户，所有者/目录可见性独立核对；编辑前重新读取原条件，别处修改则报冲突而不覆盖。原有缺名引用和未知字段保留，只有已知集合归一化。创建丢失回执不按名称猜测、同操作不重发、写后规则不匹配不报成功。重命名独立于规则保存，不引入两阶段假原子保存。条件相册不提供手工加入/移除照片，其自动规则决定成员；普通相册不受影响。
- 兼容边界：个人空间已接入，共享来源仍属于剩余共享空间能力；已有闪光灯规则保留/可移除，官方默认建议未提供新闪光灯值域，不编造新入口。未引入人工禁用/版本白名单，无持久化、权限、工具链或依赖变更。iOS/iPadOS 共享模型受影响但无新 UI，未运行移动构建；Android/Windows 只同步计划。
- PENDING_USER_VALIDATION：在专用合成资料中创建条件相册，组合日期、类型、标签等规则并预览数量；保存后与网页核对成员/规则，再编辑其中一项，确认其他规则保留；网页同时修改时应提示重新核对；断网后不得重复创建。需确认真实 DSM/Photos 版本、非空建议字段、日期边界与集合回读结构。回传脱敏步骤和失败类别，不提供原照片/地址/凭据。本轮未执行真实 NAS 条件写入，不能以合成测试替代。

当前尚未完成：高级分享（成员、密码、有效期）、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复。普通个人条件相册已从“未实现”移为“源码和本地验证完成、真实 NAS 待验”。总目标继续，不把此切片算作完整网页复刻。

错误状态居中修正后，`WorkspacePresentationTests/test条件相册表单创建编辑错误浅深色布局` 再次通过（1 项，浅深色各覆盖创建、编辑与错误）。已查看修正截图，标题/表单/底部操作区与错误内容位置正常。


创建菜单最终复核：普通相册与条件相册入口独立按实际能力判定，父菜单仅在两种都不支持时不可用。新增 `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests/test普通与条件相册能力独立不相互禁用'`，1 项通过；测试初次编译的枚举类型推断问题已修正。该 UI 修正后重新生成最终 Release 包，不沿用修正前包。本地化/fixture/diff 校验再次通过。


### 条件相册最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-conditions-20260929" bash apple/Apps/DsmMac/package.sh`。菜单能力独立修正后重新完整构建，最终退出码 0；临时 xcodebuild 包装仅指向既有缓存与 `-skipPackageUpdates`，自动清理。
- 产物：`apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64，约 17 MB。临时签名、权限检查、Sparkle 实际加载（library loaded）及 DMG checksum VALID；额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-conditions-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装或启动，未覆盖前轮交付包；本机临时签名包仍不含 Finder 本地磁盘挂载扩展。不修改应用标识、持久化、系统权限或其他端 UI，未提交/推送，已有 Download Station 改动保留。
- 当前波次临时日志/合成截图已清理，浏览器源码变量删除与开发者工具关闭已确认；正式源码、测试、脱敏发现记录和交付包保留。最终 `git diff --check` 通过。整体目标继续，下一切片优先高级分享，缺口及授权边界见本账本。

### 高级分享波次基线

上一波次已交付条件相册，为有效进展。当前 Chrome 明确报告 Mac 锁屏，暂不能补齐分享密码加密、成员列表/权限非空结构及有效期时间语义；不绕过锁屏或读取浏览器会话文件。先接入已有分享状态读取、保留现状与公开/仅受邀者访问方式，复用已记录 set_shared/update 参数；高级密码、成员和有效期编辑仍保留完整目标，不凭猜测编码。只修改 Photos 领域、Repository、macOS 分享表单、测试/双语/契约记录，其他端 UI 与持久化非目标，不进行真实公开分享或权限写入。


### 分享现状与访问方式实现、集成复核

- 实际修改：Photos 领域新增 SynologyPhotoSharingState、albumSharing 与 shareAlbum 可选原快照；Repository 只读现状、并发快照检测、无改动不写入、仅受邀者公共成员删除、保护元数据回读；macOS 分享表单按当前设置初始化，展示保护标记/链接复制，修复英文提示截断。6 个双语资源同步；无人工验证名单，无持久化/权限/依赖变更。
- Chrome 恢复可用后继续静态复核，发现公开权限转换仅 private/public-view/public-download；纠正开发中按常量误加的 public-upload，并新增未知权限拒绝测试。upload 仍为具名成员角色的后续范围。未执行真实分享、密码或成员写入。加密和日期后续线索已脱敏记录，临时浏览器变量已删除、开发者工具关闭。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：125 项 XCTest（47 Model、78 Repository）与 6 项本地化测试通过。新增 7 项测试覆盖三种已启用模式读取/保护未知/不变不提交/并发修改/预读失败重试/公共成员差量/保护回读变化/未知权限。新增错误态 UI fixture 首次使用错误的 AppError 初始化参数导致编译失败，改为标准 URLError 后重跑通过；没有降低断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-sharing-ui`：2 项通过，覆盖关闭/仅受邀者/公开下载/读取错误及现有表单，已查看浅深色合成截图。打开表单写入次数为0，提示不再截断。
- `python3 tools/localization/check_localization.py`：Apple 4319、Android 2188、Windows 3402；双语、参数、引用与硬编码检查通过。`python3 tools/contract-validation/validate_fixtures.py`：3 组、31 项引用通过；`git diff --check` 通过。
- 独立集成与只读对抗复核：新增快照是内存 SHA-256，不记录分享凭据；含原成员/保护字段用于并发检测。预读取位于写入记录之外，读失败不会留下阻塞重试的未知写入；同操作复用去重。仅受邀者只删除 public 项，不误删具名成员。链接限制 http(s)、有主机、无嵌入账号密码。最后状态不符不宣称成功。其他端仅同步影响，未运行移动/Windows/Android 构建，保留既有 Download Station 改动。
- PENDING_USER_VALIDATION：专用合成相册分别在网页设置关闭、仅受邀者、公开查看/下载，macOS 打开应准确显示且无写入；更改方式时核对现有成员、密码与有效期仍保留；网页同时更改后 macOS 保存应提示重新打开；断网后只核对不重复保存。实际分享写入需要针对测试相册/访问范围单独授权，本轮未执行。回传脱敏版本、步骤和错误类别，不提供真实链接、成员和凭据。

当前剩余仍为：高级分享成员/密码/有效期编辑、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立存储授权仍待答复）。分享现状读取与访问方式已补齐，不把它称为高级分享全部完成。下一切片继续成员结构和密码/日期协议核对。


### 分享状态最终测试包

- 命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-state-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0；临时 xcodebuild 包装只指定既有依赖缓存和 -skipPackageUpdates，自动清理。
- 产物：`apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)，arm64，约17 MB。签名、Hardened Runtime 权限与 Sparkle 实际加载（library loaded）通过，DMG checksum VALID。额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash Test.app'` 与 `file 'apple/Apps/DsmMac/dist/photos-sharing-state-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装/启动，旧交付包保留；临时签名包按既有流程移除 Finder 本地磁盘挂载扩展。应用标识、存储和系统权限无变更，未提交/推送。工作区仍在 main@9c30efeab8fb，保留全部此前用户/本任务改动及未跟踪正式源码/文档，Download Station 不触碰。
- 当前波次临时日志和合成截图已删除；正式测试、脱敏证据、账本和交付包保留。最终 diff 检查通过。整体网页复刻目标仍在进行中，未标记完成。


### 分享成员管理波次基线

上一轮已交付分享状态读取、访问方式和独立测试包，属于有效进展。继续原完整目标，当前优先补齐具名成员查询、增加/移除与角色编辑，保留未展示成员并按完整原快照核对。单一修改范围为 Photos 领域/Repository/macOS 分享表单及测试、资源和契约记录；其他端 UI、持久化和 NAS 实际权限写入均非本轮范围。共享契约扩展沿用已获授权，未获上传持久化授权不影响本切片。开始前已检查 dirty main，保留此前所有改动，不提交/推送。


### 分享成员实现与验证

- 实际修改：Photos 领域新增成员身份/角色对象，状态 members 可选值与 sharingRecipients 默认方法，shareAlbum 增加默认 nil 的成员参数；Repository 读取候选、保留编号原 JSON 类型、区分系统 uid 和 Photos id、解析当前名单、差量校验/保存/回读。macOS 同一分享窗口增加搜索、用户/群组选取、角色修改和移除；内容可滚动，标题/底部操作固定，长英文权限完整显示。14 条双语资源同步。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：135 项 XCTest（47 Model、88 Repository）与6项本地化测试通过。新增10项覆盖用户/群组同编号、当前 uid 排除、整数/字符串编号、增删改差量、名字变化忽略、名单重排不写、未知结构不当空名单、目标消失、回读不符不重发、重复身份、条件相册禁止上传、关闭时成员更改不启用、仅关闭时缺失成员字段、未知原角色不降级。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-members-ui`：2项通过；扩展关闭/仅受邀者/公开下载/整体错误/候选错误/空名单/上传角色的浅深色状态，打开所有表单的写入次数为0。已查看成员正常、最长英文角色、候选错误截图；失败不遮挡既有名单和基础分享。
- `python3 tools/localization/check_localization.py`：Apple4333、Android2188、Windows3402，双语/参数/引用/硬编码扫描通过；`python3 tools/contract-validation/validate_fixtures.py`：3组、31项端点引用通过；`git diff --check` 通过。
- 独立集成/只读对抗复核：原快照完整摘要校验；新成员写前重读候选；名单重复不构造 Dictionary 以免崩溃；只发送 type/id 与改变角色，不发送显示名或完整名单；保留未知原角色，无法完整解析名单时不当空值覆盖；未改公开模式不发送 public 差量。关闭时改成员不调用 enabled=true，单纯关闭不要求已隐藏成员字段；有成员修改则核对完整身份/角色和保护状态。成员目录能力单独读取，缺失不关闭其他分享功能。检查全部 Apple shareAlbum 模式匹配已同步；五端影响记录同步，未运行其他端构建。
- 本轮无真实成员列表响应/权限写入，证据为官方前端 static 与合成自动化；后续额外常量检查遇到锁屏，之前临时源码变量已经删除，未绕过锁屏。无人工验证白名单，真实空间/所有者、重复提交和最终核对仍保留。未改变权限、存储、工具链、依赖或其他端 UI。
- PENDING_USER_VALIDATION：在明确授权的专用合成相册，添加测试用户/群组并分别查看、下载、上传，条件相册不显示上传；改一成员并移除另一成员后与网页核对名单，原密码/有效期不变；同时在网页编辑应触发冲突提示；断网不重复提交；关闭分享时调整成员仍保持关闭。提供脱敏 DSM/Photos 版本、步骤、错误类别与是否出现重复或意外扩大权限，不回传成员真实数据/链接/凭据。本轮未执行权限写入，不能把合成测试称为真实 NAS 通过。

当前剩余：分享密码/有效期编辑、照片请求写管理、人物整理、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立持久化授权仍待答复）。具名成员增删改与角色编辑已从“未实现”移为“源码/本地验证完成、真实 NAS 待验”。下一切片继续密码与有效期协议和界面，完整网页目标保持进行中。


### 分享成员最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-members-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时 xcodebuild 包装只指定已存在依赖缓存与 -skipPackageUpdates，任务结束自动移除。
- 产物：`apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64、约17 MB。签名、Hardened Runtime 权限、Sparkle 实际加载（library loaded）及 DMG checksum VALID 全部通过。额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash Test.app'`、`file 'apple/Apps/DsmMac/dist/photos-sharing-members-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 均通过。
- 未自动安装/启动，不覆盖此前包；本地临时签名按既有流程不包含 Finder 本地磁盘挂载扩展。未更改应用标识、系统权限、持久化或其他端 UI，未提交/推送。dirty main@9c30efeab8fb 仍保留此前所有改动，Download Station 未触碰。
- 当前波次临时测试日志、合成截图及打包日志已清理，正式源码/测试、脱敏记录、账本和交付包保留；最终 diff 检查通过。总目标保持 active，尚未完成全量网页复刻。


### 人物命名与合并波次基线

上一轮成员管理已完成源码、本地验证和独立包，属于有效进展。当前 Chrome 锁屏，分享加密和日期绑定暂不能补证；继续已记录 Person.set v1 和 merge v2，先完成命名/合并主流程，其他人脸级整理仍保持原目标。使用现有 Person.list、Timeline.get(person_id) 与 Item.list(person_id) 做前后核对，不猜测 face_id 或预览事件。单一修改范围为 Photos 领域、Repository、macOS 人物入口/表单、测试/双语和契约记录；其他端 UI、持久化、真实 NAS 写入非目标。保留全部 dirty main 与 Download Station 改动，不提交推送。


### 人物命名、合并与分类封面验证

- 实际修改：共享 Photos 领域增加独立人物能力/命令/结果与默认人物列表/分类缩略图方法；Repository 接入 Person.set v1、merge v2、合并前照片并集与目录权限、原人物快照和最终回读；macOS 人物卡片右键入口、命名/合并表单、封面与照片数、当前列表局部更新。新增9条中英文资源，五端影响与契约记录同步；其他端 UI、依赖、持久化、权限未改。
- `swift test --package-path apple --skip-update --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：146项 XCTest（49 Model、97 Repository）和6项本地化测试通过。新增覆盖改名冲突、清空名称隐去且回执丢失、合并重叠照片并集、来源仍存在、目录权限/不完整照片拒绝、同操作不重发、重复身份、Person v1独立命名、分类封面隔离与重新授权失效。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test人物命名合并空列表和错误浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-people-ui`：2项通过，命名/合并/空列表/错误浅深色、月份定位及删除保持位置覆盖。查看命名浅色、合并深色截图，修正误用“已选择”的照片数量文案，并增加封面以区分未命名人物；修正后上述全量聚焦测试与界面测试重新通过。
- 独立集成/只读对抗复核：分类卡片原来按相册编号取封面，现改为当前分类授权列表缩略图，分类隔离且重新授权清空；新增两项回归。人物合并所有来源与目标必须唯一且仍存在，重读名称/数量，完整读取照片并检查目录权限后才提交；回读必须同时满足来源消失、目标名称和照片并集一致。清空名称只有明确成功回执+列表隐去才认可特殊结果，未知结果仅回读不重发。此核对是照片级而非人脸级，不宣称实际识别结果已验证。正常命名不依赖 merge v2 能力，未增加人为禁用或版本白名单。
- 本轮 Chrome 锁屏，未新增前端观察或执行 NAS 写入，依赖已记录官方 static 参数与合成测试。无临时浏览器源码变量。共享空间与人脸级整理非本切片，不猜 face_id。
- PENDING_USER_VALIDATION：在专用合成照片形成的测试人物中修改名称、清空少于两张照片人物的名称，核对网页与 App 列表；将两个代表同一人的测试人物合并，含一张重叠照片，确认所有原图保留、目标名称正确、来源卡片消失；断网不得重复合并，网页同时改名应提示重新核对。需要明确真实 NAS 写入测试范围；本轮未执行。回传脱敏版本、步骤、错误类别及重复/遗漏现象，不提供原图、人物真实姓名或凭据。

当前剩余：分享密码与有效期编辑、照片请求写管理、人脸分离/封面/识别纠正、预览重建、共享空间完整权限/写入（含共享来源条件相册）、上传跨会话与重启恢复（独立持久化授权仍待答复）。人物命名与合并已从未实现移至源码/本地验证完成、NAS待验。完整网页对齐总目标仍进行中。

补充校验：`python3 tools/localization/check_localization.py` 通过（Apple4342、Android2188、Windows3402，含双语/参数/引用/硬编码）；`python3 tools/contract-validation/validate_fixtures.py` 通过（3组、31项端点文档引用），契约文档更新后再次通过；`git diff --check` 通过。已另查看人物空列表深色、加载错误浅色截图，内容区域与恢复按钮布局正常。


### 人物整理最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-people-management-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时 xcodebuild 包装仅指定既有 apple/.build 依赖缓存与 -skipPackageUpdates，自动移除。
- 产物：`apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash-1.0.10-arm64.dmg`，1.0.10 (20)、arm64、17 MB。签名、Hardened Runtime 权限、Sparkle 实际加载（library loaded）、DMG checksum VALID 均通过；额外 `codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash Test.app'` 和 `file 'apple/Apps/DsmMac/dist/photos-people-management-20260929/LanStash Test.app/Contents/MacOS/LanStash'` 通过。
- 未自动安装/启动，旧包保留。本机临时签名包按项目流程不包含 Finder 本地磁盘挂载扩展，应用标识/存储/系统权限无变更。工作区保持 dirty main@9c30efeab8fb，保留已有所有改动和正式未跟踪源码/文档，不提交或推送，Download Station 本轮不触碰。
- 当前人物波次临时日志/合成截图已清理；正式源码、自动化、脱敏文档和独立包保留。最终 diff 检查通过。完整网页复刻目标继续，下一步优先分享密码/有效期的官方绑定证据及照片请求写管理。


### 分享有效期与收集请求波次基线

上一轮人物命名/合并与分类封面已交付源码、验证和独立包，为有效进展。本轮 Chrome 恢复可读，沿用已有环境快照仅观察官方前端，不进行分享或收集链接写入。先核对有效期日期绑定与照片请求结构，再接入完整主流程；单一修改范围为 Photos 领域、网络、macOS表单/模型、测试、双语资源与五端契约文档。保留 dirty main 及下载模块改动，无持久化/依赖/其他端UI变更。

### 1.0.11 发布后继续：分享有效期

上一轮完成正式发布与Xcode升级，为有效进展。本轮基线 main@5684170，只有发布结果文档未提交；保留该记录。继续完整目标，优先接入分享有效期读取/修改/取消，使用发布前已经观察的官方日期绑定：ZR=ZD(ZL,Zk)、Zk=false，ePp选择第二回调参数（本地日结束Unix秒），清除0；该来源属于static，真实写入未验证。当前Mac锁屏，密码加密和收集请求的新增证据待解锁，未绕过锁屏。单一修改范围为Photos领域/Repository/分享表单/相关测试和双语资源、契约与五端影响记录，无存储/依赖/系统权限变更，不执行NAS分享写入。用户已授权共享契约增量扩展，不增加人工验证白名单。

### 分享有效期实现与验证

- 实际修改：共享状态增加可选expiration，shareAlbum增加默认nil参数（保留原值）；Repository解析非负整数秒、校验原快照、只发送改变字段、关闭状态修改不启用、回读完整核对。macOS同一分享窗口提供不限期/到期日期，未知值可保留；未编辑不改变原始秒数，主动修改按本地日末，日期过期时给出恢复提示。5条双语资源与旧分享提示同步。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：153项XCTest（51 Model、102 Repository）和6项本地化测试通过。新增7项测试覆盖设置/取消、关闭状态编辑、无改动不写、无快照/负数拒绝、未知与等价数值、回读不符/密码意外变化/重放保护、草稿不改变原秒数、23/25小时夏令时日。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入|WorkspacePresentationTests/test照片管理表单标题内容与操作区对齐' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-expiration-ui`：2项通过，扩展未知/无限期/过期状态；浅深色分享窗口打开后写入计数均0。已查看正常到期日期浅色和未知状态深色截图。发现旧说明仍声称期限固定保留，修改双语提示后单独重跑分享窗口测试1项通过。
- `python3 tools/localization/check_localization.py`：Apple4347、Android2188、Windows3402通过；`python3 tools/contract-validation/validate_fixtures.py`：3组、31项引用通过；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。
- 独立集成/只读对抗复核：确认快照与owner检查保留，未知原值不会自动清除，原始密码字段不发送，成员/公开权限未改变不发送差量；关闭时编辑日期必须回读匹配，不借shared=false声称完成；重复操作只查不写，保护变化不确认成功。所有Apple枚举匹配同步，无持久化/权限/依赖变更和人工禁用名单。移动端未运行本轮构建，Android/Windows只更新影响记录。
- PENDING_USER_VALIDATION：授权测试相册中设置未来到期日、清除、关闭时编辑，与网页核对日期/密码/成员；测试不同本地时区、同时网页修改、断网恢复和重复点击。真实NAS未写入，不以合成通过替代行为证据。Mac锁屏使密码加密与照片请求补证暂不可执行，未绕过锁屏；本轮仍完成独立功能，整体目标保持进行中。
- 构建最初含临时包装目录清理的命令被自动审批拒绝（禁止强制删除写法），该命令未执行。改用项目原有package.sh直接构建，不创建该临时工具目录，不绕过被拒绝的清理操作。

当前未完成：分享密码设置/清除、照片请求管理、人脸分离/识别纠正/封面、预览重建、共享空间完整权限与写入、上传跨会话/重启恢复（独立持久化授权待答复）。有效期编辑已移至源码/本地自动化完成、真实NAS待验；1.0.11公开包不包含发布后的本轮修改。

### 分享有效期最终测试包

- 命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-expiration-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。直接使用项目既有流程；未使用临时工具包装。
- 产物：`apple/Apps/DsmMac/dist/photos-expiration-20260929/LanStash-1.0.11-arm64.dmg`，本机临时签名，1.0.11 (21)、arm64、约17 MB。Hardened Runtime权限、Sparkle实际加载（library loaded）、DMG checksum VALID通过；额外`codesign --verify --deep --strict`和`file`复核通过。
- 未安装/启动，不覆盖其他交付包；按本地流程不包含Finder磁盘挂载扩展。公开1.0.11发布不包含此后的有效期增量，本轮不提交/推送/再次发布。main@5684170上保留当前Photos增量与此前发布后验证文档。
- 完成后浏览器再次确认Mac仍锁屏，密码加密/收集请求补证留待解锁；没有浏览器临时源码变量或NAS写入。当前波次临时日志/合成截图移至系统废纸篓，正式测试/脱敏文档与交付包保留。整体目标未完成，保持继续状态。

### 发布与工具链复核后继续

本轮重新读取 GitHub 发布运行36523391845，completed/success，head为5684170；公开1.0.11附件完整。本机xcodebuild -version为26.6/17F113，三个Apple工作流一致锁定该版本和macos-26。没有重复发布或覆盖公开包。保留发布后有效期源码增量，当前未提交。

Chrome已恢复，新增只读静态证据已保存到环境快照与端点记录：PhotoRequest差量/清除相册-1、密码AES封装、共享空间权限和缩略图路由。未执行NAS写入，未声称这些功能已经实现。整体目标保持active。

下一实现切片为共享空间读取：目前不仅缺正向权限判断，还缺FotoTeam能力发现、共享图片路由和macOS空间选择；相册/分类与上传目标仍假定个人空间。必须联动空间切换后的目录、筛选和目标身份，不能仅放开入口而读写错误空间。该切片尚未修改代码；五端契约影响随实现更新。密码、照片请求、人脸级整理、预览重建、共享空间写入及上传跨重启恢复仍属剩余目标，后者独立持久化授权仍待答复。

### 共享空间读取实现基线

上一轮完成静态协议记录和发布核实，属于进展。本轮 main@5684170 保留21个文件的未提交变更，先完成共享读取依赖：真实权限枚举、FotoTeam能力发现、照片身份、缩略图/预览及媒体路由。单一修改范围为现有Photos Repository、对应回归及契约/五端影响记录；不改其他端UI、不改持久化、不执行NAS写操作。空间切换界面与共享管理仍在同一完整目标内，必须解决个人相册/上传目标假设后接入，不以网络层通过宣布整体对齐。验证等级为static与合成自动化，真实NAS权限/版本验收后置。

### 共享空间读取回归

- 实际修改：Repository增加10项FotoTeam读取能力发现；entry/management且共享空间启用时返回共享访问；图片按照片空间选p/t路由、检查NAS身份和权限代次。根目录以view或共享management访问，后者不绕过个人目录权限。时间线、搜索、筛选、目录、详情、视频及原件沿用现有按空间分派，新增测试确认全部使用FotoTeam；未新增平行实现、依赖、公开领域字段或人工版本名单。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests|DsmCapabilityDiscoveryTests'`：174项XCTest（111 Repository、51 Model、12能力发现）与6项本地化测试通过。新增9项测试覆盖共享角色与服务开关、目录权限、完整读取路由、缺失能力不回退、默认启动能力发现、同编号跨空间图片/认证头、跨NAS身份与权限撤销、转换视频/原视频、实况视频单元及原件导出路由。首次测试的2个失败均为JSON斜线合法转义与字面值比较不一致，改为JSON解码后验证根路径，复跑全部通过；未降低权限断言。
- `python3 tools/contract-validation/validate_fixtures.py`通过（3组、31项引用）；`python3 tools/localization/check_localization.py`通过（Apple4347、Android2188、Windows3402）；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。本轮没有新增UI文案。
- 独立集成/只读对抗复核：检查初始能力发现确实拼入共享API；JSON接口版本/格式约束不变；共享API缺失无个人fallback；权限none/未知值/服务关闭拒绝访问；管理角色只作用于共享目录。照片ID保留profile+space+unit，图片凭据仅在请求头，旧授权先撤销。同编号跨空间、其他NAS与撤权测试通过。共享写操作尚未接入，不把已有个人写接口用于共享编号。
- PENDING_USER_VALIDATION：在明确版本的测试NAS分别用entry和management账号，检查可见目录、无权目录、同编号个人/共享媒体、原件、视频与权限撤销；共享空间选择界面完成后做端到端验收。本轮仅合成数据，不读取真实共享照片或执行NAS写操作；实况原件测试证明请求空间，不证明真实套件完整Live Photo打包格式兼容。iOS/iPadOS构建未运行，其他端仅同步影响记录。
- 剩余：macOS空间切换与相册/分类作用域、共享上传/管理仍未完成；原完整目标和其他剩余项保持不变。本轮不提交、不推送、不发布，保留全部已有未提交改动。

构建补充：`xcodebuild -project apple/Apps/DsmMac/DsmMac.xcodeproj -scheme DsmMac -configuration Debug -destination 'platform=macOS' -derivedDataPath apple/.build/photos-shared-read -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build`退出码0、BUILD SUCCEEDED，使用本机Xcode26.6。这是主App及扩展的未签名编译验证，不是可安装发布包、运行时加载或真实NAS验收；没有安装/启动。当前轮专用构建目录和两份临时日志在证据记录后移至系统废纸篓，不清理已有依赖缓存或此前交付包。

### 空间切换状态与上传作用域基线

上一轮共享读取适配、174项回归及macOS编译为有效进展。本轮保留dirty main全部21个文件变更。共享上传缺少官方FotoTeam上传参数的已记录证据，Chrome工具实际返回锁屏，已请求解锁，不猜写入协议。先在现有Model修正显式切换/权限回退的空间状态隔离，补目录、筛选、预览、迟到响应测试；完整空间选择与上传目标仍属当前目标。单一修改范围暂为SynologyPhotosModel与对应测试，未新增公开契约、持久化、依赖和真实NAS写入，不触碰此前Repository/分享有效期实现。


### 共享空间选择、上传与目录导入实现

用户已解锁，官方静态代码明确共享上传使用 FotoTeam.Upload.Item 及公共 multipart 参数；据已有契约扩展授权，单一修改范围扩展到 Photos 领域、Repository、macOS 视图/表单/模型、对应测试及五端记录。没有改变持久化、应用标识或其他端UI；没有执行共享空间NAS写入。

- 时间线/文件夹增加空间选择器；显式切换或权限回退清除旧目录、分类、筛选、搜索、预览和选择，权限消失清除管理能力。相册/分享使用个人入口，返回照片库恢复首选空间，错误空间的页面结果不进入列表。
- upload/createFolder命令和上传队列携带固定space，目录选择与逐级导入沿用该空间。共享entry按目录upload/manage权限、共享management按其实际角色；上传和读回均使用FotoTeam。上传中切换空间不会改变目标或把结果插入个人画廊，同操作编号不得换空间或重传。UI复用既有中英文资源。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：171项XCTest（115 Repository、56 Model）与6项本地化通过，退出码0。新增4项Repository和5项Model测试覆盖目标空间、权限、回读、去重、目录导入和导航隔离。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片空间选择和共享上传目标浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-space-upload-ui`：2项通过，退出码0。已查看共享空间浅色、上传表单深色合成截图；没有启动正式App或对NAS写入。
- `python3 tools/localization/check_localization.py`：Apple4347/Android2188/Windows3402通过；`python3 tools/contract-validation/validate_fixtures.py`：3组/31引用通过；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。
- 独立集成/只读对抗复核：检查所有Apple关联值匹配、无目标照片命令的空间身份、排队时固定目标、读回大小/目录/空间、跨空间缓存批次隔离、权限回退和迟到响应代次。缺失共享能力不回退个人API，原有个人管理语义保留。新增共享写范围限上传与目录，其他共享写契约仍需继续实现，不能把个人端点用于共享编号。权限、去重与最终读回保留，无人工版本白名单。
- PENDING_USER_VALIDATION：在明确授权的专用合成共享目录，用entry上传权限账号和management账号分别上传单文件/目录，切换个人空间后确认剩余文件仍在原共享目标；个人home关闭、目录上传权限移除、网络中断、同编号跨空间、重复点击均应不误传/重传。对照网页确认最终空间、目录和数量，回传脱敏版本、步骤、错误类别和重复/遗漏现象。当前没有共享写入行为证据，不把static或合成测试记作真实NAS通过。
- 当前未完成：分享密码设置/修改/清除、照片请求写管理、人脸分离/识别纠正/封面、预览重建、共享元数据/移动复制/分类与相册来源完整对齐、上传跨会话/重启恢复（独立持久化授权仍待答复）。本轮空间选择与上传源码/本地验证完成，但完整目标仍进行中。未提交/推送，公开1.0.11不包含发布后增量。


构建过程说明：直接package.sh首次停在Sparkle依赖远端更新，停止该次专用构建进程后使用临时xcodebuild启动器指定既有apple/.build依赖缓存与-skipPackageUpdates；未修改锁定版本。启动器第一次把-clonedSourcePackagesDirPath写成-clonedSourcePackagesDir，构建立即退出64，修正参数后重跑。临时启动器只追加缓存参数，未改变签名或打包校验流程，结束后清理。


### 共享空间上传最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-upload-20260929" bash apple/Apps/DsmMac/package.sh`，由上述临时启动器仅追加既有缓存路径与-skipPackageUpdates；最终退出码0，Xcode26.6/17F113。
- 产物：`apple/Apps/DsmMac/dist/photos-shared-upload-20260929/LanStash-1.0.11-arm64.dmg`，本机临时签名、1.0.11 (21)、arm64。权限校验、Sparkle实际加载（library loaded）、DMG checksum VALID均通过，额外`codesign --verify --deep --strict`和`file`复核通过。
- 未安装/启动，独立目录保留其他包；不包含Finder本地磁盘挂载扩展。公开1.0.11不含发布后这些增量，本轮没有提交、推送或重复发布。工作区保持main@5684170及24个修改文件，保留之前有效期、共享读取和发布文档。
- 测试包不替代真实NAS共享写入验收；其限制与待验步骤如上。当前波次日志、合成截图、临时启动器、失败参数诊断包与专用构建中间目录在记录证据后移至系统废纸篓；既有apple/.build依赖缓存、交付包与正式自动化保留。另已查看共享空间深色和上传表单浅色截图，无遮挡或底部操作错位。总目标仍未完成。


### 共享空间照片管理波次基线

上一轮完成共享空间选择、上传、171项回归和独立签名测试包，为有效进展。本轮保留main@5684170上全部24个修改文件，单一修改范围为Photos领域、Repository、macOS管理表单/测试及契约记录。只读官方脚本确认共享Item.set/tag、GeneralTag、BackgroundTask.File命名空间；特别确认后台状态仍统一查询Foto.BackgroundTask.Info，不能机械替换成FotoTeam。继续接入共享照片批量编辑、标签、同空间移动复制和删除的完整已有主流程；跨空间移动、相册来源/分类与人物、持久化、其他端UI非本切片。沿用已授权契约扩展，新增默认参数不迁移存储，回滚可移除本轮共享管理路由；真实NAS写入未执行，证据为static，合成与构建待运行。


### 共享照片管理实现与验证

- 实际修改：共享Item评级/描述/绝对日期/相对偏移、标签增删/新建、同空间移动复制与原件删除；照片命令从目标身份取空间，createTag增加默认personal的space用于空目标。预检拒绝混合空间/NAS；共享entry要求view/manage，management只用于共享目录。移动复制按FotoTeam.File提交，但Foto.Info核对任务；标签创建后按同空间列表与照片回读。删除增加授权代次预检并使用同空间Item空列表确认。
- macOS批量管理表单和目录选择保留打开时空间，标签创建明确空间；复用现有确认、局部更新和自动核对，没有新用户文案或人工禁用名单。相册/人物仍使用既有个人契约，不把共享编号混入未实现入口。其他端UI、存储、签名、系统权限未改。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests|DsmCapabilityDiscoveryTests'`：191项XCTest（122 Repository、57 Model、12能力发现）与6项本地化通过，退出码0。新增7项Repository测试覆盖6种照片编辑、标签空目标/应用、管理权限、混合空间拒绝、共享移动复制与统一任务查询、删除回读去重、独立能力缺失；新增1项Model验证共享月份批量编辑后保留选择，删除自动核对且不回最新月份。首次Model测试误把再次调用日期组选择当成维持选择，实际语义为取消全组选中，导致3条断言失败；修正为断言编辑后原选择仍保留，再删除，完整复跑通过，未降低结果断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享照片批量管理和评级表单浅深色布局|WorkspacePresentationTests/test照片月份跳转静置不触发向前加载且删除不回到最新月份' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-shared-manage-ui`：2项通过，退出码0。已查看共享批量选择深色与评级表单浅色截图，工具栏、确认表单和底部操作完整；打开表单写入计数0。
- `python3 tools/localization/check_localization.py`通过（Apple4347/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组/31文档引用）；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。
- 独立集成/只读对抗复核：逐处核对个人/共享接口映射，确认Info不能替换为FotoTeam；个人相册/人物命令仍不接收共享照片。检查目标身份、混合空间/账号、目录manage与upload差异、写前权限代次、操作编号去重、成功回读、移动目标及copy任务完成判定。标签列表校验分页大小/唯一正编号，标签字段缺失仍不证明移除成功。此前个人操作、有效期、共享上传回归保持通过。无需存储迁移，默认关联参数的构造兼容但枚举匹配需同步，Apple已同步；未运行其他端构建。
- PENDING_USER_VALIDATION：专用合成共享目录中用entry/manage与management账号批量改评级/描述/日期/标签，并与网页核对；同空间移动复制确认源目标和数量、名称冲突不覆盖；单项及批量删除前核对NAS回收站条件，删除后自动确认且留在原月份；断网、权限撤销、重复点击不能重复写入或误认成功。仅有upload的账号必须拒绝修改/删除已有照片。需要用户明确授权专用共享写测试环境；本轮未执行NAS写入，static不等于behavior-verified，且不会引用个人空间旧行为证明共享兼容。
- 当前剩余：分享密码设置/修改/清除、照片请求写管理、人脸分离/纠正/封面、预览重建、共享分类/人物/相册来源完整对齐与跨空间移动、上传跨会话/重启恢复（独立持久化授权仍待答复）。共享基本照片管理已从未实现移到源码与本地自动化完成、真实NAS待验；完整目标保持进行中，不提交/推送/重复发布。


### 共享照片管理最终测试包

- 实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-management-20260929" bash apple/Apps/DsmMac/package.sh`，临时xcodebuild启动器仅指定既有apple/.build依赖缓存与-skipPackageUpdates，未修改工具链或依赖；退出码0，Xcode26.6/17F113。
- 独立产物：`apple/Apps/DsmMac/dist/photos-shared-management-20260929/LanStash-1.0.11-arm64.dmg`，17 MB、arm64、1.0.11 (21)。Hardened Runtime权限校验、Sparkle实际加载（library loaded）与DMG checksum VALID通过；额外`codesign --verify --deep --strict`及`file`复核通过。本机临时签名，不包含Finder本地磁盘挂载扩展；未安装/启动，未替换其他测试包或公开正式包。
- 另查看批量管理浅色、评级深色合成截图；本轮浏览器临时脚本引用（含局部console变量）已清空并确认长度0，DevTools关闭。临时日志/合成截图/启动器和专用构建中间目录已在记录后移至系统废纸篓；正式测试、脱敏文档、已有依赖缓存和交付包保留。
- 工作区为main@5684170，25个修改文件，全部此前Photos有效期/共享空间增量和发布结果文档保留；本轮不提交、不推送、不发布。没有真实NAS共享写入，整体网页功能对齐仍未完成，继续上述剩余清单。


### 分享密码管理波次基线

上一轮共享基本管理、191项回归和测试包为有效进展。本轮保留main@5684170全部25个修改文件，继续分享密码设置/替换/清除。官方只读脚本补齐RSA填充与实际参数编码；但当前DsmEndpoint/DsmRequestBuilder明确只接受HTTPS，故无需新增不可能触发的HTTP加密路径，不改变既有连接策略、依赖、权限、持久化或其他端UI。使用官方HTTPS提交语义（password仅编辑时发送，清除空字符串），共享契约增加默认nil参数沿用已有授权；回滚移除本轮密码字段/表单即可，原成员/有效期独立保留。范围为Photos领域、网络、macOS分享表单、测试/双语及契约记录。新密码成功必须明确update成功回执与enable_password回读同时满足，不能用已有true状态推断丢失回执时改密成功。真实分享密码写入未执行。


### 分享密码实现与本地验证

- 实际修改：shareAlbum默认nil的password参数，明确空串清除/非空原样设置；Repository所有者与原快照预检、单次更新回执记录、保护状态和成员/期限/访问方式一致核对。macOS安全输入与保留/设置/取消保护选项、关闭清空草稿；新增5组中英文资源。未改变HTTPS策略、持久化、依赖、其他端UI或正式发布。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：185项XCTest（127 Repository、58 Model）及6项本地化通过。新增测试覆盖启用/关闭分享、已有/没有保护的设置替换清除，空格/Unicode编码、丢失回执不误认替换、清除回读、成员/期限/状态不匹配和原快照冲突、去重及URL不含密码。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分享密码选择显示安全输入且不提前写入|WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-password-ui`：2项通过，退出码0。实际点击菜单切换新密码/取消保护，验证安全输入出现/消失、打开与编辑选项写入计数0；10种分享状态与浅深色窗口均绘制。已查看新密码浅深色截图，标题和底部操作固定，成员区可滚动。
- UI测试初次误认SwiftUI默认Picker为NSPopUpButton，定位失败；改为点击真实菜单后通过。通知回调另修正Swift 6主线程隔离编译错误，未删除或降低安全输入/零写入断言。临时诊断输出已从源码移除。集成复核还移除误加到只读SharingState初始化器、实际未使用的password参数，避免把秘密引入状态模型契约。
- `python3 tools/localization/check_localization.py`通过（Apple4352/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组/31引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。
- 独立集成/只读对抗复核：HTTPS-only在Endpoint和RequestBuilder双处存在；密码仅明确编辑时进入POST参数，不进入URL/日志/磁盘。设置成功须明确update回执，旧保护true不足以证明回执丢失时已替换；清除false能形成状态证据。关闭分享时编辑保护不重新启用。失败/取消不重放，原有所有者、权限代次、快照冲突与操作编号互斥均保留。当前Repository缓存持有命令用于去重，属于会话内内存，不添加永久存储。
- PENDING_USER_VALIDATION：需用户授权专用合成相册，在HTTPS连接中设置合成密码、用独立访客验证无密码和旧密码拒绝/新密码可用；替换后核对原成员/期限未变，再清除保护、关闭分享后编辑及恢复。断网与重复点击不得自动重发或误报成功。回传仅操作步骤/应用提示/保护布尔结果，不回传真实密码或分享链接。本轮未执行NAS分享写入，静态官方证据和合成测试不等于行为验证。
- 当前剩余：照片请求创建/编辑/删除、人脸分离/识别纠正/人物封面、预览重建、共享分类/人物/相册来源完整对齐与跨空间移动、上传跨会话/重启恢复（持久化变更独立授权仍待答复）。分享密码已转为源码/本地验证完成、真实NAS待验；完整目标仍进行中。


### 分享密码最终测试包与交付状态

- 最终核心回归在清理SharingState多余初始化参数后复跑：185项XCTest与6项本地化通过，退出码0；UI最终2项通过，无剩余失败。
- 实际打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-password-20260929" bash apple/Apps/DsmMac/package.sh`。临时xcodebuild启动器仅加既有apple/.build缓存路径和-skipPackageUpdates，工具链仍Xcode26.6/17F113；退出码0。
- 产物为`apple/Apps/DsmMac/dist/photos-sharing-password-20260929/LanStash-1.0.11-arm64.dmg`，17 MB、arm64、1.0.11 (21)，应用名称为LanStash Test.app。签名与Hardened Runtime权限、Sparkle实际加载（library loaded）及DMG checksum VALID通过；额外对实际Test.app执行`codesign --verify --deep --strict`和`file`复核。首次额外复核误用LanStash.app路径，纠正名称后通过，未修改产物。
- 测试包为本机临时签名、不包含Finder本地磁盘挂载扩展，没有安装或启动，不覆盖之前测试包或公开版本。最终工作区仍main@5684170、25个修改文件，全部原有改动保留；未提交、推送或再次发布。
- 本轮一次性日志、合成截图、临时启动器及专用local-test构建中间目录在记录后移至系统废纸篓；依赖缓存与交付包保留。持续防休眠服务不属于开发临时进程，保持运行。完整网页对齐目标仍在进行中，剩余五类功能见上一节。


### 照片收集请求管理波次基线

上一轮分享密码实现、185项业务回归和独立包为有效进展。本轮从main@5684170、25个已有修改文件继续，先补官方PhotoRequest创建/编辑/删除的目录、回执和读回语义，目标包含个人/共享目录、可选相册、标题说明、期限与大小限制及链接。沿用已获授权的契约增量与五端评估，不改变存储/依赖/其他端UI，不进行真实NAS创建或删除。只读环境沿用2026-09-28-photos-parity-observation，版本未知不编造；现有static线索继续补证。实现范围为Photos领域/Repository/macOS分享页面与表单、相关测试及双语/契约文档；需保持未知创建不按名称追认、编辑快照冲突、明确目标确认与结果核对。


### 收集请求主流程实现与验证

- 新增共享领域请求设置/完整快照/候选相册、photoRequests能力及create/update/delete命令；服务增加精确请求读取和addable相册列表，旧实现默认显式不支持。目录Collection.path默认nil兼容旧调用，真实Folder.name保留完整路径给选择器。Repository按自有请求list精确passphrase核对，不猜get结构；个人/共享目录检查编号、路径和upload，默认目录不提前创建，共享entry不得自动创建默认目录。
- macOS分享→照片请求接入创建/编辑/删除确认。表单有标题/说明、默认或已有目录、空间、自有/共享相册、期限及MiB限制，保存差量、清除相册-1。默认目录随新标题联动；已有请求不联动，未改限制保留原始字节值。Model结果局部插入/替换/删除列表，不刷新整库。21组中英文资源已同步，未加版本白名单、依赖、持久化或其他端UI。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：最终196项XCTest（136 Repository、60 Model）与6项本地化通过，退出码0。新增9项Repository覆盖两空间创建与去重、默认目录、回执丢失、不按名称追认、差量/清除目标、失效目录删除、addable目标、跨NAS/目录改变/错结果、共享上传权限与共享相册标识、缺字段/独立能力；新增2项Model覆盖局部CRUD自动核对和网页默认目录字符替换。
- 初次编译修正复用类型名ManagementAlbums和测试异步值不能位于XCTUnwrap自动闭包；首轮原有目录测试因Collection新增path触发两处等值失败，期望值补入真实路径后通过。共享目录请求断言改为先JSON解码再比较，避免合法斜杠转义造成误报，业务断言未降低。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片收集创建编辑删除和错误浅深色布局不提前写入|WorkspacePresentationTests/test分享窗口读取现状与错误浅深色布局且不写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-request-ui`：最终2项通过；覆盖创建、编辑、删除、读取错误、相册错误、失效目录、共享请求的浅深色布局和原分享10状态，打开表单写计数0。已查看创建浅色、编辑深色和共享请求深色截图。集成复核发现onChange会把加载已有共享请求误作用户切换空间，已改为只由Picker绑定写入触发，原目录保持。
- `python3 tools/localization/check_localization.py`通过（Apple4373/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组/31文档引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。
- 独立集成/只读对抗复核：新接口均沿既有HTTPS/认证头路径，收集标识不输出日志/文件；自有列表回读、完整快照、profile身份、空间权限代次及操作编号互斥保留。create无明确标识始终未知，不能同名追认；update成员相册/目录变动成对编码，未编辑期限/字节不归一化；delete缺失目录不阻止，但列表读取失败/重复身份/缺字段不能当成功。请求能力缺失不影响照片编辑或相册分享。
- PENDING_USER_VALIDATION：在用户授权的专用合成目录/相册创建个人和共享收集请求，用独立访客提交合成图片/视频，对照数量、目录、相册、大小限制和到期时刻；更新目录/目标相册与标题后核对网页，删除后验证链接失效及既有文件实际处理语义。断网/重复点击/权限撤销/请求在网页被修改不得误认或重发。仅回传脱敏步骤、错误类别及是否重复/错位，不回传链接、标识、用户文件。未执行任何真实NAS收集写入，static与合成测试不升级为行为兼容。
- 本轮收集请求CRUD主流程已实现，但窗口内直接新建目标相册、请求列表搜索尚待补齐；人脸分离/识别纠正/人物封面、预览重建、共享分类/人物/相册来源与跨空间移动、上传跨会话/重启恢复仍未完成。持久化变更授权待答复，其他独立功能继续；完整目标保持进行中。


收集请求完成审计补充：当前创建入口位于分享→照片请求。网页还允许从文件夹/相册直接发起、生成默认标题、在目标选择器内新建普通相册和搜索请求；这些交互尚未接入，继续列入下一切片，不因CRUD与构建通过就宣称完全对齐。共享entry的默认目录选项目前在提交预检明确拒绝、用户可选择已有上传目录；后续应将已知权限用于表单默认选择，保留实际可用功能。

### 收集请求本机测试包交付

- `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-requests-20260929" bash apple/Apps/DsmMac/package.sh` 已完成，退出码0。临时启动器为xcodebuild指定现有apple/.build依赖缓存和skipPackageUpdates，未改变项目依赖或工具链。
- 产物：`apple/Apps/DsmMac/dist/photos-requests-20260929/LanStash-1.0.11-arm64.dmg`，约17MB，版本1.0.11(21)，本机临时签名。arm64 Release构建、严格签名检查、临时包权限检查、Sparkle实际加载及DMG校验均通过；独立复核`codesign --verify --deep --strict`退出码0，`file`确认主程序为arm64。
- 未安装或启动，不含本地磁盘挂载扩展，不代表新的正式发布或真实NAS验收。工作区保持main@5684170及25个修改文件，没有提交、推送或覆盖已有改动。

用户再次明确：真实NAS实际测试由用户负责，已实现功能不得因尚未实测或版本未验证而人为关闭。复核照片页面、管理表单、Model和Repository，当前管理入口按实际API能力、账号权限、目标条件和操作状态判断，未发现按验收记录或DSM build白名单禁用的分支；本轮无需为此修改业务代码。保留权限检查、危险操作确认、重复提交保护和结果核对；PENDING_USER_VALIDATION仅记录用户待测事项，不作为功能开关。尚未实现的共享人物/相册等能力继续如实列为开发待办，不用空实现放开按钮。

删除入口另行追踪到macOS组合根LoginViewModel：构造Photos Repository时已明确传入deletionEnabled:true，因此共享Repository面向其他调用方的默认值false不会关闭本次macOS测试包的删除功能，未扩大修改至其他平台。

### 收集请求配套交互波次基线

前轮收集CRUD构建与测试包已完成，为有效进展。本轮基于同一main及25个已有修改文件补文件夹/普通相册快捷入口、日期默认标题、表单内创建目标相册与请求搜索。证据沿用photos-advanced-management的官方静态记录；复用现有相册写入和结果核对契约，不新增共享接口、持久化或其他端UI。危险写入仍由用户确认，真实NAS验收交给用户且不作为功能开关。重点验证跨页搜索、来源目标快照、嵌套创建的单次提交及延迟核对后选中；不把本波次完成等同全部照片对齐。

### 收集配套交互实现与验收

- 文件夹卡片右键和当前目录工具栏、个人普通相册卡片右键和相册内部工具栏可发起收集；表单保存来源目录编号/路径/空间或相册编号快照，自动生成App语言的日期标题。条件相册不充当普通收集目标，共享来源相册完整对齐仍在后续范围。
- 表单展开“创建相册”后输入名称，可点击或回车创建；复用现有prepare/perform/review操作编号及结果核对，只在明确成功后选择返回的相册。结果未知时继续核对，不按名称追认、不重复创建；预检失败不会残留完成回调。入口按实际个人相册能力开放，不以待实测为由关闭。
- 请求搜索使用独立关键词与标题匹配，不触发时间线刷新、不构造未经确认的远端查询参数。首屏无匹配仍保留分页入口，由现有自动加载继续读取后续页；全部读取后显示收集专用的无匹配提示，清除搜索直接恢复已加载列表。请求增删改继续局部更新，不丢失搜索条件。
- 集成复核修正相册创建结果与文件夹编号碰撞：仅相册列表接收相册卡片更新，在文件夹内新建收集目标相册不能把同编号文件夹改成相册。增加回归并通过。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`：200项XCTest（136 Repository、64 Model）与6项本地化通过，退出码0。新增4项覆盖来源快照/默认标题、跨页/大小写重音搜索与清除、未知创建到完成仅回调一次/重复提交/预检失败、相册文件夹编号碰撞。
- UI检查命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片收集创建编辑删除和错误浅深色布局不提前写入|WorkspacePresentationTests/test照片收集搜索跨页自动加载及空错误浅深色布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-request-interactions-ui`。首次新增完整页面fixture漏注入MacAppearanceStore，触发测试进程退出；按既有完整页面fixture补齐环境后2项通过，没有降低断言。检查包含9种表单状态及匹配/无匹配/空/错误列表的浅深色绘制，真实页面自动加载第二页命中请求，写入计数始终0。截图复核发现无匹配提示误用照片文案，改为收集专用双语资源后复跑。
- 只读对抗复核：仅明确点击/回车创建相册会提交，不因打开收集窗口写入；请求与相册创建使用各自命令和权限预检，跨空间的相册能力由真实个人空间接口独立核对；原删除确认、身份、并发操作互斥与结果核对保留。本轮无共享契约、依赖、工具链或存储格式变更，其他端UI与构建未触碰。
- 剩余主要能力为人脸分离/纠正/封面、预览重建、共享分类/人物/相册来源/跨空间移动（含收集表单按共享权限优化目录默认选择）、上传跨会话/重启恢复。真实NAS收集链接与访客上传由用户验收，PENDING_USER_VALIDATION只是待办；入口不添加实测白名单。完整网页对齐目标保持进行中。

收集配套交互补充验收：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test收集窗口回车新建相册后自动选中且不提前创建收集' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-request-interactions-ui`通过1项实际窗口操作测试。点击展开箭头、输入名称并回车，仅创建相册一次；返回相册自动选中，再点击收集确认才提交含返回相册编号的收集命令。初次定位误点DisclosureGroup文字导致未展开，改为箭头后通过；截图等待展开动画完成，不改变业务断言。该测试只写合成服务，不访问NAS。本波次UI合计3项通过。

`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-request-interactions-20260929" bash apple/Apps/DsmMac/package.sh`退出码0，使用现有依赖缓存启动器。产物`photos-request-interactions-20260929/LanStash-1.0.11-arm64.dmg`约17MB；Release、严格签名、权限、Sparkle实际加载、arm64架构及DMG校验通过，未安装/启动/公开发布。首次构建为修正搜索空状态文案主动停止，最终完整重建成功。

### 用户追加：照片预览触控板捏合缩放

用户在本波次中明确要求加入双指缩放。照片预览复用FilePreviewView中的FittedImagePreview，原实现仅注册scrollWheel，没有magnify。沿同一AppKit本地事件监听增量接入magnify，按当前SDK公开NSEvent.magnification语义累加倍率，保留0.25至5倍范围；捏合期间关闭补间动画并按新倍率保留/限制平移，滚轮和按钮沿用原路径。监听仍限定当前窗口与图片视口，关闭视图移除监听；Live Photo播放时沿既有isZoomEnabled规则处理，不改变视频、PDF、NAS接口或存储。

新增MacAppearanceTests合成公开NSEvent属性，验证连续正负捏合增量、滚轮仍可用、视口外/其他窗口/其他事件不被截获。`swift test --package-path apple --skip-update --jobs 4 --filter 'MacAppearanceTests|SynologyPhotosModelTests|SynologyPhotosRepositoryTests|DsmLocalizationTests'`最终224项XCTest（24外观/64Model/136Repository）与6项本地化通过，退出码0。合成事件路由不等同物理触控板实测；按用户分工，实际捏合/拖动手感由用户验收，不设置待实测开关。共享图片组件也用于文件图片预览，两处同时获得捏合支持。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片预览与视频控制区继承主题且不发起写操作' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photo-pinch-ui`通过1项，覆盖中英文/浅深色图片预览和原生视频控制区，合成服务没有自动写入。加上收集配套的3项，本波次共4项UI检查通过。静态复核监听范围、返回nil消费事件、弱引用与dismantle移除监听；持续捏合按适配尺寸及当前倍率计算平移上限，不依赖上一帧图像大小。SDK公开头文件NSEvent.h明确magnification为增量，未依赖私有触控字段或额外系统权限。

最终测试包：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-pinch-20260929" bash apple/Apps/DsmMac/package.sh`退出码0，现有缓存启动器参数与前轮一致。`apple/Apps/DsmMac/dist/photos-pinch-20260929/LanStash-1.0.11-arm64.dmg`约17MB，包含收集配套交互与预览捏合。Release构建、独立严格签名检查、权限与Sparkle实际加载、arm64架构及DMG校验均通过。版本1.0.11(21)、临时签名、不含本地磁盘挂载扩展，未安装/启动或再次公开发布。

交付保持main@5684170及27个修改文件（在前25个文件上增加FilePreviewView与MacAppearanceTests），未提交/推送，原有修改保留。已完成进程的一次性日志、截图、启动器和local-test构建中间目录在记录后移至系统废纸篓，保留依赖缓存、各轮交付包及持续防休眠服务。完整照片对齐目标仍进行中；用户负责真实NAS与物理触控板验收。


### 人脸整理波次基线

从main@5684170及27个已有修改文件继续。上一轮捏合交付已完成，本轮聚焦个人空间人物照片的人脸选择、移出人物、归入既有人物/新人物及人物封面，不改上传持久化。先读取当前官方脚本的Person.list_face与分离/移除/封面调用，再复用现有身份、权限、确认、操作编号和自动结果核对；真实NAS写入交给用户，未实测不作为人工禁用开关。完整人脸框编辑、共享人物和预览重建仍须分别对齐，不能用本轮子流程代替。


### 人脸整理源码与本地验收

- PhotoManagementPanel/View增加人物照片选择菜单、逐脸勾选与新/既有人物选择、封面确认。SynologyPhotoFace和服务读取提供兼容默认实现，Repository按照片独立读取人脸，照片与人脸身份分别校验；新增两项独立能力，不引入版本/实测白名单。
- 删除识别/分离只操作face_id，写前检查人物快照、照片身份与目录权限，原图不删除。分离核对来源消失及目标同照片的人脸编号，未知新人物不按名称追认；封面回读需与明确回执一致，不猜cover等于photo_id。Model只从当前原人物视图移除已不含该人物脸的照片，保留导航和其他照片。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`：最终211项XCTest（146 Repository、65 Model）与6项本地化通过。新增10项Repository覆盖独立编号/缩略图/重新授权、只移出指定人脸与同照片残留、不重放、来源残留、归入既有/新人物、未知回执、目标错脸/改名、错误归属/重复编号/目录权限/照片身份、封面回读、跨NAS读取拒绝；新增Model回归当前人物局部移除且时间轴原图仍存在。
- 首次Model回归fixture未实现人物使用的filteredTimeline/filtered照片查询，取不到照片；补充合成服务实际查询分支后通过，没有修改生产筛选路径或降低断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test人脸选择纠正封面和空错误浅深色布局不提前写入|WorkspacePresentationTests/test人物命名合并空列表和错误浅深色布局|WorkspacePresentationTests/test人脸窗口取消一张后回车只提交其余人脸' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-people-wave-ui`：最终3项通过，含新表单5种状态与原命名合并4种状态的浅/深色绘制，打开窗口写入0。实际取消首张勾选，再用默认回车确认，仅提交其他人脸一次，编号非照片编号。已查看移出浅色和归入深色截图。
- 新增UI测试的合成鼠标确认未触发，原因未验证；改用原生默认回车确认，保留取消勾选和最终命令精确断言。临时无障碍排查因协议访问形式编译失败，诊断代码已移除。真实鼠标/触控输入仍由用户验收，不能将键盘验证表述为鼠标验证。
- `python3 tools/localization/check_localization.py`通过（Apple4387/Android2188/Windows3402），fixture验证3组/31引用、严格文档检查及git diff --check通过。
- 独立集成与只读对抗复核：缩略图沿既有HTTPS/认证头，新增face类型只接受当前会话已读取身份；重新授权清缓存。危险写入仍需表单确认、实际目录权限、不可变身份、操作编号和结果校验；不存在未知创建按同名追认、照片编号当人脸编号或真实NAS探测写入。本轮共享契约增量已同步五端影响，无其他端UI或持久化修改。
- PENDING_USER_VALIDATION：专用合成含人脸的照片中测试同图多脸仅移出其中一张、归入已有/新人物、设置封面；对照网页确认原图未删除且当前人物位置保留；再测试断网/重复确认/账号权限撤销/网页改名，不能误认或重放。需回传仅操作步骤、提示类别、是否归入正确人物和是否重复，不回传真实照片/姓名/编号/链接。测试物理鼠标点击确认和人脸缩略图实际显示。本轮未执行真实NAS人物写入，static与合成结果不升级为行为兼容。


### 人脸整理最终测试包与工作区

实际打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/people-faces-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-people-faces-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时xcodebuild启动器沿用apple/.build依赖缓存和skipPackageUpdates，不改工程/工具链。产物`apple/Apps/DsmMac/dist/photos-people-faces-20260929/LanStash-1.0.11-arm64.dmg`约18MB、1.0.11(21)、arm64、临时签名。Release构建、严格签名、Hardened Runtime本地测试权限、Sparkle实际加载（library loaded）和DMG checksum VALID通过；另独立执行codesign --verify --deep --strict和file复核通过。

包包含此前捏合与收集/分享改动及本轮人物整理，没有自动安装、启动或公开发布，不包含Finder本地磁盘挂载扩展。工作区保持main@5684170及27个修改文件，无提交/推送，原有改动保留。本轮一次性日志、截图、启动器和专用构建中间目录在取证后移至系统废纸篓，交付包/依赖缓存/持续防休眠服务保留。完整目标仍进行中，下一切片为人物显示隐藏与图片内完整人脸编辑，再继续预览重建和共享照片能力。


### 人物显示隐藏波次基线

沿main@5684170及27个已有修改文件继续，前轮人脸整理与测试包为有效进展。本轮独占Photos领域/服务/Repository/macOS表单与相关测试文档，补人物显示隐藏（含批量、可恢复显示）和人物封面读取的两种官方形式，不修改其他端UI/存储。仍以实际权限和能力开放、用户负责真实NAS验收。手动画框流程额外需要裁剪缩略图上传，先保存官方静态线索，不用缺少该步骤的add_face假装完整实现。

### 触控板缩放交付复核（2026-09-29）

再次核对用户的照片预览双指捏合请求：当前未发布工作区与上述人脸整理测试包已经包含该实现，不另建平行手势。实际重跑 `swift test --package-path apple --skip-update --jobs 4 --filter 'MacAppearanceTests/test图片预览接收捏合与滚轮但不截获其他窗口或区域'`，当前源码编译成功，1项测试、0失败、退出码0。对 `photos-people-faces-20260929/LanStash Test.app` 执行 `codesign --verify --deep --strict` 通过，同目录DMG执行 `hdiutil verify` 返回VALID。该测试包可供用户直接验收捏合，无待实测禁用开关；本次未安装、启动、提交或发布。`PENDING_USER_VALIDATION`：打开照片预览，连续张开/收拢双指，放大拖动后继续捏合，再验证滚轮；预期连续缩放、不反复回中、其他窗口不受影响。如失败请回传测试包版本、触控板类型和复现步骤，不含真实照片或NAS信息。物理触控板手感仍未由Agent实测。


### 2026-09-29 人物显示管理增量

macOS个人空间人物页新增批量显示/隐藏、搜索与恢复隐藏入口，人物卡片菜单可直接选择原人物。隐藏不删除照片，结果局部更新，不刷新到最新日期。读取Person.list(show_hidden/show_more)，提交前后Person.get明确核对show，Person.show仅改变选中项；部分成功只更新已确认项，未知只回读不重放。人物封面同时支持unit_id/type=unit和人物编号/type=person两种结构。

共享契约增量为SynologyPhotoPersonVisibility、peopleVisibility能力/读取、setPeopleVisibility命令及结果personVisibility（默认空）；服务读取默认显式不支持保证旧实现源码兼容。macOS及共享Apple Repository实现；iOS/iPadOS仅共享声明，不新增UI且未运行移动构建；Windows/Android记录迁移影响，未改源码。无依赖、工具链或持久化变更；回滚移除本轮入口和增量声明/方法即可，已改变的人物状态可在官方网页恢复。权限、确认、重复保护和结果核对保留，不设置待实测人工禁用开关。

证据等级static及本地合成验证；PENDING_USER_VALIDATION：以少量测试人物隐藏后重新显示，确认照片仍保留、刷新后状态一致、关闭弹窗不写入；失败回传脱敏步骤与界面错误。详细本地命令及结果见MACOS_PHOTOS_PARITY_20260929_ZH.md，不能据此宣称共享人物或手工画框完成。


### 人物显示管理本地验证与独立复核

实际命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'` 退出码0：218项XCTest（152 Repository、66 Model）及6项本地化通过。本轮新增6项Repository测试覆盖包含隐藏项、两种人物缩略图、批量显示/隐藏、部分成功、缺条目/缺show/未改变不能确认、断网后只回读不重放、快照改变与权限/重复选择拒绝；Model覆盖隐藏后恢复、部分更新与不重新读取照片。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test人物显示隐藏表单正常空错误浅深色布局不提前写入|WorkspacePresentationTests/test人物显示搜索空状态保留选择并回车只隐藏目标' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-visibility-ui` 退出码0、2项通过，覆盖正常/空/错误浅深色窗口、搜索为空、取消搜索保留选择、原生回车确认仅提交原人物。人工检查合成正常深色和搜索空浅色截图，标题/表单/空状态/底栏占用正确；加载分支沿现有isLoading全内容区ProgressView，不提前写入。原生鼠标按钮完整交互与真实NAS均未实测，不以本地合成替代。

实现完成后独立只读复核：显示入口在人物列表为空时仍可打开，便于恢复全部隐藏人物；默认服务实现显式不支持，不冒充旧端已实现；真实能力和个人空间权限检查在提交前运行；每个操作编号只写一次，未知结果仅核对；验证明确show，不能用列表缺失推断成功；跨授权代次禁止拼接分页；只改变人物列表与筛选，照片删除接口未参与；缓存类型与会话失效处理一致。未发现需要新增依赖或持久化格式的修改。本轮首次聚焦测试/界面检查通过，补充边界测试后最终218项与2项通过，无删除断言或静默跳过。

`python3 tools/localization/check_localization.py`通过（Apple4400、Android2188、Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过（3组、31引用），`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。五端契约影响同步，移动/Windows/Android未构建，真实NAS版本兼容未宣称成立。


### 人物显示管理最终测试包与后续范围

实际打包：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/people-visibility-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-people-visibility-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时xcodebuild启动器仅复用apple/.build依赖缓存及skipPackageUpdates，未改工具链。新包`apple/Apps/DsmMac/dist/photos-people-visibility-20260929/LanStash-1.0.11-arm64.dmg`约18MB、arm64、版本1.0.11(21)、临时签名；Release构建、严格签名、Hardened Runtime测试权限、Sparkle实际加载、架构与DMG VALID通过；独立codesign --verify --deep --strict及file复核通过。包含前轮触控板捏合和人脸整理，未安装/启动/覆盖旧包或公开发布，不包含Finder本地磁盘挂载扩展。

工作区仍为main@5684170、27个修改文件，无新增提交/推送，既有用户改动保留。本轮测试与打包完成后将一次性日志、合成截图、启动器及专用构建目录移至废纸篓，保留测试包、依赖缓存和持续防休眠服务。剩余：图片内手动画框新增/编辑人脸及裁剪缩略图完整上传、照片/视频预览重建、共享分类/人物/相册来源/条件源与跨空间移动、共享收集目录默认选择、上传队列跨会话/重启恢复（持久化变更授权仍待答复）。按源码核对，以上不能由本轮人物显示功能代替；完整目标保持进行中。


### 图片内人脸编辑波次基线

上一波人物显示/隐藏为已完成进展，沿main@5684170和27个已有修改文件继续。当前独占Photos领域/Repository、macOS预览与表单、测试和双语/契约文档；不改其他平台界面、依赖或存储。先静态核实Item.list_face、Person.add_face与Upload.Face链路，接完整本地编辑→用户保存→新脸编号→JPEG上传→明确身份回读；不把人工画框UI或单独add_face当完成。未知结果不重放、不按同名猜人物，真实NAS行为交用户验证。保留现有所有改动。


### 2026-09-29 图片内手工人脸编辑增量

macOS个人照片预览接入编辑人脸：加载原有框、鼠标绘制/拖动/缩放、键盘等价的居中新增与位置/尺寸滑块、归入既有或新人物、移除与撤销移除，点击保存前不写NAS。裁剪最长边256的JPEG，照片显示坐标归一化；调整既有框按新增框并完成缩略图后移除旧标记，原图保留。读取Item.list_face v6；新增Person.add_face v3返回临时编号到face_id映射；Upload.Face upload v1传multipart JPEG。归属纠正和移除沿separate/delete_face。不新增猜测API。

共享契约增量为FaceBounds/FaceRegion/NewFace/FaceChange、photoFaces读取（旧服务默认显式不支持）、manualFaces能力及editPhotoFaces命令；结果仍复用photos/completedCount。macOS与共享Apple Repository实现个人空间；iOS/iPadOS共享声明但无新UI且未构建；Windows/Android仅记录待迁移，不改代码。没有存储、依赖或工具链变更。回滚可移除入口和增量声明/方法，不回退已保存NAS状态；原图无变化，人物标记可在网页恢复。

权限、照片身份、原始人脸/目标人物快照和唯一操作编号保留；新增编号不能与旧脸冲突或错配裁剪图。未知新增回执不按同名追认，丢失上传回执只接受明确新编号下完全一致的图像，否则保留待核对且不重传。部分回执只上传明确返回项；缺新增项时不移除旧框。编辑完成局部更新照片详情，月份/选择/预览保留。真实NAS为PENDING_USER_VALIDATION，功能按实际权限/能力开放，无待实测人工禁用；版本证据仍static。

### 图片内人脸编辑本地验证与独立复核

实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|MacAppearanceTests|DsmLocalizationTests'`，退出码0：257项XCTest（163 Repository、67 Model、27外观）与6项本地化通过。新增11项Repository测试覆盖读取坐标、明确的新脸编号与JPEG对应、修改归属/移除、先新增后替换、缺失/冲突/部分回执、上传断网只核对不重传、最终坐标/归属不符、旧接口和过期快照、目录权限及无效坐标拒绝。新增裁剪测试验证256像素上限、上下方向、正反拖动/边界及变更计算；Model验证保存后月份、选择和预览保持，未重新拉取照片或删除原图。

实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test人脸编辑居中新增填写姓名回车保存含裁剪图|WorkspacePresentationTests/test图片内人脸编辑中英浅深色正常空错误布局不提前写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-manual-faces-ui`，退出码0、2项通过。覆盖中英文/浅深色/正常、空内容、错误共12种布局，以及原生窗口点击居中新增、输入姓名、回车保存且只提交一次完整JPEG；保存前无写入。查看合成截图确认标题、图像区域、归属与位置/尺寸控件、底栏布局。编辑器无搜索筛选，筛选空状态不适用；加载分支占满内容区。

验证过程保留限制：扩展为模拟鼠标拖动的检查曾失败（拖动后没有生成姓名字段）。独立最小Color+DragGesture视图在相同测试宿主中，无论NSWindow.sendEvent还是直接NSHostingView鼠标方法，均没有收到onChanged；增加事件间隔/位移字段也未解决，原生界面工具不能选中xctest进程。没有据此宣称实际画框通过，也没有替换正常SwiftUI手势来迎合宿主；移除本轮无效的模拟拖动扩展和一次性探针，保留既有居中保存断言及坐标回归。实际绘制、拖动、右下角缩放列为PENDING_USER_VALIDATION，功能正常开放。首次编译曾修正JSON枚举名称；早期测试修正旧能力fixture及误把multipart解码为JSON的测试辅助逻辑，最终结果以上述命令为准。

独立只读复核：编辑表单关闭不提交；保存快照提交前检查实际管理权限、照片及原始人脸/目标人物身份；同操作编号不重复写；收到明确新脸编号才上传裁剪，编号不得重用旧脸或与其他项重复；新增/上传未完成不移除旧标记；部分成功局部回读，未知不重复创建或上传；异步回读检查授权代次，缩略图裁剪仅在内存处理，无真实图片临时文件。移除标记不调用照片删除接口。没有新增权限、依赖、签名或持久化格式，其他平台仅同步契约影响，未运行其构建。

`python3 tools/localization/check_localization.py`通过（Apple4416、Android2188、Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组、31引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

PENDING_USER_VALIDATION：在有管理权限的个人空间，用可测试照片打开预览→编辑人脸，绘制/移动/缩放框并归入新人物或既有人物后保存；重新打开与网页核对位置、姓名、头像及原图仍在。再测试移除和取消、已有框替换，以及在历史月份保存后仍停留原位置。Agent未向真实NAS写入，静态接口证据未升级为实机兼容结论。若失败，回传测试包版本、操作步骤、界面提示及是否部分成功，不附真实照片、凭据或NAS地址。

### 图片内人脸编辑测试包与后续范围

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/manual-faces-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-manual-faces-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时xcodebuild启动器复用apple/.build依赖缓存和skipPackageUpdates，与上轮工具链一致。输出 `apple/Apps/DsmMac/dist/photos-manual-faces-20260929/LanStash-1.0.11-arm64.dmg`，约18MB、arm64、版本1.0.11(21)。Release构建、严格签名、测试权限、Sparkle实际加载和DMG VALID通过；独立 `codesign --verify --deep --strict` 和 `file` 复核通过。临时签名，不含Finder本地磁盘挂载扩展，未安装、启动、公开发布或覆盖旧包。

本轮同时补充下一切片的官方静态证据：预览重建的NAS参数、匹配完成事件和失败恢复参数已记录，事件传输与客户端转换完整流程仍未实现。剩余功能保持：照片/视频预览重建；共享分类/人物/相册来源/共享条件源及跨个人共享空间移动；共享收集目录默认选择；上传跨会话/重启恢复（持久化变更授权待答复）。这些是实现待办；本轮图片内编辑的真实鼠标和NAS验收另列PENDING_USER_VALIDATION，不作为人工禁用开关。完整目标仍进行中。

工作区仍为main@5684170及27个已修改文件，没有提交、推送或PR；已有改动全部保留。本轮一次性日志、合成截图、探针、打包启动器与专用构建目录在记录证据后移至废纸篓，保留测试包、依赖缓存及Mac mini持续防休眠服务。

### 预览重建波次基线

上一轮图片内编辑完成源码、合成验证和独立测试包，属于有效进展；真实拖动与NAS验收后置。当前从main@5684170及27个已有修改文件继续，仅当前任务修改Photos契约/Repository、macOS照片管理、双语资源、测试与相关文档。预览重建已有静态证据只覆盖队列标记、NAS发起和部分事件字段；本轮先补齐完成通知的传输及转换文件链路，不能以成功接收请求代替重建完成。个人/共享空间都沿实际权限与明确照片身份，复用现有确认、操作编号、结果核对；无真实NAS写入，未实测不人工关闭入口。不改其他端UI或存储格式，不新增依赖。


### 2026-09-29 预览重建NAS分支增量

共享契约新增previewRegeneration能力与regeneratePreviews照片快照命令，结果沿用photos/completedCount。macOS个人/共享空间选择照片后确认，依实际目录管理权限执行；Network先订阅EIO4完成事件，再标记并发起NAS重建，按明确照片编号确认结果并回读身份。明确失败才恢复对应重建标记，未知不重放；部分成功局部更新，保留月份/选择并重新读取已打开的预览。无待实测人工白名单。

macOS及共享Apple网络实现本轮NAS分支；iOS/iPadOS共享新增枚举，无新UI且未构建；Windows/Android记录命令、权限与通知生命周期迁移影响，未改代码。无依赖、持久化、签名或工具链变更；回滚移除新增入口/命令/事件通道即可，不自动撤销NAS已完成的预览。Socket.IO使用官方查询令牌机制，完整URL和含URL的底层错误不得进入日志；证书、同源重定向规则沿用现有实现。

完整网页对齐尚未完成：本机图像/视频转换及ConvertedFile上传、通知中断后完整恢复仍待实现。NAS实际转换、反向代理路径及照片/视频格式覆盖为PENDING_USER_VALIDATION，需用户用测试照片/视频确认成功、失败和断线行为及原件/月份保留；失败回传脱敏步骤与提示，不包含真实内容或连接资料。精确测试命令和结果见MACOS_PHOTOS_PARITY_20260929_ZH.md；静态脚本/合成测试不代表真实版本兼容。


### 预览重建NAS分支验证与复核

实际命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosPreviewEventsTests|SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmChatRealtimeClientTests|DsmTransportSecurityTests|DsmCertificateTrustTests|DsmLocalizationTests'` 退出码0：270项XCTest及6项本地化通过。新增13项事件测试覆盖应用目录路径、EIO4握手、JSON类型与身份、订阅顺序、心跳、其他照片通知、明确失败、超时、断线、取消、并发等待及超大消息；新增8项Repository测试覆盖个人/共享路由、权限和缺能力、队列身份、未知不重发、失败恢复、批量部分成功与完成后身份变化。新增Model测试确认月份/选择保留、当前预览重新读取。早期全能力断言因fixture未声明新RegeneratePreview接口出现2项失败，补充合成能力后保留原断言通过。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test预览重建中英浅深色确认只提交打开表单时的选择' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-preview-regeneration-ui`退出码0、1项通过，覆盖中英文浅深色四种确认窗口，打开表单不写入，改变界面选择后回车仍只提交表单原目标；月份保留。查看合成深色中文截图，标题/说明/操作位置正确。表单复用现有加载/错误区，无搜索筛选，无选择时菜单不能发起操作。

独立只读集成与对抗复核：新事件文件由现有Swift Package纳入，无新依赖/工程生成变更；沿既有证书信任和同源重定向策略，握手凭据不输出，普通底层错误归为无URL的内部类型。先订阅再写，成功接收HTTP请求不能触发完成；操作编号去重覆盖重建和恢复，未知结果不清理、不重放；只有匹配通知并回读原身份后更新照片，授权代次改变不能沿用旧回执。失败恢复不会调用原件删除，取消表单不发起写入。其他平台只同步已授权契约影响，无界面或构建声明。

本地化/硬编码扫描通过（Apple4419、Android2188、Windows3402）；fixture及私有API引用校验通过（3组、31引用）；文档严格检查与git diff --check通过。真实NAS转换、通知握手/断线、不同代理目录及格式覆盖未验证；本地合成只证明实现按已记录静态结构工作。事件丢失目前保留未知结果，只回读不重放，完整恢复仍列待办，不宣称完整预览重建已经对齐。

PENDING_USER_VALIDATION：使用有管理权限的个人/共享空间测试照片与短视频，选择后执行重新生成预览；确认成功后预览可打开，原件仍在、历史月份和选择保留，再测试少量批量和失败提示。若连接失败，请回传应用版本、连接方式类别及界面提示；不要回传含SynoToken的链接、原始网络日志或真实媒体。Agent本轮没有向NAS发起重建、恢复标记或转换上传。

### 预览重建NAS分支测试包交付

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/preview-regeneration-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-regeneration-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0。临时xcodebuild启动器仅复用apple/.build依赖缓存及skipPackageUpdates，未改变工具链。输出 `apple/Apps/DsmMac/dist/photos-preview-regeneration-20260929/LanStash-1.0.11-arm64.dmg`，约18MB、arm64、版本1.0.11(21)。Release构建、严格签名、Hardened Runtime测试权限、Sparkle实际加载及DMG校验通过；额外执行 `codesign --verify --deep --strict`、`file`、`hdiutil verify` 通过。

测试包包含前轮照片预览双指捏合：AppKit magnify增量连续跟手，范围25%—500%，缩放时保留并约束平移，滚轮和按钮仍可使用，事件只在当前窗口预览区域消费。源码与对应合成事件测试再次只读核对一致，物理触控板手感仍为PENDING_USER_VALIDATION，不设置待实测禁用。测试包为本机临时签名，不含Finder本地磁盘挂载扩展；未安装、启动、覆盖旧包或公开发布。

当前工作区main@5684170，27个已修改文件及2个新增事件实现/测试文件，未提交、推送或创建PR，保留全部既有改动。本轮日志、合成截图、临时启动器和专用构建目录在记录后移至废纸篓，保留dist测试包、依赖缓存及持续防休眠服务。完整目标仍进行中：本机图像/视频转换与ConvertedFile上传、通知中断恢复、共享分类/人物/相册来源/条件源及跨空间移动、共享收集默认目录、上传跨会话/重启恢复（持久化变更授权待答复）尚未完成。


### 共享收集默认目录波次基线与实现

上一轮NAS预览重建完成构建和测试包交付，属于有效进展。本轮从main@5684170、27个修改及2个新增文件继续，保留所有改动；仅修改照片访问快照、macOS收集表单/Model、对应测试、双语资源和契约文档。核对既有官方静态记录后补齐默认目录：个人空间可用时优先使用；共享management可使用自动目录；共享entry必须选择既有可上传目录。从文件夹快捷发起及编辑已有请求仍保留明确目录，切换空间立即清除旧目录列表，避免旧空间目标被误选。

授权沿用户已同意共享契约扩展：SynologyPhotosAccess增量canManageSharedSpace，旧调用默认false；只反映已读取Photos设置，不推断DSM管理员权限。Model映射为目录选择行为，Repository原有目录上传权限与默认目录权限复查保留。无依赖、存储、工具链或签名变更；回滚移除字段和相关UI选择逻辑，不影响NAS已有收集记录。未因待实测关闭入口。预览中断恢复仍缺最终结果证据，不按队列消失确认成功；继续保留完整待办。


### 共享收集默认目录验证、复核与交付

实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|DsmLocalizationTests'`，退出码0，241项XCTest（172 Repository、69 Model）及6项本地化全部通过。新增共享默认路径创建与权限降级拒绝测试，扩展访问快照断言覆盖共享启用/禁用和management/entry/none/unknown；新增Model覆盖个人优先、仅共享两种权限、明确文件夹目标保留和模块关闭撤权。补齐多空间合成服务后最终重跑通过，未削弱既有断言。

实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享收集默认目录和成员选目录中英浅深色确认|WorkspacePresentationTests/test收集窗口回车新建相册后自动选中且不提前创建收集' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-request-destination-ui`，退出码0、2项通过。新检查覆盖中英浅深色各四种初始情形（共享管理、共享成员、明确文件夹、个人优先），共16种布局；打开无写入、成员未选目录回车无写入，点击进入Sample目录并选择后才按共享空间/目录9提交，管理者默认及明确目标确认正确。原有新建相册→选中新相册→创建收集流程回归通过。检查中文成员/英文管理者合成截图，默认开关、目录选择、底栏正确；目录展开时表单沿现有滚动区，加载/错误/空目录沿原分支，无目录筛选。

独立只读集成与写边界复核：公开访问字段默认false保持旧调用源码兼容，不改变持久化；仅明确Photos管理权限启用共享默认目录；提交仍由Repository重新核对空间、路径和真实上传权限；从文件夹发起及编辑不改默认目标；切换空间清空目录列表，不沿用上一空间编号；无自动创建目录请求、无新NAS调用。原有确认、唯一操作编号与精确结果回读保留。未改其他平台界面或宣称其构建通过。

本地化/硬编码检查通过（Apple4420、Android2188、Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过（3组、31引用），`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。官方脚本补证仅只读，记录于photos-advanced-management.md及环境快照；真实NAS等级不提升。

实际打包命令 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/request-destination-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-request-destination-20260929" bash apple/Apps/DsmMac/package.sh`，退出码0；临时xcodebuild启动器仅复用apple/.build与skipPackageUpdates。产物 `apple/Apps/DsmMac/dist/photos-request-destination-20260929/LanStash-1.0.11-arm64.dmg`约18MB，arm64、1.0.11(21)。Release、严格签名、临时权限、Sparkle实际加载、DMG校验通过；额外codesign --verify --deep --strict及file通过。本机临时签名，无Finder本地磁盘挂载扩展；没有安装、启动、覆盖旧包或公开发布。

PENDING_USER_VALIDATION：个人和共享均可用时新建收集应默认个人；仅共享management时默认路径随标题生成；entry应先选择有上传权限的文件夹，确认创建后链接和目的目录正确；编辑标题不改原目录，切换空间不会残留旧目录。请回传脱敏操作步骤、权限类别、界面提示和是否已创建；无需真实照片或连接资料。功能已按实际权限开放，没有待实测人工开关，Agent未进行真实NAS创建或上传。

工作区仍为main@5684170、27个修改及2个新增文件，无提交/推送/PR，所有既有改动保留。本轮临时日志、合成截图、工具启动器、专用构建目录移至废纸篓，保留新旧测试包、依赖缓存与防休眠服务。尚未完成：本机图片/视频预览转换及ConvertedFile上传、预览通知中断/恢复队列，共享分类/人物/相册来源/共享条件源和跨空间移动，上传跨会话/重启恢复（持久化变更授权待答复）。这些是源码待办，不与已开发功能的真实NAS待验混淆，完整目标继续进行。


### 本机预览生成波次基线

上一轮共享收集默认目录已完成实现/验证/测试包，属于有效进展。从main@5684170及既有29个工作区变更继续，当前任务独占Photos Network预览转换/Repository、聚焦测试和契约记录，不改其他端UI或持久化。沿官方静态need_thumbnail=true/need_video=false，接入ImageIO图片方向/比例与AVFoundation视频取帧，生成短边至多1280/240/320、质量0.9的JPEG；复用原件下载与ConvertedFile.upload v3。PNG优先本机，NAS明确失败才尝试其他格式本机转换；未知写回执不重放，不上传原件，不以缩略图上传代替完整视频编码。新内部API扩展沿已有用户授权，无新依赖/存储/工具链。


### 本机预览生成验证与独立复核

实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|SynologyPhotosModelTests|DsmLocalizationTests'`，退出码0：268项XCTest（181 Repository、69 Model、13事件、5转换）及6项本地化通过。新增9项Repository测试覆盖个人/共享multipart路由与三档有效JPEG、只上传预览而非完整视频、操作去重、NAS失败转本机、事件通道不可用、本机明确失败转NAS、两种均失败只恢复一次、上传丢失/矛盾/畸形回执不重传、转换期间身份变化在写前拒绝、上传后身份变化不确认及无效图片回退。新增5项转换测试覆盖1280/240/320短边与比例、小图不放大、EXIF旋转、未知内容、取消、真实本地合成短视频编码/旋转取帧及原件字节不变。

验证期间修正取消测试对XCTest实例的并发捕获及编译器Self隔离诊断，改为明确Sendable独立任务调用静态帮助函数；没有删除取消断言。首轮集成5项失败来自新测试把无body的GET下载当POST表单解码，增加只适用于新预览测试的查询参数读取后全部通过，没有改变原网络行为或既有断言。表单和用户文案未改，本轮未重复界面截图测试；此前已通过的确认窗口测试仍保留，未用其代替真实NAS验收。

独立只读集成与写边界复核：转换器为共享Apple Package自动纳入，未改工程生成文件；系统框架无新增第三方依赖。随机私有目录保存临时原件，转换结束/失败清除；原件下载复用既有大小与类型核对。耗时转换后重新读取照片身份和目录管理权限，授权代次变化停止；上传固定字段名/文件名，会话只在头中。生成过程中未写原件、未发送film_h264；唯一操作编号下未知上传不会自动改发NAS或清理队列，明确失败才回退/恢复。完成后仍按原身份回读并局部更新月份/选择/当前预览。只读检查没有发现需要放宽权限或重放未知请求的理由；完整断线队列恢复仍待实现。

`python3 tools/localization/check_localization.py`通过（Apple4420、Android2188、Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过（3组、31引用），`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。本轮无真实NAS重建/上传，只读脚本补齐共享分类/人物的下一步证据；静态版本未知项不提升，其他端未构建。

### 本机预览生成测试包与待办

实际打包命令 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/local-preview-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-local-preview-20260929" bash apple/Apps/DsmMac/package.sh`退出码0，临时xcodebuild启动器复用apple/.build与skipPackageUpdates。输出 `apple/Apps/DsmMac/dist/photos-local-preview-20260929/LanStash-1.0.11-arm64.dmg`，arm64、1.0.11(21)、本地临时签名。Release、严格签名、测试权限、Sparkle实际加载、DMG VALID通过；额外codesign --verify --deep --strict及file通过。未安装、启动或覆盖旧包，无Finder本地磁盘挂载扩展，也未正式发布。

PENDING_USER_VALIDATION：用测试PNG、带方向JPEG和短视频执行重新生成预览，确认不同尺寸及方向、原件仍在、历史月份/选择保留；分别验证个人/共享有管理权限目标，网络失败不重复上传。具体NAS格式、图片处理、视频编码支持和转换上传回读仍需用户验收；失败请只回传版本、格式、步骤、提示和是否部分完成，不含真实媒体/地址/凭据。功能无待实测禁用开关。

工作区main@5684170、27个修改及4个新增源码/测试文件，未提交、推送或PR，保留全部既有改动。本轮临时日志/启动器/专用构建目录在记录后移至废纸篓，保留测试包、依赖缓存及持续防休眠服务。下一步仍需补齐预览中断/队列恢复、共享分类与人物及相册来源/条件源、跨个人共享空间移动、上传跨会话/重启恢复（持久化授权待答复）。共享Category是统一入口且人物等有独立空间路由，已记录官方权限/来源证据，不能猜测不存在于版本表的FotoTeam.Album或Category端点。完整目标继续进行。


## 共享分类浏览波次（2026-09-29，已交付测试包）

基线为main@5684170及27个已修改文件、4个新增源码/测试文件；保留本机预览、人脸、收集、捏合等已有工作。本波次单独修改Photos共享领域集合来源、分类读取、macOS分类导航及其聚焦测试。用户已授权增量契约；其他平台界面、上传持久化、人物写操作和相册共享来源不在本切片改动范围，仍属于完整对齐待办。

官方静态证据见photos-library-read.md的“共享分类与来源补充静态证据”：统一Foto.Category入口，FotoTeam.Person/Concept/Geocoding/GeneralTag及Timeline/Item；共享全局分类按management权限，人物/主题按套件设置。集合和缩略图缓存必须携带空间，禁止个人与共享同编号相互替代。新增服务重载保持旧个人调用兼容；尚未适配的平台显式不支持共享读取。当前验证等级仍static，合成测试与目标构建结果在完成后追加，真实NAS由用户验收。

### 共享分类实现与验证

- 核心/Repository：新增空间读取重载和集合space；分类封面及人物缩略图类型按空间隔离，Folder读取/创建结果也保留来源；共享仅从已授权空间、统一Category和实际可用的FotoTeam读取，不新增假设的共享相册接口。
- macOS：相册页支持选择个人/共享空间；分类、照片、返回和分页保持空间，拒绝混入其他来源卡片；权限撤回清理分类与筛选，entry权限提供文件夹入口；分类读取失败移除旧入口并允许刷新恢复。
- 首轮250项回归出现2项失败：旧Model断言要求相册页切回个人，已按本轮交互改为保持共享；尝试对全部category照片查询加management限制会影响既有entry读取，已撤销该扩大限制，保留原断言。全局分类列表的实际权限检查不变。
- 最终命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，305项XCTest（186Repository、74Model、5转换、13事件、27外观）及6项Swift Testing本地化全部通过。新增5Repository+5Model覆盖统一入口与版本/设置、关闭个人空间、同编号封面路由、分页/日期、授权刷新、导航/权限撤回、迟到分页丢弃、错误恢复和错源列表拒绝。
- UI命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享分类中英浅深色正常空错误与权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-shared-category-ui`退出0，1项、20个中英文浅深色场景通过；人工查看合成人物深色与entry英文浅色截图，无真实NAS读取或写入。此测试验证布局与Model状态，不声称物理输入或实际NAS封面通过。
- `python3 tools/localization/check_localization.py`通过（Apple4421/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组、31项引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

独立集成/只读对抗复核：检查所有分类读调用有空间参数、旧个人方法默认兼容、无共享到个人fallback；共享列表/缩略图/日期身份一致，缓存清理不跨空间误删，切换后的晚到响应不进入当前列表，封面task identity包含来源且开始时清旧图。全局分类权限未扩大到现有entry照片读取；本轮不改变写操作确认、权限、去重或结果核对。共享人物管理仍未接入，不能误启用个人命名空间的写按钮。五端计划与兼容记录同步，静态证据等级不冒充NAS验收。

PENDING_USER_VALIDATION：管理共享空间的账号打开相册→共享空间，分别进入人物/主题/地点/标签及最近添加/视频，浏览照片并返回，确认仍在共享空间；个人/共享存在同编号时封面不能混用；切换空间过程中等待分页返回，确认无混入。仅有共享目录访问权限的账号应能通过文件夹浏览已授权照片，不能出现全局人物列表；撤回管理权限后刷新应清理旧分类。实际权限、类别可用性和NAS照片/缩略图格式仍由用户验收，失败只回传版本、权限类别、步骤与提示，不含真实图片、路径、主机或凭据。实现没有待实测开关。

剩余范围审计补充：当前SynologyPhotoCategory仅六类，分类首页卡片仍使用图标/标题；本轮完成的是共享六类内容浏览与来源隔离，不包含网页首页的照片预览拼图。官方脚本静态记录另含SimilarItem与enable_similar，当前NAS实际入口及完整读取/写语义尚未核实，不得据“六类通过”宣称全部分类完成。后续继续共享人物写管理、共享相册/条件来源、跨空间移动、预览中断恢复和上传重启恢复，并补齐分类卡片预览与相似项目证据/实现。

### 共享分类测试包交付

打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/shared-categories-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-categories-20260929" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器仅复用既有apple/.build缓存并跳过包更新，不变更工具链。产物`apple/Apps/DsmMac/dist/photos-shared-categories-20260929/LanStash-1.0.11-arm64.dmg`约18MB，1.0.11(21)、arm64、本机临时签名；Release构建、签名/权限、Sparkle实际加载、架构及DMG VALID全部通过，独立codesign --verify --deep --strict与file复核通过。保留此前所有照片改动，未安装、启动、覆盖旧包或公开发布，不含Finder本地磁盘挂载扩展。

工作区main@5684170仍为27个已修改文件及4个新增源码/测试文件，未提交、推送或创建PR。本轮临时日志、合成截图、工具启动器与专用构建目录在记录后移至废纸篓，保留测试包、依赖缓存和持续防休眠服务。完整对齐目标仍进行中，下一切片为共享人物写管理；其后继续共享相册/条件来源、跨空间移动、预览中断/队列恢复、上传重启恢复，以及上述分类首页预览与相似项目审计。


## 共享人物管理波次（2026-09-29，已交付测试包）

从共享分类交付后的main@5684170及27个修改、4个新增文件继续；上一波次属于实际实现进展，不重做已通过的分类工作。本波次独占Photos管理命令来源、人物读取/写入/回读、macOS人物表单和相关测试。依据photos-advanced-management.md官方静态FotoTeam.Person/Item/Upload.Face证据复用现有改名、合并、显示隐藏、整理人脸、封面和图片内手工人脸流程；用户已授权契约增量及实际权限开放，无新默认禁用。

人物集合已有space，本波次据此固定命令来源；照片目标依照片ID携带空间。共享人物操作须实际共享管理权限及人物启用设置，列表、人物/人脸封面缓存、目标人物选择器和最终状态复查均保持同一空间；混合个人/共享目标在写入前拒绝。个人旧调用继续兼容，其他平台只同步影响，不改UI、存储或工具链；真实NAS写验收仍交给用户。

### 共享人物实现与验证

共享人物的改名、合并、批量显示隐藏、移出人脸、分离到既有或新人物、人物封面，以及图片内新增/调整/纠正/移除人脸和JPEG裁剪上传均接入。管理命令的space从人物集合或照片身份读取；表单中的候选人物、隐藏人物及编辑器补充人物保持打开时的来源。结果只更新对应空间的卡片/筛选和照片，不混用同编号个人结果。普通个人调用和既有缩略图逻辑保留。

- 最终命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0；318项XCTest（196Repository、77Model、5转换、13事件、27外观）与6项Swift Testing本地化全部通过。新增10Repository与3Model；原有上传丢回执测试额外覆盖个人/共享两空间及精确/不匹配两种JPEG结果，不降低原断言。
- 新测试覆盖实际共享权限/设置/缺接口、改名断网后回读与去重、批量隐藏部分成功、合并照片并集、移出与封面、分离到新人物、手工人脸新增/上传/纠正/移除、同编号人脸封面隔离、跨空间混选拒绝；Model覆盖原位更新、历史月份与原图保留、共享结果不覆盖个人卡片。
- UI命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享人物管理表单中英浅深色沿共享读取且不提前写入|WorkspacePresentationTests/test共享人物显示窗口回车只提交共享目标|WorkspacePresentationTests/test人脸编辑居中新增填写姓名回车保存含裁剪图' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-shared-people-ui`退出0，3项通过；包含6种表单×2语言×2主题共24布局、共享人物显示的原生回车确认，以及个人/共享两个图片编辑器原生点击新增、填写姓名、回车保存与JPEG裁剪检查。修正布局fixture只给人脸相关表单传照片选择后，单独重跑第一项24布局通过。实际查看合并表单深色和共享编辑器截图；不将合成点击/回车描述为物理鼠标拖动或真实NAS写验收。
- 本地化检查通过（Apple4421/Android2188/Windows3402）；fixture/私有文档引用检查通过（3组/31项）；严格文档检查与git diff --check通过。没有新增用户文案，沿用已有中英资源。

独立集成与只读对抗复核：确认Person写调用、合并前照片/目录检查、写后Person/Item回读、Upload.Face及丢回执图像回查全部使用固定空间；混合人物/照片/脸在写前拒绝。人脸授权缓存按space/id隔离，权限刷新清空；合并的长预检保留授权代次，防止混合前后两次权限读取。未知操作仍保留唯一编号、不重放，批量部分结果不伪装全部完成；移除人脸不调用原件删除API。具体源范围为共享Core/Repository、macOS Model/View/Panel及测试；其他平台仅同步契约影响，无存储格式、依赖、签名或工具链变更。

PENDING_USER_VALIDATION：在有共享空间管理权限且启用人物的账号上，用专用测试照片执行人物改名、合并、隐藏/恢复、移出/归入其他人物、设封面，以及预览内新增/调整/纠正/删除人脸框。预期名称/成员/封面更新，原照片仍在，当前月份和空间不跳走；断网后自动核对，不重复创建或上传。另确认entry账号不出现管理权限、关闭人物设置或缺API时不误开放对应操作。失败回传版本、权限类别、步骤、提示与是否部分完成即可，不提供真实照片/路径/主机/凭据。真实写入和物理拖动仍由用户验收，无待实测禁用开关。

### 共享人物测试包交付

打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/shared-people-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-people-20260929" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只复用apple/.build依赖缓存并跳过包更新，不改变工具链。最终产物`apple/Apps/DsmMac/dist/photos-shared-people-20260929/LanStash-1.0.11-arm64.dmg`约18MB，版本1.0.11(21)、arm64、本机临时签名；Release、严格签名、权限、Sparkle实际加载、架构和DMG VALID通过，独立codesign --verify --deep --strict及file复核通过。没有安装、启动、覆盖旧包或公开发布，不含Finder本地磁盘挂载扩展。

工作区main@5684170保持27个修改文件、4个新增源码/测试文件；未提交、推送或PR，保留全部既有改动。本轮临时日志/合成截图/启动器及专用构建目录在记录后移至废纸篓，保留测试包、缓存和持续防休眠服务。剩余：共享照片作为普通/条件相册来源、跨空间移动、预览中断/队列恢复、上传跨重启恢复（持久化授权待答复）、分类首页拼图及相似项目入口/契约核对。下一切片为共享相册/条件来源，整体网页对齐目标保持进行中。

### 触控板捏合交付复核（2026-09-29）

用户再次确认照片预览双指缩放需求。现有FittedImagePreview已接入magnify，本次检查保留实现，没有重复添加另一套手势。重新运行 `swift test --package-path apple --skip-update --jobs 4 --filter MacAppearanceTests`，27项全部通过，包含连续正负捏合、滚轮以及其他窗口/区域的事件隔离。`python3 tools/localization/check_localization.py`和`git diff --check`通过。最新共享人物测试包的 `codesign --verify --deep --strict` 复核通过；该包已包含捏合支持，本次没有重新打包或正式发布。

PENDING_USER_VALIDATION：使用photos-shared-people-20260929目录中的测试包，在静态照片预览区域双指张开放大、合拢缩小，放大并拖动后再次捏合，检查位置连续、缩放限制和滚轮可用；关闭预览后其他窗口操作正常。物理触控板手感尚未实测，由用户验收；功能已开放。测试包不包含Finder本地磁盘挂载扩展。

## 相册照片来源波次（2026-09-29，已交付测试包）

本轮继续main工作区的既有改动，独占条件相册领域来源、建议/数量/条件回读、macOS编辑表单及相关测试。官方静态证据确认统一Foto.ConditionAlbum v3，个人user_id为当前用户、共享为0；来源选项为开启个人空间或具有共享management权限。先完成共享条件的新建/编辑/建议/数量/确认，普通相册共享成员与相册混合来源浏览仍需独立补齐，不以管理表单代替完整浏览对齐。无新增依赖、持久化、工具链或真实NAS写入。契约增量沿用用户授权，五端影响同步。

### 相册照片来源实现与验证

本波次在共享条件表单之外接通普通相册来源闭环：创建/加入/移出/封面保持统一Foto接口，源照片分别按空间预检；混合来源统一编号冲突在写前拒绝，成员按完整来源身份回读。相册列表不再限定个人入口，关闭个人空间仍可创建空相册、查看统一列表和封面。相册内owner_user_id必须存在且非负，0为共享；缺失来源拒绝读取，不把未知照片当个人原件。源空间仍需实际访问权限，非所有者相册仍拒绝写入；协作权限在后续波次完成。共享目录访问成员可查看自己有权访问的相册，不因没有全局分类管理权而整页禁止；全局分类仍严格检查management，撤权清旧分类。

条件相册提供个人/共享来源选择、各来源独立草稿、对应目录/建议、数量预览、新建/修改/回读。来源依官方user_id编码，任意其他用户编号拒绝，共享来源需management；切换时不会混用同编号规则。照片选择的管理表单从选中照片固定来源，既有共享上传队列现在可以上传成功后加入普通相册；不重复上传。新文案“照片来源”提供中英资源，没有待实测禁用开关。

- 最终单测命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，331项XCTest（206Repository、80Model、5转换、13事件、27外观）及6项Swift Testing本地化全部通过。新增10Repository与3Model，覆盖共享条件创建/编辑/建议/数量/权限、普通相册成员与封面、混合来源逐项预检、空相册、封面授权、来源缺失拒绝、共享上传后加入与Model原位来源保持。
- UI命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test条件相册来源中英浅深色切换并按来源读取|WorkspacePresentationTests/test条件相册表单创建编辑错误浅深色布局|WorkspacePresentationTests/test共享分类中英浅深色正常空错误与权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-condition-source-ui`退出0，3项共30布局通过。新增中英浅深色4组真实合成窗口菜单切换（共享→个人→共享），目录/建议读取均同源，切换不写入；回车只保存一次且完整恢复原共享规则。原6创建/编辑/错误布局及20共享分类正常/空/错误/权限布局回归通过。查看中文浅色和英文深色截图，无真实照片。
- 中间失败已明确修正：旧Model断言“共享不读相册”改为统一读取；旧Repository相册来源拒绝断言改为非所有者拒绝，并保留全部无写入断言。新上传fixture缺少共享albums能力导致未入队，补齐同本轮契约一致的fixture能力并避免失败后数组越界。来源Picker由SwiftUI绘制，改用实际菜单跟踪/点击而非不存在的NSPopUpButton；原编辑按钮允许保存未改规则，测试改为确认完整原规则仅提交一次，没有更改保存语义。整页权限门禁拆分时既有撤权回归发现旧分类残留，恢复针对分类的清理后原断言通过。
- 本地化完整性/硬编码扫描通过（Apple4422、Android2188、Windows3402）；fixture和私有文档引用检查通过（3组、31引用）；git diff --check通过。文档严格预检与最终包验证在交付段记录。

独立只读集成复核：按API路由逐项检查统一Album/NormalAlbum/ConditionAlbum与按来源的Item/Folder，未构造FotoTeam.Album；相册照片保留来源、单独详情/缩略图沿源空间；相册封面必须先按当前会话回读后带album_id，凭据只在头中。条件源与所有者均核对，耗时读取保留授权代次，未知写不重放、回执不足不按名称猜建。混合来源只扩展相册成员命令，其他批量编辑仍不跨空间；公开分享、NAS原件删除与存储格式未扩张。五端影响已同步，其他平台UI未改、未冒称构建通过。

PENDING_USER_VALIDATION：用专用测试照片验证共享来源新建/修改条件相册、切换来源后返回保留规则、建议与数量；选共享照片创建/加入普通相册、移出仍保留原件、设封面，个人与共享照片同处一个相册时预览/详情/下载各自正确；共享上传成功后加入目标相册且只上传一次。关闭个人空间时，管理共享的账号仍可查看/新建相册；仅共享目录访问账号不得看到全局人物或共享条件来源。断网不重放未知写入，刷新保留已确认结果。失败仅回传版本、权限类别、步骤、提示与是否部分完成，不含真实照片/路径/地址/凭据。实际NAS写入仍由用户验收。

### 相册来源测试包交付

打包命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/album-sources-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-sources-20260929" bash apple/Apps/DsmMac/package.sh`退出0。临时xcodebuild启动器仅复用apple/.build缓存并跳过包更新，不改变工具链。首包构建期间复核修正相册/分类权限分离与来源缺失处理，最终使用相同专用构建目录增量重打；最终Release、严格签名、测试权限、Sparkle实际library loaded、arm64及DMG VALID全部通过；另行codesign --verify --deep --strict和file复核通过。

产物`apple/Apps/DsmMac/dist/photos-album-sources-20260929/LanStash-1.0.11-arm64.dmg`，约18MB、1.0.11(21)、本地临时签名；包含本轮和此前所有照片修改，没有安装、启动、覆盖旧交付目录或正式发布，不含Finder本地磁盘挂载扩展。最后补充共享目录成员“能看自己的相册、不能读取全局分类”Model回归，331项XCTest及6项本地化全部通过；其后没有修改产品源码。严格文档预检及git diff --check通过。

工作区main@5684170，27个修改及4个新增源码/测试文件；未提交、推送或PR，保留既有工作。一次性日志、合成截图、临时启动器和本轮专用构建目录在记录后移至废纸篓；保留测试包、依赖缓存和持续防休眠服务。当前剩余五组：相册协作权限/上下文读取，跨空间移动与其他混合来源批量编辑，预览中断/队列恢复，上传跨会话/重启恢复（持久化授权待答复），分类拼图及相似项目。下一切片继续相册协作权限，整体网页对齐目标未完成。


## 相册上下文读取波次（2026-09-29）

前轮目标复核属于状态确认，本轮从已确认缺口推进源码。基线main@5684170与31个既有改动文件保留。本切片独占SynologyPhoto相册读取上下文、Repository相册内详情/缩略图/视频/原件读取、Model页面接收及聚焦回归；共享相册添加/上传角色随后接入，不以本切片冒称全部协作完成。无新增依赖、工具链或持久化变更；共享契约增量沿用用户授权，同步五端影响。

官方静态脚本再次确认Item.get和Unit.get携带album_id，缩略图携带相册编号，Download在相册场景转统一Foto路由。读取必须保留当前相册与原件owner；NAS按相册权限校验，不能在拒绝后降级到原件读取。原件写预检仍走来源权限；个人空间他人owner不得误当自己的照片写入。页面仅接受当前相册上下文，切页/重新授权的在途返回不可混入。验证计划覆盖无原空间权限、同编号不同相册、详情后继续预览/保存、Live Photo与视频、拒绝和授权刷新、源空间写入隔离；真实NAS由用户测试。


### 相册上下文实现与集成复核

核心照片模型增量albumContext，所有相册读取附album_id并使用统一Foto；来源owner仍保留，详情回读校验其一致。启用Photos的会话独立于个人/共享空间权限，没有原空间时相册/共享列表正常请求，但NAS拒绝不改用原件或无相册参数重试。Model只接收当前相册内容，无空间时保留相册导航、清理无效分类与筛选；缩略图任务键含完整上下文，切相册不复用旧请求。原件写入口仍走源空间预检，其他用户的个人照片不能借相册上下文执行删除/修改。

独立只读集成审查核对Item.list/get、Unit.get、缩略图、Streaming与Download路由及参数、身份、目录权限和异步返回。已增加相册列表/详情/视频/下载在权限重新核对后的代次检查，合成屏障证明在途列表和详情不能在Photos停用后返回；照片列表不能混入另一个相册或错误来源。失败不重放，原件导出保留随机中间文件、长度校验和不覆盖语义。没有NAS写入、公开分享或存储格式变更；协作角色入口后续完成。

验证：
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，341项XCTest（214Repository、82Model、5转换、13事件、27外观）及6项Swift Testing本地化全部通过。新增8Repository和2Model，覆盖上下文读取、原件导出、视频/实况、无空间列表、跨NAS、权限拒绝、owner变更、源写权限和在途撤权；旧相册详情测试改为保留来源身份但带album_id使用统一读取，未删除原鉴权断言。初次编译因新测试为既有无标签edit枚举写入参数标签失败，修正测试调用后全绿。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相册来源不可直接访问时中英浅深色浏览及错误布局|WorkspacePresentationTests/test共享分类中英浅深色正常空错误与权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-album-context-ui`退出0，2项共28布局通过，新增8个无源空间相册正常/错误布局，已有20分类回归；查看中文浅色正常和英文深色错误截图，标题/内容区域/错误恢复完整，图片为合成占位，未使用真实照片。
- `python3 tools/localization/check_localization.py`通过，Apple4422/Android2188/Windows3402；无本轮新增文案。`python3 tools/contract-validation/validate_fixtures.py`通过3组fixture及31文档引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

PENDING_USER_VALIDATION：用只有相册查看/下载权限的测试账号，分别浏览来自他人个人空间和共享空间的照片；核对详情、缩略图、普通视频与实况预览，允许下载时保存原件。个人/共享空间均未启用的Photos账号仍应能打开其有权相册；撤回分享后刷新应提示失败，不能绕回源空间继续读取，更不能凭查看权限删除他人原件。需要核对当前DSM/Photos版本与限制角色的真实响应；失败回传版本、权限类别、步骤、提示和是否可重现，不提供真实照片/相册链接/凭据。无待实测人工开关，角色按钮显示仍列代码待办。


### 相册上下文测试包交付

`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/album-context-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-context-20260929" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器仅附加-clonedSourcePackagesDirPath指向apple/.build与-skipPackageUpdates以复用依赖，未改工具链。源码在最终单测/UI检查及打包期间未再变更。Release、严格签名、测试权限、Sparkle实际library loaded、arm64及DMG VALID通过；file独立确认Mach-O arm64。本轮日志无编译警告，hdiutil仅输出命令弃用提示，不影响镜像校验。

产物`apple/Apps/DsmMac/dist/photos-album-context-20260929/LanStash-1.0.11-arm64.dmg`约18MB，1.0.11(21)、本地临时签名，包含本轮和此前照片修改。没有安装、启动、覆盖旧交付目录或正式发布；不包含Finder本地磁盘挂载扩展。主分支仍main@5684170，保留27个修改文件及4个新增源码/测试文件，未提交、推送或创建PR。临时日志、合成截图、xcodebuild启动器和本轮独立构建目录在记录后移至废纸篓，保留DMG/App、依赖缓存和持续防休眠服务。

当前剩余五组：相册协作角色/添加/上传及下载入口角色显示；跨空间移动和其他混合来源批量编辑；预览通知中断与未完成队列恢复；上传跨会话/重启恢复（持久化授权待答复）；分类拼图与相似项目入口/契约。下一切片基于本轮已记录的getPermission线索继续相册协作。整体目标保持进行中，不因本轮交付而宣称完整网页复刻完成。


## 相册协作权限波次（2026-09-29，进行中）

前轮已完成相册上下文源码、合成验证和独立测试包，属于有效进展。当前main与31个既有改动文件保留，本轮接入实际相册角色、贡献者添加/移除及相册上传队列；单一修改范围为Photos共享模型/Repository、macOS相册管理及对应测试。公开增量契约沿用户授权，持久化不变，其他端仅同步影响。官方静态脚本确认Sharing.Passphrase.get_permission v1(passphrase,exclude_public)返回permission.download/upload；相册贡献者可add_item，delete_item受provider_user_id匹配限制；Upload.Item.upload v1使用album_id或passphrase、folder=[PhotoLibrary]且无uploadDestination=timeline。只读静态发现，没有真实NAS写入。


### 相册协作实现与独立复核

新增SynologyPhotoAlbumAccess与服务albumAccess/addableAlbums、mutation.uploadToAlbum及albumContext.providerUserID，沿已授权共享契约增量，无持久化或工具链变化。权限读取区分当前用户、原件所有者、照片提供者；get_permission结果不进入日志或UI，分享口令只保留在实际请求参数。添加现有照片仍核对来源身份/目录访问，目标可为允许贡献的相册；移除贡献项通过带album_id的详情重新核对provider，不以他人原件管理权限取代相册成员权限。上传使用固定目标album_id/passphrase，确认后回读照片编号/大小/提供者，不额外add_item。

Model按角色更新下载、上传、移除，原件删除/人脸编辑仍按源权限；视频错误恢复不再显示无权限的下载操作。正常相册上传队列跨页面保留目标；没有原空间时直接相册上传不查源目录、不展示目录层级选项。合成权限刷新失败测试发现旧selectedAlbumAccess未清理，已在refresh开始清空并用回归覆盖，浏览不因角色读取失败被整体阻断。

独立只读集成/对抗复核检查：角色与来源身份分离、当前相册上下文及provider重新读取、所有者与贡献者参数、partial回读、共享来源view/download权限、上传文件快照、操作编号及mutationInFlight、二进制结果未知不重传、回读期间授权代次变化、队列切页目标。贡献者不能凭相册角色删除他人原件或移除别人贡献的照片；同operationID不会再次发送成员写入或文件上传。无原空间项目跨相册转加仍未接入，已保留在最新待办，不能把这一轮表述为全部相册协作完成。未向真实NAS写入。

验证命令与结果：
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests|SynologyPhotosRepositoryTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，354项XCTest（222Repository、87Model、5转换、13事件、27外观）及6项Swift Testing本地化全通过。本轮相对上包新增8Repository及5Model测试，包含角色矩阵、本人/他人提供、无空间直接上传、切页、未知回执、重复调用、部分失败及权限刷新。首次新增测试标签albumID误用为removeFromAlbum参数，按现有id标签修正；随后权限刷新测试暴露4个断言失败，修复产品状态清理后全部通过，未删除断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相册协作角色与直接上传表单中英浅深色布局|WorkspacePresentationTests/test相册来源不可直接访问时中英浅深色浏览及错误布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-album-collaboration-ui`退出0，两项24布局（新增12角色页面+4上传空确认，保留8读取正常/错误）通过。人工查看中文浅色贡献者页面及英文深色上传表单，标题/操作/内容与固定目标完整；截图为合成占位，未以空表单替代真实文件或上传验收。
- `python3 tools/localization/check_localization.py`通过，Apple4422/Android2188/Windows3402，双语、参数、引用和硬编码无问题。本轮没有新增用户文案。
- `python3 tools/contract-validation/validate_fixtures.py`通过3组fixture与31文档引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

PENDING_USER_VALIDATION：用查看/下载/贡献三个角色进入同一测试相册，检查下载和上传入口；贡献者上传两张可丢弃合成照片，上传期间切换相册，完成后原目标应只有一次上传的成员。贡献者仅可移除自己提供的照片，所有者可移除成员，均不应删除原件。撤回贡献权后刷新，不应继续显示旧上传权限；失败/部分完成应自动核对且不重复写入。需真实DSM/Photos、角色和provider字段响应，用户返回版本、角色类别、步骤、提示及是否部分成功，不返回真实照片、链接、NAS地址或凭据。功能按实际权限开放，不因待实测新增禁用开关。

### 相册协作测试包交付

`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/album-collaboration-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-collaboration-20260929" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器仅复用apple/.build依赖缓存与-skipPackageUpdates。最终功能/UI测试通过后产品源码未再更改。Release、严格签名、测试权限、Sparkle实际library loaded、arm64与DMG VALID通过；独立codesign --verify --deep --strict及file再次通过。构建无编译警告，hdiutil仅输出命令弃用提示。

产物`apple/Apps/DsmMac/dist/photos-album-collaboration-20260929/LanStash-1.0.11-arm64.dmg`，约18MB，版本1.0.11(21)、本机临时签名；包含此前照片预览捏合与本轮相册协作，没有安装、启动、覆盖旧包或正式发布。不含Finder本地磁盘挂载扩展。原有main@5684170和27个修改+4个新增源码/测试文件保留，无提交、推送或PR。本轮已完成进程的日志、UI截图、临时启动器及专用构建目录在取证后移至系统废纸篓，保留交付包、依赖缓存和防休眠服务。

完整目标仍进行中，当前余项：无原空间项目跨相册转加；跨空间移动及其他混合批量编辑；预览通知中断和未完成任务恢复；上传跨会话/重启恢复（持久化授权待答复）；分类拼图及相似项目入口/契约。下一步继续核对跨相册来源与目标参数，再推进跨空间搬移，不以相册协作主路径通过代替完整网页对齐。

## 相册间添加来源复核波次（2026-09-29，进行中）

前轮协作代码、354项XCTest/6本地化和独立测试包均完成，是有效进展；当前31个已有改动文件保留。本轮独占Repository相册成员来源预检、Model/View选择权限及其聚焦测试，沿已有create/add_item契约，不新增参数、依赖或持久化。

只读官方脚本确认：共享相册照片提供者在对应原空间启用时有ADD_TO_ALBUM；只有下载权限的非提供者仅有DOWNLOAD。原空间关闭时SPACE_DISABLE只含REMOVE_FROM_ALBUM，没有跨相册添加。混合来源提供者还要求两空间启用及共享管理权。添加提交仍为目标id或passphrase及item编号，不传来源相册字段；来源相册用于原生端读取和身份预检。因此前轮把“无原空间项目跨相册转加”列为网页缺口不准确，本轮按实际网页规则更正；要补齐的是原空间启用时本人贡献项目从相册转加到其他可添加目标，不能用owner_user_id代替provider_user_id。没有执行NAS写入，源脚本变量已删除并验证undefined，开发工具关闭；证据为static。

### 相册间添加实现、复核与验证

Repository对带来源albumContext的createAlbum/addToAlbum先确认原空间启用，再通过源相册详情核对完整身份快照和provider为当前用户；不要求修改他人原件目录，也不放宽通用requirePhoto原件写限制。混合来源相册项目按官方规则要求共享管理权。目标仍使用现有所有者id/贡献者passphrase，创建仍为name/item；回读目标相册核对成员，原相册不移除。Model/View按provider决定添加入口，原件owner属于别人不再误拒绝；下载角色及原件编辑入口各自判定，来源关闭不开放转加。

独立只读集成/对抗复核覆盖：跨NAS身份由details保留验证，owner变化由相册上下文拒绝，provider从即时详情读取而非相信UI快照；未知或拒绝不降级原空间读取；来源和目标编号不混用；只有照片成员操作进入新分支，删除/改原件保持旧权限校验；重复operationID回读而非重发。目标贡献角色仍在写前核对，没有新增人工验证白名单或持久化。

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，360项XCTest（226Repository、89Model、5转换、13事件、27外观）及6项Swift Testing本地化全部通过。本轮新增4Repository与2Model；覆盖本人provider/其他owner、原空间关闭、来源权限拒绝、provider/快照变化、个人/共享、混合管理权限、已有所有者/贡献目标与新建目标、重复提交和来源保留。首次与最终测试均无失败。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相册转加确认中英浅深色显示可添加目标且不提前写入|WorkspacePresentationTests/test相册协作角色与直接上传表单中英浅深色布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-album-transfer-ui`退出0，两项20布局通过（新增4转加确认、回归16角色/上传布局）。人工查看中文浅色及英文深色转加确认，两类目标、原相册和数量信息完整；打开表单仅请求addable列表，无写调用。没有据截图宣称真实提交或NAS行为验收。
- `python3 tools/localization/check_localization.py`通过，Apple4422/Android2188/Windows3402；无新增用户文案。`python3 tools/contract-validation/validate_fixtures.py`通过3组与31引用；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。

PENDING_USER_VALIDATION：原空间启用的测试账号打开自己贡献过照片的相册，选择本人提供的可测试照片，分别加入自己的已有相册、允许贡献的相册或新建相册；目标出现一次成员，来源保持，不能删除他人原件。再以非提供者或关闭原空间的账号检查操作栏，与官网一致不提供转加。混合个人/共享来源按共享管理权检查。真实NAS写请求和当前版本provider语义未由Agent实测；失败回传版本、角色、操作步骤及提示，不附真实数据或凭据。

### 相册间添加来源测试包交付

执行`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/album-transfer-20260929" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-transfer-20260929" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器仅复用apple/.build与-skipPackageUpdates。最终单测/UI通过之后产品源码保持不变。Release构建、严格签名、测试权限、Sparkle实际library loaded、arm64与DMG VALID均通过；独立codesign --verify --deep --strict和file再次通过。构建无编译警告，仅hdiutil弃用提示。

产物`apple/Apps/DsmMac/dist/photos-album-transfer-20260929/LanStash-1.0.11-arm64.dmg`约18MB，1.0.11(21)、本机临时签名，不含Finder本地磁盘挂载扩展。包含本轮和此前照片协作/捏合修改；没有安装、启动、覆盖旧包或正式发布。main@5684170和31个已有改动文件保留，没有提交、推送或PR。本轮日志、合成截图、临时启动器与专用构建目录在取证后移至废纸篓，保留交付包、依赖缓存和持续防休眠服务。

当前仍有四组代码待办：跨个人/共享空间移动与其他混合批量编辑；预览通知中断与未完成任务恢复；上传跨会话/重启恢复（持久化变更授权待答复）；分类拼图及相似项目入口/契约。原空间关闭不支持相册转加来自官方当前静态实现，已纠正此前误列待办；真实NAS验证依然后置给用户，不把它与代码缺口混为一谈。下一切片继续核对跨空间搬移的源/目标身份与后台结果，完整目标保持进行中。

## 跨空间移动与复制波次（进行中）

基线main@5684170，保留31个已有改动文件；上一回合仅复核捏合与旧包，没有推进剩余功能，本回合直接实施跨空间目标。当前任务独占Photos领域、Repository、Model/View/Panel及对应测试；五端文档同步影响，其他端界面、持久化、依赖与标识不变。

官方脚本静态观察确认：复制目标允许个人/共享；跨空间移动仅个人到共享。源空间决定BackgroundTask.File API，目标由target_folder_id选择；move的extra_info为JSON字符串，version:2、source_library:personal_space/shared_space。回执task_info包含id/total/target_folder(id,owner_user_id)；Info统一Foto。实现须固定双空间身份、实际目录权限、同空间同目录拒绝、任务去重和完成回读。证据为static，不代表真实NAS写入验证。

验证计划：三个跨空间方向、同编号跨空间目录、源/目标权限拒绝、错误目标回执、未知结果不重放、后台部分完成不移除全部源照片、月份位置保留；中英浅深色目标选择器和macOS构建。真实NAS结果由用户验收，不增加待实测禁用。

### 跨空间移动与复制实现及复核

领域默认目标保留同空间兼容；Repository固定源API，move额外发送JSON字符串source_library，目标要求upload/manage；共享源复制使用view/download。回执字段不完整只按任务编号查询list_user_task，目标id/owner/total一致后结合get_status完成状态确认，最终复核目标权限和授权代次。没有以已提交代替完成，重复operationID不重放。

macOS确认表单使用原生分段目标空间选择，切换后重载目标根目录、清理旧路径；源共享移动只提供共享目标，与网页一致。确认后局部移除完整完成的旧身份，保留月份；部分结果沿既有confirmed门禁保留原列表，不根据完成计数猜测具体项目。独立复核纠正了最初“部分完成会移除全部”的判断：原有结果处理已有confirmed门禁，本轮只是延伸跨空间移除条件并新增回归，不宣称修复不存在的旧缺陷。

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：367项XCTest（231Repository、91Model、5转换、13事件、27外观）及6项本地化全部通过。本轮新增5Repository、2Model；编译和测试均无失败。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test跨空间移动复制表单中英浅深色切换目标且不提前提交' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-cross-space-ui`退出0，1项16布局通过。实际操作原生分段控件，验证目录请求从个人切到共享、没有提前写入；人工查看中文浅色移动与英文深色复制截图，标题、空间、目录、同名策略和操作按钮完整。
- `python3 tools/localization/check_localization.py`通过：Apple4423/Android2188/Windows3402，双语/引用/硬编码无问题。`python3 tools/contract-validation/validate_fixtures.py`通过3组与31引用。

PENDING_USER_VALIDATION：使用可测试照片，在旧月份选择个人照片移动到共享目录，或双向复制；检查目标出现文件且原图按操作保留/移除，当前月份不跳回最新；重复同名文件应跳过，撤销目录上传权应拒绝。真实NAS写入及跨空间实际编号变化由用户验收；只回传角色、套件版本、步骤和提示，不附照片/凭据/主机。来自相册的跨空间移动目前局部移除旧身份，来源相册成员若随NAS迁移保留，其新身份需后续局部重新载入完善，已保留在代码待办，不能宣称全部搬移视图完全对齐。

### 跨空间移动与复制测试包交付（2026-09-30）

`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/cross-space-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-cross-space-20260930" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器仅复用apple/.build依赖缓存和skipPackageUpdates。产品源码在最终单测/UI通过到打包结束之间未修改。Release、严格签名、测试权限、Sparkle实际library loaded、arm64和DMG VALID全部通过；独立codesign --verify --deep --strict及file再核对通过。唯一打包警告为hdiutil弃用提示。

交付包：`apple/Apps/DsmMac/dist/photos-cross-space-20260930/LanStash-1.0.11-arm64.dmg`约18MB，1.0.11(21)、本机临时签名，不含Finder本地磁盘挂载扩展；未安装、启动、覆盖旧包或正式发布。原main@5684170及27修改+4新增源码测试文件保留，没有提交、推送或PR。已完成进程的本轮日志、合成截图、临时启动器及专用构建目录移至废纸篓，交付包、依赖缓存和防休眠服务保留。

复核后的下一步：先补移动后源相册的局部成员身份更新与混合来源操作，然后推进预览恢复。源码证据：PhotosPreviewEvents闭合断线通道后无重连，Repository inspectMutation只检查已记录regenerated/failed，无法补回丢失事件；uploadQueue仅内存数组；PhotoAlbumCover只有单张图，分类枚举无相似项目。剩余四组清单见页首，上传持久化授权仍待答复。完整目标继续进行，未标记完成。

## 混合来源编辑与搬移后相册更新波次（进行中，2026-09-30）

基线main@5684170，保留31个已有改动文件；前轮已完成跨空间移动复制并交付独立包，本轮继续代码缺口。独占Photos领域/Repository/Model/View与对应测试、双语新增键和五端记录，不修改其他端UI、上传持久化或工具链。

本轮重新只读官方react_bundle.js：相册混合来源菜单允许评级、拍摄时间、预览重建；编辑评级和时间按personalItemIds/teamItemIds分别调用Foto/FotoTeam；预览重建分别提交两空间任务。标签编辑发现混合来源直接返回；普通及共享相册菜单没有MOVE_TO/COPY_TO，故原待办“混合来源搬移”不应作为网页对齐缺口。既有客户端额外提供的移动功能保留，并修复其局部相册身份更新。混合编辑需要两空间启用和共享管理权限；每张照片仍独立核对原件权限。观察只读、无真实NAS写入、证据static，临时变量已删除确认undefined，DevTools关闭。

实施顺序：混合命令按实际来源分发、逐项结果核对和部分完成续作；跨空间移动后保持当前相册已加载范围并重新读取成员，取消/导航时不得覆盖其他页面；聚焦回归、双语UI、构建和独立包。真实NAS由用户测试，入口不加待实测禁用。


### 混合来源编辑实现、独立复核与验证

共享 mutation 的 supportsMixedPhotoSpaces 只覆盖评级、拍摄时间、相对日期和预览重建。Repository 在任何写入前核对全部空间能力、管理权限及原件身份，分来源派发；记录已提交/明确拒绝/部分失败来源，只有回读匹配目标值才计完成。断线保留未知并只读复查；部分完成续作只使用原快照剩余项，与当前选区无关。相对日期由原快照算绝对目标，不叠加偏移。预览重建复用每张照片所属空间的独立订阅与结果，来源相同数字编号不合并。

跨空间搬移完整完成后，如当前显示来源相册则只重读已加载窗口，再一次替换成员及分页状态；其他选择按新身份集合保留，不全量刷新或重新获取访问授权。三次短暂失败自动重试，最终失败保留画面并给出只读重试。导航/取消检查阻止旧读取覆盖新页。独立只读复核覆盖目标身份、每组提交前授权代次、结果回读代次、未知不重放及已完成项不再移动；没有放宽其他个人原件权限、标签或混合搬移。

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：377项XCTest（236Repository、96Model、5转换、13事件、27外观）及6项本地化全部通过；本波次新增5Repository、5Model。早期回归中原断网测试2个断言失败，原因是edit异常后过早检查改变既有pending-first语义；代码已恢复未知结果先pending，没有降低原断言。原“拒绝混合评级”负例按新需求改为“拒绝混合描述”，新增评级正例及两空间能力/权限负例。只有既有弱引用测试警告和skip-update弃用警告。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test混合来源编辑表单中英浅深色保留两空间目标且不提前提交|WorkspacePresentationTests/test相册移动后读取失败中英浅深色保持相册并可只读重试' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-mixed-photos-ui`退出0：2项、24布局（16混合表单、8相册错误/恢复）通过。查看中文浅色错误页与英文深色日期表单，标题/数量/控件/重试完整。初次测试误假定自定义SwiftUI按钮是NSButton而失败，改为绘制检查与同一Model重试动作；未声称合成测试点击了该按钮。相册恢复保留目标、只移动一次，混合表单打开不写入。

PENDING_USER_VALIDATION：在两空间启用且有共享管理权的账号，打开包含自己可修改的个人/共享照片相册，分别修改评级、指定日期、整体偏移日期及重建预览；核对两空间均变化且部分失败只继续剩余项目。选择单一来源照片移动到共享目录，当前相册应更新新身份并保留其他已加载照片/选择，短暂断线恢复不重复移动。错误回传测试包、操作步骤、角色和提示，不附真实照片、地址或凭据；Agent未执行真实NAS写入，static与合成验证不提升为实机兼容。

- `python3 tools/localization/check_localization.py`通过：Apple4424/Android2188/Windows3402，双语、参数、引用及硬编码扫描无问题。`python3 tools/contract-validation/validate_fixtures.py`通过3组fixture/31文档引用；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。

下一切片源码证据：SynologyPhotosPreviewEvents.completion断线后close，状态不再订阅；Repository inspectMutation只读取内存regenerated/regenerationFailed，不能恢复丢失完成通知。已有list_regenerating静态结构可用于恢复未完成任务，但条目消失不是完成证据。应先处理在途订阅与完成身份，再加入队列恢复，不重复已开始且未知的写入。uploadQueue仍是内存数组，PhotoAlbumCover仍单张图且SynologyPhotoCategory无相似项，故三组待办保留。


### 混合来源编辑测试包交付

`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/mixed-photos-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-mixed-20260930" bash apple/Apps/DsmMac/package.sh`退出0；临时启动器复用apple/.build与-skipPackageUpdates，没有更改工具链。Release构建、严格签名、专用测试权限、Sparkle实际library loaded、arm64和DMG VALID通过；独立`codesign --verify --deep --strict`及`file`复核通过。只有hdiutil弃用提示，没有编译失败。

产物`apple/Apps/DsmMac/dist/photos-mixed-20260930/LanStash-1.0.11-arm64.dmg`约18MB，版本1.0.11(21)，本机临时签名，包含此前捏合与本轮混合编辑/相册更新。不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或公开发布。工作区仍main@5684170、27修改+4未跟踪源码测试文件，原有修改保留，无提交/推送/PR。本波次临时日志、合成截图、启动器与专用构建中间目录取证后移至废纸篓，保留交付包、依赖缓存和防休眠服务。完整目标未完成，继续三组待办，不以实机后置为理由禁用已实现功能。


## 预览通知中断恢复波次（2026-09-30，进行中）

前轮混合来源交付为有效进展。基线main@5684170、31个已有改动文件，本轮独占PreviewEvents、Repository相关集成测试和必要契约/五端记录；不修改持久化、其他端界面、凭据或证书规则。已记录的Socket.IO订阅协议用于短暂断线重新连接，仅重发订阅、不重发NAS重建或转换上传；连接拒绝、证书失败、畸形帧、取消不得触发自动重连。完成仍要求匹配当前照片的明确事件和Repository详情回读。持续断线或错过事件继续保留未知，不能把队列消失视为完成。后续仍需list_regenerating恢复未完成任务与跨会话恢复入口，不缩减完整目标。


### 预览通知短暂断线恢复实现与验证

SynologyPhotosPreviewEvents复用原握手提取register，已订阅目标等待期间普通断线可用同一地址/证书要求创建新连接，最多三次1/2/3秒退避，重连和握手计入原600秒总期限。连接拒绝44单独标记connectionRejected，不再按普通断线处理；非法帧、证书错误、取消及显式关闭也不重连。仅重发订阅，API重建/本机上传均不重放。Repository保持最终原件详情/身份校验和明确失败后的恢复标记逻辑，不改变其业务请求。

独立只读复核：新连接保留原同源请求、凭据和证书策略，不记录URL；关闭原socket并清理信任登记；每个等待闭包捕获固定socket，取消不会关闭其他代次；退避前后与结果接受前检查取消/通道状态；总期限不被重连重置；并发completion仍拒绝。未知任务不因超时或断线标为失败/成功，也不恢复标记。没有新增UI或公开契约/存储，完整队列恢复仍待下一切片。

- `swift test --package-path apple --skip-update --jobs 4 --filter SynologyPhotosPreviewEventsTests`初次19项通过；增加证书错误负例后再次运行20项通过，退出0。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，386项XCTest（239Repository、96Model、5转换、19事件、27外观）与6项本地化全部通过。随后仅新增上述证书测试，产品代码未改；本波次新增3Repository、7事件测试，覆盖重连明确成功/失败、同编号订阅和其他编号过滤、反复握手断线/上限、超时、取消/关闭、44拒绝、证书错误、个人共享只写一次、失败只清理一次和身份改变保持未知。没有失败断言或降低既有验证；原44负例按新明确错误类型更新，仍拒绝且关闭通道。
- `python3 tools/localization/check_localization.py`通过（Apple4424/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组/31引用；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。无新可见文案或布局，未重复UI绘制。

PENDING_USER_VALIDATION：在有管理权限的可测试照片上发起预览重建，任务进行中短暂断网并恢复；预期连接恢复且最终预览更新，不重复重建、月份位置保留。持续断线或已错过完成通知仍保留待核对，不声称完成；后者属于尚未完成的队列恢复切片。用户取消后不重新建立连接，权限/证书异常不能通过自动重连绕过。失败回传测试包版本、网络中断时机、是否恢复、界面提示，不附真实照片/凭据/地址。未向真实NAS写入，合成证据不提升static等级。


### 预览通知短暂断线恢复测试包交付

实际执行`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/preview-reconnect-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-reconnect-20260930" bash apple/Apps/DsmMac/package.sh`退出0，临时xcodebuild启动器复用apple/.build缓存与-skipPackageUpdates。Release构建、严格签名、临时权限与Sparkle实际library loaded、arm64、DMG VALID均通过；独立codesign --verify --deep --strict与file复核通过。唯一打包提示为hdiutil弃用；产品代码在回归到打包期间保持不变。

测试包`apple/Apps/DsmMac/dist/photos-preview-reconnect-20260930/LanStash-1.0.11-arm64.dmg`约18MB，1.0.11(21)、本机临时签名，包含前轮混合编辑/相册原位更新/捏合及本轮重连。不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或正式发布。main@5684170与31个已有修改/未跟踪文件保留，无提交推送。一次性日志、启动器及专用构建中间目录记录后移至废纸篓，包与依赖缓存保留。

完整目标继续：下一步接list_regenerating未完成队列与原操作未知结果的恢复，随后分类拼图/相似项目；上传跨重启持久化仍待已发授权问题答复。此次仅把预览恢复组中的短暂断线通知闭环补齐，未把全部三组待办标为完成。


## 未完成预览队列恢复波次（2026-09-30，进行中）

前轮自动重连和可用包已完成，是有效进展；基线仍31个已有改动文件。当前独占Photos共享领域/Repository、macOS恢复面板与Model/View及测试、双语和五端记录。沿既有list_regenerating v1的unit_id/type/filename读取，恢复前固定空间/原件身份并复查队列，不重发set_regenerating；当前会话未知操作继续使用原operationID核对。新增只读队列方法与regeneratePreviews可选resuming参数属于已授权增量契约；默认调用行为保留，不改持久化或工具链。已错过通知的结果需要队列不再包含目标、同一原件身份及非空预览版本发生变化共同证明，单独条目消失不算完成；无法证明的仍保留未知。

### 未完成预览队列恢复实现与验证

共享服务增加只读pendingPreviewRegenerations(in:)和regeneratePreviews的resuming默认参数，原调用保持兼容。macOS“未完成的预览”面板支持个人/共享空间、加载/空/错误/正常列表、刷新、选择与清除选择、固定所选原件并确认继续；打开窗口和切换空间不写入，没有筛选控件故筛选空状态不适用。来源切换用取消和请求代次防止旧结果覆盖；本轮不新增持久化。

Repository按空间读取list_regenerating，逐个回读完整原件身份和目录管理权；恢复前再次检查队列，不重发set_regenerating。已提交未知操作仅只读核对：目标两次不在队列、原件身份保持一致、提交前新鲜读取的非空thumbnail.cache_key发生变化，才能恢复完成。提交前基线不使用列表缓存，避免把历史版本误当本轮完成；网络读取失败保持pending，取消和授权代次检查仍生效。该组合是客户端结果核对策略，不是官方完成回执，cache_key实际变化语义留给用户实测。已知部分失败继续时仅固定剩余原件，重新开始必要标记，不强行复用已被恢复的队列状态。

独立只读复核覆盖实际来源命名空间、原件身份/权限、未知不重放、取消与代次，以及队列消失但版本不变/原件改变时不宣称成功。未变更凭据、存储、其他端UI；五端契约影响已同步。本轮不执行真实NAS写入，不提高私有接口证据等级。

- 实际运行：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，397项XCTest（248Repository、97Model、5转换、20事件、27外观）与6项本地化通过。本轮新增9Repository、1Model，包含队列身份/权限、恢复不重新标记、队列变化不写入、丢通知只读恢复、旧列表版本负例与部分结果固定目标续作。初次编译遗漏一个关联值模式，已补齐；早期3个旧断网回归失败，修复为队列回读失败保留pending，没有降低原断言。
- 实际运行：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test未完成预览恢复中英浅深色四种状态且打开不写入|WorkspacePresentationTests/test恢复预览窗口回车仅继续原所选照片且保持相册位置' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-preview-recovery-ui`退出0，2项通过，覆盖16布局（中英、浅深、四种状态）、真实分段控件切换空间以及回车提交固定选择。先前截图发现透明背景及清除选择文案不准确，修正后最终重跑通过；查看中文浅色正常列表，背景和“清除选择”正确，英文深色错误页可重试。

PENDING_USER_VALIDATION：有目录管理权限的账号，在存在遗留重建任务时重新打开App，从“未完成的预览”分别读取个人/共享任务并选择继续；确认原图保留、成功预览更新、原月份不跳走。当前会话重建时短暂断网错过完成通知，恢复后应自动回读；版本未变不能误报完成，也不能重复提交。失败回传包版本、空间类别、操作和提示，不附真实照片、地址、凭据。功能按实际能力开放，不因未实测禁用。

### 未完成预览队列恢复测试包交付

`python3 tools/localization/check_localization.py`通过（Apple4432/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组fixture/31引用；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

实际运行`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/preview-recovery-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-recovery-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时xcodebuild启动器仅复用apple/.build缓存与skipPackageUpdates；Release构建、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64、DMG VALID全部通过。独立codesign --verify --deep --strict复核通过；只有hdiutil弃用提示。

产物`apple/Apps/DsmMac/dist/photos-preview-recovery-20260930/LanStash-1.0.11-arm64.dmg`约18MB，版本1.0.11(21)，本机临时签名；包含未完成预览恢复和先前照片捏合功能。不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或正式发布。保留31个已有改动文件，无提交推送。整体目标未完成，继续分类卡片和相似项目；上传持久化授权待答复。

## 分类首页拼图波次（2026-09-30，进行中）

预览恢复包已完成，本轮独占Photos只读分类缩略图服务、macOS分类卡片及聚焦测试和五端文档。现有分类首页只有图标，官方脚本确认每类offset0/limit4/additional thumbnail；人物show_more=true，视频Item.list(type=video)，最近添加RecentlyAdded.list，其他分类对应列表。原生保留已有显式空间选择，卡片与点击后列表均固定该空间，避免以另一空间照片预览误导；不改变共享management及人物/主题设置限制。拼图仅装饰性只读，单张失败不阻断进入分类；刷新/来源变化不得保留旧来源图片，不覆盖完整分类封面授权缓存。无持久化或工具链变更。

同次静态发现确认相似项目包括SimilarItem.list_similar、SimilarTimeline.get_similar、Similar.get/get_status、set_top_pick/ungroup/add_item/remove_item等v1，个人/共享独立，enable_similar控制可用性。这里只记录范围与已见字段，不实现缺少完整参数/回读证明的写入口。相似项目仍是完整待办，不以六类拼图替代。

### 分类拼图实现与独立复核

新增只读categoryPreviewImages服务，统一使用现有能力表、空间权限和同源缩略图请求；最多读取四个封面，人物保留person/unit类型，不写完整分类缓存。视频列表参数经官方枚举再次核对为字符串video，不是筛选枚举的整数1；实现与回归按JSON字符串编码断言。macOS按一张整图、两张并列、三/四张两行排列，使用现有标题和无障碍名称；读取中显示进度，空/失败保持图标，打开分类仍可用，不额外增加常驻教学文案。来源切换、刷新、离开首页和权限代次变化均丢弃旧结果。独立复核增加每张图读取前后授权代次检查，避免刷新权限后继续用旧列表发出请求。

UI实际命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test分类拼图中英浅深色正常空错误加载且保持分类入口|WorkspacePresentationTests/test共享分类中英浅深色正常空错误与权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-category-collage-ui`退出0，2项、36布局通过（新增拼图16，原共享分类20）。查看中文浅色四图拼图及英文深色加载失败占位，尺寸、标题、来源选择和刷新保持完整。所有图片均是合成色块，无真实用户照片；装饰性封面没有独立筛选状态，原页面筛选行为保留。

PENDING_USER_VALIDATION：在测试包相册页分别选择个人/共享空间，确认六类卡片可显示最多四张对应来源缩略图，人物封面正确；快速切换空间、刷新或进入分类不闪回旧来源，网络失败仍可打开分类或刷新。检查一至四张封面、浅深主题、键盘与VoiceOver；回传仅操作、包版本和提示。新只读接口没有未实测禁用开关。相似项目分组浏览、推荐照片与分组管理仍未实现；上传队列跨重启恢复仍待存储授权。

分类拼图最终回归：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，402项XCTest（251Repository、99Model、5转换、20事件、27外观）及6项本地化通过。本波次新增3Repository、2Model及1UI测试，覆盖六类/两空间、人物缩略图类型、单图失败、完整封面缓存保留、越权/重复编号/空列表、导航后迟到结果。中途仅新测试把JSON编码字符串期望写成未编码video，两个断言失败；按现有请求构造的真实编码修正期望，未修改生产序列化或降低原断言。新增每张图前后代次核对后完整回归再次通过。

本地化检查通过（Apple4432/Android2188/Windows3402，无新增可见资源）；fixture3组/文档引用31项、严格文档检查与git diff --check均通过。相似功能后续范围进一步核实：分组浏览/推荐照片、拆组/移出与撤销，以及“保留选择删除其他”的单独确认流程；只记录官方静态参数，未触发NAS写入。完整组清理语义与当前环境能力仍需继续核对，下一切片从分组读取与详情开始。

### 分类拼图测试包交付

实际命令：`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/category-collage-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-category-collage-20260930" bash apple/Apps/DsmMac/package.sh`退出0；临时启动器仅复用依赖缓存及skipPackageUpdates。Release构建、严格签名、临时权限、Sparkle实际library loaded、arm64与DMG VALID均通过；独立codesign --verify --deep --strict及file复核通过。产品源码在回归到打包期间未再修改；hdiutil弃用提示不影响产物。

新包`apple/Apps/DsmMac/dist/photos-category-collage-20260930/LanStash-1.0.11-arm64.dmg`约18MB、1.0.11(21)、本机临时签名，包含本轮拼图、预览队列恢复与此前捏合等修改。不包含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或正式发布。工作区保留main@5684170和31个累计修改/未跟踪文件，无提交推送。已结束进程的一次性日志、截图、启动器与专用构建目录移至废纸篓，保留测试包、依赖缓存和防休眠服务。完整目标保持进行中，下一切片实现相似照片分组读取与详情，再补其管理操作。

## 相似照片分组浏览波次（2026-09-30，进行中）

前轮402项回归及分类拼图独立包已交付，属于有效进展。基线main@5684170、31个累计改动文件；本轮独占Photos分组领域、Repository、macOSModel/View及聚焦测试，追加双语资源和五端契约记录。新增相似分类、独立时间线查询、分组快照与组内照片读取，沿已记录SimilarItem/SimilarTimeline/Similar v1；个人和共享分别遵守enable_similar及实际能力，共享还要求management。使用现有月份分页和图片/视频预览，不引入另一套播放器或持久化。

共享枚举新增值需对移动端两个穷尽switch做编译兼容，并在移动端原分类菜单排除新值；这只是保持既有界面不变，本轮不交付移动端相似照片。其余平台只同步影响。相似组以profile/space/groupID固定身份，组内成员回读不得跨空间/跨NAS、不得把重复或无关照片当作成员。加载/错误/空组与下一步恢复明确；分类首页相似拼图和组数标记一起接入。推荐照片、拆组/移出/撤销及保留所选删除其他仍是后续管理切片，不能将可浏览视为全部复刻。

### 相似分组浏览实现、复核与验证

已接入个人/共享相似分类卡片、独立月份时间线/分页、组数标记和预览内成员横条，标出推荐照片；点击或左右键切换同组照片，沿用已有图片捏合、视频和详情，不改变相册当前月份。顶部关键词搜索明确离开相似分类，避免以相似标题展示全空间结果。分组读取失败保留已加载大图并提供重试；关闭或切换后以预览代次丢弃迟到结果。

独立集成复核：固定profile/space/groupID，入口照片与推荐项必须是唯一成员集合中的项目；成员get响应不按顺序假定，重新按item_id排序；共享entry不能读取全局相似分类；权限刷新使在途结果失效且不继续成员读取。确认没有新增NAS写入、持久化或待实测禁用开关。移动端仅两个穷尽分支及共享Model排除新分类，未声称iOS/iPadOS构建或实机通过。稳定端点`photos-similar-items`、机器兼容表与五端影响已同步，真实环境仍为static。

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：410项XCTest（256Repository、102Model、5转换、20事件、27外观）及6项本地化通过。本轮新增5Repository、3Model，覆盖实际能力/设置/权限、个人共享路由、组内顺序/推荐项、错误成员与跨来源拒绝、权限刷新、月份/预览位置、重试和迟到结果。首轮旧测试写死六类导致1失败，按新增相似类别更新为完整枚举集合后通过，没有删断言或屏蔽失败。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相似照片预览中英浅深色加载错误与组内正常布局|WorkspacePresentationTests/test分类拼图中英浅深色正常空错误加载且保持分类入口' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-similar-ui`最终退出0，2项/28布局通过（相似预览12、分类拼图16）。初次新测试缺少MacAppearanceStore环境导致测试进程退出，补齐测试宿主后通过；截图另发现横向ScrollView高度抢占大图，约束底部横条高度并对齐推荐标记后重跑通过。查看中文深色正常组截图，底部紧凑且大图区域完整；合成色块按原尺寸显示，无真实用户照片。
- `python3 tools/localization/check_localization.py`通过（Apple4438/Android2188/Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过（3组/32文档引用），`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

PENDING_USER_VALIDATION：NAS开启相似识别、有可用分组；在个人及共享管理来源打开相似分类并跳转旧月份，打开组、点击/左右键切换、捏合、关闭，确认同组成员/推荐项与月份保留；网络恢复后重试。回传包版本、来源类别、操作和脱敏错误；不提供照片、主机、账号或凭据。尚未实现推荐项修改、拆组、移出及撤销、保留选择删除其他；上传跨重启持久化仍待已发存储授权答复，完整目标继续。

### 相似分组浏览测试包交付

实际运行`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/similar-browse-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-similar-browse-20260930" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器复用apple/.build缓存并skipPackageUpdates。Release构建、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64与DMG VALID通过，独立codesign --verify --deep --strict及file复核通过。hdiutil弃用提示不影响产物。

独立包`apple/Apps/DsmMac/dist/photos-similar-browse-20260930/LanStash-1.0.11-arm64.dmg`，约18MB、1.0.11(21)，本机临时签名；包含新相似分组浏览和此前捏合、分类拼图、预览恢复。无Finder本地磁盘挂载扩展，没有安装、启动或正式发布，没有覆盖前轮包。main@5684170及全部已有改动保留，目前34个修改/未跟踪文件，无提交推送。一次性日志、截图、工具启动器和专用构建目录在所有任务结束后移至废纸篓，保留产物和依赖缓存。完整目标未完成，下一切片接入相似分组管理并复用既有操作去重/确认/结果核查流程；上传持久化仍待已发授权问题答复。

## 相似分组管理波次（2026-09-30，进行中）

上一轮410项回归与独立浏览包完成，属于有效进展；基线main@5684170、34个累计改动文件。本轮独占Photos管理枚举/Repository、macOS预览与Model、聚焦测试、双语与契约记录。沿现有mutation确认/去重/自动核对接入set_top_pick、ungroup、remove_item、add_item；撤销绑定本会话已确认原操作，先核对其结果仍成立与原件/权限。分组变更与删除原件分开，未知结果只核对不重放。不新增存储或工具链；用户已授权契约扩展与可测试入口开放，实际NAS写入留给用户。

### 相似分组管理实现与独立复核

已接入预览内推荐设置、多个成员勾选移出、当前组拆分、已确认分组更改的本会话撤销。所有分组操作保留原件；确认框固定原组/成员/推荐项，执行后原位更新代表照片和预览，月份不刷新。撤销按钮在图库和预览均可见，未知操作阻止重复提交并沿已有自动核对时序检查；不是新增待实测门禁。

Repository复用PhotosMutationRecord与prepare/perform/review：每张原件身份/目录权限、精确分组快照、Similar.get和SimilarItem.get双重成员核对。支持空组与有效单成员解散结果；失败不当作空。撤销仅接受本会话confirmed的remove/ungroup记录，必须当前结果仍成立、原件可管理、没有成员进入其他组；同一原操作不能以新编号重复撤销。分组数量不额外受普通批量100项限制。未执行NAS写入，空组/单成员形式是静态线索及合成覆盖，真实行为仍需用户验证。

独立只读对抗复核覆盖实际权限与命名空间、伪造撤销、并发分组变化、断网未知不重放、原件消失/变化与旧成员响应；在实际写分支再次核对分类权限。另发现撤销在新月份可能插入旧组，已将原位置绑定原查询范围：不同月份只更新本窗口已有同组，不插入旧组；新增回归通过。未改变其他端界面、存储、工具链、应用标识或签名配置。

- 实际运行`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`最终退出0，419项XCTest（262Repository、105Model、5转换、20事件、27外观）及6项本地化通过。本轮新增6Repository和3Model，覆盖两个空间的三种写命令、参数、自动结果核对、重复提交、断网、撤销、未知/其他组拒绝、单成员边界与月份原位更新。初次编译新增三处keypath文本转义丢失，改为普通闭包后修正；没有删除旧测试/降低断言。
- 实际运行`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相似照片预览中英浅深色加载错误与组内正常布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-similar-manage-ui`退出0，1项/12布局通过。截图检查中文深色，管理菜单、独立勾选、推荐标记均不挤占大图；真实菜单交互/确认与NAS结果交给用户，不以截图替代写行为验证。
- `python3 tools/localization/check_localization.py`通过（Apple4447/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组/32文档引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

PENDING_USER_VALIDATION：可测试相似组分别尝试推荐设置、勾选移出、拆组、撤销，确认原件仍在时间线、成员/推荐正确、月份不跳；切换月份再撤销不插入旧月份内容，另一网页改变成员后不覆盖其结果。真实NAS断网回读和最终一致性仍未验证；回传仅包版本、来源、动作及脱敏提示。

完整目标继续：相似组“保留所选删除其他”、主列表多组选中批量拆组尚未接入，get_status的识别处理状态仅静态线索待完整核对；上传跨重启恢复仍待既有存储授权答复。不能把本轮单组管理当作全部相似功能完成。

### 相似分组管理测试包交付

实际运行`LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/similar-manage-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-similar-manage-20260930" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器只复用apple/.build缓存并skipPackageUpdates。Release、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64和DMG VALID均通过；另行codesign --verify --deep --strict和file复核通过。hdiutil弃用提示不影响包。

产物`apple/Apps/DsmMac/dist/photos-similar-manage-20260930/LanStash-1.0.11-arm64.dmg`约18MB、1.0.11(21)，本机临时签名，不包含Finder本地磁盘挂载扩展。没有安装、启动、覆盖旧测试包或正式发布，产品代码在最终419回归至打包期间冻结。保留34个累计修改/未跟踪文件和main@5684170，无提交推送；结束后的本轮一次性日志、截图、启动器及构建目录移至废纸篓，包与缓存保留。

打包期间继续只读核对网页get_status：确认running/计划处理的显示条件和15秒轮询，记录到现有环境与photos-similar-items文档；临时浏览器变量删除确认undefined，控制台清空并关闭，无NAS写入。下一切片继续原件清理、多组拆分和识别状态，上传存储授权仍待答复；完整目标保持进行中。

## 相似照片清理、批量与识别状态波次（2026-09-30，进行中）

前轮419回归及管理包完成，属于有效进展。基线main@5684170与34个累计改动文件；独占既有Photos领域/Repository、macOSModel/View、测试与双语/五端记录。沿已验证客户端的删除确认/去重/自动核对接入保留所选清理；新增可返回已解散组的只读详情以原位更新，不刷新到最新月份。主列表多个组的确认和续作复用既有单组mutation闭环；get_status仅在相似分类可见时按官方15秒轮询，读取失败不阻断浏览。无新存储/工具链，真实NAS仍留给用户。


### 相似清理、批量和状态实现与独立复核

保留所选清理先重新读取原组成员、推荐项与每张原件身份，固定未选择的原件名单；确认框明确保留和删除数量，确认前没有写入。复用既有逐项删除及自动只读核对；确认已删除后最多三次刷新受影响分组，更新剩余数量或移除解散组，不刷新整个图库、不改变月份。刷新失败只提供只读重试，不能重新删除。导航后查询范围不匹配则丢弃旧位置。分组撤销不用于恢复已删除原件。

主列表多组拆分一次确认固定分组，逐组复用prepare/perform/review；未知当前项暂停后续，核对确认后继续；已知失败保留剩余队列供继续或取消。失败核对不自动继续，批量暂停时撤销按钮准确禁用，取消剩余后可撤销已成功组。批量撤销反向恢复本会话已确认组，逐组继续原权限、身份和成员归属核对，避免覆盖网页并发更改。固定月份位置仍按原查询保存。

新增只读similarGroupDetails（已解散返回nil）及similarStatus，默认实现明确unsupported以保留旧Adapter兼容。get_status按官方字段显示正在分析的数量或计划处理状态，只有相似分类可见时每15秒刷新；失败隐藏状态但不阻断照片，离开取消轮询。所有新文案中英资源同步，没有持久化、权限、标识、依赖或其他端UI变更。

独立只读对抗复核覆盖：删除补集不能随选择变化、原件及来源权限、解散与读取失败区分、未知不重放、删除后分组查询代次/原月份、批量中途未知/失败、撤销绑定原操作和原月份。真实NAS未由Agent写入，私有接口证据仍static，不增加未实测禁用门禁。

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 最终退出0：429项XCTest（265 Repository、112 Model、5转换、20事件、27外观）和6项本地化通过。相对前轮新增3 Repository、7 Model，覆盖状态两来源/权限变化/无效响应、组解散与跨profile拒绝、固定清理名单、只读刷新重试、批量确认/撤销/未知暂停/失败停止。中途新增测试stub遗漏闭合括号导致编译失败，已修复后完整重跑；未降低原断言。

PENDING_USER_VALIDATION：使用可丢弃的测试照片组成相似组，在旧月份勾选保留项并确认删除其余，确认保留原件、计数和月份正确；主列表选多个组拆分，再撤销，原件应一直保留；短暂断网后不能重复删除/拆组，分组刷新失败重试只读。核对个人/共享来源、识别运行/等待状态、键盘/VoiceOver及触控板。回传包版本、空间、步骤和脱敏提示，不附真实照片、路径或凭据。


- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相似识别状态中英浅深色运行等待与完成布局|WorkspacePresentationTests/test相似照片预览中英浅深色加载错误与组内正常布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-similar-cleanup-ui` 退出0：2项、24布局通过（状态12、预览12）。人工检查中文浅色识别状态及英文深色预览，状态、分组数量、成员勾选和管理菜单完整；合成图片与状态，不代表真实NAS行为或物理手势验收。
- `python3 tools/localization/check_localization.py`通过（Apple4457/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组及32引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。


### 当前剩余功能复核

本轮按源码重新确认SynologyPhotosManagement中的命令及Repository实际prepare/perform/inspect分支，而非只按历史完成说明：普通/条件相册、标签与日期、分享成员/密码/有效期、照片请求、人物/手工人脸、预览重建、相册协作/跨空间与相似管理均有现行实现。界面入口仍按真实空间设置、能力和权限提供，没有人工待实测白名单。FilePreviewView继续监听窗口/区域内magnify与scrollWheel，MacAppearanceTests对应合成事件回归本轮执行通过；物理触控板手感由用户验证。

当前已核实尚未实现项是Photos上传队列跨会话/重启恢复：SynologyPhotosModel.uploadQueue仍为内存数组，未新增持久化或来源访问书签。其具体方案和回滚已在本页“剩余能力依赖复核与重启恢复方案（待授权）”列明，仍等待此前单独的存储授权答复，不重复索取契约授权。真实NAS接口行为、实际照片格式/触控手感属于用户验收，不算新的代码禁用项。当前源码审计不能证明所有DSM/Photos版本及尚未观察到的网页入口都完全一致，因此不宣称无条件100%复刻。


### 相似清理、批量和识别状态测试包交付

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/similar-cleanup-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-similar-cleanup-20260930" bash apple/Apps/DsmMac/package.sh` 退出0；临时xcodebuild启动器只复用apple/.build依赖缓存与skipPackageUpdates。Release构建、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及DMG VALID均通过；另行codesign --verify --deep --strict及file复核通过。仅hdiutil弃用提示，未改变工具链。最终429回归及24布局之后产品源码保持冻结至打包完成。

独立产物 `apple/Apps/DsmMac/dist/photos-similar-cleanup-20260930/LanStash-1.0.11-arm64.dmg` 约18MB，版本1.0.11(21)、本机临时签名；包含本轮及此前照片捏合、分组管理、分类拼图、预览恢复等累计修改。测试包不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖前轮产物或正式发布。main@5684170和34个累计修改/未跟踪文件保留，无提交、推送或PR。全部进程结束后本轮一次性日志、截图、工具启动器及专用构建目录移至废纸篓，保留dist产物和依赖缓存。

完整目标仍保留上传跨重启恢复待办及已发存储授权；不将其标记完成。实际NAS与物理触控板验收由用户执行，步骤见上文PENDING_USER_VALIDATION。


## 下载格式对齐波次（2026-09-30，进行中）

上一轮清理/批量/状态429项回归及独立包已完成。本轮重新核对实际网页菜单，发现此前剩余清单遗漏“压缩版JPEG下载”：网页下载子菜单有原始文件/压缩版JPEG，当前共享服务和macOS保存路径只有downloadOriginal。本轮独占Photos只读下载契约、Repository、macOS保存菜单与测试、双语及五端影响，先核对官方静态参数再实现；不修改NAS原件、不新增持久化。上传跨重启恢复仍待既有授权。34个累计改动保留，不因已有大部分功能而宣称全部完成。


### 压缩下载实现与独立复核

已接入原件/压缩JPEG选择、实际格式返回与命名、同名不覆盖、原格式保留数量提示；主列表相似组下载全部成员，预览只下载当前照片。复核了原件大小校验保持、压缩大小不同可接受、Content-Length不一致/截断JPEG/错误文档拒绝、跨profile和来源权限、相册统一路由、取消与权限代次、目录授权及临时文件清理。没有修改NAS原件，也没有把未实测变成人工禁用条件。共享声明有默认兼容实现，五端影响同步，未执行其他平台构建。

此前将“上传跨重启恢复”写成唯一已核实代码缺口不够完整；本轮实际网页菜单新增证据证明还有整相册/文件夹下载、特定格式原尺寸JPEG转换、幻灯片播放。Folder.set_cover只有静态入口线索，后续先核对完整契约，不能猜测实现。继续保留完整网页对齐目标，不把本轮菜单补齐当作全量完成。


- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0，434项XCTest（268 Repository、114 Model、5转换、20事件、27外观）与6项本地化通过。本轮新增3 Repository、2 Model，覆盖个人/共享/相册路由、JPEG与原格式、截断和错误文档、跨设备拒绝、不覆盖、正确后缀、相似全组成员及月份选择保留。初次377项旧回归和最终新增回归均通过，无降低断言。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片下载格式菜单中英浅深色且打开不下载|WorkspacePresentationTests/test相似照片预览中英浅深色加载错误与组内正常布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-download-ui` 退出0，2项、20布局通过。新增8布局实际打开NSMenu检查照片两选项、视频仅原件，打开不下载；原预览12布局回归。查看中文深色预览，顶部下载菜单与相似组操作完整。截图均为合成内容，不替代真实NAS或物理触控验收。
- `python3 tools/localization/check_localization.py`通过（Apple4460/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组及32引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

PENDING_USER_VALIDATION：使用测试照片分别在个人/共享/协作相册选择压缩JPEG，检查成品打开、原件不变、后缀与实际格式一致；混合视频批量保留原格式，已有同名文件另存。相似分类选择一组应下载全部成员，组内预览下载仅当前照片。断网/无权应失败且不覆盖旧文件，月份与原选择保留。失败回传包版本、照片类型、空间和脱敏提示即可。


### 下载格式测试包交付

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-download-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-download-formats-20260930" bash apple/Apps/DsmMac/package.sh` 退出0；临时xcodebuild启动器仅复用apple/.build与skipPackageUpdates。Release、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及DMG VALID均通过；额外codesign --verify --deep --strict与file检查通过。hdiutil弃用提示不影响产物，产品源码从最终UI回归到打包完成保持不变。

独立包 `apple/Apps/DsmMac/dist/photos-download-formats-20260930/LanStash-1.0.11-arm64.dmg` 约18MB、1.0.11(21)、本机临时签名；包含本轮压缩下载与此前相似整理/触控板捏合等累计修改。不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或正式发布。保留main@5684170和34个累计改动/未跟踪文件，无提交推送。全部本轮进程结束后，一次性日志、截图、临时启动器及专用构建目录移至废纸篓，保留包和依赖缓存。

下一切片：整相册与文件夹下载，随后核对原尺寸JPEG转换、幻灯片和文件夹封面；上传跨重启恢复仍待既有存储授权。当前是实际进展，完整目标保持进行中，不能因为上一版清单遗漏而提前标记完成。


## 整相册与文件夹下载波次（2026-09-30，进行中）

上轮压缩下载434回归及独立包已交付，是有效进展。本轮独占Photos共享下载目标、Repository、macOS保存入口/Model、聚焦测试及双语五端记录；34个累计修改保留。核对官方整册/目录下载参数后直接取得ZIP，不用当前已加载页冒充整个相册，不在客户端递归扫描所有原件。固定来源、相册权限与目标快照；临时文件验证后按保存面板确认导出，失败不覆盖。无新增存储、依赖或权限配置，NAS实际测试留给用户。


### 归档实现与独立集成复核

完整集合沿官方Album.download或Download.folder_id，目标固定、不以已加载页代替；当前工具栏和右键菜单均开放原件/压缩JPEG ZIP，允许取消。相册当前角色约束canDownload，非当前相册开始前重新读取角色；贡献权限不能代替下载权限。个人目录显式download=false拒绝，共享entry同时要求view/download；权限刷新丢弃在途结果。协作口令仅在POST体，目录路由绑定真实空间。没有人工待实测禁用开关。

只读对抗复核覆盖身份错配、共享只查看不下载、协作成员无下载权、相册空间关闭、权限中途撤回、JSON/HTML/截断ZIP、已有目标、重复点击与取消。ZIP检查限首标识和完整结束记录，不能宣称逐文件CRC或真实大包验证。Model沿系统保存确认协调替换，失败保留旧文件，不刷新图库。复核补齐URLSession取消错误的安静退出并纳入原取消回归。共享协议默认实现兼容，不改变存储或其他端界面。


### 本轮归档下载验证

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 最终退出0，442项XCTest（273 Repository、117 Model、5转换、20事件、27外观）与6项本地化通过。新增5 Repository/3 Model覆盖普通/条件/协作相册两格式、相册空间关闭、目录两空间真实权限、POST口令、错误/截断ZIP、不覆盖、权限撤回、取消去重和月份保留；取消使用URLError.cancelled回归。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test整册与文件夹下载菜单中英浅深色且打开不下载|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-archive-ui` 退出0：2项、20布局通过（实际菜单打开8、相册/目录/下载无权页面12）。人工查看英文浅色相册与中文深色文件夹，新增图标、标题和搜索栏无裁切。合成空内容与权限状态，不代表真实NAS下载、全部图库状态或物理触控验收。其后只补取消错误分支并完整重跑上述442项回归，界面结构没有变更。
- `python3 tools/localization/check_localization.py`通过（Apple4465/Android2188/Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过3组及32引用，`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

PENDING_USER_VALIDATION：使用普通、条件、他人分享的测试相册及个人/共享测试目录，在顶部或右键选择原件/压缩JPEG保存ZIP；解压核对全部内容（不局限当前页面）、视频等原格式保留。验证无下载权的协作者被拒绝、下载中取消和断网不覆盖已有文件、完成后保持原月份与选择；大归档/ZIP64实际兼容留给用户。现有触控板捏合测试包含在本轮MacAppearanceTests，双指实际手感仍由用户验收。回传包版本、空间、步骤和脱敏错误，不附真实照片、地址、路径或凭据。

剩余实现：特定格式原尺寸JPEG转换、幻灯片播放、文件夹封面完整契约/原生入口；上传队列跨会话和重启恢复继续等待已发持久化授权。本轮完整集合下载已从最新待办移除，历史章节保留当时证据；总体目标不标记完成。


### 整册与目录归档测试包交付

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-archive-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-archive-download-20260930" bash apple/Apps/DsmMac/package.sh` 退出0；临时xcodebuild启动器仅复用apple/.build依赖缓存与skipPackageUpdates。Release、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及DMG VALID均通过，另行 `codesign --verify --deep --strict` 和 `file` 复核通过。只有hdiutil弃用提示，未改变工具链；最终442项回归后的产品源码保持冻结到打包完成。

独立包 `apple/Apps/DsmMac/dist/photos-archive-download-20260930/LanStash-1.0.11-arm64.dmg` 约18MB，1.0.11(21)、本机临时签名；包含本轮归档下载及此前触控板捏合、相似整理、压缩下载等累计修改。不含Finder本地磁盘挂载扩展，没有安装、启动、覆盖旧包或正式发布。main@5684170与34个累计修改/未跟踪文件保留，无提交、推送或PR。全部本轮进程结束后一次性日志/截图、临时启动器及专用构建目录移至废纸篓，保留dist和依赖缓存。

下一切片继续核对原尺寸JPEG转换与幻灯片/目录封面；完整网页对齐目标仍进行中，真实NAS和物理手势由用户验收，不添加人工功能禁用。


## 幻灯片播放波次（2026-09-30，进行中）

前轮整集合下载已完成442项回归、20布局及独立测试包，是实际进展。当前34个累计修改保留，本轮仅修改macOS照片预览播放状态、原生入口、聚焦测试和双语记录；沿已有只读媒体和分页契约，不新增存储或NAS写入。先核对官方播放范围、设置、退出和视频行为，再实现并做独立集成复核；上传重启恢复继续等待此前存储授权，不阻断无依赖播放。


### 幻灯片实现与独立复核

macOS顶部和预览新增播放入口，按已有查看权限开放，不要求下载权限。独立NSWindow全屏，关闭/离开全屏取消播放、返回预览；主窗口全屏状态不修改。照片等待媒体读取完成后按三秒计时，视频以结束事件推进，暂停取消计时且暂停视频；左右键切换、空格暂停/恢复、Escape退出。错误停在当前照片，可继续或手动切换；不静默跳过失败照片。实况正在播放时进入幻灯片先恢复静态图，避免没有视频结束回调而卡住。

播放使用原空间及完整查询、独立偏移按需分页；从当前照片开始，相似组内以完整成员为范围。到尾部继续下一页，再循环；首项向前时补读末页。只保留媒体元数据，图片仍逐张读取；不会把已加载的一页当完整范围，也不改图库月份、选择或分页。先定位深历史当前照片可能需要读多页元数据，等待期间显示加载，可以暂停/退出。离开图库/刷新/权限变化取消任务，迟到响应不能复活播放；失效分页报错而不猜测跳过。

独立复核覆盖计时取消、视频暂停/结束/失败、旧播放器回调、切片重入、空/加载状态禁止启动、迟到页、分页范围、相似组及关闭窗口清理。复用PhotoMotionPlayer流媒体加载器，新增播放控制及失败事件；Live Photo既有一次播放/回静态语义保留。合成UI发现浅色宿主可让图片背景变浅，已固定播放区域深色环境，普通预览仍跟随用户主题。没有新增公开契约、NAS写操作、持久化、系统权限或其他端界面。


### 幻灯片验证与用户验收

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：449项XCTest（273 Repository、124 Model、5转换、20事件、27外观）与6项本地化通过。新增7 Model回归覆盖独立跨页/月份选择保留、首尾循环、可控计时暂停与恢复、视频结束事件、失败重试、迟到页、相似组成员、Live Photo恢复静态及刷新结束播放。中途新增测试stub漏实现searchTimeline导致编译失败，已补齐并重跑；未降低断言。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test幻灯片中英浅深色播放暂停加载失败并且退出保留位置|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-slideshow-ui-final` 退出0：2项28布局通过，幻灯片中英浅深色播放/暂停/加载/错误16，原页面/下载权限12；每个播放场景实际发送Escape并断言退出、月份保留。查看英文浅色宿主的播放错误及相册头部，最终播放背景深色、提示和按钮完整，无工具栏裁切。独立系统全屏窗口/多显示器不是上述合成测试覆盖范围。
- `python3 tools/localization/check_localization.py`通过（Apple4470/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组及32引用；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。界面背景修正后重新构建并执行最终UI回归，未修改业务逻辑。

PENDING_USER_VALIDATION：在旧月份、目录、普通/条件/协作相册与相似组内，从顶部或预览进入幻灯片；确认照片约三秒切换、视频播完推进、空格暂停/恢复、左右切换、Escape和系统退出全屏均可返回预览，关闭预览后图库仍在原月份/选择。试断网和恢复、不同视频格式、Live Photo、仅查看无下载权限账号；确认多显示器、VoiceOver和系统降低动态效果。返回版本、入口/空间、动作、脱敏错误即可，不附真实照片/地址/凭据。源码按权限开放，不新增人工验证开关。

剩余：特定格式原尺寸JPEG转换、文件夹封面完整契约及原生入口；上传队列跨会话/重启恢复仍等待此前存储授权。完整目标保持进行中，当前照片幻灯片主流程已从代码待办移除，真实设备体验不伪装为已验收。


### 幻灯片独立测试包交付

实际运行 `LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-slideshow-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-slideshow-20260930" bash apple/Apps/DsmMac/package.sh` 退出0；临时xcodebuild启动器仅复用apple/.build与skipPackageUpdates。Release、严格签名、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及DMG VALID通过；另行 `codesign --verify --deep --strict`、`file` 检查通过。只有hdiutil弃用提示，无工具链变更；最终28布局回归至打包结束产品源码保持冻结。

独立产物 `apple/Apps/DsmMac/dist/photos-slideshow-20260930/LanStash-1.0.11-arm64.dmg` 约19MB，版本1.0.11(21)、本机临时签名。包含幻灯片及此前照片捏合、整集合/压缩下载、相似整理等累计修改；不含Finder本地磁盘挂载扩展。没有自动安装、启动、覆盖旧包或正式发布。main@5684170与34个累计修改/未跟踪文件保留，无提交推送。进程结束后本轮一次性日志、截图、临时启动器及专用构建目录移至废纸篓，保留测试包和依赖缓存。

构建期间只读补充下一项original_size_jpeg的convert调用/菜单条件候选，记录在photos-library-read.md和环境快照，尚未写产品代码或执行真实转换；没有把候选证据当完成。完整目标继续，下一切片核全原尺寸转换实际能力标记和返回语义。


## 原尺寸JPEG下载波次（2026-09-30，进行中）

前轮幻灯片449回归、28布局与独立包已完成，属于实际进展。34个累计改动保留；本轮独占Photos下载格式/实际能力、Repository转换下载、macOS菜单/保存及相关测试资源，同步五端契约影响。先核对官方设置字段和转换响应，沿已授权接口增量扩展，不新增持久化/依赖或其他端UI；不能把压缩JPEG冒充原尺寸转换。实际NAS转换由用户验收，不做人工未实测禁用。


### 原尺寸JPEG实现与独立复核

已核实两项设置来源、HEIC/TIFF/RAW精确格式与convert成功后下载语义；共享能力默认false仅代表缺少真实响应字段，不是验证等级开关。单项菜单、预览/右键和普通单选可用；相似组整组和集合归档不提供原尺寸转换。保存按实际格式用.jpg，同名序号保留旧文件，保留月份/选择。

Repository新增转换去重、身份与下载权限核对、代次/取消保护，沿现有callVoid调用而非重复实现传输。相册照片所有者与相册所有者是两个身份：分别核对项目owner_user_id与照片上下文，再用相册角色选择album_id或passphrase，避免共享原件在个人相册内被错误拒绝。口令仅进POST体；转换成功不等于输出有效，JPEG完整解码和Content-Length（有值时）仍需成功。整册方法明确拒绝单项格式，避免落入压缩格式分支。默认Serving适配器继续只支持原件，不把不支持格式默默返回原件。

独立只读复核关注：取消发生在转换请求之前或响应之后，均不能继续下载/保存；转换已被NAS接收时可能已生成缓存，不承诺撤销。能力重查失败撤销旧能力；同照片在途锁覆盖下载过程，失败不自动重放。无原件写入、依赖或持久化改变，无真实NAS写操作。

补充角色边界：协作相册延续既有本人贡献下载语义；原空间开启且最新Item.get additional.provider_user_id确认为当前账号时，允许下载本人贡献，即使相册不给其他成员下载权。身份核对仍走原album_id，不回退原空间绕过拒绝；旧提供者信息不作为授权。该路径已加入合成回归。


### 原尺寸JPEG本地验证

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，最终退出0：460项XCTest（Repository282、Model126、转换器5、预览事件20、外观27）零失败；另6项本地化测试通过。中途新增转换后取消测试捕获XCTest实例触发Swift并发编译检查，改为在Task前构造Sendable照片值后重跑通过，未降低断言。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片下载格式菜单中英浅深色且打开不下载|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-jpeg-ui-final`，退出0：2项28场景通过；菜单16（HEIC可用/不可用、JPEG、视频×双语浅深色），集合页面12。实际打开NSMenu断言格式项，打开菜单零下载；菜单截图为关闭后控件，不能据其声称原生弹出菜单像素审查。检查英文浅色相册截图，工具栏/空状态布局完整。
- `python3 tools/localization/check_localization.py`：Apple4471/Android2188/Windows3402，双语、参数、引用、硬编码检查通过；`python3 tools/contract-validation/validate_fixtures.py`：3组fixture/32个私有API文档引用通过；`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。

PENDING_USER_VALIDATION：NAS具备HEVC能力且开启原尺寸JPEG后，分别选择HEIC/TIFF/RAW，从预览、右键、单选菜单下载；核对JPEG尺寸/方向/可读性、原件不变、同名不覆盖、旧月份和选择保留；测试个人、共享和协作相册含本人贡献，断网、长转换、取消与权限撤回。取消不能保证撤回NAS已经开始的派生转换。未执行真实NAS转换、下载或照片写入，不把合成测试视为实机通过。

最新剩余：文件夹封面的完整官方契约及原生入口仍需核对；上传队列跨会话/重启恢复仍等待此前明确的存储授权。原尺寸JPEG已从代码缺口移除，完整网页对齐目标保持进行中。


### 原尺寸JPEG独立测试包交付（2026-09-30）

实际打包命令：`PATH="/tmp/dsm-photos-jpeg-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-original-jpeg-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-original-jpeg-20260930" bash apple/Apps/DsmMac/package.sh`，退出0；临时xcodebuild启动器仅复用现有apple/.build依赖缓存和skipPackageUpdates，不改项目工具链。Release/arm64、本机临时签名、Hardened Runtime专用测试权限检查、Sparkle实际`library loaded`通过；独立`codesign --verify --deep --strict`、`file`架构及`hdiutil verify`（VALID）通过。

产物 `apple/Apps/DsmMac/dist/photos-original-jpeg-20260930/LanStash-1.0.11-arm64.dmg`，约19MB，版本1.0.11(21)。包括原尺寸JPEG及之前捏合缩放、幻灯片、整集合/压缩下载、相似整理等累计修改；不含Finder本地磁盘挂载扩展。未自动安装/启动、覆盖旧包或正式发布。main@5684170与34个累计修改/未跟踪文件保留，未提交推送。本轮一次性日志、截图、临时启动器与专用构建目录在进程结束后移至废纸篓，保留独立测试包及依赖缓存。

本次仅本地源码/合成/构建验证；没有真实NAS转换、下载或写操作。用户验证步骤见上述原尺寸JPEG段落。完整网页对齐仍进行中；下一切片核对文件夹封面，上传重启恢复继续等待已有存储授权答复。


## 文件夹封面对齐波次（2026-09-30，进行中）

前轮原尺寸JPEG完成460项回归、28个UI场景和独立包，属实际进展。本轮保留34个累计改动，先只读核实Folder.set_cover v2完整权限、目标和回读；单一修改范围为Photos共享封面契约、Repository、macOS目录入口及相关测试/资源/五端记录。不涉及上传队列持久化或其他端UI，不触发真实NAS封面写入。


### 文件夹封面实现与独立复核

官方静态核对支持单照片封面，窗口可进入目标子目录；本轮已加入目录卡片和顶部、单选菜单、照片右键与预览入口。卡片读取默认拼图或自定义封面；选图固定目标目录，子目录浏览不会改变设置目标，分页读取不改变图库月份或选择。保存后自动核对，仅封面修订更新。可查看但不可下载的子目录来源仍允许选用，目标必须有管理权限。根目录不提供入口，没有凭空新增清除封面动作。选择器沿现有拍摄时间顺序；网页切换排序控件仍属交互差异，不能宣称逐项完整复刻。

共享契约及五端影响同步，Folder.set_cover v2采用id与id_item单元素数组；预检重新核对目录路径/权限、照片身份和来源后代边界，沿operationID去重、代次/取消防迟到。独立只读复核重点包括同编号跨空间、无源管理/下载权限但可查看、根目录/兄弟目录/身份变化拒绝、旧权限撤销、重试不重放、图像解码失败。原生结果确认要求明确成功回执和新鲜自定义封面序号0可解码；官方没有回读所选照片ID的字段，故不能据此声称证明了精确ID，其他客户端并发改封面仍由用户验证。写回执丢失保持未知，不猜测成功，也不重复提交。

沿用户既有授权按实际能力开放，无人工未实测禁用；不修改持久化、依赖、标识或其他端UI，不执行真实NAS写入。源码/模拟验证不代替实际版本兼容。


### 文件夹封面本地验证

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，最终退出0：468项XCTest（Repository288、Model128、转换5、事件20、外观27）和6项本地化通过。新增6 Repository与2 Model，覆盖个人/共享路由、默认/自定义封面、子目录来源、权限/身份/空间/路径拒绝、回执丢失不重放、读失败重查、坏图不误报以及图库月份/选择保留。中途新测试的抛出表达式和模拟服务searchTimeline实现造成编译失败，补齐后重跑通过；没有降低断言。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录封面选择器中英浅深色五种状态且回车只提交固定目标|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-folder-ui-final`，退出0：2项32场景通过，包括选择器双语浅深色的加载/空/错误/普通/已选20场景，以及原集合页面12场景；实际发送回车验证固定目标且打开不写入。初次截图缺少明确背景导致透明宿主显示异常，补用项目现有windowBackgroundColor后重新构建并完整重跑。查看最终中文深色已选及英文浅色错误截图，标题、内容、恢复操作与底部按钮未裁切。
- `python3 tools/localization/check_localization.py`通过：Apple4479/Android2188/Windows3402；双语、参数、资源引用与硬编码扫描通过。`python3 tools/contract-validation/validate_fixtures.py`通过3组/32引用；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

PENDING_USER_VALIDATION：在个人/共享测试文件夹通过卡片右键或顶部更换封面；选择当前或子目录照片，保存后回到父目录检查新封面，并确认原图库月份/选择不变。也从照片右键、单选菜单和预览进入。分别检查无管理权目标、只有查看权的子目录来源、断网后恢复、其他客户端并发改封面；正常回执后的短暂读取失败应自动核对，回执丢失不能保证最终归属，不自动重发。验证VoiceOver、键盘及实际套件版本；回传版本、个人/共享、入口步骤和脱敏错误，不发送真实照片/路径/地址或凭据。真实NAS写入没有代测，不把这些合成回归称作兼容验收。

最新剩余：上传队列跨会话/重启恢复仍等待此前持久化授权；封面选择器排序切换尚未接入，下一切片核对官方排序范围后补齐。文件夹封面主流程已可用，完整网页对齐目标继续，未擅自缩小范围或标记完成。


### 文件夹封面独立测试包交付（2026-09-30）

实际运行 `PATH="/tmp/dsm-photos-folder-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-cover-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-cover-20260930" bash apple/Apps/DsmMac/package.sh` 退出0；临时启动器仅复用apple/.build依赖缓存并跳过更新，无工具链变更。Release、Hardened Runtime测试权限、签名、Sparkle实际`library loaded`、arm64及DMG校验通过；另行运行 `codesign --verify --deep --strict`、`file`、`hdiutil verify` 确认签名、架构与VALID。只有既有hdiutil弃用提示，最终32场景UI回归后产品源码未再改变。

独立产物 `apple/Apps/DsmMac/dist/photos-folder-cover-20260930/LanStash-1.0.11-arm64.dmg`，约19MB，版本1.0.11(21)、本机临时签名。包含目录封面和此前照片捏合、相似整理、幻灯片与下载累计改动；不含Finder本地磁盘挂载扩展。未自动安装、启动、覆盖旧包、正式发布或修改更新源。main@5684170及34个累计修改/未跟踪文件保留，无提交推送。一次性日志、合成截图、临时启动器和本轮专用构建目录移至废纸篓，保留所有dist和依赖缓存。

构建期间仅只读核对下一项封面选择器排序：名称/大小/类型/拍摄时间，固定当前目录及个人/共享路由；候选见photos-library-read.md，尚未将排序控件写入产品。上传重启恢复仍等待此前存储授权。真实NAS验证由用户完成，完整目标继续。


## 文件夹封面排序波次（2026-09-30，进行中）

前轮目录封面已完成468项回归、32场景和独立测试包，为实际进展。本轮保留34个累计修改，独占Photos目录排序领域、Repository、封面选图窗口及相关测试/资源/五端记录。官方静态新证据：排序操作先调用Folder.set_order v1，再按当前目录/排序重读；目录默认读取Folder.sort_by/sort_direction，缺失时取Setting.User.item_sort_by/sort_direction（默认takentime/asc）。子目录按filename及同一方向读取。必须保存并回读排序，不能只排已加载页；不执行真实NAS写请求。沿已授权契约扩展，不新增本地持久化/权限/依赖或其他端UI；上传队列重启恢复仍待原存储授权。


### 文件夹封面排序实现与独立复核

主流程已接入四字段/两方向菜单、保存目录偏好、严格回读及按序分页；每次进目录读取其已保存顺序，单字段缺失时沿用户默认设置。子目录按名称同方向，选中照片时菜单禁用、再次点选可取消，保存中避免同时切换目录或选择。加载编号隔离迟到页，关闭窗口不继续刷新。图库正好在同一目录时同步重排但不回时间线，保留选择ID；子目录排序不重排父目录，迟到确认不覆盖同编号相册。

共享查询folder新增带默认值的sort，保留旧构造和默认takentime/asc；当前Repository按实际字段请求，没有内存局部排序。新增目录读取重载、可选集合sort、用户默认设置解码和浏览排序命令，五端影响已同步，其他端UI不变。没有本地持久化、依赖、签名或权限配置变更。新写操作只按当前可查看目录开放（保存浏览偏好无需原件manage/download）；确认封面仍是原来的管理权限。静态观察不冒用历史NAS兼容版本，真实写入没有代测。

独立只读复核覆盖权限代次与路径身份、字段默认值和严格结果核对的区别、相同操作编号不重复写、分页方向一致、同编号跨空间与跨页面、保存时选图竞争。首次本地旧回归有1个模拟服务缺少folderSort而失败，补齐该服务的既有默认排序；新增断网测试最初假定提交失败会立即回读，改为显式检查首次缺字段回读仍pending、第二次明确字段回读confirmed，未降低断言。新增迟到排序确认不覆盖同编号相册回归通过。首次本地化扫描拒绝动态资源键前缀，已改为显式四字段资源映射，再次扫描通过。

最终运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：476项XCTest（293 Repository、131 Model、5转换、20事件、27外观）与6项本地化通过；本轮新增5 Repository、3 Model测试。资源检查Apple4484/Android2188/Windows3402，双语、参数、引用、硬编码通过；fixture验证3组/32引用，文档严格预检和git diff --check通过。

PENDING_USER_VALIDATION：在个人/共享测试文件夹打开更换封面，未选照片时切换名称/大小/类型/拍摄时间及升降序；核对第一页和后续页顺序一致、子目录按名称同方向，进入子目录再返回及关闭后重开沿已保存顺序。选中照片时不能切换排序，取消选择后恢复；图库当前同一目录同步排列，浏览位置不跳到最新照片。测试只有查看权限的目录、排序保存时断网/恢复与权限撤回，结果未知只核对不重复写；实际默认设置和不同套件版本交给用户验证。回传版本/空间/操作步骤/脱敏错误，不发送真实照片、地址、路径或凭据。

最新已确认剩余代码项为上传队列跨会话/重启恢复，继续等待此前持久化方案授权；本轮不是一次新的授权请求。完整网页目标保持进行中，真实NAS兼容和物理设备验收按用户要求后置。


### 排序最终界面验证

实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test封面排序菜单中英浅深色实际选择字段方向并保存固定目录|WorkspacePresentationTests/test目录封面选择器中英浅深色五种状态且回车只提交固定目标|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-sort-ui-final` 退出0：3项36场景通过。包含排序中英浅深色4场景（实际打开NSMenu、核对四字段、选择大小和降序、断言两次固定目标命令及最终分页顺序）、封面五状态20场景与集合12场景。查看最终英文浅色与中文深色排序后截图，标题、排序、网格、状态和底部操作无裁切；截图为菜单关闭后的页面，菜单本身靠实际项/点击断言，不冒充弹出菜单截图检查。最终单测/界面回归后冻结产品源码进入打包，真实NAS持久排序与物理设备行为仍未验证。


### 完整范围复核纠正（2026-09-30）

本轮打包期间重新比对官方动作绑定与当前源码，确认先前“只剩上传重启恢复”的清单不完整，不能据此结束完整网页对齐目标。官方handleRenameFolder个人/共享分别绑定Folder.rename动作；worker单选目录、打开名称输入框、rename v1(id,name)，响应folder.id/name更新目录树。删除worker用Folder.delete v1(id数组)；移动/复制官方动作保留selectedFolderId/folderArray和BackgroundTask.File。当前SynologyPhotosMutation只有createFolder/setFolderCover/setFolderSort，move/copy目标为照片数组，macOS目录卡片没有这些目录管理入口。以上是static与当前源码差异，尚未核全删除/搬移确认、目录树和最终结果校验，不可直接复制接口片段执行。还发现共享handleEditPermission绑定与主文件夹页排序入口，应列入后续菜单审计，不能把封面选择器排序当成所有文件夹页面控件齐全。

下一切片优先目录重命名，随后目录删除及移动/复制；相关共享目录权限/分享和主页面排序继续核对。上传重启恢复仍等待既有存储授权。未触发任何真实目录重命名、删除、搬移或权限修改；没有给候选写接口注册已验证兼容记录。构建期间未再修改产品源码。


### 文件夹排序独立测试包交付（2026-09-30）

实际运行 `PATH="/tmp/dsm-photos-sort-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-sort-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-sort-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时xcodebuild启动器仅复用apple/.build缓存、跳过更新，工具链不变；Release、Hardened Runtime测试权限、签名、Sparkle实际library loaded、arm64和DMG校验通过。独立运行codesign --verify --deep --strict、file与hdiutil verify，签名/架构/VALID通过；只有既有hdiutil弃用提示。最终UI验证至打包结束产品源码未修改。

产物 `apple/Apps/DsmMac/dist/photos-folder-sort-20260930/LanStash-1.0.11-arm64.dmg`，约19MB、1.0.11(21)、本机临时签名，包含目录封面排序及此前照片累计改动，不含Finder本地磁盘挂载扩展；未安装启动、覆盖旧包、发布或修改更新源。main@5684170和34个累计修改/未跟踪文件保留，无提交推送。临时日志、合成截图、临时启动器和本轮专用构建目录移至废纸篓，保留dist和依赖缓存。

后续按上节完整范围复核继续目录管理，不再沿用已纠正的“只剩上传恢复”表述；上传队列持久化仍待已有单独授权，真实NAS写入/物理设备测试由用户执行。


## 文件夹重命名与主页面排序波次（2026-09-30，本轮完成）

基线main@5684170、34个累计修改/未跟踪文件保留。本轮单一范围为Photos文件夹重命名契约、Repository、macOS卡片入口和主页面排序，及聚焦测试/双语/五端记录；不修改其他端UI、持久化、依赖、权限或应用标识。沿用户既有契约扩展授权，所有真实NAS写操作留给用户。

官方静态核对：个人/共享Browse.Folder.rename v1使用id标量与name，返回folder.id/name；名称非空、UTF-16长度≤255，不允许空白、开头/结尾点、@database/@eaDir/@tmp/@sharebin、#recycle/#snapshot以及斜杠/反斜杠/冒号。网页表单使用eir/eii/eio校验，eC3固定所选单目录。仅静态证据，不冒充真实写验证。原生沿现有管理权限、固定身份、操作编号去重和自动回读；保存后局部更新，不刷新到时间线。主页面复用封面窗口四字段/两方向菜单及已实现保存流程。


### 重命名与主页面排序验证、独立复核

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，退出0：484项XCTest（Repository298、Model134、转换5、预览事件20、外观27）和6项本地化通过。新增5 Repository与3 Model，覆盖名称/UTF-16规则、个人共享路由、重复编号不重写、未知回执只读恢复、根目录/权限/路径拒绝、精确结果确认、后代路径/选择保留、迟到结果不覆盖相册，以及根目录排序。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录重命名双语浅深色编辑并回车提交固定目录|WorkspacePresentationTests/test主文件夹页面双语浅深色根目录显示排序且无封面入口|WorkspacePresentationTests/test封面排序菜单中英浅深色实际选择字段方向并保存固定目录' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-rename-ui-final`，退出0：3项12场景通过。真实原生输入字段及回车固定目标、打开表单零写入、排序菜单实际选择字段/方向；主页面截图与状态检查不冒充其菜单像素审查。首轮同样通过，视觉复核后收紧重命名窗口至560×220、把主页面排序合并至空间选择栏，再全量重跑该UI集合通过。最终中文深色重命名和英文浅色主页面截图无裁切。
- `python3 tools/localization/check_localization.py`通过Apple4487/Android2188/Windows3402及双语/参数/引用/硬编码；`python3 tools/contract-validation/validate_fixtures.py`通过3组/32引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。

独立集成/只读对抗复核：新命令复用单一mutationInFlight、operationID与权限代次保护；已知失败不重放，回执成功仍需目录ID、完整新路径、已知parent和manage；回执未知仅只读核对。UI固定目标，不依赖变化中的所选照片；迟到确认不修改相册或其他空间，重命名期间进入后代目录时更新已加载路径、不全局刷新。沿实际API和权限开放，无人工实机开关；依赖、存储和其他端UI未改。

PENDING_USER_VALIDATION：个人与共享的专用目录右键重命名，检查名称、子目录和网页同步；检查无管理权、同名、加锁目录、断网恢复与另一客户端并发改名；在主页面变更字段/方向，跨页及返回重进核对。触控板双指捏合仍包含在累计实现中，物理操作由用户验收。本轮没有真实NAS写入或下载，也没有将构建/合成测试表述为实机通过。剩余：目录删除、目录移动/复制、共享目录权限/分享，以及待已有存储授权的上传重启恢复。


### 文件夹重命名独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-rename-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-rename-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-rename-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器仅复用apple/.build依赖缓存并跳过更新，不修改工具链。Release、arm64、Hardened Runtime专用测试权限、签名、Sparkle实际library loaded检查通过；独立codesign --verify --deep --strict、file及hdiutil verify（VALID）通过。只有既有hdiutil弃用提示，最终UI验证后产品源码未修改。

产物 `apple/Apps/DsmMac/dist/photos-folder-rename-20260930/LanStash-1.0.11-arm64.dmg`（19,658,863字节，约19MB），1.0.11(21)、本机临时签名，不包含Finder本地磁盘挂载扩展；含本轮重命名/主页面排序与此前照片累计实现。未安装、启动、覆盖旧包、正式发布或更改更新源。main@5684170b3ccf与34个累计修改/未跟踪文件保留，未提交推送。一次性日志、合成截图、临时启动器和本轮专用构建目录在进程结束后移入废纸篓，保留dist、依赖缓存和正式测试源码。

当前切片完成，但完整网页对齐仍进行中。下一切片为文件夹删除，随后目录移动/复制、共享目录权限/分享；上传跨会话恢复继续等待此前单独的存储授权。真实NAS写入和物理触控板验收由用户完成，未代测或宣称实机通过。


## 文件夹及混合选择删除波次（2026-09-30，本轮完成）

前轮重命名/主页面排序完成484项回归、12界面场景与独立包，为实际进展。main@5684170与34个累计文件保留。本轮独占Photos删除契约/Repository/macOS多选与确认、测试/资源/五端记录，不改其他端UI或持久化，不执行真实NAS删除。

本轮官方静态纠正：主界面HandleDelete→DeleteItemAndFolder使用Foto/FotoTeam.BackgroundTask.File.delete v1(item_id,folder_id)，照片和文件夹可混合选择；返回task_info.id，官方等对应任务完成通知后移除项目/目录。先前发现的Browse.Folder.delete helper不能当成当前主流程。删除确认使用总选择数，有回收站提示但不能保证用户NAS可恢复；原生不替用户变更回收站设置。

实现目标：同一父目录的多文件夹/混合照片选择、固定快照确认，逐个重新核对身份和管理权限；按任务完成及父目录完整回读/照片空回读自动确认，已知部分失败因缺逐目录结果不猜测删除目标，回执丢失不重复提交。目录删除本身会影响全部后代，确认框明确说明。不存在未经证据支持的“未找到”错误码映射；无法读取父目录或未知任务保持待核对。真实NAS副作用和恢复为PENDING_USER_VALIDATION。


### 文件夹混合删除实现与独立复核

macOS主目录中可选择文件夹及照片，已加载项目全选/取消、合计数量、目录勾选、固定目标确认已接入。工具栏以及选中目录/照片右键均走同一混选确认，不默默忽略目录。确认窗列出具体目标，提示全部后代受影响与恢复依赖NAS设置；选中目录时照片专用动作不应用于部分目标。普通照片原有删除路径不变。

独立集成与只读对抗复核覆盖：官方主流程是BackgroundTask.File而非此前Folder.delete helper；同父/同空间快照、完整路径/管理权、新鲜照片身份、共享manager与普通entry、全局未知写锁、operationID绑定/去重、预检权限代次变化。任务done且error/skip为0，加完整分页父目录和照片空回读才完成，缺父权限/错父ID/错任务ID/重复页/仍存在均不误报；部分失败没有逐目录结果，不能按目录不可见推断成功。回执丢失不猜任务、不重放。清理仅作用于原目录空间与已确认照片；同编号相册隔离，待核对期间进入已删目录退回父目录。没有实际NAS写入，也没有改变回收站或声称可恢复。

### 文件夹混合删除本地验证

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，最终退出0：497项XCTest（Repository307、Model138、转换5、事件20、外观27）和6项本地化通过。新增9 Repository与4 Model，覆盖混合数组/来源、完整分页、任务等待/读失败/回执丢失/去重、权限/身份拒绝、目录选择、局部更新与迟到导航处理。首轮2个旧功能枚举回归未开启已有deletionEnabled，加入新删除特性后预期不符；将“所有管理能力开放”场景与macOS组合根一致显式开启删除策略，并新增默认策略/缺实际API检查，未删除或降低原断言，最终全量聚焦集合重跑通过。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test文件夹删除确认双语浅深色空选择取消及混合目标固定|WorkspacePresentationTests/test文件夹主页面混合选择双语浅深色显示选择数量与目录勾选|WorkspacePresentationTests/test目录重命名双语浅深色编辑并回车提交固定目录' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-folder-delete-ui`，退出0：3项24场景通过。删除确认4状态×双语浅深色16场景、图库选择4场景、前轮重命名4场景；真实键盘确认/取消、空选择不提交、打开零写入和冻结快照验证。查看中文深色混选确认与英文浅色选择截图，警示、目标与按钮未裁切。后续仅补2项单测和合成服务删除状态，产品源码未再修改。
- 本地化扫描Apple4490/Android2188/Windows3402，双语/参数/引用/硬编码通过；fixture3组和私有文档引用32项通过；严格文档预检与git diff --check通过。实际命令为 `python3 tools/localization/check_localization.py`、`python3 tools/contract-validation/validate_fixtures.py`、`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`。

PENDING_USER_VALIDATION：使用可丢弃的个人/共享测试目录，分别单目录、多目录和照片混选删除；取消零写、确认后自动原地更新，目录内全部内容与相册引用变化以NAS实际结果为准。测试权限变化、锁定目录、断网、超过100个子目录、部分失败和另一客户端并发操作。回传版本/空间/脱敏错误，不回传真实资料。不能把上述合成测试当成NAS行为验证；没有执行真实删除。当前未完成目录移动复制、共享目录权限分享、多目录/混合下载、待存储授权的上传重启恢复。


### 文件夹混合删除独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-delete-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-delete-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-delete-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器仅复用apple/.build依赖缓存并skipPackageUpdates，不改工具链。Release、打包脚本签名/Designated Requirement、Hardened Runtime测试权限、Sparkle实际library loaded、arm64和hdiutil verify（VALID）通过；另以file核对产物arm64。只有既有hdiutil弃用提示。UI最终验证后产品源码未再修改，随后2项新增单测及合成服务状态补充通过完整497项回归。

产物 `apple/Apps/DsmMac/dist/photos-folder-delete-20260930/LanStash-1.0.11-arm64.dmg`，19,731,645字节（约19MB），版本1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展；包含本轮多文件夹/照片混合删除及此前累计功能。未安装、启动、覆盖旧包、正式发布或修改更新源。main@5684170b3ccf与34个累计修改/未跟踪文件保留，未提交推送。临时日志、合成截图、启动器及本轮构建目录在进程结束后移入废纸篓；保留正式测试源码、全部dist和依赖缓存。

本轮切片已完成，完整网页对齐仍继续。剩余已确认代码缺口：目录移动复制、共享目录权限分享、多目录/照片目录混选整批下载；上传队列跨会话恢复仍等待此前存储授权。下一切片继续目录移动复制，不能因可用构建或现有单目录ZIP而宣称整个Photos功能已对齐。真实NAS删除与恢复由用户验收，本轮未执行任何NAS写操作。


## 文件夹移动复制波次（2026-09-30，源码与合成验证完成）

基线main@5684170b3ccf、34个累计工作区文件与前轮497项回归/24界面场景/独立包保留。本轮单一范围为现有move/copy命令增量支持同父目录的文件夹及照片混选、固定目标选择、原地结果更新；独占对应Core/Network/macOS与测试、契约和五端文档。无其他端UI、工具链、持久化、权限变更，不执行真实NAS写入。

官方react_bundle.js静态证据：CopyToFolder/MoveToFolder读取selectedFolderIdSet与selectedItemIdSetIncludingSimilarChildren，调用同一BackgroundTask.File v1 copy/move，folder_id不再为空。源API随PERSONAL/TEAM，统一Foto.BackgroundTask.Info监控；move额外信息version=2、source_library以及可选source_folder_ids（目录视图父编号）。复制空间选择个人/共享均可；移动仅个人来源提供跨空间。选择器禁止当前父目录、所选目录自身和后代；确认目标需UPLOAD。任务total涉及目录内容，不能与顶层选择数强等。重复项暂沿用已交付skip语义；网页copy_move_default_action的全部设置选项仍须后续对齐。证据等级static，版本未知限制保留，真实NAS为PENDING_USER_VALIDATION。

共享命令在末尾新增默认空folders参数，已有构造源兼容，模式匹配须同步；无持久化迁移，回滚移除folders关联值及入口即可，既有照片移动复制保留。用户已授权共享契约扩展，不另设未验证禁用。


### 文件夹移动复制集成复核与验证

独立集成与只读对抗复核：复用已有move/copy而非平行接口；默认folders保持旧构造，全部关联值模式匹配同步。源身份/同父同空间/权限重新读取、个人共享方向、目标自身/后代/原位置判断、操作编号不可换目标、任务唯一id/目标owner/total/状态、回执丢失不重放、部分失败不猜结果均复核。目录总数不能按顶层数量上限判断；空目录允许total=0。同空间移动还核对原目录的新父编号；跨空间不假定编号不变。相同路径的不同空间不错误互斥。确认后只更新原列表，不移除同编号相册。

新增回归实际发现：核对期间进入目录后，完成逻辑先回到父目录，但内部refresh被isManaging拦住，仍残留旧目录内容。修复为仅供已结束目录变更使用的私有刷新入口，用户主动刷新仍遵守忙碌限制；文件夹删除也复用，并加强原删除断言检查实际父目录照片/空目录列表。没有把失败断言删掉。

- 最终实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，退出0：508项XCTest（Repository315、Model141、转换5、事件20、外观27）及6项本地化通过。新增8 Repository、3 Model；含空目录、600个后代任务计数、源权限变化、冲突路径、错父目录回读、跨空间、丢失回执和部分完成。早期507项中的1个新Model失败促成上述真实刷新修复，最终完整集合通过。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test文件夹移动复制双语浅深色固定混合目标且无效目录与读取失败不提交|WorkspacePresentationTests/test文件夹主页面混合选择双语浅深色显示选择数量与目录勾选|WorkspacePresentationTests/test文件夹删除确认双语浅深色空选择取消及混合目标固定' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-folder-transfer-ui`，退出0，3项36场景（移动/复制/原父目录/读取失败16、混选4、删除16）。真实键盘确认验证冻结目标，打开无写入，原位置和错误不提交。检查中文浅色/英文深色截图后将标题从“移动照片/复制照片”改为“移动到文件夹/复制到文件夹”，随后同脚本只选移动复制1项16场景再次通过并复核英文深色截图，无裁切。
- `python3 tools/localization/check_localization.py` 通过：Apple4490/Android2188/Windows3402，双语参数、引用和硬编码合格。`python3 tools/contract-validation/validate_fixtures.py` 通过3组fixture/32项私有文档引用；`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。

真实NAS移动/复制、权限改变、同名冲突及恢复仍为PENDING_USER_VALIDATION，未执行真实文件操作；操作步骤与影响见photos-management.md本轮记录。本轮不新增人工禁用，目标权限与确认保留。后续优先共享目录权限/分享、多目录/照片混选下载；拖放移动和重复项设置细节尚未对齐，上传重启恢复仍等已有存储授权问题答复。


### 文件夹移动复制独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-transfer-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-transfer-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-transfer-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器只复用apple/.build依赖缓存并skipPackageUpdates，不改变工具链。Release、签名/Designated Requirement、Hardened Runtime测试权限、Sparkle实际library loaded、arm64及hdiutil verify（VALID）通过；最终产物为LanStash Test.app，另以file检查其实际主程序。只有既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-folder-transfer-20260930/LanStash-1.0.11-arm64.dmg`，19,761,979字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。508项XCTest、6项本地化与3项36场景通过，标题调整后移动复制16场景又通过；详情与真实命令见本轮账本。不自动安装或启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf和34个累计工作区文件保留，未提交/推送。临时日志、合成截图、启动器、本轮构建目录在进程结束后移入废纸篓，保留dist与依赖缓存。真实NAS写入仍由用户验收。


## 共享目录权限与分享波次（2026-09-30，进行中）

前轮实际完成文件夹移动复制、508项回归/36场景和独立包。当前main@5684170b3ccf、34个累计文件保留。本轮单一范围为共享目录权限读取/设置及成员、链接保护与子目录影响；沿已授权公开契约增量，不改其他端UI/存储/工具链，不执行真实NAS权限写入。先完成真实现状读取与可视化，再接入写入和最终结果核对；读取入口不是保存功能完成的证据。

只读官方脚本新证据：FolderPermission v1 get_config/get_folder_link/set_config/update；读取Folder.get v2 additional.sharing_info、parent.shared、set_to_subfolder，缺链接调用get_folder_link(folder_id)。update参数经hK转为snake_case：folder_id/privacy_type/set_to_subfolder，可选password与扁平成员permission[{id,type,role,action}]。公开模式management/private/public-view/public-download，成员view/download/upload/manage；不提供public-upload。仅共享空间前两层目录有入口；第二层父目录shared=false时不能独立编辑，只有第一层显示应用到所有子文件夹。官方递减权限另有确认。尚需完整核对批量应用后的回读与密码变化；本波次不猜测继承结果。证据static，DSM/build/Photos版本仍未知，真实NAS验收后置。


### 共享目录权限读取：集成复核与验证

本轮已完成读取服务、领域快照和macOS右键/当前目录入口，成员列表及角色、链接复制、密码标志、父级限制与失败重试可用。没有保存入口，因为写入/回读流程仍待实现，不是未实测开关。新方法默认unsupported保持现有适配器兼容；其他端UI、持久化、工具链未改。

独立集成与只读对抗复核：固定shared与目录id/path/parent，限制官方前两层和Photos完整访问角色；回读父编号/路径与shared，不猜继承。未知已共享模式和坏链接拒绝；成员缺失/无法解析保留未知，不当空名单；同编号用户与群组、数字与字符串身份分别保留。权限代次变化拒绝迟到结果；快照摘要带profile和父状态，原始sharing_info不进入领域层。新读取未调用update/set_config/set_shared，现有相册候选读取的个人参数保持false。compatibility.json仅累计能力/接口记录，无新增版本兼容结论。

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，最终退出0：513项XCTest（Repository319、Model142、预览转换5、预览事件20、外观27）及6项本地化通过。新增4 Repository与1 Model，覆盖共享无个人空间、前两层权限、错误/缺失字段、父状态摘要、固定目标、成员候选路由及打开零写。初次编译发现currentSortFolder为tuple与AppError属性名错误，均修正；后续测试因新模拟FolderPermission未在版本表中定义而强解包崩溃，改为独立添加共享专用能力，最终重跑完整集合通过。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享目录权限查看双语浅深色成员空未知父目录限制及错误均无写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-folder-permissions-ui`，退出0：1项20场景，正常/空成员/未知成员/父限制/错误×双语浅深色。核对固定目标与无写入；中文浅色正常、英文深色父限制截图无裁切。加载状态有独立ProgressView；未将这些合成截图当成NAS验收。
- 实际运行 `python3 tools/localization/check_localization.py`：Apple4498/Android2188/Windows3402，双语/参数/引用/硬编码通过；`python3 tools/contract-validation/validate_fixtures.py`：3组fixture/32项引用通过；`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check`通过。

PENDING_USER_VALIDATION：共享空间前两层目录中打开“文件夹权限”，与网页核对访问范围、成员角色、链接和密码标志；测试父目录仅完整访问、断网重试及当前账号权限变化。回传Photos/DSM版本、目录层级与脱敏错误，不回传真实链接、成员资料或凭据。本轮没有真实NAS写入，观察仍static，不能提升为behavior-verified。触控板捏合的累计代码与回归保留，物理手势由用户验收。

下一切片：共享目录权限保存/成员调整/密码/子目录应用；沿同一mutation去重和最终结果回读，不能把已有true密码标志当作回执丢失时新密码成功，不能用顶层回读证明所有后代。其后多目录和混合归档下载、拖放移动与重复项设置；上传跨会话恢复继续等待此前存储授权答复。完整对齐目标保持进行中。


### 共享目录权限读取独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-folder-permissions-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-folder-permissions-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-folder-permissions-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器只复用apple/.build缓存并skipPackageUpdates，不修改工具链。Release、签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64和DMG VALID检查通过；另以file确认LanStash Test.app/Contents/MacOS/LanStash为arm64。仅既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-folder-permissions-20260930/LanStash-1.0.11-arm64.dmg`，19,820,085字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。包含此前累计照片功能及本轮共享目录权限查看；保存/成员调整/密码修改/子目录应用尚未实现，不是人工禁用。513项XCTest、6项本地化、1项20个界面场景通过，实际命令和初次失败修复见对齐账本。不自动安装/启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf和34个累计文件保留，未提交推送。

所有本轮进程结束后，临时测试日志、合成截图、启动器及本轮独立构建目录移入唯一废纸篓目录；保留dist、正式测试与依赖缓存。Chrome控制台已清空并关闭，没有保存原始脚本、HAR或真实NAS响应。完整对齐继续，下一切片为权限保存；后续仍有多目录/混合下载、拖放/重复项设置以及待存储授权的上传重启恢复。真实NAS与物理触控板验收由用户执行。


## 共享目录权限保存波次（2026-09-30，进行中）

前轮完成只读权限与513项回归、20界面场景和独立包，属于实际进展。当前保留main@5684170b3ccf与34个累计文件；本轮独占Photos Core/Network/macOS对应保存、测试、双语资源和五端说明，不改其他端界面或存储。沿已授权契约增量加入目录权限mutation，复用统一去重与自动只读核对。覆盖四种访问范围、成员增删/角色、保留/修改/移除密码和应用子目录默认选项。父目录限制与真实权限继续遵守，不增加未实测禁用。真实NAS权限写入由用户验收。

证据见photos-management.md中官方FolderPermission.update/set_config静态发现。更新成员使用扁平id/type/role/action；密码通过现有HTTPS传输，不回退HTTP。并发快照不一致先拒绝写入；回执丢失不重放。对子目录应用需成功回执与当前目录回读，不将其描述为每个后代逐项实测；密码替换需成功回执和保护标志。配置默认值保存单独核对，失败与主要权限更新区分。


### 共享目录权限保存：集成复核与本地验证

源码闭环完成：共享目录查看窗口扩展为访问范围、成员增删/角色、密码保留/修改/移除、首层子目录应用及原生确认；用户确认的完整命令固定目录和原状态。调用现有submitMutation、operationID去重、自动只读核对；不刷新图库或改变所在空间。支持条件只按共享管理角色、父目录限制和实际API，不加未实测开关。默认子目录选项保存失败时单独说明权限已保存，不使用含糊的“部分项目未完成”。未知成员不能被当空名单覆盖，仍可保留原名单修改其他选项。

独立集成与只读对抗复核：新共享能力不误列个人空间；全量原快照与新鲜状态比较，profile绑定的摘要、目录/父级/角色检查，新增成员必须来自共享候选且保留数字/字符串和用户/群组身份。确认文本说明访问扩缩及覆盖子目录；密码不读取旧值、不输出日志、只经现有强制HTTPS。目录成员为扁平字段，不复用相册嵌套member；旧未知角色不静默转换。update和set_config分阶段，回执成功加回读匹配才确认，默认配置失败单独partial；明确首写权限拒绝rejected。重复编号不能重复写，丢失回执不能据旧password=true或顶层状态确认后代；保持pendingReview并只读复查。源码未新增日志/持久化/第三方依赖，其他端UI未修改。官方菜单静态复核确认编辑处于共享管理分支，普通目录manage角色无该入口；管理员分享全局设置差异仍交用户验收，不编造is_admin字段。

- 实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，最终退出0：524项XCTest（Repository328、Model144、转换5、事件20、外观27）及6项本地化通过。新增9 Repository、2 Model；覆盖扁平成员、管理角色/候选、四种模式、密码/子目录丢回执、明确拒绝、默认配置部分成功、父限制/并发变化、原列表保持和自动6次只读核对。新增共享能力后个人allCases断言显式排除folderSharing，并独立检查共享能力/缺API/entry；未降低原个人功能断言。初次编译出现Result初始化参数顺序错误，修正后通过，后续最终完整集合通过。
- 实际运行 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test目录权限保存双语浅深色确认取消和父目录限制|WorkspacePresentationTests/test共享目录权限查看双语浅深色成员空未知父目录限制及错误均无写入' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-permission-save-ui`，最终退出0：2项36界面场景（原5状态×双语浅深色20，保存/编辑/取消/父限制×双语浅深色16），另保存/编辑/取消的12确认快照。真实菜单选择访问范围、移除密码、成员上传角色后确认，断言提交的固定值；打开/字段编辑/取消零写。新增编辑测试起初错误假定Picker为NSPopUpButton，改用与已有测试一致的原生菜单交互后全部通过，未删断言。复核中文浅色编辑界面无裁切；原生确认离屏快照的按钮材质/文字绘制不完整，实际NSButton标题与点击动作已验证，不冒充实机视觉通过。
- `python3 tools/localization/check_localization.py`通过Apple4504/Android2188/Windows3402双语、参数、引用与硬编码扫描；`python3 tools/contract-validation/validate_fixtures.py`通过3组fixture/32文档引用；`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。UI之后只新增明确拒绝单测，产品源码没有进一步变化。

PENDING_USER_VALIDATION：使用可丢弃共享目录和测试账号，与网页对比四范围、用户/群组增删和四角色、密码保护变化、首层应用后代与默认记忆、第二层父限制；检查旧链接/新密码、成员真实访问、非管理员全局分享限制、并发修改、断网与拒绝。应用子目录的自动确认基于NAS成功回执和当前目录回读，没有逐个后代行为验证；未知结果不会重放。只回传版本/层级/脱敏失败，不回传密码、分享链接、成员真实资料。没有NAS写操作，证据仍static，兼容矩阵无新verifications。

当前源码剩余：多目录和照片/目录混合整批归档下载、拖放移动与重复项处理设置。上传重启恢复仍等待此前持久化授权。完整Photos对齐目标保持进行中，本轮权限保存完成不等于全部功能已对齐。


### 共享目录权限保存独立测试包（2026-09-30）

实际执行 `PATH="/tmp/dsm-photos-permission-save-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-permission-save-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-permission-save-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。启动器只复用apple/.build依赖缓存并skipPackageUpdates，不改变工具链。Release、签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64及hdiutil verify（VALID）均通过，另以file确认主程序架构。仅既有hdiutil弃用提示。

产物 `apple/Apps/DsmMac/dist/photos-permission-save-20260930/LanStash-1.0.11-arm64.dmg`，19,956,616字节，1.0.11(21)，本机临时签名，不含Finder本地磁盘挂载扩展。包含本轮共享目录权限编辑、成员/密码/子目录选项、确认保存和自动核对，以及此前累计照片改动。524项XCTest、6项本地化、2项36界面场景通过，另有12确认快照；真实命令、失败修复和离屏绘制限制见对齐账本。不自动安装/启动、不覆盖旧包、不改更新源、不正式发布。main@5684170b3ccf与34个累计工作区文件保留，未提交推送。

本轮进程结束后，临时日志、合成截图、启动器及独立构建目录移入唯一废纸篓目录，保留dist、依赖缓存和正式测试。Chrome控制台已清空关闭；没有原始HAR或真实NAS响应落盘，没有执行真实NAS写入。权限保存源码切片完成，NAS成员真实访问/密码/后代应用为PENDING_USER_VALIDATION，完整功能对齐仍进行中。当前归档目标源码仍只有album(id)与folder(id,space)，下一切片多目录/照片混选下载；拖放/重复项设置及待持久化授权的上传重启恢复仍未完成。


## 2026-09-30 多目录与照片混选下载：验证与交付记录

### 实际修改与集成复核

沿现有SynologyPhotoArchiveTarget、downloadArchive与PhotoArchiveDownloadMenu增加selection分支；同级目录快照与照片原空间/父目录固定。Repository先逐目录核对路径、父编号和下载权限，再按100项读取照片身份，全部匹配后单次POST，省略空item_id。不展开已加载子目录、不截断所选照片。UI三个入口为选择工具栏、已选目录右键和已选照片右键；未选项目保持单项语义。独立只读集成复核检查共享枚举全部使用点、API参数、授权代次、ZIP暂存/取消和明确保存后的替换路径，未引入接口平行实现或静默部分下载。

中英文新增photos.download.selection。其他平台只有契约/计划影响同步，没有修改其他端代码、依赖、持久化或应用标识。34个累计改动文件保留，未add/提交/推送/发布；浏览器只查官方静态资源，已清除临时输出并关闭控制台。

### 已运行验证

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`：530 XCTest通过（Repository332、Model146、Converter5、Events20、Appearance27）及6个Swift Testing本地化测试通过。新增4个Repository/2个Model测试覆盖混选与纯多目录、个人/共享、拒绝与过期身份、超过100照片、授权撤回、取消/失败不覆盖、重复触发阻止和固定选择不刷新。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test整册与文件夹下载菜单中英浅深色且打开不下载|WorkspacePresentationTests/test文件夹混选下载工具栏中英浅深色保留整组选项|WorkspacePresentationTests/test整集合下载页面中英浅深色与相册只读权限布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-mixed-download-ui`：3测试通过，共44个中英文/浅深色合成场景（16菜单、16混选/未选/空页、12既有整集合页面）。实际打开原生菜单核对两个格式后关闭，零下载请求；查看英文深色与中文浅色混选截图，工具栏与选择数完整。
- `python3 tools/localization/check_localization.py`：Apple4505/Android2188/Windows3402，双语、占位符与硬编码扫描通过。
- `python3 tools/contract-validation/validate_fixtures.py`：3组fixture/32引用通过。
- `python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

执行中修正两个验证问题并重新运行完整聚焦组：新增撤权测试的Task意外捕获XCTestCase，将快照在Task外建立；PhotoUploadServiceStub声明全能力却未实现folderSort，导致目录fixture加载失败，补齐合成读取并保留原断言。最终无失败。已有weak变量和skip-update弃用警告未修改无关源码。

### 用户验收与剩余工作

PENDING_USER_VALIDATION：在个人/共享空间同级选择两个有后代照片的文件夹，分别试原件、压缩JPEG和混选同级照片；核对ZIP完整内容、真实NAS权限拒绝、下载取消与失败后原文件完整、当前目录/选择不变。没有执行真实NAS下载、系统保存面板物理操作或其他平台构建；static和合成通过不等于NAS兼容结论。反馈所选项目数量、格式、脱敏错误，不发送私有路径或凭据。

当前剩余：网页拖放移动、重复项处理设置细节，以及待另行持久化授权的上传队列跨会话/重启恢复。总体对齐仍未完成。该切片入口已开放，保留实际NAS权限与身份保护。


### 独立测试包

通过既有package.sh流程，使用临时xcodebuild包装只指定已有apple/.build依赖缓存并跳过更新，环境为LANSTASH_NON_INTERACTIVE=1、LANSTASH_RUN_AFTER_PACKAGE=0、LANSTASH_BUILD_TYPE=Release，独立build/dist子目录photos-mixed-download-20260930。无新增依赖或工程工具链改动。

产物：`apple/Apps/DsmMac/dist/photos-mixed-download-20260930/LanStash-1.0.11-arm64.dmg`，19,969,162字节；LanStash Test.app，1.0.11(21)，arm64，本机临时签名。Release成功、组件进入产物、codesign及Designated Requirement通过，保留Hardened Runtime并按既定测试权限实际加载Sparkle（library loaded），DMG校验VALID。仅hdiutil命令弃用警告，不影响结果。未自动安装/启动，不覆盖旧测试包，不属于正式发布；沿既定本地测试包流程移除不可用的本地磁盘挂载扩展。

一次性测试日志、UI截图、工具链包装和本轮中间build目录在结束后移到本机废纸篓；保留独立dist交付物及共享依赖缓存。完整目标仍active，下一切片为拖放移动与重复项处理设置。


## 2026-09-30 拖放移动与重复项设置波次：基线

前轮分类为progress：混选归档源码、测试与测试包已交付。当前main@5684170b3ccf保留34个累计改动文件，当前任务独占Photos Model/View/Panel及相关测试和资源，其他模块不修改。

官方静态证据：统一移动worker支持itemIds与folderIds，拖动单目录与当前选择调用既有移动任务；策略来自getCopyMoveDefaultDuplicateHandling。设置界面uploadDefaultAction提供ignore/rename，copyMoveDefaultAction提供skip/overwrite，移动/复制请求通过action传入。仅只读官方脚本，没有真实NAS移动或设置写入。

第一实施切片：文件夹页照片/目录拖动，已选项拖动携带整个选择快照；落到文件夹卡片、上级或路径导航后预选该目标并显示既有移动确认表单。自移动、原父目录、后代目录、无权限/忙碌状态不接受；拖动内容只含当前Model一次性随机标识，不导出照片路径/会话，不接受外部伪造选择。复用既有权限、重复提交、后台结果核对与局部刷新，不添加新API或存储。

第二切片仍保留完整目标：默认重复项设置、ignore/rename与skip/overwrite执行及结果核对；不能以第一切片完成宣布整体对齐。源码和合成验证先行，真实NAS与物理拖放PENDING_USER_VALIDATION。iPhone/iPad目录管理仍为后续；Android/Windows仅记录影响。


## 2026-09-30 文件夹拖放移动：交付验证

实际修改仅本轮Photos Model/View/Panel及Model/UI测试和记录；34个累计改动文件保留，不提交/推送。新增PhotoDragSelection保存当前generation和固定选择，PhotoDragItemProvider仅发布ownProcess随机UUID；DropDelegate使用move/forbidden反馈，接收时核对Model、token、来源代次和目标，不直接写入。已选拖整组、未选拖单项，保持原勾选状态。目标范围为可见子目录、上级按钮和路径导航；路径按钮还可直接回到已访问的上级。PhotoManagementSheet.transferPath预选并固定目标路径，表单可继续更换目录，确认才复用submitMutation；真实写前权限和身份由Repository再次验证。

独立只读集成复核：核对无外部照片路径/会话导出、跨Model随机标识不能命中、刷新使旧快照失效、一次落下消耗标识、取消不提交、同级混选不遗漏、目标禁区沿既有acceptsTransferDestination。没有绕过权限或新建平行移动实现；未修改后台任务契约或覆盖策略，不把静态候选设置计入完成。

### 实际运行

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`：535项XCTest通过（Repository332、Model151、Converter5、Events20、Appearance27）及6项Swift Testing本地化通过。新增5项拖动快照/单项/过期及外来目标/上级导航/NSItemProvider数据回归。首次Model组146项也通过；新增测试后只运行上述聚焦组。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test拖放预选目标双语浅深色固定混选确认取消与无效路径|WorkspacePresentationTests/test文件夹移动复制双语浅深色固定混合目标且无效目录与读取失败不提交|WorkspacePresentationTests/test文件夹混选下载工具栏中英浅深色保留整组选项' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-drag-ui`：3测试通过，48场景（12预选表单+4导航+16既有移动复制+16混选下载）。原生Return/Escape检查固定目标确认/取消，错误路径不提交；已查看英文深色确认与中文浅色路径导航截图。
- `python3 tools/localization/check_localization.py`：4505/2188/3402，双语及硬编码检查通过；无新用户可见资源键。
- `python3 tools/contract-validation/validate_fixtures.py`：3组/32引用通过；`git diff --check`通过。

PENDING_USER_VALIDATION：同目录多选照片和文件夹，拖到未选目录；确认数量/目标后移动，核对只移动选定内容且图库位置保留。进入子目录后拖照片至上级按钮及路径中的更上层，核对目标正确；拖回原目录或自身应拒绝。取消确认窗口应无变化。真实鼠标/触控板命中与高亮、NAS权限/任务结果未运行；可回传脱敏错误和选择数量，不发私有文件或凭据。功能未因未实机验收关闭。

当前剩余是重复项默认设置及完整策略执行、待授权的上传队列重启恢复。只读发现已记录候选字段，但尚未编码；目标保持active，不能宣布完整网页对齐。


### 拖放移动独立测试包与清理

既有package.sh执行Release/arm64，LANSTASH_NON_INTERACTIVE=1、LANSTASH_RUN_AFTER_PACKAGE=0、LANSTASH_BUILD_TYPE=Release；独立build/dist目录photos-drag-move-20260930，临时xcodebuild包装只指定已有apple/.build依赖缓存并跳过更新。产物`apple/Apps/DsmMac/dist/photos-drag-move-20260930/LanStash-1.0.11-arm64.dmg`，20,018,786字节，1.0.11(21)。Release成功、codesign/Designated Requirement通过，保留Hardened Runtime、专用测试权限及Sparkle实际加载library loaded，DMG校验VALID；PlugIns为空，按既定临时签名流程移除本地磁盘挂载扩展。仅hdiutil弃用警告，无打包失败。未安装/启动/正式发布，不覆盖旧包。

临时测试/界面/打包日志、48张合成截图、工具链包装和本轮中间build目录均移至本机废纸篓；独立dist包和apple/.build缓存保留。最终文档严格检查与diff空白检查通过。未触碰其他端源码，无git add/提交/推送。总体目标继续active，下一切片为重复项默认设置及真实策略执行。


## 2026-09-30 重复项默认设置与执行波次（源码与测试包完成）

上一轮为progress：拖放移动源码、535项回归和测试包完成。本轮基线main@5684170b3ccf，保留34个累计文件；独占Photos共享领域/Repository/Model/Panel/View、相关测试与资源，其他模块不改。

官方static补证：Foto.Setting.User版本表get:1/set:1；设置差异直接传upload_default_action(ignore/rename)和copy_move_default_action(skip/overwrite)，保存后get回读。后台移动复制action与上传duplicate沿用户确认快照固定。目标是设置编辑/自动核对与实际策略执行完整闭环，不仅提供设置外观。新增策略参数保留旧调用rename/skip默认值；macOS读取真实默认并允许单次调整。上传忽略与实际新上传分开，覆盖计数与任务完成/身份核对并行。无本地持久化变化或真实NAS写入。

用户已授权共享契约扩展，五端影响与兼容记录随实现同步。真实NAS同名处理细节和回执差异PENDING_USER_VALIDATION，入口不增加未验证禁用；保留权限、确认、去重与结果复查。上传队列重启恢复仍是独立待授权存储切片。

### 重复项默认设置与执行：源码和自动化结果

实际变更：共享Core新增当前用户重复项设置/读取/保存，upload与uploadToAlbum增加默认rename的策略，move/copy增加默认skip策略；结果skippedCount默认0。Repository接入Setting.User get/set v1，严格枚举、原快照比较、仅差异字段、去重与最终回读；上传ignore保留返回照片身份/真实提供者，与新上传数量分开。macOS增加工具栏设置面板、单次上传/传输规则、覆盖确认，队列固定确认值并显示已忽略；调整目录上传旧“另存”提示，双语同步。没有新增本地持久化、工具链、依赖、权限或其他端UI。

实际运行 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`：最终544项XCTest通过（Repository339、Model153、Converter5、Events20、Appearance27），6项Swift Testing本地化通过。新增7个Repository/2个Model测试，包含个人空间关闭仍可读取保存设置、过期快照/未知字段/无变更拒绝、权限拒绝不重发、丢回执只回读、ignore大小不同/错名/错目录/错策略、相册原提供者、overwrite计数越界/不完整、队列固定规则与忽略后继续加入相册。纯照片完成数量需与选择数量相等；目录仍按已建立的递归任务语义及目标/身份回读，不能推测初始总数就是最终成功数。

过程中首次测试编译暴露漏改的nil关联值模式，随后修正；新增ignore测试在重复调用待核对命令时未提供第二次合成读取响应，补足响应后通过。独立复核曾将纯照片的固定数量断言误扩至目录任务，既有目录回归失败；收窄到纯照片后原断言全部通过，没有降低或删除既有测试。

UI实际命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test重复项设置双语浅深色读取保存取消与失败|WorkspacePresentationTests/test移动覆盖规则双语浅深色确认前不提交且取消无写入|WorkspacePresentationTests/test拖放预选目标双语浅深色固定混选确认取消与无效路径|WorkspacePresentationTests/test目录上传确认浅深色布局|WorkspacePresentationTests/test多文件上传确认与队列浅深色布局' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-duplicates-ui`。首次4项通过、设置项失败，原因是SwiftUI Picker不是NSPopUpButton；测试改为实际打开原生菜单、选择选项后按Return及确认/取消。仅重跑设置项通过，覆盖普通保存/默认覆盖保存/取消覆盖/读取/失败的中英文浅深色；目录提示修正后只重跑目录上传项亦通过。五项测试均获得通过结果，合计78张合成快照（含编辑和确认中间状态），没有执行NAS写入。

已查看设置页、英文深色覆盖表单及中文目录上传截图，布局和按钮可见。原生系统alert的离屏快照有既有透明内容绘制限制，不能以快照判定全部文字视觉通过；原生按钮实际确认/取消与无提前写入断言通过。物理触控板、真实NAS和系统最终显示仍由用户验收。

静态门禁：`python3 tools/localization/check_localization.py`通过（Apple4518、Android2188、Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过（3组、33项私有API文档引用）；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。契约索引新增photos-duplicate-settings，保留static与空verifications，五端影响与回滚记录同步；未运行iOS/Android/Windows构建。

独立集成与只读写操作复核：用户设置属于统一Foto当前用户，不因个人图库关闭改路由；必须已有Photos会话，实际v1 JSON能力、权限代次、提交互斥与完整快照保留。旧调用默认策略保持；单次选择不偷偷修改全局默认，队列后续操作不重新读新默认。覆盖确认绑定冻结命令，错误/越界状态不报告完成；未知上传或设置不重放。忽略保留真实已有项目，加入相册失败仅重试成员操作。保留已有所有累计改动，没有git add/提交/推送。

PENDING_USER_VALIDATION与操作步骤详见photos-management.md本轮记录：真实NAS默认记忆、ignore/rename、个人/共享及相册上传、skip/overwrite和目录合并计数、覆盖后的编号、网络中断与并发编辑。用户要求开放入口已遵循，未实测标签不用于人工禁用。覆盖使用可丢弃合成资料，本轮无真实NAS写入或下载。

当前已确认剩余代码工作为上传队列跨会话/重启恢复，仍等待此前本地持久化授权；当前队列不承诺退出后的恢复。默认重复项设置和策略执行已完成源码与合成验证，不再列为未实现。总目标保持进行中，不将用户实机待验表述为通过，也不将本轮测试包等同正式云端发布。


### 重复项处理最终测试包

实际执行 `PATH="/tmp/dsm-photos-duplicates-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-duplicate-settings-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-duplicate-settings-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时包装仅指定现有apple/.build依赖缓存与skipPackageUpdates，没有升级工具链或依赖。

产物`apple/Apps/DsmMac/dist/photos-duplicate-settings-20260930/LanStash-1.0.11-arm64.dmg`，20,135,178字节，1.0.11(21)，arm64。包含此前累计照片功能与本轮重复项默认设置、ignore/rename上传、skip/overwrite移动复制；无人工未验证禁用。Release、签名/Designated Requirement、专用本地测试Hardened Runtime权限、Sparkle实际library loaded与DMG VALID检查通过；额外plist/字节数/主程序file检查确认版本和arm64，PlugIns为空。只有既有hdiutil弃用提示。

未自动安装或启动，不覆盖旧包、不改更新源、不执行正式发布；本机临时签名不包含Finder本地磁盘挂载扩展。544项XCTest、6项本地化和5项合成UI测试的最终通过结果与限制见上述记录。真实NAS写行为、物理手势仍待用户验收，未提升版本兼容等级。全部34个累计工作区改动保留，未git add/提交/推送。整体目标继续，剩余上传队列跨重启恢复需要此前待确认的本地持久化授权。

本轮所有执行进程结束后，8项临时日志/合成截图/包装工具/独立构建目录已移入唯一废纸篓目录；保留dist交付物、正式测试与apple/.build依赖缓存。Chrome控制台已清空关闭。最终文档严格检查与diff空白检查通过。

## 2026-09-30 完整范围再审计与相册排序波次

前一轮为progress：重复项源码、验证与测试包完成。当前工作区仍34项累计变更。按完整网页目标再审查官方静态定义和当前源码，发现此前“只剩上传重启恢复”清单不完整：Album.set_order v1、相册列表get/set_album_list_order v2和get/set_album_list_display v3已有官方用户入口，而当前Repository相册内容固定takentime/desc，macOS只有目录排序菜单。该证据推翻此前唯一剩余项结论，必须继续；真实NAS验收由用户负责不能当作代码缺口。

当前切片为相册内照片排序：四字段（filename、filesize、item_type、takentime）/双方向，读取相册当前sort_by/sort_direction、缺省按官方takentime/asc，选项变更调用统一Foto.Album.set_order，再回读并重新分页当前相册。排序只影响浏览，不改变照片原件、月份页或共享权限。现有album查询增加带默认值排序，旧调用保留desc行为；macOS实际读NAS顺序，其他端不新增UI/存储。允许无个人空间的相册访问者按实际接口/权限排序，不假定必须所有者。

另列剩余：相册列表排序和显示范围、分享相册列表各自排序；官方RotateFolderItems/RotateAlbumItems仅是本地动作线索，尚未证明NAS旋转写契约或可见入口，继续核对，不编造实现或明确缺口。上传重启恢复的持久化授权仍待答复。此轮不改持久化，沿已授权公开契约增量，并同步五端影响。


## 2026-09-30 相册内照片排序实现与集成复核

- 实际修改：DsmCore相册query/排序服务与mutation、DsmNetwork相册读取/保存/回读、Mac Model/图库排序入口/共用菜单标识，新增5项Repository和3项Model测试、1项原生UI测试；已有相册、上传、移动和目录排序行为保留。复用现有中英排序资源，没有硬编码显示文案。
- 独立复核结论：相册页使用平铺items，不会被日期分组重排；四字段与两方向传给NAS全部分页；全局相册能力在home关闭时不丢失；需要实际Album v1和v4；不把查看权扩展为原件写权限。原始快照变化不写，未知仅回读，保存核对必须包含明确sort字段。既有相册移动后刷新曾按默认query等值判断，本轮改为匹配相册id并保留sort，避免非默认排序下跳过刷新。上传完成沿当前query回读而非本地日期排序。
- 首次新增用例运行500项，其中2项失败：新上传用例误认为上传仍保留勾选（现有enqueue明确清空选择），现校验既有退出选择模式行为；保存核对缺字段时抛错，修为保持pendingReview，只有明确回读目标顺序后确认。没有削弱既有断言或跳过测试。
- 实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`：552项XCTest通过（Repository344、Model156、Converter5、Events20、Appearance27），另6项Swift Testing本地化通过。
- 实际命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相册排序双语浅深色原生菜单保存并显示当前相册|WorkspacePresentationTests/test封面排序菜单中英浅深色实际选择字段方向并保存固定目录' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-album-sort-ui`：2项通过，16张合成截图。真实NSMenu选择字段与方向、保存固定相册及当前页、原目录菜单回归通过；人工查看中文深色与英文浅色相册页，顶部对齐、菜单及空内容居中正常。本轮没有新增页面，仅复用既有图库状态分支，未把合成UI等同NAS行为验收。
- `python3 tools/localization/check_localization.py`：Apple4518/Android2188/Windows3402，双语/参数/硬编码扫描通过；`python3 tools/contract-validation/validate_fixtures.py`：3组fixture/33项引用通过；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。
- 当前剩余：相册列表显示及排序、分享列表独立排序；上传重启恢复按先前持久化变更方案待授权。旋转候选还需真实静态调用链证据，不能当成已确认功能。总体目标继续，未宣称完整对齐。
- PENDING_USER_VALIDATION：真实NAS读取/保存/重新打开/分页、个人空间关闭的分享相册、权限撤回、断网后只核对、上传后排序；前置为有查看权的可丢弃相册。预期保留当前相册、不改照片内容、不重复保存。只回传脱敏版本、步骤和错误，不需要真实照片/链接/凭据。五端影响已同步，未修改其他端UI、持久化、权限或依赖。


### 2026-09-30 相册内照片排序独立测试包

实际执行 `PATH="/tmp/dsm-photos-album-sort-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-album-sort-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-album-sort-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时启动器仅指定现有apple/.build依赖缓存与skipPackageUpdates，未升级工具链或依赖。Release、实际arm64、临时签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际`library loaded`与DMG校验VALID通过；仅既有hdiutil弃用提示。额外检查成品含photos.albumSort标识。

产物`apple/Apps/DsmMac/dist/photos-album-sort-20260930/LanStash-1.0.11-arm64.dmg`，20,169,527字节，1.0.11(21)，本机临时签名，沿既有独立localtest应用标识。没有自动安装/启动，不覆盖旧包，无本地磁盘挂载扩展（PlugIns=0）。含本轮相册内照片排序、保持当前排序的上传/搬移后刷新，以及此前累计照片与捏合缩放改动。552项XCTest、6项本地化、2项原生合成UI测试通过（16张截图）；详细命令与首次失败修复见对齐账本。NAS真实排序/权限/断网及物理触控板仍由用户验收，不冒充行为验证。

main@5684170b3ccf及34个累计工作区文件保留，没有git add、提交、推送或正式发布。完整对齐目标继续：相册列表显示/排序和分享列表独立排序仍待实施；上传重启恢复仍待之前本地存储方案授权。前轮“只剩上传恢复”的结论已由本轮官方静态再审计纠正。没有真实NAS写入、下载或用户数据导出。

本轮所有测试/构建进程结束后，6项临时日志、合成截图目录、启动器和独立构建目录移入唯一废纸篓目录；保留dist成品、正式测试和依赖缓存。控制台已清空并关闭，无原始脚本/HAR/真实NAS响应留存。


## 2026-09-30 相册列表与分享列表排序波次（开始）

前轮为progress：相册内容排序源码、552+6测试、2项UI测试和独立DMG完成。当前基线仍main@5684170b3ccf、34项累计文件改动，原改动保留。当前任务独占Photos领域、Repository、Mac Model/View/排序菜单、双语Photos资源与测试；其他端仅影响记录。先以官方静态资源补全album_display_type分类映射、相册/分享各自排序字段与版本，确认后沿已授权契约扩展接入。用户结果为打开相册列表读取已有偏好、切换显示范围和排序后正确分页、保存后重新打开一致；不修改原件、不扩大共享权限。安全级别为用户浏览偏好写入，保留快照冲突、去重、最终回读；实际NAS由用户验收。非目标为上传本地持久化（仍待先前方案授权）、未确认的旋转候选、其他端UI。


## 2026-09-30 相册列表与分享排序集成复核

- 相册首页全部/我的范围分别映射normal_share_with_me/normal，并非网格/列表布局；首页5个排序字段，两类分享4个字段，各自升降序；照片收集不混入相册偏好。新服务读取各自现状，保存仅写原范围或显示字段，原值变化拒绝覆盖，home关闭仍按实际能力开放。
- 当前任务修改Core类型/默认服务/命令、Network参数和自动回读、Mac Model/View/共用原生菜单、9个中英资源键及相关测试；其他端仅兼容影响文档。没有改变本地存储、依赖、系统权限或其他端UI。
- 独立集成与只读对抗复核：字段白名单按scope区分，非法请求不发出；偏好未知/缺失不猜成功，失败可继续旧列表浏览；列表分页固定display/sort，旧偏好读取及旧页迟到时检查generation，不覆盖新导航。保存独立设置，不调整照片内容或分享权限；未知只核对，operationID复用不会重新写。渲染检查后分享排序改放到分享分类同一行右侧，避免多出空工具行。
- 实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`，560项XCTest通过（Repository349、Model159、Converter5、Events20、Appearance27），另6项本地化通过。新增5项Repository测试含多字段/双向/三范围循环，新增3项Model测试覆盖分页、范围隔离、失败浏览、迟到读取。
- 本地化首次检查发现动态拼接资源键无法静态核验，改为枚举显式映射9个完整资源键，未新增假资源或放宽扫描。最终`python3 tools/localization/check_localization.py`通过：Apple4527/Android2188/Windows3402；`python3 tools/contract-validation/validate_fixtures.py`通过3组/33引用；`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。
- PENDING_USER_VALIDATION：普通账号/个人空间关闭时切换全部/我的相册、相册列表与两类分享各字段和双向、跨页与重开、断网及权限撤回。预期三个列表互不覆盖，照片及分享权限不变，没有重复保存。只回传脱敏版本和步骤/失败文案，不提供真实相册、链接或凭据。
- 未完成：上传队列跨重启恢复的本地持久化方案仍待授权；旋转候选及完整官方菜单还需后续证据复核，不能将只有action字符串的线索写成已确认缺口，更不能据当前测试宣布完整对齐。


UI最终命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test相册列表范围与分享排序中英浅深色原生菜单|WorkspacePresentationTests/test相册排序双语浅深色原生菜单保存并显示当前相册' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-list-sort-ui`，2项通过，28张合成截图。NSMenu实际切换显示范围、字段、方向和分享选项，断言命令和状态；旧相册内容排序回归通过。人工查看完整英文浅色相册页和中文深色分享页，布局与顶部菜单正常；独立透明菜单宿主的离屏快照部分为空，不能据此宣称菜单像素验收，通过实际原生菜单事件与完整图库渲染验证。


构建期间只读复核补充：网页预览旋转确认是保存到NAS的实际操作（rotate_action=counter_clockwise，个人/共享Item.set），不是死代码。当前Mac没有相应保存流程，故下一切片为预览旋转保存，需补齐版本、允许媒体、方向快照与未知结果不重放。前文“旋转只是候选”的描述为补证前状态，现以本段为准；本轮测试包未包含该能力。原件字节是否改写未验证，不作推断。


### 2026-09-30 相册列表与分享排序独立测试包

实际执行 `PATH="/tmp/dsm-photos-list-sort-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-list-sort-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-list-sort-20260930" bash apple/Apps/DsmMac/package.sh`，退出0。临时包装仅指定既有apple/.build依赖缓存与skipPackageUpdates，无依赖或工具链升级。Release、临时签名及Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、arm64与DMG checksum VALID通过；额外检查成品含photos.albumList.sort。仅既有hdiutil弃用提示。

产物`apple/Apps/DsmMac/dist/photos-list-sort-20260930/LanStash-1.0.11-arm64.dmg`，20,226,522字节，1.0.11(21)，沿既有localtest标识的本机临时签名，不含本地磁盘挂载扩展（PlugIns=0）。含全部/我的相册范围、相册列表5字段及两类分享列表4字段/双向、三个独立偏好保存/回读、固定分页与迟到响应保护，以及此前累计照片改动。560项XCTest、6项本地化、2项原生UI测试（28张合成截图）通过，截图限制见对齐账本。实际NAS偏好及权限由用户验收，未提升版本证据等级。

不自动安装/启动、不覆盖旧包、不改更新源、不正式发布；main@5684170b3ccf、34项累计工作区文件保留，没有git add/提交/推送。完整目标继续：网页预览旋转保存已补证为下一代码缺口，上传跨重启恢复仍待先前持久化方案授权；不因本轮通过就宣称完整对齐。没有执行真实NAS写入/下载或导出用户数据。

所有本轮执行进程结束后，6项临时日志/合成截图目录/启动器/独立构建目录移入唯一废纸篓目录。保留dist成品、正式测试和依赖缓存。浏览器控制台已清空并关闭，无原始脚本、HAR、NAS响应或真实用户资料留存。


### 2026-09-30 预览旋转保存波次开始

基线 main@5684170b3ccf，保留34项累计改动。本轮独占Photos Core/Repository/Model/View及聚焦测试、双语资源、契约和五端影响说明；目标为预览逆时针旋转并保存，原图库位置保持不变。已确认官方static调用链为个人/共享Item.set rotate_action=counter_clockwise；继续核对接口版本、媒体限制和方向回读。当前未实施、未验证真实NAS。

属于非幂等元数据写入，沿现有权限/快照/操作编号/自动回读框架，不能重发写请求确认结果。用户已授权契约扩展和开放测试入口，真实设备验证后置，不增加“未验证”禁用。非目标：新增旋转方向、批量旋转、其他端界面、上传队列持久化、实际NAS写入。源码完成后运行聚焦自动化和macOS构建，单独记录PENDING_USER_VALIDATION。


### 旋转保存：实现、审查与自动化

本轮新增rotatePhoto/rotation，详情原始方向及官方逆时针镜像映射；macOS工具栏“向左旋转并保存”，按钮在真实能力/权限/媒体范围内开放。Repository先验证快照与目录管理权，固定单张Item.set v2；重复operationID只核对，未决结果拦住新旋转；回读方向和宽高必须匹配，失败回执不伪报成功。结果局部替换图库照片并重新读取当前预览，动态照片在已知方向与原方向不一致时隐藏播放。沿原有管理状态显示，不重复叠加提示。

独立只读集成审查：检查权限变化、相册提供者与原件权限、跨空间路由、镜像方向、重复操作、断网未知结果、关闭预览后的迟到响应、缩略图刷新和用户月份/选择保持。未新增白名单限制、存储、依赖或其他端UI。发现重复管理提示后在打包完成前停止该次构建，移除重复提示并复跑界面测试；之后重新构建最终包。

实际命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 最终567项XCTest通过（Repository353、Model162、Converter5、Events20、Appearance27）及6项Swift Testing本地化通过。新增4项Repository覆盖8种方向×两空间、丢回执/旧方向/错误尺寸、无权限/旧快照、支持媒体和失败回执；3项Model覆盖原月份/选择/图像刷新、关闭后不重开/未知不重发、实况方向播放。首次新断言按普通字符串比较JSON编码字段导致16次失败，仅修正新断言为实际JSON编码，不改请求或降低既有断言。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片旋转预览中英浅深色保存状态和原位置保持' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-rotation-ui`：1项、8张合成截图；检查中英浅深色预览和保存后更新，调用同一Model动作，未模拟真实触控板或NAS旋转。人工查看中文深色初始与英文浅色保存图像，工具栏及横竖尺寸更新正常。

本地化4528 Apple/2188 Android/3402 Windows，fixture 3组/33项私有引用，严格文档预检与git diff --check通过。

PENDING_USER_VALIDATION：具有目录管理权限的个人/共享测试照片，在2020.03打开预览，双指缩放后点向左旋转；预期保存后图像和缩略图更新、关闭仍在原月份，连续四次回到原方向。补测带镜像EXIF、实况、短暂断网/权限撤回，未知结果不重复写入；不能由静态和合成结果推断真实NAS原件字节不变。失败只需回传空间/媒体格式/方向现象和脱敏提示。

剩余已确认缺口：上传队列跨重启恢复，前述本地持久化方案仍待用户明确授权。官方完整功能清单复核尚未结束，不据本切片完成宣称完全对齐。

最终界面复跑一度触发SwiftUI表达式类型检查超时；原因是新增条件直接引用Model私有命令，改为既有公开pendingMutationID状态，保留统一只读核对动作。该失败没有修改测试断言或其他功能，修复后重新执行同一UI命令。


### 2026-09-30 旋转保存独立测试包交付

最终实际执行 `PATH="/tmp/dsm-photos-rotation-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-rotation-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-rotation-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。先前因修正重复提示主动终止一次未完成构建，未交付中间包；本次产物含最终界面修正。临时启动器仅复用apple/.build依赖缓存，无工具链/依赖变更。

产物`apple/Apps/DsmMac/dist/photos-rotation-20260930/LanStash-1.0.11-arm64.dmg`，20,276,556字节，1.0.11(21)，沿既有localtest标识与本机临时签名。Release、严格签名和Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64与DMG checksum VALID通过，二进制含photos.media.rotate。无本地磁盘挂载扩展（PlugIns=0），没有安装、启动、正式发布或覆盖旧包。仅hdiutil弃用提示。

567项XCTest、6项本地化、最终1项UI测试及8张合成截图通过；最后UI测试发生在统一状态栏修正之后。本轮实际NAS操作为零，静态证据未升级为行为验证，具体用户验收见照片对齐账本。保留main@5684170b3ccf及34项累计工作区文件，没有git add/提交/推送。目标继续：上传跨重启恢复待已说明的持久化授权，全量官方功能审计未结束。

全部执行进程结束后，6项临时日志/截图目录/启动器/独立构建目录移入唯一废纸篓目录；保留dist成品、正式测试及依赖缓存。Chrome控制台已清空并关闭，未落盘原始脚本或真实NAS资料。


### 2026-09-30 网页入口全量清单复核开始

上一轮为progress：旋转保存实现、567项回归、6项本地化、1项UI与独立包已完成。本轮基线仍main@5684170b3ccf、34项累计文件。先只读提取官方静态菜单动作、导航与设置入口，与现行Core/Repository/Model/View对照，建立可追溯的功能清单；不把历史“只剩一项”当完成证据，不执行真实NAS写入。新增实现前另行确定具体文件范围与契约。上传持久化仍等待已说明方案授权。


### 2026-09-30 主题显示管理与剩余功能复核

官方静态动作绑定确认：主题封面set_cover、纠正分类hide_item、显示隐藏set_visibility是三个独立功能，当前均缺失。本轮先实施显示隐藏：个人/共享固定空间，显示隐藏项的完整分页列表、名称筛选和批量选择、确认保存、自动回读，结果只局部更新主题卡片，不删除照片或刷新时间线。当前任务独占现有Photos Core/Repository/Model/View/Panel、双语资源与聚焦测试；其他端只同步计划。已获API增量扩展授权，无新增持久化、依赖或权限。回滚移除新增conceptVisibility服务/命令及入口，不改已有数据格式。

新确认的设置缺口：网页个人设置含时间线按日/月、默认照片排序、日期/时间格式、预览/幻灯片信息显示、自动生成预览、个人识别开关；管理设置含全局/共享识别开关、允许普通用户分享、访客照片信息、JPEG转换与格式排除、共享空间启停和根目录分享策略。这些有表单绑定与Setting.User/Admin/TeamSpace保存链，尚需逐字段语义/权限复核与实现。应用已有外观/语言设置作为原生替代单独评估，不把全部网页字段机械计为缺失。重复项处理、相册/目录排序已有实现。下载转换缓存管理也有官方设置入口线索，后续核对，不冒充已实现。

待办顺序：本轮主题显示隐藏 → 主题封面/误分类移除 → 照片显示与识别设置 → 共享/管理设置及缓存管理。上传跨重启恢复仍待前述本地存储方案授权。以上不以真实NAS尚未测试为由增加禁用；保留实际权限、能力和结果核对。


### 主题显示管理集成复核

新增Concept v2完整隐藏项列表、个人/共享路由、独立状态与命令、自动结果核对，以及主题首页工具栏/卡片右键入口。管理窗口复用现有原生表单，新增8个中英资源键；保留人物管理的独立类型与语义。未新增人工待实测开关，主题操作不照搬人物旧表单的一百项上限；实际权限和接口能力仍需满足。

独立只读复核覆盖：固定空间/编号与旧状态、重复选择、共享非管理权限、能力缺失、跨页隐藏项、缺字段/目标/断网结果不猜成功、未知结果只回读不重发、页面切换时局部更新不污染人物列表。发现隐藏主题封面未进入已有授权缩略图缓存后，主动停止未完成打包并补齐同空间缓存；新增读取隐藏项缩略图与个人/共享路径断言。没有实际NAS写入或下载。

第一次新增断网测试把“写回执丢失后只返回待核对”误当作已执行第一次回读，导致后续空列表冲突。按既有Repository语义修正测试顺序：未决 → 一次不确定回读 → 目标状态回读；保留不重发断言，不改生产错误处理。契约检查首次发现端点标识缺少稳定声明，已补充。界面人工检查发现主题表单复用了人物按钮词，改为专用双语显示/隐藏主题并重新绘制。

PENDING_USER_VALIDATION：个人及具有管理权的共享空间，进入相册→主题，点击眼睛按钮或卡片右键，批量隐藏后搜索并恢复；预期主题卡片局部更新，原照片仍在图库，隐藏项封面正常读取。补测断网自动核对与权限撤回，不能重复写入；物理触控板捏合沿前轮交付继续由用户测试。本轮静态/合成证据不等于NAS行为验证。失败回传脱敏版本、空间、步骤和提示即可。


最终自动化：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，574项XCTest（Repository358、Model164、Converter5、Events20、Appearance27）及6项本地化通过，含最后缩略图缓存修正。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test主题显示隐藏中英浅深色正常空错误和搜索确认|WorkspacePresentationTests/test人物显示搜索空状态保留选择并回车只隐藏目标' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-concepts-ui`退出0，2项原生UI测试、17张合成截图。包括主题中英浅深色正常/空/错误/搜索为空、确认后固定目标隐藏，以及共用人物表单回归；人工复看中文深色正常与英文浅色错误状态。最后缓存修正不改变表单布局。

`python3 tools/localization/check_localization.py`通过（Apple4536/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组/34项引用；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。实际NAS功能与物理手势未验证。


### 2026-09-30 主题显示管理独立测试包

最终实际命令：`PATH="/tmp/dsm-photos-concepts-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-concepts-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-concepts-20260930" bash apple/Apps/DsmMac/package.sh`退出0。启动器仅指定既有apple/.build依赖缓存和skipPackageUpdates，无工具链/依赖升级。前一次未完成构建因修正隐藏主题封面主动终止，最终包已重建。

Release arm64、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded和DMG checksum VALID通过；二进制含photos.concepts.visibility。成品20,298,719字节，1.0.11(21)，沿既有localtest独立标识，PlugIns=0。没有自动安装/启动、没有覆盖旧包或执行正式发布。仅hdiutil弃用提示。574项相关XCTest、6项本地化、2项原生UI测试均通过；真实NAS仍待用户验证。

工作区保留main@5684170b3ccf、34项累计文件，未git add/提交/推送。当前波次修改既有Photos Core/Repository/Model/View/Panel、两种语言资源、Repository/Model/UI测试及端点/五端影响记录；其他端源代码保持已有状态。完整对齐目标继续，下一切片主题封面和误分类移除，设置与缓存管理清单已补充。

所有本轮构建/测试进程结束后，将6项临时日志、合成截图目录、启动器和独立构建目录移入唯一废纸篓目录。保留dist成品、正式测试和依赖缓存；Chrome控制台已清空关闭，没有原始网页脚本或真实NAS资料落盘。


### 2026-09-30 主题封面与误分类移除波次开始

上一轮为progress：主题显示隐藏、574项回归/6项本地化/2项UI及独立包完成。当前基线main@5684170b3ccf，34项累计工作区文件，保留已有改动。本轮目标为主题内单张设置封面和批量移出误分类，固定个人/共享空间，保留原件与当前浏览位置。沿既有Photos Core/Repository/Model/View/Panel与测试、双语资源实现；其他端只同步计划。已获公开契约增量授权，无新增存储、依赖和权限，回滚移除本轮命令/入口即可。先只读核对官方set_cover/hide_item和回读/阈值语义；真实NAS操作继续后置用户验收，不增加未验证禁用。


### 主题封面与误分类移除：集成审查与验证

主题内单选照片可设为封面，多选可移出主题；预览菜单也提供单张入口。个人/共享路由按固定空间，读取主题快照与全部分页成员后提交；移出只改变分类，自动复查成员消失、数量一致和原件身份仍在，不使用图库删除结果。封面通过重新读取主题封面编号核对。未知结果只继续读取，不重发写入；部分完成只移除已确认项目。分类卡片、当前月份与预览局部更新，不刷新至最新照片。

独立只读集成与对抗复核覆盖旧快照、非成员、无权限、跨空间、重复提交、断网回执、错误封面、原件被删除、主题缺失、数量矛盾及跨页漏项。审查发现主题详情中的结果可能把分类卡片插进照片列表，已限制卡片更新仅在分类首页，并加入模型和UI断言。没有新增人工待实测门禁、依赖、持久化或其他端UI；五端契约影响已同步。真实NAS写入和下载为零。

实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，582项XCTest（Repository364、Model166、Converter5、Events20、Appearance27）及6项Swift Testing本地化通过。本轮新增6项Repository与2项Model测试，包含501项跨分页成员、个人/共享、完整/部分完成、迟到结果与月份位置保持。

实际命令：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test主题封面和误分类移出双语浅深色确认与错误恢复|WorkspacePresentationTests/test主题显示隐藏中英浅深色正常空错误和搜索确认' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-concept-management-ui`退出0，2项原生UI测试、28张合成截图（12张本轮表单、16张显示隐藏回归）。实际回车确认并断言目标/结果/月分组/没有分类卡片混入；人工查看中文深色移出与英文浅色封面窗口，标题、说明、文件名及底部按钮正常。

`python3 tools/localization/check_localization.py`通过（Apple4541/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组/34项私有引用；`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。当前证据为static和合成自动化，不提升NAS行为验证等级。

PENDING_USER_VALIDATION：在具备管理权的个人/共享主题内选择照片设封面，关闭重开检查封面；批量移出并在图库核对原件仍在，当前月份不跳转；补测低于显示阈值、全部移出、实况/连拍封面、短暂断网和权限撤回。主题整个消失或返回缺字段时保留待核对，不猜成功、不重复写入。失败回传空间、脱敏版本、操作步骤、可见提示与位置变化即可。物理触控板捏合沿此前实现由用户验收。


### 2026-09-30 主题封面与误分类移除独立测试包

实际命令 `PATH="/tmp/dsm-photos-concept-management-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-concept-management-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-concept-management-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅指定既有apple/.build依赖缓存与skipPackageUpdates，无工具链或依赖变更。

成品`apple/Apps/DsmMac/dist/photos-concept-management-20260930/LanStash-1.0.11-arm64.dmg`，20,350,835字节，1.0.11(21)，沿既有localtest标识。Release arm64、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded及DMG checksum VALID通过；额外检查二进制含photos.concepts.cover，PlugIns=0。只有既有hdiutil弃用提示。没有自动安装/启动、覆盖旧包或正式发布，本机临时签名不含本地磁盘挂载扩展。

582项XCTest、6项本地化、2项原生UI测试/28张合成截图通过；本轮源码包含主题封面及误分类移除、双语表单与自动局部回读，继续保留此前捏合缩放等累计改动。真实NAS写入/下载为零，静态和合成证据不代替真实设备行为。main@5684170b3ccf、34项累计工作区文件保留，没有git add/提交/推送。完整目标继续，下一切片为照片显示与识别设置；共享管理与缓存管理仍待完成，上传跨重启恢复仍待既有存储方案授权。

全部本轮测试与构建进程结束后，6项临时日志、合成截图目录、启动器和独立构建目录移入唯一废纸篓目录，保留dist成品、正式测试与依赖缓存。Chrome控制台已清空关闭，没有原始脚本、HAR或真实NAS数据落盘。


### 2026-09-30 照片个人设置波次开始

上一轮为progress：主题封面/误分类移除、582项回归、6项本地化、2项UI与独立包已交付。本轮基线仍main@5684170b3ccf、34项累计改动，先只读核对网页Setting.User字段及保存/应用调用链，按证据选定完整个人设置切片。当前任务独占Photos Core/Repository/Model/View/Panel、双语资源、相关测试和契约记录；其他端仅同步计划。不新增依赖或本地持久化，无真实NAS写入。


### 显示设置：实现、独立复核与自动化

本轮完整接入显示表单六项：日/月分组、九种日期格式、12/24小时、默认照片排序字段/方向、预览与幻灯片底部信息。顶部齿轮改为照片设置菜单，保留重复项设置入口；新增13个双语键。访问结果增量可选偏好，既有服务/构造兼容，缺失不阻断浏览；表单必须读取明确值才允许保存。按已授权契约扩展，不新增本地持久化、依赖或权限，不修改其他端UI。

独立只读复核：冻结原快照和差量保存，不覆盖主题/识别/重复项其他字段；个人空间关闭仍可按登录Photos能力管理个人显示偏好；回执丢失只读核对，旧值/缺字段/未知枚举不能误判成功。新默认排序更新Repository目录缺省，目录/相册显式排序保持原契约。macOS保留底层按日分页，将已加载照片按月展示，保存不清空照片、选择与月份；时间线依旧按日期排列。预览信息与详情栏分开，视频排除，幻灯片信息叠加不挤压图像。日期格式公历年yyyy与月份MM正确转换，避免周所属年错误。

首次新增测试缺少DsmLocalization导入造成编译失败，已补导入。随后1项新断言误把分页代次要求为不变；现有executeMutation必须增加代次丢弃旧请求，故改为核对分页offset、照片、月份、选择及读取次数不变，保留原并发保护，未降低既有断言。最终实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：587项XCTest（Repository367、Model168、Converter5、Events20、Appearance27）及6项Swift Testing本地化通过。

最终UI命令`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片显示设置中英浅深色读取保存和错误|WorkspacePresentationTests/test照片显示偏好在预览和幻灯片显示底部信息' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-display-ui`退出0，2项UI测试、28张合成截图（12张表单、16张预览/幻灯片）；覆盖中英浅深色正常/错误/修改后表单，原生菜单切月份、切信息开关、回车提交并断言固定命令与模型结果。预览/幻灯片分别覆盖信息开关，使用合成照片。人工查看中文深色表单、英文浅色错误及幻灯片信息显示，布局正常；未模拟物理手势或NAS设置行为。

`python3 tools/localization/check_localization.py`通过（Apple4554/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组/35项引用；严格文档预检和git diff --check通过。真实NAS为PENDING_USER_VALIDATION，步骤见photos-display-settings记录：切换六项、与网页/重新打开同步、旧月份和目录排序、断网/并发冲突；信息显示在本机并不证明NAS设置已实测。

剩余：个人识别与自动生成预览、共享/全局识别及分享管理设置、下载转换缓存管理；上传跨重启恢复仍待此前存储方案授权。完整网页菜单/设置审计继续，不能据本轮完成宣称完全对齐。


### 2026-09-30 照片显示设置独立测试包

实际命令`PATH="/tmp/dsm-photos-display-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-display-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-display-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅使用现有apple/.build依赖缓存与skipPackageUpdates，无依赖或工具链升级。

成品`apple/Apps/DsmMac/dist/photos-display-20260930/LanStash-1.0.11-arm64.dmg`，20,417,000字节，1.0.11(21)，沿既有独立localtest标识。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded及DMG checksum VALID通过；额外检查二进制含photos.display.title，PlugIns=0。只有既有hdiutil弃用提示。没有自动安装/启动、覆盖旧包或正式发布；本机临时签名不含本地磁盘挂载扩展。

含本轮六项显示设置和此前累计照片改动，587项XCTest、6项本地化、2项UI/28张合成截图通过，命令与限制见照片对齐账本。真实NAS写入/下载为零，static不升级为行为验证。main@5684170b3ccf及34项累计文件保留，没有git add/提交/推送；完整对齐继续，剩余个人识别/自动预览、共享管理及缓存设置，上传跨重启恢复仍待此前存储方案授权。

所有本轮执行进程已结束；6项临时日志、合成截图目录、启动器与独立构建目录移入唯一废纸篓目录，保留dist测试包、正式测试和依赖缓存。浏览器控制台清空关闭，没有原始网页脚本或真实NAS数据落盘。


### 2026-09-30 个人识别与自动预览设置波次开始

上一轮为progress：六项显示设置、587项回归/6项本地化/2项UI及独立包交付。本轮基线main@5684170b3ccf，保留34项累计改动；独占Photos Core/Repository/Model/View/Panel、相关测试、双语资源与契约影响记录。先核对个人识别与自动生成预览的官方条件和触发链，再形成完整可用切片；不新增存储、依赖或其他端UI，真实NAS写入后置用户。


### 2026-09-30 个人识别设置：实现与独立复核

本轮新增个人空间人物、主题、相似照片识别设置；顶部齿轮进入原生表单，支持中英浅深色、读取失败重试、关闭与取消。按用户授权扩展服务契约，其他端仅同步影响记录，不修改其界面或存储。实际全局开关和个人空间决定可编辑项，不增加“未实测”人工禁用。只提交个人User设置的变化字段，不写Admin或TeamSpace。

独立只读复核：保存前重新读取User/Admin原快照，字段缺失、旧值变化或权限条件变化均不覆盖；同操作编号不重复提交，回执丢失只读核对。完整目标值及条件一致才确认。确认后只更新个人分类能力；关闭正在浏览分类返回相册首页，时间线保留月份、照片、分页与选择，普通相册不额外读取分类。等待能力结果期间检查代次和空间，避免迟到结果覆盖新页面。

实际命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：593项XCTest（Repository371、Model170、Converter5、Events20、Appearance27）及6项Swift Testing本地化通过。本轮新增4项Repository与2项Model测试，覆盖三开关双向保存、单字段差量、权限/缺字段/冲突拒绝、丢回执不重放、个人与共享隔离、旧月份保持和当前分类退出。

实际命令 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test个人照片识别中英浅深色可编辑受限空与错误' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-recognition-ui` 退出0，1项原生UI测试、24张合成截图。覆盖中英浅深色正常、管理员关闭、个人空间关闭、无已知字段和读取失败；实际点击人物/主题开关后回车保存，断言固定目标命令，受限条件点击不能写入。人工检查中文深色及英文浅色表单和修改状态，布局正常。物理设备手势不在这项合成测试范围。

本地化检查最初发现动态拼接资源键无法静态验证，已改为显式枚举映射；最终 `python3 tools/localization/check_localization.py` 通过（Apple4562/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py` 通过3组/36项私有引用。无真实NAS写入或下载，证据等级仍为static及合成测试。

PENDING_USER_VALIDATION：打开照片设置→个人照片识别，分别开关三项，重新打开并与网页核对；在历史月份保存应保留位置和选择，在相应分类保存关闭应返回相册首页，共享分类不受影响。补测管理员禁用、个人空间关闭、断网、网页同时修改；仅回传脱敏版本、步骤、提示及分类变化。具体字段、回滚和五端影响见photos-recognition-settings记录。

明确剩余：自动生成预览的完整触发流程、共享/全局识别及分享管理设置、下载转换缓存管理；上传队列跨重启恢复仍待此前存储方案授权。网页默认排序修改的额外确认在本轮静态审计中发现，后续审计继续核对原生交互是否需要补齐。尚未完成全菜单审计，不能将当前清单宣称为全部缺口。


### 2026-09-30 个人照片识别独立测试包

实际命令 `PATH="/tmp/dsm-photos-recognition-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-recognition-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-recognition-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时启动器仅指定既有apple/.build依赖缓存和skipPackageUpdates，无依赖或工具链变更。

成品 `apple/Apps/DsmMac/dist/photos-recognition-20260930/LanStash-1.0.11-arm64.dmg`，20,510,902字节，1.0.11(21)，沿既有localtest标识。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded和DMG checksum VALID通过；额外检查主程序包含photos.recognition.title，PlugIns=0。打包仅有既有hdiutil弃用提示；测试命令另有skip-update弃用提示。未自动安装/启动，未覆盖旧包或正式发布；临时签名不含本地磁盘挂载扩展。

593项XCTest、6项本地化及1项原生UI/24张合成截图通过，本地化完整性/硬编码扫描、3组fixture/36项引用、严格文档预检和git diff --check通过。实际命令、关键决策及PENDING_USER_VALIDATION步骤见照片对齐账本与photos-recognition-settings端点。真实NAS写入/下载为零，静态和合成证据不代替行为验证。

main@5684170b3ccf和34项累计工作区文件保留，没有git add/提交/推送。完整对齐继续，下一切片为自动生成预览完整流程；共享管理/全局设置、转换缓存仍未完成，上传跨重启恢复待此前持久化方案授权。

全部本轮测试和构建进程结束后，6项临时日志、合成截图目录、临时启动器与独立构建目录已移入唯一废纸篓目录；保留dist成品、正式自动化测试和依赖缓存。Chrome控制台此前已清空关闭，无原始网页资源或真实NAS数据落盘。


### 2026-09-30 自动预览触发流程波次开始

上一轮为progress：个人识别设置、593项回归及独立包已完成。本轮基线main@5684170b3ccf、34项累计改动；先核对官方自动预览选择、触发、取消及去重，复用已有转换/上传实现。独占Photos相关Core/Repository/Model/View/Panel和测试/资源/契约记录，无其他端界面、持久化或依赖修改。真实NAS写入仍交给用户，发现阶段只读。


### 2026-09-30 自动预览候选：源码、复核与验证

本轮完成必要的只读基础：Core新增SynologyPhotoAutomaticPreviewTask（profile/space/unitID独立身份、原始类型、缩略图/视频需求）与实际转换能力输入；Serving提供默认明确不支持的增量方法。Repository按官方HEVC/VC1/视频能力映射preset与type，读取当前候选批次，不猜分页、不把单元编号当图库项目编号。个人空间访问与共享management检查独立；没有实际NAS写入、下载或用户可见入口改动。

独立只读复核：代码只调用ConvertedFile.list_convert_needed v3；不会调用set_regenerating、set_broken、download或upload，未生成后台任务。字段缺失、重复身份、非法编号/标志明确失败，不转换成空队列；没有HEVC/视频能力时不发候选请求。取消和重新授权后丢弃迟到结果。布尔或0/1为客户端接受范围，实际NAS编码仍未验证；原始类型保留，不按文件名猜测。现有手动重建不变。

实际命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test自动预览'` 退出0，5项新增测试通过，包含8组空间/能力组合、权限拒绝、接口缺失、八种异常数据及取消/重授权屏障。最终命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0，598项XCTest（Repository376、Model170、Converter5、Events20、Appearance27）及6项本地化通过，含当前macOS Swift Package编译。

`python3 tools/contract-validation/validate_fixtures.py` 通过3组/37项引用；`python3 tools/codex/check_documentation.py --strict-release` 和 `git diff --check` 通过。本轮没有用户可见文案增量，没有重复运行原生窗口截图或制作新的Release安装包，不能把Swift Package编译表述为本轮Xcode Release构建。最近可用包仍为个人识别波次，不包含此基础增量。已同步五端影响，未修改其他端UI。

完整自动预览仍未完成：单元原件读取与结果身份核对、自动缩略图/视频执行、真实编解码能力判定、设置与后台调度、可见项优先及恢复都必须继续。视频桥接最终请求参数尚未补全，不能臆造。PENDING_USER_VALIDATION的前置条件、步骤、脱敏回传与回滚见photos-automatic-preview记录；不将未实现工作混记为只差用户实测。其他剩余功能及上传持久化授权状态保持。

工作区继续main@5684170b3ccf、34项累计改动，没有git add/提交/推送；上一轮为progress，本轮同样形成源码与验证进展，完整目标保持active。

本轮测试均已结束，2份临时测试日志已移入唯一废纸篓目录；正式测试与依赖缓存保留。浏览器控制台已清空关闭，未留下原始网页脚本或NAS数据。


### 2026-09-30 自动预览执行波次开始

上一轮为progress：只读候选与598项回归完成。本轮基线仍main@5684170b3ccf、34项累计文件；继续独占Photos转换/Repository/Core及相关测试和契约，先补证单元读取与视频上传/结果核对，再接入执行。不改变其他端UI、存储或依赖，不真实读写用户照片。


### 2026-09-30 自动预览原件与视频转换：复核和验证

本轮新增单元原件读取服务及本机H.264/AAC视频导出，具体范围、官方static证据及限制见photos-automatic-preview端点增量。没有改动现有手动重建输出；保留全部34项累计工作区改动。真实NAS写入与下载为零，未新增用户入口或发布包。

独立只读复核：源任务必须匹配当前profile和空间，读取前后核对原候选，不以同名或Item编号追认；共享扫描仍要求真实management，后续可见目录优先任务不能照搬此限制。原件下载只使用unit_id，随机0700临时目录，长度/内容类型与取消、访问代次检查后才原子导出，失败或已有目标不覆盖。视频转换使用现有Apple框架，输出后核对H.264和有效时长，不改原件，取消回调与导出对象统一MainActor。未实现上传或以单个候选批次消失推断完成，避免伪报自动流程成功。

首次编译发现AVAssetExportSession不是Sendable，取消闭包直接捕获不合法；改用MainActor持有并以回调续体启动，取消也回到同一执行域，没有降低并发检查。新增下载测试初稿有多余括号导致编译失败，已修复。最终命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test自动预览|SynologyPhotosPreviewConverterTests'` 退出0：16项聚焦测试通过。本轮新增4项Repository与2项Converter测试；既有短视频fixture抽为复用生成器，原断言保留。合成MJPEG/PCM转H.264/AAC覆盖实际音轨、90度方向、1秒时长、原件保持及已有目标不覆盖；下载覆盖两空间、正确unit_id、前后快照变化、错误响应/长度、下载期间取消。视频导出取消测试覆盖开始前取消，不替代长视频进行中用户验收。

最终命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：604项XCTest（Repository380、Model170、Converter7、Events20、Appearance27）与6项Swift Testing本地化通过。当前macOS Swift Package构建通过；未运行新的Xcode Release或UI截图，不将其表述为新的可安装版本。仅既有skip-update弃用提示。

`python3 tools/contract-validation/validate_fixtures.py` 通过3组/37项引用；`python3 tools/codex/check_documentation.py --strict-release` 与 `git diff --check` 通过。本轮无新增用户界面文案，五端影响已同步；没有其他端UI、依赖、工具链、最低系统或持久化变化。

PENDING_USER_VALIDATION：完整自动入口交付后，核对实际HEVC/VC1/VP9/MPEG2、实况视频、音轨与方向，长视频运行中取消应停止并清理半成品，NAS读取拒绝不继续上传。当前只验证合成格式，不能扩展声称所有编码受支持。返回脱敏版本、媒体类别、操作和错误即可，不需要原件或凭据。剩余自动上传/最终核对/调度/设置、共享与全局管理、缓存设置及此前上传持久化授权事项继续保留；本轮为progress，目标未完成，main@5684170b3ccf，无git add/提交/推送。

本轮所有测试进程结束，2份临时日志移入独立废纸篓目录。正式测试与依赖缓存保留；合成媒体由测试defer清理，浏览器控制台已清空关闭，没有真实NAS数据或原始脚本落盘。


### 2026-09-30 自动预览上传与结果核对波次开始

上一轮为progress：单元原件读取/本机视频转换、604项回归通过。本轮保留main@5684170b3ccf及34项累计改动；接入自动转换命令、文件流式上传、操作去重与媒体结果核对。独占Photos Core/Repository/Converter及相关测试/契约记录，不改其他端UI或存储；真实NAS写入/下载仍交给用户。


### 2026-09-30 自动预览上传与结果核对验证

已完成共享Core命令generateAutomaticPreview、automaticPreview真实API能力、Repository按单元/空间的候选核对→原件读取→本机转换→文件流式multipart上传，及明确回执确认/未知回执媒体只读核对。沿既有operationID与未决互斥，不重放、不调用set_broken；预览内容不改写原件。补齐视频编码样本SHA256、轨道格式/方向/总时长核对，允许MP4→MOV重新封装，错误页/旧内容不确认。五端计划、兼容矩阵和photos-automatic-preview记录已同步。没有其他端UI、依赖、工具链、最低系统、持久化或本轮界面资源变化。

独立集成/只读对抗复核：检查本轮Core/Repository/Converter以及合成传输测试，固定profile/space/unitID，不套用Item；NAS实际空间权限及ConvertedFile/Download能力检查，写前候选再次读取与访问代次校验；上传前取消/本机失败明确结束，上传后不明保留同编号并只读核对，重登恢复不被旧访问代次永久锁死；0700/0600暂存、流式视频及全路径清理；无凭据/原图进入文档，无临时打印遗留。没有不可见的真实写入或人为待实测白名单。已知边界：NAS upload未见条件更新字段，最后核对后仍有竞态窗口；回读视频档位绑定和空缓存键属于标明的客户端推断，未确认时只能保持未知，不能以本地合成结果升级NAS兼容等级。

验证中实际发现并修复两项问题：AVAssetReader会产生零样本EditBoundary，内容摘要应跳过该标记而继续要求真实音视频样本；AVFoundation对无扩展名的合成MOV报无法打开，因此临时源仅保留格式扩展名。首次完整回归另有两条“所有API能力”fixture未包含新ConvertedFile能力，已补充该fixture，原全集断言保持不变，没有降断言或静默跳过。

本轮新增8项Repository与1项Converter测试。聚焦命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test自动预览|SynologyPhotosPreviewConverterTests'` 最后一次退出0，24项通过；其后又补充旧视频回读测试、共享视频路由及临时文件清理断言，纳入完整回归。最终命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：613项XCTest（Repository388、Model170、Converter8、Events20、Appearance27）及6项Swift Testing本地化全部通过。只有已有skip-update弃用提示。当前macOS Swift Package目标可构建；未运行新的Xcode Release/UI实机/真NAS，不是新安装包。

PENDING_USER_VALIDATION：完整自动入口接通后，由用户使用专用合成媒体检查实际格式与实况视频、开启/关闭与调度、film_h264结果回读、缩略图缓存、共享权限、网络中断和大视频取消；原件与历史月份浏览位置应保留。只返回脱敏版本、媒体类别、操作与错误，不提供原件/凭据。当前真实NAS读取/写入测试均为零。下一切片：设置与调度、实际转换能力采集、可见项目优先与恢复；共享/全局识别及分享设置、下载转换缓存和原上传跨重启存储授权待办保持，完整网页菜单审计未完成。目标保持active，本轮有实际源码及测试进展，非blocked；main@5684170b3ccf，34项累计改动，无git add/提交/推送。

`python3 tools/contract-validation/validate_fixtures.py` 通过3组/37项引用；`python3 tools/localization/check_localization.py` 通过双语/参数/资源引用/硬编码扫描（Apple4562、Android2188、Windows3402）；严格文档检查及diff检查通过。所有本轮测试进程结束，8份一次性日志移入独立废纸篓目录；合成媒体由测试清理，正式测试、依赖缓存与此前识别测试包保留。


### 2026-09-30 自动预览设置与调度波次开始

上一轮为progress：上传/核对实际源码与613项回归通过。本轮保留main@5684170b3ccf及34项累计工作区改动，独占Photos Core/Repository/Model/View/设置面板、双语和相关测试，接入用户设置、原生能力采集、串行调度与状态/取消。复用已记录User auto_generate_thumbnail静态契约及现有写操作编号，时间轴/选择保持；不改其他端UI和持久化，不执行真实NAS下载/写入。完整可见目录优先范围仍按实际证据核对，不能把后台management扫描当作entry权限可见任务的替代。


### 2026-09-30 自动预览设置与调度验证

本轮已接通设置→NAS开关核对→系统注册转换能力→照片页串行扫描→本机转换/上传→自动核对→局部预览更新。当前可用范围为个人与共享management后台候选，批次内优先当前预览/已出现的网格照片；暂停/继续、离页取消及返回核对均接入。未实现批次外/相邻/实况单元的完整优先队列、0.8可见比例及普通entry共享目录可见任务，不能据此声称网页自动预览全部对齐。

独立集成与只读对抗复核：检查设置枚举/协议默认实现/Access可选字段/Repository参数及权限/Model生命周期/View状态；新增设置按原值快照保存仅一个字段，未知只读核对，缺字段不猜关闭。worker复用写互斥但不阻断浏览/选择；不递增图库generation，不重查时间线；成功仅按空间+预览unit重载相关缩略图。设置打开时不领取新任务，当前可取消；关闭模块或离页取消worker/当前操作，未知记录仍保留。单项失败不反复自动写入，继续操作可重新尝试；另一空间只读失败不清除已有候选。视频未知读取按5秒起逐步退避到60秒，没有密集重复上传。无新增存储或其他端UI；五端影响与私有接口记录已同步。

聚焦命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test自动预览设置|SynologyPhotosModelTests/test自动预览'` 退出0，最初8项通过。本轮最终新增3项Repository和7项Model测试；覆盖开关读取/保存/缺字段/并发修改/断网去重、历史月份与选择保持、串行与同批可见优先、个人/共享权限、关闭/暂停/缺转换器、退避、进行中取消后继续核对、设置期间不领取、单项失败后处理其他项及手动继续。新增的进行中选择断言最初失败，因为测试服务未提供照片；补入实际合成照片后保留原断言，未降低验证范围。

最终完整命令 `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'` 退出0：623项XCTest（Repository391、Model177、Converter8、Events20、Appearance27）和6项Swift Testing本地化全部通过。现有skip-update弃用及测试文件已有WeakMutability提示，不是本轮新功能编译错误。

原生UI命令 `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test自动预览设置中英浅深色正常加载错误与无转换器' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-auto-settings-ui-final` 退出0：1项原生测试、24张合成截图。覆盖中英浅深色正常/加载/读取失败/无本机转换器；实际点击开关、回车保存，正常和无转换器状态均提交同一明确设置命令，没有虚设禁用。人工查看中文深色正常和英文浅色无转换器界面，标题/开关/说明/底部按钮无裁切。设置值为布尔，不存在筛选或空列表状态；缺字段按错误恢复，不伪造默认值。

`python3 tools/localization/check_localization.py` 退出0：双语/参数/引用/硬编码扫描通过，Apple4573、Android2188、Windows3402；`python3 tools/contract-validation/validate_fixtures.py` 通过3组/37项私有接口引用；严格文档和diff检查通过。真实NAS下载/写入为零。

PENDING_USER_VALIDATION：安装本轮独立测试包，照片→设置→自动生成预览开关保存后，在2020.03等历史月份浏览专用HEIC/视频测试文件；个人和共享management应顺序补齐，原件、月份、选择不变。检查暂停/继续、正在转换时浏览选择、离开/返回、网页关闭自动开关，以及上传断网后自动核对。实际格式、音轨/方向/实况视频、NAS缓存及film_h264回读对应仍待实测，失败只回传脱敏版本、媒体类别和步骤/提示。后续：普通entry目录与批次外优先、共享/全局识别及分享管理设置、下载转换缓存，上传跨重启存储授权待办与完整网页菜单审计保留。目标active，本轮progress，main@5684170b3ccf，34项累计改动，未git add/提交/推送。


### 2026-09-30 自动预览独立测试包（非正式发布）

实际命令 `PATH="/tmp/dsm-photos-automatic-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-automatic-previews-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-automatic-previews-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时启动器仅使用现有apple/.build依赖缓存及skipPackageUpdates；没有依赖/工具链变更，也未覆盖既有测试包。

成品 `apple/Apps/DsmMac/dist/photos-automatic-previews-20260930/LanStash-1.0.11-arm64.dmg`，20,671,362字节，1.0.11(21)，沿既有localtest标识。包含之前累计照片功能及本轮自动设置/后台扫描/暂停继续/结果核对。Release arm64、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist确认localtest，PlugIns=0，主程序含photos.automatic.title。本机临时签名不提供本地磁盘挂载，未自动安装/启动、未正式发布。打包只有现有hdiutil弃用提示。

623项XCTest、6项本地化及1项原生UI/24张合成截图通过；本地化硬编码/资源、3组fixture/37项引用、严格文档和diff检查通过。真实NAS读取/写入未由Agent验证，入口无待实测白名单；按照片账本PENDING_USER_VALIDATION验收。仍缺共享普通entry目录可见触发、批次外/相邻/实况完整优先等内容，不把此包当成完整网页复刻完成。

本轮全部构建/测试进程已结束；8份一次性日志、2组临时合成UI截图、临时工具启动器与本轮build目录已移入独立废纸篓目录。dist中的App/DMG、先前测试包、依赖缓存、正式测试和其他累计改动均保留。


### 2026-09-30 可见照片与相邻预览优先波次（源码、回归与独立测试包完成）

范围仅为 macOS 自动预览队列优先级与原生视口判断。基线为上节623项XCTest和已保存独立测试包；本轮保留34项累计改动。证据采用 photos-advanced-management.md 已记录的官方静态0.8可见比例与当前/相邻预览优先规则；本轮Chrome工具仍报告锁屏，已请求解锁，不将旧证据升级为当前观察。

计划：替换网格onAppear即视为可见的逻辑，按实际裁切面积计算80%阈值；同一照片在网格和相似照片条同时显示时独立登记；现有候选批次内按当前、相邻、实际可见、其余候选排序。复用已有任务下载/生成/提交/核对流程，不新增接口、存储、权限或其他端UI。共享entry与批次外/实况单元需要额外状态和权限证据，仍为明确后续；本轮不猜字段。验证以原生裁切/滚动和队列顺序的合成测试为主，NAS操作留给用户。

实现：SynologyPhotosView中的PhotoPreviewVisibilityReader读取AppKit实际visibleRect与bounds交集面积，达到80%才登记；监听祖先滚动裁切/尺寸变化，布局后合并通知，只在阈值跨越时报告，隐藏/零面积/离窗/拆卸取消登记，hitTest不截获点击。SynologyPhotosModel按独立视图来源登记同一照片，任务排序为当前预览、前后相邻、已登记可见项和原候选；匹配包含profile/space/thumbnail unit，仍不把Item ID当Unit ID。相邻来源沿用相似组和幻灯片已有集合。未新增公开契约、存储、文案、依赖、权限或功能禁用。

验证：`swift test --package-path apple --skip-update --jobs 4 --filter 'MacAppearanceTests|SynologyPhotosModelTests|SynologyPhotosRepositoryTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|DsmLocalizationTests'`退出0，627项XCTest（Appearance29、Model179、Repository391、Converter8、Events20）和6项本地化通过。新增2项原生裁切/生命周期测试与2项队列测试，覆盖80%/79%、横纵裁切面积、滚动与布局移出、隐藏/零尺寸/离窗、拆卸取消排队回调、同照片多视图独立注销、当前与相邻顺序、快速切换预览。已有捏合/滚轮、历史月份、选择保持和串行未知核对回归同时通过。

首次聚焦运行中2项原生测试通过，但新增Model测试使用Date.distantPast触发现有月份日期范围断言；修正新增合成照片为2020.03后运行完整回归通过，未移除或降低断言。现有极早日期范围处理留待日期专项核对；本轮没有修改时间线算法。`python3 tools/localization/check_localization.py`（Apple4573/Android2188/Windows3402）、`python3 tools/codex/check_documentation.py --strict-release`及git diff --check均通过。

独立集成复核：新可见性组件不接管点击/滚轮/捏合，不改变图库分页和月份；来源注销不影响另一个视图登记。原生组件不触发NAS请求，只改变既有候选排序；Repository仍执行原权限、重复提交与结果核对。后台扫描只限management规则，未把普通entry冒充全库管理。没有新协议/五端影响；其他端累计改动保留。真实NAS操作与物理触控板验收仍为PENDING_USER_VALIDATION。

PENDING_USER_VALIDATION：安装新独立测试包后，在历史月份滚动网格、打开大图及相似照片条，确认当前照片优先补齐，相邻照片随后处理；网格提前加载项不因onAppear抢占可见照片。检查捏合/滚轮、点击/选择和月份定位不受影响。需启用自动生成预览且有实际待处理媒体；回传脱敏媒体类型、复现步骤、提示及版本即可。普通entry目录、批次外和实况视频单元完整链、2秒预览去抖唤醒仍未接入，不把本轮同批排序当成完整自动预览对齐。


### 2026-09-30 可见预览独立测试包（非正式发布）

实际命令 `PATH="/tmp/dsm-photos-visible-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-visible-previews-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-visible-previews-20260930" bash apple/Apps/DsmMac/package.sh` 退出0。临时启动器仅指定既有apple/.build缓存及skipPackageUpdates，无工具链/依赖变更。产物路径、版本和20,678,166字节大小见最新状态。严格签名、Hardened Runtime专用测试权限、Sparkle实际library loaded、arm64及DMG checksum VALID通过，额外codesign --verify --deep --strict退出0；Info.plist确认沿用localtest、PlugIns=0。未自动安装/启动，旧包保留。

打包期间用户解锁，已继续只读官方脚本；新证据表明相邻视频需排除，预览2秒去抖、实况多单元和编码优先级仍属下一切片。本包源码未在打包期间修改，仅追加证据和文档，不声称这些新发现已实现。完整剩余：自动预览上述场景、共享/全局识别和分享管理设置、下载转换缓存、待授权上传跨重启存储，以及最终网页菜单审计。实际NAS测试由用户执行，目标继续active。

本轮测试/打包进程均结束后，3份一次性日志、临时工具启动器与本轮build目录已移入独立废纸篓目录；dist成品、旧包、正式测试和依赖缓存保留。最终3组fixture/37项引用、严格文档及diff检查通过。工作区main@5684170b3ccf仍为34项累计文件，未git add/提交/推送。


### 2026-09-30 批次外与共享目录自动预览波次（开始）

上一波次为progress：627项XCTest、6项本地化、独立测试包和新增static证据完成。当前保留34项累计改动。独占本轮Photos Core/Repository/Model及对应测试和证据记录；目标是从当前可访问照片读取预览状态、实况单元与目录权限，形成批次外候选，并复用同一生成/上传/结果核对路径。普通共享目录可下载权限不能变成全库扫描权限；相册访问不能变成他人个人原件写权。共享契约沿用户已有扩展授权，增量默认值保留其他端兼容，无新增存储、依赖或系统版本；同步五端影响。真实NAS操作不执行，未实测不设置人工白名单。

源码与合成回归完成：Core增量sourcePhoto/可见服务重载；Repository读取Item/Unit原始状态，验证owner/目录下载权与固定照片身份，原件下载前后和上传前共用原来源校验，已提交结果核对允许状态变ready；Model接入可见/当前/相邻优先、实况双单元、2秒去抖与跨来源去重。共享entry仅处理授权目录中的照片；全库后台扫描仍management。没有新增人工禁用、持久化或其他平台UI。

独立集成/只读对抗复核覆盖：伪造profile/source/space/Unit、他人个人原件、共享只读无下载、下载期间撤权、上传后撤权、回执丢失、同一Unit不同来源及视频数字类型。每个提交点仍走原互斥/编号/结果证明，损失回执只读复查。新可见读取方法不使用相册权限绕过物理原件权限。发现视频typeCode的非0值需要按视频语义去重，已补修改与断言，最终包将以修改后的源码重新构建。

实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：637项XCTest（Repository398、Model182、Converter8、Events20、Appearance29）及6项本地化通过。新增7项Repository、3项Model覆盖可见共享entry、权限/身份拒绝、缺陷/编码筛选、实况Unit、完整生成上传核对、读取后撤权不导出、未知回执撤权不重传、2秒触发、无全库扫描、跨来源去重、相邻视频排除。首个聚焦测试仅下载参数断言失败：实际下载使用GET查询，测试错误读取POST正文；修正为检查实际URL参数后通过，未降低断言。

视频非0语义去重补测命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests'`退出0，182项通过；实况视频的后台typeCode=5与可见typeCode=1只提交一次。PENDING_USER_VALIDATION为真实NAS版本/HEIC/HEVC/实况/目录撤权/缓存/断网核对及历史月份保持；本轮没有真实NAS照片下载或写入。完整相邻集合/格式优先级仍需收尾审计，其他剩余为共享管理设置、转换缓存、待授权跨重启存储。

本轮本地化命令`python3 tools/localization/check_localization.py`退出0，Apple4573/Android2188/Windows3402；3组fixture/37项私有接口引用、严格文档和diff检查通过。首轮打包结束后将本轮尚未交付的build/dist移入独立废纸篓目录，再按相同既定命令从最终源码全量构建，避免包与去重修正不一致；先前已交付包保持原样。


### 2026-09-30 可见来源自动预览独立测试包

最终实际命令`PATH="/tmp/dsm-photos-visible-sources-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-visible-sources-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-visible-sources-20260930" bash apple/Apps/DsmMac/package.sh`退出0。最终源码修改在此次完整重构建开始前完成；临时工具仅指定现有依赖缓存与skipPackageUpdates，不改变工具链/依赖。成品20,733,190字节，1.0.11(21)，localtest标识，Release arm64。严格签名、Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded、DMG checksum VALID均通过。Info.plist与PlugIns=0复核通过；未自动安装/启动、未正式发布或覆盖先前交付包。

本轮源码、已执行命令、失败修正、跨端影响和PENDING_USER_VALIDATION见上一节。最终交付保留真实权限、串行和结果核对，不增加未实测白名单。完整goal仍active，本轮为progress。

所有本轮测试/构建进程已结束，8项一次性日志、工具启动器与build目录移入独立废纸篓目录；正式测试、dist中的最终App/DMG、先前交付包与依赖缓存保留。额外严格codesign通过；main@5684170b3ccf，仍保留34项累计改动，没有git add/提交/推送。


### 2026-09-30 管理设置波次（开始）

上一波次为progress：可见/实况自动预览、637项回归/6项本地化、最终Model182项与独立测试包完成。当前保留34项累计改动。本轮独占Photos Core/Repository/Model/View/Panel、双语资源和对应测试/证据；目标为网页共享空间及管理员设置，先核对字段/权限/保存链，后接原生表单、固定原快照、差异保存与自动结果核对。沿用户已有公开契约扩展授权同步五端影响，不改存储、依赖、其他端UI或真实NAS设置。


### 2026-09-30 共享空间设置：实现、验证与独立复核

新增原生共享空间设置：管理员可独立启用/停用共享空间，保存共享人物/主题/相似识别与顶层文件夹公开分享开关。启停、公开访问改变有确认，保留NAS实际权限、最后空间约束、固定原快照、重复提交保护和自动回读；没有未实测人工禁用。保存不刷新个人时间线，2020.03和多选保留；关闭当前共享分类返回相册，停用正在浏览的共享空间退出旧位置。双语资源新增20键；其他端界面/存储/工具链不变。共享成员与自动备份权限尚未接入，不能称整个共享管理完成。

官方只读static发现同时确认全局用户分享/来宾照片信息/排除格式和JPEG转换清缓存关联；设置页还含整库重新索引及缺陷预览生成，属于未实现动作，不能用已完成的单项重建代替。已登记photos-shared-space-settings、五端影响和环境记录，版本未知不绑定当前设备兼容结论，浏览器控制台已清空关闭。

独立集成/只读对抗复核：检查Core增量默认接口与结果、真实管理员身份、共享空间角色独立性、四字段差量和独立set_enable、缺字段/并发变化/撤权/外部NAS快照拒绝、未知结果只读核对、取消和访问代次检查、共享分类缓存与模型状态同步。复核发现缺失全局字段不应把已有共享分类默认为关闭，已修正并新增回归；明确全局false时才关闭对应能力。无真实NAS设置/照片读取写入，回读到写入之间仍存在未见条件更新参数的竞态窗口。

首次聚焦命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test共享设置|SynologyPhotosRepositoryTests/test共享空间|SynologyPhotosModelTests/test共享设置'`中Repository7项通过、Model一项有4条断言失败：测试只调用refresh(space:)未改变用户首选空间，切相册时按首选回个人。改为真实selectSpace流程并增加共享前置断言，保留原断言后通过。契约检查最初因新记录仍指向个人识别文档、稳定标识无反引号失败；已修正文档路径和明确标识，高风险级别与实际范围同步，无修改验证器。

最终实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：646项XCTest（Repository404、Model185、Converter8、Events20、Appearance29）和6项Swift Testing本地化通过。本轮新增6项Repository、3项Model，覆盖四字段双向差量、启停路由/实际权限、最后空间与全局关闭、旧快照/撤权/跨NAS、未知回执、缺字段保持分类、历史月份/多选/分页保持、关闭当前共享空间和分类。

原生UI实际命令`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享空间设置中英浅深色正常关闭受限空加载与错误' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-shared-settings-ui-final`退出0：1项UI测试、32张合成截图；中英浅深色正常、关闭、最后空间、全局限制、字段为空、加载、错误，实际点击人物开关及键盘保存断言固定命令，受限开关不能产生保存。设置表单无筛选列表，筛选为空不适用。初次视觉复核发现每项重复提示导致英文受限状态滚动过长，改为一条全局条件提示并复验；最后人工查看中文深色正常与英文浅色受限，布局完整。真实触控板和NAS行为仍交给用户。

PENDING_USER_VALIDATION前置条件、操作、预期、脱敏回传及影响范围见photos-shared-space-settings记录。本轮为progress，完整目标保持active；未git add/提交/推送，main@5684170b3ccf及34项累计改动保留。剩余为全局管理、共享成员/自动备份权限、转换缓存、设置页重索引/缺陷预览生成、自动预览最终范围/格式优先级与菜单审计；上传队列跨重启持久化仍待此前单独存储授权。


打包前最后复核：官方共享页在文件夹停用原因存在时仍提供启用按钮，因此移除本轮曾推断添加的禁用条件，原因字段只作恢复提示；最后空间限制仍沿官方行为。新增真实命令路由回归，实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test共享|SynologyPhotosModelTests/test共享设置'`退出0，49项通过（Repository46、Model3），包括原有共享功能。此为646项完整回归后的聚焦修正，不冒称完整回归647项已运行。最终本地化扫描Apple4593/Android2188/Windows3402通过。首个尚未交付的Release构建因此明确取消（退出143），其本轮编译子进程已终止、build/dist移入唯一废纸篓目录；随后用最终源码重新完整打包，旧交付包不变。


### 2026-09-30 共享空间设置独立测试包

最终实际命令`PATH="/tmp/dsm-photos-shared-settings-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-shared-settings-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-settings-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只指定现有apple/.build依赖缓存和skipPackageUpdates；全部源码改动在本次重新构建前完成，没有新依赖或工具链变化。

成品`apple/Apps/DsmMac/dist/photos-shared-settings-20260930/LanStash-1.0.11-arm64.dmg`，20,879,215字节，1.0.11(21)、localtest、arm64。严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded与DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist与PlugIns=0核对通过。无本地磁盘挂载扩展，未安装启动、未覆盖旧包、未正式发布或提交推送。仅既有hdiutil/skip-update弃用和旧测试WeakMutability提示。

本地化4593/2188/3402、3组fixture/38项私有接口引用、严格文档和git diff --check通过。完整646项加6项本地化、最后49项共享聚焦与1项UI/32张合成截图的范围和初次失败修正见上文；未运行其他平台构建，不能把源码默认接口兼容检查当成其他端已验收。真实NAS测试未由Agent执行。完整目标保持active，本轮完成可使用的共享设置切片，不等于全部管理设置已完成。

本轮测试和构建进程全部结束后，13项一次性日志、合成截图目录、临时工具启动器与最终build已移入唯一废纸篓目录。正式测试、dist中的App/DMG、此前交付包和依赖缓存保留；没有原始网页脚本或真实NAS数据落盘。工作区仍为34项累计改动。


### 2026-09-30 全局设置与转换缓存波次（开始）

上一轮为progress：共享空间设置、完整646项/本地化6项、最后49项聚焦及独立包完成。当前main@5684170b3ccf、34项累计改动保留。本轮独占Photos Core/Repository/Model/View/Panel、双语资源和相应测试/契约，接入全局识别、分享、来宾信息、排除格式、JPEG转换及缓存清理。沿已有共享契约扩展授权，同步五端影响，不改存储、依赖、其他端UI，不执行真实NAS写入/照片下载。先核对多阶段副作用与格式候选，再实现固定快照、确认和结果回读。


### 2026-09-30 全局设置与转换缓存实现和验证

本轮完成管理员全局人物/主题/相似识别、普通用户分享、访客照片详情、格式排除、原尺寸JPEG及转换缓存大小/刷新/清理原生入口。全局关闭识别联动当前个人与共享已知开关；重新开启不擅自开启下游。关闭JPEG先清缓存，按缓存/Admin/User/Team四类实际步骤记录回执并核对，丢失回执不重放、不补发未尝试步骤，部分完成返回实际设置。缓存清理完成后显示实读大小，不伪造0；无回执需非processing且大小0才确认。照片页在短退避后继续每15秒自动核对，离页停止调度返回恢复，错误提示不要求手动确认。

本轮独占既有Photos Core/Serving/Repository/Model/View/Panel、双语资源及相关测试/契约文档；五端影响已同步。无存储、依赖、工具链、标识或其他平台UI改动；无待实测人工白名单。保存前固定快照/身份和真实权限，关闭识别及分享/访客/格式/JPEG变化有确认，缓存错误不阻断其他设置。部分保存按实际状态更新分类和下载能力，历史月份/多选/已加载照片保持，只有当前分类关闭时回到相册。

独立集成与只读对抗复核覆盖：管理员与共享管理角色分开；跨NAS、旧快照、缺字段、撤权、HEVC变化、清理中重复提交；真实格式列表/未知原格式保留；Admin不写need_hevc；全局关闭与重新开启的不同联动；缓存/设置结果分阶段、未知仅读、后续拒绝仍报告已完成部分；非照片操作不刷新图库。真实NAS在最后读取与写入之间存在竞态，缓存缺任务编号导致无回执且新缓存非零时仍可能等待；这些限制保留PENDING_USER_VALIDATION，不升格兼容结论。

首次Repository聚焦8项通过。随后Model聚焦有1项/5条断言失败：合成共享服务尚未包含新增管理员能力，导致命令未提交；补全该fixture的真实能力并保留全部断言，回归通过。第一轮完整回归658项通过。原生UI复核发现错误复用共享识别文案及缓存按钮在首屏以下，已新增全局文案并把弹窗调整为620×680；复查中文深色与英文浅色缓存错误，标题/开关/底部按钮完整。最后补充后续权限拒绝/仅保存剩余差量、缓存无效响应，以及自动核对断网文案回归。

最终实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：660项XCTest（Repository415、Model188、Converter8、Events20、Appearance29）与6项本地化Swift Testing全部通过。较上一完整交付新增10项Repository、3项Model；包含此前最后共享入口修正。只有现有skip-update和WeakMutability提示。

原生UI命令`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test全局设置中英浅深色正常受限空加载错误与缓存状态' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-global-ui-final`退出0：1项测试、40张合成截图，覆盖中英浅深色正常/缺HEVC/空字段/加载/设置错误/缓存错误/清理中/零缓存。正常与缓存失败状态实际点击人物开关、Return打开确认并点击保存，断言固定目标命令，没有用截图代替提交路径。格式控件当前为完整展开多选，不存在搜索结果为空分支。

本轮私有端点`photos-global-settings-cache`已入索引，官方static资源只读补证完成、控制台清空关闭，无原始脚本/真实NAS响应落盘。本轮未读取真实设置/缓存、未下载照片或执行NAS写入；详细用户验收步骤在端点记录。完整目标继续active，本轮progress，不宣称全网页完全对齐。剩余：共享成员与自动备份权限、整库索引/缺陷预览生成、自动预览完整相邻范围/格式优先级和最后菜单审计；上传跨重启存储仍待此前独立授权。


### 2026-09-30 全局设置独立测试包（非正式发布）

实际命令`PATH="/tmp/dsm-photos-global-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-global-settings-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-global-settings-20260930" bash apple/Apps/DsmMac/package.sh`退出0。唯一目录避免覆盖先前成品；临时启动器仅指定现有依赖缓存与skipPackageUpdates。最终源码冻结后开始构建，期间只继续只读共享成员证据与文档，没有改变包中源码。

成品`apple/Apps/DsmMac/dist/photos-global-settings-20260930/LanStash-1.0.11-arm64.dmg`，21,122,652字节，1.0.11(21)、localtest、arm64。Release、严格签名/Designated Requirement、Hardened Runtime专用测试权限、Sparkle实际library loaded与DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist与PlugIns=0以及主程序photos.global.title复核通过。没有自动安装/启动、覆盖旧包或正式发布；仅现有工具弃用提示。

最终本地化4619/2188/3402、3组fixture/39项私有接口引用、严格文档与diff检查通过。完整660项XCTest与6项本地化、1项UI/40张截图通过范围见上文，其他端构建与真实NAS仍未验证。打包期间已只读补证下一步共享成员角色/auto_backup/administrators保护及entry目录权限弹窗；这些尚未实现，不计入本包。

工作区main@5684170b3ccf保留34项累计改动，未git add/提交/推送。目标继续active，本轮progress。所有本轮构建/测试结束后，12项一次性日志、合成截图、临时工具启动器及本轮build移入唯一废纸篓目录；正式测试、最终dist、旧包与依赖缓存保留。无真实NAS内容/凭据或原始网页脚本落盘。


### 2026-09-30 共享成员与目录权限波次（开始）

上一轮progress：全局设置/缓存完成，660项回归、6项本地化、40张合成UI及独立包。保留main@5684170b3ccf的34项累计改动；本轮独占Photos Core/Repository/Model/View/Panel及双语/测试/契约文档，目标为成员增删/角色/自动备份和entry成员目录权限的完整流程。沿已有契约扩展授权，同步五端影响，不改其他端UI/存储/工具链，不执行真实NAS成员或权限写入。先核对FolderBatchPermission与最终回读，复用既有写操作互斥和固定快照，不以裸角色开关代替目录授权。


### 2026-09-30 共享成员与目录权限读取、领域规则（继续实施）

上一goal轮仅核对并回答剩余清单，属于no progress；本轮重新核对main@5684170b3ccf、34项累计改动和源码后实际推进，归类progress，完整目标继续active。没有阻塞，不把剩余目标缩成只读管理。

实际修改：DsmCore/SynologyPhotosManagement.swift增加共享成员/原快照、两层目录权限/分页类型及草稿校验；SynologyPhotos.swift增量3个服务方法并提供显式unsupported默认实现；SynologyPhotosRepository.swift实现成员、候选和按成员目录权限分页读取；SynologyPhotosRepositoryTests.swift增加12项正式测试。私有组photos-shared-space-members、环境、索引、兼容矩阵和五端计划同步。未改本轮macOS View/Model/Panel或文案，全部既有累计改动保留。

关键规则：list_permission读取data直接数组，候选保留当前用户且不套用分享过滤参数；用户/群组及整数/字符串编号彼此独立。新management默认备份，降级保留备份；已知系统administrators群组不可编辑，未知角色原样保留。管理员身份每次重新核对，共享management不替代DSM管理员；访问代次变化丢弃旧响应。目录根和两层列表按官方参数读取，授权项无需name；保留公开访问下限与成员直接角色，第二层重新读取父目录当前权限，不能沿用旧父权限。未创建分享链接，也没有NAS成员/权限写入。

静态补证明确两种FolderBatchPermission v1结构、check_all/uncheck_all层级语义、父目录限制、私有父目录撤销查看的子目录影响，以及网页临时entry授权。保存下一步将在本地编辑草稿，最终确认后分阶段提交并核对，不在打开或取消表单时临时改NAS。仍未实现成员保存命令、批量目录权限写入、自动核对与原生表单，不能称完整成员管理已交付。

首次聚焦构建失败：新增测试两处在XCTUnwrap自动闭包中await actor调用；改为先await收集请求再断言，未降低断言。`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test共享成员'`随后10项通过。完整命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，670项XCTest（Repository425、Model188、Converter8、Events20、Appearance29）和6项本地化通过。独立复核发现候选保留本人测试的初始身份未提供uid，补入真实结构并新增坏候选/关闭空间/错误分页检查后重跑上述成员聚焦命令，12项通过。最后只变更测试，没有重新宣称672项全量通过。

独立集成及只读对抗复核：核对协议默认实现兼容性、protected群组不能通过改名规避、未知角色不静默降级、重复身份、跨NAS/跨成员/第三层快照、父目录移动或根身份不一致、缺字段与错误容器、会话更新、公开下限及无需额外链接API。修正根读取后的代次检查，并补充候选包含uid证据。权限直接角色与公开有效权限分开，后续表单需显式区分未知权限，不能把effectiveRole=nil当成已证明无访问。

`python3 tools/localization/check_localization.py`通过（Apple4619/Android2188/Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过3组/40项引用，`python3 tools/codex/check_documentation.py --strict-release`及git diff --check通过。没有本轮UI改动，未新增截图或Release包；上轮photos-global-settings-20260930成品仍是最新可测试包，不包含本轮未接UI的读取接口。其他端构建、真实NAS和物理手势仍未验证；读取与规则测试不能代替NAS写行为。

后续顺序：成员与按成员目录草稿/确认→分阶段提交及丢失回执自动核对→原生表单和目标平台构建/独立包；再继续整库重新索引/缺陷预览、自动预览相邻范围/格式优先级、默认排序确认和最终网页菜单审计。上传跨重启存储仍待此前独立授权。无git add/提交/推送，无新增存储、依赖或工具链；当前工作区34项累计改动不变。

本轮构建/测试进程全部结束后，4份一次性测试日志已移入唯一废纸篓目录；正式测试、依赖缓存、此前App/DMG和全部既有改动保留。Chrome临时输出已清空关闭，无原始资源或真实NAS内容落盘。


### 2026-09-30 共享成员确认保存与目录批量提交（实施中）

上一轮为progress：读取/领域规则、670项回归与最后12项聚焦通过。本轮保持同一34项累计工作区，继续成员管理完整目标，独占既有Core/Repository及对应测试；后续再接原生表单。已新增组合成员命令和按成员目录草稿，计划在同一操作编号内顺序提交成员、目录批量和逐目录差异，固定完整两层目录快照以核对全选范围。公开协议沿此前授权增量；无存储、依赖或其他端UI变更，无真实NAS写入。部分完成与未知回执必须分别处理，不能因读链已完成宣称整个功能交付。


### 2026-09-30 共享成员组合保存后台切片验证完成（完整入口继续）

实际修改仍限Core/SynologyPhotos.swift、Core/SynologyPhotosManagement.swift、Network/SynologyPhotosRepository.swift、Network/SynologyPhotosRepositoryTests.swift与对应契约/五端文档。新增sharedMembers能力、setSharedMembers组合命令、批量/逐目录草稿、结果中的成员和本人实际空间状态；新增完整两层快照读取，能力发现包含FolderBatchPermission v1。成员只发送差量，目录按全局批量→逐目录覆盖顺序提交，入口执行前重新验证身份、候选及完整成员/目录快照。

本轮保存链已实现，原生表单和Model自动轮询/月份保持尚未接入，不能把Repository内部结果回读描述成用户已经能用完整成员管理。未修改本轮View/Model/Panel、未新增文案/界面测试，也未生成Release或新DMG；此前photos-global-settings-20260930仍为最新可测试包。真实NAS权限写入次数为零，没有安装/启动应用或正式发布。

首轮新命令编译与原有12项成员读取测试通过；新增10项保存/草稿测试后22项通过。独立复核继续补充新增entry成员与目录的正向组合流程、结构化失败时部分应用、完整批量快照和未知目录角色独立性4项，成员聚焦最终26项全部通过。发现成功/失败回执与最终权限不是同一件事：结构化success:false记为明确失败步骤但仍回读部分应用；无回执只读等待、不补发剩余步骤。公开权限下限内的无效变化不提交，未知无关目录角色不阻断单目录编辑。

独立集成与只读对抗复核：原始身份/保护群组/候选和数值类型、拒绝外来NAS及旧快照、根和两层树完整性、查看撤销对下一层影响、批量操作不是简单统一赋值、逐目录覆盖不使前一批量步骤误判失败、结构化失败与传输未知区分、成功回执仍须最后回读、操作编号禁止换命令/重放、新命令与未知写入互斥、权限改变后的本人角色以共享设置回读为准。复核补上组合核对整段的访问代次与取消检查，防止跨多个读取阶段拼成过期确认。API没有条件写入参数，NAS并发修改仍有竞态；大量目录下完整快照读取的耗时和真实传播行为待用户测试。

最终实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，686项XCTest（Repository441、Model188、Converter8、Events20、Appearance29）与6项本地化全部通过。新增14项保存/规则测试与前轮12项成员读取测试均包含在全量范围，macOS Swift Package可执行目标编译/链接通过；没有把它表述为Release签名/打包或NAS验收。仅已有skip-update/WeakMutability提示。

`python3 tools/localization/check_localization.py`通过（Apple4619/Android2188/Windows3402）；`python3 tools/contract-validation/validate_fixtures.py`通过3组/40项引用；`python3 tools/codex/check_documentation.py --strict-release`与git diff --check通过。五端契约增量默认实现同步，其他端未构建。完整goal保持active，本轮progress；34项累计改动保留，未git add/提交/推送，无存储/工具链/依赖变更。

下一步明确为原生共享成员表单、添加/移除/角色/备份、目录编辑窗口及确认，Model接入该组合命令、持续自动核对和实际空间权限更新，保留个人月份与选择；再完成UI状态验证和独立测试包。其余整库索引/缺陷预览、自动预览相邻范围/格式优先级、默认排序确认及最终菜单审计不变；上传跨重启存储授权待办保留。

本轮所有构建/测试进程结束后，5份一次性日志已移入唯一废纸篓目录；正式测试、Swift依赖/构建缓存、已有App/DMG与其他累计改动保留。没有原始网页资源或真实NAS数据落盘。


### 2026-09-30 共享成员原生入口与自动核对（开始）

上一轮只回答状态，属于no progress；本轮重新核对源码和34项累计改动，继续完整目标。独占macOS Photos Model/View/Panel、双语资源与对应测试；既有Core/Repository成员契约复用，不改存储、其他端界面或真实NAS。实现成员/目录本地草稿、最终确认、自动核对及本人实际权限更新，个人月份和选择不刷新。依照用户授权取消待实测人工限制，保留真实权限与重复提交保护。


### 2026-09-30 共享成员原生界面与权限更新

macOS Photos新增共享成员管理窗口：搜索、添加用户或用户组、自定义/管理角色、移除、逐成员及批量自动备份；新增或降级自定义权限时打开两层目录编辑器。目录支持搜索、展开、逐项角色及四级全体授予/撤销；公开访问下限独立显示，未知权限保留，系统管理员组不能编辑。成员和目录都只在内存编辑，目录“完成”返回草稿，主窗口最终确认才提交固定组合命令。取消不写NAS，连续批量操作按当前草稿组合，父目录撤权清理子项草稿；无待实测人工白名单。

Model将共享成员保存纳入持续自动核对，断线只回读，部分完成要求重开当前权限而非重放旧命令。以结果中的本人真实权限更新空间及能力；个人时间线保留月份、选择及已加载照片。共享访问撤回退出旧空间，降级后清理旧预览并重读原历史查询；权限变化使先前在途分页/预加载响应失效，避免晚到旧照片重新显示。新增45组中英文资源，没有存储/权限/工具链变更或其他端UI改动。

验证：692项XCTest（Repository441、Model194、Converter8、Events20、Appearance29）及6项本地化通过。原生UI两项/52张合成截图覆盖中英浅深色、正常/空/关闭/加载/错误/筛选为空；实际点击备份开关，打开最终确认后断言组合命令，目录实际选择上传权限、展开并按完成只返回草稿不写入。独立集成及只读对抗复核检查取消零写、protected/未知角色、候选读取失败不阻断既有成员编辑、公开权限下限、连续批量组合、父目录影响、保存结果部分/未知、本人权限刷新及在途页隔离。真实NAS传播、权限组合、网络恢复和实际备份仍未验证，证据等级保持static。

PENDING_USER_VALIDATION：使用专用测试成员，在共享成员管理中新增/移除、自定义与管理切换、修改自动备份，编辑第一/二层目录和连续批量后单项覆盖。先取消确认NAS未变，再保存检查最终权限；保存时断网后恢复，应自动核对且无重复提交。个人2020.03位置和多选保持；修改自己的权限时不可继续显示或操作已失去访问的照片。需回传脱敏版本、角色、步骤、提示及实际/预期差异；不提供账号、地址或照片内容。

实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0。新增6项Model/草稿回归，含仅共享空间及保存期间在途旧分页，不降低原断言。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test共享成员' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-members-native-ui-final`退出0，两项UI通过；末次仅加入Model访问代次失效修正后运行完整回归，UI布局未改动。`python3 tools/localization/check_localization.py`资源Apple4664/Android2188/Windows3402通过。

首轮编译错误为使用不存在的L10n.format和测试构造参数顺序，均按现有接口修正；本地化初次扫描发现动态键前缀误匹配，改为枚举明确资源键后通过，没有修改验证器。未执行真实NAS写入。源码冻结后开始独立Release打包，当前不能在结束前声称包已通过；完整目标active，本轮progress。剩余整库索引/缺陷预览、相邻范围/格式优先级、默认排序确认、最终菜单审计及待独立存储授权的上传重启恢复均保留。

下一切片只读定位（打包期间未改源码）：PhotoDisplaySettingsPanel保存当前直接setDisplaySettings，默认排序变化尚未单独确认；SynologyPhotosModel.automaticPreviewPhotos与preferredAutomaticPreview仍仅取前后各一个非视频邻居，没有完整网页nextItems/prevItems集合及格式优先级字段。必须补核官方相邻集合范围与优先数值方向后实现，不能把已存在的两侧单项排序当成完全对齐。整库重新索引/缺陷生成目前只有官方菜单static存在证据，仍须核对具体请求和结果读取；不猜接口。


### 2026-09-30 共享成员独立测试包与最终交付

实际命令`PATH="/tmp/dsm-photos-members-native-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-shared-members-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-shared-members-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只指定既有依赖缓存与skipPackageUpdates，不改工具链。源码冻结后打包，期间仅补文档及只读定位下一切片。

成品21,454,162字节，1.0.11(21)、localtest、arm64。Release、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist标识/版本、PlugIns=0和主程序成员资源键复核通过。旧包保留，未安装启动、未正式发布。完整回归692项、6项本地化与2项UI/52张截图通过范围见上文；真实NAS未验证，不以签名或合成测试代替真实行为。

全量范围内：Model194、Repository441、Converter8、Events20、Appearance29；Apple4664/Android2188/Windows3402本地化、3组fixture/40项引用、严格文档及差异检查通过。main@5684170b3ccf保留34项累计改动，无git add/提交/推送；所有本轮进程结束后，7份一次性日志、2个合成截图目录、临时启动器及本轮build目录移入唯一废纸篓目录，正式测试、依赖缓存、最终App/DMG与旧包保留。完整goal仍active，本轮progress。


### 2026-09-30 默认排序确认与整库维护核对（开始）

上一轮为progress：共享成员完整原生入口、692项回归/6项本地化/52张合成UI和独立测试包已完成。本轮保持34项累计工作区，独占PhotoDisplaySettingsPanel与对应UI测试/双语文案；默认排序变更确认沿已记录官方static事实实现，不改接口/存储/权限，取消保留草稿。整库重新索引/缺陷预览动作仍需浏览器只读补证；本次工具明确报告Mac锁屏，已异步请求解锁，没有绕过锁屏或猜测接口。不依赖浏览器的默认排序交互继续。


### 2026-09-30 默认排序变更确认验证

实际修改仅PhotoManagementPanel.swift的PhotoDisplaySettingsPanel、WorkspacePresentationTests.swift及两组中英文资源；沿原setDisplaySettings保存契约，不改Model/Repository/存储/权限。字段或方向变化时冻结原快照和目标值，弹窗显示目标字段/方向，最终确认才调用submitMutation；取消保留草稿；仅改分组、日期、时间或预览信息不额外确认。独立复核检查确认文案来自固定目标、取消零提交、再次确认仍保存原目标，以及普通设置原路径不变。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片默认排序|WorkspacePresentationTests/test照片显示设置' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-sort-confirm-verified`退出0，2项UI测试/20张合成截图通过；中英浅深色分别实际更改字段/方向、取消、再次保存并断言唯一固定命令。首轮新增测试错误使用不存在的菜单资源workspace.sort.name，导致找不到菜单项及无确认窗口2条断言失败；修正为原控件photos.folderSort.filename后通过，未修改实现规避失败或降低断言。确认弹窗合成位图的系统按钮文字不完整，已通过真实NSButton标题定位和点击验证按钮，不把位图当成完整系统绘制结论。

`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test显示设置|SynologyPhotosModelTests/test显示设置|DsmLocalizationTests'`退出0：4项XCTest（Repository3、Model1）与6项本地化通过，覆盖差量/默认目录排序、未知回执只核对、过期快照、月份和选择保持。仅UI确认变动，未重复或宣称本轮重新运行上一轮692项全量。`python3 tools/localization/check_localization.py`通过Apple4666/Android2188/Windows3402。没有真实NAS写入。

本轮只读入口复核：macOS登录组合根LoginViewModel.swift对Photos Repository传入deletionEnabled:true；Repository保留的默认false属于跨端注入参数，不是macOS未实测限制。当前设置菜单已包含全局、共享空间、共享成员、自动预览、个人识别、显示和重复项设置。此本地核对不能替代最终网页菜单审计，整库重索引/缺陷预览和完整相邻集合/格式优先级仍未完成。浏览器锁屏请求待答复，没有绕过锁屏或执行NAS探测写入。

PENDING_USER_VALIDATION：更改默认排序字段或方向，检查确认显示目标；取消后编辑值保留但NAS设置未变，再次保存与网页一致，个人历史月份不跳回最新。真实NAS效果沿既有显示设置验收，本轮不增加人工禁用。目标保持active，本轮progress。


### 2026-09-30 默认排序确认独立测试包

实际命令`PATH="/tmp/dsm-photos-sort-confirm-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-sort-confirm-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sort-confirm-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅指定已有依赖缓存和skipPackageUpdates；源码冻结后开始构建，期间只读核对及维护文档。成品21,503,209字节，1.0.11(21)、arm64、localtest；严格签名/Designated Requirement、专用Hardened Runtime临时权限、Sparkle实际library loaded、DMG checksum VALID通过，额外codesign --verify --deep --strict退出0；Info.plist、PlugIns=0及主程序确认资源键复核通过。没有安装/启动、覆盖旧包或正式发布。

官方包替代核对：从Synology官方归档下载1.9.1-10928 x86_64和1.7.0-0795 armada37xx公开包，标准tarfile/bsdtar无法读取，未取得网页代码；不解密、安装或执行。两份来源记录单独保存版本/下载来源/摘要和失败事实，不绑定用户NAS、不新增接口兼容结论。浏览器锁屏未绕过；完整目标继续active，本轮progress。后续优先在用户解锁后读取已登录网页补齐剩余请求。

本轮结束前，5份一次性日志、3个合成截图目录、工具启动器、本轮build以及2个官方包临时目录均移入唯一废纸篓目录；正式测试、最终App/DMG、此前包和依赖缓存保留。无git add/提交/推送，无NAS写入。


### 2026-09-30 浏览器恢复与自动预览最终调度（开始）

上轮因连续锁屏标为blocked；本轮重试Chrome成功，阻塞解除。保留main工作区37项累计改动，独占Photos Core任务优先级、Network候选映射、macOS Model相邻选择及对应测试/契约文档；不改存储、其他端UI或真实NAS内容。已沿同一环境只读官方react_bundle，确认前2/后3及小集合缩减、普通/HEVC实况/VC1/后台四级顺序，先据此补齐调度。没有生成或下载真实预览；整库维护请求已发现，需独立接入确认和结果核对，不能本轮直接宣称已完成。


### 2026-09-30 自动预览相邻范围与格式调度实现和验证

实际修改：Core/SynologyPhotos.swift增加向后兼容priority枚举/可选初始化参数；Network/SynologyPhotosRepository.swift用已读编码与实况来源映射1/2/3，后台默认4；macOS/SynologyPhotosModel.swift统一相邻候选为前2后3及网页小集合缩减，已加载完整集合按对应浏览类型循环，缺页不循环或主动加载；同级当前→next→prev→可见，高等级候选不能阻止继续寻找普通格式。保留原件/权限/重复保护、2秒去抖、串行处理、未知只核对与图库位置。没有新增用户文案、UI表单或NAS写方法，其他端UI/存储/工具链不变。

正式测试新增3项Model（完整相邻、小集合/视频排除、跨格式调度、缺页不预取）和1项Repository（实际编码映射/HEIC/VC1/后台），现有实况测试增加两级断言。旧5张照片顺序断言依据新网页证据从单邻居改为完整窗口，不删除或降低断言。首轮相关43项全过；独立复核将格式调度fixture改为真实可出现的当前VC1视频、可见HEVC视频、相邻普通照片组合，再执行完整回归。

实际命令：`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test可见自动预览|SynologyPhotosRepositoryTests/test自动预览|SynologyPhotosModelTests/test自动预览|SynologyPhotosModelTests/test可见自动预览'`退出0，43项通过。最终`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，696项XCTest（Repository442、Model197、Converter8、Events20、Appearance29）和6项本地化通过。无本轮UI布局改动，不重复运行截图测试；Swift Package编译/链接成功不代替正在进行的Release打包。

独立集成/只读对抗复核：优先级不写NAS、不改变任务身份/原件权限，准备和下载前后仍重新匹配整个候选；跨来源完成去重不因priority变化重传。同级保持候选源顺序，标准候选允许提前结束、高成本候选继续查询；普通共享目录不因此取得全库扫描权。边界按原项目数量缩减后过滤视频，预取不调用loadMore或loadPrevious；已有当前实况双单元不丢失。没有并发转换新增、存储迁移或人工待实测开关。

`python3 tools/localization/check_localization.py`通过（Apple4666/Android2188/Windows3402），`python3 tools/contract-validation/validate_fixtures.py`通过3组/40项引用，`python3 tools/codex/check_documentation.py --strict-release`和`git diff --check`通过。真实NAS、物理设备及其他端构建未验证。PENDING_USER_VALIDATION：开启自动预览，在历史月份预览普通照片/HEIC、HEVC/VC1视频和实况，检查邻居预览逐步补齐、少量项目无重复、未加载页不跳动、切换月份与权限变化无重复上传；回传脱敏版本、类型、步骤和提示，不需原件。

余项为整库维护原生入口和最终网页菜单审计；上传跨重启存储仍待此前独立授权。打包期间再次只读获取官方资源得到空文本，未新增状态字段证据；不把空资源推断为任何API行为，临时变量删除确认undefined并清空关闭控制台。首轮成功读取证据仍有效但只属static。本轮progress，完整goal保持active，无提交/推送。


### 2026-09-30 自动预览调度独立测试包

实际命令`PATH="/tmp/dsm-photos-preview-priority-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-preview-priority-20260930" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-priority-20260930" bash apple/Apps/DsmMac/package.sh`退出0。临时xcodebuild启动器只复用apple/.build依赖与skipPackageUpdates，未变工具链。冻结源码后构建，后续只追加文档和只读核对。

新DMG 21,509,854字节，1.0.11(21)、arm64、localtest。Release、严格签名/Designated Requirement、专用临时Hardened Runtime权限、Sparkle实际library loaded、DMG checksum VALID及额外codesign --verify --deep --strict全部通过。Info.plist核对正确，PlugIns=0；未自动安装启动、未覆盖旧包、未正式发布。完整696项/6项本地化范围见上节，无本轮UI布局改动，未重复截图测试；真实NAS与其他端构建未验证。

main@5684170b3ccf，仍保留37项累计改动，无git add/提交/推送。所有本轮进程结束后，2份测试日志、1份打包日志、临时启动器及本轮build移入唯一废纸篓目录；正式测试、最终dist App/DMG、此前成品与依赖缓存保留。目标active，本轮progress。


### 2026-09-30 整库维护波次（开始）

上轮progress：自动预览完整调度、696项/6项本地化与独立包通过。本轮保持37项累计工作区，独占Photos Core/Serving/Repository/Model/View/Panel、双语及相应测试/契约；接入当前个人/共享空间重新索引与缺陷预览生成，固定空间/身份、最终确认、串行提交和自动读计数，不刷新当前图库。已有公开契约扩展授权适用；不改存储、依赖、其他端UI，不执行NAS真实维护。


### 2026-10-01 当前空间整库维护实现、复核与本地验证

上一轮仅回答状态，为no progress；本轮重新核对工作区、失败编译日志和源码后继续。实际修改Core维护状态/服务/命令、Network空间路由及核对、macOS Model/View/Panel、双语资源和对应测试；同步稳定端点photos-library-maintenance、机器索引及五端影响。沿已授权的公开契约增量，不改存储、工具链、其他端界面或真实NAS内容。

个人/共享当前空间均提供重新索引和异常预览生成，后者按真实NAS has_h264能力开放，共享空间须管理员。弹窗只读、固定身份及空间确认；提交前重新检查空闲/权限，操作编号去重，失败回执与丢失回执分别处理，成功回执后自动回读对应计数。历史月份、当前选择与已加载照片保留。无人工未实测禁用，权限和防重复检查保留。官方全用户reindex_all_user欢迎流程未包含在本轮，仍是明确剩余。

独立集成及只读对抗复核：检查协议默认实现、不同空间路由、当前管理员与home能力、目标身份、H.264与重新索引互不误禁用、计数类型/负数、快照忙碌、同operation不同命令、成功/失败/未知回执、持续只读轮询、取消零写与历史位置。复用提交前后的访问代次检查和互斥，不改变NAS原件或权限。由于维护没有任务ID，计数只能证明当前阶段无待处理项；丢失回执即使计数归零也不能归因本次操作，可能持续未确认。这是实际协议限制，不伪装为已完成，也不自动重复维护。

首轮前次遗留编译错误为catch中的error遮蔽视图状态，改self.error后通过。新增7项Repository测试覆盖两空间/两动作、正计数到零、丢失回执、明确失败、外来身份/过期能力、真实权限及坏计数/缺API；新增2项Model测试覆盖2020.03月份、多选、加载页保持、持续核对及无效命令。`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test整库维护'`退出0，7项通过；完整`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，705项XCTest（Repository449、Model199、Converter8、Events20、Appearance29）和6项本地化通过。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test整库维护' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-maintenance-ui-final`退出0，1项UI/24张合成截图覆盖双语浅深色空闲、运行、受限、加载与错误，以及最终确认。首批截图发现刷新按钮误用不存在的photos.refresh，改为既有photos.library.refresh；末次实际点击开始、取消、再次确认，断言取消无命令、确认只产生固定reindex命令。末次仅修复UI资源引用，完整业务测试结果不冒称修复后重跑；UI重新编译及本地化扫描已覆盖。

`python3 tools/localization/check_localization.py`通过Apple4681/Android2188/Windows3402；`python3 tools/contract-validation/validate_fixtures.py`通过3组/41项引用；`python3 tools/codex/check_documentation.py --strict-release`和git diff --check通过。真实NAS维护/转换、物理设备与其他端构建未验证；本机测试不提升static证据。PENDING_USER_VALIDATION操作步骤与脱敏反馈范围见端点记录。

源码冻结后开始独立Release包，完成前不宣称打包成功。当前main累计37项改动保留，无git add/提交/推送、安装启动或正式发布。本轮progress，完整目标继续active；剩余全用户编解码器欢迎流程、最终网页菜单查漏和待独立存储授权的上传跨重启恢复。


打包期间最终审计的只读预查：官方自动预览记录还包含ConvertedFile.set_broken v3的非连接/超时失败上报，而当前Repository没有此调用。已实现的自动转换、调度和上传不能作为该异常分支已对齐的证据。下一轮需要复核官方错误分类、标记语义和恢复入口，决定原生后端对应的失败同步，不能直接把本机不支持/临时失败标记为NAS损坏。此项纳入最终查漏，当前不宣称无其他缺口。源码在打包期间保持冻结。


同轮只读复核发现原始删除需求仍有一项不完整：SynologyPhotosModel.automaticallyReviewDeletions仅按0.5/1/2/3/5/8秒执行六轮，结束后reviewDelayed仍要求手动重试，SynologyPhotosView仅展示reviewPendingDeletion按钮，没有类似globalSettingsReviewID的持续任务。因此短期删除自动核对与月份保持已实现，但长断线恢复后无需手动点击尚未完全满足。下一切片优先补macOS持续只读恢复和无手动要求文案、生命周期取消/防并发及长断线回归。此次整库维护包源码冻结，不将该缺口误报已修复；无需新接口或存储授权。


### 2026-10-01 整库维护独立测试包

实际打包命令`PATH="/tmp/dsm-photos-maintenance-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-library-maintenance-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-library-maintenance-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只指定已有apple/.build依赖缓存和skipPackageUpdates，不改工具链；打包期间源码冻结，只有文档与只读查漏。

成品21,608,749字节，1.0.11(21)、arm64、localtest。严格签名/Designated Requirement、专用Hardened Runtime临时权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist身份版本正确，PlugIns=0。未安装启动、覆盖旧包或正式发布。完整705项/6项本地化及1项UI/24张合成截图范围见上节；NAS维护与其他端构建未验证。

全部本轮进程结束后，一次性编译/测试/UI/打包日志、合成截图、临时工具启动器及本轮build移入唯一废纸篓目录；正式测试、最终dist成品、旧包和依赖缓存保留。main仍为5684170b3ccf，37项累计改动，无git add/提交/推送。完整goal保持active，本轮progress，下一步优先补长断线删除自动核对，其他明确剩余不变。


### 2026-10-01 长断线删除持续恢复（开始）

上一轮progress：整库维护、705项回归及独立包完成。本轮保留37项累计改动，独占macOS Photos Model/View、删除双语提示、对应Model/UI回归及说明。沿既有删除只读核对接口，初始六轮后按15秒持续单轮读取，浏览不重置分页，离开/禁用取消并丢弃晚到结果；重新进入继续未决目标。取消手动核对要求，保留重复删除保护。无API/存储/其他端UI/工具链变化，不执行NAS真实删除。


### 2026-10-01 长断线删除持续恢复实现与独立复核

实际修改SynologyPhotosModel/View、Model/UI测试与一组en/zh提示；复用原删除reviewDeletion，不变Core/Network契约。初始六轮后由视图.task定期执行单轮读取，无手动核对按钮。离开/取消/禁用以独立核对代次丢弃晚到结果，保留目标以便重进继续；后台不设置isDeleting，不阻止正常浏览，串行结果读取防重复唤醒并发。目录混选删除纳入同一持续管理核对标识，原globalSettingsReviewID随其职责扩展更名automaticMutationReviewID，只改内部引用。

独立集成/只读对抗复核发现后台确认与loadMore交错会覆盖已经修正的nextOffset；修正为删除命中当前分页窗口时取消旧偏移在途页，保持月份/内容，下次按修正偏移加载。新增确定性测试覆盖8次失败超过原6轮后自动恢复、离开/禁用时晚到确认、重复唤醒/取消、删除与在途旧页交错；补充混选目录未决操作自动轮询标识与文案断言。保留单项权限、确认与每项目一次提交，不修改其他端UI、存储、依赖或工具链。

首轮`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests/test删除|SynologyPhotosModelTests/test批量|SynologyPhotosModelTests/test持续核对|SynologyPhotosModelTests/test关闭模块'`退出0，13项通过。分页交错修正后完整回归709项XCTest和6项本地化通过；随后目录混选扩展与内部名称统一后再次运行相同全量命令，最终结果需以下记录确认。没有降低断言或删除既有测试。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片长断线删除|WorkspacePresentationTests/test照片月份跳转' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-deletion-continuing-ui`退出0，2项UI/8张合成截图：中英浅深色长断线提示且无手动核对按钮、历史月份静置不预加载、批量删除后位置保持。后续目录扩展未改变布局。真实NAS恢复与物理滚动仍PENDING_USER_VALIDATION，验证步骤见photos-item-deletion新增节。


最终回归命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，709项XCTest（Repository449、Model203、Converter8、Events20、Appearance29）和6项本地化全部通过。Apple4682/Android2188/Windows3402本地化、3组fixture/41项引用、严格文档及差异检查通过。无真实NAS删除/维护，其他端未构建。

源码冻结打包期间只读Chrome官方资源，已补证下一切片Wizard提示get/set/已读与全用户维护分流，及自动预览缩略图/视频分阶段失败标记和桥接错误例外；仅static，未执行真实请求。源代码不变，候选文档/索引追加；临时源码清空并关闭DevTools。全用户任务没有已证实终态，不能用个人计数冒充全用户完成。完整目标active，本轮progress。


### 2026-10-01 长断线删除恢复独立测试包

实际命令`PATH="/tmp/dsm-photos-deletion-continuing-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-deletion-continuing-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-deletion-continuing-20261001" bash apple/Apps/DsmMac/package.sh`退出0；临时xcodebuild启动器只复用已有依赖与skipPackageUpdates，不改工具链。

成品21,613,407字节，1.0.11(21)、arm64、localtest，包含整库维护及本轮持续核对。严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、DMG checksum VALID以及额外codesign --verify --deep --strict通过；Info.plist版本身份正确，PlugIns=0。未自动安装启动、未覆盖旧包、未正式发布。709项/6项本地化/2项UI具体范围如上，不代替真实NAS和其他端构建。

所有本轮进程结束后，5份一次性日志、合成截图目录、临时启动器及本轮build移入唯一废纸篓目录；正式测试、最终dist成品、旧包、依赖缓存和其他累计修改保留。main仍5684170b3ccf，37项累计改动，无git add/提交/推送；完整目标active，本轮progress。下一切片为已补证的新格式提示与全用户补预览，之后继续失败同步和最终审计，上传持久化待独立授权不变。


### 2026-10-01 新格式提示与全用户预览波次（开始）

上一轮progress：长断线删除完整修复、709项回归及独立包完成。本轮保留37项累计改动，独占Photos Core/Serving/Repository/Model/View/Panel、相关测试/双语与契约文档，沿已授权公开契约增量实现Wizard新格式提示、“稍后”已读及按管理员分流的全用户/个人预览提交。明确区分请求已接收和全用户后台完成，不拿个人计数推断全用户结果；未知回执不重放。无存储/工具链/其他端UI变更，不执行NAS真实写入。


### 2026-10-01 新格式提示实现与本地验证

前次状态答复只复述进度，属于no progress；本轮重验源码与失败日志后继续，不重复此前授权。新格式提示、稍后已读、管理员全用户/普通用户个人补预览的Core/Repository/Model/View/Panel已接入，新增12组双语资源。读取不写入；最终按钮固定身份/范围并重新检查，生成先取得接收回执再保存提示。部分成功继续只补保存提示，未知回执自动只读核对、不重发、不以个人计数冒充全用户终态。同会话已接收标记阻止未关闭提示再次生成；观察提示关闭后允许未来新提示。保留月份、选择和已加载内容；无持久化/依赖/工具链或其他端UI修改。

独立集成/只读对抗复核覆盖协议默认实现、身份与能力变化、无个人空间时管理员仍能处理全用户/普通用户只能稍后、取消或撤权后不追加提示写入、未知回执即使提示关闭也不误报接收、已接收但提示保存失败的部分重试、未知提示保留、同操作重复调用和未决互斥。五端影响和photos-library-maintenance机器索引同步；现有static证据不提升为NAS行为验证。

实际命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test新格式'`首轮7项通过；Model新格式3项通过。新增权限/取消测试后完整`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，721项XCTest（Repository458、Model206、Converter8、Events20、Appearance29）和6项本地化通过。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test新格式提示' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-codec-ui-final`退出0，1项原生UI/28张合成截图，覆盖中英浅深色管理员/个人/已接收/无需处理/受限/加载/错误，以及实际生成点击和Esc稍后动作。首轮点击坐标误用顶部纵轴，8条提交断言失败；据截图改为原生底部坐标后通过。期间新增测试误将服务方法写到access结构导致编译失败，修正为repository.managementFeatures后通过，未修改实现规避失败或降低断言。此前遗留编译日志的输入文件变动错误在冻结源码重跑后消除。

`python3 tools/localization/check_localization.py`通过Apple4694/Android2188/Windows3402；`python3 tools/contract-validation/validate_fixtures.py`通过3组/41项引用；`python3 tools/codex/check_documentation.py --strict-release`与git diff --check通过。真实NAS维护、物理操作及其他端构建未验证，由用户验收，无人工待实测禁用。源码冻结后开始独立Release打包，完成前不声明包可交付。main@5684170b3ccf仍保留37项累计改动，无提交/推送。


### 2026-10-01 新格式提示独立测试包

实际命令`PATH="/tmp/dsm-photos-codec-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-codec-prompt-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-codec-prompt-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时xcodebuild启动器仅复用apple/.build依赖缓存和skipPackageUpdates，未更换工具链；构建期间源码冻结，只做文档及只读官方静态核对。

成品21,705,865字节，1.0.11(21)、arm64、localtest。严格签名/Designated Requirement、专用Hardened Runtime临时权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist版本身份正确，PlugIns=0。未自动安装启动、覆盖旧包或正式发布。721项回归、6项本地化及1项UI/28张截图范围见上节，真实NAS与其他端构建未验证。

浏览器临时源码删除后确认undefined，清空控制台并关闭DevTools，未执行真实NAS写入或媒体下载。下一切片失败状态同步已定位原生转换/上传阶段及网页broken字段，仍未实现，不宣称完整复刻完成。工作区仍37项累计改动，main@5684170b3ccf，无git add/提交/推送。所有本轮进程结束后清理一次性日志、合成截图、启动器和本轮build，保留正式测试、最终dist、旧包、依赖缓存和其他累计改动。


### 2026-10-01 自动预览失败同步波次（开始）

上一轮新格式提示与独立包完成，属于progress。保留37项累计改动，本轮独占Photos转换错误分类、Repository自动预览失败同步、结果模型与macOS错误提示，以及对应正式测试和双语/契约记录。根据已记录static的set_broken v3及实际broken字段处理明确转换失败；不把取消、暂时断网、权限/候选变化或未知上传回执写成失败。结果仍表示生成失败，不计为生成成功。无存储/工具链/其他端UI改动，不执行真实NAS写入。


### 2026-10-01 自动预览失败同步实现、复核与验证

实际修改Network转换器错误分类、Repository失败阶段记录与set_broken、Core结果默认false标记、macOS结果提示及双语、正式测试；五端影响与机器兼容索引同步。明确转换失败才标记photo/video阶段，提交前复查原来源/权限/候选与访问代次，未知上传结果仍核对媒体。标记接收或真实broken核对成功仍返回生成失败，不计成功、不刷新历史月份；同编号只读，不重发。没有真实NAS操作、工具链/持久化/其他端UI改动。

独立集成/只读对抗复核覆盖个人/共享路由、单元与Item区分、photo/video分别失败、转换与权限/候选变化竞态、上传回执未知不标记、取消/资源/编码器问题分类、同编号去重和后台缺少直接状态证据时保留pending。可见任务丢失回执不使用UI默认broken或待处理批次消失作为完成，只接受原单元实际尺寸/视频状态。生成失败后继续处理其他项目；界面提供已有“重建预览”恢复路径。

首轮43项相关测试的前身失败包括：对GET媒体请求错误使用POST body解码导致6条断言；修正为按请求类型解析后，又发现无效视频字节由系统返回AV未知错误而非确定转换失败。保留未知错误不标记，将明确视频失败fixture改为可解析但无视频轨道的合成MOV；不降低断言、不扩大分类迎合测试。最终`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test自动预览|SynologyPhotosRepositoryTests/test可见自动预览|SynologyPhotosPreviewConverterTests|SynologyPhotosModelTests/test自动预览已同步失败'`退出0，43项通过。

完整`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，728项XCTest（Repository463、Model207、Converter9、Events20、Appearance29）与6项本地化通过。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test自动预览失败恢复提示' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-failure-ui`退出0，1项UI/4张中英浅深色截图；已查看英文长提示，恢复说明可见，月份2020.03保持。

`python3 tools/localization/check_localization.py`通过Apple4695/Android2188/Windows3402；`python3 tools/contract-validation/validate_fixtures.py`通过3组/41项引用；`python3 tools/codex/check_documentation.py --strict-release`与git diff --check通过。源码冻结后开始Release包，未终止前不宣称包已完成。真实NAS由用户验证，不提升static等级。

### 2026-10-01 最终菜单查漏第一部分（未完成）

构建期间只读Chrome官方照片页面，读取标签分类内的批量操作菜单、相册创建/排序菜单、个人设置全部字段；未点击生成、删除、保存或修改控件，最后Esc退出设置。没有导出HAR/响应或保存用户截图。

| 本轮网页功能 | 当前原生证据 | 核对结果 |
| --- | --- | --- |
| 加入相册、标签、评级、日期、生成预览、删除 | PhotoManagementKind.selectionCases、SynologyPhotosView选择工具栏与既有删除流程 | 已有对应入口及命令 |
| 原始文件/压缩JPEG下载 | Photos Model saveSelection与格式选择、Network download | 已有对应流程 |
| 普通/条件相册创建、相册列表多字段排序/方向 | PhotoManagementPanel条件与普通相册表单、Core列表排序枚举 | 已有对应入口 |
| 个人日期/时间、预览信息、时间线分组、默认排序 | PhotoDisplaySettingsPanel | 已有对应字段与排序变更确认 |
| 上传/移动复制重复项策略、自动预览、个人识别、重新索引 | PhotoDuplicateSettingsPanel、PhotoAutomaticPreviewSettingsPanel、PhotoRecognitionSettingsPanel、PhotoLibraryMaintenancePanel | 已有对应入口 |
| 主题外观 | MacAppearanceStore/App设置 | 采用原生App整体外观，不修改浏览器外观偏好 |
| 选中照片直接“创建共享链接” | 原生selectionCases无sharing；已有createAlbum仅创建，sharing表单要求已存在album | **新发现未完成**：需要补直接选片分享组合流程，不能以先建相册再找分享设置代替 |

剩余审计仍包含其他分类/目录/预览上下文和共享/全局设置最终复核；本轮不能宣称菜单全部查漏完成。下一切片优先补选片直接分享，需只读核对官方创建及公开前顺序，不触发真实共享写入。上传队列跨重启持久化仍待此前独立授权。完整目标active，本轮progress。


### 2026-10-01 自动预览失败同步独立测试包

实际命令`PATH="/tmp/dsm-photos-failure-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-preview-failures-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-failures-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只复用已有依赖缓存及skipPackageUpdates，未改工具链；源码冻结后构建，期间只有只读审计及文档。

成品21,701,299字节，1.0.11(21)、arm64、localtest。Release、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist正确，PlugIns=0。未安装启动、覆盖旧包或正式发布。728项/6项本地化/1项UI范围见上节，不代替真实NAS与其他端构建。

所有本轮进程已结束，清理一次性测试/UI/打包日志、合成截图、临时启动器和本轮build；正式测试、最终App/DMG、旧包、依赖缓存与37项累计工作区改动保留。main@5684170b3ccf，无git add/提交/推送。下一切片选片直接分享需要静态补证及组合状态处理，完整目标尚未完成。


### 2026-10-01 选片直接分享波次（开始）

上一轮仅核对并答复剩余范围，为no progress；本轮重新检查源码后开始实现。范围为macOS选择工具栏、固定选片的创建/分享连续窗口、创建相册的持续只读核对及正式测试/双语文案。复用已记录NormalAlbum.create与既有完整分享表单/结果校验，不新增接口、存储或其他端UI。第一步经用户确认建立私有相册，确认成员后在同一窗口进入分享设置，最终保存才公开；中途取消保留私有相册。真实NAS验收由用户执行，不触发真实写入。最终菜单查漏及上传跨重启恢复仍未完成。


### 2026-10-01 选片直接分享实现与复核

新增选择工具栏、照片右键（已选照片使用整组快照）和预览窗口入口；PhotoSelectionSharingPanel先确认私有相册，沿返回编号及成员核对后在同一窗口打开既有PhotoManagementPanel分享表单。取消设置保留私有相册，不删除原件、不提前公开；分享完成沿既有managementLink展示链接。创建及分享的未知结果纳入每15秒持续只读核对，不重复提交。共享来源的相册分享读取个人相册能力，避免因当前共享空间缺少sharing标记而错误禁用保存。无新API、依赖、存储、其他端UI或真实NAS写入。

独立集成及只读对抗复核：打开窗口只读；固定所选照片；预检失败允许重试，提交后未知只回读；仅confirmed且返回相册才进入分享；创建取消不回滚已确认私有相册；最终公开仍经过既有权限/原分享状态/成员及密码有效期检查、关闭后配置再开启与结果回读；历史月份及已加载照片保持。入口按实际能力开放，无待实测白名单。真实回执完全丢失且缺少创建编号时仍无法按名称猜测成功；关闭应用后的恢复不在本轮新增能力中。

聚焦3项创建Model测试通过；最终完整`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，729项XCTest及6项本地化通过。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test选片直接分享' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-selection-share-ui-click`退出0，1项原生UI、40张中英浅深色/个人共享合成截图；覆盖打开不写、失败重试、等待不重复创建、同窗配置、最终确认才分享及链接返回，已查看英文暗色与共享选片最终设置截图。

测试修正记录：初次合成窗口透明背景已补显式窗口背景；旧密码测试坐标超出菜单，修正到实际控件内部；新分享测试先误用NSButton及无障碍协议查找SwiftUI单选项，发生查找/编译失败，移除该尝试，结束旧文本编辑后点击实际单选标签，最终写入及链接断言通过，没有删除或降低断言。

本地化Apple4700/Android2188/Windows3402及契约3组/41项引用通过；Chrome扩展列标签仍连接超时，不是锁屏证据，也不作为暂停实现的原因。最终菜单查漏未完成，不能宣称完整网页对齐；上传跨重启存储仍待此前独立授权。

PENDING_USER_VALIDATION：使用本人可分享的少量测试照片，分别在个人/共享空间从时间线历史月份选择，打开创建共享链接并命名；确认创建后应在同一窗口配置访问范围、成员、密码和有效期，保存后应可复制对应链接且照片列表保持原月份。另一次在分享设置阶段取消，应只留下私有相册。断网恢复只应继续核对原操作，不重复建立相册；如失败，请返回去除名称、地址、密码和链接的提示及操作阶段。


最终UI复验：`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test选片直接分享|WorkspacePresentationTests/test分享密码' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-selection-share-ui-delivery`退出0，2项、42张合成截图通过；英文暗色初始按钮/说明和共享来源公开范围均已查看。双语检查、严格文档预检、git diff --check通过。源码冻结后开始独立Release打包，完成前不把旧包当成本轮成品。


### 2026-10-01 选片分享独立测试包

实际命令`PATH="/tmp/dsm-photos-selection-share-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-selection-sharing-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-selection-sharing-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器只复用已有apple/.build依赖缓存和skipPackageUpdates；源码冻结后构建，未改工具链。

成品21,757,043字节，1.0.11(21)、arm64、localtest。Release、严格签名/Designated Requirement、专用Hardened Runtime测试权限、Sparkle实际library loaded、DMG checksum VALID通过；额外codesign --verify --deep --strict退出0，Info.plist身份版本正确，PlugIns目录为空。未安装启动、覆盖旧包或正式发布。实际验证729项XCTest、6项本地化、2项UI/42张合成截图，真实NAS未验证。

工作区main@5684170b3ccf保留37项累计改动，无git add、提交、推送。所有本轮运行进程已结束；清理本轮临时日志、合成截图、启动器和build，保留正式测试、最终App/DMG、旧包、依赖缓存及其他累计改动。网页最终菜单查漏与上传跨重启恢复仍未完成。


### 2026-10-01 最终菜单复核第二部分（开始）

上一轮选片分享实现、回归与独立包完成，属于progress。本轮先保留37项累计改动并只读复核网页菜单。Chrome扩展连接仍不可用，原生可访问性方式恢复操作；鼠标切换设置标签无效，键盘聚焦+Return成功显示共享/全局内容。当前共享空间关闭，仅观察启用入口，不启用；全局显示个人/共享识别总开关、普通用户分享、访客信息、排除扩展名，均需与现有原生实现逐项对应。不得把这些UI观察提升为写接口行为验证。仍不执行真实NAS写入或原件下载，不因实机缺口禁止已有功能。


### 2026-10-01 独立新建文件夹波次（开始）

上一目标轮只核对并回复状态，属于no progress；本轮保留37项累计文件，开始实际实现独立新建文件夹。范围限macOS表单、当前目录入口、确认后目录分页重读、双语与聚焦测试，复用已实现createFolder及身份/权限/防重复/结果核对；不新增公开契约或持久化、不修改其他端UI。官方静态菜单包含create_folder，现有上传创建目录不足以替代独立入口。完成后应保持当前目录、照片与选择，未知结果持续自动核对，真实NAS验收后置用户。

第二轮官方静态审计发现：NormalAlbum.create选片分享携带shared=true，并读取temporary_shared；取消临时分享时先停止分享再删除临时相册，停止时可NormalAlbum.copy保留副本。冻结相册读取freeze_album/cant_migrate_condition/condition_object，支持NormalAlbum.set_unfreeze或重新编辑条件。当前模型未表示这些状态，尚未实现，不据已有普通相册分享宣称完成。后续独立契约切片须将接口与五端影响登记后实现；这里只列发现，不提升任何环境验证等级。另确认新建目录、缩略图大小与任务完成后打开位置/前往相册等菜单；任务菜单不得误记为预览菜单。上轮浏览器临时脚本和菜单数组已删除并确认undefined，控制台清空、开发者工具关闭；未产生真实NAS写入。


### 2026-10-01 独立新建文件夹实现与验证

- PhotoManagementPanel新增createFolder表单，显示固定父目录，沿用名称校验与实际权限；SynologyPhotosView在当前非筛选目录（含空目录、根目录及共享空间）展示新建入口，时间线/相册不提供含糊目标。
- SynologyPhotosModel确认创建后只按原方向重读已展开的目录分页，不刷新照片、不清空选择、不跳转目录；等待确认允许浏览，迟到结果不污染其他目录或同编号相册。未知结果沿原操作编号持续自动回读，无重复创建。列表读取失败明确告知已创建，重置目录分页偏移，不诱导重发写入。
- 复用已有Foto/FotoTeam Folder.create契约；不新增依赖、公开接口、存储结构、版本或其他端UI，保留此前Mobile两行改动。正常权限/预检/确认/结果检查保持，没有待实测人工禁用。
- 独立只读集成复核覆盖：固定父目录与空间、根目录/筛选状态、未知回执/重复提交、回读失败与已成功写入分离、目录分页偏移、后续页去重、相册导航迟到结果、上传目录创建原流程不清空照片。正式Repository测试继续覆盖编号/父目录/名称/权限匹配以及无回执不按同名追认。

实际命令与结果：

1. `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests/test新建目录|SynologyPhotosRepositoryTests/test创建目录|SynologyPhotosRepositoryTests/test共享创建目录'`退出0，6项通过。
2. `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test独立新建目录|WorkspacePresentationTests/test主文件夹页面' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-create-folder-ui`退出0，2项原生UI、12张合成截图。空名称按钮不提交、实际输入及回车只提交固定目录一次；已查看英文暗色表单与中文浅色主页面。
3. `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，732项XCTest及6项本地化通过。
4. `python3 tools/localization/check_localization.py`通过Apple4703/Android2188/Windows3402；`python3 tools/contract-validation/validate_fixtures.py`通过3组/41项引用；`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。

PENDING_USER_VALIDATION：用户在有创建权限的个人/共享测试目录中打开新建文件夹，取消应不创建，确认后出现目标目录且现有照片和选择保留；多页目录继续加载不漏项。创建时断网恢复仅自动核对原操作，不重复创建；期间切换相册不会被结果带回目录。返回脱敏操作阶段、提示与套件版本即可，无需真实路径/照片/凭据。真实NAS写入测试为零，不提升static等级。

源码冻结后构建独立Release包，完成前不宣称可交付。完整目标未完成：临时分享取消/停止保留副本、冻结条件相册、缩略图大小、分享列表快捷管理、任务完成后导航/管理、待此前独立存储授权的上传重启恢复及最终菜单审计仍保留。


### 2026-10-01 独立新建文件夹测试包

实际打包命令`PATH="/tmp/dsm-photos-create-folder-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-create-folder-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-create-folder-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时工具启动器只复用已有apple/.build依赖缓存和skipPackageUpdates；构建期间源码冻结，未改工具链。

成品21,791,872字节、1.0.11(21)、arm64、localtest。Release、严格签名/Designated Requirement、专用测试Hardened Runtime权限、Sparkle实际library loaded、DMG checksum VALID通过；额外`codesign --verify --deep --strict`退出0，Info.plist身份版本正确，PlugIns为空。未安装启动、覆盖旧包或正式发布。实际NAS写入为零，用户验收条件见上节。

main@5684170b3ccf及37项累计改动保留，无git add、提交、推送。所有本轮进程已结束；临时测试/UI/打包日志、合成截图、启动器与本轮build移入唯一废纸篓目录，保留最终dist、旧包、正式测试与依赖缓存。下一步继续临时分享契约和完整生命周期；完整目标active，本轮progress。


### 2026-10-01 临时分享契约波次（开始）

上一目标轮独立新建文件夹及可用测试包交付，属于progress。本轮先实现临时分享生命周期依赖的最小领域/Repository契约：创建临时相册、复制为普通相册、只删除已停止分享的临时相册；随后接入macOS组合流程。用户已授权功能对齐所需共享契约扩展；影响为Apple共享枚举匹配和五端实现计划，无数据存储迁移。回滚移除本轮新命令与入口，不改变普通相册契约。预读身份/所有权/临时标记，写入沿操作编号去重，未知结果只读核对，复制完整成员确认前不允许组合流程清理来源。静态发现不替代真实NAS验收，不增加待实测禁用门禁。


### 2026-10-01 临时分享底层实现、复核与验证

实际修改Core SynologyPhotosManagement（3个新命令、SharingState可选isTemporary）、Network SynologyPhotosRepository（静态端点、最小album.id回执、完整成员快照、临时清理前置条件）、Repository正式测试及五端影响/兼容记录。本轮不改macOS或其他端UI、不增持久化/依赖、不正式发布；保持37项累计文件和先前用户改动。

关键决策：创建需非空选片、个人分享能力和合法用户；普通createAlbum语义不改。副本只读保存来源完整分页身份，核对不同新编号、名称、所有权、非临时且非共享状态及全部成员；复制本身绝不停止/删除来源。清理只允许所有者的临时相册且已停止分享，原分享状态包含临时标记参与摘要，缺字段/权限变化/旧快照拒绝。删除只调用Album，不调用Item。回执丢失不按名称找回、不重发写入；返回的创建/复制编号只需最小字段，其余通过读取确认。

只读集成/对抗复核覆盖普通相册误清理、分享未停、丢失临时字段、所有者变化、同名/同编号冒认、复制后成员不完整、跨页缺项、写回执缺失及重复调用。跨页去重用按当前页编号查字典，避免每个旧成员反复扫描新页。复用已有相册成员读取，不下载照片原件或扩大原件权限。组合流程尚未完成，不能据底层测试宣称取消清理/保留副本交互已可用。

实际验证：

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test创建相册|SynologyPhotosRepositoryTests/test读取分享'`退出0，3项既有测试通过，macOS Swift Package目标编译通过。
- 首轮`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test临时分享'`执行7项、2条断言失败：测试将JSON数组item/id错误写成标量期望；按已记录接口改为[7]/[3]精确断言，不修改实现或降低断言。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test临时分享|SynologyPhotosRepositoryTests/test创建相册'`退出0，8项通过；最小复制回执只含album.id。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test临时分享副本核对跨页'`退出0，1项通过，覆盖501成员完整/末页缺失，源和副本均读取offset 0/500。
- 最终`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0，740项XCTest及6项本地化通过。此前739项回归也通过，新增分页测试和线性去重复核后运行本次最终门禁。
- 本地化Apple4703/Android2188/Windows3402、契约3组/41项引用、严格文档预检、git diff --check通过。没有执行新UI测试、Release打包、iOS或其他端构建；不以本次Package测试替代这些验证。

PENDING_USER_VALIDATION：组合界面完成后，由用户在少量专用测试照片上验证创建、取消、停止且保留副本、断网恢复、普通相册不会误清理；分享权限和副本成员逐项核对，原件应保留。只返回脱敏阶段、提示与版本，不提供私有链接/路径/凭据。当前未执行真实NAS写入，不提升static证据等级，也未增加人为待实测功能锁。

下一切片（必须完成，非可选）：macOS模型持有临时分享生命周期，创建过程中关闭窗口也不能遗失清理意图；取消后按确认的固定临时相册停止/清理，停止保留副本按复制确认→停止→清理推进，未知结果只核对原操作。清理前需再次核对已保留副本与来源的成员一致，避免复制后新加入成员被遗漏；现有三个独立命令尚未提供此组合证明，不得直接串接当作完整闭环。接入分享表单、关闭/Esc和状态恢复，补模型与实际UI测试后再交付新包。冻结相册、缩略图大小、分享列表快捷管理、任务后续操作、上传跨重启存储授权与完整菜单审计仍保留。

所有本轮进程已结束，临时日志移入唯一废纸篓目录，正式测试、源码、旧包和缓存保留。main@5684170b3ccf，未git add/提交/推送。完整目标active，本轮progress。


### 2026-10-01 临时分享组合流程（开始）

上一轮Core/Repository三项操作和740项回归通过，属于progress。本轮独占macOS模型/分享窗口、相关测试/双语，以及清理前副本成员复查的兼容增量；保留37项累计改动。组合模型持有取消意图与固定相册，不依赖已关闭表单的State；复制确认→停止分享→清理，未知结果只回读原操作，普通相册不进入临时清理。清理命令增加可选preservedCopyID，核对已保留普通私有副本与当前来源完整成员一致，再允许删除临时相册。无存储迁移，五端影响与上一契约切片相同；真实NAS由用户验收。


### 2026-10-01 临时分享完整流程收尾与独立复核

上一目标轮仅回复剩余清单，为no progress；本轮重新核对源码、37项累计差异与已结束测试句柄，继续完成组合流程。保留所有既有改动及Mobile两行，不新增工具链、存储或其他平台界面。实际用户NAS写入为零，用户实测不构成人工禁用条件。

模型持有创建取消意图与copy→stop→delete阶段；表单关闭/Esc不丢失意图，未知操作沿原编号持续自动核对，不重发。阶段仅在确认后推进，明确拒绝停在原阶段，不因完成回调重复创建；离开图库暂停，回到图库继续，关闭模块不触发新写入。普通相册或未知临时标记不能进入清理。副本回执编号保存到deleteTemporaryAlbum的默认可选preservedCopyID，清理前再次核对所有者、非临时非共享副本、源/副本全部分页成员及来源分享快照；成员变化保留双方并显示原因。明确失败且无在途写入时可选择“保留现有相册”结束清理，不声称已恢复或停止分享；未知结果不能通过此动作丢失核对。

新增及更新界面：选片创建临时相册、同窗分享配置、停止时的停止/保留副本/取消确认，以及失败重试/保留现有相册。已有分享范围不变但缺链接时仍取得链接，不把缺链接的空操作当保存成功。中英资源同步。保持历史月份、照片、选择；迟到相册结果不会误改同编号文件夹。

独立集成/只读对抗复核覆盖创建前后取消、重复点击、复制失败和未知、完整成员与所有者变化、清理仅删除相册、不调用原件删除、普通相册拒绝、跨页缺项、缺失回执不按同名追认、阶段终态推进、列表与文件夹编号隔离及关闭模块。真实NAS、重启恢复不由本地测试保证。

已执行：15项临时分享Model/Repository聚焦测试通过。首轮4项UI中3项通过，停止确认用例的点击坐标落在短选项文案外；修正测试点击位置后，该用例中英/浅深色/三选项12种组合通过（未修改产品行为来迎合测试）。正在执行最终完整回归与合并UI复验，终态结果另记。

PENDING_USER_VALIDATION：使用允许共享的专用照片集测试个人/共享选片，创建中关闭及设置中Esc后确认临时相册清理、原件仍在；保存后链接可用；停止时分别选择直接停止、保留副本、取消，副本成员应完整且原件不变。断线恢复不应重复创建/停止/删除；复制后更改源或副本成员应保留双方并说明原因。历史月份和选择不应跳回最新。仅回传脱敏版本、步骤和错误提示，不回传照片/地址/账号/凭据。影响范围限临时分享及已有分享缺链接的保存路径。


### 2026-10-01 临时分享完整回归结果

实际命令及终态：

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests|SynologyPhotosModelTests|SynologyPhotosPreviewConverterTests|SynologyPhotosPreviewEventsTests|MacAppearanceTests|DsmLocalizationTests'`退出0：748项XCTest（Model217、Repository473、Appearance29、Converter9、Events20）及6项本地化通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test临时分享|WorkspacePresentationTests/test选片直接分享|WorkspacePresentationTests/test分享密码' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-temporary-flow-ui-final`退出0：4项UI、74张合成截图。覆盖选片分享8组合、创建关闭/设置Esc8组合、停止确认12组合及密码表单。实际按本地化NSButton标题触发三种确认动作并断言写入序列。合成截图的系统确认弹窗存在按钮文字绘制不完整，不能据该截图声称真机视觉验收；英文浅色设置表单已查看，系统弹窗最终外观由用户验证。
- `python3 tools/localization/check_localization.py`通过：Apple4715、Android2188、Windows3402；双语、资源引用、参数与硬编码检查通过。
- `python3 tools/contract-validation/validate_fixtures.py`通过3组、41项引用；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

新增“明确失败可保留现有相册，未知结果不能放弃核对”回归，不将异常状态转为静默成功。源码冻结后开始Release构建；构建期间不修改编译输入，完成前不宣称新包已交付。完整目标仍active；剩余冻结条件相册、缩略图大小、分享列表快捷管理、任务后续导航/单项操作、待此前存储授权的上传重启恢复与最终菜单查漏。


下一切片依赖定位（尚未实现）：Collection与ManagementAlbum需表示freeze_album/cant_migrate_condition，不能仅用type==condition判断迁移菜单；当前albumCondition只接受condition并调用ConditionAlbum.get，冻结项需沿已证实的Album.get(condition_object)单独读取且确认字段含义。View的相册右键菜单及Panel既有条件编辑表单为复用入口；set_unfreeze保存普通相册与条件重建→确认→清理旧项须分别证明最终状态。现有static记录不足以确定全部迁移字段类型与菜单分支，下一波次先补官方只读证据，不据当前普通条件编辑功能宣称冻结相册完成。


### 2026-10-01 临时分享独立Release包交付

实际命令`PATH="/tmp/dsm-photos-temporary-flow-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-temporary-sharing-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时启动器仅使用既有Xcode和apple/.build缓存、skipPackageUpdates，未更换工具链。编译期间源码冻结，仅修改文档和只读检查。

DMG为`apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001/LanStash-1.0.11-arm64.dmg`，21,974,554字节；同目录`LanStash Test.app`。版本1.0.11(21)、arm64、标识io.github.qwertyuiop1995.dsmnativeclient.macos.localtest。Release、严格签名/DR、专用临时权限和Hardened Runtime、Sparkle实际library loaded、DMG VALID通过；额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-temporary-sharing-20261001/LanStash Test.app'`退出0，PlugIns数量0，无本地磁盘挂载扩展。未安装启动、覆盖旧包、提交推送或正式发布。

工作区main@5684170b3ccf保留37项累计改动。本轮进程均终止后，将一次性测试/打包日志、74张合成UI及此前本轮截图、工具启动器和本轮build移入独立废纸篓目录；保留新旧dist、正式测试、依赖缓存、全部其他改动。目标未完成，本轮progress；继续冻结条件相册及其他剩余功能。


### 2026-10-01 缩略图大小波次（开始）

上一目标轮完成临时分享及新包，属于progress。本轮Chrome原生工具报告Mac锁屏并要求手动解锁，已发异步问题，不绕过。冻结条件相册保留待官方细节补证，同时推进无浏览器依赖的缩略图控制。范围为macOS Photos模型中的会话尺寸选择、原生滑杆与增减按钮、图库布局和可见照片锚点，以及双语和正式UI测试；不改API、其他端UI或持久化。沿已有列宽150–220作为默认，提供更密/更大多级布局。不得把本轮当作冻结相册完成。

对齐账本：官方静态菜单已记录缩略图大小入口，原生当前columns固定150–220；目标为用户可调整网格密度，键盘/触控/无障碍可用，浅深色正常。照片、相册/目录封面和分类卡片沿同一尺寸；分享文字列表不显示无意义滑杆。调整只改变布局，选中照片和历史月份保留，按原可见照片恢复锚点，不调用refresh。无新契约或安全写入，当前验证未运行。非目标为跨重启尺寸记忆、冻结相册实现、上传队列存储和其他端界面；没有存储迁移，回滚本轮控件/布局与会话属性即可。


### 缩略图实现与聚焦复核

会话级PhotoThumbnailSize五档（minimumWidth 110/150/190/230/270，maximum比minimum大70），默认保持150–220。Model存放选择但不写UserDefaults/NAS；同一模型切换照片页保留，重启恢复不承诺。View底部原生Slider和放大/缩小按钮，有双语标题/帮助/档位无障碍值、首尾禁用和方向键焦点；分享文字列表隐藏，进入分享相册后显示。相册/目录/分类封面高度同步，文本区域保持空间。只对照片网格改变列宽，不改变照片数据或列表请求。

原可见照片通过命名滚动坐标与PreferenceKey定位，只保存首个可见照片编号，避免每次滚动保存整份几何字典触发视图更新。尺寸改变后待布局更新再scrollTo原照片；不调用refresh，不改日期/多选。没有动画，不依赖降低动态效果偏好。加载/空/错误状态仍可调整尺寸并在随后内容出现时应用；筛选结果复用同一网格。

首轮测试编译因新合成服务缺searchTimeline方法失败，已补测试协议实现；第二轮发现SwiftUI Slider不是NSSlider子视图，改用真实坐标和键盘事件。随后暴露点击不稳定获得焦点，产品增加显式焦点和onMoveCommand；测试照片从40增为80，确保所有待验尺寸确实可滚动，保留原位置断言。修正后中英/浅深色按钮、上下限、方向键及历史位置保持4组合通过。最终增加拖动滑杆两方向覆盖，终态另记；不能以早期失败用例宣称全部通过。

独立复核范围：没有新增NAS写入/契约/存储，尺寸选择不触发refresh、月份或选择变化；普通/分组网格共享列宽，封面高度避免大图溢出固定卡片；仅文字分享列表不提供无效控件。控件使用系统Slider，按键/帮助/无障碍双语；真实触控板与VoiceOver仍PENDING_USER_VALIDATION。最终验证和包未完成前，下方临时分享包仍是最新成品。


### 缩略图交互最终验证

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片缩略图' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-thumbnail-ui-final`退出0，1项UI、8张截图通过。以80张合成照片验证真实按钮、拖动到最大再返回默认、点击聚焦后方向键调整、列表高度随列数变化、滚动位置不回顶部、2020.03月份和选择保留，以及尺寸调整前后列表读取次数相同。中英/浅深色4组合，已查看英文暗色图库与中文浅色滑杆截图。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test照片月份跳转|WorkspacePresentationTests/test照片页双语主题' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-thumbnail-ui-regression`退出0，2项UI、16张截图通过。覆盖既有月份跳转静置不向前加载、删除后保持月份、窄窗口筛选和选择。

`python3 tools/localization/check_localization.py`通过Apple4719/Android2188/Windows3402，双语/参数/硬编码无新增问题；严格文档检查与git diff --check通过。当前没有更改Network或Core契约，本轮聚焦macOS模型、外观和本地化回归，不借重跑无关网络用例扩大结论。

PENDING_USER_VALIDATION：打开时间线跳到历史月份，在中间位置拖动底部滑杆，照片应变大/变小并保持当前月份与选择；相册、文件夹和分类封面同步改变，分享文字列表不显示滑杆。使用触控板拖动、Tab聚焦及方向键，VoiceOver应读出大小和档位。切换页面仍保持当前会话设置，重启恢复不在本轮范围。实际数据/物理设备未由Agent操作，回传脱敏操作、显示差异与系统版本即可。


`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests|MacAppearanceTests|DsmLocalizationTests'`退出0：246项XCTest及6项本地化通过。不存在运行中的旧测试后，冻结源码开始独立Release打包，沿既有Xcode和依赖缓存，未改工具链或版本号。

下一独立切片定位：分享列表已有withOthers（由我共享）/withMe/requests三类，但现有行仅打开相册/复制已有URL，普通共享相册条目并不映射分享链接。可复用PhotoManagementPanel.sharing及既有albumSharing权限/状态读取，从withOthers列表直接打开管理；不能把withMe或缺albumID项当作所有者，也不能在列表展示时触发创建链接。管理结果需局部同步列表或按原排序重读，保持当前范围，临时停止沿已完成生命周期。这些只是实现依赖定位，尚未实现，不从剩余清单删除。


### 2026-10-01 缩略图大小独立Release包交付

实际命令`PATH="/tmp/dsm-photos-thumbnail-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-thumbnail-size-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-thumbnail-size-20261001" bash apple/Apps/DsmMac/package.sh`退出0。启动器仅复用既有Xcode及apple/.build缓存、skipPackageUpdates。构建期间源码冻结，只有文档及只读检查。

最终DMG为`apple/Apps/DsmMac/dist/photos-thumbnail-size-20261001/LanStash-1.0.11-arm64.dmg`，21,996,598字节；同目录`LanStash Test.app`，1.0.11(21)、arm64、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest。Release、严格签名/DR、专用临时权限/Hardened Runtime、Sparkle实际library loaded、DMG VALID通过；额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-thumbnail-size-20261001/LanStash Test.app'`退出0，PlugIns数量0。无本地磁盘挂载扩展，未安装启动、覆盖旧包或正式发布。

全部本轮进程结束后清理本轮测试/打包日志、一次性合成截图、启动器和build至独立废纸篓目录，保留新旧dist、正式测试、依赖缓存及37项累计改动。main@5684170b3ccf，无git add/提交/推送。浏览器解锁问题仍待用户回复；继续无依赖的分享列表快捷管理等工作，不因该单点暂停完整目标。本轮progress，完整目标尚未完成。


### 2026-10-01 分享列表快捷管理波次（开始）

上一目标轮缩略图大小及独立包已交付，为progress。本轮保留37项累计改动，范围为macOS由我共享列表的管理入口、分享保存/停止结果后的列表同步、失败只读重试、正式测试与双语文案。复用PhotoManagementPanel.sharing、albumSharing与既有分享/临时清理命令，不增加API或存储，不触碰其他端界面。

对齐账本：现有列表只能打开相册，网页菜单审计确认存在直接管理缺口；目标为由我共享行直接打开管理，读取实际状态，保存仍须用户操作，停止临时分享沿已确认的复制/停止/清理流程。与我共享、照片请求、缺编号和真实能力不足项不能借此获得所有者入口。操作确认后按当前分享范围/排序重新读取已加载列表窗口；未知结果不移除、不重复提交，读取失败保留列表并可只读重试；迟到结果不能覆盖已切换页面。契约无增量，沿既有权限/去重/结果核对；当前未运行验证。非目标为未补证的冻结相册、上传恢复存储、其他端UI及NAS真实写入。


### 分享列表实现与独立复核

新增sharingManagementTarget限定当前“由我共享”列表实际条目、正数albumID和实际分享能力，View行内直接打开既有分享表单；表单仍通过albumSharing检查实际所有者，打开/取消只读。withMe及照片请求不获得所有者入口。保存/停止仍沿既有确认与操作编号；未知结果先保持旧条目，确认后按原排序重新读取已加载窗口，保留当前分享范围，不打开相册或刷新时间线。

refreshManagedSharingList在完整读取后替换列表，期间不清空已有内容；generation防止迟到分页覆盖新页面，跨页重复说明期间重排而非完整快照，保留旧列表并可只读恢复。失败时停止沿旧偏移继续分页，提供“刷新”仅重读，不再次分享/取消；成功恢复正常分页。临时分享组合在最终清理后刷新，避免复制/停止每一步重复重读列表。无新持久化或公开契约，未修改Network及其他端。

独立集成/对抗复核覆盖未持有条目、withMe/请求/缺编号、实际所有权变更、表单读取不创建链接、未知结果不移除、已加载多页重新填补、分享排序传递、页面/月份切换、列表读取错误与跨页重排、失败重试不增加写入，以及临时相册停止/清理后同步。真实NAS无写入；本轮不提升私有API证据等级。

首轮3项聚焦Model测试退出0；首轮1项原生UI/16张合成截图退出0（中英/浅深色，实际点击管理、取消、关闭分享并保存）。补充跨页重排与排序传递验证后运行最终回归；早期UI的合成服务没有列表排序实现而显示设置读取提示，已补仅测试服务的排序能力以覆盖正式排序路径，不修改产品错误处理来隐藏提示。

PENDING_USER_VALIDATION：进入“由我共享”直接打开管理，取消应不改变链接；修改成员/期限/访问范围并保存，列表保持当前分类和排序。停止普通分享后条目消失但普通相册/原件保留；停止临时分享沿直接停止/保留副本两种流程。断网导致保存结果未知时不重复提交，恢复自动核对；列表读取失败时“刷新”只更新列表。实际NAS由用户验证，仅回传脱敏版本、步骤及提示。


### 2026-10-01 分享列表最终验证与测试包

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests|MacAppearanceTests|DsmLocalizationTests'`退出0：221项模型、29项外观XCTest及6项本地化通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test由我共享列表' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-sharing-list-ui-final`退出0：1项UI，16张中英浅深色合成截图，实际点击管理、取消、关闭分享保存及列表同步。最终截图检查无合成服务缺排序导致的提示。
- `PATH="/tmp/dsm-photos-sharing-list-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-sharing-list-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-sharing-list-20261001" bash apple/Apps/DsmMac/package.sh`退出0；启动器仅复用既有Xcode/依赖缓存，不改工具链。Release、专用临时权限/Hardened Runtime、Sparkle实际library loaded、DMG VALID通过。
- `codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-sharing-list-20261001/LanStash Test.app'`退出0，plist为1.0.11(21)、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest，PlugIns数量0。DMG 22,015,788字节；无本地磁盘挂载，未安装/启动/正式发布。

当前波次未改Core/Network契约、持久化或其他端UI，保留37项累计工作区改动及旧包；无git add、提交或推送。真实NAS依上节PENDING_USER_VALIDATION步骤由用户验收，自动化不冒充真实NAS验证。本轮为progress，完整目标未完成。


分享列表收尾：`python3 tools/codex/check_documentation.py --strict-release`、`python3 tools/localization/check_localization.py`、`git diff --check`均退出0，Apple4721/Android2188/Windows3402。终止态已确认后将本波次9项临时日志/截图目录/启动器及build移至独立废纸篓，保留dist、旧包、正式测试和依赖缓存。

下一切片依赖复核：PhotoUploadQueuePanel当前只有重试、未知核对、整体清理和完成当前后停止；缺少单项移除/取消及导航。模型已有uploadedPhoto.folderID，保留子目录上传的实际目录可能不同于原始entry.folder。共有协议当前只有rootFolder/folders而无按编号取目录；Repository.readableFolder已使用Browse.Folder.get v2并检查访问权限，可在既有授权范围内增量暴露只读目录身份读取，不能靠文件名或猜测目录定位。导航须保留上传队列、跨空间使用实际结果且继续检查空间权限；直接相册贡献上传只能按其相册权限导航，不能借albumContext获得原目录权限。单项移除只清本地终态记录，不调用NAS删除；排队取消不影响当前在途项或未知结果。此段为下一切片设计依据，尚未实现，也未从剩余清单删除。

本轮再次通过CUA只读选择Chrome，工具仍返回Mac锁屏且自动解锁失败；冻结条件相册静态细节继续待此前解锁回复，不重复索要确认、不猜测实现。仍有独立上传任务工作，完整目标保持active，不能记为全局blocked。


### 2026-10-01 上传任务后续操作波次（开始）

前轮分享列表已交付，为progress；保留37项累计改动。当前单一范围：上传队列单项排队取消、终态记录移除、打开实际所在目录/目标相册，模型/UI/双语与聚焦测试。既有根目录/目录读取证据和Repository.readableFolder是事实依据；共享Serving增量folder(id:in:)复用现有Browse.Folder.get v2，默认显式不支持，用户此前已批准Photos契约扩展。无新的NAS写入、存储、依赖或工具链变更。五端影响：macOS使用新读取；iPhone/iPad由默认实现兼容，Windows/Android记录等价待办，不改其界面。回滚删除新增入口和只读方法即可，无数据迁移。

对齐账本：用户结果是从完成任务抵达实际目录/相册、移除单条任务记录。目录导航先读取当前照片位置，再逐层核对真实目录和访问权，不能由显示文件名推算；直接相册上传不提供原件目录入口。排队取消不取消当前传输，未知结果不可移除/重试上传；失败加入相册仍只重试加入步骤。记录移除不删除NAS照片。验证目标包括跨空间/子目录/照片移动、权限与页面变化、目录环、上传在途队列索引变化、单项取消及错误恢复。非目标：上传跨重启存储（待独立授权）、冻结相册与NAS后台任务任意清除（未补证）；未实现前不从剩余清单删除。


上传任务波次首轮编译失败发生于合成服务：详情覆盖方法被放入后续相似照片Stub，找不到navigationPhotoFolder。已将该方法移至PhotoUploadServiceStub并恢复相似Stub原实现，未降低断言或变更产品行为；重新运行同组聚焦用例，结果待实际终态。


### 上传任务后续操作：实现与独立复核

完成单项排队取消、完成/跳过/失败/取消记录移除；未知/在途任务拒绝移除。取消不影响其他排队项，移除不调用NAS写入，按剩余批次清理目录缓存。位置导航先回读已确认上传照片，再沿实际folderID/parent读取至根；跨空间明确选择实际照片空间，循环/编号/空间错误、权限失败保留原页面。直接相册贡献上传不提供原目录入口，已完成相册任务可重新核对相册访问后进入。成功导航关闭队列；预检失败在队列提示并可重试，进入目录后列表加载失败仍显示错误。迟到预检不覆盖新页面。

独立集成与只读对抗复核：检查队列删除导致数组索引位移时当前上传回执仍按UUID匹配；检查正在准备目录、上传、加入相册及pendingReview均不能移除；检查失败的加入相册仍只重试加入，不再上传原件；检查共享空间的访问权不变成个人目录通行权；检查相册授权不变成原件目录权限；检查页面代次/模块禁用/任务取消/记录移除使晚到导航失效。未改变已有上传写入、去重及自动核对策略，无新人工待验证白名单。

实际验证：

- 聚焦命令`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests/test上传单项|SynologyPhotosModelTests/test上传未知结果不能|SynologyPhotosModelTests/test上传打开位置|SynologyPhotosModelTests/test上传目录|SynologyPhotosModelTests/test贡献者无原空间|SynologyPhotosModelTests/test加入相册失败|SynologyPhotosRepositoryTests/test任务导航'`退出0：9项通过。
- 首轮UI 1项/12张截图通过；改为实际点击后，测试在成功导航关闭窗口后继续点击原窗口，导致相册/清除断言失败。按用户重新打开队列的路径修正测试，不修改产品行为或降低断言。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test上传任务后续操作|WorkspacePresentationTests/test多文件上传确认' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-upload-actions-ui-final`退出0：2项UI、16张中英浅深色合成截图。实际点击打开位置（失败/恢复）、前往相册及移除记录；检查正常、错误、空队列及未知上传/排队状态。
- 新增上传中移除前一条完成记录用例后，`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0：760项XCTest（227模型、29外观、475Repository、20预览事件、9预览转换）及6项本地化通过。测试使用合成数据，无真实NAS写入。

PENDING_USER_VALIDATION：上传多个照片/文件夹到个人或共享目录，取消其中一条排队项，其他项应继续；移除一条已完成/失败记录，NAS照片不删除。完成后打开所在位置，应进入实际子目录；照片另行移动后再次打开应使用当前位置。相册贡献上传点击前往相册，不出现无权原件目录入口。加入相册失败后重试不重复上传。断网/权限撤回显示恢复提示，重新连接可重试，未知上传保持自动核对。回传脱敏步骤/提示/版本即可；物理设备和真实NAS未由Agent验证。

当前冻结源码生成独立Release测试包；未标交付完成。剩余包括冻结条件相册、NAS后台任务列表及后续管理（不能用本机上传队列代替）、待独立存储授权的上传跨重启恢复与最终菜单查漏。


### 2026-10-01 上传任务后续操作独立Release包完成

`PATH="/tmp/dsm-photos-upload-actions-toolchain:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-upload-actions-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-upload-actions-20261001" bash apple/Apps/DsmMac/package.sh`退出0。启动器只复用既有Xcode和依赖缓存；构建期间源码冻结。Release arm64、专用临时权限/Hardened Runtime、Sparkle实际library loaded和DMG VALID通过。

额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-upload-actions-20261001/LanStash Test.app'`退出0。plist为1.0.11(21)、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest，PlugIns数量0；DMG为22,040,123字节。无本地磁盘挂载扩展，未安装启动或正式发布，新旧包均保留。

`python3 tools/localization/check_localization.py`通过Apple4726/Android2188/Windows3402；`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。main@5684170b3ccf仍保留37项累计改动，无git add/提交/推送；其他端未运行平台构建，不以共享Package通过冒充跨端验收。全部本轮进程终止后清理本轮临时日志、UI截图、启动器和build，保留正式测试、dist及依赖缓存。本轮progress，完整目标仍active。


### 2026-10-01 剩余功能证据审计与阻塞记录（第1轮）

上一轮上传任务功能、760项XCTest与独立包属于progress，已完成交付；本轮开始无存活构建或测试，不重新运行已通过门禁。复核main工作区37项累计改动，未覆盖任何内容。

本轮CUA首次getState超时并重置kernel；按同一读取请求重试后返回明确结果：Native apps为Mac锁屏且自动解锁失败，Browsers为nodeRepl.fetch失败，apps/browsers均空。它不是仍在运行的后台浏览器请求，不能把本轮记为verified wait。之前解锁请求尚未获得新的有效工具状态，不重复发出同一问题。

| 未完成要求 | 当前源码/契约证据 | 缺失的决定性信息 | 下一步 |
| --- | --- | --- | --- |
| 冻结条件相册恢复及重建 | photos-advanced-management已记录freeze_album/cant_migrate_condition/condition_object和NormalAlbum.set_unfreeze候选；Core/Model/Panel均无实现 | 官方字段类型、分支条件、重建继承规则和写后可核对终态 | 浏览器恢复后只读核对官方资源，再实现；不凭字段名称推断 |
| NAS后台任务列表、取消/清理及后续导航 | Repository的ManagementTransferTask仅有id/可选total/target_folder，list_user_task用于已知搬移任务补查；get_status仅建模id/status/completion/error/skip/overwrite | 完整任务种类、显示字段及类型、终态语义、取消/清理准确方法及范围 | 读取官方后台任务菜单/处理链；不能把“已知搬移回执补查”当完整任务中心，也不猜写方法 |
| 上传跨重启恢复 | 本账本已有独立version=1、按NAS UUID分区、系统书签、原子写入及未知回执不重放方案；当前仍内存队列 | 项目要求的独立存储变更授权尚未取得 | 等此前授权回复；不修改持久化、entitlement或会话格式 |
| 最终网页菜单逐项审计 | 已实现功能及聚焦测试均可定位，历史清单有增量记录 | 当前官方完整菜单及不同状态/权限分支对照 | 浏览器恢复后逐项查漏，不以本地构建或历史总结宣布完整对齐 |

已尝试公开官方1.9.1/1.7.0套件读取但未取得资源，结果见对应环境记录；公开帮助仅确认冻结相册用户语义，不能替代内部请求证据。当前没有可完整落地且不依赖上述缺口的新切片；不新增伪入口、通用任务占位界面或人为“待实测”禁用功能。此为首次完整剩余范围的阻塞审计，目标仍active；若后续连续同条件且无独立进展达到三轮，按goal要求标记blocked。未声称完成，也不以单轮浏览器失败提前blocked。


### 2026-10-01 同一阻塞复核（第2轮）

本轮只读选择Google Chrome，工具再次明确返回Mac锁屏且自动解锁失败；没有新的解锁或独立存储授权回复。工作区仍为37项累计改动，未有存活构建/测试可等待，前次产物保留。第一轮已排查的公开包、公开帮助和本地契约缺口没有新证据；不重启测试/打包或制造功能进展。本轮属于no progress，同一完整剩余范围阻塞已连续两轮，目标仍active，未达到三轮blocked阈值。


### 2026-10-01 同一阻塞复核（第3轮，blocked）

再次只读选择Chrome，工具仍返回Mac锁屏且自动解锁失败，未获得有效页面状态；独立存储授权没有新回复。连续三轮均无法取得剩余功能所需证据，且前述独立实现已交付、无运行进程可等待，也没有新的安全独立切片。本轮no progress，按goal规则将完整目标标记blocked，绝非complete或用户主动paused。

恢复条件：Mac解锁并让工具可读取已登录NAS的Chrome页面；上传跨重启恢复另需此前独立存储方案授权。恢复后先核对后台任务显示/取消/清理处理链及冻结相册字段，再接入功能并完成最终菜单查漏。保留37项累计工作区改动及最新photos-upload-actions-20261001测试包，无代码回退、提交、推送或真实NAS写入。


### 2026-10-01 浏览器恢复与剩余功能续查

恢复后首轮实际选择Chrome成功，官方Photos页面可访问；此前锁屏阻塞解除，goal实际状态active。上一轮中断只执行只读检查，没有遗留构建/测试；37项累计改动保留。本轮开始后台任务/冻结相册静态证据补齐，先建独立待归属环境快照；不回放真实写操作、不导出用户资料，版本未知不冒用历史基线。上传跨重启存储授权仍待此前回复，不因浏览器恢复擅自扩展持久化。


### 2026-10-01 NAS后台任务中心实施账本

单一修改范围：DsmCore Photos契约、DsmNetwork Photos Repository及测试、macOS Photos Model/Panel/View及测试、中英资源和对应文档。保留全部累计改动及移动端已有两行变更；不改持久化、权限、工具链或NAS资料。

| 功能 | 官方证据 | 原生转换与依赖 | 安全与验证 | 非目标 |
| --- | --- | --- | --- | --- |
| 后台任务列表与进度 | photos-management.md 2026-10-01静态补证 | 原生任务窗口，统一Info v1，不依赖当前照片空间 | 只读；目前static，随后合成自动化 | 不把本机上传队列当作NAS任务 |
| 取消、清理记录 | abort_task数组id、clear_completed_task标量id | 确认冻结任务身份；沿现有mutation编号去重和回读；全部清理仅处理确认快照 | 取消保留已完成部分；清理不删除照片；未知回执不重放 | 不在真实NAS探测写入 |
| 错误与目标位置 | get_error_detail的type/id/reason和target_folder | 原生错误列表；目标目录沿现有权限与父链读取 | 未知类型/原因可显示但不猜写入；失权不跳转 | 不扩展其他端UI |

共享新增默认明确不支持的任务读取方法和增量领域命令，已有Photos管理授权覆盖；五端影响：macOS本轮实现，iPhone/iPad/Android/Windows仅登记后续适配，不改变其他端入口。没有本地数据迁移；回滚移除新增入口与契约调用，NAS已完成任务和用户照片保持原有状态。真实NAS、辅助功能实际设备体验由用户后置验收，不能标成已验证。

#### 后台任务集成复核与首次回归修正

独立第二遍集成/只读对抗复核检查了：当前用户任务身份绑定、任务编号复用、在途取消后原搬移核对、批量清理中断、确认后新终态任务隔离、未知回执重放、错误名称的编号匹配、目录父链循环和禁用后的迟到响应。发现并修复取消本App任务与原管理操作共用单一模型进度的问题：控制操作沿同一Repository机制单独保留编号，不覆写原搬移，且不能提前清掉原待核对任务的证据。

第一轮完整回归779项XCTest中4个断言失败，均来自3个既有目录传输测试把task_info.total=600与get_status.completion=3组合为“成功”。本次官方static代码明确done且completion<total为取消后终态，旧合成数据不再是完整成功场景。原测试断言不降低：成功/错误父目录验证改用completion=600，仍分别要求confirmed/pendingReview；新增后台目录取消测试固定600/3并要求partial、completedCount=3。后续回归结果另记，不将首次失败当通过。

任务状态、错误详情和确认交互2项原生UI测试通过；32张五状态/错误详情图加24张确认前后图均为合成数据。初次截图宿主没有不透明背景，造成非列表区域不可读；给合成宿主补背景和对应NSAppearance后重新检查。另发现Text日期的环境格式覆盖问题，改用现有formattedPhotoDate，遵从App语言和照片日期设置；控制结果终结增加界面刷新代次，立即重读列表。上述后续修改仍需最终UI重跑。


#### 后台任务最终本地回归

`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0：780项XCTest（Repository488、Model234、Appearance29、PreviewConverter9、PreviewEvents20）与6项本地化通过。本轮新增13项接口、7项模型测试；完整回归包含此前上传操作测试。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test后台任务' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-background-ui-verified`退出0：2项原生UI通过，56张合成截图覆盖中英浅深色、加载/空/筛选为空/错误/正常状态、错误详情和实际取消/确认/清理点击。确认后新增任务不在清理快照内，继续显示；最终图片已检查，英文日期随App语言。

`python3 tools/localization/check_localization.py`通过Apple4772、Android2188、Windows3402；`python3 tools/codex/check_documentation.py --strict-release`、`git diff --check`通过。独立Release包仍在构建，完成前不计交付通过。


#### 后台任务独立Release包完成与交付状态

`PATH="/tmp/dsm-photos-background-toolchain-tfj7rqff:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-background-tasks-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-background-tasks-20261001" bash apple/Apps/DsmMac/package.sh`退出0。启动器仅复用既有Xcode依赖缓存；构建期间未改源码。Release arm64、专用临时权限/Hardened Runtime、Sparkle实际library loaded、DMG VALID均通过。

额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-background-tasks-20261001/LanStash Test.app'`退出0。plist为1.0.11(21)、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest，PlugIns数量0，DMG22,262,350字节。新旧包均保留，没有安装、启动或正式发布。

官方静态资源仅在浏览器内存核对，完成后删除临时全局变量并确认undefined、清空控制台并关闭；未保存原始脚本或真实NAS响应。所有本轮测试/构建进程均已终止，随后清理本轮临时日志、UI截图、启动器及build，保留源码、dist和依赖缓存。工作区main@5684170b3ccf共39项累计改动（含两个新增发现文档），移动端既有改动保留；未执行git add/提交/推送。

下一切片：冻结条件相册恢复/重建。静态证据已确认freeze_album独立于type；冻结前不能开放普通相册上传/成员修改，官方列表菜单仅删除，详情提供恢复。保存普通相册使用NormalAlbum.set_unfreeze标量id；重建先创建新条件相册后删除旧相册，不能假定继承分享。暂未新增入口或声称实现。最终菜单查漏及待独立存储授权的上传跨重启恢复仍未完成，完整goal保持active。


### 2026-10-01 冻结条件相册恢复实施账本

前轮后台任务为progress，所有进程已终止；本轮复核39项累计改动，无并发源码变化。单一范围为Photos Core/Repository、macOS Model/Panel/View、对应测试、双语资源与五端文档；不改其他端源码、持久化、权限或工具链。

| 用户结果 | 官方静态证据 | 原生转换与依赖 | 安全与验证 | 非目标 |
| --- | --- | --- | --- | --- |
| 恢复为普通相册 | photos-advanced-management的freeze_album与NormalAlbum.set_unfreeze v1 | 原生恢复窗口确认保留现有照片、不再自动匹配；统一Album读取 | 本人相册、确认快照、写后明确false；自动化与UI待实施 | 不假定相册type可代表冻结 |
| 编辑条件并重建 | Album.get condition_object/cant_migrate_condition，ConditionAlbum.create v3，再Album.delete旧id数组 | 复用条件编辑器，提示不支持条件及旧分享不继承 | 核对新相册后才删除旧相册；未知回执不重放，部分结果保留新旧对象 | 不在真实NAS探测写入，不盲复制旧字段 |
| 冻结前操作限制 | 官方详情禁上传，列表仅删除，冻结提示提供恢复 | 冻结独立领域标志与原生入口；适用成员/分享/收集入口同步 | 客户端与Repository均检查，不能凭旧列表绕过 | 不增加人为待实测锁 |

契约为既有Photos扩展授权内的增量；无本地迁移。macOS本轮实现，iPhone/iPad/Android/Windows只登记语义影响与默认不支持。回滚移除新增入口/调用；已经恢复或重建的NAS相册不自动回滚，保留原照片。证据static，真实NAS的冻结样本与系统辅助功能验收后置PENDING_USER_VALIDATION。


#### 冻结恢复首次聚焦验证与独立复核

首轮编译及既有条件相册4项聚焦回归通过；新增冻结Repository12项通过。模型测试首次因合成服务缺searchTimeline协议方法而编译失败，补齐只读空结果后6项模型通过，不曾降低断言。新增20项中英文资源，本地化检查通过Apple4792/Android2188/Windows3402；严格文档和diff检查通过。原生UI正在运行，未先计为通过。

独立只读对抗复核检查了：普通恢复须明确false、快照跨账号/内容变化、先验证新条件再删除旧相册、创建失回执无同名追认、删除失回执不重放、明确拒绝保留两册、关闭窗口不丢失操作编号、待核对时切换页面不抢回导航。发现并修复普通恢复被重建目录预加载失败连带阻断：目录和建议改为选择重建后才读取。再次只读核对官方菜单，确认“由我共享”仍可管理既有分享，以及冻结预览仍可设置封面；不能据本人相册列表菜单误建全局禁止。这两项限制按确切证据收窄，随后回归另记。


#### 冻结相册最终本地验证与打包开始

`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0，798项XCTest（Repository500、Model240、Appearance29、PreviewConverter9、PreviewEvents20）及6项本地化通过。本轮新增12项接口、6项模型。随后仅将无可迁移条件的表单改为只显示普通恢复，原逻辑均保留，并完成下面最终UI验证。

`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test冻结相册' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-frozen-ui-verified`退出0，1项UI/28张中英浅深色合成截图通过，包含普通恢复、条件重建、无可迁移条件、错误、加载、取消及实际确认点击。首次测试找不到SwiftUI原生radio NSButton，改为依据截图点击；后续取消测试的固定中文坐标误点英文确认，断言成功捕获，最终改用Esc并断言取消回调确实发生且零写入。未降低断言。最终查看英文重建、英文仅普通恢复、中文错误布局，无遮挡。

本地化检查通过Apple4792/Android2188/Windows3402，严格文档及diff检查通过。独立Release构建已启动，目录photos-frozen-albums-20261001；源码冻结，包完成前不算交付。此前background-tasks包继续保留。

### 2026-10-01 最终菜单查漏：预览角色分支（进行中）

只读官方react_bundle.js中的完整预览菜单映射，对照当前Model、View与Repository；没有读取真实照片或发送NAS写入。个人/共享管理的幻灯片、下载、加入相册、旋转、预览、人脸、移动/复制、目录封面；普通/条件相册封面与成员操作；人物/主题封面及移出；相似分组首选/移出/保留此项删除其他均有现有命令。冻结恢复本轮补齐，但不能据此宣布全部菜单完成。

发现新的确定差异：team_download_lightbox包含REGENERATE_PREVIEW；album_photo_provider_not_management_lightbox与shared_album_photo_provider_not_management_lightbox也包含该动作，shared_album_download_lightbox仅下载、不含它。原生Model.canSubmit把regeneratePreviews与元数据并入canEditSelection→canModifyOriginal，Repository.prepareMutationTarget又要求requireManagedFolder，导致这些下载角色/贡献者分支被拒绝。当前界面存在预览重建按钮不足以证明角色对齐。下一切片须核对官方worker实际来源、相册上下文、读原件资格与结果回读后修正，不能直接删权限检查或把所有下载角色都开放。

预览菜单还明确区分freeze_album_lightbox（含封面但无REGENERATE_PREVIEW/DELETE）、共享相册贡献者/管理者/仅下载、原空间关闭只移除成员。后续审计需逐项核对原生对应入口和权限，不能把单一canModifyOriginal当所有动作共同门槛。最终菜单查漏仍进行中，上传跨重启存储仍待此前授权，完整goal保持active。


#### 冻结相册独立Release包完成

`PATH="/tmp/dsm-photos-frozen-toolchain-d5lll_sj:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-frozen-albums-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-frozen-albums-20261001" bash apple/Apps/DsmMac/package.sh`退出0。构建期间未改编译输入；Release arm64、临时权限/Hardened Runtime、Sparkle实际library loaded及DMG VALID通过。额外`codesign --verify --deep --strict 'apple/Apps/DsmMac/dist/photos-frozen-albums-20261001/LanStash Test.app'`退出0。plist为1.0.11(21)、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest，PlugIns数量0，DMG23,376,987字节。保留旧包，未安装/启动/发布。

PENDING_USER_VALIDATION：在包含升级遗留冻结相册的专用环境，先确认打开/取消无修改；普通恢复应保留已有照片并停止自动匹配；支持条件的重建应创建新相册、验证新规则后才移除旧相册，旧分享不继承。分别核对断网、创建失败、清理失败及操作期间改动旧相册时保留数据；仅回传脱敏套件版本、角色、步骤与错误，不回传照片、路径、账号或凭据。无真实NAS写入测试，不将本地成功提升为behavior-verified。


### 2026-10-01 预览重建角色对齐实施账本

范围：仅Photos Repository预览重建资格、macOS模型/预览与选择入口及对应聚焦测试。不修改其他写操作的原件管理门槛、持久化或其他端UI。官方eCS/eCI→eCw调用个人/共享RegeneratePreview.set_regenerating(item_id数组)，eCT分派实际转换；接口没有新增相册参数。team_download仅已登录普通目录下载角色；共享相册单纯下载者没有重建资格，本人提供者或共享原目录管理者有独立分支。冻结相册及来源空间关闭不开放该入口。

目标语义：只读回读照片身份/提供者和冻结状态后核对对应资格；共享普通目录允许view+download或管理，相册本人提供者沿相册只读上下文回读，不能因任意下载权放行。转换后的资格检查沿同一规则，未知回执保留原编号核对。复用已有原生确认表单并补预览入口，不添加新公开端点/参数。当前验证未运行；API证据仍static，真实角色/失权/断网验收后置用户。


#### 预览角色聚焦、完整回归及原生入口验证

新增接口4项、模型1项通过；`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0：803项XCTest（504 Repository、241 Model、29 Appearance、9 Converter、20 Events）及6项本地化。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test预览重建' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-preview-roles-ui-fixed`退出0：2项原生UI、12张中英浅深色截图；新预览按钮实际打开确认窗口，Esc关闭且零写入。首轮新测试因合成服务未启用详情读取与测试窗口未置前而失败，补齐fixture与焦点并按截图核对点击坐标后通过，原断言保留。

本地化4792/2188/3402、严格文档和diff检查通过。独立Release包构建中，编译输入冻结。打包期间继续只读菜单审计，发现下一段所述冻结多选差异，当前包不计最终交付，须待该修正及回归后重新打包。

#### 完整静态菜单核对新增结果（2026-10-01）

核对官方36类图库/目录/相册上下文菜单及45类预览菜单。Ei明确等于user_setting.team_space_permission==MANAGE，因此共享相册非提供者的预览管理分支是全空间管理角色；不能把相册下载或上传权限泛化成管理权。现有模型该分支按canManageSharedSpace处理正确，Repository仍保留既有原目录管理检查。

发现当前切片需先修正：freeze_album多选菜单包含EDIT_GENERAL_TAG、EDIT_RATING、EDIT_DATE_TIME、SET_COVER与REGENERATE_PREVIEW；MM读取CurrentFreezeAlbum后明确选择该菜单，MR直接生成。冻结预览菜单没有REGENERATE_PREVIEW。因此冻结限制必须仅作用于预览入口，不能全局关闭多选重建；上一段本地通过不是最终冻结分支验收。

下一切片确定缺口：SynologyPhotoPreview目前没有直接加入已有相册、当前相册移除/封面、移动/复制，以及人物封面/移出入口；这些命令在主图库存在，但不能当作预览窗口同等操作已完成。主题与相似组已有独立入口。预览信息侧栏目前主要只读，元数据快捷编辑及相册贡献者的metadata/rotation菜单资格尚须worker核对，不能据有同名主图库操作宣布全部角色对齐。上传跨重启持久化仍待此前独立授权，其他全局菜单最终审计继续。


#### 冻结入口差异修正后的最终验证

冻结相册的多选重建保持可用，预览窗口传入fromPreview单独判断不可用；Repository不再把冻结标志作为所有入口的禁令。对条件/冻结相册保留本人原件管理路径，对普通个人相册其他提供者仍不因相册所有权获得重建权。扩展原有角色测试同时覆盖两空间普通/冻结贡献者成功，以及模型多选可用/预览不可用；不删原断言来绕过失败，而是按新证据增加双场景断言。

再次运行`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0：803项XCTest及6项本地化通过。`LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test预览重建' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-preview-roles-ui-final`退出0：2项UI/12张合成截图。随后只在新共享目录资格方法保留原有正整数目录编号前置条件；最终`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosRepositoryTests/test预览角色|SynologyPhotosRepositoryTests/test预览重建'`退出0，8项聚焦回归通过。生产源码至此冻结。

只读集成/对抗复核检查：来源空间/会话代次、实际相册提供者回读、纯相册下载权不能放行、普通原件修改门槛保留、转换后的权限撤回、相册只读参数与写入原空间路由、未知回执不重放及冻结两入口差异。当前确定缺口仍列在上一段，不据本轮完成宣称全部菜单对齐。无真实NAS写入，官方脚本临时变量已清除并关闭控制台。

PENDING_USER_VALIDATION：用真实共享目录下载角色确认可重建而不能编辑原件；用相册本人提供者与仅下载者分别核对菜单和结果；冻结相册应保留多选重建而预览按钮不可用。用专用样本确认原件保持、两空间缩略图更新、转换期间撤回权限不继续上传，以及通知/网络中断后不重复启动。只回传脱敏版本、角色、动作及错误提示，不提交真实媒体、相册名、路径、地址或会话信息。跨重启相册任务缺少来源上下文时不猜权限，本轮没有新增持久化。

原先尚未交付的中间包完成后已移入独立废纸篓目录；不会作为最终包交付。最终Release复用本轮构建目录重建，dist仍为photos-preview-roles-20261001，完成后另记。冻结恢复及后台任务旧包均保留。


#### 预览角色最终Release包完成与交付状态

`PATH="/var/folders/db/hlxj5p_139b4_0kfk5c05_rc0000gn/T/dsm-photos-preview-roles-toolchain-t2nrv29w:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-preview-roles-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-roles-20261001" bash apple/Apps/DsmMac/package.sh`退出0。缓存启动器仅追加既有依赖缓存路径和skipPackageUpdates，不改工具链或依赖；最终构建期间未改编译输入。

Release arm64、临时权限/Hardened Runtime、Sparkle实际library loaded和DMG VALID通过。额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-preview-roles-20261001/LanStash Test.app'`退出0。plist为1.0.11(21)、io.github.qwertyuiop1995.dsmnativeclient.macos.localtest；PlugIns数量0；DMG22,465,220字节。旧包保留，未安装启动、未正式发布。

最终工作区main@5684170b3ccf，共39项累计改动；保留既有Mobile及其他工作，未git add/提交/推送。全部测试/构建进程结束后，本轮临时日志、UI截图、启动器及独立build移入唯一废纸篓目录，保留源码、dist与依赖缓存。下一切片先补预览直接操作闭环，并核对贡献者元数据/旋转的真实worker后再改资格；不借菜单名称扩大通用原件删除/管理门槛。上传跨重启仍待此前单独授权，完整目标保持进行中。


### 2026-10-01 预览直接操作实施账本

前轮已完成预览重建角色与独立测试包，属于有效进展；本轮开始复核当前源码与39项累计工作区改动，全部既有进程已结束。单一修改范围为macOS Photos View/Model、既有PhotoManagementPanel及对应测试/文档；不改其他端源码、公开API、依赖、权限或持久化。

| 用户结果 | 官方与原生证据 | 原生实现方向 | 安全与验证 | 非目标 |
| --- | --- | --- | --- | --- |
| 预览内加入/移出相册与封面 | 前轮45类预览菜单的ADD_TO_ALBUM/REMOVE_FROM_ALBUM/SET_COVER；主图库已有对应命令 | 原生更多菜单复用PhotoManagementSheet，固定当前预览照片及相册 | 保留所有者/提供者与冻结限制，打开只读、确认才提交；测试待实施 | 不改变相册成员或原件删除语义 |
| 预览内移动/复制 | 个人/共享/搜索预览MOVE_TO/COPY_TO；既有目录选择与重复项处理表单 | 使用当前预览目标而不是主图库多选，复用现有目标空间与目录检查 | 不扩大原目录权限；未知结果沿原操作核对 | 不新增后台任务/存储格式 |
| 人物及主题操作 | SET_PERSON_COVER/REMOVE_FROM_PERSON_ALBUM及现有主题入口 | 更多菜单复用人物人脸选择/封面和主题表单 | 固定人物/主题上下文，原件保留，移出仅更新相关集合 | 不通过入口补齐擅自改写贡献者编辑权限 |
| 预览内元数据编辑与结果同步 | 主图库已实现评级/说明/时间/标签，预览信息目前只读 | 在同一预览窗口打开既有编辑表单；确认移出当前照片时关闭旧预览，其他预览保持 | 保留历史月份、选择及分页；失败/待核对不提前移除 | 贡献者其他编辑角色仍须独立worker契约核对 |

当前实现缺口：removeManagedItems只更新items/选择/偏移，没有关闭已移出照片的预览；主题单独关闭、跨空间相册重读已有处理。新入口需把这段结果行为统一到实际移出集合，不因复制、失败、未知结果或别处移出而关闭当前预览。遵循既有删除/主题操作的原生关闭行为，不新增自动跳转。

本轮预期不新增资源键，沿用既有中英文文案；若实现确需新文案同时补齐两种语言。真实NAS与物理辅助功能验收后置PENDING_USER_VALIDATION，先完成当前环境的模型/原生UI/构建。回滚本轮入口与结果处理即可，不反向修改已完成NAS操作。


#### 预览直接操作实现与验证（2026-10-01）

SynologyPhotoPreview的更多菜单已接入加入已有相册、新建相册、移出当前相册、相册封面、评级、说明、拍摄时间、时间偏移、新建/添加/移除标签、移动与复制；人物页另含移出人物、重新分配人物和人物封面，原有主题操作并入同一菜单。元数据采用原生菜单打开既有编辑表单，信息侧栏保持只读展示。所有表单保存打开时的单张照片、相册、人物/主题和来源空间，不读取主图库保留的多选；现有下载、分享、旋转、手动人脸和重建按钮保留。

本轮只改macOS的SynologyPhotosView.swift、SynologyPhotosModel.swift及对应两份测试；复用PhotoManagementPanel，没有新增API、资源键、持久化、权限或依赖。canRemoveAlbumPhotos允许预览与列表共用现有移除资格，条件/冻结相册沿acceptsManualMembers禁用成员移除；相册封面仍需所有者。人物与主题操作保持已有能力门槛，贡献者其他元数据/旋转角色不在本轮扩大。

removeManagedItems在实际移出集合中包含当前预览时关闭预览；相册、人物、主题与目录移动共用此行为。复制、移出另一张照片、未知结果不会关闭当前预览；目录历史和相册位置保留。相册跨空间移动仍沿已有成员回读；同空间移动的详情更新继续使用Repository已核对的result.photos。

验证命令与结果：

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotosModelTests/test预览直接操作'`退出0，新增5项模型测试通过。
- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0，808项XCTest及6项本地化通过。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test预览直接操作|WorkspacePresentationTests/test预览重建' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-preview-actions-ui`退出0，3项原生UI测试、28张中英浅深色合成截图；检查实际菜单项目/启用状态，打开评级/人物封面表单，鼠标和键盘确认只提交当前照片，重建打开/取消仍不写入。已查看中文浅色工具栏/评级表单与英文深色人物封面截图。
- UI测试初次只等待绘制80ms就检查异步提交，出现命令尚未发送的失败；确认模型处于isManaging后，将测试改为有上限地等待操作完成并断言已完成，保留原有命令与照片断言。无生产代码绕过和静默跳过。
- `python3 tools/localization/check_localization.py`通过双语、参数、资源引用和硬编码检查；`python3 tools/codex/check_documentation.py --strict-release`与`git diff --check`通过。

实现后另做只读集成/对抗复核：检查预览与列表目标隔离、相册所有者/提供者资格、原件编辑权限不扩大、固定来源空间、未知结果重复提交门槛、已确认移出后的预览/分页/选择同步，以及复制与同空间时间线移动保留来源视图。既有Repository继续承担操作预检与结果核对，本轮不新增私有接口或改变其证据等级。源码冻结后按既有本机临时签名流程完成独立Release包，最终结果见下段。

PENDING_USER_VALIDATION：使用专用测试照片，从相册/人物/目录预览打开更多菜单，逐项确认加入/移出、封面、标签/时间/说明/评级和移动/复制的结果；特意让主图库选中另一张照片，确认只作用于预览目标。移出当前照片后关闭预览但保留当前集合，复制后保留来源；模拟断网及权限变化时不得重复提交或扩大原件权限。真实NAS、VoiceOver与物理键盘完整验收未运行；回传仅含脱敏版本、角色、动作、期望/实际结果与错误提示，不含真实媒体、路径、地址或凭据。

剩余：共享相册贡献者的其他元数据/旋转编辑资格须继续按官方worker核对；上传跨重启恢复等待此前独立存储授权；其他全局设置及角色组合仍需最终菜单查漏。本轮不宣称全部Photos功能已复刻，也不把主流程已完成等同真实NAS验证通过。工作区保留全部此前未提交改动（包括移动端文件），没有暂存、提交或推送。


#### 预览直接操作最终打包与收尾

实际执行`PATH="/var/folders/db/hlxj5p_139b4_0kfk5c05_rc0000gn/T/dsm-photos-preview-actions-toolchain-9gbl9wb8:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-preview-actions-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-preview-actions-20261001" bash apple/Apps/DsmMac/package.sh`退出0。临时包装器仅调用系统xcodebuild并追加`-clonedSourcePackagesDirPath <仓库>/apple/.build -skipPackageUpdates`复用既有依赖缓存，不修改工具链或工程配置。

最终DMG为22,486,900字节，版本1.0.11(21)，arm64、既有localtest标识；PlugIns为0。打包脚本的Hardened Runtime/专用测试权限、Sparkle实际加载及DMG VALID全部通过；额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-preview-actions-20261001/LanStash Test.app'`退出0。未自动安装或启动，无正式发布；无本地磁盘挂载扩展。此前交付包保留。

本轮临时测试截图/日志、编译目录与临时包装器在所有进程结束后移入独立废纸篓目录；最终dist、源码、依赖缓存与此前交付保留。工作区仍为39个累计修改/新增项，移动端及其他既有改动未触碰；没有暂存、提交或推送。


### 2026-10-01 三项收尾实施账本

用户明确要求一次实现三项后统一验证：贡献者编辑角色、上传跨应用重启恢复、全局菜单最后查漏。该指示解除此前停止剩余工作的限制，并确认本机上传任务持久化实施范围。本轮不增加第四项功能，不为中间切片重复打包。实现后统一聚焦/集成/本地化/UI与Release验证。

| 项目 | 基线与实施范围 | 安全及兼容约束 | 验收证据 |
| --- | --- | --- | --- |
| 编辑角色 | 官方菜单与worker；Repository.prepareMutation及模型canEditSelection/canRotatePreview | 独立判断元数据/旋转，不扩大删除、移动等原件写入资格；核对真实来源及提供者 | 角色矩阵回归及预览/多选入口 |
| 上传恢复 | 当前队列和Repository回执均仅内存；补齐本机队列、文件授权、阶段及回执恢复 | 不保存凭据；按连接及账号隔离，持久化先于写入；未知结果先核对不重放；旧版无队列无需迁移 | 重建模型/Repository的恢复测试，失败及重复提交测试 |
| 菜单收尾 | 已取得官方36类列表与45类预览菜单，配合当前设置入口 | 固定清单，仅修已有能力的遗漏，非本轮新功能登记为非目标 | 逐项源路径对照及缺口结论 |

新增上传记录为独立版本化本机文件，不改变连接、会话或NAS数据格式；原先内存队列无法从已退出的旧进程迁移。回滚客户端可保留独立记录待新版读取，不自动重试旧版无法理解的任务，也不删除NAS资料。文件访问授权仅用于用户选中的上传来源。真实NAS/系统授权恢复保持PENDING_USER_VALIDATION，当前环境先完成合成验证。

#### 三项统一实现与菜单终审（源码完成，验证结果待下段补齐）

编辑角色使用2026-10-01官方前端静态证据：个人空间按实际提供者允许资料、评级、时间、标签和旋转；共享相册照片需要共享空间全局management；对外共享相册的混合来源评级/时间还要求全部由本人提供，普通本人相册的共享照片允许management。条件/冻结相册继续保留本人原件资格。Repository沿相册上下文重新读取实际提供者及原件身份后，仍向原空间Item接口写入；相册口令不进入记录。新增回归包含完整保存/回读、旧提供者、关闭空间、陈旧身份、混合来源和旋转。菜单终审发现手动人脸入口复用了原件所有者判断，也一并改为同一提供者/共享管理资格；仍要求人脸识别能力、有效框、照片身份、人脸归属和回执编号，不改变删除原件及搬移权限。

上传恢复新增独立version=1队列文件，按连接配置和账号散列分区，恢复时再核对Photos当前用户编号。用户选择的来源只保存只读安全书签和相对组件，不复制媒体，不保存SID、SynoToken、Cookie、密码或相册口令。目录权限0700、文件0600，原子替换同一文件中的队列与回执；写入前保存意图，收到上传/目录回执后先保存再回读。重启后未知操作沿原操作编号只读核对，未开始项等待“继续上传”；已经上传成功而加入相册失败时只补加入步骤。过期书签/文件变化要求重新选择并核对原文件身份；读写记录失败暂停后续上传并允许重试。无回执不能按同名照片猜测，用户明确在NAS核对后可移除本机记录，该入口不重发、不撤销、不删除NAS文件。加入相册、创建目录和直接相册上传均覆盖同一路径。旧版内存队列无迁移来源，版本化记录与旧会话格式相互独立。

最终菜单清单来自官方36类列表和45类预览菜单枚举的动作并集（列表20、预览19，不计分隔线）。下表逐项对应当前源码，合并同义的原生呈现方式；它证明入口和调用存在，不把静态读取等同真实NAS写入验证。

| 官方动作 | 范围 | 原生入口与结果实现 |
| --- | --- | --- |
| EDIT_GENERAL_TAG | 列表 | PhotoManagementKind.tagsCreate/tagsAdd/tagsRemove；PhotoManagementPanel → addTags/removeTags/createTag |
| EDIT_RATING | 列表 | selectionCases.rating / 预览更多 → edit.rating |
| EDIT_DATE_TIME | 列表 | selectionCases.date/shiftDates / 预览更多 → edit.takenAt/shiftDates |
| REGENERATE_PREVIEW | 列表、预览 | 选择栏、预览重建、PhotoPreviewRecoveryPanel → regeneratePreviews |
| MOVE_TO | 列表、预览 | 照片/目录多选、预览更多、拖放 → move；目标目录与跨空间检查、后台核对 |
| COPY_TO | 列表、预览 | 选择栏/目录右键/预览更多 → copy；复制后保留来源 |
| UNSTACK | 列表 | 相似组多选取消分组 → ungroupSimilarSelection，逐组结果与撤销 |
| SET_AS_FOLDER_COVER | 列表、预览 | 照片右键/预览目录封面 → PhotoFolderCoverPanel.setFolderCover |
| RENAME | 列表 | 目录右键 → renameFolder |
| CHANGE_FOLDER_COVER | 列表 | 目录右键 → PhotoFolderCoverPanel，选图/恢复默认 |
| COLLECT_PHOTO_TO_HERE_FROM_FOLDER | 列表 | 目录顶部及右键收集照片 → createPhotoRequest；官方kZ/k0打开PhotoRequest对话框 |
| EDIT_PERMISSION | 列表 | 目录右键/目录栏 → PhotoFolderSharingPanel；共享成员的文件夹授权另有PhotoMemberFolderPermissionsPanel |
| DELETE | 列表、预览 | 明确原件删除确认；照片逐项或目录后台任务，未知不重放 |
| REMOVE_FROM_ALBUM | 列表、预览 | removeAlbum → removeFromAlbum；只移除相册成员，实际移出后关闭对应预览 |
| SET_COVER | 列表、预览 | cover → setAlbumCover；相册所有者资格 |
| DELETE_IN_ALBUM | 列表 | 相册内原件删除；canModifyOriginal与Repository原件权限独立核对 |
| SET_PERSON_COVER | 列表、预览 | personCover → setPersonCover；核对人脸属于该人物 |
| REMOVE_FROM_PERSON_ALBUM | 列表、预览 | removeFaces → removePersonFaces；保留原件 |
| SET_CONCEPT_COVER | 列表、预览 | conceptCover → setConceptCover；固定主题快照 |
| REMOVE_FROM_CONCEPT_ALBUM | 列表、预览 | removeConceptItems；复验集合和显示阈值、保留原件 |
| SLIDESHOW | 预览 | 独立原生全屏幻灯片；分页、视频结束、暂停/继续/键盘 |
| DOWNLOAD_ITEM | 预览 | PhotoDownloadMenu原件/JPEG/原尺寸JPEG，按媒体及能力显示 |
| ADD_TO_ALBUM | 预览 | 更多中的addAlbum/createAlbum，固定当前照片；不使用主列表多选 |
| ROTATE | 预览 | rotatePreview → rotatePhoto，核对方向/尺寸，未知不重放 |
| EDIT_FACE | 预览 | PhotoFaceEditor；已有框纠正/移除和新框，来源及提供者资格重新核对 |
| SET_AS_STACK_COVER | 预览 | 相似组详情setTopPick → editSimilarGroup.topPick |
| REMOVE_FROM_STACK | 预览 | 相似组详情remove → editSimilarGroup.remove；支持撤销 |
| KEEP_THIS_DELETE_REST | 预览 | 相似组详情keepSelected → 原件删除确认；排除保留项并核对结果 |

全局与辅助入口复核：设置菜单连接PhotoCodecPromptPanel、PhotoLibraryMaintenancePanel、PhotoGlobalSettingsPanel（含转换缓存）、PhotoSharedMembersPanel、PhotoSharedSpaceSettingsPanel、PhotoAutomaticPreviewSettingsPanel、PhotoRecognitionSettingsPanel、PhotoDisplaySettingsPanel、PhotoDuplicateSettingsPanel。普通相册/共享列表的排序与显示菜单独立存在；冻结相册恢复/重建、临时分享、分享权限/有效期/密码、照片请求管理、人脸/主题显示、后台任务列表/取消/清理/错误/跳转、预览失败恢复与本机上传队列分别复用现有面板。服务端不支持或角色不满足时保持现有能力与权限门槛。本轮不新增第四项功能，未把“关于/帮助/网页登录退出”等网页外壳当作Photos业务API。

本轮对原生平台转换保持不变：网页版直接信息编辑以原生更多菜单和确认表单呈现；右键/顶部选择栏互补，触控板可通过显式按钮完成操作。英文与简体中文同时提供10个上传恢复资源键。状态文字仅说明用户结果和下一步，不显示API、回执字段或本机存储路径。

只读集成及对抗复核已检查：其他模型/移动端既有改动未覆盖；共享类型仅新增上传专用窄快照与默认不支持的方法，既有端不启用持久化；上传资料与操作回执原子保存、写前失败不发送、响应丢失不重放、不同用户拒绝恢复、书签失效不静默放行、清记录不改变NAS、提供者编辑不提升原件删除/移动资格。验证和正式产物必须以本轮后续实际执行结果为准。


#### 三项统一验证记录（2026-10-01）

- `swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0：827项XCTest及6项本地化通过，包括10项跨重启队列/来源授权/记录权限测试和Repository回执恢复、角色矩阵测试。
- `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests/test上传恢复|WorkspacePresentationTests/test预览直接操作|WorkspacePresentationTests/test预览重建' bash tools/codex/run_macos_ui_checks.sh /tmp/dsm-photos-three-final-ui`退出0：4项原生UI、48张中英浅深色合成截图。恢复窗口覆盖等待继续、待核对、重新选择来源、存储错误和空队列；实际点击继续只上传一次。初次测试坐标落在中文按钮左侧，修正为两种语言共同按钮范围后通过，未降低状态或请求数断言。
- 本地化完整性/硬编码扫描、严格文档检查和差异空白检查通过。

权限变更单独待用户确认：正式主App现有沙盒权限缺少`com.apple.security.files.bookmarks.app-scope`，已询问是否允许仅增加此项以在重启后继续访问用户选择的文件；尚未修改正式或本地测试权限文件。单元测试和本地临时签名包不代表正式沙盒书签授权已验证。该项未答复前，正式沙盒交付的上传恢复不能宣布完成。


PENDING_USER_VALIDATION（三项最终范围）：使用专用测试照片分别验证本人提供的个人照片、他人提供照片、共享空间管理者/非管理者的资料、标签、拍摄时间、旋转及手动人脸操作；编辑资格不得获得原件删除/搬移资格。上传开始前退出再启动，未开始项须等用户继续；上传响应丢失时重启，只核对且不重复生成照片；上传已成功但加入相册失败，重启后只补加入；目录上传须复用已确认目录；移动或修改源文件后要求重新选择原文件；不同连接/账号不能载入另一队列。无回执未知结果仅在用户核对NAS后移除本机记录，不删除NAS文件。另验证VoiceOver、真实键盘焦点和系统安全书签授权。回传只含脱敏DSM/套件版本、角色、步骤、期望/实际结果和提示，禁止包含媒体、路径、主机、账号或凭据。当前自动化不替代这些实机结果；内部API证据等级保持static。


移动端共享兼容构建：首次直接使用仓库内DsmMobile.xcodeproj，失败于其未登记已有MobileSynologyPhotosSession.swift，错误为`cannot find 'MobileSynologyPhotosSession' in scope`。该工程与业务源码未做修改。使用锁定XcodeGen 2.46.0和原有project.yml，在`/tmp/dsm-photos-three-final-mobile-project`生成独立工程，源码/资源均引用当前工作区；随后执行`xcodebuild -project /tmp/dsm-photos-three-final-mobile-project/Apps/DsmMobile/DsmMobile.xcodeproj -scheme DsmMobile -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dsm-photos-three-final-mobile -clonedSourcePackagesDirPath "$PWD/apple/.build" -skipPackageUpdates -jobs 4 CODE_SIGNING_ALLOWED=NO build`退出0、BUILD SUCCEEDED（arm64与x86_64）。它验证共享源码兼容，不代表真机或正式签名验收。原有移动端未提交改动完整保留。


#### 三项最终本机Release产物

实际执行`PATH="/var/folders/db/hlxj5p_139b4_0kfk5c05_rc0000gn/T/dsm-photos-three-final-toolchain-ywes9bba:$PATH" LANSTASH_NON_INTERACTIVE=1 LANSTASH_RUN_AFTER_PACKAGE=0 LANSTASH_BUILD_TYPE=Release LANSTASH_BUILD_ROOT="$PWD/apple/Apps/DsmMac/build/photos-three-final-20261001" LANSTASH_DIST_DIR="$PWD/apple/Apps/DsmMac/dist/photos-three-final-20261001" bash apple/Apps/DsmMac/package.sh`退出0；包装器仅向系统xcodebuild追加`-clonedSourcePackagesDirPath <仓库>/apple/.build -skipPackageUpdates`以复用已解析依赖。

产物为`apple/Apps/DsmMac/dist/photos-three-final-20261001/LanStash-1.0.11-arm64.dmg`，22,647,845字节；1.0.11(21)、arm64，既有localtest标识，PlugIns=0。脚本完成Hardened Runtime/专用测试权限、Sparkle实际加载（library loaded）与DMG VALID；额外`codesign --verify --deep --strict --verbose=2 'apple/Apps/DsmMac/dist/photos-three-final-20261001/LanStash Test.app'`退出0。未自动安装启动，旧包完整保留；正式签名和系统沙盒权限待上述用户选择与实机验证。


收尾：所有本轮构建/测试进程结束后，13项本轮临时日志、截图、移动端临时工程/构建目录、XcodeGen下载及包装器、macOS构建目录已移入独立废纸篓目录。最终dist、此前交付包、源码和共享依赖缓存保留。工作区为44个累计修改/新增项，保留既有移动端等改动；没有暂存、提交、推送或PR操作。正式沙盒权限选择仍待用户答复，因此不将该部分或真实NAS验收标为通过。


### 2026-10-02 用户授权后补齐正式沙盒文件书签权限

用户明确允许增加重启后保留所选文件授权。仅在`apple/Apps/DsmMac/SupportingFiles/DsmMac.entitlements`加入`com.apple.security.files.bookmarks.app-scope = true`；文件来源仍是用户选择项，实际创建的书签保持只读。File Provider、本地测试权限、应用身份和原有其他权限均未改变。无需迁移队列格式；如回滚该权限，须同时停用正式沙盒的安全书签恢复或提供重新选择来源路径，不能只删权限后仍宣称支持该能力；已有队列和NAS照片不删除。

实际验证：`plutil -lint apple/Apps/DsmMac/SupportingFiles/DsmMac.entitlements`通过；Python plist解析与HEAD逐键比较确认仅新增这一项，扩展和本地测试权限不含该键；`python3 tools/release/test_macos_signing.py`通过10项测试，包括正式权限展开后保持完整、临时权限隔离和合成组件实际加载。`python3 tools/codex/check_documentation.py --strict-release`及`git diff --check`通过。

本轮只改权限配置和状态文档，业务源码未变，未重复运行此前827项XCTest/6项本地化/4项UI；这些结果属于2026-10-01统一验证。既有本机临时包使用独立权限文件，不受此次正式权限变更影响，因此沿用原测试包，未重复打包或执行正式发布。正式签名沙盒中的跨进程书签恢复仍需实际包验证。

当前剩余为验收与交付：专用NAS上的权限/写入/断网/重启结果、正式签名沙盒恢复、VoiceOver与真实键盘焦点；提交整理及正式发布尚未执行。旁项为既有移动端工程漏收源码，应由移动端任务按既定生成流程维护，不扩入本轮macOS功能收尾。没有发现此前三个收尾项中另有已登记但尚未实现的功能切片。


### 2026-10-02 开发目标完成审查

按本任务原始macOS Photos网页对齐范围复核，不以最后三个切片替代完整范围。依据为本账本“授权、范围与基线”、官方菜单静态证据、当前SynologyPhotosManagementFeature全部42项、实际View/Panel → Model → Repository接线以及现有测试断言。五端要求是同步共享契约与影响，不是本任务新增其他端全部UI；正式发布没有在本轮获得授权。按AGENTS约定，真机、正式签名和真实NAS验收后置为PENDING_USER_VALIDATION，不能据此声称这些环境已通过，也不把它们误记为未实现的功能。

| 功能组 | 覆盖的管理能力 | 当前实现链与行为 |
| --- | --- | --- |
| 照片资料与角色 | metadata、rotation、tags、tagCreation | PhotoManagementPanel、预览更多、canEditPhoto/prepareMutationTarget；评级/说明/绝对与相对日期、标签、旋转及来源身份回读 |
| 普通、条件与冻结相册 | albums、conditionAlbums、frozenAlbums | 相册创建/修改/删除/成员/封面、条件编辑、冻结恢复/重建；原相册身份和新相册结果核对 |
| 目录与传输 | folders、folderDeletion、folderCover、folderSorting、folderSharing、fileTransfer | 独立建目录、重命名/删除、封面、排序/权限、移动/复制/拖放；后台任务与目标结果回读 |
| 上传 | upload | enqueueUploads/startUploadQueue、PhotoUploadQueuePanel、PhotoUploadRecoveryStore、performRecoverableUpload；相册/目录上传、重复策略、取消重试和跨重启恢复 |
| 分享与收集 | sharing、photoRequests | PhotoSelectionSharingPanel、分享表单与请求管理；具名成员、公开范围、密码/有效期、临时分享取消/保留副本及创建/修改/删除照片请求 |
| 人物与主题 | peopleNames、peopleMerge、peopleFaces、peopleCover、peopleVisibility、conceptVisibility、conceptCover、conceptItems、manualFaces | 人物命名/合并/移出/重新分配/封面/显示、手工人脸框、主题封面/移出/显示；固定集合和本人提供者资格 |
| 相似照片 | similarGroups | 相似组详情、推荐照片、移出/解散/撤销及保留选中删除其余；按完整成员快照操作 |
| 预览与转换 | previewRegeneration、automaticPreview、automaticPreviewSettings、codecPrompt | 手动重建、本机预览转换、自动候选/失败状态、设置和新格式提示；PhotoPreviewRecoveryPanel与对应转换/事件回归 |
| 后台与整库维护 | backgroundTasks、libraryMaintenance | PhotoBackgroundTasksPanel、错误详情与目标导航、取消/清理、PhotoLibraryMaintenancePanel；提交与完成分开核对 |
| 共享空间与全局设置 | sharedSpaceSettings、sharedMembers、globalSettings、conversionCache | PhotoSharedSpaceSettingsPanel、PhotoSharedMembersPanel/PhotoMemberFolderPermissionsPanel、PhotoGlobalSettingsPanel；读取/确认/差量提交/回读 |
| 识别、显示、重复与排序 | recognitionSettings、displaySettings、duplicateSettings、albumSorting、albumListSorting、albumListDisplay | 识别/显示/重复策略面板、相册内与列表排序/显示；保存后保留浏览位置与选择 |

42项枚举与上表逐项集合比较，无遗漏或重复。该集合检查只证明覆盖清单；行为证据来自对应Repository/Model测试及前述原生界面测试，不能用枚举存在代替行为通过。额外检查非管理流程：时间线/月份/分页/筛选、个人与共享空间切换、按天/范围多选及逐项删除、批量/整册/目录下载、原件/JPEG导出、照片/视频/实况预览、缩略图大小、幻灯片和预览直接操作。saveSelection/savePhotos实际逐项导出并防覆盖；shiftDates逐项写固定绝对目标并核对，回执未知不累加偏移；预览managementTarget只捕获当前照片。上传恢复测试实际重建模型与Repository，断言旧上传不重发、仅继续未开始项以及只补加入相册。列表20/预览19动作的逐项对照保留在上节。

当前工作区重新执行`swift test --package-path apple --skip-update --jobs 4 --filter 'SynologyPhotos|MacAppearanceTests|DsmLocalizationTests'`退出0，827项XCTest及6项本地化测试通过。`python3 tools/contract-validation/validate_fixtures.py`通过3组fixture及42项私有接口文档引用；`python3 tools/localization/check_localization.py`通过4802项Apple资源及跨端双语/参数/引用/硬编码检查。权限批准后已另执行10项签名回归。业务源码未变，2026-10-01的4项原生UI/48张截图、macOS Release/签名/实际组件加载/DMG校验、临时生成移动端工程构建证据仍适用；本次未重复打包或把旧结果表述为新运行。

审查结论：已登记的macOS Photos复刻开发及本机可执行验证完成；没有发现尚未实现的既定功能切片。剩余明确为真实NAS权限/写入/断网/重启验收、正式签名沙盒书签恢复、完整VoiceOver/物理键盘验收，以及用户后续决定的提交整理与正式发布。移动端原工程漏收源码是单独维护项，保留记录。以上环境验证仍未完成，接口证据等级不升级，不作全版本或真实NAS全部通过的承诺。
