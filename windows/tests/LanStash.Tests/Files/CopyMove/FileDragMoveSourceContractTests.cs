namespace LanStash.Tests.Files.CopyMove;

public sealed class FileDragMoveSourceContractTests
{
    [Fact]
    public void DropUsesPrivateTicketAndSharedConfirmationInsteadOfDirectSubmission()
    {
        var source = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var start = source.IndexOf("private void FileList_DragItemsStarting", StringComparison.Ordinal);
        var end = source.IndexOf("private void ShowDragMoveUndo", start, StringComparison.Ordinal);
        var drop = source[start..end];
        Assert.Contains("SetData(FileDragMoveSession.DataFormat, ticket)", drop);
        Assert.Contains("session.TryConsume", drop);
        Assert.Contains("ShowBatchCopyMoveDialogAsync", drop);
        Assert.DoesNotContain("SetText(", drop); Assert.DoesNotContain("GetTextAsync", drop);
        Assert.DoesNotContain("SubmitAsync", drop); Assert.DoesNotContain("destinationCanWrite: true", drop);
    }
    [Fact]
    public void UndoUsesConfirmedItemsAndOneShotExpiringAuthority()
    {
        var source = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var batch = Read("windows/src/LanStash.App/Views/FilesPage.BatchCopyMove.cs");
        Assert.Contains("ReferenceEquals(_dragMoveUndo, undo)", source);
        Assert.Contains("undo.ExpiresAt <= DateTime.UtcNow", source);
        Assert.Contains("ShowBatchCopyMoveDialogAsync(FileCopyMoveOperation.Move, undo.Items, undo.SourceFolder", source);
        Assert.Contains("model.ConfirmedItems", batch);
        Assert.Contains("ShowDragMoveUndo(confirmedItems", batch);
        Assert.Contains("summary.ConfirmedCount == sources.Length", batch);
        Assert.Contains("folder.Path == initialDestination && folder.CanWrite", batch);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", batch);
        Assert.Contains("ClearRemoteDragState();", source);
    }
    private static string Read(string relative)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        { var path = Path.Combine(directory.FullName, relative); if (File.Exists(path)) return File.ReadAllText(path); }
        throw new FileNotFoundException(relative);
    }
}
