using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

// 仅接收本次系统浏览器授权的 loopback 回调，不提供文件、代理或局域网服务。
public sealed class FileVfsCloudSession : IDisposable
{
    private readonly FileVfsCloudRequest _request;
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly ConcurrentDictionary<TcpClient, byte> _clients = new();
    private readonly TaskCompletionSource<FileVfsCloudAuthorization> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly string _completeText, _failureText;
    private readonly string _callback;
    private int _disposed, _accepted;
    public Uri LoginUri { get; }
    internal Uri CallbackUri { get; }
    public Task<FileVfsCloudAuthorization> Completion => _completion.Task;

    public FileVfsCloudSession(FileVfsCloudRequest request, string completeText, string failureText, TimeSpan? timeout = null)
    {
        if (request.LoginUri.Scheme != "https" || request.LoginUri.Host != "synooauth.synology.com" || request.LoginUri.Port != 443 ||
            request.LoginUri.AbsolutePath != "/FileStation/Cloud/login.php" || request.LoginUri.UserInfo.Length != 0 || request.LoginUri.Fragment.Length != 0 ||
            request.ExpiresAt <= DateTimeOffset.UtcNow) throw new InvalidDataException("file.vfs.authorization");
        _request = request; _completeText = completeText; _failureText = failureText;
        var nonce = Guid.NewGuid().ToString("N"); _callback = "_lanstash_" + nonce;
        _listener.Start(8);
        CallbackUri = new Uri($"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/{nonce}");
        LoginUri = new Uri(request.LoginUri.AbsoluteUri + "&host=" + Uri.EscapeDataString(CallbackUri.AbsoluteUri) + "&callback=" + Uri.EscapeDataString(_callback));
        _stop.CancelAfter(timeout ?? request.ExpiresAt - DateTimeOffset.UtcNow);
        _ = ListenAsync();
    }

    private async Task ListenAsync()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(_stop.Token).ConfigureAwait(false);
                if (_clients.Count >= 8) { client.Dispose(); continue; }
                _clients.TryAdd(client, 0); _ = ReceiveAsync(client);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
        finally { Dispose(); _stop.Dispose(); }
    }

    private async Task ReceiveAsync(TcpClient client)
    {
        FileVfsCloudAuthorization? authorization = null;
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token); limit.CancelAfter(TimeSpan.FromSeconds(10));
            using var stream = client.GetStream(); using var bytes = new MemoryStream(); var buffer = new byte[8192];
            FileVfsCloudCallback.Request? request;
            do
            {
                var count = await stream.ReadAsync(buffer, limit.Token).ConfigureAwait(false);
                if (count == 0) return;
                bytes.Write(buffer, 0, count); request = FileVfsCloudCallback.Decode(bytes.ToArray());
            } while (request is null);
            var validAddress = request.Host == CallbackUri.Authority && (request.Path == CallbackUri.AbsolutePath || request.Path.StartsWith(CallbackUri.AbsolutePath + "/", StringComparison.Ordinal));
            var status = validAddress ? 200 : 404;
            if (validAddress)
            {
                try { authorization = request.Authorization(_request, _callback); }
                catch (InvalidDataException) { status = 400; }
            }
            if (authorization is not null && Interlocked.CompareExchange(ref _accepted, 1, 0) != 0) { authorization.Dispose(); authorization = null; status = 409; }
            await ReplyAsync(stream, status, limit.Token).ConfigureAwait(false);
            if (authorization is not null)
            {
                if (!_completion.TrySetResult(authorization)) authorization.Dispose();
                authorization = null; Dispose();
            }
        }
        catch (Exception error) when (error is IOException or SocketException or OperationCanceledException or ObjectDisposedException or InvalidDataException or DecoderFallbackException)
        {
            // 畸形请求只关闭该连接；不记录含凭据的正文，也不使其他回调失效。
            if (authorization is not null) { authorization.Dispose(); Interlocked.Exchange(ref _accepted, 0); }
        }
        finally { _clients.TryRemove(client, out _); client.Dispose(); }
    }

    private async Task ReplyAsync(NetworkStream stream, int status, CancellationToken token)
    {
        var nonce = Guid.NewGuid().ToString("N");
        var text = WebUtility.HtmlEncode(status == 200 ? _completeText : _failureText);
        var body = Encoding.UTF8.GetBytes($"<!doctype html><meta charset=\"utf-8\"><p>{text}</p><script nonce=\"{nonce}\">history.replaceState(null,'','/complete');window.close();</script>");
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Invalid Callback")}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-{nonce}'\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, token).ConfigureAwait(false); await stream.WriteAsync(body, token).ConfigureAwait(false);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _completion.TrySetCanceled(); _stop.Cancel(); _listener.Stop();
        foreach (var client in _clients.Keys) client.Dispose();
        _clients.Clear();
    }
}

