using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Timeline;

public sealed class PhotoTimelineViewModel : ObservableObject, IDisposable
{
    private IPhotoTimelineDataSource? _source;
    private PhotoSpace? _space;
    private PhotoTimelineSnapshot? _committed;
    private CancellationTokenSource? _scanCancellation;
    private CancellationTokenSource? _queryCancellation;
    private Task _queryTask = Task.CompletedTask;
    private long _generation;
    private long _queryGeneration;
    private string _query = string.Empty;
    private PhotoTimelineFilter _filter;
    private PhotoTimelinePhase _phase;
    private bool _refreshFailed;
    private bool _disposed;

    public ObservableCollection<PhotoTimelineGroup> Groups { get; } = [];
    public Guid? ActiveProfileId { get; private set; }
    public PhotoTimelinePhase Phase { get => _phase; private set => SetProperty(ref _phase, value); }
    public string Query { get => _query; set { if (SetProperty(ref _query, value ?? string.Empty)) ScheduleQuery(); } }
    public PhotoTimelineFilter Filter { get => _filter; private set { if (SetProperty(ref _filter, value)) RebuildGroups(); } }
    public bool HasCompletedSnapshot => _committed is not null;
    public bool CommittedIsEmpty => _committed?.Items.Count == 0;
    public bool IsPartial => _committed?.SkippedFolderCount > 0;
    public bool IsTruncated => _committed?.Completion == PhotoTimelineCompletion.Truncated;
    public int SkippedFolderCount => _committed?.SkippedFolderCount ?? 0;
    public bool RefreshFailed { get => _refreshFailed; private set => SetProperty(ref _refreshFailed, value); }

