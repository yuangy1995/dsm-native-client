# File Station 套件设置与分享页面

端点组 `file-station-package-settings`，组件 file-station，internal / mixed / high。来源：[2026-10-02 官方页面和脚本](../environments/2026-10-02-file-station-live-observation.md)，DSM 7.2.1-69057 Update 12 / File Station 1.4.1-1559。Settings.get 达到 read-verified；Bandwidth.list 字段只读核对。所有 set、主题读写和权限差量目前仅 static。

## 设置

`SYNO.FileStation.Settings/get,set v1`，POST、能力发现 entry.cgi 与编码方式。get：
- 原生 bool：transfer_log_enable、use_unix_default_perm、enable_list_usergrp。
- string 枚举：rf_allow/vd_allow=admin/everyone，sharing_allow/file_request_allow=admin/everyone/per_user。
- bandwidth_enable=bandwidth_disable/bandwidth_enable/bandwidth_schedule，schedule_plan 为时间表字符串；当前真实空值，非空结构依静态组件另行核对。
- sharing_default_limit、sharing_disable_html、sharing_gofile_protocol、enable_sharing_custom_setting 为字符串值。
- sharing_privilege、sharing_group_privilege、file_request_privilege、file_request_group_privilege 为含 items 数组的对象；link_limit 数组。
set 仅提交变化字段，具名授权差量为 enabled_sharing_privilege/disabled_sharing_privilege 及对应 group/file_request 字段。缺失或未知枚举不能默认改成管理员或所有人。

`SYNO.FileStation.VFS.User/get,set v1` 单独管理远程协议挂载权限；get content=user_enabled_type 返回 user_enabled_type=all/admin/custom；set settings 对象。自定义用户/组另读 content=user_settings/group_settings、type=local/domain/ldap、usergroup、offset/limit/domain；usergrp_settings 行 name/enabled/uid/gid/is_modifiable。不可把多 API 设置伪装原子保存。

## 限速

`SYNO.Core.BandwidthControl/list,set v1`；list protocol="FileStation"、owner_type、offset/limit，返回 bandwidths/total。条目 name/protocol/owner_type/policy/schedule_plan 为字符串；upload_limit_1/2、download_limit_1/2、upload_result/download_result 为数字。policy=disabled/enabled/scheduled，0 为不限速，File Station 非零下限 10 KB/s，官方输入最多九位。set bandwidths 数组，只提交修改项。本轮通过 Sources 只读核对 DSM 自带 ux-all.js 的 SYNO.ux.ScheduleTable：DAY_STRING_SHORT 按日、一、二、三、四、五、六；createTemplate 每日 0…23 列；getSchedule 为 currentSchedule.join("")。服务级 0=不限速、1=启用账号限速；账号级 0=不限速、1=默认限速、2=自定义限速。不能把 CLASS_LIST 的通用样式名当作限速语义。

## 分享页面

`SYNO.Core.Theme.FileSharingLogin/get,set v1`：
enable_logo_customize、logo_position（rightup/leftup/rightbottom/leftbottom）、
enable_background_customize、background_position（center/fill/fit/stretch/tile）、
background_color、footer_msg（最多 512）、enable_footer_html。
换图附 logo_type/logo_path、background_type/background_path；来源 fromDS/history/default。
图片接口与来源按文末第三波次契约接入；预览不得拼接带令牌的 URL。

## 管理授权及核对

管理员身份以绑定会话的明确授权摘要为准；未知权限拒绝。内部写要求实际 API 能力、草稿差异确认、提交去重、写前快照与写后回读。按用户要求取消精确固件白名单及专用验证开关。超时回读不匹配或读取失败列为待核对，不重放；不支持的 API 版本明确拒绝。设置读取失败不影响文件浏览。

五端：macOS 实施，Apple 共享增量保留旧调用；其他四端只同步影响。未提交任何真实设置，所有实际保存、普通账号拒绝、并发变化和部分保存均需专用环境验证。


## 本轮原生实现与边界

