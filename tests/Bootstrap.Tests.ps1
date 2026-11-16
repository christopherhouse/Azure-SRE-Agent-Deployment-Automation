BeforeAll {
    $script:source = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
    $script:scripts = Join-Path $TestDrive 'scripts'
    Copy-Item -LiteralPath $script:source -Destination $script:scripts -Recurse
    $script:bootstrapDirectory = Join-Path (Join-Path $TestDrive 'infra') 'bootstrap'
    New-Item -ItemType Directory -Path $script:bootstrapDirectory -Force | Out-Null
    $script:bootstrap = Join-Path $script:scripts 'Bootstrap.ps1'
    $script:backend = Join-Path $script:scripts 'Initialize-Backend.ps1'
    $script:probe = Join-Path $script:scripts 'Test-StateAccess.ps1'
    $script:accountId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/external/providers/Microsoft.Storage/storageAccounts/teststate'
    $script:savedEnvironment = @{}
    foreach ($name in @('ARM_ACCESS_KEY', 'ARM_SAS_TOKEN', 'ARM_CLIENT_SECRET',
        'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'GITHUB_ACTIONS',
        'GITHUB_REF', 'GITHUB_EVENT_NAME', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $script:originalExitCode = $global:LASTEXITCODE
    function az { }
    function terraform { }
    function gh { }
}

AfterAll {
    foreach ($name in $script:savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    $global:LASTEXITCODE = $script:originalExitCode
}

Describe 'Bootstrap ownership and failure handling' {
    BeforeEach {
        $global:LASTEXITCODE = 0
        Mock terraform {
            $global:LASTEXITCODE = 0
            if ($args -contains 'plan') {
                $outputPath = @($args | Where-Object { $_ -like '-out=*' })[0].Substring(5)
                Set-Content -LiteralPath $outputPath -Value 'mock plan'
            }
            if ($args -contains 'output') {
                '{"AZURE_CLIENT_ID":"client","AZURE_SUBSCRIPTION_ID":"target"}'
            }
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args -contains 'api') {
                '{"use_default":true,"sub_claim_prefix":"repo:owner@1/repo@2"}'
            }
        }
        Mock az {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            if ($command -match '^account show') {
                '{"id":"22222222-2222-2222-2222-222222222222","tenantId":"tenant","environmentName":"AzureCloud","user":{"type":"user"}}'
            }
            elseif ($command -match '^storage account show') {
                '{"name":"teststate","publicNetworkAccess":"Enabled","networkRuleSet":{"defaultAction":"Allow"},"primaryEndpoints":{"blob":"https://teststate.blob.core.windows.net/"}}'
            }
            elseif ($command -match '^provider show') {
                '{"registrationState":"Registered","resourceTypes":[{"resourceType":"agents","locations":["West US 3"]}]}'
            }
            elseif ($command -match '^ad signed-in-user show') {
                '"operator"'
            }
        }
    }

    It 'plans by default and preserves separate target and state account settings' {
        & $script:bootstrap -StateStorageAccountId $script:accountId
        $settings = Get-Content (Join-Path $script:bootstrapDirectory 'bootstrap.auto.tfvars.json') -Raw | ConvertFrom-Json
        $settings.target_subscription_id | Should -Be '22222222-2222-2222-2222-222222222222'
        $settings.state_storage_account_id | Should -Be $script:accountId
        $settings.github_subject_prefix | Should -Be 'repo:owner@1/repo@2'
        Should -Invoke terraform -Times 1 -Exactly -ParameterFilter { $args -contains 'plan' }
        Should -Invoke terraform -Times 0 -Exactly -ParameterFilter { $args -contains 'apply' }
    }

    It 'applies the saved plan twice without duplicating imperative Azure creates' {
        & $script:bootstrap -StateStorageAccountId $script:accountId -Apply -ConfigureGitHub
        & $script:bootstrap -StateStorageAccountId $script:accountId -Apply -ConfigureGitHub
        Should -Invoke terraform -Times 2 -Exactly -ParameterFilter { $args -contains 'apply' -and ($args -join ' ') -match 'bootstrap.tfplan' }
        Should -Invoke gh -Times 4 -Exactly -ParameterFilter { $args -contains 'set' }
        Should -Invoke az -Times 0 -Exactly -ParameterFilter { $args -contains 'create' }
    }

    It 'fails before planning when shared-account networking blocks hosted runners' {
        Mock az { '{"name":"teststate","publicNetworkAccess":"Disabled","networkRuleSet":{"defaultAction":"Deny"}}' } -ParameterFilter {
            ($args -join ' ') -match '^storage account show'
        }
        { & $script:bootstrap -StateStorageAccountId $script:accountId -Apply } | Should -Throw '*network policy*'
        Should -Invoke terraform -Times 0 -Exactly
    }

    It 'rejects cross-tenant state rather than changing the selected target subscription' {
        Mock az { '{"tenantId":"other"}' } -ParameterFilter { $args -contains '--subscription' -and $args -contains 'account' }
        { & $script:bootstrap -StateStorageAccountId $script:accountId } | Should -Throw '*Cross-tenant*'
        Should -Invoke terraform -Times 0 -Exactly
    }

    It 'does not configure variables after a native Terraform apply failure' {
        Mock terraform { $global:LASTEXITCODE = 7 } -ParameterFilter { $args -contains 'apply' }
        { & $script:bootstrap -StateStorageAccountId $script:accountId -Apply -ConfigureGitHub } | Should -Throw '*exit code 7*'
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args -contains 'set' }
    }

    It 'fails on custom GitHub subjects rather than guessing trust' {
        Mock gh { '{"use_default":false,"sub_claim_prefix":"repo:owner/repo"}' }
        { & $script:bootstrap -StateStorageAccountId $script:accountId } | Should -Throw '*Custom subjects*'
        Should -Invoke terraform -Times 0 -Exactly
    }
}

Describe 'Keyless backend request construction' {
    BeforeEach {
        $global:LASTEXITCODE = 0
        Mock terraform { $global:LASTEXITCODE = 0 }
        Mock az { '{"environmentName":"AzureCloud","user":{"type":"user"}}' }
        $script:parameters = @{
            StorageAccountName = 'teststate'
            ContainerName      = 'sre-checkout'
            StateKey           = 'checkout.tfstate'
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_EVENT_NAME = 'push'
        $env:ARM_CLIENT_ID = 'client'
        $env:ARM_TENANT_ID = 'tenant'
        $env:ARM_SUBSCRIPTION_ID = 'subscription'
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.invalid'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'mock-ephemeral-value'
    }

    It 'forces both Entra Blob and OIDC without CLI fallback in CI' {
        & $script:backend @parameters -Authentication GitHubOidc
        Should -Invoke terraform -Times 1 -Exactly -ParameterFilter {
            $args -contains '-backend-config=use_azuread_auth=true' -and
            $args -contains '-backend-config=use_oidc=true' -and
            $args -contains '-backend-config=use_cli=false'
        }
    }

    It 'uses CLI and Entra Blob authentication locally' {
        & $script:backend @parameters -Authentication AzureCli
        Should -Invoke terraform -Times 1 -Exactly -ParameterFilter {
            $args -contains '-backend-config=use_oidc=false' -and $args -contains '-backend-config=use_cli=true'
        }
    }

    It 'rejects PR execution and missing federation permissions' {
        $env:GITHUB_EVENT_NAME = 'pull_request'
        { & $script:backend @parameters -Authentication GitHubOidc } | Should -Throw '*trusted main*'
        $env:GITHUB_EVENT_NAME = 'push'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = $null
        { & $script:backend @parameters -Authentication GitHubOidc } | Should -Throw '*missing*'
        Should -Invoke terraform -Times 0 -Exactly
    }

    It 'rejects key-based environment configuration before invoking Terraform' {
        try {
            $env:ARM_ACCESS_KEY = 'mock-forbidden-value'
            { & $script:backend @parameters -Authentication AzureCli } | Should -Throw '*ARM_ACCESS_KEY*'
            Should -Invoke terraform -Times 0 -Exactly
        }
        finally {
            $env:ARM_ACCESS_KEY = $null
        }
    }
}

Describe 'State probe cleanup and error propagation' {
    BeforeEach {
        $global:LASTEXITCODE = 0
        Mock az {
            $global:LASTEXITCODE = 0
            if ($args -contains 'acquire') { '"lease-id"' }
        }
    }

    It 'probes a unique non-state blob and releases its lease before deleting it' {
        & $script:probe -StorageAccountName teststate -ContainerName sre-checkout
        Should -Invoke az -Times 5 -Exactly -ParameterFilter {
            $args -contains 'login' -and ($args -join ' ') -match 'bootstrap-probes/[a-f0-9]+[.]txt'
        }
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args -contains 'acquire' -and $args -contains '--blob-name' }
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args -contains 'release' -and $args -contains 'lease-id' -and $args -contains '--blob-name' }
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args -contains 'delete' }
    }

    It 'cleans up an uploaded probe and fails when lease acquisition fails' {
        Mock az { $global:LASTEXITCODE = 9 } -ParameterFilter { $args -contains 'acquire' }
        { & $script:probe -StorageAccountName teststate -ContainerName sre-checkout } | Should -Throw '*exit code 9*'
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args -contains 'delete' }
    }
}
