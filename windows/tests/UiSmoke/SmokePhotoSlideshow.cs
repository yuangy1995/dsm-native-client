using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
using Windows.System;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    internal TaskCompletionSource? SlideReadGate;
    internal bool SlideFailRead, SlideDecodeFails;
    internal SmokePhotoVideo? SlideVideo;
    public async Task<IReadOnlyMediaSource> VideoSourceAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        if (State is not ("slide-video" or "slide-video-pause")) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetTempPath());
        var file = await folder.CreateFileAsync("LanStash-SyntheticVideo-" + Guid.NewGuid().ToString("N") + ".mp4", CreationCollisionOption.FailIfExists);
        try
        {
            var composition = new MediaComposition();
            composition.Clips.Add(MediaClip.CreateFromColor(Windows.UI.Color.FromArgb(255, 70, 120, 170), TimeSpan.FromSeconds(0.75)));
            var result = await composition.RenderToFileAsync(file, MediaTrimmingPreference.Precise, MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Vga));
            if (result != Windows.Media.Transcoding.TranscodeFailureReason.None) throw new InvalidOperationException("合成视频无法编码。");
            cancellationToken.ThrowIfCancellationRequested(); return SlideVideo = new((await FileIO.ReadBufferAsync(file)).ToArray());
        }
        finally { await file.DeleteAsync(StorageDeleteOption.PermanentDelete); }
    }
}

