using LanStash.App.Features.Chat;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ChatPage : Page, IDisposable
{
    private const double CompactWidth = 720;

    private readonly IChatRepository _repository;
    private readonly ChatBrowserViewModel _viewModel;
    private readonly ChatTextComposerViewModel _composer;
    private readonly ChatAttachmentComposerViewModel _attachmentComposer;
    private bool _initialized;
    private bool _compactShowsConversationList;
    private bool _disposed;

    internal ChatPage(IChatRepository repository)
        : this(repository, new ChatBrowserViewModel())
    {
    }

    internal ChatPage(IChatRepository repository, ChatBrowserViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(viewModel);
        InitializeComponent();
        _repository = repository;
        _viewModel = viewModel;
        _composer = new(ChatTextSendReviewBlocker.Current);
        _attachmentComposer = new(ChatAttachmentSendReviewBlocker.Current);
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _composer.PropertyChanged += ViewModel_PropertyChanged;
        _attachmentComposer.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += ChatPage_Loaded;
        UpdateState();
    }

    private async void ChatPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_initialized)
        {
            return;
        }
        _initialized = true;
        await RunAsync(() => _viewModel.ActivateAsync(_repository));
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void ConversationList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ChatConversationItem conversation)
        {
            _compactShowsConversationList = false;
            await RunAsync(() => _viewModel.SelectConversationAsync(conversation));
        }
    }

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            _viewModel.SearchQuery = sender.Text;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.RefreshConversationsAsync);

    private async void RefreshMessages_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.RefreshMessagesAsync);

    private async void LoadEarlier_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.LoadEarlierAsync);

    private void ClearSearch_Click(object sender, RoutedEventArgs e)
    {
        SearchBox.Text = string.Empty;
        _viewModel.SearchQuery = string.Empty;
        SearchBox.Focus(FocusState.Keyboard);
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (ActualWidth < CompactWidth)
        {
            ShowConversationList();
        }
    }

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateAdaptiveLayout();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ActualWidth < CompactWidth && MessagePane.Visibility == Visibility.Visible)
        {
            args.Handled = true;
            ShowConversationList();
        }
    }

    private void SearchAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ConversationPane.Visibility == Visibility.Visible)
        {
            args.Handled = true;
            SearchBox.Focus(FocusState.Keyboard);
        }
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (_viewModel.IsUnavailable || _viewModel.RequiresValidation)
        {
            return;
        }
        if (MessagePane.Visibility == Visibility.Visible &&
            _viewModel.SelectedConversation is { IsEncrypted: false })
        {
            await RunAsync(_viewModel.RefreshMessagesAsync);
        }
        else
        {
            await RunAsync(_viewModel.RefreshConversationsAsync);
        }
    }

    private async Task RunAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        finally
        {
            UpdateState();
        }
    }

    private void UpdateState()
    {
        if (_disposed)
        {
            return;
        }
        LoadingState.Visibility = Visible(_viewModel.ContentState == ChatBrowserContentState.Loading);
        EmptyState.Visibility = Visible(_viewModel.IsEmpty);
        FilteredEmptyState.Visibility = Visible(_viewModel.IsFilteredEmpty);
        ErrorState.Visibility = Visible(_viewModel.HasError);
        UnavailableState.Visibility = Visible(_viewModel.IsUnavailable);
        ValidationState.Visibility = Visible(_viewModel.RequiresValidation);
        ContentState.Visibility = Visible(_viewModel.HasContent);

        RefreshButton.IsEnabled = !_viewModel.IsLoadingConversations &&
            !_viewModel.IsUnavailable && !_viewModel.RequiresValidation;
        ConversationRefreshError.IsOpen = _viewModel.HasConversationError && _viewModel.HasContent;
        ConversationTitle.Text = _viewModel.SelectedConversation?.Title ?? string.Empty;
        RefreshMessagesButton.IsEnabled = _viewModel.SelectedConversation is { IsEncrypted: false } &&
            !_viewModel.IsLoadingMessages;
        MessageError.IsOpen = _viewModel.HasMessageError;
        LoadEarlierError.IsOpen = _viewModel.HasLoadEarlierError;
        LoadEarlierButton.IsEnabled = _viewModel.CanLoadEarlier;
        LoadEarlierButton.Visibility = Visible(_viewModel.CanLoadEarlier || _viewModel.HasLoadEarlierError);
        LoadEarlierProgress.IsActive = _viewModel.IsLoadingEarlier;
        LoadEarlierProgress.Visibility = Visible(_viewModel.IsLoadingEarlier);

        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        EncryptedState.Visibility = Visible(_viewModel.IsEncryptedSelection);
        MessageLoadingState.Visibility = Visible(
            _viewModel.HasSelection && !_viewModel.IsEncryptedSelection &&
            _viewModel.IsLoadingMessages && _viewModel.Messages.Count == 0);
        MessageEmptyState.Visibility = Visible(
            _viewModel.HasSelection && !_viewModel.IsEncryptedSelection &&
            !_viewModel.IsLoadingMessages && !_viewModel.HasMessageError &&
            _viewModel.Messages.Count == 0);
        MessagesState.Visibility = Visible(
            _viewModel.HasSelection && !_viewModel.IsEncryptedSelection &&
            _viewModel.Messages.Count > 0);
        ConversationList.SelectedItem = _viewModel.SelectedConversation;
        UpdateSendState();
        UpdateAdaptiveLayout();
    }

    private void UpdateAdaptiveLayout()
    {
        if (ActualWidth >= CompactWidth)
        {
            _compactShowsConversationList = false;
            ConversationColumn.Width = new GridLength(340);
            MessageColumn.Width = new GridLength(1, GridUnitType.Star);
            ConversationPane.Visibility = Visibility.Visible;
            MessagePane.Visibility = Visibility.Visible;
            BackButton.Visibility = Visibility.Collapsed;
            return;
        }

        ConversationColumn.Width = new GridLength(1, GridUnitType.Star);
        MessageColumn.Width = new GridLength(1, GridUnitType.Star);
        var showMessage = _viewModel.HasSelection && !_compactShowsConversationList;
        ConversationPane.Visibility = Visible(!showMessage);
        MessagePane.Visibility = Visible(showMessage);
        BackButton.Visibility = Visible(showMessage);
    }

    private void ShowConversationList()
    {
        _compactShowsConversationList = true;
        ConversationPane.Visibility = Visibility.Visible;
        MessagePane.Visibility = Visibility.Collapsed;
        BackButton.Visibility = Visibility.Collapsed;
        ConversationList.Focus(FocusState.Keyboard);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _composer.PropertyChanged -= ViewModel_PropertyChanged;
        _attachmentComposer.PropertyChanged -= ViewModel_PropertyChanged;
        CancelAttachmentRead();
        _attachmentComposer.Dispose();
        _composer.Dispose();
        _viewModel.Dispose();
    }
}
