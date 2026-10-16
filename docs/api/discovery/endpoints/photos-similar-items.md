# Synology Photos 相似照片分组

## 标识、证据与范围

稳定标识 `photos-similar-items`；组件 `synology-photos`；内部接口，读取涉及私有照片，隐私风险 high。2026-09-30 从已登录官方页面加载的脚本静态核对，环境沿用 [观察记录](../environments/INDEX.md#2026-09-28-photos-parity-observation)，DSM/套件版本和设备归属未确认。证据仅为 **static**，没有真实 NAS 请求或写入验收，不挂靠旧 lab-a verification。


## 请求与响应

使用能力发现路径 `entry.cgi`，HTTP POST，业务字符串/数组按既有 JSON 参数编码；会话仅使用现有认证通道。以下 API 前缀按照片实际来源选择 `SYNO.Foto` 或 `SYNO.FotoTeam`，不混用来源。

| API 后缀 | 方法/版本 | 参数 | data 结构 |
| --- | --- | --- | --- |
| Browse.SimilarTimeline | get_similar / 1 | timeline_group_unit="day" | section[].list[] 含 year/month/day/item_count；沿用日期时间线解码 |
| Browse.SimilarItem | list_similar / 1 | start_time/end_time、offset/limit、additional；分类拼图 offset=0/limit=4/additional=[thumbnail] | list[] 为照片，顶层 similar 含 id/count/top_pick/item_id |
| Browse.Similar | get / 1 | id=[groupID] | list[] 为分组快照，同上四字段 |
| Browse.Item | get / 5 | id=分组 item_id，additional=[folder,thumbnail,resolution,orientation,video_convert,video_meta] | list[] 完整成员；沿用照片库基础字段 |

分组字段 id/count/top_pick 为整数，item_id 为整数数组；显示至少两项的有效分组。count 与唯一成员数必须一致，top_pick 及入口照片必须属于成员。成员回读集合完全一致后按 item_id 顺序组装，不依赖响应顺序、不按文件名补齐成员。详情接口保留代表照片的分组身份，组内读取另行获取新快照。

## 能力、权限与失败处理

分类由 Category.get v3 的 similar 项决定；还必须具备上述三个 Similar* v1 能力、个人 UserSetting.enable_similar 或共享 TeamSetting.enable_similar。共享分类要求实际 management 权限，目录 entry 不代表可读取整个共享库。没有因为待实机验证而增加禁用白名单。

固定 profileID/space/groupID，拒绝相册上下文、跨设备、跨空间及不匹配成员；权限刷新使在途读取失效。失效或解散的组显示可重试错误，不恢复旧列表；组内读取失败不遮挡已经加载的照片，关闭或切换预览后迟到结果丢弃。接口不可用不阻断其他分类，不回退扫描文件夹。未知错误使用现有通用映射，不推测专用错误码。

副作用：以上均为读取，没有 NAS 修改。本地只有短期预览状态，没有新增持久化结构。

## 分组管理

下列官方静态方法，共享/个人分别使用 FotoTeam/Foto.Browse.Similar v1；没有真实 NAS 写入，证据仍 static。分组移出不是原件删除。

| 方法 | 参数 | 用户结果 |
| --- | --- | --- |
| set_top_pick | id=groupID, item_id=当前照片整数ID | 更改推荐项 |
| ungroup | id=[groupID] | 拆分组，保留原件 |
| remove_item | id=groupID, item_id=所选整数ID数组 | 移出所选成员，保留原件 |
| add_item | id=原groupID, item_id=原成员数组, top_pick=原推荐项 | 撤销本会话已确认的拆组/移出 |

共享契约增加similarGroups能力、editSimilarGroup(detail, edit)命令及结果similarGroup；仍走现有operationID记录、prepare/perform/review流程，不新增平行写操作系统。UI保留完整确认快照，缩略图独立勾选多个成员；更改前确认原件会保留，成功后提供撤销。未实测不构成功能禁用条件，实际设置/能力/权限继续生效。

预检先固定每张原件的profile/space/id/filename/filesize/folder/indexed_time/type与目录管理权限，再读取Similar.get和SimilarItem.get的成员归组信息，必须仍与原快照一致。每次写入前重查分类访问权；未知提交只读核对，同operationID不重发。SimilarItem.get v1使用id=原成员数组、additional=[thumbnail,resolution,orientation]；身份字段和顶层similar沿只读分组契约。

核对：推荐项需精确成员集合及top_pick，移出需剩余集合完全匹配且所移出照片不再归属原组，拆组需组不存在或有效count小于2且所有原照片不再归属原组；不能只凭组列表消失推断。有效单成员组也按解散处理，非法字段、失败响应和读取异常绝不当作空组。所有结果都需回读完整原件，不能因分组操作而静默接受原件消失。

撤销仅接受同会话已confirmed的remove/ungroup记录与完全相同原快照；重新核对原操作结果仍成立，原件仍可管理，且成员未加入其他组。成功回读恢复原成员集合和原top_pick；同原操作只能发起一次撤销，未知不换编号重试。跨重启恢复范围按平台矩阵记录。新月份窗口只更新已有同组，恢复旧组不会把旧月份照片插进新窗口。


## 清理、批量与识别状态

Similar.get_status v1无业务参数，返回waiting_count（非负整数）、similar_clustering_stage（非空字符串）、is_similar_hash_migration_done（布尔）；两空间各用其API前缀。零等待且迁移完成时不提示；数量大于零且stage=running时显示数量，其余显示等待处理。不枚举或猜测其他stage含义；按15秒间隔仅在分类可见期间读取，错误不阻断浏览，授权代次变化丢弃结果。来源仍是官方静态脚本，没有当前NAS返回验证。

similarGroupDetails允许读取已解散组为空，读取失败绝不伪造解散。删除前先核对完整原组和每张身份，再固定保留补集作为删除确认名单；原件删除沿photos-item-deletion既有契约，无新删除端点。已确认删除后只读刷新原组，不将分组消失当作原件删除证据。最多三次自动读取失败后可只读重试，不刷新整个月份。

多组拆分在一次确认后逐组提交既有ungroup(id=[单组])，保留每组operationID；未知暂停后续，确认成功再续作，失败保留继续/取消选择。会话撤销按逆序恢复已确认组，不覆盖其他操作；删原件不进入分组撤销。平台实现范围见平台矩阵，接口证据仍为static。

### 证据与实现范围

接口证据按[环境记录](../environments/INDEX.md)中的日期、版本、权限和场景读取；静态线索与合成测试不能提升真实行为等级。各端实现及当前缺口只维护于[平台矩阵](../../../progress/PLATFORM_MATRIX.md)和[已知限制](../../../progress/KNOWN_LIMITATIONS.md)。通用认证、危险写与结果规则见[通用标准](../../reference/common.md)。
