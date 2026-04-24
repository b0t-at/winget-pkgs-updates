function Get-InstallerUrlEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InstallerValues
    )

    $supportedArchitectures = @{
        x32     = 'x86'
        x86     = 'x86'
        x64     = 'x64'
        arm64   = 'arm64'
        neutral = 'neutral'
    }

    foreach ($installerValue in $InstallerValues) {
        if ([string]::IsNullOrWhiteSpace($installerValue)) {
            continue
        }

        $normalizedValue = $installerValue.Trim()

        if ($normalizedValue -match '^(?<InstallerUrl>https?://\S+?)(?:\|(?<ArchitectureHint>x32|x86|x64|arm64|neutral))?$') {
            $architectureHint = $null
            if ($Matches['ArchitectureHint']) {
                $architectureHint = $supportedArchitectures[$Matches['ArchitectureHint'].ToLowerInvariant()]
            }

            [PSCustomObject]@{
                OriginalValue    = $normalizedValue
                InstallerUrl     = $Matches['InstallerUrl']
                ArchitectureHint = $architectureHint
            }
            continue
        }

        [PSCustomObject]@{
            OriginalValue    = $normalizedValue
            InstallerUrl     = $normalizedValue
            ArchitectureHint = $null
        }
    }
}

function Get-InstallerManifestEntries {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Content')]
        [string]$Content
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Content = Get-Content -Path $Path -Raw
    }

    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $inInstallersSection = $false
    $currentArchitecture = $null
    $currentInstallerUrl = $null

    foreach ($line in $Content -split "`r?`n") {
        if (-not $inInstallersSection) {
            if ($line -match '^\s*Installers:\s*$') {
                $inInstallersSection = $true
            }
            continue
        }

        # Stop at the next top-level YAML key (but not list items starting with -)
        if ($line -match '^\S' -and $line -notmatch '^\s*-') {
            break
        }

        if ($line -match '^\s*-\s+') {
            if ($currentArchitecture -and $currentInstallerUrl) {
                [void]$entries.Add([PSCustomObject]@{
                    Architecture = $currentArchitecture
                    InstallerUrl = $currentInstallerUrl
                })
            }

            $currentArchitecture = $null
            $currentInstallerUrl = $null
        }

        if ($line -match '^\s*-?\s*Architecture:\s*(?<Architecture>[^#\r\n]+?)\s*$') {
            $currentArchitecture = $Matches['Architecture'].Trim()
            continue
        }

        if ($line -match '^\s*InstallerUrl:\s*(?<InstallerUrl>\S+)') {
            $currentInstallerUrl = $Matches['InstallerUrl'].Trim()
        }
    }

    if ($currentArchitecture -and $currentInstallerUrl) {
        [void]$entries.Add([PSCustomObject]@{
            Architecture = $currentArchitecture
            InstallerUrl = $currentInstallerUrl
        })
    }

    return $entries
}

function Get-NormalizedInstallerUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerUrl,

        [Parameter(Mandatory = $false)]
        [string[]]$KnownVersions = @()
    )

    $normalizedInstallerUrl = $InstallerUrl.ToLowerInvariant()
    $normalizedInstallerUrl = [regex]::Replace($normalizedInstallerUrl, '/releases/download/[^/]+/', '/releases/download/{tag}/')

    foreach ($knownVersion in @($KnownVersions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object { $_.Length } -Descending)) {
        $normalizedInstallerUrl = $normalizedInstallerUrl.Replace($knownVersion.ToLowerInvariant(), '{version}')
    }

    return $normalizedInstallerUrl
}

