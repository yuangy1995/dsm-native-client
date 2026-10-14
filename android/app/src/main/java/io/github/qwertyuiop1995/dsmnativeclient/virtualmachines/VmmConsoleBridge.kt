package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmConsolePolicy
import kotlinx.serialization.json.JsonPrimitive

/** 在官方脚本之前安装受限桥；只有主框架的精确来源能取得原生消息端口。 */
internal object VmmConsoleBridge {
    fun script(policy: VmmConsolePolicy, token: String) = "(() => { const endpoint = " + JsonPrimitive(policy.localSocket) +
        "; const handshake = " + JsonPrimitive(token) + ";" + body
    private val body = """
// noVNC 的窗口设置只放内存，进程退出也不会留下网页存储。
const transientStorage = () => {
    const values = new Map();
    return Object.freeze({
        get length() { return values.size; },
        key(index) { return Array.from(values.keys())[index] ?? null; },
        getItem(key) { return values.get(String(key)) ?? null; },
        setItem(key, value) {
            key = String(key); value = String(value);
            if (key.length > 256 || value.length > 4096 || (!values.has(key) && values.size >= 128)) throw new DOMException('Storage full', 'QuotaExceededError');
            values.set(key, value);
        },
        removeItem(key) { values.delete(String(key)); },
        clear() { values.clear(); }
    });
};
for (const name of ['localStorage', 'sessionStorage']) Object.defineProperty(window, name, {value: transientStorage(), writable: false, configurable: false});
let port = null, sequence = 0;
const pending = new Map();
window.addEventListener('message', event => {
    if (port || event.data !== handshake || event.ports.length !== 1) return;
    port = event.ports[0];
    port.onmessage = event => {
        let reply; try { reply = JSON.parse(event.data); } catch { return; }
        const item = pending.get(reply.id); if (!item) return;
        pending.delete(reply.id); clearTimeout(item.timer);
        if (reply.ok === true) item.resolve(reply.value); else item.reject(new Error('Connection unavailable'));
    };
    for (const item of pending.values()) port.postMessage(item.payload);
});
const post = value => new Promise((resolve, reject) => {
    if (pending.size >= 16) { reject(new Error('Queue full')); return; }
    const id = String(++sequence), payload = JSON.stringify({id, ...value});
    const item = {resolve, reject, payload, timer: null}; pending.set(id, item);
    if (value.kind !== 'read') item.timer = setTimeout(() => { pending.delete(id); reject(new Error('Connection unavailable')); }, 20000);
    if (port) port.postMessage(payload);
});
window.addEventListener('pagehide', () => {
    if (port) port.close();
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(new Error('Connection closed')); }
    pending.clear();
});
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
    """.trimIndent()
}
