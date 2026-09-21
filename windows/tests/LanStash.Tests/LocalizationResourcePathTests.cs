using LanStash.App.Localization;

namespace LanStash.Tests;

public sealed class LocalizationResourcePathTests
{
    [Theory]
    [InlineData("SimpleKey", "SimpleKey")]
    [InlineData("Dialog.Title", "Dialog/Title")]
    [InlineData("Button.AutomationProperties.Name", "Button/AutomationProperties/Name")]
    [InlineData("FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name", "FileBrowserUp/[using:Microsoft.UI.Xaml.Automation]AutomationProperties/Name")]
    [InlineData("FileBrowserUp.[using:Microsoft.UI.Xaml.Controls]ToolTipService.ToolTip", "FileBrowserUp/[using:Microsoft.UI.Xaml.Controls]ToolTipService/ToolTip")]
    [InlineData("Already/Converted/Key", "Already/Converted/Key")]
    public void PriPathPreservesNamespaceSegments(string key, string expected) => Assert.Equal(expected, WinUiLocalizationPlatform.ToResourcePath(key));
}
