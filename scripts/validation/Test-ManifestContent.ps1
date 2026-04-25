<#
.SYNOPSIS
    Validates winget manifest content before submission.

.DESCRIPTION
    Parses and validates YAML manifest files to ensure they meet quality requirements
    before submitting a Pull Request. This script performs semantic pre-validation
    checks that complement the Windows Sandbox testing, including comparison against
    the currently published manifest in microsoft/winget-pkgs.

.PARAMETER ManifestPath
    Path to the manifest folder containing the YAML files.

.PARAMETER PublishedPackageRoot
    Optional local path to the published package directory containing version folders.
    When omitted, the script compares against microsoft/winget-pkgs via the GitHub API.

.OUTPUTS
    PSCustomObject with properties:
    - Valid: Boolean indicating if the manifest passed all checks
    - Errors: Array of error messages (empty if Valid is true)
    - Warnings: Array of warning messages

.EXAMPLE
    .\Test-ManifestContent.ps1 -ManifestPath ".\manifests\m\Microsoft\VSCode\1.85.0"

.NOTES
    Exit Codes:
    0 = Success (manifest is valid)
    4 = Validation error (matches existing pattern)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Path to the manifest folder containing YAML files.')]
    [ValidateScript({
        if (-not (Test-Path -Path $_ -PathType Container)) {
            throw "Manifest path '$_' does not exist or is not a directory."
        }
        return $true
    })]
    [string] $ManifestPath,

    [Parameter(Mandatory = $false, HelpMessage = 'Optional path to a published package directory that contains version folders.')]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) {
            return $true
        }
        if (-not (Test-Path -Path $_ -PathType Container)) {
            throw "PublishedPackageRoot '$_' does not exist or is not a directory."
        }
        return $true
    })]
    [string] $PublishedPackageRoot
)

#region Helper Functions

function Write-ValidationResult {
    param(
        [bool] $Valid,
        [string[]] $Errors,
        [string[]] $Warnings
    )
    
    $result = [PSCustomObject]@{
        Valid    = $Valid
        Errors   = $Errors
        Warnings = $Warnings
    }
    
    return $result
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [object] $Object,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }

        return $null
    }

    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-HasValue {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Value)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value.Count -gt 0
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value).Count -gt 0
    }

    return $true
}

function ConvertTo-Array {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    return @($Value)
}

function Get-LocalManifestFiles {
    param([string] $Path)

    $yamlFiles = @(Get-ChildItem -Path $Path -Filter '*.yaml' -File | Sort-Object Name)

    if ($yamlFiles.Count -eq 0) {
        return $null
    }

    return $yamlFiles
}

function Test-YamlParseable {
    param(
        [Parameter(Mandatory = $true)] [string] $Content,
        [Parameter(Mandatory = $true)] [string] $SourceName
    )

    try {
        $parsed = $Content | ConvertFrom-Yaml -ErrorAction Stop
        return @{ Success = $true; Data = $parsed; Error = $null; Source = $SourceName }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message; Source = $SourceName }
    }
}

