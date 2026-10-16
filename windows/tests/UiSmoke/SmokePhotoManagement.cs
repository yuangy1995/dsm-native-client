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
    public bool SupportsManagement => State.StartsWith("manage-", StringComparison.Ordinal) || State.StartsWith("regen-", StringComparison.Ordinal) || State.StartsWith("auto-", StringComparison.Ordinal) || State.StartsWith("pref-", StringComparison.Ordinal) || SupportsFolderManagement;
    internal readonly TaskCompletionSource ManagementRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int ManagementStarts, ManagementContinues, ManagementReviews;
    internal SynologyPhotoEdit? SubmittedEdit;
    private List<SynologyPhotoChange>? _changes;
    private async Task<SynologyPhoto> ManagementDetailAsync(SynologyPhoto photo)
    {
        if (State == "manage-loading") await ManagementRelease.Task;
        if (State == "manage-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return photo with { Description = "Synthetic description", Rating = 3, Orientation = 1, Width = 400, Height = 300,
            Tags = [new(5, "Synthetic tag A"), new(6, "Synthetic tag B")] };
    }
    public Task<IReadOnlyList<SynologyPhotoChoice>> TagsAsync(SynologyPhotoSpace space, int offset, int limit, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoChoice>>(offset == 0 && State != "manage-tags-empty" ? [new(5, "Synthetic tag A"), new(6, "Synthetic tag B")] : []);
    public Task PrepareEditAsync(SynologyPhotoEdit edit, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task<SynologyPhotoChange> EditAsync(Guid operationId, SynologyPhotoEdit edit, CancellationToken cancellationToken = default)
    {
        ManagementStarts++; SubmittedEdit = edit;
        var value = new SynologyPhotoChange(operationId, edit.Kind, edit.Space,
            edit.Photos.Select(photo => new SynologyPhotoChangeItem(photo, SynologyPhotoChangeState.Completed,
                photo with { Rating = edit.Kind == SynologyPhotoEditKind.Rating ? (int?)edit.Value : photo.Rating })).ToArray(), SynologyPhotoChangeState.Completed, null, false, false);
        (_changes ??= []).Add(value); return Task.FromResult(value);
    }
    public Task<IReadOnlyList<SynologyPhotoChange>> ChangesAsync(CancellationToken cancellationToken = default)
    {
        var date = DateTimeOffset.FromUnixTimeSeconds(1788220800);
        var photo = new SynologyPhoto(new(ProfileId, SynologyPhotoSpace.Personal, 1), "A long synthetic photo filename from the summer collection.jpg", 2048, date, date, 3, "photo");
        _changes ??= State == "manage-history-empty" ? [] : State == "manage-history-tag-cold" ?
            [new(Guid.NewGuid(), SynologyPhotoEditKind.CreateTag, SynologyPhotoSpace.Shared, [], SynologyPhotoChangeState.Failed, null, false, false)] :
            [new(Guid.NewGuid(), SynologyPhotoEditKind.Description, SynologyPhotoSpace.Personal,
            [new(photo, State == "manage-history-unknown" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure: SynologyPhotoFailure.WriteFailed),
             new(photo with { Id = photo.Id with { ItemId = 2 }, Filename = "Sample 002.jpg" }, SynologyPhotoChangeState.Completed),
             new(photo with { Id = photo.Id with { ItemId = 3 }, Filename = "Sample 003.jpg" }, SynologyPhotoChangeState.Ready)],
            SynologyPhotoChangeState.Ready, null, false, State is not ("manage-history-unknown" or "manage-history-cold"))];
        return Task.FromResult<IReadOnlyList<SynologyPhotoChange>>(_changes.ToArray());
    }
    public async Task<SynologyPhotoChange> ContinueChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await ChangesAsync(); ManagementContinues++; var index = _changes!.FindIndex(change => change.Id == operationId);
        return _changes[index] = _changes[index] with { Items = _changes[index].Items.Select(item => item with { State = SynologyPhotoChangeState.Completed }).ToArray(), CanContinue = false };
    }
    public async Task<SynologyPhotoChange> ReviewChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    { ManagementReviews++; return (await ChangesAsync()).Single(change => change.Id == operationId); }
    public async Task<SynologyPhotoChange> CancelChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await ChangesAsync(); var index = _changes!.FindIndex(change => change.Id == operationId);
        return _changes[index] = _changes[index] with { TagState = _changes[index].TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed ? SynologyPhotoChangeState.Cancelled : _changes[index].TagState,
            Items = _changes[index].Items.Select(item => item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed
            ? item with { State = SynologyPhotoChangeState.Cancelled } : item).ToArray(), CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoManagementAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repository = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repository, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        if (state == "manage-mixed")
        {
            await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(model.Collections[0]);
            if (model.Items.Select(photo => photo.Id.Space).Distinct().Count() != 2) throw new InvalidOperationException("合成相册未提供两种原件来源。");
        }
        var photos = model.Items.Take(state == "manage-mixed" ? 2 : 1).ToArray();
        if (photos.Length == 0) throw new InvalidOperationException("合成照片未加载。");
        if (state == "manage-submit")
        {
            typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]);
            var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedItems.Add(grid.Items[0]);
        }
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Task opening;
        if (state == "manage-menu")
        {
            var more = (Button)page.FindName("MoreButton");
            if (more.Visibility != Visibility.Visible || !more.IsEnabled) throw new InvalidOperationException("管理入口依赖了无关上传能力。");
            more.Flyout.ShowAt(more); await Task.Delay(100);
            InvokeMenu((MenuFlyoutItem)page.FindName("SelectPhotosMenu")); await Task.Delay(50);
            var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedItems.Add(grid.Items[0]);
            if (grid.SelectionMode != ListViewSelectionMode.Multiple || grid.IsItemClickEnabled || page.FindName("EditPhotosMenu") is not MenuFlyoutItem { IsEnabled: true })
                throw new InvalidOperationException("多选编辑菜单未连接生产入口。");
            more.Flyout.ShowAt(more); await Task.Delay(100); InvokeMenu((MenuFlyoutItem)page.FindName("EditPhotosMenu"));
            for (var attempt = 0; attempt < 50 && Dialog() is null; attempt++) await Task.Delay(30);
            if (Dialog() is not { } form) throw new InvalidOperationException("真实菜单没有打开资料编辑表单。");
            await Task.Delay(100); form.Hide(); await Task.Delay(150);
            await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
        }
        var history = state.StartsWith("manage-history-", StringComparison.Ordinal);
        if (state == "manage-tag-standalone")
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
            InvokeMenu((MenuFlyoutItem)page.FindName("CreatePhotoTagMenu")); opening = Task.CompletedTask;
        }
        else opening = (Task)typeof(SynologyPhotosPage).GetMethod(history ? "ShowPhotoChangesAsync" : "ShowPhotoEditAsync", flags)!
            .Invoke(page, history ? [null] : [photos, null, null])!;
        try
        {
            await Task.Delay(250); var dialog = Dialog() ?? throw new InvalidOperationException("缺少照片编辑窗口。");
            // 编辑和修改记录都会先等待自动预览退出；对象创建不等于完成原生布局。
            for (var attempt = 0; attempt < 100 && (!dialog.IsLoaded || dialog.ActualWidth <= 0 || dialog.ActualHeight <= 0); attempt++)
                await Task.Delay(25);
            if (!dialog.IsLoaded || dialog.ActualWidth <= 0 || dialog.ActualHeight <= 0)
                throw new InvalidOperationException("照片编辑窗口没有完成原生布局。");
            var l = Localization.LocalizationService.Current;
            if (!history && state is not ("manage-loading" or "manage-error"))
            {
                for (var attempt = 0; attempt < 100 && !Nodes(dialog).OfType<ComboBox>().Any(control => Equals(control.Header, l.Get("PhotosEditField"))); attempt++) await Task.Delay(25);
                var picker = Nodes(dialog).OfType<ComboBox>().Single(control => Equals(control.Header, l.Get("PhotosEditField")));
                var kind = state switch
                {
                    "manage-rating" or "manage-submit" => SynologyPhotoEditKind.Rating, "manage-date" => SynologyPhotoEditKind.Date,
                    "manage-shift" => SynologyPhotoEditKind.ShiftDates, "manage-tags" or "manage-tags-empty" => SynologyPhotoEditKind.AddTags,
                    "manage-tag-create" or "manage-tag-standalone" => SynologyPhotoEditKind.CreateTag, "manage-rotate" => SynologyPhotoEditKind.Rotate,
                    "manage-mixed" => SynologyPhotoEditKind.Rating, _ => SynologyPhotoEditKind.Description,
                };
                var choice = picker.Items.Cast<object>().Single(value => (SynologyPhotoEditKind)value.GetType().GetProperty("Kind")!.GetValue(value)! == kind);
                picker.SelectedItem = choice; await Task.Delay(100);
                if (state == "manage-mixed" && picker.Items.Count != 3) throw new InvalidOperationException("混合来源暴露了不支持的编辑。");
                if (state == "manage-tags")
                { var list = Nodes(dialog).OfType<ListView>().Single(); list.SelectedItems.Add(list.Items[0]); }
                if (state == "manage-tags-empty" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("无标签时允许空提交。");
                if (state is "manage-tag-create" or "manage-tag-standalone") Nodes(dialog).OfType<TextBox>().Single(control => Equals(control.Header, l.Get("PhotosTagName"))).Text = "Synthetic new tag";
                if (state == "manage-tag-standalone")
                {
                    if (picker.Visibility != Visibility.Collapsed || picker.Items.Count != 1) throw new InvalidOperationException("空标签入口暴露了无照片编辑。");
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                    for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosChanges")); attempt++) await Task.Delay(30);
                    dialog = Dialog() ?? throw new InvalidOperationException("创建标签后没有显示结果。"); await Task.Delay(150);
                    if (repository.SubmittedEdit is not { Kind: SynologyPhotoEditKind.CreateTag, Photos.Count: 0, Space: SynologyPhotoSpace.Personal } || repository.ManagementStarts != 1)
                        throw new InvalidOperationException("独立标签没有保持空选择与固定来源。");
                }
                if (state == "manage-submit")
                {
                    Nodes(dialog).OfType<ComboBox>().Single(control => Equals(control.Header, l.Get("PhotosEditRating"))).SelectedIndex = 5;
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                    for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosChanges")); attempt++) await Task.Delay(30);
                    dialog = Dialog() ?? throw new InvalidOperationException("保存后没有打开修改记录。");
                    for (var attempt = 0; attempt < 60 && (dialog.ActualWidth <= 0 || dialog.ActualHeight <= 0); attempt++) await Task.Delay(30);
                    await Task.Delay(100);
                    if (repository.ManagementStarts != 1 || repository.SubmittedEdit is not { Kind: SynologyPhotoEditKind.Rating, Value: 5 })
                        throw new InvalidOperationException("原生编辑没有提交固定用户选择。");
                    var grid = (GridView)page.FindName("LibraryGrid");
                    if (grid.SelectedItems.Count != 1 || grid.SelectedItems[0] is not SynologyPhotoCell { Photo.Rating: 5 })
                        throw new InvalidOperationException("保存后未更新原卡片或丢失了选择。");
                }
            }
            if (state is "manage-history-resume" or "manage-history-unknown")
            {
                var key = state == "manage-history-resume" ? "PhotosContinueChanges" : "PhotosRefresh";
                var button = Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
                if (!button.IsEnabled) throw new InvalidOperationException("修改记录动作被错误禁用。");
                Invoke(button); await Task.Delay(150);
                if (state == "manage-history-resume" ? repository.ManagementContinues != 1 : repository.ManagementReviews != 1 || repository.ManagementContinues != 0)
                    throw new InvalidOperationException("未知修改被重放或继续动作未执行。");
            }
            if (state == "manage-history-cold" && !Nodes(dialog).OfType<Button>().Any(button => Equals(button.Content, l.Get("PhotosEditAgain")) && button.Visibility == Visibility.Visible))
                throw new InvalidOperationException("重启后缺少继续编辑入口。");
            if (state == "manage-history-tag-cold")
            {
                var reedit = Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosEditAgain")));
                if (!reedit.IsEnabled || reedit.Visibility != Visibility.Visible) throw new InvalidOperationException("空标签冷恢复缺少继续编辑入口。");
                Invoke(reedit);
                for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosCreateTag")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("冷恢复未打开独立标签表单。"); await Task.Delay(120);
                Nodes(dialog).OfType<TextBox>().Single(control => Equals(control.Header, l.Get("PhotosTagName"))).Text = "Synthetic restored tag";
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("冷恢复保存后未显示结果。"); await Task.Delay(120);
                if (repository.SubmittedEdit is not { Kind: SynologyPhotoEditKind.CreateTag, Photos.Count: 0, Space: SynologyPhotoSpace.Shared } || repository.ManagementStarts != 1)
                    throw new InvalidOperationException("空标签冷恢复丢失固定原来源或重复提交。");
            }
            dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualHeight <= 0) throw new InvalidOperationException("编辑窗口尚未完成布局。");
            if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("编辑窗口主题不匹配。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            {
                var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight));
                if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("编辑控件超出窗口宽度。");
            }
            await WriteSnapshotAsync(dialog, markComplete: false); repository.ManagementRelease.TrySetResult(); dialog.Hide();
            await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
        }
        finally { repository.ManagementRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        static void InvokeMenu(MenuFlyoutItem item) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(item)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
