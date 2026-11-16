#Requires -Version 5.1

function Invoke-AgentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('GET', 'PUT')] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [hashtable] $Headers,
        [string] $Body,
        [switch] $AllowNotFound
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $parameters = @{
                Method = $Method; Uri = $Uri; Headers = $Headers
                UseBasicParsing = $true; ErrorAction = 'Stop'; TimeoutSec = 60
                MaximumRedirection = 0; Verbose = $false; Debug = $false
            }
            if ($Method -eq 'PUT') {
                $parameters.Body = [Text.Encoding]::UTF8.GetBytes($Body)
                $parameters.ContentType = 'application/json; charset=utf-8'
            }
            $response = Invoke-WebRequest @parameters
        }
        catch {
            $status = 0
            if ($_.Exception.Response) {
                $status = [int] $_.Exception.Response.StatusCode
            }
            if ($status -eq 404 -and $Method -eq 'GET' -and $AllowNotFound) {
                return $null
            }
            if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 4) {
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
                continue
            }
            # Service error bodies can include submitted content or generated URLs.
            throw "Agent $Method failed (HTTP $status, attempt $attempt/4). Check access, preview API support and service health; no response body was logged."
        }
        if ([int] $response.StatusCode -eq 202 -and $Method -eq 'PUT') {
            # Acceptance is not completion; the caller must verify the named resource.
            return $null
        }
        if ([int] $response.StatusCode -notin @(200, 201, 204)) {
            throw "Agent $Method returned unsupported HTTP $([int] $response.StatusCode)."
        }
        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            if ($Method -eq 'GET') { throw 'Agent GET returned an empty response, not a confirmed absent asset.' }
            return $null
        }
        try {
            $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Agent $Method returned invalid JSON; no response body was logged."
        }
        if ($Method -eq 'GET' -and $document -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Agent GET returned an invalid resource envelope, not a confirmed absent asset.'
        }
        return $document
    }
}

function Test-AgentValue {
    [CmdletBinding()]
    param(
        [AllowNull()] $Expected,
        [AllowNull()] $Actual
    )

    if ($null -eq $Expected) { return ($null -eq $Actual) }
    if ($null -eq $Actual) { return $false }
    if ($Expected -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Expected.PSObject.Properties) {
            if ($Actual.PSObject.Properties.Name -notcontains $property.Name) { return $false }
            if (-not (Test-AgentValue $property.Value $Actual.($property.Name))) { return $false }
        }
        return $true
    }
    if ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Expected.Count -ne $Actual.Count) { return $false }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if (-not (Test-AgentValue $Expected[$i] $Actual[$i])) { return $false }
        }
        return $true
    }
    if ($Expected -is [string]) {
        return ($Actual -is [string] -and $Expected -ceq $Actual)
    }
    if ($Expected -is [bool]) {
        return ($Actual -is [bool] -and $Expected -eq $Actual)
    }
    return ($Expected -eq $Actual)
}

