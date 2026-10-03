# macOS 容器映像搜索与下载修复

## 范围与基线

用户报告搜索下载流程停在无法确认下载状态，并要求移除开发流程文案。保留同工作区的 Chat 修改；本切片仅修改容器搜索、标签、下载跟踪和相关双语文案。main 未提交；不创建分支，不自动推送，用户随后明确授权必要的 Chrome NAS 网页下载测试；仅下载独立小体积官方镜像，不运行容器或替换既有镜像。

| 主流程 | 现有证据 | 修复目标 | 风险与验证 |
| --- | --- | --- | --- |
| 搜索和标签选择 | DsmServiceManagementRepository / PullImageSheet | 区分空结果与读取失败，防止迟到结果覆盖当前选择 | 只读；聚焦合成测试 |
| 下载状态 | ContainerImagePullModel / DsmServiceManagementRepository | 读取暂时失败后继续自动恢复，绑定原 task_id，不重放启动 | 私有写入口保持确认、权限、防重与回读；真实写后验证待用户 |
| 界面表达 | 双语语言资源、ServiceManagementView | 清楚显示下载进度、错误原因和恢复操作 | 双语与浅深色检查 |

## 验证记录

发现见 `docs/api/discovery/environments/2026-10-03-container-image-pull-observation.md`。

## 根因与修改

- Registry 宣称最高 v2，但 search 方法只接受 v1。官方同关键词对照：v1 成功、v2 返回 103。共享 Apple Adapter 固定 search v1，严格读取 data 数组，格式错误不冒充没有匹配项。
- 模型原先仅刷新 downloading，首次失败进入 needsReview 后永远不自动刷新。现自动查询 downloading 和 needsReview，继续绑定原 task_id；无回执不能猜绑定或重发。
- 受控下载已取得 task_id 并读到 finished=false/downloaded，随后 NAS 返回 1202，最终完整清单没有测试标签，聚合任务中原 ID 消失。该明确 Docker 失败保存终态；传输或暂时状态错误继续恢复。只有 pull_status 的 1202 可判此终态，最终 Image.list 的同码仍是读取失败，补独立回归。
- 搜索错误单独展示原因与“重新搜索”；标签可“重新加载版本”，切换与关闭取消旧读取并隔离迟到结果。关闭按钮不再暗示能够取消 NAS 下载。
- 下载及相关容器操作的双语文案移除“检查下载状态”“结果尚未确认”“不要再次提交”等内部流程说法；确认、权限、重复提交和最终结果核对保留。共享资源与主 App 的覆盖资源同步。

## 实际验证

| 命令/操作 | 结果 |
| --- | --- |
| `swift test --package-path apple --jobs 4 --filter 'ContainerImagePull\|DsmServiceManagementRepositoryTests.test镜像仓库搜索'` | 当时 24 项通过、0 失败；后续补“完成后列表错误不得误判失败”一例，纳入最终全量测试 |
| `swift test --package-path apple --jobs 4` | 最终 2,415 XCTest：2,246 通过、169 按既有门禁跳过、0 失败；另 12 Swift Testing 通过 |
| `LANSTASH_UI_TEST_FILTER='WorkspacePresentationTests.test容器下载恢复与搜索错误' bash tools/codex/run_macos_ui_checks.sh /tmp/lanstash-container-ui` | 1 项通过，20 种状态/语言/主题组合；验证错误/进度/完成/拒绝、辅助功能可读、搜索失败不冒充空结果、不自动再次下载 |
| `python3 tools/localization/check_localization.py` | Apple 5,576 资源；双语、占位符、引用、硬编码均通过 |
| `python3 tools/request-contract/validate_contracts.py`、`python3 tools/contract-validation/validate_fixtures.py` | 169 个请求快照、1 个写结果示例；29 组数据 fixture 和 48 项私有 API 引用通过 |
| `python3 tools/codex/generate_api_reference.py --check`、`python3 tools/codex/check_documentation.py`、`git diff --check` | 通过 |
| iPhone/iPad 通用模拟器 Debug 构建 | 最终共享代码构建通过，完整命令见 Chat 五组功能账本 |
| 当前 Chrome NAS 官方页面请求入口 | search v1 与 tags 读取成功；小体积官方镜像下载启动并运行，之后 NAS 1202 失败；没有新增镜像、没有创建/运行容器，不声称成功下载通过 |

## 独立集成及只读对抗复核

完成 UI/模型/共享 Adapter 复核：同目标重复点击、无回执、任务编号类型、连续读取失败、1202 与传输错误、旧镜像存在、畸形结束标记、跨仓库/标签回显、最终清单不完整均有回归。保留下载/删除互斥，不加入跨账号任务认领或凭名称成功推断；最终清单失败不能覆盖为下载失败。依照项目生成流程更新 Xcode 文件成员、同步双语主 App 覆盖资源后再构建。

## PENDING_USER_VALIDATION

- 当前 NAS 已能搜索，真实下载在 NAS 端失败；此前 1202 返回值本身没有证明具体原因。用户随后提供的当日日志补充了 3 次匿名拉取限额、2 次镜像中转服务 TLS 握手超时，见[日志分析与挂载修复账本](MACOS_MOUNT_WRITABILITY_FIX_20261003_ZH.md)。先解决 NAS 访问仓库的连通性与仓库认证/额度，再用此独立测试包下载可丢弃标签：应进入下载中，完成后只在最终镜像列表确实可用时显示完成。该日志不等于其他仓库或所有客户端路径均已验证。
- 弱网后自动恢复、窗口关闭重开、普通账号/权限撤销、长时间下载待验。只回传 DSM/Container Manager 版本、连接类别、脱敏步骤和错误类别，不回传地址、凭据、原始响应或用户镜像清单。
- 其他 NAS 版本不借用本次证据。Windows/Android 仅记录契约风险，未改代码；iPhone/iPad 只回归共享层。
- 测试包、签名验证、校验和与清理记录见 `MACOS_CHAT_FIVE_FEATURES_20261003_ZH.md`。所有变更保留在 main 工作区，未提交或推送。


最终交付：与 Chat 五项补齐、常驻连接和开放策略合并在 `dist/chat-and-container-20261003` 的 1.0.13（23）Release arm64 本机测试包；签名、精确权限、Sparkle 实際加载与 DMG 校验均通过，未安装或启动。NAS 的成功下载仍未验证，不能以打包通过代替该结果。
