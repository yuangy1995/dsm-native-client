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
    bool CanDiskTest)
{
    public bool CanSaveRemoteAccess { get; init; }
}

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
    bool Heartbeat = false)
{
    public string? NetworkType { get; init; }
    public string? Ipv6 { get; init; }
    public string? InterfaceV4 { get; init; }
    public string? InterfaceV6 { get; init; }
    public string? LastUpdated { get; init; }
}

public sealed record NasDDNSDraft
{
    // 草稿可能含密码/密钥，不能让默认 record 字符串化泄露凭据或账号。
    public override string ToString() => nameof(NasDDNSDraft);
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
    // 兼容旧布尔属性；显示/编辑必须先检查字段位图，未返回值不能显示成关闭。
    public NasFileServiceFields AvailableFields { get; init; }
    public NasFileServiceFields FailedFields { get; init; }
    public bool FtpsEnabled { get; init; }
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
            AvailableFields = AvailableFields,
            FailedFields = FailedFields,
            FtpsEnabled = FtpsEnabled,
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
    int? VlanId)
{
    public bool? IsDefaultGateway { get; init; }
    public bool? VlanEnabled { get; init; }
    public string? Status { get; init; }
    public string? ReportedDns { get; init; }
}

public sealed record NasEthernetSnapshot(IReadOnlyList<NasEthernetInterface> Interfaces, int FailedInterfaces);

public sealed record NasHardwareSettings(
    bool? PowerFailRestart,
    int? LedBrightness,
    string? FanMode,
    bool? BeepControl,
    int? HddSleepMinutes,
    bool? UpsEnabled,
    string? UpsMode,
    string? UpsShutdownTime)
{
    public int? LedMinimum { get; init; }
    public int? LedMaximum { get; init; }
    public NasBeepSettings? Beep { get; init; }
    public NasHibernationSettings? Hibernation { get; init; }
    public NasUpsSettings? Ups { get; init; }
    public NasHardwareSections AvailableSections { get; init; }
    public NasHardwareSections FailedSections { get; init; }
}

public sealed record NasSecuritySettings(
    bool? AutoBlockEnabled,
    int? AutoBlockFailedAttempts,
    int? AutoBlockWithinMinutes,
    int? AutoBlockExpiryDays,
    bool? DosProtectionEnabled,
    bool? FirewallEnabled,
    bool? PortScanEnabled)
{
    public IReadOnlyList<NasDoSProtectionSetting> DosProtection { get; init; } = [];
    public string? FirewallProfileName { get; init; }
    public NasSecuritySections AvailableSections { get; init; }
    public NasSecuritySections FailedSections { get; init; }
}

[Flags]
public enum NasSecuritySections { None = 0, AutoBlock = 1, Dos = 2, Firewall = 4, PortScan = 8 }
public sealed record NasDoSProtectionSetting(string Id, string Name, bool Enabled);

public sealed record NasRegionSettings(
    string? DateFormat,
    string? TimeFormat,
    string? Timezone,
    IReadOnlyList<string> NtpServers,
    string? ManualDate)
{
    public NasRegionTimeMode Mode { get; init; }
    // NAS 读取时的墙上时间，不转换为本机时区，也不当作持续走时的本机时钟。
    public DateTime? NasLocalTime { get; init; }
    public IReadOnlyList<NasTimeZoneOption> TimeZones { get; init; } = [];
}

public enum NasRegionTimeMode { Unknown, Network, Manual }
public sealed record NasTimeZoneOption(string Id, string DisplayName);

public interface INasSettingsRepository
{
    Guid ProfileId { get; }

