using LanStash.App.Features.Photos.Synology;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

/// <summary>控件保存服务端 ID 和范围，不用本地化标题反推筛选条件。</summary>
internal sealed class SynologyPhotoFilterDialog : ContentDialog
{
    private readonly SynologyPhotosWorkspace _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly StackPanel _fields = new() { Spacing = 12, MinWidth = 260, MaxWidth = 560 };
    private readonly InfoBar _error = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly Dictionary<string, ComboBox> _choices = [];
    private readonly CalendarDatePicker _start = new();
    private readonly CalendarDatePicker _end = new();
    private readonly ToggleSwitch _dateEnabled = new();
    private bool _closed;

    public SynologyPhotoFilter? Result { get; private set; }
    public SynologyPhotoFilterDialog(SynologyPhotosWorkspace model)
    {
        _model = model;
        Title = _l.Get("PhotosFilters"); PrimaryButtonText = _l.Get("PhotosApplyFilters");
        SecondaryButtonText = _l.Get("PhotosClearFilters"); CloseButtonText = _l.Get("PhotosCancel");
        DefaultButton = ContentDialogButton.Primary;
        var retry = new Button { Content = _l.Get("PhotosRetry") };
        retry.Click += async (_, _) => await ReloadOptionsAsync(); _error.ActionButton = retry;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(_error); content.Children.Add(_fields);
        Content = new ScrollViewer { Content = content, MaxHeight = 620, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Build(model.Filter);
        PrimaryButtonClick += OnApply;
        SecondaryButtonClick += (_, _) => Result = new();
        Closed += (_, _) => _closed = true;
        Loaded += async (_, _) => await ReloadOptionsAsync();
    }

    private async Task ReloadOptionsAsync()
    {
        if (_model.IsLoadingOptions || _closed) return;
        var draft = ReadValue(); _fields.IsEnabled = false; IsPrimaryButtonEnabled = false;
        try
        {
            await _model.LoadFilterOptionsAsync();
            if (_closed) return;
            Build(draft); _error.IsOpen = _model.OptionsErrorKey is not null;
            _error.Message = _model.OptionsErrorKey is { } key ? _l.Get(key) : "";
        }
        finally { if (!_closed) { _fields.IsEnabled = true; IsPrimaryButtonEnabled = true; } }
    }
    private void Build(SynologyPhotoFilter filter)
    {
        // 重载选项时先脱离旧日期行，避免同一控件挂到两个父节点。
        if (_start.Parent is Panel startParent) startParent.Children.Remove(_start);
        if (_end.Parent is Panel endParent) endParent.Children.Remove(_end);
        _fields.Children.Clear(); _choices.Clear();
        var options = _model.Options;
        Add("media", "PhotosFilterMedia", [new(0, _l.Get("PhotosMediaPhoto")), new(1, _l.Get("PhotosMediaVideo"))], filter.MediaType);
        _dateEnabled.Header = _l.Get("PhotosFilterDate"); _dateEnabled.IsOn = filter.StartTime is not null;
        _start.Header = _l.Get("PhotosDateFrom"); _end.Header = _l.Get("PhotosDateTo");
        _start.Date = filter.StartTime is { } start ? DateTimeOffset.FromUnixTimeSeconds(start).ToLocalTime() : DateTimeOffset.Now.AddYears(-1);
        _end.Date = filter.EndTime is { } end ? DateTimeOffset.FromUnixTimeSeconds(end).ToLocalTime() : DateTimeOffset.Now;
        _start.IsEnabled = _dateEnabled.IsOn; _end.IsEnabled = _dateEnabled.IsOn;
        _dateEnabled.Toggled -= DateEnabledChanged; _dateEnabled.Toggled += DateEnabledChanged;
        _fields.Children.Add(_dateEnabled);
        var dates = new Grid { ColumnSpacing = 8 };
        dates.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        dates.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        dates.Children.Add(_start); Grid.SetColumn(_end, 1); dates.Children.Add(_end); _fields.Children.Add(dates);
        Add("person", "PhotosFilterPerson", Choices(options.People), filter.PersonId);
        Add("location", "PhotosFilterLocation", Locations(options.Locations), filter.LocationId);
        Add("tag", "PhotosFilterTag", Choices(options.Tags), filter.TagId);
        Add("rating", "PhotosFilterRating", Enumerable.Range(0, 6).Select(value => new Option(value, _l.Format("PhotosRatingValue", value))), filter.Rating);
        Add("camera", "PhotosFilterCamera", Choices(options.Cameras), filter.CameraId);
        Add("lens", "PhotosFilterLens", Choices(options.Lenses), filter.LensId);
        Add("focal", "PhotosFilterFocal", options.FocalRanges.Select(value => new Option(value,
            _l.Format(value.End == 0 ? "PhotosFocalFrom" : "PhotosFocalRange", value.Start, value.End))), filter.FocalRange);
        Add("exposure", "PhotosFilterExposure", options.ExposureRanges.Select(value => new Option(value,
            _l.Format("PhotosExposureRange", value.Start.Num, value.Start.Den, value.End.Num, value.End.Den))), filter.ExposureRange);
        Add("aperture", "PhotosFilterAperture", Choices(options.Apertures), filter.ApertureId);
        Add("iso", "PhotosFilterIso", Choices(options.Iso), filter.IsoId);
    }
    private void DateEnabledChanged(object sender, RoutedEventArgs args)
    { _start.IsEnabled = _dateEnabled.IsOn; _end.IsEnabled = _dateEnabled.IsOn; }
    private void Add(string key, string titleKey, IEnumerable<Option> values, object? selected)
    {
        var options = values.Prepend(new(null, _l.Get("PhotosFilterAny"))).ToList();
        var current = options.FirstOrDefault(value => Equals(value.Value, selected));
        if (current is null) { current = new(selected, _l.Get("PhotosFilterSelectionUnavailable")); options.Add(current); }
        var combo = new ComboBox { Header = _l.Get(titleKey), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = options, DisplayMemberPath = nameof(Option.Title), SelectedItem = current };
        _choices.Add(key, combo); _fields.Children.Add(combo);
    }
    private static IEnumerable<Option> Choices(IReadOnlyList<SynologyPhotoChoice> values) => values.Select(value => new Option(value.Id, value.Name));
    private static IEnumerable<Option> Locations(IReadOnlyList<SynologyPhotoLocation> values, int depth = 0)
    {
        foreach (var location in values)
        {
            yield return new(location.Id, new string(' ', depth * 2) + location.Name);
            foreach (var child in Locations(location.Children, depth + 1)) yield return child;
        }
    }
    private object? Selected(string key) => (_choices[key].SelectedItem as Option)?.Value;
    private SynologyPhotoFilter ReadValue() => new()
    {
        MediaType = Selected("media") as int?, PersonId = Selected("person") as long?, LocationId = Selected("location") as long?,
        TagId = Selected("tag") as long?, Rating = Selected("rating") as int?, CameraId = Selected("camera") as long?, LensId = Selected("lens") as long?,
        FocalRange = Selected("focal") as SynologyPhotoFocalRange, ExposureRange = Selected("exposure") as SynologyPhotoExposureRange,
        ApertureId = Selected("aperture") as long?, IsoId = Selected("iso") as long?,
        StartTime = _dateEnabled.IsOn && _start.Date is { } start ? SynologyPhotosWorkspace.StartOfDay(DateOnly.FromDateTime(start.LocalDateTime)) : null,
        EndTime = _dateEnabled.IsOn && _end.Date is { } end ? SynologyPhotosWorkspace.StartOfDay(DateOnly.FromDateTime(end.LocalDateTime).AddDays(1)) - 1 : null,
    };
    private void OnApply(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var result = ReadValue();
        if (_dateEnabled.IsOn && (result.StartTime is null || result.EndTime is null || result.StartTime > result.EndTime))
        { args.Cancel = true; _error.Message = _l.Get("PhotosFilterInvalidDate"); _error.IsOpen = true; return; }
        Result = result;
    }
    private sealed record Option(object? Value, string Title);
}
