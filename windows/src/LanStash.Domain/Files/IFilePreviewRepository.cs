namespace LanStash.Domain;

/// <summary>
/// 文件预览只读能力。ProfileId 是 Repository 与预览状态的隔离边界。
/// </summary>
public interface IFilePreviewRepository : IFileRangeReader
{
    Guid ProfileId { get; }
}
