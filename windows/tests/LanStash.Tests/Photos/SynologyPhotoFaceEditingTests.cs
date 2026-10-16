using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace LanStash.Tests;

public sealed class SynologyPhotosFaceEditingTests
{
    [Theory]
    [InlineData(1, 255, 0, 0)][InlineData(2, 0, 255, 0)][InlineData(3, 255, 255, 0)][InlineData(4, 0, 0, 255)]
    [InlineData(5, 255, 0, 0)][InlineData(6, 0, 0, 255)][InlineData(7, 255, 255, 0)][InlineData(8, 0, 255, 0)]
    public async Task DecodeAndCropRespectEveryExifOrientation(int orientation, int red, int green, int blue)
    {
        var encoded = await SyntheticImage((ushort)orientation); var image = await SynologyPhotoFaceImage.DecodeAsync(encoded);
        Assert.Equal(orientation >= 5 ? 400 : 600, image.Width); Assert.Equal(orientation >= 5 ? 600 : 400, image.Height);
        var crop = await image.CropAsync(new(0, 0, 0.25, 0.25)); Assert.Equal(new byte[] { 255, 216, 255 }, crop.Take(3));
        var output = await SynologyPhotoFaceImage.DecodeAsync(crop); Assert.Equal(image.Width / 4, output.Width); Assert.Equal(image.Height / 4, output.Height);
        var index = (output.Height / 2 * output.Width + output.Width / 2) * 4;
        Assert.InRange(Math.Abs(output.Pixels[index] - blue), 0, 15); Assert.InRange(Math.Abs(output.Pixels[index + 1] - green), 0, 15); Assert.InRange(Math.Abs(output.Pixels[index + 2] - red), 0, 15);
    }
    [Fact]
    public async Task CropLimitsLongestSideTo256AndKeepsEdges()
    {
        var image = await SynologyPhotoFaceImage.DecodeAsync(await SyntheticImage());
        var output = await SynologyPhotoFaceImage.DecodeAsync(await image.CropAsync(new(0, 0, 1, 1))); Assert.Equal(256, output.Width); Assert.Equal(171, output.Height);
        var edge = await SynologyPhotoFaceImage.DecodeAsync(await image.CropAsync(new(0.999, 0.999, 0.001, 0.001))); Assert.Equal(1, edge.Width); Assert.Equal(1, edge.Height);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => image.CropAsync(new(0.8, 0, 0.5, 1)));
    }
    [Fact]
    public void DrawingMovingAndResizingStayInDisplayedPicture()
    {
        Assert.Null(SynologyPhotoFaceEditing.Square(20, 20, 30, 30, 400, 200));
        var box = SynologyPhotoFaceEditing.Square(160, 120, 80, 40, 400, 200)!; Assert.Equal(new(0.2, 0.2, 0.2, 0.4), box);
        Assert.Equal(80, box.Width * 400); Assert.Equal(80, box.Height * 200);
        var moved = SynologyPhotoFaceEditing.Move(box, 999, -999, 400, 200); Assert.Equal(0.8, moved.X); Assert.Equal(0, moved.Y);
        var resized = SynologyPhotoFaceEditing.Resize(box, 999, 999, 400, 200); Assert.True(resized.IsValid); Assert.Equal(160, resized.Width * 400); Assert.Equal(160, resized.Height * 200);
        var small = SynologyPhotoFaceEditing.Resize(box, 0, 0, 400, 200); Assert.Equal(10, small.Width * 400); Assert.Equal(10, small.Height * 200);
        var centered = SynologyPhotoFaceEditing.Center(400, 200); Assert.Equal(new(0.4375, 0.375, 0.125, 0.25), centered);
    }
    [Fact]
    public async Task DraftChangesKeepUnchangedFacesAndConvertMovedFrameToAddThenRemove()
    {
        var image = await SynologyPhotoFaceImage.DecodeAsync(await SyntheticImage()); var photo = new SynologyPhotosTestRepository().Photo();
        var original = new SynologyPhotoFaceRegion(71, 11, "Synthetic", new(0.1, 0.1, 0.2, 0.3)); var person = new SynologyPhotoCollection(11, "Synthetic");
        var unchanged = new SynologyPhotoFaceDraft("a", original, original.Bounds, 11, "Synthetic");
        Assert.False(SynologyPhotoFaceEditing.IsChanged(unchanged));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => SynologyPhotoFaceEditing.EditAsync(photo, image, [original], [unchanged], [person]));
        var moved = unchanged with { Bounds = original.Bounds with { X = 0.2 } }; var result = await SynologyPhotoFaceEditing.EditAsync(photo, image, [original], [moved], [person]);
        Assert.Equal([SynologyPhotoFaceChangeKind.Add, SynologyPhotoFaceChangeKind.Remove], result.FaceChanges.Select(change => change.Kind)); Assert.NotEmpty(result.FaceChanges[0].Jpeg!);
        var renamed = unchanged with { PersonId = 0, Name = " New synthetic " }; result = await SynologyPhotoFaceEditing.EditAsync(photo, image, [original], [renamed], [person]);
        Assert.Equal(SynologyPhotoFaceChangeKind.Reassign, Assert.Single(result.FaceChanges).Kind); Assert.Equal("New synthetic", result.FaceChanges[0].Name);
        var removed = unchanged with { Removed = true }; result = await SynologyPhotoFaceEditing.EditAsync(photo, image, [original], [removed], [person]); Assert.Equal(SynologyPhotoFaceChangeKind.Remove, Assert.Single(result.FaceChanges).Kind);
        Assert.False(SynologyPhotoFaceEditing.IsChanged(removed with { Removed = false }));
    }
    [Fact]
    public async Task NewDraftNeedsNameButKnownUnnamedPersonKeepsExactIdentity()
    {
        var photo = new SynologyPhotosTestRepository().Photo(); var image = await SynologyPhotoFaceImage.DecodeAsync(await SyntheticImage());
        var draft = new SynologyPhotoFaceDraft("new", null, new(0.2, 0.2, 0.2, 0.2), 0, " "); Assert.False(SynologyPhotoFaceEditing.IsValid(draft, []));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => SynologyPhotoFaceEditing.EditAsync(photo, image, [], [draft], []));
        var person = new SynologyPhotoCollection(11, ""); draft = draft with { PersonId = 11, Name = "" };
        var edit = await SynologyPhotoFaceEditing.EditAsync(photo, image, [], [draft], [person]); Assert.Equal(person, Assert.Single(edit.FaceChanges).Person); Assert.Equal("", edit.FaceChanges[0].Name);
    }
    private static async Task<byte[]> SyntheticImage(ushort orientation = 1)
    {
        const int width = 600, height = 400; var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++) for (var x = 0; x < width; x++)
        {
            var index = (y * width + x) * 4; var left = x < width / 2; var top = y < height / 2;
            pixels[index] = !top && left ? (byte)255 : (byte)0; pixels[index + 1] = !left ? (byte)255 : (byte)0;
            pixels[index + 2] = top && left || !top && !left ? (byte)255 : (byte)0; pixels[index + 3] = 255;
        }
        using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.TiffEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, width, height, 96, 96, pixels);
        await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet { ["System.Photo.Orientation"] = new(orientation, PropertyType.UInt16) });
        await encoder.FlushAsync(); stream.Seek(0); using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size);
        var bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes); return bytes;
    }
}
