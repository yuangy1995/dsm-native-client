# 社区兼容性参与与测试指南

[English](COMMUNITY_COMPATIBILITY_GUIDE_EN.md)

社区报告记录某一版本组合的用户观察，不等于维护者实机验收，也不能提高私有 API 证据等级。维护者证据见 [DSM 兼容范围](DSM_COMPATIBILITY_MATRIX.md)，已审核结果见[社区矩阵](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)。

## 提交与隐私

使用 GitHub“社区兼容性报告 / Community compatibility report”表单；熟悉仓库的贡献者也可依据[示例](../../contracts/community-compatibility/examples/example-report.json)提交结构化报告 PR。macOS 设置中的社区报告可在本机填写、预览并确认后导出；App 不自动上传或持久保存草稿，草稿不包含维护者分配的 `reportId`、`sourceRef`、`reviewStatus` 或 `supersedes`。

- 只测试有权使用的 NAS、账号和数据，使用正式发布的无临时调试版本。写操作仅用专门创建的可丢弃项目；不确定安全性时选 `skipped`。
- 仅记录客户端版本/提交/平台、公开产品型号、CPU 架构、DSM 完整版本、相关套件版本，以及连接、权限和证书类别。完整字段以[提交 Schema](../../contracts/schemas/community-compatibility-submission.schema.json)和[正式报告 Schema](../../contracts/schemas/community-compatibility-report.schema.json)为准。
- 禁止设备名、序列号、MAC、地址、端口、QuickConnect ID、账号、凭据、证书内容、共享名、路径、文件名、消息和环境变量；不接收日志、截图、HAR/PCAP、响应、崩溃转储、用户文件或自由文本故障诊断。
- `failed`/`partial` 必须有一个 `failure`，其他状态不得带该对象。只允许 `stage`、`errorCategory`、`apiName`、`apiVersion`、`httpStatus`、`retryPerformed`、`rawResponseIncluded: false`；枚举与范围遵循 Schema。App 未安全展示的 API/版本填 `unknown`，HTTP 状态填 `null`，不要为补字段查看原始响应。
- 不添加 `message`、`body`、`path`、`host` 或错误正文。需进一步调查时按 [SECURITY.md](../../SECURITY.md)选择独立问题或私密安全渠道；疑似秘密不复制到评论或其他系统。

`schemaVersion: 2` 表示数据格式，`testSuiteVersion` 表示测试集合：版本 1 必须包含 14 项，版本 2 必须包含 19 项，未测也不能省略。当前版本 2 的五项 `desktop-drive.*` 仅定义 macOS Finder 结果，其他四端必须填 `not-supported`；这不代表其他端没有系统文件集成。能力范围以[注册表](../../contracts/community-compatibility/capabilities.json)为准。

## 执行与结果

准备空测试文件夹和小型虚构文件，优先普通账号；OTP 仅测试已启用的账号，不为报告修改权限或认证设置。

| 结果 | 含义 |
| --- | --- |
| `passed` | 全部步骤完成，结果符合界面 |
| `failed` | 无法完成或结果错误 |
| `partial` | 只有部分流程成功或结果不一致 |
| `skipped` | 未执行、条件不足或主动跳过 |
| `not-supported` | 当前平台/环境明确不支持 |

