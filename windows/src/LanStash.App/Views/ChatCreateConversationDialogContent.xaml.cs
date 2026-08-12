using System.ComponentModel;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatCreateConversationDialogContent : UserControl, IDisposable
{
    public ChatConversationCreatorViewModel ViewModel { get; }
    public event EventHandler? InputChanged;

    internal ChatCreateConversationDialogContent(ChatConversationCreatorViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;
        InitializeComponent();
        ViewModel.PropertyChanged += ViewModel_PropertyChanged;
        ConfigureText();
        DirectModeButton.IsEnabled = ViewModel.CanCreateDirect;
        GroupModeButton.IsEnabled = ViewModel.CanCreatePrivateGroup;
        if (!ViewModel.CanCreateDirect && ViewModel.CanCreatePrivateGroup)
        {
            GroupModeButton.IsChecked = true;
        }
        UpdateState();
    }

    public bool IsGroupMode => GroupModeButton.IsChecked == true;
    public string GroupTitle => GroupTitleInput.Text.Trim();
    public IReadOnlyList<string> SelectedUserIds => UserList.SelectedItems
        .OfType<ChatUser>()
        .Select(user => user.Id)
        .ToArray();
    public bool HasValidInput => IsGroupMode
        ? GroupTitle.Length > 0 && SelectedUserIds.Count >= 2
        : SelectedUserIds.Count == 1;

    public void SetSubmitting(bool submitting)
    {
        DirectModeButton.IsEnabled = ViewModel.CanCreateDirect &&
            !submitting && !ViewModel.RequiresReview;
        GroupModeButton.IsEnabled = ViewModel.CanCreatePrivateGroup &&
            !submitting && !ViewModel.RequiresReview;
        GroupTitleInput.IsEnabled = !submitting && !ViewModel.RequiresReview;
        UserList.IsEnabled = !submitting && !ViewModel.RequiresReview;
        RetryButton.IsEnabled = !submitting;
    }

    public void ShowOutcome(ChatConversationCreateOutcome outcome)
    {
        var localization = LocalizationService.Current;
        FeedbackBar.IsOpen = outcome.Result.Status != MutationResultStatus.ConfirmedSuccess;
        (FeedbackBar.Severity, FeedbackBar.Title, FeedbackBar.Message) = outcome.Result.Status switch
        {
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission =>
                (InfoBarSeverity.Warning,
                    localization.Get("ChatCreateReviewTitle"),
                    localization.Get("ChatCreateReviewMessage")),
            MutationResultStatus.PermissionDenied =>
                (InfoBarSeverity.Error,
                    localization.Get("ChatCreatePermissionTitle"),
                    localization.Get("ChatCreatePermissionMessage")),
            MutationResultStatus.Unsupported =>
                (InfoBarSeverity.Warning,
                    localization.Get("ChatCreateUnavailableTitle"),
                    localization.Get("ChatCreateUnavailableMessage")),
            MutationResultStatus.CancelledBeforeSubmission =>
                (InfoBarSeverity.Informational,
                    localization.Get("ChatCreateCancelledTitle"),
                    localization.Get("ChatCreateCancelledMessage")),
            _ =>
                (InfoBarSeverity.Error,
                    localization.Get("ChatCreateFailedTitle"),
                    localization.Get("ChatCreateFailedMessage")),
        };
        SetSubmitting(false);
        InputChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ConfigureText()
    {
        var localization = LocalizationService.Current;
        ConversationTypeLabel.Text = localization.Get("ChatCreateTypeLabel");
        DirectModeButton.Content = localization.Get("ChatCreateDirectMode");
        GroupModeButton.Content = localization.Get("ChatCreateGroupMode");
        GroupTitleLabel.Text = localization.Get("ChatCreateGroupTitleLabel");
        GroupTitleInput.PlaceholderText = localization.Get("ChatCreateGroupTitlePlaceholder");
        MemberSelectionLabel.Text = localization.Get("ChatCreateDirectMemberLabel");
        RetryLabel.Text = localization.Get("ChatCreateRetry");
        LoadingText.Text = localization.Get("ChatCreateLoading");
        EmptyTitle.Text = localization.Get("ChatCreateEmptyTitle");
        EmptyMessage.Text = localization.Get("ChatCreateEmptyMessage");
        ErrorTitle.Text = localization.Get("ChatCreateLoadErrorTitle");
        ErrorMessage.Text = localization.Get("ChatCreateLoadErrorMessage");
        AutomationProperties.SetName(UserList, localization.Get("ChatCreateUserListAutomationName"));
        AutomationProperties.SetName(RetryButton, localization.Get("ChatCreateRetry"));
        ToolTipService.SetToolTip(RetryButton, localization.Get("ChatCreateRetry"));
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (UserList is null)
        {
            return;
        }
        UserList.SelectedItems.Clear();
        UserList.SelectionMode = IsGroupMode ? ListViewSelectionMode.Multiple : ListViewSelectionMode.Single;
        GroupTitlePanel.Visibility = Visible(IsGroupMode);
        MemberSelectionLabel.Text = LocalizationService.Current.Get(IsGroupMode
            ? "ChatCreateGroupMembersLabel"
            : "ChatCreateDirectMemberLabel");
        InputChanged?.Invoke(this, EventArgs.Empty);
    }

    private void GroupTitleInput_TextChanged(object sender, TextChangedEventArgs e) =>
        InputChanged?.Invoke(this, EventArgs.Empty);

    private void UserList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        InputChanged?.Invoke(this, EventArgs.Empty);

    private async void Retry_Click(object sender, RoutedEventArgs e) => await ViewModel.LoadAsync();

    private void UpdateState()
    {
        LoadingState.Visibility = Visible(
            ViewModel.ContentState == ChatConversationCreatorContentState.Loading);
        EmptyState.Visibility = Visible(
            ViewModel.ContentState == ChatConversationCreatorContentState.Empty);
        ErrorState.Visibility = Visible(
            ViewModel.ContentState == ChatConversationCreatorContentState.Error);
        UserList.Visibility = Visible(
            ViewModel.ContentState == ChatConversationCreatorContentState.Content);
        RetryButton.Visibility = Visible(
            ViewModel.ContentState == ChatConversationCreatorContentState.Error);
        if (ViewModel.ContentState == ChatConversationCreatorContentState.Content &&
            ViewModel.RequiresReview)
        {
            RestorePendingSelection();
        }
        InputChanged?.Invoke(this, EventArgs.Empty);
    }

    private void RestorePendingSelection()
    {
        GroupModeButton.IsChecked = ViewModel.PendingIsGroup;
        DirectModeButton.IsChecked = !ViewModel.PendingIsGroup;
        GroupTitleInput.Text = ViewModel.PendingGroupTitle ?? string.Empty;
        var selectedIds = ViewModel.PendingIsGroup
            ? ViewModel.PendingGroupMemberIds
            : ViewModel.PendingDirectUserId is { } id ? new[] { id } : [];
        UserList.SelectedItems.Clear();
        foreach (var user in ViewModel.Users.Where(user => selectedIds.Contains(user.Id, StringComparer.Ordinal)))
        {
            UserList.SelectedItems.Add(user);
        }
        SetSubmitting(false);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose() => ViewModel.PropertyChanged -= ViewModel_PropertyChanged;
}
