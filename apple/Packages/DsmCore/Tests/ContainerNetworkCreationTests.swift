import XCTest
@testable import DsmCore

final class ContainerNetworkCreationTests: XCTestCase {
    func test默认自动IPv4关闭IPv6且忽略未启用的地址草稿() {
        var configuration = ContainerNetworkCreation(name: "synthetic-network_1")
        configuration.subnet = "unused"
        configuration.ipv6Gateway = "unused"
        XCTAssertNil(configuration.validationIssue)
        XCTAssertFalse(configuration.usesManualIPv4)
        XCTAssertFalse(configuration.isIPv6Enabled)
        XCTAssertFalse(configuration.disableMasquerade)
    }

    func test网络名称遵循官方字符规则() {
        for name in ["", " space", "_start", "bad/name", "中文", "trailing\n"] {
            XCTAssertEqual(ContainerNetworkCreation(name: name).validationIssue, .name, name)
        }
        XCTAssertNil(ContainerNetworkCreation(name: "Net_1.test-2").validationIssue)
    }

    func test手动IPv4验证CIDR网关和可选地址池() {
        var configuration = ContainerNetworkCreation(name: "synthetic-network")
        configuration.usesManualIPv4 = true
        XCTAssertEqual(configuration.validationIssue, .ipv4)
        configuration.subnet = "192.0.2.0/24"
        configuration.gateway = "192.0.2.1"
        XCTAssertNil(configuration.validationIssue)
        configuration.ipRange = "192.0.2.128/25"
        XCTAssertNil(configuration.validationIssue)
        configuration.ipRange = "198.51.100.0/24"
        XCTAssertEqual(configuration.validationIssue, .outsideSubnet)
        configuration.ipRange = ""
        configuration.gateway = "198.51.100.1"
        XCTAssertEqual(configuration.validationIssue, .outsideSubnet)
        configuration.gateway = "192.000.2.1"
        XCTAssertEqual(configuration.validationIssue, .ipv4)
    }

    func test手动IPv6验证压缩地址前缀和边界() {
        var configuration = ContainerNetworkCreation(name: "synthetic-network")
        configuration.isIPv6Enabled = true
        configuration.ipv6Subnet = "2001:db8::/64"
        configuration.ipv6Gateway = "2001:db8::1"
        configuration.ipv6Range = "2001:db8::100/120"
        XCTAssertNil(configuration.validationIssue)
        configuration.ipv6Gateway = "2001:db8:1::1"
        XCTAssertEqual(configuration.validationIssue, .outsideSubnet)
        configuration.ipv6Gateway = "2001:db8::1%en0"
        XCTAssertEqual(configuration.validationIssue, .ipv6)
        configuration.ipv6Gateway = "2001:db8::1"
        configuration.ipv6Subnet = "2001:db8::/129"
        XCTAssertEqual(configuration.validationIssue, .ipv6)
    }
}
