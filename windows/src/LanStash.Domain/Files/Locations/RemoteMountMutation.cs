namespace LanStash.Domain;

public enum RemoteMountAction { Create, Update, Disconnect }
public enum RemoteMountStage { VerifyingConnection, VerifyingDisconnection, ReadyToConnect, ReadyToDisconnectPrevious, Complete, Rejected }

public sealed record RemoteMountMutationRequest(Guid ProfileId, Guid RequestId, RemoteMountAction Action,
    RemoteMountConnection? Baseline, RemoteMountDraft? Desired, bool RiskConfirmed)
{
    public override string ToString() => nameof(RemoteMountMutationRequest);
}

// 可恢复的表单仅包含非密码字段，避免关闭窗口后仍持有远程共享密码。
public sealed record RemoteMountSetup(string Server, string RemotePath, string MountPoint, string? Username = null,
    string? Domain = null, FileRemoteProtocol Protocol = FileRemoteProtocol.Cifs,
    RemoteMountNfsVersion NfsVersion = RemoteMountNfsVersion.V3, RemoteMountNfsTransport NfsTransport = RemoteMountNfsTransport.Tcp)
{
    public RemoteMountDraft ToDraft(string? password = null) => new(Server, RemotePath, MountPoint, Username, password, Domain, false, Protocol,
        nfsVersion: NfsVersion, nfsTransport: NfsTransport);
    public static RemoteMountSetup FromDraft(RemoteMountDraft draft) => new(draft.Server, draft.RemotePath, draft.MountPoint,
        draft.Username, draft.Domain, draft.Protocol, draft.NfsVersion, draft.NfsTransport);
    public override string ToString() => nameof(RemoteMountSetup);
}

public sealed record RemoteMountContinuation(RemoteMountConnection? Baseline, RemoteMountSetup? Setup)
{
    public override string ToString() => nameof(RemoteMountContinuation);
}

public sealed record RemoteMountProgress(Guid RequestId, RemoteMountAction Action, string MountPoint, string? PreviousMountPoint,
    RemoteMountStage Stage, MutationResult Outcome, RemoteMountContinuation? Continuation = null)
{
    public bool CanContinue => Stage is RemoteMountStage.ReadyToConnect or RemoteMountStage.ReadyToDisconnectPrevious;
    public override string ToString() => nameof(RemoteMountProgress);
}
