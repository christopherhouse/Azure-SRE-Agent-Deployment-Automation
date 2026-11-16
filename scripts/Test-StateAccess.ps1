#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string] $StorageAccountName,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')]
    [string] $ContainerName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-KeylessEnvironment
$file = [IO.Path]::GetTempFileName()
$blob = "bootstrap-probes/$([Guid]::NewGuid().ToString('N')).txt"
$lease = $null
$uploaded = $false
$arguments = @('--account-name', $StorageAccountName, '--container-name', $ContainerName,
    '--auth-mode', 'login', '--only-show-errors')
$blobArguments = $arguments + @('--name', $blob)
$leaseArguments = $arguments + @('--blob-name', $blob)
try {
    Set-Content -LiteralPath $file -Value 'Keyless state reachability probe.' -Encoding ASCII
    Invoke-Native az (@('storage', 'blob', 'upload', '--file', $file, '--overwrite', 'false', '--no-progress', '-o', 'none') + $blobArguments)
    $uploaded = $true
    $lease = Invoke-NativeJson az (@('storage', 'blob', 'lease', 'acquire', '--lease-duration', '60', '-o', 'json') + $leaseArguments)
    if (-not $lease) {
        throw 'Blob lease acquisition returned no lease ID.'
    }
    Invoke-Native az (@('storage', 'blob', 'show', '--lease-id', [string] $lease, '-o', 'none') + $blobArguments)
}
finally {
    try {
        if ($lease) {
            Invoke-Native az (@('storage', 'blob', 'lease', 'release', '--lease-id', [string] $lease, '-o', 'none') + $leaseArguments)
        }
        if ($uploaded) {
            Invoke-Native az (@('storage', 'blob', 'delete', '-o', 'none') + $blobArguments)
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force
    }
}
Write-Information 'Entra Blob write, lease, read, release, and delete succeeded; no Terraform state was touched.' -InformationAction Continue
