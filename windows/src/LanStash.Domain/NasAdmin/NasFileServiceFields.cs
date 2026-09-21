namespace LanStash.Domain;

[Flags]
public enum NasFileServiceFields
{
    None = 0,
    Smb = 1 << 0,
    Nfs = 1 << 1,
    Ftp = 1 << 2,
    Ftps = 1 << 3,
    FtpPort = 1 << 4,
    Sftp = 1 << 5,
    SftpPort = 1 << 6,
    Ssdp = 1 << 7,
    Bonjour = 1 << 8,
    TimeMachine = 1 << 9,
}
