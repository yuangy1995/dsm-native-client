using System.Text.Json.Serialization;

namespace LanStash.Domain;

/// <summary>控制台的固定同源地址；不接受任意导航地址或会话参数。</summary>
public sealed class VirtualMachineConsolePolicy
{
    public const string ConsolePath = "/webman/3rdparty/Virtualization/noVNC/vnc.html";
    public const int MaximumLocaleBytes = 1024 * 1024;
    [JsonIgnore] public Uri NavigationUri { get; }
    [JsonIgnore] public string ConnectionPolicy { get; }
    [JsonIgnore] public string ManagedConnectionPolicy { get; }
    [JsonIgnore] public Uri? SocketUri { get; }
    [JsonIgnore] public bool SupportsManagedSocket => SocketUri is not null;
    private readonly string _alias;
    private readonly string _assetPrefix;
    private VirtualMachineConsolePolicy(Uri uri, string alias, string machineId, Guid windowId)
    {
        NavigationUri = uri; _alias = alias;
        var prefix = alias.Length == 0 ? "" : "/" + Uri.EscapeDataString(alias);
        _assetPrefix = prefix + "/webman/3rdparty/Virtualization/noVNC/";
        SocketUri = new UriBuilder(uri) { Scheme = "wss", Port = uri.Port, Path = prefix + "/synovirtualization/ws/" + machineId,
            Query = "app_id=" + windowId.ToString("D"), Fragment = "" }.Uri;
        var secureSocket = new UriBuilder(uri) { Scheme = "wss", Port = uri.Port, Path = "", Query = "", Fragment = "" }.Uri;
        ConnectionPolicy = $"connect-src {uri.GetLeftPart(UriPartial.Authority)} {secureSocket.GetLeftPart(UriPartial.Authority)}; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'self'; form-action 'none'";
        ManagedConnectionPolicy = "connect-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'self'; form-action 'none'";
    }
    public static VirtualMachineConsolePolicy Create(Uri origin, string machineId, string name, string keyboardLayout, Guid windowId)
    {
        if (!IsSecureOrigin(origin) || !SafeSegment(machineId) || string.IsNullOrWhiteSpace(name) || name.Any(char.IsControl) ||
            string.IsNullOrWhiteSpace(keyboardLayout) || keyboardLayout.Any(char.IsControl) || windowId == Guid.Empty)
            throw new ArgumentException("vm.console.invalid_target");
        var alias = Uri.UnescapeDataString(origin.AbsolutePath.Trim('/'));
        if (alias.Length != 0 && !SafeSegment(alias)) throw new ArgumentException("vm.console.unsupported_alias");
        var values = new Dictionary<string, string>
        {
            ["autoconnect"] = "true", ["reconnect"] = "true", ["path"] = "synovirtualization/ws/" + machineId,
            ["title"] = name, ["app_id"] = windowId.ToString("D"), ["kb_layout"] = keyboardLayout,
            ["v"] = "", ["app_alias"] = alias
        };
        var uri = new UriBuilder(origin)
        {
            Path = (alias.Length == 0 ? "" : "/" + Uri.EscapeDataString(alias)) + ConsolePath,
            Query = string.Join("&", values.Select(pair => Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value)))
        }.Uri;
        return new(uri, alias, machineId, windowId);
    }
    public bool AllowsNavigation(Uri? candidate) => AllowsResource(candidate) && candidate!.Scheme == Uri.UriSchemeHttps &&
        candidate.AbsolutePath == NavigationUri.AbsolutePath && candidate.Query == NavigationUri.Query && string.IsNullOrEmpty(candidate.Fragment);
    public bool AllowsResource(Uri? candidate) => candidate is { IsAbsoluteUri: true } && string.IsNullOrEmpty(candidate.UserInfo) &&
        candidate.Scheme is "https" or "wss" && candidate.IdnHost.Equals(NavigationUri.IdnHost, StringComparison.OrdinalIgnoreCase) && candidate.Port == NavigationUri.Port;
    public string? ManagedAssetMediaType(Uri? candidate)
    {
        if (!SupportsManagedSocket || !AllowsResource(candidate) || candidate!.Scheme != "https" || candidate.Fragment.Length != 0) return null;
        var path = candidate.AbsolutePath;
        if (path.Contains('%') || path.Contains('\\') || path.Contains(".cgi", StringComparison.OrdinalIgnoreCase)) return null;
        if (candidate.Query.Length > 0 && (!candidate.Query.StartsWith("?v=", StringComparison.Ordinal) ||
            candidate.Query.Length > 128 || !candidate.Query[3..].All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_'))) return null;
        var iconPrefix = (_alias.Length == 0 ? "" : "/" + _alias) + "/webman/3rdparty/Virtualization/images/VirtualManagement_";
        if (path.StartsWith(iconPrefix, StringComparison.Ordinal) && path[iconPrefix.Length..] is "16.png" or "24.png" or "32.png" or "48.png" or "64.png" or "72.png" or "256.png") return "image/png";
        if (!path.StartsWith(_assetPrefix, StringComparison.Ordinal)) return null;
        var relative = path[_assetPrefix.Length..];
        if (relative == "app/sounds/bell.oga") return "audio/ogg";
        if (relative.StartsWith("app/locale/", StringComparison.Ordinal) && relative.EndsWith(".json", StringComparison.Ordinal))
        {
            var locale = relative[11..^5].Split(['-', '_']);
            return locale.Length is 1 or 2 && locale[0].Length is 2 or 3 && locale[0].All(char.IsAsciiLetter) &&
                (locale.Length == 1 || locale[1].Length is >= 2 and <= 8 && locale[1].All(char.IsAsciiLetterOrDigit)) ? "application/json" : null;
        }
        return Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".js" => "text/javascript", ".css" => "text/css", ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif", ".svg" => "image/svg+xml", ".woff" => "font/woff", ".woff2" => "font/woff2", ".ttf" => "font/ttf", _ => null,
        };
    }
    public bool MatchesOrigin(Uri origin) => IsSecureOrigin(origin) && origin.IdnHost.Equals(NavigationUri.IdnHost, StringComparison.OrdinalIgnoreCase) && origin.Port == NavigationUri.Port &&
        Uri.UnescapeDataString(origin.AbsolutePath.Trim('/')) == _alias;
    public static bool IsSecureOrigin(Uri? origin) => origin is { IsAbsoluteUri: true, Scheme: "https" } &&
        !string.IsNullOrWhiteSpace(origin.Host) && string.IsNullOrEmpty(origin.UserInfo) && string.IsNullOrEmpty(origin.Query) && string.IsNullOrEmpty(origin.Fragment);
    public static bool IsSupportedOrigin(Uri? origin) => IsSecureOrigin(origin) &&
        (origin!.AbsolutePath.Trim('/').Length == 0 || SafeSegment(Uri.UnescapeDataString(origin.AbsolutePath.Trim('/'))));
    private static bool SafeSegment(string value) => !string.IsNullOrEmpty(value) && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    public override string ToString() => nameof(VirtualMachineConsolePolicy);
}

