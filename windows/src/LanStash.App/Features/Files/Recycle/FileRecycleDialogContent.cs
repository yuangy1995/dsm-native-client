using LanStash.App.Localization;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Features.Files.Recycle;

internal static class FileRecycleDialogContent
{
    public static StackPanel Build(FileRecycleViewModel model, LocalizationService localization)
    {
        var panel = new StackPanel { Width = 480, MaxWidth = 480, Spacing = 12 };
        var source = new TextBlock
        {
            Text = model.Source.Name,
            TextWrapping = Microsoft.UI.Xaml.TextWrapping.WrapWholeWords,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(source, AutomationHeadingLevel.Level2);
        AutomationProperties.SetName(source, localization.Get("FileRecycleSourceLabel"));
        panel.Children.Add(source);

        var destination = new TextBlock
        {
            Text = model.DestinationPath,
            TextWrapping = Microsoft.UI.Xaml.TextWrapping.WrapWholeWords,
        };
        AutomationProperties.SetName(destination, localization.Get("FileRecycleDestinationLabel"));
        panel.Children.Add(destination);

        if (model.State == FileRecyclePresentationState.Confirming)
        {
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get(model.Operation == FileRecycleOperation.MoveToRecycle
                    ? "FileRecycleMoveMessage"
                    : "FileRecycleRestoreMessage"),
                TextWrapping = Microsoft.UI.Xaml.TextWrapping.WrapWholeWords,
            });
            return panel;
        }

        if (model.State == FileRecyclePresentationState.Submitting)
        {
            var statusMessage = localization.Get(model.Operation == FileRecycleOperation.MoveToRecycle
                ? "FileRecycleWorkingMove"
                : "FileRecycleWorkingRestore");
            var progress = new ProgressRing { IsActive = true, Width = 40, Height = 40 };
            AutomationProperties.SetName(progress, statusMessage);
            panel.Children.Add(progress);
            var status = new TextBlock
            {
                Text = statusMessage,
                TextWrapping = Microsoft.UI.Xaml.TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetName(status, statusMessage);
            AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
            panel.Children.Add(status);
            return panel;
        }

        var message = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State switch
            {
                FileRecyclePresentationState.ConfirmedSuccess => InfoBarSeverity.Success,
                FileRecyclePresentationState.NeedsReview => InfoBarSeverity.Warning,
                FileRecyclePresentationState.CancelledBeforeSubmission => InfoBarSeverity.Informational,
                _ => InfoBarSeverity.Error,
            },
            Title = localization.Get(TitleKey(model.State, model.Operation)),
            Message = localization.Get(MessageKey(model.State, model.Operation)),
        };
        AutomationProperties.SetName(message, localization.Get("FileRecycleStatusAutomationName"));
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Assertive);
        panel.Children.Add(message);
        return panel;
    }

    private static string TitleKey(
        FileRecyclePresentationState state,
        FileRecycleOperation operation) => state switch
    {
        FileRecyclePresentationState.NeedsReview => "FileRecycleReviewTitle",
        FileRecyclePresentationState.PermissionDenied => "FileRecyclePermissionTitle",
        FileRecyclePresentationState.Conflict => "FileRecycleConflictTitle",
        FileRecyclePresentationState.Unsupported => "FileRecycleUnsupportedTitle",
        FileRecyclePresentationState.Failure => "FileRecycleFailureTitle",
        _ => operation == FileRecycleOperation.MoveToRecycle
            ? "FileRecycleMoveTitle"
            : "FileRecycleRestoreTitle",
    };

    private static string MessageKey(
        FileRecyclePresentationState state,
        FileRecycleOperation operation) => state switch
    {
        FileRecyclePresentationState.ConfirmedSuccess => operation == FileRecycleOperation.MoveToRecycle
            ? "FileRecycleMoveSuccessMessage"
            : "FileRecycleRestoreSuccessMessage",
        FileRecyclePresentationState.NeedsReview => "FileRecycleReviewMessage",
        FileRecyclePresentationState.CancelledBeforeSubmission => "FileRecycleCancelledMessage",
        FileRecyclePresentationState.PermissionDenied => "FileRecyclePermissionMessage",
        FileRecyclePresentationState.Conflict => "FileRecycleConflictMessage",
        FileRecyclePresentationState.Unsupported => "FileRecycleUnsupportedMessage",
        _ => "FileRecycleFailureMessage",
    };
}
