using System.Buffers.Binary;
using System.Text;
using LanStash.App.Features.Files.Preview;

namespace LanStash.Tests.Files.Preview;

public sealed class IsoBmffVideoMetadataReaderTests
{
    [Fact]
    public void ReadsVersionZeroMovieDurationAndVideoTrackDimensions()
    {
        var metadata = IsoBmffVideoMetadataReader.TryRead(BuildMovie(
            width: 3840,
            height: 2160,
            timescale: 1_000,
            duration: 65_432));

        Assert.Equal(3840, metadata?.PixelWidth);
        Assert.Equal(2160, metadata?.PixelHeight);
        Assert.Equal(TimeSpan.FromMilliseconds(65_432), metadata?.Duration);
    }

    [Fact]
    public void ReadsVersionOneMovieDuration()
    {
        var metadata = IsoBmffVideoMetadataReader.TryRead(BuildMovie(
            width: 1280,
            height: 720,
            timescale: 90_000,
            duration: 180_000,
            mvhdVersion: 1));

        Assert.Equal(1280, metadata?.PixelWidth);
        Assert.Equal(720, metadata?.PixelHeight);
        Assert.Equal(TimeSpan.FromSeconds(2), metadata?.Duration);
    }

    [Fact]
    public void ReadsExtendedSizeMovieBox()
    {
        var moovPayload = BuildMoov(
            width: 640,
            height: 360,
            timescale: 1_000,
            duration: 42_000);
        var bytes = Box("ftyp", Encoding.ASCII.GetBytes("isom0000"))
            .Concat(ExtendedBox("moov", moovPayload))
            .ToArray();

        var metadata = IsoBmffVideoMetadataReader.TryRead(bytes);

        Assert.Equal(640, metadata?.PixelWidth);
        Assert.Equal(360, metadata?.PixelHeight);
        Assert.Equal(TimeSpan.FromSeconds(42), metadata?.Duration);
    }

    [Fact]
    public void AudioOnlyMovieReturnsDurationWithoutVideoDimensions()
    {
        var metadata = IsoBmffVideoMetadataReader.TryRead(BuildMovie(
            width: 1920,
            height: 1080,
            timescale: 1_000,
            duration: 5_000,
            handlerType: "soun"));

        Assert.Null(metadata?.PixelWidth);
        Assert.Null(metadata?.PixelHeight);
        Assert.Equal(TimeSpan.FromSeconds(5), metadata?.Duration);
    }

    [Fact]
    public void MissingOrDamagedBoxesReturnNullWithoutThrowing()
    {
        Assert.Null(IsoBmffVideoMetadataReader.TryRead(Box(
            "ftyp",
            Encoding.ASCII.GetBytes("isom0000"))));
        Assert.Null(IsoBmffVideoMetadataReader.TryRead(new byte[]
        {
            0, 0, 0, 24, (byte)'m', (byte)'o', (byte)'o', (byte)'v',
            0, 0, 0, 80, (byte)'m', (byte)'v', (byte)'h', (byte)'d',
        }));
    }

    private static byte[] BuildMovie(
        int width,
        int height,
        uint timescale,
        ulong duration,
        int mvhdVersion = 0,
        string handlerType = "vide") =>
        Box("ftyp", Encoding.ASCII.GetBytes("isom0000"))
            .Concat(Box(
                "moov",
                BuildMoov(
                    width,
                    height,
                    timescale,
                    duration,
                    mvhdVersion,
                    handlerType)))
            .ToArray();

    private static byte[] BuildMoov(
        int width,
        int height,
        uint timescale,
        ulong duration,
        int mvhdVersion = 0,
        string handlerType = "vide") =>
        Box("mvhd", BuildMovieHeader(timescale, duration, mvhdVersion))
            .Concat(Box(
                "trak",
                Box("tkhd", BuildTrackHeader(width, height))
                    .Concat(Box("mdia", Box("hdlr", BuildHandler(handlerType))))
                    .ToArray()))
            .ToArray();

    private static byte[] BuildMovieHeader(
        uint timescale,
        ulong duration,
        int version)
    {
        if (version == 1)
        {
            var payload = new byte[32];
            payload[0] = 1;
            BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(20), timescale);
            BinaryPrimitives.WriteUInt64BigEndian(payload.AsSpan(24), duration);
            return payload;
        }

        var versionZero = new byte[20];
        BinaryPrimitives.WriteUInt32BigEndian(versionZero.AsSpan(12), timescale);
        BinaryPrimitives.WriteUInt32BigEndian(
            versionZero.AsSpan(16),
            checked((uint)duration));
        return versionZero;
    }

    private static byte[] BuildTrackHeader(int width, int height)
    {
        var payload = new byte[84];
        BinaryPrimitives.WriteUInt32BigEndian(
            payload.AsSpan(76),
            checked((uint)width * 65_536u));
        BinaryPrimitives.WriteUInt32BigEndian(
            payload.AsSpan(80),
            checked((uint)height * 65_536u));
        return payload;
    }

    private static byte[] BuildHandler(string handlerType)
    {
        var payload = new byte[12];
        Encoding.ASCII.GetBytes(handlerType, payload.AsSpan(8));
        return payload;
    }

    private static byte[] Box(string type, byte[] payload)
    {
        var bytes = new byte[payload.Length + 8];
        BinaryPrimitives.WriteUInt32BigEndian(
            bytes,
            checked((uint)bytes.Length));
        Encoding.ASCII.GetBytes(type, bytes.AsSpan(4));
        payload.CopyTo(bytes.AsSpan(8));
        return bytes;
    }

    private static byte[] ExtendedBox(string type, byte[] payload)
    {
        var bytes = new byte[payload.Length + 16];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, 1);
        Encoding.ASCII.GetBytes(type, bytes.AsSpan(4));
        BinaryPrimitives.WriteUInt64BigEndian(
            bytes.AsSpan(8),
            checked((ulong)bytes.Length));
        payload.CopyTo(bytes.AsSpan(16));
        return bytes;
    }
}
