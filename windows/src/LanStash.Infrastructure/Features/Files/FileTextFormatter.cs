using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public static class FileTextFormatter
{
    public static string Format(string text, TextFormatKind kind)
    {
        ArgumentNullException.ThrowIfNull(text);
        return kind switch
        {
            TextFormatKind.Json => FormatJson(text),
            TextFormatKind.Xml => FormatXml(text),
            TextFormatKind.JavaScript => FormatBraceLanguage(text),
            TextFormatKind.TypeScript => FormatBraceLanguage(text),
            TextFormatKind.Css => FormatBraceLanguage(text),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }

    private static string FormatJson(string text)
    {
        using var document = JsonDocument.Parse(text);
        using var stream = new MemoryStream();
        using var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = true,
        });
        document.WriteTo(writer);
        writer.Flush();
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static string FormatXml(string text)
    {
        var document = XDocument.Parse(text);
        var settings = new System.Xml.XmlWriterSettings
        {
            Indent = true,
            IndentChars = "  ",
            OmitXmlDeclaration = text.TrimStart().StartsWith("<?xml", StringComparison.OrdinalIgnoreCase),
        };
        var result = new StringBuilder();
        using (var writer = System.Xml.XmlWriter.Create(result, settings))
        {
            document.WriteTo(writer);
        }
        return result.ToString();
    }

    private static string FormatBraceLanguage(string text)
    {
        var lines = new List<string>();
        var current = new StringBuilder();
        var indent = 0;
        char? quote = null;
        var escaped = false;
        var lineComment = false;
        var blockComment = false;

        void Flush()
        {
            var value = current.ToString().Trim();
            current.Clear();
            if (value.Length > 0)
            {
                lines.Add(new string(' ', indent * 2) + value);
            }
        }

        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            var next = index + 1 < text.Length ? text[index + 1] : '\0';

            if (lineComment)
            {
                if (character is '\r' or '\n')
                {
                    lineComment = false;
                    Flush();
                }
                else
                {
                    current.Append(character);
                }
                continue;
            }

            if (blockComment)
            {
                current.Append(character);
                if (character == '*' && next == '/')
                {
                    current.Append(next);
                    index++;
                    blockComment = false;
                }
                continue;
            }

            if (quote is not null)
            {
                current.Append(character);
                if (escaped)
                {
                    escaped = false;
                }
                else if (character == '\\')
                {
                    escaped = true;
                }
                else if (character == quote)
                {
                    quote = null;
                }
                continue;
            }

            if (character == '/' && next == '/')
            {
                current.Append("//");
                index++;
                lineComment = true;
                continue;
            }
            if (character == '/' && next == '*')
            {
                current.Append("/*");
                index++;
                blockComment = true;
                continue;
            }
            if (character is '\'' or '"' or '`')
            {
                quote = character;
                current.Append(character);
                continue;
            }
            if (character == '{')
            {
                current.Append(character);
                Flush();
                indent++;
                continue;
            }
            if (character == '}')
            {
                Flush();
                indent = Math.Max(0, indent - 1);
                current.Append(character);
                if (next != ';')
                {
                    Flush();
                }
                continue;
            }
            if (character == ';')
            {
                current.Append(character);
                Flush();
                continue;
            }
            if (character is '\r' or '\n')
            {
                Flush();
                continue;
            }
            if (!char.IsWhiteSpace(character) ||
                (current.Length > 0 && !char.IsWhiteSpace(current[^1])))
            {
                current.Append(character);
            }
        }

        Flush();
        return lines.Count == 0
            ? string.Empty
            : string.Join(Environment.NewLine, lines) + Environment.NewLine;
    }
}
