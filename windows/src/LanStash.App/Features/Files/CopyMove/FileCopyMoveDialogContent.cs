using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Features.Files.CopyMove;

internal static class FileCopyMoveDialogContent
{
    internal static FrameworkElement Build(
        FileCopyMoveViewModel model,
        LocalizationService localization,
        Func<Task> render)
    {
        var panel = new StackPanel { Width = 480, MaxWidth = 480, Spacing = 12 };
        var source = new TextBlock
        {
            Text = model.Source.Name,
            TextWrapping = TextWrapping.WrapWholeWords,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(source, AutomationHeadingLevel.Level2);
        AutomationProperties.SetName(source, localization.Get(model.Source.IsDirectory
            ? "FileCopyMove_SourceFolder_Label"
            : "FileCopyMove_Source_Label"));
        panel.Children.Add(source);

        if (model.State is FileCopyMovePresentationState.ChoosingDestination or
            FileCopyMovePresentationState.LoadingFolders)
        {
            var path = new TextBlock
            {
                Text = string.IsNullOrEmpty(model.DestinationPath)
                    ? localization.Get("FileCopyMove_Destination_Placeholder")
                    : model.DestinationPath,
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetName(path, localization.Get("FileCopyMove_Destination_Label"));
            panel.Children.Add(path);

            var up = new Button
            {
                Content = new SymbolIcon(Symbol.Up),
                MinWidth = 48,
                MinHeight = 48,
                IsEnabled = FileCopyMoveViewModel.IsDestination(model.DestinationPath),
            };
            AutomationProperties.SetName(up, localization.Get(
                "FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
            up.Click += async (_, _) =>
            {
                var separator = model.DestinationPath.LastIndexOf('/');
                var parent = separator > 0 ? model.DestinationPath[..separator] : string.Empty;
                var load = model.LoadFoldersAsync(parent, model.IsKnownWritableFolder(parent));
                await render();
                await load;
                await render();
            };
            panel.Children.Add(up);

            if (model.State == FileCopyMovePresentationState.LoadingFolders)
            {
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 40, Height = 40 });
            }
            else
            {
                var list = new ListView
                {
                    ItemsSource = model.Folders,
                    IsItemClickEnabled = true,
                    SelectionMode = ListViewSelectionMode.None,
                    MaxHeight = 320,
                    ItemTemplate = BuildFolderTemplate(),
                };
                AutomationProperties.SetName(list, localization.Get("FileCopyMove_A11y_DestinationTree"));
                list.ItemClick += async (_, args) =>
                {
                    if (args.ClickedItem is not FileCopyMoveFolder folder) return;
                    var load = model.LoadFoldersAsync(folder.Path, folder.CanWrite);
                    await render();
                    await load;
                    await render();
                };
                panel.Children.Add(list);
            }
            return panel;
        }

        var message = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State == FileCopyMovePresentationState.ConfirmedSuccess
                ? InfoBarSeverity.Success
                : model.State is FileCopyMovePresentationState.NeedsReview
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Error,
            Message = localization.Get(MessageKey(model.State, model.Operation, model.Source.IsDirectory)),
        };
        AutomationProperties.SetName(message, localization.Get("FileCopyMove_A11y_Status"));
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Assertive);
        panel.Children.Add(message);
        return panel;
    }

    internal static string TitleKey(bool isDirectory, FileCopyMoveOperation operation) =>
        (isDirectory, operation) switch
        {
            (true, FileCopyMoveOperation.Copy) => "FileCopyMove_Dialog_TitleCopyFolder",
            (true, FileCopyMoveOperation.Move) => "FileCopyMove_Dialog_TitleMoveFolder",
            (false, FileCopyMoveOperation.Copy) => "FileCopyMove_Dialog_TitleCopy",
            _ => "FileCopyMove_Dialog_TitleMove",
        };

    internal static DataTemplate BuildFolderTemplate()
    {
        const string xaml = "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'><Grid MinHeight='48' Padding='8'><TextBlock Text='{Binding Name}' VerticalAlignment='Center' TextTrimming='CharacterEllipsis'/></Grid></DataTemplate>";
        return (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(xaml);
    }

    private static string MessageKey(
        FileCopyMovePresentationState state,
        FileCopyMoveOperation operation,
        bool isDirectory) => state switch
        {
            FileCopyMovePresentationState.Submitting => operation == FileCopyMoveOperation.Copy ? "FileCopyMove_Status_Copying" : "FileCopyMove_Status_Moving",
            FileCopyMovePresentationState.ConfirmedSuccess when isDirectory => operation == FileCopyMoveOperation.Copy ? "FileCopyMove_Status_SuccessCopyFolder" : "FileCopyMove_Status_SuccessMoveFolder",
            FileCopyMovePresentationState.ConfirmedSuccess => operation == FileCopyMoveOperation.Copy ? "FileCopyMove_Status_SuccessCopy" : "FileCopyMove_Status_SuccessMove",
            FileCopyMovePresentationState.NeedsReview => "FileCopyMove_Status_Unknown",
            FileCopyMovePresentationState.CancelledBeforeSubmission => "FileCopyMove_Status_Cancelled",
            FileCopyMovePresentationState.Conflict => isDirectory ? "FileCopyMove_Status_ConflictFolder" : "FileCopyMove_Status_Conflict",
            FileCopyMovePresentationState.PermissionDenied => "FileCopyMove_Status_Permission",
            FileCopyMovePresentationState.Unsupported => isDirectory ? "FileCopyMove_Status_UnsupportedFolder" : "FileCopyMove_Status_Unsupported",
            _ => isDirectory ? "FileCopyMove_Status_ErrorFolder" : "FileCopyMove_Status_Error",
        };
}
