# DsmMobile

岚仓（LanStash）的 iPhone/iPad 通用原生 App 目录。

- iPhone 使用导航栈。
- iPad 使用 `NavigationSplitView`。
- 两种设备共享 HTTPS/QuickConnect 登录、会话恢复、文件、照片、消息、下载、容器、虚拟机、NAS 设置和传输业务层。
- VMM 当前为受限只读投影；完整管理和触控控制台在已授权的 M7 实施，不能将共享网络方法当作已有移动入口。
- 登录成功后保留名称、NAS 地址和账号；真机仅在用户明确选择后把密码存入 Keychain，并可进一步开启自动登录。无签名模拟器构建没有 Keychain entitlement，因此仅在 Simulator 使用应用沙盒内的 AES-GCM 存储，便于完整验证登录和自动登录主流程，不改变真机存储策略。
- 可选的自定义 HTTPS 端口默认收在“高级连接设置”中；仅允许 HTTPS 正式连接。

生成并验证工程：

```bash
xcodegen generate
xcodebuild \
  -project DsmMobile.xcodeproj \
  -scheme DsmMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

当前实施与证据只维护于[移动主计划](../../../docs/development/APPLE_MOBILE_MACOS_PARITY_DEVELOPMENT_PLAN_ZH.md)。2026-10-04 起按用户确认的 M0→M8 完善两端；已有测试包含状态机、网络替身及静态源码护栏，静态断言不代表实际 UI 操作通过。每轮分别保留 iPhone 与 iPad 的测试结果，不沿用过期的固定测试数量。

通用应用支持 iPhone 与 iPad，仍需分别在真机上验证动态文字、VoiceOver、分栏、键盘和网络切换。
