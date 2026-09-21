using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed partial class DesktopCloudDriveSyncStore
{
    internal async Task<IReadOnlyList<CloudDriveRelocationOperation>> ReadRelocationOperationsAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token).ConfigureAwait(false)).NamespaceOperations?.ToArray() ?? [];
    }

    internal async Task AddRelocationOperationAsync(DesktopDriveMapping mapping, CloudDriveRelocationOperation operation, CancellationToken token = default)
    {
        ValidateRelocation(mapping, operation);
        if (operation.Step != 0 || operation.Phase != CloudDriveRelocationPhase.Prepared) throw new InvalidOperationException("cloud.relocate.invalid_transition");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        var operations = state.NamespaceOperations ?? [];
        if (operations.Any(item => item.Id == operation.Id)) throw new InvalidOperationException("cloud.relocate.duplicate_operation");
        if (operations.Any(item => item.IsPending && PathsOverlap(item, operation)) ||
            state.Changes.Any(item => item.Phase == CloudDriveChangePhase.Submitted && DesktopDrivePath.IsAncestorOrSame(operation.Source, item.RemotePath)) ||
            state.LocalCreations?.Keys.Any(path => ReservedPaths(operation).Any(target => DesktopDrivePath.IsAncestorOrSame(target, path))) == true ||
            state.Changes.Any(item => item.IsPending && !DesktopDrivePath.IsAncestorOrSame(operation.Source, item.RemotePath) &&
                ReservedPaths(operation).Any(target => DesktopDrivePath.IsAncestorOrSame(target, item.RemotePath))))
            throw new InvalidOperationException("cloud.sync.pending_changes");
        CheckDeletionBlock(state, operation.Source); CheckDeletionBlock(state, operation.Destination);
        await WriteAsync(mapping, state with { Version = Math.Max(7, state.Version), NamespaceOperations = [.. operations, operation],
            LocalNames = state.LocalNames ?? [], EmptyFileBaselines = state.EmptyFileBaselines ?? [],
            LocalCreations = state.LocalCreations ?? [], Relocations = state.Relocations ?? [] }, token).ConfigureAwait(false);
    }

    internal async Task UpdateRelocationOperationAsync(DesktopDriveMapping mapping, CloudDriveRelocationOperation expected,
        CloudDriveRelocationOperation replacement, CancellationToken token = default)
    {
        ValidateRelocation(mapping, replacement);
        var transition = (expected.Phase, replacement.Phase) switch
        {
            (CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.ReadyForNextStep or CloudDriveRelocationPhase.Rejected, CloudDriveRelocationPhase.Submitted)
                => replacement.Step == expected.Step,
            (CloudDriveRelocationPhase.Submitted, CloudDriveRelocationPhase.Rejected) => replacement.Step == expected.Step,
            (CloudDriveRelocationPhase.Submitted, CloudDriveRelocationPhase.ReadyForNextStep or CloudDriveRelocationPhase.ServerVerified)
                => replacement.Step == expected.Step + 1,
            (CloudDriveRelocationPhase.ServerVerified, CloudDriveRelocationPhase.Completed) => replacement.Step == expected.Step,
            (CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.Rejected, CloudDriveRelocationPhase.Abandoned)
                => expected.Step == 0 && replacement.Step == 0,
            _ => false,
        };
        if (expected.Id != replacement.Id || expected.ItemIdentity != replacement.ItemIdentity || expected.Source != replacement.Source ||
            expected.Destination != replacement.Destination || expected.LocalName != replacement.LocalName || expected.IsDirectory != replacement.IsDirectory ||
            expected.Length != replacement.Length || expected.ModifiedAt != replacement.ModifiedAt || !expected.Steps.SequenceEqual(replacement.Steps) ||
            expected.CreatedAt != replacement.CreatedAt || !transition)
            throw new InvalidOperationException("cloud.relocate.invalid_transition");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        var operations = state.NamespaceOperations ?? throw new InvalidDataException("cloud.relocate.operation_missing");
        var index = operations.FindIndex(item => item.Id == expected.Id);
        if (index < 0 || !SameOperation(operations[index], expected)) throw new InvalidDataException("cloud.relocate.state_changed");
        operations[index] = replacement;
        await WriteAsync(mapping, state, token).ConfigureAwait(false);
    }

    internal static bool SameOperation(CloudDriveRelocationOperation left, CloudDriveRelocationOperation right) =>
        left with { Steps = right.Steps } == right && left.Steps.SequenceEqual(right.Steps);

    internal async Task RequireNoRelocationAsync(DesktopDriveMapping mapping, string path, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        CheckRelocationBlock(await ReadAsync(mapping, token).ConfigureAwait(false), path);
    }

    private static IEnumerable<string> ReservedPaths(CloudDriveRelocationOperation operation) => operation.Steps.SelectMany(step => new[] { step.Source, step.Destination });
    private static void CheckRelocationBlock(Snapshot state, string path, Guid? ownOperation = null)
    {
        CheckDeletionBlock(state, path);
        if (state.NamespaceOperations?.Any(operation => operation.IsPending && operation.Id != ownOperation && ReservedPaths(operation).Any(target =>
            DesktopDrivePath.IsAncestorOrSame(target, path) || DesktopDrivePath.IsAncestorOrSame(path, target))) == true)
            throw new InvalidOperationException("cloud.relocate.pending");
    }

    private static bool PathsOverlap(CloudDriveRelocationOperation left, CloudDriveRelocationOperation right) =>
        ReservedPaths(left).Any(a => ReservedPaths(right).Any(b =>
            DesktopDrivePath.IsAncestorOrSame(a, b) || DesktopDrivePath.IsAncestorOrSame(b, a)));

    private static void ValidateRelocation(DesktopDriveMapping mapping, CloudDriveRelocationOperation operation)
    {
        CloudDriveWriteScope.RequireWritable(mapping, operation.Source); CloudDriveWriteScope.RequireWritable(mapping, operation.Destination);
        if (operation.Id == Guid.Empty || string.IsNullOrWhiteSpace(operation.ItemIdentity) || string.IsNullOrWhiteSpace(operation.LocalName) ||
            operation.LocalName is "." or ".." || operation.LocalName.Length > 255 || operation.LocalName.EndsWith('.') || operation.LocalName.EndsWith(' ') ||
            operation.LocalName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || operation.Length < 0 ||
            !Enum.IsDefined(operation.Phase) || operation.Steps is null || operation.Steps.Count is < 1 or > 2 ||
            operation.Step < 0 || operation.Step > operation.Steps.Count ||
            DesktopDrivePath.IsAncestorOrSame(operation.Source, operation.Destination) ||
            operation.Steps[0].Source != operation.Source || operation.Steps[^1].Destination != operation.Destination)
            throw new InvalidDataException("cloud.relocate.invalid_state");
        for (var index = 0; index < operation.Steps.Count; index++)
        {
            var step = operation.Steps[index]; CloudDriveWriteScope.RequireWritable(mapping, step.Source); CloudDriveWriteScope.RequireWritable(mapping, step.Destination);
            if (index > 0 && operation.Steps[index - 1].Destination != step.Source ||
                step.Move && PathName(step.Source) != PathName(step.Destination) ||
                !step.Move && Parent(step.Source) != Parent(step.Destination) ||
                new[] { step.Source, step.Destination }.Any(path => path.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase))))
                throw new InvalidDataException("cloud.relocate.invalid_state");
        }
        if ((operation.Phase is CloudDriveRelocationPhase.ServerVerified or CloudDriveRelocationPhase.Completed) != (operation.Step == operation.Steps.Count))
            throw new InvalidDataException("cloud.relocate.invalid_state");
    }

    private static string PathName(string path) => path[(path.LastIndexOf('/') + 1)..];
}
