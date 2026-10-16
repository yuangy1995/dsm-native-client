using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>读取 MP4/MOV 的真实压缩样本；忽略容器布局、文件名与用户元数据。</summary>
internal static class PhotoPreviewVideoSignature
{
    private readonly record struct Box(string Type, long Start, long Data, long End);
    private const int MaximumTableBytes = 64 * 1024 * 1024;
    internal static SynologyPhotoVideoSignature Read(string path, CancellationToken token)
    {
        using var file = File.OpenRead(path); var roots = Boxes(file, 0, file.Length);
        // 当前转换输出为非分片 MP4；无法完整解释的容器只能保持未知，不能弱化为文件摘要。
        if (roots.Any(b => b.Type == "moof")) throw Invalid();
        var movie = One(roots, "moov"); var children = Boxes(file, movie.Data, movie.End);
        var movieHeader = Data(file, One(children, "mvhd")); var duration = Duration(movieHeader);
        var movieScale = U32(movieHeader, Version(movieHeader) == 1 ? 20 : 12);
        var media = roots.Where(b => b.Type == "mdat").ToArray(); if (media.Length == 0) throw Invalid();
        var tracks = new List<SynologyPhotoVideoTrack>(); var buffer = new byte[64 * 1024];
        foreach (var track in children.Where(b => b.Type == "trak"))
        {
            token.ThrowIfCancellationRequested(); if (tracks.Count >= 32) throw Invalid();
            var parts = Boxes(file, track.Data, track.End); var mdia = One(parts, "mdia");
            var info = Boxes(file, mdia.Data, mdia.End); var handler = Data(file, One(info, "hdlr"));
            var type = Four(handler, 8); if (type is not ("vide" or "soun")) continue;
            var header = Data(file, One(parts, "tkhd")); var matrixOffset = Version(header) == 1 ? 52 : 40;
            var matrix = Enumerable.Range(0, 9).Select(i => unchecked((int)U32(header, matrixOffset + i * 4))).ToArray();
            var timing = Data(file, One(info, "mdhd")); var timeScale = U32(timing, Version(timing) == 1 ? 20 : 12);
            if (timeScale == 0) throw Invalid();
            var minf = One(info, "minf"); var stbl = One(Boxes(file, minf.Data, minf.End), "stbl");
            var tables = Boxes(file, stbl.Data, stbl.End);
            var description = One(tables, "stsd"); var descriptionHeader = Data(file, description);
            var descriptions = Boxes(file, description.Data + 8, description.End);
            var formats = descriptions.Select(b => b.Type).ToArray();
            if (formats.Length is 0 or > 32 || U32(descriptionHeader, 4) != formats.Length) throw Invalid();
            var formatDigests = descriptions.Select(box => FormatDigest(file, box)).ToArray();
            var sizes = Data(file, One(tables, "stsz")); var constant = U32(sizes, 4); var sampleCount = Count(sizes, 8);
            if (constant == 0 && sizes.Length != 12L + sampleCount * 4L) throw Invalid();
            if (constant != 0 && sizes.Length != 12) throw Invalid();
            var times = Data(file, One(tables, "stts")); var timeCount = Table(times, 8);
            var mapping = Data(file, One(tables, "stsc")); var mapCount = Table(mapping, 12);
            var chunkBox = tables.Where(b => b.Type is "stco" or "co64").ToArray(); if (chunkBox.Length != 1) throw Invalid();
            var wide = chunkBox[0].Type == "co64"; var chunks = Data(file, chunkBox[0]); var chunkCount = Table(chunks, wide ? 8 : 4);
            var compositionBox = tables.Where(b => b.Type == "ctts").ToArray(); if (compositionBox.Length > 1) throw Invalid();
            var composition = compositionBox.Length == 1 ? Data(file, compositionBox[0]) : null;
            var compositionCount = composition is null ? 0 : Table(composition, 8);
            if (composition is not null) _ = Version(composition);
            if (U32(mapping, 8) != 1) throw Invalid();
            uint lastChunk = 0;
            for (var row = 0; row < mapCount; row++)
            {
                var first = U32(mapping, 8 + row * 12); var count = U32(mapping, 12 + row * 12); var index = U32(mapping, 16 + row * 12);
                if (first <= lastChunk || first > chunkCount || count == 0 || index == 0 || index > formats.Length) throw Invalid(); lastChunk = first;
            }
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            hash.AppendData(Encoding.ASCII.GetBytes(Timeline(file, parts, header, movieScale, timeScale)));
            var sample = 0; var map = 0; var timeRow = -1; uint timeLeft = 0, sampleDuration = 0;
            var compositionRow = -1; uint compositionLeft = 0; long compositionOffset = 0;
            for (var chunk = 1; chunk <= chunkCount; chunk++)
            {
                while (map + 1 < mapCount && U32(mapping, 8 + (map + 1) * 12) <= chunk) map++;
                var inChunk = U32(mapping, 12 + map * 12);
                var formatDigest = formatDigests[checked((int)U32(mapping, 16 + map * 12) - 1)];
                var offset = wide ? CheckedOffset(U64(chunks, 8 + (chunk - 1) * 8)) : U32(chunks, 8 + (chunk - 1) * 4);
                if (inChunk > sampleCount - sample) throw Invalid();
                for (var index = 0; index < inChunk; index++, sample++)
                {
                    token.ThrowIfCancellationRequested();
                    var size = constant == 0 ? U32(sizes, 12 + sample * 4) : constant;
                    if (size == 0 || !media.Any(b => offset >= b.Data && offset <= b.End && size <= b.End - offset)) throw Invalid();
                    if (timeLeft == 0)
                    {
                        if (++timeRow >= timeCount) throw Invalid(); timeLeft = U32(times, 8 + timeRow * 8); sampleDuration = U32(times, 12 + timeRow * 8);
                        if (timeLeft == 0) throw Invalid();
                    }
                    timeLeft--;
                    if (composition is not null)
                    {
                        if (compositionLeft == 0)
                        {
                            if (++compositionRow >= compositionCount) throw Invalid(); compositionLeft = U32(composition, 8 + compositionRow * 8);
                            var raw = U32(composition, 12 + compositionRow * 8); compositionOffset = composition[0] == 1 ? unchecked((int)raw) : raw;
                            if (compositionLeft == 0) throw Invalid();
                        }
                        compositionLeft--;
                    }
                    // 使用微秒消除容器时间基差异；保留样本边界、时长和显示顺序。
                    hash.AppendData(Encoding.ASCII.GetBytes(FormattableString.Invariant($"{formatDigest}:{size}:{Micros(sampleDuration, timeScale)}:{Micros(compositionOffset, timeScale)};")));
                    file.Position = offset; var remaining = (long)size;
                    while (remaining > 0)
                    {
                        token.ThrowIfCancellationRequested(); var read = file.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                        if (read == 0) throw Invalid(); hash.AppendData(buffer, 0, read); remaining -= read;
                    }
                    offset += size;
                }
            }
            if (sample != sampleCount || timeLeft != 0 || timeRow != timeCount - 1 ||
                composition is not null && (compositionLeft != 0 || compositionRow != compositionCount - 1)) throw Invalid();
            tracks.Add(new(type, formats, matrix, sample, Convert.ToHexString(hash.GetHashAndReset())));
        }
        var result = new SynologyPhotoVideoSignature(duration, tracks.OrderBy(t => t.Type == "vide" ? 0 : 1).ToArray());
        if (!result.IsValid) throw Invalid(); return result;
    }

