namespace LanStash.Domain;

public interface IDsmRepository : IFileRangeReader, IFileArchiveReader
{
    IReadOnlyList<AppModule> AvailableModules { get; }
    Task<FilePage> ListFilesAsync(
        string path,
        CancellationToken cancellationToken = default);
    Task<FilePage> ListFilesAsync(
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken = default);
    Task<FilePage> ListFilesAsync(
        string path,
        int offset,
        int limit,
        FileListOptions options,
        CancellationToken cancellationToken = default);
    Task<byte[]> ReadFileRangeAsync(
        string remotePath,
        long offset,
        long length,
        CancellationToken cancellationToken = default);
    Task<MutationResult> UploadFileAsync(
        FileUploadRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1,
            MutationResultStatus.Unsupported,
            "uploadFile",
            submitted: false,
            requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "file.upload.unsupported"));
    Task<IReadOnlyList<FileItem>> SearchFilesAsync(
        string path,
        string query,
        CancellationToken cancellationToken = default);
    Task CreateFolderAsync(
        string parentPath,
        string name,
        CancellationToken cancellationToken = default);
    Task RenameAsync(
        string path,
        string newName,
        CancellationToken cancellationToken = default);
    Task DeleteFilesAsync(
        IReadOnlyList<string> paths,
        CancellationToken cancellationToken = default);
    Task<NasSettingsSnapshot> LoadNasSettingsAsync(
        CancellationToken cancellationToken = default);
}
