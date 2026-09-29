import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class SynologyPhotosRepositoryTests: XCTestCase {
    func test删除默认关闭且不发送任何删除预检或写请求() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        do { try await repository.prepareDeletion(XCTUnwrap(page.items.first)); XCTFail("未启用时必须关闭删除") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
    }

    func test删除只提交一次并仅以成功空响应确认完成() async throws {
        let preflight = [
            response(itemPage),
            response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#)
        ]
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)] + preflight + [
            response(#"{"success":true,"data":{"task_info":{"id":1}}}"#), response(itemPage),
            response(#"{"success":true,"data":{"list":[]}}"#)
        ])
        let repository = try makeRepository(transport, deletionEnabled: true)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        let first = try await repository.deletePhoto(photo, operationID: UUID())
        XCTAssertEqual(first, .pendingReview)
        let retry = try await repository.deletePhoto(photo, operationID: UUID())
        XCTAssertEqual(retry, .confirmed)
        let requests = await transport.recordedRequests()
        let deletes = try requests.filter { $0.httpMethod == "POST" }.map(decode).filter { $0["method"] == "delete" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.first?["api"], "SYNO.Foto.BackgroundTask.File")
        XCTAssertEqual(deletes.first?["item_id"], "[7]")
        XCTAssertEqual(deletes.first?["folder_id"], "[]")
    }

    func test删除不查询版本且没有管理权限仍拒绝写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage),
            response(itemPage),
            response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":false}}}}}"#)
        ])
        let repository = try makeRepository(transport, deletionEnabled: true)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        do { _ = try await repository.deletePhoto(XCTUnwrap(page.items.first), operationID: UUID()); XCTFail("没有管理权限不得删除") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 7)
        let preflight = try requests.suffix(2).map(decode)
        XCTAssertEqual(preflight.map { $0["api"] }, ["SYNO.Foto.Browse.Item", "SYNO.Foto.Browse.Folder"])
    }

    func test删除提交错误不重放且权限错误不能视为已删除() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage),
            response(itemPage),
            response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#),
            response(#"{"success":false,"error":{"code":117}}"#),
            response(#"{"success":false,"error":{"code":105}}"#)
        ])
        let repository = try makeRepository(transport, deletionEnabled: true)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        let outcome = try await repository.deletePhoto(photo, operationID: UUID())
        XCTAssertEqual(outcome, .pendingReview)
        do { _ = try await repository.deletePhoto(photo, operationID: UUID()); XCTFail("无权限不能认为删除成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        let deletes = try requests.filter { $0.httpMethod == "POST" }.map(decode).filter { $0["method"] == "delete" }
        XCTAssertEqual(deletes.count, 1)
    }
    func test删除明确权限或会话拒绝显示原因且原操作不重发() async throws {
        for code in [105, 106, 107, 119] {
            let preflight = [response(itemPage), response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#)]
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)] + preflight + [
                response("{\"success\":false,\"error\":{\"code\":\(code)}}")
            ] + preflight + [response(#"{"success":true,"data":{"task_info":{"id":1}}}"#), response(#"{"success":true,"data":{"list":[]}}"#)])
            let repository = try makeRepository(transport, deletionEnabled: true)
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let photo = try XCTUnwrap(page.items.first), operationID = UUID()
            for _ in 0..<2 {
                do { _ = try await repository.deletePhoto(photo, operationID: operationID); XCTFail("明确拒绝不能报告待核查或成功") }
                catch let error as AppError { XCTAssertEqual(error.category, code == 105 ? .permissionDenied : .authenticationRequired) }
            }
            let rejectedRequests = await transport.recordedRequests()
            XCTAssertEqual(try rejectedRequests.map(decode).filter { $0["method"] == "delete" }.count, 1)
            // 新的明确用户确认重新预检；不是自动重放之前失败的操作。
            let next = try await repository.deletePhoto(photo, operationID: UUID())
            XCTAssertEqual(next, .confirmed)
            let allRequests = await transport.recordedRequests()
            XCTAssertEqual(try allRequests.map(decode).filter { $0["method"] == "delete" }.count, 2)
        }
    }

    func test删除预检不依赖无关详情且不请求附加媒体字段() async throws {
        let minimal = #"{"success":true,"data":{"list":[{"id":7,"filename":"sample.jpg","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"photo","additional":{"exif":{"iso":800},"address":{"unexpected":{}},"video_convert":false}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(minimal),
            response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#)
        ])
        let repository = try makeRepository(transport, deletionEnabled: true)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        try await repository.prepareDeletion(XCTUnwrap(page.items.first))
        let requests = await transport.recordedRequests()
        let identity = try decode(requests[5])
        XCTAssertEqual(identity["method"], "get")
        XCTAssertEqual(identity["id"], "[7]")
        XCTAssertNil(identity["additional"])
        XCTAssertFalse(try requests.map(decode).contains { $0["method"] == "delete" })
    }

    func test与他人共享必须发送共享修改时间排序且不混用权限字段() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        _ = try await repository.sharedEntries(.withOthers, offset: 100, limit: 100)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["sort_by"], #""share_modify_time""#)
        XCTAssertEqual(fields["sort_direction"], #""desc""#)
        XCTAssertEqual(fields["category"], #""shared""#)
        XCTAssertEqual(fields["offset"], "100")
        let additional = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(fields["additional"]).utf8))
        XCTAssertEqual(additional, ["thumbnail", "sharing_info"])
    }

    func test扩展筛选使用稳定ID及结构化焦距曝光范围() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        var filter = SynologyPhotoFilter()
        filter.tagID = 3; filter.cameraID = 4; filter.lensID = 5; filter.isoID = 6; filter.apertureID = 7
        filter.focalRange = .init(start: 22, end: 35)
        filter.exposureRange = .init(start: .init(num: 1, den: 500), end: .init(num: 1, den: 60))
        XCTAssertTrue(filter.isActive)
        _ = try await repository.photos(in: .personal, query: .filtered(filter, startTime: 0, endTime: 100), offset: 0, limit: 20)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        for (key, value) in ["general_tag": "[3]", "camera": "[4]", "lens": "[5]", "iso": "[6]", "aperture": "[7]"] {
            XCTAssertEqual(fields[key], value)
        }
        XCTAssertEqual(fields["general_tag_policy"], #""or""#)
        let focal = try JSONDecoder().decode([SynologyPhotoFocalRange].self, from: Data(try XCTUnwrap(fields["focal_length_group"]).utf8))
        let exposure = try JSONDecoder().decode([SynologyPhotoExposureRange].self, from: Data(try XCTUnwrap(fields["exposure_time_group"]).utf8))
        XCTAssertEqual(focal, [filter.focalRange!])
        XCTAssertEqual(exposure, [filter.exposureRange!])
    }

    func test扩展筛选候选请求完整且解析类型不丢失() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(#"{"success":true,"data":{"person":[],"geocoding":[],"general_tag":[{"id":3,"name":"Sample tag"}],"camera":[{"id":4,"name":"Sample camera"}],"lens":[{"id":5,"name":"Sample lens"}],"iso":[{"id":6,"name":"100"}],"aperture":[{"id":7,"name":"2.8"}],"focal_length_group":[{"start":22,"end":35}],"exposure_time_group":[{"start":{"num":1,"den":500},"end":{"num":1,"den":60}}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let options = try await repository.filterOptions(in: .personal)
        XCTAssertEqual(options.cameras.first?.id, 4)
        XCTAssertEqual(options.tags.first?.name, "Sample tag")
        XCTAssertEqual(options.exposureRanges.first?.start.den, 500)
        let requests = await transport.recordedRequests()
        let settings = try JSONDecoder().decode([String:Bool].self, from: Data(try XCTUnwrap(decode(XCTUnwrap(requests.last))["setting"]).utf8))
        for key in ["general_tag", "camera", "lens", "iso", "aperture", "focal_length_group", "exposure_time_group"] { XCTAssertEqual(settings[key], true) }
    }
    func test实况视频查询视频单元且不误用主照片编号() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(itemPage.replacingOccurrences(of: #""type":"photo""#, with: #""type":"live""#)),
            response(#"{"success":true,"data":{"list":[{"id_item":7,"unit":[{"id":701,"live_type":"photo"},{"id":702,"live_type":"video","additional":{"video_convert":[{"quality":"high"}]}}]}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let source = try await repository.videoSource(for: XCTUnwrap(page.items.first))
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["id"], "702")
        XCTAssertEqual(fields["type"], #""unit""#)
        let requests = await transport.recordedRequests()
        let unitFields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(unitFields["api"], "SYNO.Foto.Browse.Unit")
        XCTAssertEqual(unitFields["id_item"], "[7]")
    }
    func test筛选条件发送到Photos而不是本地裁剪已加载列表() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        var filter = SynologyPhotoFilter()
        filter.mediaType = 1; filter.personID = 8; filter.locationID = 9; filter.rating = 0
        filter.startTime = 10; filter.endTime = 90
        _ = try await repository.photos(in: .personal, query: .filtered(filter, startTime: 0, endTime: 100), offset: 0, limit: 20)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["method"], "list_with_filter")
        XCTAssertEqual(fields["version"], "2")
        XCTAssertEqual(fields["item_type"], "[1]")
        XCTAssertEqual(fields["person"], "[8]")
        XCTAssertEqual(fields["person_policy"], #""or""#)
        XCTAssertEqual(fields["geocoding"], "[9]")
        XCTAssertEqual(fields["rating"], "[0]")
        let range = try JSONDecoder().decode([[String:Int]].self, from: Data(try XCTUnwrap(fields["time"]).utf8))
        XCTAssertEqual(range, [["start_time":10,"end_time":90]])
        XCTAssertNil(fields["path"])
    }

    func test分类发现与普通相册独立且忽略未知分类() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[{"id":"recently_added"},{"id":"person"},{"id":"concept"},{"id":"geocoding"},{"id":"general_tag"},{"id":"video"},{"id":"unknown"}]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let categories = try await repository.categories()
        XCTAssertEqual(categories, Set(SynologyPhotoCategory.allCases))
    }

    func test共享三个页签只读且不创建或修改权限() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(#"{"success":true,"data":{"list":[{"id":1,"name":"Sample album"}]}}"#),
            response(#"{"success":true,"data":{"list":[]}}"#),
            response(#"{"success":true,"data":{"list":[{"passphrase":"TEST_REQUEST","subject":"Sample request","sharing_link":"https://photos.example.invalid/request/sample"}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let mine = try await repository.sharedEntries(.withMe, offset: 0, limit: 20)
        let others = try await repository.sharedEntries(.withOthers, offset: 0, limit: 20)
        let incoming = try await repository.sharedEntries(.requests, offset: 0, limit: 20)
        XCTAssertEqual(mine.first?.albumID, 1)
        XCTAssertTrue(others.isEmpty)
        XCTAssertEqual(incoming.first?.title, "Sample request")
        XCTAssertNotNil(incoming.first?.url)
        let requests = await transport.recordedRequests()
        let methods = try requests.suffix(3).map { try decode($0)["method"] }
        XCTAssertEqual(methods, ["list_shared_with_me_album", "list", "list"])
    }

    func test详情保留曝光镜头与评分() async throws {
        let detailed = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4,"exif":{"camera":"Sample camera","lens":"Sample lens","aperture":"2.8","exposure_time":"1/125","focal_length":"35","iso":"100"}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(detailed)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try await repository.details(for: XCTUnwrap(page.items.first))
        XCTAssertEqual(photo.camera, "Sample camera")
        XCTAssertEqual(photo.lens, "Sample lens")
        XCTAssertEqual(photo.aperture, "2.8")
        XCTAssertEqual(photo.exposureTime, "1/125")
        XCTAssertEqual(photo.focalLength, "35")
        XCTAssertEqual(photo.iso, "100")
        XCTAssertEqual(photo.rating, 4)
    }
    func test照片身份隔离账号与空间() {
        let profile = UUID()
        let id = SynologyPhotoID(profileID: profile, space: .personal, unitID: 7)
        XCTAssertNotEqual(id, SynologyPhotoID(profileID: profile, space: .shared, unitID: 7))
        XCTAssertNotEqual(id, SynologyPhotoID(profileID: UUID(), space: .personal, unitID: 7))
    }

    func test根目录按名称解析真实标识并核对读取权限() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"folder":{"id":42,"name":"/","parent":0,"additional":{"access_permission":{"view":true}}}}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let root = try await repository.rootFolder(in: .personal)
        XCTAssertEqual(root.id, 42)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(fields["name"]).utf8)), "/")
        XCTAssertNil(fields["id"])
        XCTAssertEqual(fields["version"], "2")
    }

    func test根目录无读取权限时不继续请求子目录() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"folder":{"id":42,"name":"/","parent":0,"additional":{"access_permission":{"view":false}}}}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.rootFolder(in: .personal); XCTFail("不能打开无权根目录") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
    }

    func test子文件夹使用父ID分页并拒绝混入其他目录() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(#"{"success":true,"data":{"list":[{"id":43,"name":"/Sample","parent":42}]}}"#),
            response(#"{"success":true,"data":{"list":[{"id":44,"name":"/Other","parent":99}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let folders = try await repository.folders(in: .personal, parentID: 42, offset: 0, limit: 1)
        XCTAssertEqual(folders.first?.name, "Sample")
        do { _ = try await repository.folders(in: .personal, parentID: 42, offset: 1, limit: 1); XCTFail("不能混入其他目录") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test相册列表和相册内容均使用Photos标识() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(#"{"success":true,"data":{"list":[{"id":71,"name":"Sample album","item_count":1}]}}"#), response(itemPage)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let albums = try await repository.albums(offset: 0, limit: 20)
        XCTAssertEqual(albums.first?.id, 71)
        XCTAssertEqual(albums.first?.itemCount, 1)
        let page = try await repository.photos(in: .personal, query: .album(id: 71), offset: 0, limit: 20)
        XCTAssertEqual(page.items.count, 1)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["album_id"], "71")
        XCTAssertNil(fields["folder_id"])
        XCTAssertNil(fields["path"])
    }

    func test详情必须返回被请求照片且保留大图信息() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        let detail = try await repository.details(for: photo)
        XCTAssertEqual(detail.id, photo.id)
        XCTAssertEqual(detail.width, 100)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["method"], "get")
        XCTAssertEqual(fields["version"], "5")
        XCTAssertEqual(fields["id"], "[7]")
    }

    func test视频源使用套件流且不把凭据放到链接() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(videoPage(extension: "mov", qualities: ["high"]))])
        let profileID = UUID()
        let repository = try makeRepository(transport, profileID: profileID)
        _ = try await repository.access()
        let photo = SynologyPhoto(id: SynologyPhotoID(profileID: profileID, space: .personal, unitID: 7),
            filename: "sample.mov", sizeBytes: 42, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "video")
        let source = try await repository.videoSource(for: photo)
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["api"], "SYNO.Foto.Streaming")
        XCTAssertEqual(fields["quality"], #""high""#)
        XCTAssertNil(fields["_sid"])
        XCTAssertNil(fields["SynoToken"])
        XCTAssertNil(source.expectedContentLength)
        XCTAssertEqual(source.request.value(forHTTPHeaderField: "Cookie"), "id=fixture-session")
    }

    func test没有转换版的不同视频格式读取原件且保留实际扩展名() async throws {
        for ext in ["mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "mts"] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(videoPage(extension: ext, qualities: []))])
            let profileID = UUID()
            let repository = try makeRepository(transport, profileID: profileID)
            _ = try await repository.access()
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: .personal, unitID: 7),
                filename: "sample.\(ext)", sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "video")
            let source = try await repository.videoSource(for: photo)
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields["api"], "SYNO.Foto.Download", ext)
            XCTAssertEqual(fields["item_id"], "[7]")
            XCTAssertNil(fields["quality"])
            XCTAssertNil(fields["force_download"])
            XCTAssertNil(fields["SynoToken"])
            XCTAssertNil(fields["_sid"])
            XCTAssertEqual(source.fileExtension, ext)
            XCTAssertEqual(source.request.value(forHTTPHeaderField: "Cookie"), "id=fixture-session")
        }
    }

    func test转换视频仅选择实际存在的质量且不固定高清() async throws {
        for (qualities, expected) in [(["mobile", "medium"], "medium"), (["low"], "low"), (["high", "orig_h264"], "orig_h264")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(videoPage(extension: "avi", qualities: qualities))])
            let profileID = UUID()
            let repository = try makeRepository(transport, profileID: profileID)
            _ = try await repository.access()
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: .personal, unitID: 7),
                filename: "sample.avi", sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "video")
            let source = try await repository.videoSource(for: photo)
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields["api"], "SYNO.Foto.Streaming")
            XCTAssertEqual(fields["quality"], "\"\(expected)\"")
        }
    }

    func test实况没有转换版时只读取视频单元原件() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(itemPage.replacingOccurrences(of: #""type":"photo""#, with: #""type":"live""#)),
            response(#"{"success":true,"data":{"list":[{"id_item":7,"unit":[{"id":701,"live_type":"photo"},{"id":702,"live_type":"video","filename":"sample.MOV","additional":{"video_convert":[]}}]}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let source = try await repository.videoSource(for: XCTUnwrap(page.items.first))
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["api"], "SYNO.Foto.Download")
        XCTAssertEqual(fields["unit_id"], "[702]")
        XCTAssertNil(fields["item_id"])
        XCTAssertEqual(source.fileExtension, "mov")
    }

    private func videoPage(extension ext: String, qualities: [String]) -> String {
        let entries = qualities.map { #"{"quality":""# + $0 + #""}"# }.joined(separator: ",")
        return itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.\(ext)")
            .replacingOccurrences(of: #""type":"photo""#, with: #""type":"video""#)
            .replacingOccurrences(of: #""additional":{"#, with: #""additional":{"video_convert":["# + entries + "],")
    }

    func test原件保存核对字节数且不覆盖已有文件() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("sample.jpg")
        let data = Data(repeating: 0x7f, count: 128)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage),
            DsmHTTPResponse(data: data, statusCode: 200, headers: ["Content-Type":"application/force-download"]),
            DsmHTTPResponse(data: Data([1]), statusCode: 200, headers: ["Content-Type":"application/force-download"]),
            DsmHTTPResponse(data: Data(repeating: 0x55, count: 128), statusCode: 200, headers: ["Content-Type":"application/force-download"])])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        try await repository.downloadOriginal(photo, to: destination, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: destination), data)
        do { try await repository.downloadOriginal(photo, to: destination, progress: { _, _ in }); XCTFail("不能接受截断响应") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        XCTAssertEqual(try Data(contentsOf: destination), data)
        do { try await repository.downloadOriginal(photo, to: destination, progress: { _, _ in }); XCTFail("完整响应也不得覆盖现有文件") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteFileExists) }
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["sample.jpg"])
    }

    func test管理员不绕过共享空间权限() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport)
        let access = try await repository.access()
        XCTAssertEqual(access.spaces, [.personal])
        XCTAssertEqual(access.packageVersion, "1.8.2-10090")
        do {
            _ = try await repository.timeline(in: .shared)
            XCTFail("无共享空间权限时不得请求共享图库")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func test分页使用套件ID拍摄日期和JSON参数() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let profileID = UUID()
        let repository = try makeRepository(transport, profileID: profileID)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .timeline(startTime: 0, endTime: 100), offset: 0, limit: 1)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.id, SynologyPhotoID(profileID: profileID, space: .personal, unitID: 7))
        XCTAssertEqual(item.takenAt, Date(timeIntervalSince1970: 50))
        XCTAssertEqual(item.indexedAt, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(item.thumbnail?.revision, "fixture-revision")
        XCTAssertEqual(item.width, 100)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextOffset, 1)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        let fields = try decode(request)
        XCTAssertEqual(fields["api"], "SYNO.Foto.Browse.Item")
        XCTAssertEqual(fields["version"], "4")
        XCTAssertEqual(fields["start_time"], "0")
        XCTAssertEqual(fields["end_time"], "100")
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-session"))
        XCTAssertNil(fields["path"])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(fields["additional"]!.utf8)),
                       ["thumbnail", "resolution", "orientation", "video_convert", "video_meta", "address"])
    }

    func test空页结束分页而不恢复旧照片() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let first = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 1)
        XCTAssertEqual(first.items.count, 1)
        let refreshed = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 1)
        XCTAssertTrue(refreshed.items.isEmpty)
        XCTAssertFalse(refreshed.hasMore)
        XCTAssertEqual(refreshed.nextOffset, 0)
    }

    func test时间线使用套件分组且字符串JSON编码() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"section":[{"offset":0,"limit":1,"list":[{"year":2020,"month":2,"day":3,"item_count":2}]}]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let days = try await repository.timeline(in: .personal)
        XCTAssertEqual(days, [SynologyPhotoDay(year: 2020, month: 2, day: 3, itemCount: 2)])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decode(XCTUnwrap(requests.last))["timeline_group_unit"], #""day""#)
    }

    func test重新核对权限失败时撤销原授权() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"enabled":false}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.access(); XCTFail("必须拒绝已撤销授权") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { _ = try await repository.timeline(in: .personal); XCTFail("不可沿用旧授权") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
    }

    func test缺少套件接口时不回退文件扫描() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport, missingCapabilities: true)
        do { _ = try await repository.access(); XCTFail("必须提示套件不可用") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test文件夹查询使用数字ID而不是路径() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        _ = try await repository.photos(in: .personal, query: .folder(id: 9), offset: 0, limit: 50)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["folder_id"], "9")
        XCTAssertEqual(fields["sort_by"], #""takentime""#)
        XCTAssertNil(fields["path"])
    }

    func test旧FORM能力声明不用于PhotosJSON接口() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport, format: .form)
        do { _ = try await repository.access(); XCTFail("编码声明不兼容时不可发送") }
        catch let error as AppError { XCTAssertEqual(error.category, .versionUnsupported) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test搜索使用Photos执行而不是本地文件名过滤() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .search(keyword: "sample", startTime: 0, endTime: 100), offset: 0, limit: 50)
        XCTAssertEqual(page.items.count, 1)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["api"], "SYNO.Foto.Search.Search")
        XCTAssertEqual(fields["method"], "list_item")
        XCTAssertEqual(fields["version"], "1")
        XCTAssertEqual(fields["keyword"], #""sample""#)
    }

    func test相册封面先读取当前会话的封面标识再下载() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":71,"name":"Fixture","additional":{"thumbnail":{"unit_id":7,"cache_key":"current-cover"}}}]}}"#
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let transport = MockHTTPTransport(responses: accessResponses() + [response(album), response(album),
            DsmHTTPResponse(data: image, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let albums = try await repository.albums(offset: 0, limit: 20)
        XCTAssertEqual(albums.first?.thumbnail?.unitID, 7)
        let stale = SynologyPhotoCollection(id: 71, name: "Fixture", thumbnail: .init(unitID: 999, revision: "stale"))
        let data = try await repository.thumbnail(for: stale)
        XCTAssertEqual(data, image)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        let parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first { $0.name == "id" }?.value, "7")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "cache_key" }?.value, #""current-cover""#)
        XCTAssertFalse(parts.string?.contains("fixture-session") ?? true)
    }

    func test缩略图认证不进入URL且修订键使用JSON编码() async throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(itemPage), DsmHTTPResponse(data: image, statusCode: 200, headers: ["Content-Type": "image/jpeg"])
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 50)
        let data = try await repository.thumbnail(for: XCTUnwrap(page.items.first))
        XCTAssertEqual(data, image)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/synofoto/api/v2/p/Thumbnail/get")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["cache_key"], #""fixture-revision""#)
        XCTAssertEqual(query["size"], #""m""#)
        XCTAssertNil(query["SynoToken"])
        XCTAssertNil(query["_sid"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "fixture-token")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func test缩略图拒绝跨账号项目且不发送请求() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let foreign = SynologyPhoto(
            id: SynologyPhotoID(profileID: UUID(), space: .personal, unitID: 7),
            filename: "sample.jpg", sizeBytes: 1, takenAt: .distantPast, indexedAt: .distantPast,
            folderID: 9, mediaType: "photo", thumbnail: SynologyPhotoThumbnail(unitID: 7, revision: "fixture")
        )
        do { _ = try await repository.thumbnail(for: foreign); XCTFail("不能使用本账号会话加载其他账号项目") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func test缩略图不把登录HTML当图片() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response(itemPage), DsmHTTPResponse(data: Data("<html></html>".utf8), statusCode: 200, headers: ["Content-Type": "text/html"])
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 50)
        do { _ = try await repository.thumbnail(for: XCTUnwrap(page.items.first)); XCTFail("必须拒绝非图片响应") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test管理功能随实际接口开放而无需额外白名单() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport)
        let beforeAccess = await repository.managementFeatures()
        XCTAssertTrue(beforeAccess.isEmpty, "没有空间访问权时不能显示可写能力")
        _ = try await repository.access()
        let features = await repository.managementFeatures()
        XCTAssertEqual(features, Set(SynologyPhotosManagementFeature.allCases))
        try await repository.prepareMutation(.createAlbum(name: "Fixture", photos: []))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4, "开放能力和创建预检不能提前发送创建请求")
    }

    func test缺少上传接口不影响其他照片管理功能() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport, omittedAPIs: ["SYNO.Foto.Upload.Item"])
        _ = try await repository.access()
        let features = await repository.managementFeatures()
        XCTAssertEqual(features, Set(SynologyPhotosManagementFeature.allCases).subtracting([.upload]))
    }

    func test评级回读一致才确认且同操作不重发() async throws {
        let updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""rating":4,"orientation":1"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(emptySuccess), response(updated)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.edit(page.items, .rating(4)), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.photos.first?.rating, 4)
        let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(repeated, result)
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["rating"], "4")
        XCTAssertEqual(writes.first?["id"], "[7]")
    }

    func test管理断网只核对不重放且阻止第二次新操作() async throws {
        let updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""rating":2,"orientation":1"#)
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(updated))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.edit(page.items, .rating(2)), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("未知结果不能再发写入") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let reviewed = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
    }

    func test新标签按返回编号核对并应用且重复调用不重建() async throws {
        let tagged = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[{"id":8,"name":"Fixture tag"}]"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"tag":{"id":8,"name":"Fixture tag"}}}"#), response(emptySuccess),
            response(#"{"success":true,"data":{"list":[{"id":8,"name":"Fixture tag"}]}}"#), response(tagged)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.createTag(name: "Fixture tag", photos: page.items), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.tag?.id, 8)
        XCTAssertEqual(result.photos.first?.tags?.first?.id, 8)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        XCTAssertEqual(requests.first { $0["method"] == "add_tag" }?["tag"], "[8]")
    }

    func test新标签已创建但应用被拒绝返回可保留标签的部分结果() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"tag":{"id":8,"name":"Fixture tag"}}}"#),
            response(#"{"success":false,"error":{"code":105}}"#),
            response(#"{"success":true,"data":{"list":[{"id":8,"name":"Fixture tag"}]}}"#), response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.createTag(name: "Fixture tag", photos: page.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial)
        XCTAssertEqual(result.tag?.name, "Fixture tag")
        XCTAssertTrue(result.photos.isEmpty)
    }

    func test新标签创建回执丢失不能按名称猜测或重发() async throws {
        let transport = MockHTTPTransport(steps: accessResponses().map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.createTag(name: "Fixture tag", photos: [])
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        let again = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        XCTAssertEqual(again.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "list" })
    }

    func test缺少新标签接口不影响已有标签修改() async throws {
        let repository = try makeRepository(MockHTTPTransport(responses: accessResponses()), omittedAPIs: ["SYNO.Foto.Browse.GeneralTag"])
        _ = try await repository.access()
        let features = await repository.managementFeatures()
        XCTAssertTrue(features.contains(.tags))
        XCTAssertFalse(features.contains(.tagCreation))
    }

    func test相对日期逐项设置绝对目标且保留间隔() async throws {
        let second = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#).replacingOccurrences(of: #""time":50"#, with: #""time":110"#)
        let updatedFirst = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":40"#)
        let updatedSecond = second.replacingOccurrences(of: #""time":110"#, with: #""time":100"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(second), response(itemPage), response(managedFolder),
            response(second), response(managedFolder), response(emptySuccess), response(emptySuccess), response(updatedFirst), response(updatedSecond)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let firstPage = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let secondPage = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 1, limit: 20)
        let command = SynologyPhotosMutation.shiftDates(firstPage.items + secondPage.items, seconds: -10), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.photos.map { Int($0.takenAt.timeIntervalSince1970) }, [40, 100])
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.map { $0["time"] }, ["40", "100"])
        XCTAssertEqual(writes.map { $0["id"] }, ["[7]", "[8]"])
    }

    func test相对日期第二项被拒绝保留第一项结果() async throws {
        let second = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#).replacingOccurrences(of: #""time":50"#, with: #""time":110"#)
        let updated = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":60"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(second), response(itemPage), response(managedFolder),
            response(second), response(managedFolder), response(emptySuccess), response(#"{"success":false,"error":{"code":105}}"#), response(updated), response(second)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let first = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let secondPage = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 1, limit: 20)
        let result = try await repository.performMutation(.shiftDates(first.items + secondPage.items, seconds: 10), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial)
        XCTAssertEqual(result.photos.map(\.id.unitID), [7])
        XCTAssertEqual(result.completedCount, 1)
    }

    func test相对日期回执丢失只回读不累加偏移() async throws {
        let updated = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":60"#)
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)]).map(MockHTTPTransport.Step.response)
            + [.urlError(.networkConnectionLost), .response(response(itemPage)), .response(response(updated))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.shiftDates(page.items, seconds: 10), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["time"], "60")
    }

    func test相对日期越界在发送修改前拒绝() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        for delta in [-100, Int.max, 0] {
            do { try await repository.prepareMutation(.shiftDates(page.items, seconds: delta)); XCTFail("不能接受越界或空调整") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set" })
    }

    func test标签字段缺失不能证明移除成功() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(emptySuccess), response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.removeTags(page.items, ids: [8]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
    }

    func test相册非所有者不得重命名() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":99}]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.performMutation(.renameAlbum(id: 3, name: "Changed"), operationID: UUID()) { _, _ in }; XCTFail("非所有者不得修改") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set_name" })
    }

    func test创建相册用返回编号核对名称和成员() async throws {
        let album = #"{"id":3,"name":"Fixture","owner_user_id":12}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [
            response("{\"success\":true,\"data\":{\"album\":\(album)}}"),
            response("{\"success\":true,\"data\":{\"list\":[\(album)]}}"), response(#"{"success":true,"data":{"list":[]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.createAlbum(name: "Fixture", photos: []), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.album?.id, 3)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
    }

    func test相册封面核对成员并按照片编号回读且不重复设置() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture-cover"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage),
            response(managedFolder), response(album), response(itemPage), response(emptySuccess), response(album)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        let command = SynologyPhotosMutation.setAlbumCover(id: 3, photo: photo), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set_cover" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["id_item"], "7")
    }

    func test不属于相册的照片不得设为封面() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage),
            response(managedFolder), response(album), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        do { _ = try await repository.performMutation(.setAlbumCover(id: 3, photo: photo), operationID: UUID()) { _, _ in }; XCTFail("非成员不能设置封面") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set_cover" })
    }

    func test复制跳过同名文件报告部分完成而不是成功() async throws {
        let target = managedFolder.replacingOccurrences(of: #""id":9"#, with: #""id":10"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(target),
            response(#"{"success":true,"data":{"task_info":{"id":2}}}"#),
            response(#"{"success":true,"data":{"list":[{"id":2,"status":"done","completion":0,"error":0,"skip":1,"overwrite":0}]}}"#)
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.copy(page.items, folderID: 10), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.first { $0["method"] == "copy" }?["action"], #""skip""#)
    }

    func test上传使用多段文件体和返回编号核对不把凭据放入链接() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(#"{"success":true,"data":{"id":7,"action":"rename"}}"#), response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.upload(file: source, size: 128, modifiedAt: modified, folderID: 9), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.photos.first?.id.unitID, 7)
        let bodies = await transport.recordedUploadBodies()
        let body = try XCTUnwrap(bodies.first).map { $0 < 128 ? $0 : 32 }
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("upload_to_folder"))
        XCTAssertTrue(text.contains("\"rename\""))
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.allSatisfy { !($0.url?.absoluteString.contains("fixture-session") ?? true) })
        XCTAssertTrue(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true && $0.value(forHTTPHeaderField: "X-SYNO-TOKEN") == "fixture-token" })
    }

    func test明确权限拒绝结束本次修改但同操作不再发送() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.edit(page.items, .rating(3)), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .rejected)
        let retry = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(retry.state, .rejected)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
    }

    func test分享先关闭再配置最后启用并回读权限() async throws {
        let before = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"shared":false}]}}"#
        let after = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"shared":true,"additional":{"sharing_info":{"privacy_type":"public-download","sharing_link":"https://example.invalid/share/fixture"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .download), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.sharingURL?.host, "example.invalid")
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["api"] == "SYNO.Foto.Sharing.Passphrase" }
        XCTAssertEqual(writes.map { $0["method"] }, ["set_shared", "update", "set_shared"])
        XCTAssertEqual(writes.first?["enabled"], "false")
        XCTAssertEqual(writes.last?["enabled"], "true")
        XCTAssertFalse(writes.contains { $0["password"] != nil || $0["expiration"] != nil })
    }

    func test读取分享方式与保护状态只发送查询() async throws {
        for (privacy, expected) in [("private", SynologyPhotoLinkAccess.invited), ("public-view", .view), ("public-download", .download)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(sharingFixture(privacy: privacy))])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let state = try await repository.albumSharing(id: 3)
            XCTAssertEqual(state.access, expected)
            XCTAssertEqual(state.hasPassword, true)
            XCTAssertEqual(state.hasExpiration, true)
            XCTAssertEqual(state.url?.host, "example.invalid")
            XCTAssertEqual(state.revision.count, 64)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
        }
    }

    func test读取关闭分享不暴露旧链接且未知保护状态不猜测() async throws {
        let data = sharingFixture(shared: false).replacingOccurrences(of: #""enable_password":true,"expiration":100"#, with: #""expiration":"unknown""#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(data)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let state = try await repository.albumSharing(id: 3)
        XCTAssertEqual(state.access, .disabled)
        XCTAssertNil(state.url)
        XCTAssertNil(state.hasPassword)
        XCTAssertNil(state.hasExpiration)
    }

    func test分享未改变不写入且原快照过期不覆盖() async throws {
        for changed in [false, true] {
            let initial = sharingFixture()
            let latest = changed ? initial.replacingOccurrences(of: #""expiration":100"#, with: #""expiration":200"#) : initial
            let transport = MockHTTPTransport(responses: accessResponses() + [response(initial), response(latest), response(latest)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do {
                let result = try await repository.performMutation(.shareAlbum(id: 3, access: .download, original: original), operationID: UUID()) { _, _ in }
                XCTAssertFalse(changed)
                XCTAssertEqual(result.state, .confirmed)
            } catch let error as AppError { XCTAssertTrue(changed); XCTAssertEqual(error.category, .conflict) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
        }
    }

    func test分享预读失败不会留下已提交操作() async throws {
        let initial = sharingFixture()
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(initial)]).map(MockHTTPTransport.Step.response) +
            [.urlError(.networkConnectionLost), .response(response(initial)), .response(response(initial))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let id = UUID()
        do { _ = try await repository.performMutation(.shareAlbum(id: 3, access: .download), operationID: id) { _, _ in }; XCTFail("读取失败不能报告保存成功") } catch {}
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .download), operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test仅受邀者与公开查看只修改公共成员且保留保护设置() async throws {
        for access in [SynologyPhotoLinkAccess.invited, .view] {
            let before = sharingFixture()
            let after = sharingFixture(privacy: access == .invited ? "private" : "public-view")
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before),
                response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let result = try await repository.performMutation(.shareAlbum(id: 3, access: access), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            let requests = try await transport.recordedRequests().map(decode)
            let update = try XCTUnwrap(requests.first { $0["method"] == "update" })
            let changes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(update["permission"]).utf8)) as? [[String: Any]])
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes.first?["action"] as? String, access == .invited ? "delete" : "update")
            XCTAssertEqual(changes.first?["member"] as? [String: String], ["type": "public"])
            XCTAssertEqual(changes.first?["role"] as? String, access == .invited ? nil : "view")
            XCTAssertNil(update["password"]); XCTAssertNil(update["expiration"])
        }
    }

    func test分享回读保护设置变化不能报告全部成功() async throws {
        let before = sharingFixture()
        let after = sharingFixture(privacy: "public-view").replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":false"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before),
            response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .view), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
    }

    func test未知公开权限不猜测为受支持的分享方式() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(sharingFixture(privacy: "public-upload"))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.albumSharing(id: 3); XCTFail("未知权限不能误显示为关闭或允许访问") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test分享成员按类型区分编号并排除当前系统用户() async throws {
        var initial = accessResponses()
        initial[0] = response(#"{"success":true,"data":{"enabled":true,"id":12,"uid":99}}"#)
        let transport = MockHTTPTransport(responses: initial + [response(memberAlbum()), response(#"{"success":true,"data":{"list":[{"id":99,"type":"user","name":"Self"},{"id":22,"type":"user","name":"Member"},{"id":22,"type":"group","name":"Group"}]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let snapshot = try await repository.albumSharing(id: 3)
        XCTAssertEqual(snapshot.members?.count, 2)
        XCTAssertEqual(Set(snapshot.members?.map(\.id) ?? []).count, 2)
        let recipients = try await repository.sharingRecipients()
        XCTAssertEqual(recipients.count, 2)
        XCTAssertEqual(recipients.map(\.id.type), ["user", "group"])
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.last?["method"], "list_user_group")
        XCTAssertEqual(requests.last?["team_space_sharable_list"], "false")
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test分享成员新增移除改角色只发送差量并保留编号类型() async throws {
        let after = memberAlbum(permission: #"[{"id":22,"type":"user","name":"Renamed member","role":"download"},{"id":"domain-23","type":"user","name":"New member","role":"upload"}]"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAlbum()), response(memberAlbum()), response(memberAlbum()),
            response(#"{"success":true,"data":{"list":[{"id":"domain-23","type":"user","name":"New member"}]}}"#),
            response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        var desired = [try XCTUnwrap(original.members?.first)]
        desired[0].role = "download"
        desired.append(.init(recipient: .init(id: .init(type: "user", value: .string("domain-23")), name: "New member"), role: "upload"))
        let id = UUID(), command = SynologyPhotosMutation.shareAlbum(id: 3, access: .invited, original: original, members: desired)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
        }
        let requests = try await transport.recordedRequests().map(decode)
        let updates = requests.filter { $0["method"] == "update" }
        XCTAssertEqual(updates.count, 1)
        let delta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(updates.first?["permission"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(delta.count, 3)
        XCTAssertEqual(delta[0]["action"] as? String, "delete")
        XCTAssertEqual((delta[0]["member"] as? [String: Any])?["type"] as? String, "group")
        XCTAssertEqual(delta[1]["role"] as? String, "download")
        XCTAssertEqual((delta[2]["member"] as? [String: Any])?["id"] as? String, "domain-23")
        XCTAssertFalse(delta.contains { ($0["member"] as? [String: Any])?["type"] as? String == "public" })
        XCTAssertNil(updates.first?["password"]); XCTAssertNil(updates.first?["expiration"])
    }

    func test成员名单与角色没有改变不重复写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(memberAlbum()), count: 3))
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .invited, original: original, members: original.members?.reversed()), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test未知成员结构保持未知不能误当空名单清除() async throws {
        let album = memberAlbum(permission: #"[{"type":"unknown","id":77,"name":"Untouched","role":"view"}]"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(album), response(album)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        XCTAssertNil(original.members)
        do { _ = try await repository.performMutation(.shareAlbum(id: 3, access: .invited, original: original, members: []), operationID: UUID()) { _, _ in }; XCTFail("未知列表不能作为空列表写入") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test成员新增目标消失不提交分享修改() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(memberAlbum()), count: 3) + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        var desired = try XCTUnwrap(original.members)
        desired.append(.init(recipient: .init(id: .init(type: "user", value: .integer(55)), name: "Missing"), role: "view"))
        do { _ = try await repository.performMutation(.shareAlbum(id: 3, access: .invited, original: original, members: desired), operationID: UUID()) { _, _ in }; XCTFail("目标不可再选择时不扩大权限") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test成员回读角色不符保持待核对且不重发() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(memberAlbum()), count: 3) +
            [response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(memberAlbum()), response(memberAlbum())])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        var desired = try XCTUnwrap(original.members); desired[0].role = "download"
        let id = UUID(), command = SynologyPhotosMutation.shareAlbum(id: 3, access: .invited, original: original, members: desired)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
        let updates = try await transport.recordedRequests().map(decode).filter { $0["method"] == "update" }
        XCTAssertEqual(updates.count, 1)
    }

    func test条件相册成员不能提升到上传且重复身份不提交() async throws {
        for duplicate in [false, true] {
            let album = memberAlbum().replacingOccurrences(of: #""type":"normal""#, with: #""type":"condition""#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(album), response(album)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            var desired = try XCTUnwrap(original.members)
            if duplicate { desired.append(desired[0]) } else { desired[0].role = "upload" }
            do { try await repository.prepareMutation(.shareAlbum(id: 3, access: .invited, original: original, members: desired)); XCTFail("不支持的角色或重复身份不能提交") }
            catch let error as AppError { XCTAssertEqual(error.category, duplicate ? .invalidResponse : .permissionDenied) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
        }
    }

    func test关闭分享时修改成员不会意外重新启用() async throws {
        let before = memberAlbum().replacingOccurrences(of: #""shared":true"#, with: #""shared":false"#)
        let after = memberAlbum(permission: "[]").replacingOccurrences(of: #""shared":true"#, with: #""shared":false"#)
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(before), count: 3) +
            [response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .disabled, original: original, members: []), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set_shared" && $0["enabled"] == "true" })
    }

    func test只关闭分享回读不要求已隐藏的成员字段() async throws {
        let after = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"shared":false}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAlbum()), response(memberAlbum()), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .disabled), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
    }

    func test未修改的未知成员角色保留不发送降级() async throws {
        let before = memberAlbum().replacingOccurrences(of: #""role":"download""#, with: #""role":"future-role""#)
        let after = before.replacingOccurrences(of: #""role":"view""#, with: #""role":"download""#)
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(before), count: 3) +
            [response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        var desired = try XCTUnwrap(original.members); desired[0].role = "download"
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .invited, original: original, members: desired), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let update = try await transport.recordedRequests().map(decode).first { $0["method"] == "update" }
        let delta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(update?["permission"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual((delta[0]["member"] as? [String: Any])?["type"] as? String, "user")
    }

    func test人物改名校验原名称并回读且不重复写入() async throws {
        let original = SynologyPhotoCollection(id: 31, name: "Before", itemCount: 1)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Before", 1)])),
            response(#"{"success":true,"data":{"id":31,"name":"After"}}"#), response(personList([(31, "After", 1)]))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.renamePerson(original, name: "After")
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            XCTAssertEqual(result.person?.name, "After")
        }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Browse.Person")
        XCTAssertEqual(writes.first?["version"], "1")
        XCTAssertEqual(writes.first?["id"], "31")
    }

    func test人物清空姓名少照片隐藏须同时有确认回执() async throws {
        for receiptMissing in [false, true] {
            let initial = (accessResponses() + [response(personList([(31, "Before", 1)]))]).map(MockHTTPTransport.Step.response)
            let write: MockHTTPTransport.Step = receiptMissing ? .urlError(.networkConnectionLost) : .response(response(#"{"success":true,"data":{"id":31,"name":""}}"#))
            let transport = MockHTTPTransport(steps: initial + [write, .response(response(personList([]))), .response(response(personList([])))])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let id = UUID()
            let first = try await repository.performMutation(.renamePerson(.init(id: 31, name: "Before", itemCount: 1), name: ""), operationID: id) { _, _ in }
            if receiptMissing {
                XCTAssertEqual(first.state, .pendingReview)
                let reviewed = try await repository.reviewMutation(operationID: id)
                XCTAssertEqual(reviewed.state, .pendingReview)
            } else {
                XCTAssertEqual(first.state, .confirmed)
                XCTAssertEqual(first.removedPersonIDs, [31])
            }
            let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
            XCTAssertEqual(writes.count, 1)
        }
    }

    func test人物被别处改名时拒绝覆盖() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Other", 1)]))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { try await repository.prepareMutation(.renamePerson(.init(id: 31, name: "Before", itemCount: 1), name: "After")); XCTFail("原姓名改变不能覆盖") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set" })
    }

    func test人物合并核对照片并集而非简单相加且不重放() async throws {
        for matches in [true, false] {
            let before = personList([(31, "Target", 1), (32, "Source", 1)])
            let after = personList([(31, "Combined", 1)])
            let wrongPage = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before),
                response(personTimeline), response(itemPage), response(managedFolder),
                response(personTimeline), response(itemPage), response(before), response(emptySuccess),
                response(after), response(personTimeline), response(matches ? itemPage : wrongPage),
                response(after), response(personTimeline), response(matches ? itemPage : wrongPage)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let id = UUID(), command = SynologyPhotosMutation.mergePeople(target: .init(id: 31, name: "Target", itemCount: 1), sources: [.init(id: 32, name: "Source", itemCount: 1)], name: "Combined")
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, matches ? .confirmed : .pendingReview)
                if matches { XCTAssertEqual(result.removedPersonIDs, [32]); XCTAssertEqual(result.person?.id, 31) }
            }
            let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "merge" }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?["version"], "2")
            XCTAssertEqual(writes.first?["target_id"], "31")
            XCTAssertEqual(writes.first?["merged_id"], "[32]")
        }
    }

    func test人物合并来源未消失不能报告完成() async throws {
        let before = personList([(31, "Target", 1), (32, "Source", 1)])
        let transport = MockHTTPTransport(responses: accessResponses() + [response(before),
            response(personTimeline), response(itemPage), response(managedFolder), response(personTimeline), response(itemPage),
            response(before), response(emptySuccess), response(personList([(31, "Combined", 1), (32, "Source", 1)]))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.mergePeople(target: .init(id: 31, name: "Target", itemCount: 1), sources: [.init(id: 32, name: "Source", itemCount: 1)], name: "Combined"), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
    }

    func test人物合并预读照片不完整或目录无权时不写入() async throws {
        for denied in [true, false] {
            let before = personList([(31, "Target", denied ? 1 : 2), (32, "Source", 1)])
            let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(personTimeline), response(itemPage), response(folder)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.mergePeople(target: .init(id: 31, name: "Target", itemCount: denied ? 1 : 2), sources: [.init(id: 32, name: "Source", itemCount: 1)], name: "Combined"), operationID: UUID()) { _, _ in }; XCTFail("不能合并不完整或无权操作的照片") }
            catch let error as AppError { XCTAssertEqual(error.category, denied ? .permissionDenied : .conflict) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "merge" })
        }
    }

    func test人物合并拒绝重复身份并独立提供命名能力() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let person = SynologyPhotoCollection(id: 31, name: "Target")
        do { try await repository.prepareMutation(.mergePeople(target: person, sources: [person], name: "Target")); XCTFail("不能合并自身") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let noPerson = try makeRepository(MockHTTPTransport(responses: accessResponses()), omittedAPIs: ["SYNO.Foto.Browse.Person"])
        _ = try await noPerson.access()
        let features = await noPerson.managementFeatures()
        XCTAssertFalse(features.contains(.peopleNames)); XCTAssertFalse(features.contains(.peopleMerge))
        XCTAssertTrue(features.contains(.albums))
        let older = try makeRepository(MockHTTPTransport(responses: accessResponses()), personVersion: 1)
        _ = try await older.access()
        let olderFeatures = await older.managementFeatures()
        XCTAssertTrue(olderFeatures.contains(.peopleNames)); XCTAssertFalse(olderFeatures.contains(.peopleMerge))
    }

    func test人物封面使用当前分类返回的缩略图而不按相册编号查询() async throws {
        let list = #"{"success":true,"data":{"list":[{"id":31,"name":"Person","item_count":1,"additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture-person"}}}]}}"#
        let data = Data([0xff, 0xd8, 0xff, 0xd9])
        let transport = MockHTTPTransport(responses: accessResponses() + [response(list), DsmHTTPResponse(data: data, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let people = try await repository.managementPeople()
        let image = try await repository.thumbnail(for: try XCTUnwrap(people.first), category: .person)
        XCTAssertEqual(image, data)
        let requests = await transport.recordedRequests()
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "7")
        let posts = try requests.filter { $0.httpMethod == "POST" }.map(decode)
        XCTAssertFalse(posts.contains { $0["api"] == "SYNO.Foto.Browse.Album" })
    }

    func test分类封面不能跨分类或沿用重新授权前的标识() async throws {
        let list = #"{"success":true,"data":{"list":[{"id":31,"name":"Person","additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture-person"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(list)] + accessResponses())
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let people = try await repository.managementPeople()
        let person = try XCTUnwrap(people.first)
        do { _ = try await repository.thumbnail(for: person, category: .tags); XCTFail("同编号的其他分类不能复用封面") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        _ = try await repository.access()
        do { _ = try await repository.thumbnail(for: person, category: .person); XCTFail("重新核对后须重新读取分类") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
    }

    private func personList(_ people: [(Int, String, Int)]) -> String {
        let rows = people.map { ["id": $0.0, "name": $0.1, "item_count": $0.2] as [String: Any] }
        return String(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": rows]]), encoding: .utf8)!
    }
    private let personTimeline = #"{"success":true,"data":{"section":[{"offset":0,"limit":1,"list":[{"year":1970,"month":1,"day":1,"item_count":1}]}]}}"#

    private func memberAlbum(permission: String = #"[{"id":22,"type":"user","name":"Member","role":"view"},{"id":22,"type":"group","name":"Group","role":"download"}]"#) -> String {
        sharingFixture(privacy: "private").replacingOccurrences(of: #""permission":[]"#, with: #""permission":\#(permission)"#)
    }

    private func sharingFixture(privacy: String = "public-download", shared: Bool = true) -> String {
        #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","type":"normal","owner_user_id":12,"shared":\#(shared),"additional":{"sharing_info":{"privacy_type":"\#(privacy)","sharing_link":"https://example.invalid/share/fixture","enable_password":true,"expiration":100,"permission":[]}}}]}}"#
    }

    func test分享中途失败不自动开启且回读关闭后报告部分完成() async throws {
        let before = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"shared":false}]}}"#
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(before))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let id = UUID()
        let first = try await repository.performMutation(.shareAlbum(id: 3, access: .view), operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let reviewed = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .partial)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "set_shared" && $0["enabled"] == "true" })
    }

    func test创建目录核对编号父目录名称和权限且不重复提交() async throws {
        let verified = #"{"success":true,"data":{"folder":{"id":10,"name":"/Sample/Trip","parent":9,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder),
            response(#"{"success":true,"data":{"folder":{"id":10}}}"#), response(verified)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.createFolder(parentID: 9, name: "Trip")
        let id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            XCTAssertEqual(result.folder, .init(id: 10, name: "Trip", parentID: 9))
        }
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["method"] == "create" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Browse.Folder")
        XCTAssertEqual(writes.first?["version"], "1")
        XCTAssertEqual(writes.first?["target_id"], "9")
        XCTAssertEqual(writes.first?["name"], #""Trip""#)
    }

    func test创建目录回读不匹配不能确认() async throws {
        for mismatch in [#""id":11,"name":"/Sample/Trip","parent":9"#,
                         #""id":10,"name":"/Other/Trip","parent":88"#,
                         #""id":10,"name":"/Sample/Other","parent":9"#] {
            let value = "{\"success\":true,\"data\":{\"folder\":{\(mismatch),\"additional\":{\"access_permission\":{\"view\":true,\"manage\":true}}}}}"
            let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder),
                response(#"{"success":true,"data":{"folder":{"id":10}}}"#), response(value)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let result = try await repository.performMutation(.createFolder(parentID: 9, name: "Trip"), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            XCTAssertNil(result.folder)
        }
    }

    func test目录创建丢失回执不按名称猜测和重建() async throws {
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(managedFolder)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let id = UUID()
        let command = SynologyPhotosMutation.createFolder(parentID: 9, name: "Trip")
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        let second = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        XCTAssertEqual(second.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "list" })
    }

    func test目录创建拒绝路径名称及无权父目录() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false"#))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        for name in ["", ".", "..", "a/b", "bad\0name", "Valid"] {
            do { try await repository.prepareMutation(.createFolder(parentID: 9, name: name)); XCTFail("不能写入") }
            catch { }
        }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "create" })
    }

    private let conditionAlbum = #"{"success":true,"data":{"list":[{"id":21,"name":"Fixture rule album","type":"condition","owner_user_id":12,"item_count":2}]}}"#
    private func conditionReply(_ fields: String) -> DsmHTTPResponse {
        response("{\"success\":true,\"data\":{\"list\":[{\"id\":21,\"additional\":{\"condition_object\":\(fields)}}]}}")
    }

    func test创建条件相册使用独立类型编码且回读全部规则后确认() async throws {
        let raw = #"{"user_id":12,"item_type":[-1],"rating":[{"id":5,"name":"Five"},{"id":3,"name":"Three"}],"keyword":["Trip"],"keyword_policy":"and","time":[{"start_time":50,"end_time":100}],"folder_filter":[{"id":9,"name":"Fixture folder"}]}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(#"{"success":true,"data":{"album":{"id":21}}}"#), response(conditionAlbum), response(conditionAlbum), conditionReply(raw)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let condition = SynologyPhotoAlbumCondition(fields: ["item_type": .array([.integer(-1)]), "rating": .array([.integer(3), .integer(5)]),
            "keyword": .array([.string("Trip")]), "keyword_policy": .string("and"), "folder_filter": .array([.integer(9)]),
            "time": .array([.object(["start_time": .integer(50), "end_time": .integer(100)])])])
        let id = UUID(), command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture rule album", condition: condition)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.album?.isConditional, true)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "create" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Browse.ConditionAlbum")
        XCTAssertEqual(writes.first?["version"], "3")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(writes.first?["condition"]).utf8)) as? [String: Any])
        XCTAssertEqual(object["item_type"] as? [Int], [-1])
        XCTAssertEqual(object["user_id"] as? Int, 12)
    }

    func test条件回读保留缺名引用和未知字段编辑时不丢失() async throws {
        let raw = #"{"user_id":12,"item_type":[],"person":[{"id":77}],"person_policy":"or","future_rule":{"weight":0.5,"optional":null},"future_empty":[],"future_order":[2,1],"general_tag":[{"id":8,"name":"Fixture tag"}],"general_tag_policy":"or"}"#
        let updated = raw.replacingOccurrences(of: #""item_type":[]"#, with: #""item_type":[-2]"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(conditionAlbum), conditionReply(raw),
            response(conditionAlbum), conditionReply(raw), response(emptySuccess), response(conditionAlbum), conditionReply(updated), response(conditionAlbum)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        var condition = try await repository.albumCondition(id: 21)
        let original = condition
        XCTAssertEqual(condition.values("person"), [.integer(77)])
        XCTAssertFalse(condition.names["person"]?.first?.name.isEmpty ?? true)
        condition.setValues([.integer(-2)], for: "item_type")
        let command = SynologyPhotosMutation.setAlbumCondition(id: 21, original: original, condition: condition)
        let result = try await repository.performMutation(command, operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set_condition" }
        XCTAssertEqual(writes.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(writes.first?["condition"]).utf8)) as? [String: Any])
        XCTAssertEqual(object["person"] as? [Int], [77])
        XCTAssertEqual((object["future_rule"] as? [String: Any])?["weight"] as? Double, 0.5)
        XCTAssertTrue((object["future_rule"] as? [String: Any])?["optional"] is NSNull)
        XCTAssertEqual(object["future_empty"] as? [Int], [])
        XCTAssertEqual(object["future_order"] as? [Int], [2, 1])
    }

    func test条件编辑拒绝过期快照且不覆盖其他端修改() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(conditionAlbum), conditionReply(#"{"user_id":12,"item_type":[-2]}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { try await repository.prepareMutation(.setAlbumCondition(id: 21, original: .init(), condition: .init())); XCTFail("过期快照不能写入") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set_condition" }; XCTAssertEqual(writes.count, 0)
    }

    func test普通与条件相册能力独立不相互禁用() async throws {
        for (missing, present, absent) in [("SYNO.Foto.Browse.NormalAlbum", SynologyPhotosManagementFeature.conditionAlbums, SynologyPhotosManagementFeature.albums),
                                           ("SYNO.Foto.Browse.ConditionAlbum", SynologyPhotosManagementFeature.albums, SynologyPhotosManagementFeature.conditionAlbums)] {
            let repository = try makeRepository(MockHTTPTransport(responses: accessResponses()), omittedAPIs: [missing])
            _ = try await repository.access()
            let features = await repository.managementFeatures()
            XCTAssertTrue(features.contains(present))
            XCTAssertFalse(features.contains(absent))
        }
    }

    func test条件相册创建回执丢失不按名称重建() async throws {
        let transport = MockHTTPTransport(steps: accessResponses().map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture", condition: .init()), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "create" }; XCTAssertEqual(writes.count, 1)
    }

    func test条件相册权限日期和策略校验阻止错误写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(conditionAlbum.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":99"#))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        for fields: [String: SynologyPhotoConditionValue] in [
            ["user_id": .integer(0)], ["rating": .array([.integer(6)])],
            ["keyword": .array([.string("Fixture")])],
            ["time": .array([.object(["start_time": .integer(100), "end_time": .integer(50)])])]
        ] {
            do { try await repository.prepareMutation(.createConditionAlbum(name: "Fixture", condition: .init(fields: fields))); XCTFail("不能接受无效规则") } catch {}
        }
        do { _ = try await repository.albumCondition(id: 21); XCTFail("不能编辑他人相册") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let writes = try await transport.recordedRequests().map(decode).filter { ["create", "set_condition"].contains($0["method"] ?? "") }; XCTAssertEqual(writes.count, 0)
    }

    func test条件建议解码范围地点且预览数量为只读() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"general_tag":[{"id":8,"name":"Fixture","additional":{"thumbnail":null}}],"focal_length_group":[{"start":18,"end":55}],"exposure_time_group":[{"start":{"num":1,"den":100},"end":{"num":1,"den":10}}],"geocoding":[{"id":1,"name":"Fixture region","children":[{"id":2,"name":"Fixture city","children":[]}]}]}}"#), response(#"{"success":true,"data":{"count":3}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let suggestions = try await repository.conditionSuggestions(keyword: "Fixture")
        XCTAssertEqual(suggestions["general_tag"]?.first?.value, .integer(8))
        XCTAssertEqual(suggestions["focal_length_group"]?.first?.value, .object(["start": .integer(18), "end": .integer(55)]))
        XCTAssertEqual(suggestions["geocoding"]?.first?.name, "Fixture region, Fixture city")
        let count = try await repository.conditionItemCount(.init())
        XCTAssertEqual(count, 3)
        let methods = try await transport.recordedRequests().map(decode).suffix(2).map { $0["method"] }
        XCTAssertEqual(methods, ["suggest", "peek_item_count"])
    }

    private let managedFolder = #"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#
    private let emptySuccess = #"{"success":true,"data":{}}"#

    private let itemPage = #"{"success":true,"data":{"list":[{"id":7,"filename":"sample.jpg","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"photo","additional":{"resolution":{"width":100,"height":80},"orientation":1,"thumbnail":{"unit_id":7,"cache_key":"fixture-revision"}}}]}}"#

    private func accessResponses() -> [DsmHTTPResponse] {
        [
            response(#"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12}}"#),
            response(#"{"success":true,"data":{"enable_home_service":true,"team_space_permission":"none"}}"#),
            response(#"{"success":true,"data":{"package_version":"1.8.2-10090"}}"#),
            response(#"{"success":true,"data":{"enabled":true}}"#)
        ]
    }

    private func response(_ body: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }

    private func decode(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let components = try XCTUnwrap(URLComponents(string: "?" + body))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func makeRepository(
        _ transport: MockHTTPTransport, profileID: UUID = UUID(),
        missingCapabilities: Bool = false, format: DsmRequestFormat = .json,
        deletionEnabled: Bool = false,
        omittedAPIs: Set<String> = [], personVersion: Int = 2
    ) throws -> SynologyPhotosRepository {
        let names = ["UserInfo": 1, "Setting.User": 1, "Setting.Admin": 1, "Setting.TeamSpace": 1,
                     "Browse.Timeline": 5, "Browse.Item": 6, "Browse.RecentlyAdded": 1, "Search.Search": 6,
                     "Browse.Folder": 2, "Browse.Album": 5, "Streaming": 2, "Download": 2,
                     "Browse.Category": 3, "Search.Filter": 3, "Sharing.Misc": 2, "PhotoRequest": 1,
                     "Browse.NormalAlbum": 2, "Browse.ConditionAlbum": 3, "BackgroundTask.Info": 1, "Upload.Item": 1, "Sharing.Passphrase": 1,
                     "Browse.Person": personVersion, "Browse.Concept": 2, "Browse.Geocoding": 1, "Browse.GeneralTag": 1, "Browse.Unit": 1]
        var entries = Dictionary(uniqueKeysWithValues: names.map { suffix, version in
            let name = "SYNO.Foto." + suffix
            return (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: format))
        })
        entries["SYNO.Foto.BackgroundTask.File"] = ApiCapability(name: "SYNO.Foto.BackgroundTask.File", path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .json)
        entries[DsmAPIName.desktopInitData] = ApiCapability(name: DsmAPIName.desktopInitData, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form)
        for api in omittedAPIs { entries.removeValue(forKey: api) }
        let capabilities = CapabilitySet(missingCapabilities ? [:] : entries)
        return try SynologyPhotosRepository(
            profile: NasProfile(id: profileID, displayName: "测试设备", host: "nas.example.invalid", port: 5001),
            capabilities: capabilities,
            session: AuthSession(sid: "fixture-session", synoToken: "fixture-token", did: nil, isPortalPort: false),
            transport: transport, deletionEnabled: deletionEnabled
        )
    }
}
