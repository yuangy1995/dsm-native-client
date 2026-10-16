namespace LanStash.Domain;

public sealed record SynologyPhotoAutomaticSetting(bool Original, bool Enabled);
public enum SynologyPhotoGrouping { Day, Month }
public enum SynologyPhotoDateFormat { YearDash, YearSlash, YearDot, DayDash, DaySlash, DayDot, MonthDash, MonthSlash, MonthDot }
public sealed record SynologyPhotoDisplaySettings(SynologyPhotoGrouping Grouping, SynologyPhotoDateFormat DateFormat,
    bool TwelveHourClock, SynologyPhotoSort DefaultSort, bool ShowsPreviewInfo);
public sealed record SynologyPhotoDuplicateSettings(SynologyPhotoDuplicatePolicy Upload, SynologyPhotoFileDuplicate Transfer);
public sealed record SynologyPhotoRecognitionSettings(bool PersonalEnabled, bool? People, bool? Subjects, bool? Similar,
    bool? GlobalPeople, bool? GlobalSubjects, bool? GlobalSimilar)
{
    public bool? Value(SynologyPhotoCategory kind) => kind switch
    { SynologyPhotoCategory.People => People, SynologyPhotoCategory.Subjects => Subjects, SynologyPhotoCategory.Similar => Similar, _ => null };
    public bool Editable(SynologyPhotoCategory kind) => PersonalEnabled && Value(kind) is not null && (kind switch
    { SynologyPhotoCategory.People => GlobalPeople, SynologyPhotoCategory.Subjects => GlobalSubjects, SynologyPhotoCategory.Similar => GlobalSimilar, _ => null }) == true;
}
public sealed record SynologyPhotoDisplaySettingChange(SynologyPhotoDisplaySettings Original, SynologyPhotoDisplaySettings Updated);
public sealed record SynologyPhotoDuplicateSettingChange(SynologyPhotoDuplicateSettings Original, SynologyPhotoDuplicateSettings Updated);
public sealed record SynologyPhotoRecognitionSettingChange(SynologyPhotoRecognitionSettings Original, SynologyPhotoRecognitionSettings Updated);
public sealed record SynologyPhotoSettingsSafety(bool SharedLibraryChanges = false, bool PublicDirectorySharing = false, bool GlobalSharingChanges = false, bool SharedMembers = false);
public enum SynologyPhotoSharedRole { None, Entry, Management }
public sealed record SynologyPhotoSharedSettings(Guid ProfileId, long AdministratorId, bool Enabled, bool PersonalEnabled,
    SynologyPhotoSharedRole Role, bool? DisabledBySharedFolder, bool? People, bool? Subjects, bool? Similar, bool? PublicRoot,
    bool? GlobalPeople, bool? GlobalSubjects, bool? GlobalSimilar)
{
    public bool CanAccess => Enabled && Role != SynologyPhotoSharedRole.None;
    public bool CanSetEnabled(bool value) => value != Enabled && (value || PersonalEnabled);
    public bool? Value(SynologyPhotoCategory kind) => kind switch
    { SynologyPhotoCategory.People => People, SynologyPhotoCategory.Subjects => Subjects, SynologyPhotoCategory.Similar => Similar, _ => null };
    public bool Editable(SynologyPhotoCategory kind) => Enabled && Value(kind) is not null && (kind switch
    { SynologyPhotoCategory.People => GlobalPeople, SynologyPhotoCategory.Subjects => GlobalSubjects, SynologyPhotoCategory.Similar => GlobalSimilar, _ => null }) == true;
}
public sealed record SynologyPhotoSharedSettingChange(SynologyPhotoSharedSettings Original, SynologyPhotoSharedSettings Updated, bool ChangesEnabled);
public sealed record SynologyPhotoSettingsChange(Guid Id, SynologyPhotoAutomaticSetting? Automatic,
    SynologyPhotoChangeState State, bool IsRunning, SynologyPhotoFailure? Failure = null)
{
    public SynologyPhotoDisplaySettingChange? Display { get; init; }
    public SynologyPhotoDuplicateSettingChange? Duplicates { get; init; }
    public SynologyPhotoRecognitionSettingChange? Recognition { get; init; }
    public SynologyPhotoSharedSettingChange? Shared { get; init; }
    public SynologyPhotoSharedSettings? SharedResult { get; init; }
    public SynologyPhotoGlobalSettingChange? Global { get; init; }
    public SynologyPhotoConversionCache? Cache { get; init; }
    public SynologyPhotoGlobalSettings? GlobalResult { get; init; }
    public SynologyPhotoConversionCache? CacheResult { get; init; }
    public SynologyPhotoMaintenanceChange? Maintenance { get; init; }
    public SynologyPhotoLibraryMaintenance? MaintenanceResult { get; init; }
    public bool MaintenanceAccepted { get; init; }
    public SynologyPhotoCodecResponse? Codec { get; init; }
    public bool CodecGenerationAccepted { get; init; }
    public SynologyPhotoBackgroundCommand? Background { get; init; }
    public int CompletedSteps { get; init; }
    public bool HasMemberChanges { get; init; }
    public bool MemberChangesObserved { get; init; }
    public int TotalSteps { get; init; }
    public bool PartiallySaved => State == SynologyPhotoChangeState.Failed && (CompletedSteps > 0 || MemberChangesObserved);
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
}
