using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class FileSearchDialogContent : UserControl
{
    private readonly string _folder;
    private readonly TextBox _query;
    private readonly TextBox _extension;
    private readonly TextBox _owner;
    private readonly TextBox _group;
    private readonly ComboBox _kind;
    private readonly NumberBox _minimum;
    private readonly NumberBox _maximum;
    private readonly CheckBox _recursive;
    private readonly CheckBox _contents;
    private readonly (CalendarDatePicker From, CalendarDatePicker To) _modified;
    private readonly (CalendarDatePicker From, CalendarDatePicker To) _created;
    private readonly (CalendarDatePicker From, CalendarDatePicker To) _accessed;
    private readonly InfoBar _error;

    public FileSearchDialogContent(FileSearchRequest draft)
    {
        _folder = draft.FolderPath;
        var panel = new StackPanel { Spacing = 12, MinWidth = 400, MaxWidth = 480 };
        Content = new ScrollViewer { MaxHeight = 520, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = panel };
        panel.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(_folder) ? T("FileSearchAllShares") : _folder,
            TextWrapping = TextWrapping.Wrap,
        });
        _query = Text("FileSearchQuery", draft.Query);
        _query.PlaceholderText = T("FileSearchQueryPlaceholder");
        panel.Children.Add(_query);
        _contents = new CheckBox { Content = T("FileSearchContents"), IsChecked = draft.SearchesContents };
        _recursive = new CheckBox { Content = T("FileSearchRecursive"), IsChecked = draft.Recursive };
        panel.Children.Add(_contents);
        panel.Children.Add(_recursive);
        _kind = new ComboBox { Header = T("FileSearchKind"), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var key in new[] { "FileBrowserTypeAll.Text", "FileBrowserTypeFiles.Text", "FileBrowserTypeFolders.Text" })
            _kind.Items.Add(T(key));
        _kind.SelectedIndex = (int)draft.Kind;
        panel.Children.Add(_kind);
        _extension = Text("FileSearchExtension", draft.Extension);
        panel.Children.Add(_extension);
        _minimum = Number("FileSearchMinimumBytes", draft.MinimumBytes);
        _maximum = Number("FileSearchMaximumBytes", draft.MaximumBytes);
        panel.Children.Add(Pair(_minimum, _maximum));
        _modified = Dates(panel, "FileSearchModified", draft.Modified);
        _created = Dates(panel, "FileSearchCreated", draft.Created);
        _accessed = Dates(panel, "FileSearchAccessed", draft.Accessed);
        _owner = Text("FileSearchOwner", draft.Owner);
        _group = Text("FileSearchGroup", draft.Group);
        panel.Children.Add(Pair(_owner, _group));
        _error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error, Message = T("FileSearchInvalidConditions") };
        AutomationProperties.SetLiveSetting(_error, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        panel.Children.Add(_error);
    }

    public bool TryBuildRequest(out FileSearchRequest? request)
    {
        request = null;
        try
        {
            var value = new FileSearchRequest(_folder, _query.Text, _recursive.IsChecked == true)
            {
                Kind = (FileListTypeFilter)_kind.SelectedIndex,
                Extension = _extension.Text,
                Owner = _owner.Text,
                Group = _group.Text,
                SearchesContents = _contents.IsChecked == true,
                MinimumBytes = Bytes(_minimum),
                MaximumBytes = Bytes(_maximum),
                Modified = Range(_modified),
                Created = Range(_created),
                Accessed = Range(_accessed),
            };
            value.Validate();
            if (!value.HasConditions) throw new ArgumentException("file.search.empty");
            request = value;
            _error.IsOpen = false;
            return true;
        }
        catch (Exception error) when (error is ArgumentException or OverflowException)
        {
            _error.IsOpen = true;
            _error.StartBringIntoView();
            return false;
        }
    }

    private static string T(string key) => LocalizationService.Current.Get(key);
    private static TextBox Text(string key, string value) => new() { Header = T(key), Text = value };
    private static NumberBox Number(string key, long? value) => new()
    {
        Header = T(key), Value = value ?? double.NaN, Minimum = 0,
        PlaceholderText = T("FileSearchAny"), SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden,
    };
    private static long? Bytes(NumberBox value)
    {
        if (double.IsNaN(value.Value)) return null;
        if (value.Value < 0 || value.Value != Math.Truncate(value.Value)) throw new ArgumentException("file.search.invalid-size");
        return checked((long)value.Value);
    }
    private static Grid Pair(FrameworkElement first, FrameworkElement second)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(second, 1);
        grid.Children.Add(first);
        grid.Children.Add(second);
        return grid;
    }
    private static (CalendarDatePicker From, CalendarDatePicker To) Dates(StackPanel panel, string key, FileSearchTimeRange range)
    {
        panel.Children.Add(new TextBlock { Text = T(key) });
        var from = new CalendarDatePicker { Date = range.From, PlaceholderText = T("FileSearchDateFrom"), MinDate = DateTimeOffset.UnixEpoch, HorizontalAlignment = HorizontalAlignment.Stretch };
        var to = new CalendarDatePicker { Date = range.To, PlaceholderText = T("FileSearchDateTo"), MinDate = DateTimeOffset.UnixEpoch, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(from, LocalizationService.Current.Format("FileSearchDateLabel", T(key), T("FileSearchDateFrom")));
        AutomationProperties.SetName(to, LocalizationService.Current.Format("FileSearchDateLabel", T(key), T("FileSearchDateTo")));
        panel.Children.Add(Pair(from, to));
        return (from, to);
    }
    private static FileSearchTimeRange Range((CalendarDatePicker From, CalendarDatePicker To) pickers) => new(
        pickers.From.Date is { } from ? new DateTimeOffset(from.Date, from.Offset) : null,
        pickers.To.Date is { } to ? new DateTimeOffset(to.Date.AddDays(1).AddSeconds(-1), to.Offset) : null);
}