internal sealed class SmokePhotoVideo(byte[] bytes) : IReadOnlyMediaSource
{
    public bool Disposed;
    public long Length => bytes.LongLength;
    public string ContentType => "video/mp4";
    public Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancellationToken = default)
    { cancellationToken.ThrowIfCancellationRequested(); if (Disposed) throw new ObjectDisposedException(nameof(SmokePhotoVideo)); return Task.FromResult(bytes.AsSpan((int)offset, Math.Min(count, bytes.Length - (int)offset)).ToArray()); }
    public void Dispose() => Disposed = true;
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoSlideshowAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repository = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repository, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(250);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var workspace = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await workspace.LoadIfNeededAsync();
        if (state == "slide-filtered") await workspace.SearchAsync("absent");
        if (state is "slide-empty" or "slide-filtered")
        {
            if (workspace.CanStartSlideshow || ((MenuFlyoutItem)page.FindName("SlideshowMenu")).IsEnabled || workspace.Items.Count != 0)
                throw new InvalidOperationException("空列表仍能启动幻灯片。");
            await WriteSnapshotAsync(page); return;
        }
        var slideshow = workspace.Slideshow; var libraryItems = workspace.Items.ToArray(); var month = workspace.SelectedMonth;
        Window? Window() => (Window?)typeof(SynologyPhotosPage).GetField("_slideshowWindow", flags)!.GetValue(page);
        AppWindow? AppWindow() => (AppWindow?)typeof(SynologyPhotosPage).GetField("_slideshowAppWindow", flags)!.GetValue(page);
        FrameworkElement Element(string name) => page.FindName(name) as FrameworkElement ??
            (FrameworkElement)typeof(SynologyPhotosPage).GetField(name, flags)!.GetValue(page)!;
        AppBarButton Button(string name) => (AppBarButton)Element(name);
        void Press(string name) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.AppBarButtonAutomationPeer(Button(name)).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        async Task WaitFor(Func<bool> predicate)
        { for (var index = 0; index < 180 && !predicate(); index++) await Task.Delay(25); if (!predicate()) throw new InvalidOperationException("幻灯片状态未按预期改变。"); }
        async Task Shortcut(VirtualKey key)
        {
            var grid = (Grid)Window()!.Content;
            _ = grid.KeyboardAccelerators.Single(item => item.Key == key);
            await page.HandleSlideshowKeyAsync(key);
        }
        if (state == "slide-pages") await workspace.Preview.OpenAsync(workspace.Items.Last());
        if (state == "slide-similar")
        { var detail = await repository.SimilarGroupAsync(11, SynologyPhotoSpace.Personal); await workspace.Preview.OpenAsync(detail!.Photos[0]); }
        if (state is "slide-loading" or "slide-late") repository.SlideReadGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        if (state is "slide-error" or "slide-retry") repository.SlideFailRead = true;
        if (state == "slide-decode") repository.SlideDecodeFails = true;
        var verified = false;
        try
        {
            if (workspace.Preview.Photo is not null) Press("StartSlideshowButton");
            else
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(60);
                var menu = (MenuFlyoutItem)page.FindName("SlideshowMenu");
                if (!menu.IsEnabled) throw new InvalidOperationException("幻灯片入口不可用。");
                ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            }
            await WaitFor(() => Window()?.Content is Grid { IsLoaded: true });
            if (AppWindow()?.Presenter.Kind != AppWindowPresenterKind.FullScreen) throw new InvalidOperationException("未使用独立全屏窗口。");
            if (state == "slide-video-pause") Press("SlideshowPlaybackButton");
            if (state is "slide-error" or "slide-retry" or "slide-decode")
            {
                await WaitFor(() => slideshow.ErrorKey is not null);
                if (slideshow.IsPlaying || !((InfoBar)Element("PreviewErrorBar")).IsOpen) throw new InvalidOperationException("媒体错误未暂停。");
                if (state == "slide-retry") { repository.SlideFailRead = false; Invoke((Button)Element("PreviewRetryButton")); await WaitFor(() => !slideshow.IsLoading && slideshow.ErrorKey is null); }
            }
            else if (state is not ("slide-loading" or "slide-late")) await WaitFor(() => !slideshow.IsLoading);
            if (state is "slide-next" or "slide-pages" or "slide-similar")
            {
                Press("SlideshowPlaybackButton"); Press("NextPhotoButton");
                await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == (state == "slide-pages" ? 101 : 2) && !slideshow.IsLoading);
                if (state == "slide-similar") { Press("PreviousPhotoButton"); await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == 1 && !slideshow.IsLoading); Press("PreviousPhotoButton"); await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == 3 && !slideshow.IsLoading); }
            }
            if (state is "slide-pause" or "slide-keyboard")
            {
                if (state == "slide-keyboard") await Shortcut(VirtualKey.Space); else Press("SlideshowPlaybackButton");
                var id = workspace.Preview.Photo?.Id; await Task.Delay(3200); if (slideshow.IsPlaying || workspace.Preview.Photo?.Id != id) throw new InvalidOperationException("暂停后仍自动切换。");
                if (state == "slide-keyboard") { await Shortcut(VirtualKey.Right); await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == 2 && !slideshow.IsLoading); }
            }
            if (state == "slide-auto") await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == 2 && !slideshow.IsLoading);
            if (state is "slide-video" or "slide-video-pause")
            {
                if (state == "slide-video-pause")
                { await Task.Delay(1000); if (workspace.Preview.Photo?.Id.ItemId != 1) throw new InvalidOperationException("暂停视频仍推进。"); Press("SlideshowPlaybackButton"); }
                await WaitFor(() => workspace.Preview.Photo?.Id.ItemId == 2 && !slideshow.IsLoading);
                if (repository.SlideVideo?.Disposed != true) throw new InvalidOperationException("播放后未回收媒体。");
            }
            if (state is "slide-stop" or "slide-close" or "slide-exit" or "slide-hide" or "slide-late")
            {
                if (state == "slide-close") Window()!.Close();
                else if (state == "slide-exit") AppWindow()!.SetPresenter(AppWindowPresenterKind.Overlapped);
                else if (state == "slide-hide") page.SetWindowVisible(false);
                else Press("SlideshowStopButton");
                repository.SlideReadGate?.TrySetResult(); await WaitFor(() => Window() is null && !slideshow.IsPresented);
                await Task.Delay(100);
                if (state is "slide-hide" or "slide-late" && workspace.Preview.Photo is not null) throw new InvalidOperationException("停止后迟到结果重新打开预览。");
                await WriteSnapshotAsync(page, markComplete: false);
            }
            else
            {
                if (Button("SaveButton").Visibility != Visibility.Collapsed || Button("DeleteButton").Visibility != Visibility.Collapsed) throw new InvalidOperationException("幻灯片仍展示写操作。");
                if (Element("PreviewImage") is Image { Source: not null } image && !slideshow.IsLoading)
                {
                    var scroll = (ScrollViewer)Element("ImageScroll"); scroll.UpdateLayout();
                    var center = image.TransformToVisual(scroll).TransformPoint(new Windows.Foundation.Point(image.ActualWidth / 2, image.ActualHeight / 2));
                    if (Math.Abs(center.X - scroll.ActualWidth / 2) > 2 || Math.Abs(center.Y - scroll.ActualHeight / 2) > 2)
                        throw new InvalidOperationException($"幻灯片图片没有居中适配窗口：图像 {image.ActualWidth}×{image.ActualHeight}，中心 {center.X},{center.Y}，视口 {scroll.ActualWidth}×{scroll.ActualHeight}。");
                }
                if (!Button("SlideshowPlaybackButton").Focus(FocusState.Keyboard)) throw new InvalidOperationException("播放控件无法键盘聚焦。");
                await WriteSnapshotAsync((FrameworkElement)Window()!.Content, markComplete: false);
                if (state == "slide-keyboard") await Shortcut(VirtualKey.Escape); else Press("SlideshowStopButton");
            }
            if (!workspace.Items.SequenceEqual(libraryItems) || workspace.SelectedMonth != month) throw new InvalidOperationException("幻灯片改变了图库范围或月份。");
            if (Window() is not null || slideshow.IsPresented) throw new InvalidOperationException("幻灯片窗口未关闭。");
            verified = true;
        }
        finally { slideshow.Stop(); repository.SlideReadGate?.TrySetResult(); if (verified) MarkSnapshotComplete(); }
    }
}
