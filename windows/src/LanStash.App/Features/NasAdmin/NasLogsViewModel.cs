using System.Globalization;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasLogsViewModel(INasDetailsRepository repository) : IDisposable
{
    private static LocalizationService L => LocalizationService.Current;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    private (int Offset, int Limit)? _retry;
    public event Action? Changed;
    public NasLogPage? Page { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsAvailable => repository.CanReadLogs;
    public string? Error { get; private set; }
    public string Search { get; private set; } = "";
    public NasLogLevelFilter Filter { get; private set; }
    public int PageSize => Page?.Limit ?? 50;
    public bool CanPrevious => !IsLoading && Page?.Offset > 0;
    public bool CanNext => !IsLoading && Page is { HasNext: true } page && page.Offset <= int.MaxValue - page.Limit;
    public IReadOnlyList<NasLogEntry> VisibleEntries => Page?.Entries.Where(entry =>
        (Filter == NasLogLevelFilter.All || Level(entry.Level) == Filter) &&
        (Search.Length == 0 || Contains(entry.Message) || Contains(entry.Source) || Contains(entry.Account))).ToArray() ?? [];
    private bool Contains(string? value) => value?.Contains(Search, StringComparison.CurrentCultureIgnoreCase) == true;
    public string PageText => Page is not { } page ? "" : page.Total is { } total
        ? L.Format("NasLogsPageKnown", page.Offset / page.Limit + 1, total.ToString("N0", CultureInfo.CurrentCulture))
        : L.Format("NasLogsPageUnknown", page.Offset / page.Limit + 1);
    public void SetFilter(NasLogLevelFilter filter, string search)
    { if (_disposed || !Enum.IsDefined(filter)) return; Filter = filter; Search = search; Changed?.Invoke(); }
    public Task RefreshAsync() => ReadAsync(_retry?.Offset ?? Page?.Offset ?? 0, _retry?.Limit ?? PageSize);
    public Task PreviousAsync() => CanPrevious ? ReadAsync(Math.Max(0, Page!.Offset - PageSize), PageSize) : Task.CompletedTask;
    public Task NextAsync() => CanNext ? ReadAsync(Page!.Offset + PageSize, PageSize) : Task.CompletedTask;
    public Task ChangePageSizeAsync(int size) => size is 50 or 100 or 200 ? ReadAsync(0, size) : Task.CompletedTask;
    private async Task ReadAsync(int offset, int limit)
    {
        if (_disposed || IsLoading || !IsAvailable) return;
        var generation = ++_generation; var cancellation = new CancellationTokenSource(); _cancellation = cancellation;
        IsLoading = true; Changed?.Invoke();
        try
        {
            var page = await repository.LoadLogPageAsync(offset, limit, cancellation.Token);
            if (_disposed || generation != _generation) return;
            if (page.ProfileId != repository.ProfileId || page.Offset != offset || page.Limit != limit) throw new InvalidDataException("nas-logs.owner-mismatch");
            Page = page; Error = null; _retry = null;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch { if (!_disposed && generation == _generation) { Error = L.Get("NasLogsReadError"); _retry = (offset, limit); } }
        finally
        {
            cancellation.Dispose();
            if (!_disposed && generation == _generation) { _cancellation = null; IsLoading = false; Changed?.Invoke(); }
        }
    }
    public static NasLogLevelFilter Level(string? value)
    {
        var level = value?.ToLowerInvariant() ?? "";
        return level.Contains("err", StringComparison.Ordinal) || level.Contains("fatal", StringComparison.Ordinal) || level.Contains("critical", StringComparison.Ordinal)
            ? NasLogLevelFilter.Error : level.Contains("warn", StringComparison.Ordinal) ? NasLogLevelFilter.Warning : NasLogLevelFilter.Information;
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _generation++; _cancellation?.Cancel(); _cancellation = null;
        IsLoading = false; Page = null; Search = ""; Error = null; _retry = null; Changed = null;
    }
}
