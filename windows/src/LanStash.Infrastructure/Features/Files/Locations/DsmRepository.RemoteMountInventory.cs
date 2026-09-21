using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<RemoteMountInventory> LoadRemoteMountInventoryAsync(CancellationToken cancellationToken = default)
    {
        const string api = "SYNO.FileStation.Mount.List";
        if (_profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) || !_capabilities.TryGetValue(api, out var capability) ||
            capability.Name != api || capability.MinVersion > 1 || capability.MaxVersion < 1 || !NasServiceFormatAndPathSupported(capability))
            throw new NotSupportedException("remote-mount.inventory.unsupported");
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "get", null, cancellationToken).ConfigureAwait(false);
        if (data["mountConfig"] is not JsonObject config || data["remoteList"] is not JsonArray rows)
            throw new InvalidDataException("remote-mount.inventory.invalid");
        var enabled = RequiredNativeBool(config, "enable_remote_mount");
        var items = new List<RemoteMountConnection>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            var row = RequiredObject(node, "remote-mount.item");
            var path = CanonicalDirectoryPath(LocationRequiredString(row, "mount_point"));
            var protocol = LocationRequiredString(row, "type").ToUpperInvariant() switch
            { "CIFS" => FileRemoteProtocol.Cifs, "NFS" => FileRemoteProtocol.Nfs, _ => throw new InvalidDataException("remote-mount.protocol.unknown") };
            if (!RemoteMountProtocol.TryNormalizeSource(LocationRequiredString(row, "source"), protocol, out var source) || !seen.Add(path))
                throw new InvalidDataException("remote-mount.identity.invalid");
            bool? automatic = row.ContainsKey("auto_mount") ? RequiredNativeBool(row, "auto_mount") : null;
            items.Add(new(_profile.Id, path, source, protocol, automatic));
        }
        return new(_profile.Id, enabled, items.AsReadOnly());
    }
}
