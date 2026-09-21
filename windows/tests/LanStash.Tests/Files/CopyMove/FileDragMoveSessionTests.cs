using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileDragMoveSessionTests
{
    private static readonly Guid Profile = Guid.NewGuid();
    private static FileItem File(string name) => new("/share/" + name, name, false, 10, DateTimeOffset.UnixEpoch, null, true, true);
    private static FileItem Folder => new("/share/target", "target", true, 0, null, null, true, true);
    [Fact]
    public void ValidTicketBindsSnapshotAndIsConsumedOnce()
    {
        var item = File("synthetic.txt"); var target = Folder;
        var session = new FileDragMoveSession(Profile, "/share", [item]);
        Assert.True(session.CanDrop(Profile, "/share", [item, target], target));
        Assert.False(session.TryConsume("forged", Profile, "/share", [item, target], target));
        Assert.True(session.TryConsume(session.Ticket, Profile, "/share", [item, target], target));
        Assert.False(session.TryConsume(session.Ticket, Profile, "/share", [item, target], target));
    }
    [Fact]
    public void DifferentProfileLocationAndChangedSourceAreRejected()
    {
        var item = File("synthetic.txt"); var target = Folder;
        var session = new FileDragMoveSession(Profile, "/share", [item]);
        Assert.False(session.CanDrop(Guid.NewGuid(), "/share", [item, target], target));
        Assert.False(session.CanDrop(Profile, "/other", [item, target], target));
        Assert.False(session.CanDrop(Profile, "/share", [item with { Size = 11 }, target], target));
        Assert.False(session.CanDrop(Profile, "/share", [item with { CanDelete = false }, target], target));
        Assert.False(session.CanDrop(Profile, "/share", [target], target));
    }
    [Fact]
    public void ReadOnlyChangedMissingAndSelfTargetsAreRejected()
    {
        var item = File("synthetic.txt"); var target = Folder;
        var session = new FileDragMoveSession(Profile, "/share", [item]);
        var readOnly = target with { CanWrite = false };
        Assert.False(session.CanDrop(Profile, "/share", [item, readOnly], readOnly));
        Assert.False(session.CanDrop(Profile, "/share", [item, readOnly], target));
        Assert.False(session.CanDrop(Profile, "/share", [item], target));
        var folderSession = new FileDragMoveSession(Profile, "/share", [target]);
        Assert.False(folderSession.CanDrop(Profile, "/share", [target], target));
        var nested = target with { Path = target.Path + "/child", Name = "child" };
        Assert.False(folderSession.CanDrop(Profile, "/share", [target, nested], nested));
    }
    [Fact]
    public void InvalidatedOrPartlyInvalidSelectionsCannotBeSilentlyReduced()
    {
        var item = File("synthetic.txt"); var denied = File("denied.txt") with { CanDelete = false }; var target = Folder;
        var invalid = new FileDragMoveSession(Profile, "/share", [item, denied]);
        Assert.False(invalid.CanDrop(Profile, "/share", [item, denied, target], target));
        var session = new FileDragMoveSession(Profile, "/share", [item]); session.Invalidate();
        Assert.False(session.TryConsume(session.Ticket, Profile, "/share", [item, target], target));
    }
}