function Get-SortableVersionKey {
    param([AllowNull()] [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return ''
    }

    return [regex]::Replace($Version, '(\d+)', {
            param($Match)
            $Match.Value.PadLeft(20, '0')
        })
}

function Get-NumericVersionAlias {
    param([AllowNull()] [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^\d+(\.\d+)*$') {
        return $null
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $Version.Split('.')) {
        $normalizedSegment = $segment.TrimStart('0')
        if ([string]::IsNullOrWhiteSpace($normalizedSegment)) {
            $normalizedSegment = '0'
        }
        $segments.Add($normalizedSegment)
    }

    while ($segments.Count -gt 1 -and $segments[$segments.Count - 1] -eq '0') {
        $segments.RemoveAt($segments.Count - 1)
    }

    return ($segments.ToArray() -join '.')
}

function ConvertTo-ManifestSet {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Documents,
        [Parameter(Mandatory = $true)] [string] $Source
    )

    $packageIdentifiers = [System.Collections.Generic.List[string]]::new()
    $packageVersions = [System.Collections.Generic.List[string]]::new()
    $installerDocument = $null
    $versionDocument = $null
    $defaultLocaleDocument = $null
    $localeDocuments = @()

    foreach ($document in $Documents) {
        $data = $document.Data
        $packageIdentifier = [string](Get-PropertyValue -Object $data -Name 'PackageIdentifier')
        $packageVersion = [string](Get-PropertyValue -Object $data -Name 'PackageVersion')
        $manifestType = [string](Get-PropertyValue -Object $data -Name 'ManifestType')
        $normalizedManifestType = if (Test-HasValue $manifestType) { $manifestType.ToLowerInvariant() } else { '' }
        $hasInstallers = Test-HasValue (Get-PropertyValue -Object $data -Name 'Installers')

        if (Test-HasValue $packageIdentifier) {
            $packageIdentifiers.Add($packageIdentifier)
        }

        if (Test-HasValue $packageVersion) {
            $packageVersions.Add($packageVersion)
        }

        if ($hasInstallers -and -not $installerDocument) {
            $installerDocument = $document
        }

        switch ($normalizedManifestType) {
            'installer' {
                if (-not $installerDocument) {
                    $installerDocument = $document
                }
            }
            'singleton' {
                if (-not $installerDocument -and $hasInstallers) {
                    $installerDocument = $document
                }
                if (-not $versionDocument) {
                    $versionDocument = $document
                }
                if (-not $defaultLocaleDocument) {
                    $defaultLocaleDocument = $document
                }
            }
            'version' {
                if (-not $versionDocument) {
                    $versionDocument = $document
                }
            }
            'defaultlocale' {
                if (-not $defaultLocaleDocument) {
                    $defaultLocaleDocument = $document
                }
            }
            'locale' {
                $localeDocuments += $document
            }
        }
    }

    if (-not $installerDocument) {
        $installerDocument = $Documents | Where-Object {
            Test-HasValue (Get-PropertyValue -Object $_.Data -Name 'Installers')
        } | Select-Object -First 1
    }

    $installerEntries = @()
    if ($installerDocument) {
        $installerEntries = @(ConvertTo-Array (Get-PropertyValue -Object $installerDocument.Data -Name 'Installers'))
    }

    $uniquePackageIdentifiers = @($packageIdentifiers | Sort-Object -Unique)
    $uniquePackageVersions = @($packageVersions | Sort-Object -Unique)

    return [PSCustomObject]@{
        Source                  = $Source
        PackageIdentifier       = $uniquePackageIdentifiers | Select-Object -First 1
        PackageIdentifierValues = $uniquePackageIdentifiers
        PackageVersion          = $uniquePackageVersions | Select-Object -First 1
        PackageVersionValues    = $uniquePackageVersions
        InstallerDocument       = if ($installerDocument) { $installerDocument.Data } else { $null }
        InstallerDocumentName   = if ($installerDocument) { $installerDocument.Name } else { $null }
        VersionDocument         = if ($versionDocument) { $versionDocument.Data } else { $null }
        DefaultLocaleDocument   = if ($defaultLocaleDocument) { $defaultLocaleDocument.Data } else { $null }
        LocaleDocuments         = @($localeDocuments | ForEach-Object { $_.Data })
        InstallerEntries        = $installerEntries
        Documents               = @($Documents)
    }
}

function Get-PackageRelativePath {
    param([Parameter(Mandatory = $true)] [string] $PackageIdentifier)

    $firstChar = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    $packagePath = $PackageIdentifier.Replace('.', '/')
    return "manifests/$firstChar/$packagePath"
}

function Get-GitHubHeaders {
    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'winget-pkgs-updates-validation'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINGET_PKGS_GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:WINGET_PKGS_GITHUB_TOKEN)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    return $headers
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }

    if ($response.PSObject.Properties.Name -contains 'StatusCode') {
        return [int]$response.StatusCode
    }

    if ($response.PSObject.Properties.Name -contains 'Status') {
        return [int]$response.Status
    }

    return $null
}

function Invoke-GitHubApiJson {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [switch] $AllowNotFound
    )

    try {
        return Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubHeaders) -Method Get -ErrorAction Stop
    }
    catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Invoke-RemoteTextDownload {
    param([Parameter(Mandatory = $true)] [string] $Uri)

    $response = Invoke-WebRequest -Uri $Uri -Headers (Get-GitHubHeaders) -Method Get -ErrorAction Stop
    return $response.Content
}