    public void Activate(IPhotoTimelineDataSource source, PhotoSpace space)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        CancelCore();
        if (!ReferenceEquals(_source, source) || ActiveProfileId != source.ProfileId || _space?.Id != space.Id)
        {
            _committed = null;
            Groups.Clear();
            Query = string.Empty;
            Filter = PhotoTimelineFilter.All;
            Phase = PhotoTimelinePhase.Idle;
            RefreshFailed = false;
        }
        _source = source;
        _space = space;
        ActiveProfileId = source.ProfileId;
    }

    public async Task ScanIfNeededAsync()
    {
        if (_committed is null) await RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_source is null || _space is null || Phase == PhotoTimelinePhase.Scanning) return;
        var source = _source;
        var space = _space;
        var profileId = source.ProfileId;
        var generation = ++_generation;
        var cancellation = new CancellationTokenSource();
        _scanCancellation = cancellation;
        Phase = PhotoTimelinePhase.Scanning;
        RefreshFailed = false;
        try
        {
            var snapshot = await source.LoadAsync(space, cancellation.Token);
            if (!IsCurrent(source, space, profileId, generation) || cancellation.IsCancellationRequested) return;
            if (snapshot.ProfileId != profileId || snapshot.SpaceId != space.Id ||
                snapshot.Items.Any(item => item.ProfileId != profileId || item.Kind == PhotoItemKind.Folder ||
                    !ContainsCanonicalPath(space.RootPath, item.Path)))
            {
                throw new InvalidDataException("Timeline snapshot identity does not match the active profile and space.");
            }
            _committed = snapshot with { Items = Sort(snapshot.Items) };
            RebuildGroups();
            Phase = _committed.Items.Count == 0 ? PhotoTimelinePhase.Empty : PhotoTimelinePhase.Content;
            RaiseSnapshotProperties();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            if (IsCurrent(source, space, profileId, generation)) RestoreCommittedPhase();
        }
        catch
        {
            if (IsCurrent(source, space, profileId, generation))
            {
                RefreshFailed = _committed is not null;
                Phase = _committed is null ? PhotoTimelinePhase.Error :
                    _committed.Items.Count == 0 ? PhotoTimelinePhase.Empty : PhotoTimelinePhase.Content;
            }
        }
        finally
        {
            if (ReferenceEquals(_scanCancellation, cancellation)) _scanCancellation = null;
            cancellation.Dispose();
        }
    }

    public void Cancel()
    {
        if (Phase != PhotoTimelinePhase.Scanning) return;
        CancelCore();
        RestoreCommittedPhase();
    }

    public void SetFilter(PhotoTimelineFilter filter) => Filter = filter;

    internal bool CanSave(PhotoItem item) =>
        _space is { } space &&
        item.ProfileId == ActiveProfileId &&
        item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
        item.SizeBytes is >= 0 &&
        ContainsCanonicalPath(space.RootPath, item.Path);

    private bool IsCurrent(IPhotoTimelineDataSource source, PhotoSpace space, Guid profileId, long generation) =>
        !_disposed && ReferenceEquals(_source, source) && _space?.Id == space.Id &&
        ActiveProfileId == profileId && _generation == generation;

    private void RebuildGroups()
    {
        Groups.Clear();
        if (_committed is null) return;
        var query = Fold(Query);
        var filtered = _committed.Items.Where(item =>
            (Filter == PhotoTimelineFilter.All ||
             Filter == PhotoTimelineFilter.Images && item.Kind == PhotoItemKind.Image ||
             Filter == PhotoTimelineFilter.Videos && item.Kind == PhotoItemKind.Video) &&
            (query.Length == 0 || Fold(item.Name).Contains(query, StringComparison.Ordinal)));
        foreach (var grouping in filtered.GroupBy(item => MonthStart(item.CreatedAt ?? item.ModifiedAt, TimeZoneInfo.Local))
                     .OrderByDescending(group => group.Key ?? DateTimeOffset.MinValue))
        {
            var group = new PhotoTimelineGroup(grouping.Key?.ToString("yyyy-MM", CultureInfo.InvariantCulture) ?? "unknown", grouping.Key);
            foreach (var item in Sort(grouping)) group.Items.Add(new PhotoTimelineEntry(item));
            Groups.Add(group);
        }
        RaisePropertyChanged(nameof(Groups));
    }

    private static IReadOnlyList<PhotoItem> Sort(IEnumerable<PhotoItem> items) => items
        .OrderByDescending(item => item.CreatedAt ?? item.ModifiedAt ?? DateTimeOffset.MinValue)
        .ThenBy(item => item.Path, StringComparer.Ordinal)
        .ToArray();

    internal static bool ContainsCanonicalPath(string root, string path)
    {
        if (!IsCanonicalAbsolutePath(root, allowRoot: true) ||
            !IsCanonicalAbsolutePath(path, allowRoot: false)) return false;
        var canonicalRoot = root == "/" ? root : root.TrimEnd('/');
        return canonicalRoot == "/" ? path != "/" :
            path.StartsWith(canonicalRoot + "/", StringComparison.Ordinal);
    }

    private static bool IsCanonicalAbsolutePath(string value, bool allowRoot)
    {
        if (string.IsNullOrEmpty(value) || value[0] != '/' || value.Contains('\\') ||
            value.Contains("//", StringComparison.Ordinal) ||
            value.Length > 1 && value.EndsWith("/", StringComparison.Ordinal)) return false;
        if (value == "/") return allowRoot;
        return value.Split('/').Skip(1).All(segment =>
            segment.Length > 0 && segment != "." && segment != "..");
    }

    internal static DateTimeOffset? MonthStart(DateTimeOffset? date, TimeZoneInfo timeZone)
    {
        if (date is not { } value) return null;
        var local = TimeZoneInfo.ConvertTime(value, timeZone);
        return new DateTimeOffset(local.Year, local.Month, 1, 0, 0, 0, TimeSpan.Zero);
    }

    private void ScheduleQuery()
    {
        _queryCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _queryCancellation = cancellation;
        var generation = ++_queryGeneration;
        _queryTask = ApplyQueryAsync(generation, cancellation);
    }

    private async Task ApplyQueryAsync(long generation, CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellation.Token);
            if (_disposed || cancellation.IsCancellationRequested || generation != _queryGeneration) return;
            RebuildGroups();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(_queryCancellation, cancellation)) _queryCancellation = null;
            cancellation.Dispose();
        }
    }

    internal Task WaitForPendingQueryAsync() => _queryTask;

    private static string Fold(string value)
    {
        var normalized = value.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(normalized.Length);
        foreach (var character in normalized)
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
                builder.Append(char.ToLowerInvariant(character));
        return builder.ToString().Normalize(NormalizationForm.FormC);
    }

    private void RestoreCommittedPhase() =>
        Phase = _committed is null ? PhotoTimelinePhase.Idle :
            _committed.Items.Count == 0 ? PhotoTimelinePhase.Empty : PhotoTimelinePhase.Content;

    private void RaiseSnapshotProperties()
    {
        RaisePropertyChanged(nameof(HasCompletedSnapshot));
        RaisePropertyChanged(nameof(CommittedIsEmpty));
        RaisePropertyChanged(nameof(IsPartial));
        RaisePropertyChanged(nameof(IsTruncated));
        RaisePropertyChanged(nameof(SkippedFolderCount));
    }

    private void CancelCore()
    {
        ++_generation;
        _scanCancellation?.Cancel();
        _scanCancellation = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        CancelCore();
        ++_queryGeneration;
        _queryCancellation?.Cancel();
        _queryCancellation = null;
        _source = null;
        _space = null;
        Groups.Clear();
    }
}
