using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private bool _tasksActivated;
    private Task RefreshCurrentSectionAsync() => ReferenceEquals(ResourcePivot.SelectedItem, TasksTab)
        ? TasksPane.RefreshAsync() : RunAsync(_viewModel.RefreshAsync);
    private async void ResourcePivot_SelectionChanged(object sender, SelectionChangedEventArgs e) => await UpdateTaskVisibilityAsync();
    private async Task UpdateTaskVisibilityAsync()
    {
        if (_disposed || TasksPane is null || _repository is null) return;
        var visible = ReferenceEquals(ResourcePivot.SelectedItem, TasksTab);
        RefreshButton.Visibility = visible ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
        if (visible && !_tasksActivated) { _tasksActivated = true; await TasksPane.ActivateAsync(_repository); }
        else await TasksPane.SetVisibleAsync(visible);
    }
}
