namespace LanStash.Domain;

/// <summary>
/// 文件预览只读能力。ProfileId 是 Repository 与预览状态的隔离边界。
/// </summary>
public interface IFilePreviewRepository : IFileRangeReader
{
    Guid ProfileId { get; }

    FileTextEditAvailability GetTextEditAvailability();

    Task<FileTextContentSnapshot> DownloadTextContentSnapshotAsync(
        string path,
        long expectedFileSize,
        long maxBytes,
        CancellationToken cancellationToken = default) =>
        Task.FromException<FileTextContentSnapshot>(
            new NotSupportedException("Safe text editing is not implemented by this repository."));

    Task<MutationResult> SaveTextContentAsync(
        string path,
        string content,
        FileTextContentSnapshot original,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1,
            MutationResultStatus.Unsupported,
            "saveTextContent",
            submitted: false,
            requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "file.textedit.safe-save-unsupported"));

    Task<string> FormatTextContentAsync(
        string text,
        TextFormatKind kind,
        CancellationToken cancellationToken = default);
}
