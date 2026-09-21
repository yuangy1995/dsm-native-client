using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;

namespace LanStash.App.CloudDrive;

internal sealed class CloudFileLocalRemovalGate
{
    private sealed record Grant(long RootId, byte[] Identity);
    private readonly ConcurrentDictionary<long, Grant> _grants = new();

    internal IDisposable Authorize(CloudFilesInterop.PlaceholderStandardInfo state, string identity)
    {
        var grant = new Grant(state.SyncRootFileId, Encoding.UTF8.GetBytes(identity));
        if (!_grants.TryAdd(state.FileId, grant)) throw new InvalidOperationException("cloud.remove.busy");
        return new Lease(() => _grants.TryRemove(new KeyValuePair<long, Grant>(state.FileId, grant)));
    }

    internal bool TryConsume(CloudFilesInterop.CallbackInfo info)
    {
        if (info.ProcessInfo == IntPtr.Zero || Marshal.ReadInt32(info.ProcessInfo) < 8 ||
            unchecked((uint)Marshal.ReadInt32(info.ProcessInfo, 4)) != unchecked((uint)Environment.ProcessId) ||
            !_grants.TryGetValue(info.FileId, out var grant) || info.SyncRootFileId != grant.RootId ||
            info.FileIdentity == IntPtr.Zero || info.FileIdentityLength != grant.Identity.Length) return false;
        var bytes = new byte[grant.Identity.Length];
        Marshal.Copy(info.FileIdentity, bytes, 0, bytes.Length);
        return bytes.AsSpan().SequenceEqual(grant.Identity) && _grants.TryRemove(new KeyValuePair<long, Grant>(info.FileId, grant));
    }

    private sealed class Lease(Action release) : IDisposable
    {
        public void Dispose() => release();
    }
}
