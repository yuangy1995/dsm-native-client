#if DEBUG
import DsmCore
import Foundation

/// 只向正式 WebKit 宿主提供合成页面与有序字节；不连接网络，也不代表真实 noVNC 已验证。
final class MobileConsoleUIFactory: @unchecked Sendable {
    private let mode: String
    private let lock = NSLock()
    private var count = 0
    init(mode: String) { self.mode = mode }
    func make(policy: VirtualMachineConsolePolicy) -> MobileConsoleUITransport {
        lock.lock(); count += 1; let first = count == 1; lock.unlock()
        return .init(policy: policy, mode: mode, first: first)
    }
}

actor MobileConsoleUITransport: VirtualMachineConsoleTransport {
    let policy: VirtualMachineConsolePolicy
    let mode: String
    let first: Bool
    private(set) var closed = false
    private(set) var inputs: [Data] = []
    private var frames: [Data] = [Data("Synthetic console ready".utf8)]
    private var reader: CheckedContinuation<Data, Error>?
    init(policy: VirtualMachineConsolePolicy, mode: String = "vmm-console", first: Bool = false) {
        self.policy = policy; self.mode = mode; self.first = first
    }
    func resource(_ url: URL) async throws -> VirtualMachineConsoleResource {
        guard !closed, url == policy.documentURL else { throw VirtualMachineConsoleError.closed }
        if mode == "vmm-console-loading" { try await Task.sleep(for: .seconds(30)) }
        if mode == "vmm-console-read-error" { throw VirtualMachineConsoleError.invalidResponse }
        return .init(data: Data(Self.html.utf8), mediaType: "text/html")
    }
    func connect() async throws {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        if mode == "vmm-console-retry" && first { throw VirtualMachineConsoleError.unavailable }
        if mode == "vmm-console-denied" { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        if mode == "vmm-console-trust" { throw AppError(category: .tlsUntrusted, isRetryable: false, safeUserMessage: "") }
    }
    func receive() async throws -> Data {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        if !frames.isEmpty { return frames.removeFirst() }
        if mode == "vmm-console-disconnect" && first {
            try await Task.sleep(for: .seconds(1)); throw VirtualMachineConsoleError.closed
        }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw VirtualMachineConsoleError.closed }
        inputs.append(data)
        let response = Data("Synthetic input received".utf8)
        if let reader { self.reader = nil; reader.resume(returning: response) } else { frames.append(response) }
    }
    func close() async {
        closed = true; frames = []; reader?.resume(throwing: VirtualMachineConsoleError.closed); reader = nil
    }
    private static let html = #"""
    <!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{background:#10151e;color:#e3e9f3;font:18px system-ui;padding:24px;margin:0}h1{font-size:24px}input,button{font:inherit;padding:12px;margin:8px 0;box-sizing:border-box;max-width:100%}input{width:100%}#output{min-height:80px}</style></head>
    <body><h1>Synthetic console</h1><p id="output" role="status"></p><label for="input">Test input</label><input id="input" autocomplete="off"><button id="send">Send input</button>
    <script>
    const q=new URLSearchParams(location.search), socket=new WebSocket('wss://'+location.host+'/'+q.get('path')+'?app_id='+q.get('app_id'),['binary']);
    socket.binaryType='arraybuffer';socket.onmessage=e=>{document.getElementById('output').textContent=new TextDecoder().decode(e.data);};
    document.getElementById('send').onclick=()=>{socket.send(new TextEncoder().encode(document.getElementById('input').value));document.getElementById('input').blur();};
    </script></body></html>
    """#
}
#endif
