using System.Reflection;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveLifecycleTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-cloud-lifetime-" + Guid.NewGuid().ToString("N"));

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LateReadCannotRegisterAfterCancellationOrDisposal(bool dispose)
    {
        var mapping = Mapping();
        var store = new DesktopCloudDriveStore(Path.Combine(_root, "mappings.json"));
        await store.SaveAsync([mapping]);
        using var service = new DesktopCloudDriveService(store);
        SetMappings(service, [mapping]);
        var repository = DispatchProxy.Create<IDsmRepository, HeldRead>();
        var read = (HeldRead)repository;
        using var cancellation = new CancellationTokenSource();
        var pending = service.ActivateAsync(mapping.ProfileId, repository, cancellation.Token);
        await read.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (dispose) service.Dispose(); else cancellation.Cancel();
        read.Release.TrySetResult(new([], 0, 0));
        if (dispose) await Assert.ThrowsAsync<ObjectDisposedException>(() => pending);
        else await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.Equal(!dispose, read.Token.IsCancellationRequested);
        Assert.Equal(DesktopDriveMappingRuntime.Default, service.Runtime(mapping));
        Assert.Equal(DesktopDriveMappingRuntime.Default, await store.LoadRuntimeAsync(mapping.Id));
        Assert.False(Directory.Exists(service.MappingPath(mapping)));
    }

    [Fact]
    public async Task CancellationBeforeReadNeverTouchesRepository()
    {
        using var service = new DesktopCloudDriveService(new(Path.Combine(_root, "mappings.json")));
        var mapping = Mapping(); SetMappings(service, [mapping]);
        var repository = DispatchProxy.Create<IDsmRepository, HeldRead>();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.ActivateAsync(mapping.ProfileId, repository, new(true)));
        Assert.False(((HeldRead)repository).Entered.Task.IsCompleted);
    }

    [Fact]
    public async Task PausedMappingDoesNotReadOrRegister()
    {
        var mapping = Mapping();
        var store = new DesktopCloudDriveStore(Path.Combine(_root, "mappings.json"));
        await store.SaveAsync([mapping]);
        using var service = new DesktopCloudDriveService(store); SetMappings(service, [mapping]);
        await service.PauseAsync(mapping);
        var repository = DispatchProxy.Create<IDsmRepository, HeldRead>();
        await service.ActivateAsync(mapping.ProfileId, repository);
        Assert.False(((HeldRead)repository).Entered.Task.IsCompleted);
        Assert.True(service.Runtime(mapping).IsManuallyPaused);
        Assert.Equal(DesktopDriveMappingState.Paused, (await store.LoadRuntimeAsync(mapping.Id)).State);
    }

    [Fact]
    public async Task PausingDuringReadPreventsLateRegistrationAndPreservesPause()
    {
        var mapping = Mapping();
        var store = new DesktopCloudDriveStore(Path.Combine(_root, "mappings.json")); await store.SaveAsync([mapping]);
        using var service = new DesktopCloudDriveService(store); SetMappings(service, [mapping]);
        var repository = DispatchProxy.Create<IDsmRepository, HeldRead>(); var read = (HeldRead)repository;
        var pending = service.ActivateAsync(mapping.ProfileId, repository);
        await read.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await service.PauseAsync(mapping); read.Release.TrySetResult(new([], 0, 0));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.Equal(DesktopDriveMappingState.Paused, service.Runtime(mapping).State);
        Assert.True(service.Runtime(mapping).IsManuallyPaused);
    }

    [Fact]
    public void IdenticalPathsOnOtherNasNeverSelectItsMapping()
    {
        using var service = new DesktopCloudDriveService(new(Path.Combine(_root, "mappings.json")));
        var first = Mapping(); var second = Mapping(); SetMappings(service, [first, second]);
        Assert.Equal(first, service.MappingContaining(first.ProfileId, ["/synthetic/file.txt"]));
        Assert.Equal(second, service.MappingContaining(second.ProfileId, ["/synthetic/file.txt"]));
        Assert.Null(service.MappingContaining(Guid.NewGuid(), ["/synthetic/file.txt"]));
        Assert.Null(service.MappingContaining(first.ProfileId, []));
    }

    private static DesktopDriveMapping Mapping() => new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/synthetic"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UnixEpoch);

    private static void SetMappings(DesktopCloudDriveService service, List<DesktopDriveMapping> mappings) =>
        typeof(DesktopCloudDriveService).GetField("_mappings", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(service, mappings);

    public class HeldRead : DispatchProxy
    {
        internal CancellationToken Token;
        internal TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource<FilePage> Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name != nameof(IDsmRepository.ListFilesAsync)) throw new NotSupportedException(method.Name);
            Token = (CancellationToken)args![^1]!; Entered.TrySetResult();
            return Release.Task; // 故意忽略取消，复验已结束工作区的迟到响应。
        }
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, true); }
}
