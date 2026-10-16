using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private CrossNasCopyMoveViewModel? _crossNasCopyMoveModel;
    private ContentDialog? _crossNasCopyMoveDialog;

    private IReadOnlyList<NasProfile>? CrossNasTargetProfiles { get; set; }
    private Func<Guid, CancellationToken, Task<IFileCopyMoveFolderSource?>>? CrossNasFolderSourceFactory { get; set; }

    internal void SetCrossNasDependencies(
        IReadOnlyList<NasProfile> targetProfiles,
        Func<Guid, CancellationToken, Task<IFileCopyMoveFolderSource?>> folderSourceFactory)
    {
        if (_copyMoveRepository?.CrossNasAvailability.CanCrossCopy != true)
        {
            CrossNasTargetProfiles = null;
            CrossNasFolderSourceFactory = null;
            return;
        }
        CrossNasTargetProfiles = targetProfiles;
        CrossNasFolderSourceFactory = folderSourceFactory;
    }

    private bool CanCrossNasCopyMove()
    {
        if (_copyMoveRepository is null || _viewModel.SelectedItem is null ||
            CrossNasTargetProfiles is null || CrossNasTargetProfiles.Count == 0 ||
            CrossNasFolderSourceFactory is null)
            return false;

        var selected = _viewModel.SelectedItem;
        if (!FileCopyMoveViewModel.IsDestination(selected.Path) ||
            !FileMutationViewModel.IsMutablePath(selected.Path))
            return false;

        var availability = _copyMoveRepository.CrossNasAvailability;
        return availability.CanCrossCopy;
    }

    private async void CrossNasCopy_Click(object sender, RoutedEventArgs e)
    {
        await ShowCrossNasCopyMoveAsync(FileCopyMoveOperation.Copy);
    }

    private async void CrossNasMove_Click(object sender, RoutedEventArgs e)
    {
        await ShowCrossNasCopyMoveAsync(FileCopyMoveOperation.Move);
    }

    private async Task ShowCrossNasCopyMoveAsync(FileCopyMoveOperation operation, CrossNasTransferSummary? restored = null)
    {
        if (_copyMoveRepository?.CrossNasAvailability.CanCrossCopy != true ||
            operation == FileCopyMoveOperation.Move && !_copyMoveRepository.CrossNasAvailability.CanCrossMove)
            return;
        var source = restored is null ? _viewModel.SelectedItem?.Item : new FileItem(restored.SourcePath, restored.Name, restored.IsDirectory, restored.Size, null, null, false, false);
        if (source is null || restored is not null && restored.SourceProfileId != _profileId ||
            _copyMoveRepository is null ||
            CrossNasTargetProfiles is null ||
            CrossNasFolderSourceFactory is null)
            return;

        if (!await ClosePreviewAsync()) return;

        var model = new CrossNasCopyMoveViewModel(
            _copyMoveRepository,
            _profileId,
            source,
            operation,
            CrossNasTargetProfiles,
            CrossNasFolderSourceFactory);

        if (model.State == CrossNasCopyMoveState.Unsupported)
        {
            model.Dispose();
            return;
        }

        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ((FrameworkElement)XamlRoot.Content).ActualTheme,
            DefaultButton = ContentDialogButton.Primary,
            MinWidth = 480,
            MaxWidth = 480,
        };

        _crossNasCopyMoveModel = model;
        _crossNasCopyMoveDialog = dialog;

        async Task RenderAsync()
        {
            dialog.SecondaryButtonText = null;
            dialog.DefaultButton = ContentDialogButton.Primary;
            dialog.IsPrimaryButtonEnabled = true;
            var isFolder = model.Source.IsDirectory;
            dialog.Title = operation switch
            {
                FileCopyMoveOperation.Copy when isFolder =>
                    localization.Get("CrossNasCopyFolderTitle"),
                FileCopyMoveOperation.Copy =>
                    localization.Get("CrossNasCopyFileTitle"),
                FileCopyMoveOperation.Move when isFolder =>
                    localization.Get("CrossNasMoveFolderTitle"),
                _ => localization.Get("CrossNasMoveFileTitle"),
            };

            dialog.Content = BuildCrossNasContent(model, localization, RenderAsync);

            switch (model.State)
            {
                case CrossNasCopyMoveState.ChoosingTarget:
                case CrossNasCopyMoveState.ChoosingDestination:
                case CrossNasCopyMoveState.LoadingFolders:
                    dialog.PrimaryButtonText = localization.Get("CrossNasSubmitButton");
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Cancel_Button");
                    dialog.IsPrimaryButtonEnabled = model.CanSubmit;
                    break;
                case CrossNasCopyMoveState.Transferring:
                case CrossNasCopyMoveState.Refreshing:
                case CrossNasCopyMoveState.DeletingSources:
                    dialog.PrimaryButtonText = null;
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Cancel_Button");
                    break;
                case CrossNasCopyMoveState.Recoverable:
                    dialog.PrimaryButtonText = localization.Get("CrossNasRefresh");
                    dialog.IsPrimaryButtonEnabled = model.CanRefresh;
                    dialog.SecondaryButtonText = model.CanContinue ? localization.Get("CrossNasContinue") : null;
                    dialog.IsSecondaryButtonEnabled = model.CanContinue;
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Close_Button");
                    break;
                case CrossNasCopyMoveState.Completed:
                    dialog.PrimaryButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.CloseButtonText = null;
                    break;
                case CrossNasCopyMoveState.SourceDeletionReady:
                    dialog.PrimaryButtonText = localization.Get("CrossNasDeleteSources");
                    dialog.IsPrimaryButtonEnabled = model.CanDeleteSources;
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Close_Button");
                    break;
                case CrossNasCopyMoveState.ConfirmingSourceDeletion:
                    dialog.PrimaryButtonText = localization.Get("CrossNasConfirmDeleteSources");
                    dialog.SecondaryButtonText = localization.Get("FileCopyMove_Cancel_Button");
                    dialog.IsSecondaryButtonEnabled = true;
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.DefaultButton = ContentDialogButton.Secondary;
                    break;
                case CrossNasCopyMoveState.TargetUnavailable:
                    dialog.PrimaryButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.CloseButtonText = null;
                    dialog.IsPrimaryButtonEnabled = true;
                    break;
                case CrossNasCopyMoveState.Failure:
                    dialog.PrimaryButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.CloseButtonText = null;
                    break;
                default:
                    dialog.PrimaryButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.CloseButtonText = null;
                    break;
            }
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (model.State is CrossNasCopyMoveState.Completed or CrossNasCopyMoveState.Failure or
                CrossNasCopyMoveState.TargetUnavailable or CrossNasCopyMoveState.Unsupported)
            {
                return;
            }
            args.Cancel = true;
            {
                if (model.State == CrossNasCopyMoveState.ChoosingTarget &&
                    model.SelectedTarget is null &&
                    model.TargetProfiles.Count == 1)
                {
                    await model.SelectTargetAndLoadAsync(model.TargetProfiles[0]);
                }
                else if (model.State == CrossNasCopyMoveState.ConfirmingSourceDeletion)
                {
                    await model.ConfirmSourceDeletionAsync();
                }
                else if (model.CanDeleteSources)
                {
                    model.RequestSourceDeletionConfirmation();
                }
                else if (model.CanRefresh)
                {
                    await model.RefreshAsync();
                }
                else if (model.CanSubmit)
                {
                    await model.SubmitAsync();
                }
                await RenderAsync();
            }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (model.State == CrossNasCopyMoveState.ConfirmingSourceDeletion) model.CancelSourceDeletionConfirmation();
            else await model.ContinueAsync();
            await RenderAsync();
        };
        System.ComponentModel.PropertyChangedEventHandler changed = (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            if (ReferenceEquals(_crossNasCopyMoveModel, model)) _ = RenderAsync();
        });
        model.PropertyChanged += changed;

        dialog.Closing += (_, args) =>
        {
            if (model.IsTransferring)
            {
                args.Cancel = true;
                model.Cancel();
            }
        };

        dialog.CloseButtonClick += (_, _) =>
        {
            if (model.IsTransferring)
            {
                model.Cancel();
            }
        };

        await model.LoadHistoryAsync(includeCompleted: restored is not null);
        if (restored is not null && model.History.FirstOrDefault(item => item.Id == restored.Id) is { } original)
            await model.RestoreAsync(original);
        await RenderAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            model.PropertyChanged -= changed;
            model.Dispose();
            _crossNasCopyMoveModel = null;
            _crossNasCopyMoveDialog = null;
        }
    }

    private static FrameworkElement BuildCrossNasContent(
        CrossNasCopyMoveViewModel model,
        LocalizationService localization,
        Func<Task> render)
    {
        var panel = new StackPanel { Spacing = 12 };

        // 源项目
        var sourceLabel = new TextBlock
        {
            Text = model.Source.IsDirectory
                ? localization.Get("CrossNasSourceFolder")
                : localization.Get("CrossNasSourceFile"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        panel.Children.Add(sourceLabel);

        var sourceName = new TextBlock
        {
            Text = model.Source.Name,
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetName(sourceName, model.Source.Name);
        panel.Children.Add(sourceName);

        // 目标 NAS 选择
        if (model.State == CrossNasCopyMoveState.ChoosingTarget)
        {
            if (model.History.Count > 0)
            {
                panel.Children.Add(new TextBlock { Text = localization.Get("CrossNasHistory"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                foreach (var previous in model.History)
                {
                    var target = model.TargetProfiles.FirstOrDefault(item => item.Id == previous.TargetProfileId);
                    var resume = new Button { Content = localization.Format("CrossNasHistoryItem", target?.DisplayName ?? previous.Name,
                        previous.DestinationFolderPath), MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch };
                    resume.Click += async (_, _) => { await model.RestoreAsync(previous); await render(); };
                    panel.Children.Add(resume);
                }
            }
            var targetLabel = new TextBlock
            {
                Text = localization.Get("CrossNasSelectTarget"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Margin = new Thickness(0, 8, 0, 0),
            };
            panel.Children.Add(targetLabel);

            var profileList = new ListView
            {
                ItemsSource = model.TargetProfiles,
                MaxHeight = 200,
                MinHeight = 48,
            };
            profileList.ItemTemplate = CreateProfileItemTemplate();
            profileList.SelectionChanged += async (_, _) =>
            {
                if (profileList.SelectedItem is NasProfile target)
                {
                    await model.SelectTargetAndLoadAsync(target);
                    await render();
                }
            };
            AutomationProperties.SetName(profileList, localization.Get("CrossNasSelectTarget"));
            panel.Children.Add(profileList);
            return panel;
        }

        // 已选目标 NAS
        if (model.SelectedTarget is { } targetProfile)
        {
            var targetDisplay = new TextBlock
            {
                Text = localization.Format("CrossNasTargetLabel", targetProfile.DisplayName),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Margin = new Thickness(0, 8, 0, 0),
            };
            panel.Children.Add(targetDisplay);
        }

        // 目标文件夹浏览
        if (model.State is CrossNasCopyMoveState.ChoosingDestination or
            CrossNasCopyMoveState.LoadingFolders)
        {
            var destLabel = new TextBlock
            {
                Text = localization.Get("FileCopyMove_Destination_Label"),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            panel.Children.Add(destLabel);

            var destPath = new TextBlock
            {
                Text = string.IsNullOrEmpty(model.DestinationPath)
                    ? "/"
                    : model.DestinationPath,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)
                    Application.Current.Resources["TextFillColorSecondaryBrush"],
            };
            panel.Children.Add(destPath);

            if (model.DestinationPath.Length > 0)
            {
                var upButton = new Button
                {
                    Content = new SymbolIcon(Symbol.Up),
                    MinHeight = 44,
                };
                AutomationProperties.SetName(upButton,
                    localization.Get("FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
                upButton.Click += async (_, _) =>
                {
                    var parent = GetParentPath(model.DestinationPath);
                    await model.LoadFoldersAsync(parent, destinationCanWrite: true);
                    await render();
                };
                panel.Children.Add(upButton);
            }

            if (model.State == CrossNasCopyMoveState.LoadingFolders)
            {
                var progressRing = new ProgressRing
                {
                    IsActive = true,
                    Width = 24,
                    Height = 24,
                };
                panel.Children.Add(progressRing);
            }
            else
            {
                if (model.Folders.Count == 0 && model.DestinationPath.Length == 0)
                    panel.Children.Add(new TextBlock { Text = localization.Get("CrossNasNoFolders"), TextWrapping = TextWrapping.Wrap });
                var folderList = new ListView
                {
                    ItemsSource = model.Folders,
                    MaxHeight = 300,
                    MinHeight = 48,
                };
                folderList.ItemTemplate = CreateFolderItemTemplate(localization);
                folderList.SelectionChanged += async (_, _) =>
                {
                    if (folderList.SelectedItem is FileCopyMoveFolder folder)
                    {
                        await model.LoadFoldersAsync(folder.Path, destinationCanWrite: true);
                        await render();
                    }
                };
                AutomationProperties.SetName(folderList,
                    localization.Get("FileCopyMove_A11y_DestinationTree"));
                panel.Children.Add(folderList);
            }
        }

        // 进度
        if (model.IsTransferring)
        {
            var progressLabel = new TextBlock
            {
                Text = model.State == CrossNasCopyMoveState.DeletingSources ? localization.Get("CrossNasSourceDeleting") :
                    model.State == CrossNasCopyMoveState.Refreshing ? localization.Get("CrossNasRefreshing") : model.TotalBytes > 0
                    ? localization.Format("CrossNasProgress",
                        model.TransferredBytes, model.TotalBytes)
                    : localization.Get("CrossNasProgressIndeterminate"),
                TextWrapping = TextWrapping.Wrap,
            };
            panel.Children.Add(progressLabel);

            var progressBar = new ProgressBar
            {
                IsIndeterminate = model.TotalBytes == 0 || model.State is CrossNasCopyMoveState.DeletingSources or CrossNasCopyMoveState.Refreshing,
                Maximum = model.TotalBytes > 0 ? model.TotalBytes : 100,
                Value = model.TotalBytes > 0 ? model.TransferredBytes : 0,
                MinHeight = 4,
            };
            panel.Children.Add(progressBar);
        }

        if (model.Outcome is { Items.Count: > 0 } outcome)
        {
            panel.Children.Add(new TextBlock { Text = localization.Format("CrossNasSummary", outcome.Result.Counts.Succeeded,
                outcome.Result.Counts.Failed, outcome.Items.Count(item => item.State == CrossNasTransferItemState.NotStarted),
                outcome.Items.Count(item => item.State == CrossNasTransferItemState.ResultUnavailable)), TextWrapping = TextWrapping.Wrap });
            var results = new ListView
            {
                MaxHeight = 220, SelectionMode = ListViewSelectionMode.None,
                ItemsSource = outcome.Items.Select(item => new
                {
                    Name = item.SourcePath[(item.SourcePath.LastIndexOf('/') + 1)..],
                    Status = localization.Get(item.State switch
                    {
                        CrossNasTransferItemState.Copied => "CrossNasItemCopied",
                        CrossNasTransferItemState.Failed => "CrossNasItemFailed",
                        CrossNasTransferItemState.ResultUnavailable => "CrossNasItemUnavailable",
                        CrossNasTransferItemState.Copying => "CrossNasProgressIndeterminate",
                        CrossNasTransferItemState.Cancelled => "FileStructureItemCancelled",
                        _ => "DownloadBatchNotStarted",
                    }),
                }).ToArray(),
                ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
                    "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><StackPanel Margin='4,6'><TextBlock Text='{Binding Name}' TextWrapping='Wrap'/><TextBlock Text='{Binding Status}' TextWrapping='Wrap'/></StackPanel></DataTemplate>"),
            };
            AutomationProperties.SetName(results, localization.Get("CrossNasResults"));
            panel.Children.Add(results);
        }

        if (model.State == CrossNasCopyMoveState.ConfirmingSourceDeletion)
            panel.Children.Add(new InfoBar { IsOpen = true, Severity = InfoBarSeverity.Warning,
                Title = localization.Get("CrossNasDeleteSources"),
                Message = localization.Format("CrossNasDeleteSourcesWarning", model.Source.Name) });
        else if (model.State == CrossNasCopyMoveState.SourceDeletionReady)
            panel.Children.Add(new InfoBar { IsOpen = true, Severity = InfoBarSeverity.Success,
                Title = localization.Get("CrossNasCompleted"), Message = localization.Get("CrossNasOriginalsKept") });

        if (model.Outcome?.SourceDeletion is { } deletion)
        {
            panel.Children.Add(new TextBlock { Text = localization.Format("CrossNasDeleteSummary", deletion.Result.Counts.Succeeded,
                deletion.Result.Counts.Failed, deletion.Items.Count(item => item.State == CrossNasSourceDeletionState.NotStarted),
                deletion.Result.Counts.Unknown), TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(new ListView { MaxHeight = 150, SelectionMode = ListViewSelectionMode.None,
                ItemsSource = deletion.Items.Select(item => localization.Format("CrossNasDeleteItem", item.SourcePath[(item.SourcePath.LastIndexOf('/') + 1)..],
                    localization.Get(item.State switch
                    {
                        CrossNasSourceDeletionState.Deleted => "CrossNasSourceDeleted",
                        CrossNasSourceDeletionState.Deleting => "CrossNasSourceDeleting",
                        CrossNasSourceDeletionState.Failed => "CrossNasSourceDeleteFailed",
                        CrossNasSourceDeletionState.ResultUnavailable => "CrossNasItemUnavailable",
                        _ => "DownloadBatchNotStarted",
                    }))).ToArray() });
        }

        // 结果
        if (model.State == CrossNasCopyMoveState.Completed)
        {
            var infoBar = new InfoBar
            {
                Severity = InfoBarSeverity.Success,
                Title = localization.Get(model.Outcome?.SourceDeletion?.Result.Status == MutationResultStatus.ConfirmedSuccess ? "CrossNasSourceDeleteCompleted" : "CrossNasCompleted"),
                IsOpen = true,
            };
            AutomationProperties.SetLiveSetting(infoBar,
                AutomationLiveSetting.Assertive);
            panel.Children.Add(infoBar);
        }
        else if (model.State == CrossNasCopyMoveState.Unsupported)
        {
            var infoBar = new InfoBar
            {
                Severity = InfoBarSeverity.Warning,
                Title = localization.Get("CrossNasUnsupportedTitle"),
                Message = localization.Get("CrossNasUnsupportedMessage"),
                IsOpen = true,
            };
            AutomationProperties.SetLiveSetting(infoBar,
                AutomationLiveSetting.Assertive);
            panel.Children.Add(infoBar);
        }
        else if (model.State == CrossNasCopyMoveState.TargetUnavailable)
        {
            var infoBar = new InfoBar
            {
                Severity = InfoBarSeverity.Warning,
                Title = localization.Get("CrossNasTargetUnavailableTitle"),
                Message = localization.Get("CrossNasTargetUnavailableMessage"),
                IsOpen = true,
            };
            AutomationProperties.SetLiveSetting(infoBar,
                AutomationLiveSetting.Assertive);
            panel.Children.Add(infoBar);
        }
        else if (model.State is CrossNasCopyMoveState.Failure or CrossNasCopyMoveState.Recoverable)
        {
            var infoBar = new InfoBar
            {
                Severity = model.State == CrossNasCopyMoveState.Recoverable ? InfoBarSeverity.Warning : InfoBarSeverity.Error,
                Title = localization.Get(model.Outcome?.SourceDeletion is not null ? "CrossNasSourceDeleteIncomplete" : model.Outcome?.IsRunning == true ? "CrossNasProgressIndeterminate" : model.State == CrossNasCopyMoveState.Recoverable ? "CrossNasIncomplete" : "CrossNasFailed"),
                Message = model.Outcome?.RecoveryStorageUnavailable == true ? localization.Get("CrossNasRecoveryStorageFailed") :
                    model.Outcome?.SourceDeletion is not null ? localization.Get("CrossNasDeleteRecovery") :
                    model.State == CrossNasCopyMoveState.Recoverable ? localization.Get("CrossNasRecoveryMessage") : CrossNasFailureMessage(model.ResultMessage, localization),
                IsOpen = true,
            };
            AutomationProperties.SetLiveSetting(infoBar,
                AutomationLiveSetting.Assertive);
            panel.Children.Add(infoBar);
        }

        return panel;
    }

    private static DataTemplate CreateProfileItemTemplate()
    {
        var templateXaml =
            @"<DataTemplate xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"">
                <TextBlock Text=""{Binding DisplayName}"" Margin=""8,6"" />
            </DataTemplate>";
        return (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(templateXaml);
    }

    private static DataTemplate CreateFolderItemTemplate(LocalizationService localization)
    {
        var templateXaml =
            @"<DataTemplate xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"">
                <StackPanel Orientation=""Horizontal"" Spacing=""8"" Margin=""4,2"">
                    <FontIcon Glyph=""&#xE8B7;"" FontSize=""16"" />
                    <TextBlock Text=""{Binding Name}"" VerticalAlignment=""Center"" />
                </StackPanel>
            </DataTemplate>";
        return (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(templateXaml);
    }

    private static string GetParentPath(string path)
    {
        if (string.IsNullOrEmpty(path) || path == "/") return string.Empty;
        var lastSlash = path.LastIndexOf('/');
        return lastSlash <= 0 ? string.Empty : path[..lastSlash];
    }

    private static string CrossNasFailureMessage(
        string? diagnosticTag,
        LocalizationService localization) =>
        diagnosticTag switch
        {
            "file.cross-nas.readback-unavailable" or
            "file.cross-nas.readback-mismatch" or
            "file.cross-nas.readback-unverified" or
            "file.cross-nas.tree-readback-mismatch" =>
                localization.Get("CrossNasFailedNeedsReviewMessage"),
            "file.cross-nas.target-not-found" or
            "file.cross-nas.target-no-capability" or
            "file.cross-nas.no-second-session" or
            "file.cross-nas.no-resolver" =>
                localization.Get("CrossNasTargetUnavailableMessage"),
            "file.cross-nas.recovery-unavailable" => localization.Get("CrossNasRecoveryStorageFailed"),
            "file.cross-nas.same-profile" =>
                localization.Get("CrossNasSameTargetMessage"),
            _ => localization.Get("CrossNasFailedMessage"),
        };
}
