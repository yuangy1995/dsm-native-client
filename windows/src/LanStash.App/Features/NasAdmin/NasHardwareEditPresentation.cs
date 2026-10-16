using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

internal static class NasHardwareEditPresentation
{
    public static string? Status(NasHardwareEditRecovery? recovery) => recovery switch
    {
        null => null,
        { IsComplete: true, Kind: NasHardwareEditKind.Zram } => "NasZramSaved",
        { IsComplete: true } => "NasPowerScheduleSaved",
        { CanMarkReboot: true } => "NasZramMarkerRemaining",
        { HasUnknown: true } => "NasHardwareEditPending",
        _ => "NasHardwareEditRejected",
    };
    public static string Error(Exception error) => error is NasHardwareEditException edit ? edit.Category switch
    {
        MutationErrorCategory.Permission => "NasHardwareEditPermission",
        MutationErrorCategory.Conflict => "NasHardwareEditChanged",
        MutationErrorCategory.Unsupported => "NasHardwareEditUnavailable",
        MutationErrorCategory.Validation => "NasHardwareEditInvalid",
        _ => "NasHardwareEditFailed",
    } : "NasHardwareEditFailed";
    public static async Task<NasHardwareEditRecovery?> LoadAsync(INasSettingsRepository repository, NasHardwareEditKind kind, CancellationToken token)
    {
        var items = (await repository.LoadHardwareEditRecoveriesAsync(token)).Where(item => item.Kind == kind).OrderByDescending(item => item.CreatedAt).ToArray();
        var current = items.FirstOrDefault(item => item.HasUnknown || item.CanMarkReboot) ?? items.FirstOrDefault();
        return current?.HasUnknown == true ? await repository.ReviewHardwareEditAsync(current.Id, token) : current;
    }
}
