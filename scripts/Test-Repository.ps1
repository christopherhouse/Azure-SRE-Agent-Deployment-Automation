#Requires -Version 5.1
[CmdletBinding()]
param([switch] $InstallDependencies)

$ErrorActionPreference = 'Stop'
if ($InstallDependencies) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser -Force
    Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -ErrorAction Stop
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$findings = @(
    Invoke-ScriptAnalyzer -Path (Join-Path $root 'scripts') -Recurse -Severity Warning, Error
    Invoke-ScriptAnalyzer -Path (Join-Path $root 'tests') -Recurse -Severity Warning, Error
)
if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize | Out-Host
    throw 'PowerShell analysis failed.'
}
$result = Invoke-Pester -Path (Join-Path $root 'tests') -Output Detailed -PassThru
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) {
    throw 'PowerShell tests failed or no tests were discovered.'
}
