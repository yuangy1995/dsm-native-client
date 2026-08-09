using LanStash.App.Features.Files.Preview;
using LanStash.Domain;

namespace LanStash.Tests.Files.Preview;

public sealed class FilePreviewClassifierTests
{
    [Theory]
    [InlineData("notes.md", FilePreviewKind.Text)]
    [InlineData("photo.JPEG", FilePreviewKind.Image)]
    [InlineData("paper.pdf", FilePreviewKind.Pdf)]
    [InlineData("sound.mp3", FilePreviewKind.Audio)]
    [InlineData("movie.mp4", FilePreviewKind.Video)]
    [InlineData("ambiguous.ts", FilePreviewKind.Unsupported)]
    [InlineData("archive.zip", FilePreviewKind.Unsupported)]
    public void ClassifierUsesOnlyFrozenExtensionWhitelist(
        string name,
        FilePreviewKind expected)
    {
        Assert.Equal(expected, FilePreviewClassifier.Classify(Item(name, size: 1)));
    }

    [Fact]
    public void DirectoryAndUnknownExtensionAreNeverPreviewed()
    {
        Assert.Equal(
            FilePreviewKind.Unsupported,
            FilePreviewClassifier.Classify(Item("photo.jpg", 0, isDirectory: true)));
        Assert.Equal(string.Empty, FilePreviewClassifier.SafeExtension(Item("payload.bin", 1)));
    }

    [Theory]
    [InlineData("track.m4a", FilePreviewKind.Audio, "audio/mp4")]
    [InlineData("clip.mov", FilePreviewKind.Video, "video/quicktime")]
    [InlineData("clip.wmv", FilePreviewKind.Video, "video/x-ms-wmv")]
    public void MediaContentTypeIsStable(
        string name,
        FilePreviewKind kind,
        string expected) =>
        Assert.Equal(expected, FilePreviewClassifier.MediaContentType(Item(name, 1), kind));

    private static FileItem Item(string name, long size, bool isDirectory = false) => new(
        $"/share/{name}",
        name,
        isDirectory,
        size,
        DateTimeOffset.UnixEpoch,
        null,
        false,
        false);
}