function Get-PublishedVersionSources {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [AllowEmptyString()] [string] $PublishedPackageRootPath
    )

    if (-not [string]::IsNullOrWhiteSpace($PublishedPackageRootPath)) {
        return @(Get-ChildItem -Path $PublishedPackageRootPath -Directory | Sort-Object Name | ForEach-Object {
                [PSCustomObject]@{
                    Name = $_.Name
                    Kind = 'Local'
                    Path = $_.FullName
                }
            })
    }

    $packageRelativePath = Get-PackageRelativePath -PackageIdentifier $PackageIdentifier
    $uri = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$packageRelativePath"
    $response = Invoke-GitHubApiJson -Uri $uri -AllowNotFound

    if ($null -eq $response) {
        return @()
    }

    return @($response | Where-Object { $_.type -eq 'dir' } | ForEach-Object {
            [PSCustomObject]@{
                Name   = $_.name
                Kind   = 'GitHub'
                Path   = $_.path
                ApiUrl = $_.url
            }
        })
}

function Read-PublishedManifestSet {
    param([Parameter(Mandatory = $true)] [pscustomobject] $VersionSource)

    $documents = @()

    if ($VersionSource.Kind -eq 'Local') {
        $yamlFiles = @(Get-ChildItem -Path $VersionSource.Path -Filter '*.yaml' -File | Sort-Object Name)
        foreach ($yamlFile in $yamlFiles) {
            $content = Get-Content -Path $yamlFile.FullName -Raw -ErrorAction Stop
            $parseResult = Test-YamlParseable -Content $content -SourceName $yamlFile.FullName
            if (-not $parseResult.Success) {
                throw "Failed to parse published manifest '$($yamlFile.FullName)': $($parseResult.Error)"
            }

            $documents += [PSCustomObject]@{
                Name = $yamlFile.Name
                Path = $yamlFile.FullName
                Data = $parseResult.Data
            }
        }
    }
    else {
        $files = @(Invoke-GitHubApiJson -Uri $VersionSource.ApiUrl)
        $yamlFiles = @($files | Where-Object { $_.type -eq 'file' -and $_.name -like '*.yaml' } | Sort-Object name)
        foreach ($yamlFile in $yamlFiles) {
            $content = Invoke-RemoteTextDownload -Uri $yamlFile.download_url
            $parseResult = Test-YamlParseable -Content $content -SourceName $yamlFile.path
            if (-not $parseResult.Success) {
                throw "Failed to parse published manifest '$($yamlFile.path)': $($parseResult.Error)"
            }

            $documents += [PSCustomObject]@{
                Name = $yamlFile.name
                Path = $yamlFile.path
                Data = $parseResult.Data
            }
        }
    }

    return ConvertTo-ManifestSet -Documents $documents -Source $VersionSource.Name
}

