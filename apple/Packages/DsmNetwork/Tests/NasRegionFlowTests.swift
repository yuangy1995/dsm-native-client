import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasRegionFlowTests: XCTestCase {
    func test区域保存明确拒绝不能用其他来源写入的同值配置覆盖() async throws {
        let zones = #"{"success":true,"data":{"zonedata":[{"value":"UTC","display":"UTC"}]}}"#
        let original = #"{"success":true,"data":{"date_format":"Y/m/d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":"time.example.invalid","date":"2026/10/5","hour":8,"minute":0,"second":0}}"#
        let matching = original.replacingOccurrences(of: "Y/m/d", with: "Y-m-d")
        let transport = MockHTTPTransport(responses: [response(original), response(zones),
            response(#"{"success":false,"error":{"code":105}}"#), response(matching), response(zones)])
        let capability = ApiCapability(name: DsmAPIName.coreRegionNTP, path: "entry.cgi", minVersion: 1, maxVersion: 3, requestFormat: .form, selectedVersion: 3)
        let repository = try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet([DsmAPIName.coreRegionNTP: capability]),
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let desired = NasRegionSettings(dateFormat: "Y-m-d", timeFormat: "H:i", timeZone: "UTC", isNetworkTimeEnabled: true,
            timeServers: ["time.example.invalid"], manualDate: nil, timeZones: [.init(id: "UTC", displayName: "UTC")])
        let result = try await repository.saveRegionSettingsResult(desired)
        XCTAssertEqual(result.status, .permissionDenied)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 3)
        let methods = calls.map { request in
            URLComponents(string: "https://fixture.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == "method" }?.value
        }
        XCTAssertEqual(methods, ["get", "listzone", "set"])
    }
    private func response(_ text: String) -> DsmHTTPResponse { .init(data: Data(text.utf8), statusCode: 200) }
}