    private static string Timeline(Stream file, List<Box> parts, byte[] header, uint movieScale, uint mediaScale)
    {
        var edits = parts.Where(b => b.Type == "edts").ToArray(); if (edits.Length > 1) throw Invalid();
        if (edits.Length == 0)
        {
            var duration = Version(header) == 1 ? CheckedOffset(U64(header, 28)) : U32(header, 20);
            return FormattableString.Invariant($"{Micros(duration, movieScale)}:0:65536;");
        }
        var list = Data(file, One(Boxes(file, edits[0].Data, edits[0].End), "elst")); var version = Version(list);
        var count = Table(list, version == 1 ? 20 : 12); if (count > 1024) throw Invalid(); var text = new StringBuilder();
        for (var row = 0; row < count; row++)
        {
            var offset = 8 + row * (version == 1 ? 20 : 12);
            var length = version == 1 ? CheckedOffset(U64(list, offset)) : U32(list, offset);
            var time = version == 1 ? unchecked((long)U64(list, offset + 8)) : unchecked((int)U32(list, offset + 4));
            var rate = U32(list, offset + (version == 1 ? 16 : 8)); if (time < -1) throw Invalid();
            if (length > 0) text.Append(FormattableString.Invariant($"{Micros(length, movieScale)}:{(time == -1 ? -1 : Micros(time, mediaScale))}:{rate};"));
        }
        return text.ToString();
    }

