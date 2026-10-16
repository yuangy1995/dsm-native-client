namespace LanStash.Domain;

public enum NasPerformanceMetric
{
    Cpu, CpuUser, CpuSystem, CpuOther, Memory, Swap, NetworkReceived, NetworkSent,
    DiskRead, DiskWrite, VolumeRead, VolumeWrite, DiskUtilization, NfsRead, NfsWrite,
}

// 仅保存当前连接内存中的采样；缺失指标保留未知，不能用零冒充读取成功。
public sealed record NasPerformanceSnapshot(Guid ProfileId, DateTimeOffset RecordedAt, IReadOnlyDictionary<NasPerformanceMetric, double?> Values)
{
    public double? this[NasPerformanceMetric metric] => Values.GetValueOrDefault(metric);
    public bool HasValues => Values.Values.Any(value => value is not null);
}
