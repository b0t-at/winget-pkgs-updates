$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Install-WinMatsch' {
    BeforeEach {
        InModuleScope WingetMaintainerModule {
            $script:DownloadedUri = $null
            $script:DownloadedPath = $null
            $script:AliasValue = $null
            $script:ChmodPath = $null

            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winmatsch' }
            Mock Invoke-WebRequest {
                $script:DownloadedUri = $Uri
                $script:DownloadedPath = $OutFile
                Set-Content -LiteralPath $OutFile -Value '' -NoNewline
            }
            Mock New-Alias {
                $script:AliasValue = $Value
            } -ParameterFilter { $Name -eq 'winmatsch' -and $Scope -eq 'Global' }
            Mock Set-WinMatschExecutablePermission {
                $script:ChmodPath = $Path
            }
        }
    }

    It 'keeps the existing Windows x64 download behavior' {
        InModuleScope WingetMaintainerModule {
            Mock Get-WinMatschPlatform { 'Windows' }
            Mock Get-WinMatschArchitecture { throw 'Windows must not need architecture detection.' }

            Push-Location TestDrive:\
            try {
                Install-WinMatsch
            }
            finally {
                Pop-Location
            }

            $script:DownloadedUri | Should -Be 'https://winmatsch.oneinfra.de/latest/winmatsch-win-x64.exe'
            Split-Path -Leaf $script:DownloadedPath | Should -Be 'winmatsch.exe'
            Split-Path -Leaf $script:AliasValue | Should -Be 'winmatsch.exe'
            $script:ChmodPath | Should -BeNullOrEmpty
            Assert-MockCalled Get-WinMatschArchitecture -Times 0 -Exactly -Scope It
        }
    }

    It 'downloads and chmods the Linux arm64 binary' {
        InModuleScope WingetMaintainerModule {
            Mock Get-WinMatschPlatform { 'Linux' }
            Mock Get-WinMatschArchitecture { 'arm64' }

            Push-Location TestDrive:\
            try {
                Install-WinMatsch
            }
            finally {
                Pop-Location
            }

            $script:DownloadedUri | Should -Be 'https://winmatsch.oneinfra.de/latest/winmatsch-linux-arm64'
            Split-Path -Leaf $script:DownloadedPath | Should -Be 'winmatsch'
            Split-Path -Leaf $script:AliasValue | Should -Be 'winmatsch'
            Split-Path -Leaf $script:ChmodPath | Should -Be 'winmatsch'
            Assert-MockCalled Set-WinMatschExecutablePermission -Times 1 -Exactly -Scope It
        }
    }

    It 'selects the macOS x64 binary' {
        InModuleScope WingetMaintainerModule {
            $download = Get-WinMatschDownload -Platform MacOS -Architecture x64

            $download.Url | Should -Be 'https://winmatsch.oneinfra.de/latest/winmatsch-osx-x64'
            $download.FileName | Should -Be 'winmatsch'
        }
    }
}