    private static string FormatDigest(Stream file, Box box)
    {
        var data = Data(file, box); var offset = box.Type switch
        {
            "avc1" or "avc3" => 78,
            "mp4a" => U16(data, 8) switch { 0 => 28, 1 => 44, _ => throw Invalid() },
            _ => throw Invalid(),
        };
        var extra = Boxes(file, box.Data + offset, box.End); byte[] configuration; string geometry;
        if (box.Type is "avc1" or "avc3")
        {
            configuration = Data(file, One(extra, "avcC"));
            var width = U16(data, 24); var height = U16(data, 26); if (width == 0 || height == 0) throw Invalid();
            var aspect = extra.Where(b => b.Type == "pasp").ToArray(); if (aspect.Length > 1) throw Invalid();
            var p = aspect.Length == 1 ? Data(file, aspect[0]) : null;
            var numerator = p is null ? 1 : U32(p, 0); var denominator = p is null ? 1 : U32(p, 4);
            if (numerator == 0 || denominator == 0) throw Invalid();
            var gcd = Gcd(numerator, denominator); geometry = FormattableString.Invariant($"{width}:{height}:{numerator / gcd}:{denominator / gcd}");
        }
        else
        {
            var wave = extra.Where(b => b.Type == "wave").ToArray(); if (wave.Length > 1) throw Invalid();
            if (wave.Length == 1) extra.AddRange(Boxes(file, wave[0].Data, wave[0].End));
            var esds = Data(file, One(extra, "esds")); configuration = DecoderConfiguration(esds.AsSpan(4));
            geometry = FormattableString.Invariant($"{U16(data, 16)}:{U32(data, 24)}");
        }
        if (configuration.Length is 0 or > 1_048_576) throw Invalid();
        return box.Type + ":" + geometry + ":" + Convert.ToHexString(SHA256.HashData(configuration));
    }
    private static byte[] DecoderConfiguration(ReadOnlySpan<byte> bytes, int depth = 0)
    {
        if (depth > 4) throw Invalid();
        while (!bytes.IsEmpty)
        {
            var tag = bytes[0]; bytes = bytes[1..]; var length = 0; var finished = false;
            for (var index = 0; index < 4 && !bytes.IsEmpty; index++)
            { var part = bytes[0]; bytes = bytes[1..]; length = (length << 7) | (part & 127); if ((part & 128) == 0) { finished = true; break; } }
            if (!finished || length > bytes.Length) throw Invalid(); var item = bytes[..length]; bytes = bytes[length..];
            if (tag == 5) return item.ToArray();
            if (tag == 3)
            {
                if (item.Length < 3) throw Invalid(); var flags = item[2]; var skip = 3 + ((flags & 128) == 0 ? 0 : 2);
                if ((flags & 64) != 0) { if (skip >= item.Length) throw Invalid(); skip += item[skip] + 1; }
                if ((flags & 32) != 0) skip += 2;
                if (skip > item.Length) throw Invalid(); return DecoderConfiguration(item[skip..], depth + 1);
            }
            if (tag == 4) { if (item.Length < 13) throw Invalid(); return DecoderConfiguration(item[13..], depth + 1); }
        }
        throw Invalid();
    }
    private static uint Gcd(uint left, uint right) { while (right != 0) (left, right) = (right, left % right); return left; }

