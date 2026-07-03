using System.CommandLine;
using WingetMaintainer.Cli.Commands;

RootCommand root = new("winget-maintainer — tooling to maintain winget package manifests.");
root.AddCommand(MatrixCommand.Create());
root.AddCommand(InventoryCommand.Create());
root.AddCommand(HashCommand.Create());
root.AddCommand(SubmitCommand.Create());
root.AddCommand(NotifyCommand.Create());
return await root.InvokeAsync(args);
