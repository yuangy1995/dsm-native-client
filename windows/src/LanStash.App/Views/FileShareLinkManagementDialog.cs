using System.ComponentModel;
using LanStash.App.Features.Files.Sharing;
using LanStash.App.Localization;
using LanStash.App.Platform.Sharing;
using LanStash.Domain;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views;

internal sealed record FileShareLinkManagementDialogOptions(
    FileShareLinkManagementScope? Scope = null,
    string TitleKey = "FileShareLinkManageTitle",
    string EmptyTitleKey = "FileShareLinkManageEmptyTitle",
    string EmptyMessageKey = "FileShareLinkManageEmptyMessage",
    string CountKey = "FileShareLinkManageCount",
    string UnsupportedMessageKey = "FileShareLinkUnsupportedMessage")
{
    internal static FileShareLinkManagementDialogOptions ForPhoto(FileShareLinkManagementScope scope) =>
        new(
            scope,
            "PhotoShareLinkManageTitle",
            "PhotoShareLinkManageEmptyTitle",
            "PhotoShareLinkManageEmptyMessage",
            "PhotoShareLinkManageCount",
            "PhotoShareLinkManageUnsupportedMessage");
}

internal sealed class FileShareLinkManagementDialog : IDisposable
{
    private readonly IFileShareLinkRepository? _repository;
    private readonly Guid _profileId;
    private readonly WindowsClipboard _clipboard;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly FileShareLinkManagementDialogOptions _options;
    private FileShareLinkManagementViewModel? _model;
    private ContentDialog? _dialog;
    private Action? _stateChanged;
    private bool _disposed;

    internal FileShareLinkManagementDialog(
        IFileShareLinkRepository? repository,
        Guid profileId,
        WindowsClipboard clipboard,
        DispatcherQueue dispatcherQueue,
        FileShareLinkManagementDialogOptions? options = null)
    {
        _repository = repository?.ProfileId == profileId ? repository : null;
        _profileId = profileId;
        _clipboard = clipboard;
        _dispatcherQueue = dispatcherQueue;
        _options = options ?? new FileShareLinkManagementDialogOptions();
    }

    internal bool IsOpen => _dialog is not null;

    internal async Task ShowAsync(XamlRoot xamlRoot, Action? stateChanged = null)
    {
        ThrowIfDisposed();
        if (_dialog is not null || _repository is null)
        {
            return;
        }

        var localization = LocalizationService.Current;
        var model = new FileShareLinkManagementViewModel(_repository, _profileId, _options.Scope);
        var dialog = new ContentDialog
        {
            XamlRoot = xamlRoot,
            Title = localization.Get(_options.TitleKey),
            CloseButtonText = localization.Get("ActionClose"),
            DefaultButton = ContentDialogButton.None,
        };
        _model = model;
        _dialog = dialog;
        _stateChanged = stateChanged;
        model.PropertyChanged += ShareManagement_PropertyChanged;
        dialog.Closed += ShareManagementDialog_Closed;
        Render();
        NotifyStateChanged();

        try
        {
            var showing = dialog.ShowAsync();
            await model.LoadAsync();
            await showing;
        }
        finally
        {
            Cleanup(dialog);
        }
    }

    internal void Close()
    {
        var dialog = _dialog;
        Cleanup(dialog);
        dialog?.Hide();
    }

    private void ShareManagement_PropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        _dispatcherQueue.TryEnqueue(Render);

    private void ShareManagementDialog_Closed(ContentDialog sender, ContentDialogClosedEventArgs args) =>
        Cleanup(sender);

    private void Cleanup(ContentDialog? dialog)
    {
        if (_dialog is null || dialog is null || !ReferenceEquals(_dialog, dialog))
        {
            return;
        }

        var model = _model;
        _dialog.Closed -= ShareManagementDialog_Closed;
        _dialog = null;
        _model = null;
        if (model is not null)
        {
            model.PropertyChanged -= ShareManagement_PropertyChanged;
            model.Dispose();
        }
        NotifyStateChanged();
        _stateChanged = null;
    }

    private void Render()
    {
        if (_dialog is not { } dialog ||
            _model is not { } model)
        {
            return;
        }
        dialog.Content = BuildContent(model, LocalizationService.Current);
    }

