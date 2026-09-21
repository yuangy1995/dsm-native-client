using System.Text.Json;

namespace LanStash.App.Features.VirtualMachines;

internal static class VirtualMachineConsoleBridgeScript
{
    internal static string Create(Uri socketUri, string context) => "(() => { const endpoint = " + JsonSerializer.Serialize(socketUri.AbsoluteUri) + "; const context = " + JsonSerializer.Serialize(context) + ";" + Body;
    private const string Body = """
        const bridge = chrome.webview;
        const post = bridge.postMessage.bind(bridge);
        const sockets = new Map(); const locales = new Map(); let sequence = 0;
        const NativeXHR = window.XMLHttpRequest;
        const localePrefix = new URL('app/locale/', location.href).pathname;
        class LocaleXHR extends NativeXHR {
            open(method, url, async=true, user, password) {
                this.abort();
                const target=new URL(url,location.href);
                if(String(method).toUpperCase()!=='GET'||target.origin!==location.origin||!target.pathname.startsWith(localePrefix)||!target.pathname.endsWith('.json')){
                    this._locale=null;return super.open(method,url,async,user,password);
                }
                if(!async||user!==undefined||password!==undefined)throw new DOMException('Unsupported locale request','InvalidAccessError');
                this._locale={id:++sequence,url:target.href,state:1,status:0,body:'',sent:false};
                this.dispatchEvent(new Event('readystatechange'));
            }
            send(body=null) {
                if(!this._locale)return super.send(body);
                const request=this._locale;
                if(request.state!==1||request.sent)throw new DOMException('Invalid locale request state','InvalidStateError');
                if(body!==null)throw new DOMException('Locale requests are read-only','SecurityError');
                request.sent=true;locales.set(request.id,this);
                if(this.timeout>0)request.timer=setTimeout(()=>{if(locales.delete(request.id)){request.state=4;this.dispatchEvent(new Event('readystatechange'));this.dispatchEvent(new ProgressEvent('timeout'));this.dispatchEvent(new ProgressEvent('loadend'));}},this.timeout);
                this.dispatchEvent(new ProgressEvent('loadstart'));post({context,id:request.id,kind:'locale',data:request.url});
            }
            abort() {
                const request=this._locale;
                if(!request)return super.abort();
                clearTimeout(request.timer);locales.delete(request.id);const active=request.sent&&request.state!==4;
                request.state=0;request.status=0;request.body='';
                if(active){this.dispatchEvent(new ProgressEvent('abort'));this.dispatchEvent(new ProgressEvent('loadend'));}
            }
            _complete(message) {
                const request=this._locale;
                if(!request||request.id!==message.id)return;
                clearTimeout(request.timer);locales.delete(request.id);request.status=message.status;request.body=message.body;request.state=4;
                this.dispatchEvent(new Event('readystatechange'));this.dispatchEvent(new ProgressEvent('load'));this.dispatchEvent(new ProgressEvent('loadend'));
            }
            get readyState(){return this._locale?this._locale.state:super.readyState}
            get status(){return this._locale?this._locale.status:super.status}
            get statusText(){return this._locale?(this._locale.status===200?'OK':'Unavailable'):super.statusText}
            get responseText(){return this._locale?this._locale.body:super.responseText}
            get response(){if(!this._locale)return super.response;if(this.responseType==='json'){try{return JSON.parse(this._locale.body)}catch{return null}}return this._locale.body}
            get responseURL(){return this._locale?this._locale.url:super.responseURL}
            getResponseHeader(name){return this._locale?(String(name).toLowerCase()==='content-type'?'application/json':null):super.getResponseHeader(name)}
            getAllResponseHeaders(){return this._locale?'Content-Type: application/json\r\nCache-Control: no-store\r\n':super.getAllResponseHeaders()}
        }
        Object.defineProperty(window,'XMLHttpRequest',{value:LocaleXHR,writable:false,configurable:false});
        const signal = (socket, event) => {
            socket.dispatchEvent(event);
            const callback = socket['on' + event.type];
            if (typeof callback === 'function') callback.call(socket, event);
        };
        class ManagedSocket extends EventTarget {
            static CONNECTING=0; static OPEN=1; static CLOSING=2; static CLOSED=3;
            constructor(url, protocols) {
                super();
                if (new URL(url, location.href).href !== endpoint) throw new DOMException('Blocked console connection', 'SecurityError');
                const requested = protocols === undefined ? [] : typeof protocols === 'string' ? [protocols] : protocols;
                if (!Array.isArray(requested) || requested.some(value => value !== 'binary')) throw new DOMException('Unsupported protocol', 'SyntaxError');
                this._id=++sequence; this._state=0; this._buffered=0; this._binary='blob'; this._tail=Promise.resolve();
                this.url=endpoint; this.protocol=''; this.extensions='';
                this.onopen=this.onmessage=this.onclose=this.onerror=null;
                sockets.set(this._id,this); post({context,id:this._id,kind:'open'});
            }
            get CONNECTING(){return 0} get OPEN(){return 1} get CLOSING(){return 2} get CLOSED(){return 3}
            get readyState(){return this._state} get bufferedAmount(){return this._buffered}
            get binaryType(){return this._binary} set binaryType(value){if(value==='blob'||value==='arraybuffer')this._binary=value}
            send(value) {
                if(this._state!==1) throw new DOMException('Console is not connected','InvalidStateError');
                let bytes;
                if(value instanceof ArrayBuffer) bytes=new Uint8Array(value).slice();
                else if(ArrayBuffer.isView(value)) bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength).slice();
                else throw new TypeError('Console accepts binary messages only');
                if(bytes.byteLength>1048576 || this._buffered+bytes.byteLength>4194304){this.close();throw new RangeError('Console send queue is full')}
                this._buffered+=bytes.byteLength;
                this._tail=this._tail.then(()=>{
                    try {
                        if(this._state===3)return;
                        let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));
                        post({context,id:this._id,kind:'send',data:btoa(text)});
                    } finally { bytes.fill(0); }
                });
            }
            close(){if(this._state>=2)return;this._state=2;this._tail=this._tail.then(()=>post({context,id:this._id,kind:'close'}))}
        }
        bridge.addEventListener('message', event => {
            const message=event.data;if(!message||message.context!==context)return;
            if(message.kind==='locale'){const request=locales.get(message.id);if(request)request._complete(message);return;}
            const socket=sockets.get(message.id);if(!socket)return;
            if(message.kind==='open'){
                if(socket._state!==0)return;socket._state=1;socket.protocol='binary';signal(socket,new Event('open'));
            } else if(message.kind==='data'&&socket._state===1){
                const raw=atob(message.data);const bytes=Uint8Array.from(raw,value=>value.charCodeAt(0));
                signal(socket,new MessageEvent('message',{data:socket._binary==='arraybuffer'?bytes.buffer:new Blob([bytes])}));
            } else if(message.kind==='sent') socket._buffered=Math.max(0,socket._buffered-message.bytes);
            else if(message.kind==='close'){
                socket._state=3;socket._buffered=0;sockets.delete(message.id);
                if(message.failed)signal(socket,new Event('error'));
                signal(socket,new CloseEvent('close',{code:message.failed?1006:1000,wasClean:!message.failed}));
            }
        });
        Object.defineProperty(window,'WebSocket',{value:ManagedSocket,writable:false,configurable:false});
    })();
    """;
}
