namespace LanStash.Domain;

public sealed record NasSettingsWriteAvailability(
    bool CanSaveDDNS,
    bool CanSaveFileService,
    bool CanSaveTerminal,
    bool CanSaveProxy,
    bool CanSaveNetwork,
    bool CanSaveRegion,
    bool CanSaveSecurity,
    bool CanSaveHardware,
    bool CanSaveFTP,
    bool CanSaveSFTP,
    bool CanSaveSSDP,
    bool CanSaveBonjour,
    bool CanSaveTimeMachine,
    bool CanSaveUPS,
    bool CanPowerAction,
    bool CanPackageControl,
    bool CanAccountDelete,
    bool CanGroupDelete,
    bool CanConnectionDisconnect,
    bool CanDiskTest);

public enum NasPowerAction
{
    Shutdown,
    Reboot,
}

public enum NasPackageAction
{
    Start,
    Stop,
    Uninstall,
}

public enum NasDiskTestType
{
    Quick,
    Extended,
}

public sealed record NasDDNSProvider(
    string Id,
    string Name,
    string? ServiceUrl);

public sealed record NasDDNSRecord(
    string Id,
    string ProviderId,
    string Hostname,
    string Username,
    string? ExternalIp,
    string? Status,
    bool IsEnabled,
    bool Heartbeat = false);

public sealed record NasDDNSDraft
{
    public string? ProviderId { get; set; }
    public string? Hostname { get; set; }
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string? ExternalIp { get; set; }
    public bool IsEnabled { get; set; } = true;
    public bool Heartbeat { get; set; }

    public bool IsValidForSubmission =>
        !string.IsNullOrWhiteSpace(ProviderId) &&
        !string.IsNullOrWhiteSpace(Hostname) &&
        !string.IsNullOrWhiteSpace(Username) &&
        !string.IsNullOrWhiteSpace(Password) &&
        Hostname.Length <= 256 &&
        Username.Length <= 128 &&
        Password.Length <= 256 &&
        (ExternalIp is null || ExternalIp.Length <= 64);
}

public sealed record NasFileServiceSettings
{
    public bool SmbEnabled { get; init; }
    public int? SmbMinProtocol { get; init; }
    public int? SmbMaxProtocol { get; init; }
    public bool? SmbTransportEncryption { get; init; }
    public bool NfsEnabled { get; init; }
    public int? NfsMinProtocol { get; init; }
    public int? NfsMaxProtocol { get; init; }
    public bool FtpEnabled { get; init; }
    public int? FtpPort { get; init; }
    public bool? FtpSslOnly { get; init; }
    public bool? FtpAnonymous { get; init; }
    public bool SftpEnabled { get; init; }
    public int? SftpPort { get; init; }
    public bool SsdpEnabled { get; init; }
    public bool BonjourEnabled { get; init; }
    public bool TimeMachineEnabled { get; init; }

    public NasFileServiceSettings CloneWith(
        bool? smbEnabled = null,
        int? smbMinProtocol = null,
        int? smbMaxProtocol = null,
        bool? smbTransportEncryption = null,
        bool? nfsEnabled = null,
        int? nfsMinProtocol = null,
        int? nfsMaxProtocol = null,
        bool? ftpEnabled = null,
        int? ftpPort = null,
        bool? ftpSslOnly = null,
        bool? ftpAnonymous = null,
        bool? sftpEnabled = null,
        int? sftpPort = null,
        bool? ssdpEnabled = null,
        bool? bonjourEnabled = null,
        bool? timeMachineEnabled = null) =>
        new()
        {
            SmbEnabled = smbEnabled ?? SmbEnabled,
            SmbMinProtocol = smbMinProtocol ?? SmbMinProtocol,
            SmbMaxProtocol = smbMaxProtocol ?? SmbMaxProtocol,
            SmbTransportEncryption = smbTransportEncryption ?? SmbTransportEncryption,
            NfsEnabled = nfsEnabled ?? NfsEnabled,
            NfsMinProtocol = nfsMinProtocol ?? NfsMinProtocol,
            NfsMaxProtocol = nfsMaxProtocol ?? NfsMaxProtocol,
            FtpEnabled = ftpEnabled ?? FtpEnabled,
            FtpPort = ftpPort ?? FtpPort,
            FtpSslOnly = ftpSslOnly ?? FtpSslOnly,
            FtpAnonymous = ftpAnonymous ?? FtpAnonymous,
            SftpEnabled = sftpEnabled ?? SftpEnabled,
            SftpPort = sftpPort ?? SftpPort,
            SsdpEnabled = ssdpEnabled ?? SsdpEnabled,
            BonjourEnabled = bonjourEnabled ?? BonjourEnabled,
            TimeMachineEnabled = timeMachineEnabled ?? TimeMachineEnabled,
        };
}

