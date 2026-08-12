# DsmMobile

岚仓（LanStash）的 iPhone/iPad 通用原生 App 目录。

- iPhone 使用导航栈。
- iPad 使用 `NavigationSplitView`。
- 两种设备共享 HTTPS/QuickConnect 登录、会话恢复、文件、照片、消息、下载、容器、虚拟机、NAS 设置和传输业务层。
- VMM 提供虚拟机、主机、存储、网络、映像、保护和日志入口；危险写操作使用系统确认框。
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

当前结果：Apple 共享包测试通过；DsmMobile 5 项单元测试通过，QuickConnect 登录、会话恢复和冷启动自动登录路由已覆盖；
Release 已在 iPhone 目标构建，并在 iPad 模拟器完成安装与启动检查。

通用应用支持 iPhone 与 iPad，仍需分别在真机上验证动态文字、VoiceOver、分栏、键盘和网络切换。