function Get-SreAgentAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroup,
        [Parameter(Mandatory = $true)] [string] $WorkspaceId
    )

    $sreAgentRoot = Join-Path $RepositoryRoot 'sre-agent'
    $manifestPath = Join-Path $sreAgentRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "SRE Agent manifest not found: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string] $manifest.owner -cnotmatch '^managed-by:[a-z0-9-]+$') {
        throw 'Invalid SRE Agent manifest ownership marker.'
    }
    $configuredSource = if ($manifest.PSObject.Properties.Name -contains 'sourcePath' -and
        -not [string]::IsNullOrWhiteSpace([string] $manifest.sourcePath)) {
        ([string] $manifest.sourcePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
    }
    else {
        Join-Path 'sample' 'checkout.py'
    }
    $sourcePath = Join-Path $RepositoryRoot $configuredSource
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Sample source snapshot not found: $sourcePath"
    }
    $values = @{
        SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; WorkspaceId = $WorkspaceId
        SourceSha256   = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        SourceContext  = (Get-Content -LiteralPath $sourcePath -Raw).Replace("`r`n", "`n").TrimEnd()
    }
    $supportedKinds = @{
        connectors     = @{ Directory = 'connectors';      Kind = 'connectors';     Type = 'DataConnector'; ManifestFile = 'connector.json' }
        skills         = @{ Directory = 'skills';          Kind = 'skills';         Type = 'Skill';         ManifestFile = 'skill.json' }
        agents         = @{ Directory = 'agents';          Kind = 'agents';         Type = 'ExtendedAgent'; ManifestFile = 'agent.json' }
        scheduledtasks = @{ Directory = 'scheduled-tasks'; Kind = 'scheduledtasks'; Type = 'ScheduledTask'; ManifestFile = 'task.json' }
        hooks          = @{ Directory = 'hooks';           Kind = 'hooks';          Type = 'Hook';          ManifestFile = 'hook.json' }
    }
    $defaultOrder = @('connectors', 'skills', 'agents', 'scheduledtasks', 'hooks')
    $kindSpecs = @()
    if ($manifest.PSObject.Properties.Name -contains 'kinds' -and $null -ne $manifest.kinds) {
        $seenKinds = @{}
        foreach ($entry in @($manifest.kinds)) {
            $kindKey = [string] $entry.kind
            if (-not $supportedKinds.ContainsKey($kindKey) -or $seenKinds.ContainsKey($kindKey)) {
                throw "Invalid or duplicate SRE Agent resource kind '$kindKey' in manifest."
            }
            $expected = $supportedKinds[$kindKey]
            if ([string] $entry.type -cne $expected.Type -or
                [string] $entry.directory -cne $expected.Directory -or
                [string] $entry.manifestFile -cne $expected.ManifestFile) {
                throw "Resource kind '$kindKey' does not match the supported directory, type or manifest file contract."
            }
            $seenKinds[$kindKey] = $true
            $kindSpecs += [pscustomobject] $expected
        }
    }
    else {
        foreach ($kindKey in $defaultOrder) {
            $kindSpecs += [pscustomobject] $supportedKinds[$kindKey]
        }
    }

    $seenAssets = @{}
    $results = @()
    foreach ($spec in $kindSpecs) {
        $kindDirectory = Join-Path $sreAgentRoot $spec.Directory
        if (-not (Test-Path -LiteralPath $kindDirectory -PathType Container)) {
            continue
        }
        if (@(Get-ChildItem -LiteralPath $kindDirectory -File).Count -gt 0) {
            throw "Unexpected file directly under '$($spec.Directory)'; each resource must live in its own subdirectory."
        }
        $resourceDirectories = @(Get-ChildItem -LiteralPath $kindDirectory -Directory | Sort-Object Name)
        foreach ($resourceDir in $resourceDirectories) {
            $resourceManifestPath = Join-Path $resourceDir.FullName $spec.ManifestFile
            if (-not (Test-Path -LiteralPath $resourceManifestPath -PathType Leaf)) {
                throw "Resource directory '$($spec.Directory)/$($resourceDir.Name)' is missing '$($spec.ManifestFile)'."
            }
            $asset = Get-Content -LiteralPath $resourceManifestPath -Raw | ConvertFrom-Json
            $name = [string] $asset.name
            if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}$' -or $name -cne $resourceDir.Name) {
                throw "Resource name '$name' in '$($spec.Directory)/$($resourceDir.Name)' must be lowercase kebab-case and match its directory name."
            }
            if (($asset.PSObject.Properties.Name -contains 'kind' -and [string] $asset.kind -cne $spec.Kind) -or
                [string] $asset.type -cne $spec.Type -or $null -eq $asset.properties) {
                throw "Invalid resource type or properties for '$($spec.Kind)/$name'."
            }
            $assetKey = "$($spec.Kind)/$name"
            if ($seenAssets.ContainsKey($assetKey)) {
                throw "Duplicate resource '$assetKey' in sre-agent tree."
            }
            $seenAssets[$assetKey] = $true

            $contentFiles = @()
            if ($asset.PSObject.Properties.Name -contains 'contentFiles' -and $null -ne $asset.contentFiles) {
                foreach ($property in $asset.contentFiles.PSObject.Properties) {
                    $fileName = [string] $property.Value
                    if ($fileName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*[.](md|txt|json|kql|yaml|yml)$' -or
                        $asset.properties.PSObject.Properties.Name -notcontains $property.Name) {
                        throw "Invalid asset content mapping '$fileName' for '$assetKey'."
                    }
                    $contentPath = Join-Path $resourceDir.FullName $fileName
                    if (-not (Test-Path -LiteralPath $contentPath -PathType Leaf)) {
                        throw "Asset content file not found: $contentPath"
                    }
                    $contentFiles += $fileName
                    $content = (Get-Content -LiteralPath $contentPath -Raw).Replace("`r`n", "`n")
                    foreach ($key in $values.Keys) {
                        $content = $content.Replace("{{$key}}", $values[$key])
                    }
                    if ($content -match '{{[A-Za-z0-9_]+}}') {
                        throw "Unresolved asset template value in '$contentPath'."
                    }
                    $asset.properties.($property.Name) = $content
                }
            }
            if ($spec.Kind -eq 'scheduledtasks') {
                # This preview persists task descriptions/status but drops envelope tags.
                $asset.properties.description += " [$($manifest.owner)]"
            }
            $results += [pscustomobject]@{
                Kind         = $spec.Kind
                Directory    = $spec.Directory
                ManifestFile = $spec.ManifestFile
                ContentFiles = $contentFiles
                Envelope     = [pscustomobject]@{
                    name       = $name
                    type       = $spec.Type
                    tags       = @([string] $manifest.owner)
                    properties = $asset.properties
                }
            }
        }
    }

    if ($results.Count -lt 1) {
        throw 'sre-agent must declare at least one data-plane resource.'
    }
    foreach ($item in $results) {
        if ($item.Kind -eq 'agents' -and
            $item.Envelope.properties.PSObject.Properties.Name -contains 'allowedSkills' -and
            $null -ne $item.Envelope.properties.allowedSkills) {
            foreach ($skillName in @($item.Envelope.properties.allowedSkills)) {
                if (-not $seenAssets.ContainsKey("skills/$skillName")) {
                    throw "Agent '$($item.Envelope.name)' references unknown skill '$skillName'."
                }
            }
        }
        if ($item.Kind -eq 'scheduledtasks' -and
            $item.Envelope.properties.PSObject.Properties.Name -contains 'agent' -and
            -not [string]::IsNullOrWhiteSpace([string] $item.Envelope.properties.agent)) {
            $agentName = [string] $item.Envelope.properties.agent
            if (-not $seenAssets.ContainsKey("agents/$agentName")) {
                throw "Scheduled task '$($item.Envelope.name)' references unknown agent '$agentName'."
            }
        }
    }
    return $results
}

