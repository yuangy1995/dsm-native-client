using System.Globalization;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private int? _memberReloadCount;
    private readonly HashSet<Guid> _appliedMemberSettings = [];
    public void BeginSharedMemberChange()
    {
        if (_disposed || SelectedSpace != SynologyPhotoSpace.Shared) return;
        var count = Math.Max(Items.Count, _memberReloadCount ?? 0); StartRequest(); _memberReloadCount = count;
        Items.Clear(); _itemIds.Clear(); _pagedPhotoIds.Clear(); Collections.Clear(); SharedEntries.Clear();
        HasMore = false; HasMoreCollections = false; NeedsChangesRefresh = true; IsLoading = false; Changed(content: true);
    }
    private static readonly string[] DatePatterns = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "dd-MM-yyyy", "dd/MM/yyyy", "dd.MM.yyyy", "MM-dd-yyyy", "MM/dd/yyyy", "MM.dd.yyyy"];
    public DateOnly DisplayGroupDate(SynologyPhoto photo)
    {
        var date = DateOnly.FromDateTime((Category == SynologyPhotoCategory.Recent ? photo.IndexedAt : photo.TakenAt).LocalDateTime);
        return DisplaySettings?.Grouping == SynologyPhotoGrouping.Month ? new(date.Year, date.Month, 1) : date;
    }
    public string DisplayDate(DateTimeOffset date, bool time = true) => FormatDisplayDate(date.LocalDateTime, DisplaySettings, time, false, CultureInfo.CurrentCulture);
    public string DisplayGroupTitle(DateOnly date) => FormatDisplayDate(date.ToDateTime(TimeOnly.MinValue), DisplaySettings, false,
        DisplaySettings?.Grouping == SynologyPhotoGrouping.Month, CultureInfo.CurrentCulture);
    public static string FormatDisplayDate(DateTime date, SynologyPhotoDisplaySettings? settings, bool time, bool month, CultureInfo culture)
    {
        if (settings is null) return date.ToString(time ? "f" : month ? "Y" : "D", culture);
        var pattern = DatePatterns[(int)settings.DateFormat];
        if (month) pattern = System.Text.RegularExpressions.Regex.Replace(pattern, @"[-/.]dd|dd[-/.]", "");
        if (time) pattern += settings.TwelveHourClock ? " h:mm tt" : " HH:mm";
        return date.ToString(pattern, culture);
    }
    public async Task ApplySettingsChangeAsync(SynologyPhotoSettingsChange change)
    {
        if (_disposed || change.State != SynologyPhotoChangeState.Completed && change.GlobalResult is null && change.SharedResult is null) return;
        if (change.SharedResult is { } owner && owner.ProfileId != _repository.ProfileId) return;
        if (change.HasMemberChanges && !_appliedMemberSettings.Add(change.Id)) return;
        if (change.GlobalResult is { } global && global.ProfileId != _repository.ProfileId) return;
        if (change.Display is { } display) { DisplaySettings = display.Updated; Changed(content: true); }
        if (change.SharedResult is { } shared)
        {
            if (shared.ProfileId != _repository.ProfileId) return;
            Spaces = Spaces.Where(space => space != SynologyPhotoSpace.Shared).Concat(shared.CanAccess ? [SynologyPhotoSpace.Shared] : Array.Empty<SynologyPhotoSpace>()).ToArray();
            CanManageSharedSpace = shared.CanAccess && shared.Role == SynologyPhotoSharedRole.Management;
            if (SelectedSpace == SynologyPhotoSpace.Shared && !shared.CanAccess)
            {
                Preview.Close(); SelectedSpace = Spaces.FirstOrDefault(); Album = null; ResetSourceNavigation();
                if (Spaces.Count == 0) Section = SynologyPhotosSection.Albums;
                await RefreshAsync(); return;
            }
            Changed();
        }
        if (change.HasMemberChanges && change.SharedResult is not null && SelectedSpace == SynologyPhotoSpace.Shared)
        {
            if (_memberReloadCount is null) BeginSharedMemberChange();
            if (ShowsCategories || Category is not null && CategoryItem is null && Category is not (SynologyPhotoCategory.Recent or SynologyPhotoCategory.Videos or SynologyPhotoCategory.Similar) || Section == SynologyPhotosSection.Sharing && Album is null)
                await RefreshAsync();
            else await ReloadChangedPhotoWindowAsync();
        }
        if (change.GlobalResult is not null || change.Recognition is not null && SelectedSpace == SynologyPhotoSpace.Personal || change.SharedResult is not null && SelectedSpace == SynologyPhotoSpace.Shared)
        {
            var generation = _generation; var token = _request.Token;
            try
            {
                var categories = await _repository.CategoriesAsync(token, SelectedSpace); EnsureCurrent(generation, token);
                Categories = categories;
                if (Category is { } kind && !categories.Contains(kind))
                { Category = null; CategoryItem = null; Section = SynologyPhotosSection.Albums; await RefreshAsync(); }
                else Changed();
            }
            catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
            catch (Exception) { if (IsCurrent(generation, token)) { ErrorKey = "PhotosRecognitionRefreshFailed"; Changed(); } }
        }
    }
}