/// <summary>只在内存中存活的单窗口会话。文档和凭据不参与诊断序列化。</summary>
public sealed class VirtualMachineConsoleSession : IDisposable
{
    private string? _cookie;
    private readonly Func<CancellationToken, Task<VirtualMachineConsoleDocument>> _load;
    private readonly Func<Uri, CancellationToken, Task<VirtualMachineConsoleDocument>>? _loadAsset;
    private readonly Func<CancellationToken, Task<System.Net.WebSockets.WebSocket>>? _connect;
    [JsonIgnore] public bool UsesManagedTransport => _connect is not null;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    [JsonIgnore] public Guid ProfileId { get; }
    [JsonIgnore] public string MachineId { get; }
    [JsonIgnore] public string MachineName { get; }
    [JsonIgnore] public VirtualMachineConsolePolicy Policy { get; }
    public VirtualMachineConsoleSession(Guid profileId, string machineId, string machineName, VirtualMachineConsolePolicy policy,
        string cookie, Func<CancellationToken, Task<VirtualMachineConsoleDocument>> load,
        Func<Uri, CancellationToken, Task<VirtualMachineConsoleDocument>>? loadAsset = null,
        Func<CancellationToken, Task<System.Net.WebSockets.WebSocket>>? connect = null)
    {
        if (profileId == Guid.Empty || !ValidCookie(cookie)) throw new ArgumentException("vm.console.invalid_session");
        ProfileId = profileId; MachineId = machineId; MachineName = machineName;
        Policy = policy ?? throw new ArgumentNullException(nameof(policy));
        if ((loadAsset is null) != (connect is null) || connect is not null && !policy.SupportsManagedSocket) throw new ArgumentException("vm.console.managed_configuration");
        _cookie = connect is null ? cookie : null; _load = load ?? throw new ArgumentNullException(nameof(load)); _loadAsset = loadAsset; _connect = connect;
    }
    public void InstallCookie(Uri destination, Action<string> install)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(install);
        if (UsesManagedTransport) throw new InvalidOperationException("vm.console.managed_cookie_forbidden");
        if (!Policy.AllowsNavigation(destination)) throw new InvalidOperationException("vm.console.cookie_origin");
        var cookie = Interlocked.Exchange(ref _cookie, null) ?? throw new InvalidOperationException("vm.console.cookie_consumed");
        install(cookie);
    }
    public async Task<VirtualMachineConsoleDocument> LoadAssetAsync(Uri uri, CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_loadAsset is null || Policy.ManagedAssetMediaType(uri) is null) throw new InvalidOperationException("vm.console.asset_forbidden");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _lifetime.Token);
        var asset = await _loadAsset(uri, linked.Token).ConfigureAwait(false);
        if (_disposed || linked.IsCancellationRequested) { asset.Dispose(); linked.Token.ThrowIfCancellationRequested(); throw new ObjectDisposedException(nameof(VirtualMachineConsoleSession)); }
        return asset;
    }
    public async Task<System.Net.WebSockets.WebSocket> ConnectManagedSocketAsync(CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_connect is null) throw new InvalidOperationException("vm.console.managed_socket_unavailable");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _lifetime.Token);
        var socket = await _connect(linked.Token).ConfigureAwait(false);
        if (_disposed || linked.IsCancellationRequested) { socket.Dispose(); linked.Token.ThrowIfCancellationRequested(); throw new ObjectDisposedException(nameof(VirtualMachineConsoleSession)); }
        return socket;
    }
    public async Task<VirtualMachineConsoleDocument> LoadDocumentAsync(CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _lifetime.Token);
        var document = await _load(linked.Token).ConfigureAwait(false);
        if (_disposed || linked.IsCancellationRequested) { document.Dispose(); linked.Token.ThrowIfCancellationRequested(); throw new ObjectDisposedException(nameof(VirtualMachineConsoleSession)); }
        return document;
    }
    public static bool ValidCookie(string? value) => !string.IsNullOrWhiteSpace(value) && value.All(c => c is >= '!' and <= '~' && c is not (';' or ',' or '"' or '\\'));
    public void Dispose() { if (_disposed) return; _disposed = true; Interlocked.Exchange(ref _cookie, null); _lifetime.Cancel(); _lifetime.Dispose(); }
    public override string ToString() => nameof(VirtualMachineConsoleSession);
}

public sealed class VirtualMachineConsoleDocument(byte[] content, string? serverPolicy, string contentType = "text/html; charset=utf-8") : IDisposable
{
    [JsonIgnore] public byte[] Content { get; } = content;
    [JsonIgnore] public string? ServerPolicy { get; } = serverPolicy;
    [JsonIgnore] public string ContentType { get; } = contentType;
    public string ResponseHeaders(VirtualMachineConsolePolicy policy, bool managedTransport = false)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (ContentType.IndexOfAny(['\r', '\n', '\0']) >= 0 || ServerPolicy?.IndexOfAny(['\r', '\n', '\0']) >= 0)
            throw new InvalidOperationException("vm.console.invalid_headers");
        var connectionPolicy = managedTransport ? policy.ManagedConnectionPolicy : policy.ConnectionPolicy;
        var csp = string.IsNullOrWhiteSpace(ServerPolicy) ? connectionPolicy : ServerPolicy + ", " + connectionPolicy;
        return $"Content-Type: {ContentType}\r\nContent-Security-Policy: {csp}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n";
    }
    public void Dispose() => Array.Clear(Content);
    public override string ToString() => nameof(VirtualMachineConsoleDocument);
}
