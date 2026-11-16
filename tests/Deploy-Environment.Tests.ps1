BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:scriptsDir = Join-Path $TestDrive 'scripts'
    Copy-Item -LiteralPath (Join-Path $script:root 'scripts') -Destination $script:scriptsDir -Recurse
    Copy-Item -LiteralPath (Join-Path $script:root 'sre-agent') -Destination (Join-Path $TestDrive 'sre-agent') -Recurse
    Copy-Item -LiteralPath (Join-Path $script:root 'sample') -Destination (Join-Path $TestDrive 'sample') -Recurse
    $script:environmentDir = Join-Path (Join-Path $TestDrive 'infra') 'environment'
    New-Item -ItemType Directory -Path $script:environmentDir -Force | Out-Null
    $script:deployEnvironment = Join-Path $script:scriptsDir 'Deploy-Environment.ps1'

    $script:savedEnvironment = @{}
    foreach ($name in @(
        'ARM_ACCESS_KEY', 'ARM_SAS_TOKEN', 'ARM_CLIENT_SECRET',
        'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
        'AZURE_OPERATOR_OBJECT_ID', 'GITHUB_ACTIONS', 'GITHUB_REF',
        'GITHUB_EVENT_NAME', 'GITHUB_STEP_SUMMARY',
        'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
    )) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $script:originalExitCode = $global:LASTEXITCODE
    function az { }
    function terraform { }
}

