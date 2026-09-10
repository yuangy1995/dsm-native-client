# 私有 API 发现环境索引

本页是面向人工阅读的匿名环境入口。机器和 AI 应同时读取 [`contracts/private-api/compatibility.json`](../../../../contracts/private-api/compatibility.json)，不要根据“当前”文字猜测版本。

## 设备别名

| 匿名设备 | 用途 | 当前基线 |
| --- | --- | --- |
| `lab-a` | 首台私有 API 发现基准 NAS | `lab-a-dsm-7-2-1-69057-u12-20260729` |

新增 NAS 时依次使用 `lab-b`、`lab-c`。同一 NAS 升级后沿用设备别名，新建环境 ID，并将旧环境标记为 `historical`。

## 环境基线

| 环境 ID | 匿名设备 | DSM | 观察日期 | 状态 | 记录 |
| --- | --- | --- | --- | --- | --- |
| `lab-a-dsm-7-2-1-69057-u12-20260729` | `lab-a` | `7.2.1-69057 Update 12` | 2026-07-29 | `current` | [查看基线](2026-07-29-lab-a-dsm-69057-u12.md) |

环境 ID 和设备别名都不得替换成设备名、型号、序列号、地址、账号或 QuickConnect ID。

## 待归属观察

- [2026-09-10 Container Manager 日志与网络读取观察](2026-09-10-container-read-observation.md)：官方日志 `load` 参数和网络关联数组已核对；版本与设备关系未重新确认，不归入历史基线；没有执行写操作。

- [2026-09-10 Photos 单项删除受控验证](2026-09-10-photos-deletion-observation.md)：唯一合成图已单次删除，任务完成，刷新后原件回读为空；macOS 按用户要求跨版本依接口能力开放供测试，App 重启和异常路径待验证。

- [2026-09-10 Photos 分类、筛选、共享与实况观察](2026-09-10-photos-filter-share-observation.md)：DSM/Photos 版本再次核对；系统分类、只读筛选／共享与独立实况视频单元已记录，未进行分享写入。

- [2026-09-09 Photos 只读观察](2026-09-09-photos-observation.md)：DSM 7.2.1-69057 Update 12、Photos 1.8.2-10090；管理员账号的个人空间读取，Photos 共享权限为 none；设备与 lab-a 的关系未确认，不冒用历史基线。

- [2026-09-09 管理员 Chat 入口观察](2026-09-09-admin-chat-observation.md)：DSM 7.2.1-69057 Update 12、Chat 2.4.1-22111；已核实新建会话 API 声明 JSON 编码，未创建真实会话，不提升写入证据等级。

- [2026-09-09 非管理员应用权限观察](2026-09-09-nonadmin-permission-observation.md)：DSM 7.2.1-69057 Update 12 已由官方初始化响应核实；尚未确认是否为既有 `lab-a`，不因版本相同推断设备相同，不建立第二个 current 基线。
