using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace LanStash.App.Views;

public sealed record NasPerformanceRow(string Title, string Value);
public sealed partial class NasPerformanceDialogContent : UserControl, INasSettingsDialogContent
{
    private static LocalizationService L => LocalizationService.Current;
    private readonly NasPerformanceViewModel _model;
    private readonly DispatcherQueueTimer _timer;
    private bool _disposed;
    public bool CanSave => false;
    public bool IsBusy => _model.IsLoading;
    public string? PrimaryButtonResourceKey => null;
    public string ReloadButtonResourceKey => "NasPerformanceRefresh";
    public event Action? StateChanged;
    public NasPerformanceDialogContent(INasDetailsRepository repository)
    {
        _model = new(repository); InitializeComponent();
        foreach (var metric in Enum.GetValues<NasPerformanceMetric>())
            MetricChoice.Items.Add(new ComboBoxItem { Tag = metric, Content = NasPerformanceViewModel.Title(metric) });
        MetricChoice.SelectedIndex = 0;
        _model.Changed += Update;
        _timer = DispatcherQueue.CreateTimer(); _timer.Interval = TimeSpan.FromSeconds(2);
        _timer.Tick += async (_, _) => await _model.RefreshAsync();
        Unloaded += (_, _) => _timer.Stop();
        Update();
    }
    public async Task ActivateAsync()
    { if (_disposed) return; _timer.Start(); await _model.RefreshAsync(true); }
    public Task ReloadAsync() => _model.RefreshAsync(true);
    public Task SaveAsync() => Task.CompletedTask;
    private async void Pause_Click(object sender, RoutedEventArgs e)
    { _model.TogglePause(); if (!_model.IsPaused) await _model.RefreshAsync(); }
    private void Metric_Changed(object sender, SelectionChangedEventArgs e)
    { if (MetricChoice.SelectedItem is ComboBoxItem { Tag: NasPerformanceMetric metric }) _model.SelectMetric(metric); }
    private void Update()
    {
        if (_disposed) return;
        var latest = _model.Latest;
        PauseButton.Content = L.Get(_model.IsPaused ? "NasPerformanceResume" : "NasPerformancePause");
        PauseButton.IsEnabled = _model.IsAvailable;
        StatusText.Text = _model.IsPaused ? L.Get("NasPerformancePaused") : latest is not null
            ? L.Format("NasPerformanceUpdated", latest.RecordedAt.ToLocalTime().ToString("T")) : "";
        LoadingIndicator.IsActive = _model.IsLoading && latest is null;
        LoadingIndicator.Visibility = LoadingIndicator.IsActive ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.Message = _model.Error ?? ""; ErrorNotice.IsOpen = _model.Error is not null;
        ErrorNotice.Visibility = ErrorNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = L.Get(_model.IsAvailable ? "NasPerformanceEmpty" : "NasPerformanceUnavailable");
        EmptyText.Visibility = !_model.IsLoading && _model.Error is null && latest?.HasValues != true ? Visibility.Visible : Visibility.Collapsed;
        ContentPanel.Visibility = latest?.HasValues == true ? Visibility.Visible : Visibility.Collapsed;
        CurrentValue.Text = NasPerformanceViewModel.Format(_model.SelectedMetric, latest?[_model.SelectedMetric]);
        if (latest is not null) Metrics.ItemsSource = Enum.GetValues<NasPerformanceMetric>().Select(metric =>
            new NasPerformanceRow(NasPerformanceViewModel.Title(metric), NasPerformanceViewModel.Format(metric, latest[metric]))).ToArray();
        DrawChart(); StateChanged?.Invoke();
    }
    private void Chart_SizeChanged(object sender, SizeChangedEventArgs e) => DrawChart();
    private void DrawChart()
    {
        if (_disposed || ChartSurface is null) return;
        ChartSurface.Children.Clear(); var history = _model.History.ToArray();
        if (history.Length == 0) return;
        var metric = _model.SelectedMetric;
        var maximum = NasPerformanceViewModel.IsPercent(metric) ? 100 : Math.Max(1, history.Max(sample => sample[metric] ?? 0));
        ChartMaximum.Text = L.Format("NasPerformanceScale", NasPerformanceViewModel.Format(metric, maximum));
        ChartRange.Text = L.Format("NasPerformanceRange", history[0].RecordedAt.ToLocalTime().ToString("T"), history[^1].RecordedAt.ToLocalTime().ToString("T"), history.Length);
        AutomationProperties.SetName(ChartSurface, L.Format("NasPerformanceChartSummary", NasPerformanceViewModel.Title(metric), CurrentValue.Text, ChartRange.Text));
        var width = Math.Max(1, ChartSurface.ActualWidth); var height = ChartSurface.Height;
        var brush = (Brush)Application.Current.Resources["WorkspaceAccentBrush"];
        Polyline? line = null;
        var duration = Math.Max(1, (history[^1].RecordedAt - history[0].RecordedAt).TotalSeconds);
        foreach (var sample in history)
        {
            if (sample[metric] is not { } value) { line = null; continue; }
            if (line is null) { line = new Polyline { Stroke = brush, StrokeThickness = 2 }; ChartSurface.Children.Add(line); }
            var x = Math.Clamp((sample.RecordedAt - history[0].RecordedAt).TotalSeconds / duration, 0, 1) * width;
            var y = height - Math.Clamp(value / maximum, 0, 1) * height;
            line.Points.Add(new Point(x, y));
            if (history.Length == 1)
            { var dot = new Ellipse { Width = 5, Height = 5, Fill = brush }; Canvas.SetLeft(dot, x); Canvas.SetTop(dot, Math.Clamp(y - 2, 0, height - 5)); ChartSurface.Children.Add(dot); }
        }
    }
    public void Dispose()
    { if (_disposed) return; _disposed = true; _timer.Stop(); _model.Changed -= Update; _model.Dispose(); }
}