    NasSettingsWriteAvailability WriteAvailability { get; }
    bool CanSaveScheduledTasks => false;
    Task<MutationResult> SaveScheduledTaskAsync(NasTaskSaveRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveTask", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<IReadOnlyList<NasTaskSaveRecoveryInfo>> GetTaskSaveRecoveriesAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<NasTaskSaveRecoveryInfo>>([]);
    Task<MutationResult?> ReviewTaskSaveAsync(Guid requestId, CancellationToken cancellationToken = default) => Task.FromResult<MutationResult?>(null);
    NasTaskCommandAvailability TaskCommandAvailability => new(false, false, false);
    Task<MutationResult> ExecuteTaskCommandAsync(NasTaskCommandRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "taskCommand", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<IReadOnlyList<NasTaskRecoveryInfo>> GetTaskRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<NasTaskRecoveryInfo>>([]);
    Task<MutationResult?> ReviewTaskCommandAsync(int id, CancellationToken cancellationToken = default) => Task.FromResult<MutationResult?>(null);
    Task<IReadOnlyList<NasTaskEntry>> LoadScheduledTasksAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<NasTaskEntry>>(new NotSupportedException());
    Task<NasTaskDetail> LoadScheduledTaskDetailAsync(int? id, string? realOwner = null, CancellationToken cancellationToken = default) =>
        Task.FromException<NasTaskDetail>(new NotSupportedException());
    Task<IReadOnlyList<NasTaskResult>> LoadScheduledTaskResultsAsync(string taskName, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<NasTaskResult>>(new NotSupportedException());
    Task<NasTaskResultOutput> LoadScheduledTaskOutputAsync(string taskName, string resultId, CancellationToken cancellationToken = default) =>
        Task.FromException<NasTaskResultOutput>(new NotSupportedException());
    Task<NasConnectionSnapshot> LoadConnectionSnapshotAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasConnectionSnapshot>(new NotSupportedException());
    Task<MutationResult> DisconnectConnectionAsync(NasConnectionDisconnectRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "disconnectConnection", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<IReadOnlyList<NasConnectionRecoveryInfo>> GetConnectionRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<NasConnectionRecoveryInfo>>([]);
    Task<MutationResult?> ReviewConnectionAsync(string targetKey, CancellationToken cancellationToken = default) => Task.FromResult<MutationResult?>(null);
    Task<MutationResult> ExecutePowerActionAsync(NasPowerRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "powerAction", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<NasPowerRecoveryInfo?> GetPowerRecoveryAsync(CancellationToken cancellationToken = default) => Task.FromResult<NasPowerRecoveryInfo?>(null);
    Task<bool> AcknowledgePowerRecoveryAsync(bool deviceChecked, CancellationToken cancellationToken = default) => Task.FromResult(false);
    NasDirectorySaveAvailability DirectorySaveAvailability => new(false, false);
    Task<MutationResult> SaveDirectoryEntryAsync(NasDirectorySaveRequest request, string? password = null, string? passwordConfirmation = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveDirectoryEntry", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<IReadOnlyList<NasDirectoryEntry>> LoadDirectoryAsync(NasDirectoryKind kind, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<NasDirectoryEntry>>(new NotSupportedException());
    Task<MutationResult> DeleteDirectoryEntryAsync(NasDirectoryDeleteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "deleteDirectoryEntry", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<IReadOnlyList<NasDirectoryRecoveryInfo>> GetDirectoryRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<NasDirectoryRecoveryInfo>>([]);
    Task<MutationResult?> ReviewDirectoryEntryAsync(NasDirectoryKind kind, string name, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);
    NasPackageControlAvailability PackageControlAvailability => new(WriteAvailability.CanPackageControl, WriteAvailability.CanPackageControl);
    Task<IReadOnlyList<NasPackageRecoveryInfo>> GetPackageRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<NasPackageRecoveryInfo>>([]);
    Task<IReadOnlyList<NasPackageSummary>> LoadPackagesAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<NasPackageSummary>>(new NotSupportedException());
    Task<MutationResult> ControlPackageAsync(NasPackageMutationRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "controlPackage", false, false, new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<MutationResult?> ReviewPackageAsync(string packageId, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);
    Task<MutationResult> SaveHardwareSettingsAsync(NasServiceSettingsSaveRequest<NasHardwareSettings> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveHardware", false, false,
            new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<MutationResult> SaveSecuritySettingsAsync(NasServiceSettingsSaveRequest<NasSecuritySettings> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveSecurity", false, false,
            new(0, 1, 0), MutationErrorCategory.Unsupported));

    Task<NasSettingsWriteAvailability> PrepareServiceSettingsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(WriteAvailability);

    // 恢复先前未确认的保存只允许回读；没有挂起请求时返回 null。
    Task<MutationResult?> ReviewServiceSettingsAsync(NasServiceSettingsKind kind,
        CancellationToken cancellationToken = default) => Task.FromResult<MutationResult?>(null);

    Task<MutationResult> SaveTerminalSettingsAsync(NasServiceSettingsSaveRequest<NasTerminalSettings> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveTerminal", false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported));

    Task<MutationResult> SaveProxySettingsAsync(NasServiceSettingsSaveRequest<NasProxySettings> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveProxy", false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported));

    // 动态域名
    Task<MutationResult> MutateDdnsAsync(NasDdnsMutationRequest request, string? password = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "ddnsMutation", false, false,
            new(0, 1, 0), MutationErrorCategory.Unsupported));

    Task<MutationResult> SaveRegionSettingsAsync(NasRegionSettingsSaveRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveRegion", false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported));

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
    Task<MutationResult> SaveFileServiceSettingsAsync(NasServiceSettingsSaveRequest<NasFileServiceSettings> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveFileService", false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported));

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
    Task<MutationResult> SaveEthernetSettingsAsync(NasServiceSettingsSaveRequest<NasEthernetInterface> request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveNetwork", false, false,
            new(0, 1, 0), MutationErrorCategory.Unsupported));
    Task<NasEthernetRecoveryInfo?> GetEthernetRecoveryAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<NasEthernetRecoveryInfo?>(null);
    Task<MutationResult?> ReviewEthernetSettingsAsync(bool sameNasConfirmed = false, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);

    async Task<NasEthernetSnapshot> LoadEthernetSnapshotAsync(CancellationToken cancellationToken = default) =>
        new(await LoadEthernetInterfacesAsync(cancellationToken), 0);

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
    Task<NasPowerScheduleSnapshot> LoadPowerScheduleAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasPowerScheduleSnapshot>(new NotSupportedException());
    Task<NasExternalStorageDirectory> LoadExternalStorageAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasExternalStorageDirectory>(new NotSupportedException());
    Task<NasZramSnapshot> LoadZramAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasZramSnapshot>(new NotSupportedException());
    Task<NasRemoteAccessSettings> LoadRemoteAccessSettingsAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasRemoteAccessSettings>(new NotSupportedException());
    Task<MutationResult> SaveRemoteAccessSettingsAsync(NasServiceSettingsSaveRequest<NasRemoteAccessSettings> request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<MutationResult> ExecuteDiskTestAsync(NasDiskTestRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<NasDiskTestRecovery>> GetDiskTestRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<NasDiskTestRecovery>>([]);
    Task<MutationResult?> ReviewDiskTestAsync(string diskId, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());
    Task<IReadOnlyList<NasDiskTestTarget>> LoadDiskTestTargetsAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<NasDiskTestTarget>>(new NotSupportedException());
    Task<NasDiskTestState> LoadDiskTestStateAsync(NasDiskTestTarget target, CancellationToken cancellationToken = default) =>
        Task.FromException<NasDiskTestState>(new NotSupportedException());
    Task<NasDiskTestHistory> LoadDiskTestHistoryAsync(NasDiskTestTarget target, CancellationToken cancellationToken = default) =>
        Task.FromException<NasDiskTestHistory>(new NotSupportedException());
    Task<MutationResult> StartDiskTestAsync(
        string diskId,
        NasDiskTestType testType,
        CancellationToken cancellationToken = default);
}
