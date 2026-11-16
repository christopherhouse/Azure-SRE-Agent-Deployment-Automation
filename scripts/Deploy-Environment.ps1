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
    [string] $Authentication,
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $OperatorObjectId,
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string] $ResourceGroup = 'rg-sre-checkout-westus3',
    [switch] $FaultEnabled,
    [string] $SummaryPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'DataPlane.ps1')
Assert-KeylessEnvironment

if ($Authentication -eq 'GitHubOidc') {
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REF -ne 'refs/heads/main' -or
        $env:GITHUB_EVENT_NAME -notin @('push', 'workflow_dispatch')) {
        throw 'OIDC environment deployment is restricted to trusted main push/dispatch jobs.'
    }
    foreach ($name in @(
        'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
        'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
    )) {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            throw "Required OIDC environment variable $name is missing."
        }
    }
    if (-not $OperatorObjectId) {
        $OperatorObjectId = $env:AZURE_OPERATOR_OBJECT_ID
    }
    $account = Invoke-NativeJson az @('account', 'show', '-o', 'json', '--only-show-errors')
    if ($account.environmentName -ne 'AzureCloud' -or
        $account.id -ne $env:ARM_SUBSCRIPTION_ID -or
        $account.tenantId -ne $env:ARM_TENANT_ID) {
        throw 'Azure CLI context does not match the OIDC target subscription and tenant in AzureCloud.'
    }
}
else {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        throw 'AzureCli environment deployment is for local interactive execution only.'
    }
    $account = Invoke-NativeJson az @('account', 'show', '-o', 'json', '--only-show-errors')
    if ($account.user.type -ne 'user' -or $account.environmentName -ne 'AzureCloud') {
        throw 'Local environment deployment requires an interactive Azure CLI user in AzureCloud.'
    }
    if (-not $OperatorObjectId) {
        $OperatorObjectId = ((Invoke-Native az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv', '--only-show-errors')) -join '').Trim()
    }
}

$parsedOperatorId = [Guid]::Empty
if (-not [Guid]::TryParse($OperatorObjectId, [ref] $parsedOperatorId)) {
    throw 'Operator object ID is missing or invalid.'
}

$root = Split-Path $PSScriptRoot -Parent
$environmentDirectory = Join-Path (Join-Path $root 'infra') 'environment'
& (Join-Path $PSScriptRoot 'Initialize-Backend.ps1') `
    -StorageAccountName $StorageAccountName `
    -ContainerName $ContainerName `
    -StateKey $StateKey `
    -Authentication $Authentication

Invoke-Native terraform @("-chdir=$environmentDirectory", 'validate')
$oidc = ($Authentication -eq 'GitHubOidc').ToString().ToLowerInvariant()
$fault = $FaultEnabled.IsPresent.ToString().ToLowerInvariant()
$plan = Join-Path $environmentDirectory 'environment.tfplan'
try {
    Invoke-Native terraform @(
        "-chdir=$environmentDirectory", 'plan', '-input=false', '-lock-timeout=60s',
        "-var=target_subscription_id=$($account.id)",
        "-var=tenant_id=$($account.tenantId)",
        "-var=operator_object_id=$($parsedOperatorId.ToString())",
        "-var=use_oidc=$oidc",
        "-var=fault_enabled=$fault",
        "-out=$plan"
    )
    Invoke-Native terraform @(
        "-chdir=$environmentDirectory", 'apply', '-input=false', '-lock-timeout=60s', $plan
    )
}
finally {
    if (Test-Path -LiteralPath $plan) {
        Remove-Item -LiteralPath $plan -Force
    }
}

$outputs = Invoke-NativeJson terraform @("-chdir=$environmentDirectory", 'output', '-json')
$agentId = [string] $outputs.agent_id.value
if ($agentId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/([^/]+)/providers/Microsoft\.App/agents/([a-zA-Z0-9-]+)$') {
    throw 'Environment Terraform output agent_id is missing or invalid.'
}
$agentResourceGroup = $Matches[1]
$agentName = $Matches[2]
if ($agentResourceGroup -cne $ResourceGroup) {
    throw "Environment Terraform output resource group '$agentResourceGroup' does not match '$ResourceGroup'."
}
$workspaceCustomerId = [Guid]::Empty
if (-not [Guid]::TryParse([string] $outputs.workspace_customer_id.value, [ref] $workspaceCustomerId)) {
    throw 'Environment Terraform output workspace_customer_id is missing or invalid.'
}

$packagePath = Join-Path ([IO.Path]::GetTempPath()) ("sre-checkout-package-" + [Guid]::NewGuid().ToString('N'))
$package = $null
$assetResults = @()
try {
    $package = New-CheckoutAssetPackage -RepositoryRoot $root -DestinationPath $packagePath
    $assetResults = @(& (Join-Path $PSScriptRoot 'Deploy-Assets.ps1') `
        -AgentName $agentName `
        -ResourceGroup $ResourceGroup `
        -PackagePath $package.PackagePath)
    if ($assetResults.Count -ne 3) {
        throw 'Data-plane deployment did not return the expected three asset outcomes.'
    }
}
finally {
    if (Test-Path -LiteralPath $packagePath) {
        Remove-Item -LiteralPath $packagePath -Recurse -Force
    }
}

foreach ($line in $assetResults) {
    Write-Output $line
}
$targetSummaryPath = $SummaryPath
if (-not $targetSummaryPath) {
    $targetSummaryPath = $env:GITHUB_STEP_SUMMARY
}
if ($targetSummaryPath) {
    $summaryLines = @(
        '### Checkout reliability environment deployment',
        '',
        "- **Authentication**: ``$Authentication``",
        "- **Resource group**: ``$ResourceGroup`` (``westus3``)",
        "- **SRE Agent**: ``$agentName``",
        "- **Log Analytics workspace**: ``law-sre-checkout`` (customer ID ``$($workspaceCustomerId.ToString())``)",
        "- **Container App workload**: ``ca-sre-checkout`` (``fault_enabled=$fault``)",
        "- **Packaged sample SHA-256**: ``$($package.SourceSha256)``",
        '- **Data-plane asset reconciliation**:'
    )
    foreach ($line in $assetResults) {
        $summaryLines += "  - ``$line``"
    }
    Add-Content -LiteralPath $targetSummaryPath -Value ($summaryLines -join [Environment]::NewLine) -Encoding UTF8
}
