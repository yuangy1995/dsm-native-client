import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class SynologyPhotosRepositoryTests: XCTestCase {

    private func deletionPhoto(_ profile: UUID, space: SynologyPhotoSpace = .personal) -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
    }
    private var deletionFolderResponse: DsmHTTPResponse {
        response(#"{"success":true,"data":{"folder":{"id":9,"name":"/Sample","parent":1,"additional":{"access_permission":{"view":true,"manage":true}}}}}"#)
    }
    func test原件删除恢复写前落盘且成功空响应后保存终态() async throws {
        let profile = UUID(), capture = PhotosDeletionCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), deletionFolderResponse,
            response(#"{"success":true}"#), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        let result = try await repository.performRecoverableDeletion(deletionPhoto(profile), operationID: UUID()) { capture.append($0) }
        XCTAssertEqual(result, .confirmed); XCTAssertEqual(capture.values.map(\.state), [.submitted, .confirmed])
        let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sample.jpg"))
        let restored = try JSONDecoder().decode(SynologyPhotoDeletionCheckpoint.self, from: data)
        XCTAssertTrue(try restored.matches(deletionPhoto(profile))); XCTAssertEqual(restored.version, 1)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
    }
    func test原件删除保存失败不提交且成功后的保存失败只读恢复() async throws {
        let profile = UUID()
        for failAfterWrite in [false, true] {
            let capture = PhotosDeletionCheckpointCapture()
            let after = failAfterWrite ? [response(#"{"success":true}"#), response(#"{"success":true,"data":{"list":[]}}"#)] : []
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), deletionFolderResponse] + after)
            let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
            do {
                _ = try await repository.performRecoverableDeletion(deletionPhoto(profile), operationID: UUID()) { value in
                    if (failAfterWrite && value.state == .confirmed) || !failAfterWrite { throw CocoaError(.fileWriteNoPermission) }
                    capture.append(value)
                }
                XCTFail("记录不能保存时不得假装完成")
            } catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, failAfterWrite ? 1 : 0)
            if failAfterWrite {
                let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.state, .submitted)
                let reader = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[]}}"#)])
                let fresh = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await fresh.access()
                let result = try await fresh.reviewDeletion(saved); XCTAssertEqual(result, .confirmed)
                let reads = try await reader.recordedRequests().map(decode); XCTAssertFalse(reads.contains { $0["method"] == "delete" })
            }
        }
    }
    func test原件删除断线重启只查询成功空响应并保留个人共享路由() async throws {
        for space in SynologyPhotoSpace.allCases {
            let profile = UUID(), capture = PhotosDeletionCheckpointCapture()
            let transport = MockHTTPTransport(steps: (accessResponses(teamPermission: "management") + [response(itemPage), deletionFolderResponse]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
            let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
            let result = try await repository.performRecoverableDeletion(deletionPhoto(profile, space: space), operationID: UUID()) { capture.append($0) }
            XCTAssertEqual(result, .pendingReview)
            let saved = try JSONDecoder().decode(SynologyPhotoDeletionCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
            let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(itemPage), response(#"{"success":true,"data":{"list":[]}}"#)])
            let fresh = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await fresh.access()
            let pending = try await fresh.reviewDeletion(saved); XCTAssertEqual(pending, .pendingReview)
            let complete = try await fresh.reviewDeletion(saved); XCTAssertEqual(complete, .confirmed)
            let reads = try await reader.recordedRequests().map(decode)
            XCTAssertEqual(reads.suffix(2).map { $0["api"] }, Array(repeating: space == .personal ? "SYNO.Foto.Browse.Item" : "SYNO.FotoTeam.Browse.Item", count: 2))
            XCTAssertFalse(reads.contains { $0["method"] == "delete" })
        }
    }
    func test原件删除明确拒绝保存终态且同操作不重发() async throws {
        for code in [105, 106, 107, 119] {
            let profile = UUID(), id = UUID(), capture = PhotosDeletionCheckpointCapture()
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), deletionFolderResponse, response("{\"success\":false,\"error\":{\"code\":\(code)}}")])
            let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
            for _ in 0..<2 {
                do { _ = try await repository.performRecoverableDeletion(deletionPhoto(profile), operationID: id) { capture.append($0) }; XCTFail("必须保留明确拒绝") } catch { }
            }
            XCTAssertEqual(capture.values.map(\.state), [.submitted, .rejected])
            let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
        }
    }
    func test原件删除恢复拒绝未提交权限错误和已替换目标() async throws {
        let profile = UUID(), photo = deletionPhoto(profile), identity = "\(profile.uuidString):12"
        let saved = try SynologyPhotoDeletionCheckpoint(photo: photo, operationID: UUID(), identity: identity, state: .submitted)
        for body in [#"{"success":false,"error":{"code":105}}"#, itemPage.replacingOccurrences(of: "sample.jpg", with: "replaced.jpg"), itemPage.replacingOccurrences(of: "\"time\":50", with: "\"time\":51")] {
            let reader = MockHTTPTransport(responses: accessResponses() + [response(body)])
            let repository = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await repository.access()
            do { _ = try await repository.reviewDeletion(saved); XCTFail("拒绝或身份改变不能冒充已删除") } catch { }
        }
        let reader = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        for state in [SynologyPhotoDeletionCheckpoint.State.prepared, .rejected, .cancelled] {
            var unsubmitted = saved; unsubmitted.state = state
            do { _ = try await repository.reviewDeletion(unsubmitted); XCTFail("未提交项不能用空列表确认删除") } catch { }
        }
        let requests = await reader.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }
    func test原件删除继续前读取最小身份且不依赖可选媒体资料() async throws {
        let profile = UUID(), photo = deletionPhoto(profile)
        let saved = try SynologyPhotoDeletionCheckpoint(photo: photo, operationID: UUID(), identity: "\(profile.uuidString):12")
        let minimal = #"{"success":true,"data":{"list":[{"id":7,"filename":"sample.jpg","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"photo","additional":{"exif":{"unexpected":true}}}]}}"#
        let reader = MockHTTPTransport(responses: accessResponses() + [response(minimal)]), repository = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        let target = try await repository.deletionTarget(saved); XCTAssertTrue(try saved.matches(target))
        let requests = try await reader.recordedRequests().map(decode)
        XCTAssertEqual(requests.last?["method"], "get"); XCTAssertNil(requests.last?["additional"]); XCTAssertFalse(requests.contains { $0["method"] == "delete" })
    }
    func test删除恢复完成释放原会话占用且未完成时阻止其他管理写() async throws {
        let profile = UUID(), capture = PhotosDeletionCheckpointCapture(), person = SynologyPhotoCollection(id: 31, name: "Before", itemCount: 1)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), deletionFolderResponse,
            response(emptySuccess), response(itemPage), response(#"{"success":true,"data":{"list":[]}}"#),
            response(personList([(31, "Before", 1)])), response(#"{"success":true,"data":{"id":31,"name":"After"}}"#), response(personList([(31, "After", 1)]))])
        let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        let first = try await repository.performRecoverableDeletion(deletionPhoto(profile), operationID: UUID()) { capture.append($0) }; XCTAssertEqual(first, .pendingReview)
        do { _ = try await repository.performMutation(.renamePerson(person, name: "After"), operationID: UUID()) { _, _ in }; XCTFail("删除尚未结束时不能交叉提交管理写") } catch { }
        let saved = try XCTUnwrap(capture.values.last); let deleted = try await repository.reviewDeletion(saved); XCTAssertEqual(deleted, .confirmed)
        let changed = try await repository.performMutation(.renamePerson(person, name: "After"), operationID: UUID()) { _, _ in }
        XCTAssertEqual(changed.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "delete" }.count, 1); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test原件删除恢复隔离账号与损坏摘要且查询前拒绝() async throws {
        let profile = UUID(), photo = deletionPhoto(profile)
        let reader = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        for identity in ["\(profile.uuidString):13", "\(UUID().uuidString):12"] {
            do {
                let saved = try SynologyPhotoDeletionCheckpoint(photo: photo, operationID: UUID(), identity: identity, state: .submitted)
                _ = try await repository.reviewDeletion(saved); XCTFail("跨账号不能读取恢复目标")
            } catch { }
        }
        let saved = try SynologyPhotoDeletionCheckpoint(photo: photo, operationID: UUID(), identity: "\(profile.uuidString):12", state: .submitted)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]); json["takenAtDigest"] = "damaged"
        let corrupted = try JSONDecoder().decode(SynologyPhotoDeletionCheckpoint.self, from: JSONSerialization.data(withJSONObject: json))
        do { _ = try await repository.reviewDeletion(corrupted); XCTFail("摘要损坏不能查询或提交") } catch { }
        let requests = await reader.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test预览设置恢复当前格式跨实例只回读开关() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let writer = MockHTTPTransport(steps: (accessResponses() + [response(automaticSettingFixture(false))]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(.setAutomaticPreview(original: false, enabled: true), operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
        let reader = MockHTTPTransport(responses: accessResponses() + [response(automaticSettingFixture(true))])
        let fresh = try makeRepository(reader, profileID: profile); _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
        let verified = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(verified.state, .confirmed)
        let calls = try await reader.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test自动预览恢复保存上传边界和摘要且重启不重复上传() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), media = try PhotoPreviewFixture.image()
        let writer = MockHTTPTransport(steps: automaticUploadResponses(source: media).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response("invalid"))])
        let repository = try makeRepository(writer, profileID: profile, convertedPreview: true); _ = try await repository.access()
        let command = automaticCommand(profileID: profile)
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let stages = capture.values.compactMap { value -> SynologyPhotosAlbumCheckpoint.AutomaticPreview? in
            if case .automatic(let task) = value.previewMaintenanceDetails { return task }; return nil
        }
        XCTAssertTrue(stages.contains { !$0.submitted && $0.thumbnailDigests.isEmpty })
        XCTAssertTrue(stages.contains { $0.submitted && !$0.acknowledged && $0.thumbnailDigests.count == 3 })
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        try await repository.restoreAlbumMutation(saved)
        let bodies = await writer.recordedUploadBodies(), body = try XCTUnwrap(bodies.first)
        for matches in [false, true] {
            let expected = try ["thumb_xl", "thumb_sm", "thumb_m"].map { try AutomaticPreviewEchoTransport.part($0, in: body) }
            let images = matches ? expected : [Data("old preview".utf8)]
            let reader = MockHTTPTransport(responses: accessResponses() + images.map { DsmHTTPResponse(data: $0, statusCode: 200, headers: ["Content-Type": "image/jpeg"]) })
            let fresh = try makeRepository(reader, profileID: profile, convertedPreview: true); _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
            let verified = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(verified.state, matches ? .confirmed : .pendingReview)
            let uploads = await reader.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
        }
        XCTAssertEqual(bodies.count, 1)
    }

    func test自动预览写前记录失败不会上传或同步失败标记() async throws {
        for failsInitially in [false, true] {
            let media = try PhotoPreviewFixture.image(), profile = UUID()
            let transport = MockHTTPTransport(responses: automaticUploadResponses(source: media))
            let repository = try makeRepository(transport, profileID: profile, convertedPreview: true); _ = try await repository.access()
            do {
                let result = try await repository.performRecoverableAlbumMutation(automaticCommand(profileID: profile), operationID: UUID()) { saved in
                    if case .automatic(let value) = saved.previewMaintenanceDetails, failsInitially || value.submitted { throw CocoaError(.fileWriteOutOfSpace) }
                }
                XCTAssertFalse(failsInitially); XCTAssertEqual(result.state, .rejected)
            } catch { XCTAssertTrue(failsInitially) }
            let uploads = await transport.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
            let calls = try await transport.recordedRequests().filter { $0.httpBody != nil }.map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set_broken" })
        }
    }

    func test自动预览恢复拒绝错账号矛盾阶段和无效视频摘要() async throws {
        let profile = UUID(), command = automaticCommand(profileID: profile)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 12)
        let reader = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(reader, profileID: profile)
        _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
        let untouched = try await repository.reviewMutation(operationID: saved.operationID); XCTAssertEqual(untouched.state, .rejected)
        var invalid = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 12)
        guard case .automatic(var value) = invalid.previewMaintenanceDetails else { return XCTFail("缺少自动预览记录") }
        value.submitted = true; invalid.previewMaintenanceDetails = .automatic(value)
        XCTAssertThrowsError(try invalid.reviewMutation())
        value.submitted = false; value.videoSignature = Data("invalid".utf8); invalid.previewMaintenanceDetails = .automatic(value)
        do { try await repository.restoreAlbumMutation(invalid); XCTFail("无效摘要不能恢复") } catch { }
        let foreign = MockHTTPTransport(responses: accessResponses()), other = try makeRepository(foreign, profileID: UUID())
        _ = try await other.access(); do { try await other.restoreAlbumMutation(saved); XCTFail("不能恢复其他账号") } catch { }
    }

    func test新格式生成回执先保存再关闭提示且跨实例保留生成限制() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), reads = codecResponses()
        let writer = MockHTTPTransport(responses: accessResponses() + reads + [response(emptySuccess), response(#"{"success":false,"error":{"code":100}}"#)] + reads)
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let original = SynologyPhotoCodecPrompt(profileID: profile, userID: 12, isAdministrator: true, shouldShow: true, personalSpaceEnabled: true)
        let result = try await repository.performRecoverableAlbumMutation(.respondToCodecPrompt(original, generate: true), operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .partial)
        XCTAssertTrue(capture.values.contains { if case .codec(_, true, true, false) = $0.previewMaintenanceDetails { return true }; return false })
        let saved = try XCTUnwrap(capture.values.last)
        let reader = MockHTTPTransport(responses: accessResponses() + reads + reads)
        let fresh = try makeRepository(reader, profileID: profile); _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
        let verified = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(verified.state, .partial)
        let prompt = try await fresh.codecPrompt(); XCTAssertTrue(prompt.generationAlreadySubmitted); XCTAssertFalse(prompt.canGenerate)
        let calls = try await reader.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["set", "reindex", "reindex_all_user"].contains($0["method"] ?? "") })
    }

    func test新格式与维护缺少接收回执重启不能按当前空闲追认() async throws {
        let profile = UUID()
        for acknowledged in [false, true] {
            let prompt = SynologyPhotoCodecPrompt(profileID: profile, userID: 12, isAdministrator: true, shouldShow: true, personalSpaceEnabled: true)
            var codec = try SynologyPhotosAlbumCheckpoint(mutation: .respondToCodecPrompt(prompt, generate: true), operationID: UUID(), profileID: profile, userID: 12)
            codec.previewMaintenanceDetails = .codec(prompt, generate: true, acknowledged: acknowledged, promptRejected: false)
            let reader = MockHTTPTransport(responses: accessResponses() + codecResponses(show: false))
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access(); try await repository.restoreAlbumMutation(codec)
            let result = try await repository.reviewMutation(operationID: codec.operationID); XCTAssertEqual(result.state, acknowledged ? .confirmed : .pendingReview)
            for space in SynologyPhotoSpace.allCases {
                let original = SynologyPhotoLibraryMaintenanceStatus(profileID: profile, userID: 12, space: space, indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
                var saved = try SynologyPhotosAlbumCheckpoint(mutation: .maintainLibrary(original, .previews), operationID: UUID(), profileID: profile, userID: 12)
                saved.previewMaintenanceDetails = .library(original, .previews, acknowledged: acknowledged)
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + maintenanceResponses(space: space))
                let fresh = try makeRepository(transport, profileID: profile); _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
                let verified = try await fresh.reviewMutation(operationID: saved.operationID); XCTAssertEqual(verified.state, acknowledged ? .confirmed : .pendingReview)
                let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "reindex" })
            }
        }
    }

    func test维护保存失败零写且回执在查询结束前保存() async throws {
        let profile = UUID(), capture = PhotosAlbumCheckpointCapture()
        let original = SynologyPhotoLibraryMaintenanceStatus(profileID: profile, userID: 12, space: .personal, indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
        for failed in [false, true] {
            let transport = MockHTTPTransport(responses: accessResponses() + maintenanceResponses() + [response(emptySuccess)] + maintenanceResponses(basic: 3))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do {
                let result = try await repository.performRecoverableAlbumMutation(.maintainLibrary(original, .reindex), operationID: UUID()) { value in
                    if failed { throw CocoaError(.fileWriteOutOfSpace) }; capture.append(value)
                }
                XCTAssertFalse(failed); XCTAssertEqual(result.state, .pendingReview)
                guard case .library(_, .reindex, true) = capture.values.last?.previewMaintenanceDetails else { return XCTFail("必须保存接收回执") }
            } catch { XCTAssertTrue(failed) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "reindex" }.count, failed ? 0 : 1)
        }
    }

    func test自动视频恢复摘要可跨实例回读真实生成内容() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.mov")
        try await PhotoPreviewFixture.video(at: source, codec: .jpeg, withAudio: true)
        let candidate = automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Fixture.mov")
            .replacingOccurrences(of: "\"type\":0", with: "\"type\":1")
            .replacingOccurrences(of: "\"need_thumbnail\":true", with: "\"need_thumbnail\":false")
            .replacingOccurrences(of: "\"need_video\":false", with: "\"need_video\":true")
        let writer = MockHTTPTransport(responses: automaticUploadResponses(source: try Data(contentsOf: source), candidate: candidate) + [response(emptySuccess)])
        let profile = UUID(), capture = PhotosAlbumCheckpointCapture(), repository = try makeRepository(writer, profileID: profile, convertedPreview: true)
        _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(automaticCommand(profileID: profile, type: 1, thumbnail: false, video: true), operationID: UUID()) { capture.append($0) }
        XCTAssertEqual(result.state, .confirmed)
        var saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        guard case .automatic(var value) = saved.previewMaintenanceDetails else { return XCTFail("缺少转换记录") }
        let signature = try JSONDecoder().decode(PhotosPreviewVideoSignature.self, from: XCTUnwrap(value.videoSignature))
        try signature.validate(); XCTAssertGreaterThan(signature.durationMicroseconds, 0); XCTAssertFalse(signature.tracks.isEmpty)
        value.acknowledged = false; saved.previewMaintenanceDetails = .automatic(value)
        let bodies = await writer.recordedUploadBodies(), film = try AutomaticPreviewEchoTransport.part("film_h264", in: XCTUnwrap(bodies.first))
        let reader = MockHTTPTransport(responses: accessResponses() + [DsmHTTPResponse(data: film, statusCode: 200)])
        let fresh = try makeRepository(reader, profileID: profile, convertedPreview: true); _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
        let verified = try await fresh.reviewMutation(operationID: saved.operationID); XCTAssertEqual(verified.state, .confirmed)
        let uploads = await reader.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
    }

    func test自动预览失败标记先保存阶段且恢复不会再次标记() async throws {
        for failsBeforeMark in [false, true] {
            let profile = UUID(), capture = PhotosAlbumCheckpointCapture()
            let writer = MockHTTPTransport(responses: automaticUploadResponses(source: Data("invalid media".utf8)) + [response(emptySuccess)])
            let repository = try makeRepository(writer, profileID: profile, convertedPreview: true); _ = try await repository.access()
            let result = try await repository.performRecoverableAlbumMutation(automaticCommand(profileID: profile), operationID: UUID()) { saved in
                if case .automatic(let value) = saved.previewMaintenanceDetails, failsBeforeMark && value.failureKind != nil { throw CocoaError(.fileWriteOutOfSpace) }
                capture.append(saved)
            }
            XCTAssertEqual(result.state, .rejected); XCTAssertEqual(result.automaticPreviewFailureRecorded, !failsBeforeMark)
            let calls = try await writer.recordedRequests().filter { $0.httpBody != nil }.map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "set_broken" }.count, failsBeforeMark ? 0 : 1)
            let saved = try XCTUnwrap(capture.values.last)
            if !failsBeforeMark {
                XCTAssertTrue(capture.values.contains { if case .automatic(let value) = $0.previewMaintenanceDetails { return value.failureKind == .photo && !value.failureAcknowledged }; return false })
                let reader = MockHTTPTransport(responses: accessResponses()), fresh = try makeRepository(reader, profileID: profile, convertedPreview: true)
                _ = try await fresh.access(); try await fresh.restoreAlbumMutation(saved)
                let verified = try await fresh.reviewMutation(operationID: saved.operationID); XCTAssertEqual(verified.state, .rejected); XCTAssertTrue(verified.automaticPreviewFailureRecorded)
                let reads = await reader.recordedRequests(); XCTAssertEqual(reads.count, accessResponses().count)
            }
        }
    }

    func test预览恢复当前格式保存每个写入边界且重启只读完成() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [itemPage, itemPage, managedFolder, previewQueue(), emptySuccess, previewQueue()].map(response))
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, profileID: profile, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        var photo = try XCTUnwrap(page.items.first)
        photo.description = "private-description"; photo.camera = "private-camera"
        let command = SynologyPhotosMutation.regeneratePreviews([photo])
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let stages = capture.values.compactMap { $0.previewRegenerationDetails?.targets.first }
        XCTAssertTrue(stages.contains { !$0.marking && !$0.submitted })
        XCTAssertTrue(stages.contains { $0.marking && !$0.marked && !$0.submitted })
        XCTAssertTrue(stages.contains { $0.marked && !$0.submitted })
        XCTAssertTrue(stages.contains { $0.submitted && !$0.generated })
        let encoded = try JSONEncoder().encode(XCTUnwrap(capture.values.last)), text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-description")); XCTAssertFalse(text.contains("private-camera")); XCTAssertFalse(text.contains("fixture-token"))
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: encoded)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertTrue(try XCTUnwrap(saved.previewRegenerationDetails).hasSameIntent(as: command))
        try await repository.restoreAlbumMutation(saved)
        let empty = #"{"success":true,"data":{"list":[]}}"#
        let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "new-preview")
        for (page, expected) in [(itemPage, SynologyPhotosMutationResult.State.pendingReview), (updated, .confirmed),
                                 (updated.replacingOccurrences(of: "sample.jpg", with: "replacement.jpg"), .pendingReview)] {
            let reader = MockHTTPTransport(responses: accessResponses() + [empty, page, empty, page].map(response))
            let fresh = try makeRepository(reader, profileID: profile); _ = try await fresh.access()
            try await fresh.restoreAlbumMutation(saved)
            let result = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(result.state, expected)
            let calls = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating", "upload"].contains($0["method"] ?? "") })
        }
    }

    func test预览恢复未转换阶段不重发标记且保留NAS队列() async throws {
        let profile = UUID(), photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg",
            sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
        for stage in 0...3 {
            var saved = try SynologyPhotosAlbumCheckpoint(mutation: .regeneratePreviews([photo]), operationID: UUID(), profileID: profile, userID: 12)
            var value = try XCTUnwrap(saved.previewRegenerationDetails)
            value.targets[0].marking = stage > 0; value.targets[0].marked = stage > 1; value.targets[0].submitted = stage > 2
            saved.previewRegenerationDetails = value
            let reader = MockHTTPTransport(responses: accessResponses() + [previewQueue(), itemPage, managedFolder].map(response))
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(saved)
            let result = try await repository.reviewMutation(operationID: saved.operationID)
            XCTAssertEqual(result.state, stage == 3 ? .pendingReview : .rejected)
            let calls = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") })
        }
    }

    func test预览标记丢回执同会话可读回队列而不要求重启() async throws {
        let capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [itemPage, itemPage, managedFolder, "invalid", previewQueue(), itemPage, managedFolder].map(response))
        let socket = previewSocket(success: true)
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let id = UUID()
        let result = try await repository.performRecoverableAlbumMutation(.regeneratePreviews(photos), operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .rejected)
        let checked = try await repository.reviewMutation(operationID: id); XCTAssertEqual(checked.state, .rejected)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "set_regenerating" }.count, 1)
        XCTAssertFalse(calls.contains { $0["method"] == "regenerate_preview_by_nas" || $0["method"] == "restore_from_regenerating" })
        XCTAssertTrue(try XCTUnwrap(capture.values.last?.previewRegenerationDetails?.targets.first).marking)
    }

    func test预览每步写前保存失败不会开始该步写请求() async throws {
        for boundary in 0...2 {
            let transport = MockHTTPTransport(responses: accessResponses() + [itemPage, itemPage, managedFolder, previewQueue()].map(response))
            let socket = previewSocket(success: true)
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
            do {
                let result = try await repository.performRecoverableAlbumMutation(.regeneratePreviews(photos), operationID: UUID()) { checkpoint in
                    let target = try XCTUnwrap(checkpoint.previewRegenerationDetails?.targets.first)
                    if boundary == 0 || (boundary == 1 && target.marking) || (boundary == 2 && target.submitted) { throw CocoaError(.fileWriteOutOfSpace) }
                }
                XCTAssertEqual(result.state, .rejected)
            } catch { XCTAssertEqual(boundary, 0) }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "set_regenerating" }.count, boundary == 2 ? 1 : 0)
            XCTAssertFalse(calls.contains { $0["method"] == "regenerate_preview_by_nas" || $0["method"] == "upload" })
        }
    }

    func test预览明确失败后清理丢回执重启只结束失败不误报生成() async throws {
        let profile = UUID(), photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg",
            sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .regeneratePreviews([photo]), operationID: UUID(), profileID: profile, userID: 12)
        var value = try XCTUnwrap(saved.previewRegenerationDetails)
        value.targets[0].marking = true; value.targets[0].marked = true; value.targets[0].submitted = true; value.targets[0].restoring = true
        value.targets[0].baselineUnitID = 7; value.targets[0].baselineRevision = "fixture-revision"; saved.previewRegenerationDetails = value
        for queue in [previewQueue(), #"{"success":true,"data":{"list":[]}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [queue, itemPage].map(response))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(saved)
            let result = try await repository.reviewMutation(operationID: saved.operationID)
            XCTAssertEqual(result.state, queue == previewQueue() ? .pendingReview : .rejected)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { $0["method"] == "restore_from_regenerating" })
        }
    }

    func test预览本机上传也保存标记提交和成功回执() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(page), response(page), response(managedFolder),
            DsmHTTPResponse(data: data, statusCode: 200), response(page), response(managedFolder), response(previewQueue(name: "fixture.png")),
            response(emptySuccess), response(page)])
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performRecoverableAlbumMutation(.regeneratePreviews(photos), operationID: UUID()) { capture.append($0) }
        XCTAssertEqual(result.state, .confirmed)
        let target = try XCTUnwrap(capture.values.last?.previewRegenerationDetails?.targets.first)
        XCTAssertTrue(target.marking && target.marked && target.submitted && target.generated)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }.count, 1)
    }

    func test预览恢复拒绝跨账号和矛盾阶段快照() async throws {
        let profile = UUID(), photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg",
            sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .regeneratePreviews([photo]), operationID: UUID(), profileID: profile, userID: 12)
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport, profileID: UUID()); _ = try await repository.access()
        do { try await repository.restoreAlbumMutation(saved); XCTFail("不能恢复其他NAS账号") } catch { }
        var value = try XCTUnwrap(saved.previewRegenerationDetails); value.targets[0].submitted = true; saved.previewRegenerationDetails = value
        XCTAssertThrowsError(try saved.reviewMutation())
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .regeneratePreviews([]), operationID: UUID(), profileID: profile, userID: 12))
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .regeneratePreviews([photo, photo]), operationID: UUID(), profileID: profile, userID: 12))
    }

    func test照片偏好恢复当前格式保持原始设置且只回读不重复保存() async throws {
        let original = SynologyPhotoDisplaySettings(), updated = SynologyPhotoDisplaySettings(grouping: .month, clock: .twelve, showsPreviewInfo: true)
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [try displayPayload(original), "invalid", try displayPayload(updated)].map(response))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setDisplaySettings(original: original, updated: updated)
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(try saved.reviewMutation(), command)
        try await repository.restoreAlbumMutation(saved)
        let current = try await repository.reviewMutation(operationID: id); XCTAssertEqual(current.state, .confirmed)
        let freshTransport = MockHTTPTransport(responses: accessResponses() + [response(try displayPayload(updated))])
        let fresh = try makeRepository(freshTransport, profileID: profile); _ = try await fresh.access()
        try await fresh.restoreAlbumMutation(saved)
        let result = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        let calls = try await freshTransport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test重复文件与识别偏好恢复校验最终值缺字段仍未知() async throws {
        let profile = UUID()
        let all = Set(SynologyPhotoRecognitionSettings.Kind.allCases)
        let original = SynologyPhotoRecognitionSettings(values: [.person: true, .concept: true, .similar: false], globallyEnabled: all, personalSpaceEnabled: true)
        let target = SynologyPhotoRecognitionSettings(values: [.person: false, .concept: true, .similar: false], globallyEnabled: all, personalSpaceEnabled: true)
        let commands: [(SynologyPhotosMutation, [DsmHTTPResponse])] = [
            (.setDuplicateSettings(original: .init(upload: .rename, transfer: .skip), updated: .init(upload: .ignore, transfer: .overwrite)),
                [response(#"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"overwrite"}}"#)]),
            (.setRecognitionSettings(original: original, enabled: [.concept]), try recognitionResponses(target))
        ]
        for (command, responses) in commands {
            let id = UUID(), saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            let restored = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(try restored.reviewMutation(), command)
            let transport = MockHTTPTransport(responses: accessResponses() + responses)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(restored)
            let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
        let missing = SynologyPhotoRecognitionSettings(values: [.person: false], globallyEnabled: [.person], personalSpaceEnabled: true)
        let transport = MockHTTPTransport(responses: accessResponses() + (try recognitionResponses(missing)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: commands[1].0, operationID: UUID(), profileID: profile, userID: 12)
        try await repository.restoreAlbumMutation(saved)
        let unknown = try await repository.reviewMutation(operationID: saved.operationID); XCTAssertEqual(unknown.state, .pendingReview)
    }

    func test照片旋转持久恢复保留方向尺寸并拒绝原尺寸或替换对象() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let rotated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":8"#)
        let confirmed = rotated.replacingOccurrences(of: #""width":100,"height":80"#, with: #""width":80,"height":100"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [itemPage, itemPage, managedFolder, "invalid", itemPage].map(response))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        var photo = try XCTUnwrap(page.items.first); photo.description = "private description"; photo.camera = "private metadata"
        let command = SynologyPhotosMutation.rotatePhoto(photo)
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last)), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private description")); XCTAssertFalse(text.contains("private metadata"))
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
        XCTAssertTrue(try XCTUnwrap(saved.preferenceDetails).hasSameIntent(as: command))
        try await repository.restoreAlbumMutation(saved)
        for (payload, expected) in [(itemPage, SynologyPhotosMutationResult.State.pendingReview), (rotated, .pendingReview), (confirmed, .confirmed), (confirmed.replacingOccurrences(of: "sample.jpg", with: "replacement.jpg"), .pendingReview)] {
            let reader = MockHTTPTransport(responses: accessResponses() + [response(payload)])
            let fresh = try makeRepository(reader, profileID: profile); _ = try await fresh.access()
            try await fresh.restoreAlbumMutation(saved)
            if payload.contains("replacement.jpg") {
                do { _ = try await fresh.reviewMutation(operationID: id); XCTFail("同编号替换原件不能追认旋转") }
                catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            } else {
                let result = try await fresh.reviewMutation(operationID: id); XCTAssertEqual(result.state, expected)
            }
            let calls = try await reader.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
    }

    func test照片偏好恢复保存失败零写且拒绝跨账号记录() async throws {
        let profile = UUID(), command = SynologyPhotosMutation.setDuplicateSettings(original: .init(upload: .ignore, transfer: .skip), updated: .init(upload: .rename, transfer: .skip))
        let original = #"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"skip"}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(original)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do {
            _ = try await repository.performRecoverableAlbumMutation(command, operationID: UUID()) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("记录不可写时不得保存偏好")
        } catch { }
        for (identity, user) in [(UUID(), 12), (profile, 99)] {
            let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: identity, userID: user)
            do { try await repository.restoreAlbumMutation(saved); XCTFail("不得恢复其他账号") } catch { }
        }
        let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test照片偏好损坏枚举及不可编辑识别记录拒绝恢复() throws {
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .setDisplaySettings(original: .init(), updated: .init(clock: .twelve)), operationID: UUID(), profileID: UUID(), userID: 12)
        let data = try JSONEncoder().encode(saved)
        let corrupt = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "yyyy-mm-dd", with: "unknown-format")
        XCTAssertThrowsError(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: Data(corrupt.utf8)))
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .setRecognitionSettings(original: .init(values: [.person: false], globallyEnabled: [], personalSpaceEnabled: true), enabled: [.person]), operationID: UUID(), profileID: UUID(), userID: 12))
    }


    func test目录权限恢复不保存密码链接成员名称且应用子目录必须取得回执() async throws {
        for acknowledged in [false, true] {
            let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            let member = #"[{"id":20,"type":"user","name":"Private member label","role":"manage"}]"#
            let baseline = [permissionFolder(members: member), permissionConfig, permissionParent]
            let receipts = acknowledged ? [emptySuccess, "invalid"] : ["invalid"]
            let writer = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + baseline + receipts).map(response))
            let source = try makeRepository(writer, profileID: profile); _ = try await source.access()
            let original = try await source.folderSharing(permissionTarget)
            let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .download, members: nil,
                password: "synthetic-password-never-persist", appliesToSubfolders: true)
            let result = try await source.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
            XCTAssertEqual(result.state, .pendingReview)
            let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last)), text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("synthetic-password-never-persist")); XCTAssertFalse(text.contains("example.invalid"))
            XCTAssertFalse(text.contains("Private member label"))
            let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
            XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.folderSharingDetails?.acknowledged, acknowledged)
            let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management") +
                [permissionFolder(privacy: "public-download", members: member), permissionConfig, permissionParent].map(response))
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(saved); try await restored.restoreAlbumMutation(saved)
            let final = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(final.state, acknowledged ? .confirmed : .pendingReview)
            let reads = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(reads.contains { ["update", "set_config"].contains($0["method"] ?? "") })
        }
    }

    func test目录权限配置失败跨实例恢复保留部分完成且不重放() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let baseline = [permissionFolder(), permissionConfig, permissionParent]
        let writer = MockHTTPTransport(responses: accessResponses(teamPermission: "management") +
            (baseline + baseline + [emptySuccess, "invalid", "invalid"]).map(response))
        let source = try makeRepository(writer, profileID: profile); _ = try await source.access()
        let original = try await source.folderSharing(permissionTarget)
        _ = try await source.performRecoverableAlbumMutation(.setFolderSharing(original: original, access: .view, members: nil, password: nil,
            appliesToSubfolders: false), operationID: id) { capture.append($0) }
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertTrue(saved.folderSharingDetails?.acknowledged == true)
        let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management") +
            [permissionFolder(privacy: "public-view"), permissionConfig, permissionParent].map(response))
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let final = try await restored.reviewMutation(operationID: id); XCTAssertEqual(final.state, .partial)
        let writes = try await writer.recordedRequests().map(decode)
        XCTAssertEqual(writes.filter { $0["method"] == "update" }.count, 1); XCTAssertEqual(writes.filter { $0["method"] == "set_config" }.count, 1)
    }

    func test目录权限恢复摘要拒绝不同原快照与账号且存储失败零写() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let baseline = [permissionFolder(), permissionConfig, permissionParent]
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + baseline + ["invalid"]).map(response))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let original = try await repository.folderSharing(permissionTarget)
        let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .view, members: nil, password: nil, appliesToSubfolders: true)
        _ = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        let changed = try SynologyPhotosAlbumCheckpoint(mutation: .setFolderSharing(original: original, access: .download, members: nil, password: nil,
            appliesToSubfolders: true), operationID: id, profileID: profile, userID: 12)
        do { try await repository.restoreAlbumMutation(changed); XCTFail("不能替换原意图") } catch { }
        let denied = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + baseline.map(response))
        let other = try makeRepository(denied, profileID: profile); _ = try await other.access()
        do { _ = try await other.performRecoverableAlbumMutation(command, operationID: UUID()) { _ in throw CocoaError(.fileWriteNoPermission) }; XCTFail() } catch { }
        let requests = try await denied.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "update" })
        let wrongAccount = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 99)
        do { try await other.restoreAlbumMutation(wrongAccount); XCTFail("不能恢复其他账号") } catch { }
    }

    func test后台取消未知回执跨实例恢复仅查询原身份() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), initial = backgroundEntry()
        let writer = MockHTTPTransport(responses: accessResponses() + [backgroundList([initial]), backgroundList([initial]), response("invalid"), backgroundList([initial])])
        let source = try makeRepository(writer, profileID: profile); _ = try await source.access()
        let listed = try await source.backgroundTasks(), task = try XCTUnwrap(listed.first)
        let first = try await source.performRecoverableAlbumMutation(.cancelBackgroundTask(task), operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
        for changed in [false, true] {
            let reader = MockHTTPTransport(responses: accessResponses() + [backgroundList([backgroundEntry(status: "done", created: changed ? 101 : 100)])])
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(saved); try await restored.restoreAlbumMutation(saved)
            do { let final = try await restored.reviewMutation(operationID: id); XCTAssertFalse(changed); XCTAssertEqual(final.state, .confirmed) }
            catch { XCTAssertTrue(changed) }
            let reads = try await reader.recordedRequests().map(decode); XCTAssertFalse(reads.contains { $0["method"] == "abort_task" })
        }
    }

    func test后台批量清除中断持久保存已尝试范围且恢复不清新增记录() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let originals = [backgroundEntry(status: "done"), backgroundEntry(id: 43, status: "done"), backgroundEntry(id: 44, status: "done")]
        let writer = MockHTTPTransport(responses: accessResponses() + [backgroundList(originals), backgroundList(originals), response(emptySuccess), response("invalid"), backgroundList(Array(originals.suffix(2)))])
        let source = try makeRepository(writer, profileID: profile); _ = try await source.access()
        let tasks = try await source.backgroundTasks()
        let first = try await source.performRecoverableAlbumMutation(.clearBackgroundTasks(tasks), operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        XCTAssertEqual(saved.backgroundDetails?.attempted, [42, 43]); XCTAssertEqual(saved.backgroundDetails?.rejected, [])
        let reader = MockHTTPTransport(responses: accessResponses() + [backgroundList([originals[2], backgroundEntry(id: 45, status: "done")])])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let final = try await restored.reviewMutation(operationID: id); XCTAssertEqual(final.state, .partial); XCTAssertEqual(final.completedCount, 2)
        let reads = try await reader.recordedRequests().map(decode); XCTAssertFalse(reads.contains { $0["method"] == "clear_completed_task" })
    }

    func test后台清除逐项保存失败不提交该项并保留已完成记录() async throws {
        let capture = PhotosAlbumCheckpointCapture(), originals = [backgroundEntry(status: "done"), backgroundEntry(id: 43, status: "done")]
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList(originals), backgroundList(originals), response(emptySuccess), backgroundList([originals[1]])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let tasks = try await repository.backgroundTasks()
        let final = try await repository.performRecoverableAlbumMutation(.clearBackgroundTasks(tasks), operationID: UUID()) {
            if $0.backgroundDetails?.attempted.contains(43) == true { throw CocoaError(.fileWriteNoPermission) }
            capture.append($0)
        }
        XCTAssertEqual(final.state, .partial); XCTAssertEqual(final.completedCount, 1)
        XCTAssertEqual(capture.values.last?.backgroundDetails?.attempted, [42])
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "clear_completed_task" }
        XCTAssertEqual(writes.map { $0["id"] }, ["42"])
    }

    func test后台恢复保留既有读取允许的零时间和未知目标() throws {
        let profile = UUID(), original = SynologyPhotoBackgroundTask(profileID: profile, userID: 12, id: 42, operation: "copy", status: .processing,
            total: 0, completion: 0, errors: 0, skipped: 0, overwritten: 0, createdAt: 0, targetFolderID: 0, targetOwnerID: 99)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .cancelBackgroundTask(original), operationID: UUID(), profileID: profile, userID: 12)
        let restored = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(saved))
        guard case .cancelBackgroundTask(let target) = try restored.reviewMutation() else { return XCTFail() }
        XCTAssertTrue(target.hasSameIdentity(as: original)); XCTAssertNil(target.targetSpace)
    }

    func test后台恢复摘要拒绝其他账号和不属于原集合的提交编号() async throws {
        let profile = UUID(), task = SynologyPhotoBackgroundTask(profileID: UUID(), userID: 12, id: 42, operation: "copy", status: .done,
            total: 5, completion: 5, errors: 0, skipped: 0, overwritten: 0, createdAt: 100, targetFolderID: 9, targetOwnerID: 12)
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .clearBackgroundTasks([task]), operationID: UUID(), profileID: profile, userID: 12))
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .clearBackgroundTasks([task]), operationID: UUID(), profileID: task.profileID, userID: 12)
        var control = try XCTUnwrap(saved.backgroundDetails); control.attempted = [99]; saved.backgroundDetails = control
        XCTAssertThrowsError(try saved.reviewMutation())
    }

    func test目录创建重命名排序跨实例恢复沿原目标且不重写() async throws {
        for space in SynologyPhotoSpace.allCases {
            for kind in 0..<3 {
                let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
                let source = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: space)
                let sort = SynologyPhotoSort(field: .filename, direction: .descending)
                let command: SynologyPhotosMutation = kind == 0 ? .createFolder(parentID: 9, name: "Trip", space: space)
                    : kind == 1 ? .renameFolder(folder: source, name: "Renamed") : .setFolderSort(folder: source, sort: sort)
                let receipt = kind == 0 ? #"{"success":true,"data":{"folder":{"id":10}}}"# : emptySuccess
                let writer = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [coverFolder(), receipt, "invalid"].map(response))
                let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
                let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
                XCTAssertEqual(first.state, .pendingReview)
                let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
                let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
                XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.folderDetails?.createdFolderID, kind == 0 ? 10 : nil)
                let updated = kind == 0 ? coverFolder(id: 10, path: "/Fixture/Trip").replacingOccurrences(of: #""parent":1"#, with: #""parent":9"#)
                    : kind == 1 ? coverFolder(path: "/Renamed") : sortedFolder(sort)
                let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(updated)])
                let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
                try await restored.restoreAlbumMutation(saved)
                let final = try await restored.reviewMutation(operationID: id)
                XCTAssertEqual(final.state, .confirmed); XCTAssertEqual(final.folder?.space, space)
                let reads = try await reader.recordedRequests().map(decode)
                XCTAssertFalse(reads.contains { ["create", "rename", "set_order"].contains($0["method"] ?? "") })
                let writes = try await writer.recordedRequests().map(decode)
                XCTAssertEqual(writes.filter { ["create", "rename", "set_order"].contains($0["method"] ?? "") }.count, 1)
            }
        }
    }

    func test目录复制移动恢复真实任务编号目标与数量且不重新提交() async throws {
        for (moving, destination) in [(true, SynologyPhotoSpace.personal), (false, .personal), (true, .shared), (false, .shared)] {
            let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            let source = deletionFolderTarget(), target = coverFolder(id: 20, path: "/Destination")
            let receipt = folderTransferReceipt(total: 600, owner: destination == .shared ? 0 : 12)
            let writer = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [coverFolder(), deletingFolder(), target, receipt, "invalid"].map(response))
            let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
            let command: SynologyPhotosMutation = moving ? .move([], folderID: 20, destinationSpace: destination, folders: [source]) : .copy([], folderID: 20, destinationSpace: destination, folders: [source])
            let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
            XCTAssertEqual(first.state, .pendingReview)
            let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
            XCTAssertEqual(saved.folderDetails?.taskID, 42); XCTAssertEqual(saved.folderDetails?.transferTotal, 600)
            XCTAssertEqual(saved.folderDetails?.transferTargetVerified, true)
            let moved = deletingFolder(parent: 20).replacingOccurrences(of: "/Fixture/Child10", with: "/Destination/Child10")
            let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management") +
                ([folderDeleteStatus(completion: 600), target] + (moving && destination == .personal ? [moved] : [])).map(response))
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(saved)
            let result = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 600)
            let reads = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(reads.contains { ["copy", "move"].contains($0["method"] ?? "") })
        }
    }

    func test目录删除恢复任务终态及父目录回读不重删() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let writer = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), folderDeleteReceipt, "invalid"].map(response))
        let repository = try makeRepository(writer, profileID: profile, deletionEnabled: true); _ = try await repository.access()
        let command = SynologyPhotosMutation.deleteFolderItems(photos: [], folders: [deletionFolderTarget()])
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(first.state, .pendingReview)
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
        XCTAssertEqual(saved.folderDetails?.taskID, 42)
        let reader = MockHTTPTransport(responses: accessResponses() + [folderDeleteStatus(), coverFolder(), emptyFolderOrItemList].map(response))
        let restored = try makeRepository(reader, profileID: profile, deletionEnabled: true); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved)
        let result = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.deletedFolders.map(\.id), [10])
        let requests = try await reader.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "delete" })
    }

    func test目录封面恢复仍要求成功回执与可解码自定义封面() async throws {
        for acknowledged in [true, false] {
            let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            let writer = MockHTTPTransport(responses: accessResponses() + [coverFolder(), itemPage, coverFolder(manage: false), acknowledged ? emptySuccess : "invalid", "invalid"].map(response))
            let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), photo: coverPhoto(profile, space: .personal))
            let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
            XCTAssertEqual(first.state, .pendingReview)
            let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.folderDetails?.coverAcknowledged, acknowledged)
            let data = try PhotoPreviewFixture.image(type: .jpeg)
            let reader = MockHTTPTransport(responses: accessResponses() + (acknowledged ? [response(coverFolder(thumbnail: customFolderCover)), .init(data: data, statusCode: 200, headers: ["Content-Type": "image/jpeg"])] : []))
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(saved)
            let result = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, acknowledged ? .confirmed : .pendingReview)
            let requests = await reader.recordedRequests(); XCTAssertEqual(requests.count, acknowledged ? 6 : 4)
        }
    }

    func test目录恢复丢失编号不按同名猜测且写前存储失败零提交() async throws {
        let profile = UUID(), source = deletionFolderTarget()
        for command in [SynologyPhotosMutation.createFolder(parentID: 9, name: "Trip"), .copy([], folderID: 20, folders: [source]), .deleteFolderItems(photos: [], folders: [source])] {
            let id = UUID(), saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, profileID: profile, deletionEnabled: true)
            _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
            let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .pendingReview)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
        let writer = MockHTTPTransport(responses: accessResponses() + [response(coverFolder())])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        do {
            _ = try await repository.performRecoverableAlbumMutation(.createFolder(parentID: 9, name: "Trip"), operationID: UUID()) { _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("存储失败不应提交")
        } catch { }
        let requests = try await writer.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "create" })
    }

    func test目录恢复拒绝错账号非法回执与同编号不同意图() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.copy([], folderID: 20, folders: [deletionFolderTarget()])
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        var invalid = saved
        var folder = try XCTUnwrap(invalid.folderDetails); folder.transferTargetVerified = true; invalid.folderDetails = folder
        XCTAssertThrowsError(try invalid.reviewMutation())
        let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
        for other in [try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: UUID(), userID: 12),
                      try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 99),
                      try SynologyPhotosAlbumCheckpoint(mutation: .move([], folderID: 20, folders: [deletionFolderTarget()]), operationID: id, profileID: profile, userID: 12)] {
            do { try await repository.restoreAlbumMutation(other); XCTFail("不能恢复其他身份或意图") } catch { }
        }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test照片编辑恢复覆盖两种来源六种操作且不保存正文或重写() async throws {
        for space in SynologyPhotoSpace.allCases {
            for kind in 0..<6 {
                let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
                let updated: String
                switch kind {
                case 0: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#)
                case 1: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"description":"Private description""#)
                case 2, 3: updated = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":100"#)
                case 4: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[{"id":8,"name":"Private tag"}]"#)
                default: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[]"#)
                }
                let writer = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder), response(emptySuccess), response("invalid")])
                let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
                let photos = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20).items
                let command: SynologyPhotosMutation
                switch kind {
                case 0: command = .edit(photos, .rating(4))
                case 1: command = .edit(photos, .description("Private description"))
                case 2: command = .edit(photos, .takenAt(Date(timeIntervalSince1970: 100)))
                case 3: command = .shiftDates(photos, seconds: 50)
                case 4: command = .addTags(photos, ids: [8])
                default: command = .removeTags(photos, ids: [8])
                }
                let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
                XCTAssertEqual(first.state, .pendingReview)
                let saved = try XCTUnwrap(capture.values.last)
                XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.photoEditDetails?.attempted, [0])
                let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
                for value in ["sample.jpg", "Private description", "Private tag", "fixture-token"] { XCTAssertFalse(text.contains(value)) }
                let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(updated)])
                let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
                try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
                let result = try await restored.reviewMutation(operationID: id)
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.map(\.id), photos.map(\.id))
                let calls = try await reader.recordedRequests().map(decode)
                XCTAssertFalse(calls.contains { ["set", "add_tag", "remove_tag", "create"].contains($0["method"] ?? "") })
            }
        }
    }

    func test日期第二步记录保存失败只完成第一步且恢复不重放() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let second = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
        let updated = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":60"#)
        let writer = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(second), response(itemPage), response(managedFolder),
            response(second), response(managedFolder), response(emptySuccess), response(updated)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let first = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let next = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 1, limit: 20)
        let result = try await repository.performRecoverableAlbumMutation(.shiftDates(first.items + next.items, seconds: 10), operationID: id) { value in
            if value.photoEditDetails?.attempted.count == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            capture.append(value)
        }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.photos.map(\.id.unitID), [7])
        let writes = try await writer.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["time"], "60")
        let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.photoEditDetails?.attempted, [0])
        let reader = MockHTTPTransport(responses: accessResponses() + [response(updated)])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .partial); XCTAssertEqual(reviewed.photos.map(\.id.unitID), [7])
        let reads = try await reader.recordedRequests().map(decode); XCTAssertFalse(reads.contains { $0["method"] == "set" })
    }

    func test标签创建恢复需要回执编号并保留未应用的部分结果() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let tags = #"{"success":true,"data":{"list":[{"id":8,"name":"Private tag"}]}}"#
        let writer = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"tag":{"id":8,"name":"Private tag"}}}"#), response(tags), response(itemPage)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let command = SynologyPhotosMutation.createTag(name: "Private tag", photos: photos)
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) { value in
            if value.photoEditDetails?.tagAdditionAttempted == true { throw CocoaError(.fileWriteOutOfSpace) }
            capture.append(value)
        }
        XCTAssertEqual(first.state, .partial); XCTAssertEqual(first.tag?.id, 8)
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(saved.photoEditDetails?.createdTagID, 8); XCTAssertEqual(saved.photoEditDetails?.tagAdditionAttempted, false)
        let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self); XCTAssertFalse(text.contains("Private tag")); XCTAssertFalse(text.contains("sample.jpg"))
        let reader = MockHTTPTransport(responses: accessResponses() + [response(tags), response(itemPage)])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .partial); XCTAssertEqual(reviewed.tag?.name, "Private tag")
        let calls = try await reader.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["create", "add_tag"].contains($0["method"] ?? "") })
        let pending = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 12)
        let noReceipt = try makeRepository(MockHTTPTransport(responses: accessResponses()), profileID: profile); _ = try await noReceipt.access()
        try await noReceipt.restoreAlbumMutation(pending)
        let unknown = try await noReceipt.reviewMutation(operationID: pending.operationID); XCTAssertEqual(unknown.state, .pendingReview)
    }

    func test资料恢复拒绝对象替换错误值账号与损坏阶段() async throws {
        let profile = UUID(), id = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .edit(photos, .description("Expected")), operationID: id, profileID: profile, userID: 12)
        var edit = try XCTUnwrap(saved.photoEditDetails); edit.attempted = [0]; saved.photoEditDetails = edit
        for changedIdentity in [false, true] {
            let responseText = changedIdentity ? itemPage.replacingOccurrences(of: "sample.jpg", with: "other.jpg") : itemPage
            let reader = MockHTTPTransport(responses: accessResponses() + [response(responseText)])
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            do { let result = try await restored.reviewMutation(operationID: id); XCTAssertFalse(changedIdentity); XCTAssertEqual(result.state, .pendingReview) }
            catch let error as AppError { XCTAssertTrue(changedIdentity); XCTAssertEqual(error.category, .conflict) }
        }
        let other = try makeRepository(MockHTTPTransport(responses: accessResponses())); _ = try await other.access()
        do { try await other.restoreAlbumMutation(saved); XCTFail("不得跨连接恢复") } catch { }
        edit.attempted = [1]; saved.photoEditDetails = edit; XCTAssertThrowsError(try saved.reviewMutation())
        edit.attempted = []; edit.rejected = [0]; saved.photoEditDetails = edit; XCTAssertThrowsError(try saved.reviewMutation())
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .edit(photos, .rating(7)), operationID: id, profileID: profile, userID: 12))
    }

    func test资料首次保存失败零写入且同操作编号不能换内容() async throws {
        let profile = UUID(), id = UUID()
        let writer = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let command = SynologyPhotosMutation.edit(photos, .rating(3))
        do {
            _ = try await repository.performRecoverableAlbumMutation(command, operationID: id) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("保存失败不能写")
        } catch { }
        let calls = try await writer.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        try await repository.restoreAlbumMutation(saved)
        let changed = try SynologyPhotosAlbumCheckpoint(mutation: .edit(photos, .rating(4)), operationID: id, profileID: profile, userID: 12)
        do { try await repository.restoreAlbumMutation(changed); XCTFail("同编号不能改意图") } catch { }
    }

    func test标签提交阶段保存失败不写入且不会留永久未知() async throws {
        let capture = PhotosAlbumCheckpointCapture()
        let writer = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)])
        let repository = try makeRepository(writer); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performRecoverableAlbumMutation(.addTags(photos, ids: [8]), operationID: UUID()) { value in
            if value.photoEditDetails?.attempted.isEmpty == false { throw CocoaError(.fileWriteOutOfSpace) }
            capture.append(value)
        }
        XCTAssertEqual(result.state, .rejected); XCTAssertEqual(capture.values.last?.rejected, true)
        let calls = try await writer.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "add_tag" })
    }

    func test相册照片编辑恢复保留贡献者上下文且拒绝提供者变化() async throws {
        let profile = UUID(), id = UUID()
        let original = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
            albumContext: .init(albumID: 3, ownerUserID: 99, providerUserID: 12))
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .edit([original], .rating(4)), operationID: id, profileID: profile, userID: 12)
        var edit = try XCTUnwrap(saved.photoEditDetails); edit.attempted = [0]; saved.photoEditDetails = edit
        for provider in [12, 99] {
            let current = itemPage.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":99"#)
                .replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4,"provider_user_id":\#(provider)"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(current)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
            do { let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(provider, 12); XCTAssertEqual(result.state, .confirmed) }
            catch let error as AppError { XCTAssertEqual(provider, 99); XCTAssertEqual(error.category, .conflict) }
            let calls = try await transport.recordedRequests().map(decode).filter { $0["api"] == "SYNO.Foto.Browse.Item" }
            XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?["album_id"], "3"); XCTAssertEqual(calls.first?["method"], "get")
        }
    }

    func test条件创建回执恢复仅摘要且归一化已知集合不改变未知顺序() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let condition = SynologyPhotoAlbumCondition(fields: ["rating": .array([.integer(3), .integer(5)]),
            "keyword": .array([.string("Private keyword")]), "keyword_policy": .string("and"),
            "future_empty": .array([]), "future_order": .array([.integer(2), .integer(1)])])
        let command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture rule album", condition: condition)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"album":{"id":21}}}"#), response("invalid")])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.createdAlbumID, 21)
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        for value in ["Fixture rule album", "Private keyword", "future_order", "fixture-token"] { XCTAssertFalse(text.contains(value)) }
        try await repository.restoreAlbumMutation(saved)
        let raw = #"{"user_id":12,"item_type":[],"rating":[{"id":5,"name":"Five"},{"id":3,"name":"Three"}],"keyword":["Private keyword"],"keyword_policy":"and","future_empty":[],"future_order":[2,1]}"#
        for wrongOrder in [false, true] {
            let reader = MockHTTPTransport(responses: accessResponses() + [response(conditionAlbum), response(conditionAlbum), conditionReply(wrongOrder ? raw.replacingOccurrences(of: "[2,1]", with: "[1,2]") : raw)])
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
            let reviewed = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(reviewed.state, wrongOrder ? .pendingReview : .confirmed)
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["create", "set_condition", "delete"].contains($0["method"] ?? "") })
        }
    }

    func test条件创建丢回执不按同名搜索且保存失败零写入() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture rule album", condition: .init())
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        let reader = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access()
        try await repository.restoreAlbumMutation(saved)
        let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .pendingReview)
        let reads = try await reader.recordedRequests().map(decode)
        XCTAssertFalse(reads.contains { $0["api"] == "SYNO.Foto.Browse.ConditionAlbum" })
        do {
            _ = try await repository.performRecoverableAlbumMutation(command, operationID: UUID()) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("未知操作不能再创建")
        } catch { }
        let writer = MockHTTPTransport(responses: accessResponses())
        let fresh = try makeRepository(writer); _ = try await fresh.access()
        do {
            _ = try await fresh.performRecoverableAlbumMutation(command, operationID: UUID()) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("恢复记录写入失败不得创建")
        } catch { }
        let writes = try await writer.recordedRequests().map(decode); XCTAssertFalse(writes.contains { $0["method"] == "create" })
    }

    func test条件编辑恢复按规则摘要且拒绝错误来源原目标和账号() async throws {
        let profile = UUID(), id = UUID(), expected = SynologyPhotoAlbumCondition(fields: ["user_id": .integer(0), "item_type": .array([.integer(-2)])])
        let command = SynologyPhotosMutation.setAlbumCondition(id: 21, original: .init(), condition: expected)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        for variant in 0..<4 {
            let raw = variant == 1 ? #"{"user_id":0,"item_type":[-1]}"# : variant == 2 ? #"{"user_id":12,"item_type":[-2]}"# : #"{"user_id":0,"item_type":[-2]}"#
            let album = variant == 3 ? conditionAlbum.replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":99") : conditionAlbum
            let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(album), conditionReply(raw), response(album)])
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
            do {
                let result = try await repository.reviewMutation(operationID: id)
                XCTAssertEqual(result.state, variant == 0 ? .confirmed : .pendingReview)
            } catch { XCTAssertTrue(variant == 2 || variant == 3) }
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "set_condition" })
        }
        let reader = MockHTTPTransport(responses: accessResponses())
        let wrong = try makeRepository(reader); _ = try await wrong.access()
        do { try await wrong.restoreAlbumMutation(saved); XCTFail("错误账号不得恢复") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test条件摘要损坏与不同意图不能恢复到已存在操作() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture", condition: .init())
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var operation = try XCTUnwrap(object["operation"] as? [String: Any]), condition = try XCTUnwrap(operation["condition"] as? [String: Any])
        var details = try XCTUnwrap(condition["_0"] as? [String: Any]); details["fieldsDigest"] = "invalid"; condition["_0"] = details
        operation["condition"] = condition; object["operation"] = operation
        let corrupt = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try corrupt.reviewMutation())
        let reader = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
        let other = try SynologyPhotosAlbumCheckpoint(mutation: .createConditionAlbum(name: "Other", condition: .init()), operationID: id, profileID: profile, userID: 12)
        do { try await repository.restoreAlbumMutation(other); XCTFail("不能覆盖其他意图") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
    }
    func test收集创建恢复只保存摘要且跨实例按回执回读() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", description: "Synthetic collection", folderPath: "/PhotoRequest/Fixture", expiration: 2_000_000_000, sizeLimit: 1_234_567)
        let writer = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(managedFolder),
            response(try requestFixture(settings, list: false)), response("invalid")])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.createPhotoRequest(settings)
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        XCTAssertNil(capture.values.first?.requestDetails?.targetDigest)
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertTrue(try XCTUnwrap(saved.requestDetails).matchesTarget("fixture-request"))
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        for secret in ["Fixture", "Synthetic collection", "/PhotoRequest", "fixture-request", "https://", "fixture-session", "fixture-token"] {
            XCTAssertFalse(text.contains(secret))
        }
        // 同实例的重装配也不把含回执摘要误判为另一操作。
        try await repository.restoreAlbumMutation(saved)
        let reader = MockHTTPTransport(responses: accessResponses() + [response(try requestFixture(settings))])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .confirmed); XCTAssertEqual(reviewed.photoRequest?.id, "fixture-request")
        let requests = try await reader.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["create", "update", "delete"].contains($0["method"] ?? "") })
    }

    func test收集创建丢回执重启不按同名搜索且写前保存失败零写() async throws {
        let profile = UUID(), id = UUID(), settings = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        let command = SynologyPhotosMutation.createPhotoRequest(settings)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        let reader = MockHTTPTransport(responses: accessResponses())
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .pendingReview)
        let requests = try await reader.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.PhotoRequest" })
        let writer = MockHTTPTransport(responses: accessResponses() + [response(managedFolder)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        do {
            _ = try await repository.performRecoverableAlbumMutation(command, operationID: UUID()) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("保存失败不得发送")
        } catch { }
        let writes = try await writer.recordedRequests().map(decode)
        XCTAssertFalse(writes.contains { $0["method"] == "create" })
    }

    func test收集编辑恢复逐字段比较且不会保存目标相册口令() async throws {
        let profile = UUID(), id = UUID()
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", description: "After", folderPath: "/Sample", folderID: 9, albumPassphrase: "synthetic-album-secret", expiration: 2_000_000_000, sizeLimit: 1_234_567)
        let original = SynologyPhotoRequest(id: "synthetic-request-secret", profileID: profile, settings: settings, isFolderValid: true)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .updatePhotoRequest(original: original, settings: settings), operationID: id, profileID: profile, userID: 12)
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        for value in [original.id, settings.albumPassphrase!, settings.subject, settings.description, settings.folderPath] { XCTAssertFalse(text.contains(value)) }
        for change in 0..<5 {
            var actual = settings
            switch change {
            case 1: actual.folderID = 10
            case 2: actual.sizeLimit = 1_234_568
            case 3: actual.albumPassphrase = "another-album"
            case 4: actual.expiration += 1
            default: break
            }
            let reader = MockHTTPTransport(responses: accessResponses() + [response(try requestFixture(actual, id: original.id))])
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
            let result = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, change == 0 ? .confirmed : .pendingReview)
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["create", "update", "delete"].contains($0["method"] ?? "") })
        }
    }

    func test收集删除恢复仅完整列表缺少原标识才结束且拒绝错误账号() async throws {
        let profile = UUID(), id = UUID(), settings = SynologyPhotoRequestSettings(subject: "Fixture", space: .shared, folderPath: "/Sample", folderID: 9)
        let original = SynologyPhotoRequest(id: "fixture-request", profileID: profile, settings: settings, isFolderValid: false)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .deletePhotoRequest(original), operationID: id, profileID: profile, userID: 12)
        for present in [true, false] {
            // 只有共享空间也可以恢复；不能误用个人相册权限。
            let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [response(present ? try requestFixture(settings) : #"{"success":true,"data":{"list":[]}}"#)])
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(saved)
            let result = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, present ? .pendingReview : .confirmed)
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
        let reader = MockHTTPTransport(responses: accessResponses())
        let wrongProfile = try makeRepository(reader); _ = try await wrongProfile.access()
        do { try await wrongProfile.restoreAlbumMutation(saved); XCTFail("不能加载另一账号的记录") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test收集摘要删除恢复不能因目标在后页或分页重复而结束() async throws {
        let profile = UUID(), id = UUID(), settings = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        let original = SynologyPhotoRequest(id: "fixture-request", profileID: profile, settings: settings, isFolderValid: true)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .deletePhotoRequest(original), operationID: id, profileID: profile, userID: 12)
        let entries = (0..<500).map { ["passphrase": "synthetic-page-\($0)", "subject": "Fixture"] }
        let first = String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": entries]]), as: UTF8.self)
        for duplicate in [false, true] {
            let reader = MockHTTPTransport(responses: accessResponses() + [response(first), response(duplicate ? first : try requestFixture(settings))])
            let repository = try makeRepository(reader, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(saved)
            do {
                let result = try await repository.reviewMutation(operationID: id)
                XCTAssertFalse(duplicate); XCTAssertEqual(result.state, .pendingReview)
            } catch { XCTAssertTrue(duplicate) }
            let requests = try await reader.recordedRequests().map(decode).filter { $0["api"] == "SYNO.Foto.PhotoRequest" }
            XCTAssertEqual(requests.map { $0["offset"] }, ["0", "500"])
            XCTAssertTrue(requests.allSatisfy { $0["method"] == "list" })
        }
    }

    func test临时创建回执跨实例恢复原相册且不再创建() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let writer = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            try temporaryAlbumFixture(receipt: true), response("invalid")])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performRecoverableAlbumMutation(.createTemporaryAlbum(name: "Fixture", photos: photos), operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.createdAlbumID, 3)
        let data = try JSONEncoder().encode(saved)
        let reader = MockHTTPTransport(responses: accessResponses() + [try temporaryAlbumFixture(), response(itemPage)])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .confirmed); XCTAssertEqual(reviewed.album?.id, 3)
        let requests = try await reader.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["create", "delete", "copy", "set_shared"].contains($0["method"] ?? "") })
    }

    func test临时副本恢复完整成员依据且内容变化不能确认() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), source = try temporaryAlbumFixture(shared: true)
        let writer = MockHTTPTransport(responses: accessResponses() + [source, source, response(itemPage), source,
            try temporaryAlbumFixture(id: 4, temporary: false, receipt: true), response("invalid")])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        _ = try await repository.performRecoverableAlbumMutation(.copyTemporaryAlbum(id: 3, name: "Fixture", original: original), operationID: id) { capture.append($0) }
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(saved.createdAlbumID, 4); XCTAssertEqual(saved.temporaryMembers?.count, 1)
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        for secret in ["passphrase", "sharing_link", "fixture-session", "fixture-token", "https://"] { XCTAssertFalse(text.contains(secret)) }
        for changed in [false, true] {
            let reader = MockHTTPTransport(responses: accessResponses() + [try temporaryAlbumFixture(id: 4, temporary: false),
                response(changed ? #"{"success":true,"data":{"list":[]}}"# : itemPage)])
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
            let result = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, changed ? .pendingReview : .confirmed)
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["copy", "set_shared", "delete"].contains($0["method"] ?? "") })
        }
    }

    func test临时副本丢失编号恢复不猜同名且清理恢复只查询消失() async throws {
        let profile = UUID(), id = UUID(), original = SynologyPhotoSharingState(access: .disabled, revision: "snapshot", isTemporary: true)
        for copying in [true, false] {
            let command: SynologyPhotosMutation = copying ? .copyTemporaryAlbum(id: 3, name: "Fixture", original: original) : .deleteTemporaryAlbum(id: 3, original: original)
            let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            let reader = MockHTTPTransport(responses: accessResponses() + (copying ? [] : [response(#"{"success":true,"data":{"list":[]}}"#)]))
            let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
            try await restored.restoreAlbumMutation(saved)
            let result = try await restored.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, copying ? .pendingReview : .confirmed)
            let requests = try await reader.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["copy", "set_shared", "delete", "create"].contains($0["method"] ?? "") })
        }
    }

    func test分享恢复保存保护回执但不保存密码链接或成员名称() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), before = memberAlbum()
        let first = MockHTTPTransport(responses: accessResponses() + [response(before), response(before), response(before),
            response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response("invalid")])
        let repository = try makeRepository(first, profileID: profile); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let command = SynologyPhotosMutation.shareAlbum(id: 3, access: .invited, original: original, password: " synthetic-secret ")
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        XCTAssertEqual(capture.values.count, 4)
        XCTAssertFalse(try XCTUnwrap(capture.values.first?.sharingDetails).passwordAcknowledged)
        XCTAssertTrue(try XCTUnwrap(capture.values[1].sharingDetails).passwordAcknowledged)
        XCTAssertFalse(try XCTUnwrap(capture.values[1].sharingDetails).enableAttempted)
        XCTAssertTrue(try XCTUnwrap(capture.values[2].sharingDetails).enableAttempted)
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        for secret in ["synthetic-secret", "fixture-passphrase", "example.invalid", "\"Member\"", "\"Group\"", "fixture-token", "fixture-session"] {
            XCTAssertFalse(text.contains(secret))
        }
        let restoredTransport = MockHTTPTransport(responses: accessResponses() + [response(before)])
        let restored = try makeRepository(restoredTransport, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .confirmed)
        let requests = try await restoredTransport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["update", "set_shared"].contains($0["method"] ?? "") })
    }

    func test分享改密丢回执跨重启不能以原密码保护为真确认() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), before = sharingFixture(shared: false)
        let setup = accessResponses() + [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#)]
        let transport = MockHTTPTransport(steps: setup.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        _ = try await repository.performRecoverableAlbumMutation(.shareAlbum(id: 3, access: .disabled, original: original, password: "new-secret"), operationID: id) { capture.append($0) }
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertFalse(try XCTUnwrap(saved.sharingDetails).passwordAcknowledged)
        let reader = MockHTTPTransport(responses: accessResponses() + [response(before), response(before)])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved); try await restored.restoreAlbumMutation(saved)
        for _ in 0..<2 { let result = try await restored.reviewMutation(operationID: id); XCTAssertEqual(result.state, .pendingReview) }
        let requests = try await reader.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["update", "set_shared"].contains($0["method"] ?? "") })
    }

    func test分享清除密码无回执跨重启可凭明确无密码确认() async throws {
        let profile = UUID(), id = UUID(), before = sharingFixture(shared: false), capture = PhotosAlbumCheckpointCapture()
        let setup = accessResponses() + [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#)]
        let writer = MockHTTPTransport(steps: setup.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(writer, profileID: profile); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        _ = try await repository.performRecoverableAlbumMutation(.shareAlbum(id: 3, access: .disabled, original: original, password: ""), operationID: id) { capture.append($0) }
        let after = before.replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":false"#)
        let reader = MockHTTPTransport(responses: accessResponses() + [response(after)])
        let restored = try makeRepository(reader, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(try XCTUnwrap(capture.values.last))
        let result = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .confirmed)
    }

    func test分享写前保存失败零写且开启前回执保存失败不公开() async throws {
        for failsBeforeWrite in [true, false] {
            let before = sharingFixture(shared: false)
            var replies = accessResponses() + [response(before), response(before), response(before)]
            if !failsBeforeWrite { replies += [response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess)] }
            let writer = MockHTTPTransport(responses: replies)
            let repository = try makeRepository(writer); _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do {
                _ = try await repository.performRecoverableAlbumMutation(.shareAlbum(id: 3, access: .download, original: original, password: "new-secret"), operationID: UUID()) { value in
                    if failsBeforeWrite || value.sharingDetails?.passwordAcknowledged == true { throw CocoaError(.fileWriteOutOfSpace) }
                }
                XCTAssertFalse(failsBeforeWrite)
            } catch { XCTAssertTrue(failsBeforeWrite) }
            let requests = try await writer.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "set_shared" && $0["enabled"] == "true" })
            XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, failsBeforeWrite ? 0 : 1)
        }
    }

    func test相册创建回执可跨实例恢复且只读原编号() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let album = #"{"success":true,"data":{"list":[{"id":31,"name":"Fixture","owner_user_id":12}]}}"#
        let first = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"album":{"id":31,"name":"Fixture","owner_user_id":12}}}"#), response("invalid")])
        let repository = try makeRepository(first, profileID: profile); _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(.createAlbum(name: "Fixture", photos: []), operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        XCTAssertEqual(capture.values.count, 2)
        XCTAssertNil(capture.values.first?.createdAlbumID)
        XCTAssertEqual(capture.values.last?.createdAlbumID, 31)
        let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
        for forbidden in ["fixture-session", "fixture-token", "passphrase", "password", "cookie"] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(forbidden))
        }
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
        let second = MockHTTPTransport(responses: accessResponses() + [response(album), response(#"{"success":true,"data":{"list":[]}}"#)])
        let restored = try makeRepository(second, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved)
        let final = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(final.state, .confirmed); XCTAssertEqual(final.album?.id, 31)
        let calls = try await second.recordedRequests().map(decode)
        XCTAssertFalse(calls.contains { $0["method"] == "create" })
        XCTAssertEqual(calls.filter { $0["api"] == "SYNO.Foto.Browse.Album" }.first?["id"], "[31]")
    }

    func test相册写前保存失败零创建且无回执不按名称追认() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.createAlbum(name: "Fixture", photos: [])
        let first = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(first, profileID: profile); _ = try await repository.access()
        do {
            _ = try await repository.performRecoverableAlbumMutation(command, operationID: id) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("保存失败必须先于创建")
        } catch { }
        let calls = try await first.recordedRequests().map(decode)
        XCTAssertFalse(calls.contains { $0["method"] == "create" })
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        try await repository.restoreAlbumMutation(saved)
        for _ in 0..<2 {
            let result = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, .pendingReview)
        }
        let after = await first.recordedRequests(); XCTAssertEqual(after.count, calls.count)
        for wrong in [try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: UUID(), userID: 12),
                      try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 99)] {
            do { try await repository.restoreAlbumMutation(wrong); XCTFail("不能恢复其他账号") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
    }

    func test无原空间仍保留统一相册能力且不开放原件编辑() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "none", homeEnabled: false))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let features = await repository.managementFeatures(in: .personal)
        XCTAssertTrue(features.contains(.albums)); XCTAssertTrue(features.contains(.sharing))
        XCTAssertFalse(features.contains(.metadata)); XCTAssertFalse(features.contains(.upload))
    }

    func test仅有相册权限的空相册创建改名删除仍沿统一接口及所有者检查() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":31,"name":"Fixture","owner_user_id":12}]}}"#
        let renamed = album.replacingOccurrences(of: "Fixture", with: "Renamed")
        let empty = #"{"success":true,"data":{"list":[]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [
            response(#"{"success":true,"data":{"album":{"id":31}}}"#), response(album), response(empty),
            response(album), response(emptySuccess), response(renamed),
            response(renamed), response(emptySuccess), response(empty)])
        let repository = try makeRepository(transport); let access = try await repository.access()
        XCTAssertTrue(access.spaces.isEmpty)
        for command: SynologyPhotosMutation in [.createAlbum(name: "Fixture", photos: []), .renameAlbum(id: 31, name: "Renamed"), .deleteAlbum(id: 31)] {
            let result = try await repository.performMutation(command, operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
        }
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertFalse(requests.contains { $0["api"]?.contains("FotoTeam") == true })
        XCTAssertEqual(requests.filter { ["create", "set_name", "delete"].contains($0["method"] ?? "") }.count, 3)

        let foreign = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(album.replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":99"))])
        let denied = try makeRepository(foreign); _ = try await denied.access()
        do { try await denied.prepareMutation(.deleteAlbum(id: 31)); XCTFail("不可删除他人的相册") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let deniedRequests = try await foreign.recordedRequests().map(decode)
        XCTAssertFalse(deniedRequests.contains { $0["method"] == "delete" })
    }

    func test上传恢复写前落盘回执先于核对且新实例不重发() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 128).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let profile = UUID(), id = UUID(), capture = PhotosUploadCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(#"{"success":true,"data":{"id":7,"action":"rename"}}"#), response("invalid")])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.upload(file: source, size: 128, modifiedAt: modified, folderID: 9)
        let result = try await repository.performRecoverableUpload(command, operationID: id, progress: { _, _ in }) { try capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let snapshots = capture.values; XCTAssertEqual(snapshots.count, 2); XCTAssertNil(snapshots.first?.itemID); XCTAssertEqual(snapshots.last?.itemID, 7)
        let encoded = try JSONEncoder().encode(XCTUnwrap(snapshots.last))
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["fixture-session", "fixture-token", "passphrase", "sid", source.deletingLastPathComponent().path] { XCTAssertFalse(text.contains(forbidden)) }
        let saved = try JSONDecoder().decode(SynologyPhotosUploadCheckpoint.self, from: encoded)
        let second = MockHTTPTransport(responses: accessResponses() + [response(itemPage)])
        let restored = try makeRepository(second, profileID: profile); _ = try await restored.access()
        try await restored.restoreUploadMutation(saved)
        let final = try await restored.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed); XCTAssertEqual(final.photos.first?.id.unitID, 7)
        _ = try await restored.reviewMutation(operationID: id)
        let uploads = await second.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
        let calls = try await second.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["upload", "create", "add_item"].contains($0["method"] ?? "") })
    }

    func test上传写前保存失败不发送文件而回执保存失败保留待核对() async throws {
        for failOnReceipt in [false, true] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try Data(repeating: 1, count: 128).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
            let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(#"{"success":true,"data":{"id":7,"action":"rename"}}"#)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                let result = try await repository.performRecoverableUpload(.upload(file: source, size: 128, modifiedAt: modified, folderID: 9), operationID: UUID(), progress: { _, _ in }) { checkpoint in
                    if !failOnReceipt || checkpoint.itemID != nil { throw CocoaError(.fileWriteOutOfSpace) }
                }
                XCTAssertTrue(failOnReceipt); XCTAssertEqual(result.state, .pendingReview)
            } catch { XCTAssertFalse(failOnReceipt) }
            let uploads = await transport.recordedUploadBodies(); XCTAssertEqual(uploads.count, failOnReceipt ? 1 : 0)
        }
    }

    func test无回执或错误身份恢复不能重放上传或猜测照片() async throws {
        let profile = UUID(), id = UUID()
        let command = SynologyPhotosMutation.upload(file: URL(fileURLWithPath: "/fixture.jpg"), size: 128, modifiedAt: .distantPast, folderID: 9)
        let saved = try SynologyPhotosUploadCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        try await repository.restoreUploadMutation(saved)
        for _ in 0..<2 { let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .pendingReview) }
        let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(repeated.state, .pendingReview)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        try await repository.forgetUploadMutation(operationID: id)
        do { _ = try await repository.reviewMutation(operationID: id); XCTFail("本机记录已移除") } catch { }
        for other in [try SynologyPhotosUploadCheckpoint(mutation: command, operationID: UUID(), profileID: UUID(), userID: 12),
                      try SynologyPhotosUploadCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 99)] {
            do { try await repository.restoreUploadMutation(other); XCTFail("拒绝不同 NAS 或账号") } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
        XCTAssertThrowsError(try SynologyPhotosUploadCheckpoint(mutation: .deleteAlbum(id: 21), operationID: UUID(), profileID: profile, userID: 12))
    }

    func test相册提供者资料和旋转写原空间接口且沿相册回读() async throws {
        for space in SynologyPhotoSpace.allCases {
            for mode in 0..<7 {
                let profile = UUID(), owner = space == .shared ? 0 : 99
                let before = collaborationPage().replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":\#(owner)"#)
                let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                    width: 100, height: 80, orientation: 1, albumContext: .init(albumID: 21, ownerUserID: owner, providerUserID: 12))
                let commands: [SynologyPhotosMutation] = [.edit([photo], .rating(3)), .edit([photo], .description("Fixture")), .edit([photo], .takenAt(Date(timeIntervalSince1970: 70))), .shiftDates([photo], seconds: 20), .addTags([photo], ids: [3]), .removeTags([photo], ids: [3]), .rotatePhoto(photo)]
                let after: String
                switch mode {
                case 0: after = before.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":3"#)
                case 1: after = before.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"description":"Fixture""#)
                case 2, 3: after = before.replacingOccurrences(of: #""time":50"#, with: #""time":70"#)
                case 4: after = before.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[{"id":3,"name":"Fixture"}]"#)
                case 5: after = before.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[]"#)
                default: after = before.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":8"#).replacingOccurrences(of: #""width":100,"height":80"#, with: #""width":80,"height":100"#)
                }
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [before, emptySuccess, after].map(response))
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let id = UUID(), result = try await repository.performMutation(commands[mode], operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed, "space=\(space), mode=\(mode)")
                _ = try await repository.reviewMutation(operationID: id)
                let calls = try await transport.recordedRequests().map(decode)
                let writes = calls.filter { ["set", "add_tag", "remove_tag"].contains($0["method"] ?? "") }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], space == .shared ? "SYNO.FotoTeam.Browse.Item" : "SYNO.Foto.Browse.Item")
                XCTAssertNil(writes.first?["album_id"])
                XCTAssertTrue(calls.filter { $0["method"] == "get" && $0["api"] == "SYNO.Foto.Browse.Item" }.allSatisfy { $0["album_id"] == "21" })
                XCTAssertFalse(calls.contains { $0["api"]?.contains("Browse.Folder") == true })
            }
        }
    }

    func test混合共享相册资料编辑必须全部由本人提供且标签不混用() async throws {
        for (albumOwner, sharedProvider, allowed) in [(99, 12, true), (99, 88, false), (12, 88, true)] {
            let profile = UUID()
            let personal = collaborationPage()
            let shared = collaborationPage(provider: sharedProvider).replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":0"#).replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
            let photos = [SynologyPhotoSpace.personal, .shared].enumerated().map { index, space in
                SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7 + index), filename: "sample.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                    albumContext: .init(albumID: 21, ownerUserID: space == .personal ? 99 : 0, providerUserID: 12))
            }
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [personal, shared, collaborationAlbum(owner: albumOwner)].map(response))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(.edit(photos, .rating(3))); XCTAssertTrue(allowed) }
            catch { XCTAssertFalse(allowed); XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
            let denied = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(personal)])
            let deniedRepository = try makeRepository(denied, profileID: profile); _ = try await deniedRepository.access()
            do { try await deniedRepository.prepareMutation(.addTags(photos, ids: [3])); XCTFail("标签不能跨来源空间") } catch { }
            let calls = try await denied.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "add_tag" })
        }
    }

    func test相册提供者不能编辑已关闭空间或陈旧身份() async throws {
        for changed in [false, true] {
            let profile = UUID()
            let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: 12))
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: changed) + [response(collaborationPage().replacingOccurrences(of: #""indexed_time":60"#, with: #""indexed_time":61"#))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(.edit([photo], .rating(3))); XCTFail("不能写入") }
            catch let error as AppError { XCTAssertEqual(error.category, changed ? .conflict : .permissionDenied) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
    }

    func test相册提供者手动人脸编辑复用资料角色且不删除原件() async throws {
        for (space, provider, manager, allowed) in [(SynologyPhotoSpace.personal, 12, false, true), (.personal, 99, false, false), (.shared, 12, false, false), (.shared, 99, true, true)] {
            let profile = UUID(), owner = space == .shared ? 0 : 99
            let page = collaborationPage(provider: provider).replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":\#(owner)"#)
            let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: owner, providerUserID: 12))
            let reads = allowed ? [page, manualList([(71, 31, "Person")]), page, emptySuccess, page, manualList([]), page] : [page, collaborationAlbum()]
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: manager ? "management" : "entry", peopleEnabled: true) + reads.map(response))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do {
                let result = try await repository.performMutation(.editPhotoFaces(photo: photo, changes: [.remove(manualRegion(71))]), operationID: UUID()) { _, _ in }
                XCTAssertTrue(allowed); XCTAssertEqual(result.state, .confirmed)
            } catch { XCTAssertFalse(allowed); XCTAssertEqual((error as? AppError)?.category, space == .shared && !manager ? .apiUnavailable : .permissionDenied) }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "delete_face" }.count, allowed ? 1 : 0)
            XCTAssertFalse(calls.contains { $0["method"] == "delete" })
        }
    }

    func test相册编辑角色使用实际提供者和共享管理资格而不扩大原件删除() async throws {
        for (space, provider, manager, allowed) in [(SynologyPhotoSpace.personal, 12, false, true), (.personal, 98, false, false), (.shared, 12, false, false), (.shared, 12, true, true), (.shared, 98, true, true)] {
            for kind in 0..<8 {
                let profile = UUID(), owner = space == .shared ? 0 : 99
                let page = collaborationPage(provider: provider).replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":\#(owner)"#)
                let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo", width: 100, height: 80, orientation: 1,
                    albumContext: .init(albumID: 21, ownerUserID: owner, providerUserID: 12))
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: manager ? "management" : "entry") + [response(page), response(collaborationAlbum())])
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let commands: [SynologyPhotosMutation] = [.edit([photo], .rating(3)), .edit([photo], .description("Fixture")), .shiftDates([photo], seconds: 60), .addTags([photo], ids: [3]), .removeTags([photo], ids: [3]), .edit([photo], .takenAt(Date(timeIntervalSince1970: 70))), .createTag(name: "Fixture", photos: [photo], space: space), .rotatePhoto(photo)]
                do { try await repository.prepareMutation(commands[kind]); XCTAssertTrue(allowed) }
                catch { XCTAssertFalse(allowed); XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
                let calls = try await transport.recordedRequests().map(decode)
                XCTAssertTrue(calls.filter { $0["api"] == "SYNO.Foto.Browse.Item" }.allSatisfy { $0["album_id"] == "21" })
                XCTAssertFalse(calls.contains { ["set", "add_tag", "remove_tag", "delete"].contains($0["method"] ?? "") })
            }
        }
    }

    private func backgroundEntry(id: Int = 42, status: String = "processing", operation: String = "copy", completion: Int = 2,
                                 errors: Int = 0, total: Int = 5, owner: Int = 12, created: Int = 100) -> String {
        "{\"id\":\(id),\"operation\":\"\(operation)\",\"status\":\"\(status)\",\"total\":\(total),\"completion\":\(completion),\"error\":\(errors),\"skip\":0,\"overwrite\":0,\"create_time\":\(created),\"target_folder\":{\"id\":9,\"owner_user_id\":\(owner)}}"
    }
    private func backgroundList(_ entries: [String]) -> DsmHTTPResponse {
        response("{\"success\":true,\"data\":{\"list\":[\(entries.joined(separator: ","))]}}")
    }

    private func frozenFixture(id: Int = 21, frozen: Bool? = true, owner: Int = 12, name: String = "Frozen fixture",
                               condition: String = #"{"user_id":12,"item_type":[],"obsolete_rule":true}"#,
                               unsupported: String = #"{"people":[1],"recently_add":true}"#, conditional: Bool = false) -> DsmHTTPResponse {
        let freeze = frozen.map { #", "freeze_album":\#($0)"# } ?? ""
        return response(#"{"success":true,"data":{"list":[{"id":\#(id),"name":"\#(name)","type":"\#(conditional ? "condition" : "normal")","owner_user_id":\#(owner),"item_count":2,"shared":false\#(freeze),"cant_migrate_condition":\#(unsupported),"additional":{"condition_object":\#(condition)}}]}}"#)
    }

    private var frozenCreated: DsmHTTPResponse { frozenFixture(id: 31, frozen: false, name: "Rebuilt fixture", conditional: true) }
    private var frozenConditionReply: DsmHTTPResponse {
        response(#"{"success":true,"data":{"list":[{"id":31,"additional":{"condition_object":{"user_id":12,"item_type":[]}}}]}}"#)
    }
    private var frozenNewProof: [DsmHTTPResponse] { [frozenCreated, frozenCreated, frozenConditionReply] }

    func test冻结恢复记录仅摘要普通恢复在个人目录关闭时只读核对() async throws {
        let profile = UUID(), id = UUID()
        let reader = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [frozenFixture(condition: #"{"user_id":0}"#)])
        let source = try makeRepository(reader, profileID: profile); _ = try await source.access()
        let original = try await source.frozenAlbum(id: 21)
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .unfreezeAlbum(original), operationID: id, profileID: profile, userID: 12)
        let data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
        for secret in ["Frozen fixture", "people", "recently_add", "obsolete_rule"] { XCTAssertFalse(text.contains(secret)) }
        for (index, final) in [frozenFixture(frozen: false), frozenFixture(frozen: nil), frozenFixture(frozen: false, owner: 99), frozenFixture(frozen: false, name: "Other")].enumerated() {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [final])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
            let result = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, index == 0 ? .confirmed : .pendingReview)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["set_unfreeze", "create", "delete"].contains($0["method"] ?? "") })
        }
    }

    func test冻结重建恢复按实际编号和删除阶段只读且不重放() async throws {
        let profile = UUID(), id = UUID()
        let reader = MockHTTPTransport(responses: accessResponses() + [frozenFixture()])
        let source = try makeRepository(reader, profileID: profile); _ = try await source.access()
        let original = try await source.frozenAlbum(id: 21)
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(original, name: "Rebuilt fixture", condition: try XCTUnwrap(original.rebuildCondition))
        for mode in 0..<5 {
            var saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            saved.createdAlbumID = mode == 0 ? nil : 31
            if var frozen = saved.frozenDetails { frozen.deletionAttempted = mode >= 3; frozen.deletionRejected = mode == 4; saved.frozenDetails = frozen }
            let old = mode == 2 ? response(#"{"success":true,"data":{"list":[]}}"#) : frozenFixture()
            let transport = MockHTTPTransport(responses: accessResponses() + (mode == 0 ? [] : frozenNewProof + [old]))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            try await repository.restoreAlbumMutation(saved)
            let result = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(result.state, mode == 2 ? .confirmed : [1, 4].contains(mode) ? .partial : .pendingReview)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["create", "delete", "set_unfreeze"].contains($0["method"] ?? "") })
            if mode == 0 { XCTAssertFalse(calls.contains { $0["api"] == "SYNO.Foto.Browse.Album" }) }
        }
    }

    func test冻结重建删除前保存失败同实例后续也只能保留两册() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture()] + frozenNewProof + [frozenFixture()])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let original = try await repository.frozenAlbum(id: 21)
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(original, name: "Rebuilt fixture", condition: try XCTUnwrap(original.rebuildCondition))
        let first = try await repository.performRecoverableAlbumMutation(command, operationID: id) {
            if $0.frozenDetails?.deletionAttempted == true { throw CocoaError(.fileWriteOutOfSpace) }
            capture.append($0)
        }
        XCTAssertEqual(first.state, .pendingReview); XCTAssertEqual(capture.values.last?.createdAlbumID, 31)
        XCTAssertEqual(capture.values.last?.frozenDetails?.deletionAttempted, false)
        let second = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(second.state, .partial); XCTAssertEqual(second.album?.id, 31)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "create" }.count, 1); XCTAssertFalse(calls.contains { $0["method"] == "delete" })
    }

    func test冻结重建正常删除保存尝试阶段且明确拒绝可恢复为部分完成() async throws {
        for reject in [false, true] {
            let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture(), response(reject ? #"{"success":false,"error":{"code":105}}"# : emptySuccess), reject ? frozenFixture() : response(#"{"success":true,"data":{"list":[]}}"#)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let original = try await repository.frozenAlbum(id: 21)
            let result = try await repository.performRecoverableAlbumMutation(.rebuildFrozenAlbum(original, name: "Rebuilt fixture", condition: try XCTUnwrap(original.rebuildCondition)), operationID: id) { capture.append($0) }
            XCTAssertEqual(result.state, reject ? .partial : .confirmed)
            XCTAssertEqual(capture.values.last?.frozenDetails?.deletionAttempted, true)
            XCTAssertEqual(capture.values.last?.frozenDetails?.deletionRejected, reject)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "delete" }.count, 1)
        }
    }

    func test冻结摘要不接受错误身份损坏阶段或另一快照() async throws {
        let profile = UUID(), id = UUID()
        let reader = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(name: "Changed")])
        let source = try makeRepository(reader, profileID: profile); _ = try await source.access()
        let original = try await source.frozenAlbum(id: 21), changed = try await source.frozenAlbum(id: 21)
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .unfreezeAlbum(original), operationID: id, profileID: UUID(), userID: 12))
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .unfreezeAlbum(original), operationID: id, profileID: profile, userID: 12)
        try await source.restoreAlbumMutation(saved)
        let other = try SynologyPhotosAlbumCheckpoint(mutation: .unfreezeAlbum(changed), operationID: id, profileID: profile, userID: 12)
        do { try await source.restoreAlbumMutation(other); XCTFail("不能恢复另一快照") } catch { }
        if var frozen = saved.frozenDetails { frozen.deletionRejected = true; saved.frozenDetails = frozen }
        XCTAssertThrowsError(try saved.reviewMutation())
        saved.createdAlbumID = 21; XCTAssertThrowsError(try saved.reviewMutation())
    }

    func test冻结相册独立标记和恢复快照只保留受支持的新条件() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), frozenFixture(), frozenFixture()])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let albums = try await repository.albums(offset: 0, limit: 100)
        XCTAssertEqual(albums.first?.isFrozen, true); XCTAssertEqual(albums.first?.isConditional, false)
        XCTAssertEqual(albums.first?.acceptsManualMembers, false)
        let snapshot = try await repository.frozenAlbum(id: 21)
        XCTAssertEqual(snapshot.rawCondition["obsolete_rule"], .boolean(true))
        XCTAssertNil(snapshot.rebuildCondition?.fields["obsolete_rule"]); XCTAssertTrue(snapshot.canRebuild)
        XCTAssertEqual(Set(snapshot.unsupportedConditions.keys), ["people", "recently_add"])
        let rights = try await repository.albumAccess(id: 21); XCTAssertFalse(rights.canContribute)
        let addable = try await repository.addableAlbums(offset: 0, limit: 100); XCTAssertTrue(addable.isEmpty)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(calls.contains { ["set_unfreeze", "create", "delete"].contains($0["method"] ?? "") })
    }

    func test冻结相册恢复普通相册要求明确解除标记且重复调用不重写() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(emptySuccess), frozenFixture(frozen: nil), frozenFixture(frozen: false)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let command = SynologyPhotosMutation.unfreezeAlbum(snapshot)
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(final.state, .confirmed); XCTAssertEqual(final.album?.acceptsManualMembers, true)
        let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set_unfreeze" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Browse.NormalAlbum")
        XCTAssertEqual(writes.first?["id"], "21"); XCTAssertEqual(writes.first?["version"], "1")
    }

    func test冻结相册普通恢复未知回执后只核对而不重发() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response("invalid"), frozenFixture(frozen: false)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let pending = try await repository.performMutation(.unfreezeAlbum(snapshot), operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set_unfreeze" }.count, 1)
    }

    func test冻结相册旧快照变化和非本人相册不能恢复() async throws {
        for changed in [frozenFixture(owner: 99), frozenFixture(name: "Changed"), frozenFixture(frozen: false), frozenFixture(unsupported: "{}"), frozenFixture(condition: #"{"user_id":12,"item_type":[-1]}"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), changed])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let snapshot = try await repository.frozenAlbum(id: 21)
            do { try await repository.prepareMutation(.unfreezeAlbum(snapshot)); XCTFail("过期确认不能执行") } catch { }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set_unfreeze" })
        }
    }

    func test冻结相册仅共享空条件仍能恢复普通相册但不能重建() async throws {
        let fixture = frozenFixture(condition: #"{"user_id":0}"#)
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [fixture, fixture, response(emptySuccess), frozenFixture(frozen: false)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21); XCTAssertFalse(snapshot.canRebuild)
        let final = try await repository.performMutation(.unfreezeAlbum(snapshot), operationID: UUID()) { _, _ in }
        XCTAssertEqual(final.state, .confirmed)
        let features = await repository.managementFeatures(in: .personal); XCTAssertTrue(features.contains(.frozenAlbums))
    }

    func test冻结相册重建先确认新相册再删除原相册且不复制旧条件和分享() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture(), response(emptySuccess), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition))
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.album?.id, 31)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let calls = try await transport.recordedRequests().map(decode)
        let creates = calls.filter { $0["method"] == "create" }, deletes = calls.filter { $0["method"] == "delete" }
        XCTAssertEqual(creates.count, 1); XCTAssertEqual(deletes.count, 1); XCTAssertEqual(deletes.first?["id"], "[21]")
        XCTAssertEqual(creates.first?["api"], "SYNO.Foto.Browse.ConditionAlbum")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(creates.first?["condition"]).utf8)) as? [String: Any])
        XCTAssertNil(fields["obsolete_rule"]); XCTAssertNil(fields["cant_migrate_condition"])
        XCTAssertFalse(calls.contains { $0["api"]?.contains("Sharing") == true })
        let deleteIndex = try XCTUnwrap(calls.firstIndex { $0["method"] == "delete" })
        XCTAssertTrue(calls[..<deleteIndex].contains { $0["id"] == "[31]" && $0["additional"]?.contains("condition_object") == true })
    }

    func test冻结相册重建创建回执丢失不重建也不删除原相册() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response("invalid")])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition))
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        let second = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview); XCTAssertEqual(second.state, .pendingReview)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "create" }.count, 1); XCTAssertFalse(calls.contains { $0["method"] == "delete" })
    }

    func test冻结相册重建新相册条件不符时保留原相册() async throws {
        let wrong = response(#"{"success":true,"data":{"list":[{"id":31,"additional":{"condition_object":{"user_id":12,"item_type":[-1]}}}]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#), frozenCreated, frozenCreated, wrong])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21)
        let result = try await repository.performMutation(.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition)), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "delete" })
    }

    func test冻结相册重建期间原相册变化保留两册并报告部分完成() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture(name: "Changed")])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21)
        let result = try await repository.performMutation(.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition)), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.album?.id, 31)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "delete" })
    }

    func test冻结相册重建删除回执未知后再次核对不会重删() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture(), response("invalid"), frozenFixture()] + frozenNewProof + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition))
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "create" }.count, 1); XCTAssertEqual(calls.filter { $0["method"] == "delete" }.count, 1)
    }

    func test冻结相册重建删除明确拒绝时保留新册且不重试() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture(), frozenFixture(), response(#"{"success":true,"data":{"album":{"id":31}}}"#)] + frozenNewProof + [frozenFixture(), response(#"{"success":false,"error":{"code":105}}"#), frozenFixture()])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.frozenAlbum(id: 21), id = UUID()
        let result = try await repository.performMutation(.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition)), operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.album?.id, 31)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final, result)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "delete" }.count, 1)
    }

    func test冻结相册在由我共享中仍可管理既有分享和名称() async throws {
        for command in [SynologyPhotosMutation.renameAlbum(id: 21, name: "Changed"), .shareAlbum(id: 21, access: .view)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [frozenFixture()])
            let repository = try makeRepository(transport); _ = try await repository.access()
            try await repository.prepareMutation(command)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["set_name", "set_shared"].contains($0["method"] ?? "") })
        }
    }

    func test后台任务统一读取进度失败取消及未知状态不猜成功() async throws {
        let profile = UUID()
        let entries = [backgroundEntry(status: "done", completion: 5, errors: 2), backgroundEntry(id: 43, status: "done", completion: 2, owner: 0),
                       backgroundEntry(id: 44, status: "future", operation: "future", owner: 99)]
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [backgroundList(entries)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let supported = await repository.managementFeatures(); XCTAssertTrue(supported.contains(.backgroundTasks))
        let result = try await repository.backgroundTasks()
        XCTAssertEqual(result.count, 3); XCTAssertEqual(result[0].profileID, profile)
        XCTAssertEqual(result[0].successfulCount, 3); XCTAssertFalse(result[0].isCancelled); XCTAssertTrue(result[0].canClear)
        XCTAssertTrue(result[1].isCancelled); XCTAssertEqual(result[1].targetSpace, .shared)
        XCTAssertEqual(result[2].status, .unknown); XCTAssertFalse(result[2].canClear); XCTAssertFalse(result[2].canCancel); XCTAssertNil(result[2].targetSpace)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(fields.last?["api"], "SYNO.Foto.BackgroundTask.Info"); XCTAssertEqual(fields.last?["method"], "list_user_task")
        XCTAssertNil(fields.last?["id"])
    }

    func test后台任务拒绝重复编号缺字段和不可能的计数() async throws {
        let valid = backgroundEntry()
        for entries in [[valid, valid], [backgroundEntry(completion: 6)], [backgroundEntry(completion: 2, errors: 3)],
                        [backgroundEntry(total: -1)], [valid.replacingOccurrences(of: "\"completion\":2,", with: "")]] {
            let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList(entries)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.backgroundTasks(); XCTFail("不能猜测有效任务") } catch { }
        }
    }

    func test后台任务取消固定数组编号等待终态且重复操作不再发送() async throws {
        let initial = backgroundEntry(), done = backgroundEntry(status: "done", completion: 3)
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([initial]), backgroundList([initial]), response(emptySuccess),
            backgroundList([backgroundEntry(status: "aborting")]), backgroundList([done])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let listedTasks = try await repository.backgroundTasks(); let task = try XCTUnwrap(listedTasks.first), id = UUID(), command = SynologyPhotosMutation.cancelBackgroundTask(task)
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(final.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode), writes = fields.filter { $0["method"] == "abort_task" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["id"], "[42]")
    }

    func test后台任务取消未知回执只回读且消失后结束核对() async throws {
        let entry = backgroundEntry()
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([entry]), backgroundList([entry]), response("invalid"), backgroundList([entry]), backgroundList([])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let listedTasks = try await repository.backgroundTasks(); let task = try XCTUnwrap(listedTasks.first), id = UUID()
        let first = try await repository.performMutation(.cancelBackgroundTask(task), operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode); XCTAssertEqual(fields.filter { $0["method"] == "abort_task" }.count, 1)
    }

    func test后台任务身份替换或任务已经结束时拒绝取消() async throws {
        for changed in [backgroundEntry(created: 101), backgroundEntry(status: "done"), backgroundEntry(owner: 0)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([backgroundEntry()]), backgroundList([changed])])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let listedTasks = try await repository.backgroundTasks(); let task = try XCTUnwrap(listedTasks.first)
            do { _ = try await repository.performMutation(.cancelBackgroundTask(task), operationID: UUID()) { _, _ in }; XCTFail() } catch { }
            let fields = try await transport.recordedRequests().map(decode); XCTAssertFalse(fields.contains { $0["method"] == "abort_task" })
        }
    }

    func test后台任务跨账号快照不可取消且取消拒绝回执不重试() async throws {
        let task = SynologyPhotoBackgroundTask(profileID: UUID(), userID: 12, id: 42, operation: "copy", status: .processing,
            total: 5, completion: 2, errors: 0, skipped: 0, overwritten: 0, createdAt: 100, targetFolderID: 9, targetOwnerID: 12)
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { try await repository.prepareMutation(.cancelBackgroundTask(task)); XCTFail() } catch { }
        let count = await transport.recordedRequests().count; XCTAssertEqual(count, 4)
        let denied = MockHTTPTransport(responses: accessResponses() + [backgroundList([backgroundEntry()]), backgroundList([backgroundEntry()]), response(#"{"success":false,"error":{"code":105}}"#)])
        let other = try makeRepository(denied); _ = try await other.access()
        let listedTasks = try await other.backgroundTasks(); let original = try XCTUnwrap(listedTasks.first), id = UUID()
        let result = try await other.performMutation(.cancelBackgroundTask(original), operationID: id) { _, _ in }; XCTAssertEqual(result.state, .rejected)
        let repeated = try await other.reviewMutation(operationID: id); XCTAssertEqual(repeated.state, .rejected)
        let fields = try await denied.recordedRequests().map(decode); XCTAssertEqual(fields.filter { $0["method"] == "abort_task" }.count, 1)
    }

    func test后台任务全部清理固定快照且单项使用标量不清理新完成任务() async throws {
        let originals = [backgroundEntry(status: "done"), backgroundEntry(id: 43, status: "done")], new = backgroundEntry(id: 44, status: "done")
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList(originals), backgroundList(originals + [new]), response(emptySuccess), response(emptySuccess), backgroundList([new])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let tasks = try await repository.backgroundTasks()
        let result = try await repository.performMutation(.clearBackgroundTasks(tasks), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
        let fields = try await transport.recordedRequests().map(decode), writes = fields.filter { $0["method"] == "clear_completed_task" }
        XCTAssertEqual(writes.map { $0["id"] }, ["42", "43"])
        XCTAssertFalse(fields.contains { $0["method"] == "delete" })
    }

    func test后台任务批量清理中途未知仅核对已尝试项并保留其余记录() async throws {
        let originals = [backgroundEntry(status: "done"), backgroundEntry(id: 43, status: "done"), backgroundEntry(id: 44, status: "done")]
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList(originals), backgroundList(originals), response(emptySuccess), response("invalid"),
            backgroundList(Array(originals.suffix(2))), backgroundList([originals[2]])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let tasks = try await repository.backgroundTasks(), id = UUID()
        let first = try await repository.performMutation(.clearBackgroundTasks(tasks), operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .partial); XCTAssertEqual(final.completedCount, 2)
        let fields = try await transport.recordedRequests().map(decode), writes = fields.filter { $0["method"] == "clear_completed_task" }
        XCTAssertEqual(writes.map { $0["id"] }, ["42", "43"])
    }

    func test后台任务不能清理在途或未知类型任务() async throws {
        for entry in [backgroundEntry(), backgroundEntry(status: "aborting"), backgroundEntry(status: "done", operation: "future")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([entry])])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let listedTasks = try await repository.backgroundTasks(); let task = try XCTUnwrap(listedTasks.first)
            do { try await repository.prepareMutation(.clearBackgroundTasks([task])); XCTFail() } catch { }
            let fields = try await transport.recordedRequests().map(decode); XCTAssertFalse(fields.contains { $0["method"] == "clear_completed_task" })
        }
    }

    func test后台任务错误详情保留未知原因且编号为标量() async throws {
        let entry = backgroundEntry(status: "done", completion: 5, errors: 3)
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([entry]), backgroundList([entry]),
            response(#"{"success":true,"data":{"list":[{"type":"item","id":7,"reason":"quota_full"},{"type":"folder","id":7,"reason":"not_existed"},{"type":"future","id":9,"reason":"future_reason"}]}}"#),
            response(#"{"success":true,"data":{"list":[{"id":7,"filename":"Fixture.jpg","additional":{"folder":"/Fixture"}}]}}"#),
            response(coverFolder(id: 7, path: "/Fixture/Subfolder"))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let listedTasks = try await repository.backgroundTasks(); let task = try XCTUnwrap(listedTasks.first), result = try await repository.backgroundTaskErrors(task)
        XCTAssertEqual(result.map(\.reason), [.quota, .missing, .unknown]); XCTAssertEqual(Set(result.map(\.id)).count, 3)
        XCTAssertEqual(result[0].name, "Fixture.jpg"); XCTAssertEqual(result[0].folderPath, "/Fixture")
        XCTAssertEqual(result[1].name, "Subfolder"); XCTAssertEqual(result[1].folderPath, "/Fixture")
        let fields = try await transport.recordedRequests().map(decode), detail = fields.first { $0["method"] == "get_error_detail" }
        XCTAssertEqual(detail?["id"], "42")
        let item = fields.first { $0["api"] == "SYNO.Foto.Browse.Item" && $0["method"] == "get" }
        XCTAssertEqual(item?["id"], "[7]"); XCTAssertEqual(item?["additional"], "[\"folder\"]")
    }

    func test后台任务目录取消后只处理部分不能因状态结束误报全部完成() async throws {
        let target = coverFolder(id: 20, path: "/Destination")
        let transport = MockHTTPTransport(responses: accessResponses() +
            [coverFolder(), deletingFolder(), target, folderTransferReceipt(total: 600), folderDeleteStatus(completion: 3), target].map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.performMutation(.copy([], folderID: 20, folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 3)
    }

    func test后台任务取消本App在途复制不覆盖原操作且禁止提前清理证据() async throws {
        let target = managedFolder.replacingOccurrences(of: #""id":9"#, with: #""id":10"#)
        let running = backgroundEntry(completion: 0, total: 1).replacingOccurrences(of: #""id":9"#, with: #""id":10"#)
        let stopped = running.replacingOccurrences(of: "processing", with: "done")
        let pendingStatus = #"{"success":true,"data":{"list":[{"id":42,"status":"processing","completion":0,"error":0,"skip":0,"overwrite":0}]}}"#
        let finalStatus = pendingStatus.replacingOccurrences(of: "processing", with: "done")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(target),
            response(#"{"success":true,"data":{"task_info":{"id":42}}}"#), response(pendingStatus),
            backgroundList([running]), backgroundList([running]), response(emptySuccess), backgroundList([stopped]), backgroundList([stopped]),
            response(finalStatus), backgroundList([stopped]), response(emptySuccess), backgroundList([])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20), moveID = UUID()
        let started = try await repository.performMutation(.copy(page.items, folderID: 10), operationID: moveID) { _, _ in }; XCTAssertEqual(started.state, .pendingReview)
        let listed = try await repository.backgroundTasks(), task = try XCTUnwrap(listed.first)
        let cancelled = try await repository.performMutation(.cancelBackgroundTask(task), operationID: UUID()) { _, _ in }; XCTAssertEqual(cancelled.state, .confirmed)
        let finished = try await repository.backgroundTasks(), done = try XCTUnwrap(finished.first)
        do { try await repository.prepareMutation(.clearBackgroundTasks([done])); XCTFail("不能先清理待核对的原操作证据") } catch { }
        let original = try await repository.reviewMutation(operationID: moveID); XCTAssertEqual(original.state, .partial); XCTAssertEqual(original.completedCount, 0)
        let cleared = try await repository.performMutation(.clearBackgroundTasks([done]), operationID: UUID()) { _, _ in }; XCTAssertEqual(cleared.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(fields.filter { $0["method"] == "copy" }.count, 1)
        XCTAssertEqual(fields.filter { $0["method"] == "abort_task" }.count, 1)
        XCTAssertEqual(fields.filter { $0["method"] == "clear_completed_task" }.count, 1)
    }

    func test后台任务错误名称缺失时保留原因且按编号匹配不依赖返回顺序() async throws {
        let entry = backgroundEntry(status: "done", completion: 5, errors: 3)
        let details = #"{"success":true,"data":{"list":[{"type":"item","id":7,"reason":"quota_full"},{"type":"item","id":8,"reason":"space_full"},{"type":"item","id":9,"reason":"not_existed"}]}}"#
        let names = #"{"success":true,"data":{"list":[{"id":8,"filename":"Second.jpg"},{"id":7,"filename":"First.jpg"}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [backgroundList([entry]), backgroundList([entry]), response(details), response(names)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let listed = try await repository.backgroundTasks(), task = try XCTUnwrap(listed.first)
        let errors = try await repository.backgroundTaskErrors(task)
        XCTAssertEqual(errors.map(\.name), ["First.jpg", "Second.jpg", nil]); XCTAssertEqual(errors.map(\.reason), [.quota, .space, .missing])
    }

    private let memberAdministrator = #"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12}}"#
    private let memberTeam = #"{"success":true,"data":{"enabled":true}}"#
    private let memberRoot = #"{"success":true,"data":{"folder":{"id":1,"name":"/","parent":0}}}"#
    private let memberList = #"{"success":true,"data":[{"type":"user","id":12,"name":"Fixture self","permission":"entry","auto_backup":false},{"type":"group","id":12,"name":"administrators","permission":"management","auto_backup":true},{"type":"user","id":"12","name":"Fixture string","permission":"future-role","auto_backup":true}]}"#

    func test共享成员读取直接数组保留本人编号类型和未知角色() async throws {
        let profile = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(memberTeam), response(memberList)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let state = try await repository.sharedSpaceMembers()
        XCTAssertEqual(state.profileID, profile); XCTAssertEqual(state.administratorID, 12); XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.members.count, 3); XCTAssertEqual(Set(state.members.map(\.id)).count, 3)
        XCTAssertEqual(state.members[0].id.value, .integer(12)); XCTAssertTrue(state.members[0].canEdit)
        XCTAssertTrue(state.members[1].isProtected); XCTAssertFalse(state.members[1].canEdit)
        XCTAssertEqual(state.members[2].id.value, .string("12")); XCTAssertEqual(state.members[2].role, "future-role")
        XCTAssertFalse(state.members[2].canEdit)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(fields.last?["api"], "SYNO.Foto.Setting.TeamSpace")
        XCTAssertEqual(fields.last?["method"], "list_permission"); XCTAssertEqual(fields.last?["version"], "1")
        XCTAssertNil(fields.last?["list"]); XCTAssertFalse(fields.contains { $0["method"]?.hasPrefix("update") == true })
    }

    func test共享成员候选不使用分享过滤参数且保留本人() async throws {
        let candidates = #"{"success":true,"data":{"list":[{"id":12,"type":"user","name":"Fixture self"},{"id":12,"type":"group","name":"Fixture group"},{"id":"12","type":"user","name":"Fixture string"}]}}"#
        var access = accessResponses()
        access[0] = response(#"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12,"uid":12}}"#)
        let transport = MockHTTPTransport(responses: access + [response(memberAdministrator), response(candidates)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.sharedSpaceMemberCandidates()
        XCTAssertEqual(result.count, 3); XCTAssertEqual(result[0].id.value, .integer(12))
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        let fields = try decode(request)
        XCTAssertEqual(fields["api"], "SYNO.Foto.Sharing.Misc"); XCTAssertEqual(fields["method"], "list_user_group")
        XCTAssertEqual(fields["version"], "1"); XCTAssertNil(fields["team_space_sharable_list"])
    }

    func test共享成员候选缺姓名未知身份和重复项不作为可添加对象() async throws {
        for list in [#"[{"id":12,"type":"user"}]"#, #"[{"id":12,"type":"public","name":"Fixture"}]"#,
                     #"[{"id":true,"type":"user","name":"Fixture"}]"#,
                     #"[{"id":12,"type":"user","name":"Fixture"},{"id":12,"type":"user","name":"Fixture"}]"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response("{\"success\":true,\"data\":{\"list\":\(list)}}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.sharedSpaceMemberCandidates(); XCTFail(list) }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test共享成员目录关闭空间不请求目录且错误分页不联网() async throws {
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(#"{"success":true,"data":{"enabled":false}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        for (offset, limit) in [(-1, 200), (0, 0), (0, 201), (Int.max, 1)] {
            do { _ = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: offset, limit: limit); XCTFail() }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        var requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        do { _ = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: 0, limit: 200); XCTFail() }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
    }

    func test共享成员拒绝普通共享管理者和管理员撤权() async throws {
        for operation in 0..<3 {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(#"{"success":true,"data":{"enabled":true,"is_admin":false,"id":12}}"#)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                switch operation {
                case 0: _ = try await repository.sharedSpaceMembers()
                case 1: _ = try await repository.sharedSpaceMemberCandidates()
                default: _ = try await repository.sharedSpaceMemberFolders(for: .init(type: "user", value: .integer(12)), parent: nil, offset: 0, limit: 200)
                }
                XCTFail("普通共享管理角色不能替代DSM管理员")
            } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
        }
    }

    func test共享成员缺字段错误容器和重复身份不可静默变为空列表() async throws {
        for body in [#"{"list":[]}"#, #"[{"type":"user","id":12,"name":"Fixture","permission":"entry"}]"#,
                     #"[{"type":"user","id":12,"name":"Fixture","permission":"entry","auto_backup":"false"}]"#,
                     #"[{"type":"user","id":0,"name":"Fixture","permission":"entry","auto_backup":false}]"#,
                     #"[{"type":"user","id":12,"name":"Fixture","permission":"entry","auto_backup":false},{"type":"user","id":12,"name":"Fixture","permission":"entry","auto_backup":false}]"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(memberTeam), response("{\"success\":true,\"data\":\(body)}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.sharedSpaceMembers(); XCTFail(body) } catch { }
        }
        let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(#"{"success":true,"data":{"enabled":false}}"#), response(#"{"success":true,"data":[]}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let empty = try await repository.sharedSpaceMembers(); XCTAssertFalse(empty.isEnabled); XCTAssertTrue(empty.members.isEmpty)
    }

    func test共享成员草稿保护系统组并按网页联动备份() throws {
        let selfUser = SynologyPhotoShareRecipient(id: .init(type: "user", value: .integer(12)), name: "Fixture self")
        let adminGroup = SynologyPhotoShareRecipient(id: .init(type: "group", value: .integer(12)), name: "administrators")
        let unknownUser = SynologyPhotoShareRecipient(id: .init(type: "user", value: .string("future")), name: "Fixture future")
        let members: [SynologyPhotoSharedMember] = [.init(recipient: selfUser, role: .entry), .init(recipient: adminGroup, role: .management),
            .init(recipient: unknownUser, role: "future-role", autoBackup: false)]
        let state = SynologyPhotoSharedMembers(profileID: UUID(), administratorID: 12, isEnabled: true, members: members)
        var changed = members; changed[0] = members[0].changingRole(to: .management)
        XCTAssertTrue(changed[0].autoBackup); XCTAssertTrue(state.canSave(changed, candidates: []))
        XCTAssertTrue(changed[0].changingRole(to: .entry).autoBackup)
        changed[0].autoBackup = false; XCTAssertFalse(state.canSave(changed, candidates: []))
        XCTAssertEqual(members[1].changingRole(to: .entry), members[1])
        XCTAssertFalse(state.canSave(Array(members.reversed()), candidates: []))
        XCTAssertFalse(state.canSave([members[0], members[2]], candidates: []))
        XCTAssertFalse(state.canSave([members[0], members[1]], candidates: []))
        changed = members; changed[2].role = "entry"; XCTAssertFalse(state.canSave(changed, candidates: []))
        changed = members; changed.removeFirst(); XCTAssertTrue(state.canSave(changed, candidates: []))
        let new = SynologyPhotoShareRecipient(id: .init(type: "user", value: .integer(13)), name: "Fixture new")
        changed = members + [.init(recipient: new, role: .entry)]
        XCTAssertFalse(changed.last!.autoBackup); XCTAssertFalse(state.canSave(changed, candidates: []))
        XCTAssertTrue(state.canSave(changed, candidates: [new]))
        XCTAssertFalse(state.canSave(changed + [changed.last!], candidates: [new]))
        let disabled = SynologyPhotoSharedMembers(profileID: state.profileID, administratorID: 12, isEnabled: false, members: members)
        XCTAssertFalse(disabled.canSave(changed, candidates: [new]))
    }

    private func memberFolderFixture(id: Int = 9, parent: Int = 1, name: String = "/Fixture", privacy: String = "private", permissions: String = "[]") -> String {
        "{\"id\":\(id),\"name\":\"\(name)\",\"parent\":\(parent),\"additional\":{\"sharing_info\":{\"privacy_type\":\"\(privacy)\",\"permission\":\(permissions)}}}"
    }

    func test共享成员目录按真实编号匹配且无需权限项姓名() async throws {
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        let permissions = #"[{"type":"user","id":12,"role":"view"},{"type":"group","id":12,"role":"manage"},{"type":"user","id":"12","role":"upload"}]"#
        let folder = memberFolderFixture(privacy: "public-download", permissions: permissions)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "none") + [response(memberAdministrator), response(memberTeam), response(memberRoot), response("{\"success\":true,\"data\":{\"list\":[\(folder)]}}")])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: 0, limit: 1)
        XCTAssertEqual(page.parentID, 1); XCTAssertNil(page.parent); XCTAssertEqual(page.nextOffset, 1)
        let node = try XCTUnwrap(page.folders.first)
        XCTAssertEqual(node.directRole, "view"); XCTAssertEqual(node.publicRole, .download); XCTAssertEqual(node.effectiveRole, .download)
        XCTAssertEqual(node.folder.space, .shared); XCTAssertEqual(node.depth, 0); XCTAssertTrue(node.canExpand)
        XCTAssertEqual(node.revision.count, 64)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests[6]["api"], "SYNO.FotoTeam.Browse.Folder"); XCTAssertEqual(requests[6]["method"], "get")
        XCTAssertNil(requests[6]["name"]); XCTAssertNil(requests[6]["id"])
        XCTAssertEqual(requests[7]["id"], "1"); XCTAssertEqual(requests[7]["sort_by"], "\"filename\"")
        XCTAssertEqual(requests[7]["sort_direction"], "\"asc\""); XCTAssertEqual(requests[7]["additional"], "[\"sharing_info\"]")
        XCTAssertFalse(requests.contains { $0["method"] == "get_folder_link" })
    }

    func test共享成员目录第二层回读父权限并拒绝跨身份和第三层() async throws {
        let profile = UUID(), member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        let parent = SynologyPhotoMemberFolder(profileID: profile, memberID: member, rootID: 1,
            folder: .init(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared), depth: 0,
            privacy: "private", directRole: "view", revision: "old")
        let reads = [response(memberAdministrator), response(memberTeam), response(memberRoot),
            response("{\"success\":true,\"data\":{\"folder\":\(memberFolderFixture())}}"),
            response("{\"success\":true,\"data\":{\"list\":[\(memberFolderFixture(id: 10, parent: 9, name: "/Fixture/Child"))]}}")]
        let transport = MockHTTPTransport(responses: accessResponses() + reads)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let page = try await repository.sharedSpaceMemberFolders(for: member, parent: parent, offset: 0, limit: 200)
        XCTAssertEqual(page.parentID, 9); XCTAssertNil(page.parent?.directRole); XCTAssertNotEqual(page.parent?.revision, parent.revision)
        XCTAssertNil(page.nextOffset); XCTAssertEqual(page.folders.first?.depth, 1); XCTAssertEqual(page.folders.first?.canExpand, false)
        for (targetMember, targetParent) in [(member, page.folders[0]), (.init(type: "group", value: .integer(12)), parent)] {
            do { _ = try await repository.sharedSpaceMemberFolders(for: targetMember, parent: targetParent, offset: 0, limit: 200); XCTFail() }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        }
        let otherRepository = try makeRepository(transport)
        do { _ = try await otherRepository.sharedSpaceMemberFolders(for: member, parent: parent, offset: 0, limit: 200); XCTFail() }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 9)
    }

    func test共享成员目录缺权限数据错误父目录和重复授权必须报错() async throws {
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        for folder in [#"{"id":9,"name":"/Fixture","parent":1}"#,
                       memberFolderFixture(parent: 20), memberFolderFixture(id: 1),
                       memberFolderFixture(permissions: #"[{"type":"user","id":12}]"#),
                       memberFolderFixture(permissions: #"[{"type":"user","id":12,"role":"view"},{"type":"user","id":12,"role":"manage"}]"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(memberTeam), response(memberRoot), response("{\"success\":true,\"data\":{\"list\":[\(folder)]}}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: 0, limit: 200); XCTFail(folder) }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test共享成员目录未知角色不伪造为无权限且分页空结束() async throws {
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        let folder = memberFolderFixture(permissions: #"[{"type":"user","id":12,"role":"future-role"}]"#)
        let reads = [response(memberAdministrator), response(memberTeam), response(memberRoot)]
        let transport = MockHTTPTransport(responses: accessResponses() + reads + [response("{\"success\":true,\"data\":{\"list\":[\(folder)]}}")]
            + reads + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let first = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: 0, limit: 1)
        XCTAssertEqual(first.folders.first?.directRole, "future-role"); XCTAssertEqual(first.folders.first?.hasKnownPermissions, false)
        let next = try await repository.sharedSpaceMemberFolders(for: member, parent: nil, offset: try XCTUnwrap(first.nextOffset), limit: 1)
        XCTAssertTrue(next.folders.isEmpty); XCTAssertNil(next.nextOffset)
        let requests = await transport.recordedRequests()
        let last = try XCTUnwrap(requests.last); XCTAssertEqual(try decode(last)["offset"], "1")
    }

    func test共享成员在途读取遇到访问刷新丢弃旧结果() async throws {
        let base = MockHTTPTransport(responses: accessResponses() + [response(memberAdministrator), response(memberTeam), response(memberList)] + accessResponses())
        let transport = AlbumReadBarrierTransport(base)
        let repository = try makeRepository(transport); _ = try await repository.access()
        await transport.holdNext(method: "list_permission")
        let read = Task { try await repository.sharedSpaceMembers() }
        await transport.waitUntilHeld(); _ = try await repository.access(); await transport.release()
        do { _ = try await read.value; XCTFail("旧代次不能交付成员快照") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    private func memberState(_ profile: UUID, role: SynologyPhotoSharedMember.Role = .entry) -> SynologyPhotoSharedMembers {
        .init(profileID: profile, administratorID: 12, isEnabled: true, members: [
            .init(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture self"), role: role),
            .init(recipient: .init(id: .init(type: "group", value: .integer(12)), name: "administrators"), role: .management)])
    }

    private func memberStateReads(_ state: SynologyPhotoSharedMembers) throws -> [DsmHTTPResponse] {
        let values = state.members.map { member in SynologyPhotoConditionValue.object([
            "id": member.id.value, "type": .string(member.id.type), "name": .string(member.recipient.name),
            "permission": .string(member.role), "auto_backup": .boolean(member.autoBackup)]) }
        let list = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        return [response(memberAdministrator), response("{\"success\":true,\"data\":{\"enabled\":\(state.isEnabled)}}"), response("{\"success\":true,\"data\":\(list)}")]
    }

    /// 完整两层目录读取，所有路径和身份均为合成fixture。
    private func memberFolderSnapshotReads(parentRole: String?, childRole: String?, privacy: String = "private") -> [DsmHTTPResponse] {
        func permissions(_ role: String?) -> String { role.map { "[{\"type\":\"user\",\"id\":12,\"role\":\"\($0)\"}]" } ?? "[]" }
        let parent = memberFolderFixture(privacy: privacy, permissions: permissions(parentRole))
        let child = memberFolderFixture(id: 10, parent: 9, name: "/Fixture/Child", permissions: permissions(childRole))
        return [response(memberAdministrator), response(memberTeam), response(memberRoot), response("{\"success\":true,\"data\":{\"list\":[\(parent)]}}"),
                response(memberAdministrator), response(memberTeam), response(memberRoot), response("{\"success\":true,\"data\":{\"folder\":\(parent)}}"), response("{\"success\":true,\"data\":{\"list\":[\(child)]}}")]
    }

    func test共享成员保存角色备份差量并自动回读且相同操作不重放() async throws {
        let profile = UUID(), original = memberState(profile)
        var members = original.members; members[0] = members[0].changingRole(to: .management)
        let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        let reads = try memberStateReads(original), final = try memberStateReads(updated) + sharedSettingsResponses(sharedSettingsFixture(profile))
        let transport = MockHTTPTransport(responses: accessResponses() + reads + [response(emptySuccess)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setSharedMembers(original: original, members: members, folderEdits: []), operation = UUID()
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1); XCTAssertEqual(result.sharedMembers, updated)
        XCTAssertEqual(result.sharedSpaceSettings?.role, .management)
        let again = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(again, result)
        let fields = try await transport.recordedRequests().map(decode)
        let writes = fields.filter { $0["method"] == "update_permission" }; XCTAssertEqual(writes.count, 1)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes.first?["list"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0]["id"] as? Int, 12); XCTAssertEqual(list[0]["type"] as? String, "user")
        XCTAssertEqual(list[0]["permission"] as? String, "management"); XCTAssertEqual(list[0]["auto_backup"] as? Bool, true)
        XCTAssertEqual(list[0]["action"] as? String, "update"); XCTAssertNil(list[0]["name"])
    }

    func test共享成员删除保留原角色和备份且不删除受保护群组() async throws {
        let profile = UUID(), original = memberState(profile, role: .management)
        let members = Array(original.members.dropFirst()), updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        let transport = MockHTTPTransport(responses: accessResponses() + (try memberStateReads(original)) + [response(emptySuccess)] + (try memberStateReads(updated)) + (try sharedSettingsResponses(sharedSettingsFixture(profile, role: .none))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: members, folderEdits: []), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.sharedSpaceSettings?.canAccess, false)
        let fields = try await transport.recordedRequests().map(decode)
        let write = try XCTUnwrap(fields.first { $0["method"] == "update_permission" })
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(write["list"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0]["action"] as? String, "delete")
        XCTAssertEqual(list[0]["permission"] as? String, "management"); XCTAssertEqual(list[0]["auto_backup"] as? Bool, true)
        XCTAssertEqual(list[0]["type"] as? String, "user")
    }

    func test共享成员新增必须来自当前候选并保留字符串编号() async throws {
        let profile = UUID(), original = memberState(profile)
        let new = SynologyPhotoShareRecipient(id: .init(type: "user", value: .string("fixture-new")), name: "Fixture new")
        let members = original.members + [.init(recipient: new, role: .management)]
        let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        for available in [true, false] {
            let list = available ? #"[{"id":"fixture-new","type":"user","name":"Fixture new"}]"# : "[]"
            let candidates = [response(memberAdministrator), response("{\"success\":true,\"data\":{\"list\":\(list)}}")]
            let transport = MockHTTPTransport(responses: accessResponses() + (try memberStateReads(original)) + candidates + (available ? [response(emptySuccess)] + (try memberStateReads(updated)) + (try sharedSettingsResponses(sharedSettingsFixture(profile))) : []))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do {
                let result = try await repository.performMutation(.setSharedMembers(original: original, members: members, folderEdits: []), operationID: UUID()) { _, _ in }
                XCTAssertTrue(available); XCTAssertEqual(result.state, .confirmed)
            } catch let error as AppError { XCTAssertFalse(available); XCTAssertEqual(error.category, .permissionDenied) }
            let fields = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(fields.filter { $0["method"] == "update_permission" }.count, available ? 1 : 0)
            if available {
                let body = try XCTUnwrap(fields.first { $0["method"] == "update_permission" }?["list"])
                let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]])
                XCTAssertEqual(list.first?["id"] as? String, "fixture-new")
            }
        }
    }

    func test共享成员未知回执自动回读期间不允许新操作也不重发() async throws {
        let profile = UUID(), original = memberState(profile)
        var members = original.members; members[0].autoBackup = true
        let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        let old = try memberStateReads(original), final = try memberStateReads(updated) + sharedSettingsResponses(sharedSettingsFixture(profile))
        let transport = MockHTTPTransport(responses: accessResponses() + old + [response("invalid")] + old + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let operation = UUID(), command = SynologyPhotosMutation.setSharedMembers(original: original, members: members, folderEdits: [])
        let pending = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail() }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode); XCTAssertEqual(fields.filter { $0["method"] == "update_permission" }.count, 1)
    }

    func test共享成员旧快照保护组重复身份与跨NAS不提交() async throws {
        for mode in ["stale", "protected", "duplicate", "profile"] {
            let profile = UUID(), original = memberState(mode == "profile" ? UUID() : profile)
            var members = original.members; members[0].autoBackup = true
            if mode == "protected" { members.removeLast() }
            if mode == "duplicate" { members.append(members[0]) }
            let current = mode == "stale" ? memberState(profile, role: .management) : original
            let transport = MockHTTPTransport(responses: accessResponses() + (try memberStateReads(current)))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setSharedMembers(original: original, members: members, folderEdits: []), operationID: UUID()) { _, _ in }; XCTFail(mode) }
            catch { }
            let fields = try await transport.recordedRequests().map(decode); XCTAssertFalse(fields.contains { $0["method"] == "update_permission" })
        }
    }

    func test共享成员目录草稿批量是权限层级并保留公开下限() async throws {
        typealias Batch = SynologyPhotoMemberFolderEdit.Batch
        XCTAssertEqual(Batch(action: .checkAll, role: .download).applying(to: "manage"), "manage")
        XCTAssertEqual(Batch(action: .checkAll, role: .download).applying(to: nil), "download")
        XCTAssertEqual(Batch(action: .uncheckAll, role: .upload).applying(to: "manage"), "download")
        XCTAssertEqual(Batch(action: .uncheckAll, role: .upload).applying(to: "view"), "view")
        XCTAssertNil(Batch(action: .uncheckAll, role: .view).applying(to: "manage"))
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        let transport = MockHTTPTransport(responses: accessResponses() + memberFolderSnapshotReads(parentRole: "view", childRole: "manage"))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        XCTAssertEqual(snapshot.count, 2)
        let remove = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, changes: [.init(folderID: 9, role: nil)])
        XCTAssertTrue(remove.canSave); XCTAssertNil(remove.expectedRole(for: snapshot[1]))
        let childOnly = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, changes: [.init(folderID: 9, role: nil), .init(folderID: 10, role: .download)])
        XCTAssertFalse(childOnly.canSave)
        let batch = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download), changes: [.init(folderID: 10, role: .view)])
        XCTAssertTrue(batch.canSave); XCTAssertEqual(batch.expectedRole(for: snapshot[0]), "download"); XCTAssertEqual(batch.expectedRole(for: snapshot[1]), "view")
    }

    func test共享成员保存先批量再单目录且读取全部目录验证结果() async throws {
        let profile = UUID(), original = memberState(profile), member = original.members[0].id
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: "view")
        let finalFolders = memberFolderSnapshotReads(parentRole: "download", childRole: "upload")
        let reads = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + reads + folders + reads + [response(emptySuccess), response(emptySuccess)] + reads + finalFolders + (try sharedSettingsResponses(sharedSettingsFixture(profile))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download), changes: [.init(folderID: 10, role: .upload)])
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: original.members, folderEdits: [edit]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
        let fields = try await transport.recordedRequests().map(decode)
        let writes = fields.filter { $0["api"] == "SYNO.FotoTeam.Sharing.FolderBatchPermission" }
        XCTAssertEqual(writes.map { $0["method"] }, ["update_all_by_member", "update_by_member"])
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes[0]["permission"]).utf8)) as? [String: Any])
        XCTAssertEqual(batch["action"] as? String, "check_all"); XCTAssertEqual(batch["role"] as? String, "download")
        XCTAssertEqual((batch["member"] as? [String: Any])?["id"] as? Int, 12)
        let one = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(writes[1]["permission"]).utf8)) as? [String: Any])
        XCTAssertEqual(one["type"] as? String, "user"); XCTAssertEqual(one["id"] as? Int, 12)
        let list = try XCTUnwrap(one["list"] as? [[String: Any]])
        XCTAssertEqual(list.first?["folder_id"] as? Int, 10); XCTAssertEqual(list.first?["role"] as? String, "upload")
    }

    func test共享成员目录删除不发送role且验证子目录撤权() async throws {
        let profile = UUID(), original = memberState(profile), member = original.members[0].id
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: "manage"), final = memberFolderSnapshotReads(parentRole: nil, childRole: nil)
        let reads = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + reads + folders + reads + [response(emptySuccess)] + reads + final + (try sharedSettingsResponses(sharedSettingsFixture(profile))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, changes: [.init(folderID: 9, role: nil)])
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: original.members, folderEdits: [edit]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode)
        let write = try XCTUnwrap(fields.first { $0["method"] == "update_by_member" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(write["permission"]).utf8)) as? [String: Any])
        let change = try XCTUnwrap((json["list"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["action"] as? String, "delete"); XCTAssertNil(change["role"])
    }

    func test共享成员保存回执丢失只报告已完成成员不补发目录步骤() async throws {
        let profile = UUID(), original = memberState(profile, role: .management), member = original.members[0].id
        var members = original.members; members[0] = members[0].changingRole(to: .entry)
        let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: nil), old = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + old + folders + old + [response("invalid")] + (try memberStateReads(updated)) + (try sharedSettingsResponses(sharedSettingsFixture(profile, role: .entry))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download))
        let operation = UUID(), command = SynologyPhotosMutation.setSharedMembers(original: original, members: members, folderEdits: [edit])
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1); XCTAssertEqual(result.sharedMembers, updated)
        let reviewed = try await repository.reviewMutation(operationID: operation); XCTAssertEqual(reviewed, result)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(fields.filter { $0["method"] == "update_permission" }.count, 1)
        XCTAssertFalse(fields.contains { $0["api"] == "SYNO.FotoTeam.Sharing.FolderBatchPermission" })
    }

    func test共享成员目录部分拒绝仍保留已完成批量结果() async throws {
        let profile = UUID(), original = memberState(profile), member = original.members[0].id
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: "view"), final = memberFolderSnapshotReads(parentRole: "download", childRole: "download")
        let reads = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + reads + folders + reads + [response(emptySuccess), response(#"{"success":false,"error":{"code":105}}"#)] + reads + final + (try sharedSettingsResponses(sharedSettingsFixture(profile))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download), changes: [.init(folderID: 10, role: .upload)])
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: original.members, folderEdits: [edit]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1)
    }

    func test共享成员新增受限成员后继续设置目录并自动核对() async throws {
        let profile = UUID(), desired = memberState(profile), member = desired.members[0].id
        let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: Array(desired.members.dropFirst()))
        let folders = memberFolderSnapshotReads(parentRole: nil, childRole: nil), final = memberFolderSnapshotReads(parentRole: "view", childRole: "view")
        let old = try memberStateReads(original)
        let candidates = [response(memberAdministrator), response(#"{"success":true,"data":{"list":[{"id":12,"type":"user","name":"Fixture self"}]}}"#)]
        let transport = MockHTTPTransport(responses: accessResponses() + folders + old + candidates + folders + old + [response(emptySuccess), response(emptySuccess)] + (try memberStateReads(desired)) + final + (try sharedSettingsResponses(sharedSettingsFixture(profile, role: .entry))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .view))
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: desired.members, folderEdits: [edit]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2); XCTAssertEqual(result.sharedMembers, desired)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(fields.filter { $0["method"]?.hasPrefix("update") == true }.map { $0["method"] }, ["update_permission", "update_all_by_member"])
        let payload = try XCTUnwrap(fields.first { $0["method"] == "update_permission" }?["list"])
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
        XCTAssertEqual(entries.first?["permission"] as? String, "entry"); XCTAssertEqual(entries.first?["auto_backup"] as? Bool, false)
    }

    func test共享成员目录明确失败回执仍自动确认部分应用() async throws {
        let profile = UUID(), original = memberState(profile), member = original.members[0].id
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: "view"), partial = memberFolderSnapshotReads(parentRole: "download", childRole: "view")
        let reads = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + reads + folders + reads + [response(#"{"success":false,"error":{"code":500}}"#)] + reads + partial + (try sharedSettingsResponses(sharedSettingsFixture(profile))))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download))
        let operation = UUID()
        let result = try await repository.performMutation(.setSharedMembers(original: original, members: original.members, folderEdits: [edit]), operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 0)
        let final = try await repository.reviewMutation(operationID: operation); XCTAssertEqual(final, result)
        let fields = try await transport.recordedRequests().map(decode); XCTAssertEqual(fields.filter { $0["method"] == "update_all_by_member" }.count, 1)
    }

    func test共享成员完整目录快照不能只提交已加载一部分() async throws {
        let profile = UUID(), original = memberState(profile), member = original.members[0].id
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: "view"), reads = try memberStateReads(original)
        let transport = MockHTTPTransport(responses: accessResponses() + folders + reads + folders)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let incomplete = SynologyPhotoMemberFolderEdit(memberID: member, original: [snapshot[0]], batch: .init(action: .checkAll, role: .download))
        do { _ = try await repository.performMutation(.setSharedMembers(original: original, members: original.members, folderEdits: [incomplete]), operationID: UUID()) { _, _ in }; XCTFail() }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let fields = try await transport.recordedRequests().map(decode); XCTAssertFalse(fields.contains { $0["method"]?.hasPrefix("update") == true })
    }

    func test共享成员单目录编辑不因其他未知角色被禁用且公开权限无效修改不提交() async throws {
        let member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        for unknown in [false, true] {
            let folders = memberFolderSnapshotReads(parentRole: unknown ? "view" : nil, childRole: unknown ? "future-role" : nil, privacy: unknown ? "private" : "public-download")
            let transport = MockHTTPTransport(responses: accessResponses() + folders)
            let repository = try makeRepository(transport); _ = try await repository.access()
            let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
            let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, changes: [.init(folderID: 9, role: .download)])
            XCTAssertEqual(edit.canSave, unknown)
            if unknown {
                let batch = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download))
                XCTAssertFalse(batch.canSave)
            }
        }
    }

    private let automaticPreviewFixture = #"{"success":true,"data":{"list":[{"unit_id":701,"filename":"Fixture.png","type":0,"need_thumbnail":true,"need_video":false}]}}"#

    private func visiblePreviewPhoto(profile: UUID, space: SynologyPhotoSpace = .personal, type: String = "photo", filename: String = "Fixture.png") -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: 7), filename: filename, sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: type,
              thumbnail: .init(unitID: 701, revision: "fixture"))
    }

    private func visiblePreviewItem(owner: Int = 12, type: String = "photo", filename: String = "Fixture.png", status: String = "ame_defect", codec: String = "h264") -> DsmHTTPResponse {
        response("""
        {"success":true,"data":{"list":[{"id":7,"owner_user_id":\(owner),"filename":"\(filename)","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"\(type)","additional":{"thumbnail":{"unit_id":701,"cache_key":"fixture","xl":"\(status)","sm":"\(status)"},"video_meta":{"video_codec":"\(codec)"},"video_convert_status":"\(status)"}}]}}
        """)
    }

    private func visiblePreviewFolder(download: Bool = true) -> DsmHTTPResponse {
        response("""
        {"success":true,"data":{"folder":{"id":9,"name":"/fixture","parent":1,"additional":{"access_permission":{"view":true,"download":\(download)}}}}}
        """)
    }

    func test可见自动预览共享目录只用下载权限且不扫描全库() async throws {
        let id = UUID(), photo = visiblePreviewPhoto(profile: id, space: .shared)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [visiblePreviewItem(owner: 0), visiblePreviewFolder()])
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let features = await repository.managementFeatures(in: .shared); XCTAssertTrue(features.contains(.automaticPreview))
        let tasks = try await repository.automaticPreviewTasks(for: photo, support: .init(hevc: true, vc1: false, video: true))
        XCTAssertEqual(tasks, [.init(profileID: id, space: .shared, unitID: 701, filename: "Fixture.png", typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)])
        let requests = await transport.recordedRequests(), item = try decode(requests[4]), folder = try decode(requests[5])
        XCTAssertEqual(item["api"], "SYNO.FotoTeam.Browse.Item"); XCTAssertEqual(item["id"], "[7]")
        XCTAssertEqual(folder["api"], "SYNO.FotoTeam.Browse.Folder"); XCTAssertEqual(folder["id"], "9")
        XCTAssertFalse(try requests.map(decode).contains { $0["method"] == "list_convert_needed" })
    }

    func test可见自动预览拒绝他人原件失去下载权限和目标变化() async throws {
        for mode in ["owner", "download", "identity", "profile"] {
            let id = UUID(), space: SynologyPhotoSpace = mode == "download" ? .shared : .personal
            let photo = visiblePreviewPhoto(profile: mode == "profile" ? UUID() : id, space: space,
                                           filename: mode == "identity" ? "Changed.png" : "Fixture.png")
            let reads = mode == "profile" ? [] : [visiblePreviewItem(owner: mode == "download" ? 0 : mode == "owner" ? 99 : 12)] + (mode == "download" ? [visiblePreviewFolder(download: false)] : [])
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + reads)
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            do { _ = try await repository.automaticPreviewTasks(for: photo, support: .init(hevc: true, vc1: false, video: true)); XCTFail(mode) }
            catch let error as AppError { XCTAssertEqual(error.category, mode == "identity" ? .conflict : .permissionDenied) }
            let uploads = await transport.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
        }
    }

    func test可见自动预览仅接缺陷状态并按实际编码能力过滤() async throws {
        for (type, filename, codec, status, hevc, expected) in [
            ("photo", "Fixture.png", "", "ready", true, 0), ("photo", "Fixture.png", "", "broken", true, 0),
            ("photo", "Fixture.heic", "", "ame_defect", false, 0), ("photo", "Fixture.heic", "", "ame_defect", true, 1),
            ("video", "Fixture.mov", "hevc", "ame_defect", false, 0), ("video360", "Fixture.mov", "h264", "ame_defect", false, 1),
            ("video", "Fixture.mov", "vc1", "ame_defect", true, 0)] {
            let id = UUID(), photo = visiblePreviewPhoto(profile: id, type: type, filename: filename)
            let transport = MockHTTPTransport(responses: accessResponses() + [visiblePreviewItem(type: type, filename: filename, status: status, codec: codec)])
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let tasks = try await repository.automaticPreviewTasks(for: photo, support: .init(hevc: hevc, vc1: false, video: true))
            XCTAssertEqual(tasks.count, expected)
            if let task = tasks.first { XCTAssertEqual(task.needsVideo, type.hasPrefix("video")); XCTAssertTrue(task.needsThumbnail) }
        }
    }

    func test可见自动预览格式等级来自实际编码且HEIC保持普通等级() async throws {
        for (type, filename, codec, expected) in [
            ("photo", "Fixture.heic", "", SynologyPhotoAutomaticPreviewPriority.standard),
            ("video", "Fixture.mov", "h264", .standard),
            ("video360", "Fixture.mov", "hevc", .hevcOrLiveVideo),
            ("video", "Fixture.wmv", "vc1", .vc1),
            ("video", "Fixture.wmv", "wmv3", .vc1)
        ] {
            let id = UUID(), photo = visiblePreviewPhoto(profile: id, type: type, filename: filename)
            let transport = MockHTTPTransport(responses: accessResponses() + [visiblePreviewItem(type: type, filename: filename, codec: codec)])
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true)
            _ = try await repository.access()
            let tasks = try await repository.automaticPreviewTasks(for: photo, support: .init(hevc: true, vc1: true, video: true))
            XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.priority, expected)
            let uploads = await transport.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
        }
        let transport = MockHTTPTransport(responses: accessResponses() + [response(automaticPreviewFixture)])
        let repository = try makeRepository(transport, convertedPreview: true); _ = try await repository.access()
        let tasks = try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: true, vc1: true, video: true))
        XCTAssertEqual(tasks.map(\.priority), [.background])
    }

    func test可见自动预览实况照片展开独立照片和视频单元() async throws {
        let id = UUID(), photo = visiblePreviewPhoto(profile: id, type: "live", filename: "Fixture.heic")
        let units = response(#"{"success":true,"data":{"list":[{"id_item":7,"unit":[{"id":701,"live_type":"photo","filename":"Fixture.heic","additional":{"thumbnail":{"unit_id":701,"cache_key":"fixture","xl":"ame_defect","sm":"ame_defect"}}},{"id":702,"live_type":"video","filename":"Fixture.mov","additional":{"thumbnail":{"unit_id":702,"cache_key":"fixture","xl":"ready","sm":"ready"},"video_meta":{"video_codec":"hevc"},"video_convert_status":"ame_defect"}}]}]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [visiblePreviewItem(type: "live", filename: "Fixture.heic"), units])
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let tasks = try await repository.automaticPreviewTasks(for: photo, support: .init(hevc: true, vc1: false, video: true))
        XCTAssertEqual(tasks.map(\.unitID), [701, 702]); XCTAssertEqual(tasks.map(\.needsThumbnail), [true, false]); XCTAssertEqual(tasks.map(\.needsVideo), [false, true])
        XCTAssertEqual(tasks.map(\.priority), [.standard, .hevcOrLiveVideo])
        XCTAssertTrue(tasks.allSatisfy { $0.sourcePhoto == photo })
        let requests = await transport.recordedRequests(), request = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(request["api"], "SYNO.Foto.Browse.Unit"); XCTAssertEqual(request["id_item"], "[7]"); XCTAssertNil(request["id"])
    }

    func test可见自动预览生成上传与核对共用原流程且不会重复提交() async throws {
        let id = UUID(), photo = visiblePreviewPhoto(profile: id, space: .shared)
        let read = [visiblePreviewItem(owner: 0), visiblePreviewFolder()]
        let responses = accessResponses(teamPermission: "entry") + read + read + [DsmHTTPResponse(data: try PhotoPreviewFixture.image(), statusCode: 200)] + read + read + [response(#"{"success":true}"#)] + [visiblePreviewItem(owner: 0, status: "ready"), visiblePreviewFolder()]
        let transport = MockHTTPTransport(responses: responses)
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: .shared, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        let command = SynologyPhotosMutation.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true)), operation = UUID()
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let again = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(again, result)
        let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
        let text = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(text.contains("SYNO.FotoTeam.Upload.ConvertedFile")); XCTAssertTrue(text.contains("\r\n\r\n701\r\n")); XCTAssertFalse(text.contains("item_id"))
        let requests = await transport.recordedRequests()
        let fields = try requests.filter { $0.httpBody != nil }.map(decode)
        XCTAssertFalse(fields.contains { $0["method"] == "list_convert_needed" })
        let download = try XCTUnwrap(requests.first { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "method" && $0.value == "download" }) == true })
        XCTAssertEqual(URLComponents(url: download.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "unit_id" }?.value, "[701]")
    }

    func test可见自动预览原件读取后权限收回不提升文件也不上传() async throws {
        let id = UUID(), photo = visiblePreviewPhoto(profile: id, space: .shared)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [visiblePreviewItem(owner: 0), visiblePreviewFolder(),
            DsmHTTPResponse(data: try PhotoPreviewFixture.image(), statusCode: 200), visiblePreviewItem(owner: 0), visiblePreviewFolder(download: false)])
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: .shared, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        do { try await repository.downloadAutomaticPreviewSource(task, support: .init(hevc: true, vc1: false, video: true), to: output) { _, _ in }; XCTFail("权限收回不能导出") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let bodies = await transport.recordedUploadBodies(); XCTAssertTrue(bodies.isEmpty)
    }

    func test可见自动预览回执未知且权限收回只保留核对不重复上传() async throws {
        let id = UUID(), photo = visiblePreviewPhoto(profile: id, space: .shared)
        let read = [visiblePreviewItem(owner: 0), visiblePreviewFolder()]
        let before = accessResponses(teamPermission: "entry") + read + read + [DsmHTTPResponse(data: try PhotoPreviewFixture.image(), statusCode: 200)] + read + read
        let denied = [visiblePreviewItem(owner: 0, status: "ready"), visiblePreviewFolder(download: false)]
        let transport = MockHTTPTransport(steps: before.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] + (denied + denied).map(MockHTTPTransport.Step.response))
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: .shared, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        let command = SynologyPhotosMutation.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true)), operation = UUID()
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(result.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTFail("失去权限不能核对") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
    }

    func test自动预览设置读取保存只更新开关并自动核对() async throws {
        for initial in [false, true] {
            let original = automaticSettingFixture(initial), updated = automaticSettingFixture(!initial)
            var access = accessResponses(); access[1] = response(original)
            let transport = MockHTTPTransport(responses: access + [response(original), response(emptySuccess), response(updated)])
            let repository = try makeRepository(transport), operation = UUID()
            let state = try await repository.access(); XCTAssertEqual(state.automaticPreviewEnabled, initial)
            let command = SynologyPhotosMutation.setAutomaticPreview(original: initial, enabled: !initial)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            let again = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(again, result)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 7)
            let fields = try decode(calls[5])
            XCTAssertEqual(fields["api"], "SYNO.Foto.Setting.User"); XCTAssertEqual(fields["method"], "set"); XCTAssertEqual(fields["version"], "1")
            XCTAssertEqual(fields["auto_generate_thumbnail"], String(!initial))
            XCTAssertNil(fields["enable_person"]); XCTAssertNil(fields["enable_home_service"])
        }
    }

    func test自动预览设置旧快照及缺字段不得保存() async throws {
        for content in [automaticSettingFixture(true), #"{"success":true,"data":{"enable_home_service":true,"team_space_permission":"none"}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(content)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setAutomaticPreview(original: false, enabled: true), operationID: UUID()) { _, _ in }; XCTFail("旧快照或缺字段不能保存") } catch { }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 5)
            XCTAssertFalse(try calls.contains { try decode($0)["method"] == "set" })
        }
    }

    func test自动预览设置断网只回读不重复保存() async throws {
        let transport = MockHTTPTransport(steps: accessResponses().map(MockHTTPTransport.Step.response)
            + [.response(response(automaticSettingFixture(false))), .urlError(.networkConnectionLost), .response(response(automaticSettingFixture(true)))])
        let repository = try makeRepository(transport), operation = UUID(); _ = try await repository.access()
        let command = SynologyPhotosMutation.setAutomaticPreview(original: false, enabled: true)
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        let verified = try await repository.reviewMutation(operationID: operation); XCTAssertEqual(verified.state, .confirmed)
        let calls = await transport.recordedRequests(); XCTAssertEqual(try calls.filter { try decode($0)["method"] == "set" }.count, 1)
    }

    private func automaticSettingFixture(_ enabled: Bool) -> String {
        "{\"success\":true,\"data\":{\"enable_home_service\":true,\"team_space_permission\":\"none\",\"auto_generate_thumbnail\":\(enabled)}}"
    }

    func test自动预览上传三档图片使用单元及空间身份且同编号不重放() async throws {
        let image = try PhotoPreviewFixture.image()
        for space in SynologyPhotoSpace.allCases {
            let id = UUID(), operation = UUID()
            let transport = MockHTTPTransport(responses: automaticUploadResponses(source: image) + [response(#"{"success":true}"#)])
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let command = automaticCommand(profileID: id, space: space)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
            let reviewed = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(reviewed, result)
            let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
            let body = try XCTUnwrap(bodies.first), text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("\r\n\r\n701\r\n"))
            XCTAssertTrue(text.contains(space == .personal ? "SYNO.Foto.Upload.ConvertedFile" : "SYNO.FotoTeam.Upload.ConvertedFile"))
            XCTAssertFalse(text.contains("item_id")); XCTAssertFalse(text.contains("film_h264"))
            for field in ["thumb_xl", "thumb_sm", "thumb_m"] {
                let data = try AutomaticPreviewEchoTransport.part(field, in: body)
                XCTAssertTrue(data.starts(with: [0xff, 0xd8, 0xff])); _ = try PhotoPreviewFixture.decoded(data)
            }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 10)
            XCTAssertNil(requests.last?.httpBody)
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        }
    }

    func test自动预览图片回执丢失自动回读不重传且旧内容不伪报完成() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try PhotoPreviewFixture.image(), file = directory.appendingPathComponent("fixture")
        try image.write(to: file)
        let expected = try await SynologyPhotosPreviewConverter.convert(file: file, mediaType: "photo")
        let jpeg: (Data) -> DsmHTTPResponse = { DsmHTTPResponse(data: $0, statusCode: 200, headers: ["Content-Type": "image/jpeg"]) }
        let transport = MockHTTPTransport(steps: automaticUploadResponses(source: image).map(MockHTTPTransport.Step.response)
            + [.urlError(.networkConnectionLost), .response(jpeg(Data("stale image".utf8)))]
            + accessResponses().map(MockHTTPTransport.Step.response)
            + [expected.large, expected.small, expected.medium].map { .response(jpeg($0)) })
        let id = UUID(), operation = UUID()
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let command = automaticCommand(profileID: id)
        let pending = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(pending.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("待核对时不能另起上传") } catch { }
        _ = try await repository.access()
        let verified = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(verified.state, .confirmed)
        let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
        let reads = await transport.recordedRequests().filter { $0.url?.path.hasSuffix("Thumbnail/get") == true }
        XCTAssertEqual(reads.count, 4)
        for request in reads {
            let fields = try query(request)
            XCTAssertEqual(fields["id"], "701"); XCTAssertEqual(fields["type"], "\"unit\"")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    func test自动预览视频与组合输出上传真实H264数据且断网回读同一媒体() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.mov")
        try await PhotoPreviewFixture.video(at: source, codec: .jpeg, withAudio: true)
        let media = try Data(contentsOf: source)
        for thumbnail in [false, true] {
            let candidate = automaticPreviewFixture.replacingOccurrences(of: #""type":0"#, with: #""type":1"#)
                .replacingOccurrences(of: "Fixture.png", with: "Fixture.mov")
                .replacingOccurrences(of: #""need_video":false"#, with: #""need_video":true"#)
                .replacingOccurrences(of: #""need_thumbnail":true"#, with: "\"need_thumbnail\":\(thumbnail)")
            let base = MockHTTPTransport(steps: automaticUploadResponses(source: media, candidate: candidate).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
            let transport = AutomaticPreviewEchoTransport(base), id = UUID(), operation = UUID()
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let space: SynologyPhotoSpace = thumbnail ? .shared : .personal
            let command = automaticCommand(profileID: id, space: space, type: 1, thumbnail: thumbnail, video: true)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            let bodies = await base.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
            let body = try XCTUnwrap(bodies.first)
            let film = try AutomaticPreviewEchoTransport.part("film_h264", in: body)
            XCTAssertGreaterThan(film.count, 100)
            XCTAssertNotEqual(film, media)
            XCTAssertEqual(String(decoding: body, as: UTF8.self).contains("thumb_xl"), thumbnail)
            let reads = await transport.mediaRequests()
            XCTAssertEqual(reads.count, thumbnail ? 4 : 1)
            let videoRead = try XCTUnwrap(reads.last), fields = try query(videoRead)
            XCTAssertEqual(fields["api"], thumbnail ? "SYNO.FotoTeam.Streaming" : "SYNO.Foto.Streaming"); XCTAssertEqual(fields["id"], "701")
            XCTAssertEqual(fields["type"], "\"unit\""); XCTAssertEqual(fields["quality"], "\"orig_h264\"")
            let second = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(second, result)
            let after = await base.recordedUploadBodies(); XCTAssertEqual(after.count, 1)
            let output = directory.appendingPathComponent("output-\(thumbnail).mp4")
            try film.write(to: output)
            let signature = try await SynologyPhotosPreviewConverter.videoSignature(file: output)
            XCTAssertEqual(signature.tracks.count, 2)
            XCTAssertEqual(signature.tracks.first?.formats, [0x61766331]) // avc1
            let uploadedFile = await transport.uploadedFile()
            let uploadFile = try XCTUnwrap(uploadedFile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: uploadFile.path))
        }
    }

    func test自动预览转换失败同步状态而候选变化不写入() async throws {
        for changed in [false, true] {
            let id = UUID(), operation = UUID()
            let media = changed ? try PhotoPreviewFixture.image() : Data("invalid media".utf8)
            var responses = automaticUploadResponses(source: media)
            if changed { responses[8] = response(automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Changed.png")) }
            else { responses.append(response(emptySuccess)) }
            let transport = MockHTTPTransport(responses: responses)
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let command = automaticCommand(profileID: id)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .rejected)
            let second = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(second.state, .rejected)
            let bodies = await transport.recordedUploadBodies(); XCTAssertTrue(bodies.isEmpty)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, changed ? 9 : 10)
            let reports = try requests.map { try ($0.httpBody == nil ? query($0) : decode($0)) }.filter { $0["method"] == "set_broken" }
            XCTAssertEqual(reports.count, changed ? 0 : 1)
            XCTAssertEqual(result.automaticPreviewFailureRecorded, !changed)
        }
    }

    func test自动预览失败按空间单元及阶段记录且不能计为生成成功() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("audio.mov")
        try await PhotoPreviewFixture.audioOnly(at: audio)
        let audioData = try Data(contentsOf: audio)
        for space in SynologyPhotoSpace.allCases {
            for video in [false, true] {
                let candidate = video ? automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Fixture.mov")
                    .replacingOccurrences(of: "\"type\":0", with: "\"type\":1")
                    .replacingOccurrences(of: "\"need_thumbnail\":true", with: "\"need_thumbnail\":false")
                    .replacingOccurrences(of: "\"need_video\":false", with: "\"need_video\":true") : automaticPreviewFixture
                let transport = MockHTTPTransport(responses: automaticUploadResponses(source: video ? audioData : Data("invalid media".utf8), candidate: candidate) + [response(emptySuccess)])
                let profile = UUID(), operation = UUID(), repository = try makeRepository(transport, profileID: profile, convertedPreview: true)
                _ = try await repository.access()
                let command = automaticCommand(profileID: profile, space: space, type: video ? 1 : 0, thumbnail: !video, video: video)
                let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
                XCTAssertEqual(result.state, .rejected); XCTAssertTrue(result.automaticPreviewFailureRecorded); XCTAssertEqual(result.completedCount, 0)
                let again = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(again, result)
                let reports = try await transport.recordedRequests().map { try ($0.httpBody == nil ? query($0) : decode($0)) }.filter { $0["method"] == "set_broken" }
                XCTAssertEqual(reports.count, 1); let report = try XCTUnwrap(reports.first)
                XCTAssertEqual(report["api"], space == .personal ? "SYNO.Foto.Upload.ConvertedFile" : "SYNO.FotoTeam.Upload.ConvertedFile")
                XCTAssertEqual(report["version"], "3"); XCTAssertEqual(report["id"], "[701]")
                XCTAssertEqual(report["type"], video ? "[\"video\"]" : "[\"photo\"]")
                let uploads = await transport.recordedUploadBodies(); XCTAssertTrue(uploads.isEmpty)
            }
        }
    }

    func test自动预览失败状态被明确拒绝不伪报已同步也不重发() async throws {
        let profile = UUID(), operation = UUID()
        let transport = MockHTTPTransport(responses: automaticUploadResponses(source: Data("invalid media".utf8)) + [response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport, profileID: profile, convertedPreview: true); _ = try await repository.access()
        let command = automaticCommand(profileID: profile)
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.automaticPreviewFailureRecorded)
        let again = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(again, result)
        let requests = await transport.recordedRequests()
        let calls = try requests.filter { $0.httpBody != nil }.map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "set_broken" }.count, 1)
    }

    func test自动预览失败标记未知回执后台不以批次消失追认且不重发() async throws {
        let profile = UUID(), operation = UUID()
        let transport = MockHTTPTransport(steps: automaticUploadResponses(source: Data("invalid media".utf8)).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport, profileID: profile, convertedPreview: true); _ = try await repository.access()
        let command = automaticCommand(profileID: profile)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertFalse(result.automaticPreviewFailureRecorded)
        }
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("未知标记不得换编号重发") } catch { }
        let calls = try await transport.recordedRequests().map { try ($0.httpBody == nil ? query($0) : decode($0)) }
        XCTAssertEqual(calls.filter { $0["method"] == "set_broken" }.count, 1)
        XCTAssertEqual(calls.count, 10)
    }

    func test可见自动预览失败标记丢失回执只接受实际broken且保留目录权限检查() async throws {
        for space in SynologyPhotoSpace.allCases {
            let profile = UUID(), operation = UUID(), photo = visiblePreviewPhoto(profile: profile, space: space)
            func read(_ status: String = "ame_defect", download: Bool = true) -> [DsmHTTPResponse] {
                [visiblePreviewItem(owner: space == .shared ? 0 : 12, status: status)] + (space == .shared ? [visiblePreviewFolder(download: download)] : [])
            }
            let before = accessResponses(teamPermission: "entry") + read() + read() + [DsmHTTPResponse(data: Data("invalid media".utf8), statusCode: 200)] + read() + read()
            let transport = MockHTTPTransport(steps: before.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] +
                (read("ready") + read("broken")).map(MockHTTPTransport.Step.response))
            let repository = try makeRepository(transport, profileID: profile, convertedPreview: true); _ = try await repository.access()
            let task = SynologyPhotoAutomaticPreviewTask(profileID: profile, space: space, unitID: 701, filename: photo.filename,
                typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
            let first = try await repository.performMutation(.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true)), operationID: operation) { _, _ in }
            XCTAssertEqual(first.state, .pendingReview); XCTAssertFalse(first.automaticPreviewFailureRecorded)
            let next = try await repository.reviewMutation(operationID: operation)
            XCTAssertEqual(next.state, .rejected); XCTAssertTrue(next.automaticPreviewFailureRecorded); XCTAssertEqual(next.completedCount, 0)
            let calls = try await transport.recordedRequests().map { try ($0.httpBody == nil ? query($0) : decode($0)) }
            XCTAssertEqual(calls.filter { $0["method"] == "set_broken" }.count, 1)
            XCTAssertFalse(calls.contains { $0["method"] == "list_convert_needed" })
        }
    }

    func test自动预览失败同步前候选已更新不覆盖已生成预览() async throws {
        let profile = UUID(), photo = visiblePreviewPhoto(profile: profile)
        let read = [visiblePreviewItem()]
        let transport = MockHTTPTransport(responses: accessResponses() + read + read + [DsmHTTPResponse(data: Data("invalid media".utf8), statusCode: 200)] + read + [visiblePreviewItem(status: "ready")])
        let repository = try makeRepository(transport, profileID: profile, convertedPreview: true); _ = try await repository.access()
        let task = SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: 701, filename: photo.filename,
            typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        let result = try await repository.performMutation(.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true)), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.automaticPreviewFailureRecorded)
        let calls = try await transport.recordedRequests().map { try ($0.httpBody == nil ? query($0) : decode($0)) }; XCTAssertFalse(calls.contains { $0["method"] == "set_broken" })
    }

    func test自动预览明确拒绝与回执不明分别保留正确状态() async throws {
        for receipt in [#"{"success":false,"error":{"code":105}}"#, #"{"success":true,"error":{"code":105}}"#, "invalid"] {
            let transport = MockHTTPTransport(responses: automaticUploadResponses(source: try PhotoPreviewFixture.image()) + [response(receipt)])
            let id = UUID(), operation = UUID()
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let command = automaticCommand(profileID: id)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, receipt.contains("false") ? .rejected : .pendingReview)
            _ = try? await repository.performMutation(command, operationID: operation) { _, _ in }
            let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
            let calls = try await transport.recordedRequests().map { try ($0.httpBody == nil ? query($0) : decode($0)) }
            XCTAssertFalse(calls.contains { $0["method"] == "set_broken" })
        }
    }

    func test自动预览无需求错设备或缺少视频能力不能执行() async throws {
        for mode in ["empty", "foreign", "video", "shared", "api"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry"))
            let id = UUID()
            let repository = try makeRepository(transport, profileID: id, convertedPreview: mode != "api"); _ = try await repository.access()
            let task = SynologyPhotoAutomaticPreviewTask(profileID: mode == "foreign" ? UUID() : id,
                space: mode == "shared" ? .shared : .personal, unitID: 701, filename: "Fixture.png", typeCode: mode == "video" ? 1 : 0,
                needsThumbnail: mode != "empty", needsVideo: mode == "video")
            do {
                _ = try await repository.performMutation(.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: false)), operationID: UUID()) { _, _ in }
                XCTFail("无权限、需求或能力不能执行")
            } catch { }
            let bodies = await transport.recordedUploadBodies(); XCTAssertTrue(bodies.isEmpty)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
    }

    func test自动预览取消区分提交前失败与提交后待核对() async throws {
        let image = try PhotoPreviewFixture.image()
        for duringUpload in [false, true] {
            let base = MockHTTPTransport(steps: automaticUploadResponses(source: image).map(MockHTTPTransport.Step.response) + [.urlError(.cancelled)])
            let transport = AutomaticPreviewEchoTransport(base, cancelUpload: duringUpload), id = UUID(), operation = UUID()
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let command = automaticCommand(profileID: id)
            let task = Task {
                try await repository.performMutation(command, operationID: operation) { _, _ in
                    if !duringUpload { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            let result = try await task.value
            XCTAssertEqual(result.state, duringUpload ? .pendingReview : .rejected)
            let uploads = await base.recordedUploadBodies(); XCTAssertEqual(uploads.count, duringUpload ? 1 : 0)
            if duringUpload {
                let verified = try await repository.reviewMutation(operationID: operation)
                XCTAssertEqual(verified.state, .confirmed)
                let after = await base.recordedUploadBodies(); XCTAssertEqual(after.count, 1)
            }
        }
    }

    func test自动预览视频回读旧视频不确认为新结果() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await PhotoPreviewFixture.video(at: source, codec: .jpeg, withAudio: true)
        let media = try Data(contentsOf: source)
        let candidate = automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Fixture.mov")
            .replacingOccurrences(of: #""type":0"#, with: #""type":1"#)
            .replacingOccurrences(of: #""need_video":false"#, with: #""need_video":true"#)
            .replacingOccurrences(of: #""need_thumbnail":true"#, with: #""need_thumbnail":false"#)
        let base = MockHTTPTransport(steps: automaticUploadResponses(source: media, candidate: candidate).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let transport = AutomaticPreviewEchoTransport(base), id = UUID(), operation = UUID()
        await transport.replaceVideoRead(with: media)
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let result = try await repository.performMutation(automaticCommand(profileID: id, type: 1, thumbnail: false, video: true), operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        await transport.replaceVideoRead(with: nil)
        let verified = try await repository.reviewMutation(operationID: operation)
        XCTAssertEqual(verified.state, .confirmed)
        let bodies = await base.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
    }

    private func automaticCommand(profileID: UUID, space: SynologyPhotoSpace = .personal, type: Int = 0,
        thumbnail: Bool = true, video: Bool = false) -> SynologyPhotosMutation {
        .generateAutomaticPreview(.init(profileID: profileID, space: space, unitID: 701, filename: type == 0 ? "Fixture.png" : "Fixture.mov", typeCode: type,
            needsThumbnail: thumbnail, needsVideo: video), support: .init(hevc: true, vc1: false, video: true))
    }

    private func automaticUploadResponses(source: Data, candidate: String? = nil) -> [DsmHTTPResponse] {
        let candidate = response(candidate ?? automaticPreviewFixture)
        return accessResponses(teamPermission: "management") + [candidate, candidate, DsmHTTPResponse(data: source, statusCode: 200), candidate, candidate]
    }

    func test自动预览原件下载使用单元编号并核对前后候选() async throws {
        let data = try PhotoPreviewFixture.image()
        for space in SynologyPhotoSpace.allCases {
            let id = UUID(), output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            let media = DsmHTTPResponse(data: data, statusCode: 200, headers: ["Content-Type": "image/png", "Content-Length": String(data.count)])
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(automaticPreviewFixture), media, response(automaticPreviewFixture)])
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: space, unitID: 701, filename: "Fixture.png", typeCode: 0, needsThumbnail: true, needsVideo: false)
            try await repository.downloadAutomaticPreviewSource(task, support: .init(hevc: true, vc1: false, video: true), to: output) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: output), data)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 7)
            let fields = try query(calls[5])
            XCTAssertEqual(fields["api"], space == .personal ? "SYNO.Foto.Download" : "SYNO.FotoTeam.Download")
            XCTAssertEqual(fields["unit_id"], "[701]"); XCTAssertNil(fields["item_id"])
            XCTAssertEqual(fields["method"], "download"); XCTAssertEqual(fields["version"], "2")
            XCTAssertEqual(try decode(calls[4])["method"], "list_convert_needed")
            XCTAssertEqual(try decode(calls[6])["method"], "list_convert_needed")
        }
    }

    func test自动预览原件下载拒绝错设备及已变化的任务() async throws {
        for foreign in [false, true] {
            let id = UUID(), output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let changed = response(automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Changed.png"))
            let transport = MockHTTPTransport(responses: accessResponses() + (foreign ? [] : [changed]))
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let task = SynologyPhotoAutomaticPreviewTask(profileID: foreign ? UUID() : id, space: .personal, unitID: 701, filename: "Fixture.png", typeCode: 0, needsThumbnail: true, needsVideo: false)
            do {
                try await repository.downloadAutomaticPreviewSource(task, support: .init(hevc: true, vc1: false, video: true), to: output) { _, _ in }
                XCTFail("任务不匹配时不能下载")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, foreign ? 4 : 5)
        }
    }

    func test自动预览下载无效响应及候选消失时保留已有目标() async throws {
        let data = try PhotoPreviewFixture.image()
        for mode in ["missing", "changed", "json", "length", "empty", "http", "existing"] {
            let id = UUID(), output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let old = Data("existing source".utf8); try old.write(to: output)
            defer { try? FileManager.default.removeItem(at: output) }
            let media = DsmHTTPResponse(data: mode == "empty" ? Data() : data, statusCode: mode == "http" ? 404 : 200,
                headers: ["Content-Type": mode == "json" ? "application/json" : "image/png", "Content-Length": String(mode == "length" ? data.count + 1 : data.count)])
            let after = mode == "missing" ? #"{"success":true,"data":{"list":[]}}"# : mode == "changed" ? automaticPreviewFixture.replacingOccurrences(of: "Fixture.png", with: "Changed.png") : automaticPreviewFixture
            let transport = MockHTTPTransport(responses: accessResponses() + [response(automaticPreviewFixture), media, response(after)])
            let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
            let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: .personal, unitID: 701, filename: "Fixture.png", typeCode: 0, needsThumbnail: true, needsVideo: false)
            do {
                try await repository.downloadAutomaticPreviewSource(task, support: .init(hevc: true, vc1: false, video: true), to: output) { _, _ in }
                XCTFail("无效或已存在目标不能被替换")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: output), old)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, ["missing", "changed", "existing"].contains(mode) ? 7 : 6)
        }
    }

    func test自动预览原件下载期间取消不提升半成品() async throws {
        let id = UUID(), output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(automaticPreviewFixture), DsmHTTPResponse(data: try PhotoPreviewFixture.image(), statusCode: 200)])
        let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
        let task = SynologyPhotoAutomaticPreviewTask(profileID: id, space: .personal, unitID: 701, filename: "Fixture.png", typeCode: 0, needsThumbnail: true, needsVideo: false)
        let operation = Task {
            try await repository.downloadAutomaticPreviewSource(task, support: .init(hevc: true, vc1: false, video: true), to: output) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await operation.value; XCTFail("取消必须退出") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 6)
    }

    func test自动预览按转换能力选择官方预设及类型并隔离空间身份() async throws {
        for space in SynologyPhotoSpace.allCases {
            for hevc in [false, true] {
                for vc1 in [false, true] {
                    let id = UUID()
                    let payload = #"{"success":true,"data":{"list":[{"unit_id":701,"filename":"Fixture.heic","type":0,"need_thumbnail":true,"need_video":false},{"unit_id":702,"filename":"Fixture.mov","type":1,"need_thumbnail":0,"need_video":1}]}}"#
                    let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(payload)])
                    let repository = try makeRepository(transport, profileID: id, convertedPreview: true); _ = try await repository.access()
                    let tasks = try await repository.automaticPreviewTasks(in: space, support: .init(hevc: hevc, vc1: vc1, video: true))
                    XCTAssertEqual(tasks.map(\.unitID), [701, 702]); XCTAssertEqual(tasks.map(\.typeCode), [0, 1])
                    XCTAssertTrue(tasks.allSatisfy { $0.profileID == id && $0.space == space })
                    XCTAssertEqual(tasks.map(\.needsThumbnail), [true, false]); XCTAssertEqual(tasks.map(\.needsVideo), [false, true])
                    let requests = try await transport.recordedRequests().map(decode)
                    let fields = try XCTUnwrap(requests.last)
                    XCTAssertEqual(fields["api"], space == .personal ? "SYNO.Foto.Upload.ConvertedFile" : "SYNO.FotoTeam.Upload.ConvertedFile")
                    XCTAssertEqual(fields["method"], "list_convert_needed"); XCTAssertEqual(fields["version"], "3")
                    XCTAssertEqual(fields["preset"], "\"" + (vc1 ? (hevc ? "windows" : "windows2") : "macos") + "\"")
                    XCTAssertEqual(fields["type"], hevc ? #"["photo","video","live_video"]"# : #"["video"]"#)
                    XCTAssertEqual(requests.count, 5, "读取候选不得读取原件、标记重建或上传")
                }
            }
        }
    }

    func test自动预览后台扫描不以目录下载权代替共享管理权() async throws {
        for (space, permission, home) in [(SynologyPhotoSpace.shared, "entry", true), (.shared, "none", true), (.personal, "management", false)] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: permission, homeEnabled: home))
            let repository = try makeRepository(transport, convertedPreview: true); _ = try await repository.access()
            do {
                _ = try await repository.automaticPreviewTasks(in: space, support: .init(hevc: true, vc1: false, video: true))
                XCTFail("没有空间扫描权限不能读取")
            } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
    }

    func test自动预览无可用转换能力不请求候选且缺少API不伪报空队列() async throws {
        let transport = MockHTTPTransport(responses: accessResponses())
        let repository = try makeRepository(transport); _ = try await repository.access()
        let tasks = try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: false, vc1: true, video: false))
        XCTAssertTrue(tasks.isEmpty)
        do {
            _ = try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: true, vc1: false, video: false))
            XCTFail("缺少API必须明确返回不可用")
        } catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test自动预览缺字段重复身份和未知布尔值不当作完成() async throws {
        let valid = #"{"unit_id":701,"filename":"Fixture.heic","type":0,"need_thumbnail":true,"need_video":false}"#
        let invalid = [valid + "," + valid,
            valid.replacingOccurrences(of: "701", with: "0"),
            valid.replacingOccurrences(of: #""filename":"Fixture.heic""#, with: #""filename":"""#),
            valid.replacingOccurrences(of: #""type":0"#, with: #""type":-1"#),
            valid.replacingOccurrences(of: #","need_video":false"#, with: ""),
            valid.replacingOccurrences(of: #""need_thumbnail":true"#, with: #""need_thumbnail":"true""#),
            valid.replacingOccurrences(of: #""need_thumbnail":true"#, with: #""need_thumbnail":2"#),
            valid.replacingOccurrences(of: #""need_video":false"#, with: #""need_video":null"#)]
        for row in invalid {
            let transport = MockHTTPTransport(responses: accessResponses() + [response("{\"success\":true,\"data\":{\"list\":[\(row)]}}")])
            let repository = try makeRepository(transport, convertedPreview: true); _ = try await repository.access()
            do {
                _ = try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: true, vc1: false, video: true))
                XCTFail("无效列表不能返回可处理任务或空队列")
            } catch { }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
        }
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport, convertedPreview: true); _ = try await repository.access()
        let tasks = try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: true, vc1: false, video: true))
        XCTAssertTrue(tasks.isEmpty)
    }

    func test自动预览丢弃重新授权后的迟到列表及取消结果() async throws {
        for revoke in [false, true] {
            let base = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"list":[]}}"#)] + (revoke ? accessResponses(homeEnabled: false) : []))
            let transport = AlbumReadBarrierTransport(base)
            let repository = try makeRepository(transport, convertedPreview: true); _ = try await repository.access()
            await transport.holdNext(method: "list_convert_needed")
            let task = Task { try await repository.automaticPreviewTasks(in: .personal, support: .init(hevc: true, vc1: false, video: true)) }
            await transport.waitUntilHeld()
            if revoke { _ = try await repository.access() } else { task.cancel() }
            await transport.release()
            do { _ = try await task.value; XCTFail("迟到结果不能进入队列") }
            catch is CancellationError { XCTAssertFalse(revoke) }
            catch let error as AppError { XCTAssertTrue(revoke); XCTAssertEqual(error.category, .permissionDenied) }
        }
    }

    func test旋转个人共享全部方向保存回读且同操作不重复写入() async throws {
        for space in SynologyPhotoSpace.allCases {
            for (orientation, expected) in [(1, 8), (2, 5), (3, 6), (4, 7), (5, 4), (6, 1), (7, 2), (8, 3)] {
                let before = itemPage.replacingOccurrences(of: #""orientation":1"#, with: "\"orientation\":\(orientation),\"orientation_original\":1")
                let after = before.replacingOccurrences(of: "\"orientation\":\(orientation)", with: "\"orientation\":\(expected)")
                    .replacingOccurrences(of: #""width":100,"height":80"#, with: #""width":80,"height":100"#)
                    .replacingOccurrences(of: "fixture-revision", with: "rotated-revision")
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: space == .personal) + [before, before, managedFolder, emptySuccess, after].map(response))
                let repository = try makeRepository(transport); _ = try await repository.access()
                let page = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20)
                let command = SynologyPhotosMutation.rotatePhoto(try XCTUnwrap(page.items.first)), id = UUID()
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
                XCTAssertEqual(result.photos.first?.orientation, expected); XCTAssertEqual(result.photos.first?.originalOrientation, 1)
                XCTAssertEqual(result.photos.first?.width, 80); XCTAssertEqual(result.photos.first?.thumbnail?.revision, "rotated-revision")
                _ = try await repository.performMutation(command, operationID: id) { _, _ in }
                let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["version"], "2")
                XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.Browse.Item" : "SYNO.FotoTeam.Browse.Item")
                XCTAssertEqual(writes.first?["id"], "[7]"); XCTAssertEqual(writes.first?["rotate_action"], #""counter_clockwise""#)
            }
        }
    }

    func test旋转丢回执只读核对旧方向和错误尺寸不能误报成功() async throws {
        let after = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":8"#)
        let confirmed = after.replacingOccurrences(of: #""width":100,"height":80"#, with: #""width":80,"height":100"#)
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)]).map(MockHTTPTransport.Step.response) +
            [.urlError(.networkConnectionLost), .response(response(itemPage)), .response(response(after)), .response(response(confirmed))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let command = SynologyPhotosMutation.rotatePhoto(try XCTUnwrap(page.items.first)), id = UUID()
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(initial.state, .pendingReview)
        let stale = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(stale.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("未知结果不能通过新操作再次旋转") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let wrongSize = try await repository.reviewMutation(operationID: id); XCTAssertEqual(wrongSize.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
    }

    func test旋转拒绝旧快照或无管理权限且不提交() async throws {
        for stale in [true, false] {
            let current = stale ? itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":8"#) : itemPage
            let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [itemPage, current, folder].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            do { _ = try await repository.performMutation(.rotatePhoto(XCTUnwrap(page.items.first)), operationID: UUID()) { _, _ in }; XCTFail("不得绕过快照和权限") }
            catch let error as AppError { XCTAssertEqual(error.category, stale ? .conflict : .permissionDenied) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "set" })
        }
    }

    func test旋转仅允许官方支持媒体且失败回执不报成功() async throws {
        for (type, name, orientation) in [("video", "sample.mov", 1), ("photo360", "sample.jpg", 1), ("video360", "sample.mov", 1), ("photo", "sample.GIF", 1), ("photo", "sample.webp", 1), ("photo", "sample.jpg", 0)] {
            let before = itemPage.replacingOccurrences(of: #""type":"photo""#, with: "\"type\":\"\(type)\"").replacingOccurrences(of: "sample.jpg", with: name).replacingOccurrences(of: #""orientation":1"#, with: "\"orientation\":\(orientation)")
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let photo = try XCTUnwrap(page.items.first); XCTAssertFalse(photo.supportsRotation)
            do { try await repository.prepareMutation(.rotatePhoto(photo)); XCTFail("不支持的媒体不能旋转") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        for rejection in [#"{"success":false,"error":{"code":105}}"#, #"{"success":true,"data":{"error_list":[{"id":7}]}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [itemPage, itemPage, managedFolder, rejection].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.rotatePhoto(XCTUnwrap(page.items.first)), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .rejected)
        }
    }

    private func permissionFolder(shared: Bool = true, privacy: String = "private", link: String = "https://example.invalid/folder", members: String = "[]", path: String = "/Fixture", parent: Int = 1) -> String {
        "{\"success\":true,\"data\":{\"folder\":{\"id\":9,\"name\":\"\(path)\",\"parent\":\(parent),\"shared\":\(shared),\"additional\":{\"sharing_info\":{\"privacy_type\":\"\(privacy)\",\"sharing_link\":\"\(link)\",\"enable_password\":true,\"permission\":\(members)}}}}}"
    }
    private let permissionParent = #"{"success":true,"data":{"folder":{"id":1,"name":"/","parent":0,"shared":false}}}"#
    private let permissionConfig = #"{"success":true,"data":{"set_to_subfolder":true}}"#
    private var permissionTarget: SynologyPhotoCollection { .init(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared) }

    func test共享目录权限只读加载现状保留成员类型和未知角色() async throws {
        let members = #"[{"id":20,"type":"user","name":"Fixture user","role":"manage"},{"id":"20","type":"group","name":"Fixture group","role":"future-role"}]"#
        let payload = permissionFolder(members: members)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [payload, permissionConfig, permissionParent, payload, permissionConfig, permissionParent].map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let state = try await repository.folderSharing(permissionTarget)
        XCTAssertEqual(state.access, .invited); XCTAssertEqual(state.members?.count, 2); XCTAssertEqual(state.members?.map(\.role), ["manage", "future-role"])
        XCTAssertEqual(state.members?.first?.id.value, .integer(20)); XCTAssertEqual(state.members?.last?.id.value, .string("20"))
        XCTAssertTrue(state.appliesToSubfolders); XCTAssertFalse(state.parentIsShared); XCTAssertFalse(state.inheritsManagementOnly)
        XCTAssertEqual(state.hasPassword, true); XCTAssertEqual(state.url.absoluteString, "https://example.invalid/folder")
        let repeated = try await repository.folderSharing(permissionTarget); XCTAssertEqual(state.revision, repeated.revision)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertTrue(requests.dropFirst(4).allSatisfy { ["get", "get_config"].contains($0["method"] ?? "") })
        XCTAssertTrue(requests.dropFirst(4).allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
    }

    func test未共享目录读取链接不创建分享且父目录权限变化进入摘要() async throws {
        let original = permissionFolder(shared: false, link: "", path: "/Parent/Fixture", parent: 8)
        let link = #"{"success":true,"data":{"folder_link":"https://example.invalid/folder"}}"#
        let parent = #"{"success":true,"data":{"folder":{"id":8,"name":"/Parent","parent":1,"shared":false}}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [original, link, permissionConfig, parent, original, link, permissionConfig, parent.replacingOccurrences(of: #""shared":false"#, with: #""shared":true"#)].map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 8, path: "/Parent/Fixture", space: .shared)
        let state = try await repository.folderSharing(folder); XCTAssertEqual(state.access, .management); XCTAssertTrue(state.inheritsManagementOnly)
        let changed = try await repository.folderSharing(folder); XCTAssertNotEqual(state.revision, changed.revision); XCTAssertFalse(changed.inheritsManagementOnly)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "get_folder_link" }.count, 2)
        XCTAssertFalse(requests.contains { ["update", "set_shared", "set_config"].contains($0["method"] ?? "") })
    }

    func test目录权限缺成员保留未知且坏链接未知模式与父身份拒绝() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [permissionFolder(members: "null"), permissionConfig, permissionParent].map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let state = try await repository.folderSharing(permissionTarget); XCTAssertNil(state.members)
        for payload in [permissionFolder(link: "javascript:fixture"), permissionFolder(privacy: "public-upload"), permissionFolder(shared: true, link: ""), permissionFolder(path: "/Renamed")] {
            let failing = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [payload, permissionConfig, permissionParent].map(response))
            let target = try makeRepository(failing); _ = try await target.access()
            do { _ = try await target.folderSharing(permissionTarget); XCTFail("不能把未知状态显示为已关闭") } catch { }
        }
        let mismatch = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [permissionFolder(), permissionConfig, permissionParent.replacingOccurrences(of: #""id":1"#, with: #""id":2"#)].map(response))
        let target = try makeRepository(mismatch); _ = try await target.access()
        do { _ = try await target.folderSharing(permissionTarget); XCTFail("父目录身份不符") } catch { }
    }

    func test目录权限限制共享完整权限和前两层且候选走共享列表() async throws {
        for role in ["entry", "none"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: role)), repository = try makeRepository(transport)
            _ = try await repository.access()
            do { _ = try await repository.folderSharing(permissionTarget); XCTFail("没有共享完整权限") } catch { }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(#"{"success":true,"data":{"list":[{"id":20,"type":"group","name":"Fixture group"}]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        for folder in [SynologyPhotoCollection(id: 1, name: "Root", path: "/", space: .shared), .init(id: 9, name: "C", path: "/A/B/C", space: .shared), .init(id: 9, name: "Fixture", path: "/Fixture", space: .personal)] {
            do { _ = try await repository.folderSharing(folder); XCTFail("目录范围不符") } catch { }
        }
        let recipients = try await repository.folderSharingRecipients(); XCTAssertEqual(recipients.count, 1)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.last?["api"], "SYNO.Foto.Sharing.Misc"); XCTAssertEqual(requests.last?["team_space_sharable_list"], "true")
    }


    func test目录权限保存扁平成员管理角色密码与默认选项且同操作不重发() async throws {
        let old = #"[{"id":20,"type":"user","name":"Fixture user","role":"view"},{"id":"20","type":"group","name":"Fixture group","role":"download"}]"#
        let changed = #"[{"id":20,"type":"user","name":"Fixture user","role":"manage"},{"id":21,"type":"group","name":"New fixture","role":"upload"}]"#
        let baseline = [permissionFolder(members: old), permissionConfig, permissionParent]
        let candidate = #"{"success":true,"data":{"list":[{"id":21,"type":"group","name":"New fixture"}]}}"#
        let after = [permissionFolder(privacy: "public-download", members: changed), permissionConfig, permissionParent]
        let configFalse = #"{"success":true,"data":{"set_to_subfolder":false}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) +
            (baseline + baseline + [candidate, emptySuccess, emptySuccess, after[0], configFalse, after[2]]).map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.folderSharing(permissionTarget)
        let desired = [SynologyPhotoShareGrant(recipient: original.members![0].recipient, role: "manage"),
            .init(recipient: .init(id: .init(type: "group", value: .integer(21)), name: "New fixture"), role: "upload")]
        let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .download, members: desired, password: "fixture-password", appliesToSubfolders: false)
        XCTAssertEqual(command.space, .shared); XCTAssertEqual(command.feature, .folderSharing)
        let operation = UUID(), result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.folder?.id, 9)
        let repeated = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(repeated, result)
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["method"] == "update" }; XCTAssertEqual(writes.count, 1)
        let write = try XCTUnwrap(writes.first); XCTAssertEqual(write["api"], "SYNO.FotoTeam.Sharing.FolderPermission")
        XCTAssertEqual(write["folder_id"], "9"); XCTAssertEqual(write["privacy_type"], #""public-download""#)
        XCTAssertEqual(write["password"], #""fixture-password""#); XCTAssertEqual(write["set_to_subfolder"], "false")
        let permission = try XCTUnwrap(write["permission"])
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(permission.utf8)) as? [[String: Any]])
        XCTAssertEqual(fields.count, 3); XCTAssertTrue(fields.allSatisfy { $0["member"] == nil && $0["auto_backup"] == nil })
        XCTAssertEqual(fields[0]["action"] as? String, "delete"); XCTAssertEqual(fields[0]["id"] as? String, "20"); XCTAssertEqual(fields[0]["role"] as? String, "download")
        XCTAssertEqual(fields[1]["role"] as? String, "manage"); XCTAssertEqual(fields[2]["role"] as? String, "upload")
        XCTAssertEqual(requests.filter { $0["method"] == "set_config" }.count, 1)
    }

    func test目录四种访问范围回读确认并保留未修改成员密码() async throws {
        for access in SynologyPhotoFolderSharingState.Access.allCases {
            let baseline = [permissionFolder(), permissionConfig, permissionParent]
            let after = [permissionFolder(shared: access != .management, privacy: access.rawValue), permissionConfig, permissionParent]
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + baseline + [emptySuccess] + after).map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(permissionTarget)
            let result = try await repository.performMutation(.setFolderSharing(original: original, access: access, members: nil, password: nil, appliesToSubfolders: true), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            let requests = try await transport.recordedRequests().map(decode), write = try XCTUnwrap(requests.first { $0["method"] == "update" })
            XCTAssertNil(write["permission"]); XCTAssertNil(write["password"]); XCTAssertFalse(requests.contains { $0["method"] == "set_config" })
        }
    }

    func test目录权限快照变化或父目录受限及第二层配置改动不写入() async throws {
        for scenario in ["changed", "parent", "second-level"] {
            let nested = scenario != "changed", path = nested ? "/Parent/Fixture" : "/Fixture", parentID = nested ? 8 : 1
            let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: parentID, path: path, space: .shared)
            let parent = nested ? #"{"success":true,"data":{"folder":{"id":8,"name":"/Parent","parent":1,"shared":SHARED}}}"#.replacingOccurrences(of: "SHARED", with: scenario == "parent" ? "false" : "true") : permissionParent
            let payload = permissionFolder(path: path, parent: parentID), baseline = [payload, permissionConfig, parent]
            let current = scenario == "changed" ? payload.replacingOccurrences(of: "private", with: "public-view") : payload
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + [current, permissionConfig, parent]).map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(folder)
            do {
                _ = try await repository.performMutation(.setFolderSharing(original: original, access: .download, members: nil, password: nil, appliesToSubfolders: scenario != "second-level"), operationID: UUID()) { _, _ in }
                XCTFail("身份或父目录条件不满足时不能保存")
            } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "update" })
        }
    }

    func test目录权限丢失回执只读核对且子目录和新密码不凭旧标志确认() async throws {
        for scenario in ["scope", "password", "subfolders"] {
            let apply = scenario == "subfolders", password: String? = scenario == "password" ? "fixture-new" : nil
            let config = apply ? permissionConfig : #"{"success":true,"data":{"set_to_subfolder":false}}"#
            let baseline = [permissionFolder(), config, permissionParent]
            let after = [permissionFolder(privacy: "public-view"), config, permissionParent]
            let steps = (accessResponses(teamPermission: "management") + (baseline + baseline).map(response)).map(MockHTTPTransport.Step.response) +
                [.urlError(.timedOut)] + (after + after).map { MockHTTPTransport.Step.response(response($0)) }
            let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(permissionTarget), id = UUID()
            let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .view, members: nil, password: password, appliesToSubfolders: apply)
            let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
            let reviewed = try await repository.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, scenario == "scope" ? .confirmed : .pendingReview)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, 1)
        }
    }

    func test目录权限成功但默认选项保存失败返回部分完成() async throws {
        let baseline = [permissionFolder(), permissionConfig, permissionParent]
        let after = [permissionFolder(privacy: "public-view"), permissionConfig, permissionParent]
        let steps = (accessResponses(teamPermission: "management") + (baseline + baseline + [emptySuccess]).map(response)).map(MockHTTPTransport.Step.response) +
            [.urlError(.timedOut)] + after.map { MockHTTPTransport.Step.response(response($0)) }
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.folderSharing(permissionTarget)
        let result = try await repository.performMutation(.setFolderSharing(original: original, access: .view, members: nil, password: nil, appliesToSubfolders: false), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.folder?.id, 9)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, 1)
    }

    func test目录权限未知成员不可覆盖且非法角色或不在候选的新成员拒绝() async throws {
        for scenario in ["unknown", "role", "candidate"] {
            let baseline = [permissionFolder(members: scenario == "unknown" ? "null" : "[]"), permissionConfig, permissionParent]
            let candidate = #"{"success":true,"data":{"list":[]}}"#
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + baseline + [candidate]).map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(permissionTarget)
            let member = SynologyPhotoShareGrant(recipient: .init(id: .init(type: "user", value: .integer(20)), name: "Fixture"), role: scenario == "role" ? "admin" : "manage")
            do {
                _ = try await repository.performMutation(.setFolderSharing(original: original, access: .invited, members: [member], password: nil, appliesToSubfolders: true), operationID: UUID()) { _, _ in }
                XCTFail("无法确认成员时不能写入")
            } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "update" })
        }
    }

    func test目录权限回读不一致不误报且清除密码要确认关闭() async throws {
        for mismatch in [true, false] {
            let baseline = [permissionFolder(), permissionConfig, permissionParent]
            let after = [permissionFolder(privacy: "public-view").replacingOccurrences(of: #""enable_password":true"#, with: mismatch ? #""enable_password":true"# : #""enable_password":false"#), permissionConfig, permissionParent]
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + (baseline + baseline + [emptySuccess] + after).map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(permissionTarget)
            let result = try await repository.performMutation(.setFolderSharing(original: original, access: .view, members: nil, password: "", appliesToSubfolders: true), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, mismatch ? .pendingReview : .confirmed)
        }
    }

    func test目录权限明确拒绝不会误报或重放且配置拒绝保留已保存结果() async throws {
        for failConfig in [false, true] {
            let baseline = [permissionFolder(), permissionConfig, permissionParent]
            let denied = #"{"success":false,"error":{"code":105}}"#
            let responses = baseline + baseline + (failConfig ? [emptySuccess, denied, permissionFolder(privacy: "public-view"), permissionConfig, permissionParent] : [denied])
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + responses.map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.folderSharing(permissionTarget), id = UUID()
            let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .view, members: nil, password: nil, appliesToSubfolders: false)
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, failConfig ? .partial : .rejected)
            let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(repeated, result)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, 1)
            XCTAssertEqual(requests.filter { $0["method"] == "set_config" }.count, failConfig ? 1 : 0)
        }
    }

    func test目录权限保存仅共享管理账号及真实接口可用时开放() async throws {
        for (role, missing) in [("management", false), ("management", true), ("entry", false), ("none", false)] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: role)), repository = try makeRepository(transport, omittedAPIs: missing ? ["SYNO.FotoTeam.Sharing.FolderPermission"] : [])
            _ = try await repository.access()
            let shared = await repository.managementFeatures(in: .shared), personal = await repository.managementFeatures(in: .personal)
            XCTAssertEqual(shared.contains(.folderSharing), role == "management" && !missing); XCTAssertFalse(personal.contains(.folderSharing))
        }
    }

    private func deletingFolder(_ id: Int = 10, parent: Int = 9) -> String {
        coverFolder(id: id, path: "/Fixture/Child\(id)").replacingOccurrences(of: #""parent":1"#, with: #""parent":PARENT"#.replacingOccurrences(of: "PARENT", with: String(parent)))
    }
    private func deletionFolderTarget(_ id: Int = 10, space: SynologyPhotoSpace = .personal) -> SynologyPhotoCollection {
        .init(id: id, name: "Child\(id)", parentID: 9, path: "/Fixture/Child\(id)", space: space)
    }
    private func folderDeleteStatus(_ status: String = "done", error: Int = 0, skip: Int = 0, id: Int = 42, completion: Int = 3) -> String {
        #"{"success":true,"data":{"list":[{"id":ID,"status":"STATUS","completion":COMPLETION,"error":ERROR,"skip":SKIP,"overwrite":0}]}}"#
            .replacingOccurrences(of: "ID", with: String(id)).replacingOccurrences(of: "STATUS", with: status)
            .replacingOccurrences(of: "ERROR", with: String(error)).replacingOccurrences(of: "SKIP", with: String(skip))
            .replacingOccurrences(of: "COMPLETION", with: String(completion))
    }
    private let folderDeleteReceipt = #"{"success":true,"data":{"task_info":{"id":42}}}"#
    private let emptyFolderOrItemList = #"{"success":true,"data":{"list":[]}}"#

    private func folderTransferReceipt(total: Int = 600, owner: Int = 12, folder: Int = 20) -> String {
        "{\"success\":true,\"data\":{\"task_info\":{\"id\":42,\"total\":\(total),\"target_folder\":{\"id\":\(folder),\"owner_user_id\":\(owner)}}}}"
    }

    func test多目录混合移动复制跨空间使用固定来源数组和递归任务总数() async throws {
        for (source, destination, move) in [(SynologyPhotoSpace.personal, SynologyPhotoSpace.shared, true), (.personal, .shared, false), (.shared, .personal, false)] {
            let profile = UUID(), photo = coverPhoto(profile, space: source)
            let folders = [deletionFolderTarget(10, space: source), deletionFolderTarget(11, space: source)]
            func sourceRead(_ raw: String) -> String { source == .shared ? raw.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"download":true"#) : raw }
            let target = coverFolder(id: 20, path: "/Destination").replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
            let receipt = folderTransferReceipt(owner: destination == .shared ? 0 : 12)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") +
                [itemPage, sourceRead(coverFolder()), coverFolder(), sourceRead(deletingFolder(10)), sourceRead(deletingFolder(11)), target,
                 receipt, folderDeleteStatus().replacingOccurrences(of: #""completion":3"#, with: #""completion":600"#), target].map(response))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command: SynologyPhotosMutation = move ? .move([photo], folderID: 20, destinationSpace: destination, folders: folders) : .copy([photo], folderID: 20, destinationSpace: destination, folders: folders)
            let id = UUID(), result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 600)
            let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(repeated, result)
            let requests = try await transport.recordedRequests().map(decode), writes = requests.filter { $0["method"] == (move ? "move" : "copy") }
            XCTAssertEqual(writes.count, 1); let write = try XCTUnwrap(writes.first)
            XCTAssertEqual(write["folder_id"], "[10,11]"); XCTAssertEqual(write["item_id"], "[7]"); XCTAssertEqual(write["target_folder_id"], "20"); XCTAssertEqual(write["action"], #""skip""#)
            XCTAssertEqual(write["api"], source == .personal ? "SYNO.Foto.BackgroundTask.File" : "SYNO.FotoTeam.BackgroundTask.File")
            if move {
                let json = try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(write["extra_info"]).utf8))
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                XCTAssertEqual(fields["source_folder_ids"] as? [Int], [9]); XCTAssertEqual(fields["source_library"] as? String, "personal_space"); XCTAssertEqual(fields["version"] as? Int, 2)
            } else { XCTAssertNil(write["extra_info"]) }
        }
    }

    func test同空间目录移动回读新父目录身份且复制不改原目录() async throws {
        for moving in [true, false] {
            let target = coverFolder(id: 20, path: "/Destination")
            let moved = deletingFolder(parent: 20).replacingOccurrences(of: "/Fixture/Child10", with: "/Destination/Child10")
            let reads = [coverFolder(), deletingFolder(), target, folderTransferReceipt(), folderDeleteStatus(completion: 600), target] + (moving ? [moved] : [])
            let transport = MockHTTPTransport(responses: accessResponses() + reads.map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let command: SynologyPhotosMutation = moving ? .move([], folderID: 20, folders: [deletionFolderTarget()]) : .copy([], folderID: 20, folders: [deletionFolderTarget()])
            let result = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
        }
    }

    func test目录传输拒绝自身后代原父目录及共享反向移动() async throws {
        for (id, path) in [(9, "/Fixture"), (10, "/Fixture/Child10"), (20, "/Fixture/Child10/Descendant")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), coverFolder(id: id, path: path)].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { try await repository.prepareMutation(.move([], folderID: id, folders: [deletionFolderTarget()])); XCTFail("目录冲突不能提交") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "move" })
        }
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry")), repository = try makeRepository(transport)
        _ = try await repository.access()
        do { try await repository.prepareMutation(.move([], folderID: 20, destinationSpace: .personal, folders: [deletionFolderTarget(space: .shared)])); XCTFail("不支持共享反向移动") } catch { }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test目录传输任务回执缺失目标只读补查且不重发() async throws {
        let target = coverFolder(id: 20, path: "/Destination")
        let listed = folderTransferReceipt().replacingOccurrences(of: #""task_info":{"#, with: #""list":[{"#).replacingOccurrences(of: "}}}}", with: "}}]}}")
        let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), target, folderDeleteReceipt,
            emptyFolderOrItemList, listed, folderDeleteStatus(completion: 600), target].map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.copy([], folderID: 20, folders: [deletionFolderTarget()]), id = UUID()
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "copy" }.count, 1)
    }

    func test目录传输部分失败不误报完成且异常计数保持未知() async throws {
        let target = coverFolder(id: 20, path: "/Destination")
        for (status, expected) in [(folderDeleteStatus(error: 1), SynologyPhotosMutationResult.State.partial), (folderDeleteStatus(skip: 1), .partial),
                                   (folderDeleteStatus().replacingOccurrences(of: #""completion":3"#, with: #""completion":601"#), .pendingReview),
                                   (folderDeleteStatus(id: 43), .pendingReview)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), target, folderTransferReceipt(), status, target].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let result = try await repository.performMutation(.copy([], folderID: 20, folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, expected)
        }
    }

    func test空目录复制允许零任务总数而同空间移动回读错误父目录不能确认() async throws {
        let target = coverFolder(id: 20, path: "/Destination")
        let emptyDone = folderDeleteStatus().replacingOccurrences(of: #""completion":3"#, with: #""completion":0"#)
        let empty = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), target, folderTransferReceipt(total: 0), emptyDone, target].map(response))
        let repository = try makeRepository(empty); _ = try await repository.access()
        let copied = try await repository.performMutation(.copy([], folderID: 20, folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(copied.state, .confirmed)
        let mismatch = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), target, folderTransferReceipt(), folderDeleteStatus(completion: 600), target, deletingFolder()].map(response))
        let other = try makeRepository(mismatch); _ = try await other.access()
        let moved = try await other.performMutation(.move([], folderID: 20, folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(moved.state, .pendingReview)
    }

    func test目录传输回执丢失不能猜任务或重复写入() async throws {
        let transport = MockHTTPTransport(steps: (accessResponses() + [coverFolder(), deletingFolder(), coverFolder(id: 20, path: "/Destination")].map(response)).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.copy([], folderID: 20, folders: [deletionFolderTarget()]), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let again = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(again.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "copy" }.count, 1)
    }

    func test目录移动身份或源权限变化时不得发送后台写入() async throws {
        for source in [deletingFolder().replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#), deletingFolder(parent: 8), deletingFolder().replacingOccurrences(of: "Child10", with: "Other")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), source].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { try await repository.prepareMutation(.move([], folderID: 20, folders: [deletionFolderTarget()])); XCTFail("源目录已改变") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "move" })
        }
    }

    func test文件夹与照片混合删除固定个人共享路由且任务完成和逐项回读后确认() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let profile = UUID(), targets = [deletionFolderTarget(10, space: space), deletionFolderTarget(11, space: space)]
            let photo = coverPhoto(profile, space: space)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") +
                [coverFolder(), deletingFolder(10), deletingFolder(11), itemPage, coverFolder(), folderDeleteReceipt,
                 folderDeleteStatus(), coverFolder(), emptyFolderOrItemList, emptyFolderOrItemList].map(response))
            let repository = try makeRepository(transport, profileID: profile, deletionEnabled: true); _ = try await repository.access()
            let command = SynologyPhotosMutation.deleteFolderItems(photos: [photo], folders: targets), id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.deletedFolders, targets); XCTAssertEqual(result.deletedPhotoIDs, [photo.id]); XCTAssertEqual(result.completedCount, 3)
            let again = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(again, result)
            let requests = try await transport.recordedRequests().map(decode), writes = requests.filter { $0["method"] == "delete" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.BackgroundTask.File" : "SYNO.FotoTeam.BackgroundTask.File")
            XCTAssertEqual(writes.first?["version"], "1"); XCTAssertEqual(writes.first?["item_id"], "[7]"); XCTAssertEqual(writes.first?["folder_id"], "[10,11]")
            XCTAssertEqual(requests.first { $0["method"] == "get_status" }?["api"], "SYNO.Foto.BackgroundTask.Info")
        }
    }

    func test文件夹删除任务尚未完成或目录仍存在不能当作成功且恢复核对不重放() async throws {
        let listed = #"{"success":true,"data":{"list":[{"id":10,"name":"/Fixture/Child10","parent":9}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), folderDeleteReceipt, folderDeleteStatus("processing"),
            folderDeleteStatus(), coverFolder(), listed, folderDeleteStatus(), coverFolder(), emptyFolderOrItemList].map(response))
        let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.deleteFolderItems(photos: [], folders: [deletionFolderTarget()])
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let stillPresent = try await repository.reviewMutation(operationID: id); XCTAssertEqual(stillPresent.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
    }

    func test文件夹删除回执丢失不猜测任务且不重新提交() async throws {
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(coverFolder()), response(deletingFolder())]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.deleteFolderItems(photos: [], folders: [deletionFolderTarget()])
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let reviewed = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(reviewed.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
    }

    func test文件夹删除部分错误缺少逐项目结果不冒充已确认删除() async throws {
        let remains = #"{"success":true,"data":{"list":[{"id":11,"name":"/Fixture/Child11","parent":9}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(10), deletingFolder(11), folderDeleteReceipt,
            folderDeleteStatus(error: 1), coverFolder(), remains].map(response))
        let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
        let result = try await repository.performMutation(.deleteFolderItems(photos: [], folders: [deletionFolderTarget(10), deletionFolderTarget(11)]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertTrue(result.deletedFolders.isEmpty); XCTAssertEqual(result.completedCount, 0)
    }

    func test文件夹删除回读父目录权限与任务身份失败不能确认消失() async throws {
        for readbacks in [
            [folderDeleteStatus(id: 43)],
            [folderDeleteStatus(), coverFolder().replacingOccurrences(of: #""view":true"#, with: #""view":false"#)],
            [folderDeleteStatus(), coverFolder(path: "/Other")],
            [folderDeleteStatus(), coverFolder(), #"{"success":false,"error":{"code":105}}"#],
            [folderDeleteStatus(), coverFolder(), #"{"success":true,"data":{"list":[{"id":12,"name":"/Elsewhere","parent":1}]}}"#]
        ] {
            let transport = MockHTTPTransport(responses: accessResponses() + ([coverFolder(), deletingFolder(), folderDeleteReceipt] + readbacks).map(response))
            let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
            let result = try await repository.performMutation(.deleteFolderItems(photos: [], folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.deletedFolders.isEmpty)
        }
    }

    func test文件夹删除必须完整分页核对而不是只看父目录第一页() async throws {
        let page = try JSONSerialization.data(withJSONObject: ["success":true,"data":["list":(100..<200).map { ["id":$0,"name":"/Fixture/Page\($0)","parent":9] }]])
        let remains = #"{"success":true,"data":{"list":[{"id":10,"name":"/Fixture/Child10","parent":9}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [coverFolder(), deletingFolder(), folderDeleteReceipt, folderDeleteStatus(), coverFolder()].map(response) + [.init(data: page, statusCode: 200, headers: [:]), response(remains)])
        let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
        let result = try await repository.performMutation(.deleteFolderItems(photos: [], folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "list" }.map { $0["offset"] }, ["0", "100"])
    }

    func test文件夹删除预检期间权限代次改变不能继续写入() async throws {
        let base = MockHTTPTransport(responses: accessResponses() + [response(coverFolder())] + accessResponses(homeEnabled: false))
        let barrier = AlbumReadBarrierTransport(base), repository = try makeRepository(barrier, deletionEnabled: true)
        _ = try await repository.access(); await barrier.holdNext()
        let command = SynologyPhotosMutation.deleteFolderItems(photos: [], folders: [deletionFolderTarget()])
        let task = Task { try await repository.performMutation(command, operationID: UUID()) { _, _ in } }
        await barrier.waitUntilHeld(); _ = try await repository.access(); await barrier.release()
        do { _ = try await task.value; XCTFail("权限变化不能继续删除") } catch { }
        let requests = try await base.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "delete" })
    }

    func test目录删除沿调用方既有删除策略与真实接口能力开放() async throws {
        for enabled in [false, true] {
            let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, deletionEnabled: enabled)
            _ = try await repository.access(); let features = await repository.managementFeatures()
            XCTAssertEqual(features.contains(.folderDeletion), enabled)
        }
        let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, deletionEnabled: true, omittedAPIs: ["SYNO.Foto.BackgroundTask.File"])
        _ = try await repository.access(); let features = await repository.managementFeatures()
        XCTAssertFalse(features.contains(.folderDeletion)); XCTAssertTrue(features.contains(.folders))
    }

    func test文件夹删除根目录重复跨空间和权限变化均不提交() async throws {
        let invalid: [[SynologyPhotoCollection]] = [[], [.init(id: 1, name: "Root", parentID: 1, path: "/")], [deletionFolderTarget(), deletionFolderTarget()],
            [deletionFolderTarget(), deletionFolderTarget(11, space: .shared)], [.init(id: 10, name: "Child10", path: "/Fixture/Child10")]]
        for targets in invalid {
            let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, deletionEnabled: true)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.deleteFolderItems(photos: [], folders: targets), operationID: UUID()) { _, _ in }; XCTFail("无效目标不能删除") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
        for body in [deletingFolder().replacingOccurrences(of: #""manage":true"#, with: #""manage":false"#), deletingFolder(parent: 8), deletingFolder(11)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(coverFolder()), response(body)]), repository = try makeRepository(transport, deletionEnabled: true)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.deleteFolderItems(photos: [], folders: [deletionFolderTarget()]), operationID: UUID()) { _, _ in }; XCTFail("权限或身份改变不能删除") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
    }

    func test目录重命名名称规则按网页UTF16长度及保留名称处理() {
        for name in ["Fixture", "相册 2020", "a.b", "@other", "#other", String(repeating: "a", count: 255), String(repeating: "😀", count: 127)] {
            XCTAssertTrue(SynologyPhotosMutation.isValidFolderName(name), name)
        }
        for name in ["", "   ", ".hidden", "end.", "@database", "@eaDir", "@tmp", "@sharebin", "#recycle", "#snapshot", "a/b", "a\\b", "a:b", "a\0b", String(repeating: "a", count: 256), String(repeating: "😀", count: 128)] {
            XCTAssertFalse(SynologyPhotosMutation.isValidFolderName(name), name)
        }
    }

    func test目录重命名个人共享路由精确回读且相同操作不重复写入() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(coverFolder()), response(#"{"success":true,"data":{"folder":{"id":9,"name":"Renamed"}}}"#), response(coverFolder(path: "/Renamed"))])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: space)
            let mutation = SynologyPhotosMutation.renameFolder(folder: folder, name: "Renamed"), id = UUID()
            let result = try await repository.performMutation(mutation, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.folder?.path, "/Renamed"); XCTAssertEqual(result.folder?.space, space)
            let repeated = try await repository.performMutation(mutation, operationID: id) { _, _ in }; XCTAssertEqual(result, repeated)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.count, 7); XCTAssertEqual(requests[5]["api"], space == .personal ? "SYNO.Foto.Browse.Folder" : "SYNO.FotoTeam.Browse.Folder")
            XCTAssertEqual(requests[5]["method"], "rename"); XCTAssertEqual(requests[5]["version"], "1"); XCTAssertEqual(requests[5]["id"], "9"); XCTAssertEqual(requests[5]["name"], #""Renamed""#)
        }
    }

    func test目录重命名回执丢失只读自动核对不重放写入() async throws {
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(coverFolder())]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(coverFolder(path: "/Renamed")))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.renameFolder(folder: .init(id: 9, name: "Fixture", parentID: 1, path: "/Fixture"), name: "Renamed")
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "rename" }.count, 1)
    }

    func test目录重命名拒绝根目录无路径非法名称与身份管理权限变化() async throws {
        for (folder, name, body) in [
            (SynologyPhotoCollection(id: 1, name: "Root", path: "/"), "New", coverFolder()),
            (.init(id: 9, name: "Fixture"), "New", coverFolder()),
            (.init(id: 9, name: "Fixture", path: "/Fixture"), "../Other", coverFolder()),
            (.init(id: 9, name: "Fixture", path: "/Fixture"), "New", coverFolder(id: 10)),
            (.init(id: 9, name: "Fixture", path: "/Fixture"), "New", coverFolder(path: "/Other")),
            (.init(id: 9, name: "Fixture", path: "/Fixture"), "New", coverFolder(manage: false)),
            (.init(id: 9, name: "Fixture", parentID: 2, path: "/Fixture"), "New", coverFolder())
        ] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(body)]), repository = try makeRepository(transport)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.renameFolder(folder: folder, name: name), operationID: UUID()) { _, _ in }; XCTFail("不允许重命名") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "rename" })
        }
    }

    func test目录重命名不能用成功回执代替同一目录完整路径核对() async throws {
        for body in [coverFolder(), coverFolder(id: 10, path: "/Renamed"), coverFolder(path: "/Other/Renamed"), coverFolder(path: "/Renamed", manage: false), coverFolder(path: "/Renamed").replacingOccurrences(of: #""parent":1"#, with: #""parent":2"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(coverFolder()), response(#"{"success":true,"data":{}}"#), response(body)]), repository = try makeRepository(transport)
            _ = try await repository.access()
            let result = try await repository.performMutation(.renameFolder(folder: .init(id: 9, name: "Fixture", parentID: 1, path: "/Fixture"), name: "Renamed"), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
    }

    private func sortedFolder(_ sort: SynologyPhotoSort?, manage: Bool = false) -> String {
        let fields = sort.map { #""sort_by":"FIELD","sort_direction":"DIRECTION","parent":1"#.replacingOccurrences(of: "FIELD", with: $0.field.rawValue).replacingOccurrences(of: "DIRECTION", with: $0.direction.rawValue) } ?? #""parent":1"#
        return coverFolder(manage: manage).replacingOccurrences(of: #""parent":1"#, with: fields)
    }

    func test目录排序优先读取目录字段且缺失或未知字段逐项沿用户设置() async throws {
        var initial = accessResponses()
        initial[1] = response(#"{"success":true,"data":{"enable_home_service":true,"team_space_permission":"none","item_sort_by":"filename","sort_direction":"desc"}}"#)
        let explicit = SynologyPhotoSort(field: .filesize, direction: .ascending)
        let partial = sortedFolder(explicit).replacingOccurrences(of: #""sort_by":"filesize""#, with: #""sort_by":"unknown""#)
        let transport = MockHTTPTransport(responses: initial + [response(sortedFolder(explicit)), response(sortedFolder(nil)), response(partial)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture")
        let first = try await repository.folderSort(folder), second = try await repository.folderSort(folder), third = try await repository.folderSort(folder)
        XCTAssertEqual(first, explicit); XCTAssertEqual(second, .init(field: .filename, direction: .descending)); XCTAssertEqual(third, .init(field: .filename, direction: .ascending))
        let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "set_order" })
    }

    func test目录排序四字段双向及跨页均传给原空间且子目录按名称同方向() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for field in SynologyPhotoSort.Field.allCases {
                for direction in SynologyPhotoSort.Direction.allCases {
                    let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(#"{"success":true,"data":{"list":[]}}"#)])
                    let repository = try makeRepository(transport); _ = try await repository.access()
                    let sort = SynologyPhotoSort(field: field, direction: direction)
                    _ = try await repository.photos(in: space, query: .folder(id: 9, sort: sort), offset: 0, limit: 100)
                    _ = try await repository.photos(in: space, query: .folder(id: 9, sort: sort), offset: 100, limit: 100)
                    _ = try await repository.folders(in: space, parentID: 9, offset: 100, limit: 100, direction: direction)
                    let fields = try await transport.recordedRequests().map(decode), prefix = space == .personal ? "SYNO.Foto" : "SYNO.FotoTeam"
                    for (index, offset) in [(4, "0"), (5, "100")] {
                        XCTAssertEqual(fields[index]["api"], prefix + ".Browse.Item"); XCTAssertEqual(fields[index]["offset"], offset)
                        XCTAssertEqual(fields[index]["sort_by"], #"""# + field.rawValue + #"""#); XCTAssertEqual(fields[index]["sort_direction"], #"""# + direction.rawValue + #"""#)
                    }
                    XCTAssertEqual(fields[6]["api"], prefix + ".Browse.Folder"); XCTAssertEqual(fields[6]["sort_by"], #""filename""#)
                    XCTAssertEqual(fields[6]["sort_direction"], #"""# + direction.rawValue + #"""#)
                }
            }
        }
    }

    func test目录排序只需查看权且按v1固定目标保存回读与去重() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let sort = SynologyPhotoSort(field: .itemType, direction: .descending)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(sortedFolder(nil)), response(emptySuccess), response(sortedFolder(sort))])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let command = SynologyPhotosMutation.setFolderSort(folder: .init(id: 9, name: "Fixture", path: "/Fixture", space: space), sort: sort), id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.folder?.sort, sort); XCTAssertEqual(result.folder?.space, space)
            let again = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(again, result)
            let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.count, 7)
            XCTAssertEqual(requests[5]["api"], space == .personal ? "SYNO.Foto.Browse.Folder" : "SYNO.FotoTeam.Browse.Folder")
            XCTAssertEqual(requests[5]["method"], "set_order"); XCTAssertEqual(requests[5]["version"], "1"); XCTAssertEqual(requests[5]["id"], "9")
            XCTAssertEqual(requests[5]["sort_by"], #""item_type""#); XCTAssertEqual(requests[5]["sort_direction"], #""desc""#)
        }
    }

    func test目录排序回执丢失只回读且缺字段不按默认值冒充成功() async throws {
        let sort = SynologyPhotoSort()
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(sortedFolder(nil))]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(sortedFolder(nil))), .response(response(sortedFolder(sort)))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setFolderSort(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), sort: sort), id = UUID()
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let missing = try await repository.reviewMutation(operationID: id); XCTAssertEqual(missing.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.filter { $0["method"] == "set_order" }.count, 1)
    }

    func test目录排序拒绝目录身份及查看权变化并且撤销代次后不写入() async throws {
        for body in [coverFolder().replacingOccurrences(of: #""view":true"#, with: #""view":false"#), coverFolder(id: 10), coverFolder(path: "/Other")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(body)]), repository = try makeRepository(transport)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.setFolderSort(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), sort: .init()), operationID: UUID()) { _, _ in }; XCTFail("错误目标不能保存") } catch { }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "set_order" })
        }
        let base = MockHTTPTransport(responses: accessResponses() + [response(coverFolder())] + accessResponses(homeEnabled: false))
        let transport = AlbumReadBarrierTransport(base), repository = try makeRepository(transport); _ = try await repository.access(); await transport.holdNext()
        let pending = Task { try await repository.performMutation(.setFolderSort(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), sort: .init()), operationID: UUID()) { _, _ in } }
        await transport.waitUntilHeld(); _ = try await repository.access(); await transport.release()
        do { _ = try await pending.value; XCTFail("撤销后不能保存") } catch { }
        let requests = try await base.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "set_order" })
    }

    private func coverFolder(id: Int = 9, path: String = "/Fixture", manage: Bool = true, thumbnail: String = "[]") -> String {
        #"{"success":true,"data":{"folder":{"id":ID,"name":"PATH","parent":1,"additional":{"access_permission":{"view":true,"manage":MANAGE},"thumbnail":THUMB}}}}"#
            .replacingOccurrences(of: "ID", with: String(id)).replacingOccurrences(of: "PATH", with: path)
            .replacingOccurrences(of: "MANAGE", with: String(manage)).replacingOccurrences(of: "THUMB", with: thumbnail)
    }
    private let customFolderCover = #"[{"folder_cover_seq":0,"cache_key":"fixture-cover"}]"#
    private func coverPhoto(_ profile: UUID, space: SynologyPhotoSpace, folderID: Int = 9) -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: folderID, mediaType: "photo")
    }

    func test目录封面读取自定义序号及默认拼图且个人共享缓存隔离() async throws {
        let data = try PhotoPreviewFixture.image(type: .jpeg)
        for space in [SynologyPhotoSpace.personal, .shared] {
            let covers = #"[{"folder_cover_seq":0,"cache_key":"custom"},{"unit_id":7,"cache_key":"unit"}]"#
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(coverFolder(thumbnail: covers)),
                .init(data: data, statusCode: 200, headers: ["Content-Type":"image/jpeg"]), .init(data: data, statusCode: 200, headers: ["Content-Type":"image/jpeg"])])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let images = try await repository.folderCoverImages(.init(id: 9, name: "Fixture", path: "/Fixture", space: space))
            XCTAssertEqual(images, [data, data])
            let requests = await transport.recordedRequests(), custom = try query(requests[5]), unit = try query(requests[6])
            XCTAssertTrue(requests[5].url!.path.contains(space == .shared ? "/t/" : "/p/"))
            XCTAssertEqual(custom["type"], #""folder""#); XCTAssertEqual(custom["id"], "9"); XCTAssertEqual(custom["folder_cover_seq"], "0"); XCTAssertNil(custom["size"])
            XCTAssertEqual(unit["type"], #""unit""#); XCTAssertEqual(unit["id"], "7"); XCTAssertNil(unit["folder_cover_seq"])
        }
    }

    func test目录封面按v2数组提交且成功回执和可读封面共同确认并去重() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let data = try PhotoPreviewFixture.image(type: .jpeg), profile = UUID()
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(coverFolder()), response(itemPage), response(coverFolder(manage: false)), response(emptySuccess), response(coverFolder(thumbnail: customFolderCover)), .init(data: data, statusCode: 200, headers: ["Content-Type":"image/jpeg"])])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture", space: space), photo: coverPhoto(profile, space: space)), operation = UUID()
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.folder?.space, space)
            let repeated = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(repeated, result)
            let requests = await transport.recordedRequests(), writes = try requests.filter { guard $0.httpBody != nil else { return false }; return try decode($0)["method"] == "set_cover" }
            XCTAssertEqual(writes.count, 1)
            let fields = try decode(XCTUnwrap(writes.first))
            XCTAssertEqual(fields["api"], space == .shared ? "SYNO.FotoTeam.Browse.Folder" : "SYNO.Foto.Browse.Folder")
            XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["id"], "9"); XCTAssertEqual(fields["id_item"], "[7]")
        }
    }

    func test目录封面拒绝根目录无管理权兄弟目录和身份变化() async throws {
        for scenario in ["root", "permission", "sibling", "identity"] {
            let profile = UUID(), path = scenario == "root" ? "/" : "/Fixture"
            let currentItem = scenario == "identity" ? itemPage.replacingOccurrences(of: "sample.jpg", with: "changed.jpg") : itemPage
            let transport = MockHTTPTransport(responses: accessResponses() + [response(coverFolder(path: path, manage: scenario != "permission")), response(currentItem), response(coverFolder(path: scenario == "sibling" ? "/Fixture-other" : path))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(.setFolderCover(folder: .init(id: 9, name: "Fixture", path: path), photo: coverPhoto(profile, space: .personal))); XCTFail("不能越过目录和身份边界") }
            catch let error as AppError { XCTAssertTrue([AppErrorCategory.permissionDenied, .conflict].contains(error.category)) }
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "set_cover" })
        }
    }

    func test目录封面可选无管理权的子目录照片且不把坏图当保存成功() async throws {
        for validImage in [true, false] {
            let profile = UUID(), data = validImage ? try PhotoPreviewFixture.image(type: .jpeg) : Data("invalid image".utf8)
            let identity = itemPage.replacingOccurrences(of: #""folder_id":9"#, with: #""folder_id":10"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(coverFolder()), response(identity),
                response(coverFolder(id: 10, path: "/Fixture/Child", manage: false)), response(emptySuccess),
                response(coverFolder(thumbnail: customFolderCover)), .init(data: data, statusCode: 200, headers: ["Content-Type":"image/jpeg"])])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture"),
                photo: coverPhoto(profile, space: .personal, folderID: 10))
            let result = try await repository.performMutation(command, operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, validImage ? .confirmed : .pendingReview)
            let requests = await transport.recordedRequests(), fields = try decode(requests[7])
            XCTAssertEqual(fields["method"], "set_cover"); XCTAssertEqual(fields["id"], "9"); XCTAssertEqual(fields["id_item"], "[7]")
        }
    }

    func test目录封面读取失败只重查且丢失写回执不猜测或重放() async throws {
        for acknowledged in [false, true] {
            let profile = UUID(), data = try PhotoPreviewFixture.image(type: .jpeg)
            var steps = (accessResponses() + [response(coverFolder()), response(itemPage), response(coverFolder())]).map(MockHTTPTransport.Step.response)
            steps += acknowledged ? [.response(response(emptySuccess)), .urlError(.networkConnectionLost), .response(response(coverFolder(thumbnail: customFolderCover))), .response(.init(data: data, statusCode: 200, headers: ["Content-Type":"image/jpeg"]))] : [.urlError(.networkConnectionLost)]
            let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let operation = UUID(), command = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), photo: coverPhoto(profile, space: .personal))
            let pending = try await repository.performMutation(command, operationID: operation) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
            let reviewed = try await repository.reviewMutation(operationID: operation); XCTAssertEqual(reviewed.state, acknowledged ? .confirmed : .pendingReview)
            let requests = await transport.recordedRequests(), writes = try requests.filter { guard $0.httpBody != nil else { return false }; return try decode($0)["method"] == "set_cover" }
            XCTAssertEqual(writes.count, 1)
        }
    }

    func test目录封面预检时撤销权限不提交且跨空间快照拒绝() async throws {
        let profile = UUID(), base = MockHTTPTransport(responses: accessResponses() + [response(coverFolder())] + accessResponses(homeEnabled: false) + [response(itemPage)])
        let transport = AlbumReadBarrierTransport(base), repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let wrong = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture", space: .shared), photo: coverPhoto(profile, space: .personal))
        do { try await repository.prepareMutation(wrong); XCTFail("空间不能混用") } catch { }
        await transport.holdNext()
        let command = SynologyPhotosMutation.setFolderCover(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), photo: coverPhoto(profile, space: .personal))
        let pending = Task { try await repository.prepareMutation(command) }
        await transport.waitUntilHeld(); _ = try await repository.access(); await transport.release()
        do { try await pending.value; XCTFail("旧权限不能继续") } catch { }
        let requests = try await base.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "set_cover" })
    }

    private func originalJPEGAccess(hevc: Bool? = true, enabled: Bool? = true, home: Bool = true) -> [DsmHTTPResponse] {
        var values = accessResponses(teamPermission: "entry", homeEnabled: home)
        var user: [String: Any] = ["enable_home_service": home, "team_space_permission": "entry"]
        if let hevc { user["ame_status"] = ["has_hevc": hevc] }
        var admin: [String: Any] = ["package_version": "1.8.2-10090"]
        if let enabled { admin["enable_converted_original_jpeg"] = enabled }
        values[1] = .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": user]), statusCode: 200)
        values[2] = .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": admin]), statusCode: 200)
        return values
    }

    private func originalJPEGPhoto(profile: UUID, space: SynologyPhotoSpace = .personal, album: Bool = false) -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.heic", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
              albumContext: album ? .init(albumID: 21, ownerUserID: space == .shared ? 0 : 12) : nil)
    }

    func test原尺寸JPEG实际能力同时依赖解码器和管理员设置且缺字段兼容() async throws {
        for hevc in [nil, false, true] as [Bool?] {
            for enabled in [nil, false, true] as [Bool?] {
                let transport = MockHTTPTransport(responses: originalJPEGAccess(hevc: hevc, enabled: enabled))
                let id = UUID(), repository = try makeRepository(transport, profileID: id)
                let access = try await repository.access()
                XCTAssertEqual(access.supportsOriginalSizeJPEG, hevc == true && enabled == true)
                if !access.supportsOriginalSizeJPEG {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { _ = try await repository.download(originalJPEGPhoto(profile: id), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("能力不足不能转换") }
                    catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
                    let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                }
            }
        }
    }

    func test原尺寸JPEG按个人共享路由先单项转换再下载真实JPEG() async throws {
        let jpeg = try PhotoPreviewFixture.image(type: .jpeg)
        for space in [SynologyPhotoSpace.personal, .shared] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic")
            let folder = #"{"success":true,"data":{"folder":{"id":9,"name":"/Fixture","parent":1,"additional":{"access_permission":{"view":true,"download":true}}}}}"#
            let transport = MockHTTPTransport(responses: originalJPEGAccess() + [response(identity), response(folder), response(emptySuccess), .init(data: jpeg, statusCode: 200)])
            let id = UUID(), repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let actual = try await repository.download(originalJPEGPhoto(profile: id, space: space), format: .originalSizeJPEG, to: file) { _, _ in }
            XCTAssertEqual(actual, .originalSizeJPEG); XCTAssertEqual(try Data(contentsOf: file), jpeg)
            let requests = await transport.recordedRequests(), converted = try decode(requests[6]), downloaded = try decode(requests[7])
            XCTAssertEqual(converted["method"], "convert"); XCTAssertEqual(converted["item_id"], "7"); XCTAssertEqual(converted["version"], "2")
            XCTAssertEqual(converted["api"], space == .shared ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download")
            XCTAssertEqual(downloaded["method"], "download"); XCTAssertEqual(downloaded["item_id"], "[7]")
            XCTAssertEqual(downloaded["download_type"], #""original_size_jpeg""#)
            XCTAssertEqual(requests[6].httpMethod, "POST"); XCTAssertEqual(requests[7].httpMethod, "POST")
        }
    }

    func test原尺寸JPEG协作相册按下载权且共享原件统一Foto并保护口令() async throws {
        for allowed in [false, true] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic").replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":0")
            let transport = MockHTTPTransport(responses: originalJPEGAccess(home: false) + [response(identity), response(collaborationAlbum()),
                response(collaborationPermission(download: allowed, upload: true)), response(emptySuccess), .init(data: try PhotoPreviewFixture.image(type: .jpeg), statusCode: 200)])
            let id = UUID(), repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            do { _ = try await repository.download(originalJPEGPhoto(profile: id, space: .shared, album: true), format: .originalSizeJPEG, to: file) { _, _ in }; XCTAssertTrue(allowed) }
            catch let error as AppError { XCTAssertFalse(allowed); XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests(), writes = try requests.filter { ["convert", "download"].contains(try decode($0)["method"] ?? "") }
            XCTAssertEqual(writes.count, allowed ? 2 : 0)
            for request in writes {
                let fields = try decode(request)
                XCTAssertEqual(fields["api"], "SYNO.Foto.Download"); XCTAssertEqual(fields["passphrase"], #""fixture-collaboration""#)
                XCTAssertNil(fields["album_id"]); XCTAssertFalse(request.url!.absoluteString.contains("fixture-collaboration"))
            }
        }
    }

    func test原尺寸JPEG协作原空间开启时可下载本人贡献且不信任旧提供者() async throws {
        for (provider, home, allowed) in [(12, true, true), (88, true, false), (12, false, false)] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic").replacingOccurrences(of: "\"resolution\":", with: "\"provider_user_id\":\(provider),\"resolution\":")
            let transport = MockHTTPTransport(responses: originalJPEGAccess(home: home) + [response(identity), response(collaborationAlbum()),
                response(collaborationPermission(download: false, upload: true)), response(emptySuccess), .init(data: try PhotoPreviewFixture.image(type: .jpeg), statusCode: 200)])
            let id = UUID(), repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            do { _ = try await repository.download(originalJPEGPhoto(profile: id, album: true), format: .originalSizeJPEG, to: file) { _, _ in }; XCTAssertTrue(allowed) }
            catch let error as AppError { XCTAssertFalse(allowed); XCTAssertEqual(error.category, .permissionDenied) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "convert" }.count, allowed ? 1 : 0)
        }
    }

    func test原尺寸JPEG转换拒绝后不下载且不重放() async throws {
        let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic")
        let transport = MockHTTPTransport(responses: originalJPEGAccess() + [response(identity), response(managedFolder), response(#"{"success":false,"error":{"code":105}}"#)])
        let id = UUID(), repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { _ = try await repository.download(originalJPEGPhoto(profile: id), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("不能把转换失败当成功") }
        catch { }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "convert" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "download" }); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test原尺寸JPEG不接受回退原件假JPEG或截断且不覆盖目标() async throws {
        let jpeg = try PhotoPreviewFixture.image(type: .jpeg)
        for data in [Data(repeating: 0x55, count: 128), Data(jpeg.prefix(20)), jpeg] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic")
            let transport = MockHTTPTransport(responses: originalJPEGAccess() + [response(identity), response(managedFolder), response(emptySuccess), .init(data: data, statusCode: 200)])
            let id = UUID(), repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let previous = Data("keep".utf8); try previous.write(to: file)
            do { _ = try await repository.download(originalJPEGPhoto(profile: id), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("不能覆盖") }
            catch let error as CocoaError { XCTAssertEqual(data, jpeg); XCTAssertEqual(error.code, .fileWriteFileExists) }
            catch let error as AppError { XCTAssertNotEqual(data, jpeg); XCTAssertEqual(error.category, .invalidResponse) }
            XCTAssertEqual(try Data(contentsOf: file), previous)
        }
    }

    func test原尺寸JPEG预检期间去重且取消或授权变更不提交转换() async throws {
        for revoke in [false, true] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic")
            let base = MockHTTPTransport(responses: originalJPEGAccess() + [response(identity)] + (revoke ? accessResponses() : []) + [response(managedFolder)])
            let transport = AlbumReadBarrierTransport(base), id = UUID(), repository = try makeRepository(transport, profileID: id)
            _ = try await repository.access(); await transport.holdNext()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), photo = originalJPEGPhoto(profile: id)
            let pending = Task { try await repository.download(photo, format: .originalSizeJPEG, to: file) { _, _ in } }
            await transport.waitUntilHeld()
            do { _ = try await repository.download(photo, format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("不能重复转换") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            if revoke { _ = try await repository.access() } else { pending.cancel() }
            await transport.release()
            do { _ = try await pending.value; XCTFail("不能继续转换") } catch { }
            let requests = try await base.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["convert", "download"].contains($0["method"] ?? "") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func test原尺寸JPEG所有者相册转换后取消或授权撤回不继续下载() async throws {
        for revoke in [false, true] {
            let identity = itemPage.replacingOccurrences(of: "sample.jpg", with: "sample.heic")
            let base = MockHTTPTransport(responses: originalJPEGAccess() + [response(identity), response(collaborationAlbum(owner: 12)), response(emptySuccess)] + (revoke ? accessResponses() : []))
            let transport = AlbumReadBarrierTransport(base), id = UUID(), repository = try makeRepository(transport, profileID: id)
            _ = try await repository.access(); await transport.holdNext(method: "convert")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let photo = originalJPEGPhoto(profile: id, album: true)
            let pending = Task { try await repository.download(photo, format: .originalSizeJPEG, to: file) { _, _ in } }
            await transport.waitUntilHeld()
            if revoke { _ = try await repository.access() } else { pending.cancel() }
            await transport.release()
            do { _ = try await pending.value; XCTFail("转换后已取消不能保存") } catch { }
            let requests = try await base.recordedRequests().map(decode), conversions = requests.filter { $0["method"] == "convert" }
            XCTAssertEqual(conversions.count, 1); XCTAssertEqual(conversions.first?["album_id"], "21"); XCTAssertNil(conversions.first?["passphrase"])
            XCTAssertFalse(requests.contains { $0["method"] == "download" }); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func test原尺寸JPEG拒绝批量归档错误身份和不支持格式() async throws {
        let id = UUID(), transport = MockHTTPTransport(responses: originalJPEGAccess() + [response(itemPage)])
        let repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try await repository.downloadArchive(.album(id: 21), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("原尺寸仅单项") } catch { }
        let unsupported = SynologyPhoto(id: .init(profileID: id, space: .personal, unitID: 7), filename: "sample.jpg", sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        do { _ = try await repository.download(unsupported, format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("JPEG不需要转换") } catch { }
        do { _ = try await repository.download(originalJPEGPhoto(profile: UUID()), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("不能跨设备") } catch { }
        do { _ = try await repository.download(originalJPEGPhoto(profile: id), format: .originalSizeJPEG, to: file) { _, _ in }; XCTFail("身份不符") } catch { }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.count, 5); XCTAssertFalse(requests.contains { ["convert", "download"].contains($0["method"] ?? "") })
    }

    private var archiveFixture: Data {
        // 标准库生成的单个虚构文本文件ZIP，未包含用户资料。
        Data(base64Encoded: "UEsDBBQAAAAAAAAAIVDuQOUFBwAAAAcAAAALAAAAZml4dHVyZS50eHRmaXh0dXJlUEsBAhQDFAAAAAAAAAAhUO5A5QUHAAAABwAAAAsAAAAAAAAAAAAAAIABAAAAAGZpeHR1cmUudHh0UEsFBgAAAAABAAEAOQAAADAAAAAAAA==")!
    }

    func test整册下载不依赖照片分页且普通条件相册均用完整目标() async throws {
        for condition in [false, true] {
            for format in [SynologyPhotoDownloadFormat.original, .optimizedJPEG] {
                let archive = archiveFixture
                let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum(owner: 12, condition: condition)),
                    .init(data: archive, statusCode: 200, headers: ["Content-Type": "application/zip", "Content-Length": String(archive.count)])])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: file) }
                try await repository.downloadArchive(.album(id: 21), format: format, to: file) { _, _ in }
                XCTAssertEqual(try Data(contentsOf: file), archive)
                let requests = await transport.recordedRequests(), request = try XCTUnwrap(requests.last), fields = try decode(request)
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(fields["api"], "SYNO.Foto.Browse.Album")
                XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["id"], "21"); XCTAssertNil(fields["item_id"])
                XCTAssertEqual(fields["download_type"], format == .original ? #""source""# : #""optimized_jpeg""#)
                XCTAssertFalse(requests.contains { (try? decode($0)["api"]) == "SYNO.Foto.Browse.Item" })
            }
        }
    }

    func test协作整册下载按角色且分享口令只进入请求体() async throws {
        for allowed in [false, true] {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum()), response(collaborationPermission(download: allowed, upload: true)), .init(data: archiveFixture, statusCode: 200)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            do { try await repository.downloadArchive(.album(id: 21), format: .original, to: file) { _, _ in }; XCTAssertTrue(allowed) }
            catch let error as AppError { XCTAssertFalse(allowed); XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests(), downloads = try requests.filter { try decode($0)["method"] == "download" }
            XCTAssertEqual(downloads.count, allowed ? 1 : 0)
            if let request = downloads.first {
                let fields = try decode(request)
                XCTAssertEqual(fields["passphrase"], #""fixture-collaboration""#); XCTAssertNil(fields["id"])
                XCTAssertFalse(request.url!.absoluteString.contains("fixture-collaboration")); XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
            }
        }
    }

    func test整目录下载固定来源与目录编号且共享查看不能代替下载权() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for allowed in [false, true] {
                let folder = #"{"success":true,"data":{"folder":{"id":9,"name":"/Fixture","parent":1,"additional":{"access_permission":{"view":true,"download":ALLOWED}}}}}"#.replacingOccurrences(of: "ALLOWED", with: String(allowed))
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(folder), .init(data: archiveFixture, statusCode: 200)])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: file) }
                let succeeds = allowed
                do { try await repository.downloadArchive(.folder(id: 9, space: space), format: .optimizedJPEG, to: file) { _, _ in }; XCTAssertTrue(succeeds) }
                catch let error as AppError { XCTAssertFalse(succeeds); XCTAssertEqual(error.category, .permissionDenied) }
                let requests = try await transport.recordedRequests().map(decode), downloads = requests.filter { $0["method"] == "download" }
                XCTAssertEqual(downloads.count, succeeds ? 1 : 0)
                if let fields = downloads.first {
                    XCTAssertEqual(fields["api"], space == .shared ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download")
                    XCTAssertEqual(fields["folder_id"], "[9]"); XCTAssertNil(fields["item_id"]); XCTAssertEqual(fields["force_download"], "true")
                }
            }
        }
    }

    func test多个目录与照片混选整批下载使用同一次POST且固定空间() async throws {
        for space in SynologyPhotoSpace.allCases {
            for mixed in [false, true] {
                let profile = UUID(), photos = mixed ? [coverPhoto(profile, space: space)] : []
                let folders = [deletionFolderTarget(10, space: space), deletionFolderTarget(11, space: space)]
                let checkedFolders = [deletingFolder(10), deletingFolder(11)] + (mixed ? [coverFolder()] : [])
                let responses = checkedFolders.map { response($0.replacingOccurrences(of: #""view":true"#, with: #""view":true,"download":true"#)) }
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + responses +
                    (mixed ? [response(itemPage)] : []) + [.init(data: archiveFixture, statusCode: 200)])
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: file) }
                try await repository.downloadArchive(.selection(photos: photos, folders: folders), format: mixed ? .optimizedJPEG : .original, to: file) { _, _ in }
                XCTAssertEqual(try Data(contentsOf: file), archiveFixture)
                let requests = await transport.recordedRequests(), downloads = try requests.filter { try decode($0)["method"] == "download" }
                XCTAssertEqual(downloads.count, 1)
                let request = try XCTUnwrap(downloads.first), fields = try decode(request)
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(fields["folder_id"], "[10,11]")
                XCTAssertEqual(fields["item_id"], mixed ? "[7]" : nil); XCTAssertEqual(fields["force_download"], "true")
                XCTAssertEqual(fields["api"], space == .personal ? "SYNO.Foto.Download" : "SYNO.FotoTeam.Download")
                XCTAssertEqual(fields["download_type"], mixed ? #""optimized_jpeg""# : #""source""#)
                XCTAssertNil(fields["album_id"]); XCTAssertNil(fields["passphrase"])
                XCTAssertFalse(try requests.contains { try decode($0)["method"] == "list" }, "下载完整子目录不能依赖列表分页")
            }
        }
    }

    func test混选归档任一目录拒绝或身份改变均不下载任何项目() async throws {
        let failures = [
            deletingFolder().replacingOccurrences(of: #""view":true"#, with: #""view":true,"download":false"#),
            deletingFolder().replacingOccurrences(of: "Child10", with: "Changed"),
            deletingFolder(parent: 8)
        ]
        for payload in failures {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(payload)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try await repository.downloadArchive(.selection(photos: [], folders: [deletionFolderTarget()]), format: .original, to: file) { _, _ in }; XCTFail("不可绕过目录预检") }
            catch is AppError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let requests = try await transport.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "download" })
        }
    }

    func test混选归档拒绝跨来源重复选择与过期照片身份() async throws {
        let profile = UUID(), original = coverPhoto(profile, space: .personal)
        let albumPhoto = SynologyPhoto(id: original.id, filename: original.filename, sizeBytes: original.sizeBytes,
            takenAt: original.takenAt, indexedAt: original.indexedAt, folderID: 9, mediaType: "photo", albumContext: .init(albumID: 21, ownerUserID: 12))
        let targets: [SynologyPhotoArchiveTarget] = [
            .selection(photos: [original], folders: []),
            .selection(photos: [], folders: [deletionFolderTarget(), deletionFolderTarget()]),
            .selection(photos: [original, original], folders: [deletionFolderTarget()]),
            .selection(photos: [coverPhoto(UUID(), space: .personal)], folders: [deletionFolderTarget()]),
            .selection(photos: [coverPhoto(profile, space: .shared)], folders: [deletionFolderTarget()]),
            .selection(photos: [coverPhoto(profile, space: .personal, folderID: 8)], folders: [deletionFolderTarget()]),
            .selection(photos: [albumPhoto], folders: [deletionFolderTarget()]),
            .selection(photos: [original], folders: [deletionFolderTarget()])
        ]
        for (index, target) in targets.enumerated() {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(deletingFolder()), response(coverFolder()), response(itemPage.replacingOccurrences(of: "sample.jpg", with: "changed.jpg"))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try await repository.downloadArchive(target, format: .original, to: file) { _, _ in }; XCTFail("不可下载错误目标") }
            catch is AppError { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.count, index == targets.count - 1 ? 7 : 4)
            XCTAssertFalse(requests.contains { $0["method"] == "download" }); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func test混选归档预检照片超过一页仍完整下载且期间撤权不会继续() async throws {
        let profile = UUID()
        let photos = (1...101).map { id in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: id), filename: "sample.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo") }
        func page(_ ids: [Int]) throws -> DsmHTTPResponse {
            let list = ids.map { ["id": $0, "filename": "sample.jpg", "filesize": 128, "time": 50, "indexed_time": 60, "folder_id": 9, "type": "photo"] as [String: Any] }
            return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": list]]), statusCode: 200)
        }
        let base = MockHTTPTransport(responses: accessResponses() + [response(deletingFolder()), response(coverFolder()), try page(Array(1...100)), try page([101]), .init(data: archiveFixture, statusCode: 200)])
        let repository = try makeRepository(base, profileID: profile); _ = try await repository.access()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await repository.downloadArchive(.selection(photos: photos, folders: [deletionFolderTarget()]), format: .original, to: file) { _, _ in }
        let requests = try await base.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["api"] == "SYNO.Foto.Browse.Item" }.count, 2)
        let ids = try JSONDecoder().decode([Int].self, from: Data(XCTUnwrap(requests.last?["item_id"]).utf8)); XCTAssertEqual(ids, Array(1...101))

        let revoked = MockHTTPTransport(responses: accessResponses() + [response(deletingFolder())] + accessResponses(homeEnabled: false))
        let held = AlbumReadBarrierTransport(revoked), revokedRepository = try makeRepository(held)
        _ = try await revokedRepository.access(); await held.holdNext()
        let target = SynologyPhotoArchiveTarget.selection(photos: [], folders: [deletionFolderTarget()])
        let task = Task { try await revokedRepository.downloadArchive(target, format: .original, to: file) { _, _ in } }
        await held.waitUntilHeld(); _ = try await revokedRepository.access(); await held.release()
        do { try await task.value; XCTFail("旧权限不可继续下载") } catch is AppError { }
        let deniedRequests = try await revoked.recordedRequests().map(decode); XCTAssertFalse(deniedRequests.contains { $0["method"] == "download" })
    }

    func test归档拒绝截断错误页面且成功下载也不覆盖已有目标() async throws {
        let empty = Data([0x50, 0x4b, 5, 6] + Array(repeating: 0, count: 18))
        let cases: [(Data, String, String?, Bool)] = [
            (empty, "application/force-download", nil, true), (archiveFixture, "application/zip", nil, true),
            (Data(archiveFixture.dropLast()), "application/zip", nil, false),
            (archiveFixture, "application/zip", "99999", false),
            (archiveFixture, "application/json", nil, false),
            (Data("<html>failure</html>".utf8), "text/html", nil, false),
            (Data(repeating: 0, count: 50), "application/zip", nil, false)
        ]
        for (data, type, length, valid) in cases {
            var headers = ["Content-Type": type]; headers["Content-Length"] = length
            let transport = MockHTTPTransport(responses: accessResponses() + [response(collaborationAlbum(owner: 12)), .init(data: data, statusCode: 200, headers: headers)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let previous = Data("keep-archive".utf8); try previous.write(to: file)
            do { try await repository.downloadArchive(.album(id: 21), format: .original, to: file) { _, _ in }; XCTFail("不能覆盖旧文件") }
            catch let error as CocoaError { XCTAssertTrue(valid); XCTAssertEqual(error.code, .fileWriteFileExists) }
            catch let error as AppError { XCTAssertFalse(valid); XCTAssertEqual(error.category, .invalidResponse) }
            XCTAssertEqual(try Data(contentsOf: file), previous)
        }
    }

    func test归档预检期间授权撤回不会继续下载() async throws {
        let base = MockHTTPTransport(responses: accessResponses() + [response(managedFolder)] + accessResponses(homeEnabled: false))
        let transport = AlbumReadBarrierTransport(base), repository = try makeRepository(transport)
        _ = try await repository.access(); await transport.holdNext()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pending = Task { try await repository.downloadArchive(.folder(id: 9, space: .personal), format: .original, to: file) { _, _ in } }
        await transport.waitUntilHeld(); _ = try await repository.access(); await transport.release()
        do { try await pending.value; XCTFail("不能沿旧授权继续") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await base.recordedRequests().map(decode); XCTAssertFalse(requests.contains { $0["method"] == "download" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test压缩下载使用官方格式且个人共享相册路由隔离() async throws {
        let jpeg = try PhotoPreviewFixture.image(type: .jpeg)
        for (space, album) in [(SynologyPhotoSpace.personal, false), (.shared, false), (.shared, true)] {
            let profile = UUID()
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: album ? "none" : "entry", homeEnabled: !album) + [
                DsmHTTPResponse(data: jpeg, statusCode: 200, headers: ["Content-Type": "application/force-download", "Content-Length": String(jpeg.count)])])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "fixture.heic", sizeBytes: 128,
                takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo", albumContext: album ? .init(albumID: 21, ownerUserID: 0) : nil)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try await repository.download(photo, format: .optimizedJPEG, to: file) { _, _ in }
            XCTAssertEqual(result, .optimizedJPEG); XCTAssertEqual(try Data(contentsOf: file), jpeg)
            let requests = await transport.recordedRequests(), fields = try query(XCTUnwrap(requests.last))
            XCTAssertEqual(fields["api"], space == .shared && !album ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download")
            XCTAssertEqual(fields["download_type"], #""optimized_jpeg""#); XCTAssertEqual(fields["item_id"], "[7]")
            XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["album_id"], album ? "21" : nil)
        }
    }

    func test压缩下载保留原格式且拒绝截断错误文档和假JPEG() async throws {
        let jpeg = try PhotoPreviewFixture.image(type: .jpeg)
        let cases: [(Data, String, String?, Bool)] = [
            (Data(repeating: 0x55, count: 128), "application/force-download", nil, true),
            (Data(repeating: 0x55, count: 127), "application/force-download", nil, false),
            (Data(jpeg.prefix(20)), "image/jpeg", nil, false),
            (jpeg, "image/jpeg", "999999", false),
            (Data(repeating: 0x55, count: 128), "image/jpeg", nil, false),
            (Data(repeating: 0x55, count: 128), "application/json", nil, false),
            (Data(repeating: 0x55, count: 128), "text/html", nil, false),
            (Data(repeating: 0x55, count: 128), "application/zip", nil, false)
        ]
        for (data, type, length, succeeds) in cases {
            var headers = ["Content-Type": type]; headers["Content-Length"] = length
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), .init(data: data, statusCode: 200, headers: headers)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 10)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let result = try await repository.download(XCTUnwrap(page.items.first), format: .optimizedJPEG, to: file) { _, _ in }
                XCTAssertTrue(succeeds); XCTAssertEqual(result, .original); XCTAssertEqual(try Data(contentsOf: file), data)
            } catch let error as AppError {
                XCTAssertFalse(succeeds); XCTAssertEqual(error.category, .invalidResponse)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    func test压缩下载拒绝跨设备且不覆盖现有目标() async throws {
        let jpeg = try PhotoPreviewFixture.image(type: .jpeg)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), .init(data: jpeg, statusCode: 200)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 10)
        let photo = try XCTUnwrap(page.items.first), file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let previous = Data("keep-fixture".utf8); try previous.write(to: file)
        let other = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        do { _ = try await repository.download(other, format: .optimizedJPEG, to: file) { _, _ in }; XCTFail("不能跨设备") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { _ = try await repository.download(photo, format: .optimizedJPEG, to: file) { _, _ in }; XCTFail("不能覆盖") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteFileExists) }
        XCTAssertEqual(try Data(contentsOf: file), previous)
    }

    func test相似识别状态按空间读取且只在有待处理内容时显示() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for (count, stage, done) in [(0, "waiting", true), (12, "running", true), (12, "waiting", true), (0, "waiting", false)] {
                let payload = DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["waiting_count": count, "similar_clustering_stage": stage, "is_similar_hash_migration_done": done]]), statusCode: 200)
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: true) + [payload])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let value = try await repository.similarStatus(in: space)
                XCTAssertEqual(value.waitingCount, count); XCTAssertEqual(value.isVisible, count > 0 || !done)
                XCTAssertEqual(value.isRunning, count > 0 && stage == "running")
                let requests = try await transport.recordedRequests().map(decode)
                XCTAssertEqual(requests.last?["method"], "get_status")
                XCTAssertEqual(requests.last?["api"], space == .shared ? "SYNO.FotoTeam.Browse.Similar" : "SYNO.Foto.Browse.Similar")
            }
        }
    }

    func test相似识别状态拒绝负计数且权限变化后不返回旧状态() async throws {
        let negative = response(#"{"success":true,"data":{"waiting_count":-1,"similar_clustering_stage":"running","is_similar_hash_migration_done":true}}"#)
        let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [negative]))
        _ = try await repository.access()
        do { _ = try await repository.similarStatus(in: .personal); XCTFail("负计数不能展示") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let payload = response(#"{"success":true,"data":{"waiting_count":1,"similar_clustering_stage":"running","is_similar_hash_migration_done":true}}"#)
        let transport = AlbumReadBarrierTransport(MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [payload, response(#"{"success":true,"data":{"enabled":false}}"#)]))
        let changed = try makeRepository(transport); _ = try await changed.access(); await transport.holdNext()
        let pending = Task { try await changed.similarStatus(in: .personal) }; await transport.waitUntilHeld()
        do { _ = try await changed.access() } catch {}
        await transport.release()
        do { _ = try await pending.value; XCTFail("不能返回旧来源状态") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test已解散相似组详情返回空且不能用其他设备身份读取() async throws {
        let original = similarMutationFixture()
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [similarState([])])
        let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
        let empty = try await repository.similarGroupDetails(original.group); XCTAssertNil(empty)
        do { _ = try await repository.similarGroupDetails(similarMutationFixture().group); XCTFail("不能跨设备读取") } catch {}
        let requests = try await transport.recordedRequests().map(decode); XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.last?["method"], "get")
    }

    func test相似拆组不能仅凭空组确认且支持仅剩一张时自动解散() async throws {
        let original = similarMutationFixture()
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + similarPreflight() +
            [response(emptySuccess), similarState([]), similarMemberResponse([7, 8, 9], group: [7, 8, 9]),
             similarState([]), similarMemberResponse([7, 8, 9], group: [])])
        let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
        let id = UUID()
        let first = try await repository.performMutation(.editSimilarGroup(original, .ungroup), operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let checked = try await repository.reviewMutation(operationID: id); XCTAssertEqual(checked.state, .confirmed)
        let singleton = response(#"{"success":true,"data":{"list":[{"id":31,"count":1,"top_pick":7,"item_id":[7]}]}}"#)
        let second = try makeRepository(MockHTTPTransport(responses: accessResponses(similarEnabled: true) + similarPreflight() +
            [response(emptySuccess), singleton, similarMemberResponse([7, 8, 9], group: [])]), profileID: original.group.profileID)
        _ = try await second.access()
        let dissolved = try await second.performMutation(.editSimilarGroup(original, .remove([8, 9])), operationID: UUID()) { _, _ in }
        XCTAssertEqual(dissolved.state, .confirmed); XCTAssertNil(dissolved.similarGroup)
    }

    func test相似撤销拒绝未记录操作与已加入其他分组的成员() async throws {
        let original = similarMutationFixture()
        let identities = [7, 8, 9].flatMap { [similarMemberResponse([$0], group: []), response(managedFolder)] }
        let originalMembers = similarMemberResponse([7, 8, 9], group: [7, 8, 9])
        let otherGroup = DsmHTTPResponse(data: Data(String(decoding: originalMembers.data, as: UTF8.self).replacingOccurrences(of: "31", with: "32").utf8), statusCode: 200)
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + identities + similarPreflight() +
            [response(emptySuccess), similarState([]), similarMemberResponse([7, 8, 9], group: [])] + identities + [similarState([]), otherGroup])
        let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
        do { _ = try await repository.performMutation(.editSimilarGroup(original, .undo(UUID())), operationID: UUID()) { _, _ in }; XCTFail("不能伪造撤销") } catch {}
        let id = UUID()
        let changed = try await repository.performMutation(.editSimilarGroup(original, .ungroup), operationID: id) { _, _ in }; XCTAssertEqual(changed.state, .confirmed)
        do { _ = try await repository.performMutation(.editSimilarGroup(original, .undo(id)), operationID: UUID()) { _, _ in }; XCTFail("不能从其他组拉回成员") } catch {}
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "add_item" })
    }

    func test相似推荐移出拆组均回读且相同操作不重复提交() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for edit in [SynologyPhotoSimilarEdit.topPick(7), .remove([9]), .ungroup] {
                let original = similarMutationFixture(space: space)
                let after: [Int]
                let top: Int
                let method: String
                switch edit {
                case .topPick: after = [7, 8, 9]; top = 7; method = "set_top_pick"
                case .remove: after = [7, 8]; top = 8; method = "remove_item"
                default: after = []; top = 8; method = "ungroup"
                }
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: true) +
                    similarPreflight() + [response(emptySuccess), similarState(after, top: top), similarMemberResponse([7, 8, 9], group: after, top: top)])
                let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
                let command = SynologyPhotosMutation.editSimilarGroup(original, edit), id = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.count, 3)
                    XCTAssertEqual(result.similarGroup?.photoIDs ?? [], after)
                }
                let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
                let writes = requests.filter { $0["method"] == method }
                XCTAssertEqual(writes.count, 1)
                XCTAssertTrue(requests.allSatisfy { $0["api"]?.hasPrefix(space == .shared ? "SYNO.FotoTeam." : "SYNO.Foto.") == true })
                XCTAssertEqual(writes.first?["id"], method == "ungroup" ? "[31]" : "31")
                XCTAssertEqual(writes.first?["item_id"], method == "set_top_pick" ? "7" : method == "remove_item" ? "[9]" : nil)
                XCTAssertFalse(requests.contains { $0["method"] == "delete" })
            }
        }
    }

    func test相似更改断网只读核对且组响应与成员响应必须一致() async throws {
        let original = similarMutationFixture()
        let base = accessResponses(similarEnabled: true) + similarPreflight()
        let transport = MockHTTPTransport(steps: base.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] +
            [similarState([7, 8]), similarMemberResponse([7, 8, 9], group: [7, 8, 9]),
             similarState([7, 8]), similarMemberResponse([7, 8, 9], group: [7, 8])].map(MockHTTPTransport.Step.response))
        let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
        let command = SynologyPhotosMutation.editSimilarGroup(original, .remove([9])), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let stale = try await repository.reviewMutation(operationID: id); XCTAssertEqual(stale.state, .pendingReview)
        let checked = try await repository.reviewMutation(operationID: id); XCTAssertEqual(checked.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "remove_item" }.count, 1)
    }

    func test相似撤销固定原操作并恢复原推荐项且不能重复撤销() async throws {
        for edit in [SynologyPhotoSimilarEdit.remove([9]), .ungroup] {
            let original = similarMutationFixture(), after = edit == .ungroup ? [] : [7, 8]
            let identity = [7, 8, 9].flatMap { [similarMemberResponse([$0], group: []), response(managedFolder)] }
            let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + similarPreflight() +
                [response(emptySuccess), similarState(after), similarMemberResponse([7, 8, 9], group: after)] + identity +
                [similarState(after), similarMemberResponse([7, 8, 9], group: after), response(emptySuccess), similarState([7, 8, 9]), similarMemberResponse([7, 8, 9], group: [7, 8, 9])] + identity)
            let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
            let id = UUID(), command = SynologyPhotosMutation.editSimilarGroup(original, edit)
            let changed = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(changed.state, .confirmed)
            let undone = try await repository.performMutation(.editSimilarGroup(original, .undo(id)), operationID: UUID()) { _, _ in }
            XCTAssertEqual(undone.state, .confirmed); XCTAssertEqual(undone.similarGroup, original.group)
            do { _ = try await repository.performMutation(.editSimilarGroup(original, .undo(id)), operationID: UUID()) { _, _ in }; XCTFail("同一次更改不能重复恢复") } catch {}
            let requests = try await transport.recordedRequests().map(decode), writes = requests.filter { $0["method"] == "add_item" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["item_id"], "[7,8,9]"); XCTAssertEqual(writes.first?["top_pick"], "8")
        }
    }

    func test相似快照改变权限不足或原件变化时不能发送写入() async throws {
        for variant in 0..<3 {
            let original = similarMutationFixture()
            var responses = accessResponses(similarEnabled: true)
            if variant == 0 { responses += similarPreflight().dropLast(2) + [similarState([7, 8])] }
            if variant == 1 { responses += [similarMemberResponse([7], group: []), response(managedFolder.replacingOccurrences(of: "true", with: "false"))] }
            if variant == 2 { responses += [similarMemberResponse([8], group: [])] }
            let transport = MockHTTPTransport(responses: responses)
            let repository = try makeRepository(transport, profileID: original.group.profileID); _ = try await repository.access()
            do { _ = try await repository.performMutation(.editSimilarGroup(original, .ungroup), operationID: UUID()) { _, _ in }; XCTFail("拒绝过时或无权目标") } catch {}
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["ungroup", "add_item", "remove_item", "set_top_pick"].contains($0["method"] ?? "") })
        }
    }

    func test相似写前阶段持久化并在新服务中只读恢复() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for edit in [SynologyPhotoSimilarEdit.topPick(7), .remove([9]), .ungroup] {
                let detail = similarMutationFixture(space: space), capture = PhotosAlbumCheckpointCapture()
                let transport = MockHTTPTransport(steps: (accessResponses(teamPermission: "management", similarEnabled: true) + similarPreflight()).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
                let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
                let result = try await repository.performRecoverableAlbumMutation(.editSimilarGroup(detail, edit), operationID: UUID()) { capture.append($0) }
                XCTAssertEqual(result.state, .pendingReview)
                XCTAssertEqual(capture.values.first?.similarDetails?.submitted, false)
                let bytes = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("sample.jpg"))
                let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: bytes)
                XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.similarDetails?.submitted, true)
                let after = edit == .ungroup ? [] : edit == .remove([9]) ? [7, 8] : [7, 8, 9], top = edit == .topPick(7) ? 7 : 8
                let reader = MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: true) + [similarState(after, top: top), similarMemberResponse([7, 8, 9], group: after, top: top)])
                let fresh = try makeRepository(reader, profileID: detail.group.profileID); _ = try await fresh.access()
                try await fresh.restoreAlbumMutation(saved)
                let restored = try await fresh.reviewMutation(operationID: saved.operationID)
                XCTAssertEqual(restored.state, .confirmed); XCTAssertEqual(restored.photos.map(\.filename), ["sample.jpg", "sample.jpg", "sample.jpg"])
                let requests = try await reader.recordedRequests().dropFirst(4).map(decode)
                XCTAssertTrue(requests.allSatisfy { $0["method"] == "get" })
            }
        }
    }

    func test相似写前保存失败不发送分类修改() async throws {
        for submittedOnly in [false, true] {
            let detail = similarMutationFixture(), transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + similarPreflight())
            let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
            do {
                let result = try await repository.performRecoverableAlbumMutation(.editSimilarGroup(detail, .ungroup), operationID: UUID()) {
                    if !submittedOnly || $0.similarDetails?.submitted == true { throw CocoaError(.fileWriteNoPermission) }
                }
                XCTAssertEqual(result.state, .rejected)
            } catch { XCTAssertFalse(submittedOnly) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "ungroup" })
        }
    }

    func test相似意图保存后提交前取消不遗留未知操作() async throws {
        let detail = similarMutationFixture(), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + similarPreflight())
        let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
        let task = Task {
            try await repository.performRecoverableAlbumMutation(.editSimilarGroup(detail, .ungroup), operationID: UUID()) {
                capture.append($0)
                if $0.similarDetails?.submitted == false { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result.state, .rejected); XCTAssertEqual(capture.values.last?.rejected, true)
        XCTAssertEqual(capture.values.last?.similarDetails?.submitted, false)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "ungroup" })
    }

    func test相似恢复可保留超过百张的完整成员集合() throws {
        let profile = UUID(), group = SynologyPhotoSimilarGroup(profileID: profile, space: .personal, id: 31, photoIDs: Array(1...101), topPickID: 1)
        let photos = group.photoIDs.map { id in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: id), filename: "sample.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo") }
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(.init(group: group, photos: photos), .ungroup), operationID: UUID(), profileID: profile, userID: 12)
        XCTAssertEqual(try saved.reviewMutation().photos.count, 101)
        XCTAssertEqual(saved.similarDetails?.group.photoIDs, group.photoIDs)
    }

    func test未提交相似记录不能被回读状态误判为完成() async throws {
        let detail = similarMutationFixture()
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(detail, .ungroup), operationID: UUID(), profileID: detail.group.profileID, userID: 12)
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true)), repository = try makeRepository(transport, profileID: detail.group.profileID)
        _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
        let result = try await repository.reviewMutation(operationID: saved.operationID)
        XCTAssertEqual(result.state, .rejected); let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test相似剩余任务重新读取真实照片且拒绝变化的原件() async throws {
        for changed in [false, true] {
            let detail = similarMutationFixture()
            let saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(detail, .ungroup), operationID: UUID(), profileID: detail.group.profileID, userID: 12)
            let source = similarMemberResponse([7, 8, 9], group: [7, 8, 9])
            let members = changed ? DsmHTTPResponse(data: Data(String(decoding: source.data, as: UTF8.self).replacingOccurrences(of: "sample.jpg", with: "replaced.jpg").utf8), statusCode: 200) : source
            let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [members, similarState([7, 8, 9])])
            let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
            do {
                let command = try await repository.similarMutationTarget(saved)
                XCTAssertFalse(changed); XCTAssertEqual(command, .editSimilarGroup(detail, .ungroup))
            } catch { XCTAssertTrue(changed) }
            let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(requests.allSatisfy { $0["method"] == "get" })
        }
    }

    func test相似已确认记录重启后可撤销且只提交一次恢复成员() async throws {
        let detail = similarMutationFixture(), identities = [7, 8, 9].flatMap { [similarMemberResponse([$0], group: []), response(managedFolder)] }
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(detail, .ungroup), operationID: UUID(), profileID: detail.group.profileID, userID: 12)
        saved.similarDetails?.submitted = true; saved.similarDetails?.confirmed = true
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) +
            [similarState([]), similarMemberResponse([7, 8, 9], group: [])] + identities +
            [similarState([]), similarMemberResponse([7, 8, 9], group: []), response(emptySuccess), similarState([7, 8, 9]), similarMemberResponse([7, 8, 9], group: [7, 8, 9])])
        let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
        let command = try await repository.prepareSimilarUndo(saved), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.similarGroup, detail.group)
        let repeated = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(repeated.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "add_item" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "ungroup" })
    }

    func test相似撤销持久记录不能覆盖另一分组或冒用账号() async throws {
        for wrongAccount in [false, true] {
            let detail = similarMutationFixture()
            var saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(detail, .ungroup), operationID: UUID(), profileID: detail.group.profileID, userID: wrongAccount ? 13 : 12)
            saved.similarDetails?.submitted = true; saved.similarDetails?.confirmed = true
            let original = similarMemberResponse([7, 8, 9], group: [7, 8, 9])
            let other = DsmHTTPResponse(data: Data(String(decoding: original.data, as: UTF8.self).replacingOccurrences(of: "31", with: "32").utf8), statusCode: 200)
            let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + (wrongAccount ? [] : [similarState([]), other]))
            let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access()
            do { _ = try await repository.prepareSimilarUndo(saved); XCTFail("原账号或归组不符时不得恢复") } catch {}
            let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(requests.allSatisfy { $0["method"] == "get" }); if wrongAccount { XCTAssertTrue(requests.isEmpty) }
        }
    }

    func test相似持久结果要求原件身份与完整分组一致() async throws {
        let detail = similarMutationFixture()
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: .editSimilarGroup(detail, .remove([9])), operationID: UUID(), profileID: detail.group.profileID, userID: 12)
        saved.similarDetails?.submitted = true
        let source = similarMemberResponse([7, 8, 9], group: [7, 8])
        let replaced = DsmHTTPResponse(data: Data(String(decoding: source.data, as: UTF8.self).replacingOccurrences(of: "sample.jpg", with: "changed.jpg").utf8), statusCode: 200)
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [similarState([7, 8]), replaced])
        let repository = try makeRepository(transport, profileID: detail.group.profileID); _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
        do { _ = try await repository.reviewMutation(operationID: saved.operationID); XCTFail("替换后的原件不能追认为旧操作成功") } catch {}
        saved.similarDetails?.confirmed = true; saved.similarDetails?.resultingGroup = detail.group
        XCTAssertThrowsError(try saved.reviewMutation())
    }

    private func similarMutationFixture(space: SynologyPhotoSpace = .personal) -> SynologyPhotoSimilarDetail {
        let group = SynologyPhotoSimilarGroup(profileID: UUID(), space: space, id: 31, photoIDs: [7, 8, 9], topPickID: 8)
        return .init(group: group, photos: group.photoIDs.map { id in
            var photo = SynologyPhoto(id: .init(profileID: group.profileID, space: space, unitID: id), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
            photo.similarGroup = group; return photo
        })
    }
    private func similarMemberResponse(_ ids: [Int], group: [Int], top: Int = 8) -> DsmHTTPResponse {
        let list: [[String: Any]] = ids.map { id in
            var item: [String: Any] = ["id": id, "filename": "sample.jpg", "filesize": 128, "time": 50, "indexed_time": 60, "folder_id": 9, "type": "photo"]
            if group.count >= 2, group.contains(id) { item["similar"] = ["id": 31, "count": group.count, "top_pick": top, "item_id": group] }
            return item
        }
        return DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": list]]), statusCode: 200)
    }
    private func similarState(_ ids: [Int], top: Int = 8) -> DsmHTTPResponse {
        let list: [[String: Any]] = ids.count < 2 ? [] : [["id": 31, "count": ids.count, "top_pick": top, "item_id": ids]]
        return DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": list]]), statusCode: 200)
    }
    private func similarPreflight() -> [DsmHTTPResponse] {
        [7, 8, 9].flatMap { [similarMemberResponse([$0], group: []), response(managedFolder)] } +
            [similarState([7, 8, 9]), similarMemberResponse([7, 8, 9], group: [7, 8, 9])]
    }

    func test相似分类依据实际设置权限与能力开放() async throws {
        let category = response(#"{"success":true,"data":{"list":[{"id":"similar"}]}}"#)
        for space in [SynologyPhotoSpace.personal, .shared] {
            for enabled in [false, true] {
                let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: enabled) + [category]))
                _ = try await repository.access()
                let available = try await repository.categories(in: space)
                XCTAssertEqual(available.contains(.similar), enabled)
            }
            let prefix = space == .shared ? "SYNO.FotoTeam." : "SYNO.Foto."
            for suffix in ["Similar", "SimilarItem", "SimilarTimeline"] {
                let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: true) + [category]), omittedAPIs: [prefix + "Browse." + suffix])
                _ = try await repository.access()
                let available = try await repository.categories(in: space)
                XCTAssertFalse(available.contains(.similar))
            }
        }
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", similarEnabled: true))
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { _ = try await repository.similarTimeline(in: .shared); XCTFail("普通目录成员不能浏览共享全局分组") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let count = await transport.recordedRequests().count; XCTAssertEqual(count, 4)
    }

    func test相似时间线列表与组内照片保持来源顺序及推荐项() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", similarEnabled: true) +
                [response(personTimeline), response(similarPage()), response(similarGroups), response(similarMembers)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let days = try await repository.similarTimeline(in: space); XCTAssertEqual(days.count, 1)
            let page = try await repository.photos(in: space, query: .similar(startTime: 0, endTime: 100), offset: 3, limit: 1)
            XCTAssertTrue(page.hasMore); XCTAssertEqual(page.nextOffset, 4)
            let representative = try XCTUnwrap(page.items.first)
            XCTAssertEqual(representative.similarGroup?.photoIDs, [7, 8])
            let detail = try await repository.similarPhotos(for: representative)
            XCTAssertEqual(detail.photos.map(\.id.unitID), [7, 8]); XCTAssertEqual(detail.group.topPickID, 8)
            XCTAssertTrue(detail.photos.allSatisfy { $0.id.space == space && $0.similarGroup == detail.group })
            let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
            let prefix = space == .shared ? "SYNO.FotoTeam.Browse." : "SYNO.Foto.Browse."
            XCTAssertEqual(parameters.map { $0["api"] }, [prefix + "SimilarTimeline", prefix + "SimilarItem", prefix + "Similar", prefix + "Item"])
            XCTAssertEqual(parameters.map { $0["method"] }, ["get_similar", "list_similar", "get", "get"])
            XCTAssertEqual(parameters[0]["timeline_group_unit"], #""day""#)
            XCTAssertEqual(parameters[1]["offset"], "3"); XCTAssertEqual(parameters[1]["start_time"], "0")
            XCTAssertEqual(parameters[2]["id"], "[31]"); XCTAssertEqual(parameters[3]["id"], "[7,8]")
        }
    }

    func test相似列表拒绝缺失重复或错误分组成员() async throws {
        for group in ["null", #"{"id":31,"count":2,"top_pick":7,"item_id":[7,7]}"#,
                      #"{"id":31,"count":3,"top_pick":7,"item_id":[7,8]}"#,
                      #"{"id":31,"count":2,"top_pick":9,"item_id":[7,8]}"#,
                      #"{"id":31,"count":2,"top_pick":8,"item_id":[8,9]}"#] {
            let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [response(similarPage(group: group))]))
            _ = try await repository.access()
            do { _ = try await repository.photos(in: .personal, query: .similar(startTime: 0, endTime: 100), offset: 0, limit: 20); XCTFail("不能展示无效分组") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test相似详情拒绝跨来源过时分组和无关成员() async throws {
        for variant in 0..<5 {
            let responses = variant < 2 ? [] : variant == 2 ? [response(similarGroups.replacingOccurrences(of: "31", with: "32"))] :
                [response(similarGroups), response(variant == 3 ? itemPage : similarMembers.replacingOccurrences(of: "\"id\":8", with: "\"id\":9"))]
            let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [response(similarPage())] + responses)
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .similar(startTime: 0, endTime: 100), offset: 0, limit: 20)
            var photo = try XCTUnwrap(page.items.first)
            if variant < 2 { photo.similarGroup = .init(profileID: variant == 0 ? UUID() : photo.id.profileID, space: variant == 1 ? .shared : .personal, id: 31, photoIDs: [7, 8], topPickID: 8) }
            do { _ = try await repository.similarPhotos(for: photo); XCTFail("不能接受不匹配的分组") } catch {}
            let count = await transport.recordedRequests().count
            XCTAssertEqual(count, variant < 2 ? 5 : variant == 2 ? 6 : 7)
        }
    }

    func test相似分组读取期间权限撤回丢弃内容并停止后续请求() async throws {
        let base = MockHTTPTransport(responses: accessResponses(similarEnabled: true) + [response(similarPage()), response(similarGroups), response(#"{"success":true,"data":{"enabled":false}}"#)])
        let transport = AlbumReadBarrierTransport(base), repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .similar(startTime: 0, endTime: 100), offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        await transport.holdNext()
        let pending = Task { try await repository.similarPhotos(for: photo) }
        await transport.waitUntilHeld()
        do { _ = try await repository.access(); XCTFail("Photos停用") } catch {}
        await transport.release()
        do { _ = try await pending.value; XCTFail("拒绝旧授权结果") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await base.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Browse.Item" })
    }

    private let similarGroupJSON = #"{"id":31,"count":2,"top_pick":8,"item_id":[7,8]}"#
    private var similarGroups: String { #"{"success":true,"data":{"list":[\#(similarGroupJSON)]}}"# }
    private func similarPage(group: String? = nil) -> String {
        itemPage.replacingOccurrences(of: #""owner_user_id":12"#, with: #""similar":\#(group ?? similarGroupJSON),"owner_user_id":12"#)
    }
    private var similarMembers: String {
        let object = itemPage.components(separatedBy: "\"list\":[")[1].dropLast(3)
        let second = object.replacingOccurrences(of: "\"id\":7", with: "\"id\":8").replacingOccurrences(of: "\"unit_id\":7", with: "\"unit_id\":8")
        return #"{"success":true,"data":{"list":[\#(second),\#(object)]}}"#
    }

    func test分类拼图按类别和实际空间读取且保持人物缩略图类型() async throws {
        let image = DsmHTTPResponse(data: Data([1]), statusCode: 200, headers: ["Content-Type": "image/jpeg"])
        for space in [SynologyPhotoSpace.personal, .shared] {
            for category in SynologyPhotoCategory.allCases {
                let list = category == .person
                    ? #"{"success":true,"data":{"list":[{"id":31,"additional":{"thumbnail":{"cache_key":"fixture"}}}]}}"#
                    : #"{"success":true,"data":{"list":[{"id":31,"additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture"}}}]}}"#
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", peopleEnabled: true, conceptsEnabled: true, similarEnabled: true) + [response(list), image])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let images = try await repository.categoryPreviewImages(category, in: space)
                XCTAssertEqual(images, [Data([1])])
                let requests = await transport.recordedRequests(), parameters = try decode(requests[4])
                XCTAssertEqual(parameters["offset"], "0"); XCTAssertEqual(parameters["limit"], "4")
                XCTAssertEqual(parameters["additional"], "[\"thumbnail\"]")
                XCTAssertEqual(parameters["method"], category == .similar ? "list_similar" : "list"); XCTAssertNil(parameters["show_hidden"])
                XCTAssertEqual(parameters["show_more"], category == .person ? "true" : nil)
                XCTAssertEqual(parameters["type"], category == .videos ? "\"video\"" : nil)
                let suffix: String
                switch category {
                case .person: suffix = "Person"
                case .concept: suffix = "Concept"
                case .location: suffix = "Geocoding"
                case .tags: suffix = "GeneralTag"
                case .recentlyAdded: suffix = "RecentlyAdded"
                case .videos: suffix = "Item"
                case .similar: suffix = "SimilarItem"
                }
                XCTAssertEqual(parameters["api"], "SYNO.\(space == .shared ? "FotoTeam" : "Foto").Browse.\(suffix)")
                let url = try XCTUnwrap(requests.last?.url), query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertTrue(url.path.contains(space == .shared ? "/t/Thumbnail/" : "/p/Thumbnail/"))
                XCTAssertEqual(query.first { $0.name == "id" }?.value, category == .person ? "31" : "7")
                XCTAssertEqual(query.first { $0.name == "type" }?.value, category == .person ? "\"person\"" : "\"unit\"")
            }
        }
    }

    func test分类拼图单图失败继续其余封面且不清除完整分类缓存() async throws {
        let original = #"{"success":true,"data":{"list":[{"id":90,"name":"Fixture","additional":{"thumbnail":{"unit_id":9,"cache_key":"original"}}}]}}"#
        let previews = #"{"success":true,"data":{"list":[{"id":31,"additional":{"thumbnail":{"unit_id":7,"cache_key":"a"}}},{"id":32,"additional":{"thumbnail":{"unit_id":8,"cache_key":"b"}}}]}}"#
        let image = DsmHTTPResponse(data: Data([1]), statusCode: 200, headers: ["Content-Type": "image/jpeg"])
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(original), response(previews)]).map(MockHTTPTransport.Step.response)
            + [.urlError(.networkConnectionLost), .response(image), .response(image)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let collections = try await repository.categoryItems(.tags, offset: 0, limit: 20)
        let previewsData = try await repository.categoryPreviewImages(.tags, in: .personal)
        XCTAssertEqual(previewsData, [Data([1])])
        let originalData = try await repository.thumbnail(for: XCTUnwrap(collections.first), category: .tags)
        XCTAssertEqual(originalData, Data([1]))
    }

    func test分类拼图拒绝共享越权与重复编号且空列表不取图() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry"))
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { _ = try await repository.categoryPreviewImages(.videos, in: .shared); XCTFail("目录成员不能读取全局封面") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        for list in [#"{"success":true,"data":{"list":[]}}"#, #"{"success":true,"data":{"list":[{"id":1},{"id":1}]}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(list)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            if list.contains("\"id\"") {
                do { _ = try await repository.categoryPreviewImages(.videos, in: .personal); XCTFail("拒绝重复编号") }
                catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            } else {
                let images = try await repository.categoryPreviewImages(.videos, in: .personal); XCTAssertTrue(images.isEmpty)
            }
            let count = await transport.recordedRequests().count; XCTAssertEqual(count, 5)
        }
    }

    func test共享人物能力按管理权限人物设置与对应接口开放() async throws {
        let features: Set<SynologyPhotosManagementFeature> = [.peopleNames, .peopleMerge, .peopleFaces, .peopleCover, .peopleVisibility, .manualFaces]
        for (permission, enabled) in [("entry", true), ("management", false), ("management", true)] {
            let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(teamPermission: permission, peopleEnabled: enabled)))
            _ = try await repository.access()
            let available = await repository.managementFeatures(in: .shared)
            XCTAssertEqual(available.intersection(features), permission == "management" && enabled ? features : [])
        }
        let repository = try makeRepository(MockHTTPTransport(responses: sharedPeopleAccess), omittedAPIs: ["SYNO.FotoTeam.Upload.Face"])
        _ = try await repository.access()
        let available = await repository.managementFeatures(in: .shared)
        XCTAssertFalse(available.contains(.manualFaces)); XCTAssertTrue(available.contains(.peopleNames))
        XCTAssertTrue(SynologyPhotosRepository.discoveryAPIs.contains("SYNO.FotoTeam.Upload.Face"))
    }

    func test共享人物改名断网后只核对共享来源且操作编号去重() async throws {
        let original = SynologyPhotoCollection(id: 31, name: "Before", itemCount: 1, space: .shared)
        let transport = MockHTTPTransport(steps: (sharedPeopleAccess + [response(personList([(31, "Before", 1)]))]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(personList([(31, "After", 1)])))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.renamePerson(original, name: "After"), id = UUID()
        XCTAssertEqual(command.space, .shared)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.person?.space, .shared); XCTAssertEqual(result.person?.name, "After")
        let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"] == "SYNO.FotoTeam.Browse.Person" })
        XCTAssertEqual(parameters.filter { $0["method"] == "set" }.count, 1)
    }

    func test共享人物隐藏列表和批量显示结果保留来源且不重放() async throws {
        let before = visibilityList([(31, true), (32, true)]), after = visibilityList([(31, false), (32, true)])
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(before), response(before), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let states = try await repository.peopleVisibility(in: .shared)
        XCTAssertTrue(states.allSatisfy { $0.person.space == .shared })
        let command = SynologyPhotosMutation.setPeopleVisibility(states, visible: false), id = UUID()
        XCTAssertEqual(command.space, .shared)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1)
            XCTAssertEqual(result.personVisibility.first?.person.space, .shared)
        }
        let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"] == "SYNO.FotoTeam.Browse.Person" })
        XCTAssertEqual(parameters.first?["show_hidden"], "true")
        XCTAssertEqual(parameters.filter { $0["method"] == "show" }.count, 1)
    }

    func test共享人物合并核对同空间照片并集且返回同空间人物() async throws {
        let before = personList([(31, "Target", 1), (32, "Source", 1)]), after = personList([(31, "Combined", 1)])
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(before), response(personTimeline), response(itemPage), response(managedFolder), response(personTimeline), response(itemPage), response(before), response(emptySuccess), response(after), response(personTimeline), response(itemPage)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.mergePeople(target: .init(id: 31, name: "Target", itemCount: 1, space: .shared), sources: [.init(id: 32, name: "Source", itemCount: 1, space: .shared)], name: "Combined"), id = UUID()
        XCTAssertEqual(command.space, .shared)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.person?.space, .shared); XCTAssertEqual(result.removedPersonIDs, [32])
        }
        let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        XCTAssertEqual(parameters.filter { $0["method"] == "merge" }.count, 1)
        XCTAssertEqual(parameters.first { $0["method"] == "merge" }?["merged_id"], "[32]")
    }

    func test共享人脸移出和封面使用共享目标并保留原照片() async throws {
        for cover in [false, true] {
            let profile = UUID(), photo = facePhoto(profile, in: .shared), person = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1, space: .shared)
            let common = sharedPeopleAccess + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder)]
            let tail = cover ? [response(#"{"success":true,"data":{"id":31,"cover":71}}"#), response(#"{"success":true,"data":{"list":[{"id":31,"name":"Person","cover":71}]}}"#), response(personList([(31, "Person", 1)]))] : [response(emptySuccess), response(faceList([])), response(personList([]))]
            let transport = MockHTTPTransport(responses: common + tail), repository = try makeRepository(transport, profileID: profile)
            _ = try await repository.access()
            let command: SynologyPhotosMutation = cover ? .setPersonCover(person: person, photo: photo) : .removePersonFaces(person: person, faces: [.init(id: 71, personID: 31, photo: photo)])
            XCTAssertEqual(command.space, .shared)
            let result = try await repository.performMutation(command, operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.person?.space, .shared)
            XCTAssertEqual(result.removedFromPersonPhotoIDs, cover ? [] : [photo.id])
            let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(parameters.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
            XCTAssertFalse(parameters.contains { $0["method"] == "delete" })
        }
    }

    func test共享人脸分离到新人物须核对来源目标和名称() async throws {
        let profile = UUID(), photo = facePhoto(profile, in: .shared), person = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1, space: .shared)
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#), response(faceList([])), response(faceList([71])), response(personList([(32, "Target", 1)])), response(personList([(32, "Target", 1)]))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.reassignPersonFaces(person: person, faces: [.init(id: 71, personID: 31, photo: photo)], target: nil, name: "Target"), id = UUID()
        XCTAssertEqual(command.space, .shared)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.removedFromPersonPhotoIDs, [photo.id]); XCTAssertEqual(result.person?.space, .shared)
        }
        let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        XCTAssertEqual(parameters.filter { $0["method"] == "separate" }.count, 1)
    }

    func test共享手工人脸新增与上传及详情回读均沿共享且去重() async throws {
        let profile = UUID(), photo = facePhoto(profile, in: .shared)
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(manualList([])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(manualList([(72, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.editPhotoFaces(photo: photo, changes: [.add(addedFace())]), id = UUID()
        XCTAssertEqual(command.space, .shared)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.id, photo.id)
        }
        let requests = await transport.recordedRequests().dropFirst(4)
        let uploads = requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }
        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(uploads.first?.httpBody), as: UTF8.self).contains("SYNO.FotoTeam.Upload.Face"))
        let parameters = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        XCTAssertEqual(parameters.filter { $0["method"] == "add_face" }.count, 1)
    }

    func test共享图片人脸纠正和移除不误用个人目标() async throws {
        let profile = UUID(), photo = facePhoto(profile, in: .shared)
        let people = visibilityList([(32, true)]).replacingOccurrences(of: "Person", with: "Target")
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(manualList([(71, 31, "Person"), (72, 31, "Person")])), response(people), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#), response(emptySuccess), response(manualList([(71, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.editPhotoFaces(photo: photo, changes: [.reassign(manualRegion(71), person: .init(id: 32, name: "Target", space: .shared), name: "Target"), .remove(manualRegion(72))]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
        let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(parameters.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        XCTAssertEqual(parameters.first { $0["method"] == "separate" }?["target_id"], "32")
        XCTAssertEqual(parameters.first { $0["method"] == "delete_face" }?["face_id"], "[72]")
        XCTAssertFalse(parameters.contains { $0["method"] == "delete" })
    }

    func test同编号个人共享人脸封面互不覆盖() async throws {
        let profile = UUID(), personal = facePhoto(profile), shared = facePhoto(profile, in: .shared)
        let image = DsmHTTPResponse(data: Data([1]), statusCode: 200, headers: ["Content-Type":"image/jpeg"])
        let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(faceList([71])), response(faceList([71])), image, image])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let p = try await repository.personFaces(personID: 31, photos: [personal]), t = try await repository.personFaces(personID: 31, photos: [shared])
        _ = try await repository.thumbnail(for: try XCTUnwrap(p.first)); _ = try await repository.thumbnail(for: try XCTUnwrap(t.first))
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests[6].url?.path.contains("/p/Thumbnail/get") == true)
        XCTAssertTrue(requests[7].url?.path.contains("/t/Thumbnail/get") == true)
    }

    func test人物混合空间目标在写入前拒绝且不使用个人写接口() async throws {
        let profile = UUID(), photo = facePhoto(profile, in: .shared), person = SynologyPhotoCollection(id: 31, name: "Person", space: .shared)
        let wrong = SynologyPhotoCollection(id: 32, name: "Target")
        let commands: [SynologyPhotosMutation] = [
            .mergePeople(target: person, sources: [wrong], name: "Target"),
            .setPeopleVisibility([.init(person: person, isVisible: true), .init(person: wrong, isVisible: true)], visible: false),
            .setPersonCover(person: person, photo: facePhoto(profile)),
            .editPhotoFaces(photo: photo, changes: [.add(.init(temporaryID: "7-0", bounds: manualBounds, person: wrong, name: "Target", jpeg: faceJPEG))]),
            .reassignPersonFaces(person: person, faces: [.init(id: 71, personID: 31, photo: photo)], target: wrong, name: "Target")]
        for command in commands {
            let transport = MockHTTPTransport(responses: sharedPeopleAccess + [response(command.feature == .manualFaces ? manualList([]) : personList([(31, "Person", 1)]))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(command); XCTFail("不能跨空间复用人物编号") }
            catch let error as AppError { XCTAssertTrue([.invalidResponse, .permissionDenied, .conflict].contains(error.category)) }
            let parameters = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(parameters.allSatisfy { ["list", "list_face"].contains($0["method"] ?? "") && $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        }
    }

    private var sharedPeopleAccess: [DsmHTTPResponse] { accessResponses(teamPermission: "management", peopleEnabled: true) }

    func test共享分类统一发现且按设置权限和实际接口筛选() async throws {
        let list = #"{"success":true,"data":{"list":[{"id":"recently_added"},{"id":"person"},{"id":"concept"},{"id":"geocoding"},{"id":"general_tag"},{"id":"video"}]}}"#
        for enabled in [false, true] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false, peopleEnabled: enabled, conceptsEnabled: enabled) + [response(list)])
            let repository = try makeRepository(transport, omittedAPIs: ["SYNO.FotoTeam.Browse.Geocoding"])
            _ = try await repository.access()
            let categories = try await repository.categories(in: .shared)
            XCTAssertEqual(categories, enabled ? [.recentlyAdded, .person, .concept, .tags, .videos] : [.recentlyAdded, .tags, .videos])
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.last?["api"], "SYNO.Foto.Browse.Category")
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.FotoTeam.Browse.Category" })
        }
    }

    func test共享分类入口权限不足或人物未启用不发全局列表请求() async throws {
        for permission in ["entry", "management"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: permission))
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            if permission == "entry" {
                let categories = try await repository.categories(in: .shared)
                XCTAssertTrue(categories.isEmpty)
            }
            do { _ = try await repository.categoryItems(.person, in: .shared, offset: 0, limit: 20); XCTFail("共享人物须获得实际权限和设置") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 4)
        }
    }

    func test个人共享同编号人物封面缓存互不覆盖且沿来源读取() async throws {
        let personal = #"{"success":true,"data":{"list":[{"id":31,"name":"Personal","additional":{"thumbnail":{"unit_id":7,"cache_key":"personal"}}}]}}"#
        let shared = #"{"success":true,"data":{"list":[{"id":31,"name":"Shared","additional":{"thumbnail":{"cache_key":"shared"}}}]}}"#
        let image = DsmHTTPResponse(data: Data([1]), statusCode: 200, headers: ["Content-Type":"image/jpeg"])
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", peopleEnabled: true) + [response(personal), response(shared), image, image])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let p = try await repository.categoryItems(.person, offset: 0, limit: 20)
        let t = try await repository.categoryItems(.person, in: .shared, offset: 0, limit: 20)
        let personalPerson = try XCTUnwrap(p.first), sharedPerson = try XCTUnwrap(t.first)
        XCTAssertEqual(personalPerson.space, .personal); XCTAssertEqual(sharedPerson.space, .shared)
        XCTAssertNotEqual(personalPerson, sharedPerson)
        _ = try await repository.thumbnail(for: personalPerson, category: .person)
        _ = try await repository.thumbnail(for: sharedPerson, category: .person)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decode(requests[4])["api"], "SYNO.Foto.Browse.Person")
        XCTAssertEqual(try decode(requests[5])["api"], "SYNO.FotoTeam.Browse.Person")
        for (index, space, id, type) in [(6, "p", "7", "\"unit\""), (7, "t", "31", "\"person\"")] {
            let url = try XCTUnwrap(requests[index].url)
            XCTAssertTrue(url.path.contains("/\(space)/Thumbnail/get"))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "id" }?.value, id)
            XCTAssertEqual(query.first { $0.name == "type" }?.value, type)
        }
    }

    func test共享标签主题地点分页与日期读取不调用个人接口() async throws {
        for (category, suffix, parameter, version) in [(SynologyPhotoCategory.tags, "GeneralTag", "general_tag_id", "1"), (.concept, "Concept", "concept_id", "2"), (.location, "Geocoding", "geocoding_id", "1")] {
            let list = #"{"success":true,"data":{"list":[{"id":31,"name":"Fixture","additional":{"thumbnail":{"unit_id":7,"cache_key":"shared"}}}]}}"#
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", conceptsEnabled: true) + [response(list), response(#"{"success":true,"data":{"section":[]}}"#)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let items = try await repository.categoryItems(category, in: .shared, offset: 20, limit: 20)
            XCTAssertEqual(items.first?.space, .shared)
            let days = try await repository.categoryTimeline(category, id: 31, in: .shared)
            XCTAssertTrue(days.isEmpty)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests[4]["api"], "SYNO.FotoTeam.Browse." + suffix)
            XCTAssertEqual(requests[4]["version"], version); XCTAssertEqual(requests[4]["offset"], "20")
            XCTAssertEqual(requests[5]["api"], "SYNO.FotoTeam.Browse.Timeline")
            XCTAssertEqual(requests[5][parameter], "31")
        }
    }

    func test共享人物列表重新授权后不沿用旧封面() async throws {
        let list = #"{"success":true,"data":{"list":[{"id":31,"name":"Shared","additional":{"thumbnail":{"cache_key":"shared"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", peopleEnabled: true) + [response(list)] + accessResponses(teamPermission: "management", peopleEnabled: true))
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let items = try await repository.categoryItems(.person, in: .shared, offset: 0, limit: 20)
        _ = try await repository.access()
        do { _ = try await repository.thumbnail(for: try XCTUnwrap(items.first), category: .person); XCTFail("必须重新读取来源列表") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 9)
    }

    func testPNG本机三档预览上传个人共享路由和去重() async throws {
        let data = try PhotoPreviewFixture.image()
        let page = localPreviewPage(data)
        for space in SynologyPhotoSpace.allCases {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(page), response(page), response(managedFolder),
                DsmHTTPResponse(data: data, statusCode: 200), response(page), response(managedFolder), response(previewQueue(name: "fixture.png")),
                response(emptySuccess), response(page.replacingOccurrences(of: "fixture-revision", with: "local-revision"))])
            let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
            _ = try await repository.access()
            let photos = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20).items
            let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(photos)
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
                XCTAssertEqual(result.photos.first?.thumbnail?.revision, "local-revision")
            }
            let requests = await transport.recordedRequests()
            let uploads = requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }
            XCTAssertEqual(uploads.count, 1)
            let upload = try XCTUnwrap(uploads.first), body = try XCTUnwrap(upload.httpBody)
            let name = space == .personal ? "SYNO.Foto.Upload.ConvertedFile" : "SYNO.FotoTeam.Upload.ConvertedFile"
            XCTAssertNotNil(body.range(of: Data("\r\n\r\n\(name)\r\n".utf8)))
            XCTAssertNotNil(body.range(of: Data("name=\"unit_id\"\r\n\r\n7\r\n".utf8)))
            XCTAssertNil(body.range(of: Data("film_h264".utf8)))
            XCTAssertEqual(upload.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "fixture-token")
            XCTAssertFalse(upload.url?.absoluteString.contains("fixture-token") ?? true)
            for key in ["thumb_xl", "thumb_sm", "thumb_m"] {
                let jpeg = try localPreviewPart(upload, key: key), image = try PhotoPreviewFixture.decoded(jpeg)
                XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 40)
            }
            let forms = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(previewParameters)
            XCTAssertFalse(forms.contains { ["regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") })
            XCTAssertEqual(forms.filter { $0["method"] == "set_regenerating" }.count, 1)
        }
    }

    func testNAS明确失败后本机接续无需重新标记且不恢复成功项() async throws {
        let data = try PhotoPreviewFixture.image(type: .jpeg), page = localPreviewPage(data, name: "fixture.jpg")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), response(previewQueue(name: "fixture.jpg")), response(emptySuccess),
            DsmHTTPResponse(data: data, statusCode: 200), response(page), response(managedFolder), response(emptySuccess), response(page)])
        let socket = previewSocket(success: false)
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = await transport.recordedRequests()
        let forms = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(previewParameters)
        XCTAssertEqual(forms.filter { $0["method"] == "set_regenerating" }.count, 1)
        XCTAssertEqual(forms.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(forms.contains { $0["method"] == "restore_from_regenerating" })
    }

    func test事件订阅无法建立时本机仍可独立重建() async throws {
        let data = try PhotoPreviewFixture.image(type: .jpeg), page = localPreviewPage(data, name: "fixture.jpg")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder),
            DsmHTTPResponse(data: data, statusCode: 200), response(page), response(managedFolder), response(previewQueue(name: "fixture.jpg")), response(emptySuccess), response(page)])
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
    }

    func testPNG本机上传明确拒绝才转NAS且不重复标记() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
            response(page), response(managedFolder), response(previewQueue(name: "fixture.png")), response(#"{"success":false,"error":{"code":1000}}"#), response(emptySuccess), response(page)])
        let socket = previewSocket(success: true)
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = await transport.recordedRequests()
        let forms = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(previewParameters)
        XCTAssertEqual(forms.filter { $0["method"] == "set_regenerating" }.count, 1)
        XCTAssertEqual(forms.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
    }

    func test本机与NAS均明确失败只恢复一次且不确认成功() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
            response(page), response(managedFolder), response(previewQueue(name: "fixture.png")), response(#"{"success":false,"error":{"code":1000}}"#), response(emptySuccess), response(emptySuccess)])
        let socket = previewSocket(success: false)
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let command = SynologyPhotosMutation.regeneratePreviews(photos), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .rejected); XCTAssertEqual(result.completedCount, 0)
        }
        let requests = await transport.recordedRequests()
        let forms = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(previewParameters)
        XCTAssertEqual(forms.filter { $0["method"] == "restore_from_regenerating" }.count, 1)
    }

    func test本机上传成功后照片身份改变不把旧预览归到新照片() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
            response(page), response(managedFolder), response(previewQueue(name: "fixture.png")), response(emptySuccess), response(page.replacingOccurrences(of: "fixture.png", with: "changed.png"))])
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.photos.isEmpty)
    }

    func test本机上传回执丢失或畸形不重传不切换NAS() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        for ending in [MockHTTPTransport.Step.urlError(.networkConnectionLost), .response(response(#"{"success":true,"error":{"code":1000}}"#)), .response(response(#"{"success":false}"#))] {
            let responses = accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
                response(page), response(managedFolder), response(previewQueue(name: "fixture.png"))]
            let transport = MockHTTPTransport(steps: responses.map(MockHTTPTransport.Step.response) + [ending])
            let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
            _ = try await repository.access()
            let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
            let command = SynologyPhotosMutation.regeneratePreviews(photos), id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .pendingReview)
            }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }.count, 1)
            let forms = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(previewParameters)
            XCTAssertFalse(forms.contains { ["regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") })
        }
    }

    func test转换期间原件改变在任何写入前拒绝() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
            response(page.replacingOccurrences(of: "fixture.png", with: "changed.png"))])
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { throw PhotosPreviewEventError.disconnected })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected)
        let requests = try await transport.recordedRequests().map(previewParameters)
        XCTAssertFalse(requests.contains { $0["method"] == "set_regenerating" || $0["method"] == "upload" })
    }

    func test本机无法解码仍可NAS转换不上传无效JPEG() async throws {
        let data = Data("invalid image".utf8), page = localPreviewPage(data)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page), response(managedFolder), DsmHTTPResponse(data: data, statusCode: 200),
            response(previewQueue(name: "fixture.png")), response(emptySuccess), response(page)])
        let socket = previewSocket(success: true)
        let repository = try makeRepository(transport, convertedPreview: true, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
    }

    private func previewParameters(_ request: URLRequest) throws -> [String: String] {
        if request.httpBody != nil { return try decode(request) }
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func localPreviewPage(_ data: Data, name: String = "fixture.png") -> String {
        itemPage.replacingOccurrences(of: "sample.jpg", with: name).replacingOccurrences(of: #""filesize":128"#, with: "\"filesize\":\(data.count)")
    }
    private func localPreviewPart(_ request: URLRequest, key: String) throws -> Data {
        let boundary = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
        let body = try XCTUnwrap(request.httpBody)
        let header = Data("name=\"\(key)\"; filename=\"\(key).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let start = try XCTUnwrap(body.range(of: header)).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)".utf8), in: start..<body.endIndex)).lowerBound
        return body.subdata(in: start..<end)
    }

    func test未完成预览队列按空间读取身份权限且不写入() async throws {
        for space in SynologyPhotoSpace.allCases {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(previewQueue()), response(itemPage), response(managedFolder)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let photos = try await repository.pendingPreviewRegenerations(in: space)
            XCTAssertEqual(photos.count, 1); XCTAssertEqual(photos.first?.id.space, space)
            XCTAssertEqual(photos.first?.thumbnail?.revision, "fixture-revision")
            let requests = try await transport.recordedRequests().map(decode)
            let queue = try XCTUnwrap(requests.first { $0["method"] == "list_regenerating" })
            XCTAssertEqual(queue["api"], space == .personal ? "SYNO.Foto.RegeneratePreview" : "SYNO.FotoTeam.RegeneratePreview")
            XCTAssertFalse(requests.contains { ["set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") })
        }
    }

    func test未完成队列拒绝重复编号错误原件和无目录权限() async throws {
        let duplicate = #"{"success":true,"data":{"list":[{"unit_id":7,"type":"photo","filename":"sample.jpg"},{"unit_id":7,"type":"photo","filename":"sample.jpg"}]}}"#
        for responses in [
            [response(duplicate)],
            [response(previewQueue()), response(itemPage.replacingOccurrences(of: "sample.jpg", with: "different.jpg"))],
            [response(previewQueue()), response(itemPage), response(#"{"success":false,"error":{"code":105}}"#)]
        ] {
            let transport = MockHTTPTransport(responses: accessResponses() + responses)
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.pendingPreviewRegenerations(in: .personal); XCTFail("错误或无权目标不能进入恢复选择") } catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "regenerate_preview_by_nas" })
        }
    }

    func test恢复个人共享预览复查队列后继续且不重新标记() async throws {
        for space in SynologyPhotoSpace.allCases {
            let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "resumed-revision")
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(previewQueue()),
                response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess), response(updated)])
            let socket = previewSocket(success: true)
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let page = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20)
            let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items, resuming: true)
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.thumbnail?.revision, "resumed-revision")
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "list_regenerating" }.count, 2)
            XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
            XCTAssertFalse(requests.contains { $0["method"] == "set_regenerating" || $0["method"] == "restore_from_regenerating" })
        }
    }

    func test恢复提交前队列已变化不重建也不留下待核对写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(previewQueue()), response(itemPage),
            response(managedFolder), response(#"{"success":true,"data":{"list":[]}}"#)])
        let socket = previewSocket(success: true)
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(page.items, resuming: true), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "regenerate_preview_by_nas" || $0["method"] == "set_regenerating" })
    }

    func test丢失通知用原件身份新预览和两次队列核对恢复完成() async throws {
        let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "recovered-revision")
        let emptyQueue = response(#"{"success":true,"data":{"list":[]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(previewQueue()), response(emptySuccess), emptyQueue, response(updated), emptyQueue, response(updated)])
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.thumbnail?.revision, "recovered-revision")
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "restore_from_regenerating" })
    }

    func test原操作待核对随后恢复只读确认且不再提交() async throws {
        let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "later-revision")
        let emptyQueue = response(#"{"success":true,"data":{"list":[]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(previewQueue()), response(emptySuccess), response(previewQueue()),
            emptyQueue, response(updated), emptyQueue, response(updated)])
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID()
        let pending = try await repository.performMutation(.regeneratePreviews(page.items), operationID: id) { _, _ in }
        XCTAssertEqual(pending.state, .pendingReview)
        let resolved = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(resolved.state, .confirmed); XCTAssertEqual(resolved.photos.first?.thumbnail?.revision, "later-revision")
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "restore_from_regenerating" })
    }

    func test恢复核对不把列表过期版本误判为本次重建完成() async throws {
        let current = itemPage.replacingOccurrences(of: "fixture-revision", with: "already-updated-before-submit")
        let emptyQueue = response(#"{"success":true,"data":{"list":[]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(current), response(managedFolder),
            response(previewQueue()), response(emptySuccess), emptyQueue, response(current)])
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.photos.isEmpty)
        let requests = try await transport.recordedRequests().map(decode)
        let preflight = try XCTUnwrap(requests.first { $0["method"] == "get" && $0["api"] == "SYNO.Foto.Browse.Item" })
        XCTAssertEqual(preflight["additional"], #"["thumbnail"]"#)
    }

    func test恢复核对时任务仍在队列不读取旧预览冒充完成() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(previewQueue()), response(emptySuccess), response(previewQueue())])
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["api"] == "SYNO.Foto.Browse.Item" && $0["method"] == "get" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
    }

    func test任务消失但版本不变或原件变化仍是未知且不重放() async throws {
        let emptyQueue = response(#"{"success":true,"data":{"list":[]}}"#)
        for current in [itemPage, itemPage.replacingOccurrences(of: "sample.jpg", with: "different.jpg"),
                        itemPage.replacingOccurrences(of: "fixture-revision", with: "")] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
                response(previewQueue()), response(emptySuccess), emptyQueue, response(current)])
            let socket = PreviewSocketFixture([previewOpening, "40", "41"])
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.photos.isEmpty)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
            XCTAssertFalse(requests.contains { $0["method"] == "restore_from_regenerating" })
        }
    }

    func test预览角色共享下载者可完成重建但不能编辑原件() async throws {
        let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"download":true"#)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(folder),
            response(previewQueue()), response(emptySuccess), response(itemPage), response(itemPage), response(folder)])
        let socket = previewSocket(success: true)
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let photos = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20).items
        let command = SynologyPhotosMutation.regeneratePreviews(photos), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
        do { try await repository.prepareMutation(.edit(photos, .rating(3))); XCTFail("下载不能赋予原件编辑权限") } catch { }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "set_regenerating" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "set_rating" })
    }

    func test预览角色相册提供者与冻结多选沿相册核对且不需要原目录管理() async throws {
        for (space, frozen) in [(SynologyPhotoSpace.personal, false), (.shared, false), (.personal, true), (.shared, true)] {
            let profile = UUID(), owner = space == .shared ? 0 : 99
            let page = collaborationPage().replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":\#(owner)"#)
            let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: owner, providerUserID: 12))
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(page), response(collaborationAlbum().replacingOccurrences(of: #""type":"normal""#, with: #""type":"normal","freeze_album":\#(frozen)"#)),
                response(previewQueue()), response(emptySuccess), response(page)])
            let socket = previewSocket(success: true)
            let repository = try makeRepository(transport, profileID: profile, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews([photo])
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.albumContext, photo.albumContext)
            let requests = try await transport.recordedRequests().map(decode)
            let reads = requests.filter { $0["api"] == "SYNO.Foto.Browse.Item" && $0["method"] == "get" }
            XCTAssertEqual(reads.count, 2); XCTAssertTrue(reads.allSatisfy { $0["album_id"] == "21" })
            XCTAssertFalse(requests.contains { $0["api"]?.hasSuffix("Browse.Folder") == true })
            let writes = requests.filter { $0["method"] == "set_regenerating" || $0["method"] == "regenerate_preview_by_nas" }
            XCTAssertEqual(writes.count, 2)
            XCTAssertTrue(writes.allSatisfy { $0["api"] == (space == .shared ? "SYNO.FotoTeam.RegeneratePreview" : "SYNO.Foto.RegeneratePreview") && $0["album_id"] == nil })
        }
    }

    func test预览角色拒绝失去提供者身份及空间关闭() async throws {
        for mode in ["provider", "space", "sharedDownload", "ownerWithoutProvider"] {
            let shared = mode == "sharedDownload", profile = UUID(), owner = shared ? 0 : (mode == "ownerWithoutProvider" ? 12 : 99)
            let page = collaborationPage(provider: mode == "provider" || shared || mode == "ownerWithoutProvider" ? 98 : 12)
                .replacingOccurrences(of: #""owner_user_id":99"#, with: #""owner_user_id":\#(owner)"#)
            let album = collaborationAlbum()
            let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"download":true"#)
            let photo = SynologyPhoto(id: .init(profileID: profile, space: shared ? .shared : .personal, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: owner, providerUserID: 12))
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: mode != "space") + [response(page), response(album), response(folder)])
            let repository = try makeRepository(transport, profileID: profile)
            _ = try await repository.access()
            do { try await repository.prepareMutation(.regeneratePreviews([photo])); XCTFail("当前资格不足时不能提交：\(mode)") } catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"]?.contains("RegeneratePreview") == true })
        }
    }

    func test预览角色本机转换后撤回共享下载权限不上传() async throws {
        let data = try PhotoPreviewFixture.image(), page = localPreviewPage(data)
        let granted = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"download":true"#)
        let revoked = granted.replacingOccurrences(of: #""download":true"#, with: #""download":false"#)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(page), response(page), response(granted),
            DsmHTTPResponse(data: data, statusCode: 200), response(page), response(revoked)])
        let repository = try makeRepository(transport, convertedPreview: true)
        _ = try await repository.access()
        let photos = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20).items
        let result = try await repository.performMutation(.regeneratePreviews(photos), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected); XCTAssertEqual(result.completedCount, 0)
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        let forms = try requests.map(previewParameters)
        XCTAssertFalse(forms.contains { $0["method"] == "set_regenerating" })
    }

    func test预览重建个人共享均等待明确完成且同编号不重复写() async throws {
        for space in SynologyPhotoSpace.allCases {
            let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "regenerated-revision")
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder),
                response(previewQueue()), response(emptySuccess), response(updated)])
            let socket = previewSocket(success: true)
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let page = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20)
            let operation = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
            XCTAssertEqual(result.photos.first?.thumbnail?.revision, "regenerated-revision")
            _ = try await repository.performMutation(command, operationID: operation) { _, _ in }
            let requests = try await transport.recordedRequests().map(decode)
            let writes = requests.filter { ["set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") }
            XCTAssertEqual(writes.count, 2)
            XCTAssertTrue(writes.allSatisfy { $0["api"] == (space == .personal ? "SYNO.Foto.RegeneratePreview" : "SYNO.FotoTeam.RegeneratePreview") })
            XCTAssertEqual(writes[0]["item_id"], "[7]"); XCTAssertEqual(writes[1]["unit_id"], "7")
            let sent = await socket.sent
            XCTAssertEqual(sent.count, 2)
        }
    }

    func test预览通知重连个人共享完成均不重复发送重建且回读新预览() async throws {
        for space in SynologyPhotoSpace.allCases {
            let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "reconnected-revision")
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder),
                response(previewQueue()), response(emptySuccess), response(updated)])
            let original = PreviewSocketFixture([previewOpening, "40", "41"]), recovered = previewSocket(success: true)
            let factory = PreviewSocketSequence([recovered])
            let repository = try makeRepository(transport, previewEvents: {
                SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
            })
            _ = try await repository.access()
            let page = try await repository.photos(in: space, query: .recentlyAdded, offset: 0, limit: 20)
            let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.thumbnail?.revision, "reconnected-revision")
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().map(decode)
            let writes = requests.filter { ["set_regenerating", "regenerate_preview_by_nas", "restore_from_regenerating"].contains($0["method"] ?? "") }
            XCTAssertEqual(writes.count, 2); XCTAssertEqual(factory.calls, 1)
            XCTAssertTrue(writes.allSatisfy { $0["api"] == (space == .personal ? "SYNO.Foto.RegeneratePreview" : "SYNO.FotoTeam.RegeneratePreview") })
        }
    }

    func test预览重连明确失败只恢复一次且身份变化不冒充完成() async throws {
        for completed in [false, true] {
            let final = completed ? response(itemPage.replacingOccurrences(of: "sample.jpg", with: "replaced.jpg")) : response(emptySuccess)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess), final])
            let original = PreviewSocketFixture([previewOpening, "40", "41"]), recovered = previewSocket(success: completed)
            let factory = PreviewSocketSequence([recovered])
            let repository = try makeRepository(transport, previewEvents: {
                SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
            })
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, completed ? .pendingReview : .rejected)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
            XCTAssertEqual(requests.filter { $0["method"] == "restore_from_regenerating" }.count, completed ? 0 : 1)
        }
    }

    func test预览持续断线用尽重连仍保留未知且不恢复标记() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess)])
        let original = PreviewSocketFixture([previewOpening, "40", "41"])
        let factory = PreviewSocketSequence((0..<3).map { _ in PreviewSocketFixture([previewOpening, "40", "41"]) })
        let repository = try makeRepository(transport, previewEvents: {
            SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
        })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertEqual(result.completedCount, 0)
        }
        XCTAssertEqual(factory.calls, 3)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "restore_from_regenerating" })
    }

    func test预览重建明确失败才恢复标记且不声称成功() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess), response(emptySuccess)])
        let socket = previewSocket(success: false)
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected); XCTAssertEqual(result.completedCount, 0)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.last?["method"], "restore_from_regenerating")
        XCTAssertEqual(requests.last?["unit_id"], "[7]")
    }

    func test预览重建丢失完成事件只核对不重发也不清理未知任务() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess)])
        let socket = PreviewSocketFixture([previewOpening, "40", "41"])
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
        _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.photos.isEmpty)
        }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "restore_from_regenerating" })
    }

    func test预览订阅失败在写入前结束且空列表不冒充完成() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder)])
        let repository = try makeRepository(transport, previewEvents: { throw PhotosPreviewEventError.disconnected })
        _ = try await repository.access()
        do { try await repository.prepareMutation(.regeneratePreviews([])); XCTFail("空目标不能提交") } catch {}
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .rejected)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"]?.contains("RegeneratePreview") == true })
    }

    func test预览队列返回身份不符不继续重建() async throws {
        for queue in [previewQueue(id: 8), previewQueue(name: "other.jpg"), previewQueue(type: "video"), #"{"success":true,"data":{"list":[]}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(queue)])
            let socket = previewSocket(success: true)
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "regenerate_preview_by_nas" })
            let closed = await socket.closed
            XCTAssertTrue(closed)
        }
    }

    func test预览重建无管理权限或缺少共享接口不能写入() async throws {
        for missing in [false, true] {
            let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(folder)])
            let repository = try makeRepository(transport, omittedAPIs: missing ? ["SYNO.FotoTeam.RegeneratePreview"] : [], previewEvents: { throw PhotosPreviewEventError.disconnected })
            _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            do { try await repository.prepareMutation(.regeneratePreviews(page.items)); XCTFail("不能用个人能力或上传权限代替") } catch {}
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"]?.contains("RegeneratePreview") == true })
        }
    }

    func test批量预览重建保留成功项且明确失败仅恢复该项() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(itemPage.utf8)) as? [String: Any])
        var data = try XCTUnwrap(root["data"] as? [String: Any])
        let first = try XCTUnwrap((data["list"] as? [[String: Any]])?.first)
        var second = first; second["id"] = 8; second["filename"] = "other.jpg"
        data["list"] = [first, second]; root["data"] = data
        let batchPage = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        data["list"] = [second]; root["data"] = data
        let secondPage = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        for secondSuccess in [true, false] {
            var replies = accessResponses() + [response(batchPage), response(itemPage), response(managedFolder), response(secondPage), response(managedFolder),
                response(previewQueue()), response(emptySuccess), response(previewQueue(id: 8, name: "other.jpg")), response(emptySuccess)]
            if !secondSuccess { replies.append(response(emptySuccess)) }
            replies.append(response(itemPage)); if secondSuccess { replies.append(response(secondPage)) }
            let transport = MockHTTPTransport(responses: replies)
            let opening = previewOpening
            let repository = try makeRepository(transport, previewEvents: {
                SynologyPhotosPreviewEvents(socket: PreviewSocketFixture([opening, "40",
                    #"42["regenerate-preview",{"data":{"idUnit":7,"success":true}}]"#,
                    #"42["regenerate-preview",{"data":{"idUnit":8,"success":\#(secondSuccess)}}]"#]))
            })
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let id = UUID(), command = SynologyPhotosMutation.regeneratePreviews(page.items)
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, secondSuccess ? .confirmed : .partial)
            XCTAssertEqual(result.photos.map(\.id.unitID), secondSuccess ? [7, 8] : [7])
            XCTAssertEqual(result.completedCount, secondSuccess ? 2 : 1)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "regenerate_preview_by_nas" }.count, 2)
            let restores = requests.filter { $0["method"] == "restore_from_regenerating" }
            XCTAssertEqual(restores.count, secondSuccess ? 0 : 1)
            if !secondSuccess { XCTAssertEqual(restores.first?["unit_id"], "[8]") }
        }
    }

    func test预览完成后身份改变或失败恢复未确认仍保持未知() async throws {
        for completed in [true, false] {
            let final = completed ? response(itemPage.replacingOccurrences(of: "sample.jpg", with: "replaced.jpg")) : response(#"{"success":false,"error":{"code":105}}"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess), final])
            let socket = previewSocket(success: completed)
            let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: socket) })
            _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.regeneratePreviews(page.items), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
    }

    private let previewOpening = #"0{"sid":"SANITIZED","pingInterval":25000,"pingTimeout":20000}"#
    private func previewSocket(success: Bool) -> PreviewSocketFixture {
        PreviewSocketFixture([previewOpening, "40", #"42["regenerate-preview",{"data":{"idUnit":7,"success":\#(success)}}]"#])
    }
    private func previewQueue(id: Int = 7, name: String = "sample.jpg", type: String = "photo") -> String {
        #"{"success":true,"data":{"list":[{"unit_id":\#(id),"type":"\#(type)","filename":"\#(name)"}]}}"#
    }

    func test共享编辑评级描述日期与标签使用共享接口并自动回读() async throws {
        for kind in 0..<6 {
            let updated: String
            switch kind {
            case 0: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#)
            case 1: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"description":"Fixture description""#)
            case 2, 3: updated = itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":100"#)
            case 4: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[{"id":8,"name":"Fixture"}]"#)
            default: updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[]"#)
            }
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [response(itemPage), response(itemPage), response(managedFolder), response(emptySuccess), response(updated)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let command: SynologyPhotosMutation
            switch kind {
            case 0: command = .edit(page.items, .rating(4))
            case 1: command = .edit(page.items, .description("Fixture description"))
            case 2: command = .edit(page.items, .takenAt(Date(timeIntervalSince1970: 100)))
            case 3: command = .shiftDates(page.items, seconds: 50)
            case 4: command = .addTags(page.items, ids: [8])
            default: command = .removeTags(page.items, ids: [8])
            }
            let id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.id.space, .shared)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(requests.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
            XCTAssertEqual(requests.filter { ["set", "add_tag", "remove_tag"].contains($0["method"] ?? "") }.count, 1)
        }
    }

    func test共享管理不能用上传权限代替管理权限() async throws {
        for deleting in [false, true] {
            let uploadOnly = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(uploadOnly)])
            let repository = try makeRepository(transport, deletionEnabled: true)
            _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            do {
                if deleting { _ = try await repository.deletePhoto(XCTUnwrap(page.items.first), operationID: UUID()) }
                else { _ = try await repository.performMutation(.edit(page.items, .rating(4)), operationID: UUID()) { _, _ in } }
                XCTFail("只有上传权限不能修改或删除已有照片")
            } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["set", "delete"].contains($0["method"] ?? "") })
        }
    }

    func test混合来源评级绝对与相对日期分别使用所属空间接口() async throws {
        let shared = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#).replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":0"#)
        for mode in 0..<3 {
            let first = mode == 0 ? itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#) : itemPage.replacingOccurrences(of: #""time":50"#, with: #""time":70"#)
            let second = mode == 0 ? shared.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#) : shared.replacingOccurrences(of: #""time":50"#, with: #""time":70"#)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(itemPage), response(shared), response(itemPage), response(managedFolder), response(shared), response(managedFolder), response(emptySuccess), response(emptySuccess), response(first), response(second)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let personal = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let team = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let photos = personal.items + team.items
            let command: SynologyPhotosMutation = mode == 0 ? .edit(photos, .rating(4)) : (mode == 1 ? .edit(photos, .takenAt(Date(timeIntervalSince1970: 70))) : .shiftDates(photos, seconds: 20))
            let id = UUID(), result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
            XCTAssertEqual(result.photos.map(\.id.space), [.personal, .shared])
            let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result, repeated)
            let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
            XCTAssertEqual(writes.map { $0["api"] }, ["SYNO.Foto.Browse.Item", "SYNO.FotoTeam.Browse.Item"])
            XCTAssertEqual(writes.map { $0["id"] }, ["[7]", "[8]"])
            XCTAssertEqual(writes.map { $0[mode == 0 ? "rating" : "time"] }, mode == 0 ? ["4", "4"] : ["70", "70"])
        }
    }

    func test混合评级第二空间拒绝或逐项失败保留第一空间成功() async throws {
        let shared = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
        let updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#)
        for rejected in [false, true] {
            let failure = rejected ? #"{"success":false,"error":{"code":105}}"# : #"{"success":true,"data":{"error_list":[{"id":8,"error":105}]}}"#
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(itemPage), response(shared), response(itemPage), response(managedFolder), response(shared), response(managedFolder), response(emptySuccess), response(failure), response(updated)] + (rejected ? [] : [response(shared)]))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let personal = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let team = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let id = UUID(), command = SynologyPhotosMutation.edit(personal.items + team.items, .rating(4))
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.photos.map(\.id.space), [.personal]); XCTAssertEqual(result.completedCount, 1)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
            XCTAssertEqual(writes.count, 2)
        }
    }

    func test混合编辑第一空间断网不发送第二空间且核对后可只继续未处理项() async throws {
        let shared = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
        let updated = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"rating":4"#)
        let initial = accessResponses(teamPermission: "management") + [response(itemPage), response(shared), response(itemPage), response(managedFolder), response(shared), response(managedFolder)]
        let transport = MockHTTPTransport(steps: initial.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(itemPage)), .response(response(updated))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let personal = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let team = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.edit(personal.items + team.items, .rating(4))
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("未知写不能重复") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let result = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.photos.map(\.id.space), [.personal])
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Browse.Item")
    }

    func test混合编辑共享管理权或第二空间能力缺失时不会先写个人空间() async throws {
        for manager in [false, true] {
            let profile = UUID()
            let photos = SynologyPhotoSpace.allCases.map { space in SynologyPhoto(id: .init(profileID: profile, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo") }
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: manager ? "management" : "entry"))
            let repository = try makeRepository(transport, profileID: profile, omittedAPIs: manager ? ["SYNO.FotoTeam.Browse.Item"] : [])
            _ = try await repository.access()
            do { _ = try await repository.performMutation(.edit(photos, .rating(4)), operationID: UUID()) { _, _ in }; XCTFail("必须先预检两空间") }
            catch let error as AppError { XCTAssertEqual(error.category, manager ? .apiUnavailable : .permissionDenied) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
    }

    func test混合预览重建同编号照片分别订阅并写入对应空间() async throws {
        let updated = itemPage.replacingOccurrences(of: "fixture-revision", with: "regenerated-revision")
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(itemPage), response(itemPage), response(itemPage), response(managedFolder), response(itemPage), response(managedFolder), response(previewQueue()), response(emptySuccess), response(previewQueue()), response(emptySuccess), response(updated), response(updated)])
        let opening = previewOpening
        let repository = try makeRepository(transport, previewEvents: { SynologyPhotosPreviewEvents(socket: PreviewSocketFixture([opening, "40", #"42["regenerate-preview",{"data":{"idUnit":7,"success":true}}]"#])) })
        _ = try await repository.access()
        let personal = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let team = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.regeneratePreviews(personal.items + team.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.map(\.id.space), [.personal, .shared]); XCTAssertEqual(result.completedCount, 2)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "regenerate_preview_by_nas" }
        XCTAssertEqual(writes.map { $0["api"] }, ["SYNO.Foto.RegeneratePreview", "SYNO.FotoTeam.RegeneratePreview"])
    }

    func test共享修改拒绝不支持的混合描述和非所有者相册目标() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(itemPage), response(itemPage), response(itemPage), response(managedFolder), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":99}]}}"#)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let shared = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let personal = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        for command in [SynologyPhotosMutation.edit(shared.items + personal.items, .description("Fixture")), .addToAlbum(id: 3, photos: shared.items), .createTag(name: "Fixture", photos: shared.items)] {
            do { try await repository.prepareMutation(command); XCTFail("混合描述、错误标签来源或非所有者相册不得写入") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["set", "create", "add_item"].contains($0["method"] ?? "") })
    }

    func test共享标签新建应用和空标签均固定空间回读() async throws {
        for apply in [false, true] {
            let tagged = itemPage.replacingOccurrences(of: #""orientation":1"#, with: #""orientation":1,"tag":[{"id":8,"name":"Fixture tag"}]"#)
            var replies = [response(itemPage)]
            if apply { replies += [response(itemPage), response(managedFolder)] }
            replies.append(response(#"{"success":true,"data":{"tag":{"id":8,"name":"Fixture tag"}}}"#))
            if apply { replies.append(response(emptySuccess)) }
            replies.append(response(#"{"success":true,"data":{"list":[{"id":8,"name":"Fixture tag"}]}}"#))
            if apply { replies.append(response(tagged)) }
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + replies)
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let command = SynologyPhotosMutation.createTag(name: "Fixture tag", photos: apply ? page.items : [], space: .shared), id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.tag?.id, 8)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertTrue(requests.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
            XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        }
    }

    func test跨空间移动复制固定源接口目标空间并验证后台回执() async throws {
        for (source, targetSpace, move) in [(SynologyPhotoSpace.personal, SynologyPhotoSpace.shared, true), (.personal, .shared, false), (.shared, .personal, false)] {
            let sourceFolder = move ? managedFolder : managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"download":true"#)
            // 个人源目录仍沿现有原件权限；共享复制只需要下载权限。
            let readable = source == .personal ? managedFolder : sourceFolder
            let uploadFolder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
            let owner = targetSpace == .shared ? 0 : 12
            let receipt = "{\"success\":true,\"data\":{\"task_info\":{\"id\":91,\"total\":1,\"target_folder\":{\"id\":9,\"owner_user_id\":\(owner)}}}}"
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(readable), response(uploadFolder), response(receipt),
                response(#"{"success":true,"data":{"list":[{"id":91,"status":"done","completion":1,"error":0,"skip":0,"overwrite":0}]}}"#), response(uploadFolder)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: source, query: .recentlyAdded, offset: 0, limit: 20)
            let command: SynologyPhotosMutation = move ? .move(page.items, folderID: 9, destinationSpace: targetSpace) : .copy(page.items, folderID: 9, destinationSpace: targetSpace)
            let id = UUID(), result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
            XCTAssertTrue(result.photos.isEmpty, "跨空间不能假设原照片编号与归属不变")
            let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(repeated, result)
            let requests = try await transport.recordedRequests().map(decode)
            let writes = requests.filter { $0["method"] == (move ? "move" : "copy") }
            XCTAssertEqual(writes.count, 1)
            let write = try XCTUnwrap(writes.first)
            XCTAssertEqual(write["api"], source == .personal ? "SYNO.Foto.BackgroundTask.File" : "SYNO.FotoTeam.BackgroundTask.File")
            XCTAssertEqual(write["target_folder_id"], "9"); XCTAssertEqual(write["item_id"], "[7]")
            XCTAssertNil(write["target_library"]); XCTAssertNil(write["target_user_id"])
            if move {
                let encoded = try XCTUnwrap(write["extra_info"]?.data(using: .utf8))
                let json = try JSONDecoder().decode(String.self, from: encoded)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                XCTAssertEqual(fields["version"] as? Int, 2); XCTAssertEqual(fields["source_library"] as? String, "personal_space")
            } else { XCTAssertNil(write["extra_info"]) }
            let folders = requests.filter { $0["api"]?.hasSuffix("Browse.Folder") == true }
            XCTAssertEqual(folders.last?["api"], targetSpace == .shared ? "SYNO.FotoTeam.Browse.Folder" : "SYNO.Foto.Browse.Folder")
        }
    }

    func test跨空间任务回执缺失目标时自动回读且不重新提交() async throws {
        let receipt = #"{"success":true,"data":{"task_info":{"id":91}}}"#
        let listed = #"{"success":true,"data":{"list":[{"id":91,"total":1,"target_folder":{"id":9,"owner_user_id":0}}]}}"#
        let done = #"{"success":true,"data":{"list":[{"id":91,"status":"done","completion":1,"error":0,"skip":0,"overwrite":0}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder), response(managedFolder), response(receipt),
            response(#"{"success":true,"data":{"list":[]}}"#), response(listed), response(done), response(managedFolder)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.move(page.items, folderID: 9, destinationSpace: .shared)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let final = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(final.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "move" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] == "list_user_task" }.count, 2)
    }

    func test跨空间回执错误空间文件夹或数量不得确认() async throws {
        for (folder, owner, total) in [(8, 0, 1), (9, 12, 1), (9, 0, 2)] {
            let receipt = "{\"success\":true,\"data\":{\"task_info\":{\"id\":91,\"total\":\(total),\"target_folder\":{\"id\":\(folder),\"owner_user_id\":\(owner)}}}}"
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder), response(managedFolder), response(receipt), response(#"{"success":true,"data":{"list":[]}}"#)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let result = try await repository.performMutation(.copy(page.items, folderID: 9, destinationSpace: .shared), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "get_status" })
        }
    }

    func test跨空间目标无上传权限或共享反向移动不写入() async throws {
        for reverseMove in [false, true] {
            let denied = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":false"#)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder)] + (reverseMove ? [] : [response(denied)]))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: reverseMove ? .shared : .personal, query: .recentlyAdded, offset: 0, limit: 20)
            do {
                _ = try await repository.performMutation(.move(page.items, folderID: 9, destinationSpace: reverseMove ? .personal : .shared), operationID: UUID()) { _, _ in }
                XCTFail("不符合网页方向或目录权限不能写入")
            } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "move" })
        }
    }

    func test跨空间完成后目标权限撤销仍保留待核对且不会重复写入() async throws {
        let denied = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":false"#)
        let done = #"{"success":true,"data":{"list":[{"id":91,"status":"done","completion":1,"error":0,"skip":0,"overwrite":0}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(itemPage), response(itemPage), response(managedFolder), response(managedFolder),
            response(#"{"success":true,"data":{"task_info":{"id":91,"total":1,"target_folder":{"id":9,"owner_user_id":0}}}}"#), response(done), response(denied), response(done), response(managedFolder)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let id = UUID(), command = SynologyPhotosMutation.move(page.items, folderID: 9, destinationSpace: .shared)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let reviewed = try await repository.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "move" }.count, 1)
    }

    func test共享移动复制使用共享目标但统一查询后台任务状态() async throws {
        for move in [false, true] {
            let target = managedFolder.replacingOccurrences(of: #""id":9"#, with: #""id":10"#)
            let moved = itemPage.replacingOccurrences(of: #""folder_id":9"#, with: #""folder_id":10"#)
            var replies = [response(itemPage), response(itemPage), response(managedFolder), response(target),
                response(#"{"success":true,"data":{"task_info":{"id":91}}}"#),
                response(#"{"success":true,"data":{"list":[{"id":91,"status":"done","completion":1,"error":0,"skip":0,"overwrite":0}]}}"#)]
            if move { replies.append(response(moved)) }
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + replies)
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let command: SynologyPhotosMutation = move ? .move(page.items, folderID: 10) : .copy(page.items, folderID: 10)
            let id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            if move { XCTAssertEqual(result.photos.first?.folderID, 10); XCTAssertEqual(result.photos.first?.id.space, .shared) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.first { $0["method"] == (move ? "move" : "copy") }?["api"], "SYNO.FotoTeam.BackgroundTask.File")
            XCTAssertEqual(requests.first { $0["method"] == "get_status" }?["api"], "SYNO.Foto.BackgroundTask.Info")
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.FotoTeam.BackgroundTask.Info" })
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        }
    }

    func test共享删除自动回读且不重发并隔离同编号个人照片() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(itemPage), response(itemPage), response(managedFolder), response(emptySuccess), response(itemPage), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport, deletionEnabled: true)
        _ = try await repository.access()
        let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first), id = UUID()
        let initial = try await repository.deletePhoto(photo, operationID: id)
        XCTAssertEqual(initial, .pendingReview)
        let reviewed = try await repository.reviewDeletion(photo)
        XCTAssertEqual(reviewed, .confirmed)
        let repeated = try await repository.deletePhoto(photo, operationID: id)
        XCTAssertEqual(repeated, .confirmed)
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(requests.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
    }

    func test共享管理缺少各自能力时不借用个人写接口() async throws {
        for (missing, feature) in [("SYNO.FotoTeam.Browse.Item", SynologyPhotosManagementFeature.metadata), ("SYNO.FotoTeam.Browse.GeneralTag", .tagCreation), ("SYNO.FotoTeam.BackgroundTask.File", .fileTransfer), ("SYNO.Foto.BackgroundTask.Info", .fileTransfer)] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management"))
            let repository = try makeRepository(transport, omittedAPIs: [missing])
            _ = try await repository.access()
            let features = await repository.managementFeatures(in: .shared)
            XCTAssertFalse(features.contains(feature))
            XCTAssertTrue(features.contains(.folders))
        }
    }

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
        XCTAssertEqual(categories, Set(SynologyPhotoCategory.allCases).subtracting([.similar]))
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

    func test任务导航按目录编号读取当前名称父目录且不写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"folder":{"id":43,"name":"/Parent/Current","parent":42,"additional":{"access_permission":{"view":true}}}}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let folder = try await repository.folder(id: 43, in: .personal)
        XCTAssertEqual(folder.id, 43); XCTAssertEqual(folder.name, "Current"); XCTAssertEqual(folder.parentID, 42)
        XCTAssertEqual(folder.path, "/Parent/Current"); XCTAssertEqual(folder.space, .personal)
        let requests = await transport.recordedRequests(), fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["api"], "SYNO.Foto.Browse.Folder"); XCTAssertEqual(fields["method"], "get")
        XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["id"], "43"); XCTAssertNil(fields["name"])
    }

    func test任务导航拒绝错目录身份和撤回的读取权限() async throws {
        for (id, view, category) in [(44, true, AppErrorCategory.conflict), (43, false, .permissionDenied)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response("{\"success\":true,\"data\":{\"folder\":{\"id\":\(id),\"name\":\"/Current\",\"parent\":42,\"additional\":{\"access_permission\":{\"view\":\(view)}}}}}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.folder(id: 43, in: .personal); XCTFail("不能接受越权或其他目录") }
            catch let error as AppError { XCTAssertEqual(error.category, category) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
        }
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

    func test共享空间权限与启用状态独立于个人空间() async throws {
        for (permission, enabled, home, expected) in [
            ("entry", true, true, [SynologyPhotoSpace.personal, .shared]),
            ("management", true, false, [.shared]),
            ("entry", false, true, [.personal]),
            ("none", true, false, []),
            ("unknown", true, true, [.personal])
        ] {
            let repository = try makeRepository(MockHTTPTransport(responses:
                accessResponses(teamPermission: permission, teamEnabled: enabled, homeEnabled: home)))
            let access = try await repository.access()
            XCTAssertEqual(access.spaces, expected, permission)
            XCTAssertEqual(access.canManageSharedSpace, permission == "management" && enabled)
        }
    }

    func test共享目录按目录权限且管理角色不依赖个人目录权限() async throws {
        let deniedFolder = managedFolder.replacingOccurrences(of: #""view":true"#, with: #""view":false"#)
        for permission in ["entry", "management"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: permission) + [response(deniedFolder)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            do {
                let root = try await repository.rootFolder(in: .shared)
                XCTAssertEqual(permission, "management")
                XCTAssertEqual(root.id, 9)
            } catch let error as AppError {
                XCTAssertEqual(permission, "entry")
                XCTAssertEqual(error.category, .permissionDenied)
            }
            let requests = await transport.recordedRequests()
            let fields = try decode(XCTUnwrap(requests.last))
            XCTAssertEqual(fields["api"], "SYNO.FotoTeam.Browse.Folder")
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(fields["name"]).utf8)), "/")
        }
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(deniedFolder)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.rootFolder(in: .personal); XCTFail("共享管理角色不能绕过个人目录权限") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test共享时间线搜索筛选目录与照片详情均使用共享接口() async throws {
        let timeline = #"{"success":true,"data":{"section":[{"list":[{"year":2020,"month":3,"day":15,"item_count":1}]}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [
            response(timeline), response(timeline), response(timeline),
            response(#"{"success":true,"data":{"person":[],"geocoding":[]}}"#),
            response(managedFolder), response(#"{"success":true,"data":{"list":[{"id":10,"name":"Fixture","parent":9}]}}"#)
        ] + Array(repeating: response(itemPage), count: 7))
        let profileID = UUID()
        let repository = try makeRepository(transport, profileID: profileID)
        _ = try await repository.access()
        let days = try await repository.timeline(in: .shared)
        XCTAssertEqual(days.first?.year, 2020)
        _ = try await repository.searchTimeline(in: .shared, keyword: "fixture")
        var filter = SynologyPhotoFilter(); filter.rating = 3
        _ = try await repository.filteredTimeline(in: .shared, filter: filter)
        _ = try await repository.filterOptions(in: .shared)
        let root = try await repository.rootFolder(in: .shared)
        let folders = try await repository.folders(in: .shared, parentID: root.id, offset: 0, limit: 20)
        XCTAssertEqual(folders.map(\.id), [10])
        for query: SynologyPhotoQuery in [
            .timeline(startTime: 0, endTime: 100), .search(keyword: "fixture", startTime: 0, endTime: 100),
            .folder(id: 9), .recentlyAdded, .filtered(filter, startTime: 0, endTime: 100),
            .category(.person, id: 31, startTime: 0, endTime: 100)
        ] {
            let page = try await repository.photos(in: .shared, query: query, offset: 0, limit: 20)
            XCTAssertEqual(page.items.first?.id, .init(profileID: profileID, space: .shared, unitID: 7))
        }
        let photo = SynologyPhoto(id: .init(profileID: profileID, space: .shared, unitID: 7), filename: "sample.jpg",
            sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        let details = try await repository.details(for: photo)
        XCTAssertEqual(details.id, photo.id)
        let fields = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertEqual(fields.map { $0["api"] }, [
            "SYNO.FotoTeam.Browse.Timeline", "SYNO.FotoTeam.Search.Search", "SYNO.FotoTeam.Browse.Timeline",
            "SYNO.FotoTeam.Search.Filter", "SYNO.FotoTeam.Browse.Folder", "SYNO.FotoTeam.Browse.Folder",
            "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Search.Search", "SYNO.FotoTeam.Browse.Item",
            "SYNO.FotoTeam.Browse.RecentlyAdded", "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Item"
        ])
        XCTAssertEqual(fields[2]["rating"], "[3]")
        XCTAssertEqual(fields[10]["method"], "list_with_filter")
        XCTAssertEqual(fields[11]["person_id"], "31")
    }

    func test共享接口缺失不会改为请求个人空间() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry"))
        let repository = try makeRepository(transport, omittedAPIs: ["SYNO.FotoTeam.Browse.Timeline"])
        _ = try await repository.access()
        do { _ = try await repository.timeline(in: .shared); XCTFail("不可用接口不能回退个人图库") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func test默认能力发现实际查询并保留共享照片接口() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"SYNO.FotoTeam.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":6,"requestFormat":"JSON"}}}"#)])
        let client = DsmAPIClient(baseURL: try XCTUnwrap(URL(string: "https://nas.example.invalid:5001")), transport: transport)
        let capabilities = try await DsmCapabilityDiscovery(client: client).discover()
        let item = try XCTUnwrap(capabilities["SYNO.FotoTeam.Browse.Item"])
        XCTAssertEqual(item.maxVersion, 6)
        XCTAssertEqual(item.requestFormat, .json)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        let query = try XCTUnwrap(fields["query"]).split(separator: ",").map(String.init)
        XCTAssertTrue(query.contains("SYNO.FotoTeam.Browse.Item"))
        XCTAssertTrue(query.contains("SYNO.FotoTeam.Thumbnail"))
        XCTAssertTrue(query.contains("SYNO.FotoTeam.Download"))
        XCTAssertEqual(query.count, Set(query).count)
    }

    func test个人与共享同编号照片图片使用独立路由且凭据不进入URL() async throws {
        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") +
            Array(repeating: DsmHTTPResponse(data: image, statusCode: 200, headers: ["Content-Type": "image/jpeg"]), count: 4))
        let profileID = UUID()
        let repository = try makeRepository(transport, profileID: profileID)
        _ = try await repository.access()
        for space in [SynologyPhotoSpace.personal, .shared] {
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: 7), filename: "sample.jpg",
                sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo",
                thumbnail: .init(unitID: 701, revision: "fixture-revision"))
            let thumbnail = try await repository.thumbnail(for: photo)
            let preview = try await repository.previewImage(for: photo)
            XCTAssertEqual(thumbnail, image); XCTAssertEqual(preview, image)
        }
        let requests = await transport.recordedRequests().dropFirst(4)
        XCTAssertEqual(requests.compactMap { $0.url?.path }, [
            "/synofoto/api/v2/p/Thumbnail/get", "/synofoto/api/v2/p/Thumbnail/get",
            "/synofoto/api/v2/t/Thumbnail/get", "/synofoto/api/v2/t/Thumbnail/get"
        ])
        for (index, request) in requests.enumerated() {
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value) })
            XCTAssertEqual(fields["id"], "701")
            XCTAssertEqual(fields["size"], index.isMultiple(of: 2) ? #""m""# : #""xl""#)
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-session"))
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "fixture-token")
        }
    }

    func test共享图片不接受其他NAS身份且重新授权后撤销旧访问() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + accessResponses())
        let profileID = UUID()
        let repository = try makeRepository(transport, profileID: profileID)
        _ = try await repository.access()
        func photo(_ id: UUID) -> SynologyPhoto {
            .init(id: .init(profileID: id, space: .shared, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
                takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 7, revision: "fixture"))
        }
        do { _ = try await repository.thumbnail(for: photo(UUID())); XCTFail("不得使用其他NAS身份") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        _ = try await repository.access()
        do { _ = try await repository.previewImage(for: photo(profileID)); XCTFail("不得继续使用旧共享权限") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 8)
    }

    func test共享视频转换流和原件均保持共享空间身份() async throws {
        for qualities in [[], ["medium"]] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(videoPage(extension: "mp4", qualities: qualities))])
            let profileID = UUID()
            let repository = try makeRepository(transport, profileID: profileID)
            _ = try await repository.access()
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: .shared, unitID: 7), filename: "sample.mp4",
                sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "video")
            let source = try await repository.videoSource(for: photo)
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields["api"], qualities.isEmpty ? "SYNO.FotoTeam.Download" : "SYNO.FotoTeam.Streaming")
            let requests = await transport.recordedRequests()
            XCTAssertEqual(try decode(XCTUnwrap(requests.last))["api"], "SYNO.FotoTeam.Browse.Item")
        }
    }

    func test共享实况视频单元与原件导出不会转到个人接口() async throws {
        let livePage = itemPage.replacingOccurrences(of: #""type":"photo""#, with: #""type":"live""#)
        let original = Data(repeating: 0x7f, count: 128)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [
            response(livePage),
            response(#"{"success":true,"data":{"list":[{"id_item":7,"unit":[{"id":701,"live_type":"photo"},{"id":702,"live_type":"video","filename":"sample.MOV","additional":{"video_convert":[]}}]}]}}"#),
            DsmHTTPResponse(data: original, statusCode: 200, headers: ["Content-Type": "application/force-download"])
        ])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let photo = try XCTUnwrap(page.items.first)
        let source = try await repository.videoSource(for: photo)
        let videoFields = Dictionary(uniqueKeysWithValues: URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(videoFields["api"], "SYNO.FotoTeam.Download")
        XCTAssertEqual(videoFields["unit_id"], "[702]")
        XCTAssertNil(videoFields["item_id"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("fixture.jpg")
        try await repository.downloadOriginal(photo, to: destination, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decode(requests[5])["api"], "SYNO.FotoTeam.Browse.Unit")
        let download = try XCTUnwrap(requests.last?.url)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: download, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["api"], "SYNO.FotoTeam.Download")
        XCTAssertEqual(fields["item_id"], "[7]")
        XCTAssertNil(fields["unit_id"])
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
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true))
        let repository = try makeRepository(transport, deletionEnabled: true, convertedPreview: true)
        let beforeAccess = await repository.managementFeatures()
        XCTAssertTrue(beforeAccess.isEmpty, "没有空间访问权时不能显示可写能力")
        _ = try await repository.access()
        let features = await repository.managementFeatures()
        XCTAssertEqual(features, Set(SynologyPhotosManagementFeature.allCases).subtracting([.folderSharing]))
        try await repository.prepareMutation(.createAlbum(name: "Fixture", photos: []))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4, "开放能力和创建预检不能提前发送创建请求")
    }

    func test缺少上传接口不影响其他照片管理功能() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(similarEnabled: true))
        let repository = try makeRepository(transport, deletionEnabled: true, omittedAPIs: ["SYNO.Foto.Upload.Item"], convertedPreview: true)
        _ = try await repository.access()
        let features = await repository.managementFeatures()
        XCTAssertEqual(features, Set(SynologyPhotosManagementFeature.allCases).subtracting([.upload, .folderSharing]))
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

    private func temporaryAlbumFixture(id: Int = 3, temporary: Bool? = true, shared: Bool = false, owner: Int = 12, name: String = "Fixture", receipt: Bool = false) throws -> DsmHTTPResponse {
        var album: [String: Any] = ["id": id, "name": name, "owner_user_id": owner, "shared": shared, "type": "normal",
            "additional": ["sharing_info": ["privacy_type": "private", "permission": [], "enable_password": false, "expiration": 0]]]
        if let temporary { album["temporary_shared"] = temporary }
        let data: [String: Any] = receipt ? ["album": ["id": id]] : ["list": [album]]
        return response(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), as: UTF8.self))
    }

    func test临时分享创建携带标记并核对完整选片且不重复() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            try temporaryAlbumFixture(receipt: true), try temporaryAlbumFixture(), response(itemPage)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
        let command = SynologyPhotosMutation.createTemporaryAlbum(name: "Fixture", photos: photos), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.album?.id, 3)
        let repeatResult = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(repeatResult, result)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "create" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["shared"], "true")
        XCTAssertEqual(writes.first?["item"], "[7]")
    }

    func test临时分享创建缺少标记或成员不符不能追认为成功() async throws {
        for temporary in [Bool?.none, .some(false), .some(true)] {
            let album = try temporaryAlbumFixture(temporary: temporary)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
                try temporaryAlbumFixture(receipt: true), album] + (temporary == true ? [response(#"{"success":true,"data":{"list":[]}}"#)] : []))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20).items
            let result = try await repository.performMutation(.createTemporaryAlbum(name: "Fixture", photos: photos), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
    }

    func test临时分享副本核对普通私有相册与完整成员不清理来源() async throws {
        let source = try temporaryAlbumFixture(shared: true)
        let transport = MockHTTPTransport(responses: accessResponses() + [source, source, response(itemPage), source,
            try temporaryAlbumFixture(id: 4, temporary: false, receipt: true), try temporaryAlbumFixture(id: 4, temporary: false), response(itemPage)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        XCTAssertEqual(original.isTemporary, true)
        let id = UUID(), command = SynologyPhotosMutation.copyTemporaryAlbum(id: 3, name: "Fixture", original: original)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.album?.id, 4); XCTAssertEqual(result.completedCount, 1)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["method"] == "copy" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["source_album_id"], "3")
        XCTAssertFalse(requests.contains { ["delete", "set_shared"].contains($0["method"] ?? "") })
    }

    func test临时分享副本缺标记仍共享或成员变化保持待核对() async throws {
        let source = try temporaryAlbumFixture(shared: true)
        for (temporary, shared, matchingMembers) in [(Bool?.none, false, true), (.some(true), false, true), (.some(false), true, true), (.some(false), false, false)] {
            let copy = try temporaryAlbumFixture(id: 4, temporary: temporary, shared: shared)
            let suffix = temporary == false && !shared ? [response(matchingMembers ? itemPage : #"{"success":true,"data":{"list":[]}}"#)] : []
            let transport = MockHTTPTransport(responses: accessResponses() + [source, source, response(itemPage), source,
                try temporaryAlbumFixture(id: 4, temporary: false, receipt: true), copy] + suffix)
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            let result = try await repository.performMutation(.copyTemporaryAlbum(id: 3, name: "Fixture", original: original), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["delete", "set_shared"].contains($0["method"] ?? "") })
        }
    }

    func test临时分享副本核对跨页全部成员且末页缺失不确认() async throws {
        let source = try temporaryAlbumFixture(shared: true)
        func members(_ ids: ClosedRange<Int>) throws -> DsmHTTPResponse {
            let list: [[String: Any]] = ids.map { ["id": $0, "owner_user_id": 12, "filename": "fixture-\($0).jpg", "filesize": 128,
                "time": 50, "indexed_time": 60, "folder_id": 9, "type": "photo"] }
            return response(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": list]]), as: UTF8.self))
        }
        let first = try members(1...500), last = try members(501...501)
        for complete in [true, false] {
            let transport = MockHTTPTransport(responses: accessResponses() + [source, source, first, last, source,
                try temporaryAlbumFixture(id: 4, temporary: false, receipt: true), try temporaryAlbumFixture(id: 4, temporary: false),
                first, complete ? last : response(#"{"success":true,"data":{"list":[]}}"#)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            let result = try await repository.performMutation(.copyTemporaryAlbum(id: 3, name: "Fixture", original: original), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, complete ? .confirmed : .pendingReview)
            if complete { XCTAssertEqual(result.completedCount, 501) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["api"] == "SYNO.Foto.Browse.Item" }.compactMap { $0["offset"] }, ["0", "500", "0", "500"])
            XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
    }

    func test临时分享副本丢失编号只读核对不重发复制() async throws {
        let source = try temporaryAlbumFixture(shared: true)
        let transport = MockHTTPTransport(responses: accessResponses() + [source, source, response(itemPage), source, response(emptySuccess)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let id = UUID(), command = SynologyPhotosMutation.copyTemporaryAlbum(id: 3, name: "Fixture", original: original)
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        let second = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview); XCTAssertEqual(second.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "copy" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "delete" })
    }

    func test临时分享清理仅接受本人已停止临时相册并核对消失() async throws {
        let album = try temporaryAlbumFixture()
        let transport = MockHTTPTransport(responses: accessResponses() + [album, album, response(emptySuccess), response(#"{"success":true,"data":{"list":[]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let id = UUID(), command = SynologyPhotosMutation.deleteTemporaryAlbum(id: 3, original: original)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let requests = try await transport.recordedRequests().map(decode)
        let deletes = requests.filter { $0["method"] == "delete" }
        XCTAssertEqual(deletes.count, 1); XCTAssertEqual(deletes.first?["api"], "SYNO.Foto.Browse.Album")
        XCTAssertEqual(deletes.first?["id"], "[3]")
    }

    func test临时分享保留副本清理前重查当前完整成员() async throws {
        for matching in [true, false] {
            let source = try temporaryAlbumFixture(), copy = try temporaryAlbumFixture(id: 4, temporary: false)
            let tail = matching ? [source, response(emptySuccess), response(#"{"success":true,"data":{"list":[]}}"#)] : []
            let transport = MockHTTPTransport(responses: accessResponses() + [source, source, copy, response(itemPage),
                response(matching ? itemPage : #"{"success":true,"data":{"list":[]}}"#)] + tail)
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do {
                let result = try await repository.performMutation(.deleteTemporaryAlbum(id: 3, original: original, preservedCopyID: 4), operationID: UUID()) { _, _ in }
                XCTAssertTrue(matching); XCTAssertEqual(result.state, .confirmed)
            } catch { XCTAssertFalse(matching) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, matching ? 1 : 0)
        }
    }

    func test临时分享原范围未变但缺少链接时仍取得可用链接() async throws {
        let source = try temporaryAlbumFixture(shared: true)
        let after = response(#"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"temporary_shared":true,"shared":true,"additional":{"sharing_info":{"privacy_type":"private","permission":[],"enable_password":false,"expiration":0,"sharing_link":"https://example.invalid/share/fixture"}}}]}}"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [source, source, source,
            response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), after])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .invited, original: original), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertNotNil(result.sharingURL)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "set_shared" }.compactMap { $0["enabled"] }, ["false", "true"])
    }

    func test临时分享清理拒绝普通相册缺字段仍共享权限变化与旧快照() async throws {
        for (temporary, shared, owner) in [(Bool?.none, false, 12), (.some(false), false, 12), (.some(true), true, 12), (.some(true), false, 13)] {
            let before = try temporaryAlbumFixture()
            let changed = try temporaryAlbumFixture(temporary: temporary, shared: shared, owner: owner)
            let transport = MockHTTPTransport(responses: accessResponses() + [before, changed])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do { _ = try await repository.performMutation(.deleteTemporaryAlbum(id: 3, original: original), operationID: UUID()) { _, _ in }; XCTFail("不应删除不满足条件的相册") }
            catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
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

    private func codecResponses(show: Bool = true, admin: Bool = true, home: Bool = true) -> [DsmHTTPResponse] {
        [response("{\"success\":true,\"data\":{\"enabled\":true,\"id\":12,\"is_admin\":\(admin)}}"),
         response("{\"success\":true,\"data\":{\"enable_home_service\":\(home),\"team_space_permission\":\"management\"}}"),
         response("{\"success\":true,\"data\":{\"prompt\":[{\"name\":\"other_fixture\",\"show\":true},{\"name\":\"new_codec_installed\",\"show\":\(show)}]}}")]
    }

    func test新格式提示管理员和普通用户生成固定范围且不以计数冒充完成() async throws {
        for admin in [false, true] {
            let profile = UUID(), reads = codecResponses(admin: admin)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + reads + reads +
                [response(emptySuccess), response(emptySuccess)] + codecResponses(show: false, admin: admin))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let prompt = try await repository.codecPrompt()
            XCTAssertEqual(prompt.isAdministrator, admin); XCTAssertTrue(prompt.canGenerate)
            let operation = UUID(), command = SynologyPhotosMutation.respondToCodecPrompt(prompt, generate: true)
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
                XCTAssertEqual(result.state, .confirmed)
            }
            let calls = try await transport.recordedRequests().map(decode)
            let index = calls.filter { $0["api"] == "SYNO.Foto.Index" }
            XCTAssertEqual(index.count, 1); XCTAssertEqual(index.first?["method"], admin ? "reindex_all_user" : "reindex")
            XCTAssertEqual(index.first?["type"], "\"thumbnail\"")
            let saves = calls.filter { $0["api"] == "SYNO.Foto.Setting.Wizard" && $0["method"] == "set" }
            XCTAssertEqual(saves.count, 1)
            let prompts = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(saves.first?["prompt"]).utf8)) as? [[String: Any]]
            XCTAssertEqual(prompts?.count, 1); XCTAssertEqual(prompts?.first?["name"] as? String, "new_codec_installed")
            XCTAssertEqual(prompts?.first?["show"] as? Bool, false)
        }
    }

    func test新格式稍后只保存提示丢失回执后自动回读且不启动生成() async throws {
        let profile = UUID(), reads = codecResponses()
        let steps = (accessResponses() + reads + reads).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] + codecResponses(show: false).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access(); let prompt = try await repository.codecPrompt()
        let result = try await repository.performMutation(.respondToCodecPrompt(prompt, generate: false), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(calls.contains { $0["api"] == "SYNO.Foto.Index" })
        XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test新格式生成回执未知即使提示已读也不误报接收或重发() async throws {
        let profile = UUID(), reads = codecResponses()
        let steps = (accessResponses() + reads + reads).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] +
            (codecResponses(show: false) + codecResponses(show: false)).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access(); let prompt = try await repository.codecPrompt()
        let operation = UUID(), command = SynologyPhotosMutation.respondToCodecPrompt(prompt, generate: true)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "reindex_all_user" }.count, 1)
        XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test新格式任务已接收提示保存断网可核对且只提交一次生成() async throws {
        let profile = UUID(), reads = codecResponses()
        let steps = (accessResponses() + reads + reads + [response(emptySuccess)]).map(MockHTTPTransport.Step.response) +
            [.urlError(.networkConnectionLost)] + (reads + codecResponses(show: false)).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access(); let prompt = try await repository.codecPrompt(), operation = UUID()
        let first = try await repository.performMutation(.respondToCodecPrompt(prompt, generate: true), operationID: operation) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: operation); XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "reindex_all_user" }.count, 1)
        XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test新格式提示保存明确失败后只能补保存不重复生成() async throws {
        let profile = UUID(), reads = codecResponses()
        let transport = MockHTTPTransport(responses: accessResponses() + reads + reads + [response(emptySuccess), response(#"{"success":false,"error":{"code":100}}"#)] + reads + reads + reads + [response(emptySuccess)] + codecResponses(show: false) + reads)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let original = try await repository.codecPrompt()
        let result = try await repository.performMutation(.respondToCodecPrompt(original, generate: true), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1)
        let remaining = try await repository.codecPrompt()
        XCTAssertTrue(remaining.generationAlreadySubmitted); XCTAssertFalse(remaining.canGenerate)
        do { _ = try await repository.performMutation(.respondToCodecPrompt(remaining, generate: true), operationID: UUID()) { _, _ in }; XCTFail("已接收的生成不能重复提交") } catch { }
        let saved = try await repository.performMutation(.respondToCodecPrompt(original, generate: false), operationID: UUID()) { _, _ in }
        XCTAssertEqual(saved.state, .confirmed)
        let future = try await repository.codecPrompt(); XCTAssertTrue(future.canGenerate, "已观察到提示关闭后，未来的新提示可再次处理")
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "reindex_all_user" }.count, 1)
    }

    func test新格式拒绝外来身份已关闭提示及管理员身份变化() async throws {
        let profile = UUID()
        for scenario in 0..<4 {
            let original = SynologyPhotoCodecPrompt(profileID: scenario == 0 ? UUID() : profile, userID: scenario == 1 ? 99 : 12,
                isAdministrator: true, shouldShow: scenario != 2, personalSpaceEnabled: true)
            let transport = MockHTTPTransport(responses: accessResponses() + (scenario == 3 ? codecResponses(admin: false) : []))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { _ = try await repository.performMutation(.respondToCodecPrompt(original, generate: true), operationID: UUID()) { _, _ in }; XCTFail("应拒绝外来或过期快照") } catch { }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { ["reindex_all_user", "reindex", "set"].contains($0["method"] ?? "") })
        }
    }

    func test新格式缺字段重复提示失败而未知提示保留不触发维护() async throws {
        for payload in [#"{}"#, #"{"prompt":[{"name":"new_codec_installed"}]}"#, #"{"prompt":[{"name":"new_codec_installed","show":true},{"name":"new_codec_installed","show":false}]}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + Array(codecResponses().dropLast()) + [response("{\"success\":true,\"data\":\(payload)}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.codecPrompt(); XCTFail("损坏提示不能当作无需处理") } catch { }
        }
        let transport = MockHTTPTransport(responses: accessResponses() + Array(codecResponses().dropLast()) + [response(#"{"success":true,"data":{"prompt":[{"name":"future","show":true}]}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let prompt = try await repository.codecPrompt(); XCTAssertFalse(prompt.shouldShow)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test新格式无个人空间管理员仍能处理全用户普通用户只能稍后() async throws {
        for admin in [true, false] {
            let reads = codecResponses(admin: admin, home: false)
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + reads + reads +
                (admin ? [response(emptySuccess)] : []) + [response(emptySuccess)] + codecResponses(show: false, admin: admin, home: false))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let features = await repository.managementFeatures(in: .personal)
            XCTAssertTrue(features.contains(.codecPrompt))
            let prompt = try await repository.codecPrompt(); XCTAssertEqual(prompt.canGenerate, admin)
            if !admin {
                do { _ = try await repository.performMutation(.respondToCodecPrompt(prompt, generate: true), operationID: UUID()) { _, _ in }; XCTFail("未开启个人空间不能生成") } catch { }
            }
            let result = try await repository.performMutation(.respondToCodecPrompt(prompt, generate: admin), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "reindex_all_user" }.count, admin ? 1 : 0)
            XCTAssertFalse(calls.contains { $0["method"] == "reindex" })
        }
    }

    func test新格式生成等待接收时取消或撤权不再保存提示或重复生成() async throws {
        for revoke in [true, false] {
            let base = MockHTTPTransport(responses: accessResponses() + codecResponses() + codecResponses() + [response(emptySuccess)] +
                (revoke ? [response(#"{"success":true,"data":{"enabled":false}}"#)] : codecResponses()))
            let transport = AlbumReadBarrierTransport(base), repository = try makeRepository(transport)
            _ = try await repository.access(); let prompt = try await repository.codecPrompt()
            await transport.holdNext(method: "reindex_all_user")
            let task = Task { try await repository.performMutation(.respondToCodecPrompt(prompt, generate: true), operationID: UUID()) { _, _ in } }
            await transport.waitUntilHeld()
            if revoke { do { _ = try await repository.access(); XCTFail("Photos已停用") } catch { } }
            else { task.cancel() }
            await transport.release()
            _ = try? await task.value
            let calls = try await base.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "reindex_all_user" }.count, 1)
            XCTAssertFalse(calls.contains { $0["api"] == "SYNO.Foto.Setting.Wizard" && $0["method"] == "set" })
        }
    }

    private func maintenanceResponses(space: SynologyPhotoSpace = .personal, basic: Int = 0, thumbnail: Int = 0,
                                      admin: Bool = true, h264: Bool = true, home: Bool = true) -> [DsmHTTPResponse] {
        var values = [
            response("{\"success\":true,\"data\":{\"enabled\":true,\"is_admin\":\(admin),\"id\":12}}"),
            response("{\"success\":true,\"data\":{\"enable_home_service\":\(home),\"team_space_permission\":\"management\",\"ame_status\":{\"has_h264\":\(h264)}}}")
        ]
        if space == .shared { values.append(response(#"{"success":true,"data":{"enabled":true}}"#)) }
        values.append(response("{\"success\":true,\"data\":{\"basic\":\(basic),\"thumbnail\":\(thumbnail)}}"))
        return values
    }

    func test整库维护个人共享两种动作固定路由且同一操作只写一次() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for action in SynologyPhotoLibraryMaintenanceStatus.Action.allCases {
                let profile = UUID(), reads = maintenanceResponses(space: space)
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + reads + reads + [response(emptySuccess)] + reads)
                let repository = try makeRepository(transport, profileID: profile)
                _ = try await repository.access()
                let original = try await repository.libraryMaintenanceStatus(in: space)
                XCTAssertEqual(original.profileID, profile); XCTAssertEqual(original.userID, 12)
                XCTAssertTrue(original.canStart(action))
                let command = SynologyPhotosMutation.maintainLibrary(original, action), operation = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1)
                }
                let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "reindex" }
                XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.Index" : "SYNO.FotoTeam.Index")
                XCTAssertEqual(writes.first?["type"], "\"\(action.rawValue)\"")
                XCTAssertFalse(calls.contains { $0["method"] == "reindex_all_user" })
            }
        }
    }

    func test整库维护运行计数自动回读归零后确认且不会重发() async throws {
        for action in SynologyPhotoLibraryMaintenanceStatus.Action.allCases {
            let profile = UUID(), idle = maintenanceResponses()
            let busy = maintenanceResponses(basic: action == .reindex ? 4 : 0, thumbnail: action == .previews ? 5 : 0)
            let transport = MockHTTPTransport(responses: accessResponses() + idle + [response(emptySuccess)] + busy + busy + idle)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let original = SynologyPhotoLibraryMaintenanceStatus(profileID: profile, userID: 12, space: .personal,
                indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
            let command = SynologyPhotosMutation.maintainLibrary(original, action), operation = UUID()
            let first = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(first.state, .pendingReview)
            let second = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(second.state, .pendingReview)
            let final = try await repository.reviewMutation(operationID: operation)
            XCTAssertEqual(final.state, .confirmed)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.filter { $0["method"] == "reindex" }.count, 1)
        }
    }

    func test整库维护丢失接收回执不能凭计数追认且禁止另一次提交() async throws {
        let profile = UUID(), idle = maintenanceResponses(), busy = maintenanceResponses(basic: 3)
        let steps = (accessResponses() + idle).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)] +
            (idle + busy + idle).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access()
        let original = SynologyPhotoLibraryMaintenanceStatus(profileID: profile, userID: 12, space: .personal,
            indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
        let command = SynologyPhotosMutation.maintainLibrary(original, .reindex), operation = UUID()
        let first = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        for _ in 0..<2 {
            let result = try await repository.reviewMutation(operationID: operation)
            XCTAssertEqual(result.state, .pendingReview)
        }
        do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("未确认时不应重复维护") }
        catch { }
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "reindex" }.count, 1)
    }

    func test整库维护明确失败回执不会当作待处理或自动重发() async throws {
        let profile = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + maintenanceResponses() + [response(#"{"success":false,"error":{"code":100}}"#)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let original = SynologyPhotoLibraryMaintenanceStatus(profileID: profile, userID: 12, space: .personal,
            indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
        let operation = UUID(), command = SynologyPhotosMutation.maintainLibrary(original, .reindex)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
            XCTAssertEqual(result.state, .rejected)
        }
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "reindex" }.count, 1)
    }

    func test整库维护拒绝外来身份忙碌及过期能力快照() async throws {
        let profile = UUID()
        let scenarios: [(UUID, Int, Int, Bool, [DsmHTTPResponse])] = [
            (UUID(), 12, 0, true, []), (profile, 19, 0, true, []), (profile, 12, 1, true, []),
            (profile, 12, 0, false, []), (profile, 12, 0, true, maintenanceResponses(thumbnail: 2)),
            (profile, 12, 0, true, maintenanceResponses(h264: false))
        ]
        for (owner, user, count, supported, reads) in scenarios {
            let transport = MockHTTPTransport(responses: accessResponses() + reads)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let original = SynologyPhotoLibraryMaintenanceStatus(profileID: owner, userID: user, space: .personal,
                indexingCount: 0, previewCount: count, supportsPreviewGeneration: supported)
            do { _ = try await repository.performMutation(.maintainLibrary(original, .previews), operationID: UUID()) { _, _ in }; XCTFail("不应接受过期或外来维护目标") }
            catch { }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { $0["method"] == "reindex" })
        }
    }

    func test整库维护真实权限与编解码条件分别处理() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + maintenanceResponses(space: space, admin: false, h264: false))
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                let status = try await repository.libraryMaintenanceStatus(in: space)
                XCTAssertEqual(space, .personal); XCTAssertTrue(status.canStart(.reindex)); XCTAssertFalse(status.canStart(.previews))
            } catch { XCTAssertEqual(space, .shared) }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { $0["method"] == "reindex" })
        }
        let transport = MockHTTPTransport(responses: accessResponses() + maintenanceResponses(home: false))
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { _ = try await repository.libraryMaintenanceStatus(in: .personal); XCTFail("个人空间关闭时不应允许维护") } catch { }
    }

    func test整库维护缺失或负数计数不当作空闲且缺失接口不显示能力() async throws {
        for counts in [#"{"basic":0}"#, #"{"basic":-1,"thumbnail":0}"#, #"{"basic":0,"thumbnail":-1}"#, #"{"basic":"0","thumbnail":0}"#] {
            let reads = Array(maintenanceResponses().dropLast()) + [response("{\"success\":true,\"data\":\(counts)}")]
            let transport = MockHTTPTransport(responses: accessResponses() + reads), repository = try makeRepository(transport)
            _ = try await repository.access()
            do { _ = try await repository.libraryMaintenanceStatus(in: .personal); XCTFail("无效计数不应接受") } catch { }
        }
        for space in [SynologyPhotoSpace.personal, .shared] {
            let missing = space == .personal ? "SYNO.Foto.Index" : "SYNO.FotoTeam.Index"
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management"))
            let repository = try makeRepository(transport, omittedAPIs: [missing]); _ = try await repository.access()
            let features = await repository.managementFeatures(in: space)
            XCTAssertFalse(features.contains(.libraryMaintenance))
        }
    }

    func test管理员恢复全局多步保存逐步记录且跨实例只回读() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let target = original.applying(enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions)
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + Array(repeating: response(emptySuccess), count: 3) + (try globalSettingsResponses(target)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: target.enabled, excludedExtensions: target.excludedExtensions)
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .confirmed)
        let snapshots = capture.values.compactMap(\.administrationDetails)
        XCTAssertTrue(snapshots.contains { $0.globalAttempted == [.admin] && $0.globalAcknowledged.isEmpty })
        XCTAssertTrue(snapshots.contains { $0.globalAttempted == [.admin, .personal] && $0.globalAcknowledged == [.admin] })
        let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
        let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data)
        XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion); XCTAssertEqual(saved.administrationDetails?.globalAcknowledged, [.admin, .personal, .shared])
        let reads = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(target)))
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed)
        let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["set", "clear_cache"].contains($0["method"]) })
    }

    func test管理员恢复全局回执丢失不补发未提交的个人共享步骤() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let target = original.applying(enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions)
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + [response("invalid")] + (try globalSettingsResponses(original)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: target.enabled, excludedExtensions: target.excludedExtensions)
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
        XCTAssertEqual(result.state, .pendingReview)
        let saved = try XCTUnwrap(capture.values.last)
        XCTAssertEqual(saved.administrationDetails?.globalAttempted, [.admin]); XCTAssertEqual(saved.administrationDetails?.globalAcknowledged, [])
        let reads = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(target)))
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .partial); XCTAssertEqual(reviewed.completedCount, 1)
        let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test管理员恢复保存阶段失败停止写入并保留已完成步骤() async throws {
        for failBeforeFirst in [true, false] {
            let profile = UUID(), original = globalSettingsFixture(profile), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            var partial = original; partial.values[.person] = false
            let extra = failBeforeFirst ? [] : [response(emptySuccess)] + (try globalSettingsResponses(partial))
            let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + extra)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions)
            let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { saved in
                if let details = saved.administrationDetails,
                   failBeforeFirst ? details.globalAttempted == [.admin] : details.globalAttempted == [.admin, .personal] { throw CocoaError(.fileWriteNoPermission) }
                capture.append(saved)
            }
            XCTAssertEqual(result.state, failBeforeFirst ? .rejected : .partial)
            let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, failBeforeFirst ? 0 : 1)
            if !failBeforeFirst { XCTAssertEqual(capture.values.last?.administrationDetails?.globalAttempted, [.admin]) }
        }
    }

    func test管理员恢复缓存区分未提交清理中和已有接收回执() async throws {
        let profile = UUID(), original = SynologyPhotoConversionCache(profileID: profile, administratorID: 12, sizeBytes: 20, isClearing: false)
        let command = SynologyPhotosMutation.clearConversionCache(original), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let transport = MockHTTPTransport(responses: accessResponses() + cacheResponses(size: 25) + [response(emptySuccess)] + cacheResponses(size: 3, processing: true))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .pendingReview)
        let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.administrationDetails?.globalAcknowledged, [.cache])
        let reads = MockHTTPTransport(responses: accessResponses() + cacheResponses(size: 4))
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed)
        let untouched = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: UUID(), profileID: profile, userID: 12)
        try await restored.restoreAlbumMutation(untouched)
        let initial = try await restored.reviewMutation(operationID: untouched.operationID); XCTAssertEqual(initial.state, .rejected)
        let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "clear_cache" })
    }

    func test管理员恢复共享开关和选项保持原身份且不重复保存() async throws {
        for switching in [true, false] {
            let profile = UUID(), original = sharedSettingsFixture(profile), id = UUID(), capture = PhotosAlbumCheckpointCapture()
            var target = original
            if switching { target.isEnabled = false } else { target.values[.person] = false }
            let command: SynologyPhotosMutation = switching ? .setSharedSpaceEnabled(original: original, enabled: false) : .setSharedSpaceSettings(original: original, enabled: target.enabled)
            let transport = MockHTTPTransport(responses: accessResponses() + (try sharedSettingsResponses(original)) + [response(emptySuccess)] + (try sharedSettingsResponses(target)))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
            let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(capture.values.last)))
            let reads = MockHTTPTransport(responses: accessResponses() + (try sharedSettingsResponses(target)))
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["set_enable", "set"].contains($0["method"]) })
        }
    }

    func test管理员恢复成员与目录多步结果不保存名称且重启只回读() async throws {
        let profile = UUID(), original = memberState(profile, role: .management), member = original.members[0].id
        var members = original.members; members[0] = members[0].changingRole(to: .entry)
        let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
        let folders = memberFolderSnapshotReads(parentRole: "view", childRole: nil), old = try memberStateReads(original)
        let finalFolders = memberFolderSnapshotReads(parentRole: "download", childRole: "download")
        let final = try memberStateReads(updated) + finalFolders + sharedSettingsResponses(sharedSettingsFixture(profile))
        let transport = MockHTTPTransport(responses: accessResponses() + folders + old + folders + old + [response(emptySuccess), response(emptySuccess)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
        let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, batch: .init(action: .checkAll, role: .download))
        let command = SynologyPhotosMutation.setSharedMembers(original: original, members: members, folderEdits: [edit]), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
        let saved = try XCTUnwrap(capture.values.last), data = try JSONEncoder().encode(saved)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Fixture self")); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("administrators"))
        XCTAssertEqual(saved.administrationDetails?.memberAttempted, [0, 1]); XCTAssertEqual(saved.administrationDetails?.memberAcknowledged, [0, 1])
        try await repository.restoreAlbumMutation(try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
        let reads = MockHTTPTransport(responses: accessResponses() + final)
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access()
        try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed); XCTAssertEqual(reviewed.completedCount, 2)
        let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"]?.hasPrefix("update") == true })
    }

    func test管理员恢复成员保存失败零写和部分保存不补目录步骤() async throws {
        for failBeforeFirst in [true, false] {
            let profile = UUID(), original = memberState(profile, role: .management), member = original.members[0].id
            var members = original.members; members[0] = members[0].changingRole(to: .entry)
            let updated = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: members)
            let folders = memberFolderSnapshotReads(parentRole: "view", childRole: nil), old = try memberStateReads(original)
            let extra = failBeforeFirst ? [] : [response(emptySuccess)] + (try memberStateReads(updated)) + (try sharedSettingsResponses(sharedSettingsFixture(profile)))
            let transport = MockHTTPTransport(responses: accessResponses() + folders + old + folders + old + extra)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let snapshot = try await repository.sharedSpaceMemberFolderSnapshot(for: member)
            let edit = SynologyPhotoMemberFolderEdit(memberID: member, original: snapshot, changes: [.init(folderID: 9, role: .download)])
            let command = SynologyPhotosMutation.setSharedMembers(original: original, members: members, folderEdits: [edit]), id = UUID()
            let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { saved in
                if let details = saved.administrationDetails,
                   failBeforeFirst ? details.memberAttempted == [0] : details.memberAttempted == [0, 1] { throw CocoaError(.fileWriteNoPermission) }
            }
            XCTAssertEqual(result.state, failBeforeFirst ? .rejected : .partial)
            let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"]?.hasPrefix("update") == true }.count, failBeforeFirst ? 0 : 1)
        }
    }

    func test管理员恢复拒绝跨账号损坏步骤和受保护管理员修改() throws {
        let profile = UUID(), original = globalSettingsFixture(profile), id = UUID()
        let command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions)
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: UUID(), userID: 12))
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 99))
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        var details = try XCTUnwrap(saved.administrationDetails); details.globalAcknowledged = [.shared]; saved.administrationDetails = details
        XCTAssertThrowsError(try saved.reviewMutation())
        details.globalAcknowledged = []; details.globalAttempted = [.shared]; saved.administrationDetails = details; XCTAssertThrowsError(try saved.reviewMutation())
        details.globalAcknowledged = []; details.memberAttempted = [0]; saved.administrationDetails = details; XCTAssertThrowsError(try saved.reviewMutation())
        let members = memberState(profile)
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: .setSharedMembers(original: members, members: [members.members[0]], folderEdits: []), operationID: id, profileID: profile, userID: 12))
    }

    private func globalSettingsFixture(_ profile: UUID) -> SynologyPhotoGlobalSettings {
        .init(profileID: profile, administratorID: 12, values: [.person: true, .concept: true, .similar: true, .userSharing: true, .guestInfo: false, .originalJPEG: true],
              excludedExtensions: ["legacy"], hasHEVC: true, personalRecognition: [.person: true, .concept: true, .similar: true],
              sharedRecognition: [.person: true, .concept: true, .similar: true], personalSpaceEnabled: true, sharedSpaceEnabled: true, sharedRole: .management)
    }
    private func globalSettingsResponses(_ settings: SynologyPhotoGlobalSettings, administrator: Bool = true) throws -> [DsmHTTPResponse] {
        var user: [String: Any] = ["enable_home_service": settings.personalSpaceEnabled, "team_space_permission": settings.sharedRole.rawValue]
        if let hevc = settings.hasHEVC { user["ame_status"] = ["has_hevc": hevc] }
        var admin: [String: Any] = ["package_version": "fixture"], team: [String: Any] = ["enabled": settings.sharedSpaceEnabled]
        for (kind, value) in settings.values { admin[kind.rawValue] = value }
        if let extensions = settings.excludedExtensions { admin["exclude_extension"] = extensions.sorted() }
        for (kind, value) in settings.personalRecognition { user[kind.rawValue] = value }
        for (kind, value) in settings.sharedRecognition { team[kind.rawValue] = value }
        return try [["enabled": true, "is_admin": administrator, "id": settings.administratorID], user, admin, team].map {
            response(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": $0]), as: UTF8.self))
        }
    }
    private func cacheResponses(size: Int64, processing: Bool = false) -> [DsmHTTPResponse] {
        [response(#"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12}}"#),
         response("{\"success\":true,\"data\":{\"status\":\"\(processing ? "processing" : "fixture-finished")\"}}"),
         response("{\"success\":true,\"data\":{\"cache_size\":\(size)}}")]
    }

    func test全局设置三种识别双向保存差量联动个人共享且不重复提交() async throws {
        for kind in [SynologyPhotoGlobalSettings.Kind.person, .concept, .similar] {
            for wasEnabled in [true, false] {
                let profile = UUID(); var original = globalSettingsFixture(profile)
                original.values[kind] = wasEnabled
                if !wasEnabled {
                    original.personalRecognition[.init(rawValue: kind.rawValue)!] = false
                    original.sharedRecognition[.init(rawValue: kind.rawValue)!] = false
                }
                var enabled = original.enabled
                if wasEnabled { enabled.remove(kind) } else { enabled.insert(kind) }
                let target = original.applying(enabled: enabled, excludedExtensions: original.excludedExtensions)
                let writes = Array(repeating: response(emptySuccess), count: wasEnabled ? 3 : 1)
                let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + writes + (try globalSettingsResponses(target)))
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: enabled, excludedExtensions: original.excludedExtensions), id = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.globalSettings, target)
                }
                let calls = try await transport.recordedRequests().map(decode), updates = calls.filter { $0["method"] == "set" }
                XCTAssertEqual(updates.count, wasEnabled ? 3 : 1)
                XCTAssertEqual(updates.map { $0["api"]! }, wasEnabled ? ["SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"] : ["SYNO.Foto.Setting.Admin"])
                for call in updates { XCTAssertEqual(call[kind.rawValue], wasEnabled ? "false" : "true"); XCTAssertNil(call["need_hevc"]); XCTAssertNil(call["enable_home_service"]) }
            }
        }
    }

    func test全局分享访客及格式差量保留未知格式且不触发其他设置() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile)
        let target = original.applying(enabled: original.enabled.subtracting([.userSharing]).union([.guestInfo]), excludedExtensions: ["legacy", "RAW", "MP4"])
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + [response(emptySuccess)] + (try globalSettingsResponses(target)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.setGlobalSettings(original: original, enabled: target.enabled, excludedExtensions: target.excludedExtensions), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode), updates = calls.filter { $0["method"] == "set" }
        XCTAssertEqual(updates.count, 1); XCTAssertEqual(updates[0]["enable_user_sharing"], "false"); XCTAssertEqual(updates[0]["display_photo_info_to_guest"], "true")
        let formats = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(updates[0]["exclude_extension"]).utf8))
        XCTAssertEqual(Set(formats), ["legacy", "RAW", "MP4"])
        XCTAssertNil(updates[0]["enable_person"]); XCTAssertNil(updates[0]["need_hevc"])
        XCTAssertFalse(original.canSave(enabled: target.enabled, excludedExtensions: ["invented"]))
        XCTAssertTrue(original.canSave(enabled: original.enabled, excludedExtensions: []))
    }

    func test全局关闭JPEG先清缓存且处理完成后才确认同时允许新缓存出现() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile)
        let target = original.applying(enabled: original.enabled.subtracting([.originalJPEG]), excludedExtensions: original.excludedExtensions)
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + cacheResponses(size: 40) +
            [response(emptySuccess), response(emptySuccess)] + (try globalSettingsResponses(target)) + cacheResponses(size: 10, processing: true) +
            (try globalSettingsResponses(target)) + cacheResponses(size: 2))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: target.enabled, excludedExtensions: target.excludedExtensions)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.conversionCache?.sizeBytes, 2)
        let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { ["set", "clear_cache"].contains($0["method"]) }
        XCTAssertEqual(writes.map { $0["method"]! }, ["clear_cache", "set"])
        XCTAssertEqual(writes[0]["api"], "SYNO.Foto.Download"); XCTAssertEqual(writes[0]["version"], "2")
        XCTAssertEqual(writes[1]["enable_converted_original_jpeg"], "false"); XCTAssertNil(writes[1]["need_hevc"])
    }

    func test全局联动中途回执丢失只读核对已完成步骤不补发未提交步骤() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile)
        let enabled = original.enabled.subtracting([.person])
        var partiallySaved = original; partiallySaved.values[.person] = false
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + [response("invalid")] +
            (try globalSettingsResponses(original)) + (try globalSettingsResponses(partiallySaved)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: enabled, excludedExtensions: original.excludedExtensions)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1); XCTAssertEqual(result.globalSettings, partiallySaved)
        XCTAssertTrue(partiallySaved.canSave(enabled: enabled, excludedExtensions: partiallySaved.excludedExtensions), "全局已关闭但下游尚未完成时仍可保存剩余差量")
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test全局清缓存回执丢失不确认设置成功也不重放() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile)
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) + cacheResponses(size: 40) + [response("invalid")] +
            (try globalSettingsResponses(original)) + cacheResponses(size: 40) + (try globalSettingsResponses(original)) + cacheResponses(size: 0))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.originalJPEG]), excludedExtensions: original.excludedExtensions)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.globalSettings?.values[.originalJPEG], true)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "clear_cache" }.count, 1); XCTAssertFalse(calls.contains { $0["method"] == "set" })
    }

    func test全局独立缓存清理丢失回执等到非处理状态且大小归零才确认() async throws {
        let profile = UUID(), original = SynologyPhotoConversionCache(profileID: profile, administratorID: 12, sizeBytes: 20, isClearing: false)
        let transport = MockHTTPTransport(responses: accessResponses() + cacheResponses(size: 25) + [response("invalid")] + cacheResponses(size: 0, processing: true) + cacheResponses(size: 4) + cacheResponses(size: 0))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.clearConversionCache(original)
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
        let features = await repository.managementFeatures(in: .shared); XCTAssertTrue(features.contains(.conversionCache))
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "clear_cache" }.count, 1)
        XCTAssertTrue(calls.filter { ["get_cache_status", "calculate_cache_size", "clear_cache"].contains($0["method"]) }.allSatisfy { $0["api"] == "SYNO.Foto.Download" && $0["version"] == "2" })
    }

    func test全局未知字段不猜默认值且真实编解码条件不能绕过() async throws {
        let profile = UUID()
        let original = SynologyPhotoGlobalSettings(profileID: profile, administratorID: 12, values: [.originalJPEG: false, .userSharing: true], excludedExtensions: nil, hasHEVC: nil,
            personalRecognition: [:], sharedRecognition: [:], personalSpaceEnabled: true, sharedSpaceEnabled: false, sharedRole: .none)
        XCTAssertFalse(original.canSave(enabled: [.userSharing, .originalJPEG], excludedExtensions: nil))
        XCTAssertFalse(original.canSave(enabled: [.person], excludedExtensions: nil))
        XCTAssertFalse(original.canSave(enabled: [], excludedExtensions: []))
        XCTAssertTrue(original.canSave(enabled: [], excludedExtensions: nil))
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let read = try await repository.globalSettings(); XCTAssertEqual(read, original); XCTAssertNil(read.excludedExtensions); XCTAssertNil(read.values[.person])
    }

    func test全局设置拒绝撤权旧快照外来NAS和正在清理缓存() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile)
        var changed = original; changed.values[.guestInfo] = true
        for administrator in [true, false] {
            let snapshot = try globalSettingsResponses(changed, administrator: administrator)
            let transport = MockHTTPTransport(responses: accessResponses() + (administrator ? snapshot : Array(snapshot.prefix(1))))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions), operationID: UUID()) { _, _ in }; XCTFail("不可覆盖变化或撤权") }
            catch let error as AppError { XCTAssertEqual(error.category, administrator ? .conflict : .permissionDenied) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
            if !administrator { let features = await repository.managementFeatures(); XCTAssertFalse(features.contains(.globalSettings)); XCTAssertFalse(features.contains(.conversionCache)) }
        }
        let transport = MockHTTPTransport(responses: accessResponses() + cacheResponses(size: 20, processing: true))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do { _ = try await repository.performMutation(.clearConversionCache(.init(profileID: profile, administratorID: 12, sizeBytes: 20, isClearing: false)), operationID: UUID()) { _, _ in }; XCTFail("清理中不可重发") } catch {}
        let foreign = globalSettingsFixture(UUID())
        do { _ = try await repository.performMutation(.setGlobalSettings(original: foreign, enabled: [], excludedExtensions: []), operationID: UUID()) { _, _ in }; XCTFail("不可跨NAS") } catch {}
        let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["clear_cache", "set"].contains($0["method"]) })
    }

    func test全局保存后续明确拒绝返回部分完成且下一次只提交剩余差量() async throws {
        let profile = UUID(), original = globalSettingsFixture(profile), enabled = original.enabled.subtracting([.person])
        var partial = original; partial.values[.person] = false; partial.personalRecognition[.person] = false
        let target = original.applying(enabled: enabled, excludedExtensions: original.excludedExtensions)
        let transport = MockHTTPTransport(responses: accessResponses() + (try globalSettingsResponses(original)) +
            [response(emptySuccess), response(emptySuccess), response(#"{"success":false,"error":{"code":105}}"#)] + (try globalSettingsResponses(partial)) +
            (try globalSettingsResponses(partial)) + [response(emptySuccess)] + (try globalSettingsResponses(target)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let first = try await repository.performMutation(.setGlobalSettings(original: original, enabled: enabled, excludedExtensions: original.excludedExtensions), operationID: UUID()) { _, _ in }
        XCTAssertEqual(first.state, .partial); XCTAssertEqual(first.completedCount, 2); XCTAssertEqual(first.globalSettings, partial)
        let final = try await repository.performMutation(.setGlobalSettings(original: partial, enabled: enabled, excludedExtensions: partial.excludedExtensions), operationID: UUID()) { _, _ in }
        XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set" }
        XCTAssertEqual(writes.map { $0["api"]! }, ["SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace", "SYNO.Foto.Setting.TeamSpace"])
        XCTAssertEqual(writes.last?["enable_person"], "false"); XCTAssertNil(writes.last?["enable_concept"])
    }

    func test全局缓存缺失大小或无效状态不当作已清空() async throws {
        for (status, size) in [(#"{"status":"fixture-finished"}"#, "{}"), (#"{"status":""}"#, #"{"cache_size":0}"#), (#"{"status":"fixture-finished"}"#, #"{"cache_size":-1}"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(#"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12}}"#),
                response("{\"success\":true,\"data\":\(status)}"), response("{\"success\":true,\"data\":\(size)}")])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.conversionCache(); XCTFail("未知或无效状态不得显示空缓存") } catch {}
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "clear_cache" })
        }
    }

    private func sharedSettingsFixture(_ profile: UUID, enabled: Bool = true, personal: Bool = true,
                                       role: SynologyPhotoSharedSpaceSettings.Role = .management) -> SynologyPhotoSharedSpaceSettings {
        .init(profileID: profile, administratorID: 12, isEnabled: enabled, personalSpaceEnabled: personal, role: role,
              values: [.person: true, .concept: true, .similar: true, .publicRoot: false], globallyEnabled: [.person, .concept, .similar])
    }

    private func sharedSettingsResponses(_ state: SynologyPhotoSharedSpaceSettings, administrator: Bool = true) throws -> [DsmHTTPResponse] {
        var team: [String: Any] = ["enabled": state.isEnabled]
        var admin: [String: Any] = ["package_version": "fixture"]
        for (kind, value) in state.values {
            team[kind.rawValue] = value
            if kind != .publicRoot { admin[kind.rawValue] = state.globallyEnabled.contains(kind) }
        }
        if let disabled = state.disabledBySharedFolder { team["team_space_disabled_by_share_folder_disabled"] = disabled }
        let payloads: [[String: Any]] = [
            ["enabled": true, "is_admin": administrator, "id": state.administratorID],
            ["enable_home_service": state.personalSpaceEnabled, "team_space_permission": state.role.rawValue], admin, team]
        return try payloads.map { response(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": $0]), as: UTF8.self)) }
    }

    func test共享空间四项设置双向差量保存并自动核对去重() async throws {
        for kind in SynologyPhotoSharedSpaceSettings.Kind.allCases {
            for value in [false, true] {
                let profile = UUID()
                var original = sharedSettingsFixture(profile); original.values[kind] = value
                var updated = original; updated.values[kind] = !value
                let old = try sharedSettingsResponses(original), new = try sharedSettingsResponses(updated)
                let transport = MockHTTPTransport(responses: accessResponses() + old + old + [response(emptySuccess)] + new)
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let read = try await repository.sharedSpaceSettings(); XCTAssertEqual(read, original)
                let command = SynologyPhotosMutation.setSharedSpaceSettings(original: original, enabled: updated.enabled), id = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.sharedSpaceSettings, updated)
                }
                let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Setting.TeamSpace")
                XCTAssertEqual(writes.first?["version"], "1"); XCTAssertEqual(writes.first?[kind.rawValue], value ? "false" : "true")
                XCTAssertNil(writes.first?["enabled"])
                for other in SynologyPhotoSharedSpaceSettings.Kind.allCases where other != kind { XCTAssertNil(writes.first?[other.rawValue]) }
            }
        }
    }

    func test共享空间启停使用独立方法且管理员身份不授予照片访问() async throws {
        for value in [false, true] {
            let profile = UUID(), original = sharedSettingsFixture(profile, enabled: value, role: .none)
            var updated = original; updated.isEnabled = !value
            // 套件启用后可能初始化识别默认值；使用实际回读值。
            updated.values[.person] = false
            let transport = MockHTTPTransport(responses: accessResponses() + (try sharedSettingsResponses(original)) + [response(emptySuccess)] + (try sharedSettingsResponses(updated)))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.setSharedSpaceEnabled(original: original, enabled: !value), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.sharedSpaceSettings, updated)
            do { _ = try await repository.timeline(in: .shared); XCTFail("管理员身份不得代替照片访问") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set_enable" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["enabled"], value ? "false" : "true")
            XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Setting.TeamSpace"); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
    }

    func test共享设置拒绝撤回管理员旧快照和不同NAS() async throws {
        let profile = UUID(), original = sharedSettingsFixture(profile)
        var changed = original; changed.values[.concept] = false
        var missing = original; missing.values.removeValue(forKey: .similar)
        for current in [changed, missing] {
            let transport = MockHTTPTransport(responses: accessResponses() + (try sharedSettingsResponses(current)))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setSharedSpaceSettings(original: original, enabled: [.person]), operationID: UUID()) { _, _ in }; XCTFail("不覆盖变化快照") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
        let transport = MockHTTPTransport(responses: accessResponses() + Array(try sharedSettingsResponses(original, administrator: false).prefix(1)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do { _ = try await repository.performMutation(.setSharedSpaceSettings(original: original, enabled: [.person]), operationID: UUID()) { _, _ in }; XCTFail("撤权后不可提交") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let features = await repository.managementFeatures(in: .personal); XCTAssertFalse(features.contains(.sharedSpaceSettings))
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 5)
        let foreignTransport = MockHTTPTransport(responses: accessResponses())
        let foreign = try makeRepository(foreignTransport); _ = try await foreign.access()
        do { _ = try await foreign.performMutation(.setSharedSpaceSettings(original: original, enabled: [.person]), operationID: UUID()) { _, _ in }; XCTFail("不得跨NAS") } catch {}
        let foreignCalls = await foreignTransport.recordedRequests(); XCTAssertEqual(foreignCalls.count, 4)
    }

    func test共享设置最后空间与全局关闭不允许绕过() async throws {
        let profile = UUID(), lastSpace = sharedSettingsFixture(profile, personal: false)
        let restricted = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: true, personalSpaceEnabled: true,
            role: .management, values: [.person: false, .publicRoot: false], globallyEnabled: [])
        let disabledFolder = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: false, personalSpaceEnabled: true,
            role: .management, disabledBySharedFolder: true, values: [:], globallyEnabled: [])
        XCTAssertTrue(disabledFolder.canSetEnabled(true), "官方仍允许尝试启用，状态原因不应形成额外禁用")
        for command in [SynologyPhotosMutation.setSharedSpaceEnabled(original: lastSpace, enabled: false),
                        .setSharedSpaceSettings(original: restricted, enabled: [.person])] {
            let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, profileID: profile)
            _ = try await repository.access()
            do { _ = try await repository.performMutation(command, operationID: UUID()) { _, _ in }; XCTFail("不应提交不可执行设置") } catch {}
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        }
    }

    func test共享设置缺失全局字段不伪造开关或关闭已有分类() async throws {
        let profile = UUID(), original = sharedSettingsFixture(profile)
        for global in ["", ",\"enable_person\":false"] {
            var responses = try sharedSettingsResponses(original)
            responses[2] = response("{\"success\":true,\"data\":{\"package_version\":\"fixture\"" + global + "}}")
            let list = #"{"success":true,"data":{"list":[{"id":"person"},{"id":"concept"}]}}"#
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", peopleEnabled: true, conceptsEnabled: true) + responses + [response(list)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let state = try await repository.sharedSpaceSettings()
            XCTAssertNil(state.values[.concept]); XCTAssertFalse(state.editable.contains(.person))
            let categories = try await repository.categories(in: .shared)
            XCTAssertEqual(categories.contains(.person), global.isEmpty); XCTAssertTrue(categories.contains(.concept))
        }
    }

    func test共享空间文件夹停用状态不额外封锁官方启用入口() async throws {
        let profile = UUID()
        let original = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: false, personalSpaceEnabled: true,
            role: .management, disabledBySharedFolder: true, values: [:], globallyEnabled: [])
        var updated = original; updated.isEnabled = true
        let transport = MockHTTPTransport(responses: accessResponses() + (try sharedSettingsResponses(original)) + [response(emptySuccess)] + (try sharedSettingsResponses(updated)))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.setSharedSpaceEnabled(original: original, enabled: true), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["method"] == "set_enable" }.count, 1)
    }

    func test共享设置回执丢失只核对不重复写入() async throws {
        let profile = UUID(), original = sharedSettingsFixture(profile)
        var updated = original; updated.values[.person] = false
        let old = try sharedSettingsResponses(original), new = try sharedSettingsResponses(updated)
        let transport = MockHTTPTransport(responses: accessResponses() + old + [response("invalid")] + old + new)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setSharedSpaceSettings(original: original, enabled: updated.enabled), id = UUID()
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(initial.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    private func recognitionResponses(_ state: SynologyPhotoRecognitionSettings) throws -> [DsmHTTPResponse] {
        var user: [String: Any] = ["enable_home_service": state.personalSpaceEnabled, "team_space_permission": "none"]
        var admin: [String: Any] = ["package_version": "fixture"]
        for (kind, value) in state.values { user[kind.rawValue] = value; admin[kind.rawValue] = state.globallyEnabled.contains(kind) }
        return try [user, admin].map { payload in
            response(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), as: UTF8.self))
        }
    }

    func test个人识别三项独立开关差量保存自动核对及去重() async throws {
        let all = Set(SynologyPhotoRecognitionSettings.Kind.allCases)
        for kind in SynologyPhotoRecognitionSettings.Kind.allCases {
            for wasEnabled in [false, true] {
                let values = Dictionary(uniqueKeysWithValues: all.map { ($0, $0 == kind ? wasEnabled : true) })
                let original = SynologyPhotoRecognitionSettings(values: values, globallyEnabled: all, personalSpaceEnabled: true)
                var changed = values; changed[kind] = !wasEnabled
                let updated = SynologyPhotoRecognitionSettings(values: changed, globallyEnabled: all, personalSpaceEnabled: true)
                let old = try recognitionResponses(original), new = try recognitionResponses(updated)
                let transport = MockHTTPTransport(responses: accessResponses() + old + old + [response(emptySuccess)] + new)
                let repository = try makeRepository(transport); _ = try await repository.access()
                let read = try await repository.recognitionSettings(); XCTAssertEqual(read, original)
                let id = UUID(), command = SynologyPhotosMutation.setRecognitionSettings(original: original, enabled: updated.enabled)
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
                }
                let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Setting.User")
                XCTAssertEqual(writes.first?[kind.rawValue], wasEnabled ? "false" : "true")
                for other in all.subtracting([kind]) { XCTAssertNil(writes.first?[other.rawValue]) }
                XCTAssertNil(writes.first?["auto_generate_thumbnail"]); XCTAssertNil(writes.first?["date_format"])
                let features = await repository.managementFeatures(in: .personal)
                let feature: SynologyPhotosManagementFeature = kind == .person ? .peopleNames : kind == .concept ? .conceptVisibility : .similarGroups
                XCTAssertEqual(features.contains(feature), !wasEnabled)
            }
        }
    }

    func test识别权限变化缺字段和个人空间关闭不得用旧快照写入() async throws {
        let all = Set(SynologyPhotoRecognitionSettings.Kind.allCases)
        let original = SynologyPhotoRecognitionSettings(values: [.person: true, .concept: true, .similar: true], globallyEnabled: all, personalSpaceEnabled: true)
        for changed in [SynologyPhotoRecognitionSettings(values: original.values, globallyEnabled: [.concept, .similar], personalSpaceEnabled: true),
                        .init(values: original.values, globallyEnabled: all, personalSpaceEnabled: false),
                        .init(values: [.concept: true, .similar: true], globallyEnabled: all, personalSpaceEnabled: true),
                        .init(values: [.person: false, .concept: true, .similar: true], globallyEnabled: all, personalSpaceEnabled: true)] {
            let transport = MockHTTPTransport(responses: accessResponses() + (try recognitionResponses(changed)))
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setRecognitionSettings(original: original, enabled: [.concept, .similar]), operationID: UUID()) { _, _ in }; XCTFail("不应覆盖权限变化或旧设置") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
        for state in [SynologyPhotoRecognitionSettings(values: [.person: false], globallyEnabled: [], personalSpaceEnabled: true),
                      .init(values: [.person: false], globallyEnabled: all, personalSpaceEnabled: false),
                      .init(values: [:], globallyEnabled: all, personalSpaceEnabled: true)] {
            let transport = MockHTTPTransport(responses: accessResponses())
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setRecognitionSettings(original: state, enabled: [.person]), operationID: UUID()) { _, _ in }; XCTFail("不可编辑项不得保存") } catch {}
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        }
    }

    func test识别断网未知结果只回读且缺字段不算成功() async throws {
        let original = SynologyPhotoRecognitionSettings(values: [.person: true], globallyEnabled: [.person], personalSpaceEnabled: true)
        let updated = SynologyPhotoRecognitionSettings(values: [.person: false], globallyEnabled: [.person], personalSpaceEnabled: true)
        let missing = SynologyPhotoRecognitionSettings(values: [:], globallyEnabled: [], personalSpaceEnabled: true)
        let transport = MockHTTPTransport(responses: accessResponses() + (try recognitionResponses(original)) + [response("invalid")] + (try recognitionResponses(missing)) + (try recognitionResponses(updated)))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setRecognitionSettings(original: original, enabled: [])
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test个人识别关闭分类不会关闭共享分类且缺字段保持独立能力() async throws {
        let original = SynologyPhotoRecognitionSettings(values: [.person: false, .concept: false, .similar: false], globallyEnabled: [.person, .concept, .similar], personalSpaceEnabled: true)
        let categories = #"{"success":true,"data":{"list":[{"id":"person"},{"id":"concept"},{"id":"similar"},{"id":"video"}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", peopleEnabled: true, conceptsEnabled: true, similarEnabled: true) + (try recognitionResponses(original)) + [response(categories), response(categories)])
        let repository = try makeRepository(transport); _ = try await repository.access(); _ = try await repository.recognitionSettings()
        let personal = try await repository.categories(in: .personal), shared = try await repository.categories(in: .shared)
        XCTAssertEqual(personal, [.videos]); XCTAssertEqual(shared, [.person, .concept, .similar, .videos])
        for kind in [SynologyPhotoCategory.person, .concept, .similar] {
            do { _ = try await repository.categoryItems(kind, in: .personal, offset: 0, limit: 20); XCTFail("关闭后不能继续读分类") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
        let features = await repository.managementFeatures(in: .shared); XCTAssertTrue(features.contains(.peopleNames)); XCTAssertTrue(features.contains(.conceptVisibility)); XCTAssertTrue(features.contains(.similarGroups))
    }

    private func displayPayload(_ value: SynologyPhotoDisplaySettings) throws -> String {
        let fields: [String: Any] = ["enable_home_service": true, "team_space_permission": "none",
            "timeline_group_unit": value.grouping.rawValue, "date_format": value.dateFormat.rawValue,
            "time_format": value.clock.rawValue, "item_sort_by": value.defaultSort.field.rawValue,
            "sort_direction": value.defaultSort.direction.rawValue, "show_item_info_in_lightbox": value.showsPreviewInfo]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": fields]), as: UTF8.self)
    }

    func test显示设置全部格式读取差量保存去重和目录默认生效() async throws {
        for format in SynologyPhotoDisplaySettings.DateFormat.allCases {
            let original = SynologyPhotoDisplaySettings(dateFormat: format)
            var updated = original; updated.defaultSort = .init(field: .filename, direction: .descending)
            for home in [true, false] {
                let old = try displayPayload(original), new = try displayPayload(updated)
                let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: home) + [response(old), response(old), response(emptySuccess), response(new)] + (home ? [response(managedFolder)] : []))
                let repository = try makeRepository(transport); _ = try await repository.access()
                let value = try await repository.displaySettings(); XCTAssertEqual(value, original)
                let features = await repository.managementFeatures(in: .personal); XCTAssertTrue(features.contains(.displaySettings))
                let command = SynologyPhotosMutation.setDisplaySettings(original: original, updated: updated), id = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed)
                }
                if home {
                    let sort = try await repository.folderSort(.init(id: 9, name: "Fixture", space: .personal))
                    XCTAssertEqual(sort, updated.defaultSort)
                }
                let calls = try await transport.recordedRequests().map(decode)
                let writes = calls.filter { $0["method"] == "set" }; XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(writes.first?["api"], "SYNO.Foto.Setting.User")
                XCTAssertEqual(writes.first?["item_sort_by"], #""filename""#)
                XCTAssertEqual(writes.first?["sort_direction"], #""desc""#)
                for key in ["date_format", "time_format", "timeline_group_unit", "show_item_info_in_lightbox", "upload_default_action"] { XCTAssertNil(writes.first?[key]) }
            }
        }
    }

    func test显示设置全部字段冻结保存且未知回执只核对() async throws {
        let original = SynologyPhotoDisplaySettings(), updated = SynologyPhotoDisplaySettings(grouping: .month, dateFormat: .monthDot, clock: .twelve, defaultSort: .init(field: .filesize, direction: .descending), showsPreviewInfo: true)
        let old = try displayPayload(original), new = try displayPayload(updated)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(old), response("invalid"), response(old), response(new)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setDisplaySettings(original: original, updated: updated), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["timeline_group_unit"], #""month""#)
        XCTAssertEqual(writes.first?["date_format"], #""mm.dd.yyyy""#)
        XCTAssertEqual(writes.first?["time_format"], #""12""#)
        XCTAssertEqual(writes.first?["show_item_info_in_lightbox"], "true")
    }

    func test显示设置缺失未知值及过期快照拒绝保存() async throws {
        let original = SynologyPhotoDisplaySettings(), updated = SynologyPhotoDisplaySettings(grouping: .month)
        let old = try displayPayload(original)
        for invalid in [old.replacingOccurrences(of: "yyyy-mm-dd", with: "unsupported"), old.replacingOccurrences(of: "takentime", with: "unsupported"),
                        old.replacingOccurrences(of: #""24""#, with: #""25""#), old.replacingOccurrences(of: #""day""#, with: #""year""#),
                        #"{"success":true,"data":{"enable_home_service":true,"team_space_permission":"none"}}"#, try displayPayload(updated)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(invalid)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.performMutation(.setDisplaySettings(original: original, updated: updated), operationID: UUID()) { _, _ in }; XCTFail("不得覆盖未知或过期设置") } catch {}
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
    }

    func test重复项默认读取保存差异回读去重且不依赖个人图库() async throws {
        let old = #"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"skip"}}"#
        let new = old.replacingOccurrences(of: "skip", with: "overwrite")
        for home in [true, false] {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: home) + [response(old), response(old), response(emptySuccess), response(new)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.duplicateSettings()
            XCTAssertEqual(original, .init(upload: .ignore, transfer: .skip))
            let features = await repository.managementFeatures(in: .personal); XCTAssertTrue(features.contains(.duplicateSettings))
            let command = SynologyPhotosMutation.setDuplicateSettings(original: original, updated: .init(upload: .ignore, transfer: .overwrite)), id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed)
            }
            let calls = try await transport.recordedRequests().map(decode)
            let write = try XCTUnwrap(calls.first { $0["method"] == "set" })
            XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
            XCTAssertEqual(write["api"], "SYNO.Foto.Setting.User"); XCTAssertEqual(write["version"], "1")
            XCTAssertEqual(write["copy_move_default_action"], #""overwrite""#); XCTAssertNil(write["upload_default_action"])
        }
    }

    func test重复设置快照过期或无改动不保存且未知枚举不猜默认值() async throws {
        let old = #"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"skip"}}"#
        for payload in [old, old.replacingOccurrences(of: "ignore", with: "unknown"), #"{"success":true,"data":{}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(payload)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                _ = try await repository.performMutation(.setDuplicateSettings(original: .init(upload: .rename, transfer: .skip), updated: .init(upload: .ignore, transfer: .overwrite)), operationID: UUID()) { _, _ in }
                XCTFail("不能用过期或不完整默认值写入")
            } catch {}
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
        let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport)
        _ = try await repository.access()
        let value = SynologyPhotoDuplicateSettings(upload: .ignore, transfer: .skip)
        do { _ = try await repository.performMutation(.setDuplicateSettings(original: value, updated: value), operationID: UUID()) { _, _ in }; XCTFail("无变更不提交") } catch {}
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
    }

    func test重复设置结果未知只回读不重复保存() async throws {
        let old = #"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"skip"}}"#
        let new = old.replacingOccurrences(of: "ignore", with: "rename")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(old), response("invalid"), response(old), response(new)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setDuplicateSettings(original: .init(upload: .ignore, transfer: .skip), updated: .init(upload: .rename, transfer: .skip)), id = UUID()
        let initial = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(initial.state, .pendingReview)
        let stillPending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(stillPending.state, .pendingReview)
        let result = try await repository.reviewMutation(operationID: id); XCTAssertEqual(result.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test上传忽略回执按现有照片身份核对且不算新上传() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.jpg")
        try Data(repeating: 1, count: 256).write(to: source)
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        for scenario in ["valid", "wrongName", "wrongFolder", "wrongPolicy"] {
            let page = scenario == "wrongName" ? itemPage.replacingOccurrences(of: "sample.jpg", with: "other.jpg") : scenario == "wrongFolder" ? itemPage.replacingOccurrences(of: #""folder_id":9"#, with: #""folder_id":10"#) : itemPage
            let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(#"{"success":true,"data":{"id":7,"action":"ignore"}}"#), response(page), response(page)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let command = SynologyPhotosMutation.upload(file: source, size: 256, modifiedAt: modified, folderID: 9, duplicate: scenario == "wrongPolicy" ? .rename : .ignore), id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, scenario == "valid" ? .confirmed : .pendingReview)
            if scenario == "valid" { XCTAssertEqual(result.completedCount, 0); XCTAssertEqual(result.skippedCount, 1); XCTAssertEqual(result.photos.first?.sizeBytes, 128) }
            let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(repeated.state, result.state)
            let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
            XCTAssertTrue(String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self).contains(scenario == "wrongPolicy" ? #""rename""# : #""ignore""#))
        }
    }

    func test相册上传忽略允许保留原提供者且仍通过相册回读() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.jpg")
        try Data(repeating: 1, count: 256).write(to: source)
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum(owner: 99)), response(collaborationPermission()), response(#"{"success":true,"data":{"id":7,"action":"ignore"}}"#), response(collaborationPage(provider: 99))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.performMutation(.uploadToAlbum(file: source, size: 256, modifiedAt: modified, albumID: 21, duplicate: .ignore), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 0); XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.photos.first?.albumContext?.providerUserID, 99)
        let calls = await transport.recordedRequests()
        let fields = try calls.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(decode)
        XCTAssertEqual(fields.last?["album_id"], "21")
    }

    func test重复项保存权限拒绝不改变设置且不重发() async throws {
        let old = #"{"success":true,"data":{"upload_default_action":"ignore","copy_move_default_action":"skip"}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(old), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setDuplicateSettings(original: .init(upload: .ignore, transfer: .skip), updated: .init(upload: .rename, transfer: .skip)), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .rejected)
        }
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set" }.count, 1)
    }

    func test复制覆盖明确策略允许覆盖计数且拒绝越界或跳过策略覆盖() async throws {
        for (policy, count, completion, expected) in [(SynologyPhotoDuplicateSettings.Transfer.overwrite, 1, 1, SynologyPhotosMutationResult.State.confirmed), (.overwrite, 2, 1, .pendingReview), (.skip, 1, 1, .pendingReview), (.overwrite, 1, 0, .pendingReview)] {
            let target = managedFolder.replacingOccurrences(of: #""id":9"#, with: #""id":10"#)
            let status = "{\"success\":true,\"data\":{\"list\":[{\"id\":2,\"status\":\"done\",\"completion\":\(completion),\"error\":0,\"skip\":0,\"overwrite\":\(count)}]}}"
            let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder), response(target), response(#"{"success":true,"data":{"task_info":{"id":2}}}"#), response(status)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let photos = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
            let command = SynologyPhotosMutation.copy(photos.items, folderID: 10, duplicate: policy), id = UUID()
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, expected)
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls.first { $0["method"] == "copy" }?["action"], "\"\(policy.rawValue)\"")
        }
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

    func test共享上传使用共享权限目标和回读且操作编号不能换空间() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let uploadFolder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
        for folderID: Int? in [9, nil] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) +
                Array(repeating: response(uploadFolder), count: folderID == nil ? 2 : 1) + [response(#"{"success":true,"data":{"id":7,"action":"rename"}}"#), response(itemPage)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let features = await repository.managementFeatures(in: .shared)
            XCTAssertTrue(features.contains(.upload)); XCTAssertTrue(features.contains(.folders))
            let command = SynologyPhotosMutation.upload(file: source, size: 128, modifiedAt: modified, folderID: folderID, space: .shared)
            let operationID = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: operationID) { _, _ in }
                XCTAssertEqual(result.state, .confirmed)
                XCTAssertEqual(result.photos.first?.id.space, .shared)
                XCTAssertEqual(result.photos.first?.folderID, 9)
            }
            do {
                _ = try await repository.performMutation(.upload(file: source, size: 128, modifiedAt: modified, folderID: folderID), operationID: operationID) { _, _ in }
                XCTFail("同操作编号不能改为个人空间")
            } catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let bodies = await transport.recordedUploadBodies()
            XCTAssertEqual(bodies.count, 1)
            let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
            XCTAssertTrue(body.contains("SYNO.FotoTeam.Upload.Item"))
            XCTAssertFalse(body.contains("fixture-session")); XCTAssertFalse(body.contains("fixture-token"))
            if folderID == nil { XCTAssertTrue(body.contains("PhotoLibrary")); XCTAssertTrue(body.contains("timeline")) }
            else { XCTAssertTrue(body.contains("upload_to_folder")); XCTAssertTrue(body.contains("target_folder_id")) }
            let requests = await transport.recordedRequests()
            let reads = try requests.dropFirst(4).filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(decode)
            XCTAssertTrue(reads.allSatisfy { $0["api"]?.hasPrefix("SYNO.FotoTeam.") == true })
        }
    }

    func test共享上传无目录上传权限时不发送文件且管理角色按共享权限处理() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let denied = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":false"#)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(denied)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do {
            _ = try await repository.performMutation(.upload(file: source, size: 128, modifiedAt: modified, folderID: 9, space: .shared), operationID: UUID()) { _, _ in }
            XCTFail("没有上传权限不得发送文件")
        } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let bodies = await transport.recordedUploadBodies()
        XCTAssertTrue(bodies.isEmpty)
    }

    func test共享上传回读目录不符保持待核对且不重新上传() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let wrong = itemPage.replacingOccurrences(of: #""folder_id":9"#, with: #""folder_id":11"#)
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(managedFolder), response(#"{"success":true,"data":{"id":7}}"#), response(wrong), response(itemPage)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.upload(file: source, size: 128, modifiedAt: modified, folderID: 9, space: .shared)
        let id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let reviewed = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(reviewed.state, .confirmed)
        XCTAssertEqual(reviewed.photos.first?.id.space, .shared)
        let bodies = await transport.recordedUploadBodies()
        XCTAssertEqual(bodies.count, 1)
    }

    func test共享创建目录以共享父目录预检并回读目标() async throws {
        let parent = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false,"upload":true"#)
        let child = #"{"success":true,"data":{"folder":{"id":10,"name":"/Sample/Trip","parent":9,"additional":{"access_permission":{"view":true,"manage":false,"upload":true}}}}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [response(parent), response(#"{"success":true,"data":{"folder":{"id":10}}}"#), response(child)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.createFolder(parentID: 9, name: "Trip", space: .shared), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            XCTAssertEqual(result.folder?.id, 10)
        }
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertEqual(requests.map { $0["api"] }, Array(repeating: "SYNO.FotoTeam.Browse.Folder", count: 3))
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
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

    private func requestFixture(_ settings: SynologyPhotoRequestSettings, id: String = "fixture-request", list: Bool = true, valid: Bool = true) throws -> String {
        var value: [String: Any] = ["passphrase": id, "subject": settings.subject, "description": settings.description,
            "library": settings.space == .personal ? "personal_space" : "shared_space", "folder_home_path": settings.folderPath,
            "folder_id": settings.folderID ?? 9, "expiration": settings.expiration, "filesize_limit": settings.sizeLimit,
            "is_folder_valid": valid, "sharing_link": "https://example.invalid/request/fixture"]
        if let albumID = settings.albumID { value["album_id"] = albumID }
        if let passphrase = settings.albumPassphrase { value["album_passphrase"] = passphrase }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": list ? ["list": [value]] : value], options: [.sortedKeys]), as: UTF8.self)
    }

    func test收集请求个人共享创建按回执身份回读并去重() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let settings = SynologyPhotoRequestSettings(subject: "Fixture", description: "Synthetic collection", space: space, folderPath: "/Sample", folderID: 9, expiration: 2_000_000_000, sizeLimit: 25 * 1_048_576)
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(managedFolder), response(try requestFixture(settings, list: false)), response(try requestFixture(settings))])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let id = UUID(), command = SynologyPhotosMutation.createPhotoRequest(settings)
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed)
                XCTAssertEqual(result.photoRequest?.settings, settings)
                XCTAssertNotNil(result.sharingURL)
            }
            let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
            XCTAssertEqual(requests.first?["api"], space == .personal ? "SYNO.Foto.Browse.Folder" : "SYNO.FotoTeam.Browse.Folder")
            let create = try XCTUnwrap(requests.first { $0["method"] == "create" })
            XCTAssertEqual(create["api"], "SYNO.Foto.PhotoRequest")
            XCTAssertEqual(create["passphrase"], "\"\"")
            XCTAssertEqual(create["filesize_limit"], "26214400")
            XCTAssertNil(create["folder_id"])
            XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        }
    }

    func test共享收集默认目录管理权限撤销后不再允许自动建目录() async throws {
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", space: .shared, folderPath: "/PhotoRequest/Fixture")
        let transport = MockHTTPTransport(responses:
            accessResponses(teamPermission: "management", homeEnabled: false) +
            [response(managedFolder), response(managedFolder), response(try requestFixture(settings, list: false)), response(try requestFixture(settings))] +
            accessResponses(teamPermission: "entry", homeEnabled: false))
        let repository = try makeRepository(transport)
        let firstAccess = try await repository.access()
        XCTAssertTrue(firstAccess.canManageSharedSpace)
        let operationID = UUID()
        let result = try await repository.performMutation(.createPhotoRequest(settings), operationID: operationID) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let secondAccess = try await repository.access()
        XCTAssertFalse(secondAccess.canManageSharedSpace)
        do { try await repository.prepareMutation(.createPhotoRequest(settings)); XCTFail("新权限不允许默认共享目录") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await transport.recordedRequests().map(decode)
        let writes = requests.filter { $0["method"] == "create" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?["library"], "\"shared_space\"")
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.FotoTeam.Browse.Folder" && $0["method"] == "create" })
    }

    func test默认收集目录无需提前存在且只允许可创建空间() async throws {
        let settings = SynologyPhotoRequestSettings(subject: "Fixture:2020", folderPath: "/PhotoRequest/Fixture_2020")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(managedFolder), response(try requestFixture(settings, list: false)), response(try requestFixture(settings))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let result = try await repository.performMutation(.createPhotoRequest(settings), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.photoRequest?.settings.folderID, 9)
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertFalse(requests.contains { $0["api"]?.contains("Folder") == true && $0["method"] == "create" })
        let sharedTransport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false))
        let sharedRepository = try makeRepository(sharedTransport)
        _ = try await sharedRepository.access()
        var shared = settings; shared.space = .shared
        do { try await sharedRepository.prepareMutation(.createPhotoRequest(shared)); XCTFail("entry不能自动创建默认目录") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test收集创建回执丢失不能按名称追认或重复创建() async throws {
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(managedFolder)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.createPhotoRequest(settings), id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "create" }.count, 1)
        XCTAssertFalse(requests.contains { $0["method"] == "list" })
    }

    func test收集请求编辑只发差量且清除目标相册使用负一() async throws {
        var old = SynologyPhotoRequestSettings(subject: "Fixture", description: "Before", folderPath: "/Sample", folderID: 9, albumID: 3, expiration: 2_000_000_000, sizeLimit: 1234567)
        var desired = old; desired.description = "After"; desired.albumID = nil
        let before = try requestFixture(old), after = try requestFixture(desired)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before), response(managedFolder), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.photoRequest(id: "fixture-request")
        let result = try await repository.performMutation(.updatePhotoRequest(original: original, settings: desired), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.photoRequest?.settings, desired)
        let requests = try await transport.recordedRequests().map(decode)
        let update = try XCTUnwrap(requests.first { $0["method"] == "update" })
        XCTAssertEqual(update["album_id"], "-1"); XCTAssertEqual(update["description"], "\"After\"")
        for field in ["subject", "expiration", "filesize_limit", "library", "folder_home_path", "album_passphrase"] { XCTAssertNil(update[field]) }
        old.subject = "Changed elsewhere"
        let conflictTransport = MockHTTPTransport(responses: accessResponses() + [response(try requestFixture(old))])
        let conflictRepository = try makeRepository(conflictTransport, profileID: original.profileID)
        _ = try await conflictRepository.access()
        do { try await conflictRepository.prepareMutation(.updatePhotoRequest(original: original, settings: desired)); XCTFail("快照改变必须停止") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
    }

    func test删除收集请求只删除精确链接并自动确认失效且不要求原目录有效() async throws {
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        let before = try requestFixture(settings, valid: false)
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(before), response(before)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(#"{"success":true,"data":{"list":[]}}"#))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.photoRequest(id: "fixture-request"), id = UUID()
        let first = try await repository.performMutation(.deletePhotoRequest(original), operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let reviewed = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(reviewed.state, .confirmed)
        let repeated = try await repository.performMutation(.deletePhotoRequest(original), operationID: id) { _, _ in }
        XCTAssertEqual(repeated.state, .confirmed)
        let requests = try await transport.recordedRequests().dropFirst(4).map(decode)
        XCTAssertTrue(requests.allSatisfy { $0["api"] == "SYNO.Foto.PhotoRequest" })
        XCTAssertEqual(requests.filter { $0["method"] == "delete" }.count, 1)
        XCTAssertEqual(requests.first { $0["method"] == "delete" }?["passphrase"], "[\"fixture-request\"]")
    }

    func test收集目标相册使用可添加列表并区分自己和共享目标() async throws {
        let choices = #"{"success":true,"data":{"list":[{"id":3,"name":"Owned","owner_user_id":12,"shared":false},{"id":4,"name":"Shared","owner_user_id":22,"shared":true,"additional":{"sharing_info":{"passphrase":"fixture-album"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(choices)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let albums = try await repository.photoRequestAlbums()
        XCTAssertEqual(albums.map(\.albumID), [3, nil]); XCTAssertEqual(albums.map(\.passphrase), [nil, "fixture-album"])
        let recorded = await transport.recordedRequests()
        let request = try decode(XCTUnwrap(recorded.last))
        XCTAssertEqual(request["api"], "SYNO.Foto.Browse.NormalAlbum"); XCTAssertEqual(request["category"], "\"addable\"")
    }

    func test收集请求改共享目标同时发送空间目录并使用相册分享标识() async throws {
        let old = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        var desired = old; desired.space = .shared; desired.folderPath = "/Shared"; desired.folderID = 10; desired.albumPassphrase = "fixture-album"
        let before = try requestFixture(old), after = try requestFixture(desired)
        let folder = #"{"success":true,"data":{"folder":{"id":10,"name":"/Shared","parent":1,"additional":{"access_permission":{"view":true,"manage":false,"upload":true}}}}}"#
        let albums = #"{"success":true,"data":{"list":[{"id":4,"name":"Shared","owner_user_id":22,"shared":true,"additional":{"sharing_info":{"passphrase":"fixture-album"}}}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry") + [response(before), response(before), response(folder), response(albums), response(emptySuccess), response(after)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.photoRequest(id: "fixture-request")
        let result = try await repository.performMutation(.updatePhotoRequest(original: original, settings: desired), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        let update = try XCTUnwrap(requests.first { $0["method"] == "update" })
        XCTAssertEqual(update["library"], "\"shared_space\"")
        let encodedPath = try XCTUnwrap(update["folder_home_path"]?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: encodedPath), "/Shared")
        XCTAssertEqual(update["album_passphrase"], "\"fixture-album\"")
        XCTAssertNil(update["album_id"])
        XCTAssertTrue(requests.contains { $0["api"] == "SYNO.FotoTeam.Browse.Folder" })
    }

    func test收集请求读取缺字段不能用于管理且缺少接口不影响其他能力() async throws {
        let invalid = #"{"success":true,"data":{"list":[{"passphrase":"fixture-request","subject":"Fixture"}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses() + [response(invalid)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { _ = try await repository.photoRequest(id: "fixture-request"); XCTFail("缺少目标与限制信息不能形成修改快照") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let absent = try makeRepository(MockHTTPTransport(responses: accessResponses()), omittedAPIs: ["SYNO.Foto.PhotoRequest"])
        _ = try await absent.access()
        let features = await absent.managementFeatures()
        XCTAssertFalse(features.contains(.photoRequests)); XCTAssertTrue(features.contains(.sharing)); XCTAssertTrue(features.contains(.metadata))
    }

    func test收集请求拒绝跨NAS和目录移位及写后不同结果() async throws {
        let settings = SynologyPhotoRequestSettings(subject: "Fixture", folderPath: "/Sample", folderID: 9)
        let foreign = SynologyPhotoRequest(id: "fixture-request", profileID: UUID(), settings: settings, isFolderValid: true)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder.replacingOccurrences(of: "/Sample", with: "/Moved"))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        do { try await repository.prepareMutation(.deletePhotoRequest(foreign)); XCTFail("跨NAS目标必须拒绝") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { try await repository.prepareMutation(.createPhotoRequest(settings)); XCTFail("目录路径改变必须拒绝") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        var different = settings; different.sizeLimit = 25 * 1_048_576
        let mismatchTransport = MockHTTPTransport(responses: accessResponses() + [response(managedFolder), response(try requestFixture(settings, list: false)), response(try requestFixture(different))])
        let mismatchRepository = try makeRepository(mismatchTransport)
        _ = try await mismatchRepository.access()
        let result = try await mismatchRepository.performMutation(.createPhotoRequest(settings), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { ["create", "update", "delete"].contains($0["method"] ?? "") })
    }

    func test分享密码设置替换清除均核对且不改有效期成员() async throws {
        for enabled in [true, false] {
            for protected in [true, false] {
                for password in [" synthetic 密码 + & / ", ""] {
                    let before = sharingFixture(shared: enabled).replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":\#(protected)"#)
                    let after = sharingFixture(shared: enabled).replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":\#(!password.isEmpty)"#)
                    var replies = [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess)]
                    if enabled { replies.append(response(emptySuccess)) }
                    replies.append(response(after))
                    let transport = MockHTTPTransport(responses: accessResponses() + replies)
                    let repository = try makeRepository(transport)
                    _ = try await repository.access()
                    let original = try await repository.albumSharing(id: 3)
                    let command = SynologyPhotosMutation.shareAlbum(id: 3, access: enabled ? .download : .disabled, original: original, password: password), id = UUID()
                    for _ in 0..<2 {
                        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                        XCTAssertEqual(result.state, .confirmed)
                    }
                    let requests = await transport.recordedRequests()
                    XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && !($0.url?.absoluteString.contains("password") ?? true) })
                    let updates = try requests.map(decode).filter { $0["method"] == "update" }
                    XCTAssertEqual(updates.count, 1)
                    let encoded = try XCTUnwrap(updates.first?["password"]?.data(using: .utf8))
                    XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoded), password)
                    XCTAssertNil(updates.first?["expiration"]); XCTAssertNil(updates.first?["permission"])
                }
            }
        }
    }

    func test改密回执丢失不能以原保护状态为真确认成功且不重发() async throws {
        for enabled in [true, false] {
            let before = sharingFixture(shared: enabled)
            let setup = accessResponses() + [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#)]
            let transport = MockHTTPTransport(steps: setup.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(before)), .response(response(before))])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            let command = SynologyPhotosMutation.shareAlbum(id: 3, access: enabled ? .download : .disabled, original: original, password: "synthetic-new-password"), id = UUID()
            let first = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(first.state, .pendingReview)
            for _ in 0..<2 {
                let reviewed = try await repository.reviewMutation(operationID: id)
                XCTAssertEqual(reviewed.state, .pendingReview)
            }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, 1)
            XCTAssertFalse(requests.contains { $0["enabled"] == "true" })
        }
    }

    func test清除密码回执丢失可凭明确无密码回读确认() async throws {
        let before = sharingFixture(shared: false)
        let after = before.replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":false"#)
        let setup = accessResponses() + [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#)]
        let transport = MockHTTPTransport(steps: setup.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(after))])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3), id = UUID()
        _ = try await repository.performMutation(.shareAlbum(id: 3, access: .disabled, original: original, password: ""), operationID: id) { _, _ in }
        let result = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(result.state, .confirmed)
    }

    func test改密收到回执但保护成员或期限不符仍不能确认() async throws {
        let before = sharingFixture()
        for after in [before.replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":false"#), before.replacingOccurrences(of: #""enable_password":true,"#, with: ""), before.replacingOccurrences(of: #""expiration":100"#, with: #""expiration":0"#), before.replacingOccurrences(of: #""permission":[]"#, with: #""permission":[{"type":"user","id":22,"role":"view"}]"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before), response(before), response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            let result = try await repository.performMutation(.shareAlbum(id: 3, access: .download, original: original, password: "synthetic-password"), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
    }

    func test密码修改必须有分享快照且原设置冲突不发送() async throws {
        let before = sharingFixture()
        for conflict in [false, true] {
            var replies = [response(before), response(conflict ? before.replacingOccurrences(of: #""expiration":100"#, with: #""expiration":200"#) : before)]
            if conflict { replies.append(response(before)) }
            let transport = MockHTTPTransport(responses: accessResponses() + replies)
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do {
                _ = try await repository.performMutation(.shareAlbum(id: 3, access: .download, original: conflict ? original : nil, password: "synthetic-password"), operationID: UUID()) { _, _ in }
                XCTFail("无快照或原状态改变不能修改密码")
            } catch let error as AppError { XCTAssertEqual(error.category, conflict ? .conflict : .invalidResponse) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
        }
    }

    func test分享有效期设置取消关闭时修改均自动核对且不改密码成员() async throws {
        for enabled in [true, false] {
            for seconds in [0, 2_000_000_000] {
                let before = sharingFixture(shared: enabled)
                let after = before.replacingOccurrences(of: #""expiration":100"#, with: #""expiration":\#(seconds)"#)
                var replies = [response(before), response(before), response(before),
                    response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess)]
                if enabled { replies.append(response(emptySuccess)) }
                replies.append(response(after))
                let transport = MockHTTPTransport(responses: accessResponses() + replies)
                let repository = try makeRepository(transport)
                _ = try await repository.access()
                let original = try await repository.albumSharing(id: 3)
                let id = UUID()
                let command = SynologyPhotosMutation.shareAlbum(id: 3, access: enabled ? .download : .disabled, original: original, expiration: seconds)
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, .confirmed)
                }
                let writes = try await transport.recordedRequests().map(decode).filter { $0["api"] == "SYNO.Foto.Sharing.Passphrase" }
                let update = try XCTUnwrap(writes.first { $0["method"] == "update" })
                XCTAssertEqual(update["expiration"], String(seconds))
                XCTAssertNil(update["permission"]); XCTAssertNil(update["password"])
                XCTAssertEqual(writes.filter { $0["method"] == "update" }.count, 1)
                XCTAssertEqual(writes.filter { $0["enabled"] == "true" }.count, enabled ? 1 : 0)
            }
        }
    }

    func test分享有效期未改变不写入() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + Array(repeating: response(sharingFixture()), count: 3))
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let original = try await repository.albumSharing(id: 3)
        let result = try await repository.performMutation(.shareAlbum(id: 3, access: .download, original: original, expiration: 100), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
    }

    func test分享有效期回读不符或密码变化不报告成功且不重发() async throws {
        for after in [sharingFixture(), sharingFixture().replacingOccurrences(of: #""expiration":100"#, with: #""expiration":0"#).replacingOccurrences(of: #""enable_password":true"#, with: #""enable_password":false"#)] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(sharingFixture()), response(sharingFixture()), response(sharingFixture()),
                response(#"{"success":true,"data":{"passphrase":"fixture-passphrase"}}"#), response(emptySuccess), response(emptySuccess), response(after), response(after)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            let id = UUID(), command = SynologyPhotosMutation.shareAlbum(id: 3, access: .download, original: original, expiration: 0)
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .pendingReview)
            }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "update" }.count, 1)
        }
    }

    func test有效期修改必须有原快照且不能为负数() async throws {
        for missing in [true, false] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(sharingFixture()), response(sharingFixture())])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.albumSharing(id: 3)
            do {
                try await repository.prepareMutation(.shareAlbum(id: 3, access: .download, original: missing ? nil : original, expiration: missing ? 0 : -1))
                XCTFail("不得在没有确认快照时改变链接期限")
            } catch {}
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Sharing.Passphrase" })
        }
    }

    func test读取分享有效期数值不把未知值当作无限期() async throws {
        for (raw, expected) in [("0", Optional(0)), ("2000000000.0", Optional(2_000_000_000)), ("-1", nil), ("0.5", nil), (#""unknown""#, nil)] {
            let value = sharingFixture().replacingOccurrences(of: #""expiration":100"#, with: #""expiration":\#(raw)"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(value)])
            let repository = try makeRepository(transport)
            _ = try await repository.access()
            let state = try await repository.albumSharing(id: 3)
            XCTAssertEqual(state.expiration, expected)
            XCTAssertEqual(state.hasExpiration, expected.map { $0 > 0 })
        }
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

    func test人物恢复改名仅保存摘要且清空名称保留回执条件() async throws {
        for clear in [false, true] {
            let profile = UUID(), person = SynologyPhotoCollection(id: 31, name: "Private before", itemCount: 1)
            let name = clear ? "" : "Private after", id = UUID(), capture = PhotosAlbumCheckpointCapture()
            let after = personList(clear ? [] : [(31, name, 1)])
            let receipt = "{\"success\":true,\"data\":{\"id\":31,\"name\":\"\(name)\"}}"
            let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, person.name, 1)])), response(receipt), response(after)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.renamePerson(person, name: name)
            let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }
            XCTAssertEqual(result.state, .confirmed)
            let data = try JSONEncoder().encode(XCTUnwrap(capture.values.last))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private"))
            let saved = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data); XCTAssertEqual(saved.version, SynologyPhotosAlbumCheckpoint.currentVersion)
            try await repository.restoreAlbumMutation(saved)
            let reads = MockHTTPTransport(responses: accessResponses() + [response(after)])
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed)
            XCTAssertEqual(reviewed.person?.name, name)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set" })
        }
    }

    func test人物恢复合并保存原成员并集且错误目标仍未知() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let before = personList([(31, "Target", 1), (32, "Source", 1)]), after = personList([(31, "Combined", 1)])
        let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(personTimeline), response(itemPage), response(managedFolder), response(personTimeline), response(itemPage), response(before), response(emptySuccess), response(after), response(personTimeline), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.mergePeople(target: .init(id: 31, name: "Target", itemCount: 1), sources: [.init(id: 32, name: "Source", itemCount: 1)], name: "Combined")
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
        let saved = try XCTUnwrap(capture.values.last); XCTAssertEqual(saved.recognitionDetails?.personPhotoIDs, [7])
        for matches in [false, true] {
            let reads = MockHTTPTransport(responses: accessResponses() + [response(after), response(personTimeline), response(matches ? itemPage : itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#))])
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, matches ? .confirmed : .pendingReview)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "merge" })
        }
    }

    func test人物恢复封面必须有真实回执不能把照片编号当封面() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), photo = facePhoto(profile)
        let person = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1)
        let cover = #"{"success":true,"data":{"list":[{"id":31,"name":"Person","cover":71}]}}"#
        let final = [response(cover), response(personList([(31, "Person", 1)]))]
        let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":31,"cover":71}}"#)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.setPersonCover(person: person, photo: photo)
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
        for acknowledged in [false, true] {
            let saved = try acknowledged ? XCTUnwrap(capture.values.last) : SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            let reads = MockHTTPTransport(responses: accessResponses() + (acknowledged ? final : []))
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, acknowledged ? .confirmed : .pendingReview)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set_cover" })
        }
    }

    func test人物恢复归属移动保留新人物编号且无回执不按名称追认() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), photo = facePhoto(profile)
        let source = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1)
        let command = SynologyPhotosMutation.reassignPersonFaces(person: source, faces: [.init(id: 71, personID: 31, photo: photo)], target: nil, name: "Target")
        let final = [response(faceList([])), response(faceList([71])), response(personList([(32, "Target", 1)])), response(personList([(32, "Target", 1)])), response(itemPage)]
        let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
        for acknowledged in [false, true] {
            let saved = try acknowledged ? XCTUnwrap(capture.values.last) : SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
            let reads = MockHTTPTransport(responses: accessResponses() + (acknowledged ? final : [response(faceList([]))]))
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, acknowledged ? .confirmed : .pendingReview)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["separate", "delete_face"].contains($0["method"]) })
        }
    }

    func test人物移出恢复不能把原件变化当作仅移出分类成功() async throws {
        let profile = UUID(), id = UUID(), photo = facePhoto(profile)
        let command = SynologyPhotosMutation.removePersonFaces(person: .init(id: 31, name: "Person"), faces: [.init(id: 71, personID: 31, photo: photo)])
        let saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        for originalIntact in [false, true] {
            let detail = originalIntact ? itemPage : itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(faceList([])), response(personList([])), response(detail)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access(); try await repository.restoreAlbumMutation(saved)
            do {
                let result = try await repository.reviewMutation(operationID: id)
                if originalIntact { XCTAssertEqual(result.state, .confirmed); XCTAssertTrue(result.deletedPhotoIDs.isEmpty) }
                else { XCTAssertNotEqual(result.state, .confirmed) }
            } catch { XCTAssertFalse(originalIntact) }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["delete_face", "delete"].contains($0["method"]) })
        }
    }

    func test人物主题恢复显示部分完成保持原来源且不重写() async throws {
        for concept in [false, true] {
            for space in SynologyPhotoSpace.allCases {
                let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture()
                let before = concept ? conceptList([(31, true), (32, true)]) : visibilityList([(31, true), (32, true)])
                let after = concept ? conceptList([(31, false), (32, true)]) : visibilityList([(31, false), (32, true)])
                let access = accessResponses(teamPermission: space == .shared ? "management" : "none", peopleEnabled: true, conceptsEnabled: true)
                let transport = MockHTTPTransport(responses: access + [response(before), response(emptySuccess), response(after)])
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let people = [31, 32].map { SynologyPhotoCollection(id: $0, name: "Person", space: space) }
                let command: SynologyPhotosMutation = concept ? .setConceptVisibility(people.map { .init(concept: $0, isVisible: true) }, visible: false) : .setPeopleVisibility(people.map { .init(person: $0, isVisible: true) }, visible: false)
                let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .partial)
                let saved = try XCTUnwrap(capture.values.last)
                let reads = MockHTTPTransport(responses: access + [response(after)])
                let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
                let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .partial); XCTAssertEqual(reviewed.completedCount, 1)
                let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["show", "set_visibility"].contains($0["method"]) })
                XCTAssertEqual(calls.last?["api"], (space == .shared ? "SYNO.FotoTeam.Browse." : "SYNO.Foto.Browse.") + (concept ? "Concept" : "Person"))
            }
        }
    }

    func test主题恢复移出检查原件身份摘要且封面使用原目标() async throws {
        for cover in [false, true] {
            let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), photo = conceptPhoto(profile, id: 7, in: .personal)
            let original = conceptSnapshot(count: 1)
            let final = cover ? [response(conceptDetail(count: 1, cover: 7))] : [response(conceptDetail(count: 0)), response(#"{"success":true,"data":{"section":[]}}"#), response(conceptMembers([7]))]
            let transport = MockHTTPTransport(responses: accessResponses(conceptsEnabled: true) + conceptPreflight([7]) + [response(emptySuccess)] + final)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command: SynologyPhotosMutation = cover ? .setConceptCover(concept: original, photo: photo) : .removeConceptItems(concept: original, photos: [photo])
            let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
            let saved = try XCTUnwrap(capture.values.last), data = try JSONEncoder().encode(saved)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(photo.filename))
            let reads = MockHTTPTransport(responses: accessResponses(conceptsEnabled: true) + final)
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed); XCTAssertTrue(reviewed.deletedPhotoIDs.isEmpty)
            let calls = try await reads.recordedRequests().map(decode); XCTAssertFalse(calls.contains { ["hide_item", "set_cover", "delete"].contains($0["method"]) })
        }
    }

    func test手工人脸恢复逐步保存回执且重启不保存或重传图片() async throws {
        let profile = UUID(), id = UUID(), capture = PhotosAlbumCheckpointCapture(), photo = facePhoto(profile)
        let final = [response(manualList([(72, 32, "Target")])), response(itemPage)]
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person")])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(emptySuccess)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.editPhotoFaces(photo: photo, changes: [.remove(manualRegion(71)), .add(addedFace())])
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { capture.append($0) }; XCTAssertEqual(result.state, .confirmed)
        let snapshots = capture.values.compactMap(\.recognitionDetails)
        XCTAssertTrue(snapshots.contains { $0.manualNewIDs == ["7-0": 72] && $0.manualThumbnailAttempted.isEmpty })
        XCTAssertTrue(snapshots.contains { $0.manualUploaded == [72] && $0.manualAttempted == ["face-71"] && $0.manualAcknowledged == ["new-7-0"] })
        let saved = try XCTUnwrap(capture.values.last), data = try JSONEncoder().encode(saved), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(#""Target""#)); XCTAssertFalse(text.contains(#""Person""#)); XCTAssertFalse(text.contains(photo.filename)); XCTAssertFalse(text.contains(faceJPEG.base64EncodedString()))
        let reads = MockHTTPTransport(responses: accessResponses() + final)
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: data))
        let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .confirmed); XCTAssertEqual(reviewed.completedCount, 2)
        let requests = await reads.recordedRequests()
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        let calls = try requests.map(decode); XCTAssertFalse(calls.contains { ["add_face", "delete_face"].contains($0["method"]) })
    }

    func test手工人脸恢复上传丢回执只按新编号和图像摘要确认() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.editPhotoFaces(photo: facePhoto(profile), changes: [.add(addedFace())])
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        var details = try XCTUnwrap(saved.recognitionDetails)
        details.manualAddAttempted = true; details.manualAddAcknowledged = true; details.manualNewIDs = ["7-0": 72]; details.manualThumbnailAttempted = [72]; saved.recognitionDetails = details
        for matches in [false, true] {
            let image = DsmHTTPResponse(data: matches ? faceJPEG : Data([0xff, 0xd8, 0xff, 0x11]), statusCode: 200, headers: ["Content-Type": "image/jpeg"])
            let reads = MockHTTPTransport(responses: accessResponses() + [response(manualList([(72, 32, "Target")])), image] + (matches ? [response(itemPage)] : []))
            let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
            let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, matches ? .confirmed : .pendingReview)
            let requests = await reads.recordedRequests(); XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        }
    }

    func test手工人脸恢复新增回执保存失败不移除旧框且保留部分结果() async throws {
        let profile = UUID(), photo = facePhoto(profile), id = UUID(), capture = PhotosAlbumCheckpointCapture()
        let final = [response(manualList([(71, 31, "Person"), (72, 32, "Target")])), DsmHTTPResponse(data: Data([0xff, 0xd8, 0xff, 0x11]), statusCode: 200, headers: ["Content-Type": "image/jpeg"]), response(itemPage)]
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person")])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#)] + final)
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.editPhotoFaces(photo: photo, changes: [.remove(manualRegion(71)), .add(addedFace())])
        let result = try await repository.performRecoverableAlbumMutation(command, operationID: id) { saved in
            if saved.recognitionDetails?.manualThumbnailAttempted.isEmpty == false { throw CocoaError(.fileWriteNoPermission) }
            capture.append(saved)
        }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 0)
        let saved = try XCTUnwrap(capture.values.last)
        let reads = MockHTTPTransport(responses: accessResponses() + final)
        let restored = try makeRepository(reads, profileID: profile); _ = try await restored.access(); try await restored.restoreAlbumMutation(saved)
        let reviewed = try await restored.reviewMutation(operationID: id); XCTAssertEqual(reviewed.state, .partial)
        let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        let calls = try requests.filter { $0.httpMethod != "GET" }.map(decode); XCTAssertFalse(calls.contains { $0["method"] == "delete_face" })
    }

    func test人物恢复拒绝跨账号与人脸损坏阶段并保留主题批量范围() async throws {
        let profile = UUID(), id = UUID(), command = SynologyPhotosMutation.editPhotoFaces(photo: facePhoto(profile), changes: [.remove(manualRegion(71)), .add(addedFace())])
        XCTAssertThrowsError(try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: UUID(), userID: 12))
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 12)
        var details = try XCTUnwrap(saved.recognitionDetails); details.manualAttempted = ["face-71"]; saved.recognitionDetails = details
        XCTAssertThrowsError(try saved.reviewMutation())
        details.manualAttempted = []; details.manualUploaded = [72]; saved.recognitionDetails = details; XCTAssertThrowsError(try saved.reviewMutation())
        let clean = try SynologyPhotosAlbumCheckpoint(mutation: command, operationID: id, profileID: profile, userID: 99)
        let transport = MockHTTPTransport(responses: accessResponses()), repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access()
        do { try await repository.restoreAlbumMutation(clean); XCTFail("其他账号记录不可恢复") } catch {}
        let many = SynologyPhotosMutation.setConceptVisibility((1...101).map { .init(concept: .init(id: $0, name: "Concept"), isVisible: true) }, visible: false)
        XCTAssertNoThrow(try SynologyPhotosAlbumCheckpoint(mutation: many, operationID: UUID(), profileID: profile, userID: 12).reviewMutation())
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

    private var manualBounds: SynologyPhotoFaceBounds { .init(x: 0.1, y: 0.2, width: 0.3 - 0.1, height: 0.5 - 0.2) }
    private var faceJPEG: Data { Data([0xff, 0xd8, 0xff, 0xd9]) }
    private func manualRegion(_ id: Int, person: Int = 31, name: String = "Person") -> SynologyPhotoFaceRegion {
        .init(id: id, personID: person, name: name, bounds: manualBounds, thumbnail: .init(unitID: id, revision: "fixture"))
    }
    private func manualList(_ entries: [(Int, Int, String)]) -> String {
        let list = entries.map { "{\"face_id\":\($0.0),\"person_id\":\($0.1),\"name\":\"\($0.2)\",\"face_bounding_box\":{\"top_left\":{\"x\":0.1,\"y\":0.2},\"bottom_right\":{\"x\":0.3,\"y\":0.5}},\"additional\":{\"thumbnail\":{\"cache_key\":\"fixture\"}}}" }.joined(separator: ",")
        return "{\"success\":true,\"data\":{\"list\":[\(list)]}}"
    }
    private func addedFace(_ temporary: String = "7-0") -> SynologyPhotoNewFace {
        .init(temporaryID: temporary, bounds: manualBounds, person: nil, name: "Target", jpeg: faceJPEG)
    }

    func test图片人脸读取坐标和身份并拒绝其他照片空间() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person")]))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let faces = try await repository.photoFaces(for: photo)
        XCTAssertEqual(faces, [manualRegion(71)])
        let requests = await transport.recordedRequests()
        let request = try decode(try XCTUnwrap(requests.last))
        XCTAssertEqual(request["method"], "list_face"); XCTAssertEqual(request["version"], "6"); XCTAssertEqual(request["id_item"], "7")
        do { _ = try await repository.photoFaces(for: facePhoto(UUID())); XCTFail("不可读其他NAS人脸") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test手工新脸按明确编号上传JPEG并回读且不重复写() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([])), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(manualList([(72, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.editPhotoFaces(photo: photo, changes: [.add(addedFace())]), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 1); XCTAssertEqual(result.photos.first?.id, photo.id)
        }
        let requests = await transport.recordedRequests()
        let upload = try XCTUnwrap(requests.first { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        let body = try XCTUnwrap(upload.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("SYNO.Foto.Upload.Face")); XCTAssertTrue(text.contains("name=\"face_id\"\r\n\r\n72"))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg")); XCTAssertNotNil(body.range(of: faceJPEG)); XCTAssertFalse(text.contains("tempFaceId"))
        let parameters = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(decode)
        let adds = parameters.filter { $0["method"] == "add_face" }
        XCTAssertEqual(adds.count, 1); XCTAssertEqual(adds.first?["version"], "3")
        let face = try XCTUnwrap(adds.first?["face"])
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(face.utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.first?["face_id_temp"] as? String, "7-0"); XCTAssertEqual(objects.first?["name"] as? String, "Target")
        XCTAssertNil(objects.first?["person_id"])
        XCTAssertFalse(parameters.contains { $0["method"] == "delete" })
    }

    func test图片内纠正与移除仅操作原人脸不删除照片() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let people = visibilityList([(32, true)]).replacingOccurrences(of: "Person", with: "Target")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person"), (72, 31, "Person")])), response(people), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#), response(emptySuccess), response(manualList([(71, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.editPhotoFaces(photo: photo, changes: [.reassign(manualRegion(71), person: .init(id: 32, name: "Target"), name: "Target"), .remove(manualRegion(72))]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
        let parameters = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(parameters.first { $0["method"] == "separate" }?["target_id"], "32")
        XCTAssertEqual(parameters.first { $0["method"] == "delete_face" }?["face_id"], "[72]")
        XCTAssertFalse(parameters.contains { $0["method"] == "delete" })
    }

    func test调整既有框先完整创建新框再移除旧标记() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person")])), response(itemPage), response(managedFolder),
            response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(emptySuccess), response(manualList([(72, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.editPhotoFaces(photo: photo, changes: [.remove(manualRegion(71)), .add(addedFace())]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let requests = await transport.recordedRequests()
        let uploadIndex = try XCTUnwrap(requests.firstIndex { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        let deleteIndex = try XCTUnwrap(requests.firstIndex { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true && (try? decode($0)["method"]) == "delete_face" })
        XCTAssertLessThan(uploadIndex, deleteIndex)
    }

    func test新脸缺回执不猜编号且错误映射不上传() async throws {
        for receipt in [#"{"success":true,"data":{}}"#, #"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"wrong"}]}}"#,
                        #"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"},{"face_id":72,"face_id_temp":"7-0"}]}}"#] {
            let profile = UUID()
            let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([])), response(itemPage), response(managedFolder), response(receipt), response(manualList([(72, 32, "Target")]))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.add(addedFace())]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            let requests = await transport.recordedRequests()
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        }
    }

    func test新增人脸部分回执只上传返回项并报告部分完成() async throws {
        let profile = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(manualList([(72, 32, "Target")])), response(itemPage)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.add(addedFace()), .add(addedFace("7-1"))]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }.count, 1)
    }

    func test人脸上传丢回执只接受新编号精确图片且不重传() async throws {
        for space in SynologyPhotoSpace.allCases {
        for matches in [true, false] {
            let profile = UUID()
            let transport = MockHTTPTransport(steps: ((space == .shared ? sharedPeopleAccess : accessResponses()) + [response(manualList([])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(manualList([(72, 32, "Target")]))),
                .response(.init(data: matches ? faceJPEG : Data([0xff, 0xd8, 0xff, 0x11]), statusCode: 200, headers: ["Content-Type": "image/jpeg"]))] + (matches ? [.response(response(itemPage))] : []))
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.editPhotoFaces(photo: facePhoto(profile, in: space), changes: [.add(addedFace())]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, matches ? .confirmed : .pendingReview)
            let requests = await transport.recordedRequests()
            let thumbnailRequest = try XCTUnwrap(requests.first { $0.httpMethod == "GET" })
            XCTAssertTrue(thumbnailRequest.url?.path.contains(space == .shared ? "/t/Thumbnail/get" : "/p/Thumbnail/get") == true)
            XCTAssertEqual(requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true }.count, 1)
        }
        }
    }

    func test新脸回执不能指向旧脸且缺少新框时保留旧标记() async throws {
        for receipt in [#"{"success":true,"data":{"list":[{"face_id":71,"face_id_temp":"7-0"}]}}"#, #"{"success":true,"data":{"list":[]}}"#] {
            let profile = UUID()
            let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 31, "Person")])), response(itemPage), response(managedFolder), response(receipt), response(manualList([(71, 31, "Person")])), response(itemPage)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.remove(manualRegion(71)), .add(addedFace())]), operationID: UUID()) { _, _ in }
            XCTAssertNotEqual(result.state, .confirmed)
            let requests = await transport.recordedRequests()
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
            let params = try requests.map(decode)
            XCTAssertFalse(params.contains { $0["method"] == "delete_face" })
        }
    }

    func test人脸无目录管理权限及无效坐标不写入() async throws {
        let profile = UUID()
        let denied = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false"#)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([])), response(itemPage), response(denied)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do { try await repository.prepareMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.add(addedFace())])); XCTFail("无权限不可添加人脸") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "add_face" })
        let invalid = SynologyPhotoNewFace(temporaryID: "7-0", bounds: .init(x: -0.1, y: 0, width: 0.2, height: 0.2), person: nil, name: "Target", jpeg: faceJPEG)
        let otherTransport = MockHTTPTransport(responses: accessResponses() + [response(manualList([]))])
        let other = try makeRepository(otherTransport, profileID: profile); _ = try await other.access()
        do { try await other.prepareMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.add(invalid)])); XCTFail("非法框不可保存") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test人脸最终归属和坐标不符保持待核对() async throws {
        for wrong in [manualList([(72, 32, "Wrong")]), manualList([(72, 32, "Target")]).replacingOccurrences(of: "0.3", with: "0.4")] {
            let profile = UUID()
            let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"list":[{"face_id":72,"face_id_temp":"7-0"}]}}"#), response(emptySuccess), response(wrong)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.add(addedFace())]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
    }

    func test人脸旧接口缺上传和失效快照不能提前写入() async throws {
        for missing in [Set(["SYNO.Foto.Upload.Face"]), Set<String>()] {
            let repository = try makeRepository(MockHTTPTransport(responses: accessResponses()), omittedAPIs: missing, personVersion: missing.isEmpty ? 2 : 3)
            _ = try await repository.access()
            let features = await repository.managementFeatures()
            XCTAssertFalse(features.contains(.manualFaces)); XCTAssertTrue(features.contains(.peopleFaces))
        }
        let profile = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(manualList([(71, 99, "Changed")]))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do { try await repository.prepareMutation(.editPhotoFaces(photo: facePhoto(profile), changes: [.remove(manualRegion(71))])); XCTFail("旧快照不能删除新归属") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(requests.contains { $0["method"] == "delete_face" })
    }

    private func conceptDetail(count: Int, cover: Int = 9, threshold: Int = 2) -> String {
        #"{"success":true,"data":{"list":[{"id":31,"name":"Topic","item_count":\#(count),"visibility":true,"display_threshold":\#(threshold),"additional":{"thumbnail":{"unit_id":\#(cover),"cache_key":"fixture"}}}]}}"#
    }

    private func conceptSnapshot(count: Int, in space: SynologyPhotoSpace = .personal) -> SynologyPhotoConceptVisibility {
        .init(concept: .init(id: 31, name: "Topic", itemCount: count, thumbnail: .init(unitID: 9, revision: "fixture"), space: space), isVisible: true, displayThreshold: 2)
    }

    private func conceptPhoto(_ profile: UUID, id: Int, in space: SynologyPhotoSpace) -> SynologyPhoto {
        .init(id: .init(profileID: profile, space: space, unitID: id), filename: "sample.jpg", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
    }

    private func conceptMembers(_ ids: [Int]) -> String {
        let source = try! JSONSerialization.jsonObject(with: Data(itemPage.utf8)) as! [String: Any]
        let data = source["data"] as! [String: Any], rows = data["list"] as! [[String: Any]]
        let list = ids.map { id -> [String: Any] in var row = rows[0]; row["id"] = id; return row }
        return String(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": list]]), encoding: .utf8)!
    }

    private func conceptPreflight(_ ids: [Int], members: [Int]? = nil) -> [DsmHTTPResponse] {
        [response(conceptDetail(count: ids.count)), response(personTimeline), response(conceptMembers(members ?? ids))] + ids.flatMap { [response(conceptMembers([$0])), response(managedFolder)] }
    }

    func test主题封面双空间固定照片回读且同操作不重复提交() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for lostReceipt in [false, true] {
                let profile = UUID(), original = conceptSnapshot(count: 1, in: space), photo = conceptPhoto(profile, id: 7, in: space)
                let initial = accessResponses(teamPermission: "management", conceptsEnabled: true) + conceptPreflight([7])
                let transport = MockHTTPTransport(steps: initial.map(MockHTTPTransport.Step.response) + [lostReceipt ? .urlError(.networkConnectionLost) : .response(response(emptySuccess)), .response(response(conceptDetail(count: 1, cover: 7)))])
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let command = SynologyPhotosMutation.setConceptCover(concept: original, photo: photo), id = UUID()
                let first = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(first.state, lostReceipt ? .pendingReview : .confirmed)
                let result = try await repository.reviewMutation(operationID: id)
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.conceptVisibility.first?.concept.thumbnail?.unitID, 7)
                _ = try await repository.performMutation(command, operationID: id) { _, _ in }
                let requests = try await transport.recordedRequests().map(decode)
                let writes = requests.filter { $0["method"] == "set_cover" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["photo_id"], "7"); XCTAssertEqual(writes.first?["id"], "31")
                XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.Browse.Concept" : "SYNO.FotoTeam.Browse.Concept")
                XCTAssertEqual(writes.first?["version"], "1")
            }
        }
    }

    func test主题移出双空间全部及部分成员保留原件并低于阈值隐藏() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for partial in [true, false] {
                let profile = UUID(), ids = [7, 8], remaining = partial ? [8] : []
                let photos = ids.map { conceptPhoto(profile, id: $0, in: space) }
                let timeline = remaining.isEmpty ? #"{"success":true,"data":{"section":[]}}"# : personTimeline
                let final = [response(conceptDetail(count: remaining.count, cover: 8)), response(timeline)] + (remaining.isEmpty ? [] : [response(conceptMembers(remaining))]) + (partial ? [7] : ids).map { response(conceptMembers([$0])) }
                let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", conceptsEnabled: true) + conceptPreflight(ids) + [response(emptySuccess)] + final)
                let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
                let command = SynologyPhotosMutation.removeConceptItems(concept: conceptSnapshot(count: 2, in: space), photos: photos), id = UUID()
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, partial ? .partial : .confirmed)
                XCTAssertEqual(result.removedFromConceptPhotoIDs.map(\.unitID), partial ? [7] : ids)
                XCTAssertEqual(result.conceptVisibility.first?.appearsInList, false); XCTAssertTrue(result.deletedPhotoIDs.isEmpty)
                _ = try await repository.performMutation(command, operationID: id) { _, _ in }
                let requests = try await transport.recordedRequests().map(decode)
                let writes = requests.filter { $0["method"] == "hide_item" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["id"], "31"); XCTAssertEqual(writes.first?["item_id"], "[7,8]")
                XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.Browse.Concept" : "SYNO.FotoTeam.Browse.Concept")
                XCTAssertFalse(requests.contains { $0["method"] == "delete" })
            }
        }
    }

    func test主题移出回读缺目标数量不一致或原件丢失不能伪报成功() async throws {
        for scenario in ["missing", "count", "original"] {
            let profile = UUID(), photo = conceptPhoto(profile, id: 7, in: .personal)
            let get = scenario == "missing" ? emptyFolderOrItemList : conceptDetail(count: scenario == "count" ? 1 : 0)
            let final = [response(get), response(#"{"success":true,"data":{"section":[]}}"#), response(emptyFolderOrItemList)]
            let transport = MockHTTPTransport(responses: accessResponses() + conceptPreflight([7]) + [response(emptySuccess)] + final)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.removeConceptItems(concept: conceptSnapshot(count: 1), photos: [photo]), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.removedFromConceptPhotoIDs.isEmpty)
        }
    }

    func test主题移出必须读完所有分页不能把后页成员误判为消失() async throws {
        let profile = UUID(), firstPage = Array(100...599), photo = conceptPhoto(profile, id: 7, in: .personal)
        let original = conceptSnapshot(count: 501)
        let before = [conceptDetail(count: 501), personTimeline, conceptMembers(firstPage), conceptMembers([7]), conceptMembers([7]), managedFolder]
        let after = [conceptDetail(count: 501), personTimeline, conceptMembers(firstPage), conceptMembers([7])]
        let transport = MockHTTPTransport(responses: accessResponses() + (before + [emptySuccess] + after).map(response))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.removeConceptItems(concept: original, photos: [photo]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.removedFromConceptPhotoIDs.isEmpty)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "list" && $0["api"] == "SYNO.Foto.Browse.Item" }.map { $0["offset"] }, ["0", "500", "0", "500"])
    }

    func test主题封面旧编号不能算成功且后续只回读() async throws {
        let profile = UUID(), command = SynologyPhotosMutation.setConceptCover(concept: conceptSnapshot(count: 1), photo: conceptPhoto(profile, id: 7, in: .personal)), id = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + conceptPreflight([7]) + [emptySuccess, conceptDetail(count: 1), conceptDetail(count: 1, cover: 7)].map(response))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(pending.state, .pendingReview)
        let checked = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(checked.state, .confirmed)
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "set_cover" }.count, 1)
    }

    func test主题封面旧快照及照片不在分类时拒绝写入() async throws {
        for stale in [true, false] {
            let profile = UUID(), photo = conceptPhoto(profile, id: 7, in: .personal)
            let initial = [response(conceptDetail(count: stale ? 2 : 1)), response(personTimeline), response(conceptMembers([8]))]
            let transport = MockHTTPTransport(responses: accessResponses() + initial)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(.setConceptCover(concept: conceptSnapshot(count: 1), photo: photo)); XCTFail("旧快照或非成员不能设置封面") } catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["hide_item", "set_cover"].contains($0["method"]) })
        }
    }

    private func conceptList(_ entries: [(Int, Bool)]) -> String {
        visibilityList(entries).replacingOccurrences(of: "\"show\":", with: "\"visibility\":")
            .replacingOccurrences(of: "\"cache_key\":", with: "\"unit_id\":7,\"cache_key\":")
    }

    func test主题显示完整分页包含隐藏项且双空间路由正确() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let pages = [conceptList((1...500).map { ($0, true) }), conceptList([(501, false)])]
            let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", conceptsEnabled: true) + pages.map(response) + [DsmHTTPResponse(data: bytes, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let features = await repository.managementFeatures(in: space)
            XCTAssertTrue(features.contains(.conceptVisibility))
            let result = try await repository.conceptVisibility(in: space)
            XCTAssertEqual(result.count, 501); XCTAssertEqual(result.last?.isVisible, false)
            XCTAssertTrue(result.allSatisfy { $0.concept.space == space })
            let requests = try await transport.recordedRequests().map(decode).filter { $0["method"] == "list" }
            XCTAssertEqual(requests.map { $0["offset"] }, ["0", "500"])
            XCTAssertTrue(requests.allSatisfy { $0["api"] == (space == .personal ? "SYNO.Foto.Browse.Concept" : "SYNO.FotoTeam.Browse.Concept") && $0["version"] == "2" && $0["show_hidden"] == "true" })
            let image = try await repository.thumbnail(for: XCTUnwrap(result.last?.concept), category: .concept)
            XCTAssertEqual(image, bytes)
            let imageRequest = await transport.recordedRequests().last
            XCTAssertEqual(imageRequest?.url?.path, "/synofoto/api/v2/\(space == .personal ? "p" : "t")/Thumbnail/get")
        }
    }

    func test主题显示隐藏部分回读去重不删除原件() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for visible in [true, false] {
                for partial in [true, false] {
                    let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", conceptsEnabled: true) + [response(conceptList([(31, !visible), (32, !visible)])), response(emptySuccess), response(conceptList([(31, visible), (32, partial ? !visible : visible)]))])
                    let repository = try makeRepository(transport); _ = try await repository.access()
                    let command = SynologyPhotosMutation.setConceptVisibility([31, 32].map { .init(concept: .init(id: $0, name: "Person", space: space), isVisible: !visible) }, visible: visible)
                    let id = UUID()
                    for _ in 0..<2 {
                        let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                        XCTAssertEqual(result.state, partial ? .partial : .confirmed)
                        XCTAssertEqual(result.conceptVisibility.map(\.id), partial ? [31] : [31, 32])
                        XCTAssertTrue(result.photos.isEmpty); XCTAssertTrue(result.deletedPhotoIDs.isEmpty)
                    }
                    let requests = try await transport.recordedRequests().map(decode)
                    let writes = requests.filter { $0["method"] == "set_visibility" }
                    XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["visibility"], visible ? "true" : "false")
                    XCTAssertEqual(writes.first?["id"], "[31,32]"); XCTAssertEqual(writes.first?["version"], "2")
                    XCTAssertEqual(writes.first?["api"], space == .personal ? "SYNO.Foto.Browse.Concept" : "SYNO.FotoTeam.Browse.Concept")
                    XCTAssertFalse(requests.contains { ["delete", "hide_item", "set_cover"].contains($0["method"]) })
                }
            }
        }
    }

    func test主题缺字段缺目标或旧状态不猜成功且未知只回读() async throws {
        for after in [conceptList([]), conceptList([(31, true)]), conceptList([(31, false)]).replacingOccurrences(of: "\"visibility\":false,", with: "")] {
            let before = conceptList([(31, true)])
            let transport = MockHTTPTransport(steps: (accessResponses() + [response(before)]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(after)), .response(response(conceptList([(31, false)])))])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let id = UUID(), command = SynologyPhotosMutation.setConceptVisibility([.init(concept: .init(id: 31, name: "Person"), isVisible: true)], visible: false)
            let pending = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(pending.state, .pendingReview)
            let uncertain = try? await repository.reviewMutation(operationID: id)
            XCTAssertTrue(uncertain == nil || uncertain?.state == .pendingReview)
            let recovered = try await repository.reviewMutation(operationID: id)
            XCTAssertEqual(recovered.state, .confirmed)
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(requests.filter { $0["method"] == "set_visibility" }.count, 1)
        }
    }

    func test主题批量操作不设置人为一百项上限() async throws {
        let ids = Array(1...101)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(conceptList(ids.map { ($0, true) })), response(emptySuccess), response(conceptList(ids.map { ($0, false) }))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.performMutation(.setConceptVisibility(ids.map { .init(concept: .init(id: $0, name: "Person"), isVisible: true) }, visible: false), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 101)
    }

    func test主题权限重复选择混空间及过期快照拒绝写入() async throws {
        for permission in ["none", "entry"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: permission, conceptsEnabled: true))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let features = await repository.managementFeatures(in: .shared)
            XCTAssertFalse(features.contains(.conceptVisibility))
            do { _ = try await repository.conceptVisibility(in: .shared); XCTFail("共享管理权不足") } catch { }
        }
        let a = SynologyPhotoConceptVisibility(concept: .init(id: 31, name: "Person"), isVisible: true)
        let b = SynologyPhotoConceptVisibility(concept: .init(id: 32, name: "Person", space: .shared), isVisible: true)
        for targets in [[], [a, a], [a, b], [a]] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(conceptList([(31, false)]))])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { try await repository.prepareMutation(.setConceptVisibility(targets, visible: false)); XCTFail("无效或旧选择不提交") } catch { }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "set_visibility" })
        }
        let transport = MockHTTPTransport(responses: accessResponses())
        let missing = try makeRepository(transport, omittedAPIs: ["SYNO.Foto.Browse.Concept"]); _ = try await missing.access()
        let features = await missing.managementFeatures()
        XCTAssertFalse(features.contains(.conceptVisibility))
    }

    private func visibilityList(_ entries: [(Int, Bool)]) -> String {
        let list = entries.map { "{\"id\":\($0.0),\"name\":\"Person\",\"show\":\($0.1),\"additional\":{\"thumbnail\":{\"cache_key\":\"fixture\"}}}" }.joined(separator: ",")
        return "{\"success\":true,\"data\":{\"list\":[\(list)]}}"
    }

    func test人物显示列表包含隐藏项并支持人物编号缩略图() async throws {
        for usesUnit in [false, true] {
            let list = visibilityList([(31, true), (32, false)]).replacingOccurrences(of: "\"cache_key\":\"fixture\"", with: usesUnit ? "\"unit_id\":7,\"cache_key\":\"fixture\"" : "\"cache_key\":\"fixture\"")
            let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
            let transport = MockHTTPTransport(responses: accessResponses() + [response(list), DsmHTTPResponse(data: bytes, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let people = try await repository.peopleVisibility()
            XCTAssertEqual(people.map(\.isVisible), [true, false])
            let data = try await repository.thumbnail(for: people[0].person, category: .person)
            XCTAssertEqual(data, bytes)
            let requests = await transport.recordedRequests()
            let params = try decode(try XCTUnwrap(requests.dropLast().last))
            XCTAssertEqual(params["show_hidden"], "true"); XCTAssertEqual(params["show_more"], "true")
            let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "type" }?.value, usesUnit ? #""unit""# : #""person""#)
            XCTAssertEqual(query.first { $0.name == "id" }?.value, usesUnit ? "7" : "31")
            XCTAssertNil(query.first { $0.name == "size" })
        }
    }

    func test人物显示隐藏批量回读与部分成功不重放() async throws {
        for visible in [false, true] {
            for partial in [false, true] {
                let before = visibilityList([(31, !visible), (32, !visible)])
                let after = visibilityList([(31, visible), (32, partial ? !visible : visible)])
                let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(emptySuccess), response(after)])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let command = SynologyPhotosMutation.setPeopleVisibility([31, 32].map { .init(person: .init(id: $0, name: "Person"), isVisible: !visible) }, visible: visible)
                let id = UUID()
                for _ in 0..<2 {
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                    XCTAssertEqual(result.state, partial ? .partial : .confirmed)
                    XCTAssertEqual(result.personVisibility.map(\.id), partial ? [31] : [31, 32])
                    XCTAssertTrue(result.photos.isEmpty)
                }
                let requests = try await transport.recordedRequests().map(decode)
                let writes = requests.filter { $0["method"] == "show" }
                XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["id"], "[31,32]")
                XCTAssertEqual(writes.first?["show"], visible ? "true" : "false")
                XCTAssertFalse(requests.contains { $0["method"] == "delete" })
            }
        }
    }

    func test人物隐藏缺失或未改变不能当作完成() async throws {
        for after in [visibilityList([]), visibilityList([(31, true)]), personList([(31, "Person", 1)])] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(visibilityList([(31, true)])), response(emptySuccess), response(after)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let result = try await repository.performMutation(.setPeopleVisibility([.init(person: .init(id: 31, name: "Person"), isVisible: true)], visible: false), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.personVisibility.isEmpty)
        }
    }

    func test人物显示缺权限重复编号和无变化不提交() async throws {
        let person = SynologyPhotoPersonVisibility(person: .init(id: 31, name: "Person"), isVisible: true)
        for originals in [[], [person, person], [person]] {
            let transport = MockHTTPTransport(responses: accessResponses())
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                try await repository.prepareMutation(.setPeopleVisibility(originals, visible: originals.count == 1))
                XCTFail("无效选择不能写入")
            } catch { XCTAssertTrue(error is AppError) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["api"] == "SYNO.Foto.Browse.Person" })
        }
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false))
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { _ = try await repository.peopleVisibility(); XCTFail("无个人空间权限不能读人物") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { try await repository.prepareMutation(.setPeopleVisibility([person], visible: false)); XCTFail("无权限不能写入") }
        catch { XCTAssertTrue(error is AppError) }
    }

    func test人物显示断网后仅回读且丢失回执也能确认() async throws {
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(visibilityList([(31, false)]))]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(visibilityList([(31, true)])))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setPeopleVisibility([.init(person: .init(id: 31, name: "Person"), isVisible: false)], visible: true)
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }
        XCTAssertEqual(first.state, .pendingReview)
        let checked = try await repository.reviewMutation(operationID: id)
        XCTAssertEqual(checked.state, .confirmed)
        _ = try await repository.performMutation(command, operationID: id) { _, _ in }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "show" }.count, 1)
    }

    func test人物显示快照变更或缺少显示字段不能写入() async throws {
        for before in [visibilityList([(31, false)]), personList([(31, "Person", 1)]), visibilityList([(32, true)])] {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                try await repository.prepareMutation(.setPeopleVisibility([.init(person: .init(id: 31, name: "Person"), isVisible: true)], visible: false))
                XCTFail("不能使用已变化的人物快照")
            } catch { XCTAssertTrue(error is AppError) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { $0["method"] == "show" })
        }
    }

    func test人脸列表使用独立编号和缩略图类型且重新授权后失效() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let transport = MockHTTPTransport(responses: accessResponses() + [response(faceList([71, 72])), DsmHTTPResponse(data: bytes, statusCode: 200, headers: ["Content-Type": "image/jpeg"])] + accessResponses())
        let repository = try makeRepository(transport, profileID: profile)
        _ = try await repository.access()
        let faces = try await repository.personFaces(personID: 31, photos: [photo])
        XCTAssertEqual(faces.map(\.id), [71, 72]); XCTAssertTrue(faces.allSatisfy { $0.photo.id.unitID == 7 })
        let face = try XCTUnwrap(faces.first)
        let image = try await repository.thumbnail(for: face); XCTAssertEqual(image, bytes)
        let requests = await transport.recordedRequests()
        let params = try decode(try XCTUnwrap(requests.dropLast().last))
        XCTAssertEqual(params["item_id"], "[7]"); XCTAssertEqual(params["person_id"], "31")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "type" }?.value, #""face""#)
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "71")
        XCTAssertNil(query.first { $0.name == "size" })
        _ = try await repository.access()
        do { _ = try await repository.thumbnail(for: face); XCTFail("不能使用旧会话人脸缓存") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
    }

    func test人脸移出只提交选中脸且保留同照片其他脸不重放() async throws {
        for remainingFace in [true, false] {
            let profile = UUID(), photo = facePhoto(profile), person = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71, 72])), response(itemPage), response(managedFolder), response(emptySuccess), response(faceList(remainingFace ? [72] : [])), response(personList([(31, "Person", remainingFace ? 1 : 0)]))])
            let repository = try makeRepository(transport, profileID: profile)
            _ = try await repository.access()
            let command = SynologyPhotosMutation.removePersonFaces(person: person, faces: [.init(id: 71, personID: 31, photo: photo)])
            let id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed)
                XCTAssertEqual(result.removedFromPersonPhotoIDs, remainingFace ? [] : [photo.id])
            }
            let requests = try await transport.recordedRequests().map(decode)
            let writes = requests.filter { $0["method"] == "delete_face" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["face_id"], "[71]")
            XCTAssertFalse(requests.contains { $0["method"] == "delete" })
        }
    }

    func test人脸仍在来源时不能报告移出完成() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder), response(emptySuccess), response(faceList([71]))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let result = try await repository.performMutation(.removePersonFaces(person: .init(id: 31, name: "Person", itemCount: 1), faces: [.init(id: 71, personID: 31, photo: photo)]), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .pendingReview); XCTAssertTrue(result.removedFromPersonPhotoIDs.isEmpty)
    }

    func test人脸分离到新人物或既有人物须核对两边成员() async throws {
        for isNew in [false, true] {
            let profile = UUID(), photo = facePhoto(profile)
            let source = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1)
            let target = SynologyPhotoCollection(id: 32, name: "Target", itemCount: 2)
            let before = personList([(31, "Person", 1), (32, "Target", 2)])
            let responses = [response(before)] + (isNew ? [] : [response(before)]) + [response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#), response(faceList([])), response(faceList([71])), response(personList([(32, "Target", 3)])), response(personList([(31, "Person", 0), (32, "Target", 3)]))]
            let transport = MockHTTPTransport(responses: accessResponses() + responses)
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let command = SynologyPhotosMutation.reassignPersonFaces(person: source, faces: [.init(id: 71, personID: 31, photo: photo)], target: isNew ? nil : target, name: "Target")
            let id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.removedFromPersonPhotoIDs, [photo.id])
            }
            let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "separate" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["target_id"], isNew ? "0" : "32")
            XCTAssertEqual(writes.first?["face_id"], "[71]")
        }
    }

    func test新人物分离丢失回执不能按名称追认或重发() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let initial = accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder)]
        let transport = MockHTTPTransport(steps: initial.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(faceList([])))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let command = SynologyPhotosMutation.reassignPersonFaces(person: .init(id: 31, name: "Person", itemCount: 1), faces: [.init(id: 71, personID: 31, photo: photo)], target: nil, name: "Target")
        let id = UUID()
        let first = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(first.state, .pendingReview)
        let again = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(again.state, .pendingReview)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "separate" }; XCTAssertEqual(writes.count, 1)
    }

    func test人脸写入拒绝错误归属重复编号与无权目录() async throws {
        for scenario in ["owner", "duplicate", "missing", "permission", "photo"] {
            let profile = UUID(), photo = facePhoto(profile), person = SynologyPhotoCollection(id: 31, name: "Person", itemCount: 1)
            let face = SynologyPhotoFace(id: 71, personID: scenario == "owner" ? 99 : 31, photo: photo)
            let identity = scenario == "photo" ? itemPage.replacingOccurrences(of: "sample.jpg", with: "different.jpg") : itemPage
            let folder = managedFolder.replacingOccurrences(of: #""manage":true"#, with: #""manage":false"#)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList(scenario == "missing" ? [] : [71])), response(identity), response(folder)])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            do { try await repository.prepareMutation(.removePersonFaces(person: person, faces: scenario == "duplicate" ? [face, face] : [face])); XCTFail("不能提交失效目标") }
            catch let error as AppError { XCTAssertEqual(error.category, scenario == "permission" ? .permissionDenied : ["owner", "duplicate"].contains(scenario) ? .invalidResponse : .conflict) }
            let requests = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(requests.contains { ["delete_face", "separate"].contains($0["method"] ?? "") })
        }
    }

    func test人物封面必须回读与回执一致且不混用照片编号() async throws {
        for matches in [true, false] {
            let profile = UUID(), photo = facePhoto(profile)
            let transport = MockHTTPTransport(responses: accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":31,"name":"Person","cover":71}}"#), response("{\"success\":true,\"data\":{\"list\":[{\"id\":31,\"name\":\"Person\",\"cover\":\(matches ? 71 : 72)}]}}"), response(personList([(31, "Person", 1)]))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.setPersonCover(person: .init(id: 31, name: "Person", itemCount: 1), photo: photo), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, matches ? .confirmed : .pendingReview)
            let request = try await transport.recordedRequests().map(decode).first { $0["method"] == "set_cover" }
            XCTAssertEqual(request?["id"], "31"); XCTAssertEqual(request?["photo_id"], "7")
        }
    }

    func test人脸分离目标未收到相同人脸或名称冲突保持未知() async throws {
        for wrongName in [false, true] {
            let profile = UUID(), photo = facePhoto(profile)
            let before = personList([(31, "Person", 1), (32, "Target", 1)])
            let transport = MockHTTPTransport(responses: accessResponses() + [response(before), response(before), response(faceList([71])), response(itemPage), response(managedFolder), response(#"{"success":true,"data":{"id":32,"name":"Target"}}"#), response(faceList([])), response(faceList(wrongName ? [71] : [72])), response(personList([(32, "Changed", 1)]))])
            let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
            let result = try await repository.performMutation(.reassignPersonFaces(person: .init(id: 31, name: "Person", itemCount: 1), faces: [.init(id: 71, personID: 31, photo: photo)], target: .init(id: 32, name: "Target", itemCount: 1), name: "Target"), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
            XCTAssertTrue(result.removedFromPersonPhotoIDs.isEmpty)
        }
    }

    func test人物封面丢失回执不能靠旧封面确认或重发() async throws {
        let profile = UUID(), photo = facePhoto(profile)
        let initial = accessResponses() + [response(personList([(31, "Person", 1)])), response(faceList([71])), response(itemPage), response(managedFolder)]
        let transport = MockHTTPTransport(steps: initial.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        let id = UUID(), command = SynologyPhotosMutation.setPersonCover(person: .init(id: 31, name: "Person", itemCount: 1), photo: photo)
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .pendingReview)
        }
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set_cover" }; XCTAssertEqual(writes.count, 1)
    }

    func test人脸读取拒绝跨NAS身份和重复响应编号() async throws {
        let profile = UUID()
        let transport = MockHTTPTransport(responses: accessResponses() + [response(faceList([71, 71]))])
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do { _ = try await repository.personFaces(personID: 31, photos: [facePhoto(UUID())]); XCTFail("不能读取其他NAS的照片") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { _ = try await repository.personFaces(personID: 31, photos: [facePhoto(profile)]); XCTFail("不能接受重复人脸编号") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let reads = try await transport.recordedRequests().map(decode).filter { $0["method"] == "list_face" }; XCTAssertEqual(reads.count, 1)
    }

    private func faceList(_ ids: [Int]) -> String {
        let rows = ids.map { ["id": $0, "additional": ["thumbnail": ["cache_key": "fixture-face"]]] as [String: Any] }
        return String(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": rows]]), encoding: .utf8)!
    }
    private func facePhoto(_ profileID: UUID, in space: SynologyPhotoSpace = .personal) -> SynologyPhoto {
        .init(id: .init(profileID: profileID, space: space, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
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
            XCTAssertEqual(result.folder, .init(id: 10, name: "Trip", parentID: 9, path: "/Sample/Trip"))
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

    func test共享照片可创建加入移出普通相册且所有写入保持统一入口() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12}]}}"#
        let created = #"{"success":true,"data":{"album":{"id":3,"name":"Fixture","owner_user_id":12}}}"#
        let sharedPage = itemPage.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":0"#)
        for mode in ["create", "add_item", "delete_item", "set_cover"] {
            var responses = accessResponses(teamPermission: "management", homeEnabled: false) + [response(itemPage), response(itemPage), response(managedFolder)]
            if mode != "create" { responses.append(response(album)) }
            if mode == "set_cover" { responses.append(response(sharedPage)) }
            responses.append(response(mode == "create" ? created : emptySuccess))
            if mode == "create" { responses.append(response(album)) }
            responses.append(response(mode == "set_cover" ? album.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":12,"additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture"}}"#) : mode == "delete_item" ? #"{"success":true,"data":{"list":[]}}"# : sharedPage))
            let transport = MockHTTPTransport(responses: responses)
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
            let photo = try XCTUnwrap(page.items.first)
            let command: SynologyPhotosMutation = switch mode {
            case "create": .createAlbum(name: "Fixture", photos: [photo])
            case "add_item": .addToAlbum(id: 3, photos: [photo])
            case "delete_item": .removeFromAlbum(id: 3, photos: [photo])
            default: .setAlbumCover(id: 3, photo: photo)
            }
            XCTAssertEqual(command.space, .shared)
            let id = UUID(), result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed, mode)
            _ = try await repository.performMutation(command, operationID: id) { _, _ in }
            let calls = try await transport.recordedRequests().map(decode)
            let writes = calls.filter { $0["method"] == mode }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["api"], mode == "set_cover" ? "SYNO.Foto.Browse.Album" : "SYNO.Foto.Browse.NormalAlbum")
            XCTAssertFalse(calls.contains { $0["api"]?.hasPrefix("SYNO.FotoTeam.Browse.Album") == true })
        }
    }

    func test混合来源照片加入相册各自预检且写后核对两种来源() async throws {
        let shared = itemPage.replacingOccurrences(of: #""id":7"#, with: #""id":8"#).replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":0"#)
        let personal = itemPage
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(personal.utf8)) as? [String: Any])
        let right = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        let leftItems = try XCTUnwrap((left["data"] as? [String: Any])?["list"] as? [[String: Any]])
        let rightItems = try XCTUnwrap((right["data"] as? [String: Any])?["list"] as? [[String: Any]])
        let mixed = String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": leftItems + rightItems]]), as: UTF8.self)
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(personal), response(shared),
            response(personal), response(managedFolder), response(shared), response(managedFolder), response(album), response(emptySuccess), response(mixed)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let a = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 20)
        let b = try await repository.photos(in: .shared, query: .recentlyAdded, offset: 0, limit: 20)
        let result = try await repository.performMutation(.addToAlbum(id: 3, photos: a.items + b.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.completedCount, 2)
        let calls = try await transport.recordedRequests().map(decode)
        let identities = calls.filter { $0["method"] == "get" && $0["api"]?.hasSuffix("Browse.Item") == true }
        XCTAssertEqual(identities.map { $0["api"] }, ["SYNO.Foto.Browse.Item", "SYNO.FotoTeam.Browse.Item"])
        XCTAssertEqual(calls.first { $0["method"] == "add_item" }?["item"], "[7,8]")
        let first = try XCTUnwrap(a.items.first)
        var duplicate = first
        duplicate = SynologyPhoto(id: .init(profileID: first.id.profileID, space: .shared, unitID: first.id.unitID), filename: first.filename,
            sizeBytes: first.sizeBytes, takenAt: first.takenAt, indexedAt: first.indexedAt, folderID: first.folderID, mediaType: first.mediaType)
        do { try await repository.prepareMutation(.addToAlbum(id: 3, photos: [first, duplicate])); XCTFail("统一相册成员编号不能含混") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
    }

    func test关闭个人照片空间仍能创建空普通相册并读取统一列表() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [
            response(#"{"success":true,"data":{"album":{"id":3,"name":"Fixture","owner_user_id":12}}}"#), response(album),
            response(#"{"success":true,"data":{"list":[]}}"#), response(album)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.performMutation(.createAlbum(name: "Fixture", photos: []), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let albums = try await repository.albums(offset: 0, limit: 100); XCTAssertEqual(albums.first?.id, 3)
    }

    func test关闭个人空间仍按相册编号授权读取共享封面() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":3,"name":"Fixture","owner_user_id":12,"additional":{"thumbnail":{"unit_id":7,"cache_key":"fixture"}}}]}}"#
        let bytes = Data([1, 2, 3])
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(album),
            DsmHTTPResponse(data: bytes, statusCode: 200, headers: ["Content-Type": "image/jpeg"])])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let data = try await repository.thumbnail(for: .init(id: 3, name: "Fixture")); XCTAssertEqual(data, bytes)
        let requests = await transport.recordedRequests(); let request = try XCTUnwrap(requests.last)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "album_id" }?.value, "3")
        XCTAssertTrue(request.url?.path.contains("/p/Thumbnail/get") == true)
    }

    func test共享条件相册在关闭个人空间时按共享目录预检并统一创建回读() async throws {
        let raw = #"{"user_id":0,"item_type":[-1],"folder_filter":[{"id":9,"name":"Fixture folder"}]}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [response(managedFolder),
            response(#"{"success":true,"data":{"album":{"id":21}}}"#), response(conditionAlbum), response(conditionAlbum), conditionReply(raw)])
        let repository = try makeRepository(transport)
        _ = try await repository.access()
        let command = SynologyPhotosMutation.createConditionAlbum(name: "Fixture rule album", condition: .init(fields: [
            "user_id": .integer(0), "item_type": .array([.integer(-1)]), "folder_filter": .array([.integer(9)])]))
        XCTAssertEqual(command.space, .shared)
        let operation = UUID()
        let result = try await repository.performMutation(command, operationID: operation) { _, _ in }
        XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.album?.isConditional, true)
        _ = try await repository.performMutation(command, operationID: operation) { _, _ in }
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.filter { $0["api"] == "SYNO.FotoTeam.Browse.Folder" }.count, 1)
        let creates = calls.filter { $0["method"] == "create" }
        XCTAssertEqual(creates.count, 1); XCTAssertEqual(creates[0]["api"], "SYNO.Foto.Browse.ConditionAlbum")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(creates[0]["condition"]).utf8)) as? [String: Any])
        XCTAssertEqual(fields["user_id"] as? Int, 0)
    }

    func test条件相册可从个人改为共享且核对原快照和新来源() async throws {
        let personal = #"{"user_id":12,"item_type":[]}"#
        let shared = #"{"user_id":0,"item_type":[-2]}"#
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(conditionAlbum), conditionReply(personal),
            response(emptySuccess), response(conditionAlbum), conditionReply(shared), response(conditionAlbum)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let result = try await repository.performMutation(.setAlbumCondition(id: 21,
            original: .init(fields: ["user_id": .integer(12), "item_type": .array([])]),
            condition: .init(fields: ["user_id": .integer(0), "item_type": .array([.integer(-2)])])), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let writes = try await transport.recordedRequests().map(decode).filter { $0["method"] == "set_condition" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["api"], "SYNO.Foto.Browse.ConditionAlbum")
    }

    func test共享条件来源要求管理权限与实际接口且不接受他人用户编号() async throws {
        for permission in ["none", "entry", "management"] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: permission))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let features = await repository.managementFeatures(in: .shared)
            XCTAssertEqual(features.contains(.conditionAlbums), permission == "management")
            for user in [0, 99] where permission != "management" || user == 99 {
                do { try await repository.prepareMutation(.createConditionAlbum(name: "Fixture", condition: .init(fields: ["user_id": .integer(user)]))); XCTFail("不允许越权来源") }
                catch let error as AppError { XCTAssertTrue([.permissionDenied, .apiUnavailable].contains(error.category)) }
            }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        }
        let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(teamPermission: "management")), omittedAPIs: ["SYNO.Foto.Browse.ConditionAlbum"])
        _ = try await repository.access()
        let features = await repository.managementFeatures(in: .shared)
        XCTAssertFalse(features.contains(.conditionAlbums))
    }

    func test共享条件建议与数量以零用户编码且全程只读() async throws {
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management", homeEnabled: false) + [
            response(#"{"success":true,"data":{"general_tag":[{"id":8,"name":"Fixture shared tag"}]}}"#), response(#"{"success":true,"data":{"count":7}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let suggestions = try await repository.conditionSuggestions(keyword: "Fixture", in: .shared)
        XCTAssertEqual(suggestions["general_tag"]?.first?.name, "Fixture shared tag")
        let count = try await repository.conditionItemCount(.init(fields: ["user_id": .integer(0)]))
        XCTAssertEqual(count, 7)
        let calls = try await transport.recordedRequests().map(decode).suffix(2)
        XCTAssertTrue(calls.allSatisfy { $0["api"] == "SYNO.Foto.Browse.ConditionAlbum" })
        XCTAssertEqual(calls.first?["user_id"], "0"); XCTAssertEqual(calls.map { $0["method"] }, ["suggest", "peek_item_count"])
    }

    func test相册照片来源缺失或无效时不猜测为个人照片() async throws {
        for value in ["", #""owner_user_id":-1,"#] {
            let page = itemPage.replacingOccurrences(of: #""owner_user_id":12,"#, with: value)
            let repository = try makeRepository(MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(page)]))
            _ = try await repository.access()
            do { _ = try await repository.photos(in: .personal, query: .album(id: 3), offset: 0, limit: 100); XCTFail("来源不完整不能误路由原件操作") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test相册照片保留来源且详情继续携带相册授权() async throws {
        let sharedPage = itemPage.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":0"#)
        for space in [SynologyPhotoSpace.personal, .shared] {
            let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "management") + [response(sharedPage), response(sharedPage)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let page = try await repository.photos(in: space, query: .album(id: 21), offset: 0, limit: 100)
            let photo = try XCTUnwrap(page.items.first)
            XCTAssertEqual(photo.id.space, .shared)
            _ = try await repository.details(for: photo)
            let calls = try await transport.recordedRequests().map(decode).suffix(2)
            XCTAssertEqual(calls.first?["api"], "SYNO.Foto.Browse.Item")
            XCTAssertEqual(calls.last?["api"], "SYNO.Foto.Browse.Item")
            XCTAssertEqual(calls.last?["album_id"], "21")
        }
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

    func test相册授权可读取未开放源空间的详情缩略图和原件() async throws {
        for owner in [0, 99] {
            let page = itemPage.replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":\(owner)")
            let bytes = Data(repeating: 0x7f, count: 128)
            let image = DsmHTTPResponse(data: bytes, statusCode: 200, headers: ["Content-Type": "image/jpeg"])
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(page), response(page), image, image, image])
            let repository = try makeRepository(transport); let access = try await repository.access()
            XCTAssertTrue(access.spaces.isEmpty)
            let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 100)
            let photo = try XCTUnwrap(photos.items.first)
            XCTAssertEqual(photo.id.space, owner == 0 ? .shared : .personal)
            XCTAssertEqual(photo.albumContext, .init(albumID: 21, ownerUserID: owner))
            let detail = try await repository.details(for: photo)
            XCTAssertEqual(detail.albumContext, photo.albumContext)
            let thumbnail = try await repository.thumbnail(for: detail), preview = try await repository.previewImage(for: detail)
            XCTAssertEqual(thumbnail, bytes); XCTAssertEqual(preview, bytes)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            try await repository.downloadOriginal(detail, to: destination) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            let requests = await transport.recordedRequests()
            for request in requests.dropFirst(4) {
                let parameters = request.httpMethod == "GET" ? try query(request) : try decode(request)
                XCTAssertEqual(parameters["album_id"], "21")
                XCTAssertFalse(parameters["api"]?.hasPrefix("SYNO.FotoTeam.") == true)
                if request.url?.path.contains("Thumbnail") == true { XCTAssertTrue(request.url?.path.contains("/p/") == true) }
                XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
            }
        }
    }

    func test相册视频及实况读取始终带相册编号() async throws {
        for live in [false, true] {
            for converted in [false, true] {
                let page = live ? itemPage.replacingOccurrences(of: "\"type\":\"photo\"", with: "\"type\":\"live\"") : videoPage(extension: "mp4", qualities: converted ? ["medium"] : [])
                let video = live ? #"{"success":true,"data":{"list":[{"id_item":7,"unit":[{"id":702,"live_type":"video","filename":"sample.mov","additional":{"video_convert":CONVERSIONS}}]}]}}"#.replacingOccurrences(of: "CONVERSIONS", with: converted ? #"[{"quality":"medium"}]"# : "[]") : page
                let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(page), response(video)])
                let repository = try makeRepository(transport); _ = try await repository.access()
                let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
                let source = try await repository.videoSource(for: XCTUnwrap(photos.items.first))
                let fields = try query(source.request)
                XCTAssertEqual(fields["album_id"], "21")
                XCTAssertEqual(fields["api"], converted ? "SYNO.Foto.Streaming" : "SYNO.Foto.Download")
                XCTAssertEqual(fields[converted ? "id" : live ? "unit_id" : "item_id"], converted ? live ? "702" : "7" : live ? "[702]" : "[7]")
                let calls = try await transport.recordedRequests().map(decode)
                XCTAssertEqual(calls.last?["album_id"], "21")
                XCTAssertEqual(calls.last?["api"], live ? "SYNO.Foto.Browse.Unit" : "SYNO.Foto.Browse.Item")
            }
        }
    }

    func test相册查看权不授予他人个人照片原件写权限() async throws {
        let page = itemPage.replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":99")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(page), response(page)])
        let repository = try makeRepository(transport, deletionEnabled: true); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
        let photo = try XCTUnwrap(photos.items.first)
        do { try await repository.prepareDeletion(photo); XCTFail("相册查看不能变成删除原件") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { try await repository.prepareMutation(.edit([photo], .rating(5))); XCTFail("仅查看而非提供者不能编辑") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
        let calls = try requests.map(decode)
        XCTAssertFalse(calls.contains { $0["method"] == "set" || $0["method"] == "delete" })
        XCTAssertTrue(calls.filter { $0["api"] == "SYNO.Foto.Browse.Item" }.allSatisfy { $0["album_id"] == "21" })
    }

    func test相册读取权限失败不降级到原件空间() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
        do { _ = try await repository.details(for: XCTUnwrap(photos.items.first)); XCTFail("权限失败应传递") } catch {}
        let calls = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(calls.count, 6); XCTAssertEqual(calls.last?["album_id"], "21")
    }

    func test相册详情不接受改变原件所有者的响应() async throws {
        let wrong = itemPage.replacingOccurrences(of: "\"owner_user_id\":12", with: "\"owner_user_id\":0")
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(wrong)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
        do { _ = try await repository.details(for: XCTUnwrap(photos.items.first)); XCTFail("详情不能换来源") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test相册上下文不跨NAS且Photos授权失败后不可复用() async throws {
        let id = UUID()
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(itemPage), response(#"{"success":true,"data":{"enabled":false}}"#)])
        let repository = try makeRepository(transport, profileID: id); _ = try await repository.access()
        let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
        let photo = try XCTUnwrap(photos.items.first)
        let foreign = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: photo.filename, sizeBytes: 128,
            takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: 9, mediaType: "photo", thumbnail: photo.thumbnail, albumContext: photo.albumContext)
        do { _ = try await repository.thumbnail(for: foreign); XCTFail("不能跨NAS读取") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        do { _ = try await repository.access(); XCTFail("Photos已停用") } catch {}
        do { _ = try await repository.thumbnail(for: photo); XCTFail("不能复用旧授权") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
    }

    func test没有个人共享空间仍可列出相册和他人分享() async throws {
        let album = #"{"success":true,"data":{"list":[{"id":21,"name":"Fixture","owner_user_id":99}]}}"#
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(album), response(album)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let albums = try await repository.albums(offset: 0, limit: 10), shares = try await repository.sharedEntries(.withMe, offset: 0, limit: 10)
        XCTAssertEqual(albums.first?.id, 21); XCTAssertEqual(shares.first?.albumID, 21)
    }

    func test相册在途读取在Photos重新授权失败后不能返回旧结果() async throws {
        for detail in [false, true] {
            let transport = AlbumReadBarrierTransport(MockHTTPTransport(responses: accessResponses() +
                (detail ? [response(itemPage)] : []) + [response(itemPage), response(#"{"success":true,"data":{"enabled":false}}"#)]))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let photo: SynologyPhoto?
            if detail {
                let page = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
                photo = try XCTUnwrap(page.items.first)
            } else { photo = nil }
            await transport.holdNext()
            let read = Task {
                if let photo { _ = try await repository.details(for: photo) }
                else { _ = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10) }
            }
            await transport.waitUntilHeld()
            do { _ = try await repository.access(); XCTFail("Photos已停用") } catch {}
            await transport.release()
            do { try await read.value; XCTFail("授权变化后不能返回旧相册内容") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
    }

    private func albumListOrder(_ scope: SynologyPhotoAlbumListScope, _ sort: SynologyPhotoAlbumListSort) -> String {
        #"{"success":true,"data":{"\#(scope.rawValue)_sort_by":"\#(sort.field.rawValue)","\#(scope.rawValue)_sort_direction":"\#(sort.direction.rawValue)"}}"#
    }
    private func albumDisplay(_ value: SynologyPhotoAlbumDisplay) -> String {
        #"{"success":true,"data":{"album_display_type":"\#(value.rawValue)"}}"#
    }

    func test三类相册列表排序按各自字段双向保存回读并去重() async throws {
        for scope in SynologyPhotoAlbumListScope.allCases {
            for field in scope.fields {
                for direction in SynologyPhotoSort.Direction.allCases {
                    let sort = SynologyPhotoAlbumListSort(field: field, direction: direction)
                    let old = SynologyPhotoAlbumListSort(field: field, direction: direction == .ascending ? .descending : .ascending)
                    let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [albumListOrder(scope, old), emptySuccess, albumListOrder(scope, sort)].map(response))
                    let repository = try makeRepository(transport); _ = try await repository.access()
                    let command = SynologyPhotosMutation.setAlbumListSort(scope: scope, original: old, sort: sort), id = UUID()
                    let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
                    let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result, repeated)
                    let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set_album_list_order" }
                    XCTAssertEqual(writes.count, 1); let write = try XCTUnwrap(writes.first)
                    XCTAssertEqual(write["version"], "2"); XCTAssertEqual(write["api"], "SYNO.Foto.Browse.Album")
                    XCTAssertEqual(write[scope.rawValue + "_sort_by"], "\"" + field.rawValue + "\"")
                    XCTAssertEqual(write[scope.rawValue + "_sort_direction"], "\"" + direction.rawValue + "\"")
                    for other in SynologyPhotoAlbumListScope.allCases where other != scope {
                        XCTAssertNil(write[other.rawValue + "_sort_by"]); XCTAssertNil(write[other.rawValue + "_sort_direction"])
                    }
                }
            }
        }
    }

    func test相册显示范围v3保存不修改排序并按两种分类分页() async throws {
        for display in SynologyPhotoAlbumDisplay.allCases {
            let old: SynologyPhotoAlbumDisplay = display == .all ? .mine : .all
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [albumDisplay(old), emptySuccess, albumDisplay(display), collaborationAlbum(owner: 12), collaborationAlbum(owner: 12)].map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let result = try await repository.performMutation(.setAlbumListDisplay(original: old, display: display), operationID: UUID()) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
            for offset in [0, 10] { _ = try await repository.albums(offset: offset, limit: 10, display: display, sort: .init(field: .created, direction: .ascending)) }
            let calls = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(calls[5]["method"], "set_album_list_display"); XCTAssertEqual(calls[5]["version"], "3")
            XCTAssertEqual(calls[5]["album_display_type"], "\"" + display.rawValue + "\""); XCTAssertNil(calls[5]["album_list_sort_by"])
            for (call, offset) in zip(calls.suffix(2), ["0", "10"]) {
                XCTAssertEqual(call["category"], display == .mine ? #""normal""# : #""normal_share_with_me""#)
                XCTAssertEqual(call["sort_by"], #""create_time""#); XCTAssertEqual(call["sort_direction"], #""asc""#); XCTAssertEqual(call["offset"], offset)
            }
        }
    }

    func test分享列表自定义排序每页保留原路由且不改变收集列表() async throws {
        for scope in [SynologyPhotoShareScope.withMe, .withOthers] {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum()), response(collaborationAlbum())])
            let repository = try makeRepository(transport); _ = try await repository.access()
            for offset in [0, 20] { _ = try await repository.sharedEntries(scope, offset: offset, limit: 20, sort: .init(field: .name, direction: .ascending)) }
            let calls = try await transport.recordedRequests().map(decode)
            for (call, offset) in zip(calls.suffix(2), ["0", "20"]) {
                XCTAssertEqual(call["method"], scope == .withMe ? "list_shared_with_me_album" : "list")
                XCTAssertEqual(call["api"], scope == .withMe ? "SYNO.Foto.Sharing.Misc" : "SYNO.Foto.Browse.Album")
                XCTAssertEqual(call["sort_by"], #""album_name""#); XCTAssertEqual(call["sort_direction"], #""asc""#); XCTAssertEqual(call["offset"], offset)
            }
            do { _ = try await repository.sharedEntries(.requests, offset: 0, limit: 20, sort: .init(field: .name, direction: .ascending)); XCTFail("收集不接受相册排序") } catch { }
            let after = await transport.recordedRequests(); XCTAssertEqual(after.count, calls.count)
        }
    }

    func test列表偏好缺失未知枚举及其他范围字段不猜默认值() async throws {
        let bad = [#"{"success":true,"data":{}}"#, albumDisplay(.all), albumListOrder(.withMe, .init(field: .created, direction: .ascending)), albumListOrder(.withMe, .init(field: .name, direction: .ascending)).replacingOccurrences(of: "asc", with: "future")]
        for value in bad {
            let transport = MockHTTPTransport(responses: accessResponses() + [response(value)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do { _ = try await repository.albumListSort(.withMe); XCTFail("未知不能伪装成已读偏好") } catch { }
        }
        let transport = MockHTTPTransport(responses: accessResponses() + [response(albumDisplay(.all).replacingOccurrences(of: "all_album", with: "future"))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        do { _ = try await repository.albumListDisplay(); XCTFail("未知显示范围不能覆盖为全部") } catch { }
    }

    func test列表排序冲突不覆盖而丢失回执只核对原范围() async throws {
        let old = SynologyPhotoAlbumListSort(field: .name, direction: .ascending), next = SynologyPhotoAlbumListSort(field: .type, direction: .descending)
        let conflict = MockHTTPTransport(responses: accessResponses() + [response(albumListOrder(.byMe, next))])
        let stale = try makeRepository(conflict); _ = try await stale.access()
        do { _ = try await stale.performMutation(.setAlbumListSort(scope: .byMe, original: old, sort: next), operationID: UUID()) { _, _ in }; XCTFail("并发改变应拒绝") } catch { }
        let noWrites = try await conflict.recordedRequests().map(decode); XCTAssertFalse(noWrites.contains { $0["method"] == "set_album_list_order" })
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(albumListOrder(.byMe, old))]).map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(albumListOrder(.byMe, old))), .response(response(albumListOrder(.byMe, next)))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setAlbumListSort(scope: .byMe, original: old, sort: next), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .pendingReview)
        let pending = try await repository.reviewMutation(operationID: id); XCTAssertEqual(pending.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set_album_list_order" }.count, 1)
    }

    private func sortedAlbum(_ sort: SynologyPhotoSort?, owner: Int = 12) -> String {
        let base = collaborationAlbum(owner: owner)
        guard let sort else { return base }
        return base.replacingOccurrences(of: #""id":21"#, with: #""id":21,"sort_by":"\#(sort.field.rawValue)","sort_direction":"\#(sort.direction.rawValue)""#)
    }

    func test相册排序四字段双向跨页与个人空间关闭仍使用统一相册路由() async throws {
        for field in SynologyPhotoSort.Field.allCases {
            for direction in SynologyPhotoSort.Direction.allCases {
                let sort = SynologyPhotoSort(field: field, direction: direction)
                let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [sortedAlbum(sort), itemPage, itemPage].map(response))
                let repository = try makeRepository(transport); _ = try await repository.access()
                let current = try await repository.albumSort(id: 21); XCTAssertEqual(current, sort)
                for offset in [0, 100] { _ = try await repository.photos(in: .personal, query: .album(id: 21, sort: sort), offset: offset, limit: 100) }
                let calls = try await transport.recordedRequests().map(decode)
                XCTAssertEqual(calls[4]["version"], "4"); XCTAssertEqual(calls[4]["id"], "[21]")
                for (call, offset) in zip(calls.suffix(2), ["0", "100"]) {
                    XCTAssertEqual(call["api"], "SYNO.Foto.Browse.Item"); XCTAssertEqual(call["album_id"], "21")
                    XCTAssertEqual(call["offset"], offset); XCTAssertEqual(call["sort_by"], "\"" + field.rawValue + "\"")
                    XCTAssertEqual(call["sort_direction"], "\"" + direction.rawValue + "\"")
                }
            }
        }
    }

    func test相册排序默认拍摄升序而未知枚举与错误相册拒绝() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(sortedAlbum(nil))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let order = try await repository.albumSort(id: 21); XCTAssertEqual(order, .init())
        for payload in [sortedAlbum(.init()).replacingOccurrences(of: "takentime", with: "future"), sortedAlbum(.init()).replacingOccurrences(of: "asc", with: "future"), sortedAlbum(.init()).replacingOccurrences(of: #""id":21"#, with: #""id":22"#)] {
            let failing = MockHTTPTransport(responses: accessResponses() + [response(payload)])
            let target = try makeRepository(failing); _ = try await target.access()
            do { _ = try await target.albumSort(id: 21); XCTFail("未知排序或身份不能沿默认值冒充成功") } catch { }
        }
    }

    func test相册排序查看者保存v1自动回读去重且不要求上传权限() async throws {
        let old = SynologyPhotoSort(), next = SynologyPhotoSort(field: .filename, direction: .descending)
        let baseline = [sortedAlbum(old, owner: 99), collaborationPermission(download: false, upload: false)]
        let after = [sortedAlbum(next, owner: 99), collaborationPermission(download: false, upload: false)]
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + (baseline + [emptySuccess] + after).map(response))
        let repository = try makeRepository(transport); _ = try await repository.access()
        let features = await repository.managementFeatures(in: .personal); XCTAssertTrue(features.contains(.albumSorting))
        let command = SynologyPhotosMutation.setAlbumSort(id: 21, original: old, sort: next), id = UUID()
        let result = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result.state, .confirmed)
        let repeated = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(result, repeated)
        let calls = try await transport.recordedRequests().map(decode), writes = calls.filter { $0["method"] == "set_order" }
        XCTAssertEqual(writes.count, 1); let write = try XCTUnwrap(writes.first)
        XCTAssertEqual(write["api"], "SYNO.Foto.Browse.Album"); XCTAssertEqual(write["version"], "1"); XCTAssertEqual(write["id"], "21")
        XCTAssertEqual(write["sort_by"], #""filename""#); XCTAssertEqual(write["sort_direction"], #""desc""#)
        XCTAssertFalse(calls.contains { $0["api"]?.contains("Browse.Item") == true || $0["api"]?.contains("Browse.Folder") == true })
    }

    func test相册排序回执丢失只回读且缺省字段不能作为保存证明() async throws {
        let old = SynologyPhotoSort(field: .filename), next = SynologyPhotoSort()
        let transport = MockHTTPTransport(steps: (accessResponses() + [response(sortedAlbum(old))]).map(MockHTTPTransport.Step.response) +
            [.urlError(.networkConnectionLost), .response(response(sortedAlbum(nil))), .response(response(sortedAlbum(next)))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.setAlbumSort(id: 21, original: old, sort: next), id = UUID()
        let pending = try await repository.performMutation(command, operationID: id) { _, _ in }; XCTAssertEqual(pending.state, .pendingReview)
        let missing = try await repository.reviewMutation(operationID: id); XCTAssertEqual(missing.state, .pendingReview)
        let final = try await repository.reviewMutation(operationID: id); XCTAssertEqual(final.state, .confirmed)
        let calls = try await transport.recordedRequests().map(decode); XCTAssertEqual(calls.filter { $0["method"] == "set_order" }.count, 1)
    }

    func test相册排序原始设置变化或权限撤回不写入() async throws {
        for responses in [[sortedAlbum(.init(field: .filesize))], [sortedAlbum(.init(), owner: 99), #"{"success":false,"error":{"code":105}}"#]] {
            let transport = MockHTTPTransport(responses: accessResponses() + responses.map(response))
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                _ = try await repository.performMutation(.setAlbumSort(id: 21, original: .init(), sort: .init(field: .filename)), operationID: UUID()) { _, _ in }
                XCTFail("过期设置或撤回权限不能保存")
            } catch { }
            let calls = try await transport.recordedRequests().map(decode); XCTAssertFalse(calls.contains { $0["method"] == "set_order" })
        }
    }

    private func collaborationAlbum(owner: Int = 99, condition: Bool = false) -> String {
        #"{"success":true,"data":{"list":[{"id":21,"name":"Fixture","owner_user_id":\#(owner),"type":"\#(condition ? "condition" : "normal")","passphrase":"fixture-collaboration"}]}}"#
    }

    private func collaborationPermission(download: Bool = true, upload: Bool = true) -> String {
        #"{"success":true,"data":{"permission":{"download":\#(download),"upload":\#(upload)}}}"#
    }

    private func collaborationPage(provider: Int = 12) -> String {
        itemPage.replacingOccurrences(of: #""owner_user_id":12"#, with: #""owner_user_id":99"#)
            .replacingOccurrences(of: #""additional":{"#, with: #""additional":{"provider_user_id":\#(provider),"#)
    }

    func test相册角色区分查看下载贡献及条件限制且不输出分享口令() async throws {
        for (download, upload, condition) in [(false, false, false), (true, false, false), (true, true, false), (true, true, true)] {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum(condition: condition)), response(collaborationPermission(download: download, upload: upload))])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let rights = try await repository.albumAccess(id: 21)
            XCTAssertFalse(rights.isOwner); XCTAssertEqual(rights.canDownload, download)
            XCTAssertEqual(rights.canContribute, upload && !condition); XCTAssertEqual(rights.currentUserID, 12)
            let requests = await transport.recordedRequests()
            let request = try XCTUnwrap(requests.last)
            let fields = try decode(request)
            XCTAssertEqual(fields["api"], "SYNO.Foto.Sharing.Passphrase"); XCTAssertEqual(fields["method"], "get_permission")
            XCTAssertEqual(fields["passphrase"], #""fixture-collaboration""#); XCTAssertEqual(fields["exclude_public"], "false")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-collaboration"))
        }
        let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum(owner: 12))])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let rights = try await repository.albumAccess(id: 21)
        XCTAssertTrue(rights.isOwner && rights.canContribute && rights.canDownload)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
    }

    func test添加相册选择器只请求可贡献相册列表() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(collaborationAlbum())])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let albums = try await repository.addableAlbums(offset: 0, limit: 100)
        XCTAssertEqual(albums.first?.id, 21)
        let requests = await transport.recordedRequests()
        let fields = try decode(XCTUnwrap(requests.last))
        XCTAssertEqual(fields["api"], "SYNO.Foto.Browse.NormalAlbum"); XCTAssertEqual(fields["category"], #""addable""#)
    }

    func test贡献者添加自己的照片使用分享目标并回读成员且不重放() async throws {
        let transport = MockHTTPTransport(responses: accessResponses() + [response(itemPage), response(itemPage), response(managedFolder),
            response(collaborationAlbum()), response(collaborationPermission()), response(emptySuccess), response(itemPage)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 10)
        let command = SynologyPhotosMutation.addToAlbum(id: 21, photos: page.items), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .confirmed)
        }
        let fields = try await transport.recordedRequests().map(decode)
        let writes = fields.filter { $0["method"] == "add_item" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["passphrase"], #""fixture-collaboration""#)
        XCTAssertNil(writes.first?["id"])
    }

    func test相册成员部分失败按回读确认且重复操作编号不重放() async throws {
        let second = itemPage.replacingOccurrences(of: "\"id\":7", with: "\"id\":8").replacingOccurrences(of: "\"unit_id\":7", with: "\"unit_id\":8")
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(itemPage.utf8)) as? [String: Any])
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        let firstList = try XCTUnwrap((firstObject["data"] as? [String: Any])?["list"] as? [[String: Any]])
        let secondList = try XCTUnwrap((secondObject["data"] as? [String: Any])?["list"] as? [[String: Any]])
        let combined = String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "data": ["list": firstList + secondList]]), as: UTF8.self)
        let transport = MockHTTPTransport(responses: accessResponses() + [response(combined), response(itemPage), response(managedFolder),
            response(second), response(managedFolder), response(collaborationAlbum()), response(collaborationPermission()),
            response(#"{"success":true,"data":{"error_list":[{"id":8}]}}"#), response(itemPage)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let page = try await repository.photos(in: .personal, query: .recentlyAdded, offset: 0, limit: 10)
        let command = SynologyPhotosMutation.addToAlbum(id: 21, photos: page.items), operationID = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: operationID) { _, _ in }
            XCTAssertEqual(result.state, .partial); XCTAssertEqual(result.completedCount, 1)
            XCTAssertEqual(result.photos, [page.items[0]])
        }
        let requests = try await transport.recordedRequests().map(decode)
        XCTAssertEqual(requests.filter { $0["method"] == "add_item" }.count, 1)
    }

    func test贡献者只能移除自己提供的相册成员且不要求原件写权限() async throws {
        for provider in [12, 99] {
            let page = collaborationPage(provider: provider)
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(page), response(page),
                response(collaborationAlbum()), response(collaborationPermission())] + (provider == 12 ? [response(emptySuccess), response(#"{"success":true,"data":{"list":[]}}"#)] : []))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let photos = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
            do {
                let result = try await repository.performMutation(.removeFromAlbum(id: 21, photos: photos.items), operationID: UUID()) { _, _ in }
                XCTAssertEqual(provider, 12); XCTAssertEqual(result.state, .confirmed)
            } catch let error as AppError { XCTAssertEqual(provider, 99); XCTAssertEqual(error.category, .permissionDenied) }
            let fields = try await transport.recordedRequests().map(decode)
            XCTAssertEqual(fields.filter { $0["method"] == "delete_item" }.count, provider == 12 ? 1 : 0)
            XCTAssertFalse(fields.contains { $0["method"] == "delete" || $0["api"]?.hasSuffix("Browse.Folder") == true })
        }
    }

    func test只读相册不能上传且权限未知不会发起写入() async throws {
        for permission in [collaborationPermission(download: false, upload: false), #"{"success":false,"error":{"code":105}}"#] {
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum()), response(permission)])
            let repository = try makeRepository(transport); _ = try await repository.access()
            do {
                _ = try await repository.performMutation(.uploadToAlbum(file: URL(fileURLWithPath: "/synthetic/unused.jpg"), size: 128, modifiedAt: Date(), albumID: 21), operationID: UUID()) { _, _ in }
                XCTFail("只读或权限失败不可上传")
            } catch {}
            let requests = await transport.recordedRequests()
            XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") == true })
        }
    }

    func test共享相册上传直接完成成员关系且无个人空间依赖() async throws {
        for owner in [12, 99] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try Data(repeating: 0x7f, count: 128).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: false) + [response(collaborationAlbum(owner: owner))] +
                (owner == 12 ? [] : [response(collaborationPermission())]) + [response(#"{"success":true,"data":{"id":7,"action":"upload"}}"#), response(collaborationPage())])
            let repository = try makeRepository(transport); _ = try await repository.access()
            let command = SynologyPhotosMutation.uploadToAlbum(file: file, size: 128, modifiedAt: modified, albumID: 21), id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed); XCTAssertEqual(result.photos.first?.albumContext?.albumID, 21)
                XCTAssertEqual(result.photos.first?.albumContext?.providerUserID, 12)
            }
            let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
            let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
            XCTAssertTrue(body.contains("SYNO.Foto.Upload.Item")); XCTAssertTrue(body.contains(owner == 12 ? "album_id" : "passphrase"))
            XCTAssertFalse(body.contains("uploadDestination")); XCTAssertFalse(body.contains("target_folder_id"))
            let requests = await transport.recordedRequests()
            let reads = try requests.filter { $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart") != true }.map(decode)
            XCTAssertEqual(reads.last?["album_id"], "21")
            XCTAssertFalse(reads.contains { $0["method"] == "add_item" })
        }
    }

    func test相册上传回执丢失只核对不重新传输() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data(repeating: 0x7f, count: 128).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let steps = (accessResponses(homeEnabled: false) + [response(collaborationAlbum()), response(collaborationPermission())]).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps + [.urlError(.timedOut)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let command = SynologyPhotosMutation.uploadToAlbum(file: file, size: 128, modifiedAt: modified, albumID: 21), id = UUID()
        for _ in 0..<2 {
            let result = try await repository.performMutation(command, operationID: id) { _, _ in }
            XCTAssertEqual(result.state, .pendingReview)
        }
        let bodies = await transport.recordedUploadBodies(); XCTAssertEqual(bodies.count, 1)
    }

    func test本人提供的相册照片可转加或新建目标且不访问他人原件目录() async throws {
        for mode in ["add-owned", "add-shared", "create"] {
            let page = collaborationPage()
            let target = collaborationAlbum(owner: mode == "add-shared" ? 88 : 12).replacingOccurrences(of: "\"id\":21", with: "\"id\":22")
            var responses = accessResponses() + [response(page), response(page)]
            if mode != "create" { responses.append(response(target)) }
            if mode == "add-shared" { responses.append(response(collaborationPermission())) }
            responses.append(response(mode == "create" ? #"{"success":true,"data":{"album":{"id":22,"name":"Fixture","owner_user_id":12}}}"# : emptySuccess))
            if mode == "create" { responses.append(response(target)) }
            responses.append(response(page))
            let transport = MockHTTPTransport(responses: responses), repository = try makeRepository(transport)
            _ = try await repository.access()
            let original = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
            let command: SynologyPhotosMutation = mode == "create" ? .createAlbum(name: "Fixture", photos: original.items) : .addToAlbum(id: 22, photos: original.items)
            let id = UUID()
            for _ in 0..<2 {
                let result = try await repository.performMutation(command, operationID: id) { _, _ in }
                XCTAssertEqual(result.state, .confirmed, mode); XCTAssertEqual(result.completedCount, 1)
            }
            let fields = try await transport.recordedRequests().map(decode)
            let writes = fields.filter { $0["method"] == "create" || $0["method"] == "add_item" }
            XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["item"], "[7]")
            XCTAssertNil(writes[0]["album_id"], "来源相册不应被错当作写入目标参数")
            if mode == "add-shared" { XCTAssertNotNil(writes[0]["passphrase"]); XCTAssertNil(writes[0]["id"]) }
            if mode == "add-owned" { XCTAssertEqual(writes[0]["id"], "22") }
            XCTAssertFalse(fields.contains { $0["api"]?.hasSuffix("Browse.Folder") == true })
            let reads = fields.filter { $0["api"] == "SYNO.Foto.Browse.Item" }
            XCTAssertEqual(reads.map { $0["album_id"] }, ["21", "21", "22"])
        }
    }

    func test跨相册添加拒绝原空间关闭提供者变化与来源读取拒绝() async throws {
        for scenario in ["disabled", "provider", "denied", "changed"] {
            let source = collaborationPage()
            let preflight = scenario == "provider" ? collaborationPage(provider: 99) : scenario == "denied" ? #"{"success":false,"error":{"code":105}}"# : source.replacingOccurrences(of: "\"filesize\":128", with: "\"filesize\":256")
            let transport = MockHTTPTransport(responses: accessResponses(homeEnabled: scenario != "disabled") + [response(source)] + (scenario == "disabled" ? [] : [response(preflight)]))
            let repository = try makeRepository(transport); _ = try await repository.access()
            let original = try await repository.photos(in: .personal, query: .album(id: 21), offset: 0, limit: 10)
            do {
                _ = try await repository.performMutation(.addToAlbum(id: 22, photos: original.items), operationID: UUID()) { _, _ in }
                XCTFail("来源预检必须拒绝: \(scenario)")
            } catch { }
            let fields = try await transport.recordedRequests().map(decode)
            XCTAssertFalse(fields.contains { $0["method"] == "add_item" || $0["method"] == "create" })
            XCTAssertFalse(fields.contains { $0["api"] == "SYNO.Foto.Browse.Item" && $0["album_id"] == nil })
        }
    }

    func test混合来源的相册转加缺少共享管理权时不提交() async throws {
        let profile = UUID()
        let personal = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "sample.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
            albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: 12))
        let shared = SynologyPhoto(id: .init(profileID: profile, space: .shared, unitID: 8), filename: "sample.jpg", sizeBytes: 128,
            takenAt: personal.takenAt, indexedAt: personal.indexedAt, folderID: 9, mediaType: "photo",
            albumContext: .init(albumID: 21, ownerUserID: 0, providerUserID: 12))
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry"))
        let repository = try makeRepository(transport, profileID: profile); _ = try await repository.access()
        do {
            _ = try await repository.performMutation(.addToAlbum(id: 22, photos: [personal, shared]), operationID: UUID()) { _, _ in }
            XCTFail("混合来源必须遵循官方共享管理权限")
        } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
    }

    func test共享空间本人提供的相册项目可转加无需全局管理权限() async throws {
        let page = collaborationPage().replacingOccurrences(of: "\"owner_user_id\":99", with: "\"owner_user_id\":0")
        let target = collaborationAlbum(owner: 12).replacingOccurrences(of: "\"id\":21", with: "\"id\":22")
        let transport = MockHTTPTransport(responses: accessResponses(teamPermission: "entry", homeEnabled: false) + [response(page), response(page), response(target), response(emptySuccess), response(page)])
        let repository = try makeRepository(transport); _ = try await repository.access()
        let original = try await repository.photos(in: .shared, query: .album(id: 21), offset: 0, limit: 10)
        let result = try await repository.performMutation(.addToAlbum(id: 22, photos: original.items), operationID: UUID()) { _, _ in }
        XCTAssertEqual(result.state, .confirmed)
        let fields = try await transport.recordedRequests().map(decode)
        XCTAssertFalse(fields.contains { $0["api"]?.hasPrefix("SYNO.FotoTeam") == true || $0["api"]?.hasSuffix("Browse.Folder") == true })
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private let itemPage = #"{"success":true,"data":{"list":[{"id":7,"owner_user_id":12,"filename":"sample.jpg","filesize":128,"time":50,"indexed_time":60,"folder_id":9,"type":"photo","additional":{"resolution":{"width":100,"height":80},"orientation":1,"thumbnail":{"unit_id":7,"cache_key":"fixture-revision"}}}]}}"#

    private func accessResponses(teamPermission: String = "none", teamEnabled: Bool = true, homeEnabled: Bool = true, peopleEnabled: Bool = false, conceptsEnabled: Bool = false, similarEnabled: Bool = false) -> [DsmHTTPResponse] {
        [
            response(#"{"success":true,"data":{"enabled":true,"is_admin":true,"id":12}}"#),
            response("{\"success\":true,\"data\":{\"enable_home_service\":\(homeEnabled),\"enable_similar\":\(similarEnabled),\"team_space_permission\":\"\(teamPermission)\"}}"),
            response(#"{"success":true,"data":{"package_version":"1.8.2-10090"}}"#),
            response("{\"success\":true,\"data\":{\"enabled\":\(teamEnabled),\"enable_person\":\(peopleEnabled),\"enable_concept\":\(conceptsEnabled),\"enable_similar\":\(similarEnabled)}}")
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
        _ transport: any DsmHTTPTransport, profileID: UUID = UUID(),
        missingCapabilities: Bool = false, format: DsmRequestFormat = .json,
        deletionEnabled: Bool = false,
        omittedAPIs: Set<String> = [], personVersion: Int = 3, convertedPreview: Bool = false,
        previewEvents: (@Sendable () throws -> SynologyPhotosPreviewEvents)? = nil
    ) throws -> SynologyPhotosRepository {
        let names = ["Index": 1, "UserInfo": 1, "Setting.User": 1, "Setting.Wizard": 1, "Setting.Admin": 1, "Setting.TeamSpace": 1,
                     "RegeneratePreview": 1, "Browse.Timeline": 5, "Browse.Item": 6, "Browse.RecentlyAdded": 1, "Search.Search": 6,
                     "Browse.Folder": 2, "Browse.Album": 5, "Streaming": 2, "Download": 2,
                     "Browse.Similar": 1, "Browse.SimilarItem": 1, "Browse.SimilarTimeline": 1, "Browse.Category": 3, "Search.Filter": 3, "Sharing.Misc": 2, "PhotoRequest": 1,
                     "Browse.NormalAlbum": 2, "Browse.ConditionAlbum": 3, "BackgroundTask.File": 1, "BackgroundTask.Info": 1, "Upload.Item": 1, "Upload.Face": 1, "Sharing.Passphrase": 1,
                     "Browse.Person": personVersion, "Browse.Concept": 2, "Browse.Geocoding": 1, "Browse.GeneralTag": 1, "Browse.Unit": 1]
        var entries = Dictionary(uniqueKeysWithValues: names.map { suffix, version in
            let name = "SYNO.Foto." + suffix
            return (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: format))
        })
        entries["SYNO.FotoTeam.Sharing.FolderPermission"] = ApiCapability(name: "SYNO.FotoTeam.Sharing.FolderPermission", path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: format)
        entries["SYNO.FotoTeam.Sharing.FolderBatchPermission"] = ApiCapability(name: "SYNO.FotoTeam.Sharing.FolderBatchPermission", path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: format)
        for suffix in ["Index", "Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline", "Upload.Face", "Browse.Person", "Browse.Concept", "Browse.Geocoding", "RegeneratePreview", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.RecentlyAdded", "Search.Search", "Search.Filter", "Streaming", "Download", "Browse.Unit", "Upload.Item", "Browse.GeneralTag", "BackgroundTask.File"] {
            let name = "SYNO.FotoTeam." + suffix
            entries[name] = ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: names[suffix]!, requestFormat: format)
        }
        entries["SYNO.Foto.BackgroundTask.File"] = ApiCapability(name: "SYNO.Foto.BackgroundTask.File", path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .json)
        entries[DsmAPIName.desktopInitData] = ApiCapability(name: DsmAPIName.desktopInitData, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form)
        if convertedPreview {
            for name in ["SYNO.Foto.Upload.ConvertedFile", "SYNO.FotoTeam.Upload.ConvertedFile"] {
                entries[name] = ApiCapability(name: name, path: "entry.cgi", minVersion: 3, maxVersion: 3, requestFormat: .json)
            }
        }
        for api in omittedAPIs { entries.removeValue(forKey: api) }
        let capabilities = CapabilitySet(missingCapabilities ? [:] : entries)
        if let previewEvents {
            return try SynologyPhotosRepository(profile: NasProfile(id: profileID, displayName: "测试设备", host: "nas.example.invalid", port: 5001),
                capabilities: capabilities, session: AuthSession(sid: "fixture-session", synoToken: "fixture-token", did: nil, isPortalPort: false),
                transport: transport, deletionEnabled: deletionEnabled, previewEvents: previewEvents)
        }
        return try SynologyPhotosRepository(
            profile: NasProfile(id: profileID, displayName: "测试设备", host: "nas.example.invalid", port: 5001),
            capabilities: capabilities,
            session: AuthSession(sid: "fixture-session", synoToken: "fixture-token", did: nil, isPortalPort: false),
            transport: transport, deletionEnabled: deletionEnabled
        )
    }
}

/// 只暂停合成响应的交付，复现授权刷新与在途相册读取的先后关系。
private actor AlbumReadBarrierTransport: DsmBinaryHTTPTransport {
    private let base: MockHTTPTransport
    private var shouldHold = false
    private var heldMethod: String?
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    init(_ base: MockHTTPTransport) { self.base = base }
    func holdNext(method: String? = nil) { shouldHold = true; heldMethod = method }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { held?.resume(); held = nil }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.download(request, to: destinationURL, progress: progress)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await base.upload(request, from: bodyFileURL, progress: progress)
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let response = try await base.send(request)
        let fields = URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        if shouldHold && (heldMethod == nil || fields.contains { $0.name == "method" && $0.value == heldMethod }) {
            shouldHold = false
            await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
        }
        return response
    }
}

/// 合成NAS回读已上传的multipart媒体，用于断网后核对；不会发出真实网络请求。
private actor AutomaticPreviewEchoTransport: DsmBinaryHTTPTransport {
    let base: MockHTTPTransport
    let cancelUpload: Bool
    private var body = Data()
    private var reads: [URLRequest] = []
    private var uploadFile: URL?
    private var videoRead: Data?
    init(_ base: MockHTTPTransport, cancelUpload: Bool = false) { self.base = base; self.cancelUpload = cancelUpload }
    func mediaRequests() -> [URLRequest] { reads }
    func uploadedFile() -> URL? { uploadFile }
    func replaceVideoRead(with data: Data?) { videoRead = data }
    static func part(_ name: String, in body: Data) throws -> Data {
        let boundaryEnd = try XCTUnwrap(body.range(of: Data("\r\n".utf8)))
        let boundary = body[..<boundaryEnd.lowerBound]
        let field = try XCTUnwrap(body.range(of: Data("name=\"\(name)\"; filename=".utf8)))
        let start = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8), in: field.upperBound..<body.endIndex)).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\r\n".utf8) + boundary, in: start..<body.endIndex)).lowerBound
        return body.subdata(in: start..<end)
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        if request.url?.path.hasSuffix("Thumbnail/get") == true {
            reads.append(request)
            let size = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value
            let field = "thumb_" + (size ?? "").replacingOccurrences(of: "\"", with: "")
            return DsmHTTPResponse(data: try Self.part(field, in: body), statusCode: 200, headers: ["Content-Type": "image/jpeg"])
        }
        return try await base.send(request)
    }
    func download(_ request: URLRequest, to url: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        let method = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "method" }?.value
        if method == "streaming" {
            reads.append(request)
            let data = try videoRead ?? Self.part("film_h264", in: body)
            try data.write(to: url)
            return DsmHTTPResponse(data: Data(), statusCode: 200, headers: ["Content-Type": "video/mp4"])
        }
        return try await base.download(request, to: url, progress: progress)
    }
    func upload(_ request: URLRequest, from file: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        body = try Data(contentsOf: file)
        uploadFile = file
        if cancelUpload { withUnsafeCurrentTask { $0?.cancel() } }
        return try await base.upload(request, from: file, progress: progress)
    }
}

private final class PhotosUploadCheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SynologyPhotosUploadCheckpoint] = []
    var values: [SynologyPhotosUploadCheckpoint] { lock.withLock { snapshots } }
    func append(_ snapshot: SynologyPhotosUploadCheckpoint) throws { lock.withLock { snapshots.append(snapshot) } }
}

private final class PhotosAlbumCheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SynologyPhotosAlbumCheckpoint] = []
    var values: [SynologyPhotosAlbumCheckpoint] { lock.withLock { snapshots } }
    func append(_ value: SynologyPhotosAlbumCheckpoint) { lock.withLock { snapshots.append(value) } }
}

private final class PhotosDeletionCheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [SynologyPhotoDeletionCheckpoint] = []
    var values: [SynologyPhotoDeletionCheckpoint] { lock.withLock { snapshots } }
    func append(_ value: SynologyPhotoDeletionCheckpoint) { lock.withLock { snapshots.append(value) } }
}
