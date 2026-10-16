using LanStash.Domain;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace LanStash.App.Features.Photos.Synology;

public sealed record SynologyPhotoFaceDraft(string Id, SynologyPhotoFaceRegion? Original, SynologyPhotoFaceBounds Bounds, long PersonId, string Name, bool Removed = false);

/// <summary>画框与键盘调整共用显示图片坐标；裁剪资料仅驻留内存。</summary>
public static class SynologyPhotoFaceEditing
{
    public static SynologyPhotoFaceBounds? Square(double startX, double startY, double endX, double endY, double width, double height)
    {
        if (width <= 0 || height <= 0) return null;
        var x = Math.Clamp(startX, 0, width); var y = Math.Clamp(startY, 0, height); var right = endX >= x; var down = endY >= y;
        var side = Math.Min(Math.Max(Math.Abs(endX - x), Math.Abs(endY - y)), Math.Min(right ? width - x : x, down ? height - y : y));
        return side < Math.Min(36, Math.Min(width, height)) ? null : new((right ? x : x - side) / width, (down ? y : y - side) / height, side / width, side / height);
    }
    public static SynologyPhotoFaceBounds Center(double width, double height)
    {
        var side = Math.Min(width, height) * 0.25; return new((width - side) / (2 * width), (height - side) / (2 * height), side / width, side / height);
    }
    public static SynologyPhotoFaceBounds Move(SynologyPhotoFaceBounds box, double deltaX, double deltaY, double width, double height) =>
        box with { X = Math.Clamp(box.X + deltaX / width, 0, 1 - box.Width), Y = Math.Clamp(box.Y + deltaY / height, 0, 1 - box.Height) };
    public static SynologyPhotoFaceBounds Resize(SynologyPhotoFaceBounds box, double endX, double endY, double width, double height, double minimum = 10)
    {
        var available = Math.Min((1 - box.X) * width, (1 - box.Y) * height);
        var side = Math.Clamp(Math.Max(endX - box.X * width, endY - box.Y * height), Math.Min(minimum, available), available);
        return box with { Width = Math.Min(1 - box.X, side / width), Height = Math.Min(1 - box.Y, side / height) };
    }
    public static bool IsChanged(SynologyPhotoFaceDraft draft) => draft.Original is not { } original ? !draft.Removed : draft.Removed ||
        draft.Bounds != original.Bounds || draft.PersonId != original.PersonId || draft.Name != original.Name;
    public static bool IsValid(SynologyPhotoFaceDraft draft, IReadOnlyList<SynologyPhotoCollection> people) => !IsChanged(draft) || draft.Removed ||
        draft.Bounds.IsValid && (people.Any(person => person.Id == draft.PersonId) || !string.IsNullOrWhiteSpace(draft.Name));
    public static async Task<SynologyPhotoRecognitionEdit> EditAsync(SynologyPhoto photo, SynologyPhotoFaceImage image,
        IReadOnlyList<SynologyPhotoFaceRegion> originals, IReadOnlyList<SynologyPhotoFaceDraft> drafts, IReadOnlyList<SynologyPhotoCollection> people, CancellationToken token = default)
    {
        var changes = new List<SynologyPhotoFaceChange>();
        foreach (var draft in drafts.Where(IsChanged))
        {
            token.ThrowIfCancellationRequested(); if (!IsValid(draft, people)) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
            if (draft.Removed) { if (draft.Original is { } original) changes.Add(new(SynologyPhotoFaceChangeKind.Remove) { Original = original }); continue; }
            var person = people.SingleOrDefault(person => person.Id == draft.PersonId); var name = person?.Name ?? draft.Name.Trim();
            if (draft.Original is { } source && source.Bounds == draft.Bounds)
                changes.Add(new(SynologyPhotoFaceChangeKind.Reassign) { Original = source, Person = person, Name = name });
            else
            {
                changes.Add(new(SynologyPhotoFaceChangeKind.Add) { TemporaryId = draft.Id, Bounds = draft.Bounds, Person = person, Name = name, Jpeg = await image.CropAsync(draft.Bounds, token) });
                if (draft.Original is { } previous) changes.Add(new(SynologyPhotoFaceChangeKind.Remove) { Original = previous });
            }
        }
        if (changes.Count is 0 or > 100) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
        return new(SynologyPhotoRecognitionKind.ManualFaces, []) { Space = photo.Id.Space, ManualPhoto = photo, OriginalRegions = originals.ToArray(), FaceChanges = changes };
    }
}

public sealed class SynologyPhotoFaceImage
{
    public int Width { get; }
    public int Height { get; }
    internal byte[] Pixels { get; }
    private SynologyPhotoFaceImage(int width, int height, byte[] pixels) { Width = width; Height = height; Pixels = pixels; }
    public static async Task<SynologyPhotoFaceImage> DecodeAsync(byte[] bytes, CancellationToken token = default)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream)) { writer.WriteBytes(bytes); await writer.StoreAsync().AsTask(token); writer.DetachStream(); }
        stream.Seek(0); var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(token);
        var width = checked((int)decoder.OrientedPixelWidth); var height = checked((int)decoder.OrientedPixelHeight);
        // 防止压缩图片展开后耗尽内存；常用 Photos 预览远小于此限制。
        if (width <= 0 || height <= 0 || (long)width * height > 64 * 1024 * 1024) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(),
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(token)).DetachPixelData();
        return new(width, height, pixels);
    }
    public async Task<byte[]> CropAsync(SynologyPhotoFaceBounds bounds, CancellationToken token = default)
    {
        if (!bounds.IsValid) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
        var x = Math.Clamp((int)Math.Floor(bounds.X * Width), 0, Width - 1); var y = Math.Clamp((int)Math.Floor(bounds.Y * Height), 0, Height - 1);
        var right = Math.Clamp((int)Math.Ceiling((bounds.X + bounds.Width) * Width), x + 1, Width); var bottom = Math.Clamp((int)Math.Ceiling((bounds.Y + bounds.Height) * Height), y + 1, Height);
        var width = right - x; var height = bottom - y; var pixels = new byte[checked(width * height * 4)];
        for (var row = 0; row < height; row++) { token.ThrowIfCancellationRequested(); System.Buffer.BlockCopy(Pixels, ((y + row) * Width + x) * 4, pixels, row * width * 4, width * 4); }
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, new Dictionary<string, BitmapTypedValue>
            { ["ImageQuality"] = new(0.9f, PropertyType.Single) }).AsTask(token);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
        var scale = Math.Min(1, 256d / Math.Max(width, height));
        encoder.BitmapTransform.ScaledWidth = (uint)Math.Max(1, Math.Round(width * scale)); encoder.BitmapTransform.ScaledHeight = (uint)Math.Max(1, Math.Round(height * scale));
        encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        await encoder.FlushAsync().AsTask(token); stream.Seek(0);
        using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size).AsTask(token); var result = new byte[checked((int)stream.Size)]; reader.ReadBytes(result); return result;
    }
}
