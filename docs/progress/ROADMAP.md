# 产品路线图

> 最后更新：2026-08-10
> 当前实现、测试和阻塞情况以[当前开发进度](STATUS.md)为准。

本文只记录未来优先级和里程碑出口，不重复维护已经实现的功能清单。

## P0：发布与实机验收

### macOS 文件客户端

- 完成目标 DSM build 下的登录、浏览、预览、传输、远程位置和危险写操作回归。
- 完成签名、公证、缓存、通知、关闭窗口后台运行、性能和无障碍验收。
- 将真实环境结论写入兼容矩阵。

### 桌面端只读云盘位置

- 继续覆盖正式签名环境才会出现的系统调度与进程中断恢复边界；现有 fake 与 Extension
  测试已覆盖 runtime 恢复最终提交、启动恢复连续写入失败、多时点容量复查、并发软
  上限准入与在途额度预留、下载 Task 取消和主要补偿路径，但不替代 File Provider
  系统传输取消验证。
- 使用正式签名验证 macOS Finder/File Provider 端到端行为。
- 在 Windows x64/arm64 完成 WinUI 构建、Cloud Files 回调、资源管理器状态、固定与释放、只读保护、重启、外部磁盘和安装/卸载验收。
- 通过真实 NAS 验证整个 NAS/指定目录映射、按需读取、离线保留、空间预检、缓存清理和后台恢复。

详细设计和验收条件见[桌面端云盘开发计划](../development/NATIVE_DSM_DESKTOP_CLOUD_DRIVE_DEVELOPMENT_PLAN_ZH.md)。

### 契约与危险写操作

- 维护并扩展现有请求契约库；当前已有 94 份请求 Fixture 与 1 份写结果示例，后续优先
  补齐仍无稳定证据的覆盖上传、套件、容器/VMM 子资源、网络、防火墙和系统更新，继续
  记录 API、方法、版本、路径、参数编码、认证要求、重试策略和危险等级。
- 五端统一写操作结果语义已经建立并进入多条生产调用链；继续迁移尚存的旧 Void/瞬时
  结果路径，并保持已回读确认、明确失败、已提交但无法确认、部分成功、提交前取消和
  提交后请求取消的区别。超时或结果未知时禁止界面引导用户立即重复提交。
- 请求契约或结果模型进入公共契约前，必须同步评估五端实现计划、兼容矩阵、迁移和
  回滚，不在单个平台先行固化未经验证的 DSM 行为。
- 将桌面云盘已使用的诊断字段白名单和“禁止出现”结构测试扩展到其他诊断出口，覆盖
  URL、主机、路径、显示名称、查询参数、会话材料和原始底层错误，不导出原始日志。
- macOS 已实现本地草稿预览/导出器；其他端由各端现有开发计划独立推进，本批不修改。
  所有实现都只能组装独立 submission 契约允许的字段并要求用户确认，不得把诊断摘要、
  原始错误或响应直接转换成社区报告。
- 完成维护者只读候选生成与证据审计：候选工具不得写仓库或访问 GitHub；重复身份和
  无效取代关系阻断，合法匹配、冲突与状态建议只提示人工复核。
- 在 Android 已完成、Windows 已经通过多轮 GitHub CI 的写契约基础上，继续用同一
  Fixture 对齐套件、容器/VMM 子资源、网络和防火墙的可观察请求语义；没有稳定生产
  入口的平台不得为了矩阵齐全而复制未经验证写操作。

实施顺序、五端影响、迁移和回滚见
[请求契约与写操作结果模型实施计划](../development/REQUEST_CONTRACT_AND_MUTATION_RESULT_PLAN_ZH.md)。

### 移动端与 Windows 基础客户端

- iPhone、iPad 和 Android 分别完成真实设备完整登录、自动恢复、网络切换和显式退出验收。
- Windows 完成完整 WinUI 构建、安装启动、登录恢复和平台安全存储验收。

## P1：现有模块收敛

### 照片管理

- 完成大图库、元数据、权限、弱网、缓存和危险写操作验收。
- 补齐基础相册入口，再按版本化契约评估人物、主题、地点、标签等增强能力。
- macOS 继续完成发布出口；iPhone/iPad 精选照片浏览、查看、主动导入/分享和有限 NAS
  管理已形成主流程，Windows 也已完成文件夹、时间线、缩略图、单项导入和受限恢复。
  两端剩余语义、性能与真实设备/NAS 验收可按无依赖切片并行推进；Apple 自动照片备份
  仍是后续独立决策，Android 继续按其专项范围推进。

