$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'ConvertTo-WingetVersionStyle' {
    It 'preserves upstream leading zeros when the published style has none (qaac 3.05 regression)' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '3.05' -PublishedVersions @('2.84', '2.89') | Should -Be '3.05'
        }
    }

    It 'pads a segment to match a zero-padded published style' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '1.3' -PublishedVersions @('1.01', '1.02') | Should -Be '1.03'
        }
    }

    It 'keeps an already padded version when the published style is zero-padded' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '3.05' -PublishedVersions @('3.03', '3.04') | Should -Be '3.05'
        }
    }

    It 'returns the version unchanged when no published versions exist' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '3.05' -PublishedVersions @() | Should -Be '3.05'
        }
    }

    It 'returns the version unchanged when published segment counts differ' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '3.05' -PublishedVersions @('1.2.3') | Should -Be '3.05'
        }
    }

    It 'returns non-numeric versions unchanged' {
        InModuleScope WingetMaintainerModule {
            ConvertTo-WingetVersionStyle -Version '1.2-beta' -PublishedVersions @('1.1') | Should -Be '1.2-beta'
        }
    }
}

Describe 'Find-WingetPublishedVersionMatch' {
    It 'still matches an already published numeric alias so no duplicate PR is opened' {
        InModuleScope WingetMaintainerModule {
            $match = Find-WingetPublishedVersionMatch -Version '3.05' -PublishedVersions @('2.89', '3.5')
            $match | Should -Not -BeNullOrEmpty
            $match.Version | Should -Be '3.5'
            $match.MatchType | Should -Be 'NumericAlias'
        }
    }

    It 'prefers an exact match over an alias' {
        InModuleScope WingetMaintainerModule {
            $match = Find-WingetPublishedVersionMatch -Version '3.05' -PublishedVersions @('3.05', '3.5')
            $match.MatchType | Should -Be 'Exact'
        }
    }
}
