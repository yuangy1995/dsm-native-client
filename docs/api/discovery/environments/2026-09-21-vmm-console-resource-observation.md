# VMM 控制台静态资源与别名路径核查

按环境模板建立；不保存地址、会话或真实 VM 内容。

| 字段 | 值 |
| --- | --- |
| 日期 | 2026-09-21 |
| 匿名设备 / 基线状态 / 替代基线 | 待归属 / 待归属 / none |
| DSM / build / Update | 同会话既有记录 7.2.1 / 69057 / Update 12，本次尚未重读系统版本 |
| 套件 | 既有记录 Virtualization 2.6.5-12202，本次核对其已加载/同源静态资源 |
| 架构 / 证书类别 | 未独立核实 / 未独立核实 |
| 连接 / 权限 | Chrome 既有 HTTPS QuickConnect 会话 / 先前管理员记录，本次只读 |

## 范围

读取官方 noVNC HTML/脚本中的 app_alias、WebSocket 路径及静态资源路径规则。
研究页不指定 VM，不自动连接；不新增/修改/启动/删除 VM，不改应用门户或代理。
只保存必要字段名、静态代码的路径规则及验证结论，不导出 HTML、脚本、HAR、
Cookie、SID、SynoToken、地址、用户配置或真实画面。若资源加载失败，不猜路径。

## 结论

已在未指定 VM、autoconnect=false 的同源研究页检查官方 noVNC app.js。页面代码
只在 autoconnect=true/1 时连接，本次未发起 VM 连接或电源操作。

- `static`：Synology initPathSetting 在 path 后追加 app_id；可选 sharing_id 只供
  分享连接，本客户端不提供此模式。UI.connect 将 app_alias 放在 path 之前，因此
  会话控制台为同源 /<alias>/synovirtualization/ws/<guest-id>?app_id=<window-id>，
  没有别名时省去该段。app_id 与启动文档的同一窗口参数一致，不能省略或混用。
- `static`：noVNC 的接收队列把 ArrayBuffer 作为有序字节流追加，支持原生消息桥
  的有界分块交付，不需要累计整个高分辨率画面消息。
- `read-verified`：已加载的资源包括 noVNC/app.js、app/error-handler.js、样式、
  SVG 图标、app/locale/zh.json 和 app/sounds/bell.oga。语言通过 GET XMLHttpRequest
  读取；zh.json 返回 application/json，bell.oga 返回 application/octet-stream。
- `static/read-verified`：原始 HTML 使用相对路径；套件图标限定为
  ../images/VirtualManagement_{16,24,32,48,64,72,256}.png。已读取的 32 像素图标
  返回 image/png。浏览器工具注入的 data: 图标不算官方资源，不据此扩展白名单。
- 当前资源版本查询参数为 2.6.5-12202，与先前套件版本记录一致。

Windows 合成 WebView2 验证表明，IPv6 字面地址的显式 CSP 源会阻断语言 XHR。
最终方案保持 connect-src 'none'：语言 GET 复用受限原生消息桥，必须匹配窗口
来源/上下文和现有同源语言路径白名单，不开放一般代理。静态路径、真实资源读取
与真实别名部署的验证分开；没有修改 DSM 应用门户/代理，也不声称真实别名入口
或 VNC 画面已经在此环境验证。无 HTML/脚本/HAR/响应/画面落盘。