function Get-InstallerHashRecords {
    param([Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet)

    $records = @()
    foreach ($installer in @($ManifestSet.InstallerEntries)) {
        $hash = [string](Get-PropertyValue -Object $installer -Name 'InstallerSha256')
        if (-not (Test-HasValue $hash)) {
            continue
        }

        $records += [PSCustomObject]@{
            Hash          = $hash.ToLowerInvariant()
            Architecture  = [string](Get-PropertyValue -Object $installer -Name 'Architecture')
            InstallerType = [string](Get-PropertyValue -Object $installer -Name 'InstallerType')
            InstallerUrl  = [string](Get-PropertyValue -Object $installer -Name 'InstallerUrl')
            PackageVersion = $ManifestSet.PackageVersion
            Source        = $ManifestSet.Source
        }
    }

    return $records
}

function Get-MatchingInstallerEntry {
    param(
        [Parameter(Mandatory = $true)] [object[]] $CurrentEntries,
        [Parameter(Mandatory = $true)] [object] $ReferenceEntry
    )

    $candidates = @($CurrentEntries)
    if ($candidates.Count -eq 0) {
        return $null
    }

    $referenceArchitecture = [string](Get-PropertyValue -Object $ReferenceEntry -Name 'Architecture')
    if (Test-HasValue $referenceArchitecture) {
        $architectureMatches = @($candidates | Where-Object {
                [string](Get-PropertyValue -Object $_ -Name 'Architecture') -ieq $referenceArchitecture
            })
        if ($architectureMatches.Count -gt 0) {
            $candidates = $architectureMatches
        }
    }

    $referenceInstallerType = [string](Get-PropertyValue -Object $ReferenceEntry -Name 'InstallerType')
    if (Test-HasValue $referenceInstallerType -and $candidates.Count -gt 1) {
        $installerTypeMatches = @($candidates | Where-Object {
                [string](Get-PropertyValue -Object $_ -Name 'InstallerType') -ieq $referenceInstallerType
            })
        if ($installerTypeMatches.Count -gt 0) {
            $candidates = $installerTypeMatches
        }
    }

    return $candidates | Select-Object -First 1
}

$script:InstallerManifestStickyProperties = @(
    'MinimumOSVersion',
    'Platform',
    'InstallerSwitches',
    'InstallModes',
    'UpgradeBehavior',
    'Commands',
    'Protocols',
    'FileExtensions',
    'Dependencies',
    'Capabilities',
    'RestrictedCapabilities',
    'AppsAndFeaturesEntries',
    'Scope',
    'ElevationRequirement',
    'ExpectedReturnCodes',
    'UnsupportedOSArchitectures',
    'Markets',
    'NestedInstallerType',
    'NestedInstallerFiles',
    'PackageFamilyName',
    'ArchiveBinariesDependOnPath',
    'DisplayInstallWarnings',
    'InstallationMetadata'
)

$script:InstallerEntryStickyProperties = @(
    'MinimumOSVersion',
    'Platform',
    'InstallerSwitches',
    'InstallModes',
    'UpgradeBehavior',
    'Commands',
    'Protocols',
    'FileExtensions',
    'Dependencies',
    'Capabilities',
    'RestrictedCapabilities',
    'AppsAndFeaturesEntries',
    'Scope',
    'ElevationRequirement',
    'ExpectedReturnCodes',
    'UnsupportedOSArchitectures',
    'Markets',
    'NestedInstallerType',
    'NestedInstallerFiles',
    'PackageFamilyName',
    'ArchiveBinariesDependOnPath',
    'DisplayInstallWarnings'
)

function Test-InstallerMetadataConsistency {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $CurrentManifestSet,
        [Parameter(Mandatory = $true)] [pscustomobject] $PreviousManifestSet
    )

    $consistencyErrors = [System.Collections.Generic.List[string]]::new()
    $currentInstallerDocument = $CurrentManifestSet.InstallerDocument
    $previousInstallerDocument = $PreviousManifestSet.InstallerDocument

    if ($null -eq $currentInstallerDocument -or $null -eq $previousInstallerDocument) {
        return @()
    }

    foreach ($propertyName in $script:InstallerManifestStickyProperties) {
        $previousValue = Get-PropertyValue -Object $previousInstallerDocument -Name $propertyName
        $currentValue = Get-PropertyValue -Object $currentInstallerDocument -Name $propertyName

        if ((Test-HasValue $previousValue) -and -not (Test-HasValue $currentValue)) {
            $consistencyErrors.Add("Missing property $propertyName compared to published version $($PreviousManifestSet.PackageVersion)")
        }
    }

    $currentInstallers = @($CurrentManifestSet.InstallerEntries)
    foreach ($previousInstaller in @($PreviousManifestSet.InstallerEntries)) {
        $matchingInstaller = Get-MatchingInstallerEntry -CurrentEntries $currentInstallers -ReferenceEntry $previousInstaller
        if ($null -eq $matchingInstaller) {
            continue
        }

        $architecture = [string](Get-PropertyValue -Object $previousInstaller -Name 'Architecture')
        $architectureSuffix = if (Test-HasValue $architecture) { " for architecture '$architecture'" } else { '' }

        foreach ($propertyName in $script:InstallerEntryStickyProperties) {
            $previousValue = Get-PropertyValue -Object $previousInstaller -Name $propertyName
            $currentValue = Get-PropertyValue -Object $matchingInstaller -Name $propertyName

            if ((Test-HasValue $previousValue) -and -not (Test-HasValue $currentValue)) {
                $consistencyErrors.Add("Missing installer property $propertyName$architectureSuffix compared to published version $($PreviousManifestSet.PackageVersion)")
            }
        }
    }

    return $consistencyErrors.ToArray()
}

#endregion

#region Main Validation Logic

Write-Host "=== Winget Manifest Content Validation ===" -ForegroundColor Cyan
Write-Host "Manifest Path: $ManifestPath" -ForegroundColor Gray
Write-Host ""