通用设置、分享/收集授权（UserGrp.list_user/list_group 返回 uid/gid/name/is_admin 后按 uid/gid 逗号串提交增删差量）、SMB/NFS 与 ISO 挂载权限、远程协议访问范围、六种账号来源的分页限速及每周时间表、现有分享页页脚/颜色/布局已接入。Settings 与 VFS.User、BandwidthControl、Theme 分别保存、分别回读，不能描述为一次原子保存。

VFS 自定义名单已接入本机用户/组分页、可修改标识和单 uid/gid 的 enabled 差量；范围切换与名单分别确认保存。域/LDAP 名单按下方来源契约接入。Settings 的 enable_sharing_custom_setting 已观察字符串 false，客户端仅接受明确 true/false 形态；写 boolean 依官方静态表单，和主题布局保存分开，未知形态不伪造关闭。分享页总开关已接入，新图片选择、上传和预览按下方契约接入。所有真实写入均待专用环境验证。

源码：`DsmFileRepository+Settings.swift`、`FileStationSettingsView.swift`、`FileStationBandwidthView.swift`、`FileStationMountAccountList.swift`；自动化：`FileStationParityTests`。合成请求位于 `contracts/request-fixtures/file-station/{set-package-settings,set-sharing-theme-enabled,list-mount-accounts,set-mount-account,set-bandwidth,set-sharing-theme}`；响应位于 `contracts/fixtures-redacted/file-station/settings`，结构描述为 `contracts/schemas/file-station-settings.schema.json`。统一未知核查与原保存互斥，不重放 set。

## 第三波次目录来源契约（static）

官方 `ProtocolUserGrid.loadRoles` 使用 `SYNO.Core.Directory.LDAP/get v1` 的 `enable_client`，`SYNO.Core.Directory.Domain/get v1` 的 `enable_domain`，以及 `test_dc v1` 的 `test_join_success`。启用且加入有效的域用 `get_domain_list v2` 读取 `domain_list`：每项是域字符串，或 `[显示名称, 请求值, 说明]` 数组；请求必须使用第二列，不能用显示名称代替。此处只读查询不加入或修改目录服务。

名单 get 为 `type=local/ldap/domain`、`usergroup=user/group`、`content=user_settings/group_settings`、`substr/offset/limit`；域来源另传 `domain`。保存仍为 `settings.user_settings/group_settings` 中单 uid/gid 与 enabled，不提交整个来源名单。客户端把来源绑定在确认快照及待核查身份中，回读同一来源。某目录查询失败明确提示，可用的其他来源继续列出，不将失败伪装成未启用。

本波次按用户要求取消专用验证开关和精确固件白名单；实际管理员、文件服务权限、目标基线、确认、重复保护和回读仍保留。未执行真实目录权限写入，证据保持 static / synthetic automated。

## 第三波次图片契约（static）

来源为官方 image_selector.js：`SYNO.Core.Theme.Image/list,get,upload v1`。type 为 fbsharing_login_logo/background；list 返回 list 数组（index、path、可选 filename/hd_path）。get 使用 type、index、is_thumbnail=true；客户端先按稳定 path 重新确认当前 index，认证只在 Cookie/请求头，不进入 URL。NAS 选图复用 List/getinfo 与 Thumb，权限由 NAS 校验。默认背景沿官方 dsm7_0 加 1…10（第十张 dsm7_010.jpg）和 default_login_background 目录。

upload 为 multipart，type 与 upload_image 文件字段，成功 data.path 作为历史身份；上传后回查历史，之后页面应用需要独立确认。上传超时保存当前会话内图片摘要，不重复发送同一图片；用户查看历史后可选取已上传项，其他图片和页面设置不被阻断。摘要不包含文件路径、内容或凭据。图片来源为 fromDS/history/default：NAS 保留完整路径，历史/默认用文件名。Theme.set 保存回执和 logo_seq/background_seq 变化同时成立才确认换图成功；单独序列变化不证明未知写完成。

本轮未执行真实上传或主题写入。合成 fixture 覆盖 list/get/upload、历史清单及目录来源；源码为 `DsmFileRepository+ThemeImages.swift`、`FileStationThemeImagePicker.swift`，自动化在 `FileStationParityTests`。真实图片尺寸限制、所有支持格式和最终页面显示由用户验收，不增加推测的文件大小上限。
