using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Features.Files.Recycle;

internal static class FileRecycleBatchDialogContent
{
    public static StackPanel Build(
        FileRecycleBatchViewModel model,
        LocalizationService localization,
        string confirmationMessageKey = "FileRecycleBatchConfirmMessage")
    {
        var panel = new StackPanel
        {
            Width = 460,
            MaxWidth = 460,
            Spacing = 12,
        };
        var selected = new TextBlock
        {
            Text = localization.Format("FileRecycleBatchSelectedSummary", model.Sources.Count),
            TextWrapping = TextWrapping.WrapWholeWords,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(selected, AutomationHeadingLevel.Level2);
        panel.Children.Add(selected);

        if (model.State == FileRecycleBatchState.Confirming)
        {
            panel.Children.Add(new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Warning,
                Message = localization.Get(confirmationMessageKey),
            });
            return panel;
        }
        if (model.State == FileRecycleBatchState.Submitting)
        {
            var progress = new ProgressBar
            {
                Minimum = 0,
                Maximum = model.Sources.Count,
                Value = model.ProcessedCount,
                Height = 4,
            };
            AutomationProperties.SetName(
                progress,
                localization.Get(model.Operation == FileRecycleOperation.Restore
                    ? "FileRestoreBatchProgressAutomationName"
                    : "FileRecycleBatchProgressAutomationName"));
            panel.Children.Add(progress);
            var status = new TextBlock
            {
                Text = localization.Format(
                    model.Operation == FileRecycleOperation.Restore
                        ? "FileRestoreBatchWorking"
                        : "FileRecycleBatchWorking",
                    Math.Min(model.ProcessedCount + 1, model.Sources.Count),
                    model.Sources.Count),
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
            panel.Children.Add(status);
            return panel;
        }

        var message = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State == FileRecycleBatchState.Completed &&
                model.Summary.NeedsReviewCount == 0 && model.Summary.FailedCount == 0 &&
                model.Summary.CancelledCount == 0 && model.Summary.NotStartedCount == 0
                ? InfoBarSeverity.Success
                : InfoBarSeverity.Warning,
            Message = model.State == FileRecycleBatchState.Completed
                ? FormatSummary(localization, model.Summary, model.Operation)
                : localization.Get(model.Operation == FileRecycleOperation.Restore
                    ? "FileRestoreBatchUnsupported"
                    : "FileRecycleBatchUnsupported"),
        };
        AutomationProperties.SetName(
            message,
            localization.Get(model.Operation == FileRecycleOperation.Restore
                ? "FileRestoreBatchStatusAutomationName"
                : "FileRecycleBatchStatusAutomationName"));
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Assertive);
        panel.Children.Add(message);
        return panel;
    }

    public static string FormatSummary(
        LocalizationService localization,
        FileRecycleBatchSummary summary,
        FileRecycleOperation operation = FileRecycleOperation.MoveToRecycle) =>
        localization.Format(
            operation == FileRecycleOperation.Restore
                ? "FileRestoreBatchSummary"
                : "FileRecycleBatchSummary",
            summary.SelectedCount,
            summary.ConfirmedCount,
            summary.NeedsReviewCount,
            summary.FailedCount,
            summary.CancelledCount,
            summary.NotStartedCount);
}