    /// <summary>只修改本次生成的派生文件；保留原长度和媒体偏移，清除用户元数据内容。</summary>
    internal static void RemoveMetadata(string path, CancellationToken token)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None); var zeros = new byte[64 * 1024];
        void Clean(long start, long end, int depth)
        {
            if (depth > 8) throw Invalid();
            foreach (var box in Boxes(file, start, end))
            {
                token.ThrowIfCancellationRequested();
                if (box.Type is "udta" or "meta")
                {
                    file.Position = box.Start + 4; file.Write("free"u8); file.Position = box.Data; var remaining = box.End - box.Data;
                    while (remaining > 0) { token.ThrowIfCancellationRequested(); var count = (int)Math.Min(remaining, zeros.Length); file.Write(zeros, 0, count); remaining -= count; }
                }
                else if (box.Type is "moov" or "trak" or "mdia" or "minf") Clean(box.Data, box.End, depth + 1);
            }
        }
        Clean(0, file.Length, 0); file.Flush(true);
    }
    private static List<Box> Boxes(Stream file, long start, long end)
    {
        var result = new List<Box>(); Span<byte> bytes = stackalloc byte[16];
        while (start < end)
        {
            if (end - start < 8 || result.Count >= 100_000) throw Invalid(); file.Position = start; file.ReadExactly(bytes[..8]);
            var size = (long)BinaryPrimitives.ReadUInt32BigEndian(bytes); var header = 8;
            if (size == 1) { if (end - start < 16) throw Invalid(); file.ReadExactly(bytes[8..]); size = CheckedOffset(BinaryPrimitives.ReadUInt64BigEndian(bytes[8..])); header = 16; }
            if (size == 0) size = end - start;
            if (size < header || size > end - start) throw Invalid();
            result.Add(new(Encoding.ASCII.GetString(bytes.Slice(4, 4)), start, start + header, start + size)); start += size;
        }
        return result;
    }
    private static Box One(IEnumerable<Box> boxes, string type) { var found = boxes.Where(b => b.Type == type).ToArray(); return found.Length == 1 ? found[0] : throw Invalid(); }
    private static byte[] Data(Stream file, Box box)
    {
        if (box.End - box.Data > MaximumTableBytes) throw Invalid(); var result = new byte[checked((int)(box.End - box.Data))];
        file.Position = box.Data; file.ReadExactly(result); return result;
    }
    private static int Version(byte[] value) => value.Length >= 4 && value[0] <= 1 ? value[0] : throw Invalid();
    private static uint U32(byte[] data, int offset) => offset >= 0 && offset <= data.Length - 4 ? BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset, 4)) : throw Invalid();
    private static ushort U16(byte[] data, int offset) => offset >= 0 && offset <= data.Length - 2 ? BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(offset, 2)) : throw Invalid();
    private static ulong U64(byte[] data, int offset) => offset >= 0 && offset <= data.Length - 8 ? BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(offset, 8)) : throw Invalid();
    private static string Four(byte[] data, int offset) => offset >= 0 && offset <= data.Length - 4 ? Encoding.ASCII.GetString(data, offset, 4) : throw Invalid();
    private static int Count(byte[] data, int offset) { var count = U32(data, offset); return count is > 0 and <= 16_000_000 ? (int)count : throw Invalid(); }
    private static int Table(byte[] data, int stride) { var count = Count(data, 4); if (data.Length != 8L + count * (long)stride) throw Invalid(); return count; }
    private static long CheckedOffset(ulong offset) => offset <= long.MaxValue ? (long)offset : throw Invalid();
    private static long Micros(long duration, uint scale) => scale == 0 ? throw Invalid() : checked((long)Math.Round(duration * 1_000_000m / scale, MidpointRounding.AwayFromZero));
    private static long Duration(byte[] data)
    {
        var version = Version(data); var scale = U32(data, version == 1 ? 20 : 12);
        return Micros(version == 1 ? CheckedOffset(U64(data, 24)) : U32(data, 16), scale);
    }
    private static SynologyPhotoConversionException Invalid() => new(false);
}
