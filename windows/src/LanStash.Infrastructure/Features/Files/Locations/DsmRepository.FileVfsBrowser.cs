using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanBrowseVfs => _profile.Id == _session.ProfileId && !string.IsNullOrEmpty(_session.Sid) &&
        HasFixedCapability(VfsProfileApi, 1) && HasFixedCapability("SYNO.FileStation.List", 2);
    public bool CanDownloadVfs => CanBrowseVfs && HasFixedCapability("SYNO.FileStation.Download", 2);

    public async Task<FileVfsFolder> ListVfsFolderAsync(FileVfsProfile profile, string path, CancellationToken cancellationToken = default)
    {
        if (!CanBrowseVfs || profile.ProfileId != _profile.Id || profile.State != FileVfsState.Connected || !FileVfsPath.Contains(profile, path)) throw VfsInvalid();
        if (!(await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false)).Contains(profile)) throw VfsInvalid();
        const string api = "SYNO.FileStation.List";
        var items = new List<FileItem>(); var paths = new HashSet<string>(StringComparer.Ordinal); int? total = null;
        do
        {
            var data = await _api.CallAsync(_profile, _session, FixedCapability(api, 2), "list", new Dictionary<string, string>
            {
                ["folder_path"] = ShareParameterString(api, path), ["offset"] = items.Count.ToString(CultureInfo.InvariantCulture),
                ["limit"] = "500", ["sort_by"] = ShareParameterString(api, "name"), ["sort_direction"] = ShareParameterString(api, "asc"),
                ["additional"] = "[\"size\",\"time\"]",
            }, cancellationToken).ConfigureAwait(false);
            if (data["files"] is not JsonArray rows || rows.Count > 500 || StrictInt(data, "offset") != items.Count ||
                StrictInt(data, "total") is not { } count || count < 0 || total is not null && total != count ||
                rows.Count > count - items.Count || rows.Count == 0 && items.Count != count) throw VfsInvalid();
            total = count;
            foreach (var node in rows)
            {
                if (node is not JsonObject row || StrictBool(row, "isdir") is not { } directory) throw VfsInvalid();
                var child = VfsText(row, "path"); var name = VfsText(row, "name");
                if (!FileVfsPath.IsChild(profile, path, child) || !paths.Add(child) || string.IsNullOrWhiteSpace(name) ||
                    name.Any(char.IsControl) || name.Contains('/') || name.Contains('\\')) throw VfsInvalid();
                var additional = row["additional"] as JsonObject;
                var sizeNode = row["size"] ?? additional?["size"];
                long size = 0;
                if (!directory && (sizeNode is not JsonValue bytes || !bytes.TryGetValue(out size) || size < 0)) throw VfsInvalid();
                var modifiedNode = (additional?["time"] as JsonObject)?["mtime"] ?? row["mtime"];
                DateTimeOffset? modified = null;
                if (modifiedNode is not null)
                {
                    if (modifiedNode is not JsonValue time || !time.TryGetValue<long>(out var seconds)) throw VfsInvalid();
                    try { modified = DateTimeOffset.FromUnixTimeSeconds(seconds); } catch (ArgumentOutOfRangeException) { throw VfsInvalid(); }
                }
                items.Add(new(child, name, directory, size, modified, null, false, false));
            }
        } while (items.Count < total);
        if (!(await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false)).Contains(profile)) throw VfsInvalid();
        return new(profile, path, items);
    }

    public async Task ValidateVfsDownloadAsync(FileVfsDownloadSource source, CancellationToken cancellationToken = default)
    {
        if (!CanDownloadVfs || !source.IsValid || source.Profile.ProfileId != _profile.Id) throw VfsInvalid();
        var folder = await ListVfsFolderAsync(source.Profile, source.Parent, cancellationToken).ConfigureAwait(false);
        if (!folder.Items.Contains(source.File)) throw VfsInvalid();
    }

    public async Task<FileRangeReadResult> ReadVfsRangeAsync(FileVfsDownloadSource source, long offset, long length,
        string? expectedContentVersion = null, CancellationToken cancellationToken = default)
    {
        await ValidateVfsDownloadAsync(source, cancellationToken).ConfigureAwait(false);
        return await _api.ReadFileRangeResultAsync(_profile, _session, FixedCapability("SYNO.FileStation.Download", 2),
            source.File.Path, offset, length, expectedContentVersion, source.File.Size, cancellationToken).ConfigureAwait(false);
    }
}
