namespace LanStash.Domain;

// 未知/拒绝以异常返回，不能转换成 Missing 后驱动本地目录清理。
public enum FilePresence { Present, Missing }

public sealed record FileEntryMetadata(FileItem Item, string? Type, string? MountPointType);