$errors = @()
$warnings = @()

# Ensure powershell-yaml module is available
if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
    Write-Host "Installing powershell-yaml module..." -ForegroundColor Yellow
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module -Name powershell-yaml -ErrorAction Stop

# Get manifest files
Write-Host "--> Locating manifest files..." -ForegroundColor White
$manifestFiles = Get-LocalManifestFiles -Path $ManifestPath

if ($null -eq $manifestFiles) {
    $errors += "No YAML files found in manifest folder: $ManifestPath"
    Write-Host "ERROR: No YAML files found" -ForegroundColor Red
    Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    exit 4
}

Write-Host "  Found $($manifestFiles.Count) manifest file(s):" -ForegroundColor Gray
foreach ($file in $manifestFiles) {
    Write-Host "    - $($file.Name)" -ForegroundColor Gray
}

# Validate each file is parseable YAML
Write-Host ""
Write-Host "--> Validating YAML syntax..." -ForegroundColor White

$parsedDocuments = @()

foreach ($file in $manifestFiles) {
    $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
    $parseResult = Test-YamlParseable -Content $content -SourceName $file.FullName
    
    if ($parseResult.Success) {
        Write-Host "  [OK] $($file.Name)" -ForegroundColor Green
        $parsedDocuments += [PSCustomObject]@{
            Name = $file.Name
            Path = $file.FullName
            Data = $parseResult.Data
        }
    }
    else {
        $errors += "Failed to parse $($file.Name): $($parseResult.Error)"
        Write-Host "  [FAIL] $($file.Name): $($parseResult.Error)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "--> Running content validation checks..." -ForegroundColor White

if ($errors.Count -eq 0) {
    $localManifestSet = ConvertTo-ManifestSet -Documents $parsedDocuments -Source $ManifestPath

    if ($null -eq $localManifestSet.InstallerDocument) {
        $errors += 'Installer manifest data not found in local manifest set.'
    }

    if ($localManifestSet.PackageIdentifierValues.Count -eq 0) {
        $errors += 'PackageIdentifier is missing from the manifest set.'
    }
    elseif ($localManifestSet.PackageIdentifierValues.Count -gt 1) {
        $errors += "PackageIdentifier is inconsistent across manifest files: $($localManifestSet.PackageIdentifierValues -join ', ')"
    }

    if ($localManifestSet.PackageVersionValues.Count -eq 0) {
        $errors += 'PackageVersion is missing from the manifest set.'
    }
    elseif ($localManifestSet.PackageVersionValues.Count -gt 1) {
        $errors += "PackageVersion is inconsistent across manifest files: $($localManifestSet.PackageVersionValues -join ', ')"
    }

    if ($null -eq $localManifestSet.VersionDocument) {
        $warnings += 'Version manifest not found (single-file manifests are allowed).'
    }

    if ($null -eq $localManifestSet.DefaultLocaleDocument -and $localManifestSet.LocaleDocuments.Count -eq 0) {
        $warnings += 'No locale manifest was found (single-file manifests are allowed).'
    }

    if ($localManifestSet.InstallerEntries.Count -eq 0) {
        $errors += 'No Installers entries were found in the manifest set.'
    }

    $localInstallerHashRecords = @()
    foreach ($installer in @($localManifestSet.InstallerEntries)) {
        $installerUrl = [string](Get-PropertyValue -Object $installer -Name 'InstallerUrl')
        $installerHash = [string](Get-PropertyValue -Object $installer -Name 'InstallerSha256')
        $architecture = [string](Get-PropertyValue -Object $installer -Name 'Architecture')
        $label = if (Test-HasValue $architecture) { $architecture } else { 'unknown architecture' }

        if (-not (Test-HasValue $installerUrl)) {
            $errors += "InstallerUrl is missing for $label."
        }

        if (-not (Test-HasValue $installerHash)) {
            $errors += "InstallerSha256 is missing for $label."
        }
        elseif ($installerHash -notmatch '^[A-Fa-f0-9]{64}$') {
            $errors += "InstallerSha256 '$installerHash' for $label is not a valid 64-character SHA256 hash."
        }
    }

    if ($errors.Count -eq 0 -and (Test-HasValue $localManifestSet.PackageIdentifier) -and (Test-HasValue $localManifestSet.PackageVersion)) {
        try {
            Write-Host "  Checking published manifest history for $($localManifestSet.PackageIdentifier)..." -ForegroundColor Gray
            $publishedVersionSources = @(Get-PublishedVersionSources -PackageIdentifier $localManifestSet.PackageIdentifier -PublishedPackageRootPath $PublishedPackageRoot)

            if ($publishedVersionSources.Count -eq 0) {
                $warnings += "Published package path for $($localManifestSet.PackageIdentifier) was not found. Skipping published manifest comparison."
            }
            else {
                Write-Host "  Found $($publishedVersionSources.Count) published version folder(s) to compare against." -ForegroundColor Gray

                $publishedManifestSets = @()
                foreach ($publishedVersionSource in $publishedVersionSources) {
                    $publishedManifestSets += Read-PublishedManifestSet -VersionSource $publishedVersionSource
                }

                $exactVersionMatch = $publishedManifestSets | Where-Object { $_.PackageVersion -eq $localManifestSet.PackageVersion } | Select-Object -First 1
                if ($exactVersionMatch) {
                    $errors += "Package version $($localManifestSet.PackageVersion) is already published in winget-pkgs."
                }

                $localVersionAlias = Get-NumericVersionAlias -Version $localManifestSet.PackageVersion
                if (Test-HasValue $localVersionAlias) {
                    $aliasMatches = @($publishedManifestSets | Where-Object {
                            $_.PackageVersion -ne $localManifestSet.PackageVersion -and
                            (Get-NumericVersionAlias -Version $_.PackageVersion) -eq $localVersionAlias
                        })
                    foreach ($aliasMatch in $aliasMatches) {
                        $errors += "Package version $($localManifestSet.PackageVersion) normalizes to the same numeric alias as published version $($aliasMatch.PackageVersion)."
                    }
                }

                $localInstallerHashRecords = @(Get-InstallerHashRecords -ManifestSet $localManifestSet)
                foreach ($localInstallerHashRecord in $localInstallerHashRecords) {
                    $duplicateHashes = @(
                        foreach ($publishedManifestSet in $publishedManifestSets) {
                            if ($publishedManifestSet.PackageVersion -eq $localManifestSet.PackageVersion) {
                                continue
                            }

                            foreach ($publishedHashRecord in @(Get-InstallerHashRecords -ManifestSet $publishedManifestSet)) {
                                if ($publishedHashRecord.Hash -eq $localInstallerHashRecord.Hash) {
                                    $publishedHashRecord
                                }
                            }
                        }
                    )

                    foreach ($duplicateHash in $duplicateHashes) {
                        $architectureSuffix = if (Test-HasValue $duplicateHash.Architecture) { " ($($duplicateHash.Architecture))" } else { '' }
                        $errors += "Installer SHA256 $($localInstallerHashRecord.Hash.ToUpperInvariant()) already exists in published version $($duplicateHash.PackageVersion)$architectureSuffix."
                    }
                }

                $baselinePublishedManifest = $publishedManifestSets |
                    Where-Object { $_.PackageVersion -ne $localManifestSet.PackageVersion } |
                    Sort-Object { Get-SortableVersionKey -Version $_.PackageVersion } -Descending |
                    Select-Object -First 1

                if ($baselinePublishedManifest) {
                    $consistencyErrors = @(Test-InstallerMetadataConsistency -CurrentManifestSet $localManifestSet -PreviousManifestSet $baselinePublishedManifest)
                    foreach ($consistencyError in $consistencyErrors) {
                        $errors += $consistencyError
                    }
                }
            }
        }
        catch {
            $errors += "Failed to compare against published winget manifests: $($_.Exception.Message)"
        }
    }
}

# Summary
Write-Host ""
Write-Host "=== Validation Summary ===" -ForegroundColor Cyan

if ($warnings.Count -gt 0) {
    Write-Host "Warnings ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Errors ($($errors.Count)):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "RESULT: FAILED" -ForegroundColor Red
    
    $result = Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    Write-Output $result
    exit 4
}

Write-Host ""
Write-Host "RESULT: PASSED" -ForegroundColor Green

$result = Write-ValidationResult -Valid $true -Errors $errors -Warnings $warnings
Write-Output $result
exit 0

#endregion
