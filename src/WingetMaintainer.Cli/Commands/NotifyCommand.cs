using System.CommandLine;
using WingetMaintainer.Core.Notifications;

namespace WingetMaintainer.Cli.Commands;

/// <summary><c>notify</c> — send an ntfy notification.</summary>
internal static class NotifyCommand
{
    public static Command Create()
    {
        Option<string> urlOption = new("--url", "ntfy server URL.") { IsRequired = true };
        Option<string> topicOption = new("--topic", "ntfy topic.") { IsRequired = true };
        Option<string> titleOption = new("--title", "Notification title.") { IsRequired = true };
        Option<string> messageOption = new("--message", "Notification message.") { IsRequired = true };
        Option<int> priorityOption = new("--priority", () => 3, "Priority 1-5.");
        Option<string[]> tagsOption = new("--tag", "Tag (repeatable).") { AllowMultipleArgumentsPerToken = true };

        Command command = new("notify", "Send an ntfy notification.")
        {
            urlOption, topicOption, titleOption, messageOption, priorityOption, tagsOption,
        };

        command.SetHandler(async (context) =>
        {
            string url = context.ParseResult.GetValueForOption(urlOption)!;
            string topic = context.ParseResult.GetValueForOption(topicOption)!;
            string title = context.ParseResult.GetValueForOption(titleOption)!;
            string message = context.ParseResult.GetValueForOption(messageOption)!;
            int priority = context.ParseResult.GetValueForOption(priorityOption);
            string[] tags = context.ParseResult.GetValueForOption(tagsOption) ?? [];

            NtfyNotification notification = new()
            {
                Topic = topic,
                Title = title,
                Message = message,
                Priority = priority,
                Tags = tags.Length > 0 ? tags : null,
            };

            using HttpClient httpClient = new();
            NtfyClient client = new(httpClient);
            NtfyResult result = await client.SendAsync(url, notification, context.GetCancellationToken());

            if (result.Success)
            {
                Console.WriteLine($"Notification sent to topic '{topic}'.");
            }
            else
            {
                await Console.Error.WriteLineAsync($"Failed to send notification: {result.Error}");
                context.ExitCode = 1;
            }
        });

        return command;
    }
}
