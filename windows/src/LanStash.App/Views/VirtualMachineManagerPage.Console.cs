using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private VirtualMachineConsoleWindow? _consoleWindow;
    private async void OpenConsole_Click(object sender, RoutedEventArgs e) => await ShowConsoleAsync();
    private async Task ShowConsoleAsync()
    {
        if (_disposed || _viewModel.IsLoading || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId ||
            _viewModel.SelectedMachine is not { } selected) return;
        if (_consoleWindow is { } previous)
        {
            if (previous.MachineId == selected.Id) { previous.Activate(); return; }
            previous.Close();
        }
        var window = new VirtualMachineConsoleWindow(_repository, selected.Machine, ActualTheme); _consoleWindow = window;
        window.Closed += (_, _) => { if (ReferenceEquals(_consoleWindow, window)) _consoleWindow = null; };
        window.Activate(); await window.InitializeAsync();
    }
    private void CloseConsoleWindow() { var window = _consoleWindow; _consoleWindow = null; window?.Close(); }
}