| 能力 ID | 操作与预期 |
| --- | --- |
| `connection.resolve` | 打开连接流程，提交凭据前找到并确认预期 NAS；报告只记连接类别 |
| `authentication.password` | 测试账号正常登录，不记录账号/密码/原始错误 |
| `authentication.otp` | 已启用两步验证时完成验证，否则跳过 |
| `authentication.restore-session` | 正常关闭重开，按当前设置恢复或要求登录，不串账号/NAS |
| `files.list-shares` | 显示当前账号可访问共享，不记录名称 |
| `files.browse` | 进入授权目录并返回，列表与导航正确 |
| `files.search` | 在测试目录搜索虚构项目，结果可打开，不提交关键词 |
| `files.download` | 下载小型非敏感文件，完成且可打开 |
| `files.upload` | 上传测试文件，NAS 可见完整项目 |
| `files.create-folder` | 新建空目录，刷新后仍可见 |
| `files.rename` | 重命名测试项，新名出现、旧名消失 |
| `files.copy-move` | 测试目录间复制/移动，目标出现；移动另确认源消失 |
| `files.recycle` | 仅已有回收站时删除测试项，先有确认再离开原位置；无回收站跳过/不支持，不永久删除 |
| `files.restore` | 恢复上一项产生的测试文件至预期位置，不覆盖真实文件 |
| `desktop-drive.mount` | 正式签名 macOS 包添加/移除映射，Finder 入口对应出现/消失，NAS 文件不变 |
| `desktop-drive.browse` | Finder 连续滚动至少 1,000 合成项并切层，响应正常、离开后停止加载 |
| `desktop-drive.download-resume` | 中断可丢弃大文件下载后再打开，复用进度且最终内容一致；不提交文件名/校验值 |
| `desktop-drive.keep-offline` | 保留离线、取消、再次完成、断网读、释放；空间不足有恢复提示且不影响其他映射 |
| `desktop-drive.upgrade-restore` | 从上一公开版本原位升级，映射/暂停/缓存策略保留且可浏览；重新创建不算升级恢复 |

写测试均可跳过，不使用生产数据、唯一副本或工作共享。macOS 云盘缺正式签名条件时填 `skipped`，普通浏览或临时签名不能代替 Finder 结果。完成后正常清理测试项和本地下载，不为报告清空回收站；清理失败停止危险重试，以允许字段记录 `stage: cleanup`。

## 维护者审核

| 状态 | 含义 |
| --- | --- |
| `submitted` | 已提交，未审核 |
| `reviewed` | 结构、版本和隐私检查通过，不保证观察正确 |
| `corroborated` | 至少两位不同贡献者对同一组合给出一致结果 |
| `maintainer-verified` | 维护者在已记录环境复现 |
| `disputed` | 同一组合存在冲突 |
| `superseded` | 被同环境的新报告显式替代 |

保留失败与冲突，不用多数票覆盖。组合至少含产品型号、架构、DSM build/update、客户端平台及版本，套件能力还须套件版本；升级后新建报告，不覆盖历史。维护者手工维护 `supersedes`，目标须标为 `superseded`；验证器阻止悬空、自环、循环、日期倒序及无后继的旧报告，不由日期或型号自动推断关系。

管理员可配置 `compatibility-report`、`needs-review` 标签。先人工检查公开来源隐私，再将安全提交交给只读候选工具：

```bash
python3 tools/community-compatibility/prepare_candidate.py \
  --submission /path/to/submission.json --source-ref issue-123 \
  --submitted-at 2026-08-04 --confirm-privacy-reviewed --format diff
python3 tools/community-compatibility/validate.py
python3 tools/community-compatibility/validate_submission.py /path/to/submission.json
python3 tools/community-compatibility/generate.py
```

候选工具按最高 ID 分配下一个 `cc-NNNNNN`，不复用空号；只向标准输出提供报告与双语矩阵差异，不写仓库、不联网、不运行 Git，也不解析整条 Issue/附件。审核后显式应用所需变更并分配证据状态。正式数据位于 `contracts/community-compatibility/reports/`；[中文矩阵](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md)与[英文矩阵](COMMUNITY_COMPATIBILITY_MATRIX_EN.md)由生成器维护，禁止手改。仅提交脱敏结构化数据与生成结果，不保留原始附件。

当前不自动采集遥测、上传报告或绕过人工隐私审核。新增套件测试、统计或展示方式须先演进同一契约；报告数量不能当作市场份额、整体成功率或内部写能力的准入条件。
