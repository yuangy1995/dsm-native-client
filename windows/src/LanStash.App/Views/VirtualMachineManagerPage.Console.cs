using Microsoft.UI.Xaml;
using LanStash.Domain;

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
        await OpenConsoleWindowAsync(selected.Machine);
    }
    private async Task OpenConsoleWindowAsync(VirtualMachineSummary baseline)
    {
        var window = new VirtualMachineConsoleWindow(_repository, baseline, ActualTheme); _consoleWindow = window;
        window.Closed += (_, _) => { if (ReferenceEquals(_consoleWindow, window)) _consoleWindow = null; };
        window.ReconnectRequested += async () =>
        {
            if (_disposed || !ReferenceEquals(_consoleWindow, window) || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) return;
            // 明确重连仍绑定原虚拟机；页面当前选择可能已经改变，不能转到另一目标。
            window.Close();
            await OpenConsoleWindowAsync(baseline);
        };
        window.Activate(); await window.InitializeAsync();
    }
    private void CloseConsoleWindow() { var window = _consoleWindow; _consoleWindow = null; window?.Close(); }
}
