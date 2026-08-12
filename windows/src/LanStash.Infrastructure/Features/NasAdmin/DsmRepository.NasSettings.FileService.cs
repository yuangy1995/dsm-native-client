using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.FileServ"))
        {
            return new NasFileServiceSettings();
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.FileServ",
                ["get", "load"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            var smb = data.Object("smb") ?? data.Object("SMB");
            var nfs = data.Object("nfs") ?? data.Object("NFS");
            var ftp = data.Object("ftp") ?? data.Object("FTP");
            var sftp = data.Object("sftp") ?? data.Object("SFTP");
            var ssdp = data.Bool("ssdp_enabled") ?? data.Bool("wsd_enabled");
            var bonjour = data.Bool("bonjour_enabled") ?? data.Bool("mdns_enabled");
            var timeMachine = data.Bool("timemachine_enabled") ?? data.Bool("afp_enabled");

            return new NasFileServiceSettings
            {
                SmbEnabled = smb?.Bool("enable") ?? smb?.Bool("enabled") ?? false,
                SmbMinProtocol = smb?.Int("min_protocol") ?? smb?.Int("min_smb"),
                SmbMaxProtocol = smb?.Int("max_protocol") ?? smb?.Int("max_smb"),
                SmbTransportEncryption = smb?.Bool("transport_encryption") ?? smb?.Bool("encrypt_transport"),
                NfsEnabled = nfs?.Bool("enable") ?? nfs?.Bool("enabled") ?? false,
                NfsMinProtocol = nfs?.Int("min_protocol") ?? nfs?.Int("min_nfs"),
                NfsMaxProtocol = nfs?.Int("max_protocol") ?? nfs?.Int("max_nfs"),
                FtpEnabled = ftp?.Bool("enable") ?? ftp?.Bool("enabled") ?? false,
                FtpPort = ftp?.Int("port") ?? ftp?.Int("ftp_port"),
                FtpSslOnly = ftp?.Bool("ssl_only") ?? ftp?.Bool("sslonly"),
                FtpAnonymous = ftp?.Bool("allow_anonymous") ?? ftp?.Bool("anonymous"),
                SftpEnabled = sftp?.Bool("enable") ?? sftp?.Bool("enabled") ?? false,
                SftpPort = sftp?.Int("port") ?? sftp?.Int("sftp_port"),
                SsdpEnabled = ssdp ?? false,
                BonjourEnabled = bonjour ?? false,
                TimeMachineEnabled = timeMachine ?? false,
            };
        }
        catch (DsmException)
        {
            return new NasFileServiceSettings();
        }
    }

    public Task<MutationResult> SaveFileServiceSettingsAsync(
        NasFileServiceSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["smb_enable"] = settings.SmbEnabled ? "true" : "false",
            ["nfs_enable"] = settings.NfsEnabled ? "true" : "false",
            ["ftp_enable"] = settings.FtpEnabled ? "true" : "false",
            ["sftp_enable"] = settings.SftpEnabled ? "true" : "false",
            ["ssdp_enable"] = settings.SsdpEnabled ? "true" : "false",
            ["bonjour_enable"] = settings.BonjourEnabled ? "true" : "false",
            ["timemachine_enable"] = settings.TimeMachineEnabled ? "true" : "false",
        };

        if (settings.FtpPort is int ftpPort && ftpPort is > 0 and <= 65535)
        {
            parameters["ftp_port"] = ftpPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        if (settings.SftpPort is int sftpPort && sftpPort is > 0 and <= 65535)
        {
            parameters["sftp_port"] = sftpPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return SaveSettingsAsync(
            "SYNO.Core.FileServ", "set", parameters, "saveFileService",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
