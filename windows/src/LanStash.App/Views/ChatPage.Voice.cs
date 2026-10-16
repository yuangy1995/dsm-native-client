using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.App.Platform.Chat;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private readonly Dictionary<string, ChatVoiceRecordingModel> _voiceModels = new(StringComparer.Ordinal);
    private ChatVoiceDialog? _voiceDialog;
    internal Func<IChatVoiceCapture>? VoiceCaptureFactory { get; set; }
    internal IReadOnlyList<ChatVoiceRecordingModel> VoiceRecordings => _voiceModels.Values.ToArray();

    private async void VoiceMessage_Click(object sender, RoutedEventArgs args) => await ShowVoiceAsync();
    internal async Task ShowVoiceAsync()
    {
        if (_disposed || _voiceDialog is not null || XamlRoot is null || !_attachmentComposer.IsAvailable ||
            _viewModel.SelectedConversation is not { IsEncrypted: false } selected) return;
        if (!_voiceModels.TryGetValue(selected.Id, out var model))
        {
            model = new(_repository, selected.Conversation, VoiceCaptureFactory?.Invoke() ?? new WindowsChatVoiceCapture(DispatcherQueue));
            _voiceModels[selected.Id] = model;
        }
        await model.SetVisibleAsync(_isWindowActive && _isLoaded && _isWindowVisible);
        using var dialog = _voiceDialog = new(model, () => ExportVoiceAsync(model)) { XamlRoot = XamlRoot, RequestedTheme = ActualTheme };
        try { await dialog.ShowAsync(); }
        finally
        {
            await model.SetVisibleAsync(false); _voiceDialog = null;
            if (!_disposed) await _viewModel.RefreshMessagesAsync();
        }
    }
    private async Task ExportVoiceAsync(ChatVoiceRecordingModel model)
    {
        if ((Application.Current as App)?.MainWindow is not { } window || model.Recording is null) return;
        var picker = new FileSavePicker(Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(window)))
        { SuggestedFileName = "recording.m4a", DefaultFileExtension = ".m4a" };
        picker.FileTypeChoices.Add(LocalizationService.Current.Get("ChatVoiceFileType"), [".m4a"]);
        var destination = await picker.PickSaveFileAsync();
        if (destination is null) return;
        using var stream = new MemoryStream();
        await model.ExportAsync(stream);
        await using var output = await Features.Transfers.WindowsTransactionalDownloadDestination.CreateAsync(destination.Path);
        await output.WriteAsync(stream.ToArray());
        await output.CommitAsync();
    }
    private async Task StopVoiceCaptureAsync()
    {
        foreach (var model in _voiceModels.Values.ToArray()) await model.SetVisibleAsync(false);
    }
    private async Task UpdateVoiceActivityAsync()
    {
        foreach (var pair in _voiceModels.ToArray())
            await pair.Value.SetVisibleAsync(_voiceDialog is not null && pair.Key == _viewModel.SelectedConversation?.Id &&
                _isLoaded && _isWindowVisible && _isWindowActive);
    }
    private async Task DisposeVoiceAsync()
    {
        _voiceDialog?.Dispose(); _voiceDialog?.Hide(); _voiceDialog = null;
        foreach (var model in _voiceModels.Values.ToArray()) await model.DisposeAsync();
        _voiceModels.Clear();
    }
}
