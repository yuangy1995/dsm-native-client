using LanStash.App.Features.Files.Preview;

namespace LanStash.Tests.Files.Office;

public sealed class OfficePreviewArtifactTests
{
    [Fact]
    public async Task UnpackagedClientCanPrepareAndDeleteItsLocalOfficePreview()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository();
        var item = (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item;
        var artifact = await new FilePreviewArtifactStore().PrepareAsync(repo, item, null, default);
        var path = artifact.Path;
        try
        {
            Assert.Equal(".docx", Path.GetExtension(path));
            Assert.Equal(server.Bytes, await File.ReadAllBytesAsync(path));
            Assert.NotNull(artifact.File);
        }
        finally { await artifact.DisposeAsync(); }
        Assert.False(File.Exists(path)); Assert.False(Directory.Exists(Path.GetDirectoryName(path)));
    }
}
