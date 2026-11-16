BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    . (Join-Path (Join-Path $script:root 'scripts') 'Common.ps1')
    . (Join-Path (Join-Path $script:root 'scripts') 'DataPlane.ps1')
    $script:deploy = Join-Path (Join-Path $script:root 'scripts') 'Deploy-Assets.ps1'
    $script:subscription = '11111111-1111-1111-1111-111111111111'
    $script:workspace = '22222222-2222-2222-2222-222222222222'
    $script:endpoint = 'https://checkout.test.westus3.azuresre.ai'
    function az { }
    function Get-HttpFailure {
        param([int] $Status)
        $exception = New-Object System.Exception 'Sensitive service response must not escape.'
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status })
        return $exception
    }
}

Describe 'Checkout asset rendering' {
    It 'renders valid envelopes, source snapshot and scoped prompts without unresolved tokens' {
        $assets = @(Get-CheckoutAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        $assets.Count | Should -Be 3
        $skill = $assets[0].Envelope
        $skill.type | Should -Be 'Skill'
        $skill.tags | Should -Contain 'managed-by:checkout-reliability-lab'
        $skill.properties.skillContent | Should -Match $script:workspace
        $skill.properties.skillContent | Should -Match 'sequence % 5 == 0'
        $skill.properties.skillContent | Should -Match 'ContainerAppConsoleLogs'
        $skill.properties.skillContent | Should -Match 'SHA-256\s+`[a-f0-9]{64}`'
        ($assets | ConvertTo-Json -Depth 30) | Should -Not -Match '{{[A-Za-z]+}}'
        $assets[1].Envelope.properties.allowedSkills | Should -Contain $skill.name
        $assets[2].Envelope.properties.agent | Should -Be $assets[1].Envelope.name
        $assets[2].Envelope.properties.status | Should -Be 'Paused'
    }

    It 'compares only intended fields while detecting case, type and array changes' {
        $expected = '{"text":"ReadOnly","enabled":false,"tools":["read"],"empty":[]}' | ConvertFrom-Json
        $actual = '{"empty":[],"tools":["read"],"enabled":false,"text":"ReadOnly","serverField":"extra"}' | ConvertFrom-Json
        Test-AgentValue $expected $actual | Should -BeTrue
        $actual.text = 'readonly'
        Test-AgentValue $expected $actual | Should -BeFalse
        $actual.text = 'ReadOnly'
        $actual.enabled = 'false'
        Test-AgentValue $expected $actual | Should -BeFalse
        $actual.enabled = $false
        $actual.empty = $null
        Test-AgentValue $expected $actual | Should -BeFalse
    }

    It 'packages only the versioned checkout manifest, prompt files and sample source into a clean directory' {
        $destination = Join-Path $TestDrive ('pkg-' + [Guid]::NewGuid().ToString('N'))
        $package = New-CheckoutAssetPackage -RepositoryRoot $script:root -DestinationPath $destination
        $package.PackagePath | Should -Be $destination
        $package.SourceSha256 | Should -Match '^[a-f0-9]{64}$'
        $package.AssetNames | Should -Be @(
            'skills/checkout-investigation',
            'agents/checkout-investigator',
            'scheduledtasks/checkout-daily-investigation'
        )
        $stagedFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        $stagedFiles | Should -Be @('agent.md', 'assets.json', 'automation.md', 'checkout.py', 'investigation.md')
        $fromRepo = @(Get-CheckoutAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        $fromPackage = @(Get-CheckoutAsset -RepositoryRoot $destination -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        ($fromPackage | ConvertTo-Json -Depth 30 -Compress) |
            Should -Be ($fromRepo | ConvertTo-Json -Depth 30 -Compress)
        { New-CheckoutAssetPackage -RepositoryRoot $script:root -DestinationPath $destination } |
            Should -Throw '*already exists*'
    }
}

Describe 'Agent HTTP request construction and failures' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"name":"checkout-test"}' }
        }
    }

    It 'sends UTF-8 JSON with in-memory authorization and no redirects' {
        Invoke-AgentRequest -Method PUT -Uri "$script:endpoint/api/v2/extendedAgent/skills/checkout-test" `
            -Headers @{ Authorization = 'Bearer mock-short-lived' } -Body '{"name":"checkout-test"}' | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 60 -and
            $Headers.Authorization -eq 'Bearer mock-short-lived' -and
            [Text.Encoding]::UTF8.GetString($Body) -eq '{"name":"checkout-test"}' -and
            $ContentType -eq 'application/json; charset=utf-8'
        }
    }

    It 'retries throttling with a bounded delay then returns success' {
        $script:calls = 0
        Mock Invoke-WebRequest {
            $script:calls++
            if ($script:calls -lt 3) { throw (Get-HttpFailure 429) }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
        Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} | Out-Null
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
    }

    It 'fails after four transient responses without leaking the service body' {
        Mock Invoke-WebRequest { throw (Get-HttpFailure 503) }
        { Invoke-AgentRequest -Method PUT -Uri $script:endpoint -Headers @{} -Body '{}' } |
            Should -Throw '*HTTP 503, attempt 4/4*'
        Should -Invoke Invoke-WebRequest -Times 4 -Exactly
    }

    It 'does not retry or hide authorization, unsupported API or network errors' -ForEach @(
        @{ Status = 401 }, @{ Status = 403 }, @{ Status = 400 },
        @{ Status = 404 }, @{ Status = 405 }, @{ Status = 0 }
    ) {
        Mock Invoke-WebRequest { throw (Get-HttpFailure $Status) }
        { Invoke-AgentRequest -Method PUT -Uri $script:endpoint -Headers @{} -Body '{}' } |
            Should -Throw "*HTTP $Status, attempt 1/4*"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'allows absent assets only for an explicitly opted-in GET' {
        Mock Invoke-WebRequest { throw (Get-HttpFailure 404) }
        Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} -AllowNotFound | Should -BeNullOrEmpty
        { Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} } | Should -Throw '*HTTP 404*'
    }

    It 'rejects invalid JSON and accepts asynchronous PUT only for subsequent read-back' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = 'not-json-sensitive' } }
        { Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} } | Should -Throw '*invalid JSON*'
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 202; Content = '{}' } }
        Invoke-AgentRequest -Method PUT -Uri $script:endpoint -Headers @{} -Body '{}' | Should -BeNullOrEmpty
        { Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} } |
            Should -Throw '*unsupported HTTP 202*'
    }

    It 'does not treat an empty or null successful GET as an absent asset' -ForEach @(
        @{ Content = '' }, @{ Content = 'null' }, @{ Content = '[]' }
    ) {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $Content } }
        { Invoke-AgentRequest -Method GET -Uri $script:endpoint -Headers @{} -AllowNotFound } |
            Should -Throw '*not a confirmed absent asset*'
    }
}

Describe 'Owned asset convergence' {
    BeforeEach {
        $script:assets = @(Get-CheckoutAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        $script:store = @{}
        Mock Start-Sleep { }
        Mock Invoke-AgentRequest {
            if ($Method -eq 'PUT') {
                $script:store[$Uri] = $Body | ConvertFrom-Json
                return $script:store[$Uri]
            }
            if ($script:store.ContainsKey($Uri)) { return $script:store[$Uri] }
            if (-not $AllowNotFound) { throw 'Unexpected missing read-back.' }
            return $null
        }
    }

    It 'creates, reads back and reruns without duplicate writes, then converges an owned edit' {
        Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 3 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        $script:store["$script:endpoint/api/v2/extendedAgent/agents/checkout-investigator"].properties.instructions = 'outdated'
        Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 4 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'preflights all names and refuses an unmanaged object before any writes' {
        $script:store["$script:endpoint/api/v2/extendedAgent/scheduledtasks/checkout-daily-investigation"] =
            '{"name":"checkout-daily-investigation","type":"ScheduledTask","tags":[],"properties":{}}' | ConvertFrom-Json
        { Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Refusing unmanaged*'
        Should -Invoke Invoke-AgentRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'uses the persisted description marker for tasks whose envelope tags are dropped' {
        Mock Invoke-AgentRequest {
            if ($Method -eq 'PUT') {
                $script:store[$Uri] = $Body | ConvertFrom-Json
                $script:store[$Uri].tags = $null
            }
            if ($script:store.ContainsKey($Uri)) { return $script:store[$Uri] }
            return $null
        } -ParameterFilter { $Uri -match '/scheduledtasks/' }
        Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 3 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        $script:store["$script:endpoint/api/v2/extendedAgent/scheduledtasks/checkout-daily-investigation"].properties.description = 'unmanaged'
        { Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Refusing unmanaged*'
        Should -Invoke Invoke-AgentRequest -Times 3 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'stops after a failed PUT without deploying dependent assets' {
        Mock Invoke-AgentRequest { throw 'Deliberate HTTP 400.' } -ParameterFilter { $Method -eq 'PUT' }
        { Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Deliberate HTTP 400*'
        Should -Invoke Invoke-AgentRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'fails a successful-looking write when the service drops intended properties' {
        $script:written = $false
        Mock Invoke-AgentRequest { $script:written = $true } -ParameterFilter { $Method -eq 'PUT' }
        Mock Invoke-AgentRequest {
            '{"name":"checkout-investigation","type":"Skill","tags":["managed-by:checkout-reliability-lab"],"properties":{}}' |
                ConvertFrom-Json
        } -ParameterFilter { $Method -eq 'GET' -and $script:written }
        { Sync-CheckoutAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Read-back verification failed*'
        Should -Invoke Invoke-AgentRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }
}

Describe 'Deployment discovery and identity boundaries' {
    BeforeEach {
        $script:savedActions = $env:GITHUB_ACTIONS
        $script:savedRef = $env:GITHUB_REF
        $script:savedEvent = $env:GITHUB_EVENT_NAME
        $env:GITHUB_ACTIONS = $null
        Mock Assert-KeylessEnvironment { }
        Mock Sync-CheckoutAsset { 'mock configured' }
        Mock az {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            if ($command -match '^account show') {
                '{"id":"11111111-1111-1111-1111-111111111111","environmentName":"AzureCloud"}'
            }
            elseif ($command -match 'Microsoft.App/agents') {
                '{"location":"westus3","properties":{"provisioningState":"Succeeded","agentEndpoint":"https://checkout.test.westus3.azuresre.ai"}}'
            }
            elseif ($command -match 'Microsoft.OperationalInsights/workspaces') {
                '{"properties":{"customerId":"22222222-2222-2222-2222-222222222222"}}'
            }
            elseif ($command -match '^account get-access-token') { 'mock-short-lived' }
        }
    }
    AfterEach {
        $env:GITHUB_ACTIONS = $script:savedActions
        $env:GITHUB_REF = $script:savedRef
        $env:GITHUB_EVENT_NAME = $script:savedEvent
    }

    It 'discovers ARM resources in the selected subscription and requests the documented audience' {
        & $script:deploy -AgentName sre-checkout-test
        Should -Invoke az -Times 1 -Exactly -ParameterFilter {
            $args -contains '--url' -and ($args -join ' ') -match "subscriptions/$script:subscription/resourceGroups/rg-sre-checkout-westus3/providers/Microsoft.App/agents/sre-checkout-test[?]api-version=2026-01-01"
        }
        Should -Invoke az -Times 1 -Exactly -ParameterFilter {
            $args -contains 'get-access-token' -and $args -contains 'https://azuresre.dev'
        }
        Should -Invoke Sync-CheckoutAsset -Times 1 -Exactly -ParameterFilter { $Assets.Count -eq 3 }
    }

    It 'rejects an untrusted ARM endpoint before token acquisition' -ForEach @(
        @{ Endpoint = 'https://evil.example' },
        @{ Endpoint = 'http://checkout.azuresre.ai' },
        @{ Endpoint = 'https://checkout.azuresre.ai.evil.example' },
        @{ Endpoint = 'https://checkout.azuresre.ai/path' }
    ) {
        Mock az {
            '{"location":"westus3","properties":{"provisioningState":"Succeeded","agentEndpoint":"' + $Endpoint + '"}}'
        } -ParameterFilter { ($args -join ' ') -match 'Microsoft.App/agents' }
        { & $script:deploy -AgentName sre-checkout-test } | Should -Throw '*unsupported agent endpoint*'
        Should -Invoke az -Times 0 -Exactly -ParameterFilter { $args -contains 'get-access-token' }
    }

    It 'propagates native token acquisition failure' {
        Mock az { $global:LASTEXITCODE = 5 } -ParameterFilter { $args -contains 'get-access-token' }
        { & $script:deploy -AgentName sre-checkout-test } | Should -Throw '*exit code 5*'
        Should -Invoke Sync-CheckoutAsset -Times 0 -Exactly
    }

    It 'rejects PR execution before accessing Azure' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REF = 'refs/pull/42/merge'
        $env:GITHUB_EVENT_NAME = 'pull_request'
        { & $script:deploy -AgentName sre-checkout-test } | Should -Throw '*trusted main*'
        Should -Invoke az -Times 0 -Exactly
    }

    It 'deploys from an explicit staged package directory and rejects a missing package path' {
        $destination = Join-Path $TestDrive ('deploy-pkg-' + [Guid]::NewGuid().ToString('N'))
        $package = New-CheckoutAssetPackage -RepositoryRoot $script:root -DestinationPath $destination
        & $script:deploy -AgentName sre-checkout-test -PackagePath $package.PackagePath
        Should -Invoke Sync-CheckoutAsset -Times 1 -Exactly -ParameterFilter { $Assets.Count -eq 3 }
        $missing = Join-Path $TestDrive 'nonexistent-package'
        { & $script:deploy -AgentName sre-checkout-test -PackagePath $missing } |
            Should -Throw '*package directory does not exist*'
    }
}
