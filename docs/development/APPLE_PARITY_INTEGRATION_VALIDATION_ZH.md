<!-- doc-role: validation-report -->
<!-- last-reviewed: 2026-09-21 -->

# Apple 跨模块修复集成验证

## 范围与基线

本轮以 main 的既有源码为基线，验证用户已授权的 macOS 同类 API 修复，
包括下载与照片、容器请求和任务核查、VMM 启动策略/单位、NAS 管理写前身份与
写后结果检查，以及远程挂载身份和未知结果恢复。沿用现有 API、身份、签名和工具链。

专用分支为 `codex/macos-parity-integration-validation`。分支只携带 Apple 修复、
必要合成请求样本和本报告；Windows 的完整实施账本、其他 Windows/Android 改动
仍在本地 main，不通过本次 Apple 验证分支发布或提交。

## 五端影响与验证边界

- macOS：共享包、App 模型与视图、正式回归一起验证；新增源文件由 XcodeGen 生成工程。
- iPhone/iPad：保留只读范围；共享 VMM 启动策略使用关闭、恢复原状态、开机三态，
  未知不伪装关闭；运行两种模拟器回归，不增加移动写入口。
- Windows：本轮不带入源码；其适配仍按主工作区已有契约与对齐账本独立验证。
- Android：本轮不修改源码，不扩大既有 Photos 授权范围。
- 请求样本仅为合成数据，不能当作真实 NAS 行为证明。接口证据与兼容性完整记录
  保留在主工作区的 contracts/private-api 和 docs/api/discovery，不以测试分支替代。

## 本地预检

已在隔离分支执行：
`python tools/localization/check_localization.py`、
`python tools/request-contract/validate_contracts.py`、
`python tools/contract-validation/validate_fixtures.py`、
`python tools/codex/check_documentation.py --strict-release`、
`git -c core.safecrlf=false diff --check`。

结果：104 个请求样本、3 组响应样本、22 项既有私有引用检查通过；
Apple 4125 项资源的双语/参数/引用/硬编码检查通过。分支未带入 Windows 新增资源，
其 Windows 资源数不代表主工作区当前总数。

## 云端与用户验收

第一轮提交 `ae5c82bee927aa59e20f316b4dfcacd6394c2d9c` 的 Apple Build
`35561277872` 在共享包测试编译阶段失败：ContainerImagePullTests 四处
replacingOccurrences 缺少 of 参数标签；后续类型推断报错由此产生。已同步修复
测试分支与本地 main，并让五个失败场景各自只改变一个字段，不降低断言。
修复提交为 `4803d24`，后续运行结果另记，尚不能称本轮构建通过。
第二轮 Apple Build `35561952195` 继续发现 Swift 6 actor 初始化中空合并闭包的
隔离限制，以及展示测试仍使用旧镜像下载弹窗参数。提交 `fa3935d` 已修正，
展示测试改用实际跟踪模型与仓库写调用计数，保留“不自动下载”断言。
第三轮 `35562276285` 已通过编译，测试暴露合成替身伪造下载核查结果、JSON
斜线转义的字面比较、缺时区清单、下载目录版本旧断言及硬盘写前重读样本缺失，
最后因测试直接索引缺失请求而中止。另有实时事件固定等待受调度影响。
提交 `431604d` 修正这些测试：保留写次数/终态/版本/顺序断言，使用解码后的
JSON 值比较和有界可观察结果等待，硬盘测试补真实调用顺序并安全解包请求。
第四轮 Apple Build `35562581319` 已开始执行共享包测试，当前未完成；
本轮完整共享测试、工程生成、模拟器和打包仍未通过验收。
第四轮后续结果：XCTest 1281 项中 1224 通过、57 既有条件跳过、0 失败，
另 12 项 Swift Testing 通过；发布脚本回归通过。随后 XcodeGen 工程一致性检查
发现两个新增源文件尚未纳入生成工程，未绕过该检查。已从该 Runner 的生成差异
原样取回工程文件，两个工作区计算出的 Git blob 均与生成结果 `fbcb4f7` 一致。
提交 `8b383d6` 的第五轮 `35563080613` 已再次通过共享测试、生成物检查和
iPhone/iPad 通用应用构建，正在运行两种模拟器回归；Mac 打包尚未完成。
22 端口独立连接检查超时后，改用 GitHub 官方 443 SSH 通道成功推送；
命令级指定主机别名与严格密钥校验，没有更改全局 SSH 配置或仓库远端。
第一轮 Documentation & Quality Preflight `35561277880`、Repository Check
`35561277873` 均通过；不把这些预检或上一轮下载/照片包作为本轮构建通过。
第一轮请求样本变动自动触发的 Android Build `35561277878` 有 1419 个测试，
其中 1 项下载创建契约测试失败：包含 destination 的共享样本已纠正为 v2，
Android 调用方尚未同步。记录为跨端影响，不回退正确样本、不放宽测试，
也不把本次 Apple 授权扩大到 Android 源码；该分支不能声称全仓库门禁通过。
保持正常共享包、Mac、iPhone/iPad、打包与临时签名检查，不删除测试或放宽断言。
新增源文件对应工程文件必须由锁定 XcodeGen 生成，不手工编写工程条目。

PENDING_USER_VALIDATION：真实 NAS、用户编辑器与正式签名/系统扩展验收由用户后置。
用户使用隔离测试数据核对相关读写操作、取消和未知结果恢复；回传操作步骤、
版本类别与脱敏失败信息，不回传会话、主机、账号或真实路径。临时签名测试包
不包含本地磁盘挂载扩展，不自动安装或启动。

测试通过后取回产物，核对所有 CI 修复已保留在本地 main，再删除本地和远端
专用测试分支及隔离工作树；不推送 main、不合并、不正式发布。

## 最终构建与产物

[第六轮 Apple Build](https://github.com/yuangy1995/dsm-native-client/actions/runs/35564520773)
在提交 `a4d597a2f470a4c2a0a3dd19a7b1115de1a99614` 上全部通过。第五轮仅有移动页面
资源集合仍要求旧两态键的失败；现保留页面集合检查，并增加共享三态及未知资源断言。
最终 XCTest 1281 项中 1224 通过、57 既有条件跳过、0 失败；另 12 项 Swift Testing
通过。iPhone 与 iPad 各 498 项通过、0 失败，工程生成一致性、Mac Release 打包与
临时签名组件加载校验通过，不替代真实 NAS、正式签名或 Finder 扩展验收。

产物 `LanStash-macOS`（artifact 10623562344）已取回到忽略的
`apple/Apps/DsmMac/dist/github-parity-integration-20260921/`。ZIP SHA-256 与 GitHub
公布的 digest 相同，仅提取 DMG，未在 Windows 解包重组 App bundle：

- ZIP：`372B66D2838529AB0ABA48BA651457DC114642EE9A3AF61AD8991CBE39F4B564`
- `LanStash-1.0.9-arm64.dmg`：`E59864682FAFA3CA2600D4231135C636DC8D5FFB0D01A9B7EAD4E7D6FD3E89E7`

这是 Apple Silicon 临时签名测试包，不包含本地磁盘挂载扩展；未自动安装/启动、
未覆盖旧包、未正式发布。

清理已完成：六个专用分支临时提交整理为单一语义提交
`429582cdba337d1e958a37bea14f463aedf83240`，未推送改写历史；逐文件 Git blob 对比
确认全部 65 个交付文件已保留在本地 main 工作区。远端删除使用已验证提交的 lease
保护，随后移除隔离工作区和本地测试分支；重新查询确认二者均不存在。
未删除任何其他历史分支，未提交/推送 main，也未合并或发布。