internal static class FileVfsCloudCallback
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    internal sealed record Request(string Host, string Path, string Query, string? ContentType, byte[] Body)
    {
        public FileVfsCloudAuthorization Authorization(FileVfsCloudRequest request, string callback)
        {
            try
            {
                var fields = Form(Query);
                if (Body.Length > 0)
                {
                    var type = ContentType?.Split(';')[0].Trim();
                    var values = type switch { "application/json" => JsonFields(Utf8.GetString(Body)), "application/x-www-form-urlencoded" => Form(Utf8.GetString(Body)), _ => throw Invalid() };
                    Merge(fields, values);
                }
                if (fields.Remove("data", out var wrapped)) Merge(fields, JsonFields(wrapped));
                if (!fields.TryGetValue("callback", out var name) || name != callback || !fields.TryGetValue("account", out var account) || account.Length == 0 ||
                    !fields.TryGetValue("access_token", out var access) || access.Length == 0) throw Invalid();
                long? expires = null;
                if (fields.TryGetValue("expires_in", out var raw)) expires = long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? number : throw Invalid();
                return new(request.RequestId, request.ProfileId, request.Protocol, account, access, fields.GetValueOrDefault("client_id"), fields.GetValueOrDefault("refresh_token"), expires);
            }
            catch (Exception error) when (error is JsonException or DecoderFallbackException or ArgumentException or FormatException) { throw Invalid(); }
        }
        public override string ToString() => nameof(Request);
    }

    internal static Request? Decode(byte[] bytes)
    {
        if (bytes.Length > 131072) throw Invalid();
        var split = bytes.AsSpan().IndexOf("\r\n\r\n"u8);
        if (split < 0) { if (bytes.Length > 16384) throw Invalid(); return null; }
        if (split > 16384) throw Invalid();
        var lines = Utf8.GetString(bytes, 0, split).Split("\r\n", StringSplitOptions.None);
        var start = lines[0].Split(' ', StringSplitOptions.None);
        if (start.Length != 3 || start[0] is not ("GET" or "POST") || start[2] is not ("HTTP/1.0" or "HTTP/1.1") ||
            !start[1].StartsWith('/') || start[1].StartsWith("//", StringComparison.Ordinal) || start[1].Contains('#') || start[1].Any(char.IsControl)) throw Invalid();
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 1 || line[..colon].Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-') || !headers.TryAdd(line[..colon], line[(colon + 1)..].Trim())) throw Invalid();
        }
        if (!headers.TryGetValue("Host", out var host) || headers.ContainsKey("Transfer-Encoding") ||
            !int.TryParse(headers.GetValueOrDefault("Content-Length", "0"), NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length > 114688 ||
            start[0] == "POST" && !headers.ContainsKey("Content-Length")) throw Invalid();
        if (bytes.Length < split + 4 + length) return null;
        if (bytes.Length != split + 4 + length) throw Invalid();
        var target = start[1].Split('?', 2);
        return new(host, target[0], target.Length > 1 ? target[1] : "", headers.GetValueOrDefault("Content-Type")?.ToLowerInvariant(), bytes[(split + 4)..]);
    }

    private static Dictionary<string, string> Form(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (text.Length == 0) return result;
        foreach (var pair in text.Split('&'))
        {
            var fields = pair.Split('=', 2);
            if (fields.Length != 2 || !result.TryAdd(DecodeValue(fields[0]), DecodeValue(fields[1]))) throw Invalid();
        }
        return result;
    }
    private static string DecodeValue(string raw)
    {
        var bytes = Utf8.GetBytes(raw); using var result = new MemoryStream();
        for (var i = 0; i < bytes.Length; i++)
        {
            if (bytes[i] == '%')
            {
                if (i + 2 >= bytes.Length || !byte.TryParse(Encoding.ASCII.GetString(bytes, i + 1, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var value)) throw Invalid();
                result.WriteByte(value); i += 2;
            }
            else result.WriteByte(bytes[i] == '+' ? (byte)' ' : bytes[i]);
        }
        return Utf8.GetString(result.ToArray());
    }
    private static Dictionary<string, string> JsonFields(string text)
    {
        using var json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 8 });
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw Invalid();
        var result = new Dictionary<string, string>(StringComparer.Ordinal); var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in json.RootElement.EnumerateObject())
        {
            if (!keys.Add(field.Name)) throw Invalid();
            if (field.Value.ValueKind == JsonValueKind.String) result.Add(field.Name, field.Value.GetString()!);
            else if (field.Name == "expires_in" && field.Value.ValueKind == JsonValueKind.Number && field.Value.TryGetInt64(out var number) && number >= 0) result.Add(field.Name, number.ToString(CultureInfo.InvariantCulture));
            else if (field.Name is "callback" or "account" or "client_id" or "access_token" or "refresh_token" or "expires_in" or "data") throw Invalid();
        }
        return result;
    }
    private static void Merge(Dictionary<string, string> destination, Dictionary<string, string> source)
    { foreach (var pair in source) if (!destination.TryAdd(pair.Key, pair.Value)) throw Invalid(); }
    private static InvalidDataException Invalid() => new("file.vfs.authorization");
}
