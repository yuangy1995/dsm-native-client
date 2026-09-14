<!-- doc-role: development-plan -->
<!-- last-reviewed: 2026-09-15 -->

# 原生玻璃界面与 Synology Photos 跨端对齐账本

基线：`2243e731000382e5ff8bf2460c1ee7f9b83d0f11`。本轮用户明确扩大 Android、Windows、iPhone、iPad 的视觉重构范围；macOS App 保持只读。旧计划中“不复刻 macOS 外观”和“不修改 Android”不再约束本次授权。应用标识、凭据存储、最低系统版本及 NAS 写权限不随外观迁移改变。

## 对齐与安全范围

| 切片 | macOS 证据 | 目标端实现/交互转换 | 安全级别 | 验证状态 |
| --- | --- | --- | --- | --- |
| 照片身份、时间轴、分页、搜索 | `apple/Packages/DsmCore/Sources/SynologyPhotos.swift`、`apple/Packages/DsmNetwork/Sources/SynologyPhotosRepository.swift`、`apple/Apps/DsmMac/Sources/SynologyPhotosModel.swift` | 个人空间＋账号＋Photos ID；不回退 File Station；触控月选择与键鼠导航 | 只读；私有 API | 实施中 |
| 相册、系统分类、文件夹、12 类筛选、共享读取 | 同上及 `SynologyPhotosView.swift` | 复用真实能力与参数；共享列表不等同共享空间授权 | 只读；私有 API | 实施中 |
| 大图、视频、实况、详情、原件保存 | 同上 | 手机/平板使用安全 Range 播放、系统 Files/分享；Windows 使用原生播放器与文件选择器 | 认证媒体读取；本地保存 | 实施中 |
| 移动端 NAS 写入边界 | `docs/api/discovery/endpoints/photos-item-deletion.md` | 不将旧 File Station 移动、回收、分享写入口映射到 Photos；未验证高风险操作只读 | 高风险写关闭 | 实施中 |
| 玻璃视觉与原生导航 | `apple/Apps/DsmMac/Sources/MacAppearance.swift`、`WorkspaceView.swift` | 共用雾白/墨蓝色值、细边框与选中层次；SwiftUI Liquid Glass、Compose 原生模糊、WinUI Acrylic；系统辅助功能优先 | 本地 UI | 实施中 |
| Windows 原生重构 | Mac 工作区各模块 | 重建展示层并复用已测试的认证、证书、领域、传输安全层；不以删除安全基础设施作为“重写” | 本地 UI/既有契约 | 实施中 |
| 性能 | Mac 惰性网格/双向游标 | 惰性渲染、有界缩略图、限并发、取消、迟到结果隔离，避免对每个卡片整屏截图 | 本地/只读 | 实施中 |

## 验证原则

源码、合成自动化、目标端构建、真机和发布证据分别记录。iOS 27 的系统玻璃外观通过原生 API 和可用性检查接入，不以旧 SDK 的兼容分支构建证明新 SDK 构建成功。未运行的项目保持未验证；不会删除断言或把失败改成成功。

## PENDING_USER_VALIDATION

前置条件：四端对应测试构建、授权 NAS、合成照片/视频/实况、深浅主题与辅助功能。检查时间轴跳转、筛选与官方 Photos 一致、分页/取消/断网/切换账号、预览/拖动/导出、不同窗口宽度、减少动态效果/透明度与读屏。预期凭据不出现在媒体 URL，旧账号结果不闪回，NAS 不发生未确认写入。反馈仅包括平台/应用/DSM/Photos 版本、步骤和脱敏错误，不回传凭据、真实照片、路径或原始响应。
