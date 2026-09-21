namespace LanStash.App.Views;

// NAS 原生设置内容共享弹窗生命周期，具体字段和能力由各自内容控制。
internal interface INasSettingsDialogContent : IDisposable
{
    event Action? StateChanged;
    bool CanSave { get; }
    bool IsBusy { get; }
    string? PrimaryButtonResourceKey => "ActionSave";
    Task ActivateAsync();
    Task ReloadAsync();
    Task SaveAsync();
}
