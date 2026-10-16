namespace LanStash.Domain;

public enum SynologyPhotoMaintenanceAction { Reindex, Previews }
public sealed record SynologyPhotoLibraryMaintenance(Guid ProfileId, long UserId, SynologyPhotoSpace Space,
    long IndexingCount, long PreviewCount, bool SupportsPreviews)
{
    public long PendingCount(SynologyPhotoMaintenanceAction action) => action == SynologyPhotoMaintenanceAction.Reindex ? IndexingCount : PreviewCount;
    public bool CanStart(SynologyPhotoMaintenanceAction action) => ProfileId != Guid.Empty && UserId > 0 && Enum.IsDefined(Space) && Enum.IsDefined(action) &&
        IndexingCount >= 0 && PreviewCount >= 0 && PendingCount(action) == 0 && (action == SynologyPhotoMaintenanceAction.Reindex || SupportsPreviews);
}
public sealed record SynologyPhotoMaintenanceChange(SynologyPhotoLibraryMaintenance Original, SynologyPhotoMaintenanceAction Action);
public sealed record SynologyPhotoCodecPrompt(Guid ProfileId, long UserId, bool IsAdministrator, bool ShouldShow,
    bool PersonalEnabled, bool GenerationAlreadySubmitted = false)
{
    public bool CanGenerate => UserId > 0 && ShouldShow && !GenerationAlreadySubmitted && (IsAdministrator || PersonalEnabled);
}
public sealed record SynologyPhotoCodecResponse(SynologyPhotoCodecPrompt Original, bool Generate);
