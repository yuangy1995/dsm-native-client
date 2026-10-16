using LanStash.App.Features.Photos.Synology;
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
    public async Task<IReadOnlyList<SynologyPhotoFace>> PersonFacesAsync(long personId, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default)
    {
        if (State == "face-loading") await PeopleRelease.Task;
        if (State == "face-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (State == "face-empty") return [];
        return photos.SelectMany((photo, index) => Enumerable.Range(0, 2).Select(face => new SynologyPhotoFace(71 + index * 2 + face, personId, photo,
            new(71 + index * 2 + face, "synthetic-face") { Space = photo.Id.Space, Type = SynologyPhotoThumbnailType.Face, NativeSize = true }))).ToArray();
    }
    public Task<byte[]> FaceImageAsync(SynologyPhotoFace face, CancellationToken cancellationToken = default) => ThumbnailAsync(face.Photo, cancellationToken: cancellationToken);
    public async Task<IReadOnlyList<SynologyPhoto>> RecognitionPhotosAsync(Guid operationId, CancellationToken cancellationToken = default) =>
        (await PhotosAsync(new SynologyPhotoQuery.Category(SynologyPhotoCategory.People, 11, 0, long.MaxValue), 0, 1, cancellationToken)).Items;
    private SynologyPhotoRecognitionChange SaveSyntheticFaces(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        var unknown = State == "face-unknown"; var cover = edit.Kind == SynologyPhotoRecognitionKind.SetPersonCover;
        var complete = cover ? new[] { edit.People[0].Person.Id } : edit.Faces.Select(face => face.Id).ToArray();
        var value = new SynologyPhotoRecognitionChange(id, edit.Kind, edit.Space, unknown ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed,
            null, false, false, false, complete.Length, unknown ? [] : complete, edit.People, [])
        { TargetIds = edit.People.Select(person => person.Person.Id).ToArray(), PhotoIds = cover ? [edit.CoverPhoto!.Id.ItemId] : edit.Faces.Select(face => face.Photo.Id.ItemId).Distinct().ToArray() };
        _recognitionChanges!.Add(value); return value;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoFacesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        if (state == "face-shared") await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.People); await model.OpenCollectionAsync(model.Collections[0]);
        var l = Localization.LocalizationService.Current; var grid = (GridView)page.FindName("LibraryGrid");
        typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]); grid.SelectedIndex = 0; await Task.Delay(180);
        var history = state.StartsWith("face-history-", StringComparison.Ordinal); var cover = state.StartsWith("face-cover", StringComparison.Ordinal);
        var reassign = state is "face-reassign" or "face-new-submit" or "face-known-submit";
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoRecognitionChangesMenu" : cover ? "SetPhotoPersonCoverMenu" : reassign ? "ReassignPhotoFacesMenu" : "RemovePhotoFacesMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("人脸原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(220); var dialog = Dialog()!;
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        try
        {
            var editor = Nodes(dialog).OfType<SynologyPhotoFacesEditor>().SingleOrDefault();
            if (!history && state is not ("face-loading" or "face-error") && editor is null) throw new InvalidOperationException("人脸表单未加载。");
            if (editor is not null && state != "face-empty") await Wait(() => Nodes(editor).OfType<Image>().Count(image => image.Source is not null) == 2);
            if (state is "face-loading" or "face-error" or "face-empty" or "face-safety" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不可用人脸表单仍可提交。");
            if (editor is not null && reassign)
            {
                if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("新人物无姓名可提交。");
                if (state == "face-known-submit") Nodes(editor).OfType<ComboBox>().Single().SelectedIndex = 1;
                else Nodes(editor).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosPersonName"))).Text = "  Synthetic new person  ";
                await Wait(() => dialog.IsPrimaryButtonEnabled);
            }
            if (editor is not null && state is "face-none" or "face-one")
            {
                foreach (var check in Nodes(editor).OfType<CheckBox>().Take(state == "face-one" ? 1 : 2)) check.IsChecked = false;
                if (state == "face-none" && dialog.IsPrimaryButtonEnabled || state == "face-one" && editor.Input()?.Faces.Count != 1) throw new InvalidOperationException("人脸选择数量错误。");
            }
            if (state == "face-cancel") { Invoke(Button("PhotosCancel")); await Task.Delay(150); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消仍写入。"); await WriteSnapshotAsync(page); return; }
            if (state == "face-cover-submit")
            {
                Invoke(Button("PhotosSaveChanges")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(120); dialog = Dialog()!;
                if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.CoverPhoto?.Id.ItemId != 1 || repo.SubmittedPeople.Faces.Count != 0) throw new InvalidOperationException("封面目标不正确。");
            }
            if (state is "face-remove-confirm" or "face-remove-submit" or "face-new-submit" or "face-known-submit" or "face-confirm-cancel" or "face-unknown" or "face-one")
            {
                Invoke(Button("PhotosShareContinue")); await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(120); dialog = Dialog()!;
                if (repo.PeopleWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get(reassign ? "PhotosReassignFacesConfirm" : "PhotosRemoveFacesConfirm"))) throw new InvalidOperationException("缺少原件保留确认或过早提交。");
                if (state == "face-confirm-cancel") { Invoke(Button("PhotosCancel")); await Task.Delay(150); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消确认仍写入。"); await WriteSnapshotAsync(page); return; }
                if (state != "face-remove-confirm")
                {
                    Invoke(Button(reassign ? "PhotosReassignPersonFaces" : "PhotosRemovePersonFaces")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(120); dialog = Dialog()!;
                    if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.Faces.Count != (state == "face-one" ? 1 : 2)) throw new InvalidOperationException("所选人脸未提交一次。");
                    if (state == "face-new-submit" && repo.SubmittedPeople.Name != "Synthetic new person" || state == "face-known-submit" && repo.SubmittedPeople.People.Count != 2) throw new InvalidOperationException("归入目标错误。");
                    if (state == "face-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (Button("PhotosShareContinue").IsEnabled || repo.PeopleContinues != 0) throw new InvalidOperationException("未知人脸操作可以重放。"); }
                }
            }
            if (state == "face-history-cold" && (repo.PeopleReviews == 0 || repo.PeopleContinues != 0)) throw new InvalidOperationException("冷恢复没有只读查询。");
            if (state == "face-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(150); if (repo.PeopleContinues != 1) throw new InvalidOperationException("人脸继续未绑定原任务。"); }
            if (state == "face-history-input")
            {
                Invoke(Button("PhotosShareEditAgain")); await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(180); dialog = Dialog()!;
                if (repo.PeopleCancels != 1 || repo.PeopleWrites != 0 || !Nodes(dialog).OfType<SynologyPhotoFacesEditor>().Any()) throw new InvalidOperationException("重新输入人脸目标未结束旧任务。");
            }
            await Task.Delay(300); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("人脸控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false);
        }
        finally
        {
            repo.PeopleRelease.TrySetResult();
            if (Dialog() is { } open)
            {
                // 先等待原生关闭动画和 Closed 回调，避免测试页释放与弹窗关闭交错。
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnClosed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= OnClosed; closed.TrySetResult(); }
                open.Closed += OnClosed; open.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
        page.Dispose(); MarkSnapshotComplete();
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 100 && !ready(); attempt++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("人脸窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
