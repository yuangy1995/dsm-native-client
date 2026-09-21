using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasDirectoryMutationTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDirectorySaveTests
{
    private static NasDirectorySaveRequest Create(Fixture f, NasDirectoryKind kind) => new(f.Profile.Id, kind, null,
        new(kind == NasDirectoryKind.User ? "<synthetic-account>" : "<synthetic-group>", "<synthetic-description>",
            kind == NasDirectoryKind.User ? "<synthetic-email>" : null, kind == NasDirectoryKind.User ? false : null), Guid.NewGuid(), true);
    private static async Task<NasDirectorySaveRequest> Edit(Fixture f, NasDirectoryKind kind)
    {
        var baseline = Assert.Single(await f.Repository.LoadDirectoryAsync(kind)); f.Calls.Clear();
        return new(f.Profile.Id, kind, baseline, new(baseline.Name, "Changed", baseline.Email, baseline.IsExpired), Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM", NasDirectoryKind.User)] [InlineData("JSON", NasDirectoryKind.User)]
    [InlineData("FORM", NasDirectoryKind.Group)] [InlineData("JSON", NasDirectoryKind.Group)]
    public async Task CreationUsesOnlyRecordedFieldsAndRequiresReadback(string format, NasDirectoryKind kind)
    {
        using var f = new Fixture(format); (kind == NasDirectoryKind.User ? f.Users : f.Groups).Clear(); var request = Create(f, kind);
        var password = kind == NasDirectoryKind.User ? " synthetic-secret " : null;
        var result = await f.Repository.ExecuteDirectorySaveAsync(request, password, password);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(new[] { "get_user_service", "list", "create", "list" }, f.Calls.Select(call => call["method"]));
        var save = Assert.Single(f.Saves); Assert.Equal("1", save["version"]); Assert.DoesNotContain("groups", save.Keys);
        if (kind == NasDirectoryKind.User)
        {
            var root = new DirectoryInfo(Directory.GetCurrentDirectory());
            while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
            var contract = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/users/create/synthetic-account/request.json")))!;
            foreach (var parameter in contract["parameters"]!.AsArray())
            {
                var expected = parameter!["redacted"]?.ToString() == "true" ? password! : parameter["encodedValue"]!.ToString();
                if (format == "JSON" && parameter["valueType"]!.ToString() == "string") expected = JsonSerializer.Serialize(expected);
                Assert.Equal(expected, save[parameter["name"]!.ToString()]);
            }
        }
        else Assert.DoesNotContain(save.Keys, key => key is "email" or "expired" or "password" or "password_confirm");
        Assert.Equal(nameof(NasDirectorySaveRequest), request.ToString()); Assert.DoesNotContain("synthetic-secret", JsonSerializer.Serialize(request));
        var count = f.Calls.Count; await f.Recreate().ExecuteDirectorySaveAsync(request, password, password); Assert.Equal(count, f.Calls.Count);
    }

    [Theory]
    [InlineData("FORM", NasDirectoryKind.User)] [InlineData("JSON", NasDirectoryKind.User)]
    [InlineData("FORM", NasDirectoryKind.Group)] [InlineData("JSON", NasDirectoryKind.Group)]
    public async Task EditPreservesAbsentPasswordAndMembership(string format, NasDirectoryKind kind)
    {
        using var f = new Fixture(format); var request = await Edit(f, kind);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDirectorySaveAsync(request)).Status);
        var write = Assert.Single(f.Saves); Assert.Equal("set", write["method"]);
        Assert.DoesNotContain(write.Keys, key => key is "password" or "password_confirm" or "groups");
        Assert.DoesNotContain(f.Calls, call => call["api"] != (kind == NasDirectoryKind.User ? Fixture.UserApi : Fixture.GroupApi) && call["method"] == "list");
    }

    [Theory]
    [InlineData("false")] [InlineData("null")] [InlineData("\"true\"")]
    public async Task AdministratorMustBeExplicitBooleanTrue(string admin)
    {
        using var f = new Fixture { Administrator = JsonNode.Parse(admin) }; var request = await Edit(f, NasDirectoryKind.User);
        var result = await f.Repository.ExecuteDirectorySaveAsync(request);
        Assert.Equal(admin == "false" ? MutationResultStatus.PermissionDenied : MutationResultStatus.Unsupported, result.Status); Assert.False(result.Submitted);
        Assert.Single(f.Calls); Assert.Empty(f.Saves); Assert.False(f.Repository.DirectorySaveAvailability.CanSaveUsers);
    }

    [Fact]
    public async Task InvalidCredentialsUnknownFieldsAndRenamingMakeZeroRequests()
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.User);
        var invalid = new[] { edit with { RiskConfirmed = false }, edit with { RequestId = Guid.Empty },
            edit with { Desired = edit.Desired with { Name = "renamed" } }, edit with { Baseline = edit.Baseline! with { Email = null } },
            edit with { Baseline = edit.Baseline! with { IsExpired = null } }, edit with { Baseline = edit.Baseline! with { Description = null } },
            edit with { Baseline = edit.Baseline! with { Groups = null }, Desired = edit.Desired with { Groups = [] } },
            edit with { Desired = edit.Desired with { Groups = new[] { "same", "same" } } },
            Create(f, NasDirectoryKind.User) with { Desired = new("admin", "", "", false) } };
        foreach (var request in invalid) Assert.False((await f.Repository.ExecuteDirectorySaveAsync(request, "secret", "secret")).Submitted);
        Assert.False((await f.Repository.ExecuteDirectorySaveAsync(edit, "secret", "wrong")).Submitted);
        Assert.False((await f.Repository.ExecuteDirectorySaveAsync(Create(f, NasDirectoryKind.User))).Submitted);
        Assert.False((await f.Repository.ExecuteDirectorySaveAsync(Create(f, NasDirectoryKind.Group), "secret", "secret")).Submitted);
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task CurrentAccountCannotBeDisabledOrRegrouped()
    {
        using var f = new Fixture(); f.User["name"] = f.Profile.Username; var request = await Edit(f, NasDirectoryKind.User);
        foreach (var desired in new[] { request.Desired with { IsExpired = true }, request.Desired with { Groups = [] } })
            Assert.Equal(MutationResultStatus.PermissionDenied, (await f.Repository.ExecuteDirectorySaveAsync(request with { Desired = desired })).Status);
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task CreationCollisionAndStaleIdDoNotWrite()
    {
        using var f = new Fixture();
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteDirectorySaveAsync(Create(f, NasDirectoryKind.User), "secret", "secret")).ErrorCategory);
        var edit = await Edit(f, NasDirectoryKind.User); f.User["additional"]!["uid"] = 101;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteDirectorySaveAsync(edit)).ErrorCategory); Assert.Empty(f.Saves);
    }

    [Fact]
    public async Task GroupMembershipIsCheckedAndOnlyExplicitSelectionIsSent()
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.User);
        var invalid = edit with { Desired = edit.Desired with { Groups = new[] { "missing" } } };
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteDirectorySaveAsync(invalid)).ErrorCategory); Assert.Empty(f.Saves);
        var selected = edit with { Desired = edit.Desired with { Groups = new[] { "<synthetic-group>" } } };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDirectorySaveAsync(selected)).Status);
        Assert.Equal(new[] { "<synthetic-group>" }, JsonSerializer.Deserialize<string[]>(Assert.Single(f.Saves)["groups"]));
    }

    [Fact]
    public async Task LostPasswordAcknowledgementCannotBeConfirmedByVisibleFields()
    {
        using var f = new Fixture { LoseWrite = true }; var edit = await Edit(f, NasDirectoryKind.User);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDirectorySaveAsync(edit, "new-secret", "new-secret")).Status);
        var info = Assert.Single(await f.Recreate().GetDirectoryRecoveriesAsync()); Assert.Equal(NasDirectoryOperationKind.Update, info.Operation);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ReviewDirectoryEntryAsync(info.Kind, info.Name))!.Status);
        Assert.Single(f.Saves);
        var current = Assert.Single(await f.Repository.LoadDirectoryAsync(NasDirectoryKind.User));
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteDirectoryDeletionAsync(new(f.Profile.Id, current, Guid.NewGuid(), true))).ErrorCategory);
        Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task LostMetadataAcknowledgementCanRecoverWithoutReplaying()
    {
        using var f = new Fixture { LoseWrite = true }; var edit = await Edit(f, NasDirectoryKind.Group);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteDirectorySaveAsync(edit)).Status);
        var count = f.Calls.Count; await f.Recreate().ExecuteDirectorySaveAsync(edit); Assert.Equal(count, f.Calls.Count); Assert.Single(f.Saves);
    }

    [Theory]
    [InlineData("description")] [InlineData("email")] [InlineData("expired")] [InlineData("uid")]
    public async Task NameExistenceDoesNotProveSavedFieldsOrIdentity(string field)
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.User);
        f.AfterWrite = () => f.User["additional"]![field] = field == "expired" ? JsonValue.Create(true) : field == "uid" ? JsonValue.Create(999) : JsonValue.Create("different");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteDirectorySaveAsync(edit)).Status); Assert.Single(f.Saves);
    }

    [Fact]
    public async Task CancellationAndExplicitPermissionRejectionNeverClaimSaved()
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.Group);
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteDirectorySaveAsync(edit, token: cancel.Token)).Status); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterWrite = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecuteDirectorySaveAsync(edit, token: after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDirectoryEntryAsync(edit.Kind, edit.Desired.Name))!.Status);
        using var rejected = new Fixture { WriteError = 105 }; var attempt = await Edit(rejected, NasDirectoryKind.User);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await rejected.Repository.ExecuteDirectorySaveAsync(attempt)).Status);
        Assert.Equal(1, rejected.Calls.Count(call => call["method"] == "list"));
    }

    [Fact]
    public async Task SavingAndDeletingSameTargetCannotOverlap()
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.User);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await finish.Task; };
        var saving = f.Repository.ExecuteDirectorySaveAsync(edit); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDirectoryDeletionAsync(new(f.Profile.Id, edit.Baseline!, Guid.NewGuid(), true))).ErrorCategory);
        finish.SetResult(); await saving; Assert.Single(f.Saves); Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task PublicDirectorySaveRequiresConfirmationAndVerifiedAdministrator()
    {
        using var f = new Fixture(); var edit = await Edit(f, NasDirectoryKind.User);
        await f.Repository.PrepareServiceSettingsAsync(); f.Calls.Clear();
        Assert.True(f.Repository.DirectorySaveAvailability.CanSaveUsers); Assert.True(f.Repository.DirectorySaveAvailability.CanSaveGroups);
        Assert.False((await f.Repository.SaveDirectoryEntryAsync(edit with { RiskConfirmed = false })).Submitted); Assert.Empty(f.Calls);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.SaveDirectoryEntryAsync(edit)).Status); Assert.Single(f.Saves);
    }
}
