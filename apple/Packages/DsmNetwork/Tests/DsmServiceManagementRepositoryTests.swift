import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmServiceManagementRepositoryTests: XCTestCase {
    func test移动容器清单固定内部ContainerV1精确参数且零附属请求() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"containers":[{"id":"container-1","name":"示例容器","status":"running","image":"demo:latest"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.dockerContainer,
                DsmAPIName.dockerImage,
                DsmAPIName.dockerNetwork,
                DsmAPIName.dockerProject,
                DsmAPIName.dockerLog,
            ],
            transport: transport
        )

        let snapshot = try await repository.loadContainerInventory()

        XCTAssertEqual(snapshot.source, .internalAPI)
        XCTAssertEqual(snapshot.containers, [
            ContainerInventoryItem(
                id: "container-1",
                name: "示例容器",
                status: "running",
                image: "demo:latest"
            )
        ])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.dockerContainer)
        XCTAssertEqual(requestValue("version", in: request), "1")
        XCTAssertEqual(requestValue("method", in: request), "list")
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "-1")
        XCTAssertEqual(requestValue("type", in: request), "all")
    }

    func test移动容器清单能力缺失时零请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerLog],
            transport: transport
        )

        do {
            _ = try await repository.loadContainerInventory()
            XCTFail("Container.list v1 能力缺失时应返回不可用")
        } catch {
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func test移动容器清单只接受ContainerV1确定形状() async throws {
        let invalidPayloads = [
            #"{"success":true,"data":{"items":[]}}"#,
            #"{"success":true,"data":{"containers":{}}}"#,
            #"{"success":true,"data":{"containers":[{"container_id":"container-1","name":"示例","status":"running"}]}}"#,
            #"{"success":true,"data":{"containers":[{"id":"container-1","status":"running"}]}}"#,
            #"{"success":true,"data":{"containers":[{"id":"container-1","name":"示例"}]}}"#,
            #"{"success":true,"data":{"containers":[{"id":"container-1","name":"示例","status":"running","image":1}]}}"#,
            #"{"success":true,"data":{"containers":[{"id":"container-1","name":"一","status":"running"},{"id":"container-1","name":"二","status":"stopped"}]}}"#,
        ]

        for payload in invalidPayloads {
            let transport = MockHTTPTransport(responses: [response(payload)])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.dockerContainer],
                transport: transport
            )
            do {
                _ = try await repository.loadContainerInventory()
                XCTFail("畸形 Container.list v1 响应不得伪装成正常清单：\(payload)")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test移动容器清单允许确定空数组且只跨层传递白名单字段() async throws {
        let emptyTransport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"containers":[]}}"#)
        ])
        let emptyRepository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: emptyTransport
        )
        let emptySnapshot = try await emptyRepository.loadContainerInventory()
        XCTAssertTrue(emptySnapshot.containers.isEmpty)

        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"containers":[{"id":"container-1","name":"示例","status":"stopped","image":"demo:latest","project":"private-project","cpu":99,"memory":2048,"ports":["private"],"logs":["private"]}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let snapshot = try await repository.loadContainerInventory()

        XCTAssertEqual(snapshot.containers, [
            ContainerInventoryItem(
                id: "container-1",
                name: "示例",
                status: "stopped",
                image: "demo:latest"
            )
        ])
    }

    func test移动虚拟机清单固定公开GuestV1且不读取附属分区() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试虚拟机","status":"running","vcpu_num":2,"vram_size":2048,"vdisks":[{"vdisk_size":10240}],"autorun":1}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationAPIGuest,
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationAPIHost,
                DsmAPIName.virtualizationLog
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineInventory()

        XCTAssertEqual(snapshot.source, .official)
        XCTAssertEqual(snapshot.machines.first?.name, "测试虚拟机")
        XCTAssertEqual(snapshot.machines.first?.memoryBytes, 2_147_483_648)
        XCTAssertEqual(snapshot.machines.first?.storageBytes, 10_737_418_240)
        XCTAssertEqual(snapshot.machines.first?.autoStart, true)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.virtualizationAPIGuest)
        XCTAssertEqual(requestValue("version", in: request), "1")
        XCTAssertEqual(requestValue("method", in: request), "list")
    }

    func test移动虚拟机公开清单能力缺失时零请求且不降级内部接口() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationGuest],
            transport: transport
        )

        do {
            _ = try await repository.loadVirtualMachineInventory()
            XCTFail("公开 Guest 能力缺失时应返回不可用")
        } catch {
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func test移动虚拟机公开清单只接受GuestV1确定形状() async throws {
        let invalidPayloads = [
            #"{"success":true,"data":{"vms":[]}}"#,
            #"{"success":true,"data":{"guests":{}}}"#,
            #"{"success":true,"data":{"guests":[{"vm_id":"vm-1","guest_name":"测试","status":"running","autorun":1}]}}"#,
            #"{"success":true,"data":{"guests":[{"guest_id":"vm-1","status":"running","autorun":1}]}}"#,
            #"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试","status":"running"}]}}"#,
            #"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"一","status":"running","autorun":1},{"guest_id":"vm-1","guest_name":"二","status":"stopped","autorun":0}]}}"#,
        ]

        for payload in invalidPayloads {
            let transport = MockHTTPTransport(responses: [response(payload)])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.virtualizationAPIGuest],
                transport: transport
            )
            do {
                _ = try await repository.loadVirtualMachineInventory()
                XCTFail("畸形 Guest v1 响应不得伪装成正常清单：\(payload)")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test移动虚拟机公开清单允许确定空数组且忽略白名单外字段() async throws {
        let emptyTransport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[]}}"#)
        ])
        let emptyRepository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: emptyTransport
        )
        let emptySnapshot = try await emptyRepository.loadVirtualMachineInventory()
        XCTAssertTrue(emptySnapshot.machines.isEmpty)

        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试","status":"running","vcpu_num":2,"vram_size":1024,"vdisks":[{"vdisk_size":2048}],"autorun":true,"host_id":"private-host","ip":"192.0.2.1","description":"must-not-cross","logs":["must-not-cross"]}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )
        let snapshot = try await repository.loadVirtualMachineInventory()
        XCTAssertEqual(snapshot.machines, [
            VirtualMachineInventoryItem(
                id: "vm-1",
                name: "测试",
                status: "running",
                cpuCount: 2,
                memoryBytes: 1_073_741_824,
                storageBytes: 2_147_483_648,
                autoStart: true
            )
        ])
    }

    func test移动虚拟机公开清单拒绝容量溢出() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试","status":"running","vram_size":9223372036854775807,"autorun":1}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )
        do {
            _ = try await repository.loadVirtualMachineInventory()
            XCTFail("溢出容量不得进入清单")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .invalidResponse)
        }
    }

    func test优先使用官方下载接口并解析任务进度() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tasks":[{"id":"task-1","title":"示例任务","status":"downloading","size":1000,"additional":{"detail":{"destination":"video"},"transfer":{"size_downloaded":400,"speed_download":20,"speed_upload":2}}}]}}"#),
            response(#"{"success":true,"data":{"speed_download":20,"speed_upload":2}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.downloadStationTask,
                DsmAPIName.downloadStationStatistic
            ],
            transport: transport
        )

        let snapshot = try await repository.loadDownloadStation()

        XCTAssertEqual(snapshot.source, .official)
        XCTAssertEqual(snapshot.tasks.first?.title, "示例任务")
        XCTAssertEqual(snapshot.tasks.first?.progress, 0.4)
        XCTAssertEqual(snapshot.downloadBytesPerSecond, 20)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("api", in: requests[0]), DsmAPIName.downloadStationTask)
        XCTAssertFalse(
            requests.contains {
                $0.url?.absoluteString.contains("REDACTED_SESSION") == true
            }
        )
    }

    func test公开接口缺失时隔离使用DownloadStation2() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tasks":[{"task_id":"task-2","name":"内部适配任务","state":"paused","total_size":500,"completed":250}]}}"#),
            response(#"{"success":true,"data":{"download_rate":0,"upload_rate":0}}"#),
            response(#"{"success":true,"data":{"path":"downloads"}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.downloadStation2Task,
                DsmAPIName.downloadStation2Statistic,
                DsmAPIName.downloadStation2Location
            ],
            transport: transport
        )

        let snapshot = try await repository.loadDownloadStation()

        XCTAssertEqual(snapshot.source, .internalAPI)
        XCTAssertEqual(snapshot.tasks.first?.status, "paused")
        XCTAssertEqual(snapshot.defaultDestination, "downloads")
    }

    func test暂停任务只提交所选标识且凭据不进入地址() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        try await repository.controlDownloadTasks(ids: ["task-2", "task-1"], action: .pause)

        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(requestValue("method", in: request), "pause")
        XCTAssertEqual(requestValue("id", in: request), "task-1,task-2")
        XCTAssertFalse(request.url?.absoluteString.contains("REDACTED_SESSION") == true)
    }

    func test单任务暂停继续固定官方V1且必须回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            downloadTaskListResponse(id: "task-1", status: "downloading"),
            response(#"{"success":true}"#),
            downloadTaskListResponse(id: "task-1", status: "paused"),
            downloadTaskListResponse(id: "task-1", status: "paused"),
            response(#"{"success":true}"#),
            downloadTaskListResponse(id: "task-1", status: "downloading"),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.downloadStationTask,
                DsmAPIName.downloadStation2Task,
            ],
            transport: transport
        )

        let pause = try await repository.controlDownloadTaskResult(
            DownloadTaskControlRequest(
                task: downloadTask(id: "task-1", status: "downloading"),
                action: .pause
            )
        )
        let resume = try await repository.controlDownloadTaskResult(
            DownloadTaskControlRequest(
                task: downloadTask(id: "task-1", status: "paused"),
                action: .resume
            )
        )

        XCTAssertEqual(pause.result.status, .confirmedSuccess)
        XCTAssertEqual(pause.task?.status, "paused")
        XCTAssertEqual(resume.result.status, .confirmedSuccess)
        XCTAssertEqual(resume.task?.status, "downloading")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, [
            "list", "pause", "list", "list", "resume", "list"
        ])
        XCTAssertTrue(requests.allSatisfy {
            requestValue("api", in: $0) == DsmAPIName.downloadStationTask
                && requestValue("version", in: $0) == "1"
        })
        XCTAssertFalse(requests.contains {
            requestValue("api", in: $0) == DsmAPIName.downloadStation2Task
        })
    }

    func test单任务控制状态漂移时返回冲突且零提交() async throws {
        let transport = MockHTTPTransport(responses: [
            downloadTaskListResponse(id: "task-1", status: "paused"),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        let result = try await repository.controlDownloadTaskResult(
            DownloadTaskControlRequest(
                task: downloadTask(id: "task-1", status: "downloading"),
                action: .pause
            )
        )

        XCTAssertEqual(result.result.status, .confirmedFailure)
        XCTAssertEqual(result.result.errorCategory, .conflict)
        XCTAssertFalse(result.result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["list"])
    }

    func test单任务控制提交后取消会保存核对且第二次只回读() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(downloadTaskListResponse(id: "task-1", status: "downloading")),
            .waitUntilCancelled,
            .response(downloadTaskListResponse(id: "task-1", status: "downloading")),
            .response(downloadTaskListResponse(id: "task-1", status: "paused")),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let controlledTask = downloadTask(id: "task-1", status: "downloading")
        let first = Task {
            try await repository.controlDownloadTaskResult(
                DownloadTaskControlRequest(
                    task: controlledTask,
                    action: .pause
                )
            )
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        first.cancel()
        let cancelled = try await first.value
        let replay = try await repository.controlDownloadTaskResult(
            DownloadTaskControlRequest(
                task: controlledTask,
                action: .pause
            )
        )

        XCTAssertEqual(cancelled.result.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.result.requiresRefresh)
        XCTAssertEqual(replay.result.status, .confirmedSuccess)
        XCTAssertEqual(replay.task?.status, "paused")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "pause" }.count,
            1
        )
    }

    func test拒绝不支持的下载链接且不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        do {
            try await repository.createDownloadTask(
                uri: "file:///Users/example/private.torrent",
                destination: nil
            )
            XCTFail("本地文件地址不应被发送到 NAS")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .conflict)
        }
        let recordedRequests = await transport.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func test上传种子文件使用官方任务接口且凭据不进入地址() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-task-\(UUID().uuidString).torrent")
        try Data("d4:infod4:name4:testee".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await repository.createDownloadTask(
            fileURL: fileURL,
            destination: "downloads",
            unzipPassword: "example"
        )

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.downloadStationTask)
        XCTAssertEqual(requestValue("method", in: request), "create")
        XCTAssertNil(requestValue("unzip_password", in: request))
        XCTAssertFalse(request.url?.absoluteString.contains("REDACTED_SESSION") == true)
        let bodies = await transport.recordedUploadBodies()
        let body = try XCTUnwrap(bodies.first)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("name=\"destination\"\r\n\r\ndownloads"))
        XCTAssertTrue(bodyText.contains("name=\"unzip_password\"\r\n\r\nexample"))
        XCTAssertTrue(bodyText.contains("name=\"file\""))
        XCTAssertTrue(bodyText.contains(fileURL.lastPathComponent))
    }

    func test保存下载设置后回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(
                #"{"success":true,"data":{"default_destination":"downloads","emule_enabled":false,"unzip_service_enabled":true,"bt_max_download":500,"bt_max_upload":100,"http_max_download":200,"ftp_max_download":200,"nzb_max_download":300,"emule_max_download":0,"emule_max_upload":0}}"#
            ),
            response(#"{"success":true,"data":{"enabled":true,"emule_enabled":false}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.downloadStationInfo,
                DsmAPIName.downloadStationSchedule
            ],
            transport: transport
        )
        let settings = DownloadStationSettings(
            defaultDestination: "downloads",
            isEMuleEnabled: false,
            isAutoExtractEnabled: true,
            btDownloadLimit: 500,
            btUploadLimit: 100,
            httpDownloadLimit: 200,
            ftpDownloadLimit: 200,
            nzbDownloadLimit: 300,
            emuleDownloadLimit: 0,
            emuleUploadLimit: 0,
            isScheduleEnabled: true,
            isEMuleScheduleEnabled: false
        )

        try await repository.saveDownloadStationSettings(settings)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requestValue("method", in: requests[0]), "setserverconfig")
        XCTAssertEqual(requestValue("bt_max_download", in: requests[0]), "500")
        XCTAssertEqual(requestValue("method", in: requests[1]), "setconfig")
        XCTAssertEqual(requestValue("enabled", in: requests[1]), "true")
        XCTAssertEqual(requestValue("method", in: requests[2]), "getconfig")
        XCTAssertEqual(requestValue("method", in: requests[3]), "getconfig")
    }

    func test下载任务删除回读确认并保留删除数据选项() async throws {
        let task = #"{"id":"task-1","title":"示例任务","status":"paused"}"#
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tasks":[\#(task)]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"tasks":[]}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        let result = try await repository.deleteDownloadTasksResult(
            ids: ["task-1"],
            removeData: true
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        let requests = await transport.recordedRequests()
        let deletion = try XCTUnwrap(requests.first {
            requestValue("method", in: $0) == "delete"
        })
        XCTAssertEqual(requestValue("id", in: deletion), "task-1")
        XCTAssertEqual(requestValue("force_complete", in: deletion), "true")
    }

    func test下载任务删除提交超时返回未确认且不自动重放() async throws {
        let task = #"{"id":"task-1","title":"示例任务","status":"paused"}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"tasks":[\#(task)]}}"#)),
            .urlError(.timedOut),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        let result = try await repository.deleteDownloadTasksResult(
            ids: ["task-1"],
            removeData: false
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.errorCategory, .network)
        XCTAssertTrue(result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func test下载任务删除回读失败时要求刷新() async throws {
        let task = #"{"id":"task-1","title":"示例任务","status":"paused"}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"tasks":[\#(task)]}}"#)),
            .response(response(#"{"success":true}"#)),
            .urlError(.networkConnectionLost),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        let result = try await repository.deleteDownloadTasksResult(
            ids: ["task-1"],
            removeData: false
        )

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertTrue(result.requiresRefresh)
    }

    func test下载任务删除被明确拒绝时返回权限不足() async throws {
        let task = #"{"id":"task-1","title":"示例任务","status":"paused"}"#
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tasks":[\#(task)]}}"#),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )

        let result = try await repository.deleteDownloadTasksResult(
            ids: ["task-1"],
            removeData: false
        )

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.errorCategory, .permission)
        XCTAssertTrue(result.submitted)
    }

    func test下载任务删除拒绝重复提交并区分提交后取消() async throws {
        let task = #"{"id":"task-1","title":"示例任务","status":"paused"}"#
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"tasks":[\#(task)]}}"#)),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let firstTask = Task {
            try await repository.deleteDownloadTasksResult(
                ids: ["task-1"],
                removeData: false
            )
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.deleteDownloadTasksResult(
            ids: ["task-1"],
            removeData: false
        )
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test下载任务删除提交前取消时不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.deleteDownloadTasksResult(
                ids: ["task-1"],
                removeData: false
            )
        }

        let result = try await task.value

        XCTAssertEqual(result.status, .cancelledBeforeSubmission)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test容器列表按DSM契约提交分页参数且附属能力缺失不影响主列表() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"containers":[{"id":"container-1","name":"示例容器","image":"demo:latest","status":"running"}],"offset":0,"limit":-1,"total":1}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let snapshot = try await repository.loadContainerManager()

        XCTAssertEqual(snapshot.containers.first?.name, "示例容器")
        XCTAssertTrue(snapshot.images.isEmpty)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "-1")
        XCTAssertEqual(requestValue("type", in: request), "all")
    }

    func test容器删除回读确认后返回成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(containerListResponse(ids: ["container-1"])),
            response(#"{"success":true}"#),
            response(containerListResponse(ids: [])),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let result = try await repository.deleteContainersResult(ids: ["container-1"])

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertFalse(result.requiresRefresh)
    }

    func test容器批量删除回读不一致时返回部分成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(containerListResponse(ids: ["container-1", "container-2"])),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(containerListResponse(ids: ["container-2"])),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let result = try await repository.deleteContainersResult(
            ids: ["container-2", "container-1"]
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertTrue(result.requiresRefresh)
    }

    func test容器删除提交时断网返回未确认且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(containerListResponse(ids: ["container-1"]))),
            .urlError(.networkConnectionLost),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let result = try await repository.deleteContainersResult(ids: ["container-1"])

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.errorCategory, .network)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func test容器删除回读失败时要求刷新且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(containerListResponse(ids: ["container-1"]))),
            .response(response(#"{"success":true}"#)),
            .urlError(.timedOut),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let result = try await repository.deleteContainersResult(ids: ["container-1"])

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func test容器删除被明确拒绝时返回权限不足() async throws {
        let transport = MockHTTPTransport(responses: [
            response(containerListResponse(ids: ["container-1"])),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        let result = try await repository.deleteContainersResult(ids: ["container-1"])

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.errorCategory, .permission)
        XCTAssertTrue(result.submitted)
        XCTAssertEqual(result.counts.failed, 1)
    }

    func test容器删除拒绝同目标重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(containerListResponse(ids: ["container-1"]))),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )
        let firstTask = Task {
            try await repository.deleteContainersResult(ids: ["container-1"])
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.deleteContainersResult(ids: ["container-1"])
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test镜像仓库搜索按DSM契约提交参数并解析结果() async throws {
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"data":[{"name":"nginx","registry":"docker.io","description":"Web server","star_count":100,"is_official":true,"is_automated":false,"is_trusted":true}],"offset":0,"limit":50,"page_size":50,"total":1}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerRegistry],
            requestFormatOverrides: [DsmAPIName.dockerRegistry: .json],
            transport: transport
        )

        let images = try await repository.searchContainerImages(query: "nginx")

        XCTAssertEqual(images.first?.name, "nginx")
        XCTAssertEqual(images.first?.registry, "docker.io")
        XCTAssertEqual(images.first?.starCount, 100)
        XCTAssertEqual(images.first?.isOfficial, true)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.dockerRegistry)
        XCTAssertEqual(requestValue("method", in: request), "search")
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "50")
        XCTAssertEqual(requestValue("page_size", in: request), "50")
        XCTAssertEqual(requestValue("q", in: request), #""nginx""#)
    }

    func test读取镜像标签使用仓库参数并去除重复项() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":[{"tag":"latest"},{"tag":"stable"},{"tag":"latest"}]}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerRegistry],
            requestFormatOverrides: [DsmAPIName.dockerRegistry: .json],
            transport: transport
        )

        let tags = try await repository.loadContainerImageTags(repository: "nginx")

        XCTAssertEqual(tags, ["latest", "stable"])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.dockerRegistry)
        XCTAssertEqual(requestValue("method", in: request), "tags")
        XCTAssertEqual(requestValue("repo", in: request), #""nginx""#)
    }

    func test下载镜像使用已验证的启动方法且不重复提交() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerImage],
            requestFormatOverrides: [DsmAPIName.dockerImage: .json],
            transport: transport
        )

        try await repository.pullContainerImage(repository: "nginx", tag: "latest")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.dockerImage)
        XCTAssertEqual(requestValue("method", in: request), "pull_start")
        XCTAssertEqual(requestValue("repository", in: request), #""nginx""#)
        XCTAssertEqual(requestValue("tag", in: request), #""latest""#)
    }

    func test容器映像删除回读确认后返回成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [
                response(containerListResponse(ids: [])),
                response(containerListResponse(ids: [])),
            ],
            DsmAPIName.dockerImage: [
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-1","repository":"demo","tag":"latest"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(#"{"success":true,"data":{"images":[]}}"#),
            ],
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.dockerContainer,
                DsmAPIName.dockerImage,
            ],
            transport: transport
        )

        let result = try await repository.deleteContainerImagesResult(
            ids: ["image-1"]
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "containerImageDelete")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter {
                requestValue("api", in: $0) == DsmAPIName.dockerImage
                    && requestValue("method", in: $0) == "delete"
            }.count,
            1
        )
    }

    func test容器映像逐项删除被拒绝后回读为部分成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [
                response(containerListResponse(ids: [])),
                response(containerListResponse(ids: [])),
            ],
            DsmAPIName.dockerImage: [
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-1","repository":"demo","tag":"one"},{"id":"image-2","repository":"demo","tag":"two"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(#"{"success":false,"error":{"code":105}}"#),
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-2","repository":"demo","tag":"two"}]}}"#
                ),
            ],
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.dockerContainer,
                DsmAPIName.dockerImage,
            ],
            transport: transport
        )

        let result = try await repository.deleteContainerImagesResult(
            ids: ["image-2", "image-1"]
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertTrue(result.requiresRefresh)
    }

    func test容器网络删除回读确认后返回成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [
                response(containerListResponse(ids: [])),
                response(containerListResponse(ids: [])),
            ],
            DsmAPIName.dockerNetwork: [
                response(
                    #"{"success":true,"data":{"networks":[{"id":"network-1","name":"isolated","driver":"bridge"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(#"{"success":true,"data":{"networks":[]}}"#),
            ],
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.dockerContainer,
                DsmAPIName.dockerNetwork,
            ],
            transport: transport
        )

        let result = try await repository.deleteContainerNetworksResult(
            ids: ["network-1"]
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "containerNetworkDelete")
    }

    func test虚拟机附属面板失败时仍返回官方主列表并解析官方字段() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationAPIGuest: response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试虚拟机","status":"shutdown","vcpu_num":2,"vram_size":2048,"vdisks":[{"vdisk_size":10240}]}]}}"#),
            DsmAPIName.virtualizationAPIHost: response(#"{"success":true,"data":{"hosts":[{"host_id":"host-1","host_name":"主机","status":"running"}]}}"#),
            DsmAPIName.virtualizationAPIStorage: response(#"{"success":true,"data":{"storages":[{"storage_id":"storage-1","storage_name":"虚拟机存储","status":"online","volume_path":"/volume1"}]}}"#),
            DsmAPIName.virtualizationAPINetwork: response(#"{"success":true,"data":{"networks":[{"network_id":"network-1","network_name":"默认网络"}]}}"#),
            DsmAPIName.virtualizationAPIGuestImage: response(#"{"success":true,"data":{"images":[{"image_id":"image-1","image_name":"安装映像","type":"iso"}]}}"#),
            DsmAPIName.virtualizationLog: response(#"{"success":false,"error":{"code":402}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationAPIGuest,
                DsmAPIName.virtualizationAPIHost,
                DsmAPIName.virtualizationAPIStorage,
                DsmAPIName.virtualizationAPINetwork,
                DsmAPIName.virtualizationAPIGuestImage,
                DsmAPIName.virtualizationLog
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineManager()

        XCTAssertEqual(snapshot.source, .official)
        XCTAssertEqual(snapshot.machines.first?.name, "测试虚拟机")
        XCTAssertEqual(snapshot.machines.first?.memoryBytes, 2_147_483_648)
        XCTAssertEqual(snapshot.machines.first?.storageBytes, 10_737_418_240)
        XCTAssertEqual(snapshot.storages.first?.name, "虚拟机存储")
        XCTAssertEqual(snapshot.networks.first?.name, "默认网络")
        XCTAssertEqual(snapshot.images.first?.name, "安装映像")
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func test虚拟机官方只读列表不兼容时降级到已发现的内部列表() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationAPIGuest: response(
                #"{"success":false,"error":{"code":103}}"#
            ),
            DsmAPIName.virtualizationGuest: response(
                #"{"success":true,"data":{"guests":[{"guest_id":"vm-2","guest_name":"降级虚拟机","status":"running"}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationAPIGuest,
                DsmAPIName.virtualizationGuest
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineManager()

        XCTAssertEqual(snapshot.source, .internalAPI)
        XCTAssertEqual(snapshot.machines.first?.name, "降级虚拟机")
    }

    func test虚拟机删除回读确认后返回成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1"])),
            response(#"{"success":true}"#),
            response(virtualMachineListResponse(ids: [])),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertFalse(result.requiresRefresh)
    }

    func test虚拟机批量删除回读不一致时返回部分成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1", "vm-2"])),
            response(#"{"success":true}"#),
            response(virtualMachineListResponse(ids: ["vm-2"])),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachinesResult(
            ids: ["vm-2", "vm-1"]
        )

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertEqual(result.counts.unknown, 1)
        XCTAssertTrue(result.requiresRefresh)
    }

    func test虚拟机删除提交时断网返回未确认且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(virtualMachineListResponse(ids: ["vm-1"]))),
            .urlError(.timedOut),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertEqual(result.errorCategory, .network)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func test虚拟机删除回读失败时要求刷新且不自动重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(virtualMachineListResponse(ids: ["vm-1"]))),
            .response(response(#"{"success":true}"#)),
            .urlError(.networkConnectionLost),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])

        XCTAssertEqual(result.status, .submittedButUnverified)
        XCTAssertTrue(result.requiresRefresh)
        XCTAssertEqual(result.counts.unknown, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "delete" }.count,
            1
        )
    }

    func test虚拟机删除被明确拒绝时返回权限不足() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1"])),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.errorCategory, .permission)
        XCTAssertTrue(result.submitted)
        XCTAssertEqual(result.counts.failed, 1)
    }

    func test虚拟机删除拒绝同目标重复提交并区分提交后取消() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(virtualMachineListResponse(ids: ["vm-1"]))),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )
        let firstTask = Task {
            try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        let duplicate = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        firstTask.cancel()
        let cancelled = try await firstTask.value

        XCTAssertEqual(duplicate.status, .confirmedFailure)
        XCTAssertFalse(duplicate.submitted)
        XCTAssertEqual(duplicate.errorCategory, .conflict)
        XCTAssertEqual(cancelled.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.requiresRefresh)
    }

    func test容器和虚拟机删除提交前取消时不发送请求() async throws {
        let containerTransport = MockHTTPTransport(responses: [])
        let containerRepository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: containerTransport
        )
        let containerTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await containerRepository.deleteContainersResult(
                ids: ["container-1"]
            )
        }
        let containerResult = try await containerTask.value

        let virtualMachineTransport = MockHTTPTransport(responses: [])
        let virtualMachineRepository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: virtualMachineTransport
        )
        let virtualMachineTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await virtualMachineRepository.deleteVirtualMachinesResult(
                ids: ["vm-1"]
            )
        }
        let virtualMachineResult = try await virtualMachineTask.value

        XCTAssertEqual(containerResult.status, .cancelledBeforeSubmission)
        XCTAssertEqual(virtualMachineResult.status, .cancelledBeforeSubmission)
        let containerRequests = await containerTransport.recordedRequests()
        let virtualMachineRequests = await virtualMachineTransport.recordedRequests()
        XCTAssertTrue(containerRequests.isEmpty)
        XCTAssertTrue(virtualMachineRequests.isEmpty)
    }

    func test创建虚拟机提交已核对的内部契约并回读确认() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#),
                response(#"{"success":true,"data":{"guests":[]}}"#),
                response(#"{"success":true}"#),
                response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-new","name":"新虚拟机","status":"shutdown"}]}}"#)
            ],
            DsmAPIName.virtualizationRepo: [
                response(#"{"success":true,"data":[{"repo_id":"repo-1","repo_name":"虚拟机存储","host_id":"host-1","host_name":"主机","allocated_size":100,"size":1000}]}"#)
            ],
            DsmAPIName.virtualizationNetwork: [
                response(#"{"success":true,"data":[{"network_id":"network-1","network_name":"默认网络"}]}"#)
            ]
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationRepo,
                DsmAPIName.virtualizationNetwork
            ],
            requestFormatOverrides: [
                DsmAPIName.virtualizationGuest: .json,
                DsmAPIName.virtualizationRepo: .json,
                DsmAPIName.virtualizationNetwork: .json
            ],
            transport: transport
        )
        let initial = try await repository.loadVirtualMachineManager()
        XCTAssertEqual(initial.storages.first?.id, "repo-1")
        XCTAssertEqual(initial.networks.first?.id, "network-1")

        try await repository.createVirtualMachine(
            VirtualMachineCreation(
                name: "新虚拟机",
                operatingSystem: .linux,
                storageID: "repo-1",
                networkID: "network-1",
                cpuCount: 2,
                memoryMiB: 2_048,
                diskGiB: 20
            )
        )

        let requests = await transport.recordedRequests()
        let createRequest = try XCTUnwrap(
            requests.first(where: { requestValue("method", in: $0) == "create" })
        )
        XCTAssertEqual(requestValue("api", in: createRequest), DsmAPIName.virtualizationGuest)
        XCTAssertEqual(requestValue("name", in: createRequest), #""新虚拟机""#)
        XCTAssertEqual(requestValue("vcpu_num", in: createRequest), "2")
        XCTAssertEqual(requestValue("vram_size", in: createRequest), "2048")
        XCTAssertEqual(requestValue("repo_id", in: createRequest), #""repo-1""#)
        XCTAssertEqual(requestValue("poweron_after_create", in: createRequest), "false")
        XCTAssertFalse(createRequest.url?.absoluteString.contains("REDACTED_SESSION") == true)
    }

    func test修改虚拟机只提交变化并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"旧名称","status":"shutdown","vcpu_num":2,"vram_size":2048}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"新名称","status":"shutdown","vcpu_num":4,"vram_size":4096}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationGuest],
            requestFormatOverrides: [DsmAPIName.virtualizationGuest: .json],
            transport: transport
        )

        try await repository.updateVirtualMachine(
            id: "vm-1",
            configuration: VirtualMachineUpdate(
                name: "新名称",
                cpuCount: 4,
                memoryMiB: 4_096
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("method", in: requests[1]), "set")
        XCTAssertEqual(requestValue("guest_id", in: requests[1]), #""vm-1""#)
        XCTAssertEqual(requestValue("name", in: requests[1]), #""新名称""#)
        XCTAssertEqual(requestValue("vcpu_num", in: requests[1]), "4")
        XCTAssertEqual(requestValue("vram_size", in: requests[1]), "4096")
    }

    func test远程控制台地址不包含会话凭据并使用虚拟机通道() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"测试虚拟机","status":"running","kb_layout":"Default"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.virtualizationGuest],
            transport: transport
        )

        let session = try await repository.openVirtualMachineConsole(id: "vm-1")

        let components = try XCTUnwrap(
            URLComponents(url: session.url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(session.url.path, "/webman/3rdparty/Virtualization/noVNC/vnc.html")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "path" })?.value,
            "synovirtualization/ws/vm-1"
        )
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "_sid" }))
        XCTAssertFalse(session.url.absoluteString.contains("REDACTED_SESSION"))
    }

    func test虚拟机日志提交网页端必需参数并解析时间用户和内容() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#)
            ],
            DsmAPIName.virtualizationLog: [
                response(
                    #"{"success":true,"data":{"logs":[{"log_id":"log-1","time":"2026-07-27 17:12:45","level":"error","user":"tester","event":"虚拟机启动失败"}]}}"#
                )
            ]
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationLog
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineManager()

        XCTAssertEqual(snapshot.events.first?.id, "log-1")
        XCTAssertEqual(snapshot.events.first?.user, "tester")
        XCTAssertEqual(snapshot.events.first?.message, "虚拟机启动失败")
        XCTAssertNotNil(snapshot.events.first?.timestamp)
        XCTAssertFalse(snapshot.unavailableSections.contains(.logs))
        let logRequests = await transport.recordedRequests().filter {
            requestValue("api", in: $0) == DsmAPIName.virtualizationLog
        }
        let request = try XCTUnwrap(logRequests.first)
        XCTAssertEqual(logRequests.count, 1)
        XCTAssertEqual(requestValue("method", in: request), "list")
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "1000")
        XCTAssertEqual(requestValue("loglevel", in: request), "")
        XCTAssertEqual(requestValue("filter_content", in: request), "")
        XCTAssertEqual(requestValue("datefrom", in: request), "0")
        XCTAssertEqual(requestValue("dateto", in: request), "0")
        XCTAssertEqual(requestValue("sort_by", in: request), "time")
        XCTAssertEqual(requestValue("sort_dir", in: request), "DESC")
    }

    func test虚拟机保护同时解析计划策略和保留策略() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: response(
                #"{"success":true,"data":{"guests":[]}}"#
            ),
            DsmAPIName.virtualizationProtectionPlan: response(
                #"{"success":true,"data":{"plans":[{"id":"plan-1","plan_name":"每日保护"}],"schedule_policies":[{"id":"schedule-1","policy_name":"每天"}],"retention_policies":[{"id":"retention-1","policy_name":"保留 7 份"}]}}"#
            )
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationProtectionPlan
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineManager()

        XCTAssertEqual(snapshot.protectionPlans.first?.name, "每日保护")
        XCTAssertEqual(snapshot.protectionSchedulePolicies.first?.name, "每天")
        XCTAssertEqual(snapshot.protectionRetentionPolicies.first?.name, "保留 7 份")
        XCTAssertFalse(snapshot.unavailableSections.contains(.protection))
    }

    func test删除虚拟机映像使用公开接口并回读确认() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#)
            ],
            DsmAPIName.virtualizationAPIGuestImage: [
                response(
                    #"{"success":true,"data":{"images":[{"image_id":"image-1","image_name":"安装映像"}]}}"#
                ),
                response(#"{"success":true,"data":{"task_id":"task-1"}}"#),
                response(#"{"success":true,"data":{"images":[]}}"#)
            ]
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationAPIGuestImage
            ],
            transport: transport
        )

        try await repository.deleteVirtualMachineImages(ids: ["image-1"])

        let requests = await transport.recordedRequests()
        let deletion = try XCTUnwrap(requests.first {
            requestValue("api", in: $0) == DsmAPIName.virtualizationAPIGuestImage
                && requestValue("method", in: $0) == "delete"
        })
        XCTAssertEqual(requestValue("image_id", in: deletion), "image-1")
    }

    func test虚拟机映像统一删除结果回读确认后返回成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#),
                response(#"{"success":true,"data":{"guests":[]}}"#),
            ],
            DsmAPIName.virtualizationAPIGuestImage: [
                response(
                    #"{"success":true,"data":{"images":[{"image_id":"image-1","image_name":"安装映像"}]}}"#
                ),
                response(#"{"success":true,"data":{}}"#),
                response(#"{"success":true,"data":{"images":[]}}"#),
            ],
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationAPIGuestImage,
            ],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachineImagesResult(
            ids: ["image-1"]
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "virtualMachineImageDelete")
    }

    func test修改虚拟机网络使用内部接口并回读确认() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#)
            ],
            DsmAPIName.virtualizationNetwork: [
                response(
                    #"{"success":true,"data":{"networks":[{"network_id":"network-1","network_name":"旧名称"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(
                    #"{"success":true,"data":{"networks":[{"network_id":"network-1","network_name":"新名称"}]}}"#
                )
            ]
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationNetwork
            ],
            requestFormatOverrides: [DsmAPIName.virtualizationNetwork: .json],
            transport: transport
        )

        try await repository.updateVirtualMachineNetwork(
            id: "network-1",
            configuration: VirtualMachineNetworkUpdate(name: "新名称")
        )

        let requests = await transport.recordedRequests()
        let update = try XCTUnwrap(requests.first {
            requestValue("api", in: $0) == DsmAPIName.virtualizationNetwork
                && requestValue("method", in: $0) == "set"
        })
        XCTAssertEqual(requestValue("network_id", in: update), #""network-1""#)
        XCTAssertEqual(requestValue("name", in: update), #""新名称""#)
    }

    func test删除虚拟机网络使用内部接口并回读确认() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#)
            ],
            DsmAPIName.virtualizationNetwork: [
                response(
                    #"{"success":true,"data":{"networks":[{"network_id":"network-1","network_name":"待删除网络"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(#"{"success":true,"data":{"networks":[]}}"#)
            ]
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationNetwork
            ],
            requestFormatOverrides: [DsmAPIName.virtualizationNetwork: .json],
            transport: transport
        )

        try await repository.deleteVirtualMachineNetworks(ids: ["network-1"])

        let requests = await transport.recordedRequests()
        let deletion = try XCTUnwrap(requests.first {
            requestValue("api", in: $0) == DsmAPIName.virtualizationNetwork
                && requestValue("method", in: $0) == "delete"
        })
        XCTAssertEqual(requestValue("network_id", in: deletion), #""network-1""#)
    }

    func test虚拟机网络统一删除结果回读确认后返回成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationGuest: [
                response(#"{"success":true,"data":{"guests":[]}}"#),
                response(#"{"success":true,"data":{"guests":[]}}"#),
            ],
            DsmAPIName.virtualizationNetwork: [
                response(
                    #"{"success":true,"data":{"networks":[{"network_id":"network-1","network_name":"待删除网络"}]}}"#
                ),
                response(#"{"success":true}"#),
                response(#"{"success":true,"data":{"networks":[]}}"#),
            ],
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationGuest,
                DsmAPIName.virtualizationNetwork,
            ],
            requestFormatOverrides: [DsmAPIName.virtualizationNetwork: .json],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachineNetworksResult(
            ids: ["network-1"]
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "virtualMachineNetworkDelete")
    }

    private func makeRepository(
        apiNames: [String],
        requestFormatOverrides: [String: DsmRequestFormat] = [:],
        transport: any DsmHTTPTransport
    ) throws -> DsmServiceManagementRepository {
        let capabilities = Dictionary(uniqueKeysWithValues: apiNames.map { name in
            (
                name,
                ApiCapability(
                    name: name,
                    path: "entry.cgi",
                    minVersion: 1,
                    maxVersion: 2,
                    requestFormat: requestFormatOverrides[name] ?? .form,
                    selectedVersion: name.contains("DownloadStation2") ? 2 : 1
                )
            )
        })
        return try DsmServiceManagementRepository(
            profile: NasProfile(
                displayName: "测试设备",
                host: "nas.example.invalid",
                port: 5_001
            ),
            capabilities: CapabilitySet(capabilities),
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_SESSION",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func response(_ json: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(json.utf8), statusCode: 200)
    }

    private func downloadTask(id: String, status: String) -> DownloadStationTask {
        DownloadStationTask(id: id, title: "示例任务", status: status)
    }

    private func downloadTaskListResponse(id: String, status: String) -> DsmHTTPResponse {
        response(
            #"{"success":true,"data":{"tasks":[{"id":"\#(id)","title":"示例任务","status":"\#(status)"}],"offset":0,"total":1}}"#
        )
    }

    private func containerListResponse(ids: [String]) -> String {
        let containers = ids.map {
            #"{"id":"\#($0)","name":"\#($0)","image":"demo:latest","status":"stopped"}"#
        }.joined(separator: ",")
        return #"{"success":true,"data":{"containers":[\#(containers)]}}"#
    }

    private func virtualMachineListResponse(ids: [String]) -> String {
        let machines = ids.map {
            #"{"guest_id":"\#($0)","guest_name":"\#($0)","status":"shutdown"}"#
        }.joined(separator: ",")
        return #"{"success":true,"data":{"guests":[\#(machines)]}}"#
    }

    private func requestValue(_ name: String, in request: URLRequest) -> String? {
        if let url = request.url,
           let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value {
            return value
        }
        guard let body = request.httpBody,
              let fields = String(data: body, encoding: .utf8) else {
            return nil
        }
        return URLComponents(string: "https://example.invalid/?\(fields)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

private actor ServiceRoutingTransport: DsmHTTPTransport {
    private let responses: [String: DsmHTTPResponse]

    init(responses: [String: DsmHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        guard let body = request.httpBody,
              let fields = String(data: body, encoding: .utf8),
              let api = URLComponents(string: "https://example.invalid/?\(fields)")?
                .queryItems?
                .first(where: { $0.name == "api" })?
                .value,
              let response = responses[api] else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}

private actor SequencedServiceRoutingTransport: DsmHTTPTransport {
    private var responses: [String: [DsmHTTPResponse]]
    private var requests: [URLRequest] = []

    init(responses: [String: [DsmHTTPResponse]]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        guard let body = request.httpBody,
              let fields = String(data: body, encoding: .utf8),
              let api = URLComponents(string: "https://example.invalid/?\(fields)")?
                .queryItems?
                .first(where: { $0.name == "api" })?
                .value,
              var values = responses[api],
              let response = values.first else {
            throw URLError(.badServerResponse)
        }
        if values.count > 1 {
            values.removeFirst()
            responses[api] = values
        }
        return response
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