public sealed record NasTerminalSettings(
    bool SshEnabled,
    int? SshPort,
    bool TelnetEnabled,
    int? TelnetPort);

public sealed record NasProxySettings(
    bool Enabled,
    string? Host,
    int? Port);

public sealed record NasEthernetInterface(
    string Id,
    string Name,
    bool DhcpEnabled,
    string? IpAddress,
    string? SubnetMask,
    string? Gateway,
    IReadOnlyList<string> DnsServers,
    int? Mtu,
    int? VlanId);

public sealed record NasHardwareSettings(
    bool? PowerFailRestart,
    int? LedBrightness,
    string? FanMode,
    bool? BeepControl,
    int? HddSleepMinutes,
    bool? UpsEnabled,
    string? UpsMode,
    string? UpsShutdownTime);

public sealed record NasSecuritySettings(
    bool? AutoBlockEnabled,
    int? AutoBlockFailedAttempts,
    int? AutoBlockWithinMinutes,
    int? AutoBlockExpiryDays,
    bool? DosProtectionEnabled,
    bool? FirewallEnabled,
    bool? PortScanEnabled);

public sealed record NasRegionSettings(
    string? DateFormat,
    string? TimeFormat,
    string? Timezone,
    IReadOnlyList<string> NtpServers,
    string? ManualDate);

public interface INasSettingsRepository
{
    Guid ProfileId { get; }

    NasSettingsWriteAvailability WriteAvailability { get; }

    // 动态域名
    Task<IReadOnlyList<NasDDNSProvider>> LoadDDNSProvidersAsync(
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveDDNSRecordAsync(
        NasDDNSDraft draft,
        string? existingRecordId = null,
        CancellationToken cancellationToken = default);
    Task<MutationResult> DeleteDDNSRecordAsync(
        string recordId,
        CancellationToken cancellationToken = default);
    Task<MutationResult> TestDDNSRecordAsync(
        string recordId,
        CancellationToken cancellationToken = default);
    Task<MutationResult> UpdateDDNSAddressAsync(
        string recordId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "updateDDNSAddress",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "ddns.update-address.unsupported"));

    // 文件服务
    Task<NasFileServiceSettings> LoadFileServiceSettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveFileServiceSettingsAsync(
        NasFileServiceSettings settings,
        CancellationToken cancellationToken = default);

    // 终端
    Task<NasTerminalSettings> LoadTerminalSettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveTerminalSettingsAsync(
        NasTerminalSettings settings,
        CancellationToken cancellationToken = default);

    // 代理
    Task<NasProxySettings> LoadProxySettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveProxySettingsAsync(
        NasProxySettings settings,
        CancellationToken cancellationToken = default);

    // 网络
    Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveEthernetInterfaceAsync(
        string interfaceId,
        bool dhcp,
        string? ip,
        string? subnet,
        string? gateway,
        IReadOnlyList<string>? dns,
        int? mtu,
        int? vlan,
        CancellationToken cancellationToken = default);

    // 区域
    Task<NasRegionSettings> LoadRegionSettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveRegionSettingsAsync(
        NasRegionSettings settings,
        CancellationToken cancellationToken = default);

    // 安全
    Task<NasSecuritySettings> LoadSecuritySettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveSecuritySettingsAsync(
        NasSecuritySettings settings,
        CancellationToken cancellationToken = default);

    // 硬件
    Task<NasHardwareSettings> LoadHardwareSettingsAsync(
        CancellationToken cancellationToken = default);
    Task<MutationResult> SaveHardwareSettingsAsync(
        NasHardwareSettings settings,
        CancellationToken cancellationToken = default);

    // 电源操作
    Task<MutationResult> ExecutePowerActionAsync(
        NasPowerAction action,
        CancellationToken cancellationToken = default);

    // 套件控制
    Task<MutationResult> ControlPackageAsync(
        string packageId,
        NasPackageAction action,
        CancellationToken cancellationToken = default);

    // 账户与群组删除
    Task<MutationResult> DeleteAccountAsync(
        string accountName,
        CancellationToken cancellationToken = default);
    Task<MutationResult> DeleteGroupAsync(
        string groupName,
        CancellationToken cancellationToken = default);

    // 连接管理
    Task<MutationResult> DisconnectConnectionAsync(
        string connectionId,
        CancellationToken cancellationToken = default);

    // S.M.A.R.T. 磁盘检测
    Task<MutationResult> StartDiskTestAsync(
        string diskId,
        NasDiskTestType testType,
        CancellationToken cancellationToken = default);
}
