using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private bool _favoriteBusy;
    private long _favoriteGeneration;
    private CancellationTokenSource? _favoriteCancellation;
    private string FavoriteTargetPath => _viewModel.SelectedItem?.Path ?? _viewModel.CurrentPath;
    private bool FavoriteNeedsReview(string path) => _locationsViewModel.FavoriteReviews.Any(item => item.Path == path);

    private void UpdateFavoriteAction()
    {
        var path = FavoriteTargetPath;
        var valid = !string.IsNullOrWhiteSpace(path) && path != "/";
        var key = FavoriteNeedsReview(path) ? "FileFavoriteReview" :
            _locationsViewModel.Favorites.Items.Any(item => item.Path == path) ? "FileFavoriteRemove" : "FileFavoriteAdd";
        ToggleFavoriteButton.Label = LocalizationService.Current.Get(key);
        AutomationProperties.SetName(ToggleFavoriteButton, ToggleFavoriteButton.Label);
        ToggleFavoriteButton.Visibility = valid && !_isSelectingItems ? Visibility.Visible : Visibility.Collapsed;
        ToggleFavoriteButton.IsEnabled = !_disposed && !_favoriteBusy && !_viewModel.IsLoading && _locationsViewModel.ProfileId == _profileId && _locationsViewModel.CanWriteFavorites && valid;
    }

    private async void ToggleFavorite_Click(object sender, RoutedEventArgs e) => await ChangeFavoriteAsync();

    private async Task ChangeFavoriteAsync()
    {
        UpdateFavoriteAction();
        if (!ToggleFavoriteButton.IsEnabled) return;
        var path = FavoriteTargetPath; var parent = _viewModel.CurrentPath;
        var review = FavoriteNeedsReview(path);
        var remove = _locationsViewModel.Favorites.Items.Any(item => item.Path == path);
        var generation = ++_favoriteGeneration; _favoriteCancellation = new(); var token = _favoriteCancellation.Token;
        _favoriteBusy = true; FileFavoriteStatus.IsOpen = false; UpdateFavoriteAction();
        bool Current() => !_disposed && generation == _favoriteGeneration && _locationsViewModel.ProfileId == _profileId &&
            parent == _viewModel.CurrentPath && path == FavoriteTargetPath;
        try
        {
            var result = review ? await _locationsViewModel.ReviewFavoriteAsync(path, token) : remove ?
                await _locationsViewModel.RemoveFavoriteAsync(path, token) :
                await _locationsViewModel.AddFavoriteAsync(path, _viewModel.SelectedItem?.Name, token);
            if (!Current()) return;
            var key = result is null ? "FileFavoriteRefreshed" : result.ErrorCategory == MutationErrorCategory.Authentication ? "FileFavoriteSignIn" : result.Status switch
            {
                MutationResultStatus.ConfirmedSuccess => result.Operation == "removeFavorite" ? "FileFavoriteRemoved" : "FileFavoriteAdded",
                MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "FileFavoriteUnknown",
                MutationResultStatus.CancelledBeforeSubmission => "FileFavoriteCancelled",
                MutationResultStatus.Unsupported => "FileFavoriteUnavailable",
                _ => result?.ErrorCategory == MutationErrorCategory.Permission ? "FileFavoritePermission" :
                    result?.ErrorCategory == MutationErrorCategory.Conflict ? "FileFavoriteConflict" : "FileFavoriteFailed"
            };
            FileFavoriteStatus.Message = LocalizationService.Current.Get(key);
            FileFavoriteStatus.Severity = result is null ? InfoBarSeverity.Informational : result.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            FileFavoriteStatus.IsOpen = true;
        }
        catch { if (Current()) { FileFavoriteStatus.Message = LocalizationService.Current.Get("FileFavoriteUnknown"); FileFavoriteStatus.Severity = InfoBarSeverity.Warning; FileFavoriteStatus.IsOpen = true; } }
        finally
        {
            if (generation == _favoriteGeneration)
            { _favoriteBusy = false; _favoriteCancellation?.Dispose(); _favoriteCancellation = null; if (!_disposed) UpdateFavoriteAction(); }
        }
    }
    private void CancelFavoriteOperation()
    { _favoriteGeneration++; _favoriteCancellation?.Cancel(); _favoriteCancellation?.Dispose(); _favoriteCancellation = null; _favoriteBusy = false; }
}
