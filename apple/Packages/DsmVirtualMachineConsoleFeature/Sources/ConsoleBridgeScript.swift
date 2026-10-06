import DsmCore
import Foundation

enum ConsoleBridgeScript {
    static func make(policy: VirtualMachineConsolePolicy) -> String {
        var socket = URLComponents(url: policy.socketURL, resolvingAgainstBaseURL: false)!
        socket.host = policy.localDocumentURL.host; socket.port = nil
        let endpoint = String(data: try! JSONEncoder().encode(socket.url!.absoluteString), encoding: .utf8)!
        return "(() => { const endpoint = \(endpoint);" + body
    }

    // 只适配官方 noVNC 的二进制连接及语言 GET，不安装 Cookie，也不提供通用网络代理。
    private static let body = #"""
        const post = value => window.webkit.messageHandlers.console.postMessage(value);
        const NativeXHR = window.XMLHttpRequest;
        const localePrefix = new URL('app/locale/', location.href).pathname;
        class LocaleXHR extends NativeXHR {
            open(method, url, async=true, user, password) {
                this.abort();
                const target = new URL(url, location.href);
                if (String(method).toUpperCase() !== 'GET' || target.protocol !== location.protocol || target.host !== location.host ||
                    !target.pathname.startsWith(localePrefix) || !target.pathname.endsWith('.json')) {
                    this._locale = null; return super.open(method, url, async, user, password);
                }
                if (!async || user !== undefined || password !== undefined) throw new DOMException('Invalid request', 'SecurityError');
                this._locale = {url: target.href, state: 1, status: 0, body: '', sent: false};
                this.dispatchEvent(new Event('readystatechange'));
            }
            send(body=null) {
                if (!this._locale) return super.send(body);
                const item = this._locale;
                if (item.state !== 1 || item.sent || body !== null) throw new DOMException('Invalid request', 'InvalidStateError');
                item.sent = true;
                this.dispatchEvent(new ProgressEvent('loadstart'));
                if (this.timeout > 0) item.timer = setTimeout(() => this._finish(item, null, 'timeout'), this.timeout);
                post({kind: 'locale', url: item.url}).then(value => this._finish(item, value, 'load'), () => this._finish(item, null, 'error'));
            }
            _finish(item, value, event) {
                if (this._locale !== item || item.state === 4 || item.state === 0) return;
                clearTimeout(item.timer); item.state = 4; item.status = event === 'load' ? 200 : 0; item.body = value || '';
                this.dispatchEvent(new Event('readystatechange')); this.dispatchEvent(new ProgressEvent(event)); this.dispatchEvent(new ProgressEvent('loadend'));
            }
            abort() {
                const item = this._locale;
                if (!item) return super.abort();
                clearTimeout(item.timer); const active = item.sent && item.state !== 4 && item.state !== 0;
                item.state = 0; item.status = 0; item.body = '';
                if (active) { this.dispatchEvent(new ProgressEvent('abort')); this.dispatchEvent(new ProgressEvent('loadend')); }
            }
            get readyState() { return this._locale ? this._locale.state : super.readyState; }
            get status() { return this._locale ? this._locale.status : super.status; }
            get statusText() { return this._locale ? (this._locale.status === 200 ? 'OK' : '') : super.statusText; }
            get responseText() { return this._locale ? this._locale.body : super.responseText; }
            get response() {
                if (!this._locale) return super.response;
                if (this.responseType === 'json') { try { return JSON.parse(this._locale.body); } catch { return null; } }
                return this._locale.body;
            }
            get responseURL() { return this._locale ? this._locale.url : super.responseURL; }
            getResponseHeader(name) { return this._locale ? (String(name).toLowerCase() === 'content-type' ? 'application/json' : null) : super.getResponseHeader(name); }
            getAllResponseHeaders() { return this._locale ? 'Content-Type: application/json\r\n' : super.getAllResponseHeaders(); }
        }
        Object.defineProperty(window, 'XMLHttpRequest', {value: LocaleXHR, writable: false, configurable: false});
        const signal = (socket, event) => {
            socket.dispatchEvent(event);
            const handler = socket['on' + event.type];
            if (typeof handler === 'function') handler.call(socket, event);
        };
        class ManagedSocket extends EventTarget {
            static CONNECTING=0; static OPEN=1; static CLOSING=2; static CLOSED=3;
            constructor(url, protocols) {
                super();
                const actual = new URL(url, location.href), expected = new URL(endpoint);
                if (!['ws:', 'wss:'].includes(actual.protocol) || actual.hostname !== expected.hostname || actual.port ||
                    actual.username || actual.password || actual.hash || actual.pathname !== expected.pathname || actual.search !== expected.search)
                    throw new DOMException('Invalid connection', 'SecurityError');
                const values = protocols === undefined ? [] : typeof protocols === 'string' ? [protocols] : protocols;
                if (!Array.isArray(values) || values.some(value => value !== 'binary')) throw new DOMException('Invalid protocol', 'SyntaxError');
                this.url=actual.href; this.protocol=''; this.extensions=''; this._state=0; this._buffered=0; this._binary='blob'; this._tail=Promise.resolve();
                this.onopen=this.onmessage=this.onclose=this.onerror=null;
                post({kind: 'open', url: actual.href}).then(() => {
                    if (this._state !== 0) return;
                    this._state=1; this.protocol='binary'; signal(this, new Event('open')); this._read();
                }, () => this._end(true));
            }
            get CONNECTING(){return 0} get OPEN(){return 1} get CLOSING(){return 2} get CLOSED(){return 3}
            get readyState(){return this._state} get bufferedAmount(){return this._buffered}
            get binaryType(){return this._binary} set binaryType(value){if(value==='blob'||value==='arraybuffer')this._binary=value}
            async _read() {
                while (this._state === 1) {
                    try {
                        const text = await post({kind: 'read'});
                        if (this._state !== 1) return;
                        const raw = atob(text), bytes = Uint8Array.from(raw, value => value.charCodeAt(0));
                        signal(this, new MessageEvent('message', {data: this._binary === 'arraybuffer' ? bytes.buffer : new Blob([bytes])}));
                    } catch { this._end(true); }
                }
            }
            send(value) {
                if (this._state !== 1) throw new DOMException('Not connected', 'InvalidStateError');
                let bytes;
                if (value instanceof ArrayBuffer) bytes = new Uint8Array(value).slice();
                else if (ArrayBuffer.isView(value)) bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
                else throw new TypeError('Binary input required');
                if (bytes.byteLength === 0) return;
                if (bytes.byteLength > 1048576 || this._buffered + bytes.byteLength > 4194304) { this.close(); throw new RangeError('Input queue full'); }
                this._buffered += bytes.byteLength;
                this._tail = this._tail.then(async () => {
                    try {
                        if (this._state === 3) return;
                        let text = ''; for (let i=0; i<bytes.length; i+=8192) text += String.fromCharCode(...bytes.subarray(i, i+8192));
                        await post({kind: 'send', data: btoa(text)});
                    } catch { this._end(true); }
                    finally { this._buffered = Math.max(0, this._buffered - bytes.byteLength); bytes.fill(0); }
                });
            }
            close() {
                if (this._state >= 2) return;
                this._state=2;
                this._tail = this._tail.then(async () => { try { await post({kind: 'close'}); } finally { this._end(false); } });
            }
            _end(failed) {
                if (this._state === 3) return;
                this._state=3; this._buffered=0;
                if (failed) signal(this, new Event('error'));
                signal(this, new CloseEvent('close', {code: failed ? 1006 : 1000, wasClean: !failed}));
            }
        }
        Object.defineProperty(window, 'WebSocket', {value: ManagedSocket, writable: false, configurable: false});
    })();
    """#
}
