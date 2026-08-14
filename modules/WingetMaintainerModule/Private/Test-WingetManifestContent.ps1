function Test-WingetManifestContent {
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

        [Parameter(Mandatory = $false)]
        [string] $PublishedPackageRoot,

        [Parameter(Mandatory = $false)]
        [switch] $AllowStructuralRewrite,

        [Parameter(Mandatory = $false)]
        [switch] $SkipPublishedComparison
    )

    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function Write-ValidationResult {
        param(
            [bool] $Valid,
            [string[]] $Errors,
            [string[]] $Warnings
        )

        [PSCustomObject]@{
            Valid    = $Valid
            Errors   = $Errors
            Warnings = $Warnings
        }
    }

    function Add-ArtifactValidationErrors {
        param(
            [Parameter(Mandatory = $true)] [string] $Path,
            [Parameter(Mandatory = $true)] [ref] $Errors
        )

        $artifactValidation = Test-SubmittedManifestArtifacts -ManifestPath $Path
        if (-not $artifactValidation.Valid) {
            foreach ($artifactError in $artifactValidation.Errors) {
                $Errors.Value += $artifactError
            }
        }
    }

    function Get-ExpectedManifestFileNames {
        param([Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet)

        $packageIdentifier = [string]$ManifestSet.PackageIdentifier
        if (-not (Test-HasValue $packageIdentifier)) {
            return @()
        }

        $singletonDocument = $ManifestSet.Documents | Where-Object {
            [string](Get-PropertyValue -Object $_.Data -Name 'ManifestType') -ieq 'singleton'
        } | Select-Object -First 1
        if ($null -ne $singletonDocument) {
            return @("$packageIdentifier.yaml")
        }

        $expected = [System.Collections.Generic.List[string]]::new()
        $expected.Add("$packageIdentifier.yaml")

        if ($null -ne $ManifestSet.InstallerDocument) {
            $expected.Add("$packageIdentifier.installer.yaml")
        }

        if ($null -ne $ManifestSet.DefaultLocaleDocument) {
            $defaultLocale = [string](Get-PropertyValue -Object $ManifestSet.DefaultLocaleDocument -Name 'PackageLocale')
            if (-not (Test-HasValue $defaultLocale)) {
                $defaultLocale = [string](Get-PropertyValue -Object $ManifestSet.DefaultLocaleDocument -Name 'DefaultLocale')
            }
            if (Test-HasValue $defaultLocale) {
                $expected.Add("$packageIdentifier.locale.$defaultLocale.yaml")
            }
        }

        foreach ($localeDocument in @($ManifestSet.LocaleDocuments)) {
            $packageLocale = [string](Get-PropertyValue -Object $localeDocument -Name 'PackageLocale')
            if (Test-HasValue $packageLocale) {
                $expected.Add("$packageIdentifier.locale.$packageLocale.yaml")
            }
        }

        return @($expected | Sort-Object -Unique)
    }

    function Test-ManifestFileSet {
        param(
            [Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet,
            [Parameter(Mandatory = $true)] [object[]] $Documents
        )

        $errors = [System.Collections.Generic.List[string]]::new()
        $warnings = [System.Collections.Generic.List[string]]::new()

        $actualNames = @($Documents | ForEach-Object { $_.Name } | Sort-Object -Unique)
        $expectedNames = @(Get-ExpectedManifestFileNames -ManifestSet $ManifestSet)

        foreach ($actualName in $actualNames) {
            if ($actualName -notin $expectedNames) {
                $errors.Add("Unexpected manifest file '$actualName' for the submitted manifest set.")
            }
        }

        foreach ($expectedName in $expectedNames) {
            if ($expectedName -notin $actualNames) {
                $errors.Add("Expected manifest file '$expectedName' is missing from the submitted manifest set.")
            }
        }

        [PSCustomObject]@{
            Errors   = @($errors)
            Warnings = @($warnings)
        }
    }

    function Test-ManifestCollisions {
        param([Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet)

        $errors = [System.Collections.Generic.List[string]]::new()

        $localeKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($localeDocument in @($ManifestSet.LocaleDocuments)) {
            $packageLocale = [string](Get-PropertyValue -Object $localeDocument -Name 'PackageLocale')
            if (-not (Test-HasValue $packageLocale)) {
                continue
            }
            if (-not $localeKeys.Add($packageLocale)) {
                $errors.Add("Duplicate locale manifest detected for PackageLocale '$packageLocale'.")
            }
        }

        $installerKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $installerUrlKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($installer in @($ManifestSet.InstallerEntries)) {
            $architecture = [string](Get-PropertyValue -Object $installer -Name 'Architecture')
            $scope = [string](Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $ManifestSet.InstallerDocument -Name 'Scope')
            $installerType = [string](Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $ManifestSet.InstallerDocument -Name 'InstallerType')
            $installerLocale = [string](Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $ManifestSet.InstallerDocument -Name 'InstallerLocale')
            $installerUrl = [string](Get-PropertyValue -Object $installer -Name 'InstallerUrl')
            $key = "$architecture|$scope|$installerType|$installerLocale"
            if (-not $installerKeys.Add($key)) {
                $errors.Add("Duplicate installer entry detected for Architecture='$architecture', Scope='$scope', InstallerType='$installerType', InstallerLocale='$installerLocale'.")
            }
            if (Test-HasValue $installerUrl) {
                $urlKey = "$installerUrl|$architecture|$scope"
                if (-not $installerUrlKeys.Add($urlKey)) {
                    $errors.Add("Duplicate InstallerUrl detected for Architecture='$architecture' and Scope='$scope': $installerUrl")
                }
            }
        }

        return @($errors)
    }

    function Test-ManifestTypeAndLocalePolicy {
        param([Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet)

        $errors = [System.Collections.Generic.List[string]]::new()

        if ($null -ne $ManifestSet.DefaultLocaleDocument) {
            $defaultLocale = [string](Get-PropertyValue -Object $ManifestSet.DefaultLocaleDocument -Name 'PackageLocale')
            if (-not (Test-HasValue $defaultLocale)) {
                $defaultLocale = [string](Get-PropertyValue -Object $ManifestSet.DefaultLocaleDocument -Name 'DefaultLocale')
            }

            if (Test-HasValue $defaultLocale) {
                foreach ($localeDocument in @($ManifestSet.LocaleDocuments)) {
                    $packageLocale = [string](Get-PropertyValue -Object $localeDocument -Name 'PackageLocale')
                    if ($packageLocale -ieq $defaultLocale) {
                        $errors.Add("Locale manifest duplicates the default locale '$defaultLocale'; keep that locale only in the defaultLocale manifest.")
                    }
                }
            }
        }

        foreach ($document in @($ManifestSet.Documents)) {
            $manifestType = [string](Get-PropertyValue -Object $document.Data -Name 'ManifestType')
            $normalizedManifestType = if (Test-HasValue $manifestType) { $manifestType.ToLowerInvariant() } else { '' }

            switch ($normalizedManifestType) {
                'installer' {
                    $expectedName = "$($ManifestSet.PackageIdentifier).installer.yaml"
                    if ($document.Name -ine $expectedName) {
                        $errors.Add("Installer manifest must be named '$expectedName', got '$($document.Name)'.")
                    }
                }
                'defaultlocale' {
                    $packageLocale = [string](Get-PropertyValue -Object $document.Data -Name 'PackageLocale')
                    if (-not (Test-HasValue $packageLocale)) {
                        $packageLocale = [string](Get-PropertyValue -Object $document.Data -Name 'DefaultLocale')
                    }
                    if (Test-HasValue $packageLocale) {
                        $expectedName = "$($ManifestSet.PackageIdentifier).locale.$packageLocale.yaml"
                        if ($document.Name -ine $expectedName) {
                            $errors.Add("DefaultLocale manifest must be named '$expectedName', got '$($document.Name)'.")
                        }
                    }
                }
                'locale' {
                    $packageLocale = [string](Get-PropertyValue -Object $document.Data -Name 'PackageLocale')
                    if (Test-HasValue $packageLocale) {
                        $expectedName = "$($ManifestSet.PackageIdentifier).locale.$packageLocale.yaml"
                        if ($document.Name -ine $expectedName) {
                            $errors.Add("Locale manifest must be named '$expectedName', got '$($document.Name)'.")
                        }
                    }
                }
                'singleton' {
                    $expectedName = "$($ManifestSet.PackageIdentifier).yaml"
                    if ($document.Name -ine $expectedName) {
                        $errors.Add("Singleton manifest must be named '$expectedName', got '$($document.Name)'.")
                    }
                }
            }
        }

        return @($errors)
    }

    function Get-InstallerUrlHost {
        param([AllowNull()] [string] $InstallerUrl)

        if (-not (Test-HasValue $InstallerUrl)) {
            return $null
        }

        try {
            return ([Uri]$InstallerUrl).Host
        }
        catch {
            return $null
        }
    }

    function Test-InstallerTypeMatchesUrl {
        param([Parameter(Mandatory = $true)] [pscustomobject] $ManifestSet)

        $errors = [System.Collections.Generic.List[string]]::new()
        $installerDocument = $ManifestSet.InstallerDocument

        foreach ($installer in @($ManifestSet.InstallerEntries)) {
            $installerUrl = [string](Get-PropertyValue -Object $installer -Name 'InstallerUrl')
            $installerType = [string](Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $installerDocument -Name 'InstallerType')
            $nestedInstallerType = [string](Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $installerDocument -Name 'NestedInstallerType')
            $nestedInstallerFiles = @(ConvertTo-Array (Get-EffectiveInstallerProperty -Installer $installer -InstallerDocument $installerDocument -Name 'NestedInstallerFiles'))

            if (-not (Test-HasValue $installerUrl) -or -not (Test-HasValue $installerType)) {
                continue
            }

            try {
                $path = ([Uri]$installerUrl).AbsolutePath.ToLowerInvariant()
            }
            catch {
                continue
            }

            switch ($installerType.ToLowerInvariant()) {
                'msi' {
                    if (-not $path.EndsWith('.msi')) {
                        $errors.Add("InstallerType 'msi' should use an .msi URL, got '$installerUrl'.")
                    }
                }
                'msix' {
                    if (-not ($path.EndsWith('.msix') -or $path.EndsWith('.msixbundle'))) {
                        $errors.Add("InstallerType 'msix' should use an .msix or .msixbundle URL, got '$installerUrl'.")
                    }
                }
                'appx' {
                    if (-not ($path.EndsWith('.appx') -or $path.EndsWith('.appxbundle'))) {
                        $errors.Add("InstallerType 'appx' should use an .appx or .appxbundle URL, got '$installerUrl'.")
                    }
                }
                'zip' {
                    if (-not $path.EndsWith('.zip')) {
                        $errors.Add("InstallerType 'zip' should use a .zip URL, got '$installerUrl'.")
                    }
                }
                'portable' {
                    if ($path.EndsWith('.msi') -or $path.EndsWith('.msix') -or $path.EndsWith('.msixbundle')) {
                        $errors.Add("InstallerType 'portable' should not point to MSI/MSIX payloads, got '$installerUrl'.")
                    }
                }
            }

            if ((Test-HasValue $nestedInstallerType) -and -not ($path.EndsWith('.zip') -or $path.EndsWith('.exe'))) {
                $errors.Add("NestedInstallerType '$nestedInstallerType' requires an archive-like installer URL, got '$installerUrl'.")
            }
            if ((Test-HasValue $nestedInstallerType) -xor ($nestedInstallerFiles.Count -gt 0)) {
                $errors.Add("Nested installer metadata must provide both NestedInstallerType and NestedInstallerFiles together for '$installerUrl'.")
            }
        }

        return @($errors)
    }

    function Test-UpstreamDomainChange {
        param(
            [Parameter(Mandatory = $true)] [pscustomobject] $CurrentManifestSet,
            [Parameter(Mandatory = $true)] [pscustomobject] $PreviousManifestSet,
            [Parameter(Mandatory = $true)] [ref] $Warnings
        )

        $currentHosts = @(
            $CurrentManifestSet.InstallerEntries |
                ForEach-Object { Get-InstallerUrlHost -InstallerUrl ([string](Get-PropertyValue -Object $_ -Name 'InstallerUrl')) } |
                Where-Object { Test-HasValue $_ } |
                Sort-Object -Unique
        )
        $previousHosts = @(
            $PreviousManifestSet.InstallerEntries |
                ForEach-Object { Get-InstallerUrlHost -InstallerUrl ([string](Get-PropertyValue -Object $_ -Name 'InstallerUrl')) } |
                Where-Object { Test-HasValue $_ } |
                Sort-Object -Unique
        )

        if ($currentHosts.Count -eq 0 -or $previousHosts.Count -eq 0) {
            return
        }

        $newHosts = @($currentHosts | Where-Object { $_ -notin $previousHosts })
        if ($newHosts.Count -gt 0) {
            $Warnings.Value += "Installer download host changed from '$($previousHosts -join ', ')' to include '$($newHosts -join ', ')'. Review source legitimacy before submit."
        }
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

            if (Test-HasValue $packageIdentifier) { $packageIdentifiers.Add($packageIdentifier) }
            if (Test-HasValue $packageVersion) { $packageVersions.Add($packageVersion) }
            if ($hasInstallers -and -not $installerDocument) { $installerDocument = $document }

            switch ($normalizedManifestType) {
                'installer' {
                    if (-not $installerDocument) { $installerDocument = $document }
                }
                'singleton' {
                    if (-not $installerDocument -and $hasInstallers) { $installerDocument = $document }
                    if (-not $versionDocument) { $versionDocument = $document }
                    if (-not $defaultLocaleDocument) { $defaultLocaleDocument = $document }
                }
                'version' {
                    if (-not $versionDocument) { $versionDocument = $document }
                }
                'defaultlocale' {
                    if (-not $defaultLocaleDocument) { $defaultLocaleDocument = $document }
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

        [PSCustomObject]@{
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
            $headers['Authorization'] = "Bearer $env:WINGET_PKGS_GITHUB_TOKEN"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
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
            return Invoke-WithGitHubRateLimitRetry -OperationName $Uri -ScriptBlock {
                Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubHeaders) -Method Get -ErrorAction Stop
            }
        }
        catch {
            $statusCode = Get-HttpStatusCode -ErrorRecord $_
            if ($AllowNotFound -and $statusCode -eq 404) {
                return $null
            }
            throw
        }
    }

    function Invoke-GitHubGraphQl {
        param([Parameter(Mandatory = $true)] [string] $Query)

        $headers = Get-GitHubHeaders
        if (-not $headers.ContainsKey('Authorization')) {
            throw 'GitHub authentication is required to batch published manifest reads.'
        }

        $body = @{ query = $Query } | ConvertTo-Json -Compress
        return Invoke-WithGitHubRateLimitRetry -OperationName 'GitHub GraphQL manifest read' -ScriptBlock {
            $response = Invoke-RestMethod `
                -Uri 'https://api.github.com/graphql' `
                -Headers $headers `
                -Method Post `
                -ContentType 'application/json' `
                -Body $body `
                -ErrorAction Stop

            if ($null -ne $response.PSObject.Properties['errors'] -and @($response.errors).Count -gt 0) {
                $messages = @($response.errors | ForEach-Object { [string]$_.message })
                $isRateLimited = @($response.errors | Where-Object { "$($_.type)" -eq 'RATE_LIMITED' }).Count -gt 0
                $graphQlFailure = [System.Exception]::new("GitHub GraphQL request failed: $($messages -join '; ')")
                if ($isRateLimited) {
                    # GraphQL rate limits arrive as HTTP 200 with an errors array;
                    # tag the failure so the retry helper treats it as a 429.
                    $graphQlFailure.Data['StatusCode'] = 429
                }
                throw $graphQlFailure
            }

            return $response.data
        }
    }

    function ConvertFrom-GitHubContentResponse {
        param(
            [Parameter(Mandatory = $true)] [pscustomobject] $Response,
            [Parameter(Mandatory = $true)] [string] $SourceName
        )

        if ([string]$Response.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$Response.content)) {
            throw "GitHub returned unsupported content for '$SourceName'."
        }

        $encodedContent = ([string]$Response.content) -replace '\s', ''
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedContent))
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
                    Name   = [string]$_.name
                    Kind   = 'GitHub'
                    Path   = [string]$_.path
                    ApiUrl = [string]$_.url
                    PackageIdentifier = $PackageIdentifier
                }
            })
    }

    function Read-GitHubPublishedManifestSets {
        param(
            [Parameter(Mandatory = $true)] [object[]] $VersionSources,
            [Parameter(Mandatory = $true)] [string] $PackageIdentifier
        )

        $manifestSets = [System.Collections.Generic.List[object]]::new()
        $batchSize = 50

        for ($offset = 0; $offset -lt $VersionSources.Count; $offset += $batchSize) {
            $batch = @($VersionSources | Select-Object -Skip $offset -First $batchSize)
            $queryFields = [System.Collections.Generic.List[string]]::new()
            $fieldMappings = [System.Collections.Generic.List[object]]::new()

            for ($batchIndex = 0; $batchIndex -lt $batch.Count; $batchIndex++) {
                $versionSource = $batch[$batchIndex]
                $globalIndex = $offset + $batchIndex
                $installerAlias = "installer$globalIndex"
                $baseAlias = "base$globalIndex"
                $installerPath = "$($versionSource.Path)/$PackageIdentifier.installer.yaml"
                $basePath = "$($versionSource.Path)/$PackageIdentifier.yaml"
                $installerExpression = ConvertTo-Json -InputObject "master:$installerPath" -Compress
                $baseExpression = ConvertTo-Json -InputObject "master:$basePath" -Compress

                $queryFields.Add("      ${installerAlias}: object(expression: $installerExpression) { ... on Blob { text } }")
                $queryFields.Add("      ${baseAlias}: object(expression: $baseExpression) { ... on Blob { text } }")
                $fieldMappings.Add([pscustomobject]@{
                        VersionSource = $versionSource
                        InstallerAlias = $installerAlias
                        InstallerPath = $installerPath
                        BaseAlias = $baseAlias
                        BasePath = $basePath
                    })
            }

            $query = @"
query {
  repository(owner: "microsoft", name: "winget-pkgs") {
$($queryFields -join [Environment]::NewLine)
  }
}
"@
            $data = Invoke-GitHubGraphQl -Query $query
            $repositoryData = $data.repository
            if ($null -eq $repositoryData) {
                throw 'GitHub GraphQL did not return microsoft/winget-pkgs.'
            }

            foreach ($mapping in $fieldMappings) {
                $installerBlob = $repositoryData.PSObject.Properties[$mapping.InstallerAlias].Value
                $baseBlob = $repositoryData.PSObject.Properties[$mapping.BaseAlias].Value
                $content = $null
                $path = $null

                if ($null -ne $installerBlob -and -not [string]::IsNullOrWhiteSpace([string]$installerBlob.text)) {
                    $content = [string]$installerBlob.text
                    $path = $mapping.InstallerPath
                }
                elseif ($null -ne $baseBlob -and -not [string]::IsNullOrWhiteSpace([string]$baseBlob.text)) {
                    $content = [string]$baseBlob.text
                    $path = $mapping.BasePath
                }
                else {
                    continue
                }

                $parseResult = Test-YamlParseable -Content $content -SourceName $path
                if (-not $parseResult.Success) {
                    throw "Failed to parse published manifest '$path': $($parseResult.Error)"
                }

                $documents = @([pscustomobject]@{
                        Name = Split-Path -Leaf $path
                        Path = $path
                        Data = $parseResult.Data
                    })
                $manifestSets.Add((ConvertTo-ManifestSet -Documents $documents -Source $mapping.VersionSource.Name))
            }
        }

        return $manifestSets.ToArray()
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
            $apiUrl = [string]$VersionSource.ApiUrl
            if ([string]::IsNullOrWhiteSpace($apiUrl)) {
                throw "ApiUrl is null or empty for published version source '$($VersionSource.Name)'."
            }
            $packageIdentifier = [string]$VersionSource.PackageIdentifier
            if ([string]::IsNullOrWhiteSpace($packageIdentifier)) {
                throw "PackageIdentifier is null or empty for published version source '$($VersionSource.Name)'."
            }
            $files = Invoke-GitHubApiJson -Uri $apiUrl
            $installerName = "$packageIdentifier.installer.yaml"
            $baseName = "$packageIdentifier.yaml"
            $yamlFiles = @($files | Where-Object { $_.type -eq 'file' -and $_.name -eq $installerName } | Select-Object -First 1)
            if ($yamlFiles.Count -eq 0) {
                $yamlFiles = @($files | Where-Object { $_.type -eq 'file' -and $_.name -eq $baseName } | Select-Object -First 1)
            }
            foreach ($yamlFile in $yamlFiles) {
                $contentUrl = [string]$yamlFile.url
                if ([string]::IsNullOrWhiteSpace($contentUrl)) {
                    throw "API URL is null or empty for file '$($yamlFile.name)' in version '$($VersionSource.Name)'."
                }
                $contentResponse = Invoke-GitHubApiJson -Uri $contentUrl
                $content = ConvertFrom-GitHubContentResponse -Response $contentResponse -SourceName $yamlFile.path
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

        if ($documents.Count -eq 0) {
            return $null
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
                Hash           = $hash.ToLowerInvariant()
                Architecture   = [string](Get-PropertyValue -Object $installer -Name 'Architecture')
                InstallerType  = [string](Get-PropertyValue -Object $installer -Name 'InstallerType')
                InstallerUrl   = [string](Get-PropertyValue -Object $installer -Name 'InstallerUrl')
                PackageVersion = $ManifestSet.PackageVersion
                Source         = $ManifestSet.Source
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
        'MinimumOSVersion', 'Platform', 'InstallerSwitches', 'InstallModes', 'UpgradeBehavior',
        'Commands', 'Protocols', 'FileExtensions', 'Dependencies', 'Capabilities',
        'RestrictedCapabilities', 'AppsAndFeaturesEntries', 'Scope', 'ElevationRequirement',
        'ExpectedReturnCodes', 'UnsupportedOSArchitectures', 'Markets', 'NestedInstallerType',
        'NestedInstallerFiles', 'PackageFamilyName', 'ArchiveBinariesDependOnPath',
        'DisplayInstallWarnings', 'InstallationMetadata'
    )

    $script:InstallerEntryStickyProperties = @(
        'MinimumOSVersion', 'Platform', 'InstallerSwitches', 'InstallModes', 'UpgradeBehavior',
        'Commands', 'Protocols', 'FileExtensions', 'Dependencies', 'Capabilities',
        'RestrictedCapabilities', 'AppsAndFeaturesEntries', 'Scope', 'ElevationRequirement',
        'ExpectedReturnCodes', 'UnsupportedOSArchitectures', 'Markets', 'NestedInstallerType',
        'NestedInstallerFiles', 'PackageFamilyName', 'ArchiveBinariesDependOnPath',
        'DisplayInstallWarnings'
    )

    function Get-EffectiveInstallerProperty {
        param(
            [Parameter(Mandatory = $true)] [object] $Installer,
            [Parameter(Mandatory = $true)] [object] $InstallerDocument,
            [Parameter(Mandatory = $true)] [string] $Name
        )

        $entryValue = Get-PropertyValue -Object $Installer -Name $Name
        if (Test-HasValue $entryValue) {
            return $entryValue
        }

        return Get-PropertyValue -Object $InstallerDocument -Name $Name
    }

    # Nested installer metadata is only meaningful for archive installers. Carrying it over to a
    # non-archive installer produces manifests that winget itself rejects.
    $script:NestedInstallerStickyProperties = @(
        'NestedInstallerType', 'NestedInstallerFiles', 'ArchiveBinariesDependOnPath'
    )

    function Test-SupportsNestedInstallerMetadata {
        param(
            [Parameter(Mandatory = $true)] [AllowNull()] [object] $Installer,
            [Parameter(Mandatory = $true)] [object] $InstallerDocument
        )

        $installerType = if ($null -eq $Installer) {
            [string](Get-PropertyValue -Object $InstallerDocument -Name 'InstallerType')
        }
        else {
            [string](Get-EffectiveInstallerProperty -Installer $Installer -InstallerDocument $InstallerDocument -Name 'InstallerType')
        }

        return $installerType -ieq 'zip'
    }

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

        $currentInstallers = @($CurrentManifestSet.InstallerEntries)
        foreach ($propertyName in $script:InstallerManifestStickyProperties) {
            if ($script:NestedInstallerStickyProperties -contains $propertyName) {
                $supportsNested = $false
                if ($currentInstallers.Count -eq 0) {
                    $supportsNested = Test-SupportsNestedInstallerMetadata -Installer $null -InstallerDocument $currentInstallerDocument
                }
                else {
                    foreach ($currentInstaller in $currentInstallers) {
                        if (Test-SupportsNestedInstallerMetadata -Installer $currentInstaller -InstallerDocument $currentInstallerDocument) {
                            $supportsNested = $true
                            break
                        }
                    }
                }

                if (-not $supportsNested) {
                    continue
                }
            }

            $previousValue = Get-PropertyValue -Object $previousInstallerDocument -Name $propertyName
            $currentValue = Get-PropertyValue -Object $currentInstallerDocument -Name $propertyName

            $allCurrentEntriesHaveValue = $currentInstallers.Count -gt 0
            foreach ($currentInstaller in $currentInstallers) {
                $effectiveValue = Get-EffectiveInstallerProperty -Installer $currentInstaller -InstallerDocument $currentInstallerDocument -Name $propertyName
                if (-not (Test-HasValue $effectiveValue)) {
                    $allCurrentEntriesHaveValue = $false
                    break
                }
            }

            if ((Test-HasValue $previousValue) -and -not (Test-HasValue $currentValue) -and -not $allCurrentEntriesHaveValue) {
                $consistencyErrors.Add("Missing property $propertyName compared to published version $($PreviousManifestSet.PackageVersion)")
            }
        }

        foreach ($previousInstaller in @($PreviousManifestSet.InstallerEntries)) {
            $matchingInstaller = Get-MatchingInstallerEntry -CurrentEntries $currentInstallers -ReferenceEntry $previousInstaller
            if ($null -eq $matchingInstaller) {
                continue
            }

            $architecture = [string](Get-PropertyValue -Object $previousInstaller -Name 'Architecture')
            $architectureSuffix = if (Test-HasValue $architecture) { " for architecture '$architecture'" } else { '' }

            foreach ($propertyName in $script:InstallerEntryStickyProperties) {
                if (($script:NestedInstallerStickyProperties -contains $propertyName) -and
                    -not (Test-SupportsNestedInstallerMetadata -Installer $matchingInstaller -InstallerDocument $currentInstallerDocument)) {
                    continue
                }

                $previousValue = Get-EffectiveInstallerProperty -Installer $previousInstaller -InstallerDocument $previousInstallerDocument -Name $propertyName
                $currentValue = Get-EffectiveInstallerProperty -Installer $matchingInstaller -InstallerDocument $currentInstallerDocument -Name $propertyName

                if ((Test-HasValue $previousValue) -and -not (Test-HasValue $currentValue)) {
                    $consistencyErrors.Add("Missing installer property $propertyName$architectureSuffix compared to published version $($PreviousManifestSet.PackageVersion)")
                }
            }
        }

        return $consistencyErrors.ToArray()
    }

    Write-Host "=== Winget Manifest Content Validation ===" -ForegroundColor Cyan
    Write-Host "Manifest Path: $ManifestPath" -ForegroundColor Gray
    Write-Host ""

    $errors = @()
    $warnings = @()

    Add-ArtifactValidationErrors -Path $ManifestPath -Errors ([ref]$errors)

    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        Write-Host "Installing powershell-yaml module..." -ForegroundColor Yellow
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module -Name powershell-yaml -ErrorAction Stop

    Write-Host "--> Locating manifest files..." -ForegroundColor White
    $manifestFiles = Get-LocalManifestFiles -Path $ManifestPath

    if ($null -eq $manifestFiles) {
        $errors += "No YAML files found in manifest folder: $ManifestPath"
        Write-Host "ERROR: No YAML files found" -ForegroundColor Red
        return Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    }

    Write-Host "  Found $($manifestFiles.Count) manifest file(s):" -ForegroundColor Gray
    foreach ($file in $manifestFiles) {
        Write-Host "    - $($file.Name)" -ForegroundColor Gray
    }

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

        $fileSetValidation = Test-ManifestFileSet -ManifestSet $localManifestSet -Documents $parsedDocuments
        $errors += @($fileSetValidation.Errors)
        $warnings += @($fileSetValidation.Warnings)

        $errors += @(Test-ManifestCollisions -ManifestSet $localManifestSet)
        $errors += @(Test-ManifestTypeAndLocalePolicy -ManifestSet $localManifestSet)
        $errors += @(Test-InstallerTypeMatchesUrl -ManifestSet $localManifestSet)

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

        if (-not $SkipPublishedComparison -and $errors.Count -eq 0 -and (Test-HasValue $localManifestSet.PackageIdentifier) -and (Test-HasValue $localManifestSet.PackageVersion)) {
            try {
                Write-Host "  Checking published manifest history for $($localManifestSet.PackageIdentifier)..." -ForegroundColor Gray
                $publishedVersionSources = @(Get-PublishedVersionSources -PackageIdentifier $localManifestSet.PackageIdentifier -PublishedPackageRootPath $PublishedPackageRoot)

                if ($publishedVersionSources.Count -eq 0) {
                    $warnings += "Published package path for $($localManifestSet.PackageIdentifier) was not found. Skipping published manifest comparison."
                }
                else {
                    Write-Host "  Found $($publishedVersionSources.Count) published version folder(s) to compare against." -ForegroundColor Gray

                    $publishedManifestSets = @()
                    $githubHeaders = Get-GitHubHeaders
                    if ($publishedVersionSources[0].Kind -eq 'GitHub' -and $githubHeaders.ContainsKey('Authorization')) {
                        $publishedManifestSets = @(Read-GitHubPublishedManifestSets `
                                -VersionSources $publishedVersionSources `
                                -PackageIdentifier $localManifestSet.PackageIdentifier)
                    }
                    else {
                        foreach ($publishedVersionSource in $publishedVersionSources) {
                            $publishedManifestSet = Read-PublishedManifestSet -VersionSource $publishedVersionSource
                            if ($null -ne $publishedManifestSet) {
                                $publishedManifestSets += $publishedManifestSet
                            }
                        }
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
                        if ($AllowStructuralRewrite) {
                            $warnings += "Skipping installer metadata consistency comparison against published version $($baselinePublishedManifest.PackageVersion) because structural rewrite approval was explicitly provided."
                        }
                        else {
                            $consistencyErrors = @(Test-InstallerMetadataConsistency -CurrentManifestSet $localManifestSet -PreviousManifestSet $baselinePublishedManifest)
                            foreach ($consistencyError in $consistencyErrors) {
                                $errors += $consistencyError
                            }
                        }

                        Test-UpstreamDomainChange -CurrentManifestSet $localManifestSet -PreviousManifestSet $baselinePublishedManifest -Warnings ([ref]$warnings)
                    }
                }
            }
            catch {
                $errors += "Failed to compare against published winget manifests: $($_.Exception.Message)"
            }
        }
    }

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
        return Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    }

    Write-Host ""
    Write-Host "RESULT: PASSED" -ForegroundColor Green
    return Write-ValidationResult -Valid $true -Errors $errors -Warnings $warnings
}
