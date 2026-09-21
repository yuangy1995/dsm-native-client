using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDdnsViewModelTests
{
    [Fact]
    public async Task ActivateWithWriteAvailabilityLoadsProvidersAndRecords()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.Providers.Add(new NasDDNSProvider("synology", "Synology", "https://synology.com"));
        repository.Records.Add(new NasDDNSRecord("ddns-1", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", true));
        using var model = new NasDdnsViewModel();

        await model.ActivateAsync(repository);

        Assert.Single(model.Providers);
        Assert.Equal("synology", model.Providers[0].Id);
        Assert.Single(model.Records);
        Assert.Equal("test.synology.me", model.Records[0].Hostname);
        Assert.False(model.IsLoading);
        Assert.False(model.IsEditing);
    }

    [Fact]
    public async Task ActivateWithoutWriteAvailabilityStillLoadsReadableDirectory()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: false);
        repository.Providers.Add(new("synthetic", "Synthetic", null));
        repository.Records.Add(new("synthetic", "synthetic", "nas.example.invalid", "", null, null, true));
        using var model = new NasDdnsViewModel();

        await model.ActivateAsync(repository);

        Assert.Single(model.Providers);
        Assert.Single(model.Records);
        Assert.True(model.IsUnsupported);
    }

    [Fact]
    public async Task BeginCreateSetsEditingState()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();

        Assert.True(model.IsEditing);
        Assert.True(model.Draft.IsEnabled);
    }

    [Fact]
    public async Task ClosingOrSwitchingClearsPasswordOnExistingDraftReference()
    {
        var model = new NasDdnsViewModel();
        await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: false));
        model.BeginCreate(); var previous = model.Draft; previous.Password = "synthetic-secret";
        await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: false));
        Assert.Null(previous.Password);
        model.BeginCreate(); var final = model.Draft; final.Password = "synthetic-secret";
        model.Dispose();
        Assert.Null(final.Password); Assert.Empty(model.Providers); Assert.Empty(model.Records);
    }

    [Fact]
    public void DraftStringRepresentationDoesNotExposeCredentialsOrAccount()
    {
        var draft = new NasDDNSDraft { Password = "synthetic-secret", Username = "synthetic-account", Hostname = "nas.example.invalid" };
        Assert.Equal(nameof(NasDDNSDraft), draft.ToString());
    }

    [Fact]
    public async Task BeginEditPopulatesDraftFromRecord()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        var record = new NasDDNSRecord("ddns-1", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", false);
        model.BeginEdit(record);

        Assert.True(model.IsEditing);
        Assert.Equal("synology", model.Draft.ProviderId);
        Assert.Equal("test.synology.me", model.Draft.Hostname);
        Assert.Equal("user", model.Draft.Username);
        Assert.False(model.Draft.IsEnabled);
    }

    [Fact]
    public async Task CancelEditResetsState()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        model.CancelEdit();

        Assert.False(model.IsEditing);
        Assert.Null(model.Draft.Hostname);
    }

    [Fact]
    public async Task SaveWithInvalidDraftFailsValidation()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        // 草稿字段尚未填写完整。
        model.SaveAsync().GetAwaiter();

        Assert.NotNull(model.ErrorMessage);
    }

    [Fact]
    public async Task SaveWithValidDraftSucceeds()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.NextSaveResult = new MutationResult(1, MutationResultStatus.ConfirmedSuccess,
            "saveDDNS", submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        model.BeginCreate();
        model.Draft.ProviderId = "synology";
        model.Draft.Hostname = "new.synology.me";
        model.Draft.Username = "user";
        model.Draft.Password = "secret";

        repository.Providers.Add(new("synology", "Synthetic provider", null));
        model.Providers.Add(repository.Providers[0]);
        Assert.True(model.ConfirmAction());

        await model.SaveAsync();

        Assert.False(model.IsEditing);
        Assert.True(model.WasSuccessful);
        Assert.Null(model.ErrorMessage);
    }

    [Fact]
    public async Task DeleteCallsRepositoryAndRefreshes()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), writeAvailable: true);
        repository.Records.Add(new NasDDNSRecord("synology", "synology", "test.synology.me",
            "user", "1.2.3.4", "normal", true));
        repository.NextDeleteResult = new MutationResult(1, MutationResultStatus.ConfirmedSuccess,
            "deleteDDNS", submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));
        using var model = new NasDdnsViewModel();
        await model.ActivateAsync(repository);

        Assert.Single(model.Records);

        model.SelectAction(NasDdnsAction.Delete, model.Records[0]);
        Assert.True(model.ConfirmAction());
        await model.DeleteAsync("synology");

        Assert.Empty(model.Records); // 删除后重新读取目录。
    }

    private static async Task<(FakeSettingsRepository Repository, NasDdnsViewModel Model)> Editable()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true);
        repository.Providers.Add(new("Example", "Synthetic provider", null));
        var model = new NasDdnsViewModel(); await model.ActivateAsync(repository); model.BeginCreate();
        model.Draft.ProviderId = "Example"; model.Draft.Hostname = "nas.example.invalid";
        model.Draft.Username = "synthetic"; model.Draft.Password = " synthetic-secret ";
        return (repository, model);
    }

    [Fact]
    public async Task NoConfirmationAndChangedPasswordCannotSubmit()
    {
        var (repository, model) = await Editable(); using var owned = model;
        await model.ExecuteConfirmedAsync(); Assert.Equal(0, repository.Writes);
        Assert.True(model.ConfirmAction()); model.Draft.Password = "changed";
        await model.ExecuteConfirmedAsync(); Assert.Equal(0, repository.Writes); Assert.False(model.CanSave);
        Assert.True(model.ConfirmAction()); model.Draft.Hostname = "other.example.invalid";
        await model.ExecuteConfirmedAsync(); Assert.Equal(0, repository.Writes);
    }

    [Fact]
    public async Task TestDoesNotSaveAndClearsPasswordButPreservesOtherDraftFields()
    {
        var (repository, model) = await Editable(); using var owned = model;
        repository.NextTestResult = Success(); model.SelectAction(NasDdnsAction.Test); Assert.True(model.ConfirmAction());
        var oldDraft = model.Draft; await model.ExecuteConfirmedAsync();
        Assert.Equal(NasDdnsAction.Test, repository.LastRequest!.Action); Assert.Equal(1, repository.Writes);
        Assert.Empty(repository.Records); Assert.True(model.IsEditing); Assert.Null(oldDraft.Password);
        Assert.Equal("nas.example.invalid", model.Draft.Hostname); Assert.False(model.IsBusy);
        Assert.NotNull(model.TestResult); Assert.True(model.WasSuccessful);
        Assert.False(model.CanExecute); Assert.False(model.ConfirmAction());
    }

    [Fact]
    public async Task SuccessRefreshDoesNotLeaveSavingFlagSetAndKeepsFeedback()
    {
        var (repository, model) = await Editable(); using var owned = model; repository.NextSaveResult = Success();
        Assert.True(model.ConfirmAction()); await model.ExecuteConfirmedAsync();
        Assert.False(model.IsSaving); Assert.False(model.IsBusy); Assert.False(model.IsEditing);
        Assert.Single(model.Records); Assert.True(model.WasSuccessful); Assert.NotNull(model.FeedbackMessage);
        await model.RefreshAsync(); Assert.NotNull(model.FeedbackMessage); Assert.Equal(1, repository.Writes);
    }

    [Fact]
    public async Task ExistingRecordCanKeepPasswordAndNetworkMetadata()
    {
        var (repository, model) = await Editable(); using var owned = model;
        var record = new NasDDNSRecord("Example", "Example", "nas.example.invalid", "synthetic", null, null, true)
            { NetworkType = "BOTH", Ipv6 = null, InterfaceV4 = "eth0" };
        repository.Records.Add(record); await model.RefreshAsync(); model.BeginEdit(model.Records[0]);
        model.Draft.Heartbeat = true; Assert.True(model.ConfirmAction()); repository.NextSaveResult = Success();
        await model.ExecuteConfirmedAsync();
        Assert.Equal(record, repository.LastRequest!.Baseline); Assert.Null(repository.LastPassword);
        Assert.Equal("BOTH", repository.LastRequest.Desired!.NetworkType); Assert.Null(repository.LastRequest.Desired.Ipv6);
        Assert.Equal("eth0", repository.LastRequest.Desired.InterfaceV4);
    }

    [Fact]
    public async Task UnknownResultBlocksWritesAndRefreshOnlyReviews()
    {
        var (repository, model) = await Editable(); using var owned = model;
        repository.NextSaveResult = Unknown(); Assert.True(model.ConfirmAction()); await model.ExecuteConfirmedAsync();
        Assert.True(model.NeedsReview); Assert.False(model.CanExecute); Assert.False(model.WasSuccessful); Assert.Null(model.Draft.Password);
        repository.ReviewResult = Unknown(); await model.RefreshAsync(); Assert.True(model.NeedsReview); Assert.Equal(1, repository.Writes);
        repository.ReviewResult = Success(); await model.RefreshAsync(); Assert.False(model.NeedsReview); Assert.True(model.WasSuccessful);
        Assert.Equal(1, repository.Writes);
    }

    [Fact]
    public async Task PendingOperationIsFoundOnNewPage()
    {
        var repository = new FakeSettingsRepository(Guid.NewGuid(), true) { ReviewResult = Unknown() };
        using var model = new NasDdnsViewModel(); await model.ActivateAsync(repository);
        Assert.True(model.NeedsReview); Assert.False(model.CanEdit); Assert.NotNull(model.FeedbackMessage);
        Assert.Equal(0, repository.Writes);
    }

    [Fact]
    public async Task OverlappingActionsAndReloadDoNotCancelSubmittedOperation()
    {
        var (repository, model) = await Editable(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.WriteTask = finish.Task; Assert.True(model.ConfirmAction()); var active = model.ExecuteConfirmedAsync();
        Assert.True(model.IsBusy); Assert.Null(model.Draft.Password);
        model.SelectAction(NasDdnsAction.Test); model.CancelEdit(); await model.RefreshAsync(); await model.ExecuteConfirmedAsync();
        Assert.Equal(1, repository.Writes); Assert.False(repository.LastToken.IsCancellationRequested);
        finish.SetResult(Success()); await active; Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task SwitchingProfileCancelsAndIgnoresLateWriteResult()
    {
        var (repository, model) = await Editable(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.WriteTask = finish.Task; Assert.True(model.ConfirmAction()); var oldDraft = model.Draft;
        var active = model.ExecuteConfirmedAsync(); await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), true));
        Assert.True(repository.LastToken.IsCancellationRequested); Assert.Null(oldDraft.Password);
        finish.SetResult(Success()); await active;
        Assert.Null(model.LastResult); Assert.Empty(model.Records); Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task UpdateConfirmationBindsCompleteDirectoryAndNeverUsesDraftPassword()
    {
        var (repository, model) = await Editable(); using var owned = model;
        var record = new NasDDNSRecord("Example", "Example", "nas.example.invalid", "synthetic", null, null, true);
        repository.Records.Add(record); await model.RefreshAsync(); model.SelectAction(NasDdnsAction.UpdateAddress);
        Assert.True(model.ConfirmAction()); model.Records.Add(record with { Id = "Other", ProviderId = "Other" });
        await model.ExecuteConfirmedAsync(); Assert.Equal(0, repository.Writes);
        model.Records.RemoveAt(1); Assert.True(model.ConfirmAction()); repository.NextSaveResult = Success();
        await model.ExecuteConfirmedAsync(); Assert.Equal(NasDdnsAction.UpdateAddress, repository.LastRequest!.Action);
        Assert.Null(repository.LastPassword); Assert.Equal(new[] { "Example" }, repository.LastRequest.ExpectedProviderIds);
    }

    [Fact]
    public async Task ReadOnlyAndMissingProviderCannotConfirm()
    {
        var (repository, model) = await Editable(); using var owned = model;
        model.Draft.ProviderId = "missing"; Assert.False(model.ConfirmAction());
        await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), false)); model.BeginCreate();
        Assert.False(model.ConfirmAction()); await model.ExecuteConfirmedAsync(); Assert.Equal(0, repository.Writes);
    }

    [Fact]
    public async Task ChangingTestedDraftRemovesStaleSuccessAndRequiresFreshConfirmation()
    {
        var (repository, model) = await Editable(); using var owned = model;
        repository.NextTestResult = Success(); model.SelectAction(NasDdnsAction.Test); Assert.True(model.ConfirmAction());
        await model.ExecuteConfirmedAsync(); Assert.NotNull(model.TestResult);
        model.Draft.Hostname = "changed.example.invalid"; model.DraftChanged();
        Assert.Null(model.TestResult); Assert.Null(model.LastResult); Assert.False(model.CanExecute); Assert.Equal(1, repository.Writes);
    }

    [Fact]
    public async Task LateProviderResponseAfterSwitchDoesNotStartOldRecordRead()
    {
        var providers = new TaskCompletionSource<IReadOnlyList<NasDDNSProvider>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var old = new FakeSettingsRepository(Guid.NewGuid(), true) { ProviderTask = providers.Task };
        using var model = new NasDdnsViewModel(); var loading = model.ActivateAsync(old);
        await model.ActivateAsync(new FakeSettingsRepository(Guid.NewGuid(), true));
        providers.SetResult([new("old", "Old synthetic", null)]); await loading;
        Assert.Empty(model.Providers); Assert.Equal(0, old.RecordReads);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "ddnsMutation", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "ddnsMutation", true, true, new(0, 0, 1));

    private sealed class FakeSettingsRepository(Guid profileId, bool writeAvailable) : INasSettingsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public List<NasDDNSProvider> Providers { get; } = [];
        public List<NasDDNSRecord> Records { get; } = [];
        public MutationResult? NextSaveResult { get; set; }
        public MutationResult? NextDeleteResult { get; set; }
        public MutationResult? NextTestResult { get; set; }
        public MutationResult? ReviewResult { get; set; }
        public Task<MutationResult>? WriteTask { get; set; }
        public int Writes { get; private set; }
        public NasDdnsMutationRequest? LastRequest { get; private set; }
        public string? LastPassword { get; private set; }
        public CancellationToken LastToken { get; private set; }
        public Task<IReadOnlyList<NasDDNSProvider>>? ProviderTask { get; set; }
        public int RecordReads { get; private set; }
        public Task<MutationResult?> ReviewServiceSettingsAsync(NasServiceSettingsKind kind, CancellationToken token = default) => Task.FromResult(ReviewResult);
        public Task<MutationResult> MutateDdnsAsync(NasDdnsMutationRequest request, string? password = null, CancellationToken cancellationToken = default)
        {
            Writes++; LastRequest = request; LastPassword = password; LastToken = cancellationToken;
            if (WriteTask is not null) return WriteTask;
            var result = (request.Action == NasDdnsAction.Test ? NextTestResult : request.Action == NasDdnsAction.Delete ? NextDeleteResult : NextSaveResult) ?? Unsupported("ddnsMutation");
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                if (request.Action == NasDdnsAction.Delete) Records.RemoveAll(r => r.ProviderId == request.Baseline!.ProviderId);
                if (request.Action == NasDdnsAction.Save) { Records.RemoveAll(r => r.ProviderId == request.Desired!.ProviderId); Records.Add(request.Desired!); }
            }
            return Task.FromResult(result);
        }

        public NasSettingsWriteAvailability WriteAvailability { get; } = new(
            CanSaveDDNS: writeAvailable,
            CanSaveFileService: writeAvailable,
            CanSaveTerminal: writeAvailable,
            CanSaveProxy: writeAvailable,
            CanSaveNetwork: writeAvailable,
            CanSaveRegion: writeAvailable,
            CanSaveSecurity: writeAvailable,
            CanSaveHardware: writeAvailable,
            CanSaveFTP: writeAvailable,
            CanSaveSFTP: writeAvailable,
            CanSaveSSDP: writeAvailable,
            CanSaveBonjour: writeAvailable,
            CanSaveTimeMachine: writeAvailable,
            CanSaveUPS: writeAvailable,
            CanPowerAction: writeAvailable,
            CanPackageControl: writeAvailable,
            CanAccountDelete: writeAvailable,
            CanGroupDelete: writeAvailable,
            CanConnectionDisconnect: writeAvailable,
            CanDiskTest: writeAvailable);

        public Task<IReadOnlyList<NasDDNSProvider>> LoadDDNSProvidersAsync(
            CancellationToken cancellationToken = default) =>
            ProviderTask ?? Task.FromResult<IReadOnlyList<NasDDNSProvider>>(Providers);

        public Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(
            CancellationToken cancellationToken = default)
        { RecordReads++; return Task.FromResult<IReadOnlyList<NasDDNSRecord>>(Records); }

        public Task<MutationResult> SaveDDNSRecordAsync(
            NasDDNSDraft draft, string? existingRecordId = null,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(NextSaveResult ?? Unsupported("saveDDNS"));

        public Task<MutationResult> DeleteDDNSRecordAsync(
            string recordId, CancellationToken cancellationToken = default)
        {
            Records.RemoveAll(r => r.Id == recordId);
            return Task.FromResult(NextDeleteResult ?? Unsupported("deleteDDNS"));
        }

        public Task<MutationResult> TestDDNSRecordAsync(
            string recordId, CancellationToken cancellationToken = default) =>
            Task.FromResult(NextTestResult ?? Unsupported("testDDNS"));

        public Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasFileServiceSettings());

        public Task<MutationResult> SaveFileServiceSettingsAsync(
            NasFileServiceSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveFileService"));

        public Task<NasTerminalSettings> LoadTerminalSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasTerminalSettings(false, null, false, null));

        public Task<MutationResult> SaveTerminalSettingsAsync(
            NasTerminalSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveTerminal"));

        public Task<NasProxySettings> LoadProxySettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasProxySettings(false, null, null));

        public Task<MutationResult> SaveProxySettingsAsync(
            NasProxySettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveProxy"));

        public Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<NasEthernetInterface>>([]);

        public Task<MutationResult> SaveEthernetInterfaceAsync(
            string interfaceId, bool dhcp, string? ip, string? subnet,
            string? gateway, IReadOnlyList<string>? dns, int? mtu, int? vlan,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveNetwork"));

        public Task<NasRegionSettings> LoadRegionSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasRegionSettings(null, null, null, [], null));

        public Task<MutationResult> SaveRegionSettingsAsync(
            NasRegionSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveRegion"));

        public Task<NasSecuritySettings> LoadSecuritySettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasSecuritySettings(null, null, null, null, null, null, null));

        public Task<MutationResult> SaveSecuritySettingsAsync(
            NasSecuritySettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveSecurity"));

        public Task<NasHardwareSettings> LoadHardwareSettingsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new NasHardwareSettings(null, null, null, null, null, null, null, null));

        public Task<MutationResult> SaveHardwareSettingsAsync(
            NasHardwareSettings settings, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("saveHardware"));

        public Task<MutationResult> ExecutePowerActionAsync(
            NasPowerAction action, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("powerAction"));

        public Task<MutationResult> ControlPackageAsync(
            string packageId, NasPackageAction action,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("controlPackage"));

        public Task<MutationResult> DeleteAccountAsync(
            string accountName, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("deleteAccount"));

        public Task<MutationResult> DeleteGroupAsync(
            string groupName, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("deleteGroup"));

        public Task<MutationResult> DisconnectConnectionAsync(
            string connectionId, CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("disconnectConnection"));

        public Task<MutationResult> StartDiskTestAsync(
            string diskId, NasDiskTestType testType,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(Unsupported("startDiskTest"));

        private static MutationResult Unsupported(string op) =>
            new(1, MutationResultStatus.Unsupported, op, submitted: false,
                requiresRefresh: false, new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported);
    }
}
