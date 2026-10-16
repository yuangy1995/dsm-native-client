using System.Collections.ObjectModel;
using System.Globalization;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasPerformanceViewModel : IDisposable
{
    private static LocalizationService L => LocalizationService.Current;
    private readonly INasDetailsRepository _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public NasPerformanceViewModel(INasDetailsRepository repository) => _repository = repository;
    public ObservableCollection<NasPerformanceSnapshot> History { get; } = [];
    public event Action? Changed;
    public bool IsLoading { get; private set; }
    public bool IsPaused { get; private set; }
    public string? Error { get; private set; }
    public bool IsAvailable => _repository.CanReadPerformance;
    public NasPerformanceSnapshot? Latest => History.LastOrDefault();
    public NasPerformanceMetric SelectedMetric { get; private set; } = NasPerformanceMetric.Cpu;
    public void SelectMetric(NasPerformanceMetric metric)
    { if (_disposed || !Enum.IsDefined(metric)) return; SelectedMetric = metric; Changed?.Invoke(); }
    public void TogglePause()
    {
        if (_disposed) return;
        IsPaused = !IsPaused;
        if (IsPaused) CancelRead();
        Changed?.Invoke();
    }
    public async Task RefreshAsync(bool force = false)
    {
        if (_disposed || IsLoading || !IsAvailable || IsPaused && !force) return;
        var generation = ++_generation;
        var cancellation = new CancellationTokenSource(); _cancellation = cancellation;
        IsLoading = true; Changed?.Invoke();
        try
        {
            var value = await _repository.LoadPerformanceAsync(cancellation.Token);
            if (_disposed || generation != _generation) return;
            if (value.ProfileId != _repository.ProfileId) throw new InvalidDataException("nas-performance.profile-mismatch");
            if (History.LastOrDefault()?.RecordedAt != value.RecordedAt)
            {
                if (History.LastOrDefault()?.RecordedAt > value.RecordedAt) History.Clear();
                History.Add(value);
                while (History.Count > 120) History.RemoveAt(0);
            }
            Error = null;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch { if (!_disposed && generation == _generation) Error = L.Get("NasPerformanceReadError"); }
        finally
        {
            cancellation.Dispose();
            if (!_disposed && generation == _generation) { _cancellation = null; IsLoading = false; Changed?.Invoke(); }
        }
    }
    private void CancelRead()
    { _generation++; _cancellation?.Cancel(); _cancellation = null; IsLoading = false; }
    public void Dispose()
    { if (_disposed) return; _disposed = true; CancelRead(); }

    public static string Title(NasPerformanceMetric metric) => L.Get(metric switch
    {
        NasPerformanceMetric.Cpu => "NasPerformanceCpu", NasPerformanceMetric.CpuUser => "NasPerformanceCpuUser",
        NasPerformanceMetric.CpuSystem => "NasPerformanceCpuSystem", NasPerformanceMetric.CpuOther => "NasPerformanceCpuOther",
        NasPerformanceMetric.Memory => "NasPerformanceMemory", NasPerformanceMetric.Swap => "NasPerformanceSwap",
        NasPerformanceMetric.NetworkReceived => "NasPerformanceReceived", NasPerformanceMetric.NetworkSent => "NasPerformanceSent",
        NasPerformanceMetric.DiskRead => "NasPerformanceDiskRead", NasPerformanceMetric.DiskWrite => "NasPerformanceDiskWrite",
        NasPerformanceMetric.VolumeRead => "NasPerformanceVolumeRead", NasPerformanceMetric.VolumeWrite => "NasPerformanceVolumeWrite",
        NasPerformanceMetric.DiskUtilization => "NasPerformanceDiskUtilization", NasPerformanceMetric.NfsRead => "NasPerformanceNfsRead",
        NasPerformanceMetric.NfsWrite => "NasPerformanceNfsWrite", _ => throw new ArgumentOutOfRangeException(nameof(metric)),
    });
    public static bool IsPercent(NasPerformanceMetric metric) => metric is NasPerformanceMetric.Cpu or NasPerformanceMetric.CpuUser or
        NasPerformanceMetric.CpuSystem or NasPerformanceMetric.CpuOther or NasPerformanceMetric.Memory or NasPerformanceMetric.Swap or NasPerformanceMetric.DiskUtilization;
    public static string Format(NasPerformanceMetric metric, double? value)
    {
        if (value is null) return L.Get("NasPerformanceUnknown");
        if (IsPercent(metric)) return (value.Value / 100).ToString("P1", CultureInfo.CurrentCulture);
        if (metric is NasPerformanceMetric.NfsRead or NasPerformanceMetric.NfsWrite) return L.Format("NasPerformanceOperations", value.Value.ToString("N1", CultureInfo.CurrentCulture));
        var amount = value.Value; var unit = "B/s";
        foreach (var next in new[] { "KiB/s", "MiB/s", "GiB/s", "TiB/s" })
        { if (amount < 1024) break; amount /= 1024; unit = next; }
        return L.Format("NasPerformanceRate", amount.ToString("N1", CultureInfo.CurrentCulture), unit);
    }
}
