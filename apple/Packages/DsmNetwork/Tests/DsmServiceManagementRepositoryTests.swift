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
        XCTAssertEqual(snapshot.machines.first?.startupBehavior, .restorePreviousState)
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
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试","status":"running","vcpu_num":2,"vram_size":1024,"vdisks":[{"vdisk_size":2048}],"autorun":2,"host_id":"private-host","ip":"192.0.2.1","description":"must-not-cross","logs":["must-not-cross"]}]}}"#)
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
                startupBehavior: .powerOn
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
            response(#"{"success":true,"data":{"speed_download":20,"speed_upload":2,"emule_speed_download":7,"emule_speed_upload":3}}"#)
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
        XCTAssertTrue(snapshot.hasActivitySummary)
        XCTAssertEqual(snapshot.downloadBytesPerSecond, 20)
        XCTAssertEqual(snapshot.uploadBytesPerSecond, 2)
        XCTAssertEqual(snapshot.emuleDownloadBytesPerSecond, 7)
        XCTAssertEqual(snapshot.emuleUploadBytesPerSecond, 3)
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
        XCTAssertFalse(snapshot.hasBTSearch)
    }

    func testBT搜索目录固定公开V1并解析提供方和类别() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"modules":[{"id":"provider-a","title":"Provider A","enabled":true},{"id":"provider-b","title":"Provider B","enabled":false}]}}"#),
            response(#"{"success":true,"data":{"categories":[{"id":"_allcat_","title":"All"},{"id":"Books","title":"Books"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationBTSearch],
            transport: transport
        )

        let catalog = try await repository.loadDownloadBTSearchCatalog()

        XCTAssertEqual(catalog.modules.map(\.id), ["provider-a", "provider-b"])
        XCTAssertEqual(catalog.modules.map(\.isEnabled), [true, false])
        XCTAssertEqual(catalog.categories.map(\.id), ["_allcat_", "Books"])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["getModule", "getCategory"])
        XCTAssertTrue(requests.allSatisfy {
            requestValue("api", in: $0) == DsmAPIName.downloadStationBTSearch &&
                requestValue("version", in: $0) == "1"
        })
    }

    func testBT搜索目录拒绝重复和畸形标识() async throws {
        let payloads = [
            [
                #"{"success":true,"data":{"modules":[{"id":"provider-a","title":"A","enabled":true},{"id":"provider-a","title":"B","enabled":false}]}}"#,
                #"{"success":true,"data":{"categories":[]}}"#
            ],
            [
                #"{"success":true,"data":{"modules":[{"id":"provider,a","title":"A","enabled":true}]}}"#,
                #"{"success":true,"data":{"categories":[]}}"#
            ],
            [
                #"{"success":true,"data":{"modules":[{"id":"provider-a","title":"A","enabled":"true"}]}}"#,
                #"{"success":true,"data":{"categories":[]}}"#
            ]
        ]

        for payload in payloads {
            let transport = MockHTTPTransport(responses: payload.map(response))
            let repository = try makeRepository(
                apiNames: [DsmAPIName.downloadStationBTSearch],
                transport: transport
            )
            do {
                _ = try await repository.loadDownloadBTSearchCatalog()
                XCTFail("畸形 BT 搜索目录不得伪装成正常目录：\(payload)")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func testBT搜索发送筛选排序并在完成后清理任务() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"taskid":"search-1"}}"#),
            response(#"{"success":true,"data":{"finished":true,"items":[{"title":"Linux Guide","size":1234,"date":"2026-08-01","download_uri":"magnet:?xt=urn:btih:synthetic","external_link":"https://example.invalid/item","peers":10,"seeds":20,"leechs":3,"module_title":"Provider A"}]}}"#),
            response(#"{"success":true,"data":{}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationBTSearch],
            transport: transport
        )

        let results = try await repository.searchDownloadBT(
            DownloadBTSearchRequest(
                keyword: "  linux  ",
                moduleScope: .selected(["provider-b", "provider-a"]),
                categoryID: "Books",
                sort: .size,
                direction: .ascending,
                titleFilter: "  guide  "
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Linux Guide")
        XCTAssertEqual(results.first?.sizeBytes, 1234)
        XCTAssertEqual(results.first?.downloadURI, "magnet:?xt=urn:btih:synthetic")
        XCTAssertEqual(results.first?.seeds, 20)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["start", "list", "clean"])
        XCTAssertEqual(requestValue("keyword", in: requests[0]), "linux")
        XCTAssertEqual(requestValue("module", in: requests[0]), "provider-a,provider-b")
        XCTAssertEqual(requestValue("filter_category", in: requests[1]), "Books")
        XCTAssertEqual(requestValue("filter_title", in: requests[1]), "guide")
        XCTAssertEqual(requestValue("sort_by", in: requests[1]), "size")
        XCTAssertEqual(requestValue("sort_direction", in: requests[1]), "asc")
        XCTAssertEqual(requestValue("taskid", in: requests[2]), "search-1")
    }

    func testBT搜索非法输入零请求且畸形结果或读取失败仍清理任务() async throws {
        let invalidTransport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationBTSearch],
            transport: invalidTransport
        )
        for (request, reason) in [
            (
                DownloadBTSearchRequest(keyword: "linux", moduleScope: .selected([])),
                "空提供方选择"
            ),
            (DownloadBTSearchRequest(keyword: "\nlinux"), "首部控制字符"),
            (
                DownloadBTSearchRequest(keyword: "linux", titleFilter: "guide\t"),
                "尾部控制字符"
            ),
        ] {
            do {
                _ = try await repository.searchDownloadBT(request)
                XCTFail("\(reason)不应发送请求")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .conflict)
            }
        }
        let invalidRequests = await invalidTransport.recordedRequests()
        XCTAssertTrue(invalidRequests.isEmpty)

        let oversizedItems = (0...200).map { index in
            #"{"download_uri":"magnet:?xt=urn:btih:synthetic-\#(index)"}"#
        }.joined(separator: ",")
        let malformedResults = [
            (
                #"{"success":true,"data":{"finished":true,"items":[\#(oversizedItems)]}}"#,
                "超过 200 条的响应"
            ),
            (
                #"{"success":true,"data":{"finished":true,"items":[{"download_uri":"magnet:?xt=urn:btih:synthetic-max","size":9223372036854775807}]}}"#,
                "无法由 Double 精确表达的 Int64 上边界"
            ),
            (
                #"{"success":true,"data":{"finished":true,"items":[{"download_uri":"magnet:?xt=urn:btih:synthetic-overflow","size":9223372036854775808}]}}"#,
                "超过 Int64 的数值"
            ),
        ]
        for (payload, reason) in malformedResults {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"taskid":"search-malformed"}}"#),
                response(payload),
                response(#"{"success":true,"data":{}}"#),
            ])
            let repository = try makeRepository(
                apiNames: [DsmAPIName.downloadStationBTSearch],
                transport: transport
            )
            do {
                _ = try await repository.searchDownloadBT(
                    DownloadBTSearchRequest(keyword: "linux")
                )
                XCTFail("\(reason)不得伪装成正常搜索结果")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(
                requests.map { requestValue("method", in: $0) },
                ["start", "list", "clean"],
                "\(reason)仍须恰好清理一次临时任务"
            )
        }

        let failingTransport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"taskid":"search-2"}}"#)),
            .urlError(.timedOut),
            .response(response(#"{"success":true,"data":{}}"#))
        ])
        let failingRepository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationBTSearch],
            transport: failingTransport
        )
        do {
            _ = try await failingRepository.searchDownloadBT(DownloadBTSearchRequest(keyword: "linux"))
            XCTFail("列表读取失败应抛错")
        } catch {}
        let requests = await failingTransport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["start", "list", "clean"])
    }

    func testBT搜索取消后使用独立请求清理远端任务() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(#"{"success":true,"data":{"taskid":"search-cancelled"}}"#)),
            .waitUntilCancelled,
            .response(response(#"{"success":true,"data":{}}"#))
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationBTSearch],
            transport: transport
        )
        let searchTask = Task {
            try await repository.searchDownloadBT(DownloadBTSearchRequest(keyword: "linux"))
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        searchTask.cancel()
        do {
            _ = try await searchTask.value
            XCTFail("取消搜索后不得返回结果")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .cancelled)
        } catch {
            XCTFail("取消搜索应返回可识别的取消错误：\(type(of: error))")
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["start", "list", "clean"])
        XCTAssertEqual(requestValue("taskid", in: requests[2]), "search-cancelled")
        let cancellationStates = await transport.recordedRequestCancellationStates()
        XCTAssertEqual(cancellationStates, [false, false, false])
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

    func test指定目录链接使用官方V2且必须回读稳定任务ID() async throws {
        let transport = MockHTTPTransport(responses: [
            downloadTaskListResponse(ids: []),
            response(#"{"success":true,"data":{"taskid":"task-1"}}"#),
            downloadTaskListResponse(
                ids: ["task-1"],
                destination: "downloads"
            ),
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.downloadStationTask,
                DsmAPIName.downloadStation2Task,
            ],
            transport: transport
        )

        let outcome = try await repository.createDownloadTaskResult(
            DownloadTaskCreateRequest(
                uri: "https://example.invalid/synthetic.iso",
                destination: "downloads"
            )
        )

        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        XCTAssertEqual(outcome.result.operation, "downloadCreate")
        XCTAssertEqual(outcome.taskID, "task-1")
        XCTAssertEqual(outcome.task?.destination, "downloads")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, [
            "list", "create", "list"
        ])
        let create = try XCTUnwrap(requests.first {
            requestValue("method", in: $0) == "create"
        })
        XCTAssertEqual(requestValue("api", in: create), DsmAPIName.downloadStationTask)
        XCTAssertEqual(requestValue("version", in: create), "2")
        XCTAssertEqual(requestValue("uri", in: create), "https://example.invalid/synthetic.iso")
        XCTAssertEqual(requestValue("destination", in: create), "downloads")
        XCTAssertFalse(requests.contains {
            requestValue("api", in: $0) == DsmAPIName.downloadStation2Task
        })
    }

    func test链接创建提交后取消会阻止同请求重放() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(downloadTaskListResponse(ids: [])),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let request = DownloadTaskCreateRequest(
            uri: "magnet:?xt=urn:btih:synthetic",
            destination: nil
        )
        let first = Task {
            try await repository.createDownloadTaskResult(request)
        }
        while await transport.recordedRequests().count < 2 {
            await Task.yield()
        }

        first.cancel()
        let cancelled = try await first.value
        let replay = try await repository.createDownloadTaskResult(request)

        XCTAssertEqual(cancelled.result.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(cancelled.result.requiresRefresh)
        XCTAssertEqual(replay.result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "create" }.count,
            1
        )
    }

    func test链接创建响应缺少任务ID后第二次零提交() async throws {
        let transport = MockHTTPTransport(responses: [
            downloadTaskListResponse(ids: []),
            response(#"{"success":true,"data":{}}"#),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let request = DownloadTaskCreateRequest(
            uri: "https://example.invalid/synthetic.iso",
            destination: nil
        )

        let first = try await repository.createDownloadTaskResult(request)
        let second = try await repository.createDownloadTaskResult(request)

        XCTAssertEqual(first.result.status, .submittedButUnverified)
        XCTAssertEqual(second.result.status, .submittedButUnverified)
        XCTAssertTrue(first.result.requiresRefresh)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.filter { requestValue("method", in: $0) == "create" }.count,
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
            unzipPassword: "  example  "
        )

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.downloadStationTask)
        XCTAssertEqual(requestValue("method", in: request), "create")
        XCTAssertEqual(requestValue("version", in: request), "2")
        XCTAssertNil(requestValue("unzip_password", in: request))
        XCTAssertFalse(request.url?.absoluteString.contains("REDACTED_SESSION") == true)
        let bodies = await transport.recordedUploadBodies()
        let body = try XCTUnwrap(bodies.first)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("name=\"destination\"\r\n\r\ndownloads"))
        XCTAssertTrue(bodyText.contains("name=\"unzip_password\"\r\n\r\n  example  \r\n"))
        XCTAssertTrue(bodyText.contains("name=\"file\""))
        XCTAssertTrue(bodyText.contains(fileURL.lastPathComponent))
    }

    func test上传种子响应超限映射为安全错误() async throws {
        let transport = MockHTTPTransport(steps: [.responseTooLarge])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-task-\(UUID().uuidString).torrent")
        try Data("d4:infod4:name4:testee".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            try await repository.createDownloadTask(
                fileURL: fileURL,
                destination: "downloads",
                unzipPassword: nil
            )
            XCTFail("超限响应不应被当作上传成功。")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .invalidResponse)
        }
    }

    func test指定目录任务文件创建使用官方V2且回读确认任务() async throws {
        let transport = MockHTTPTransport(responses: [
            downloadTaskListResponse(ids: []),
            response(#"{"success":true,"data":{"taskid":"task-file-1"}}"#),
            downloadTaskListResponse(
                ids: ["task-file-1"],
                destination: "downloads"
            ),
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.downloadStationTask],
            transport: transport
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-task-\(UUID().uuidString).torrent")
        try Data("d4:infod4:name4:testee".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let outcome = try await repository.createDownloadTaskFileResult(
            DownloadTaskFileCreateRequest(
                fileURL: fileURL,
                destination: "downloads"
            )
        )

        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        XCTAssertEqual(outcome.result.operation, "downloadCreate")
        XCTAssertEqual(outcome.taskID, "task-file-1")
        XCTAssertEqual(outcome.task?.destination, "downloads")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, [
            "list", "create", "list"
        ])
        let create = try XCTUnwrap(requests.first {
            requestValue("method", in: $0) == "create"
        })
        XCTAssertEqual(requestValue("api", in: create), DsmAPIName.downloadStationTask)
        XCTAssertEqual(requestValue("version", in: create), "2")
        XCTAssertNil(requestValue("unzip_password", in: create))
        XCTAssertFalse(create.url?.absoluteString.contains("REDACTED_SESSION") == true)
        let bodies = await transport.recordedUploadBodies()
        let body = try XCTUnwrap(bodies.first)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains("name=\"destination\"\r\n\r\ndownloads"))
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

    func test结束任务使用ForceComplete并仅确认任务已移除() async throws {
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
        XCTAssertNil(requestValue("remove_data", in: deletion))
        XCTAssertFalse(requests.contains {
            requestValue("api", in: $0)?.hasPrefix("SYNO.FileStation.") == true
        })
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
        XCTAssertEqual(snapshot.unavailableSections, [.images, .networks, .projects, .logs])
        XCTAssertTrue(snapshot.failedSections.isEmpty)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "-1")
        XCTAssertEqual(requestValue("type", in: request), "all")
    }

    func test官方容器日志参数和斜线日期用户事件解析() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
            DsmAPIName.dockerLog: [response(#"{"success":true,"data":{"offset":0,"limit":1000,"total":1,"logs":[{"time":"2026/07/02 21:17:09","level":"info","log_type":"container","user":"synthetic-user","event":"Synthetic container started."}]}}"#)]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerLog], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.message, "Synthetic container started.")
        XCTAssertEqual(snapshot.events.first?.user, "synthetic-user")
        XCTAssertNotNil(snapshot.events.first?.timestamp)
        XCTAssertFalse(snapshot.failedSections.contains(.logs))
        let requests = await transport.recordedRequests()
        let logRequest = try XCTUnwrap(requests.first { requestValue("api", in: $0) == DsmAPIName.dockerLog })
        for (key, expected) in ["action": "load", "sort_by": "time", "sort_dir": "DESC", "offset": "0",
                                "limit": "1000", "datefrom": "0", "dateto": "0", "loglevel": "", "filter_content": ""] {
            XCTAssertEqual(requestValue(key, in: logRequest), expected, key)
        }
    }

    func test日志按返回总数读取后页且同秒事件身份不冲突() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
            DsmAPIName.dockerLog: [
                response(#"{"success":true,"data":{"offset":0,"total":2,"logs":[{"time":100,"level":"info","event":"Synthetic first"}]}}"#),
                response(#"{"success":true,"data":{"offset":1,"total":2,"logs":[{"time":100,"level":"info","event":"Synthetic second"}]}}"#)
            ]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerLog], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.events.map(\.message), ["Synthetic first", "Synthetic second"])
        XCTAssertEqual(Set(snapshot.events.map(\.id)).count, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("api", in: $0) == DsmAPIName.dockerLog }.map { requestValue("offset", in: $0) }, ["0", "1"])
    }

    func test日志后页空缺时报告分区失败而不是返回不完整日志() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: ["container-1"]))],
            DsmAPIName.dockerLog: [
                response(#"{"success":true,"data":{"offset":0,"total":2,"logs":[{"time":100,"level":"info","event":"Synthetic first"}]}}"#),
                response(#"{"success":true,"data":{"offset":1,"total":2,"logs":[]}}"#)
            ]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerLog], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.containers.count, 1)
        XCTAssertTrue(snapshot.failedSections.contains(.logs))
        XCTAssertTrue(snapshot.events.isEmpty)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("api", in: $0) == DsmAPIName.dockerLog }.count, 2)
    }

    func test网络数量取真实关联数组且缺失不冒充零() async throws {
        for (payload, expectedCount) in [
            (#"{"id":"synthetic-network","name":"demo","driver":"bridge","containers":["synthetic-a","synthetic-b"]}"#, 2),
            (#"{"id":"synthetic-network","name":"demo","driver":"host","containers":[]}"#, 0),
            (#"{"id":"synthetic-network","name":"demo","driver":"bridge"}"#, -1),
            (#"{"id":"synthetic-network","name":"demo","driver":"bridge","containers":[42]}"#, -1)
        ] {
            let transport = ServiceRoutingTransport(responses: [
                DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
                DsmAPIName.dockerNetwork: response("{\"success\":true,\"data\":{\"network\":[\(payload)]}}")
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerNetwork], transport: transport)
            let snapshot = try await repository.loadContainerManager()
            if expectedCount >= 0 {
                XCTAssertEqual(snapshot.networks.first?.connectedContainerCount, expectedCount)
                XCTAssertFalse(snapshot.failedSections.contains(.networks))
            } else {
                XCTAssertTrue(snapshot.networks.isEmpty)
                XCTAssertTrue(snapshot.failedSections.contains(.networks))
            }
        }
    }

    func test网络只读详情映射且旧构造保持兼容() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
            DsmAPIName.dockerNetwork: [response(#"{"success":true,"data":{"network":[{"id":"synthetic-bridge","name":"Synthetic bridge","driver":"bridge","containers":["Synthetic A","Synthetic B"],"enable_ipv6":false,"subnet":"192.0.2.0/24","gateway":"192.0.2.1","iprange":""},{"id":"synthetic-host","name":"Synthetic host","driver":"host","containers":[],"enable_ipv6":true,"subnet":"","gateway":""}]}}"#)]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerNetwork], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        let network = try XCTUnwrap(snapshot.networks.first)
        XCTAssertEqual(network.subnet, "192.0.2.0/24")
        XCTAssertEqual(network.gateway, "192.0.2.1")
        XCTAssertEqual(network.isIPv6Enabled, false)
        XCTAssertEqual(network.connectedContainerNames, ["Synthetic A", "Synthetic B"])
        XCTAssertEqual(network.connectedContainerCount, 2)
        XCTAssertNil(snapshot.networks[1].subnet)
        XCTAssertNil(snapshot.networks[1].gateway)
        XCTAssertEqual(snapshot.networks[1].isIPv6Enabled, true)
        XCTAssertEqual(snapshot.networks[1].connectedContainerNames, [])
        let old = ContainerNetwork(id: "old", name: "Old caller", driver: "bridge", connectedContainerCount: 2)
        XCTAssertNil(old.subnet)
        XCTAssertNil(old.gateway)
        XCTAssertNil(old.isIPv6Enabled)
        XCTAssertNil(old.connectedContainerNames)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { requestValue("method", in: $0) == "list" })
    }

    func test网络计数拒绝布尔小数溢出和冲突别名() async throws {
        for fields in [#""container_count":false"#, #""container_count":0.5"#, #""container_count":1e30"#, #""container_count":0,"using":1"#] {
            let transport = ServiceRoutingTransport(responses: [
                DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
                DsmAPIName.dockerNetwork: response("{\"success\":true,\"data\":{\"network\":[{\"id\":\"synthetic\",\"name\":\"Synthetic\",\(fields)}]}}")
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerNetwork], transport: transport)
            let snapshot = try await repository.loadContainerManager()
            XCTAssertTrue(snapshot.networks.isEmpty); XCTAssertTrue(snapshot.failedSections.contains(.networks))
        }
    }

    func test官方项目空对象是正常空列表而不是加载失败() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
            DsmAPIName.dockerProject: response(#"{"success":true,"data":{}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerProject], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertTrue(snapshot.projects.isEmpty)
        XCTAssertFalse(snapshot.failedSections.contains(.projects))
        XCTAssertFalse(snapshot.unavailableSections.contains(.projects))
    }

    func test网络创建默认能力关闭时零请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], transport: transport)
        do { try await repository.createContainerNetwork(.init(name: "synthetic-network")); XCTFail("未验证的创建能力必须关闭") }
        catch { XCTAssertNotNil(error as? AppError) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test测试包创建开关传递至界面快照且默认仍关闭() async throws {
        for enabled in [false, true] {
            let transport = ServiceRoutingTransport(responses: [
                DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
                DsmAPIName.dockerNetwork: response(#"{"success":true,"data":{"network":[]}}"#)
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerNetwork],
                containerNetworkCreationEnabled: enabled, transport: transport)
            let snapshot = try await repository.loadContainerManager()
            XCTAssertEqual(snapshot.canCreateNetworks, enabled)
        }
    }

    func test网络自动创建只提交官方默认参数并回读确认() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [
            response(#"{"success":true,"data":{"network":[]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"network":[{"id":"synthetic-id","name":"synthetic-network","driver":"bridge","containers":[],"enable_ipv6":false}]}}"#)
        ]])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        var configuration = ContainerNetworkCreation(name: "synthetic-network")
        configuration.subnet = "unused-draft"
        configuration.ipv6Gateway = "unused-draft"
        try await repository.createContainerNetwork(configuration)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["list", "create", "list"])
        let create = requests[1]
        XCTAssertEqual(requestValue("name", in: create), "synthetic-network")
        XCTAssertEqual(requestValue("enable_ipv6", in: create), "false")
        XCTAssertEqual(requestValue("disable_masquerade", in: create), "false")
        for key in ["driver", "subnet", "iprange", "gateway", "ipv6_subnet", "ipv6_iprange", "ipv6_gateway"] {
            XCTAssertNil(requestValue(key, in: create), key)
        }
    }

    func test网络手动IPv4IPv6和伪装选项按官方字段提交() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [
            response(#"{"success":true,"data":{"network":[]}}"#), response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"network":[{"id":"synthetic-id","name":"synthetic-network","driver":"bridge","containers":[],"enable_ipv6":true,"subnet":"192.0.2.0/24","iprange":"192.0.2.128/25","gateway":"192.0.2.1"}]}}"#)
        ]])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        var configuration = ContainerNetworkCreation(name: "synthetic-network")
        configuration.usesManualIPv4 = true
        configuration.subnet = "192.0.2.0/24"
        configuration.ipRange = "192.0.2.128/25"
        configuration.gateway = "192.0.2.1"
        configuration.isIPv6Enabled = true
        configuration.ipv6Subnet = "2001:db8::/64"
        configuration.ipv6Gateway = "2001:db8::1"
        configuration.disableMasquerade = true
        try await repository.createContainerNetwork(configuration)
        let requests = await transport.recordedRequests()
        let create = requests[1]
        for (key, expected) in ["subnet": configuration.subnet, "iprange": configuration.ipRange, "gateway": configuration.gateway,
                                "ipv6_subnet": configuration.ipv6Subnet, "ipv6_gateway": configuration.ipv6Gateway,
                                "ipv6_iprange": "", "enable_ipv6": "true", "disable_masquerade": "true"] {
            XCTAssertEqual(requestValue(key, in: create), expected, key)
        }
        XCTAssertNil(requestValue("driver", in: create))
    }

    func test网络创建同名拦截且无效地址不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"network":[{"id":"synthetic-id","name":"synthetic-network","driver":"bridge","containers":[]}]}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        var invalid = ContainerNetworkCreation(name: "synthetic-network")
        invalid.usesManualIPv4 = true
        do { try await repository.createContainerNetwork(invalid); XCTFail("无效地址不得提交") } catch {}
        let before = await transport.recordedRequests()
        XCTAssertTrue(before.isEmpty)
        do { try await repository.createContainerNetwork(.init(name: "synthetic-network")); XCTFail("同名网络不得创建") } catch {}
        let after = await transport.recordedRequests()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(requestValue("method", in: after[0]), "list")
    }

    func test网络创建回读不一致后只核对不重复提交() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [
            response(#"{"success":true,"data":{"network":[]}}"#), response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"network":[]}}"#),
            response(#"{"success":true,"data":{"network":[{"id":"synthetic-id","name":"synthetic-network","driver":"bridge","containers":[],"enable_ipv6":false}]}}"#)
        ]])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        let configuration = ContainerNetworkCreation(name: "synthetic-network")
        do { try await repository.createContainerNetwork(configuration); XCTFail("未回读到目标不得报告成功") } catch {}
        try await repository.createContainerNetwork(configuration)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["list", "create", "list", "list"])
    }

    func test同名网络创建并发只发送一次写入() async throws {
        let base = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [
            response(#"{"success":true,"data":{"network":[]}}"#), response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"network":[{"id":"synthetic-id","name":"synthetic-network","driver":"bridge","containers":[],"enable_ipv6":false}]}}"#)
        ]])
        let transport = HoldingServiceReadTransport(base: base)
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        let configuration = ContainerNetworkCreation(name: "synthetic-network")
        let first = Task { try await repository.createContainerNetwork(configuration) }
        await transport.waitForRead()
        do { try await repository.createContainerNetwork(configuration); XCTFail("重复创建应被拦截") } catch {}
        await transport.release()
        try await first.value
        let requests = await base.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["list", "create", "list"])
    }

    func test创建前取消不发送网络写入() async throws {
        let base = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [response(#"{"success":true,"data":{"network":[]}}"#)]])
        let transport = HoldingServiceReadTransport(base: base)
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], containerNetworkCreationEnabled: true, transport: transport)
        let task = Task { try await repository.createContainerNetwork(.init(name: "synthetic-network")) }
        await transport.waitForRead()
        task.cancel()
        await transport.release()
        do { try await task.value; XCTFail("取消后不得创建") } catch {}
        let requests = await base.recordedRequests()
        XCTAssertTrue(requests.allSatisfy { requestValue("method", in: $0) == "list" })
    }

    func test项目键值列表提取稳定身份和关联容器数量() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
            DsmAPIName.dockerProject: response(#"{"success":true,"data":{"synthetic-project":{"name":"Synthetic project","status":"running","containerIds":["synthetic-a","synthetic-b"]}}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerProject], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.projects, [.init(id: "synthetic-project", name: "Synthetic project", status: "running", containerCount: 2)])
        XCTAssertFalse(snapshot.failedSections.contains(.projects))
    }

    func test项目畸形对象仍报告失败且原数组格式保留兼容() async throws {
        for (data, expectedFailure) in [(#"{"unexpected":"not-a-project"}"#, true),
                                         (#"{"projects":[{"id":"synthetic-project","name":"Synthetic project","container_count":1}]}"#, false)] {
            let transport = ServiceRoutingTransport(responses: [
                DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
                DsmAPIName.dockerProject: response("{\"success\":true,\"data\":\(data)}")
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerProject], transport: transport)
            let snapshot = try await repository.loadContainerManager()
            XCTAssertEqual(snapshot.failedSections.contains(.projects), expectedFailure)
            XCTAssertEqual(snapshot.projects.count, expectedFailure ? 0 : 1)
        }
    }

    func test网络详情缺失或IPv6类型不符不推断为停用() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: [])),
            DsmAPIName.dockerNetwork: response(#"{"success":true,"data":{"network":[{"id":"synthetic-old","name":"Synthetic old","driver":"bridge","container_count":2},{"id":"synthetic-unknown","name":"Synthetic unknown","driver":"bridge","containers":[],"enable_ipv6":"unexpected"}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerNetwork], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.networks.count, 2)
        XCTAssertNil(snapshot.networks[0].connectedContainerNames)
        XCTAssertNil(snapshot.networks[0].isIPv6Enabled)
        XCTAssertNil(snapshot.networks[1].isIPv6Enabled)
        XCTAssertTrue(snapshot.failedSections.isEmpty)
    }

    func test容器主分区拒绝非根数组坏元素与重复身份() async throws {
        let payloads = [
            #"{"success":true,"data":{"items":[]}}"#,
            #"{"success":true,"data":{"containers":[{"name":"缺少身份"}]}}"#,
            #"{"success":true,"data":{"containers":[{"id":"same"},{"id":"same"}]}}"#
        ]
        for payload in payloads {
            let repository = try makeRepository(
                apiNames: [DsmAPIName.dockerContainer],
                transport: MockHTTPTransport(responses: [response(payload)])
            )
            do {
                _ = try await repository.loadContainerManager()
                XCTFail("畸形容器主分区必须整体失败")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test容器附属分区严格解析失败进入Typed状态() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: ["container-1"])),
            DsmAPIName.dockerImage: response(#"{"success":true,"data":{"images":[{"id":"same"},{"id":"same"}]}}"#),
            DsmAPIName.dockerNetwork: response(#"{"success":true,"data":{"networks":[{"name":"缺少身份"}]}}"#),
            DsmAPIName.dockerProject: response(#"{"success":true,"data":{"projects":{}}}"#),
            DsmAPIName.dockerLog: response(#"{"success":true,"data":{"logs":[{}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.dockerContainer, DsmAPIName.dockerImage,
                DsmAPIName.dockerNetwork, DsmAPIName.dockerProject, DsmAPIName.dockerLog
            ],
            transport: transport
        )

        let snapshot = try await repository.loadContainerManager()

        XCTAssertEqual(snapshot.containers.map(\.id), ["container-1"])
        XCTAssertEqual(snapshot.failedSections, [.images, .networks, .projects, .logs])
        XCTAssertTrue(snapshot.images.isEmpty)
        XCTAssertTrue(snapshot.networks.isEmpty)
        XCTAssertTrue(snapshot.projects.isEmpty)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func test无服务器事件身份时只用时间与顺序生成稳定白名单身份() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: ["container-1"])),
            DsmAPIName.dockerLog: response(#"{"success":true,"data":{"logs":[{"time":100,"level":"info","user":"user-a","message":"same"},{"time":100,"level":"info","user":"user-a","message":"same"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerLog],
            transport: transport
        )

        let snapshot = try await repository.loadContainerManager()

        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(Set(snapshot.events.map(\.id)).count, 2)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.id.hasPrefix("event-") })
        XCTAssertFalse(snapshot.failedSections.contains(.logs))
    }

    func test容器主清单显示真实重启过渡态() async throws {
        let transport = MockHTTPTransport(responses: [response(containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z", restarting: true))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertEqual(snapshot.containers.first?.status, "restarting")
    }

    func test重启过渡态仍能停止或重启但不能删除() async throws {
        for running in [false, true] {
            for action in [ContainerAction.stop, .restart] {
                let transport = MockHTTPTransport(responses: [
                    response(containerControlResponse(running: running, startedAt: "2026-01-01T00:00:00Z", restarting: true)),
                    response(#"{"success":true}"#),
                    response(containerControlResponse(running: action == .restart, startedAt: "2026-01-01T01:00:00Z")),
                ])
                let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
                try await repository.controlContainers(ids: ["synthetic-id"], action: action)
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.filter { requestValue("method", in: $0) == action.rawValue }.count, 1)
            }
        }
        let transport = MockHTTPTransport(responses: [response(containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z", restarting: true))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        let result = try await repository.deleteContainersResult(ids: ["synthetic-id"])
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "delete" })
    }

    func test停止后仍在重启不误报成功也不重发() async throws {
        let looping = containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z", restarting: true)
        let transport = MockHTTPTransport(responses: [response(looping), response(#"{"success":true}"#), response(looping),
            response(containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z"))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        do { try await repository.controlContainers(ids: ["synthetic-id"], action: .stop); XCTFail("过渡状态不能确认停止") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        try await repository.controlContainers(ids: ["synthetic-id"], action: .stop)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "stop" }.count, 1)
    }

    func test容器操作使用名称并按状态回读支持两种编码() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for action in [ContainerAction.start, .stop, .restart] {
                let initialRunning = action != .start
                let transport = MockHTTPTransport(responses: [
                    response(containerControlResponse(running: initialRunning, startedAt: "2026-01-01T00:00:00.000Z")),
                    response(#"{"success":true}"#),
                    response(containerControlResponse(running: action != .stop, startedAt: "2026-01-01T01:00:00.000Z")),
                ])
                let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer],
                    requestFormatOverrides: [DsmAPIName.dockerContainer: format], transport: transport)
                try await repository.controlContainers(ids: ["synthetic-id"], action: action)
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 3)
                let sent = requests[1]
                XCTAssertEqual(requestValue("name", in: sent), format == .json ? #""synthetic-worker""# : "synthetic-worker")
                XCTAssertNil(requestValue("id", in: sent))
                XCTAssertEqual(requestValue("method", in: sent), action.rawValue)
                XCTAssertEqual(requestValue("version", in: sent), "1")
            }
        }
    }

    func test容器重启必须启动时间变化且未确认不能重放() async throws {
        let before = containerControlResponse(running: true, startedAt: "2026-01-01T00:00:00Z")
        let transport = MockHTTPTransport(responses: [response(before), response(#"{"success":true}"#), response(before),
            response(containerControlResponse(running: true, startedAt: "2026-01-01T01:00:00Z"))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        do { try await repository.controlContainers(ids: ["synthetic-id"], action: .restart); XCTFail("未确认重启被误报成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        try await repository.controlContainers(ids: ["synthetic-id"], action: .restart)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "restart" }.count, 1)
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "list" }.count, 3)
    }

    func test容器启动断线后只能回读不能再次提交() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z"))),
            .urlError(.networkConnectionLost),
            .response(response(containerControlResponse(running: true, startedAt: "2026-01-01T01:00:00Z"))),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        do { try await repository.controlContainers(ids: ["synthetic-id"], action: .start); XCTFail("断线应保留未确认") }
        catch { }
        try await repository.controlContainers(ids: ["synthetic-id"], action: .start)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "start" }.count, 1)
    }

    func test容器删除按名称且不强制删除或保留配置() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: [
                response(containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z")),
                response(#"{"success":true}"#), response(containerListResponse(ids: [])),
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer],
                requestFormatOverrides: [DsmAPIName.dockerContainer: format], transport: transport)
            let result = try await repository.deleteContainersResult(ids: ["synthetic-id"])
            XCTAssertEqual(result.status, .confirmedSuccess)
            let requests = await transport.recordedRequests()
            let sent = requests[1]
            XCTAssertEqual(requestValue("name", in: sent), format == .json ? #""synthetic-worker""# : "synthetic-worker")
            XCTAssertNil(requestValue("id", in: sent))
            XCTAssertEqual(requestValue("force", in: sent), "false")
            XCTAssertEqual(requestValue("preserve_profile", in: sent), "false")
        }
    }

    func test容器删除断线后的显式重试只读取列表() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(containerListResponse(ids: ["container-1"]))), .urlError(.networkConnectionLost),
            .response(response(containerListResponse(ids: []))),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        let first = try await repository.deleteContainersResult(ids: ["container-1"])
        XCTAssertEqual(first.status, .submittedButUnverified)
        let reviewed = try await repository.deleteContainersResult(ids: ["container-1"])
        XCTAssertEqual(reviewed.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    func test未知删除期间同名新实例不能接管操作() async throws {
        let original = containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z")
        let replacement = original.replacingOccurrences(of: "synthetic-id", with: "replacement-id")
        let transport = MockHTTPTransport(steps: [.response(response(original)), .urlError(.networkConnectionLost), .response(response(replacement))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer], transport: transport)
        let first = try await repository.deleteContainersResult(ids: ["synthetic-id"])
        XCTAssertEqual(first.status, .submittedButUnverified)
        do { try await repository.controlContainers(ids: ["replacement-id"], action: .start); XCTFail("同名新实例不应绕过未知锁") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "start" }.count, 0)
    }

    func test套件托管容器及项目均不能提交启停或删除() async throws {
        for viaProject in [false, true] {
            let list = containerControlResponse(running: false, startedAt: "2026-01-01T00:00:00Z")
                .replacingOccurrences(of: #""is_package":false"#, with: viaProject ? #""is_package":false"# : #""is_package":true"#)
                .replacingOccurrences(of: #""Labels":{}"#, with: viaProject ? #""Labels":{"com.docker.compose.project":"synthetic-project"}"# : #""Labels":{}"#)
            let replies = viaProject ? [response(list), response(#"{"success":true,"data":{"synthetic-project-id":{"name":"synthetic-project","is_package":true}}}"#)] : [response(list)]
            let transport = MockHTTPTransport(responses: replies)
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerProject], transport: transport)
            do { try await repository.controlContainers(ids: ["synthetic-id"], action: .start); XCTFail("托管容器不应提交") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.allSatisfy { requestValue("method", in: $0) == "list" })

            let deletionTransport = MockHTTPTransport(responses: replies)
            let deletionRepository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerProject], transport: deletionTransport)
            let deleted = try await deletionRepository.deleteContainersResult(ids: ["synthetic-id"])
            XCTAssertEqual(deleted.status, .permissionDenied)
            let deleteRequests = await deletionTransport.recordedRequests()
            XCTAssertTrue(deleteRequests.allSatisfy { requestValue("method", in: $0) == "list" })
        }
    }

    private func containerControlResponse(running: Bool, startedAt: String, restarting: Bool = false) -> String {
        let state = running ? "running" : "stopped"
        return #"{"success":true,"data":{"containers":[{"id":"synthetic-id","name":"synthetic-worker","status":"\#(state)","image":"synthetic:latest","is_package":false,"Labels":{},"State":{"Running":\#(running),"Paused":false,"Restarting":\#(restarting),"StartedAt":"\#(startedAt)"}}]}}"#
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
            response(containerListResponse(ids: ["container-2"])),
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

    func test镜像标签兼容字符串和对象数组且保留顺序() async throws {
        for payload in [
            #"{"success":true,"data":["latest",{"tag":"stable"},"latest",{"name":"V1"}]}"#,
            #"{"success":true,"data":{"tags":["latest",{"name":"stable"},"latest","V1"]}}"#
        ] {
            let transport = MockHTTPTransport(responses: [response(payload)])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerRegistry], transport: transport)
            let tags = try await repository.loadContainerImageTags(repository: "synthetic/image")
            XCTAssertEqual(tags, ["latest", "stable", "V1"])
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requestValue("method", in: try XCTUnwrap(requests.first)), "tags")
        }
    }

    func test镜像标签畸形响应不能冒充空列表或部分成功() async throws {
        for data in [
            #"{}"#, #"{"tags":{}}"#, #"["valid",1]"#, #"["valid",null]"#,
            #"[{"tag":"a","name":"b"}]"#, #"{"data":[],"tags":["different"]}"#,
            #"[" "]"#, #"["bad\nvalue"]"#
        ] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(data)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerRegistry], transport: transport)
            do {
                _ = try await repository.loadContainerImageTags(repository: "synthetic/image")
                XCTFail("畸形标签响应不得成功")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test下载镜像兼容入口保留任务且不重复提交() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"tags":["latest"]}}"#),
            response(#"{"success":true,"data":{"images":[]}}"#),
            response(#"{"success":true,"data":{"task_id":"synthetic-task"}}"#),
            response(#"{"success":true,"data":{"finished":false,"repository":"nginx","tag":"latest","current":1,"total":4}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry],
            requestFormatOverrides: [DsmAPIName.dockerImage: .json],
            transport: transport
        )

        try await repository.pullContainerImage(repository: "nginx", tag: "latest")
        do {
            try await repository.pullContainerImage(repository: "nginx", tag: "latest")
            XCTFail("兼容入口不得重复启动同一未结束目标")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        let starts = requests.filter { requestValue("method", in: $0) == "pull_start" }
        XCTAssertEqual(starts.count, 1)
        let request = try XCTUnwrap(starts.first)
        XCTAssertEqual(requestValue("api", in: request), DsmAPIName.dockerImage)
        XCTAssertEqual(requestValue("method", in: request), "pull_start")
        XCTAssertEqual(requestValue("repository", in: request), #""nginx""#)
        XCTAssertEqual(requestValue("tag", in: request), #""latest""#)
    }

    func test容器映像完整列表使用官方分页和布尔参数() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
            DsmAPIName.dockerImage: [response(#"{"success":true,"data":{"images":[],"total":0,"offset":0,"limit":-1}}"#)]
        ])
        let repository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerImage],
            requestFormatOverrides: [DsmAPIName.dockerImage: .json], transport: transport
        )
        let snapshot = try await repository.loadContainerManager()
        XCTAssertTrue(snapshot.images.isEmpty)
        XCTAssertFalse(snapshot.failedSections.contains(.images))
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first { requestValue("api", in: $0) == DsmAPIName.dockerImage })
        XCTAssertEqual(requestValue("offset", in: request), "0")
        XCTAssertEqual(requestValue("limit", in: request), "-1")
        XCTAssertEqual(requestValue("show_dsm", in: request), "false")
    }

    func test容器映像分页不完整或类型错误仅使映像分区失败() async throws {
        for metadata in [#""total":1"#, #""total":true"#, #""total":"0""#, #""total":0.5"#, #""offset":1"#, #""offset":null"#] {
            let transport = SequencedServiceRoutingTransport(responses: [
                DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
                DsmAPIName.dockerImage: [response("{\"success\":true,\"data\":{\"images\":[],\(metadata)}}")]
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerImage], transport: transport)
            let snapshot = try await repository.loadContainerManager()
            XCTAssertTrue(snapshot.images.isEmpty)
            XCTAssertTrue(snapshot.failedSections.contains(.images))
            XCTAssertEqual(snapshot.failedSections, [.images])
            XCTAssertTrue(snapshot.containers.isEmpty)
        }
    }

    func test容器映像删除回读确认后返回成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [
                response(containerListResponse(ids: [])),
                response(containerListResponse(ids: [])),
            ],
            DsmAPIName.dockerImage: [
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-1","repository":"demo","tags":["latest"]}]}}"#
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
            ids: [ContainerImage.selectionID(imageID: "image-1", repository: "demo", tag: "latest")]
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

    func test容器映像批量删除后按标签回读为部分成功() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [
                response(containerListResponse(ids: [])),
                response(containerListResponse(ids: [])),
            ],
            DsmAPIName.dockerImage: [
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-1","repository":"demo","tags":["one"]},{"id":"image-2","repository":"demo","tags":["two"]}]}}"#
                ),
                response(#"{"success":true}"#),
                response(
                    #"{"success":true,"data":{"images":[{"id":"image-2","repository":"demo","tags":["two"]}]}}"#
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
            ids: [ContainerImage.selectionID(imageID: "image-2", repository: "demo", tag: "two"),
                  ContainerImage.selectionID(imageID: "image-1", repository: "demo", tag: "one")]
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
                    #"{"success":true,"data":{"networks":[{"id":"network-1","name":"isolated","driver":"bridge","containers":[]}]}}"#
                ),
                response(#"{"success":true,"data":{"networks":[{"id":"network-1","name":"isolated","driver":"bridge","containers":[]}]}}"#),
                response(#"{"success":true,"data":{"failed":[]}}"#),
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
        let requests = await transport.recordedRequests()
        let remove = try XCTUnwrap(requests.first { requestValue("method", in: $0) == "remove" })
        XCTAssertNil(requestValue("id", in: remove))
        let encoded = try XCTUnwrap(requestValue("networks", in: remove))
        let targets = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0]["id"] as? String, "network-1")
        XCTAssertEqual(targets[0]["name"] as? String, "isolated")
        XCTAssertEqual(targets[0]["_key"] as? String, "network-1")
        XCTAssertEqual(targets[0]["containers"] as? [String], [])
    }

    func test默认网络及仍连接容器的网络不提交删除() async throws {
        for (name, containers) in [("bridge", "[]"), ("host", "[]"), ("none", "[]"), ("synthetic-network", "[\"synthetic-container\"]")] {
            let payload = "{\"success\":true,\"data\":{\"network\":[{\"id\":\"synthetic-id\",\"name\":\"\(name)\",\"driver\":\"bridge\",\"containers\":\(containers)}]}}"
            let transport = SequencedServiceRoutingTransport(responses: [DsmAPIName.dockerNetwork: [response(payload)]])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerNetwork], transport: transport)
            let result = try await repository.deleteContainerNetworksResult(ids: ["synthetic-id"])
            XCTAssertNotEqual(result.status, .confirmedSuccess)
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.allSatisfy { requestValue("method", in: $0) == "list" })
        }
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
        XCTAssertEqual(snapshot.failedSections, [.logs])
        XCTAssertEqual(snapshot.unavailableSections, [.protection])
    }

    func test虚拟机主分区拒绝非根数组坏元素与重复身份() async throws {
        let payloads = [
            #"{"success":true,"data":{"items":[]}}"#,
            #"{"success":true,"data":{"guests":[{"guest_name":"缺少身份"}]}}"#,
            #"{"success":true,"data":{"guests":[{"guest_id":"same"},{"guest_id":"same"}]}}"#
        ]
        for payload in payloads {
            let repository = try makeRepository(
                apiNames: [DsmAPIName.virtualizationAPIGuest],
                transport: MockHTTPTransport(responses: [response(payload)])
            )
            do {
                _ = try await repository.loadVirtualMachineManager()
                XCTFail("畸形虚拟机主分区必须整体失败")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .invalidResponse)
            }
        }
    }

    func test虚拟机附属分区严格解析失败进入Typed状态() async throws {
        let transport = ServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationAPIGuest: response(#"{"success":true,"data":{"guests":[]}}"#),
            DsmAPIName.virtualizationAPIHost: response(#"{"success":true,"data":{"hosts":[{"host_id":"same","host_name":"一"},{"host_id":"same","host_name":"二"}]}}"#),
            DsmAPIName.virtualizationAPIStorage: response(#"{"success":true,"data":{"storages":[{"storage_name":"缺少身份"}]}}"#),
            DsmAPIName.virtualizationAPINetwork: response(#"{"success":true,"data":{"networks":{}}}"#),
            DsmAPIName.virtualizationAPIGuestImage: response(#"{"success":true,"data":{"images":[1]}}"#),
            DsmAPIName.virtualizationProtectionPlan: response(#"{"success":true,"data":{"plans":[{}]}}"#),
            DsmAPIName.virtualizationLog: response(#"{"success":true,"data":{"logs":[{"log_id":"same","event":"一"},{"log_id":"same","event":"二"}]}}"#)
        ])
        let repository = try makeRepository(
            apiNames: [
                DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIHost,
                DsmAPIName.virtualizationAPIStorage, DsmAPIName.virtualizationAPINetwork,
                DsmAPIName.virtualizationAPIGuestImage,
                DsmAPIName.virtualizationProtectionPlan, DsmAPIName.virtualizationLog
            ],
            transport: transport
        )

        let snapshot = try await repository.loadVirtualMachineManager()

        XCTAssertEqual(
            snapshot.failedSections,
            [.hosts, .storages, .networks, .images, .protection, .logs]
        )
        XCTAssertTrue(snapshot.machines.isEmpty)
        XCTAssertTrue(snapshot.hosts.isEmpty)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func test容器附属分区区分缺能力与读取失败且认证继续抛出() async throws {
        let failedTransport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: ["container-1"])),
            DsmAPIName.dockerImage: response(#"{"success":false,"error":{"code":402}}"#)
        ])
        let failedRepository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerImage],
            transport: failedTransport
        )

        let snapshot = try await failedRepository.loadContainerManager()
        XCTAssertEqual(snapshot.failedSections, [.images])
        XCTAssertEqual(snapshot.unavailableSections, [.networks, .projects, .logs])

        let authenticationTransport = ServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: response(containerListResponse(ids: ["container-1"])),
            DsmAPIName.dockerImage: response(#"{"success":false,"error":{"code":106}}"#)
        ])
        let authenticationRepository = try makeRepository(
            apiNames: [DsmAPIName.dockerContainer, DsmAPIName.dockerImage],
            transport: authenticationTransport
        )
        do {
            _ = try await authenticationRepository.loadContainerManager()
            XCTFail("认证错误不应被折叠为分区状态")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .authenticationRequired)
        }
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
        let allRequests = await transport.recordedRequests()
        let requests = allRequests.filter { requestValue("method", in: $0) == "delete" }
        XCTAssertEqual(requests.compactMap { requestValue("guest_id", in: $0) }, ["vm-1", "vm-2"])
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
            selectedVersionOverrides: [DsmAPIName.virtualizationGuest: 2],
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
                diskGiB: 20,
                autoStart: true
            )
        )

        let requests = await transport.recordedRequests()
        let createRequest = try XCTUnwrap(
            requests.first(where: { requestValue("method", in: $0) == "create" })
        )
        XCTAssertEqual(requestValue("api", in: createRequest), DsmAPIName.virtualizationGuest)
        XCTAssertEqual(requestValue("version", in: createRequest), "1")
        XCTAssertEqual(requestValue("iso_images", in: createRequest), #"["unmounted","unmounted"]"#)
        XCTAssertEqual(requestValue("usbs", in: createRequest), #"["unmounted","unmounted","unmounted","unmounted"]"#)
        XCTAssertEqual(requestValue("boot_from", in: createRequest), #""disk""#)
        XCTAssertEqual(requestValue("name", in: createRequest), #""新虚拟机""#)
        XCTAssertEqual(requestValue("vcpu_num", in: createRequest), "2")
        XCTAssertEqual(requestValue("vram_size", in: createRequest), "2048")
        XCTAssertEqual(requestValue("allocated_size", in: createRequest), "100")
        XCTAssertEqual(requestValue("repo_id", in: createRequest), #""repo-1""#)
        XCTAssertEqual(requestValue("poweron_after_create", in: createRequest), "false")
        XCTAssertEqual(requestValue("autorun", in: createRequest), "2")
        XCTAssertFalse(createRequest.url?.absoluteString.contains("REDACTED_SESSION") == true)
    }

    func test虚拟机内部读取KiB与公开读取MiB分别转换() async throws {
        for (api, rawMemory) in [(DsmAPIName.virtualizationGuest, 524_288), (DsmAPIName.virtualizationAPIGuest, 512)] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":{\"guests\":[{\"guest_id\":\"vm-1\",\"name\":\"Synthetic\",\"guest_name\":\"Synthetic\",\"status\":\"shutdown\",\"vcpu_num\":1,\"vram_size\":\(rawMemory)}]}}")])
            let repository = try makeRepository(apiNames: [api], selectedVersionOverrides: [DsmAPIName.virtualizationGuest: 2], transport: transport)
            let snapshot = try await repository.loadVirtualMachineManager()
            XCTAssertEqual(snapshot.machines.first?.memoryBytes, 536_870_912)
        }
    }

    func test内部内存回读不能将MiB数值误认为已保存() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown","vcpu_num":2,"vram_size":2097152}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown","vcpu_num":2,"vram_size":4096}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], selectedVersionOverrides: [DsmAPIName.virtualizationGuest: 2], transport: transport)
        do {
            try await repository.updateVirtualMachine(id: "vm-1", configuration: VirtualMachineUpdate(memoryMiB: 4096))
            XCTFail("内部读取必须核对对应的 KiB，不能误报成功")
        } catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
    }

    func test修改虚拟机只提交变化并回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"旧名称","status":"shutdown","vcpu_num":2,"vram_size":2097152}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"新名称","status":"shutdown","vcpu_num":4,"vram_size":4194304}]}}"#)
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

    func test虚拟机修改核查全部发送字段并保留空说明() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"旧名称","status":"shutdown","vcpu_num":2,"vram_size":2097152}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"新名称","desc":"","vcpu_num":4,"vram_size":4194304,"cpu_weight":64,"autorun":0}]}}"#)
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], transport: transport)
        try await repository.updateVirtualMachine(id: "vm-1", configuration: VirtualMachineUpdate(
            name: " 新名称 ", description: "", cpuCount: 4, memoryMiB: 4096, cpuWeight: 64, autoStart: false
        ))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("name", in: requests[1]), "新名称")
        XCTAssertEqual(requestValue("desc", in: requests[1]), "")
        XCTAssertEqual(requestValue("cpu_weight", in: requests[1]), "64")
        XCTAssertEqual(requestValue("autorun", in: requests[1]), "0")
        XCTAssertEqual(requestValue("api", in: requests[2]), DsmAPIName.virtualizationGuest)
        XCTAssertEqual(requestValue("method", in: requests[2]), "list")
    }

    func test镜像多标签按独立身份展开且分页对原始记录计数() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.dockerContainer: [response(containerListResponse(ids: []))],
            DsmAPIName.dockerImage: [response(#"{"success":true,"data":{"offset":0,"total":2,"images":[{"id":"same-id","repository":"demo","tags":["latest","stable"]},{"id":"same-id","repository":"alias","tags":["v1"]}]}}"#)]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer],
            selectedVersionOverrides: [DsmAPIName.dockerImage: 2, DsmAPIName.dockerContainer: 2], transport: transport)
        let snapshot = try await repository.loadContainerManager()
        XCTAssertFalse(snapshot.failedSections.contains(.images))
        XCTAssertEqual(snapshot.images.map(\.tag), ["latest", "stable", "v1"])
        XCTAssertEqual(Set(snapshot.images.map(\.id)).count, 3)
        XCTAssertTrue(snapshot.images.allSatisfy { $0.sourceImageID == "same-id" })
        let requests = await transport.recordedRequests()
        let imageRequest = try XCTUnwrap(requests.first { requestValue("api", in: $0) == DsmAPIName.dockerImage })
        XCTAssertEqual(requestValue("version", in: imageRequest), "1")
        let containerRequest = try XCTUnwrap(requests.first { requestValue("api", in: $0) == DsmAPIName.dockerContainer })
        XCTAssertEqual(requestValue("version", in: containerRequest), "1")
    }

    func test镜像删除两种编码均按标签提交且保留同ID其他标签仍算成功() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: [
                response(imageTagList()), response(containerListResponse(ids: [])), response(#"{"success":true}"#),
                response(imageTagList(tags: "\"latest\""))
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer],
                requestFormatOverrides: [DsmAPIName.dockerImage: format], transport: transport)
            let result = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
            XCTAssertEqual(result.status, .confirmedSuccess)
            let requests = await transport.recordedRequests()
            let deletion = try XCTUnwrap(requests.first { requestValue("method", in: $0) == "delete" })
            XCTAssertEqual(requestValue("version", in: deletion), "1")
            XCTAssertNil(requestValue("id", in: deletion)); XCTAssertNil(requestValue("force", in: deletion))
            let payload = try XCTUnwrap(requestValue("images", in: deletion))
            let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
            XCTAssertEqual(objects.count, 1); XCTAssertEqual(objects[0]["repository"] as? String, "demo")
            XCTAssertEqual(objects[0]["tags"] as? [String], ["stable"])
            XCTAssertEqual(requests.count, 4)
        }
    }

    func test镜像明确拒绝不会回读成成功且核查入口绝不发送删除() async throws {
        for code in [105, 9999] {
            let transport = MockHTTPTransport(responses: [response(imageTagList()), response(containerListResponse(ids: [])),
                response("{\"success\":false,\"error\":{\"code\":\(code)}}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
            let result = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
            XCTAssertEqual(result.status, code == 105 ? .permissionDenied : .confirmedFailure)
            XCTAssertEqual(result.counts.failed, 1); XCTAssertEqual(result.counts.unknown, 0)
            let review = try await repository.reviewContainerImageDeletion(ids: [imageTagID()])
            XCTAssertFalse(review.submitted)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 3)
        }
    }

    func test镜像回执丢失后重复调用和独立核查都只读() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(imageTagList())), .response(response(containerListResponse(ids: []))),
            .urlError(.timedOut), .response(response(imageTagList())), .response(response(imageTagList())),
            .response(response(imageTagList(tags: "\"latest\"")))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
        let first = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
        let repeated = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
        let reviewed = try await repository.reviewContainerImageDeletion(ids: [imageTagID()])
        XCTAssertEqual(first.status, .submittedButUnverified); XCTAssertEqual(repeated.status, .submittedButUnverified)
        XCTAssertEqual(reviewed.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    func test镜像标签换ID后不能重放且不能凭旧ID消失确认删除() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(imageTagList())), .response(response(containerListResponse(ids: []))),
            .urlError(.timedOut), .response(response(imageTagList(id: "replacement"))), .response(response(imageTagList(id: "replacement"))),
            .response(response(imageTagList(id: "replacement")))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
        let first = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
        let replacement = try await repository.deleteContainerImagesResult(ids: [imageTagID(id: "replacement")])
        let reviewed = try await repository.reviewContainerImageDeletion(ids: [imageTagID()])
        XCTAssertEqual(first.status, .submittedButUnverified)
        XCTAssertFalse(replacement.submitted); XCTAssertEqual(replacement.errorCategory, .conflict)
        XCTAssertEqual(reviewed.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    func test镜像删除拒绝停止容器占用并归一官方仓库前缀() async throws {
        for name in ["demo:stable", "docker.io/demo:stable", "index.docker.io/demo:stable"] {
            let transport = MockHTTPTransport(responses: [response(imageTagList()),
                response("{\"success\":true,\"data\":{\"containers\":[{\"image\":\"\(name)\",\"status\":\"stopped\"}]}}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
            let result = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
            XCTAssertFalse(result.submitted)
            let requests = await transport.recordedRequests()
            XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "delete" })
        }
    }

    func test镜像删除拒绝畸形身份重复标签和不完整列表() async throws {
        let values = [
            #"{"images":[{"id":123,"repository":"demo","tags":["stable"]}]}"#,
            #"{"images":[{"id":"image-1","repository":123,"tags":["stable"]}]}"#,
            #"{"images":[{"id":"image-1","repository":"demo","tags":["stable",true]}]}"#,
            #"{"images":[{"id":"image-1","repository":"demo","tags":["stable","stable"]}]}"#,
            #"{"images":[{"id":"image-1","repository":"demo","tag":"stable"}]}"#,
            #"{"total":2,"images":[{"id":"image-1","repository":"demo","tags":["stable"]}]}"#
        ]
        for value in values {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(value)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
            let result = try await repository.deleteContainerImagesResult(ids: [imageTagID()])
            XCTAssertFalse(result.submitted)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func test裸镜像使用identity删除但不能隐含删除有效标签() async throws {
        for otherTag in [false, true] {
            let transport = MockHTTPTransport(responses: [response(imageTagList(tags: otherTag ? "\"<none>\",\"stable\"" : "\"<none>\"")),
                response(containerListResponse(ids: [])), response(#"{"success":true}"#), response(#"{"success":true,"data":{"images":[]}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
            let result = try await repository.deleteContainerImagesResult(ids: [imageTagID(tag: "<none>")])
            XCTAssertEqual(result.submitted, !otherTag)
            let requests = await transport.recordedRequests()
            if !otherTag {
                XCTAssertEqual(result.status, .confirmedSuccess)
                let deletion = try XCTUnwrap(requests.first { requestValue("method", in: $0) == "delete" })
                let payload = try XCTUnwrap(requestValue("images", in: deletion))
                let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: String]])
                XCTAssertEqual(objects, [["identity": "image-1"]])
            } else { XCTAssertEqual(requests.count, 1) }
        }
    }

    func test镜像核查从未提交的目标不会调用任何接口() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
        let result = try await repository.reviewContainerImageDeletion(ids: [imageTagID()])
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test镜像提交后取消保留原范围且下一次只读核查() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(imageTagList())), .response(response(containerListResponse(ids: []))),
            .waitUntilCancelled, .response(response(imageTagList(tags: "\"latest\"")))])
        let repository = try makeRepository(apiNames: [DsmAPIName.dockerImage, DsmAPIName.dockerContainer], transport: transport)
        let ids = [imageTagID()]
        let operation = Task { try await repository.deleteContainerImagesResult(ids: ids) }
        let deadline = Date().addingTimeInterval(2)
        while await transport.recordedRequests().count < 3 && Date() < deadline { await Task.yield() }
        let beforeCancellation = await transport.recordedRequests()
        operation.cancel()
        let result = try await operation.value
        XCTAssertEqual(beforeCancellation.count, 3)
        XCTAssertEqual(result.status, .cancellationRequestedAfterSubmission)
        let reviewed = try await repository.reviewContainerImageDeletion(ids: ids)
        XCTAssertEqual(reviewed.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    private func imageTagID(id: String = "image-1", tag: String = "stable") -> String {
        ContainerImage.selectionID(imageID: id, repository: "demo", tag: tag)
    }
    private func imageTagList(id: String = "image-1", tags: String = "\"latest\",\"stable\"") -> String {
        "{\"success\":true,\"data\":{\"images\":[{\"id\":\"\(id)\",\"repository\":\"demo\",\"tags\":[\(tags)]}]}}"
    }

    func test虚拟机说明权重或自动启动未保存不能报成功() async throws {
        let cases: [(VirtualMachineUpdate, String)] = [
            (VirtualMachineUpdate(description: "new"), #""desc":"old""#),
            (VirtualMachineUpdate(description: ""), #""desc":null"#),
            (VirtualMachineUpdate(description: ""), #""unrelated":0"#),
            (VirtualMachineUpdate(cpuWeight: 64), #""cpu_weight":63"#),
            (VirtualMachineUpdate(cpuWeight: 64), #""cpu_weight":64.5"#),
            (VirtualMachineUpdate(cpuWeight: 8), #""cpu_weight":true"#),
            (VirtualMachineUpdate(autoStart: false), #""unrelated":0"#),
            (VirtualMachineUpdate(autoStart: false), #""autorun":false"#),
            (VirtualMachineUpdate(autoStart: false), #""autorun":"0""#),
            (VirtualMachineUpdate(autoStart: true), #""autorun":1"#)
        ]
        for (configuration, fields) in cases {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"测试","status":"shutdown"}]}}"#),
                response(#"{"success":true}"#),
                response("{\"success\":true,\"data\":{\"guests\":[{\"guest_id\":\"vm-1\",\"name\":\"测试\",\(fields)}]}}")
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], transport: transport)
            do { try await repository.updateVirtualMachine(id: "vm-1", configuration: configuration); XCTFail("没有精确回读证据不能报告保存成功") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict); XCTAssertFalse(error.isRetryable) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "set" }.count, 1)
        }
    }

    func test虚拟机内部修改不使用公开清单确认内部字段() async throws {
        let transport = SequencedServiceRoutingTransport(responses: [
            DsmAPIName.virtualizationAPIGuest: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"测试","status":"shutdown"}]}}"#)],
            DsmAPIName.virtualizationGuest: [response(#"{"success":true}"#), response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","desc":"new","cpu_weight":64,"autorun":2}]}}"#)]
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest], transport: transport)
        try await repository.updateVirtualMachine(id: "vm-1", configuration: VirtualMachineUpdate(description: "new", cpuWeight: 64, autoStart: true))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requestValue("api", in: requests[0]), DsmAPIName.virtualizationAPIGuest)
        XCTAssertEqual(requestValue("api", in: requests[2]), DsmAPIName.virtualizationGuest)
        XCTAssertEqual(requestValue("method", in: requests[2]), "list")
    }

    func test虚拟机修改不能以错误或重复身份确认() async throws {
        for guests in [
            #"[{"guest_id":"other","desc":"new"}]"#,
            #"[{"guest_id":"vm-1","desc":"new"},{"guest_id":"vm-1","desc":"new"}]"#
        ] {
            let transport = MockHTTPTransport(responses: [
                response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"测试","status":"shutdown"}]}}"#),
                response(#"{"success":true}"#), response("{\"success\":true,\"data\":{\"guests\":\(guests)}}")
            ])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], transport: transport)
            do { try await repository.updateVirtualMachine(id: "vm-1", configuration: VirtualMachineUpdate(description: "new")); XCTFail("目标身份不明确不能确认") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        }
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
                response(#"{"success":true}"#),
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
        XCTAssertEqual(requestValue("version", in: deletion), "1")
        XCTAssertFalse(requests.contains { requestValue("api", in: $0) == DsmAPIName.virtualizationAPITaskInfo })
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
            selectedVersionOverrides: [DsmAPIName.virtualizationNetwork: 2],
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
        XCTAssertEqual(requestValue("version", in: update), "1")
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
            selectedVersionOverrides: [DsmAPIName.virtualizationNetwork: 2],
            transport: transport
        )

        try await repository.deleteVirtualMachineNetworks(ids: ["network-1"])

        let requests = await transport.recordedRequests()
        let deletion = try XCTUnwrap(requests.first {
            requestValue("api", in: $0) == DsmAPIName.virtualizationNetwork
                && requestValue("method", in: $0) == "delete"
        })
        XCTAssertEqual(requestValue("network_id", in: deletion), #""network-1""#)
        XCTAssertEqual(requestValue("version", in: deletion), "1")
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
            selectedVersionOverrides: [DsmAPIName.virtualizationNetwork: 2],
            transport: transport
        )

        let result = try await repository.deleteVirtualMachineNetworksResult(
            ids: ["network-1"]
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(result.operation, "virtualMachineNetworkDelete")
        let requests = await transport.recordedRequests()
        let deletion = try XCTUnwrap(requests.first { requestValue("method", in: $0) == "delete" })
        XCTAssertEqual(requestValue("version", in: deletion), "1")
    }

    func test内部网络写不支持V1时不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let api = DsmAPIName.virtualizationNetwork
        let repository = try makeRepository(apiNames: [api], minimumVersionOverrides: [api: 2],
            selectedVersionOverrides: [api: 2], transport: transport)
        do { try await repository.updateVirtualMachineNetwork(id: "network-1", configuration: .init(name: "Synthetic")); XCTFail("不能使用只读版本写入") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        do { try await repository.deleteVirtualMachineNetworks(ids: ["network-1"]); XCTFail("不能使用只读版本删除") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test公开虚拟机多项删除固定版本逐项回读() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1", "vm-2"])),
            response(#"{"success":true}"#), response(virtualMachineListResponse(ids: ["vm-2"])),
            response(#"{"success":true}"#), response(virtualMachineListResponse(ids: [])),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest],
            selectedVersionOverrides: [DsmAPIName.virtualizationAPIGuest: 2], transport: transport)
        try await repository.deleteVirtualMachines(ids: ["vm-2", "vm-1"])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["list", "delete", "list", "delete", "list"])
        XCTAssertTrue(requests.allSatisfy { requestValue("api", in: $0) == DsmAPIName.virtualizationAPIGuest && requestValue("version", in: $0) == "1" })
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.compactMap { requestValue("guest_id", in: $0) }, ["vm-1", "vm-2"])
    }

    func test公开映像删除空响应和附加字段都不启动任务轮询() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for acknowledgement in [#"{"success":true}"#, #"{"success":true,"data":{"task_id":"unrelated"}}"#] {
                let transport = MockHTTPTransport(responses: [
                    response(#"{"success":true,"data":{"images":[{"image_id":"image-1"}]}}"#),
                    response(acknowledgement), response(#"{"success":true,"data":{"images":[]}}"#),
                ])
                let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestImage, DsmAPIName.virtualizationAPITaskInfo],
                    requestFormatOverrides: [DsmAPIName.virtualizationAPIGuestImage: format],
                    selectedVersionOverrides: [DsmAPIName.virtualizationAPIGuestImage: 2], transport: transport)
                try await repository.deleteVirtualMachineImages(ids: ["image-1"])
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 3)
                XCTAssertTrue(requests.allSatisfy { requestValue("api", in: $0) == DsmAPIName.virtualizationAPIGuestImage && requestValue("version", in: $0) == "1" })
                let deletion = try XCTUnwrap(requests.first { requestValue("method", in: $0) == "delete" })
                XCTAssertEqual(requestValue("image_id", in: deletion), format == .json ? #""image-1""# : "image-1")
            }
        }
    }

    func test公开删除未知后重复调用只读且不启动未执行项() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(virtualMachineListResponse(ids: ["vm-1", "vm-2"]))), .urlError(.timedOut),
            .response(response(virtualMachineListResponse(ids: ["vm-1", "vm-2"]))),
            .response(response(virtualMachineListResponse(ids: ["vm-1", "vm-2"]))),
            .response(response(virtualMachineListResponse(ids: ["vm-2"]))),
            .response(response(virtualMachineListResponse(ids: ["vm-2"]))), .response(response(#"{"success":true}"#)),
            .response(response(virtualMachineListResponse(ids: []))),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        let first = try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2"])
        XCTAssertEqual(first.status, .submittedButUnverified); XCTAssertEqual(first.counts.unknown, 1); XCTAssertEqual(first.counts.failed, 1)
        let retry = try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2"])
        XCTAssertEqual(retry.counts.unknown, 1)
        let reviewed = try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2"])
        XCTAssertEqual(reviewed.status, .partialSuccess); XCTAssertEqual(reviewed.counts.succeeded, 1); XCTAssertEqual(reviewed.counts.failed, 1)
        var requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
        let remaining = try await repository.deleteVirtualMachinesResult(ids: ["vm-2"])
        XCTAssertEqual(remaining.status, .confirmedSuccess)
        requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.compactMap { requestValue("guest_id", in: $0) }, ["vm-1", "vm-2"])
    }

    func test公开删除明确拒绝停止整批且不以他人删除覆盖拒绝() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1", "vm-2"])),
            response(#"{"success":false,"error":{"code":105}}"#),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2"])
        XCTAssertEqual(result.status, .permissionDenied); XCTAssertEqual(result.counts.failed, 2); XCTAssertEqual(result.counts.succeeded, 0)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }

    func test公开映像删除回读缺少数组不能冒充成功() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"images":[{"image_id":"image-1"},{"image_id":"image-2"}]}}"#),
            response(#"{"success":true}"#), response(#"{"success":true,"data":{}}"#),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestImage], transport: transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1", "image-2"])
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.counts.unknown, 1); XCTAssertEqual(result.counts.failed, 1)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    func test公开映像身份数组畸形在写入前失败() async throws {
        for payload in [#"{"images":[{"image_id":7}]}"#, #"{"images":[{"image_id":"image-1"},{"image_id":"image-1"}]}"#, #"{"images":{}}"#] {
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":\(payload)}")])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestImage], transport: transport)
            let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertFalse(result.submitted)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1)
        }
    }

    func test公开删除复合身份不发送请求() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1,vm-2"])
        XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test公开多项删除取消保留成功未知和未执行计数() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(response(virtualMachineListResponse(ids: ["vm-1", "vm-2", "vm-3"]))),
            .response(response(#"{"success":true}"#)), .response(response(virtualMachineListResponse(ids: ["vm-2", "vm-3"]))),
            .waitUntilCancelled,
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        let task = Task { try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2", "vm-3"]) }
        while await transport.recordedRequests().count < 4 { await Task.yield() }
        task.cancel(); let result = try await task.value
        XCTAssertEqual(result.status, .cancellationRequestedAfterSubmission)
        XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.unknown, 1); XCTAssertEqual(result.counts.failed, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.compactMap { requestValue("guest_id", in: $0) }, ["vm-1", "vm-2"])
    }

    func test公开删除认证失效保留认证语义() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1"])),
            response(#"{"success":false,"error":{"code":106}}"#),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        do {
            try await repository.deleteVirtualMachines(ids: ["vm-1"])
            XCTFail("认证失败不得冒充删除成功")
        } catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }

    func test公开删除不支持固定版本时不降级内部删除() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest],
            minimumVersionOverrides: [DsmAPIName.virtualizationAPIGuest: 2],
            selectedVersionOverrides: [DsmAPIName.virtualizationAPIGuest: 2], transport: transport)
        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        XCTAssertEqual(result.status, .unsupported); XCTAssertFalse(result.submitted)
        let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test公开删除后续目标已消失时不再发送删除() async throws {
        let transport = MockHTTPTransport(responses: [
            response(virtualMachineListResponse(ids: ["vm-1", "vm-2"])),
            response(#"{"success":true}"#), response(virtualMachineListResponse(ids: [])),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
        let result = try await repository.deleteVirtualMachinesResult(ids: ["vm-1", "vm-2"])
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1); XCTAssertEqual(result.counts.failed, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { requestValue("method", in: $0) == "delete" }.count, 1)
    }

    func test公开电源按单台身份固定版本并严格回读() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for (action, method) in [(VirtualMachinePowerAction.powerOn, "poweron"), (.shutdown, "shutdown"), (.powerOff, "poweroff")] {
                let initial = action == .powerOn ? "shutdown" : "running"
                let desired = action == .powerOn ? "running" : "shutdown"
                let transport = MockHTTPTransport(responses: [
                    powerTarget("vm-1", initial), powerTarget("vm-2", initial),
                    powerTarget("vm-1", initial), response(#"{"success":true}"#), powerTarget("vm-1", desired),
                    powerTarget("vm-2", initial), response(#"{"success":true}"#), powerTarget("vm-2", desired),
                ])
                let apis = [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIGuestAction]
                let repository = try makeRepository(apiNames: apis,
                    requestFormatOverrides: Dictionary(uniqueKeysWithValues: apis.map { ($0, format) }),
                    selectedVersionOverrides: Dictionary(uniqueKeysWithValues: apis.map { ($0, 2) }), transport: transport)
                try await repository.controlVirtualMachines(ids: ["vm-2", "vm-1", "vm-1"], action: action)
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 8)
                XCTAssertTrue(requests.allSatisfy { requestValue("version", in: $0) == "1" })
                XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get", "get", method, "get", "get", method, "get"])
                let actions = requests.filter { requestValue("api", in: $0) == DsmAPIName.virtualizationAPIGuestAction }
                XCTAssertEqual(actions.compactMap { requestValue("guest_id", in: $0) }, format == .json ? [#""vm-1""#, #""vm-2""#] : ["vm-1", "vm-2"])
            }
        }
    }

    func test公开电源重启不猜测方法或自动转为强制开关机() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction,
            DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuestAction], transport: transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .restart); XCTFail("公开 v1 没有重启契约") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test公开电源非法身份和缺固定版本均零请求() async throws {
        for ids in [[String](), ["vm-1,vm-2"], [" vm-1"], ["vm\\1"], ["vm\n1"]] {
            let transport = MockHTTPTransport(responses: [])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
            do { try await repository.controlVirtualMachines(ids: ids, action: .powerOn); XCTFail("非法身份不得发送请求") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        }
        for missing in [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationAPIGuestAction] {
            let transport = MockHTTPTransport(responses: [])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest],
                minimumVersionOverrides: [missing: 2], selectedVersionOverrides: [missing: 2], transport: transport)
            do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("不支持 v1 时不得改用 v2") }
            catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
            let requests = await transport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        }
    }

    func test公开电源尾项不满足状态时整批零写() async throws {
        let transport = MockHTTPTransport(responses: [powerTarget("vm-1", "shutdown"), powerTarget("vm-2", "running")])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1", "vm-2"], action: .powerOn); XCTFail("必须先检查全部目标") } catch {}
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get"])
    }

    func test公开电源提交前身份变化不能继续() async throws {
        let transport = MockHTTPTransport(responses: [powerTarget("vm-1", "shutdown"), powerTarget("vm-1", "shutdown", name: "renamed")])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("身份变化必须重新确认") } catch {}
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get"])
    }

    func test公开电源畸形读取不当作默认关机() async throws {
        for data in [#"{"guest_id":1,"guest_name":"vm-1","status":"shutdown"}"#,
                     #"{"guest_id":"vm-1","status":"shutdown"}"#,
                     #"{"guest_id":"vm-2","guest_name":"vm-1","status":"shutdown"}"#,
                     #"{"guest_id":"vm-1","guest_name":"vm-1","status":false}"#] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":\#(data)}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
            do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("畸形回读不能执行电源") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1)
        }
    }

    func test公开电源丢回执后整批只核对不继续尾项() async throws {
        let transport = MockHTTPTransport(steps: [
            .response(powerTarget("vm-1", "shutdown")), .response(powerTarget("vm-2", "shutdown")),
            .response(powerTarget("vm-1", "shutdown")), .urlError(.timedOut), .response(powerTarget("vm-1", "running")),
        ])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        for _ in 0..<2 {
            do { try await repository.controlVirtualMachines(ids: ["vm-1", "vm-2"], action: .powerOn); XCTFail("丢回执及仅恢复部分目标不应报告整批完成") } catch {}
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get", "get", "poweron", "get"])
    }

    func test公开电源未确认时反向动作删除和编辑零请求() async throws {
        let transport = MockHTTPTransport(responses: [powerTarget("vm-1", "running"), powerTarget("vm-1", "running"),
            response(#"{"success":true}"#), powerTarget("vm-1", "shutting_down"), powerTarget("vm-1", "shutdown")])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest,
            DsmAPIName.virtualizationGuest], transport: transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .shutdown); XCTFail("回执不等于状态已改变") } catch {}
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOff); XCTFail("未知操作不能升级为断电") } catch {}
        let deletion = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        XCTAssertNotEqual(deletion.status, .confirmedSuccess)
        do { try await repository.updateVirtualMachine(id: "vm-1", configuration: VirtualMachineUpdate(name: "changed")); XCTFail("未知电源期间不编辑") } catch {}
        let beforeReview = await transport.recordedRequests(); XCTAssertEqual(beforeReview.count, 4)
        try await repository.controlVirtualMachines(ids: ["vm-1"], action: .shutdown)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get", "shutdown", "get", "get"])
    }

    func test公开电源明确拒绝保留认证语义且不回读伪成功() async throws {
        let transport = MockHTTPTransport(responses: [powerTarget("vm-1", "shutdown"), powerTarget("vm-1", "shutdown"),
            response(#"{"success":false,"error":{"code":119}}"#)])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("拒绝不得转为成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }

    func test公开电源提交后取消再次操作只读() async throws {
        let transport = MockHTTPTransport(steps: [.response(powerTarget("vm-1", "shutdown")), .response(powerTarget("vm-1", "shutdown")),
            .waitUntilCancelled, .response(powerTarget("vm-1", "running"))])
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        let task = Task { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn) }
        while await transport.recordedRequests().count < 3 { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("取消不得报告已完成") } catch {}
        try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { requestValue("method", in: $0) }, ["get", "get", "poweron", "get"])
    }

    func test公开电源在途重复操作和删除不发请求() async throws {
        let base = MockHTTPTransport(responses: [powerTarget("vm-1", "shutdown"), powerTarget("vm-1", "shutdown"),
            response(#"{"success":true}"#), powerTarget("vm-1", "running")])
        let transport = HoldingServiceReadTransport(base: base)
        let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuestAction, DsmAPIName.virtualizationAPIGuest], transport: transport)
        let task = Task { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn) }
        await transport.waitForRead()
        do { try await repository.controlVirtualMachines(ids: ["vm-1"], action: .powerOn); XCTFail("重复提交不能进入读取或写入") } catch {}
        let deletion = try await repository.deleteVirtualMachinesResult(ids: ["vm-1"])
        XCTAssertNotEqual(deletion.status, .confirmedSuccess)
        let heldRequests = await base.recordedRequests(); XCTAssertTrue(heldRequests.isEmpty)
        await transport.release()
        try await task.value
        let requests = await base.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    private func powerTarget(_ id: String, _ status: String, name: String? = nil) -> DsmHTTPResponse {
        response(#"{"success":true,"data":{"guest_id":"\#(id)","guest_name":"\#(name ?? id)","status":"\#(status)"}}"#)
    }

    func test公开和内部管理清单保留启动三态() async throws {
        for api in [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest] {
            for mode in VirtualMachineStartupBehavior.allCases {
                let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"Synthetic","name":"Synthetic","status":"shutdown","autorun":\#(mode.rawValue)}]}}"#)])
                let repository = try makeRepository(apiNames: [api], transport: transport)
                let snapshot = try await repository.loadVirtualMachineManager()
                XCTAssertEqual(snapshot.machines.first?.startupBehavior, mode)
            }
        }
    }

    func test未知启动值不被管理清单显示为关闭或启动() async throws {
        for raw in ["true", "false", "\"2\"", "3", "0.5", "null"] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown","autorun":\#(raw)}]}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], transport: transport)
            let snapshot = try await repository.loadVirtualMachineManager()
            XCTAssertEqual(snapshot.machines.count, 1)
            XCTAssertNil(snapshot.machines.first?.startupBehavior)
        }
    }

    func test公开只读摘要支持三态并拒绝布尔字符串或越界值() async throws {
        for mode in VirtualMachineStartupBehavior.allCases {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"Synthetic","status":"shutdown","autorun":\#(mode.rawValue)}]}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
            let snapshot = try await repository.loadVirtualMachineInventory()
            XCTAssertEqual(snapshot.machines.first?.startupBehavior, mode)
        }
        for raw in ["true", "false", "\"1\"", "3", "-1", "1.5"] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","guest_name":"Synthetic","status":"shutdown","autorun":\#(raw)}]}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationAPIGuest], transport: transport)
            do { _ = try await repository.loadVirtualMachineInventory(); XCTFail("不猜测非三态 autorun") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test优先级读取保留原生整数而不截断或转换其他类型() async throws {
        for (raw, expected) in [("1024", Optional(1024)), ("128", Optional(128)), ("64.5", nil), ("true", nil), ("\"64\"", nil), ("-1", nil)] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown","cpu_weight":\#(raw)}]}}"#)])
            let repository = try makeRepository(apiNames: [DsmAPIName.virtualizationGuest], transport: transport)
            let snapshot = try await repository.loadVirtualMachineManager()
            XCTAssertEqual(snapshot.machines.first?.cpuWeight, expected)
        }
    }

    func test内部设置三态和五档优先级固定V1且严格回读() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for (weight, mode) in [(8, VirtualMachineStartupBehavior.off), (64, .restorePreviousState), (256, .powerOn), (512, .off), (1024, .powerOn)] {
                let transport = MockHTTPTransport(responses: [
                    response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown"}]}}"#),
                    response(#"{"success":true}"#),
                    response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","cpu_weight":\#(weight),"autorun":\#(mode.rawValue)}]}}"#),
                ])
                let api = DsmAPIName.virtualizationGuest
                let repository = try makeRepository(apiNames: [api], requestFormatOverrides: [api: format], selectedVersionOverrides: [api: 2], transport: transport)
                try await repository.updateVirtualMachine(id: "vm-1", configuration: .init(cpuWeight: weight, startupBehavior: mode))
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 3)
                XCTAssertEqual(requestValue("version", in: requests[1]), "1")
                XCTAssertEqual(requestValue("version", in: requests[2]), "2")
                XCTAssertEqual(requestValue("cpu_weight", in: requests[1]), String(weight))
                XCTAssertEqual(requestValue("autorun", in: requests[1]), String(mode.rawValue))
            }
        }
    }

    func test内部编辑不支持V1时零请求且未记录权重零写() async throws {
        let unavailable = MockHTTPTransport(responses: [])
        let api = DsmAPIName.virtualizationGuest
        let repository = try makeRepository(apiNames: [api], minimumVersionOverrides: [api: 2], selectedVersionOverrides: [api: 2], transport: unavailable)
        do { try await repository.updateVirtualMachine(id: "vm-1", configuration: .init(startupBehavior: .powerOn)); XCTFail("不能猜 v2 保存") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let unsupportedRequests = await unavailable.recordedRequests(); XCTAssertTrue(unsupportedRequests.isEmpty)
        for weight in [1, 128, 1025] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"guests":[{"guest_id":"vm-1","name":"Synthetic","status":"shutdown"}]}}"#)])
            let repository = try makeRepository(apiNames: [api], transport: transport)
            do { try await repository.updateVirtualMachine(id: "vm-1", configuration: .init(cpuWeight: weight)); XCTFail("新写仅使用已记录档位") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(requests.contains { requestValue("method", in: $0) == "set" })
        }
    }

    private func makeRepository(
        apiNames: [String],
        requestFormatOverrides: [String: DsmRequestFormat] = [:],
        minimumVersionOverrides: [String: Int] = [:],
        selectedVersionOverrides: [String: Int] = [:],
        containerNetworkCreationEnabled: Bool = false,
        transport: any DsmHTTPTransport
    ) throws -> DsmServiceManagementRepository {
        let capabilities = Dictionary(uniqueKeysWithValues: apiNames.map { name in
            (
                name,
                ApiCapability(
                    name: name,
                    path: "entry.cgi",
                    minVersion: minimumVersionOverrides[name] ?? 1,
                    maxVersion: 2,
                    requestFormat: requestFormatOverrides[name] ?? .form,
                    selectedVersion: selectedVersionOverrides[name] ?? (name.contains("DownloadStation2") ? 2 : 1)
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
            transport: transport,
            containerNetworkCreationEnabled: containerNetworkCreationEnabled
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

    private func downloadTaskListResponse(
        ids: [String],
        destination: String? = nil
    ) -> DsmHTTPResponse {
        let tasks = ids.map { id in
            if let destination {
                return #"{"id":"\#(id)","title":"示例任务","status":"waiting","additional":{"detail":{"destination":"\#(destination)"}}}"#
            }
            return #"{"id":"\#(id)","title":"示例任务","status":"waiting"}"#
        }.joined(separator: ",")
        return response(
            #"{"success":true,"data":{"tasks":[\#(tasks)],"offset":0,"total":\#(ids.count)}}"#
        )
    }

    private func containerListResponse(ids: [String]) -> String {
        let containers = ids.map {
            #"{"id":"\#($0)","name":"\#($0)","image":"demo:latest","status":"stopped","is_package":false,"Labels":{},"State":{"Running":false,"Paused":false,"Restarting":false}}"#
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

private actor HoldingServiceReadTransport: DsmHTTPTransport {
    let base: any DsmHTTPTransport
    private var shouldHold = true
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    init(base: any DsmHTTPTransport) { self.base = base }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                held = continuation
                ready?.resume()
                ready = nil
            }
        }
        return try await base.send(request)
    }
    func waitForRead() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { held?.resume(); held = nil }
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
