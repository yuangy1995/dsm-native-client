namespace LanStash.Domain;

/// <summary>坐标基于按方向显示的图片，范围为 0 到 1；原件像素不会被修改。</summary>
public sealed record SynologyPhotoFaceBounds(double X, double Y, double Width, double Height)
{
    public bool IsValid => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Width) && double.IsFinite(Height) &&
        X >= 0 && Y >= 0 && Width > 0 && Height > 0 && X + Width <= 1 && Y + Height <= 1;
    public bool Matches(SynologyPhotoFaceBounds other) => Math.Abs(X - other.X) < 0.000001 && Math.Abs(Y - other.Y) < 0.000001 &&
        Math.Abs(Width - other.Width) < 0.000001 && Math.Abs(Height - other.Height) < 0.000001;
}
public sealed record SynologyPhotoFaceRegion(long Id, long PersonId, string Name, SynologyPhotoFaceBounds Bounds,
    SynologyPhotoThumbnail? Thumbnail = null);
public enum SynologyPhotoFaceChangeKind { Add, Remove, Reassign }
public sealed record SynologyPhotoFaceChange(SynologyPhotoFaceChangeKind Kind)
{
    public string TemporaryId { get; init; } = "";
    public SynologyPhotoFaceRegion? Original { get; init; }
    public SynologyPhotoFaceBounds? Bounds { get; init; }
    public SynologyPhotoCollection? Person { get; init; }
    public string? Name { get; init; }
    public byte[]? Jpeg { get; init; }
    public string Id => Kind == SynologyPhotoFaceChangeKind.Add ? "new-" + TemporaryId : "face-" + Original?.Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
}
