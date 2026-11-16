#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string] $StorageAccountName,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')]
    [string] $ContainerName,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+[.]tfstate$')]
    [string] $StateKey,
    [Parameter(Mandatory = $true)]
    [ValidateSet('AzureCli', 'GitHubOidc')]
    [string] $Authentication
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-KeylessEnvironment
if ($Authentication -eq 'GitHubOidc') {
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REF -ne 'refs/heads/main' -or
        $env:GITHUB_EVENT_NAME -notin @('push', 'workflow_dispatch')) {
        throw 'OIDC backend initialization is restricted to trusted main push/dispatch jobs.'
    }
    foreach ($name in @('ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            throw "Required OIDC environment variable $name is missing."
        }
    }
}
else {
    $account = Invoke-NativeJson az @('account', 'show', '-o', 'json')
    if ($account.user.type -ne 'user' -or $account.environmentName -ne 'AzureCloud') {
        throw 'Local backend access requires an interactive Azure CLI user in AzureCloud.'
    }
}
$oidc = ($Authentication -eq 'GitHubOidc').ToString().ToLowerInvariant()
$cli = ($Authentication -eq 'AzureCli').ToString().ToLowerInvariant()
$directory = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra') 'environment'
Invoke-Native terraform @(
    "-chdir=$directory", 'init', '-input=false', '-reconfigure',
    "-backend-config=storage_account_name=$StorageAccountName",
    "-backend-config=container_name=$ContainerName",
    "-backend-config=key=$StateKey",
    '-backend-config=use_azuread_auth=true', "-backend-config=use_oidc=$oidc",
    "-backend-config=use_cli=$cli", '-backend-config=use_msi=false'
)
