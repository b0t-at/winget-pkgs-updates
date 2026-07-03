using System.CommandLine;
using WingetMaintainer.Cli.Commands;

RootCommand root = new("winget-maintainer — tooling to maintain winget package manifests.");
root.AddCommand(MatrixCommand.Create());
root.AddCommand(InventoryCommand.Create());
return await root.InvokeAsync(args);