详细范围见[照片管理开发计划](../development/NATIVE_DSM_PHOTOS_DEVELOPMENT_PLAN_ZH.md)。

### Synology Chat

- 完成首次单聊、私人群聊、附件、提醒、定时消息、投票创建和实时刷新的真实套件验收。
- 补齐语音、投票参与及其他未完成消息能力。
- 加密会话必须先完成密钥生命周期、安全评审和跨设备验证，不允许明文降级。
- Android 已形成完整 Chat 主流程，Apple 移动端与 Windows 已进入会话/历史和受限纯文字
  发送；下一步先冻结单附件 typed 契约再接两端原生 UI。macOS 仍是业务语义与安全基准，
  但不再把“等待 macOS 全部稳定”作为其他平台无依赖切片的串行前置条件。

详细范围见[Synology Chat 开发计划](../development/NATIVE_DSM_CHAT_DEVELOPMENT_PLAN_ZH.md)。

### NAS 设置、套件与统一存储

- 使用专用测试目标验证可能断网、改时、停服或影响存储状态的写操作。
- 在已完成 Download Station 常用单任务流程和当前活动摘要基础上，BTSearch v1 的 Apple shared/mobile 与 Windows Domain/Infrastructure/ViewModel/WinUI 闭环也已通过候选提交 `53360d2` 的 Apple、Android、Windows 与 Repository 四组云端门禁；当前只剩真实 NAS、iPad、Windows、Narrator 和键盘验收。下一功能切片优先推进 ACT-01 统一活动中心；CHAT-03 必须先补 Apple 单附件 typed outcome 与 Windows 上传/缩略图/下载 typed 契约；NAS-02/NAS-04 有界只读详情可与 Chat 契约并行。RSS、文件优先级、BT 协议高级设置、设置写入以及 Container/VMM 高危能力继续后置。
- 验证统一存储管理的大目录、取消、权限、QuickConnect 和 MD5 任务；取得版本化契约后再评估套件历史报告与计划任务。

详细范围见[套件管理计划](../development/NATIVE_DSM_SERVICE_MANAGEMENT_PLAN_ZH.md)和[统一存储管理计划](../development/NATIVE_DSM_STORAGE_MANAGEMENT_PLAN_ZH.md)。

## P2：Windows 语义对齐与移动端范围交付

- Windows 使用 C# 与 WinUI 3，继续以 macOS 已承诺业务范围为完整语义对齐目标。
- Apple 移动端复用共享领域层，但按 iPhone 随身伴侣和 iPad 增强型移动工作台场景，只交付专项矩阵中的核心/受限能力；复杂运维、长流程和系统级集成不因共享代码存在而自动进入范围。
- Android 使用 Kotlin 与 Jetpack Compose，具体范围由 Android 专项计划和范围账本独立决定。
- 各端遵循共同契约、安全语义和兼容矩阵，不共享跨平台 UI 运行时；范围缩减不能削弱已纳入写操作的安全门禁。
- Windows 对齐与各移动端范围根据[平台功能矩阵](PLATFORM_MATRIX.md)逐项确定，不以单个平台实现代替其他平台验收。

## P3：候选能力

- Apple 移动端自动照片备份、后台常驻传输、iPad 多窗口与 File Provider；只有独立产品、权限、契约和验收决策通过后才进入活动里程碑。
- File Station 后台任务、异步目录大小、MD5、VFS 扩展和更完整的恢复入口。
- Download Station 的 RSS、文件优先级、BT 协议高级设置、设置写入，以及 Container Manager 和 Virtual Machine Manager 的剩余高级能力。BTSearch v1 已退出“候选实现”、形成两端源码闭环并通过云端门禁，只保留真实环境验收；不得借此把尚无稳定 typed 契约的 RSS、文件优先级或高级设置并入当前波次。
- Audio Station、Video Station、Note Station、Synology Drive、Calendar、Contacts、Surveillance Station、Hyper Backup、Active Backup 和 Synology Office。
- 社区兼容性计划后续阶段，包括静态筛选页、匿名统计口径、报告过期策略和定期复核；
  维护者只读候选生成、冲突检测和 macOS 本地草稿导出已经进入当前实现。

候选能力只有在用户优先级明确、API 来源清楚、安全边界成立且具备目标环境验证条件后，才进入活动里程碑。

## 里程碑完成规则

- “已实现”只表示源码和自动化测试路径已经建立。
- “已完成”必须满足专项验收条件并形成目标平台或真实 NAS 证据。
- 每次状态变化只更新[当前开发进度](STATUS.md)；本路线图仅在优先级、范围或里程碑出口发生变化时更新。
