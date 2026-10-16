using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasFileServiceSettingsReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasFileServiceOrderingTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SmbAndTimeMachineRemainValidBetweenRequests(bool enable)
    {
        using var f = new Fixture();
        f.Data["SYNO.Core.FileServ.SMB"]["enable_samba"] = !enable;
        f.Data["SYNO.Core.FileServ.ServiceDiscovery"]["enable_smb_time_machine"] = !enable;
        var before = await f.Repository.LoadFileServiceSettingsAsync();
        var after = before with { SmbEnabled = enable, TimeMachineEnabled = enable };
        f.AfterWrite = () => Assert.False(f.Data["SYNO.Core.FileServ.ServiceDiscovery"]["enable_smb_time_machine"]!.GetValue<bool>() &&
            !f.Data["SYNO.Core.FileServ.SMB"]["enable_samba"]!.GetValue<bool>());
        var result = await f.Repository.ExecuteFileServiceSettingsWriteAsync(new(f.Profile.Id, before, after, Guid.NewGuid(), true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(enable ? new[] { "SYNO.Core.FileServ.SMB", "SYNO.Core.FileServ.ServiceDiscovery" } :
            new[] { "SYNO.Core.FileServ.ServiceDiscovery", "SYNO.Core.FileServ.SMB" }, f.Writes.Select(call => call["api"]).ToArray());
    }
    [Fact]
    public async Task PortMoveReleasesOccupiedPortFirst()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadFileServiceSettingsAsync();
        var after = before with { FtpPort = 2222, SftpPort = 2223 };
        f.AfterWrite = () => Assert.NotEqual(f.Data["SYNO.Core.FileServ.FTP"]["portnum"]!.GetValue<int>(), f.Data["SYNO.Core.FileServ.FTP.SFTP"]["portnum"]!.GetValue<int>());
        var result = await f.Repository.ExecuteFileServiceSettingsWriteAsync(new(f.Profile.Id, before, after, Guid.NewGuid(), true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(new[] { "SYNO.Core.FileServ.FTP.SFTP", "SYNO.Core.FileServ.FTP" }, f.Writes.Select(call => call["api"]).ToArray());
    }
    [Fact]
    public async Task DirectActivePortSwapIsRejectedBeforeAnyRequest()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadFileServiceSettingsAsync(); f.Calls.Clear();
        var after = before with { FtpPort = before.SftpPort, SftpPort = before.FtpPort };
        Assert.False(NasFileServiceSettingsRules.IsValidChange(before, after));
        var result = await f.Repository.ExecuteFileServiceSettingsWriteAsync(new(f.Profile.Id, before, after, Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task DisablingServiceAllowsExplicitPortExchange()
    {
        using var f = new Fixture(); var before = await f.Repository.LoadFileServiceSettingsAsync();
        var after = before with { FtpPort = before.SftpPort, SftpPort = before.FtpPort, SftpEnabled = false };
        var result = await f.Repository.ExecuteFileServiceSettingsWriteAsync(new(f.Profile.Id, before, after, Guid.NewGuid(), true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal("SYNO.Core.FileServ.FTP.SFTP", f.Writes.First()["api"]);
    }
}