function Get-CheckoutAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroup,
        [Parameter(Mandatory = $true)] [string] $WorkspaceId
    )

    return Get-SreAgentAsset @PSBoundParameters
}

function Test-AgentOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Expected,
        [AllowNull()] $Actual,
        [Parameter(Mandatory = $true)] [string] $Kind
    )

    if ($null -eq $Actual -or $Actual.name -cne $Expected.name -or $Actual.type -cne $Expected.type) {
        return $false
    }
    if ($Kind -eq 'scheduledtasks') {
        return ($Actual.properties.description -is [string] -and
            $Actual.properties.description.EndsWith(" [$($Expected.tags[0])]", [StringComparison]::Ordinal))
    }
    return (@($Actual.tags) -ccontains $Expected.tags[0])
}

function Sync-SreAgentAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Endpoint,
        [Parameter(Mandatory = $true)] [hashtable] $Headers,
        [Parameter(Mandatory = $true)] [object[]] $Assets
    )

    $pending = @()
    foreach ($asset in $Assets) {
        $desired = $asset.Envelope
        $uri = "$Endpoint/api/v2/extendedAgent/$($asset.Kind)/$($desired.name)"
        $existing = Invoke-AgentRequest -Method GET -Uri $uri -Headers $Headers -AllowNotFound
        if ($null -ne $existing) {
            if (-not (Test-AgentOwnership -Expected $desired -Actual $existing -Kind $asset.Kind)) {
                throw "Refusing unmanaged or incompatible $($asset.Kind)/$($desired.name). Verify ownership manually; automatic adoption is not supported."
            }
        }
        $pending += [pscustomobject]@{ Asset = $asset; Uri = $uri; Existing = $existing }
    }
    foreach ($item in $pending) {
        $desired = $item.Asset.Envelope
        $isCurrent = $null -ne $item.Existing -and (Test-AgentValue $desired.properties $item.Existing.properties)
        if ($isCurrent) {
            Write-Output "Unchanged $($item.Asset.Kind)/$($desired.name)"
            continue
        }
        $body = $desired | ConvertTo-Json -Depth 30 -Compress
        $null = Invoke-AgentRequest -Method PUT -Uri $item.Uri -Headers $Headers -Body $body
        $verified = $false
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $actual = Invoke-AgentRequest -Method GET -Uri $item.Uri -Headers $Headers -AllowNotFound
            if ((Test-AgentOwnership -Expected $desired -Actual $actual -Kind $item.Asset.Kind) -and
                (Test-AgentValue $desired.properties $actual.properties)) {
                $verified = $true
                break
            }
            if ($attempt -lt 4) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt)) }
        }
        if (-not $verified) {
            throw "Read-back verification failed for $($item.Asset.Kind)/$($desired.name). Check the current preview schema; deployment is incomplete."
        }
        Write-Output "Configured $($item.Asset.Kind)/$($desired.name)"
    }
}

