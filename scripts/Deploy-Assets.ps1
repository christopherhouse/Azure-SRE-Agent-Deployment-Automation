#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string] $AgentName,
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string] $ResourceGroup = 'rg-sre-checkout-westus3',
    [string] $PackagePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DataPlane.ps1')
Assert-KeylessEnvironment
if ($env:GITHUB_ACTIONS -eq 'true' -and
    ($env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_EVENT_NAME -notin @('push', 'workflow_dispatch'))) {
    throw 'Data-plane deployment is restricted to trusted main execution.'
}
$account = Invoke-NativeJson az @('account', 'show', '-o', 'json', '--only-show-errors')
if ($account.environmentName -ne 'AzureCloud') { throw 'Select an AzureCloud account.' }
$base = "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers"
$agent = Invoke-NativeJson az @('rest', '-m', 'GET', '--url',
    "$base/Microsoft.App/agents/${AgentName}?api-version=2026-01-01", '-o', 'json', '--only-show-errors')
if ($agent.location -ne 'westus3' -or $agent.properties.provisioningState -ne 'Succeeded') {
    throw 'The target agent must be successfully provisioned in West US 3.'
}
$endpoint = $null
if (-not [Uri]::TryCreate($agent.properties.agentEndpoint, [UriKind]::Absolute, [ref] $endpoint) -or
    $endpoint.Scheme -ne 'https' -or $endpoint.DnsSafeHost -notmatch '^[a-z0-9.-]+[.]azuresre[.]ai$' -or
    $endpoint.Port -ne 443 -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or
    $endpoint.AbsolutePath -ne '/') {
    throw 'ARM returned an unsupported agent endpoint; no bearer token was sent.'
}
$workspace = Invoke-NativeJson az @('rest', '-m', 'GET', '--url',
    "$base/Microsoft.OperationalInsights/workspaces/law-sre-checkout?api-version=2025-07-01", '-o', 'json', '--only-show-errors')
$workspaceId = [Guid]::Empty
if (-not [Guid]::TryParse($workspace.properties.customerId, [ref] $workspaceId)) {
    throw 'Workspace customer ID is invalid.'
}
$assetRoot = Split-Path $PSScriptRoot -Parent
if ($PackagePath) {
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Container)) {
        throw 'Supplied asset package directory does not exist.'
    }
    $assetRoot = $PackagePath
}
$assets = @(Get-SreAgentAsset -RepositoryRoot $assetRoot `
    -SubscriptionId $account.id -ResourceGroup $ResourceGroup -WorkspaceId $workspaceId.ToString())
$token = $null
$headers = @{}
try {
    # Capture stdout in memory; never pass a bearer token in native command arguments.
    $token = ((Invoke-Native az @('account', 'get-access-token', '--resource', 'https://azuresre.dev',
        '--query', 'accessToken', '-o', 'tsv', '--only-show-errors')) -join '').Trim()
    if (-not $token) { throw 'Azure CLI returned an empty data-plane token.' }
    $headers.Authorization = "Bearer $token"
    Sync-SreAgentAsset -Endpoint $endpoint.AbsoluteUri.TrimEnd('/') -Headers $headers -Assets $assets
}
finally {
    $headers.Clear()
    $token = $null
}
