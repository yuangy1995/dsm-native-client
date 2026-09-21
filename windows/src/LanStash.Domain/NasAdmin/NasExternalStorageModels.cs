namespace LanStash.Domain;

public enum NasExternalStorageConnection { Usb, Esata }
public enum NasExternalStorageStatus { Unknown, Ready, Busy, Unavailable }
[Flags]
public enum NasExternalStorageSources { None = 0, Usb = 1, Esata = 2 }
// 只读目录不含设备节点、挂载路径或序列号；Id 不得用于弹出。
public sealed record NasExternalStorageDevice(string Id, string? DisplayName, NasExternalStorageConnection Connection,
    NasExternalStorageStatus Status, long? CapacityBytes, long? UsedBytes);
public sealed record NasExternalStorageDirectory(IReadOnlyList<NasExternalStorageDevice> Devices, int Total, bool IsTruncated,
    int IgnoredEntries, NasExternalStorageSources AvailableSources, NasExternalStorageSources UnavailableSources);
