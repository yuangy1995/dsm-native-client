using System.Collections.ObjectModel;
using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.App.Features.Photos.Synology;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace LanStash.App.Views.Photos;

public sealed class SynologyPhotoCell
{
    public required string Id { get; init; }
    public SynologyPhoto? Photo { get; init; }
    public SynologyPhotoCollection? Collection { get; init; }
    public SynologyPhotoSharedEntry? Shared { get; init; }
    public string Title => Photo?.Filename ?? Collection?.Name ?? Shared?.Title ?? "";
    public string Subtitle => Collection?.Count is { } count ? LocalizationService.Current.Format("PhotosItemCount", count) : "";
    public string CopyLinkTitle => LocalizationService.Current.Get("PhotosCopyLink");
    public Visibility LinkVisibility => Shared?.Url is not null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility MediaLabelVisibility => Photo?.MediaType is "video" or "live" ? Visibility.Visible : Visibility.Collapsed;
    public string MediaLabel => Photo?.MediaType switch
    {
        "video" => LocalizationService.Current.Get("PhotosMediaVideo"),
        "live" => LocalizationService.Current.Get("PhotosMediaLive"),
        _ => "",
    };
}

public sealed class SynologyPhotoGroup(string key, string title) : ObservableCollection<SynologyPhotoCell>
{
    public string Key { get; } = key;
    public string Title { get; set; } = title;
}

public sealed class SynologyPhotoTemplateSelector : DataTemplateSelector
{
    public DataTemplate PhotoTemplate { get; set; } = null!;
    public DataTemplate CollectionTemplate { get; set; } = null!;
    public DataTemplate SharedTemplate { get; set; } = null!;
    protected override DataTemplate SelectTemplateCore(object item, DependencyObject container) =>
        item is SynologyPhotoCell { Photo: not null } ? PhotoTemplate :
        item is SynologyPhotoCell { Shared: not null } ? SharedTemplate : CollectionTemplate;
}

internal sealed record SynologyPhotoCategoryChoice(SynologyPhotoCategory Category, string Title);
internal sealed record SynologyPhotoShareChoice(SynologyPhotoShareScope Scope, string Title);

internal static class SynologyPhotoImages
{
    public static async Task<SynologyPhotoDecodedThumbnail<BitmapImage>> DecodeAsync(
        byte[] bytes, int maximumDimension, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync().AsTask(cancellationToken);
            writer.DetachStream();
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellationToken);
        if (decoder.OrientedPixelWidth == 0 || decoder.OrientedPixelHeight == 0) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        var scale = Math.Min(1d, maximumDimension / (double)Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
        var width = Math.Max(1, (int)Math.Round(decoder.OrientedPixelWidth * scale));
        var height = Math.Max(1, (int)Math.Round(decoder.OrientedPixelHeight * scale));
        stream.Seek(0);
        var image = new BitmapImage { DecodePixelWidth = width, DecodePixelHeight = height, DecodePixelType = DecodePixelType.Physical };
        await image.SetSourceAsync(stream).AsTask(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return new(image, checked((long)width * height * 4));
    }
}
