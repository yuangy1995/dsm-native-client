using System.Globalization;
using System.Text.Json;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

/// <summary>原生条件表单；只改动用户编辑的字段，其余旧规则按原值保留。</summary>
internal sealed class SynologyPhotoConditionEditor : StackPanel
{
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly ISynologyPhotosRepository _repository;
    private readonly Func<bool> _current;
    private readonly Func<Exception, string> _error;
    private readonly CancellationToken _token;
    private readonly Dictionary<string, JsonElement> _fields;
    private readonly Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>> _names;
    private readonly StackPanel _selected = new() { Spacing = 6 };
    private readonly ComboBox _field = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _policy = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _search = new();
    private readonly ListView _options = new() { MaxHeight = 150, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _message = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _find, _add;
    private readonly SynologyPhotoConditionField[] _choices = Enum.GetValues<SynologyPhotoConditionField>().Where(value => value != SynologyPhotoConditionField.Flash).ToArray();
    private IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>> _suggestions = new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>();
    private SynologyPhotoSpace _space;
    private bool _rendering;
    private int _request;
    private Action? _resetFolders;
    internal bool Busy { get; private set; }
    internal int EditVersion { get; private set; }
    internal event Action? Changed;
    private sealed record Option(string Title, JsonElement Value) { public override string ToString() => Title; }
    internal SynologyPhotoConditionEditor(ISynologyPhotosRepository repository, SynologyPhotoCondition condition, IReadOnlyList<SynologyPhotoSpace> spaces,
        Func<bool> current, Func<Exception, string> error, CancellationToken token)
    {
        _repository = repository; _current = current; _error = error; _token = token; _space = condition.Space;
        _fields = condition.Fields.ToDictionary(pair => pair.Key, pair => pair.Value.Clone()); _names = condition.Names.ToDictionary(pair => pair.Key, pair => pair.Value);
        Spacing = 12; HorizontalAlignment = HorizontalAlignment.Stretch;
        var sources = spaces.Contains(_space) ? spaces.ToArray() : new[] { _space }.Concat(spaces).ToArray();
        var source = new ComboBox { Header = _l.Get("PhotosChooseSource"), ItemsSource = sources.Select(value => _l.Get(value == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared")).ToArray(),
            SelectedIndex = Array.IndexOf(sources, _space), HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = sources.Length > 1 ? Visibility.Visible : Visibility.Collapsed };
        var known = Enum.GetValues<SynologyPhotoConditionField>().Select(SynologyPhotoCondition.Key).Concat(["user_id", "folder_filter", "item_type", "time", "rating", "keyword_policy", "person_policy", "concept_policy", "general_tag_policy"]).ToHashSet();
        var preserved = _fields.Keys.Any(key => !known.Contains(key)) || Values("time").Length > 1;
        source.IsEnabled = !preserved; Children.Add(source);
        if (preserved) Children.Add(new TextBlock { Text = _l.Get("PhotosConditionPreserved"), TextWrapping = TextWrapping.Wrap });
        var media = new ComboBox { Header = _l.Get("PhotosFilterMedia"), ItemsSource = new[] { _l.Get("PhotosFilterAny"), _l.Get("PhotosMediaPhoto"), _l.Get("PhotosMediaVideo") },
            SelectedIndex = Values("item_type") is { Length: 1 } types ? types[0].GetInt64() == -1 ? 1 : 2 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        media.SelectionChanged += (_, _) => SetValues("item_type", media.SelectedIndex == 0 ? [] : [JsonSerializer.SerializeToElement(media.SelectedIndex == 1 ? -1 : -2)]); Children.Add(media);
        var datePanel = new StackPanel { Spacing = 8 }; var times = Values("time");
        foreach (var (key, title) in new[] { ("start_time", "PhotosDateFrom"), ("end_time", "PhotosDateTo") })
        {
            var time = times.Length > 0 && times[0].TryGetProperty(key, out var timestamp) ? timestamp.GetInt64() : (long?)null;
            var enabled = new CheckBox { Content = _l.Get(title), IsChecked = time is not null };
            var picker = new CalendarDatePicker { Date = time is { } seconds ? DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime() : null,
                PlaceholderText = _l.Get(title), IsEnabled = enabled.IsChecked == true, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(picker, _l.Get(title));
            void Change()
            {
                picker.IsEnabled = enabled.IsChecked == true;
                var currentTimes = Values("time"); var first = currentTimes.Length > 0 ? currentTimes[0].EnumerateObject().ToDictionary(pair => pair.Name, pair => pair.Value.Clone()) : new Dictionary<string, JsonElement>();
                if (enabled.IsChecked == true && picker.Date is { } date)
                {
                    var local = DateTime.SpecifyKind(date.Date.AddDays(key == "end_time" ? 1 : 0), DateTimeKind.Unspecified);
                    var seconds = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds() - (key == "end_time" ? 1 : 0);
                    first[key] = JsonSerializer.SerializeToElement(seconds);
                }
                else first.Remove(key);
                var rest = currentTimes.Skip(1); SetValues("time", first.Count == 0 ? rest.ToArray() : new[] { JsonSerializer.SerializeToElement(first) }.Concat(rest).ToArray());
            }
            enabled.Checked += (_, _) => { if (picker.Date is null) picker.Date = DateTimeOffset.Now; Change(); }; enabled.Unchecked += (_, _) => Change();
            picker.DateChanged += (_, _) => Change(); datePanel.Children.Add(enabled); datePanel.Children.Add(picker);
        }
        Children.Add(Section("PhotosFilterDate", datePanel));
        var ratings = new StackPanel { Spacing = 4 }; var ratingValues = Values("rating").Select(value => value.GetInt64()).ToHashSet();
        for (var rating = 0; rating <= 5; rating++)
        {
            var number = rating; var box = new CheckBox { Content = number == 0 ? _l.Get("PhotosNoRating") : _l.Format("PhotosRatingValue", number), IsChecked = ratingValues.Contains(number) };
            void Change() { if (box.IsChecked == true) ratingValues.Add(number); else ratingValues.Remove(number); SetValues("rating", ratingValues.Select(value => JsonSerializer.SerializeToElement(value)).ToArray()); }
            box.Checked += (_, _) => Change(); box.Unchecked += (_, _) => Change(); ratings.Children.Add(box);
        }
        Children.Add(Section("PhotosFilterRating", ratings)); Children.Add(Folders());
        _field.Header = _l.Get("PhotosConditionField"); _field.ItemsSource = _choices.Select(Title).ToArray(); _field.SelectedIndex = 0;
        _policy.Header = _l.Get("PhotosConditionMatch"); _policy.ItemsSource = new[] { _l.Get("PhotosConditionAny"), _l.Get("PhotosConditionAll") };
        _search.Header = _l.Get("PhotosConditionSearch"); _find = Button("PhotosConditionFind"); _add = Button("PhotosConditionAdd");
        AutomationProperties.SetName(_options, _l.Get("PhotosConditionSuggestions"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; buttons.Children.Add(_find); buttons.Children.Add(_add);
        foreach (var child in new FrameworkElement[] { _field, _policy, _search, buttons, _options, _message, _selected }) Children.Add(child);
        _field.SelectionChanged += (_, _) => Render(); _options.SelectionChanged += (_, _) => RenderButtons(); _search.TextChanged += (_, _) => { _request++; _suggestions = new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>(); Render(); };
        _policy.SelectionChanged += (_, _) => { if (!_rendering) { _fields[Key + "_policy"] = JsonSerializer.SerializeToElement(_policy.SelectedIndex == 1 ? "and" : "or"); EditChanged(); } };
        _find.Click += async (_, _) => await Find(); _add.Click += (_, _) => Add();
        source.SelectionChanged += (_, _) =>
        {
            _space = sources[source.SelectedIndex]; _fields.Remove("user_id");
            foreach (var field in _choices.Where(value => value != SynologyPhotoConditionField.Keyword).Select(SynologyPhotoCondition.Key).Concat(["folder_filter", "flash"]))
            { _fields.Remove(field); _fields.Remove(field + "_policy"); _names.Remove(field); }
            _suggestions = new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>(); _request++; _resetFolders?.Invoke(); EditChanged(); Render();
        };
        Render();
    }
    internal SynologyPhotoCondition Build() => new(_space, _fields, _names);
    internal bool Valid => Values("time").All(value =>
    {
        var start = value.TryGetProperty("start_time", out var from) ? from.GetInt64() : (long?)null;
        var end = value.TryGetProperty("end_time", out var to) ? to.GetInt64() : (long?)null;
        return (start is not null || end is not null) && !(start < 0 || end < 0 || start > end);
    });
    private string Key => SynologyPhotoCondition.Key(_choices[_field.SelectedIndex]);
    private JsonElement[] Values(string key) => _fields.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().ToArray() : [];
    private void SetValues(string key, JsonElement[] values)
    {
        if (values.Length == 0 && key != "item_type") { _fields.Remove(key); _fields.Remove(key + "_policy"); }
        else _fields[key] = JsonSerializer.SerializeToElement(values);
        EditChanged(); if (_find is not null) Render();
    }
    private void EditChanged() { EditVersion++; Changed?.Invoke(); }
    private Button Button(string key) => new() { Content = _l.Get(key) };
    private Expander Section(string key, UIElement content) => new() { Header = _l.Get(key), Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private string Title(SynologyPhotoConditionField field) => _l.Get(field switch
    {
        SynologyPhotoConditionField.Keyword => "PhotosConditionKeyword", SynologyPhotoConditionField.Person => "PhotosFilterPerson", SynologyPhotoConditionField.Concept => "PhotosCategorySubjects",
        SynologyPhotoConditionField.GeneralTag => "PhotosFilterTag", SynologyPhotoConditionField.Camera => "PhotosFilterCamera", SynologyPhotoConditionField.Lens => "PhotosFilterLens",
        SynologyPhotoConditionField.Aperture => "PhotosFilterAperture", SynologyPhotoConditionField.Iso => "PhotosFilterIso", SynologyPhotoConditionField.Geocoding => "PhotosFilterLocation",
        SynologyPhotoConditionField.FocalLength => "PhotosFilterFocal", SynologyPhotoConditionField.ExposureTime => "PhotosFilterExposure", _ => "PhotosConditionFlash",
    });
    private string ValueTitle(string key, JsonElement value)
    {
        var named = _names.GetValueOrDefault(key)?.FirstOrDefault(option => JsonElement.DeepEquals(value, option.Value))?.Name;
        if (!string.IsNullOrWhiteSpace(named)) return named;
        if (key == "keyword") return value.GetString() ?? "";
        if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty("start", out var start) && value.TryGetProperty("end", out var end))
        {
            string Display(JsonElement part) => part.ValueKind == JsonValueKind.Number ? part.GetDouble().ToString("G", CultureInfo.CurrentCulture) : part.ValueKind == JsonValueKind.String ? part.GetString()! : _l.Get("PhotosFilterAny");
            return _l.Format(key == "focal_length_group" ? "PhotosFocalRange" : "PhotosConditionExposureRange", Display(start), Display(end));
        }
        return value.TryGetInt64(out var id) ? _l.Format("PhotosConditionSavedItem", id) : _l.Get("PhotosConditionSavedRule");
    }
    private void RenderButtons()
    {
        _add.IsEnabled = !Busy && (Key == "keyword" ? !string.IsNullOrWhiteSpace(_search.Text) : _options.SelectedItem is Option);
        _find.IsEnabled = !Busy; _find.Visibility = Key == "keyword" ? Visibility.Collapsed : Visibility.Visible;
    }
    private void Render()
    {
        if (!_current()) return; _rendering = true;
        var field = _choices[_field.SelectedIndex]; _policy.Visibility = SynologyPhotoCondition.HasPolicy(field) ? Visibility.Visible : Visibility.Collapsed;
        _policy.SelectedIndex = _fields.TryGetValue(Key + "_policy", out var policy) && policy.GetString() == "and" ? 1 : 0;
        _options.ItemsSource = (_suggestions.GetValueOrDefault(Key) ?? []).Select(value => new Option(string.IsNullOrWhiteSpace(value.Name) ? ValueTitle(Key, value.Value) : value.Name, value.Value)).ToArray();
        _options.Visibility = Key == "keyword" ? Visibility.Collapsed : Visibility.Visible; _selected.Children.Clear();
        foreach (var item in Enum.GetValues<SynologyPhotoConditionField>().Select(value => (Key: SynologyPhotoCondition.Key(value), Title: Title(value))).Prepend((Key: "folder_filter", Title: _l.Get("PhotosLibraryFolders"))))
        {
            foreach (var value in Values(item.Key))
            {
                var row = new Grid { ColumnSpacing = 8 }; row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var title = new TextBlock { Text = _l.Format("PhotosConditionSelected", item.Title, item.Key == "flash" ? _l.Get("PhotosConditionSavedRule") : ValueTitle(item.Key, value)), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                var remove = Button("PhotosConditionRemove"); AutomationProperties.SetName(remove, _l.Format("PhotosConditionRemoveItem", title.Text));
                remove.Click += (_, _) => SetValues(item.Key, Values(item.Key).Where(current => !JsonElement.DeepEquals(current, value)).ToArray());
                row.Children.Add(title); Grid.SetColumn(remove, 1); row.Children.Add(remove); _selected.Children.Add(row);
            }
        }
        _rendering = false; RenderButtons();
    }
    private async Task Find()
    {
        if (Busy || !_current()) return; Busy = true; Changed?.Invoke(); RenderButtons(); var request = ++_request; var space = _space;
        _message.Text = _l.Get("PhotosLoadingDescription");
        try
        {
            var values = await _repository.ConditionSuggestionsAsync(space, _search.Text, _token);
            if (!_current() || request != _request || space != _space) return;
            _suggestions = values; _message.Text = values.GetValueOrDefault(Key)?.Count > 0 ? "" : _l.Get("PhotosConditionNoSuggestions");
        }
        catch (Exception error) { if (_current() && request == _request) _message.Text = _error(error); }
        finally { Busy = false; if (_current()) { Render(); Changed?.Invoke(); } }
    }
    private void Add()
    {
        if (!_add.IsEnabled) return; var key = Key;
        var value = key == "keyword" ? JsonSerializer.SerializeToElement(_search.Text) : ((Option)_options.SelectedItem).Value;
        if (!Values(key).Any(existing => JsonElement.DeepEquals(existing, value)))
        {
            if (key != "keyword" && _options.SelectedItem is Option option) _names[key] = (_names.GetValueOrDefault(key) ?? []).Append(new(option.Title, value)).ToArray();
            if (SynologyPhotoCondition.HasPolicy(_choices[_field.SelectedIndex])) _fields[key + "_policy"] = JsonSerializer.SerializeToElement(_policy.SelectedIndex == 1 ? "and" : "or");
            SetValues(key, [.. Values(key), value]);
        }
    }
    private Expander Folders()
    {
        var panel = new StackPanel { Spacing = 8 }; var list = new ListView { DisplayMemberPath = nameof(SynologyPhotoCollection.Name), SelectionMode = ListViewSelectionMode.Single, MaxHeight = 150 };
        AutomationProperties.SetName(list, _l.Get("PhotosLibraryFolders")); var location = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var open = Button("PhotosOpenFolder"); var back = Button("PhotosBack"); var choose = Button("PhotosConditionUseFolder"); var more = Button("PhotosLoadOlder"); var refresh = Button("PhotosRefresh");
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; actions.Children.Add(back); actions.Children.Add(open); actions.Children.Add(refresh);
        foreach (var child in new FrameworkElement[] { location, actions, list, more, choose, message }) panel.Children.Add(child);
        var history = new List<SynologyPhotoFolder>(); var rows = new List<SynologyPhotoCollection>(); var hasMore = false; SynologyPhotoSpace? loadedSpace = null; var busy = false;
        void RenderFolder() { back.IsEnabled = !busy && history.Count > 1; open.IsEnabled = !busy && list.SelectedItem is not null; choose.IsEnabled = !busy && history.Count > 0 && loadedSpace == _space; more.Visibility = hasMore ? Visibility.Visible : Visibility.Collapsed; more.IsEnabled = refresh.IsEnabled = list.IsEnabled = !busy; }
        _resetFolders = () => { rows.Clear(); history.Clear(); loadedSpace = null; hasMore = false; list.ItemsSource = Array.Empty<SynologyPhotoCollection>(); location.Text = message.Text = ""; RenderFolder(); };
        async Task Load(long? id, bool append = false, bool previous = false)
        {
            if (busy || !_current()) return; busy = true; RenderFolder(); var space = _space; message.Text = _l.Get("PhotosLoadingDescription");
            try
            {
                var folder = await _repository.FolderAsync(id, space, _token);
                var page = await _repository.FoldersAsync(folder.Id, append ? rows.Count : 0, 100, _token, space);
                var seen = append ? rows.Select(value => value.Id).ToHashSet() : [];
                if (page.Count > 100 || page.Any(value => value.Space != space || value.ParentId != folder.Id || !seen.Add(value.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                if (!_current() || space != _space) return;
                if (!append) { rows.Clear(); if (id is null || loadedSpace != space) history.Clear(); else if (previous) history.RemoveAt(history.Count - 1); if (history.Count == 0 || history[^1].Id != folder.Id) history.Add(folder); }
                loadedSpace = space; rows.AddRange(page); hasMore = page.Count == 100; list.ItemsSource = rows.ToArray(); location.Text = folder.Name;
                message.Text = rows.Count == 0 ? _l.Get("PhotosFileFolderEmpty") : "";
            }
            catch (Exception error) { if (_current() && space == _space) message.Text = _error(error); }
            finally { busy = false; if (_current()) RenderFolder(); }
        }
        list.SelectionChanged += (_, _) => RenderFolder(); open.Click += async (_, _) => { if (list.SelectedItem is SynologyPhotoCollection folder) await Load(folder.Id); };
        back.Click += async (_, _) => { if (history.Count > 1) await Load(history[^2].Id, previous: true); };
        more.Click += async (_, _) => { if (history.Count > 0) await Load(history[^1].Id, append: true); };
        refresh.Click += async (_, _) => await Load(loadedSpace == _space ? history.LastOrDefault()?.Id : null);
        choose.Click += (_, _) =>
        {
            if (loadedSpace != _space || history.LastOrDefault() is not { } folder) return;
            var value = JsonSerializer.SerializeToElement(folder.Id);
            if (!Values("folder_filter").Any(item => JsonElement.DeepEquals(item, value)))
            { _names["folder_filter"] = (_names.GetValueOrDefault("folder_filter") ?? []).Append(new(folder.Name, value)).ToArray(); SetValues("folder_filter", [.. Values("folder_filter"), value]); }
        };
        var expander = Section("PhotosLibraryFolders", panel); expander.Expanding += async (_, _) => { if (loadedSpace != _space) await Load(null); }; RenderFolder(); return expander;
    }
}
