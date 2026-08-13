using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private static readonly string[] EmojiChoices =
    [
        "😀", "😂", "😊", "😍", "😎", "🤔", "😅", "😭",
        "👍", "👏", "🙏", "💪", "🎉", "❤️", "✨", "🔥",
        "⭐", "✅", "❌", "❓", "💡", "📌", "📎", "☕",
    ];

    private Flyout? _emojiFlyout;

    private void ConfigureEmojiAction()
    {
        var name = LocalizationService.Current.Get("ChatEmojiActionName");
        AutomationProperties.SetName(EmojiButton, name);
        ToolTipService.SetToolTip(EmojiButton, name);
    }

    private void UpdateEmojiAction()
    {
        EmojiButton.Visibility = Visible(_composer.CanEdit);
        EmojiButton.IsEnabled = _composer.CanEdit;
    }

    private void Emoji_Click(object sender, RoutedEventArgs e)
    {
        _emojiFlyout ??= BuildEmojiFlyout();
        _emojiFlyout.ShowAt(EmojiButton);
    }

    private Flyout BuildEmojiFlyout()
    {
        var localization = LocalizationService.Current;
        var panel = new GridView
        {
            MaxWidth = 352,
            MaxHeight = 264,
            IsItemClickEnabled = false,
            SelectionMode = ListViewSelectionMode.None,
        };
        foreach (var emoji in EmojiChoices)
        {
            var button = new Button
            {
                Content = emoji,
                FontSize = 24,
                MinWidth = 44,
                MinHeight = 44,
                Padding = new Thickness(0),
            };
            AutomationProperties.SetName(
                button,
                localization.Format("ChatEmojiItemAutomationName", emoji));
            button.Click += (_, _) => InsertEmoji(emoji);
            panel.Items.Add(button);
        }
        return new Flyout { Content = panel };
    }

    private void InsertEmoji(string emoji)
    {
        var insertion = ChatEmojiInsertion.Apply(
            ComposerInput.Text,
            ComposerInput.SelectionStart,
            ComposerInput.SelectionLength,
            emoji);
        ComposerInput.Text = insertion.Text;
        ComposerInput.SelectionStart = insertion.Caret;
        ComposerInput.SelectionLength = 0;
        _composer.DraftText = insertion.Text;
        _emojiFlyout?.Hide();
        ComposerInput.Focus(FocusState.Keyboard);
    }

    private void DisposeEmojiFlyout()
    {
        _emojiFlyout?.Hide();
        _emojiFlyout = null;
    }
}
