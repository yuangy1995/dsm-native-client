using LanStash.App.Features.Files.Sharing;
using LanStash.App.Localization;
using LanStash.App.Platform.Sharing;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Features.Photos;

internal sealed class PhotoShareLinkDialog
{
    private readonly IFileShareLinkRepository? _repository;
    private readonly Guid _profileId;
    private readonly FileShareLinkReviewBlocker _reviewBlocker;
    private readonly WindowsClipboard _clipboard = new();
    private FileShareLinkViewModel? _model;
    private ContentDialog? _dialog;
    private bool _isClosing;

    internal PhotoShareLinkDialog(
        IFileShareLinkRepository? repository,
        Guid profileId,
        FileShareLinkReviewBlocker reviewBlocker)
    {
        _repository = repository?.ProfileId == profileId ? repository : null;
        _profileId = profileId;
        _reviewBlocker = reviewBlocker;
    }

    internal bool IsOpen => _dialog is not null;
    internal bool IsClosing => _isClosing;

    internal async Task ShowAsync(XamlRoot xamlRoot, FileShareLinkTarget target, Action stateChanged)
    {
        if (_dialog is not null || _isClosing || target.ProfileId != _profileId)
        {
            return;
        }

        var localization = LocalizationService.Current;
        if (_repository is null)
        {
            await new ContentDialog
            {
                XamlRoot = xamlRoot,
                Title = localization.Get("FileShareLinkUnsupportedTitle"),
                Content = localization.Get("FileShareLinkUnsupportedMessage"),
                CloseButtonText = localization.Get("ActionClose"),
                DefaultButton = ContentDialogButton.Close,
            }.ShowAsync();
            return;
        }

        _model = new FileShareLinkViewModel(
            _repository,
            _profileId,
            target,
            initialNeedsReview: _reviewBlocker.Contains(_profileId, target.Path));
        var dialog = new ContentDialog
        {
            XamlRoot = xamlRoot,
            CloseButtonText = localization.Get("ActionClose"),
            DefaultButton = ContentDialogButton.None,
        };
        _dialog = dialog;

        void Render()
        {
            if (_model is not { } model || _dialog != dialog)
            {
                return;
            }
            dialog.Title = Title(model.State, localization);
            dialog.Content = BuildContent(model, localization, Render);
        }

        dialog.Closing += (_, args) =>
        {
            if (_isClosing || _dialog != dialog ||
                _model?.State != FileShareLinkPresentationState.Creating)
            {
                return;
            }
            args.Cancel = true;
            _model.RequestCancellation();
            Render();
        };

        Render();
        stateChanged();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            _model?.Dispose();
            _model = null;
            if (ReferenceEquals(_dialog, dialog))
            {
                _dialog = null;
            }
            _isClosing = false;
            stateChanged();
        }
    }

    internal void Close()
    {
        var dialog = _dialog;
        var model = _model;
        _dialog = null;
        _model = null;
        if (model?.State == FileShareLinkPresentationState.Creating)
        {
            _reviewBlocker.Block(_profileId, model.TargetPath);
        }
        model?.RequestCancellation();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosing = true;
        dialog.Hide();
    }

    private FrameworkElement BuildContent(
        FileShareLinkViewModel model,
        LocalizationService localization,
        Action render)
    {
        var panel = new StackPanel
        {
            Width = 440,
            MaxWidth = 440,
            Spacing = 12,
        };
        var target = new TextBlock
        {
            Text = localization.Format("FileShareLinkTarget", model.TargetName),
            TextWrapping = TextWrapping.Wrap,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(target, AutomationHeadingLevel.Level2);
        panel.Children.Add(target);

        if (model.State == FileShareLinkPresentationState.Form)
        {
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get("FileShareLinkAccessNote"),
                TextWrapping = TextWrapping.Wrap,
            });
            var create = new Button
            {
                Content = localization.Get("FileShareLinkCreateAction"),
                IsEnabled = model.CanCreate,
                MinHeight = 44,
                HorizontalAlignment = HorizontalAlignment.Right,
                AccessKey = "C",
            };
            var passwordError = new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Error,
                Message = localization.Get("FileShareLinkPasswordError"),
                Visibility = model.HasPasswordError ? Visibility.Visible : Visibility.Collapsed,
            };
            AutomationProperties.SetLiveSetting(passwordError, AutomationLiveSetting.Assertive);
            var password = new PasswordBox
            {
                Header = localization.Get("FileShareLinkPasswordLabel"),
                Password = model.Password,
                MinHeight = 44,
            };
            AutomationProperties.SetHelpText(password, localization.Get("FileShareLinkPasswordHelp"));
            password.PasswordChanged += (_, _) =>
            {
                model.Password = password.Password;
                passwordError.Visibility = model.HasPasswordError
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                create.IsEnabled = model.CanCreate;
            };
            panel.Children.Add(password);
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get("FileShareLinkPasswordHelp"),
                TextWrapping = TextWrapping.Wrap,
                Style = Application.Current.Resources["CaptionTextBlockStyle"] as Style,
            });
            panel.Children.Add(passwordError);

            var expiration = new ComboBox
            {
                Header = localization.Get("FileShareLinkExpirationLabel"),
                MinHeight = 44,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            AddExpiration(expiration, localization.Get("FileShareLinkExpirationNever"), FileShareLinkExpiration.Never);
            AddExpiration(expiration, localization.Get("FileShareLinkExpiration7Days"), FileShareLinkExpiration.SevenDays);
            AddExpiration(expiration, localization.Get("FileShareLinkExpiration30Days"), FileShareLinkExpiration.ThirtyDays);
            AddExpiration(expiration, localization.Get("FileShareLinkExpiration90Days"), FileShareLinkExpiration.NinetyDays);
            expiration.SelectedIndex = (int)model.Expiration;
            expiration.SelectionChanged += (_, _) =>
            {
                if (expiration.SelectedItem is ComboBoxItem { Tag: FileShareLinkExpiration value })
                {
                    model.Expiration = value;
                }
            };
            panel.Children.Add(expiration);

            create.Click += async (_, _) =>
            {
                var creation = model.CreateAsync();
                render();
                await creation;
                if (model.State == FileShareLinkPresentationState.NeedsReview)
                {
                    _reviewBlocker.Block(_profileId, model.TargetPath);
                }
                render();
            };
            panel.Children.Add(create);
            return Scrollable(panel);
        }

        if (model.State == FileShareLinkPresentationState.Creating)
        {
            panel.Children.Add(new ProgressRing
            {
                IsActive = true,
                Width = 32,
                Height = 32,
                HorizontalAlignment = HorizontalAlignment.Left,
            });
            var message = new TextBlock
            {
                Text = localization.Get(model.IsCancellationRequested
                    ? "FileShareLinkCancellingMessage"
                    : "FileShareLinkCreatingMessage"),
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Polite);
            panel.Children.Add(message);
            var cancel = new Button
            {
                Content = localization.Get("ActionCancel"),
                MinHeight = 44,
                IsEnabled = !model.IsCancellationRequested,
            };
            cancel.Click += (_, _) =>
            {
                model.RequestCancellation();
                render();
            };
            panel.Children.Add(cancel);
            return Scrollable(panel);
        }

        var status = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State == FileShareLinkPresentationState.Success
                ? InfoBarSeverity.Success
                : model.State == FileShareLinkPresentationState.NeedsReview
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Error,
            Message = Message(model.State, localization),
        };
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        panel.Children.Add(status);

        if (model.State == FileShareLinkPresentationState.Success && model.ConfirmedUrl is { } url)
        {
            var confirmedUrl = new TextBox
            {
                Text = url.AbsoluteUri,
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 44,
            };
            AutomationProperties.SetName(
                confirmedUrl,
                localization.Get("FileShareLinkConfirmedUrlAutomationName"));
            panel.Children.Add(confirmedUrl);
            if (model.ConfirmedLink?.HasPassword == true)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Get("FileShareLinkProtectedNote"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            if (model.ConfirmedLink?.ExpiresOn is { } expiresOn)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Format(
                        "FileShareLinkExpiresOn",
                        expiresOn.ToString("d", System.Globalization.CultureInfo.CurrentCulture)),
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            var copyStatus = new TextBlock { Visibility = Visibility.Collapsed };
            AutomationProperties.SetLiveSetting(copyStatus, AutomationLiveSetting.Polite);
            var copy = new Button
            {
                Content = localization.Get("FileShareLinkCopyAction"),
                MinHeight = 44,
                AccessKey = "C",
            };
            copy.Click += (_, _) =>
            {
                if (model.ConfirmedUrl is not { } confirmed)
                {
                    return;
                }
                try
                {
                    copyStatus.Text = _clipboard.SetUri(confirmed)
                        ? localization.Get("FileShareLinkCopiedMessage")
                        : localization.Get("FileShareLinkCopyFailedMessage");
                }
                catch
                {
                    copyStatus.Text = localization.Get("FileShareLinkCopyFailedMessage");
                }
                copyStatus.Visibility = Visibility.Visible;
            };
            panel.Children.Add(copy);
            panel.Children.Add(copyStatus);
        }
        else if (model.CanRetry || model.State == FileShareLinkPresentationState.Cancelled)
        {
            var retry = new Button
            {
                Content = localization.Get("FileShareLinkTryAgainAction"),
                MinHeight = 44,
            };
            retry.Click += (_, _) =>
            {
                model.Retry();
                render();
            };
            panel.Children.Add(retry);
        }

        return Scrollable(panel);
    }

    private static ScrollViewer Scrollable(FrameworkElement content) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        MaxHeight = 600,
    };

    private static void AddExpiration(
        ComboBox comboBox,
        string text,
        FileShareLinkExpiration expiration) =>
        comboBox.Items.Add(new ComboBoxItem { Content = text, Tag = expiration, MinHeight = 44 });

    private static string Title(
        FileShareLinkPresentationState state,
        LocalizationService localization) => state switch
    {
        FileShareLinkPresentationState.Success => localization.Get("FileShareLinkSuccessTitle"),
        FileShareLinkPresentationState.NeedsReview => localization.Get("FileShareLinkReviewTitle"),
        FileShareLinkPresentationState.TargetChanged => localization.Get("FileShareLinkChangedTitle"),
        FileShareLinkPresentationState.PermissionDenied => localization.Get("FileShareLinkPermissionTitle"),
        FileShareLinkPresentationState.Unsupported => localization.Get("FileShareLinkUnsupportedTitle"),
        FileShareLinkPresentationState.Failure => localization.Get("FileShareLinkFailureTitle"),
        FileShareLinkPresentationState.Cancelled => localization.Get("FileShareLinkCancelledTitle"),
        _ => localization.Get("FileShareLinkTitle"),
    };

    private static string Message(
        FileShareLinkPresentationState state,
        LocalizationService localization) => localization.Get(state switch
    {
        FileShareLinkPresentationState.Success => "FileShareLinkSuccessMessage",
        FileShareLinkPresentationState.NeedsReview => "FileShareLinkReviewMessage",
        FileShareLinkPresentationState.TargetChanged => "FileShareLinkChangedMessage",
        FileShareLinkPresentationState.PermissionDenied => "FileShareLinkPermissionMessage",
        FileShareLinkPresentationState.Unsupported => "FileShareLinkUnsupportedMessage",
        FileShareLinkPresentationState.Cancelled => "FileShareLinkCancelledMessage",
        _ => "FileShareLinkFailureMessage",
    });
}
