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
        } == desired && SaveOrder(baseline, desired) is not null;
    }

    // 逐组写入不是事务：每个中间配置也须满足 SMB/备份和在用端口依赖。
    public static IReadOnlyList<NasFileServiceFields>? SaveOrder(NasFileServiceSettings baseline, NasFileServiceSettings desired)
    {
        NasFileServiceFields[] groups = [NasFileServiceFields.Smb, NasFileServiceFields.Nfs,
            NasFileServiceFields.Ftp | NasFileServiceFields.Ftps | NasFileServiceFields.FtpPort,
            NasFileServiceFields.Sftp | NasFileServiceFields.SftpPort,
            NasFileServiceFields.Ssdp | NasFileServiceFields.Bonjour, NasFileServiceFields.TimeMachine];
        var remaining = groups.Where(group => ApplyGroup(baseline, desired, group) != baseline).ToList();
        var order = new List<NasFileServiceFields>(); var current = baseline;
        while (remaining.Count > 0)
        {
            var index = remaining.FindIndex(group => SafeDependencies(ApplyGroup(current, desired, group)));
            if (index < 0) return null;
            var next = remaining[index]; remaining.RemoveAt(index); order.Add(next); current = ApplyGroup(current, desired, next);
        }
        return order;
    }
    private static bool SafeDependencies(NasFileServiceSettings value)
    {
        var known = value.AvailableFields;
        if (known.HasFlag(NasFileServiceFields.Smb | NasFileServiceFields.TimeMachine) && !value.SmbEnabled && value.TimeMachineEnabled) return false;
        var ftp = known.HasFlag(NasFileServiceFields.Ftp) && value.FtpEnabled || known.HasFlag(NasFileServiceFields.Ftps) && value.FtpsEnabled;
        return !(ftp && value.SftpEnabled && known.HasFlag(NasFileServiceFields.Sftp | NasFileServiceFields.FtpPort | NasFileServiceFields.SftpPort) && value.FtpPort == value.SftpPort);
    }
    private static NasFileServiceSettings ApplyGroup(NasFileServiceSettings current, NasFileServiceSettings desired, NasFileServiceFields group) => group switch
    {
        NasFileServiceFields.Smb => current with { SmbEnabled = desired.SmbEnabled },
        NasFileServiceFields.Nfs => current with { NfsEnabled = desired.NfsEnabled },
        NasFileServiceFields.Ftp | NasFileServiceFields.Ftps | NasFileServiceFields.FtpPort => current with { FtpEnabled = desired.FtpEnabled, FtpsEnabled = desired.FtpsEnabled, FtpPort = desired.FtpPort },
        NasFileServiceFields.Sftp | NasFileServiceFields.SftpPort => current with { SftpEnabled = desired.SftpEnabled, SftpPort = desired.SftpPort },
        NasFileServiceFields.Ssdp | NasFileServiceFields.Bonjour => current with { SsdpEnabled = desired.SsdpEnabled, BonjourEnabled = desired.BonjourEnabled },
        _ => current with { TimeMachineEnabled = desired.TimeMachineEnabled },
    };
}
