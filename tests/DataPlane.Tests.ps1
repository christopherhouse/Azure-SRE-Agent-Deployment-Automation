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

Describe 'SRE Agent resource tree discovery and rendering' {
    It 'renders valid envelopes, source snapshot and scoped prompts without unresolved tokens' {
        $assets = @(Get-SreAgentAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        $assets.Count | Should -Be 8

        $logConnector = $assets[0].Envelope
        $logConnector.type | Should -Be 'AgentConnector'
        $logConnector.name | Should -Be 'checkout-log-analytics'
        $logConnector.properties.identity | Should -Match $script:subscription
        $logConnector.properties.extendedProperties.workspaceId | Should -Be $script:workspace
        $logConnector.properties.extendedProperties.description | Should -Match '\[managed-by:checkout-reliability-lab\]$'

        $monitorConnector = $assets[1].Envelope
        $monitorConnector.type | Should -Be 'AgentConnector'
        $monitorConnector.name | Should -Be 'monitor-client'

        $commonPrompt = $assets[2].Envelope
        $commonPrompt.type | Should -Be 'CommonPrompt'
        $commonPrompt.properties.prompt | Should -Match $script:workspace

        $tool = $assets[3].Envelope
        $tool.type | Should -Be 'ExtendedAgentTool'
        $tool.properties.type | Should -Be 'PythonFunctionTool'
        $tool.properties.functionCode | Should -Match 'def main\('

        $skill = $assets[4].Envelope
        $skill.type | Should -Be 'Skill'
        $skill.tags | Should -Contain 'managed-by:checkout-reliability-lab'
        $skill.properties.skillContent | Should -Match $script:workspace
        $skill.properties.skillContent | Should -Match 'sequence % 5 == 0'
        $skill.properties.skillContent | Should -Match 'ContainerAppConsoleLogs'
        $skill.properties.skillContent | Should -Match 'SHA-256\s+`[a-f0-9]{64}`'

        $hook = $assets[5].Envelope
        $hook.type | Should -Be 'GlobalHook'
        $hook.properties.hook.prompt | Should -Match $script:workspace

        $agent = $assets[6].Envelope
        $agent.properties.allowedSkills | Should -Contain $skill.name
        $agent.properties.commonPrompts | Should -Contain $commonPrompt.name
        $agent.properties.tools | Should -Contain $tool.name

        $task = $assets[7].Envelope
        $task.properties.agent | Should -Be $agent.name
        $task.properties.status | Should -Be 'Paused'

        ($assets | ConvertTo-Json -Depth 30) | Should -Not -Match '{{[A-Za-z0-9_]+}}'
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

    It 'packages only the versioned sre-agent resource tree, prompt files and sample source into a clean directory' {
        $destination = Join-Path $TestDrive ('pkg-' + [Guid]::NewGuid().ToString('N'))
        $package = New-SreAgentAssetPackage -RepositoryRoot $script:root -DestinationPath $destination
        $package.PackagePath | Should -Be $destination
        $package.SourceSha256 | Should -Match '^[a-f0-9]{64}$'
        $package.AssetNames | Should -Be @(
            'connectors/checkout-log-analytics',
            'connectors/monitor-client',
            'commonprompts/checkout-guardrails',
            'tools/checkout-slo-evaluator',
            'skills/checkout-investigation',
            'hooks/checkout-audit-stop-hook',
            'agents/checkout-investigator',
            'scheduledtasks/checkout-daily-investigation'
        )
        $stagedFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        $stagedFiles | Should -Be @(
            'agent.json', 'checkout.py', 'connector.json', 'connector.json',
            'hook.json', 'instructions.md', 'manifest.json', 'prompt.json',
            'prompt.md', 'prompt.md', 'prompt.md', 'skill.json',
            'SKILL.md', 'task.json', 'tool.json', 'tool.py'
        )
        $fromRepo = @(Get-SreAgentAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        $fromPackage = @(Get-SreAgentAsset -RepositoryRoot $destination -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        ($fromPackage | ConvertTo-Json -Depth 30 -Compress) |
            Should -Be ($fromRepo | ConvertTo-Json -Depth 30 -Compress)
        { New-SreAgentAssetPackage -RepositoryRoot $script:root -DestinationPath $destination } |
            Should -Throw '*already exists*'
    }

    It 'discovers additional SRE Agent resources in topological order and validates cross-references' {
        $tempRepo = Join-Path $TestDrive ('multi-kind-' + [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $script:root 'sre-agent') -Destination (Join-Path $tempRepo 'sre-agent') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:root 'sample') -Destination (Join-Path $tempRepo 'sample') -Recurse

        $extraSkillDir = Join-Path $tempRepo 'sre-agent\skills\zeta-latency-triage'
        New-Item -ItemType Directory -Path $extraSkillDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $extraSkillDir 'skill.json') -Value '{"name":"zeta-latency-triage","type":"Skill","properties":{"description":"Triage latency.","tools":["RunAzCliReadCommands"],"skillContent":""},"contentFiles":{"skillContent":"SKILL.md"}}'
        Set-Content -LiteralPath (Join-Path $extraSkillDir 'SKILL.md') -Value 'Inspect workspace {{WorkspaceId}} in {{ResourceGroup}}.'

        $discovered = @(Get-SreAgentAsset -RepositoryRoot $tempRepo -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace)
        @($discovered | ForEach-Object { "$($_.Kind)/$($_.Envelope.name)" }) | Should -Be @(
            'connectors/checkout-log-analytics',
            'connectors/monitor-client',
            'commonprompts/checkout-guardrails',
            'tools/checkout-slo-evaluator',
            'skills/checkout-investigation',
            'skills/zeta-latency-triage',
            'hooks/checkout-audit-stop-hook',
            'agents/checkout-investigator',
            'scheduledtasks/checkout-daily-investigation'
        )

        $agentManifestPath = Join-Path $tempRepo 'sre-agent\agents\checkout-investigator\agent.json'
        $agentJson = Get-Content -LiteralPath $agentManifestPath -Raw | ConvertFrom-Json
        $agentJson.properties.commonPrompts = @('missing-prompt')
        Set-Content -LiteralPath $agentManifestPath -Value ($agentJson | ConvertTo-Json -Depth 10)
        { Get-SreAgentAsset -RepositoryRoot $tempRepo -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace } |
            Should -Throw "*unknown common prompt 'missing-prompt'*"

        $agentJson.properties.commonPrompts = @('checkout-guardrails')
        $agentJson.properties.tools = @('RunAzCliReadCommands', 'missing-custom-tool')
        Set-Content -LiteralPath $agentManifestPath -Value ($agentJson | ConvertTo-Json -Depth 10)
        { Get-SreAgentAsset -RepositoryRoot $tempRepo -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace } |
            Should -Throw "*unknown custom tool 'missing-custom-tool'*"

        Set-Content -LiteralPath (Join-Path $extraSkillDir 'skill.json') -Value '{"name":"mismatched-name","type":"Skill","properties":{"description":"Bad"}}'
        { Get-SreAgentAsset -RepositoryRoot $tempRepo -SubscriptionId $script:subscription `
            -ResourceGroup rg-sre-checkout-westus3 -WorkspaceId $script:workspace } |
            Should -Throw '*must be lowercase kebab-case and match its directory name*'
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
        $script:assets = @(Get-SreAgentAsset -RepositoryRoot $script:root -SubscriptionId $script:subscription `
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
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 8 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        $script:store["$script:endpoint/api/v2/extendedAgent/agents/checkout-investigator"].properties.instructions = 'outdated'
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 9 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'preflights all names and refuses an unmanaged object before any writes' {
        $script:store["$script:endpoint/api/v2/extendedAgent/scheduledtasks/checkout-daily-investigation"] =
            '{"name":"checkout-daily-investigation","type":"ScheduledTask","tags":[],"properties":{}}' | ConvertFrom-Json
        { Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
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
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 8 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        $script:store["$script:endpoint/api/v2/extendedAgent/scheduledtasks/checkout-daily-investigation"].properties.description = 'unmanaged'
        { Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Refusing unmanaged*'
        Should -Invoke Invoke-AgentRequest -Times 8 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'uses listSecrets fallback and extendedProperties.description ownership marker when connector GET masks properties' {
        Mock Invoke-AgentRequest {
            if ($Method -eq 'PUT') {
                $script:store[$Uri] = $Body | ConvertFrom-Json
                $script:store[$Uri].tags = $null
                return $script:store[$Uri]
            }
            if ($Uri -like '*/connectors/listSecrets') {
                $values = @($script:store.Keys | Where-Object { $_ -match '/connectors/' } | ForEach-Object { $script:store[$_] })
                return [pscustomobject]@{ value = $values }
            }
            if ($script:store.ContainsKey($Uri)) {
                $masked = $script:store[$Uri] | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                $masked.tags = $null
                $masked.properties.dataSource = $null
                return $masked
            }
            return $null
        } -ParameterFilter { $Uri -match '/connectors/' }

        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets
        Should -Invoke Invoke-AgentRequest -Times 8 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'stops after a failed PUT without deploying dependent assets' {
        Mock Invoke-AgentRequest { throw 'Deliberate HTTP 400.' } -ParameterFilter { $Method -eq 'PUT' }
        { Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
            Should -Throw '*Deliberate HTTP 400*'
        Should -Invoke Invoke-AgentRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'fails a successful-looking write when the service drops intended properties' {
        $script:written = $false
        Mock Invoke-AgentRequest { $script:written = $true } -ParameterFilter { $Method -eq 'PUT' }
        Mock Invoke-AgentRequest {
            '{"name":"checkout-log-analytics","type":"AgentConnector","tags":["managed-by:checkout-reliability-lab"],"properties":{}}' |
                ConvertFrom-Json
        } -ParameterFilter { $Method -eq 'GET' -and $script:written }
        { Sync-SreAgentAsset -Endpoint $script:endpoint -Headers @{} -Assets $script:assets } |
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
        Mock Sync-SreAgentAsset { 'mock configured' }
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
        Should -Invoke Sync-SreAgentAsset -Times 1 -Exactly -ParameterFilter { $Assets.Count -eq 8 }
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
        Should -Invoke Sync-SreAgentAsset -Times 0 -Exactly
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
        $package = New-SreAgentAssetPackage -RepositoryRoot $script:root -DestinationPath $destination
        & $script:deploy -AgentName sre-checkout-test -PackagePath $package.PackagePath
        Should -Invoke Sync-SreAgentAsset -Times 1 -Exactly -ParameterFilter { $Assets.Count -eq 8 }
        $missing = Join-Path $TestDrive 'nonexistent-package'
        { & $script:deploy -AgentName sre-checkout-test -PackagePath $missing } |
            Should -Throw '*package directory does not exist*'
    }
}
