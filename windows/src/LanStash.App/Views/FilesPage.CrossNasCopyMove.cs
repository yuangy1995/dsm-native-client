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
    private Func<Guid, IFileCopyMoveFolderSource>? CrossNasFolderSourceFactory { get; set; }

    internal void SetCrossNasDependencies(
        IReadOnlyList<NasProfile> targetProfiles,
        Func<Guid, IFileCopyMoveFolderSource> folderSourceFactory)
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

    private async Task ShowCrossNasCopyMoveAsync(FileCopyMoveOperation operation)
    {
        if (operation != FileCopyMoveOperation.Copy ||
            _copyMoveRepository?.CrossNasAvailability.CanCrossCopy != true)
            return;
        if (_viewModel.SelectedItem is not { } selected ||
            _copyMoveRepository is null ||
            CrossNasTargetProfiles is null ||
            CrossNasFolderSourceFactory is null)
            return;

        await ClosePreviewAsync();

        var model = new CrossNasCopyMoveViewModel(
            _copyMoveRepository,
            _profileId,
            selected.Item,
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
            DefaultButton = ContentDialogButton.Primary,
            MinWidth = 480,
            MaxWidth = 480,
        };

        _crossNasCopyMoveModel = model;
        _crossNasCopyMoveDialog = dialog;

        async Task RenderAsync()
        {
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
                    dialog.PrimaryButtonText = null;
                    dialog.CloseButtonText = localization.Get("FileCopyMove_Cancel_Button");
                    break;
                case CrossNasCopyMoveState.Completed:
                    dialog.PrimaryButtonText = localization.Get("FileCopyMove_Close_Button");
                    dialog.CloseButtonText = null;
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
            if (model.State == CrossNasCopyMoveState.Completed ||
                model.State == CrossNasCopyMoveState.Failure)
            {
                return;
            }
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                if (model.State == CrossNasCopyMoveState.ChoosingTarget &&
                    model.SelectedTarget is null &&
                    model.TargetProfiles.Count == 1)
                {
                    await model.SelectTargetAndLoadAsync(model.TargetProfiles[0]);
                }
                else if (model.CanSubmit)
                {
                    await model.SubmitAsync();
                }
                await RenderAsync();
            }
            finally
            {
                deferral.Complete();
            }
        };

        dialog.Closing += (_, args) =>
        {
            if (model.State == CrossNasCopyMoveState.Transferring)
            {
                args.Cancel = true;
                model.Cancel();
            }
        };

        dialog.CloseButtonClick += (_, _) =>
        {
            if (model.State == CrossNasCopyMoveState.Transferring)
            {
                model.Cancel();
            }
        };

        await RenderAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
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
                Text = $"{localization.Get("CrossNasSelectedTarget")}: {targetProfile.DisplayName}",
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
        if (model.State == CrossNasCopyMoveState.Transferring)
        {
            var progressLabel = new TextBlock
            {
                Text = model.TotalBytes > 0
                    ? string.Format(localization.Get("CrossNasProgress"),
                        model.TransferredBytes, model.TotalBytes)
                    : localization.Get("CrossNasProgressIndeterminate"),
                TextWrapping = TextWrapping.Wrap,
            };
            panel.Children.Add(progressLabel);

            var progressBar = new ProgressBar
            {
                IsIndeterminate = model.TotalBytes == 0,
                Maximum = model.TotalBytes > 0 ? model.TotalBytes : 100,
                Value = model.TotalBytes > 0 ? model.TransferredBytes : 0,
                MinHeight = 4,
            };
            panel.Children.Add(progressBar);
        }

        // 结果
        if (model.State == CrossNasCopyMoveState.Completed)
        {
            var infoBar = new InfoBar
            {
                Severity = InfoBarSeverity.Success,
                Title = localization.Get("CrossNasCompleted"),
                IsOpen = true,
            };
            AutomationProperties.SetLiveSetting(infoBar,
                AutomationLiveSetting.Assertive);
            panel.Children.Add(infoBar);
        }
        else if (model.State == CrossNasCopyMoveState.Failure)
        {
            var infoBar = new InfoBar
            {
                Severity = InfoBarSeverity.Error,
                Title = localization.Get("CrossNasFailed"),
                Message = model.ResultMessage,
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
}
