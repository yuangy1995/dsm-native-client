import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class StorageAnalysisIntegrationTests: XCTestCase {
    func test容量分析通过真实请求编码和分页形成报告() async throws {
        let transport = StorageAnalysisTransport()
        let model = try makeModel(transport: transport)
        model.beginStorageAnalysis()
        try await waitForAnalysis(model)

        let report = try XCTUnwrap(model.storageAnalysis)
        XCTAssertNil(model.storageAnalysisError)
        XCTAssertEqual(report.scannedFileCount, 2)
        XCTAssertEqual(report.scannedBytes, 30)
        XCTAssertEqual(report.shares.first?.usedBytes, 30)
        XCTAssertEqual(report.largeFiles.map(\.sizeBytes), [20, 10])
        XCTAssertEqual(report.categories.reduce(0) { $0 + $1.usedBytes }, 30)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["list_share", "start", "list", "list", "clean"])
    }

    func test容量分析失败不生成假报告且可以重新开始() async throws {
        let transport = StorageAnalysisTransport(failsSearch: true)
        let model = try makeModel(transport: transport)
        model.beginStorageAnalysis()
        try await waitForAnalysis(model)
        XCTAssertNil(model.storageAnalysis)
        XCTAssertEqual(model.storageAnalysisError, L10n.string("ui.ebf27fffde487252"))
        XCTAssertNil(model.storageAnalysisProgress)

        await transport.setFailsSearch(false)
        model.beginStorageAnalysis()
        try await waitForAnalysis(model)
        XCTAssertNil(model.storageAnalysisError)
        XCTAssertEqual(model.storageAnalysis?.scannedBytes, 30)
    }

    private func makeModel(transport: StorageAnalysisTransport) throws -> NasSettingsModel {
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [
            DsmAPIName.fileStationList, DsmAPIName.fileStationSearch
        ].map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1,
                                 maxVersion: 2, requestFormat: .json, selectedVersion: 2))
        }))
        let repository = try DsmFileRepository(
            profile: NasProfile(displayName: "合成测试", host: "nas.example.invalid", port: 5001),
            capabilities: capabilities,
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false),
            transport: transport
        )
        let model = NasSettingsModel(fileRepository: repository)
        model.setModuleEnabled(true)
        return model
    }

    private func waitForAnalysis(_ model: NasSettingsModel) async throws {
        for _ in 0..<200 {
            if !model.isAnalyzingStorage { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("合成容量分析未在期限内完成")
        model.cancelStorageAnalysis()
    }
}

/// 仅接受容量分析的已知请求；不连接 NAS，不读写本机文件。
private actor StorageAnalysisTransport: DsmBinaryHTTPTransport {
    private var failsSearch: Bool
    private(set) var methods: [String] = []

    init(failsSearch: Bool = false) { self.failsSearch = failsSearch }
    func setFailsSearch(_ value: Bool) { failsSearch = value }

    func send(_ request: URLRequest) throws -> DsmHTTPResponse {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + body)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let method = fields["method"] ?? ""
        methods.append(method)
        switch (fields["api"], method) {
        case (DsmAPIName.fileStationList, "list_share"):
            return response(#"{"success":true,"data":{"offset":0,"total":1,"shares":[{"name":"资料","path":"/synthetic-share","isdir":true}]}}"#)
        case (DsmAPIName.fileStationSearch, "start"):
            let folders = try JSONDecoder().decode([String].self, from: Data((fields["folder_path"] ?? "").utf8))
            guard folders == ["/synthetic-share"], fields["pattern"] == #""*""# else {
                throw URLError(.badServerResponse)
            }
            if failsSearch { return response(#"{"success":false,"error":{"code":400}}"#) }
            return response(#"{"success":true,"data":{"taskid":"synthetic-search"}}"#)
        case (DsmAPIName.fileStationSearch, "list"):
            if fields["offset"] == "0" {
                return response(#"{"success":true,"data":{"finished":true,"offset":0,"total":2,"files":[{"name":"a.txt","path":"/synthetic-share/a.txt","isdir":false,"additional":{"size":10}}]}}"#)
            }
            guard fields["offset"] == "1" else { throw URLError(.badServerResponse) }
            return response(#"{"success":true,"data":{"finished":true,"offset":1,"total":2,"files":[{"name":"b.jpg","path":"/synthetic-share/b.jpg","isdir":false,"additional":{"size":20}}]}}"#)
        case (DsmAPIName.fileStationSearch, "clean"):
            return response(#"{"success":true}"#)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func download(_ request: URLRequest, to destinationURL: URL,
                  progress: @escaping FileTransferProgress) throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL,
                progress: @escaping FileTransferProgress) throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }

    private func response(_ json: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(json.utf8), statusCode: 200)
    }
}
