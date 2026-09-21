namespace LanStash.Domain;

public enum NasServiceSettingsKind { Terminal, Proxy, FileServices, Region, Ethernet, Security, Hardware, Ddns, Packages, Directory, Power, Connections, Tasks, DiskTests, RemoteAccess, ContainerNetworks, ContainerLifecycle, ContainerImages, ContainerImagePull }

// 风险确认只针对这一份不可变原值/目标值；请求标识用于未知结果恢复，不写入磁盘。
public sealed record NasServiceSettingsSaveRequest<T>(
    Guid ProfileId, T Baseline, T Desired, Guid RequestId, bool RiskConfirmed) where T : class;