AfterAll {
    foreach ($name in $script:savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
    $global:LASTEXITCODE = $script:originalExitCode
}

Describe 'End-to-end environment and data-plane orchestration' {
    BeforeEach {
        $global:LASTEXITCODE = 0
        $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
        $script:tenantId = '22222222-2222-2222-2222-222222222222'
        $script:operatorId = '33333333-3333-3333-3333-333333333333'
        $script:workspaceCustomerId = '44444444-4444-4444-4444-444444444444'
        $script:summaryPath = Join-Path $TestDrive ('summary-' + [Guid]::NewGuid().ToString('N') + '.md')
        $script:tracePath = Join-Path $TestDrive 'trace.log'
        if (Test-Path -LiteralPath $script:tracePath) {
            Remove-Item -LiteralPath $script:tracePath -Force
        }

        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_EVENT_NAME = 'push'
        $env:GITHUB_STEP_SUMMARY = $null
        $env:ARM_CLIENT_ID = '55555555-5555-5555-5555-555555555555'
        $env:ARM_TENANT_ID = $script:tenantId
        $env:ARM_SUBSCRIPTION_ID = $script:subscriptionId
        $env:AZURE_OPERATOR_OBJECT_ID = $script:operatorId
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.invalid/oidc'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'mock-oidc-request-token'

        Mock terraform {
            $global:LASTEXITCODE = 0
            $trace = Join-Path $TestDrive 'trace.log'
            $joined = $args -join ' '
            if ($args -contains 'init') {
                Add-Content -LiteralPath $trace -Value 'terraform:init'
            }
            elseif ($args -contains 'validate') {
                Add-Content -LiteralPath $trace -Value 'terraform:validate'
            }
            elseif ($args -contains 'plan') {
                Add-Content -LiteralPath $trace -Value 'terraform:plan'
                $outArg = @($args | Where-Object { $_ -like '-out=*' })[0]
                Set-Content -LiteralPath $outArg.Substring(5) -Value 'mock-plan-binary'
            }
            elseif ($args -contains 'apply') {
                $planFile = Join-Path (Join-Path (Join-Path $TestDrive 'infra') 'environment') 'environment.tfplan'
                if (-not (Test-Path -LiteralPath $planFile)) {
                    throw 'Expected saved plan file to exist during apply.'
                }
                Add-Content -LiteralPath $trace -Value 'terraform:apply'
            }
            elseif ($joined -match 'output -json$') {
                Add-Content -LiteralPath $trace -Value 'terraform:output'
                '{"agent_id":{"value":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-sre-checkout-westus3/providers/Microsoft.App/agents/sre-checkout-da3a0ee8"},"workspace_customer_id":{"value":"44444444-4444-4444-4444-444444444444"}}'
            }
        }

        Mock az {
            $global:LASTEXITCODE = 0
            $trace = Join-Path $TestDrive 'trace.log'
            $command = $args -join ' '
            if ($command -match '^account show') {
                '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","environmentName":"AzureCloud","user":{"type":"servicePrincipal"}}'
            }
            elseif ($command -match '^ad signed-in-user show') {
                '33333333-3333-3333-3333-333333333333'
            }
            elseif ($command -match 'Microsoft.App/agents/sre-checkout-da3a0ee8') {
                Add-Content -LiteralPath $trace -Value 'az:agent'
                '{"location":"westus3","properties":{"provisioningState":"Succeeded","agentEndpoint":"https://checkout.test.westus3.azuresre.ai"}}'
            }
            elseif ($command -match 'Microsoft.OperationalInsights/workspaces/law-sre-checkout') {
                Add-Content -LiteralPath $trace -Value 'az:workspace'
                '{"properties":{"customerId":"44444444-4444-4444-4444-444444444444"}}'
            }
            elseif ($command -match '^account get-access-token') {
                Add-Content -LiteralPath $trace -Value 'az:token'
                'mock-ephemeral-bearer'
            }
        }
    }

    It 'executes backend init, plan, apply, asset packaging, data-plane sync and summary generation in order on trusted main' {
        Mock Invoke-WebRequest {
            $trace = Join-Path $TestDrive 'trace.log'
            Add-Content -LiteralPath $trace -Value "http:$Method"
            . (Join-Path (Join-Path $TestDrive 'scripts') 'DataPlane.ps1')
            $expectedAssets = @(Get-SreAgentAsset -RepositoryRoot $TestDrive `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroup 'rg-sre-checkout-westus3' `
                -WorkspaceId '44444444-4444-4444-4444-444444444444')
            foreach ($item in $expectedAssets) {
                $key = "$($item.Kind)/$($item.Envelope.name)"
                if ($Uri -like "*/$key") {
                    return [pscustomobject]@{
                        StatusCode = 200
                        Content    = ($item.Envelope | ConvertTo-Json -Depth 30 -Compress)
                    }
                }
            }
            throw "Unexpected URI $Uri"
        }

        $output = @(& $script:deployEnvironment `
            -StorageAccountName 'teststate' `
            -ContainerName 'sre-checkout' `
            -StateKey 'checkout.tfstate' `
            -Authentication GitHubOidc `
            -SummaryPath $script:summaryPath)

        Test-Path -LiteralPath (Join-Path $script:environmentDir 'environment.tfplan') | Should -BeFalse
        $output | Should -Contain 'Unchanged skills/checkout-investigation'
        $output | Should -Contain 'Unchanged agents/checkout-investigator'
        $output | Should -Contain 'Unchanged scheduledtasks/checkout-daily-investigation'

        $calls = @(Get-Content -LiteralPath $script:tracePath)
        ($calls -join ' -> ') | Should -Be (
            'terraform:init -> terraform:validate -> terraform:plan -> terraform:apply -> terraform:output -> ' +
            'az:agent -> az:workspace -> az:token -> http:GET -> http:GET -> http:GET'
        )

        Should -Invoke terraform -Times 1 -Exactly -ParameterFilter {
            $args -contains 'plan' -and
            $args -contains '-var=target_subscription_id=11111111-1111-1111-1111-111111111111' -and
            $args -contains '-var=tenant_id=22222222-2222-2222-2222-222222222222' -and
            $args -contains '-var=operator_object_id=33333333-3333-3333-3333-333333333333' -and
            $args -contains '-var=use_oidc=true' -and
            $args -contains '-var=fault_enabled=false'
        }

        $summary = Get-Content -LiteralPath $script:summaryPath -Raw
        $summary | Should -Match 'sre-checkout-da3a0ee8'
        $summary | Should -Match $script:workspaceCustomerId
        $summary | Should -Match 'Unchanged skills/checkout-investigation'
        $summary | Should -Not -Match 'mock-ephemeral-bearer'
        $summary | Should -Not -Match 'mock-oidc-request-token'
        $summary | Should -Not -Match 'mock-plan-binary'
    }

    It 'supports local interactive AzureCli execution and FaultEnabled flag' {
        $env:GITHUB_ACTIONS = $null
        Mock az {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            if ($command -match '^account show') {
                '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","environmentName":"AzureCloud","user":{"type":"user"}}'
            }
            elseif ($command -match '^ad signed-in-user show') {
                '33333333-3333-3333-3333-333333333333'
            }
            elseif ($command -match 'Microsoft.App/agents/sre-checkout-da3a0ee8') {
                '{"location":"westus3","properties":{"provisioningState":"Succeeded","agentEndpoint":"https://checkout.test.westus3.azuresre.ai"}}'
            }
            elseif ($command -match 'Microsoft.OperationalInsights/workspaces/law-sre-checkout') {
                '{"properties":{"customerId":"44444444-4444-4444-4444-444444444444"}}'
            }
            elseif ($command -match '^account get-access-token') {
                'mock-ephemeral-bearer'
            }
        }
        Mock Invoke-WebRequest {
            . (Join-Path (Join-Path $TestDrive 'scripts') 'DataPlane.ps1')
            $expectedAssets = @(Get-SreAgentAsset -RepositoryRoot $TestDrive `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroup 'rg-sre-checkout-westus3' `
                -WorkspaceId '44444444-4444-4444-4444-444444444444')
            foreach ($item in $expectedAssets) {
                $key = "$($item.Kind)/$($item.Envelope.name)"
                if ($Uri -like "*/$key") {
                    return [pscustomobject]@{
                        StatusCode = 200
                        Content    = ($item.Envelope | ConvertTo-Json -Depth 30 -Compress)
                    }
                }
            }
            throw "Unexpected URI $Uri"
        }

        & $script:deployEnvironment `
            -StorageAccountName 'teststate' `
            -ContainerName 'sre-checkout' `
            -StateKey 'checkout.tfstate' `
            -Authentication AzureCli `
            -FaultEnabled `
            -SummaryPath $script:summaryPath | Out-Null

        Should -Invoke terraform -Times 1 -Exactly -ParameterFilter {
            $args -contains 'plan' -and
            $args -contains '-var=use_oidc=false' -and
            $args -contains '-var=fault_enabled=true'
        }
    }

    It 'rejects pull_request execution and non-main refs before running Terraform or Azure CLI' {
        $env:GITHUB_EVENT_NAME = 'pull_request'
        $env:GITHUB_REF = 'refs/pull/6/merge'
        {
            & $script:deployEnvironment `
                -StorageAccountName 'teststate' `
                -ContainerName 'sre-checkout' `
                -StateKey 'checkout.tfstate' `
                -Authentication GitHubOidc
        } | Should -Throw '*trusted main*'
        Should -Invoke terraform -Times 0 -Exactly
        Should -Invoke az -Times 0 -Exactly
    }

    It 'rejects AzureCli mode inside GitHub Actions' {
        {
            & $script:deployEnvironment `
                -StorageAccountName 'teststate' `
                -ContainerName 'sre-checkout' `
                -StateKey 'checkout.tfstate' `
                -Authentication AzureCli
        } | Should -Throw '*local interactive execution only*'
        Should -Invoke terraform -Times 0 -Exactly
    }

    It 'cleans up the saved plan and stops before data-plane deployment when Terraform apply fails' {
        Mock terraform {
            $global:LASTEXITCODE = 0
            if ($args -contains 'plan') {
                $outArg = @($args | Where-Object { $_ -like '-out=*' })[0]
                Set-Content -LiteralPath $outArg.Substring(5) -Value 'mock-plan-binary'
            }
            elseif ($args -contains 'apply') {
                $global:LASTEXITCODE = 1
            }
        }
        {
            & $script:deployEnvironment `
                -StorageAccountName 'teststate' `
                -ContainerName 'sre-checkout' `
                -StateKey 'checkout.tfstate' `
                -Authentication GitHubOidc `
                -SummaryPath $script:summaryPath
        } | Should -Throw '*exit code 1*'

        Test-Path -LiteralPath (Join-Path $script:environmentDir 'environment.tfplan') | Should -BeFalse
        Test-Path -LiteralPath $script:summaryPath | Should -BeFalse
        Should -Invoke az -Times 0 -Exactly -ParameterFilter { $args -contains 'get-access-token' }
    }

    It 'propagates a data-plane sync failure without writing a summary and cleans up staged packages' {
        Mock Invoke-WebRequest {
            return [pscustomobject]@{
                StatusCode = 200
                Content    = '{"name":"checkout-investigation","type":"Skill","tags":["unmanaged"],"properties":{}}'
            }
        }
        $beforePackages = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'sre-checkout-assets-*')
        {
            & $script:deployEnvironment `
                -StorageAccountName 'teststate' `
                -ContainerName 'sre-checkout' `
                -StateKey 'checkout.tfstate' `
                -Authentication GitHubOidc `
                -SummaryPath $script:summaryPath
        } | Should -Throw '*Refusing unmanaged or incompatible skills/checkout-investigation*'

        $afterPackages = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'sre-checkout-assets-*')
        $afterPackages.Count | Should -Be $beforePackages.Count
        Test-Path -LiteralPath $script:summaryPath | Should -BeFalse
    }
}
