using System.ComponentModel;
using LanStash.App.Features.Files.Sharing;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private FileShareLinkManagementViewModel? _shareManagementModel;
    private ContentDialog? _shareManagementDialog;

    private async void ManageShareLinks_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _shareRepository is null || _shareManagementDialog is not null ||
            _shareLinkDialog is not null)
        {
            return;
        }

        var localization = LocalizationService.Current;
        var model = new FileShareLinkManagementViewModel(_shareRepository, _profileId);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("FileShareLinkManageTitle"),
            CloseButtonText = localization.Get("ActionClose"),
            DefaultButton = ContentDialogButton.None,
        };
        _shareManagementModel = model;
        _shareManagementDialog = dialog;
        model.PropertyChanged += ShareManagement_PropertyChanged;
        dialog.Closed += ShareManagementDialog_Closed;
        RenderShareManagement();
        UpdateState();

        var showing = dialog.ShowAsync();
        await model.LoadAsync();
        await showing;
    }

    private void ShareManagement_PropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(RenderShareManagement);

    private void ShareManagementDialog_Closed(ContentDialog sender, ContentDialogClosedEventArgs args)
    {
        if (_shareManagementDialog != sender)
        {
            return;
        }
        var model = _shareManagementModel;
        _shareManagementDialog = null;
        _shareManagementModel = null;
        sender.Closed -= ShareManagementDialog_Closed;
        if (model is not null)
        {
            model.PropertyChanged -= ShareManagement_PropertyChanged;
            model.Dispose();
        }
        UpdateState();
    }

    private void CloseShareManagementDialog()
    {
        var dialog = _shareManagementDialog;
        var model = _shareManagementModel;
        _shareManagementDialog = null;
        _shareManagementModel = null;
        if (dialog is not null)
        {
            dialog.Closed -= ShareManagementDialog_Closed;
        }
        if (model is not null)
        {
            model.PropertyChanged -= ShareManagement_PropertyChanged;
            model.Dispose();
        }
        dialog?.Hide();
    }

    private void RenderShareManagement()
    {
        if (_shareManagementDialog is not { } dialog ||
            _shareManagementModel is not { } model)
        {
            return;
        }
        dialog.Content = BuildShareManagementContent(model, LocalizationService.Current);
    }

    private FrameworkElement BuildShareManagementContent(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        if (model.DeletionState is FileShareLinkDeletionState.Confirming or
            FileShareLinkDeletionState.Deleting)
        {
            return BuildShareDeletionConfirmation(model, localization);
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
                panel.Children.Add(Heading(localization.Get("FileShareLinkManageEmptyTitle")));
                panel.Children.Add(Message(localization.Get("FileShareLinkManageEmptyMessage")));
                panel.Children.Add(ShareManagementRefreshButton(model, localization));
                break;
            case FileShareLinkManagementState.Error:
                panel.Children.Add(Heading(localization.Get("FileShareLinkManageErrorTitle")));
                panel.Children.Add(Message(localization.Get("FileShareLinkManageErrorMessage")));
                panel.Children.Add(ShareManagementRefreshButton(model, localization));
                break;
            case FileShareLinkManagementState.Unsupported:
                panel.Children.Add(Heading(localization.Get("FileShareLinkUnsupportedTitle")));
                panel.Children.Add(Message(localization.Get("FileShareLinkUnsupportedMessage")));
                break;
            case FileShareLinkManagementState.Content:
                panel.Children.Add(BuildShareManagementHeader(model, localization));
                foreach (var link in model.VisibleLinks)
                {
                    panel.Children.Add(BuildShareLinkRow(model, link, localization));
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

    private FrameworkElement BuildShareManagementHeader(
        FileShareLinkManagementViewModel model,
        LocalizationService localization)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Heading(localization.Format("FileShareLinkManageCount", model.LinkCount)));
        var refresh = ShareManagementRefreshButton(model, localization);
        Grid.SetColumn(refresh, 1);
        grid.Children.Add(refresh);
        return grid;
    }

    private FrameworkElement BuildShareLinkRow(
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

    private FrameworkElement BuildShareDeletionConfirmation(
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

    private Button ShareManagementRefreshButton(
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

    private static TextBlock Heading(string text) => new()
    {
        Text = text,
        Style = Application.Current.Resources["SubtitleTextBlockStyle"] as Style,
        TextWrapping = TextWrapping.Wrap,
    };

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
}
