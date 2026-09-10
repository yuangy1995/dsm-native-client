# Photos 分类、筛选与共享只读观察

## 环境

- 发现日期：2026-09-10。
- 匿名设备归属：尚未确认与既有 lab-a 的关系，不新增或覆盖 current 基线。
- DSM/build/Update：7.2.1/69057/12，本轮官方初始化响应核对；Photos 1.8.2-10090，由本轮 Setting.Admin.get 核对。
- 连接与证书类别：未验证；权限类别：DSM 管理员，不能由此推断共享空间或分享写权限。
- 证据来源：已登录官方 Photos 网页的必要读取请求、官方静态资源与脱敏响应结构。

## 范围与安全

本记录范围为只读发现，不执行写操作。后来单项删除的授权和行为另见[删除观察](2026-09-10-photos-deletion-observation.md)，不把后续授权倒写成此处已进行写验证。

- 核对分类相册、人物／位置／媒体类型等筛选，以及与我共享、与他人共享、照片请求的读取结构。
- 不为探测创建公开链接、修改访问权限、发送邀请、上传或删除真实照片。
- 不保存原始 HAR、凭据、地址、照片、人物／地点名称或其他真实用户数据，只保存必要结构。
- 写入实现和真实写行为验证分开；未验证创建／权限变更保持关闭。

## 结论

### 后续筛选与共享报错复查

用户回传与他人共享报错和筛选条件／布局问题。本次只比较已记录读取方法的参数、扩展筛选候选结构；不更改用户筛选设置、不创建或修改共享。待核实 access_permission 是否为 Album.list 不支持的 additional 字段，不能提前认定根因。

复查结果：

- 原请求和仅去掉 access_permission 的请求都返回 code=120，errors.name=sort_by、reason=condition。故额外权限字段并非本次根因。
- get_album_list_order 返回 shared_with_others_sort_by=share_modify_time、shared_with_others_sort_direction=desc。补入 sort_by="share_modify_time"、sort_direction="desc" 后，两个 additional 版本均成功；客户端采用官方相册列表的 thumbnail/sharing_info 字段集合。
- 完整候选请求核实 camera/lens/iso/aperture 为 id:number、name:string 数组，当前返回的 id 均为整数；focal_length_group 为整数 start/end，exposure_time_group 的 start/end 为 num/den 分数；零端点代表开放边界。
- 上述拍摄条件组合发送给 get_with_filter，返回成功。只记录接受的字段与类型，不保存实际相机、地点、人物或照片信息。
- 官方前端标准筛选设置包含类型、时间、人物、位置、评分、标签、相机、镜头、焦距、曝光、光圈、ISO；虽然候选响应有 flash，但官方设置代码明确排除该入口，本轮不自行解释闪光灯编码或新增该项。concept/folder_filter 未返回可用候选，不伪造选项。

- 官方分类返回 recently_added、person、concept、geocoding、general_tag、video；普通 Album.list 为空不代表系统分类不存在。
- 视频、人物、位置筛选的官方 Timeline.get_with_filter v3 / Item.list_with_filter v2 请求已观察，字段分别为 item_type 数字数组、person 数字数组配 person_policy="or"、geocoding 数字数组；time 为 start_time/end_time 对象数组。
- 评分 rating=[0] 做同源只读补验，返回成功与 section 数组；未对比真实评分筛选效果，不当作完整行为验收。
- 共享三个列表均取得成功空响应：Sharing.Misc.list_shared_with_me_album v2、Browse.Album.list v4 category="shared"、PhotoRequest.list v1。非空内容和创建／撤销／权限修改未验证。
- 官方实况播放首先调用 Browse.Unit.get v1，id_item 数字数组，返回 list[].id_item 与 unit[]；选择 live_type="video" 的单元，再以 Streaming v2、type="unit"、该视频单元 ID、quality="high" 播放。主照片 ID 和照片缩略图 ID 均不等于视频单元 ID。
- Item.get v5 可提供 exif 的相机／镜头／光圈／曝光／焦距／ISO 字符串、rating 数字、gps.latitude/longitude 数字，以及 address 的行政区与街道字符串；只保留结构，不保存实际位置。
- 端点与客户端说明见 photos-library-read.md；没有执行或验证分享写入。

### MP4 播放问题只读排查

- 用户报告同一 App 中 MOV 可播放、两项 MP4 不可播放，官方网页可播放。本轮只对用户指出的媒体读取必要元数据、官方播放参数及有界媒体响应，不下载完整视频，不保存真实名称或内容。
- 当前源码对所有视频固定 quality="high"、use_mov=true；截图对应播放器拒绝非成功状态或 JSON／HTML 内容的分支。具体根因待网页请求对照，不能据文件扩展名断言编码不支持。
- 两个用户指出的 MP4 均返回 video_convert=[]。按 App 的 Streaming v2、quality="high"、use_mov=true 发送 Range: bytes=0-511，均得到 HTTP 404、text/html；同一项目改用 Download v2、item_id:[项目ID]，均得到 HTTP 206、video/mp4。只读少量响应后取消，不保存媒体正文。
- 官方静态前端 yE 根据 video_convert 和 video_meta 选择质量；raw 分支调用 Download.download（item_id 或 unit_id），仅当转换列表存在选定 quality 才走 Streaming.streaming。空转换列表不能视为存在 high。
- 结论：已复现 App 请求不存在的转换版本；不是“MP4 扩展名不受支持”的证据，也不能把此错误指向重新登录。首次诊断未改代码；后续用户授权修复后已按可用转换列表选源，并补普通视频与实况回归。App 实际播放仍待用户验收。
- 修复阶段对照用户指出的可播放 MOV：video_convert 含 high，video_meta 为 container_type="mp4"、video_codec="hevc"；与无转换版 MP4 的差异解释了原有行为。没有为检查下载完整视频或更改 NAS 内容。
