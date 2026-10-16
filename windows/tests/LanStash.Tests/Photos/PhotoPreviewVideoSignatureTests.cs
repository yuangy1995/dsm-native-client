using System.Buffers.Binary;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Photos;

public sealed class PhotoPreviewVideoSignatureTests
{
    [Fact]
    public void ContainerRemuxPreservesSamplesRegardlessOfChunksBrandsAndTimeScale()
    {
        var a = Signature(Movie()); var b = Signature(Movie(remux: true));
        Assert.True(a.Matches(b)); Assert.Equal(1_000_000, a.DurationMicroseconds); Assert.Equal(2, a.Tracks.Single().SampleCount);
    }
    [Theory]
    [InlineData("sample")][InlineData("duration")][InlineData("rotation")][InlineData("format")][InlineData("timing")][InlineData("composition")][InlineData("configuration")][InlineData("edit")]
    public void AnyMediaOrPresentationChangeCannotBeClaimedAsUploadedContent(string change) =>
        Assert.False(Signature(Movie()).Matches(Signature(Movie(change: change))));

    [Theory]
    [InlineData("offset")][InlineData("count")][InlineData("chunk")][InlineData("truncated")][InlineData("fragment")][InlineData("size")][InlineData("duplicate")]
    public void IncompleteOrContradictorySampleTablesNeverProduceProof(string damage) =>
        Assert.ThrowsAny<Exception>(() => Signature(Movie(damage: damage)));

    [Fact]
    public void MetadataRemovalErasesPayloadAndRetainsMediaAndOffsets()
    {
        var path = Temp(); var bytes = Movie();
        try
        {
            File.WriteAllBytes(path, bytes); var before = PhotoPreviewVideoSignature.Read(path, default);
            PhotoPreviewVideoSignature.RemoveMetadata(path, default); var after = File.ReadAllBytes(path);
            Assert.Equal(bytes.Length, after.Length); Assert.DoesNotContain("synthetic-private-metadata", Encoding.ASCII.GetString(after));
            Assert.True(before.Matches(PhotoPreviewVideoSignature.Read(path, default)));
        }
        finally { File.Delete(path); }
    }
    [Fact]
    public void CancellationAndInvalidProofAreRejected()
    {
        using var cts = new CancellationTokenSource(); cts.Cancel(); var path = Temp();
        try { File.WriteAllBytes(path, Movie()); Assert.Throws<OperationCanceledException>(() => PhotoPreviewVideoSignature.Read(path, cts.Token)); }
        finally { File.Delete(path); }
        var proof = Signature(Movie()); Assert.False(proof.Matches(proof with { DurationMicroseconds = 0 }));
        Assert.False(proof.Matches(proof with { Tracks = [proof.Tracks[0] with { Digest = "wrong" }] }));
    }
    internal static byte[] Movie(bool remux = false, string? change = null, string? damage = null)
    {
        var scale = remux ? 90_000u : 1000u;
        var brand = Box("ftyp", Encoding.ASCII.GetBytes(remux ? "qt  " : "isom"), U(0), Encoding.ASCII.GetBytes("isom"));
        var padding = remux ? Box("free", new byte[71]) : [];
        var payload = new byte[] { 1, 2, 3, 4, 5, 6, 7 }; if (change == "sample") payload[6]++;
        var mdat = Box("mdat", payload); var offset = (uint)(brand.Length + padding.Length + 8);
        var mvhd = new byte[100]; Put(mvhd, 12, scale); Put(mvhd, 16, change == "duration" ? scale * 2 : scale);
        var tkhd = new byte[84]; Put(tkhd, 20, scale); Put(tkhd, 40, change == "rotation" ? 0u : 65536u); Put(tkhd, 56, 65536); Put(tkhd, 72, 0x40000000);
        var mdhd = new byte[24]; Put(mdhd, 12, scale); Put(mdhd, 16, scale);
        var hdlr = new byte[24]; Encoding.ASCII.GetBytes("vide").CopyTo(hdlr, 8);
        var sampleDescription = new byte[78]; BinaryPrimitives.WriteUInt16BigEndian(sampleDescription.AsSpan(24), 160); BinaryPrimitives.WriteUInt16BigEndian(sampleDescription.AsSpan(26), 96);
        var stsd = Box("stsd", U(0, 1), Box(change == "format" ? "avc3" : "avc1", sampleDescription, Box("avcC", change == "configuration" ? [2, 3, 4] : [1, 3, 4])));
        var stsz = Box("stsz", U(0, 0, damage == "count" ? 3u : 2u, 3, damage == "size" ? 9999u : 4u));
        var stts = Box("stts", U(0, 1, 2, change == "timing" ? scale / 4 : scale / 2));
        var stsc = Box("stsc", U(0, 1, damage == "chunk" ? 2u : 1u, remux ? 1u : 2u, 1));
        var stco = remux ? Box("co64", U(0, 2), UL(offset, offset + 3)) : Box("stco", U(0, 1, damage == "offset" ? 0u : offset));
        var ctts = change == "composition" ? Box("ctts", U(0, 1, 2, 5)) : [];
        var stbl = Box("stbl", stsd, stsz, stts, stsc, stco, ctts, damage == "duplicate" ? stco : []);
        var edit = remux || change == "edit" ? Box("edts", Box("elst", U(0, 1, scale, change == "edit" ? scale / 2 : 0, 65536))) : [];
        var movie = Box("moov", Box("mvhd", mvhd), Box("trak", Box("tkhd", tkhd), edit, Box("mdia", Box("mdhd", mdhd), Box("hdlr", hdlr), Box("minf", stbl))),
            Box("udta", Encoding.ASCII.GetBytes("synthetic-private-metadata")));
        var result = brand.Concat(padding).Concat(mdat).Concat(movie).Concat(damage == "fragment" ? Box("moof", []) : []).ToArray();
        return damage == "truncated" ? result[..^4] : result;
    }
    private static SynologyPhotoVideoSignature Signature(byte[] bytes)
    {
        var path = Temp(); try { File.WriteAllBytes(path, bytes); return PhotoPreviewVideoSignature.Read(path, default); } finally { File.Delete(path); }
    }
    private static string Temp() => Path.Combine(Path.GetTempPath(), "LanStash-Video-Test-" + Guid.NewGuid().ToString("N") + ".mp4");
    private static byte[] U(params uint[] values) { var data = new byte[values.Length * 4]; for (var i = 0; i < values.Length; i++) Put(data, i * 4, values[i]); return data; }
    private static byte[] UL(params ulong[] values) { var data = new byte[values.Length * 8]; for (var i = 0; i < values.Length; i++) BinaryPrimitives.WriteUInt64BigEndian(data.AsSpan(i * 8), values[i]); return data; }
    private static void Put(byte[] bytes, int index, uint value) => BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(index), value);
    private static byte[] Box(string name, params byte[][] contents) => U((uint)(8 + contents.Sum(v => v.Length))).Concat(Encoding.ASCII.GetBytes(name)).Concat(contents.SelectMany(v => v)).ToArray();
}
