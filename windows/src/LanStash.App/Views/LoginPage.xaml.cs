using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class LoginPage : Page
{
    private readonly AppViewModel _viewModel;
    private bool _isLoadingLanguage;

    public LoginPage(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        _viewModel.PropertyChanged += (_, _) => UpdateState();
        _viewModel.PasswordLoaded += (_, password) =>
            DispatcherQueue.TryEnqueue(() => PasswordInput.Password = password);
        LoadLanguageOptions();
        UpdateState();
    }

    private void LoadLanguageOptions()
    {
        _isLoadingLanguage = true;
        var localization = LocalizationService.Current;
        LanguageLabel.Text = localization.Get("LanguageTitle");
        LanguageNote.Text = localization.Get("LanguageFallbackNote");
        LanguageSelector.ItemsSource = localization.Choices();
        LanguageSelector.SelectedItem = localization.Choices()
            .First(choice => choice.Value == localization.Selection);
        _isLoadingLanguage = false;
    }

    private void LanguageSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoadingLanguage || LanguageSelector.SelectedItem is not LanguageChoice choice)
        {
            return;
        }
        LocalizationService.Current.SetSelection(choice.Value);
    }

    private async void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is not NasProfile profile || _viewModel.IsBusy)
        {
            return;
        }
        await _viewModel.SelectProfileAsync(profile);
        PasswordInput.Password = _viewModel.Password;
        await _viewModel.RestoreAsync(profile);
    }

    private void NewProfile_Click(object sender, RoutedEventArgs e)
    {
        ProfileList.SelectedItem = null;
        PasswordInput.Password = string.Empty;
        OtpInput.Password = string.Empty;
        _viewModel.NewProfile();
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.Password = PasswordInput.Password;
        _viewModel.Otp = OtpInput.Password;
        await _viewModel.ConnectAsync();
    }

    private void CancelConnect_Click(object sender, RoutedEventArgs e) =>
        _viewModel.CancelConnection();

    private void UpdateState()
    {
        if (ConnectButton is null)
        {
            return;
        }
        ConnectButton.IsEnabled = !_viewModel.IsBusy;
        AddNasButton.IsEnabled = !_viewModel.IsBusy;
        ProfileList.IsEnabled = !_viewModel.IsBusy;
        SetControlsEnabled(ConnectionFields, !_viewModel.IsBusy);
        CancelConnectButton.Visibility = _viewModel.IsBusy
            ? Visibility.Visible
            : Visibility.Collapsed;
        BusyIndicator.IsActive = _viewModel.IsBusy;
        ErrorBar.IsOpen = !string.IsNullOrWhiteSpace(_viewModel.ErrorMessage);
        StatusBar.IsOpen = !string.IsNullOrWhiteSpace(_viewModel.ConnectionStatus);
    }

    private static void SetControlsEnabled(DependencyObject root, bool isEnabled)
    {
        var childCount = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < childCount; index++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, index);
            if (child is Control control)
            {
                control.IsEnabled = isEnabled;
            }
            SetControlsEnabled(child, isEnabled);
        }
    }
}
