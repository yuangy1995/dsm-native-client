using System.Security.Cryptography;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasPackageInstallProgress> UploadPackageAsync(Guid requestId, string filePath, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        if (!AllowsPackageInstallation) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        if (requestId == Guid.Empty || !Path.IsPathFullyQualified(filePath) || !Path.GetExtension(filePath).Equals(".spk", StringComparison.OrdinalIgnoreCase) ||
            !_api.CanUploadPackage || !HasPackageInstallationCapabilities) throw PackageError("NasPackageCenterInvalidFile");
        if (!HasPackageConfigurationCapabilities) throw PackageError("NasPackageUnsupported", MutationErrorCategory.Unsupported);
        var file = new FileInfo(filePath);
        if (!file.Exists || file.Length <= 0 || (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw PackageError("NasPackageCenterInvalidFile");
        await using var source = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var digest = Convert.ToHexString(await SHA256.HashDataAsync(source, token).ConfigureAwait(false)).ToLowerInvariant(); source.Position = 0;
        var signature = ServiceHash("package-upload:" + digest);
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            if (ExistingPackageRequest(requestId, signature) is { } previous) return PackageProgressForRecord(previous);
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var capability = SecurityCapability("SYNO.Core.Package.Installation", 1) ?? throw PackageError("NasPackageUnsupported", MutationErrorCategory.Unsupported);
            var entry = NewPackageRecord(requestId, signature, NasPackageActivityKind.Upload, ServiceHash("package-upload"), digest);
            var record = entry.Package!; record.SubmissionKind = PackageSubmissionKind.Upload; record.Stage = NasPackageStepStage.Unknown; record.Submitted = true;
            token.ThrowIfCancellationRequested(); await SaveNasManagementAsync(entry).ConfigureAwait(false);
            JsonObject checkedPackage;
            try { checkedPackage = await _api.UploadPackageAsync(_profile, _session, capability, source, source.Length, token).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            { record.Stage = NasPackageStepStage.Rejected; record.Error = ServiceErrorCategory(error); await SaveNasManagementAsync(entry).ConfigureAwait(false); return PackageProgressForRecord(entry); }
            catch (Exception) { record.Error = MutationErrorCategory.Network; await SaveNasManagementAsync(entry).ConfigureAwait(false); return PackageProgressForRecord(entry); }
            record.Accepted = true; await SaveNasManagementAsync(entry).ConfigureAwait(false);
            var metadata = PackageMetadataObject(checkedPackage);
            if (PackageText(metadata, "id") is not { } id || !StablePackageId(id) || PackageText(metadata, "name") is not { Length: > 0 } name ||
                PackageText(metadata, "version") is not { Length: > 0 } version)
            {
                await CleanOwnedPackageRecordAsync(entry, checkedPackage, token).ConfigureAwait(false);
                throw InvalidNasServiceSettings();
            }
            var installed = await LoadPackagesAsync(token).ConfigureAwait(false);
            var current = installed.FirstOrDefault(item => item.Id == id);
            if (current is not null && string.IsNullOrWhiteSpace(current.Version)) throw InvalidNasServiceSettings();
            var package = new NasPackageCatalogEntry(id, name, version, PackageText(metadata, "description") ?? "", "", "", [], false, false, source.Length,
                current?.Version, current is not null && current.Version != version);
            var candidate = new PackageCandidate(package, checkedPackage);
            record.Items = [InstallReceipt(candidate, installed)];
            var job = new PackageInstallJob(entry, [candidate], [new(package, [], "")], installed, [], true, _packageTrackingLifetime.Token)
            { Manual = true, Checked = checkedPackage, Phase = NasPackageInstallPhase.Unknown };
            NasManagementRecords.PackageJobs[entry.Id] = job; await SaveNasManagementAsync(entry).ConfigureAwait(false);
            try
            {
                job.Configuration = await PackageConfigurationAsync(checkedPackage, package, token).ConfigureAwait(false);
                job.Phase = NasPackageInstallPhase.NeedsOptions; return job.Progress;
            }
            catch (NasPackageCenterException error) when (error.ResourceKey is "NasPackageCenterSignatureFailed" or "NasPackageCenterCustomOptions")
            {
                job.MessageKey = error.ResourceKey; await CleanOwnedPackageAsync(job, token).ConfigureAwait(false);
                if (job.Phase == NasPackageInstallPhase.Cancelled) { job.Phase = NasPackageInstallPhase.Failed; record.Stage = NasPackageStepStage.Rejected; await SaveNasManagementAsync(entry).ConfigureAwait(false); }
                return job.Progress;
            }
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task<NasPackageInstallConfiguration> PackageConfigurationAsync(JsonObject data, NasPackageCatalogEntry expected, CancellationToken token)
    {
        if (data["codesign_error"] is not null) throw PackageError("NasPackageCenterSignatureFailed");
        var metadata = PackageMetadataObject(data);
        if (PackageText(metadata, "id") != expected.PackageId || PackageText(metadata, "version") != expected.Version ||
            PackageText(data, "errmsg") is { Length: > 0 }) throw InvalidNasServiceSettings();
        await PackageFeasibilityAsync([expected.PackageId], token).ConfigureAwait(false);
        var settings = await PackageCallAsync("SYNO.Core.Package.Setting", 1, "get",
            new() { ["option"] = PackageBoolean(metadata, "install_on_cold_storage") == true ? "include_cold_storage" : "" }, token).ConfigureAwait(false);
        var defaults = await PackageCallAsync("SYNO.Core.Package.Setting.Volume", 1, "get", new(), token).ConfigureAwait(false);
        var volumes = PackageVolumes(settings["volume_list"]);
        var system = PackageText(metadata, "install_type") is "system" or "system_hidden";
        if (system) volumes = [];
        var selected = system ? "" : PackageText(defaults, "default_vol") ?? (volumes.Length == 1 ? volumes[0].Id : "");
        if (selected == "no_default_vol") selected = "";
        var license = PackageText(metadata, "licence"); var restart = PackageBoolean(metadata, "install_reboot") == true;
        return new(expected.Name, expected.Version, string.IsNullOrEmpty(license) ? null : license,
            ParsePackageInstallFields(metadata["install_pages"]), volumes, selected, PackageBoolean(metadata, "startable") == true && !restart, restart);
    }
    private static JsonObject PackageMetadataObject(JsonObject data)
    {
        var result = (JsonObject)data.DeepClone();
        if (data["additional"] is not null && data["additional"] is not JsonObject) throw InvalidNasServiceSettings();
        if (data["additional"] is JsonObject additional)
            foreach (var pair in additional) result[pair.Key] = pair.Value?.DeepClone();
        result.Remove("additional"); return result;
    }
    private static NasPackageInstallField[] ParsePackageInstallFields(JsonNode? value)
    {
        if (value is null) return [];
        try
        {
            if (value is JsonValue textValue && textValue.TryGetValue<string>(out var encoded))
            { if (encoded.Length == 0) return []; value = JsonNode.Parse(Uri.UnescapeDataString(encoded)); }
            if (value is not JsonArray pages || ContainsUnsupportedPackageOptions(pages)) throw PackageError("NasPackageCenterCustomOptions");
            var fields = new List<NasPackageInstallField>(); var keys = new HashSet<string>(StringComparer.Ordinal);
            for (var pageIndex = 0; pageIndex < pages.Count; pageIndex++)
            {
                if (pages[pageIndex] is not JsonObject page || page["items"] is not JsonArray items) throw PackageError("NasPackageCenterCustomOptions");
                for (var itemIndex = 0; itemIndex < items.Count; itemIndex++)
                {
                    if (items[itemIndex] is not JsonObject item) throw PackageError("NasPackageCenterCustomOptions");
                    var group = $"page-{pageIndex}-item-{itemIndex}";
                    if (PackageText(item, "desc") is { Length: > 0 } description)
                        fields.Add(new(group, description, NasPackageOptionKind.Description, new(Text: ""), []));
                    var type = PackageText(item, "type");
                    if (type is null) { if (item["subitems"] is not null) throw PackageError("NasPackageCenterCustomOptions"); continue; }
                    var kind = type switch { "textfield" => NasPackageOptionKind.Text, "password" => NasPackageOptionKind.Password,
                        "multiselect" => NasPackageOptionKind.Toggle, "singleselect" => NasPackageOptionKind.Radio, "combobox" => NasPackageOptionKind.Choice,
                        _ => throw PackageError("NasPackageCenterCustomOptions") };
                    if (item["subitems"] is not JsonArray children) throw PackageError("NasPackageCenterCustomOptions");
                    foreach (var node in children)
                    {
                        if (node is not JsonObject child || PackageText(child, "key") is not { Length: > 0 } key || !keys.Add(key)) throw PackageError("NasPackageCenterCustomOptions");
                        var validator = child["validator"] as JsonObject;
                        if (child["validator"] is not null && validator is null) throw PackageError("NasPackageCenterCustomOptions");
                        var choices = kind == NasPackageOptionKind.Choice ? PackageFieldChoices(child["store"]) : [];
                        var initial = kind is NasPackageOptionKind.Toggle or NasPackageOptionKind.Radio
                            ? new NasPackageOptionValue(Flag: PackageBoolean(child, "defaultValue") == true)
                            : new NasPackageOptionValue(Text: PackageText(child, "defaultValue") ?? PackageText(child, "value") ?? "");
                        var minimum = validator is null ? null : PackageInteger(validator, "minLength"); var maximum = validator is null ? null : PackageInteger(validator, "maxLength");
                        if (minimum > int.MaxValue || maximum > int.MaxValue || minimum > maximum) throw PackageError("NasPackageCenterCustomOptions");
                        fields.Add(new(key, PackageText(child, "desc") ?? key, kind, initial, choices, kind == NasPackageOptionKind.Radio ? group : null,
                            validator is not null && PackageBoolean(validator, "allowBlank") == false, (int?)minimum, (int?)maximum));
                    }
                }
            }
            return fields.ToArray();
        }
        catch (NasPackageCenterException) { throw; }
        catch { throw PackageError("NasPackageCenterCustomOptions"); }
    }
    private static bool ContainsUnsupportedPackageOptions(JsonNode value) => value switch
    {
        JsonArray array => array.Any(node => node is not null && ContainsUnsupportedPackageOptions(node)),
        JsonObject obj => obj.Any(pair => pair.Key is "fn" or "regex" or "vtype" or "api_store" or "listeners" or "script" ||
            pair.Key is "hidden" or "disabled" && PackageBoolean(obj, pair.Key) == true || pair.Value is not null && ContainsUnsupportedPackageOptions(pair.Value)),
        _ => false,
    };
    private static NasPackageCategory[] PackageFieldChoices(JsonNode? value)
    {
        if (value is not JsonArray rows) throw PackageError("NasPackageCenterCustomOptions");
        var result = rows.Select(node =>
        {
            if (node is JsonValue scalar && scalar.TryGetValue<string>(out var text)) return new NasPackageCategory(text, text);
            if (node is JsonArray pair && pair.Count == 2 && pair[0] is JsonValue key && key.TryGetValue<string>(out var id) &&
                pair[1] is JsonValue label && label.TryGetValue<string>(out var name)) return new NasPackageCategory(id, name);
            throw PackageError("NasPackageCenterCustomOptions");
        }).ToArray();
        if (result.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != result.Length) throw PackageError("NasPackageCenterCustomOptions");
        return result;
    }
}
