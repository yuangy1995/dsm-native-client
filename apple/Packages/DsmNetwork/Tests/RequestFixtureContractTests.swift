import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class RequestFixtureContractTests: XCTestCase {
    func test收藏分页请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/list-favorites/synthetic-page/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"offset":0,"total":0,"favorites":[]}}"#)
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationFavorite: capability(
                    DsmAPIName.fileStationFavorite,
                    version: 2
                )
            ]),
            transport: transport
        )

        _ = try await repository.listFavoritesPage(offset: 0, limit: 100)

        let requests = await transport.recordedRequests()
        try assertFormRequest(try XCTUnwrap(requests.first), matches: fixture)
    }

    func test虚拟文件夹请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/list-virtual-folders/synthetic-cifs-page/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"support_virtual_protocol":"cifs"}}"#),
            response(#"{"success":true,"data":{"offset":0,"total":0,"folders":[]}}"#),
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationInfo: capability(
                    DsmAPIName.fileStationInfo,
                    version: 2
                ),
                DsmAPIName.fileStationVirtualFolder: capability(
                    DsmAPIName.fileStationVirtualFolder,
                    version: 2
                )
            ]),
            transport: transport
        )

        _ = try await repository.listVirtualFolders(offset: 0, limit: 100)

        let requests = await transport.recordedRequests()
        try assertFormRequest(try XCTUnwrap(requests.last), matches: fixture)
    }

    func test分享链接创建请求经结果型调用链后与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/create-share-link/synthetic-target/request.json"
        )
        let targetPath = "/<synthetic-path>"
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"files":[{"name":"<synthetic-path>","path":"/<synthetic-path>","isdir":false,"additional":{"size":12,"owner":{"user":"tester","group":"users"},"time":{"mtime":1700000000},"perm":{"adv_right":{"read":true,"write":false,"delete":false}}}}]}}"#
            ),
            response(#"{"success":true,"data":{"offset":0,"total":0,"links":[]}}"#),
            response(
                #"{"success":true,"data":{"links":[{"id":"synthetic-link","path":"/<synthetic-path>","url":"https://share.example.invalid/synthetic","qrcode":"synthetic","error":0}]}}"#
            ),
            response(
                #"{"success":true,"data":{"offset":0,"total":1,"links":[{"id":"synthetic-link","name":"Synthetic","path":"/<synthetic-path>","url":"https://share.example.invalid/synthetic","has_password":true,"date_expired":"2026-08-20"}]}}"#
            ),
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationList: capability(
                    DsmAPIName.fileStationList,
                    version: 2
                ),
                DsmAPIName.fileStationSharing: capability(
                    DsmAPIName.fileStationSharing,
                    version: fixture.api.resolvedVersion
                ),
            ]),
            transport: transport
        )
        let target = FileItem(
            profileID: repository.profileID,
            name: "<synthetic-path>",
            path: targetPath,
            kind: .file,
            sizeBytes: 12,
            owner: "tester",
            group: "users",
            times: FileTimes(
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                createdAt: nil,
                accessedAt: nil
            ),
            permissions: FilePermissions(
                canRead: true,
                canWrite: false,
                canDelete: false,
                posixMode: nil
            )
        )

        let outcome = try await repository.createShareLinkResult(
            FileShareLinkCreateRequest(
                target: target,
                password: "EPHEMERAL16",
                availableOn: try FileShareLinkCalendarDate(iso8601: "2026-08-10"),
                expiresOn: try FileShareLinkCalendarDate(iso8601: "2026-08-20")
            )
        )

        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        let createRequest = try XCTUnwrap(requests.first {
            (try? decodeForm($0.httpBody)["method"]) == "create"
        })
        try assertFormRequest(createRequest, matches: fixture)
        XCTAssertFalse(createRequest.url?.absoluteString.contains("EPHEMERAL16") == true)
    }

    func test分享链接列表请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/list-share-links/synthetic-page/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"offset":0,"total":0,"links":[]}}"#)
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationList: capability(
                    DsmAPIName.fileStationList,
                    version: 2
                ),
                DsmAPIName.fileStationSharing: capability(
                    DsmAPIName.fileStationSharing,
                    version: fixture.api.resolvedVersion
                ),
            ]),
            transport: transport
        )

        _ = try await repository.listShareLinksPage(offset: 0, limit: 500)

        let requests = await transport.recordedRequests()
        try assertFormRequest(try XCTUnwrap(requests.first), matches: fixture)
    }

    func test排序筛选目录请求经Repository调用链后与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/list-folder/synthetic-sorted-filtered/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"offset":0,"total":0,"files":[]}}"#)
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationList: capability(
                    DsmAPIName.fileStationList,
                    version: fixture.api.resolvedVersion
                ),
            ]),
            transport: transport
        )

        _ = try await repository.listFolder(
            path: "<synthetic-folder>",
            offset: 0,
            limit: 200,
            options: FileListOptions(
                sortField: .modifiedTime,
                sortDirection: .descending,
                typeFilter: .files
            )
        )

        let requests = await transport.recordedRequests()
        try assertFormRequest(try XCTUnwrap(requests.first), matches: fixture)
    }

    func test删除请求经Repository调用链后与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/delete/synthetic-task/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"taskid":"synthetic-delete-task"}}"#),
            response(#"{"success":true,"data":{"finished":true}}"#),
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationDelete: capability(
                    DsmAPIName.fileStationDelete,
                    version: fixture.api.resolvedVersion
                ),
            ]),
            transport: transport
        )

        try await repository.delete(paths: ["<synthetic-path>"]) { _, _ in }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            try requests.map { try decodeForm($0.httpBody)["method"] },
            ["start", "status"]
        )
        try assertFormRequest(try XCTUnwrap(requests.first), matches: fixture)
    }

    func test移动请求经Repository调用链后与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "file-station/move/synthetic-task/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"taskid":"synthetic-move-task"}}"#),
            response(#"{"success":true,"data":{"finished":true}}"#),
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationCopyMove: capability(
                    DsmAPIName.fileStationCopyMove,
                    version: fixture.api.resolvedVersion
                ),
            ]),
            transport: transport
        )

        try await repository.move(
            paths: ["<synthetic-path>"],
            to: "<synthetic-destination>",
            overwrite: true
        ) { _, _ in }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            try requests.map { try decodeForm($0.httpBody)["method"] },
            ["start", "status"]
        )
        try assertFormRequest(try XCTUnwrap(requests.first), matches: fixture)
    }

    func test覆盖上传请求遵守Apple凭据查询收敛并保留共享Fixture业务约束() async throws {
        let fixture = try loadFixture(
            "file-station/upload/synthetic-overwrite/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
        ])
        let repository = try makeRepository(
            capabilities: CapabilitySet([
                DsmAPIName.fileStationUpload: capability(
                    DsmAPIName.fileStationUpload,
                    version: 2
                ),
                DsmAPIName.fileStationCheckPermission: capability(
                    DsmAPIName.fileStationCheckPermission,
                    version: 1
                ),
            ]),
            transport: transport
        )
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-upload.bin")
        try Data("synthetic".utf8).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }

        try await repository.upload(
            localURL: localFile,
            to: "<synthetic-destination>",
            overwrite: true
        ) { _, _ in }

        let requests = await transport.recordedRequests()
        let uploadRequest = try XCTUnwrap(requests.last)
        let bodies = await transport.recordedUploadBodies()
        let uploadBody = try XCTUnwrap(bodies.last)
        try assertMultipartRequest(
            uploadRequest,
            body: uploadBody,
            matches: fixture,
            expectedAuthentication: appleAuthenticationExpectation(for: fixture)
        )
        let queryItems = URLComponents(
            url: try XCTUnwrap(uploadRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "_sid" }))
        XCTAssertNil(queryItems.first(where: { $0.name == "SynoToken" }))
        XCTAssertNil(queryItems.first(where: { $0.name == "synotoken" }))
    }

    func test账号创建请求与共享Fixture一致且不保存密码值() async throws {
        let fixture = try loadFixture(
            "users/create/synthetic-account/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
        ])
        let repository = try makeAdministrationRepository(transport: transport)

        try await repository.saveAccount(
            NasAccountDraft(
                name: "<synthetic-account>",
                description: "<synthetic-description>",
                email: "<synthetic-email>",
                password: "SYNTHETIC_EPHEMERAL_SECRET",
                passwordConfirmation: "SYNTHETIC_EPHEMERAL_SECRET"
            )
        )

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        try assertFormRequest(request, matches: fixture)
        XCTAssertFalse(
            request.url?.absoluteString.contains("SYNTHETIC_EPHEMERAL_SECRET")
                == true
        )
    }

    func test账号删除请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "users/delete/synthetic-account/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
        ])
        let repository = try makeAdministrationRepository(transport: transport)

        try await repository.deleteAccount(name: "<synthetic-account>")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        try assertFormRequest(request, matches: fixture)
    }

    func test群组删除请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "groups/delete/synthetic-group/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreGroup],
            transport: transport
        )

        try await repository.deleteGroup(name: "<synthetic-group>")

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        try assertFormRequest(request, matches: fixture)
    }

    func test套件卸载请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "packages/uninstall/synthetic-package/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"packages":[{"id":"<synthetic-package>","name":"Synthetic Package","version":"1.0","additional":{"status":"stopped","dsm_apps":"<synthetic-app-one> <synthetic-app-two>","ctl_uninstall":true,"available_operation":["uninstall"]}}]}}"#
            ),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"packages":[]}}"#),
        ])
        let repository = try makePackageAdministrationRepository(
            transport: transport
        )
        _ = try await repository.loadPackages()

        _ = try await repository.uninstallPackageResult(
            id: "<synthetic-package>"
        )

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(
            requests.first {
                (try? decodeForm($0.httpBody)["method"]) == "uninstall"
            }
        )
        try assertFormRequest(request, matches: fixture)
    }

    func test套件启动与停止请求和共享Fixture一致且写后回读() async throws {
        let startFixture = try loadFixture(
            "packages/start/synthetic-package/request.json"
        )
        let stopFixture = try loadFixture(
            "packages/stop/synthetic-package/request.json"
        )
        let stopped = response(
            #"{"success":true,"data":{"packages":[{"id":"<synthetic-package>","name":"Synthetic Package","version":"1.0","additional":{"status":"stopped","startable":true,"dsm_apps":"<synthetic-app-one> <synthetic-app-two>","available_operation":["start"]}}]}}"#
        )
        let running = response(
            #"{"success":true,"data":{"packages":[{"id":"<synthetic-package>","name":"Synthetic Package","version":"1.0","additional":{"status":"running","startable":true,"dsm_apps":"<synthetic-app-one> <synthetic-app-two>","available_operation":["stop"]}}]}}"#
        )
        let accepted = response(#"{"success":true}"#)

        let startTransport = MockHTTPTransport(
            responses: [stopped, accepted, accepted, running]
        )
        let startRepository = try makePackageAdministrationRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: startTransport
        )
        let startResult = try await startRepository.controlPackageResult(
            id: "<synthetic-package>",
            action: .start
        )
        let startRequests = await startTransport.recordedRequests()
        let startRequest = try XCTUnwrap(
            startRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "start"
            }
        )

        XCTAssertEqual(startResult.status, .confirmedSuccess)
        XCTAssertEqual(
            startRequests.compactMap {
                try? decodeForm($0.httpBody)["method"]
            },
            ["list", "feasibility_check", "start", "list"]
        )
        try assertFormRequest(startRequest, matches: startFixture)

        let stopTransport = MockHTTPTransport(
            responses: [running, accepted, accepted, stopped]
        )
        let stopRepository = try makePackageAdministrationRepository(
            apiNames: [
                DsmAPIName.corePackage,
                DsmAPIName.corePackageControl,
            ],
            transport: stopTransport
        )
        let stopResult = try await stopRepository.controlPackageResult(
            id: "<synthetic-package>",
            action: .stop
        )
        let stopRequests = await stopTransport.recordedRequests()
        let stopRequest = try XCTUnwrap(
            stopRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "stop"
            }
        )

        XCTAssertEqual(stopResult.status, .confirmedSuccess)
        XCTAssertEqual(
            stopRequests.compactMap {
                try? decodeForm($0.httpBody)["method"]
            },
            ["list", "feasibility_check", "stop", "list"]
        )
        try assertFormRequest(stopRequest, matches: stopFixture)
    }

    func test容器删除请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "container-manager/delete/synthetic-container/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"containers":[]}}"#),
        ])
        let repository = try makeServiceManagementRepository(
            apiNames: [DsmAPIName.dockerContainer],
            transport: transport
        )

        try await repository.deleteContainers(ids: ["<synthetic-container>"])

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        try assertFormRequest(request, matches: fixture)
    }

    func test虚拟机删除请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "vmm/delete/synthetic-virtual-machine/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"guests":[]}}"#),
        ])
        let repository = try makeServiceManagementRepository(
            apiNames: [DsmAPIName.virtualizationAPIGuest],
            transport: transport
        )

        try await repository.deleteVirtualMachines(
            ids: ["<synthetic-virtual-machine>"]
        )

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        try assertFormRequest(request, matches: fixture)
    }

    func test服务子资源删除请求与共享Fixture一致() throws {
        let cases: [
            (
                path: String,
                format: DsmRequestFormat,
                parameters: [String: DsmParameterValue]
            )
        ] = [
            (
                "download-station/delete/synthetic-task/request.json",
                .form,
                [
                    "id": .string("<synthetic-download-task>"),
                    "force_complete": .boolean(true),
                ]
            ),
            (
                "container-manager/delete-image/synthetic-image/request.json",
                .form,
                ["id": .string("<synthetic-container-image>")]
            ),
            (
                "container-manager/delete-network/synthetic-network/request.json",
                .form,
                ["id": .string("<synthetic-container-network>")]
            ),
            (
                "vmm/delete-image/synthetic-image/request.json",
                .form,
                ["image_id": .string("<synthetic-virtual-machine-image>")]
            ),
            (
                "vmm/delete-network/synthetic-network/request.json",
                .json,
                ["network_id": .string("<synthetic-virtual-machine-network>")]
            ),
        ]

        for item in cases {
            let fixture = try loadFixture(item.path)
            let request = try DsmRequestBuilder.build(
                baseURL: try XCTUnwrap(
                    URL(string: "https://nas.example.invalid:5001")
                ),
                path: fixture.api.resolvedPath,
                api: fixture.api.name,
                version: fixture.api.resolvedVersion,
                method: fixture.api.method,
                requestFormat: item.format,
                parameters: item.parameters,
                credential: testCredential
            )

            try assertFormRequest(request, matches: fixture)
        }
    }

    func test远程访问复合请求与共享Fixture一致() async throws {
        let fixtures = try [
            loadFixture("network/set-relay/synthetic-setting/request.json"),
            loadFixture(
                "network/set-router-configuration/synthetic-setting/request.json"
            )
        ]
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"relay_enabled":true}}"#),
            response(#"{"success":true,"data":{"enabled":false}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"relay_enabled":false}}"#),
            response(#"{"success":true,"data":{"enabled":true}}"#)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.coreQuickConnect,
                DsmAPIName.coreQuickConnectUPnP
            ],
            transport: transport
        )

        let result = try await repository.saveRemoteAccessSettingsResult(
            NasRemoteAccessSettings(
                isRelayEnabled: false,
                isRouterConfigurationEnabled: true,
                canDisableRelay: true
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        for (request, fixture) in zip(requests[2...3], fixtures) {
            try assertFormRequest(request, matches: fixture)
        }
    }

    func test文件服务复合请求与共享Fixture一致() async throws {
        let fixtures = try [
            loadFixture(
                "file-services/set-smb/synthetic-settings/request.json"
            ),
            loadFixture(
                "file-services/set-nfs/synthetic-settings/request.json"
            ),
            loadFixture(
                "file-services/set-ftp/synthetic-settings/request.json"
            ),
            loadFixture(
                "file-services/set-sftp/synthetic-settings/request.json"
            ),
            loadFixture(
                "file-services/set-web-discovery/synthetic-settings/request.json"
            ),
            loadFixture(
                "file-services/set-time-machine/synthetic-settings/request.json"
            )
        ]
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_samba":false}}"#),
            response(#"{"success":true,"data":{"enable_nfs":false}}"#),
            response(#"{"success":true,"data":{"enable_ftp":false,"enable_ftps":false,"portnum":21}}"#),
            response(#"{"success":true,"data":{"enable":false,"portnum":22}}"#),
            response(#"{"success":true,"data":{"enable_ssdp":false,"enable_avahi":true}}"#),
            response(#"{"success":true,"data":{"enable_smb_time_machine":false}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable_samba":true}}"#),
            response(#"{"success":true,"data":{"enable_nfs":true}}"#),
            response(#"{"success":true,"data":{"enable_ftp":true,"enable_ftps":true,"portnum":2121}}"#),
            response(#"{"success":true,"data":{"enable":true,"portnum":2222}}"#),
            response(#"{"success":true,"data":{"enable_ssdp":true,"enable_avahi":false}}"#),
            response(#"{"success":true,"data":{"enable_smb_time_machine":true}}"#)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.coreFileServiceSMB,
                DsmAPIName.coreFileServiceNFS,
                DsmAPIName.coreFileServiceFTP,
                DsmAPIName.coreFileServiceSFTP,
                DsmAPIName.coreWebDSM,
                DsmAPIName.coreFileServiceDiscovery
            ],
            transport: transport
        )

        let result = try await repository.saveFileServiceSettingsResult(
            NasFileServiceSettings(
                isSMBEnabled: true,
                isNFSEnabled: true,
                isFTPEnabled: true,
                isFTPSEnabled: true,
                ftpPort: 2_121,
                isSFTPEnabled: true,
                sftpPort: 2_222,
                isSSDPEnabled: true,
                isBonjourEnabled: false,
                isSMBTimeMachineEnabled: true
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(
            result.counts,
            try MutationResultCounts(succeeded: 6, failed: 0, unknown: 0)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 18)
        for (request, fixture) in zip(requests[6...11], fixtures) {
            try assertFormRequest(request, matches: fixture)
        }
    }

    func test远程终端请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "terminal/set-settings/synthetic-settings/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable_ssh":true,"enable_telnet":true,"ssh_port":2222}}"#)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreTerminal],
            transport: transport
        )

        let result = try await repository.saveTerminalSettingsResult(
            NasTerminalSettings(
                isSSHEnabled: true,
                isTelnetEnabled: true,
                sshPort: 2_222
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        try assertFormRequest(requests[1], matches: fixture)
    }

    func test互联网代理请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "network/set-proxy/synthetic-settings/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"enable":false,"http_host":"","http_port":8080}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"enable":true,"http_host":"proxy.example.invalid","http_port":3128}}"#)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreNetworkProxy],
            transport: transport
        )

        let result = try await repository.saveProxySettingsResult(
            NasProxySettings(
                isEnabled: true,
                host: "proxy.example.invalid",
                port: 3_128
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        try assertFormRequest(requests[1], matches: fixture)
    }

    func test区域配置与立即校时请求与共享Fixture一致() async throws {
        let setFixture = try loadFixture(
            "region/set-settings/synthetic-settings/request.json"
        )
        let syncFixture = try loadFixture(
            "region/synchronize-time/synthetic-servers/request.json"
        )
        let current = #"{"success":true,"data":{"date_format":"Y-m-d","time_format":"H:i","timezone":"Asia/Shanghai","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let updated = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":"time.example.invalid","date":"2026/7/26","hour":18,"minute":30,"second":10}}"#
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"Asia/Shanghai","display":"Synthetic Local"},{"value":"UTC","display":"Synthetic UTC"}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(current),
            response(zones),
            response(#"{"success":true}"#),
            response(updated),
            response(zones),
            response(#"{"success":true}"#),
            response(updated),
            response(zones)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreRegionNTP],
            transport: transport
        )

        let result = try await repository.saveRegionSettingsResult(
            NasRegionSettings(
                dateFormat: "Y/m/d",
                timeFormat: "H:i",
                timeZone: "UTC",
                isNetworkTimeEnabled: true,
                timeServers: ["time.example.invalid"],
                manualDate: nil,
                timeZones: [
                    NasTimeZoneOption(id: "Asia/Shanghai", displayName: "Synthetic Local"),
                    NasTimeZoneOption(id: "UTC", displayName: "Synthetic UTC")
                ]
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 8)
        let setRequest = try XCTUnwrap(
            requests.first {
                (try? decodeForm($0.httpBody)["method"]) == "set"
            }
        )
        let syncRequest = try XCTUnwrap(
            requests.first {
                (try? decodeForm($0.httpBody)["method"]) == "sync"
            }
        )
        try assertFormRequest(setRequest, matches: setFixture)
        try assertFormRequest(syncRequest, matches: syncFixture)
    }

    func testDDNS四类独立请求与共享Fixture一致且不保存凭据值() async throws {
        let testFixture = try loadFixture(
            "ddns/test-provider/synthetic-record/request.json"
        )
        let createFixture = try loadFixture(
            "ddns/create-record/synthetic-record/request.json"
        )
        let updateFixture = try loadFixture(
            "ddns/update-address/synthetic-record/request.json"
        )
        let deleteFixture = try loadFixture(
            "ddns/delete-record/synthetic-record/request.json"
        )
        let providers = #"{"success":true,"data":{"providers":[{"id":"Example","display":"Synthetic Provider"}]}}"#
        let emptyRecords = #"{"success":true,"data":{"records":[]}}"#
        let records = #"{"success":true,"data":{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"synthetic-owner","enable":true,"heartbeat":false}]}}"#
        let draft = NasDDNSDraft(
            providerID: "Example",
            hostname: "nas.example.invalid",
            username: "synthetic-owner",
            password: "SYNTHETIC_EPHEMERAL_SECRET",
            ipv4: "<synthetic-ipv4>",
            ipv6: "<synthetic-ipv6>",
            interfaceV4: "<synthetic-interface-v4>",
            interfaceV6: "<synthetic-interface-v6>"
        )

        let testTransport = MockHTTPTransport(responses: [
            response(providers),
            response(emptyRecords),
            response(#"{"success":true}"#)
        ])
        let testRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: testTransport
        )
        _ = try await testRepository.testDDNSResult(draft)
        let testRequests = await testTransport.recordedRequests()
        let testRequest = try XCTUnwrap(
            testRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "test"
            }
        )
        try assertFormRequest(testRequest, matches: testFixture)

        let createTransport = MockHTTPTransport(responses: [
            response(providers),
            response(emptyRecords),
            response(#"{"success":true}"#),
            response(providers),
            response(records)
        ])
        let createRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: createTransport
        )
        _ = try await createRepository.saveDDNSResult(draft)
        let createRequests = await createTransport.recordedRequests()
        let createRequest = try XCTUnwrap(
            createRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "create"
            }
        )
        try assertFormRequest(createRequest, matches: createFixture)

        let updateTransport = MockHTTPTransport(responses: [
            response(providers),
            response(records),
            response(#"{"success":true}"#),
            response(providers),
            response(records)
        ])
        let updateRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: updateTransport
        )
        _ = try await updateRepository.refreshDDNSResult()
        let updateRequests = await updateTransport.recordedRequests()
        let updateRequest = try XCTUnwrap(
            updateRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "update_ip_address"
            }
        )
        try assertFormRequest(updateRequest, matches: updateFixture)

        let deleteTransport = MockHTTPTransport(responses: [
            response(providers),
            response(records),
            response(#"{"success":true}"#),
            response(providers),
            response(emptyRecords)
        ])
        let deleteRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreDDNSProvider, DsmAPIName.coreDDNSRecord],
            transport: deleteTransport
        )
        _ = try await deleteRepository.deleteDDNSResult(providerID: "Example")
        let deleteRequests = await deleteTransport.recordedRequests()
        let deleteRequest = try XCTUnwrap(
            deleteRequests.first {
                (try? decodeForm($0.httpBody)["method"]) == "delete"
            }
        )
        try assertFormRequest(deleteRequest, matches: deleteFixture)

        for request in [testRequest, createRequest] {
            let fields = try decodeForm(request.httpBody)
            XCTAssertEqual(fields["passwd"], "SYNTHETIC_EPHEMERAL_SECRET")
            XCTAssertEqual(fields["username"], "synthetic-owner")
        }
        for fixture in [testFixture, createFixture] {
            XCTAssertTrue(
                fixture.parameters
                    .filter { ["hostname", "passwd", "username"].contains($0.name) }
                    .allSatisfy { $0.redacted == true && $0.encodedValue == nil }
            )
        }
    }

    func testNAS关机与重启请求和共享Fixture一致且没有业务参数() async throws {
        let shutdownFixture = try loadFixture(
            "system-power/shutdown/synthetic-nas/request.json"
        )
        let rebootFixture = try loadFixture(
            "system-power/reboot/synthetic-nas/request.json"
        )
        let info = response(
            #"{"success":true,"data":{"model":"Synthetic NAS","firmware_ver":"DSM 7"}}"#
        )
        let accepted = response(#"{"success":true}"#)

        let shutdownTransport = MockHTTPTransport(
            responses: [info, accepted]
        )
        let shutdownRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: shutdownTransport
        )
        let shutdownResult = try await shutdownRepository
            .performPowerActionResult(.shutdown)
        let shutdownRequests = await shutdownTransport.recordedRequests()

        XCTAssertEqual(shutdownResult.status, .confirmedSuccess)
        XCTAssertEqual(shutdownRequests.count, 2)
        XCTAssertEqual(
            try decodeForm(shutdownRequests[0].httpBody)["method"],
            "info"
        )
        try assertFormRequest(shutdownRequests[1], matches: shutdownFixture)

        let rebootTransport = MockHTTPTransport(
            responses: [info, accepted]
        )
        let rebootRepository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreSystem],
            transport: rebootTransport
        )
        let rebootResult = try await rebootRepository
            .performPowerActionResult(.reboot)
        let rebootRequests = await rebootTransport.recordedRequests()

        XCTAssertEqual(rebootResult.status, .confirmedSuccess)
        XCTAssertEqual(rebootRequests.count, 2)
        XCTAssertEqual(
            try decodeForm(rebootRequests[0].httpBody)["method"],
            "info"
        )
        try assertFormRequest(rebootRequests[1], matches: rebootFixture)
        XCTAssertTrue(shutdownFixture.parameters.isEmpty)
        XCTAssertTrue(rebootFixture.parameters.isEmpty)
    }

    func test物理网卡设置请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "network/set-ethernet/synthetic-interface/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"interfaces":[{"ifname":"eth0","title":"Synthetic Interface","status":"connected"}]}}"#
            ),
            response(
                #"{"success":true,"data":{"ifname":"eth0","title":"Synthetic Interface","status":"connected","use_dhcp":false,"ip":"192.0.2.10","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.1","is_default_gateway":true,"mtu":1500,"enable_vlan":true,"vlan_id":20}}"#
            ),
            response(#"{"success":true}"#),
            response(
                #"{"success":true,"data":{"ifname":"eth0","title":"Synthetic Interface","status":"connected","use_dhcp":true,"ip":"","mask":"","gateway":"","dns":"","is_default_gateway":false,"mtu":1500,"enable_vlan":false,"vlan_id":0}}"#
            )
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreNetworkEthernet],
            transport: transport
        )

        let result = try await repository.saveEthernetInterfaceResult(
            NasEthernetInterface(
                id: "eth0",
                displayName: "Synthetic Interface",
                status: "connected",
                usesDHCP: true,
                address: "",
                subnetMask: "",
                gateway: "",
                dnsServers: "",
                isDefaultGateway: false,
                mtu: 1_500,
                isVLANEnabled: false,
                vlanID: nil
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        let request = try XCTUnwrap(requests.dropFirst(2).first)
        try assertFormRequest(request, matches: fixture)
    }

    func test安全设置复合请求与共享Fixture一致() async throws {
        let fixtures = try [
            loadFixture("security/set-auto-block/synthetic-settings/request.json"),
            loadFixture("security/set-dos/synthetic-interface/request.json"),
            loadFixture("security/set-port-scan/synthetic-settings/request.json"),
            loadFixture("security/disable-firewall/synthetic-settings/request.json")
        ]
        let currentAutoBlock =
            #"{"success":true,"data":{"enable":false,"attempts":10,"within_mins":5,"expire_day":0}}"#
        let updatedAutoBlock =
            #"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}}"#
        let ethernet =
            #"{"success":true,"data":{"interfaces":[{"id":"eth-synthetic","display":"Synthetic LAN"}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(currentAutoBlock),
            response(
                #"{"success":true,"data":{"enable_firewall":true,"profile_name":"synthetic-profile"}}"#
            ),
            response(#"{"success":true,"data":{"enable_port_check":false}}"#),
            response(ethernet),
            response(
                #"{"success":true,"data":{"configs":[{"adapter":"eth-synthetic","dos_protect_enable":false}]}}"#
            ),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(updatedAutoBlock),
            response(
                #"{"success":true,"data":{"enable_firewall":false,"profile_name":"synthetic-profile"}}"#
            ),
            response(#"{"success":true,"data":{"enable_port_check":true}}"#),
            response(ethernet),
            response(
                #"{"success":true,"data":{"configs":[{"adapter":"eth-synthetic","dos_protect_enable":true}]}}"#
            )
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreNetworkEthernet,
                DsmAPIName.coreSecurityDoS,
                DsmAPIName.coreSecurityFirewall,
                DsmAPIName.coreSecurityFirewallConf
            ],
            transport: transport
        )

        let result = try await repository.saveSecuritySettingsResult(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: 7,
                dosProtection: [
                    NasDoSProtectionSetting(
                        id: "eth-synthetic",
                        displayName: "Synthetic LAN",
                        isEnabled: true
                    )
                ],
                isFirewallEnabled: false,
                firewallProfileName: "synthetic-profile",
                isPortScanProtectionEnabled: true
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 14)
        for (request, fixture) in zip(requests[5...8], fixtures) {
            try assertFormRequest(request, matches: fixture)
        }
    }

    func test防火墙配置档应用请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "security/apply-firewall-profile/synthetic-profile/request.json"
        )
        let autoBlock =
            #"{"success":true,"data":{"enable":true,"attempts":5,"within_mins":10,"expire_day":0}}"#
        let transport = MockHTTPTransport(responses: [
            response(autoBlock),
            response(
                #"{"success":true,"data":{"enable_firewall":false,"profile_name":"synthetic-profile"}}"#
            ),
            response(#"{"success":true,"data":{"task_id":"synthetic-task"}}"#),
            response(#"{"success":true,"data":{"success":true}}"#),
            response(#"{"success":true}"#),
            response(autoBlock),
            response(
                #"{"success":true,"data":{"enable_firewall":true,"profile_name":"synthetic-profile"}}"#
            )
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.coreSecurityAutoBlock,
                DsmAPIName.coreSecurityFirewall,
                DsmAPIName.coreSecurityFirewallProfileApply
            ],
            transport: transport
        )

        let result = try await repository.saveSecuritySettingsResult(
            NasSecuritySettings(
                isAutoBlockEnabled: true,
                failedAttempts: 5,
                withinMinutes: 10,
                expirationDays: nil,
                isFirewallEnabled: true,
                firewallProfileName: "synthetic-profile"
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 7)
        try assertFormRequest(requests[2], matches: fixture)
    }

    func test硬件设置复合请求与共享Fixture一致() async throws {
        let fixtures = try [
            loadFixture(
                "hardware/set-power-recovery/synthetic-settings/request.json"
            ),
            loadFixture(
                "hardware/set-led-brightness/synthetic-settings/request.json"
            ),
            loadFixture("hardware/set-fan-mode/synthetic-settings/request.json"),
            loadFixture("hardware/set-beep/synthetic-settings/request.json"),
            loadFixture(
                "hardware/set-hibernation/synthetic-settings/request.json"
            ),
            loadFixture("hardware/set-ups/synthetic-settings/request.json")
        ]
        let powerBefore =
            #"{"success":true,"data":{"rc_power_config":false}}"#
        let powerAfter =
            #"{"success":true,"data":{"rc_power_config":true}}"#
        let ledBefore =
            #"{"success":true,"data":{"led_brightness":3}}"#
        let ledAfter =
            #"{"success":true,"data":{"led_brightness":5}}"#
        let ledRange =
            #"{"success":true,"data":{"min":0,"max":7}}"#
        let fanBefore =
            #"{"success":true,"data":{"dual_fan_speed":"quietfan"}}"#
        let fanAfter =
            #"{"success":true,"data":{"dual_fan_speed":"coolfan"}}"#
        let beepBefore =
            #"{"success":true,"data":{"fan_fail":true,"volume_or_cache_crash":true,"poweron_beep":false,"poweroff_beep":false,"reset_beep":true}}"#
        let beepAfter =
            #"{"success":true,"data":{"fan_fail":true,"volume_or_cache_crash":true,"poweron_beep":true,"poweroff_beep":false,"reset_beep":true}}"#
        let hibernationBefore =
            #"{"success":true,"data":{"eunit_deep_sleep":false,"enable_log":true,"sata_deep_sleep":true,"ignore_netbios_broadcast":false,"auto_poweroff_enable":false}}"#
        let hibernationAfter =
            #"{"success":true,"data":{"eunit_deep_sleep":true,"enable_log":true,"sata_deep_sleep":true,"ignore_netbios_broadcast":true,"auto_poweroff_enable":false}}"#
        let upsBefore =
            #"{"success":true,"data":{"enable":false,"mode":"USB","delay_time":60,"ups_set_safemode_until_lowbatt":false,"shutdown_device":false}}"#
        let upsAfter =
            #"{"success":true,"data":{"enable":true,"mode":"SLAVE","delay_time":120,"ups_set_safemode_until_lowbatt":false,"shutdown_device":true,"net_server_ip":"<synthetic-ups-server>"}}"#
        let transport = MockHTTPTransport(responses: [
            response(powerBefore),
            response(ledBefore),
            response(ledRange),
            response(fanBefore),
            response(beepBefore),
            response(hibernationBefore),
            response(upsBefore),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true}"#),
            response(powerAfter),
            response(ledAfter),
            response(ledRange),
            response(fanAfter),
            response(beepAfter),
            response(hibernationAfter),
            response(upsAfter)
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.coreHardwarePowerRecovery,
                DsmAPIName.coreHardwareLEDBrightness,
                DsmAPIName.coreHardwareFanSpeed,
                DsmAPIName.coreHardwareBeepControl,
                DsmAPIName.coreHardwareHibernation,
                DsmAPIName.coreExternalDeviceUPS
            ],
            transport: transport
        )

        let result = try await repository.saveHardwareSettingsResult(
            NasHardwareSettings(
                restartsAfterPowerFailure: true,
                ledBrightness: 5,
                ledBrightnessRange: 0...7,
                fanMode: "coolfan",
                isFanFailureAlertEnabled: true,
                isVolumeFailureAlertEnabled: true,
                isPowerOnSoundEnabled: true,
                isPowerOffSoundEnabled: false,
                isResetSoundEnabled: true,
                isExternalDriveDeepSleepEnabled: true,
                isWakeUpLogEnabled: true,
                isSATASleepEnabled: true,
                ignoresNetworkDiscoveryDuringSleep: true,
                isAutomaticPowerOffEnabled: false,
                ups: NasUPSSettings(
                    isEnabled: true,
                    mode: "SLAVE",
                    safeModeDelaySeconds: 120,
                    waitsUntilLowBattery: false,
                    shutsDownUPSAfterSafeMode: true,
                    networkServerAddress: "<synthetic-ups-server>",
                    snmpServerAddress: nil
                )
            )
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 21)
        let writeIndexes = [7, 8, 10, 11, 12, 13]
        for (index, fixture) in zip(writeIndexes, fixtures) {
            try assertFormRequest(requests[index], matches: fixture)
        }
        XCTAssertEqual(try decodeForm(requests[9].httpBody)["method"], "update")
    }

    func test启动硬盘检测请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "storage/start-smart-test/synthetic-disk/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"disks":[{"id":"synthetic-disk","device":"<synthetic-device>","longName":"Synthetic Disk","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#
            ),
            response(
                #"{"success":true,"data":{"testInfo":[{"device":"<synthetic-device>","testing":false,"ihm_testing":false,"perf_testing":false}]}}"#
            ),
            response(#"{"success":true}"#),
            response(
                #"{"success":true,"data":{"testInfo":[{"device":"<synthetic-device>","testing":true,"test_type":"quick"}]}}"#
            ),
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.storageOverview,
                DsmAPIName.coreStorageDisk,
            ],
            transport: transport
        )
        _ = try await repository.loadStorage()

        let result = try await repository.startDiskTestResult(
            diskID: "synthetic-disk",
            type: .quick
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        let request = requests[2]
        try assertFormRequest(request, matches: fixture)
    }

    func test停止硬盘检测请求与共享Fixture一致() async throws {
        let fixture = try loadFixture(
            "storage/stop-smart-test/synthetic-disk/request.json"
        )
        let transport = MockHTTPTransport(responses: [
            response(
                #"{"success":true,"data":{"disks":[{"id":"synthetic-disk","device":"<synthetic-device>","longName":"Synthetic Disk","smart_status":"normal","smart_test_support":true}],"storagePools":[],"volumes":[]}}"#
            ),
            response(
                #"{"success":true,"data":{"testInfo":[{"device":"<synthetic-device>","testing":true,"test_type":"quick"}]}}"#
            ),
            response(#"{"success":true}"#),
            response(
                #"{"success":true,"data":{"testInfo":[{"device":"<synthetic-device>","testing":false}]}}"#
            )
        ])
        let repository = try makeAdministrationRepository(
            apiNames: [
                DsmAPIName.storageOverview,
                DsmAPIName.coreStorageDisk
            ],
            transport: transport
        )
        _ = try await repository.loadStorage()

        let result = try await repository.stopDiskTestResult(
            diskID: "synthetic-disk"
        )

        XCTAssertEqual(result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        try assertFormRequest(requests[2], matches: fixture)
    }

    private var testCredential: DsmSessionCredential {
        DsmSessionCredential(
            sid: "REDACTED_SESSION",
            synoToken: "REDACTED_TOKEN"
        )
    }

    private func assertFormRequest(
        _ request: URLRequest,
        matches fixture: RequestFixture
    ) throws {
        XCTAssertEqual(request.httpMethod, fixture.transport.httpMethod)
        XCTAssertEqual(request.url?.lastPathComponent, fixture.api.resolvedPath)
        let fields = try decodeForm(request.httpBody)
        XCTAssertEqual(fields["api"], fixture.api.name)
        XCTAssertEqual(fields["method"], fixture.api.method)
        XCTAssertEqual(fields["version"], String(fixture.api.resolvedVersion))

        let actualParameters = fields.filter {
            !["api", "method", "version", "_sid", "SynoToken"].contains($0.key)
        }
        XCTAssertEqual(
            Set(actualParameters.keys),
            Set(fixture.parameters.map(\.name))
        )
        for parameter in fixture.parameters {
            guard let expected = parameter.encodedValue,
                  let actual = actualParameters[parameter.name] else {
                continue
            }
            if ["object", "objectArray", "stringArray"].contains(parameter.valueType) {
                XCTAssertTrue(
                    try jsonValuesAreEqual(actual, expected),
                    "参数 \(parameter.name) 的 JSON 结构不一致"
                )
            } else {
                XCTAssertEqual(actual, expected)
            }
        }
        for parameter in fixture.parameters where parameter.redacted == true {
            XCTAssertNotNil(actualParameters[parameter.name])
        }
        let authentication = authenticationLocations(in: request, fields: fields)
        XCTAssertEqual(authentication.required, fixture.authentication.required)
        XCTAssertEqual(
            authentication.synoTokenRequired,
            fixture.authentication.synoTokenRequired
        )
        XCTAssertEqual(
            Set(authentication.sessionLocations),
            Set(fixture.authentication.sessionLocations)
        )
        XCTAssertEqual(
            Set(authentication.synoTokenLocations),
            Set(fixture.authentication.synoTokenLocations)
        )
    }

    private func assertMultipartRequest(
        _ request: URLRequest,
        body: Data,
        matches fixture: RequestFixture,
        expectedAuthentication: RequestFixture.Authentication? = nil
    ) throws {
        XCTAssertEqual(request.httpMethod, fixture.transport.httpMethod)
        XCTAssertEqual(request.url?.lastPathComponent, fixture.api.resolvedPath)
        let query = Dictionary(
            uniqueKeysWithValues: (
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems ?? []
            ).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["api"], fixture.api.name)
        XCTAssertEqual(query["method"], fixture.api.method)
        XCTAssertEqual(query["version"], String(fixture.api.resolvedVersion))

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(
            contentType.components(separatedBy: "boundary=").last
        )
        var fields = parseMultipartFields(body, boundary: boundary)
        fields["file"] = "<synthetic-binary>"
        let actualParameters = fields.filter {
            ![
                "api",
                "method",
                "version",
                "_sid",
                "SynoToken",
                "synotoken",
            ].contains($0.key)
        }
        XCTAssertEqual(
            Set(actualParameters.keys),
            Set(fixture.parameters.map(\.name))
        )
        for parameter in fixture.parameters {
            guard let expected = parameter.encodedValue,
                  let actual = actualParameters[parameter.name] else {
                continue
            }
            if ["object", "objectArray"].contains(parameter.valueType) {
                XCTAssertTrue(
                    try jsonValuesAreEqual(actual, expected),
                    "参数 \(parameter.name) 的 JSON 结构不一致"
                )
            } else {
                XCTAssertEqual(actual, expected)
            }
        }

        var sessionLocations = Set<String>()
        var tokenLocations = Set<String>()
        if request.value(forHTTPHeaderField: "Cookie") != nil {
            sessionLocations.insert("cookie")
        }
        if query["_sid"] != nil {
            sessionLocations.insert("query")
        }
        if fields["_sid"] != nil {
            sessionLocations.insert("multipart")
        }
        if request.value(forHTTPHeaderField: "X-SYNO-TOKEN") != nil {
            tokenLocations.insert("header")
        }
        if query["SynoToken"] != nil || query["synotoken"] != nil {
            tokenLocations.insert("query")
        }
        if fields["SynoToken"] != nil || fields["synotoken"] != nil {
            tokenLocations.insert("multipart")
        }
        let authentication = expectedAuthentication ?? fixture.authentication
        XCTAssertEqual(sessionLocations, Set(authentication.sessionLocations))
        XCTAssertEqual(tokenLocations, Set(authentication.synoTokenLocations))
    }

    private func appleAuthenticationExpectation(
        for fixture: RequestFixture
    ) -> RequestFixture.Authentication {
        guard fixture.fixtureId == "file-station.upload.synthetic-overwrite" else {
            return fixture.authentication
        }
        // 共享 Fixture 仍保留 Android 尚未迁移时的历史认证位置；Apple 发布策略不得因此恢复 URL 凭据。
        return RequestFixture.Authentication(
            required: fixture.authentication.required,
            synoTokenRequired: fixture.authentication.synoTokenRequired,
            sessionLocations: fixture.authentication.sessionLocations.filter { $0 != "query" },
            synoTokenLocations: fixture.authentication.synoTokenLocations.filter { $0 != "query" }
        )
    }

    private func authenticationLocations(
        in request: URLRequest,
        fields: [String: String]
    ) -> RequestFixture.Authentication {
        var sessionLocations = Set<String>()
        var tokenLocations = Set<String>()
        if request.value(forHTTPHeaderField: "Cookie") != nil {
            sessionLocations.insert("cookie")
        }
        if fields["_sid"] != nil {
            sessionLocations.insert("form")
        }
        if request.value(forHTTPHeaderField: "X-SYNO-TOKEN") != nil {
            tokenLocations.insert("header")
        }
        if fields["SynoToken"] != nil {
            tokenLocations.insert("form")
        }
        return RequestFixture.Authentication(
            required: true,
            synoTokenRequired: false,
            sessionLocations: sessionLocations.sorted(),
            synoTokenLocations: tokenLocations.sorted()
        )
    }

    private func decodeForm(_ data: Data?) throws -> [String: String] {
        let body = try XCTUnwrap(data.flatMap { String(data: $0, encoding: .utf8) })
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
    }

    private func jsonValuesAreEqual(
        _ lhs: String,
        _ rhs: String
    ) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: Data(lhs.utf8))
        let right = try JSONSerialization.jsonObject(with: Data(rhs.utf8))
        return (canonicalFixtureJSONValue(left) as AnyObject).isEqual(
            canonicalFixtureJSONValue(right)
        )
    }

    private func canonicalFixtureJSONValue(_ value: Any) -> Any {
        if let string = value as? String {
            // Fixture 策略以不带绝对路径前缀的固定占位符代表合成路径。
            return string == "/<synthetic-path>" ? "<synthetic-path>" : string
        }
        if let array = value as? [Any] {
            return array.map(canonicalFixtureJSONValue)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(canonicalFixtureJSONValue)
        }
        return value
    }

    private func parseMultipartFields(
        _ data: Data,
        boundary: String
    ) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [String: String] = [:]
        for section in text.components(separatedBy: "--\(boundary)") {
            guard let nameRange = section.range(of: #"name=""#) else {
                continue
            }
            let afterName = section[nameRange.upperBound...]
            guard let endName = afterName.firstIndex(of: "\"") else {
                continue
            }
            let name = String(afterName[..<endName])
            guard name != "file",
                  let separator = section.range(of: "\r\n\r\n") else {
                continue
            }
            result[name] = section[separator.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func loadFixture(_ relativePath: String) throws -> RequestFixture {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("contracts/request-fixtures")
                .appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(
                    RequestFixture.self,
                    from: Data(contentsOf: candidate)
                )
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func makeRepository(
        capabilities: CapabilitySet,
        transport: MockHTTPTransport
    ) throws -> DsmFileRepository {
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        return try DsmFileRepository(
            profile: profile,
            capabilities: capabilities,
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func makeAdministrationRepository(
        transport: MockHTTPTransport
    ) throws -> DsmNasAdministrationRepository {
        try makeAdministrationRepository(
            apiNames: [DsmAPIName.coreUser],
            transport: transport
        )
    }

    private func makeAdministrationRepository(
        apiNames: [String],
        transport: MockHTTPTransport
    ) throws -> DsmNasAdministrationRepository {
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        return try DsmNasAdministrationRepository(
            profile: profile,
            capabilities: CapabilitySet(
                Dictionary(
                    uniqueKeysWithValues: apiNames.map {
                        (
                            $0,
                            capability(
                                $0,
                                version: [
                                    DsmAPIName.coreQuickConnect,
                                    DsmAPIName.coreRegionNTP,
                                    DsmAPIName.coreSystem,
                                ].contains($0)
                                    ? 3
                                    : ($0 == DsmAPIName.coreWebDSM
                                        ? 2
                                        : ([
                                        DsmAPIName.coreNetworkEthernet,
                                        DsmAPIName.coreSecurityDoS
                                        ].contains($0) ? 2 : 1))
                            )
                        )
                    }
                )
            ),
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func makePackageAdministrationRepository(
        apiNames: [String] = [
            DsmAPIName.corePackage,
            DsmAPIName.corePackageUninstallation,
        ],
        transport: MockHTTPTransport
    ) throws -> DsmNasAdministrationRepository {
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        return try DsmNasAdministrationRepository(
            profile: profile,
            capabilities: CapabilitySet(
                Dictionary(
                    uniqueKeysWithValues: apiNames.map {
                        ($0, capability($0, version: $0 == DsmAPIName.corePackage ? 2 : 1))
                    }
                )
            ),
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func makeServiceManagementRepository(
        apiNames: [String],
        transport: MockHTTPTransport
    ) throws -> DsmServiceManagementRepository {
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        return try DsmServiceManagementRepository(
            profile: profile,
            capabilities: CapabilitySet(
                Dictionary(
                    uniqueKeysWithValues: apiNames.map {
                        ($0, capability($0, version: 1))
                    }
                )
            ),
            session: AuthSession(
                sid: "REDACTED_SESSION",
                synoToken: "REDACTED_TOKEN",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func capability(_ name: String, version: Int) -> ApiCapability {
        ApiCapability(
            name: name,
            path: "entry.cgi",
            minVersion: 1,
            maxVersion: version,
            requestFormat: .form,
            selectedVersion: version
        )
    }

    private func response(_ body: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }
}

private struct RequestFixture: Decodable {
    struct API: Decodable {
        let name: String
        let method: String
        let resolvedVersion: Int
        let resolvedPath: String
    }

    struct Transport: Decodable {
        let httpMethod: String
        let requestFormat: String
    }

    struct Parameter: Decodable {
        let name: String
        let valueType: String
        let encodedValue: String?
        let redacted: Bool?
    }

    struct Authentication: Codable, Equatable {
        let required: Bool
        let synoTokenRequired: Bool
        let sessionLocations: [String]
        let synoTokenLocations: [String]
    }

    let fixtureId: String
    let api: API
    let transport: Transport
    let parameters: [Parameter]
    let authentication: Authentication
}
