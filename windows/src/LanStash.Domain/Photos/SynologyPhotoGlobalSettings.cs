namespace LanStash.Domain;

public enum SynologyPhotoGlobalKind { People, Subjects, Similar, UserSharing, GuestInfo, OriginalJpeg }
public sealed record SynologyPhotoGlobalSettings(Guid ProfileId, long AdministratorId,
    bool? People, bool? Subjects, bool? Similar, bool? UserSharing, bool? GuestInfo, bool? OriginalJpeg,
    IReadOnlyList<string>? ExcludedExtensions, bool? HasHevc, bool PersonalEnabled, bool SharedEnabled, SynologyPhotoSharedRole SharedRole,
    bool? PersonalPeople, bool? PersonalSubjects, bool? PersonalSimilar, bool? SharedPeople, bool? SharedSubjects, bool? SharedSimilar)
{
    public static IReadOnlyList<string> SupportedExtensions { get; } = "JPG JPEG JPE WEBP BMP PNG GIF TIF TIFF HEIC HEIF HIF ARW SRF SR2 DCR K25 KDC CR2 CR3 CRW NEF MRW PTX PEF RAF 3FR ERF MEF MOS ORF RW2 DNG X3F RAW MPG MPEG AVI ASF WMV MOV FLV F4V MP4 DIVX XVID M2TS M2T MTS M4V 3GP 3G2 QT".Split(' ');
    public bool SupportsOriginalJpeg => HasHevc == true && OriginalJpeg == true;
    public bool? Value(SynologyPhotoGlobalKind kind) => kind switch
    { SynologyPhotoGlobalKind.People => People, SynologyPhotoGlobalKind.Subjects => Subjects, SynologyPhotoGlobalKind.Similar => Similar,
      SynologyPhotoGlobalKind.UserSharing => UserSharing, SynologyPhotoGlobalKind.GuestInfo => GuestInfo, _ => OriginalJpeg };
    public bool Editable(SynologyPhotoGlobalKind kind) => Value(kind) is not null && (kind != SynologyPhotoGlobalKind.OriginalJpeg || HasHevc == true);
    public SynologyPhotoGlobalSettings Applying(IReadOnlySet<SynologyPhotoGlobalKind> enabled, IReadOnlyList<string>? excluded)
    {
        bool? V(SynologyPhotoGlobalKind kind) => Value(kind) is null ? null : enabled.Contains(kind);
        return this with { People = V(SynologyPhotoGlobalKind.People), Subjects = V(SynologyPhotoGlobalKind.Subjects), Similar = V(SynologyPhotoGlobalKind.Similar),
            UserSharing = V(SynologyPhotoGlobalKind.UserSharing), GuestInfo = V(SynologyPhotoGlobalKind.GuestInfo), OriginalJpeg = V(SynologyPhotoGlobalKind.OriginalJpeg), ExcludedExtensions = excluded?.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            PersonalPeople = V(SynologyPhotoGlobalKind.People) == false && PersonalPeople is not null ? false : PersonalPeople,
            PersonalSubjects = V(SynologyPhotoGlobalKind.Subjects) == false && PersonalSubjects is not null ? false : PersonalSubjects,
            PersonalSimilar = V(SynologyPhotoGlobalKind.Similar) == false && PersonalSimilar is not null ? false : PersonalSimilar,
            SharedPeople = V(SynologyPhotoGlobalKind.People) == false && SharedPeople is not null ? false : SharedPeople,
            SharedSubjects = V(SynologyPhotoGlobalKind.Subjects) == false && SharedSubjects is not null ? false : SharedSubjects,
            SharedSimilar = V(SynologyPhotoGlobalKind.Similar) == false && SharedSimilar is not null ? false : SharedSimilar };
    }
    public bool SameValues(SynologyPhotoGlobalSettings other) => this with { ExcludedExtensions = null } == other with { ExcludedExtensions = null } && SameExtensions(ExcludedExtensions, other.ExcludedExtensions);
    public static bool SameExtensions(IReadOnlyList<string>? a, IReadOnlyList<string>? b) => a is null ? b is null : b is not null && a.ToHashSet(StringComparer.Ordinal).SetEquals(b);
}
public sealed record SynologyPhotoGlobalSettingChange(SynologyPhotoGlobalSettings Original, SynologyPhotoGlobalSettings Updated);
public sealed record SynologyPhotoConversionCache(Guid ProfileId, long AdministratorId, long SizeBytes, bool IsClearing)
{ public bool CanClear => SizeBytes > 0 && !IsClearing; }
public enum SynologyPhotoSettingStep { Cache, Admin, Personal, Shared }
