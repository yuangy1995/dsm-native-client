using Windows.ApplicationModel.DataTransfer;

namespace LanStash.App.Platform.Sharing;

internal sealed class WindowsClipboard
{
    public bool SetUri(Uri value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var package = new DataPackage
        {
            RequestedOperation = DataPackageOperation.Copy,
        };
        package.SetText(value.AbsoluteUri);
        var accepted = Clipboard.SetContentWithOptions(
            package,
            new ClipboardContentOptions
            {
                IsAllowedInHistory = false,
                IsRoamable = false,
            });
        if (!accepted)
        {
            return false;
        }
        Clipboard.Flush();
        return true;
    }
}
