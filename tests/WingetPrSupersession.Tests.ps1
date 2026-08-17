$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

Write-Host 'TEST: standard update title parses'
$parsed = & $module { Get-WingetPrTitlePackageVersion -Title 'Update version: KeeperSecurity.Commander version 18.1.0' }
if ($null -eq $parsed -or $parsed.PackageIdentifier -cne 'KeeperSecurity.Commander' -or $parsed.Version -cne '18.1.0') {
    throw "Standard title parsing failed: $($parsed | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: legacy combined title parses'
$parsed = & $module { Get-WingetPrTitlePackageVersion -Title 'Add version: Foo.Bar version 2.0.0 - Update version: Foo.Bar version 2.0.0' }
if ($null -eq $parsed -or $parsed.PackageIdentifier -cne 'Foo.Bar' -or $parsed.Version -cne '2.0.0') {
    throw "Legacy combined title parsing failed: $($parsed | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: foreign title shapes return null'
foreach ($title in @('New package: Foo.Bar 1.0', 'Update Foo.Bar to 1.0', '', 'Update version: Foo.Bar version 1.0 extra words')) {
    $parsed = & $module { param($Title) Get-WingetPrTitlePackageVersion -Title $Title } $title
    if ($null -ne $parsed) {
        throw "Expected null for title '$title', got: $($parsed | ConvertTo-Json -Compress)"
    }
}

Write-Host 'TEST: superseded selection closes only strictly older versions of the same package'
$openPrs = @(
    [PSCustomObject]@{ number = 100; title = 'Update version: Foo.Bar version 1.0.0' },
    [PSCustomObject]@{ number = 101; title = 'Update version: Foo.Bar version 1.2.0' },
    [PSCustomObject]@{ number = 102; title = 'Update version: Foo.Bar version 2.0.0' },
    [PSCustomObject]@{ number = 103; title = 'Update version: Foo.Baz version 0.5.0' },
    [PSCustomObject]@{ number = 104; title = 'Something unrelated mentioning Foo.Bar 0.1' },
    [PSCustomObject]@{ number = 105; title = 'Update version: Foo.Bar version 1.2.0' }
)
$selected = @(& $module {
        param($OpenPrs)
        Select-WingetSupersededOpenPrs -OpenPrs $OpenPrs -PackageIdentifier 'Foo.Bar' -NewVersion '1.2.0' -NewPrNumber 105
    } $openPrs)
if ((@($selected | ForEach-Object { $_.Number }) -join ',') -ne '100') {
    throw "Expected only PR 100 selected, got: $($selected | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: version comparison is numeric, not lexicographic'
$openPrs = @([PSCustomObject]@{ number = 200; title = 'Update version: Foo.Bar version 9.0.0' })
$selected = @(& $module {
        param($OpenPrs)
        Select-WingetSupersededOpenPrs -OpenPrs $OpenPrs -PackageIdentifier 'Foo.Bar' -NewVersion '10.0.0'
    } $openPrs)
if (@($selected).Count -ne 1) {
    throw "Expected 9.0.0 to be older than 10.0.0, got: $($selected | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: hygiene actions plan supersession, published closes, and keeps'
$openPrs = @(
    [PSCustomObject]@{ number = 300; title = 'Update version: Keeper.Commander version 18.1.0'; labels = @() },
    [PSCustomObject]@{ number = 301; title = 'Update version: Keeper.Commander version 18.1.1'; labels = @([PSCustomObject]@{ name = 'Azure-Pipeline-Passed' }) },
    [PSCustomObject]@{ number = 302; title = 'Update version: Shipped.App version 3.0.0'; labels = @([PSCustomObject]@{ name = 'Validation-Executable-Error' }) },
    [PSCustomObject]@{ number = 303; title = 'Update version: Stuck.App version 1.0.0'; labels = @('Validation-Defender-Error') },
    [PSCustomObject]@{ number = 304; title = 'Totally different title'; labels = @() }
)
$actions = @(& $module {
        param($OpenPrs)
        Select-WingetHygienePrActions -OpenPrs $OpenPrs -PublishedVersionsResolver {
            param($PackageIdentifier)
            if ($PackageIdentifier -eq 'Shipped.App') { @('2.9.0', '3.0.0') } else { @() }
        }
    } $openPrs)

$byNumber = @{}
foreach ($action in $actions) { $byNumber[$action.Number] = $action }
if ($byNumber[300].Action -ne 'close-superseded' -or $byNumber[300].Reason -notmatch '#301') {
    throw "Expected PR 300 superseded by #301, got: $($byNumber[300] | ConvertTo-Json -Compress)"
}
if ($byNumber[301].Action -ne 'keep') {
    throw "Expected PR 301 kept, got: $($byNumber[301] | ConvertTo-Json -Compress)"
}
if ($byNumber[302].Action -ne 'close-published') {
    throw "Expected PR 302 closed as published, got: $($byNumber[302] | ConvertTo-Json -Compress)"
}
if ($byNumber[303].Action -ne 'keep' -or @($byNumber[303].Labels) -notcontains 'Validation-Defender-Error') {
    throw "Expected PR 303 kept with its label, got: $($byNumber[303] | ConvertTo-Json -Compress)"
}
if ($byNumber[304].Action -ne 'keep' -or $byNumber[304].Reason -notmatch 'not parsable') {
    throw "Expected PR 304 kept as unparsable, got: $($byNumber[304] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: hygiene sweep works without a published-version resolver'
$actions = @(& $module {
        param($OpenPrs)
        Select-WingetHygienePrActions -OpenPrs $OpenPrs
    } @([PSCustomObject]@{ number = 400; title = 'Update version: Foo.Bar version 1.0.0'; labels = @() }))
if (@($actions).Count -ne 1 -or $actions[0].Action -ne 'keep') {
    throw "Expected a single keep action, got: $($actions | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: Close-SupersededWingetPrs closes selected PRs via the injected invokers'
$closeResult = & $module {
    $script:closedCalls = @()
    Close-SupersededWingetPrs `
        -PackageId 'Foo.Bar' `
        -Version '2.0.0' `
        -BotLogin 'test-bot' `
        -NewPrNumber 999 `
        -NewPrUrl 'https://github.com/microsoft/winget-pkgs/pull/999' `
        -SearchInvoker {
            @(
                [PSCustomObject]@{ number = 500; title = 'Update version: Foo.Bar version 1.0.0' },
                [PSCustomObject]@{ number = 501; title = 'Update version: Foo.Bar version 2.0.0' },
                [PSCustomObject]@{ number = 999; title = 'Update version: Foo.Bar version 2.0.0' }
            )
        } `
        -CloseInvoker {
            param($Number, $Comment)
            $script:closedCalls += [PSCustomObject]@{ Number = $Number; Comment = $Comment }
        }
}
if ((@($closeResult.ClosedPrNumbers) -join ',') -ne '500') {
    throw "Expected only PR 500 closed, got: $($closeResult | ConvertTo-Json -Compress)"
}
$closedCalls = & $module { $script:closedCalls }
if (@($closedCalls).Count -ne 1 -or $closedCalls[0].Comment -notmatch 'pull/999') {
    throw "Expected the close comment to reference the successor PR, got: $($closedCalls | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: Close-SupersededWingetPrs fails open when the search fails'
$closeResult = & $module {
    Close-SupersededWingetPrs `
        -PackageId 'Foo.Bar' `
        -Version '2.0.0' `
        -BotLogin 'test-bot' `
        -SearchInvoker { throw 'search exploded' } `
        -CloseInvoker { throw 'must not be called' }
}
if (@($closeResult.ClosedPrNumbers).Count -ne 0 -or @($closeResult.Warnings).Count -ne 1) {
    throw "Expected a warning and no closes on search failure, got: $($closeResult | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: Close-SupersededWingetPrs honors the MaxCloses cap'
$closeResult = & $module {
    Close-SupersededWingetPrs `
        -PackageId 'Foo.Bar' `
        -Version '9.0.0' `
        -BotLogin 'test-bot' `
        -MaxCloses 1 `
        -SearchInvoker {
            @(
                [PSCustomObject]@{ number = 600; title = 'Update version: Foo.Bar version 1.0.0' },
                [PSCustomObject]@{ number = 601; title = 'Update version: Foo.Bar version 2.0.0' }
            )
        } `
        -CloseInvoker { param($Number, $Comment) }
}
if (@($closeResult.ClosedPrNumbers).Count -ne 1 -or $closeResult.SkippedCount -ne 1 -or @($closeResult.Warnings).Count -ne 1) {
    throw "Expected the cap to close one and skip one, got: $($closeResult | ConvertTo-Json -Compress)"
}

Write-Host 'All WingetPrSupersession tests passed.'
