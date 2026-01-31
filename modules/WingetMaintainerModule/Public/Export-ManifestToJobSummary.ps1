<#
.SYNOPSIS
    Exports manifest YAML files to GitHub Actions job summary.

.DESCRIPTION
    Reads all YAML files from a manifest folder and outputs them as collapsible
    markdown blocks to the GitHub Actions job summary. This provides visibility
    into the generated manifest content for debugging purposes.

.PARAMETER ManifestPath
    Path to the manifest folder containing YAML files.

.PARAMETER PackageId
    The package identifier (e.g., "Microsoft.VSCode"). Used in summary header.

.PARAMETER Version
    The package version. Used in summary header.

.EXAMPLE
    Export-ManifestToJobSummary -ManifestPath "./manifests/m/Microsoft/VSCode/1.85.0" `
        -PackageId "Microsoft.VSCode" -Version "1.85.0"

.NOTES
    This function writes directly to $env:GITHUB_STEP_SUMMARY when running in
    GitHub Actions. When running locally, it outputs to the console.
#>

function Export-ManifestToJobSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
                throw "Manifest path '$_' does not exist or is not a directory."
            }
            return $true
        })]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Version
    )

    $summaryContent = @()

    # Header
    $summaryContent += "## 📦 Manifest: $PackageId v$Version"
    $summaryContent += ""
    $summaryContent += "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    $summaryContent += ""
    $summaryContent += "**Path:** ``$ManifestPath``"
    $summaryContent += ""

    # Get all YAML files
    $yamlFiles = Get-ChildItem -Path $ManifestPath -Filter "*.yaml" -File | Sort-Object Name

    if ($yamlFiles.Count -eq 0) {
        $summaryContent += "⚠️ No YAML files found in manifest folder."
    }
    else {
        $summaryContent += "### Manifest Files ($($yamlFiles.Count))"
        $summaryContent += ""

        foreach ($file in $yamlFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
                
                # Determine file type for icon
                $icon = "📄"
                if ($file.Name -match '\.installer\.yaml$') {
                    $icon = "🔧"
                }
                elseif ($file.Name -match '\.locale\..+\.yaml$') {
                    $icon = "🌐"
                }
                
                # Add collapsible section
                $summaryContent += "<details>"
                $summaryContent += "<summary>$icon $($file.Name) ($('{0:N0}' -f $content.Length) bytes)</summary>"
                $summaryContent += ""
                $summaryContent += '```yaml'
                $summaryContent += $content.TrimEnd()
                $summaryContent += '```'
                $summaryContent += ""
                $summaryContent += "</details>"
                $summaryContent += ""
            }
            catch {
                $summaryContent += "<details>"
                $summaryContent += "<summary>❌ $($file.Name) (failed to read)</summary>"
                $summaryContent += ""
                $summaryContent += "Error: $($_.Exception.Message)"
                $summaryContent += ""
                $summaryContent += "</details>"
                $summaryContent += ""
            }
        }
    }

    # Join all content
    $fullSummary = $summaryContent -join "`n"

    # Write to GitHub Actions step summary if available
    if ($env:GITHUB_STEP_SUMMARY) {
        Write-Verbose "Writing to GitHub Actions step summary: $env:GITHUB_STEP_SUMMARY"
        $fullSummary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
        Write-Host "Manifest exported to job summary" -ForegroundColor Green
    }
    else {
        # Output to console when not in GitHub Actions
        Write-Host "GitHub Actions step summary not available. Outputting to console:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host $fullSummary
    }

    return @{
        Success    = $true
        FileCount  = $yamlFiles.Count
        TotalBytes = ($yamlFiles | ForEach-Object { (Get-Item $_.FullName).Length } | Measure-Object -Sum).Sum
    }
}

# Export the function when loaded as a module
Export-ModuleMember -Function Export-ManifestToJobSummary
