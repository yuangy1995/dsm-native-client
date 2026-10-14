# File Station 具名分享与文件请求扩展

端点组 `file-station-sharing-extended`，组件 file-station，internal / mixed / high。来源：[2026-10-02 环境](../environments/2026-10-02-file-station-live-observation.md)中的官方 FileBrowser.js；DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。写请求均为 static，未创建、编辑或删除真实链接；官方管理器自然读取的 list 字段类型和空日期形态已只读核对。

## 请求契约

使用会话认证、API.Info 相对 entry.cgi、POST 表单和声明的参数编码：
- `SYNO.FileStation.UserGrp/list_all v1`：type="all"、prefix、offset、limit；owners 数组，每项 name/type（user/group），total。只选择实际读取的成员，不通过随意输入拼造账号。
- `SYNO.FileStation.Sharing/list v3`：在公开字段上扩展 expire_times、protect_type、protect_users/protect_groups、enable_upload、request_name/request_info、isFolder、limit_size。保留既有 id/path/url/日期/status 字段；缺失不能冒充默认值。
- `Sharing/edit v3`：id 为选中链接数组；protect_type 为 none/password/user；protect_users/protect_groups 是完整所选集合，new_protect_users/new_protect_groups 是相对原快照的新增集合。密码保留时不发送密码；空成员不能静默变公开。expire_times=0 表示不限制次数，正整数表示限制；官方输入最多四位。
- `Sharing/create v3`：公开 path 数组上增加 file_request=true，目标应为可写目录。官方网页先创建后编辑；客户端不得照搬取消窗口后自动删除链接的隐式副作用。
- 文件请求的 edit 发送 file_request=true、request_name/request_info 与有效期；enable_upload 只读展示，不据字段名猜测开关写法；仅把已观察静态字段用于对应业务，不发送 Core.Sharing 的其他父类字段。

## 权限与安全

按实际接口版本能力、目标身份及当前权限开放。按用户追加要求取消实测开关和精确固件白名单，真实写仍待用户验证。具名保护、收集开关和访问限制先读取完整快照，确认影响成员/范围后再写。进行中和未知结果阻止重复写；超时先查原 id，不重建、不自动撤销。密码不回显或记录。修改后逐字段回读；账号保护缺字段不得判成功。文件请求会允许接收者向目标上传，确认须说明这一点。

当前 native 接入以各端账本为准，静态文档不代表功能已实现。原始五端影响为 macOS 与 Apple 共享类型增量；后续移动与 Android 接入见下文和各端主计划，Windows 增量仍需独立适配。真实 NAS 写行为全部 PENDING_USER_VALIDATION。


## 客户端接入增量

已接入具名成员分页选择、完整集合/新增差量、访问次数和文件请求创建/信息编辑。文件请求通过现有取消分享流程关闭，不发送未确认的 enable_upload 写字段。所有新增私有写由 Repository 再校验实际接口能力与绑定会话的文件应用权限；按用户追加要求不再使用精确固件白名单或专用测试开关；未知写保持会话内待核对锁，不能再次提交。分享保护修改前两次核对基线，日期保留不发送参数，避免丢失 NAS 原时分秒。创建请求支持目录写权限检查、每目标独立链接、只读回查类型/消息/接收上传状态。

2026-10-11 Android A3h 使用同一字段与版本接入上述结果：Sharing v3 的严格完整分页和快照、UserGrp v1 成员分页/类型绑定、用户及群组完整集合和新增差量、访问次数与文件请求创建/信息编辑。基本密码与日期意图独立，保留日期不发送；具名保护修改在成员查询后重新核对快照，读取权限与目录写权限仍由绑定工作区和文件信息检查。创建只认本次回执的新编号，缺编号不按路径认领；新密码只在内存提交，成功响应加上状态回读才能确认。

Android 新增独立加密恢复记录，写前同步保存、收到回执后保存原编号与成功事实；重新打开同一账号时只读恢复，不把其他账号或同名链接当作原结果。未知记录不会生成重发请求，也不因关闭窗口自动删除链接。完整扩展字段缺失时不开放高级修改，不发送猜测的收集开关；界面只在创建收集、移除密码和访问范围改变时说明具体后果。二维码使用已批准的 ZXing Core 3.5.4 在本机生成，许可证随包保留，不向外部二维码服务发送链接。此增量不改变共享 API 契约和其他四端代码，合成回归与模拟器测试不提升 DSM 版本/套件真实写证据等级。

## 2026-10-14 五端写入策略更正

五端均按实际接口能力、当前账号/对象权限、必要确认、防重复提交和结果复查开放操作；不匹配DSM/build/套件或客户端类型版本白名单，也不为版本匹配要求额外系统管理读取权限。未实测版本不标为已验证，但不据此关闭功能。 Android已删除A10误加的限制；实际权限和恢复保护保留，见[功能参考](../../reference/files.md#写入可用性与版本策略五端统一)。真实环境证据等级不变。
