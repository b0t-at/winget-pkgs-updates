Param(
    [Parameter(Position = 0, HelpMessage = 'The Manifest to install in the Sandbox.')]
    [String] $ManifestURL,
    [Parameter(Position = 1, HelpMessage = 'The script to run in the Sandbox.')]
    [ScriptBlock] $Script,
    [switch] $SkipManifestValidation,
    [switch] $EnableExperimentalFeatures,
    [Parameter(HelpMessage = 'Additional options for WinGet')]
    [string] $WinGetOptions
)

Write-Host "Running Test-Manifest-Sandbox with ManifestURL: $ManifestURL"