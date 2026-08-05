<#
.SYNOPSIS
    Picks the most useful single-line error message out of a manifest generator's output.

.DESCRIPTION
    WinMatsch, Komac and WinGetCreate report failures as free-form console text, so the
    only signal available to the workflow today is the exit code plus whatever the tool
    printed. This helper reduces that output to one short, table-friendly line for the
    job summary: it strips ANSI colour codes, then prefers the first line the tool itself
    flagged as an error and falls back to the last non-empty line.

    This is deliberately format-agnostic - it makes no assumption about a specific error
    grammar - and becomes redundant as soon as a generator emits a machine-readable result.

.PARAMETER GeneratorOutput
    The captured stdout/stderr of the generator.

.PARAMETER MaxLength
    Maximum length of the returned message before it is truncated.

.OUTPUTS
    System.String - a single-line error message, or $null when nothing usable was printed.
#>
function Get-GeneratorFailureMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $GeneratorOutput,

        [Parameter(Mandatory = $false)]
        [ValidateRange(20, 2000)]
        [int] $MaxLength = 300
    )

    if ($null -eq $GeneratorOutput) {
        return $null
    }

    $lines = @(
        ($GeneratorOutput | Out-String) -split '\r?\n' |
            ForEach-Object { ($_ -replace '\x1b\[[0-9;]*[A-Za-z]', '').Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($lines.Count -eq 0) {
        return $null
    }

    $flagged = $lines | Where-Object { $_ -match '(?i)\b(error|failed|failure|fatal)\b' } | Select-Object -First 1
    $message = if ($flagged) { $flagged } else { $lines[-1] }

    if ($message.Length -gt $MaxLength) {
        $message = $message.Substring(0, $MaxLength - 1) + [char]0x2026
    }

    return $message
}
