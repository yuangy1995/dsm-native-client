<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-10-10 -->

# Apple 原生客户端

Apple 客户端使用 Swift、SwiftUI 和 Swift Package Manager：macOS 作为业务语义与安全行为
基准，iPhone/iPad 按已确认的 M0→M8 共享业务、保持各自原生布局。当前实现与目标范围见移动主计划，不能互相替代。

```text
Apps/DsmMac/                   macOS 原生应用（业务参考；必要共享引用获授权调整）
Apps/DsmMobile/                iPhone/iPad 通用 SwiftUI 应用
Packages/DsmCore/              领域模型、错误和 Repository 协议
Packages/DsmNetwork/           DSM HTTP、会话和参数编码
Packages/DsmPhotosFeature/     共用 Photos 状态机与上传恢复，文件授权由平台适配
Packages/DsmFileFeature/       共用上传计划、归档、远程位置、Office 与存储分析
Packages/DsmFileProviderRuntime/ 共用枚举、缓存、写回、冲突与恢复
Packages/DsmTransferFeature/   传输编排预留目录，移动队列在 App 中按阶段完善
```

## 修改边界

- 当前移动波次已获得必要共享逻辑提取及 macOS 引用调整授权；Mac 用户行为与数据格式保持兼容并运行回归。其余桌面改动仍遵循项目授权边界。
- `apple/Packages/**` 可以做向后兼容的增量拆分；必须保持 actor、公有协议、会话、错误
  类型和 macOS 回归行为。
- iPhone/iPad 不复制菜单栏、悬停、右键或常驻进程；管理功能采用分步表单。范围与证据分别见[平台矩阵](../docs/progress/PLATFORM_MATRIX.md)及移动主计划。

## 本地验证

使用 [Apple 工作流](../.github/workflows/apple-build.yml)锁定的 Xcode 26.6（17F113）与 XcodeGen 2.46.0。下列通用构建不等于两端实际 UI 测试；设备选择与结果分别记录。

```bash
swift test --package-path apple

cd apple/Apps/DsmMobile
xcodegen generate
xcodebuild \
  -project DsmMobile.xcodeproj \
  -scheme DsmMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

cd ../DsmMac
LANSTASH_NON_INTERACTIVE=1 LANSTASH_BUILD_TYPE=Release \
LANSTASH_TARGET_ARCH=native LANSTASH_RUN_AFTER_PACKAGE=0 ./package.sh
```

这些命令不替代 Developer ID 签名、公证、票据装订、Gatekeeper、Finder/File Provider、
真实 NAS、升级安装或危险写回读。它们均为 `PENDING_USER_VALIDATION`，详细步骤见
[发布与手工验收历史](../docs/archive/2026-h2/RELEASE_VALIDATION_HISTORY.md) 和
[macOS 桌面云盘发布验收](../docs/compatibility/DESKTOP_CLOUD_DRIVE_RELEASE_ACCEPTANCE_ZH.md)。

## 相关文档

- [GitHub Actions Apple 签名与发布配置](../docs/development/APPLE_GITHUB_ACTIONS_SIGNING_ZH.md)
- [Apple 移动端长期计划](../docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)
- [macOS 对齐总控计划](../docs/development/MACOS_PARITY_REPLICATION_MASTER_PLAN_ZH.md)
- [当前开发进度](../docs/progress/STATUS.md)
- [功能实现与验证等级](../docs/quality/VERIFICATION_LEVELS_ZH.md)
