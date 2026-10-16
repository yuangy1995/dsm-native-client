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
    public bool SupportsManualFaceEditing(SynologyPhotoSpace space) => State.StartsWith("manual-", StringComparison.Ordinal) && State != "manual-capability";
    public async Task<IReadOnlyList<SynologyPhotoFaceRegion>> PhotoFacesAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        if (State == "manual-loading") await PeopleRelease.Task;
        if (State == "manual-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (State == "manual-empty") return [];
        return [new(71, 11, State == "manual-long-name" ? string.Concat(Enumerable.Repeat("Synthetic long person ", 7)) : "Synthetic Alice", new(0.12, 0.2, 0.25, 0.25)),
            new(72, 12, "Synthetic Bob", new(0.57, 0.3, 0.2, 0.2))];
    }
    private SynologyPhotoRecognitionChange SaveSyntheticManual(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        var unknown = State == "manual-unknown"; var partial = State == "manual-partial";
        var value = new SynologyPhotoRecognitionChange(id, edit.Kind, edit.Space, unknown ? SynologyPhotoChangeState.PendingReview : partial ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed,
            null, false, false, partial, edit.FaceChanges.Count, [], [], []) { PhotoIds = [edit.ManualPhoto!.Id.ItemId], TargetIds = [11, 12],
                CompletedFaceChanges = unknown ? [] : edit.FaceChanges.Take(partial ? 1 : 100).Select(change => change.Id).ToArray() };
        _recognitionChanges!.Add(value); return value;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoManualFacesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        if (state == "manual-shared") await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        if (state == "manual-album") { await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(model.Collections.First()); }
        var photo = model.Items.First(); await model.Preview.OpenAsync(photo);
        var l = Localization.LocalizationService.Current;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        TextBox Name() => Nodes(Dialog()!).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosPersonName")));
        ComboBox Combo(string key) => Nodes(Dialog()!).OfType<ComboBox>().Single(value => Equals(value.Header, l.Get(key)));
        var history = state.StartsWith("manual-history-", StringComparison.Ordinal);
        var verified = false;
        try
        {
            if (state == "manual-capability")
            { if (((AppBarButton)page.FindName("EditPhotoFacesButton")).Visibility != Visibility.Collapsed) throw new InvalidOperationException("缺失手工能力仍显示入口。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (history)
            {
                model.Preview.Close(); var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
                var menu = (MenuFlyoutItem)page.FindName("PhotoRecognitionChangesMenu");
                ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            }
            else
            {
                var button = (AppBarButton)page.FindName("EditPhotoFacesButton"); if (!button.IsEnabled || button.Visibility != Visibility.Visible) throw new InvalidOperationException("手工人脸入口不可用。");
                Invoke(button);
            }
            await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(160); var dialog = Dialog()!;
            if (state == "manual-history-input")
            { Invoke(Button("PhotosManualEditAgain")); await Wait(() => Dialog() is { IsLoaded: true } current && !ReferenceEquals(current, dialog)); await Task.Delay(160); dialog = Dialog()!; if (repo.PeopleCancels != 1) throw new InvalidOperationException("重新编辑没有结束旧任务。"); }
            if (state == "manual-history-cold")
            { if (repo.PeopleReviews == 0 || repo.PeopleContinues != 0 || Button("PhotosShareContinue").IsEnabled) throw new InvalidOperationException("冷恢复没有只读查询。"); }
            else if (state is "manual-loading" or "manual-error")
            { if (dialog.IsPrimaryButtonEnabled || Nodes(dialog).OfType<SynologyPhotoManualFacesEditor>().Any()) throw new InvalidOperationException("未加载手工编辑器仍可保存。"); }
            else
            {
                await Wait(() => Nodes(dialog).OfType<SynologyPhotoManualFacesEditor>().Any()); var editor = Nodes(dialog).OfType<SynologyPhotoManualFacesEditor>().Single();
                if (dialog.IsPrimaryButtonEnabled || editor.CanSave) throw new InvalidOperationException("未修改人脸仍可保存。");
                if (!Nodes(editor).OfType<Image>().Any(image => image.Source is not null)) throw new InvalidOperationException("原生编辑器没有图片。");
                var add = state is "manual-add" or "manual-add-known" or "manual-submit" or "manual-unknown" or "manual-cancel" or "manual-confirm-cancel" or "manual-safety" or "manual-conflict";
                if (add)
                {
                    Invoke(Button("PhotosManualAdd")); if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("新框没有人物姓名仍可保存。");
                    if (state == "manual-add-known") Combo("PhotosFaceTarget").SelectedIndex = 2; else Name().Text = "  New synthetic person  ";
                    if (state == "manual-safety") { if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("危险入口未受专项保护。"); }
                    else await Wait(() => dialog.IsPrimaryButtonEnabled);
                }
                if (state is "manual-adjust" or "manual-keyboard" or "manual-partial")
                {
                    var position = Nodes(editor).OfType<NumberBox>().Single(box => Equals(box.Header, l.Get("PhotosManualX")));
                    if (!position.Focus(FocusState.Keyboard)) throw new InvalidOperationException("位置控件不能键盘聚焦。"); position.Value += 3;
                    if (!editor.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("位置调整没有启用保存。");
                    var change = await editor.InputAsync(); if (change.FaceChanges.Count != 2 || change.FaceChanges[0].Kind != SynologyPhotoFaceChangeKind.Add || change.FaceChanges[1].Kind != SynologyPhotoFaceChangeKind.Remove) throw new InvalidOperationException("调整框没有保留先新后旧顺序。");
                }
                if (state == "manual-assign") { Combo("PhotosFaceTarget").SelectedIndex = 2; if ((await editor.InputAsync()).FaceChanges.Single().Kind != SynologyPhotoFaceChangeKind.Reassign) throw new InvalidOperationException("同框归类误新增。"); }
                if (state is "manual-remove" or "manual-undo")
                {
                    Invoke(Button("PhotosManualRemove")); if (!editor.Drafts[0].Removed || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("原人脸没有标记移除。");
                    if (state == "manual-undo") { Invoke(Button("PhotosManualUndoRemove")); if (editor.Drafts[0].Removed || editor.CanSave) throw new InvalidOperationException("撤销移除仍有未保存修改。"); }
                }
                if (state == "manual-cancel") { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消仍然写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                if (state == "manual-conflict")
                {
                    Invoke(Button("PhotosShareContinue")); await Task.Delay(220); if (repo.PeopleWrites != 0 || editor.Drafts.Last().Name.Trim() != "New synthetic person" || !Button("PhotosManualReload").IsEnabled) throw new InvalidOperationException("冲突丢失草稿或未提供重新载入。");
                    Invoke(Button("PhotosManualReload")); await Wait(() => Nodes(dialog).OfType<SynologyPhotoManualFacesEditor>().SingleOrDefault() is { } fresh && !ReferenceEquals(fresh, editor));
                }
                if (state is "manual-submit" or "manual-unknown" or "manual-confirm-cancel" or "manual-remove" or "manual-partial")
                {
                    Invoke(Button("PhotosShareContinue")); await Wait(() => Dialog() is { IsLoaded: true } current && !ReferenceEquals(current, dialog)); await Task.Delay(100); dialog = Dialog()!;
                    if (repo.PeopleWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosManualConfirm"))) throw new InvalidOperationException("缺少人脸变更确认。");
                    if (state == "manual-confirm-cancel") { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消确认仍写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                    Invoke(Button("PhotosManualFaces")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(150); dialog = Dialog()!;
                    if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.ManualPhoto?.Id != photo.Id) throw new InvalidOperationException("手工编辑没有绑定原照片并只提交一次。");
                    if (state == "manual-submit") { var change = repo.SubmittedPeople.FaceChanges.Single(); if (change.Name != "New synthetic person" || change.Jpeg is not { Length: > 3 } || change.Jpeg[0] != 255) throw new InvalidOperationException("手工新增没有裁剪图或姓名未规整。"); }
                    if (state == "manual-submit" && !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosRecognitionSaved"))) throw new InvalidOperationException("人脸保存状态文案不正确。");
                    if (state == "manual-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (repo.PeopleContinues != 0 || Button("PhotosShareContinue").IsEnabled) throw new InvalidOperationException("未知手工操作可以重复执行。"); }
                }
            }
            await Task.Delay(250); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("手工人脸控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); verified = true;
        }
        finally
        {
            repo.PeopleRelease.TrySetResult();
            if (Dialog() is { } open)
            {
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); }
                open.Closed += Closed; open.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 120 && !ready(); attempt++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("手工人脸窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value) { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
