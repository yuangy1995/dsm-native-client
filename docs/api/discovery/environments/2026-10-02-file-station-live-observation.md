# File Station 对齐续查环境记录

依据环境模板建立；用户已明确允许访问 Chrome 中已登录的 DSM。发现阶段只读，不创建分享、不修改权限、不挂载连接、不保存设置。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 | 待归属观察，不建立 current 基线 |
| 匿名设备别名 | 未确认，不按相同版本推断为 lab-a |
| 基线状态 | 待归属 |
| 替代的旧基线 | none |
| 发现日期 | 2026-10-02 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12；官方信息中心显示 |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户已登录的 Chrome DSM；QuickConnect 直连页面，链路类别未独立验证 |
| 证书类别 | 未验证 |
| 账号权限类别 | 未验证 |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 | 备注 |
| --- | --- | --- | --- | --- |
| file-station | File Station | 1.4.1-1559 | 已启动 | 官方套件中心详情；不据此推断所有接口可用 |

## 证据来源与范围

- Chrome 原生界面可读取已登录的官方桌面；网页检查通道超时，随后通过 Chrome 原生开发工具观察必要请求，未导出网络日志。
- 拟核实 DSM 与套件版本，以及全文、分享/文件请求、权限、ISO/远程位置和套件设置的官方界面与契约。
- 不导出 HAR，不保存主机、账号、路径、文件名、Cookie、SID、SynoToken、DID 或原始响应。
- 当前观察不能提升历史设备基线或任何写操作证据等级。

## 结论

- `SYNO.FileStation.Settings/get v1`：官方设置窗口自然发出的 POST，HTTP 200、业务成功；响应字段类型已只读核对。原生布尔：`transfer_log_enable`、`use_unix_default_perm`、`enable_list_usergrp`；字符串：`rf_allow`、`vd_allow`、`sharing_allow`、`file_request_allow`、`bandwidth_enable`、`schedule_plan`、`sharing_default_limit`、`sharing_disable_html`、`sharing_gofile_protocol`、`enable_sharing_custom_setting`。权限集合为含 `items` 的对象，`link_limit` 为数组；当前时间表为空串，非空形态仅有静态证据。
- `SYNO.Core.BandwidthControl/list v1`：官方速度限制表产生读取；响应条目中的 `name/protocol/owner_type/policy/schedule_plan` 为字符串，`upload_limit_1/2`、`download_limit_1/2`、`upload_result/download_result` 为数字。未保存账号或实际限速值。为打开已禁用的设置按钮，仅在未保存草稿中切换限速单选项，完成后明确选择“不要保存”；未提交任何设置写请求。
- 官方静态资源已读取：`FileBrowser.js`（623128 字节，SHA-256 `92df4d0fb1b640c2920e0209a08fc033b150e0be0ce32b940b5a551774570d18`）、`FileProperty.js`、`FileBrowserUtil.js`、`PermissionDialog.js`、`BandwidthControl.js`；只保留临时分析副本，完成契约记录后删除，不提交厂商脚本。
- 静态确认搜索 `search_content` 与 `has_not_index_share`，分享 `protect_type/protect_users/protect_groups/expire_times/file_request`，ISO `mount_iso`，VFS Connection/Profile，以及 POSIX/ACL、套件设置与主题接口候选。需在稳定端点记录中进一步列清参数和回读语义；所有写操作仍未行为验证。
- 云盘授权静态流程依赖群晖官方授权页及同源窗口消息回调；本轮没有发起云盘登录，没有读取或保存云盘令牌。

- 全文搜索进一步只读核查：官方高级搜索出现“启用文件内容搜索”；使用无真实业务含义的合成关键词触发搜索。自然 POST `SYNO.FileStation.Search/start v2`，`search_content=true`、`search_type="advance"`、`recursive=true`；HTTP 200 / 业务成功，返回 taskid 和原生布尔 `has_not_index_share=true`，官方页面同步提示部分位置未建索引。未保存任务编号、目录或结果行，不以零命中证明实际正文召回。
- 信息中心自然响应核对 `SYNO.Core.System/info v3` 的 `firmware_ver` 为 `DSM 7.2.1-69057 Update 12`；客户端只需此版本字段，其他设备数据不进入记录。

- 官方共享链接管理器自然产生 Sharing.list 读取，已只读核对 has_password/enable_upload/isFolder 为 bool，expire_times 为 number，protect_users/protect_groups 为数组，protect_type/project_name/request_name/request_info 为 string。无日期的 date_available/date_expired 实际返回空字符串；含时分秒形态仍是官方静态支持，未保存链接、账号、目录或业务正文。

- Sources 只读检查 DSM ux-all.js 中 ScheduleTable 的星期顺序、每行 24 小时、join 编码和服务/账号时段标签；只记录方法与枚举，不保存页面数据。未修改时间表，未执行任何保存请求。

- 只读打开官方远程连接向导，观察 Protocol.list 的协议、默认端口与 has_server 布尔结构；仅核对字段和协议枚举，没有提交连接。has_server=false 不等于该协议不可配置；已按官方树根处理代码纠正语义。没有依据可见的首屏条目推断完整协议清单。

- Settings.get 的 `enable_sharing_custom_setting` 进一步核对为字符串 `false`。为查看官方主题弹窗临时勾选未保存草稿，主题窗口取消后父设置明确选择“不要保存”；没有提交主题或设置写入。主题 get/set 仍只有静态证据，不能把打开页面当成响应验证。

- 第三波次读取官方 image_selector.js 静态资源，确认 Theme.Image 的 type、list/get/upload、upload_image、历史 path/index 与默认图片编号规则；所有主题/目录权限写保持未验证。
- 云授权公开合成检查不连接 NAS：群晖 login.php 在 major/minor/type/host/callback 参数下进入 Google 官方账号选择页，Google state 保留 127.0.0.1 临时端口、合成路径与回调名，redirect_uri 保持群晖官方 redirect.php。未选择账号、未提交授权、未取得或保存令牌；成功回调载荷仍未验证。临时公开测试标签页已关闭。
