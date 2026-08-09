using System.Text;

namespace LanStash.App.Features.Files.Preview;

internal static class FilePreviewTextDecoder
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly UnicodeEncoding StrictUtf16LittleEndian = new(false, true, true);
    private static readonly UnicodeEncoding StrictUtf16BigEndian = new(true, true, true);

    public static string Decode(ReadOnlySpan<byte> bytes, bool allowTruncatedUtf8Tail)
    {
        if (bytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
        {
            return DecodeUtf8(bytes[3..], allowTruncatedUtf8Tail);
        }
        if (bytes.StartsWith(new byte[] { 0xFF, 0xFE }))
        {
            return StrictUtf16LittleEndian.GetString(bytes[2..]);
        }
        if (bytes.StartsWith(new byte[] { 0xFE, 0xFF }))
        {
            return StrictUtf16BigEndian.GetString(bytes[2..]);
        }
        return DecodeUtf8(bytes, allowTruncatedUtf8Tail);
    }

    private static string DecodeUtf8(ReadOnlySpan<byte> bytes, bool allowTruncatedTail)
    {
        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException) when (allowTruncatedTail)
        {
            for (var trim = 1; trim <= 3 && trim < bytes.Length; trim++)
            {
                try
                {
                    return StrictUtf8.GetString(bytes[..^trim]);
                }
                catch (DecoderFallbackException)
                {
                }
            }
            throw;
        }
    }
}
