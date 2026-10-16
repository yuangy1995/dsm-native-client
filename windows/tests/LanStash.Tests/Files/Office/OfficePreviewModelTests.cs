using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Windows.Storage;

namespace LanStash.Tests.Files.Office;

public sealed class OfficePreviewModelTests
{
    [Theory]
    [InlineData("doc")] [InlineData("DOCX")] [InlineData("xls")] [InlineData("XLSX")] [InlineData("ppt")] [InlineData("PPTX")]
    public async Task OfficeUsesLocalArtifactAndReleasesItWhenPreviewCloses(string extension)
    {
        var repo = new Repository(); var artifacts = new Artifacts(); using var model = new FilePreviewViewModel(artifacts);
        await model.OpenAsync(repo, repo.ProfileId, Item("document." + extension, 1024));
        Assert.Equal(FilePreviewKind.Office, model.Snapshot.Kind); Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.NotNull(model.Snapshot.Artifact); Assert.Null(model.Snapshot.Media); Assert.Equal(1, artifacts.Prepares);
        await model.CloseAsync(); Assert.True(artifacts.Artifact.Disposed);
    }

    [Theory]
    [InlineData(0, FilePreviewUnavailableReason.Empty)]
    [InlineData(-1, FilePreviewUnavailableReason.UnknownSize)]
    [InlineData(134217729, FilePreviewUnavailableReason.TooLarge)]
    public async Task UnusableOfficePreviewStillKeepsTheOriginalCopyTarget(long size, FilePreviewUnavailableReason reason)
    {
        var repo = new Repository(); var artifacts = new Artifacts(); using var model = new FilePreviewViewModel(artifacts);
        var item = Item("document.docx", size); await model.OpenAsync(repo, repo.ProfileId, item);
        Assert.Equal(reason, model.Snapshot.UnavailableReason); Assert.Equal(FilePreviewPhase.DetailsOnly, model.Snapshot.Phase);
        Assert.Equal(0, artifacts.Prepares); Assert.True(model.TryGetSaveCopyTarget(item, out var target));
        Assert.Equal(repo.ProfileId, target!.ProfileId); Assert.Equal(item, target.Item);
    }

    private static FileItem Item(string name, long size) => new("/sample/" + name, name, false, size, DateTimeOffset.UnixEpoch, null, true, false);
    private sealed class Artifacts : IFilePreviewArtifactStore
    {
        public int Prepares;
        public Artifact Artifact { get; } = new();
        public Task<IFilePreviewArtifact> PrepareAsync(IFileRangeReader repository, FileItem item, IProgress<ForegroundTransferProgress>? progress, CancellationToken token)
        { Prepares++; return Task.FromResult<IFilePreviewArtifact>(Artifact); }
    }
    private sealed class Artifact : IFilePreviewArtifact
    {
        public bool Disposed;
        public StorageFile? File => null;
        public string Path => System.IO.Path.Combine(System.IO.Path.GetTempPath(), "synthetic-preview.docx");
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
    private sealed class Repository : IFilePreviewRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public FileMD5Availability MD5Availability => new(false);
        public FileTextEditAvailability GetTextEditAvailability() => new(false, false, []);
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => throw new NotSupportedException();
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length, string? version = null, long? total = null, CancellationToken token = default) => throw new NotSupportedException();
    }
}