function Test-GeneratedInstallerArchitecture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $true)]
        [string]$ManifestOutPath,

        [Parameter(Mandatory = $true)]
        [string[]]$RequestedInstallerValues
    )

    $requestedEntries = @(Get-InstallerUrlEntries -InstallerValues $RequestedInstallerValues)
    if (-not $requestedEntries) {
        return
    }

    $packagePath = $PackageIdentifier -replace '\.', '/'
    $firstChar = $PackageIdentifier[0].ToString().ToLowerInvariant()
    $generatedManifestPath = Join-Path $ManifestOutPath "manifests/$firstChar/$packagePath/$CurrentVersion/$PackageIdentifier.installer.yaml"

    if (-not (Test-Path $generatedManifestPath)) {
        throw "Generated installer manifest not found for $PackageIdentifier $CurrentVersion at $generatedManifestPath"
    }

    $generatedEntries = @(Get-InstallerManifestEntries -Path $generatedManifestPath)
    if (-not $generatedEntries) {
        throw "No installer entries found in generated installer manifest $generatedManifestPath"
    }

    $validationErrors = [System.Collections.Generic.List[string]]::new()
    $hintedEntries = @($requestedEntries | Where-Object { $_.ArchitectureHint })
    $hintedInstallerUrls = @($hintedEntries | Select-Object -ExpandProperty InstallerUrl)

    foreach ($hintedEntry in $hintedEntries) {
        $generatedMatches = @($generatedEntries | Where-Object { $_.InstallerUrl -eq $hintedEntry.InstallerUrl })
        if (-not $generatedMatches) {
            [void]$validationErrors.Add("No generated installer entry found for hinted URL $($hintedEntry.InstallerUrl)")
            continue
        }

        $matchingArchitecture = @($generatedMatches | Where-Object { $_.Architecture -eq $hintedEntry.ArchitectureHint })
        if (-not $matchingArchitecture) {
            $generatedArchitectures = ($generatedMatches | Select-Object -ExpandProperty Architecture) -join ', '
            [void]$validationErrors.Add("Generated architecture mismatch for $($hintedEntry.InstallerUrl): expected $($hintedEntry.ArchitectureHint), got [$generatedArchitectures]")
        }
    }

    try {
        $previousVersion = Get-LatestVersionInWinget -PackageId $PackageIdentifier
        if ($previousVersion -and $previousVersion -ne $CurrentVersion) {
            $previousManifestUrl = "https://raw.githubusercontent.com/microsoft/winget-pkgs/refs/heads/master/manifests/$firstChar/$packagePath/$previousVersion/$PackageIdentifier.installer.yaml"
            $previousInstallerManifestContent = (Invoke-WebRequest -Uri $previousManifestUrl -UseBasicParsing).Content
            $previousEntries = @(Get-InstallerManifestEntries -Content $previousInstallerManifestContent)

            if ($previousEntries) {
                $knownVersions = @($CurrentVersion, $previousVersion) | Sort-Object -Unique
                $previousEntriesByNormalizedUrl = @{}

                foreach ($previousEntry in $previousEntries) {
                    $normalizedInstallerUrl = Get-NormalizedInstallerUrl -InstallerUrl $previousEntry.InstallerUrl -KnownVersions $knownVersions
                    if (-not $previousEntriesByNormalizedUrl.ContainsKey($normalizedInstallerUrl)) {
                        $previousEntriesByNormalizedUrl[$normalizedInstallerUrl] = [System.Collections.Generic.List[string]]::new()
                    }

                    $previousEntriesByNormalizedUrl[$normalizedInstallerUrl].Add([string]$previousEntry.Architecture)
                }

                foreach ($generatedEntry in $generatedEntries) {
                    if ($hintedInstallerUrls -contains $generatedEntry.InstallerUrl) {
                        continue
                    }

                    $normalizedInstallerUrl = Get-NormalizedInstallerUrl -InstallerUrl $generatedEntry.InstallerUrl -KnownVersions $knownVersions
                    if (-not $previousEntriesByNormalizedUrl.ContainsKey($normalizedInstallerUrl)) {
                        continue
                    }

                    $previousArchitectures = @($previousEntriesByNormalizedUrl[$normalizedInstallerUrl] | Sort-Object -Unique)
                    if ($previousArchitectures.Count -eq 1 -and $previousArchitectures[0] -ne $generatedEntry.Architecture) {
                        [void]$validationErrors.Add("Generated architecture drift detected for $($generatedEntry.InstallerUrl): expected $($previousArchitectures[0]) based on previous winget manifest, got $($generatedEntry.Architecture)")
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Skipped previous-manifest architecture comparison for ${PackageIdentifier}: $($_.Exception.Message)"
    }

    if ($validationErrors.Count -gt 0) {
        throw "Installer architecture validation failed for $PackageIdentifier ${CurrentVersion}:`n - $($validationErrors -join "`n - ")"
    }

    Write-Host "Installer architecture validation passed for $PackageIdentifier $CurrentVersion"
}
