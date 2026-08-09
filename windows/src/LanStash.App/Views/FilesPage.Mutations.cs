using LanStash.App.Features.Files.Mutations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileMutationRepository? _mutationRepository;
    private readonly FileMutationReviewBlocker _mutationReviewBlocker;
    private FileMutationViewModel? _mutationModel;
    private ContentDialog? _mutationDialog;
    private bool _isClosingMutation;

    private async void CreateFolder_Click(object sender, RoutedEventArgs e) =>
        await ShowMutationAsync(FileMutationOperation.CreateFolder);

    private async void CreateFolderAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!CanCreateFolder())
        {
            return;
        }
        args.Handled = true;
        await ShowMutationAsync(FileMutationOperation.CreateFolder);
    }

    private async void RenameItem_Click(object sender, RoutedEventArgs e) =>
        await ShowMutationAsync(FileMutationOperation.Rename);

    private async void RenameAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!CanRename())
        {
            return;
        }
        args.Handled = true;
        await ShowMutationAsync(FileMutationOperation.Rename);
    }

    private bool CanCreateFolder() =>
        !_disposed &&
        !IsReadOnlyLocation() &&
        _mutationRepository?.FileMutationAvailability.CanCreateFolder == true &&
        _mutationDialog is null &&
        !_isClosingMutation &&
        !_viewModel.IsLoading &&
        FileMutationViewModel.IsMutablePath(_viewModel.CurrentPath);

    private bool CanRename() =>
        !_disposed &&
        !IsReadOnlyLocation() &&
        _mutationRepository?.FileMutationAvailability.CanRename == true &&
        _mutationDialog is null &&
        !_isClosingMutation &&
        !_viewModel.IsLoading &&
        _viewModel.SelectedItem is { Item: { CanWrite: true } } selected &&
        FileMutationViewModel.IsMutablePath(selected.Path) &&
        IsDirectMutationChild(_viewModel.CurrentPath, selected.Path);

    private async Task ShowMutationAsync(FileMutationOperation operation)
    {
        if (operation == FileMutationOperation.CreateFolder
                ? !CanCreateFolder()
                : !CanRename())
        {
            return;
        }
        var repository = _mutationRepository;
        var frozenParent = _viewModel.CurrentPath;
        var frozenItem = _viewModel.SelectedItem?.Item;
        if (repository is null || repository.ProfileId != _profileId ||
            IsReadOnlyLocation() ||
            !FileMutationViewModel.IsMutablePath(frozenParent) ||
            (operation == FileMutationOperation.Rename &&
                (frozenItem is null || !IsDirectMutationChild(frozenParent, frozenItem.Path))))
        {
            return;
        }

        CloseShareLinkDialog();
        await ClosePreviewAsync();
        if (_disposed || repository.ProfileId != _profileId || IsReadOnlyLocation() ||
            !string.Equals(_viewModel.CurrentPath, frozenParent, StringComparison.Ordinal) ||
            (operation == FileMutationOperation.Rename &&
                !SameMutationItem(_viewModel.SelectedItem?.Item, frozenItem)))
        {
            return;
        }

        var model = operation == FileMutationOperation.CreateFolder
            ? FileMutationViewModel.CreateFolder(
                repository, _profileId, frozenParent, _mutationReviewBlocker)
            : FileMutationViewModel.Rename(
                repository, _profileId, frozenItem!, _mutationReviewBlocker);
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };
        _mutationModel = model;
        _mutationDialog = dialog;

        void Render()
        {
            if (_mutationModel != model || _mutationDialog != dialog)
            {
                return;
            }
            dialog.Title = localization.Get(MutationTitleKey(model.Operation, model.State));
            dialog.CloseButtonText = localization.Get(
                model.State == FileMutationPresentationState.Submitting
                    ? "ActionCancel"
                    : "ActionClose");
            dialog.PrimaryButtonText = model.State switch
            {
                FileMutationPresentationState.Form => localization.Get(
                    model.Operation == FileMutationOperation.CreateFolder
                        ? "FileMutationCreateAction"
                        : "FileMutationRenameAction"),
                FileMutationPresentationState.CancelledBeforeSubmission =>
                    localization.Get("FileMutationReturnToFormAction"),
                _ => string.Empty,
            };
            dialog.IsPrimaryButtonEnabled = model.State ==
                    FileMutationPresentationState.CancelledBeforeSubmission || model.CanSubmit;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText)
                ? ContentDialogButton.Close
                : ContentDialogButton.Primary;
            dialog.Content = BuildMutationDialogContent(model, localization, dialog);
        }

        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if ((args.PropertyName == nameof(FileMutationViewModel.State) ||
                    args.PropertyName == nameof(FileMutationViewModel.CancellationRequested)) &&
                model.State != FileMutationPresentationState.ConfirmedSuccess)
            {
                DispatcherQueue.TryEnqueue(Render);
            }
        }
        model.PropertyChanged += Changed;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (model.State == FileMutationPresentationState.CancelledBeforeSubmission)
            {
                model.ReturnToForm();
                Render();
                return;
            }
            if (!model.CanSubmit || repository.ProfileId != _profileId || IsReadOnlyLocation())
            {
                return;
            }
            var deferral = args.GetDeferral();
            try
            {
                await model.SubmitAsync();
                args.Cancel = model.State != FileMutationPresentationState.ConfirmedSuccess;
                if (args.Cancel)
                {
                    Render();
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.Closing += (_, args) =>
        {
            if (_isClosingMutation || _mutationDialog != dialog ||
                model.State != FileMutationPresentationState.Submitting)
            {
                return;
            }
            args.Cancel = true;
            model.RequestCancellation();
            Render();
        };

        Render();
        var confirmed = false;
        try
        {
            await dialog.ShowAsync();
            confirmed = model.State == FileMutationPresentationState.ConfirmedSuccess;
        }
        finally
        {
            model.PropertyChanged -= Changed;
            model.Dispose();
            if (ReferenceEquals(_mutationModel, model))
            {
                _mutationModel = null;
            }
            if (ReferenceEquals(_mutationDialog, dialog))
            {
                _mutationDialog = null;
            }
            _isClosingMutation = false;
        }

        if (confirmed && !_disposed && repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, model.ParentPath, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
        if (!_disposed)
        {
            UpdateState();
        }
    }

    private static FrameworkElement BuildMutationDialogContent(
        FileMutationViewModel model,
        LocalizationService localization,
        ContentDialog dialog)
    {
        var panel = new StackPanel { Width = 440, MaxWidth = 440, Spacing = 12 };
        var target = new TextBlock
        {
            Text = localization.Format(
                model.Operation == FileMutationOperation.CreateFolder
                    ? "FileMutationCreateTarget"
                    : "FileMutationRenameTarget",
                model.Operation == FileMutationOperation.CreateFolder
                    ? model.FrozenPath
                    : model.TargetName),
            TextWrapping = TextWrapping.WrapWholeWords,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(target, AutomationHeadingLevel.Level2);
        panel.Children.Add(target);

        if (model.State == FileMutationPresentationState.Form)
        {
            var name = new TextBox
            {
                Header = localization.Get("FileMutationNameLabel"),
                Text = model.Name,
                MinHeight = 48,
                IsSpellCheckEnabled = false,
            };
            AutomationProperties.SetName(
                name, localization.Get("FileMutationNameAutomationName"));
            var nameError = new InfoBar
            {
                IsOpen = model.HasNameError,
                IsClosable = false,
                Severity = InfoBarSeverity.Error,
                Message = localization.Get("FileMutationNameError"),
            };
            AutomationProperties.SetLiveSetting(nameError, AutomationLiveSetting.Polite);
            name.TextChanged += (_, _) =>
            {
                model.Name = name.Text;
                dialog.IsPrimaryButtonEnabled = model.CanSubmit;
                nameError.IsOpen = model.HasNameError;
                AutomationProperties.SetHelpText(
                    name,
                    localization.Get(model.HasNameError
                        ? "FileMutationNameError"
                        : "FileMutationNameHelp"));
            };
            AutomationProperties.SetHelpText(
                name,
                localization.Get(model.HasNameError
                    ? "FileMutationNameError"
                    : "FileMutationNameHelp"));
            panel.Children.Add(name);
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get("FileMutationNameHelp"),
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                    "TextFillColorSecondaryBrush"],
                TextWrapping = TextWrapping.WrapWholeWords,
            });
            panel.Children.Add(nameError);
            name.Loaded += (_, _) =>
            {
                name.SelectAll();
                name.Focus(FocusState.Programmatic);
            };
            return panel;
        }

        if (model.State == FileMutationPresentationState.Submitting)
        {
            var statusMessage = localization.Get(model.CancellationRequested
                ? "FileMutationCancellingMessage"
                : "FileMutationSubmittingMessage");
            var progress = new ProgressRing { IsActive = true, Width = 40, Height = 40 };
            AutomationProperties.SetName(progress, statusMessage);
            panel.Children.Add(progress);
            var status = new TextBlock
            {
                Text = statusMessage,
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetName(status, statusMessage);
            AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
            panel.Children.Add(status);
            return panel;
        }

        var messageKey = MutationMessageKey(model.State);
        var message = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State == FileMutationPresentationState.NeedsReview
                ? InfoBarSeverity.Warning
                : model.State == FileMutationPresentationState.CancelledBeforeSubmission
                    ? InfoBarSeverity.Informational
                    : InfoBarSeverity.Error,
            Message = localization.Get(messageKey),
        };
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Polite);
        panel.Children.Add(message);
        if (model.State == FileMutationPresentationState.NeedsReview &&
            model.ReviewBlock is { } review)
        {
            panel.Children.Add(new TextBlock
            {
                Text = localization.Format("FileMutationReviewTarget", review.ProposedPath),
                TextWrapping = TextWrapping.WrapWholeWords,
            });
        }
        return panel;
    }

    private static string MutationTitleKey(
        FileMutationOperation operation,
        FileMutationPresentationState state) => state switch
    {
        FileMutationPresentationState.NeedsReview => "FileMutationReviewTitle",
        FileMutationPresentationState.PermissionDenied => "FileMutationPermissionTitle",
        FileMutationPresentationState.TargetChanged => "FileMutationChangedTitle",
        FileMutationPresentationState.Unsupported => "FileMutationUnsupportedTitle",
        FileMutationPresentationState.Failure => "FileMutationFailureTitle",
        _ => operation == FileMutationOperation.CreateFolder
            ? "FileMutationCreateFolderTitle"
            : "FileMutationRenameTitle",
    };

    private static string MutationMessageKey(FileMutationPresentationState state) => state switch
    {
        FileMutationPresentationState.NeedsReview => "FileMutationReviewMessage",
        FileMutationPresentationState.CancelledBeforeSubmission => "FileMutationCancelledMessage",
        FileMutationPresentationState.PermissionDenied => "FileMutationPermissionMessage",
        FileMutationPresentationState.TargetChanged => "FileMutationChangedMessage",
        FileMutationPresentationState.Unsupported => "FileMutationUnsupportedMessage",
        _ => "FileMutationFailureMessage",
    };

    private static bool SameMutationItem(FileItem? current, FileItem? frozen) =>
        current is not null && frozen is not null &&
        string.Equals(current.Path, frozen.Path, StringComparison.Ordinal) &&
        string.Equals(current.Name, frozen.Name, StringComparison.Ordinal) &&
        current.IsDirectory == frozen.IsDirectory &&
        current.Size == frozen.Size &&
        current.ModifiedAt == frozen.ModifiedAt &&
        current.CanWrite == frozen.CanWrite;

    private static bool IsDirectMutationChild(string parent, string path)
    {
        var separator = path.LastIndexOf('/');
        return separator > 0 &&
            string.Equals(path[..separator], parent, StringComparison.Ordinal);
    }

    private static bool ContainsRecycleSegment(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));


    private void UpdateMutationControls()
    {
        CreateFolderButton.IsEnabled = CanCreateFolder();
        CreateFolderButton.Visibility = IsReadOnlyLocation()
            ? Visibility.Collapsed
            : Visibility.Visible;
        RenameButton.IsEnabled = CanRename();
        RenameButton.Visibility = IsReadOnlyLocation()
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void CloseMutationDialog()
    {
        var dialog = _mutationDialog;
        var model = _mutationModel;
        _mutationDialog = null;
        _mutationModel = null;
        model?.Abandon();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingMutation = true;
        dialog.Hide();
    }
}
