using LanStash.App.Features.Files.Preview;
using LanStash.Domain;

namespace LanStash.Tests.Files.Preview;

public sealed class FilePreviewClassifierTests
{
    [Theory]
    [InlineData("notes.md", FilePreviewKind.Text)]
    [InlineData("photo.JPEG", FilePreviewKind.Image)]
    [InlineData("photo.HEIC", FilePreviewKind.Image)]
    [InlineData("photo.heif", FilePreviewKind.Image)]
    [InlineData("photo.WeBp", FilePreviewKind.Image)]
    [InlineData("paper.pdf", FilePreviewKind.Pdf)]
    [InlineData("sound.mp3", FilePreviewKind.Audio)]
    [InlineData("movie.mp4", FilePreviewKind.Video)]
    [InlineData("movie.MKV", FilePreviewKind.Video)]
    [InlineData("movie.WeBm", FilePreviewKind.Video)]
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
    [InlineData("photo.HEIC", "heic")]
    [InlineData("photo.HeIf", "heif")]
    [InlineData("photo.WEBP", "webp")]
    [InlineData("movie.MKV", "mkv")]
    [InlineData("movie.WebM", "webm")]
    public void SafeExtensionNormalizesNewPreviewExtensions(string name, string expected) =>
        Assert.Equal(expected, FilePreviewClassifier.SafeExtension(Item(name, 1)));

    [Theory]
    [InlineData("track.m4a", FilePreviewKind.Audio, "audio/mp4")]
    [InlineData("clip.mov", FilePreviewKind.Video, "video/quicktime")]
    [InlineData("clip.wmv", FilePreviewKind.Video, "video/x-ms-wmv")]
    [InlineData("clip.MKV", FilePreviewKind.Video, "video/x-matroska")]
    [InlineData("clip.WebM", FilePreviewKind.Video, "video/webm")]
    public void MediaContentTypeIsStable(
        string name,
        FilePreviewKind kind,
        string expected) =>
        Assert.Equal(expected, FilePreviewClassifier.MediaContentType(Item(name, 1), kind));

    [Theory]
    [InlineData("photo.heic")]
    [InlineData("photo.HEIF")]
    [InlineData("photo.WebP")]
    public void ImageExtensionsDoNotProduceMediaContentTypes(string name)
    {
        var item = Item(name, 1);

        Assert.Throws<InvalidOperationException>(() =>
            FilePreviewClassifier.MediaContentType(item, FilePreviewKind.Image));
    }

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