function Sync-CheckoutAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Endpoint,
        [Parameter(Mandatory = $true)] [hashtable] $Headers,
        [Parameter(Mandatory = $true)] [object[]] $Assets
    )

    Sync-SreAgentAsset @PSBoundParameters
}

function New-SreAgentAssetPackage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        throw 'Asset package destination already exists; supply a clean staging path.'
    }
    $placeholderId = '00000000-0000-0000-0000-000000000000'
    $preview = @(Get-SreAgentAsset -RepositoryRoot $RepositoryRoot `
        -SubscriptionId $placeholderId -ResourceGroup 'rg-sre-checkout-westus3' -WorkspaceId $placeholderId)
    if ($preview.Count -lt 1) {
        throw 'Asset package validation failed to discover any SRE Agent resources.'
    }
    $sourceAgentRoot = Join-Path $RepositoryRoot 'sre-agent'
    $sourceManifestPath = Join-Path $sourceAgentRoot 'manifest.json'
    $targetAgentRoot = Join-Path $DestinationPath 'sre-agent'
    $targetSample = Join-Path $DestinationPath 'sample'
    New-Item -ItemType Directory -Path $targetAgentRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $targetSample -Force | Out-Null
    Copy-Item -LiteralPath $sourceManifestPath -Destination (Join-Path $targetAgentRoot 'manifest.json')
    foreach ($item in $preview) {
        $sourceResourceDir = Join-Path (Join-Path $sourceAgentRoot $item.Directory) $item.Envelope.name
        $targetResourceDir = Join-Path (Join-Path $targetAgentRoot $item.Directory) $item.Envelope.name
        New-Item -ItemType Directory -Path $targetResourceDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceResourceDir $item.ManifestFile) `
            -Destination (Join-Path $targetResourceDir $item.ManifestFile)
        foreach ($fileName in @($item.ContentFiles)) {
            Copy-Item -LiteralPath (Join-Path $sourceResourceDir $fileName) `
                -Destination (Join-Path $targetResourceDir $fileName)
        }
    }
    $sampleSource = Join-Path (Join-Path $RepositoryRoot 'sample') 'checkout.py'
    $stagedSample = Join-Path $targetSample 'checkout.py'
    Copy-Item -LiteralPath $sampleSource -Destination $stagedSample
    $verified = @(Get-SreAgentAsset -RepositoryRoot $DestinationPath `
        -SubscriptionId $placeholderId -ResourceGroup 'rg-sre-checkout-westus3' -WorkspaceId $placeholderId)
    if ($verified.Count -ne $preview.Count) {
        throw 'Staged SRE Agent asset package failed post-copy verification.'
    }
    return [pscustomobject]@{
        PackagePath  = $DestinationPath
        SourceSha256 = (Get-FileHash -LiteralPath $stagedSample -Algorithm SHA256).Hash.ToLowerInvariant()
        AssetNames   = @($verified | ForEach-Object { "$($_.Kind)/$($_.Envelope.name)" })
    }
}

function New-CheckoutAssetPackage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )

    return New-SreAgentAssetPackage @PSBoundParameters
}
