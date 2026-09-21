namespace LanStash.Domain;

// 表单与网络边界使用同一组字段/依赖规则，未知值不参与布尔判断。
public static class NasFileServiceSettingsRules
{
    public const NasFileServiceFields AllFields = (NasFileServiceFields)1023;
    public static object? Value(NasFileServiceSettings value, NasFileServiceFields field) => field switch
    {
        NasFileServiceFields.Smb => value.SmbEnabled,
        NasFileServiceFields.Nfs => value.NfsEnabled,
        NasFileServiceFields.Ftp => value.FtpEnabled,
        NasFileServiceFields.Ftps => value.FtpsEnabled,
        NasFileServiceFields.FtpPort => value.FtpPort,
        NasFileServiceFields.Sftp => value.SftpEnabled,
        NasFileServiceFields.SftpPort => value.SftpPort,
        NasFileServiceFields.Ssdp => value.SsdpEnabled,
        NasFileServiceFields.Bonjour => value.BonjourEnabled,
        NasFileServiceFields.TimeMachine => value.TimeMachineEnabled,
        _ => null,
    };

    public static bool IsValidChange(NasFileServiceSettings baseline, NasFileServiceSettings desired)
    {
        var available = baseline.AvailableFields;
        if (available == NasFileServiceFields.None || (available & ~AllFields) != 0 ||
            desired.AvailableFields != available || baseline.FailedFields != NasFileServiceFields.None ||
            desired.FailedFields != NasFileServiceFields.None) return false;
        foreach (var item in Enum.GetValues<NasFileServiceFields>())
            if (!available.HasFlag(item) && !Equals(Value(baseline, item), Value(desired, item))) return false;
        if (available.HasFlag(NasFileServiceFields.FtpPort) && desired.FtpPort is not (> 0 and <= 65535)) return false;
        if (available.HasFlag(NasFileServiceFields.SftpPort) && desired.SftpPort is not (> 0 and <= 65535)) return false;
        if (available.HasFlag(NasFileServiceFields.Smb | NasFileServiceFields.TimeMachine) &&
            !desired.SmbEnabled && desired.TimeMachineEnabled) return false;
        var ftp = available.HasFlag(NasFileServiceFields.Ftp) && desired.FtpEnabled ||
            available.HasFlag(NasFileServiceFields.Ftps) && desired.FtpsEnabled;
        if (ftp && desired.SftpEnabled && available.HasFlag(NasFileServiceFields.Sftp |
            NasFileServiceFields.FtpPort | NasFileServiceFields.SftpPort) && desired.FtpPort == desired.SftpPort) return false;
        // 未记录的高级属性必须保持原样，不能静默忽略调用方要求更改的字段。
        return baseline with
        {
            SmbEnabled = desired.SmbEnabled, NfsEnabled = desired.NfsEnabled,
            FtpEnabled = desired.FtpEnabled, FtpsEnabled = desired.FtpsEnabled, FtpPort = desired.FtpPort,
            SftpEnabled = desired.SftpEnabled, SftpPort = desired.SftpPort,
            SsdpEnabled = desired.SsdpEnabled, BonjourEnabled = desired.BonjourEnabled,
            TimeMachineEnabled = desired.TimeMachineEnabled,
        } == desired;
    }
}
