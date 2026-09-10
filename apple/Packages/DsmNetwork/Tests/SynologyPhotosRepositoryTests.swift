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

    private let itemPage = #"{"success":true,"data":{"list":[{"id":7,"filename":"sample.jpg","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"photo","additional":{"resolution":{"width":100,"height":80},"orientation":1,"thumbnail":{"unit_id":7,"cache_key":"fixture-revision"}}}]}}"#

    private func accessResponses() -> [DsmHTTPResponse] {
        [
            response(#"{"success":true,"data":{"enabled":true,"is_admin":true}}"#),
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
        deletionEnabled: Bool = false
    ) throws -> SynologyPhotosRepository {
        let names = ["UserInfo": 1, "Setting.User": 1, "Setting.Admin": 1, "Setting.TeamSpace": 1,
                     "Browse.Timeline": 5, "Browse.Item": 6, "Browse.RecentlyAdded": 1, "Search.Search": 6,
                     "Browse.Folder": 2, "Browse.Album": 5, "Streaming": 2, "Download": 2,
                     "Browse.Category": 3, "Search.Filter": 3, "Sharing.Misc": 2, "PhotoRequest": 1,
                     "Browse.Person": 1, "Browse.Concept": 2, "Browse.Geocoding": 1, "Browse.GeneralTag": 1, "Browse.Unit": 1]
        var entries = Dictionary(uniqueKeysWithValues: names.map { suffix, version in
            let name = "SYNO.Foto." + suffix
            return (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: format))
        })
        entries["SYNO.Foto.BackgroundTask.File"] = ApiCapability(name: "SYNO.Foto.BackgroundTask.File", path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .json)
        entries[DsmAPIName.desktopInitData] = ApiCapability(name: DsmAPIName.desktopInitData, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form)
        let capabilities = CapabilitySet(missingCapabilities ? [:] : entries)
        return try SynologyPhotosRepository(
            profile: NasProfile(id: profileID, displayName: "测试设备", host: "nas.example.invalid", port: 5001),
            capabilities: capabilities,
            session: AuthSession(sid: "fixture-session", synoToken: "fixture-token", did: nil, isPortalPort: false),
            transport: transport, deletionEnabled: deletionEnabled
        )
    }
}
