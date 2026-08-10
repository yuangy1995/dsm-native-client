using System.Buffers.Binary;

namespace LanStash.App.Features.Files.Preview;

internal static class IsoBmffVideoMetadataReader
{
    private const uint BoxMoov = 0x6D6F6F76; // moov
    private const uint BoxMvhd = 0x6D766864; // mvhd
    private const uint BoxTrak = 0x7472616B; // trak
    private const uint BoxTkhd = 0x746B6864; // tkhd
    private const uint BoxMdia = 0x6D646961; // mdia
    private const uint BoxHdlr = 0x68646C72; // hdlr
    private const uint HandlerVideo = 0x76696465; // vide

    public static FilePreviewMediaMetadata? TryRead(ReadOnlySpan<byte> data)
    {
        if (!TryFindChild(data, 0, data.Length, BoxMoov, out var moov))
        {
            return null;
        }

        var duration = TryReadMovieDuration(data, moov);
        long? width = null;
        long? height = null;
        var offset = moov.PayloadStart;
        while (offset + 8 <= moov.End)
        {
            if (!TryReadBox(data, offset, moov.End, out var child))
            {
                break;
            }
            if (child.Type == BoxTrak && IsVideoTrack(data, child))
            {
                (width, height) = TryReadTrackDimensions(data, child);
                break;
            }
            offset = child.End;
        }

        return width is null && height is null && duration is null
            ? null
            : new FilePreviewMediaMetadata(width, height, Duration: duration);
    }

    private static TimeSpan? TryReadMovieDuration(ReadOnlySpan<byte> data, Box moov)
    {
        if (!TryFindChild(data, moov.PayloadStart, moov.End, BoxMvhd, out var mvhd) ||
            mvhd.PayloadStart >= mvhd.End)
        {
            return null;
        }

        var version = data[mvhd.PayloadStart];
        if (version == 0)
        {
            var timescaleOffset = mvhd.PayloadStart + 12;
            var durationOffset = mvhd.PayloadStart + 16;
            if (durationOffset + 4 > mvhd.End)
            {
                return null;
            }
            return ToDuration(
                BinaryPrimitives.ReadUInt32BigEndian(data[timescaleOffset..]),
                BinaryPrimitives.ReadUInt32BigEndian(data[durationOffset..]));
        }
        if (version == 1)
        {
            var timescaleOffset = mvhd.PayloadStart + 20;
            var durationOffset = mvhd.PayloadStart + 24;
            if (durationOffset + 8 > mvhd.End)
            {
                return null;
            }
            return ToDuration(
                BinaryPrimitives.ReadUInt32BigEndian(data[timescaleOffset..]),
                BinaryPrimitives.ReadUInt64BigEndian(data[durationOffset..]));
        }
        return null;
    }

    private static bool IsVideoTrack(ReadOnlySpan<byte> data, Box trak)
    {
        if (!TryFindChild(data, trak.PayloadStart, trak.End, BoxMdia, out var mdia) ||
            !TryFindChild(data, mdia.PayloadStart, mdia.End, BoxHdlr, out var hdlr))
        {
            return false;
        }

        var handlerOffset = hdlr.PayloadStart + 8;
        return handlerOffset + 4 <= hdlr.End &&
            BinaryPrimitives.ReadUInt32BigEndian(data[handlerOffset..]) == HandlerVideo;
    }

    private static (long? Width, long? Height) TryReadTrackDimensions(
        ReadOnlySpan<byte> data,
        Box trak)
    {
        if (!TryFindChild(data, trak.PayloadStart, trak.End, BoxTkhd, out var tkhd) ||
            tkhd.PayloadStart >= tkhd.End)
        {
            return (null, null);
        }

        var version = data[tkhd.PayloadStart];
        var widthOffset = tkhd.PayloadStart + (version == 1 ? 88 : 76);
        if (widthOffset + 8 > tkhd.End)
        {
            return (null, null);
        }

        var width = Fixed16ToWholePixels(
            BinaryPrimitives.ReadUInt32BigEndian(data[widthOffset..]));
        var height = Fixed16ToWholePixels(
            BinaryPrimitives.ReadUInt32BigEndian(data[(widthOffset + 4)..]));
        return (width, height);
    }

    private static long? Fixed16ToWholePixels(uint fixedValue)
    {
        var whole = (long)(fixedValue >> 16);
        return whole > 0 ? whole : null;
    }

    private static TimeSpan? ToDuration(uint timescale, ulong duration)
    {
        if (timescale == 0 || duration == 0)
        {
            return null;
        }

        try
        {
            return TimeSpan.FromSeconds(duration / (double)timescale);
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    private static bool TryFindChild(
        ReadOnlySpan<byte> data,
        int start,
        int end,
        uint type,
        out Box box)
    {
        var offset = start;
        while (offset + 8 <= end)
        {
            if (!TryReadBox(data, offset, end, out var candidate))
            {
                break;
            }
            if (candidate.Type == type)
            {
                box = candidate;
                return true;
            }
            offset = candidate.End;
        }

        box = default;
        return false;
    }

    private static bool TryReadBox(
        ReadOnlySpan<byte> data,
        int offset,
        int limit,
        out Box box)
    {
        if (offset < 0 || offset + 8 > limit || limit > data.Length)
        {
            box = default;
            return false;
        }

        var size32 = BinaryPrimitives.ReadUInt32BigEndian(data[offset..]);
        var type = BinaryPrimitives.ReadUInt32BigEndian(data[(offset + 4)..]);
        var headerSize = 8;
        ulong size = size32;
        if (size32 == 1)
        {
            if (offset + 16 > limit)
            {
                box = default;
                return false;
            }
            headerSize = 16;
            size = BinaryPrimitives.ReadUInt64BigEndian(data[(offset + 8)..]);
        }
        else if (size32 == 0)
        {
            size = (ulong)(limit - offset);
        }

        if (size < (ulong)headerSize || size > int.MaxValue)
        {
            box = default;
            return false;
        }

        var end = offset + checked((int)size);
        if (end > limit || end <= offset)
        {
            box = default;
            return false;
        }

        box = new Box(type, offset + headerSize, end);
        return true;
    }

    private readonly record struct Box(uint Type, int PayloadStart, int End);
}
