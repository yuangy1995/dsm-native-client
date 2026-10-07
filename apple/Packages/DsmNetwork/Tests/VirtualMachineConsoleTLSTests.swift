#if os(macOS)
import CryptoKit
import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

/// 自行生成短期证书及回环 HTTPS/WSS 服务；不依赖 NAS、用户证书或真实凭据。
final class VirtualMachineConsoleTLSTests: XCTestCase, @unchecked Sendable {
    func test真实WSS握手二进制输入输出和已固定证书() async throws {
        try await withServer { server in
            let policy = try server.policy()
            let transport = try server.transport(policy: policy)
            let document = try await transport.resource(policy.documentURL)
            XCTAssertEqual(document.mediaType, "text/html")
            try await transport.connect()
            let greeting = try await transport.receive()
            XCTAssertEqual(greeting, Data("RFB 003.008\n".utf8))
            try await transport.send(Data([4, 0, 1, 2]))
            let echo = try await transport.receive()
            XCTAssertEqual(echo, Data([4, 0, 1, 2]))
            await transport.close()
        }
    }
    func test真实资源与画面均拒绝变化的固定证书() async throws {
        try await withServer { server in
            let policy = try server.policy()
            let transport = try server.transport(policy: policy, fingerprint: String(repeating: "0", count: 64))
            do { _ = try await transport.resource(policy.documentURL); XCTFail("资源不得忽略证书变化") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            do { try await transport.connect(); XCTFail("画面不得忽略证书变化") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            await transport.close()
        }
    }
    func test要求系统信任时不能使用自签名固定证书() async throws {
        try await withServer { server in
            let policy = try server.policy(), transport = try server.transport(policy: policy, requiresSystemTrust: true)
            do { _ = try await transport.resource(policy.documentURL); XCTFail("强制系统信任不能退回固定指纹") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            do { try await transport.connect(); XCTFail("WSS 必须保持系统信任限制") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            await transport.close()
        }
    }
    func test真实HTTPS重定向不跟随到其他资源() async throws {
        try await withServer { server in
            let http = URLSessionTransport(expectedHost: "127.0.0.1", pinnedCertificateSHA256: server.fingerprint, allowsRedirects: false)
            let response = try await http.send(URLRequest(url: server.origin.appendingPathComponent("redirect")))
            XCTAssertEqual(response.statusCode, 302)
            XCTAssertEqual(String(data: response.data, encoding: .utf8), "redirect")
        }
    }
    func test真实WSS文本帧不能作为画面二进制接受() async throws {
        try await withServer { server in
            let policy = try server.policy(alias: "text"), transport = try server.transport(policy: policy)
            try await transport.connect()
            do { _ = try await transport.receive(); XCTFail("不能把文本控制消息作为画面") }
            catch { XCTAssertEqual(error as? VirtualMachineConsoleError, .invalidResponse) }
            await transport.close()
        }
    }
    func test真实HTTPS和WSS拒绝均给出权限恢复类型() async throws {
        try await withServer { server in
            let policy = try server.policy(alias: "denied"), transport = try server.transport(policy: policy)
            do { _ = try await transport.resource(policy.documentURL); XCTFail("资源拒绝不能当一般加载故障") }
            catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
            do { try await transport.connect(); XCTFail("控制台拒绝不能当一般连接故障") }
            catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
            await transport.close()
        }
    }
    func test真实WSS不跟随同源重定向() async throws {
        try await withServer { server in
            let policy = try server.policy(alias: "redirect"), transport = try server.transport(policy: policy)
            do { try await transport.connect(); XCTFail("不得跟随画面连接重定向") } catch {}
            await transport.close()
        }
    }
    private func withServer(_ operation: (ConsoleLoopbackServer) async throws -> Void) async throws {
        let server = try ConsoleLoopbackServer()
        do { try await operation(server) }
        catch { await server.stop(); throw error }
        await server.stop()
    }
}

private final class ConsoleLoopbackServer {
    let origin: URL
    let fingerprint: String
    private let root: URL
    private let process: Process
    private let output: Pipe
    private let errors: Pipe
    private let termination: AsyncStream<Void>
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lanstash-console-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=ext
        prompt=no
        [dn]
        CN=Synthetic console
        [ext]
        subjectAltName=IP:127.0.0.1
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        """.write(to: config, atomically: true, encoding: .utf8)
        do {
            try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path,
                                               "-keyout", root.appendingPathComponent("key.pem").path, "-out", root.appendingPathComponent("cert.pem").path])
            try Self.run("/usr/bin/openssl", ["x509", "-in", root.appendingPathComponent("cert.pem").path, "-outform", "DER", "-out", root.appendingPathComponent("cert.der").path])
            fingerprint = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("cert.der"))).map { String(format: "%02X", $0) }.joined()
            process = Process(); output = Pipe(); errors = Pipe()
            let (events, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            termination = events
            // 在启动前观察退出，避免 waitUntilExit 在并发执行器中等待失去唤醒的 RunLoop。
            process.terminationHandler = { _ in completion.yield(()); completion.finish() }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-c", Self.server, root.path]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            var line = Data()
            while line.count < 16 {
                let byte = output.fileHandleForReading.readData(ofLength: 1)
                guard !byte.isEmpty else { throw VirtualMachineConsoleError.unavailable }
                if byte == Data([10]) { break }; line.append(byte)
            }
            guard let port = Int(String(decoding: line, as: UTF8.self)), let origin = URL(string: "https://127.0.0.1:\(port)") else { throw VirtualMachineConsoleError.unavailable }
            self.origin = origin
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func policy(alias: String = "") throws -> VirtualMachineConsolePolicy {
        try .init(baseURL: alias.isEmpty ? origin : origin.appendingPathComponent(alias), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us")
    }
    func transport(policy: VirtualMachineConsolePolicy, fingerprint: String? = nil, requiresSystemTrust: Bool = false) throws -> DsmVirtualMachineConsoleTransport {
        let pin = fingerprint ?? self.fingerprint
        let http = URLSessionTransport(expectedHost: "127.0.0.1", pinnedCertificateSHA256: pin, requiresSystemCertificateTrust: requiresSystemTrust, allowsRedirects: false)
        return try .init(policy: policy, cookie: "SYNTHETIC", http: http) { request in
            DsmNativeConsoleSocket(request: request, expectedHost: "127.0.0.1", fingerprint: pin, requiresSystemTrust: requiresSystemTrust)
        }
    }
    func stop() async {
        if process.isRunning { process.terminate() }
        for await _ in termination { break }
        try? FileManager.default.removeItem(at: root)
    }
    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw VirtualMachineConsoleError.unavailable }
    }
    private static let server = #"""
    import base64, hashlib, http.server, os, socketserver, ssl, struct, sys
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args): pass
        def do_GET(self):
            if self.path.startswith('/denied/'):
                self.send_response(403); self.send_header('Content-Length','0'); self.end_headers(); return
            if self.path.startswith('/redirect/') and self.headers.get('Upgrade','').lower() == 'websocket':
                self.send_response(302); self.send_header('Location', self.path[len('/redirect'):]); self.send_header('Content-Length', '0'); self.end_headers(); return
            if self.path == '/redirect':
                self.send_response(302); self.send_header('Location', '/outside'); self.send_header('Content-Length', '8'); self.end_headers(); self.wfile.write(b'redirect'); return
            if self.headers.get('Cookie') != 'id=SYNTHETIC':
                self.send_error(401); return
            if self.headers.get('Upgrade','').lower() != 'websocket':
                body=b'<!doctype html><html><body>Synthetic</body></html>'
                self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
            key=self.headers.get('Sec-WebSocket-Key','')
            accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101); self.send_header('Upgrade','websocket'); self.send_header('Connection','Upgrade'); self.send_header('Sec-WebSocket-Accept',accept); self.send_header('Sec-WebSocket-Protocol','binary'); self.end_headers()
            def frame(data, opcode=2):
                header=bytes([0x80|opcode]); size=len(data)
                header += bytes([size]) if size<126 else bytes([126])+struct.pack('!H',size) if size<65536 else bytes([127])+struct.pack('!Q',size)
                self.wfile.write(header+data); self.wfile.flush()
            frame(b'RFB 003.008\n', 1 if self.path.startswith('/text/') else 2)
            self.connection.settimeout(10)
            try:
                while True:
                    header=self.rfile.read(2)
                    if len(header)!=2: break
                    opcode=header[0]&15; size=header[1]&127; masked=header[1]&128
                    if size==126: size=struct.unpack('!H',self.rfile.read(2))[0]
                    elif size==127: size=struct.unpack('!Q',self.rfile.read(8))[0]
                    if size>1048576: break
                    mask=self.rfile.read(4) if masked else b''; data=self.rfile.read(size)
                    if masked: data=bytes(value^mask[index%4] for index,value in enumerate(data))
                    if opcode==8: frame(b'',8); break
                    if opcode==9: frame(data,10)
                    elif opcode==2: frame(data)
            except (OSError, ValueError): pass
            self.close_connection=True
    class LoopbackServer(http.server.ThreadingHTTPServer):
        def server_bind(self):
            socketserver.TCPServer.server_bind(self)
            self.server_name='localhost'; self.server_port=self.server_address[1]
    server=LoopbackServer(('127.0.0.1',0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(os.path.join(sys.argv[1],'cert.pem'),os.path.join(sys.argv[1],'key.pem'))
    server.socket=context.wrap_socket(server.socket,server_side=True)
    print(server.server_address[1],flush=True); server.serve_forever()
    """#
}
#endif
