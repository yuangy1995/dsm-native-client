using System.ComponentModel;
using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class DownloadRecoveryContent : UserControl, IDisposable
{
    private readonly DownloadRecoveryModel _model;
    private readonly ComboBox _choices = new() { DisplayMemberPath = nameof(DownloadRecoveryRow.Title), MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ListView _items = new() { SelectionMode = ListViewSelectionMode.None, MinHeight = 120 };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _error = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly ProgressRing _progress = new() { Width = 28, Height = 28 };
    private readonly Button _review = new() { MinHeight = 44 }, _resume = new() { MinHeight = 44 }, _cancel = new() { MinHeight = 44 };
    private readonly CheckBox _confirmation = new() { MinHeight = 44 };
    private bool _rendering;
    public DownloadRecoveryContent(DownloadRecoveryModel model)
    {
        _model = model; MinWidth = 300; MaxWidth = 560; MinHeight = 360; MaxHeight = 560;
        _choices.Header = L("DownloadActionChoose"); AutomationProperties.SetName(_choices, L("DownloadActionChoose"));
        _error.Message = L("DownloadActionLoadFailed");
        var reload = new Button { Content = L("DownloadReadRetry"), MinHeight = 44 };
        reload.Click += async (_, _) => await _model.LoadAsync(); _error.ActionButton = reload;
        _review.Content = L("DownloadActionRefresh"); _resume.Content = L("DownloadBatchContinue"); _cancel.Content = L("DownloadBatchStopRemaining");
        _confirmation.Content = L("DownloadBatchConfirm");
        _review.Click += async (_, _) => await _model.ReviewAsync();
        _resume.Click += async (_, _) => { if (!_model.NeedsDangerConfirmation || _confirmation.IsChecked == true) await _model.ContinueAsync(); _confirmation.IsChecked = false; };
        _cancel.Click += async (_, _) => await _model.CancelAsync();
        _confirmation.Checked += (_, _) => Render(); _confirmation.Unchecked += (_, _) => Render();
        _choices.SelectionChanged += (_, _) => { if (!_rendering) { _confirmation.IsChecked = false; _model.Select(_choices.SelectedItem as DownloadRecoveryRow); } };
        _items.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><StackPanel Margin='4,8' Spacing='4'><TextBlock Text='{Binding Title}' TextWrapping='Wrap'/><TextBlock Text='{Binding State}' TextWrapping='Wrap'/></StackPanel></DataTemplate>");
        AutomationProperties.SetName(_items, L("DownloadBatchResults"));
        var root = new Grid { RowSpacing = 8 };
        for (var index = 0; index < 6; index++) root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        var commands = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        commands.Children.Add(_review); commands.Children.Add(_resume); commands.Children.Add(_cancel);
        FrameworkElement[] controls = [_choices, _error, _progress, _notice, _confirmation, commands, _items];
        for (var index = 0; index < controls.Length; index++) { Grid.SetRow(controls[index], index); root.Children.Add(controls[index]); }
        Grid.SetRow(_empty, 6); root.Children.Add(_empty); Content = root;
        _model.PropertyChanged += Changed; Render();
    }
    private static string L(string key) => LocalizationService.Current.Get(key);
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private void Changed(object? sender, PropertyChangedEventArgs e) => Render();
    private void Render()
    {
        if (_rendering) return; _rendering = true;
        try
        {
            _choices.ItemsSource = _model.Rows; _choices.SelectedItem = _model.Rows.FirstOrDefault(row => row.Action.Id == _model.Selected?.Id);
            _choices.IsEnabled = !_model.IsBusy; _items.ItemsSource = _model.Items;
            _progress.IsActive = _model.IsBusy; _progress.Visibility = Show(_model.IsBusy);
            _error.IsOpen = _model.HasError; _error.Visibility = Show(_model.HasError);
            _notice.Text = _model.NoticeKey is { } key ? L(key) : ""; _notice.Visibility = Show(_model.NoticeKey is not null);
            _confirmation.Visibility = Show(_model.CanContinue && _model.NeedsDangerConfirmation);
            _review.Visibility = Show(_model.Selected?.RequiresReview == true); _review.IsEnabled = _model.CanReview;
            _resume.Visibility = Show(_model.Selected?.CanContinue == true); _resume.IsEnabled = _model.CanContinue && (!_model.NeedsDangerConfirmation || _confirmation.IsChecked == true);
            _cancel.Visibility = Show(_model.Selected?.CanCancelRemaining == true); _cancel.IsEnabled = _model.CanCancel;
            _empty.Text = L("DownloadActionEmpty"); _empty.Visibility = Show(!_model.IsBusy && !_model.HasError && _model.Rows.Count == 0);
        }
        finally { _rendering = false; }
    }
    public void Dispose() => _model.PropertyChanged -= Changed;
}
