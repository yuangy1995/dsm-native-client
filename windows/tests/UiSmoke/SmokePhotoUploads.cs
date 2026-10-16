using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    public bool SupportsUploads => State.StartsWith("upload-", StringComparison.Ordinal);
    internal int UploadStarts, UploadContinues, UploadStops, UploadReviews;
    internal SynologyPhotoUploadTarget? SubmittedUploadTarget;
    internal IReadOnlyList<SynologyPhotoUploadSource>? SubmittedUploadSources;
    private List<SynologyPhotoUploadBatch>? _uploadBatches;
    internal TaskCompletionSource UploadLoadRelease { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<IReadOnlyList<SynologyPhotoCollection>> AddableAlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default) =>
        SupportsAlbumManagement ? AlbumTargetsAsync(offset, limit) :
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(offset == 0 ? [new(41, "Synthetic shared album")] : []);
    public async Task<IReadOnlyList<SynologyPhotoUploadBatch>> UploadsAsync(CancellationToken cancellationToken = default)
    {
        if (State == "upload-loading") await UploadLoadRelease.Task;
        if (State == "upload-error") throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable);
        return _uploadBatches ??= State is "upload-empty" or "upload-options" or "upload-submit" or "upload-folder" ? [] : [UploadBatch()];
    }
    private SynologyPhotoUploadBatch UploadBatch()
    {
        var date = DateTimeOffset.FromUnixTimeSeconds(1788220800);
        var photo = new SynologyPhoto(new(ProfileId, SynologyPhotoSpace.Personal, 7), "Sample 001.jpg", 2048, date, date, 3, "photo");
        var files = new[]
        {
            new SynologyPhotoUploadItem(Guid.NewGuid(), new("Sample 001.jpg", 2048, date, new string('A', 64), []),
                State == "upload-unknown" ? SynologyPhotoUploadState.PendingReview : State == "upload-running" ? SynologyPhotoUploadState.Uploading : SynologyPhotoUploadState.Failed,
                SynologyPhotoUploadStep.AddToAlbum, 2048, photo, false, SynologyPhotoFailure.WriteFailed),
            new SynologyPhotoUploadItem(Guid.NewGuid(), new("A long photo filename for the summer holiday collection 002.jpg", 4096, date, new string('B', 64), []),
                SynologyPhotoUploadState.Queued, SynologyPhotoUploadStep.None, 0, null, false),
            new SynologyPhotoUploadItem(Guid.NewGuid(), new("Sample 003.jpg", 8192, date, new string('C', 64), []),
                SynologyPhotoUploadState.Completed, SynologyPhotoUploadStep.None, 8192, photo, false),
        };
        return new(Guid.NewGuid(), ProfileId, new(SynologyPhotoSpace.Personal, AlbumId: 41), files, State == "upload-running", false);
    }
    public Task<SynologyPhotoUploadBatch> QueueUploadAsync(Guid operationId, SynologyPhotoUploadTarget target,
        IReadOnlyList<SynologyPhotoUploadSource> sources, CancellationToken cancellationToken = default)
    {
        UploadStarts++; SubmittedUploadTarget = target; SubmittedUploadSources = sources;
        var items = sources.Select(source => new SynologyPhotoUploadItem(Guid.NewGuid(), new(Path.GetFileName(source.Path),
            new FileInfo(source.Path).Length, DateTimeOffset.UtcNow, new string('A', 64), source.Directories), SynologyPhotoUploadState.Queued,
            SynologyPhotoUploadStep.None, 0, null, true)).ToArray();
        var result = new SynologyPhotoUploadBatch(operationId, ProfileId, target, items, false, false);
        (_uploadBatches ??= []).Add(result); return Task.FromResult(result);
    }
    public async Task<SynologyPhotoUploadBatch> ContinueUploadAsync(Guid batchId, IReadOnlyList<SynologyPhotoUploadSource>? sources = null,
        CancellationToken cancellationToken = default)
    {
        _ = await UploadsAsync(cancellationToken); UploadContinues++;
        var index = _uploadBatches!.FindIndex(batch => batch.Id == batchId);
        var result = _uploadBatches[index] with { Items = _uploadBatches[index].Items.Select(item => item with { State = SynologyPhotoUploadState.Completed }).ToArray() };
        _uploadBatches[index] = result; return result;
    }
    public async Task<SynologyPhotoUploadBatch> ReviewUploadAsync(Guid batchId, CancellationToken cancellationToken = default)
    { UploadReviews++; return (await UploadsAsync(cancellationToken)).Single(batch => batch.Id == batchId); }
    public async Task StopUploadAsync(Guid batchId, bool cancelRemaining = false)
    {
        _ = await UploadsAsync(); UploadStops++;
        var index = _uploadBatches!.FindIndex(batch => batch.Id == batchId);
        _uploadBatches[index] = _uploadBatches[index] with { IsRunning = false, StopRequested = true };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoUploadsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
        var directory = Directory.CreateTempSubdirectory("LanStash-Photo-Smoke-");
        var path = Path.Combine(directory.FullName, "Sample 001.jpg"); await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var repository = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repository, new WindowsTransferSavePicker(() => null), new PhotoUploadSmokePicker(path, directory.FullName));
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task opening;
        var choose = state is "upload-options" or "upload-submit" or "upload-folder";
        try
        {
            if (page.FindName("MoreButton") is not Button { Visibility: Visibility.Visible }) throw new InvalidOperationException("上传菜单没有生产入口。");
            if (state == "upload-menu")
            {
                foreach (var name in new[] { "MoreButton", "RefreshButton", "FiltersButton", "SearchBox", "Sections" })
                {
                    var control = (FrameworkElement)page.FindName(name);
                    var bounds = control.TransformToVisual(page).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight));
                    if (control.Visibility == Visibility.Visible && (bounds.X < -1 || bounds.Right > page.ActualWidth + 1))
                        throw new InvalidOperationException("Photos 工具栏超出可用宽度。");
                }
                await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
            }
            opening = (Task)typeof(SynologyPhotosPage).GetMethod(choose ? "ChooseUploadAsync" : "ShowUploadQueueAsync", flags)!
                .Invoke(page, choose ? [state == "upload-folder"] : null)!;
            ContentDialog Dialog() => (ContentDialog)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page)!;
            for (var attempt = 0; attempt < 150 && (Dialog() is not { IsLoaded: true, ActualWidth: > 0, ActualHeight: > 0 } ready ||
                choose && !Nodes(ready).OfType<Button>().Any(button => Equals(button.Content, ready.PrimaryButtonText))); attempt++) await Task.Delay(30);
            var dialog = Dialog(); if (dialog is null) throw new InvalidOperationException("未打开上传窗口。");
            var l = Localization.LocalizationService.Current;
            if (choose)
            {
                var pickers = Nodes(dialog).OfType<ComboBox>().ToArray();
                if (pickers.Length != 2) throw new InvalidOperationException("缺少重复处理或相册选择。");
                if (pickers[0].SelectedIndex != (int)repository.DuplicatePreferences.Upload) throw new InvalidOperationException("上传表单未采用实际默认重复处理。");
                pickers[0].SelectedIndex = 1; pickers[1].SelectedIndex = 1;
                if (state != "upload-options")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                    for (var attempt = 0; attempt < 150 && (Dialog() is not { IsLoaded: true, ActualWidth: > 0, ActualHeight: > 0 } || !Equals(Dialog().Title, l.Get("PhotosUploadQueue"))); attempt++) await Task.Delay(30);
                    dialog = Dialog(); await Task.Delay(100);
                    if (repository.UploadStarts != 1 || repository.UploadContinues != 1 || repository.SubmittedUploadTarget is not { AlbumId: 41, Duplicate: SynologyPhotoDuplicatePolicy.KeepBoth })
                        throw new InvalidOperationException("原生上传表单没有保持用户选择或重复发起。");
                    if (state == "upload-folder" && repository.SubmittedUploadSources![0].Directories.Count != 1)
                        throw new InvalidOperationException("目录上传丢失原层级。");
                }
            }
            else if (state is "upload-resume" or "upload-running" or "upload-unknown")
            {
                var key = state == "upload-running" ? "PhotosUploadPause" : state == "upload-unknown" ? "PhotosRefresh" : "PhotosUploadContinue";
                var action = Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
                if (!action.IsEnabled) throw new InvalidOperationException("队列动作不可使用。");
                Invoke(action); await Task.Delay(150);
                if (state == "upload-resume" && repository.UploadContinues != 1 || state == "upload-running" && repository.UploadStops != 1 ||
                    state == "upload-unknown" && (repository.UploadReviews != 1 || repository.UploadContinues != 0)) throw new InvalidOperationException("队列动作错误或未知任务被重放。");
            }
            dialog.UpdateLayout();
            if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("上传窗口主题未对齐。");
            foreach (var button in Nodes(dialog).OfType<Button>().Where(button => button.Visibility == Visibility.Visible && button.ActualWidth > 0))
            {
                var bounds = button.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, button.ActualWidth, button.ActualHeight));
                if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("上传按钮超出窗口宽度。");
            }
            await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
        }
        finally { repository.UploadLoadRelease.TrySetResult(); directory.Delete(true); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
    private sealed class PhotoUploadSmokePicker(string path, string directory) : IWindowsTransferOpenPicker
    {
        public Task<string?> PickSingleFilePathAsync(IReadOnlyList<string>? filters = null) => Task.FromResult<string?>(path);
        public Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(IReadOnlyList<string>? filters = null) => Task.FromResult<IReadOnlyList<string>?>([path]);
        public Task<string?> PickSingleFolderPathAsync() => Task.FromResult<string?>(directory);
    }
}
