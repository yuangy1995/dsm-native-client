using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ContentDialog? _createConversationDialog;

    private void ConfigureCreateConversationAction()
    {
        var text = LocalizationService.Current.Get("ChatCreateAction");
        CreateConversationButtonLabel.Text = text;
        AutomationProperties.SetName(CreateConversationButton, text);
        ToolTipService.SetToolTip(CreateConversationButton, text);
    }

    private async void CreateConversation_Click(object sender, RoutedEventArgs e) =>
        await ShowCreateConversationAsync();

    private async void CreateConversationAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_conversationCreator.CanCreateDirect && !_conversationCreator.CanCreatePrivateGroup)
        {
            return;
        }
        args.Handled = true;
        await ShowCreateConversationAsync();
    }

    private async Task ShowCreateConversationAsync()
    {
        if (_createConversationDialog is not null || XamlRoot is null ||
            (!_conversationCreator.CanCreateDirect && !_conversationCreator.CanCreatePrivateGroup))
        {
            return;
        }

        var localization = LocalizationService.Current;
        using var content = new ChatCreateConversationDialogContent(_conversationCreator);
        var dialog = _createConversationDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("ChatCreateDialogTitle"),
            PrimaryButtonText = localization.Get("ChatCreatePrimaryAction"),
            CloseButtonText = localization.Get("ChatCreateCloseAction"),
            DefaultButton = ContentDialogButton.Primary,
            Content = content,
        };

        void UpdatePrimary(object? sender, EventArgs args)
        {
            dialog.PrimaryButtonText = localization.Get(_conversationCreator.RequiresReview
                ? "ChatCreateReviewAction"
                : "ChatCreatePrimaryAction");
            dialog.IsPrimaryButtonEnabled =
                _conversationCreator.ContentState ==
                    ChatConversationCreatorContentState.Content &&
                content.HasValidInput && !_conversationCreator.IsSubmitting;
        }

        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            var deferral = args.GetDeferral();
            args.Cancel = true;
            content.SetSubmitting(true);
            UpdatePrimary(null, EventArgs.Empty);
            try
            {
                var outcome = content.IsGroupMode
                    ? await _conversationCreator.CreatePrivateGroupAsync(
                        content.GroupTitle,
                        content.SelectedUserIds)
                    : await _conversationCreator.CreateDirectAsync(
                        content.SelectedUserIds.Single());
                if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
                    outcome.ConfirmedConversation is { } conversation)
                {
                    await _viewModel.AcceptCreatedConversationAsync(conversation);
                    _compactShowsConversationList = false;
                    args.Cancel = false;
                }
                else
                {
                    content.ShowOutcome(outcome);
                }
            }
            catch
            {
                content.ShowOutcome(LocalConversationCreateFailure());
            }
            finally
            {
                UpdatePrimary(null, EventArgs.Empty);
                deferral.Complete();
                UpdateState();
            }
        }

        content.InputChanged += UpdatePrimary;
        dialog.PrimaryButtonClick += Submit;
        var load = _conversationCreator.LoadAsync();
        UpdatePrimary(null, EventArgs.Empty);
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            content.InputChanged -= UpdatePrimary;
            dialog.PrimaryButtonClick -= Submit;
            if (!_disposed)
            {
                _conversationCreator.CancelLoad();
            }
            await load;
            if (ReferenceEquals(_createConversationDialog, dialog))
            {
                _createConversationDialog = null;
            }
        }
    }

    private static ChatConversationCreateOutcome LocalConversationCreateFailure() => new(
        new MutationResult(
            1,
            MutationResultStatus.ConfirmedFailure,
            "chatConversationCreate",
            submitted: false,
            requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unknown,
            diagnosticTag: "chat.conversation-create.ui-failed"),
        Guid.Empty,
        ConfirmedConversation: null);

    private void DisposeCreateConversationDialog()
    {
        _createConversationDialog?.Hide();
        _createConversationDialog = null;
    }
}
