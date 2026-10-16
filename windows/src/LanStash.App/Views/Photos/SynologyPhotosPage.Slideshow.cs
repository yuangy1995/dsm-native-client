using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using WinRT.Interop;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private Window? _slideshowWindow;
    private AppWindow? _slideshowAppWindow;
    private Grid? _slideshowRoot;
    private long _playerSlideGeneration;
    private bool _slideshowStarting;

    private async void StartSlideshow_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _dialog is not null || _isSaving || _exportStarting || _slideshowStarting) return;
        var generation = _viewGeneration; _slideshowStarting = true;
        try
        {
            // 菜单关闭后再移动控件到另一 XamlRoot，不能在弹出层退场时迁移其页面。
            if (MoreButton.Flyout is { IsOpen: true } flyout)
            {
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Closed(object? source, object value) => closed.TrySetResult();
                flyout.Closed += Closed;
                try { flyout.Hide(); await closed.Task.WaitAsync(_viewCancellation.Token); }
                finally { flyout.Closed -= Closed; }
            }
            if (!_disposed && generation == _viewGeneration) await _model.StartSlideshowAsync();
        }
        catch (OperationCanceledException) when (_disposed || generation != _viewGeneration) { }
        finally { _slideshowStarting = false; if (!_disposed) RenderPreviewControls(); }
    }
    private async void SlideshowPlayback_Click(object sender, RoutedEventArgs args) => await _model.Slideshow.ToggleAsync();
    private void SlideshowStop_Click(object sender, RoutedEventArgs args) => _model.Slideshow.Stop();

    private void SlideshowChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_disposed) return;
        if (_model.Slideshow.IsPresented && _slideshowWindow is null) OpenSlideshowWindow();
        else if (!_model.Slideshow.IsPresented) CloseSlideshowWindow();
        RenderPreviewControls();
        if (_model.Slideshow.IsPresented && _player is { } player)
        {
            if (_model.Slideshow.IsPlaying) player.Play(); else player.Pause();
        }
    }

    private void OpenSlideshowWindow()
    {
        // 同一控件树与媒体会话在独立窗口呈现，避免另一套播放器或主窗口全屏状态迁移。
        _slideshowRoot = new Grid { RequestedTheme = ElementTheme.Dark };
        foreach (var key in new[] { VirtualKey.Space, VirtualKey.Left, VirtualKey.Right, VirtualKey.Escape })
        {
            var accelerator = new KeyboardAccelerator { Key = key };
            accelerator.Invoked += SlideshowKeyInvoked; _slideshowRoot.KeyboardAccelerators.Add(accelerator);
        }
        PhotosPageRoot.Children.Remove(PreviewRoot); _slideshowRoot.Children.Add(PreviewRoot);
        _slideshowWindow = new Window { Title = _l.Get("PhotosSlideshowStart"), Content = _slideshowRoot };
        _slideshowWindow.Closed += SlideshowWindowClosed;
        _slideshowAppWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(_slideshowWindow)));
        _slideshowAppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        _slideshowAppWindow.Changed += SlideshowWindowChanged;
        _slideshowWindow.Activate();
        SlideshowPlaybackButton.Focus(FocusState.Programmatic);
    }

    private async void SlideshowKeyInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_model.Slideshow.IsPresented) return;
        args.Handled = true;
        await HandleSlideshowKeyAsync(sender.Key);
    }
    internal Task HandleSlideshowKeyAsync(VirtualKey key)
    {
        if (!_model.Slideshow.IsPresented) return Task.CompletedTask;
        if (key == VirtualKey.Escape) { _model.Slideshow.Stop(); return Task.CompletedTask; }
        return key == VirtualKey.Space ? _model.Slideshow.ToggleAsync() :
            key is VirtualKey.Left or VirtualKey.Right ? _model.Slideshow.AdvanceAsync(key == VirtualKey.Left ? -1 : 1) : Task.CompletedTask;
    }
    private void SlideshowWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidPresenterChange && sender.Presenter.Kind != AppWindowPresenterKind.FullScreen) _model.Slideshow.Stop();
    }
    private void SlideshowWindowClosed(object sender, WindowEventArgs args)
    {
        CloseSlideshowWindow(alreadyClosed: true); _model.Slideshow.Stop();
    }
    private void CloseSlideshowWindow(bool alreadyClosed = false)
    {
        if (_slideshowWindow is not { } window) return;
        _slideshowWindow = null;
        window.Closed -= SlideshowWindowClosed;
        if (_slideshowAppWindow is { } appWindow) appWindow.Changed -= SlideshowWindowChanged;
        _slideshowAppWindow = null;
        if (_slideshowRoot is { } root)
        {
            foreach (var accelerator in root.KeyboardAccelerators) accelerator.Invoked -= SlideshowKeyInvoked;
            root.Children.Remove(PreviewRoot);
        }
        window.Content = null; _slideshowRoot = null;
        PhotosPageRoot.Children.Add(PreviewRoot);
        _player?.Pause();
        if (!alreadyClosed) window.Close();
        if (!_disposed && PreviewRoot.IsLoaded) ClosePreviewButton.Focus(FocusState.Programmatic);
    }

    private void RenderSlideshowControls()
    {
        var slideshow = _model.Slideshow;
        SlideshowMenu.Text = _l.Get("PhotosSlideshowStart");
        SlideshowMenu.IsEnabled = StartSlideshowButton.IsEnabled = _model.CanStartSlideshow && !_isSaving && !_exportStarting && !_slideshowStarting;
        StartSlideshowButton.Label = _l.Get("PhotosSlideshowStart");
        SlideshowPlaybackButton.Label = _l.Get(slideshow.IsPlaying ? "PhotosSlideshowPause" : "PhotosSlideshowPlay");
        SlideshowPlaybackButton.Icon = new SymbolIcon(slideshow.IsPlaying ? Symbol.Pause : Symbol.Play);
        SlideshowStopButton.Label = _l.Get("PhotosSlideshowStop");
        foreach (var button in new[] { StartSlideshowButton, SlideshowPlaybackButton, SlideshowStopButton })
            AutomationProperties.SetName(button, button.Label);
        SlideshowPlaybackButton.Visibility = SlideshowStopButton.Visibility = Visible(slideshow.IsPresented);
        StartSlideshowButton.Visibility = ClosePreviewButton.Visibility = SaveButton.Visibility = DeleteButton.Visibility = DetailsButton.Visibility = Visible(!slideshow.IsPresented);
        if (slideshow.IsPresented)
        {
            MotionButton.Visibility = EditPhotoButton.Visibility = EditPhotoFacesButton.Visibility = SimilarPhotoButton.Visibility = Visibility.Collapsed;
            PreviousPhotoButton.IsEnabled = NextPhotoButton.IsEnabled = !slideshow.IsLoading && _model.Preview.Photo is not null;
            PreviewProgress.IsActive = slideshow.IsLoading; PreviewProgress.Visibility = Visible(slideshow.IsLoading);
            if (slideshow.ErrorKey is { } key) { PreviewErrorBar.Message = _l.Get(key); PreviewErrorBar.IsOpen = true; }
            PreviewSaveBar.IsOpen = PreviewDeletionBar.IsOpen = false;
        }
        PlayerElement.AreTransportControlsEnabled = !slideshow.IsPresented;
        ImageScroll.ZoomMode = slideshow.IsPresented ? ZoomMode.Disabled : ZoomMode.Enabled;
    }
}
