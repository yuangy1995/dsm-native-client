using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDirectoryManagementViewModelTests
{
    private static NasDirectoryEntry Entry(NasDirectoryKind kind, string name = "synthetic") => new(kind, name, 100, "old",
        kind == NasDirectoryKind.User ? "synthetic@example.invalid" : null, kind == NasDirectoryKind.User ? false : null,
        kind == NasDirectoryKind.User ? new[] { "synthetic-group" } : null, true, true);
    private static async Task<(Fake Fake, NasDirectoryManagementViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Users.Add(Entry(NasDirectoryKind.User)); fake.Groups.Add(Entry(NasDirectoryKind.Group, "synthetic-group"));
        var model = new NasDirectoryManagementViewModel(); await model.ActivateAsync(repository); model.SelectEntry("synthetic"); return (fake, model);
    }

    [Theory]
    [InlineData(NasDirectoryKind.User, true)] [InlineData(NasDirectoryKind.User, false)]
    [InlineData(NasDirectoryKind.Group, true)] [InlineData(NasDirectoryKind.Group, false)]
    public async Task CreateAndEditUseConfirmedSnapshotAndClearSecrets(NasDirectoryKind kind, bool create)
    {
        var (fake, model) = await Ready(); using var owned = model; model.SetKind(kind);
        if (create) model.BeginCreate(); else { model.SelectEntry(kind == NasDirectoryKind.User ? "synthetic" : "synthetic-group"); model.BeginEdit(); }
        var name = create ? "new-entry" : model.Draft.Name;
        var password = kind == NasDirectoryKind.User ? " synthetic-secret " : null;
        model.SetDraft(new(name, "changed", kind == NasDirectoryKind.User ? "new@example.invalid" : null, kind == NasDirectoryKind.User ? false : null), password, password, false);
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); await model.ExecuteAsync(); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.Equal(kind, fake.Save!.Kind); Assert.Equal(name, fake.Save.Desired.Name);
        Assert.Equal(create, fake.Save.Baseline is null); Assert.Equal(password, fake.PasswordSent);
        Assert.Null(model.Password); Assert.Null(model.PasswordConfirmation); Assert.False(model.IsEditing); Assert.False(model.IsBusy); Assert.True(model.WasSuccessful);
        Assert.Null(fake.Save.Desired.Groups); Assert.NotNull(model.Feedback);
    }

    [Theory]
    [InlineData(NasDirectoryKind.User)] [InlineData(NasDirectoryKind.Group)]
    public async Task DeleteIsSeparateAndRefreshDoesNotReplay(NasDirectoryKind kind)
    {
        var (fake, model) = await Ready(); using var owned = model; model.SetKind(kind); model.SelectEntry(kind == NasDirectoryKind.User ? "synthetic" : "synthetic-group");
        model.ChooseDelete(); Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Equal(kind, fake.Delete!.Baseline.Kind); Assert.Null(fake.Save); Assert.Equal(1, fake.Writes);
        Assert.Empty(model.VisibleEntries); await model.ReloadAsync(); Assert.Equal(1, fake.Writes); Assert.NotNull(model.Feedback);
    }

    [Fact]
    public async Task ChangingPasswordOrGroupSelectionRequiresConfirmationAgain()
    {
        var (fake, model) = await Ready(); using var owned = model; model.BeginEdit();
        var draft = model.Draft with { Description = "changed" };
        model.SetDraft(draft, "one", "one", false); Assert.True(model.Confirm(true));
        model.SetDraft(draft, "two", "two", false); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); model.SetDraft(draft with { Groups = [] }, "two", "two", true);
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes); Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Empty(fake.Save!.Desired.Groups!); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task GroupReadFailureStillAllowsUserEditWithoutOverwritingMembership()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.FailGroups = true; await model.ReloadAsync();
        Assert.Null(model.UserError); Assert.NotNull(model.GroupError); Assert.True(model.CanEdit); model.BeginEdit(); Assert.False(model.CanModifyGroups);
        model.SetDraft(model.Draft with { Description = "changed" }, null, null, false); Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Null(fake.Save!.Desired.Groups); Assert.Equal(1, fake.Writes);
        model.SetKind(NasDirectoryKind.Group); Assert.False(model.CanCreate); Assert.NotNull(model.ErrorMessage);
    }

    [Fact]
    public async Task MissingOriginalMembershipAndCurrentUserCannotBeRegrouped()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Users[0] = fake.Users[0] with { Groups = null }; await model.ReloadAsync(); model.BeginEdit(); Assert.False(model.CanModifyGroups);
        model.SetDraft(model.Draft with { Description = "changed", Groups = [] }, null, null, true); Assert.False(model.Confirm(true));
        await model.ReloadAsync(); fake.Users[0] = fake.Users[0] with { IsCurrentAccount = true, Groups = new[] { "synthetic-group" } };
        await model.ReloadAsync(); Assert.False(model.CanDelete); model.BeginEdit(); Assert.False(model.CanModifyGroups);
        model.SetDraft(model.Draft with { IsExpired = true }, null, null, false); Assert.False(model.Confirm(true)); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task MissingFieldsAndReservedEntriesAreReadOnlyForRelevantActions()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Users[0] = fake.Users[0] with { Email = null }; await model.ReloadAsync(); Assert.False(model.CanEdit); Assert.True(model.CanDelete);
        fake.Users[0] = fake.Users[0] with { Name = "admin", Email = "" }; await model.ReloadAsync(); model.SelectEntry("admin"); Assert.False(model.CanDelete);
        fake.SaveAvailable = false; fake.DeleteAvailable = false; Assert.True(model.IsReadOnly); Assert.False(model.CanCreate);
    }

    [Fact]
    public async Task UnknownPasswordResultBlocksTargetAndReloadOnlyChecks()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Result = Unknown(); model.BeginEdit();
        model.SetDraft(model.Draft, "new-secret", "new-secret", false); Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Single(model.Pending); Assert.Null(model.Password); Assert.False(model.CanExecute); Assert.False(model.WasSuccessful);
        await model.ReloadAsync(); Assert.Single(model.Pending); Assert.Equal(1, fake.Writes); Assert.Single(fake.Reviews);
        fake.ReviewResult = Success(); await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task RecoveryIncludesNamesNoLongerInDirectory()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Recoveries.Add(new(NasDirectoryKind.Group, "removed", NasDirectoryOperationKind.Delete)); fake.ReviewResult = Success();
        using var model = new NasDirectoryManagementViewModel(); await model.ActivateAsync(repository);
        Assert.Empty(model.Groups); Assert.True(model.WasSuccessful); Assert.Equal("removed", model.LastTarget); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task ContextSwitchAndCloseClearBothPasswords()
    {
        var (fake, model) = await Ready(); using var owned = model; model.BeginCreate();
        model.SetDraft(new("new", "", "", false), "secret", "secret", false); Assert.True(model.Confirm(true));
        model.SetKind(NasDirectoryKind.Group); Assert.Null(model.Password); Assert.Null(model.PasswordConfirmation); Assert.False(model.CanExecute);
        model.SetKind(NasDirectoryKind.User); model.BeginCreate(); model.SetDraft(new("new", "", "", false), "secret", "secret", false);
        model.Dispose(); Assert.Null(model.Password); Assert.Empty(model.Users); Assert.Empty(model.Groups); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task ConcurrentOperationsAndReloadCannotCancelTheWrite()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.ChooseDelete(); model.Confirm(true); var active = model.ExecuteAsync();
        Assert.True(model.IsBusy); await model.ReloadAsync(); model.SetKind(NasDirectoryKind.Group); model.BeginCreate(); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.Equal(NasDirectoryKind.User, model.Kind); Assert.False(fake.LastToken.IsCancellationRequested);
        finish.SetResult(Success()); await active; Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task SwitchingNasIgnoresLateWriteAndReadResults()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var finish = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = finish.Task;
        model.ChooseDelete(); model.Confirm(true); var active = model.ExecuteAsync();
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.LastToken.IsCancellationRequested);
        finish.SetResult(Success()); await active; Assert.Null(model.LastResult); Assert.Empty(model.Users);
    }

    [Fact]
    public async Task LateUserReadDoesNotPopulateNewNasOrStartOldGroupRead()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var finish = new TaskCompletionSource<IReadOnlyList<NasDirectoryEntry>>(TaskCreationOptions.RunContinuationsAsynchronously); fake.UserReadTask = finish.Task;
        using var model = new NasDirectoryManagementViewModel(); var loading = model.ActivateAsync(repository);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>());
        finish.SetResult([Entry(NasDirectoryKind.User)]); await loading;
        Assert.Empty(model.Users); Assert.Equal(1, fake.Reads); Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task RecoveryFailureBlocksWritesButNotReadableData()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.FailRecovery = true; await model.ReloadAsync();
        Assert.Single(model.Users); Assert.Single(model.Groups); Assert.NotNull(model.RecoveryError);
        Assert.False(model.CanCreate); Assert.False(model.CanEdit); Assert.False(model.CanDelete); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task SearchIsLocalAndChangingDeleteTargetInvalidatesConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model; var reads = fake.Reads;
        model.ChooseDelete(); model.Confirm(true); model.SetSearch("no-match"); await model.ExecuteAsync();
        Assert.Empty(model.VisibleEntries); Assert.False(model.CanExecute); Assert.Equal(0, fake.Writes); Assert.Equal(reads, fake.Reads);
    }

    [Fact]
    public async Task CollisionNoopAndMismatchedPasswordsCannotSubmit()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.BeginEdit(); Assert.False(model.Confirm(true)); model.CancelEdit(); model.BeginCreate();
        model.SetDraft(new("synthetic", "", "", false), "one", "one", false); Assert.False(model.Confirm(true));
        model.SetDraft(new("new", "", "", false), "one", "two", false); Assert.False(model.Confirm(true));
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "directoryMutation", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "directoryMutation", true, true, new(0, 0, 1));
    public class Fake : DispatchProxy
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public bool SaveAvailable { get; set; } = true; public bool DeleteAvailable { get; set; } = true;
        public bool FailGroups { get; set; }
        public bool FailRecovery { get; set; }
        public Task<IReadOnlyList<NasDirectoryEntry>>? UserReadTask { get; set; }
        public List<NasDirectoryEntry> Users { get; } = []; public List<NasDirectoryEntry> Groups { get; } = [];
        public List<NasDirectoryRecoveryInfo> Recoveries { get; } = []; public List<string> Reviews { get; } = [];
        public int Writes { get; private set; } public int Reads { get; private set; }
        public string? PasswordSent { get; private set; }
        public NasDirectorySaveRequest? Save { get; private set; } public NasDirectoryDeleteRequest? Delete { get; private set; }
        public MutationResult Result { get; set; } = Success(); public MutationResult? ReviewResult { get; set; } = Unknown();
        public Task<MutationResult>? WriteTask { get; set; } public CancellationToken LastToken { get; private set; }
        private NasSettingsWriteAvailability Flags => new(false, false, false, false, false, false, false, false, false, false,
            false, false, false, false, false, false, DeleteAvailable, DeleteAvailable, false, false);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return ProfileId;
                case "get_WriteAvailability": return Flags;
                case "get_DirectorySaveAvailability": return new NasDirectorySaveAvailability(SaveAvailable, SaveAvailable);
                case "PrepareServiceSettingsAsync": return Task.FromResult(Flags);
                case "GetDirectoryRecoveriesAsync": return FailRecovery ? Task.FromException<IReadOnlyList<NasDirectoryRecoveryInfo>>(new IOException("合成核对失败")) : Task.FromResult<IReadOnlyList<NasDirectoryRecoveryInfo>>(Recoveries.ToArray());
                case "ReviewDirectoryEntryAsync":
                    var name = (string)args![1]!; Reviews.Add(name);
                    if (ReviewResult?.Status == MutationResultStatus.ConfirmedSuccess) Recoveries.RemoveAll(item => item.Kind == (NasDirectoryKind)args[0]! && item.Name == name);
                    return Task.FromResult(ReviewResult);
                case "LoadDirectoryAsync":
                    Reads++; var kind = (NasDirectoryKind)args![0]!;
                    if (kind == NasDirectoryKind.User && UserReadTask is not null) return UserReadTask;
                    if (kind == NasDirectoryKind.Group && FailGroups) return Task.FromException<IReadOnlyList<NasDirectoryEntry>>(new IOException("合成读取失败"));
                    return Task.FromResult<IReadOnlyList<NasDirectoryEntry>>((kind == NasDirectoryKind.User ? Users : Groups).ToArray());
                case "SaveDirectoryEntryAsync":
                    Save = (NasDirectorySaveRequest)args![0]!; PasswordSent = (string?)args[1]; LastToken = (CancellationToken)args[3]!;
                    return Mutate(Save.Kind, Save.Desired.Name, Save.Baseline is null ? NasDirectoryOperationKind.Create : NasDirectoryOperationKind.Update);
                case "DeleteDirectoryEntryAsync":
                    Delete = (NasDirectoryDeleteRequest)args![0]!; LastToken = (CancellationToken)args[1]!;
                    return Mutate(Delete.Baseline.Kind, Delete.Baseline.Name, NasDirectoryOperationKind.Delete);
                default: throw new NotSupportedException(method.Name);
            }
        }
        private Task<MutationResult> Mutate(NasDirectoryKind kind, string name, NasDirectoryOperationKind operation)
        {
            Writes++; if (WriteTask is not null) return WriteTask;
            if (Result.Counts.Unknown > 0) Recoveries.Add(new(kind, name, operation));
            if (Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                var entries = kind == NasDirectoryKind.User ? Users : Groups; var old = entries.FirstOrDefault(item => item.Name == name);
                entries.RemoveAll(item => item.Name == name);
                if (operation != NasDirectoryOperationKind.Delete)
                {
                    var value = Save!.Desired; entries.Add(new(kind, name, old?.NumericId ?? 101, value.Description, value.Email, value.IsExpired,
                        value.Groups ?? old?.Groups, true, true));
                }
            }
            return Task.FromResult(Result);
        }
    }
}
