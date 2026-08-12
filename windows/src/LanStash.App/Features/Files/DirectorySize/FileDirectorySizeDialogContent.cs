using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Features.Files.DirectorySize;

internal sealed class FileDirectorySizeDialogContent : Grid
{
    private readonly FileDirectorySizeViewModel _model;
    private readonly TextBlock _status;
    private readonly ProgressRing _progress;
    private readonly StackPanel _summary;
    private readonly TextBlock _total;
    private readonly TextBlock _files;
    private readonly TextBlock _folders;
    private readonly Button _calculate;
    private readonly Button _cancel;

    internal FileDirectorySizeDialogContent(FileDirectorySizeViewModel model)
    {
        _model = model;
        var localization = LocalizationService.Current;
        MinWidth = 300;
        MaxWidth = 520;

        var content = new StackPanel { Spacing = 12 };
        Children.Add(content);

        var name = new TextBlock
        {
            Text = model.Folder.Name,
            Style = Application.Current.Resources["SubtitleTextBlockStyle"] as Style,
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetHeadingLevel(name, AutomationHeadingLevel.Level2);
        content.Children.Add(name);

        content.Children.Add(new TextBlock
        {
            Text = localization.Format(
                "FileDirectorySizeModified",
                model.Folder.ModifiedAt?.ToLocalTime().ToString("g") ??
                    localization.Get("UnknownValue")),
            Foreground = Application.Current.Resources["TextFillColorSecondaryBrush"] as
                Microsoft.UI.Xaml.Media.Brush,
            TextWrapping = TextWrapping.Wrap,
        });

        var progressRow = new Grid { ColumnSpacing = 8 };
        progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _progress = new ProgressRing { Width = 20, Height = 20, IsActive = false };
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        progressRow.Children.Add(_progress);
        Grid.SetColumn(_status, 1);
        progressRow.Children.Add(_status);
        content.Children.Add(progressRow);

        _summary = new StackPanel { Spacing = 6 };
        _total = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _files = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _folders = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _summary.Children.Add(_total);
        _summary.Children.Add(_files);
        _summary.Children.Add(_folders);
        content.Children.Add(_summary);

        var actions = new StackPanel
        {
            Orientation = Orientation.Vertical,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
        };
        _cancel = new Button
        {
            Content = localization.Get("FileDirectorySizeCancel"),
            MinHeight = 44,
            MinWidth = 96,
        };
        _cancel.Click += (_, _) => _model.Cancel();
        _calculate = new Button { MinHeight = 44, MinWidth = 120 };
        _calculate.Click += async (_, _) => await _model.CalculateAsync();
        actions.Children.Add(_cancel);
        actions.Children.Add(_calculate);
        content.Children.Add(actions);

        _model.PropertyChanged += Model_PropertyChanged;
        UpdateState();
    }

    private void Model_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private void UpdateState()
    {
        var localization = LocalizationService.Current;
        _progress.IsActive = _model.State == FileDirectorySizeState.Calculating;
        _progress.Visibility = _progress.IsActive ? Visibility.Visible : Visibility.Collapsed;
        _cancel.Visibility = _model.CanCancel ? Visibility.Visible : Visibility.Collapsed;
        _calculate.IsEnabled = _model.CanCalculate;
        _calculate.Visibility = _model.State == FileDirectorySizeState.Unsupported
            ? Visibility.Collapsed
            : Visibility.Visible;
        _calculate.Content = localization.Get(_model.State == FileDirectorySizeState.Available
            ? "FileDirectorySizeRecalculate"
            : "FileDirectorySizeCalculate");
        _status.Text = localization.Get(_model.State switch
        {
            FileDirectorySizeState.Ready => "FileDirectorySizeReady",
            FileDirectorySizeState.Calculating => "FileDirectorySizeCalculating",
            FileDirectorySizeState.Available => "FileDirectorySizeAvailable",
            FileDirectorySizeState.Error => "FileDirectorySizeFailure",
            FileDirectorySizeState.Unsupported => "FileDirectorySizeUnavailable",
            FileDirectorySizeState.Cancelled => "FileDirectorySizeCancelled",
            _ => "FileDirectorySizeFailure",
        });
        AutomationProperties.SetName(_status, _status.Text);

        _summary.Visibility = _model.Summary is null ? Visibility.Collapsed : Visibility.Visible;
        if (_model.Summary is { } summary)
        {
            _total.Text = localization.Format(
                "FileDirectorySizeTotal",
                FormatBytes(summary.TotalBytes));
            _files.Text = localization.Format("FileDirectorySizeFileCount", summary.FileCount);
            _folders.Text = localization.Format(
                "FileDirectorySizeFolderCount",
                summary.DirectoryCount);
        }
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB", "PB"];
        var value = (double)Math.Max(bytes, 0);
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }
        return string.Format(
            System.Globalization.CultureInfo.CurrentCulture,
            index == 0 ? "{0:0} {1}" : "{0:0.#} {1}",
            value,
            units[index]);
    }

    internal void Detach() => _model.PropertyChanged -= Model_PropertyChanged;
}