    private FrameworkElement BuildContent(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        if (model.DeletionState is FileShareLinkDeletionState.Confirming or
            FileShareLinkDeletionState.Deleting)
        {
            return BuildDeletionConfirmation(model, localization);
        }

        var panel = new StackPanel { Spacing = 12, MinWidth = 320, MaxWidth = 680 };
        if (DeletionMessageKey(model.DeletionState) is { } messageKey)
        {
            var feedback = new TextBlock
            {
                Text = localization.Get(messageKey),
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetLiveSetting(feedback, AutomationLiveSetting.Polite);
            panel.Children.Add(feedback);
        }

        switch (model.State)
        {
            case FileShareLinkManagementState.Loading:
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
                panel.Children.Add(Message(localization.Get("FileShareLinkManageLoading")));
                break;
            case FileShareLinkManagementState.Empty:
                panel.Children.Add(Heading(localization.Get(_options.EmptyTitleKey)));
                panel.Children.Add(Message(localization.Get(_options.EmptyMessageKey)));
                panel.Children.Add(RefreshButton(model, localization));
                break;
            case FileShareLinkManagementState.Error:
                panel.Children.Add(Heading(localization.Get("FileShareLinkManageErrorTitle")));
                panel.Children.Add(Message(localization.Get("FileShareLinkManageErrorMessage")));
                panel.Children.Add(RefreshButton(model, localization));
                break;
            case FileShareLinkManagementState.Unsupported:
                panel.Children.Add(Heading(localization.Get("FileShareLinkUnsupportedTitle")));
                panel.Children.Add(Message(localization.Get(_options.UnsupportedMessageKey)));
                break;
            case FileShareLinkManagementState.Content:
                panel.Children.Add(BuildHeader(model, localization));
                foreach (var link in model.VisibleLinks)
                {
                    panel.Children.Add(BuildLinkRow(model, link, localization));
                    panel.Children.Add(new Border
                    {
                        Height = 1,
                        Background = Application.Current.Resources[
                            "CardStrokeColorDefaultBrush"] as Brush,
                    });
                }
                if (model.HasMoreLinks)
                {
                    var showMore = new Button
                    {
                        Content = localization.Get("FileShareLinkManageShowMoreAction"),
                        MinHeight = 44,
                    };
                    AutomationProperties.SetName(
                        showMore,
                        localization.Get("FileShareLinkManageShowMoreAutomationName"));
                    showMore.Click += (_, _) => model.ShowMore();
                    panel.Children.Add(showMore);
                }
                break;
        }
        return new ScrollViewer
        {
            Content = panel,
            MaxHeight = 620,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    private FrameworkElement BuildHeader(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Heading(localization.Format(_options.CountKey, model.LinkCount)));
        var refresh = RefreshButton(model, localization);
        Grid.SetColumn(refresh, 1);
        grid.Children.Add(refresh);
        return grid;
    }

    private FrameworkElement BuildLinkRow(
        FileShareLinkManagementViewModel model,
        FileShareLink link,
        LocalizationService localization)
    {
        var grid = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var details = new StackPanel { Spacing = 3 };
        details.Children.Add(new TextBlock
        {
            Text = ShareLinkDisplayName(link.Path),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        details.Children.Add(new TextBlock
        {
            Text = link.Path,
            Opacity = 0.72,
            TextWrapping = TextWrapping.Wrap,
        });
        if (link.HasPassword)
        {
            details.Children.Add(Message(localization.Get("FileShareLinkManageProtected")));
        }
        if (link.ExpiresOn is { } expiry)
        {
            details.Children.Add(Message(localization.Format(
                "FileShareLinkExpiresOn",
                expiry.ToString("d", System.Globalization.CultureInfo.CurrentCulture))));
        }
        var copyStatus = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetLiveSetting(copyStatus, AutomationLiveSetting.Polite);
        details.Children.Add(copyStatus);
        grid.Children.Add(details);

        var copy = IconButton(
            Symbol.Copy,
            localization.Get("FileShareLinkManageCopyAutomationName"),
            localization.Get("FileShareLinkCopyAction"));
        copy.Click += (_, _) => CopyManagedShareLink(link, localization, copyStatus);
        Grid.SetColumn(copy, 1);
        grid.Children.Add(copy);

        var delete = IconButton(
            Symbol.Delete,
            localization.Get("FileShareLinkManageDeleteAutomationName"),
            localization.Get("FileShareLinkManageDeleteAction"));
        delete.IsEnabled = model.DeletionState != FileShareLinkDeletionState.NeedsReview ||
            !string.Equals(model.PendingDeletion?.Id, link.Id, StringComparison.Ordinal);
        delete.Click += (_, _) => model.BeginDelete(link);
        Grid.SetColumn(delete, 2);
        grid.Children.Add(delete);
        return grid;
    }

    private FrameworkElement BuildDeletionConfirmation(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        var link = model.PendingDeletion;
        var panel = new StackPanel { Spacing = 12, MinWidth = 320, MaxWidth = 680 };
        panel.Children.Add(Heading(localization.Get("FileShareLinkManageDeleteTitle")));
        panel.Children.Add(Message(localization.Format(
            "FileShareLinkManageDeleteMessage",
            link is null ? string.Empty : ShareLinkDisplayName(link.Path))));
        if (link is not null)
        {
            panel.Children.Add(Message(link.Path));
        }
        if (model.IsDeleting)
        {
            panel.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
            panel.Children.Add(Message(localization.Get("FileShareLinkManageDeleting")));
        }
        else
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var cancel = new Button
            {
                Content = localization.Get("ActionCancel"),
                MinHeight = 44,
            };
            cancel.Click += (_, _) => model.CancelDelete();
            actions.Children.Add(cancel);
            var confirm = new Button
            {
                Content = localization.Get("FileShareLinkManageDeleteAction"),
                MinHeight = 44,
            };
            AutomationProperties.SetName(
                confirm,
                localization.Get("FileShareLinkManageConfirmDeleteAutomationName"));
            confirm.Click += async (_, _) => await model.ConfirmDeleteAsync();
            actions.Children.Add(confirm);
            panel.Children.Add(actions);
        }
        return panel;
    }

    private Button RefreshButton(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        var button = IconButton(
            Symbol.Refresh,
            localization.Get("FileShareLinkManageRefreshAutomationName"),
            localization.Get("FileShareLinkManageRefreshAction"));
        button.Click += async (_, _) => await model.LoadAsync();
        return button;
    }

    private void CopyManagedShareLink(
        FileShareLink link,
        LocalizationService localization,
        TextBlock status)
    {
        try
        {
            status.Text = _clipboard.SetUri(link.Url)
                ? localization.Get("FileShareLinkCopiedMessage")
                : localization.Get("FileShareLinkCopyFailedMessage");
        }
        catch
        {
            status.Text = localization.Get("FileShareLinkCopyFailedMessage");
        }
        status.Visibility = Visibility.Visible;
    }

    private static Button IconButton(Symbol symbol, string automationName, string tooltip)
    {
        var button = new Button
        {
            Content = new SymbolIcon(symbol),
            MinWidth = 44,
            MinHeight = 44,
        };
        AutomationProperties.SetName(button, automationName);
        ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    private static TextBlock Heading(string text)
    {
        var heading = new TextBlock
        {
            Text = text,
            Style = Application.Current.Resources["SubtitleTextBlockStyle"] as Style,
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
        return heading;
    }

    private static TextBlock Message(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
    };

    private static string ShareLinkDisplayName(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? path;

    private static string? DeletionMessageKey(FileShareLinkDeletionState state) => state switch
    {
        FileShareLinkDeletionState.Deleted => "FileShareLinkManageDeletedMessage",
        FileShareLinkDeletionState.NeedsReview => "FileShareLinkManageReviewMessage",
        FileShareLinkDeletionState.TargetChanged => "FileShareLinkManageChangedMessage",
        FileShareLinkDeletionState.PermissionDenied => "FileShareLinkManagePermissionMessage",
        FileShareLinkDeletionState.Unsupported => "FileShareLinkManageUnsupportedMessage",
        FileShareLinkDeletionState.Failure => "FileShareLinkManageFailureMessage",
        FileShareLinkDeletionState.Cancelled => "FileShareLinkManageCancelledMessage",
        _ => null,
    };

    private void NotifyStateChanged() => _stateChanged?.Invoke();

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Close();
    }
}
