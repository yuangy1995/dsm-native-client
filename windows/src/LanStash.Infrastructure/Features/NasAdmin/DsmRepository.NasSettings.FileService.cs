using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // DSM 内部六组只读契约；不调用未记录的聚合 FileServ/get 或猜测 load。
    public async Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        var result = new NasFileServiceSettings();
        var discovered = false;
        foreach (var group in FileServiceReadGroups)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!_capabilities.ContainsKey(group.Api)) continue;
            discovered = true;
            try
            {
                var data = await ReadNasServiceSettingsAsync(group.Api, group.MaximumVersion,
                    cancellationToken, group.MinimumVersion).ConfigureAwait(false);
                foreach (var field in group.Fields)
                {
                    if (field.Port)
                    {
                        var port = data.Int(field.Key);
                        // sftp_portnum 是已记录的读取别名，写入仍只使用 portnum。
                        if (port is null && field.Field == NasFileServiceFields.SftpPort) port = data.Int("sftp_portnum");
                        if (port is > 0 and <= 65535)
                        {
                            result = field.Field == NasFileServiceFields.FtpPort
                                ? result with { FtpPort = port } : result with { SftpPort = port };
                            result = result with { AvailableFields = result.AvailableFields | field.Field };
                        }
                        else if (data.ContainsKey(field.Key) ||
                            field.Field == NasFileServiceFields.SftpPort && data.ContainsKey("sftp_portnum"))
                            result = result with { FailedFields = result.FailedFields | field.Field };
                        continue;
                    }
                    if (data.Bool(field.Key) is not bool enabled)
                    {
                        result = result with { FailedFields = result.FailedFields | field.Field };
                        continue;
                    }
                    result = field.Field switch
                    {
                        NasFileServiceFields.Smb => result with { SmbEnabled = enabled },
                        NasFileServiceFields.Nfs => result with { NfsEnabled = enabled },
                        NasFileServiceFields.Ftp => result with { FtpEnabled = enabled },
                        NasFileServiceFields.Ftps => result with { FtpsEnabled = enabled },
                        NasFileServiceFields.Sftp => result with { SftpEnabled = enabled },
                        NasFileServiceFields.Ssdp => result with { SsdpEnabled = enabled },
                        NasFileServiceFields.Bonjour => result with { BonjourEnabled = enabled },
                        NasFileServiceFields.TimeMachine => result with { TimeMachineEnabled = enabled },
                        _ => result,
                    };
                    result = result with { AvailableFields = result.AvailableFields | field.Field };
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception)
            {
                // 单个组失败只影响自身，不能把其默认布尔值当作已读取。
                result = result with { FailedFields = result.FailedFields | group.AllFields };
            }
        }
        if (!discovered)
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("WinShared371d84f48836296f"), 102);
        return result;
    }

    public Task<MutationResult> SaveFileServiceSettingsAsync(NasFileServiceSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // 无基线的旧签名不能绕过新的确认/原值核对/整体回读流程。
        return Task.FromResult(UnsupportedResult("saveFileService"));
    }

    private sealed record FileServiceReadField(NasFileServiceFields Field, string Key, bool Port = false);
    private sealed record FileServiceReadGroup(string Api, int MinimumVersion, int MaximumVersion, FileServiceReadField[] Fields)
    {
        public NasFileServiceFields AllFields => Fields.Aggregate(NasFileServiceFields.None, (all, item) => all | item.Field);
    }
    private static readonly FileServiceReadGroup[] FileServiceReadGroups =
    [
        new("SYNO.Core.FileServ.SMB", 1, 3, [new(NasFileServiceFields.Smb, "enable_samba")]),
        new("SYNO.Core.FileServ.NFS", 1, 3, [new(NasFileServiceFields.Nfs, "enable_nfs")]),
        new("SYNO.Core.FileServ.FTP", 1, 1, [new(NasFileServiceFields.Ftp, "enable_ftp"), new(NasFileServiceFields.Ftps, "enable_ftps"), new(NasFileServiceFields.FtpPort, "portnum", true)]),
        new("SYNO.Core.FileServ.FTP.SFTP", 1, 1, [new(NasFileServiceFields.Sftp, "enable"), new(NasFileServiceFields.SftpPort, "portnum", true)]),
        new("SYNO.Core.Web.DSM", 2, 2, [new(NasFileServiceFields.Ssdp, "enable_ssdp"), new(NasFileServiceFields.Bonjour, "enable_avahi")]),
        new("SYNO.Core.FileServ.ServiceDiscovery", 1, 1, [new(NasFileServiceFields.TimeMachine, "enable_smb_time_machine")]),
    ];
}
