import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmQuickConnectResolverTests: XCTestCase {
    func test可选实机QuickConnect中继与能力发现() async throws {
        guard let quickConnectID = ProcessInfo.processInfo.environment["DSM_TEST_QC_ID"],
              !quickConnectID.isEmpty else {
            throw XCTSkip("未提供脱离仓库保存的 QuickConnect 测试 ID。")
        }

        let resolver = DsmQuickConnectResolver()
        let relay = try await resolver.requestRelay(id: quickConnectID)
        let profile = try NasProfile(
            displayName: "QuickConnect 中继测试",
            host: relay.host,
            port: relay.port
        )
        let capabilities = try await DsmAuthRepository().discover(profile: profile)

        XCTAssertEqual(relay.kind, .relay)
        XCTAssertEqual(relay.port, 443)
        XCTAssertNotNil(capabilities[DsmAPIName.authentication])
    }

    func test优先选择局域网直连地址() throws {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {"ds_state": "CONNECTED"},
              "service": {"port": 5001},
              "smartdns": {
                "host": "family-nas.direct.quickconnect.to",
                "lan": ["192-168-1-20.family-nas.direct.quickconnect.to"]
              }
            }]
            """.utf8
        )

        let endpoints = try DsmQuickConnectResolver.decodeEndpoints(from: data)

        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints[0].host, "192-168-1-20.family-nas.direct.quickconnect.to")
        XCTAssertEqual(endpoints[0].port, 5_001)
        XCTAssertEqual(endpoints[0].kind, .local)
        XCTAssertEqual(endpoints[1].host, "family-nas.direct.quickconnect.to")
        XCTAssertEqual(endpoints[1].kind, .external)
    }

    func test没有局域网地址时使用QuickConnect直连域名() throws {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {"ds_state": "CONNECTED"},
              "service": {"port": 5001},
              "smartdns": {"host": "family-nas.direct.quickconnect.cn", "lan": []}
            }]
            """.utf8
        )

        let endpoints = try DsmQuickConnectResolver.decodeEndpoints(from: data)

        XCTAssertEqual(endpoints.map(\.host), ["family-nas.direct.quickconnect.cn"])
        XCTAssertEqual(endpoints.first?.kind, .external)
    }

    func test拒绝QuickConnect域名之外的返回地址() {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {"ds_state": "CONNECTED"},
              "service": {"port": 5001},
              "smartdns": {"host": "untrusted.example.com", "lan": []}
            }]
            """.utf8
        )

        XCTAssertThrowsError(try DsmQuickConnectResolver.decodeEndpoints(from: data)) { error in
            XCTAssertEqual(error as? QuickConnectResolutionError, .noDirectRoute)
        }
    }

    func test拒绝包含非法字符的伪直连域名() {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {"ds_state": "CONNECTED"},
              "service": {"port": 5001},
              "smartdns": {"host": "bad/path.direct.quickconnect.to", "lan": []}
            }]
            """.utf8
        )

        XCTAssertThrowsError(try DsmQuickConnectResolver.decodeEndpoints(from: data)) { error in
            XCTAssertEqual(error as? QuickConnectResolutionError, .noDirectRoute)
        }
    }

    func test离线设备给出明确错误() {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {"ds_state": "DISCONNECTED"},
              "service": {"port": 5001},
              "smartdns": {"host": "family-nas.direct.quickconnect.to", "lan": []}
            }]
            """.utf8
        )

        XCTAssertThrowsError(try DsmQuickConnectResolver.decodeEndpoints(from: data)) { error in
            XCTAssertEqual(error as? QuickConnectResolutionError, .offline)
        }
    }

    func test解析并约束QuickConnect中继域名() throws {
        let data = Data(
            """
            [{
              "errno": 0,
              "server": {
                "ds_state": "CONNECTED",
                "serverID": "server-identity",
                "pingpong_path": "/webman/pingpong.cgi?action=cors&quickconnect=true"
              },
              "service": {
                "port": 5001,
                "relay_ip": "relay.example.invalid",
                "relay_port": 40001
              },
              "env": {
                "control_host": "control.quickconnect.to",
                "relay_region": "r1"
              }
            }]
            """.utf8
        )

        let descriptor = try DsmQuickConnectResolver.decodeRelayDescriptor(
            from: data,
            quickConnectID: "family-nas"
        )

        XCTAssertEqual(descriptor.endpoint.host, "family-nas.r1.quickconnect.to")
        XCTAssertEqual(descriptor.endpoint.port, 443)
        XCTAssertEqual(descriptor.endpoint.kind, .relay)
        XCTAssertTrue(DsmQuickConnectResolver.isTrustedRelayHost(descriptor.endpoint.host))
        XCTAssertFalse(
            DsmQuickConnectResolver.isTrustedRelayHost(
                "family-nas.r1.quickconnect.to.example.invalid"
            )
        )
    }

    func test直连域名不被当作中继而真实中继仍可信() {
        XCTAssertFalse(
            DsmQuickConnectResolver.isTrustedRelayHost("family-nas.direct.quickconnect.to")
        )
        XCTAssertFalse(
            DsmQuickConnectResolver.isTrustedRelayHost("family-nas.direct.quickconnect.cn")
        )
        XCTAssertTrue(DsmQuickConnectResolver.isTrustedRelayHost("family-nas.r1.quickconnect.to"))
        XCTAssertTrue(DsmQuickConnectResolver.isTrustedRelayHost("family-nas.r1.quickconnect.cn"))
    }

    func test中继未开启时返回可恢复错误() {
        let data = Data("[{\"errno\":19}]".utf8)

        XCTAssertThrowsError(
            try DsmQuickConnectResolver.decodeRelayDescriptor(
                from: data,
                quickConnectID: "family-nas"
            )
        ) { error in
            XCTAssertEqual(error as? QuickConnectResolutionError, .relayDisabled)
        }
    }
}
