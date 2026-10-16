using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosAutomaticExecutionTests
{
    private sealed class Fixture : IDsmApiClient, ISynologyPhotoPreviewConverter, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<string> Paths = [];
        internal readonly SynologyPhotoConversionSupport Support = new(true, true, true);
        internal readonly SynologyPhotoSpace Space;
        internal readonly bool Visible, Thumbnail, Video;
        internal bool Enabled = true, Defect = true, Download = true, Match, ErrorInVideo;
        internal string? Broken, Problem;
        internal long? SourceOwner;
        internal int Uploads, Downloads, ThumbnailConversions, VideoConversions, ThumbnailReads, MediaReads, Saves;
        internal int BrokenWrites => Http.Requests.Count(r => r.Method == "set_broken");
        internal Func<Task>? AfterConvert;
        internal Action? OnUpload;
        internal Action? OnMediaRead;
        internal SynologyPhotoThumbnailSize? MismatchedSize;
        internal bool MismatchedVideo;
        internal Exception? ConversionError;
        internal SynologyPhotoWriteStatus UploadStatus = SynologyPhotoWriteStatus.Accepted, BrokenStatus = SynologyPhotoWriteStatus.Accepted;
        internal SynologyPhoto Photo => Http.Photo with { Id = Http.Photo.Id with { Space = Space }, MediaType = Video ? "video" : "photo",
            Filename = Video ? "synthetic.mp4" : "synthetic.jpg", Description = "synthetic-private-description", Thumbnail = Http.Photo.Thumbnail! with { Space = Space } };
        internal SynologyPhotoAutomaticCandidate Candidate => new(Http.ProfileId, Space, 8, Photo.Filename, Video ? 1 : 0, Thumbnail, Video,
            Visible ? Photo : null, Visible ? SynologyPhotoAutomaticPriority.Standard : SynologyPhotoAutomaticPriority.Background);
        internal Fixture(bool shared = false, bool visible = false, bool thumbnail = true, bool video = false)
        {
            Space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal; Visible = visible; Thumbnail = thumbnail; Video = video;
            Http.Respond = Respond; Http.AccessResponse = name => name == "SYNO.Foto.Setting.User" ? new JsonObject
            { ["enable_home_service"] = Http.HomeEnabled, ["team_space_permission"] = Http.TeamPermission, ["auto_generate_thumbnail"] = Enabled } : null;
            foreach (var prefix in new[] { "SYNO.Foto.", "SYNO.FotoTeam." })
            {
                Http.Capabilities[prefix + "Upload.ConvertedFile"] = new(prefix + "Upload.ConvertedFile", "entry.cgi", 1, 3, "JSON");
                Http.Capabilities[prefix + "RegeneratePreview"] = new(prefix + "RegeneratePreview", "entry.cgi", 1, 1, "JSON");
            }
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, NasProfile? profile = null)
        { var repo = new SynologyPhotosRepository(profile ?? Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store, previewConverter: this); await repo.AccessAsync(); return repo; }
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            JsonObject data;
            if (call.Method == "list_convert_needed") data = Defect ? SynologyPhotosHttpFixture.List(new JsonObject
            { ["unit_id"] = 8, ["filename"] = Photo.Filename, ["type"] = Video ? 1 : 0, ["need_thumbnail"] = Thumbnail, ["need_video"] = Video }) : SynologyPhotosHttpFixture.List();
            else if (call.Api.EndsWith("Browse.Item"))
            {
                var photo = Http.PhotoJson(Video ? "video" : "photo"); photo["filename"] = Photo.Filename; photo["owner_user_id"] = SourceOwner ?? (Space == SynologyPhotoSpace.Shared ? 0 : Http.UserId);
                photo["additional"]!["thumbnail"]!["xl"] = Broken is not null ? "broken" : Defect && Thumbnail ? "ame_defect" : "ready";
                photo["additional"]!["thumbnail"]!["sm"] = Broken == "both" ? "broken" : "ready";
                photo["additional"]!["video_meta"] = new JsonObject { ["video_codec"] = "h264" };
                photo["additional"]!["video_convert_status"] = Broken == "both" ? "broken" : Defect && Video ? "ame_defect" : "ready";
                data = SynologyPhotosHttpFixture.List(photo);
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["download"] = Download, ["manage"] = true } } } };
            else if (call.Method == "set_broken")
            {
                if (BrokenStatus == SynologyPhotoWriteStatus.Unknown) throw new HttpRequestException();
                if (BrokenStatus == SynologyPhotoWriteStatus.Rejected) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                    { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                data = new();
            }
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        private static byte[] Jpeg(byte marker) => [255, 216, 255, marker, 255, 217];
        public Task<SynologyPhotoConversionSupport> SupportAsync(CancellationToken cancellationToken = default) => Task.FromResult(Support);
        public async Task<SynologyPhotoConvertedPreview> ConvertAsync(string source, string mediaType, CancellationToken cancellationToken = default)
        {
            ThumbnailConversions++; Assert.True(File.Exists(source)); if (AfterConvert is not null) await AfterConvert();
            if (!ErrorInVideo && ConversionError is not null) throw ConversionError;
            return new(Jpeg(1), Jpeg(2), Jpeg(3));
        }
        public async Task ConvertVideoAsync(string source, string destination, CancellationToken cancellationToken = default)
        {
            VideoConversions++; Assert.True(File.Exists(source)); Paths.Add(destination);
            if (ErrorInVideo && ConversionError is not null) throw ConversionError;
            await File.WriteAllBytesAsync(destination, [7, 8, 9], cancellationToken);
        }
        public async Task<SynologyPhotoVideoSignature> VideoSignatureAsync(string source, CancellationToken cancellationToken = default)
        {
            if (Problem == "signature") throw new SynologyPhotoConversionException(true);
            var bytes = await File.ReadAllBytesAsync(source, cancellationToken);
            return new(1_000_000, [new("vide", ["avc1"], [65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824], 24, Convert.ToHexString(SHA256.HashData(bytes)))]);
        }
        public async Task<SynologyPhotoBinaryResult> DownloadPhotoAsync(NasProfile profile, DsmSession session, SynologyPhotoMediaRequest request, string destination, long? expectedBytes, bool archive,
            IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            Downloads++; Paths.Add(destination); Assert.Null(expectedBytes); Assert.False(archive); Assert.Equal("[8]", request.Parameters["unit_id"]);
            Assert.Equal(Space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download", request.Capability.Name);
            if (Problem == "download") throw new HttpRequestException();
            await File.WriteAllBytesAsync(destination, new byte[8], cancellationToken); return new("image/jpeg", 8);
        }
        public Task<SynologyPhotoWriteReceipt> UploadPhotoConvertedMediaAsync(NasProfile profile, DsmSession session, ApiCapability capability, long unitId,
            SynologyPhotoConvertedPreview? preview, string? video, CancellationToken cancellationToken = default)
        {
            Uploads++; Assert.Equal(8, unitId); Assert.Equal(Thumbnail, preview is not null); Assert.Equal(Video, video is not null);
            Assert.Equal(Space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Upload.ConvertedFile" : "SYNO.Foto.Upload.ConvertedFile", capability.Name);
            if (video is not null) Assert.True(File.Exists(video)); OnUpload?.Invoke(); if (Problem == "upload-throw") throw new HttpRequestException();
            if (UploadStatus == SynologyPhotoWriteStatus.Accepted) Defect = false;
            return Task.FromResult(new SynologyPhotoWriteReceipt(UploadStatus));
        }
        public Task<byte[]> ReadPhotoThumbnailSizeAsync(NasProfile profile, DsmSession session, SynologyPhotoThumbnail thumbnail, SynologyPhotoThumbnailSize size, CancellationToken cancellationToken = default)
        {
            ThumbnailReads++; Assert.Equal(8, thumbnail.UnitId); Assert.Equal(Space, thumbnail.Space); Assert.Equal("", thumbnail.Revision); Assert.Null(thumbnail.AlbumId);
            return Task.FromResult(Jpeg(Match && size != MismatchedSize ? size switch { SynologyPhotoThumbnailSize.Large => (byte)1, SynologyPhotoThumbnailSize.Small => (byte)2, _ => (byte)3 } : (byte)9));
        }
        public Task<IReadOnlyMediaSource> OpenPhotoMediaAsync(NasProfile profile, DsmSession session, SynologyPhotoMediaRequest request, CancellationToken cancellationToken = default)
        {
            MediaReads++; Assert.Equal("8", request.Parameters["id"]); Assert.Equal("\"unit\"", request.Parameters["type"]);
            Assert.Equal("\"orig_h264\"", request.Parameters["quality"]); Assert.Equal("true", request.Parameters["use_mov"]);
            OnMediaRead?.Invoke(); return Task.FromResult<IReadOnlyMediaSource>(new Media(Match && !MismatchedVideo ? [7, 8, 9] : [4, 5, 6]));
        }
        private sealed class Media(byte[] bytes) : IReadOnlyMediaSource
        {
            public long Length => bytes.Length;
            public string ContentType => "video/quicktime";
            public Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancellationToken = default) => Task.FromResult(bytes.AsSpan((int)offset, count).ToArray());
            public void Dispose() { }
        }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string> parameters, CancellationToken cancellationToken = default) => Http.Api.WritePhotoAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
