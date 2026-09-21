using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string PublicVirtualMachineTaskApi = "SYNO.Virtualization.API.Task.Info";
    public bool CanReadTasks => HasPublicVirtualMachineVersion(PublicVirtualMachineTaskApi);

    public async Task<IReadOnlyList<VirtualMachineTaskSummary>> LoadVirtualMachineTasksAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!CanReadTasks) throw UnavailableVirtualMachineManagerError();
        var protectedIds = await ProtectedVirtualMachineTaskIdsAsync(cancellationToken).ConfigureAwait(false);
        var unique = await ReadVirtualMachineTaskIdsAsync(cancellationToken).ConfigureAwait(false);
        var result = new List<VirtualMachineTaskSummary>();
        var scope = ServiceScope();
        foreach (var id in unique.Order(StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var key = ServiceHash(scope + "\n" + id);
            try
            {
                result.Add((await ReadVirtualMachineTaskAsync(id, key, cancellationToken).ConfigureAwait(false)) with { IsProtected = protectedIds.Contains(id) });
            }
            catch (OperationCanceledException) { throw; }
            catch (DsmException error) when (IsMutationAuthenticationFailure(error)) { throw; }
            catch (Exception)
            {
                cancellationToken.ThrowIfCancellationRequested();
                result.Add(new(key, VirtualMachineTaskState.ReadFailed, null));
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    private async Task<HashSet<string>> ReadVirtualMachineTaskIdsAsync(CancellationToken cancellationToken)
    {
        var data = await CallPublicVirtualMachineAsync(PublicVirtualMachineTaskApi, "list", null, cancellationToken).ConfigureAwait(false);
        if (data["task_ids"] is not JsonArray ids) throw InvalidVirtualMachineManagerResponse();
        var unique = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in ids)
        {
            if (node is not JsonValue value || !value.TryGetValue<string>(out var id) || !VirtualMachinePowerRules.ValidId(id) || !unique.Add(id))
                throw InvalidVirtualMachineManagerResponse();
        }
        return unique;
    }

    private async Task<VirtualMachineTaskSummary> ReadVirtualMachineTaskAsync(string id, string key, CancellationToken cancellationToken)
    {
        var detail = await SecurityCallAsync(_capabilities[PublicVirtualMachineTaskApi] with { MinVersion = 1, MaxVersion = 1 }, "get",
            new Dictionary<string, object> { ["task_id"] = id }, cancellationToken).ConfigureAwait(false);
        if (detail["finish"] is not JsonValue finishedValue || !finishedValue.TryGetValue<bool>(out var finished) || detail["task_info"] is not JsonObject info)
            throw InvalidVirtualMachineManagerResponse();
        int? progress = null;
        if (info.ContainsKey("progress"))
        {
            if (info["progress"] is not JsonValue progressValue || !progressValue.TryGetValue<int>(out var number) || number is < 0 or > 100)
                throw InvalidVirtualMachineManagerResponse();
            progress = number;
        }
        return new(key, finished ? VirtualMachineTaskState.Finished : VirtualMachineTaskState.Running, progress);
    }
}
