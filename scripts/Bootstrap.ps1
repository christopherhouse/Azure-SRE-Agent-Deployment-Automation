#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{3,24}$')]
    [string] $StateStorageAccountId,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'christopherhouse/Azure-SRE-Agent-Deployment-Automation',

    [switch] $Apply,
    [switch] $ConfigureGitHub
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

if ($ConfigureGitHub -and -not $Apply) {
    throw '-ConfigureGitHub requires -Apply; variables must come from an applied bootstrap.'
}
Assert-KeylessEnvironment
$account = Invoke-NativeJson az @('account', 'show', '-o', 'json')
if ($account.user.type -ne 'user' -or $account.environmentName -ne 'AzureCloud') {
    throw 'Bootstrap requires an interactive Azure CLI user in AzureCloud.'
}
$stateSubscription = $StateStorageAccountId.Split('/')[2]
$stateAccount = Invoke-NativeJson az @('account', 'show', '--subscription', $stateSubscription, '-o', 'json')
if ($account.tenantId -ne $stateAccount.tenantId) {
    throw 'Cross-tenant state is not supported. Target and state subscriptions must share a tenant.'
}
$storage = Invoke-NativeJson az @('storage', 'account', 'show', '--ids', $StateStorageAccountId, '-o', 'json')
if ($storage.publicNetworkAccess -ne 'Enabled' -or $storage.networkRuleSet.defaultAction -ne 'Allow') {
    throw 'State account network policy does not allow ordinary hosted runners. No settings were changed.'
}
if ($storage.primaryEndpoints.blob -ne "https://$($storage.name).blob.core.windows.net/") {
    throw 'Only the standard AzureCloud Blob endpoint is supported.'
}
foreach ($namespace in @('Microsoft.App', 'Microsoft.ManagedIdentity', 'Microsoft.Authorization')) {
    $provider = Invoke-NativeJson az @('provider', 'show', '--namespace', $namespace, '--subscription', $account.id, '-o', 'json')
    if ($provider.registrationState -ne 'Registered') {
        throw "Register $namespace in the selected target subscription before bootstrap."
    }
    if ($namespace -eq 'Microsoft.App') {
        $agentType = @($provider.resourceTypes | Where-Object { $_.resourceType -eq 'agents' })
        if ($agentType.Count -ne 1 -or $agentType[0].locations -notcontains 'West US 3') {
            throw 'Microsoft.App/agents is not advertised in West US 3 for this subscription.'
        }
    }
}
$operatorId = Invoke-NativeJson az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'json')
$subject = Invoke-NativeJson gh @('api', "repos/$Repository/actions/oidc/customization/sub")
if (-not $subject.use_default -or -not $subject.sub_claim_prefix) {
    throw 'A default GitHub OIDC subject with a reported sub_claim_prefix is required. Custom subjects need explicit review.'
}
$variables = @{
    target_subscription_id   = $account.id
    tenant_id                = $account.tenantId
    operator_object_id       = $operatorId
    state_storage_account_id = $StateStorageAccountId
    github_subject_prefix    = $subject.sub_claim_prefix
}
$directory = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra') 'bootstrap'
$settings = Join-Path $directory 'bootstrap.auto.tfvars.json'
$variables | ConvertTo-Json | Set-Content -LiteralPath $settings -Encoding ASCII
Write-Information "Target: $($account.id); tenant: $($account.tenantId); region: westus3" -InformationAction Continue
Write-Information "External state account subscription: $stateSubscription" -InformationAction Continue
Invoke-Native terraform @("-chdir=$directory", 'init', '-input=false', '-lockfile=readonly')
Invoke-Native terraform @("-chdir=$directory", 'validate')
$plan = Join-Path $directory 'bootstrap.tfplan'
Invoke-Native terraform @("-chdir=$directory", 'plan', '-input=false', '-lock-timeout=60s', "-out=$plan")
if ($Apply) {
    try {
        Invoke-Native terraform @("-chdir=$directory", 'apply', '-input=false', '-lock-timeout=60s', $plan)
    }
    finally {
        if (Test-Path -LiteralPath $plan) {
            Remove-Item -LiteralPath $plan -Force
        }
    }
    if ($ConfigureGitHub) {
        $outputs = Invoke-NativeJson terraform @("-chdir=$directory", 'output', '-json', 'github_variables')
        foreach ($property in $outputs.PSObject.Properties) {
            Invoke-Native gh @('variable', 'set', $property.Name, '--repo', $Repository, '--body', [string] $property.Value)
        }
    }
}
else {
    Remove-Item -LiteralPath $plan -Force
    Write-Information 'Plan only. Repeat with -Apply to provision; add -ConfigureGitHub to publish non-secret variables.' -InformationAction Continue
}
