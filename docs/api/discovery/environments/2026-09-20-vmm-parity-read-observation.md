# VMM 高级配置与控制台只读核查

按环境模板建立；此前观察仅作线索，未知字段不沿用旧环境结论。

## 基本信息

| 字段 | 值 |
| --- | --- |
| 环境标识 / 匿名设备别名 | 待归属，不根据地址或设备名称推断 |
| 基线状态 / 替代的旧基线 | 待归属 / none |
| 发现日期 | 2026-09-20 |
| DSM 版本 / build / Update | 7.2.1 / 69057 / 12；官方页面 Session fullversion=69057-s12 |
| 设备架构类别 | 未验证 |
| 连接方式 | 用户已登录的 Chrome 官方 DSM，QuickConnect 类；直连/中继未验证 |
| 证书类别 | 待核实 |
| 账号权限类别 | 管理员；只读取 is_admin 布尔，不记录账号 |

## 相关套件

| 项目组件标识 | 显示名称 | 完整版本 | 运行状态 |
| --- | --- | --- | --- |
| virtual-machine-manager | Virtual Machine Manager | 2.6.5-12202 | 官方页面已打开，资源读取成功 |

## 证据来源

- 已登录官方网页自然产生的只读请求、已加载前端静态线索。
- 既有 vmm-internal 文档、Mac 源码仅作定位，不提升证据等级。

## 发现范围

- 核查系统类型、固件、启动介质、CPU 优先级及控制台会话/导航的既有契约缺口。
- 不保存表单、不提交创建、不启动/停止/重启/删除、不调整网络或权限。
- 不打开会话凭据，不导出 HAR；只保存必要版本、参数名称和字段类型。

## 安全检查

- 不保存 Cookie、SID、SynoToken、DID、OTP、主机、账号、设备名、VM 名称或路径。
- 不输出响应正文；只读观察后清除临时监听，不持久化原始截图或抓包。

## 结论

- `read-verified`：官方 API.Info 响应声明内部 Guest、Guest.Image、Network 为 v1–v2，Guest.Action 为 v1，路径 entry.cgi、请求格式 JSON。Guest.get v2 以单 guest_id 读取；编辑窗口通过 Entry.Request 调用 Guest.get_setting v1（guest_id），读取成功。
- Guest.get / get_setting 的 autorun、cpu_weight 为原生数字；该次受控读取值分别为 0、256。只记录与设置语义有关的值，不记录资源身份、名称、路径或网络映射。
- `static`：当前加载的 virtualization.js 中 Guest.set 固定 v1；CPU 档位为 8/64/256/512/1024；autorun 为 0 不启动、1 恢复原状态、2 启动。上述含义来自官方控件数据，不将读取一个当前值或打开表单当作写行为验证。
- `static`：控制台使用同源 /webman/3rdparty/Virtualization/noVNC/vnc.html，参数 autoconnect/reconnect、path=synovirtualization/ws/<guest-id>、title、app_id、kb_layout、v、app_alias；Default 键盘布局取套件常规设置，重写入口保留应用别名路径。没有打开控制台或获取其会话值，不能宣称 WebSocket/认证已验证。
- `static`：固件编辑字段 bios，展示读取 use_ovmf；安装介质 iso_images 含两个位置，未挂载哨兵为 unmounted。字段转换、提交完整性及实际保存结果仍须后续契约切片，不能凭字段名字复制请求。
- 已取消编辑并关闭本次打开的 VMM 窗口，Debugger/Network 监听关闭。官方打开页面自然产生套件缓存/连接检查、候选 MAC 生成及读取请求；未点击保存、创建、电源、删除、连接控制台或改变权限。
- 无本地原始 HAR、截图、响应或脚本副本；只保留本记录中的脱敏结构。内存中原始响应和脚本已清除。
