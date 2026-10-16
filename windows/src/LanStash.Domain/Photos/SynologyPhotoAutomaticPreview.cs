namespace LanStash.Domain;

public enum SynologyPhotoAutomaticPriority { Standard = 1, HevcOrLiveVideo, Vc1, Background }
public sealed record SynologyPhotoConversionSupport(bool Hevc, bool Vc1, bool Video)
{
    public bool Available => Hevc || Video;
    public string Preset => Vc1 ? Hevc ? "windows" : "windows2" : "macos";
}
/// <summary>单元编号不能当作图库项目编号；后台来源没有照片快照。</summary>
public sealed record SynologyPhotoAutomaticCandidate(Guid ProfileId, SynologyPhotoSpace Space, long UnitId, string Filename,
    int TypeCode, bool NeedsThumbnail, bool NeedsVideo, SynologyPhoto? SourcePhoto = null,
    SynologyPhotoAutomaticPriority Priority = SynologyPhotoAutomaticPriority.Background)
{
    public bool SameUnit(SynologyPhotoAutomaticCandidate other) => ProfileId == other.ProfileId && Space == other.Space &&
        UnitId == other.UnitId && Filename == other.Filename && (TypeCode == 0) == (other.TypeCode == 0) &&
        NeedsThumbnail == other.NeedsThumbnail && NeedsVideo == other.NeedsVideo;
}

/// <summary>仅包含压缩轨道摘要，不保存媒体或容器路径；重封装不改变样本身份。</summary>
public sealed record SynologyPhotoVideoSignature(long DurationMicroseconds, IReadOnlyList<SynologyPhotoVideoTrack> Tracks)
{
    public bool IsValid => DurationMicroseconds > 0 && Tracks is { Count: > 0 and <= 32 } && Tracks.Any(t => t.Type == "vide") &&
        Tracks.All(t => t.Type is "vide" or "soun" && t.Formats is { Count: > 0 and <= 32 } && t.Formats.All(f => f.Length == 4) &&
            t.Matrix is { Count: 9 } && t.SampleCount > 0 && t.Digest.Length == 64 && t.Digest.All(Uri.IsHexDigit));
    public bool Matches(SynologyPhotoVideoSignature other) => IsValid && other.IsValid && DurationMicroseconds == other.DurationMicroseconds &&
        Tracks.Count == other.Tracks.Count && Tracks.Zip(other.Tracks).All(p => p.First.Type == p.Second.Type &&
            p.First.Formats.SequenceEqual(p.Second.Formats) && p.First.Matrix.SequenceEqual(p.Second.Matrix) &&
            p.First.SampleCount == p.Second.SampleCount && p.First.Digest == p.Second.Digest);
}
public sealed record SynologyPhotoVideoTrack(string Type, IReadOnlyList<string> Formats, IReadOnlyList<int> Matrix, long SampleCount, string Digest);

public sealed record SynologyPhotoAutomaticPreview(Guid Id, SynologyPhotoAutomaticCandidate Candidate,
    SynologyPhotoChangeState State, bool Running, bool FailureRecorded = false, SynologyPhoto? Updated = null,
    SynologyPhotoFailure? Failure = null)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
}

/// <summary>只有明确的媒体损坏或编解码失败才允许报告 NAS；系统能力/资源不足不属于该类。</summary>
public sealed class SynologyPhotoConversionException : Exception
{
    public bool CanRecordFailure { get; }
    public SynologyPhotoConversionException(bool canRecordFailure) : base("photos.conversion.failed") => CanRecordFailure = canRecordFailure;
}
