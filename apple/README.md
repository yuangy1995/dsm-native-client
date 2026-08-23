<!-- doc-role: platform-readme -->
<!-- last-reviewed: 2026-08-20 -->

# Apple 原生客户端

Apple 客户端使用 Swift、SwiftUI 和 Swift Package Manager：macOS 作为业务语义与安全行为
基准，iPhone/iPad 共享移动工程但只交付各自明确的核心或受限范围。

```text
Apps/DsmMac/                   macOS 原生应用（只读参考实现）
Apps/DsmMobile/                iPhone/iPad 通用 SwiftUI 应用
Packages/DsmCore/              领域模型、错误和 Repository 协议
Packages/DsmNetwork/           DSM HTTP、会话和参数编码
Packages/DsmFileFeature/       浏览、详情和预览
Packages/DsmTransferFeature/   下载、上传、删除和恢复任务
```

## 修改边界

- `apple/Apps/DsmMac/**` 是只读范围。需要修改 Workspace、NAS Administration View 或对应
  Model 时，必须暂停并取得用户明确授权。
- `apple/Packages/**` 可以做向后兼容的增量拆分；必须保持 actor、公有协议、会话、错误
  类型和 macOS 回归行为。
- iPhone/iPad 不复制 macOS 菜单栏、悬停、右键、常驻进程或复杂运维流程；移动能力以
  [平台功能矩阵](../docs/progress/PLATFORM_MATRIX.md) 的核心/受限范围为准。

## 本地验证

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
