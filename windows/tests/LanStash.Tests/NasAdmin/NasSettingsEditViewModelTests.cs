using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasSettingsEditViewModelTests
{
    private static readonly NasTerminalSettings Initial = new(false, 22, false, null);
    private static readonly NasTerminalSettings Desired = new(true, 2222, false, null);

    [Theory]
    [InlineData(false, true, 1)]
    [InlineData(true, false, 0)]
    [InlineData(false, false, 0)]
    public async Task TerminalUsesItsOwnCapabilityNotFileService(bool fileService, bool terminal, int expected)
    {
        var repository = Repository(fileService, terminal);
        var calls = 0;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(repository, "Synthetic", _ => Task.FromResult(Initial),
            (_, _) => { calls++; return Task.FromResult(Success()); });
        Assert.Equal(terminal, model.CanSave);
        await model.SaveAsync();
        Assert.Equal(expected, calls);
    }

    [Fact]
    public async Task ProxyUsesItsOwnCapabilityAndUnknownTypesStayClosed()
    {
        var repository = Repository(proxy: true);
        using var proxy = new NasSettingsEditViewModel<NasProxySettings>();
        await proxy.ActivateAsync(repository, "Synthetic", _ => Task.FromResult(new NasProxySettings(false, null, null)),
            (_, _) => Task.FromResult(Success()));
        Assert.True(proxy.CanSave);
        using var unknown = new NasSettingsEditViewModel<object>();
        await unknown.ActivateAsync(repository, "Synthetic", _ => Task.FromResult(new object()),
            (_, _) => throw new InvalidOperationException());
        Assert.False(unknown.CanSave);
        await unknown.SaveAsync();
    }

    [Theory]
    [InlineData(MutationResultStatus.SubmittedButUnverified)]
    [InlineData(MutationResultStatus.CancellationRequestedAfterSubmission)]
    [InlineData(MutationResultStatus.PartialSuccess)]
    public async Task SubmittedResultsNeverClaimSavedOrReplayWithoutFreshRead(MutationResultStatus status)
    {
        var calls = 0;
        var current = Initial;
        var failRead = false;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic",
            _ => failRead ? Task.FromException<NasTerminalSettings>(new IOException()) : Task.FromResult(current),
            (_, _) => { calls++; return Task.FromResult(new MutationResult(1, status, "saveTerminal", true, true,
                new MutationResultCounts(0, 0, 1))); });
        model.Draft = Desired;
        await model.SaveAsync();
        Assert.Equal(NasSettingsEditState.NeedsReview, model.State);
        Assert.False(model.WasSuccessful);
        Assert.False(model.CanEdit);
        Assert.False(model.CanSave);
        Assert.NotNull(model.ErrorMessage);
        model.Draft = Initial;
        model.BeginEdit(); model.CancelEdit(); model.SetUnsupported();
        await model.SaveAsync();
        Assert.Equal(Desired, model.Draft);
        Assert.Equal(1, calls);
        failRead = true;
        await model.LoadAsync();
        Assert.Null(model.Draft);
        Assert.False(model.CanSave);
        model.BeginEdit();
        await model.SaveAsync();
        Assert.Equal(1, calls);
        failRead = false; current = Desired;
        await model.LoadAsync();
        Assert.Equal(Desired, model.Draft);
        Assert.True(model.CanSave);
        Assert.Null(model.LastResult);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task DoubleSaveAndEditCannotCancelOrDuplicateSubmission()
    {
        var completion = new TaskCompletionSource<MutationResult>();
        var calls = 0; var loads = 0;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic",
            _ => { loads++; return Task.FromResult(Initial); },
            (_, _) => { calls++; return completion.Task; });
        model.Draft = Desired;
        var saving = model.SaveAsync();
        Assert.True(model.IsSaving);
        await model.SaveAsync(); await model.LoadAsync();
        model.CancelEdit(); model.BeginEdit(); model.Draft = Initial;
        Assert.Equal(Desired, model.Draft);
        Assert.Equal(1, calls);
        Assert.Equal(1, loads);
        completion.SetResult(Success());
        await saving;
        Assert.True(model.WasSuccessful);
        Assert.False(model.CanSave);
        model.BeginEdit();
        Assert.Equal(Desired, model.Draft);
    }

    [Fact]
    public async Task SaverExceptionIsUnknownAndCannotBeRetriedByChangingDraft()
    {
        var calls = 0;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic", _ => Task.FromResult(Initial),
            (_, _) => { calls++; throw new IOException(); });
        await model.SaveAsync();
        Assert.Equal(NasSettingsEditState.NeedsReview, model.State);
        model.Draft = Desired;
        await model.SaveAsync();
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task SwitchingRepositoryRejectsLateSaveAndLoadsNewProfile()
    {
        var completion = new TaskCompletionSource<MutationResult>();
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "First", _ => Task.FromResult(Initial),
            (_, _) => completion.Task);
        var saving = model.SaveAsync();
        await model.ActivateAsync(Repository(), "Second", _ => Task.FromResult(Desired),
            (_, _) => throw new InvalidOperationException());
        completion.SetResult(Success());
        await saving;
        Assert.Equal(Desired, model.Draft);
        Assert.Null(model.LastResult);
        Assert.False(model.CanSave);
        Assert.Equal(NasSettingsEditState.Editing, model.State);
    }

    [Fact]
    public async Task FailedRefreshClearsOldDraftAndCannotSaveStaleSettings()
    {
        var failRead = false;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic",
            _ => failRead ? Task.FromException<NasTerminalSettings>(new IOException()) : Task.FromResult(Initial),
            (_, _) => throw new InvalidOperationException());
        failRead = true;
        await model.LoadAsync();
        Assert.Null(model.Draft);
        Assert.False(model.CanSave);
        model.BeginEdit(); await model.SaveAsync();
        Assert.Equal(NasSettingsEditState.Failed, model.State);
    }

    private static MutationResult Success() =>
        new(1, MutationResultStatus.ConfirmedSuccess, "saveTerminal", true, false, new MutationResultCounts(1, 0, 0));

    [Fact]
    public async Task SnapshotSaverReceivesFixedBaselineDesiredAndNonEmptyRequestId()
    {
        var completion = new TaskCompletionSource<MutationResult>();
        var calls = 0;
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic", _ => Task.FromResult(Initial),
            (_, _) => throw new InvalidOperationException("不应调用无基线的旧保存接口"),
            (baseline, desired, requestId, _) =>
            {
                calls++;
                Assert.Equal(Initial, baseline); Assert.Equal(Desired, desired); Assert.NotEqual(Guid.Empty, requestId);
                return completion.Task;
            });
        model.Draft = Desired;
        var saving = model.SaveAsync();
        model.Draft = Initial;
        await model.SaveAsync();
        Assert.Equal(1, calls);
        completion.SetResult(Success());
        await saving;
        Assert.True(model.WasSuccessful);
    }

    [Theory]
    [InlineData(MutationErrorCategory.Permission)]
    [InlineData(MutationErrorCategory.Authentication)]
    public async Task ExplicitRejectionDoesNotSuggestThatSettingsMayHaveBeenSaved(MutationErrorCategory category)
    {
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic", _ => Task.FromResult(Initial),
            (_, _) => Task.FromResult(new MutationResult(1,
                category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "saveTerminal", true, false, new(0, 1, 0), category)));
        await model.SaveAsync();
        Assert.Equal(NasSettingsEditState.Failed, model.State);
        Assert.False(model.WasSuccessful);
        Assert.DoesNotContain("may have been saved", model.ErrorMessage!);
        Assert.Contains(category == MutationErrorCategory.Permission ? "permission" : "Sign in", model.ErrorMessage!);
    }

    [Fact]
    public async Task MissingApiShowsUnavailableWithoutFabricatedDraft()
    {
        using var model = new NasSettingsEditViewModel<NasFileServiceSettings>();
        await model.ActivateAsync(Repository(), "Synthetic",
            _ => Task.FromException<NasFileServiceSettings>(new DsmException("synthetic", "synthetic", 102)),
            (_, _) => throw new InvalidOperationException());
        Assert.Equal(NasSettingsEditState.Unsupported, model.State);
        Assert.Null(model.Draft);
        Assert.False(model.CanSave);
        Assert.Contains("DSM Control Panel", model.ErrorMessage!);
    }

    [Fact]
    public async Task PreflightConflictRequiresReloadWithoutClaimingSubmission()
    {
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await model.ActivateAsync(Repository(terminal: true), "Synthetic", _ => Task.FromResult(Initial),
            (_, _) => Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "saveTerminal",
                false, true, new(0, 1, 0), MutationErrorCategory.Conflict)));
        await model.SaveAsync();
        Assert.Equal(NasSettingsEditState.NeedsReview, model.State);
        Assert.Contains("Nothing was saved by this attempt", model.ErrorMessage!);
        Assert.DoesNotContain("may have been saved", model.ErrorMessage!);
        Assert.False(model.CanSave);
    }

    [Theory]
    [InlineData(true)] [InlineData(false)]
    public async Task RemoteAccessSnapshotOnlyUsesItsOwnCapabilityAndOriginalBaseline(bool writable)
    {
        var repository = Repository(); var fake = (SettingsRepositoryProxy)(object)repository;
        fake.Availability = fake.Availability with { CanSaveRemoteAccess = writable };
        var baseline = new NasRemoteAccessSettings(true, false, true, NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router);
        var desired = baseline with { RouterConfigurationEnabled = true }; var calls = 0;
        using var model = new NasSettingsEditViewModel<NasRemoteAccessSettings>();
        await model.ActivateAsync(repository, "Synthetic", _ => Task.FromResult(baseline), (before, after, id, _) =>
        {
            Assert.Equal(baseline, before); Assert.Equal(desired, after); Assert.NotEqual(Guid.Empty, id);
            calls++; return Task.FromResult(Success());
        });
        model.Draft = desired; await model.SaveAsync(); Assert.Equal(writable ? 1 : 0, calls);
    }

    [Fact]
    public async Task SnapshotOnlyUnknownSaveCannotRepeatUntilReload()
    {
        var repository = Repository(); var fake = (SettingsRepositoryProxy)(object)repository;
        fake.Availability = fake.Availability with { CanSaveRemoteAccess = true };
        var baseline = new NasRemoteAccessSettings(true, false, true, NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router); var calls = 0;
        using var model = new NasSettingsEditViewModel<NasRemoteAccessSettings>();
        await model.ActivateAsync(repository, "Synthetic", _ => Task.FromResult(baseline), (_, _, _, _) =>
        { calls++; return Task.FromResult(new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "saveRemoteAccess", true, true, new(0, 0, 1))); });
        model.Draft = baseline with { RelayEnabled = false }; await model.SaveAsync(); await model.SaveAsync();
        Assert.Equal(1, calls); Assert.Equal(NasSettingsEditState.NeedsReview, model.State); Assert.False(model.CanSave);
    }

    [Fact]
    public async Task SnapshotOnlyWithoutAnySaverIsRejected()
    {
        using var model = new NasSettingsEditViewModel<NasTerminalSettings>();
        await Assert.ThrowsAsync<ArgumentNullException>(() => model.ActivateAsync(Repository(), "Synthetic", _ => Task.FromResult(Initial),
            (Func<NasTerminalSettings, NasTerminalSettings, Guid, CancellationToken, Task<MutationResult>>)null!));
    }

    private static INasSettingsRepository Repository(bool fileService = false, bool terminal = false, bool proxy = false)
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, SettingsRepositoryProxy>();
        ((SettingsRepositoryProxy)(object)repository).Availability = new(
            false, fileService, terminal, proxy, false, false, false, false, false, false,
            false, false, false, false, false, false, false, false, false, false);
        return repository;
    }

    // 编辑器测试只读取能力；加载和提交由它既有的委托注入，不模拟无关端点。
    public class SettingsRepositoryProxy : DispatchProxy
    {
        public NasSettingsWriteAvailability Availability { get; set; } = null!;
        protected override object? Invoke(MethodInfo? method, object?[]? args) =>
            method?.Name == "get_WriteAvailability" ? Availability : throw new NotSupportedException();
    }
}
