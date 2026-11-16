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

function Get-CheckoutAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $ResourceGroup,
        [Parameter(Mandatory = $true)] [string] $WorkspaceId
    )

    $directory = Join-Path (Join-Path $RepositoryRoot 'assets') 'checkout'
    $manifest = Get-Content -LiteralPath (Join-Path $directory 'assets.json') -Raw | ConvertFrom-Json
    if ($manifest.owner -cne 'managed-by:checkout-reliability-lab' -or @($manifest.assets).Count -ne 3) {
        throw 'Invalid checkout asset manifest ownership or asset count.'
    }
    $sourcePath = Join-Path (Join-Path $RepositoryRoot 'sample') 'checkout.py'
    $values = @{
        SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; WorkspaceId = $WorkspaceId
        SourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        SourceContext = (Get-Content -LiteralPath $sourcePath -Raw).Replace("`r`n", "`n").TrimEnd()
    }
    $seen = @{}
    foreach ($asset in $manifest.assets) {
        $types = @{ skills = 'Skill'; agents = 'ExtendedAgent'; scheduledtasks = 'ScheduledTask' }
        if (-not $types.ContainsKey($asset.kind) -or $types[$asset.kind] -cne $asset.type -or
            $asset.name -cnotmatch '^checkout-[a-z0-9-]+$' -or $seen.ContainsKey($asset.kind)) {
            throw 'Invalid or duplicate checkout asset kind, type or name.'
        }
        $seen[$asset.kind] = $true
        foreach ($property in $asset.contentFiles.PSObject.Properties) {
            if ($property.Value -cnotmatch '^[a-z-]+[.]md$' -or
                $asset.properties.PSObject.Properties.Name -notcontains $property.Name) {
                throw 'Invalid asset content mapping.'
            }
            $content = (Get-Content -LiteralPath (Join-Path $directory $property.Value) -Raw).Replace("`r`n", "`n")
            foreach ($key in $values.Keys) {
                $content = $content.Replace("{{$key}}", $values[$key])
            }
            if ($content -match '{{[A-Za-z]+}}') { throw 'Unresolved asset template value.' }
            $asset.properties.($property.Name) = $content
        }
        if ($asset.kind -eq 'scheduledtasks') {
            # This preview persists task descriptions/status but drops envelope tags.
            $asset.properties.description += " [$($manifest.owner)]"
        }
        [pscustomobject]@{
            Kind = $asset.kind
            Envelope = [pscustomobject]@{
                name = $asset.name; type = $asset.type; tags = @($manifest.owner)
                properties = $asset.properties
            }
        }
    }
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

function Sync-CheckoutAsset {
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

function New-CheckoutAssetPackage {
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
    $preview = @(Get-CheckoutAsset -RepositoryRoot $RepositoryRoot `
        -SubscriptionId $placeholderId -ResourceGroup 'rg-sre-checkout-westus3' -WorkspaceId $placeholderId)
    if ($preview.Count -ne 3) {
        throw 'Asset package validation failed to produce the expected three checkout assets.'
    }
    $sourceAssets = Join-Path (Join-Path $RepositoryRoot 'assets') 'checkout'
    $sourceManifestPath = Join-Path $sourceAssets 'assets.json'
    $manifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
    $targetAssets = Join-Path (Join-Path $DestinationPath 'assets') 'checkout'
    $targetSample = Join-Path $DestinationPath 'sample'
    New-Item -ItemType Directory -Path $targetAssets -Force | Out-Null
    New-Item -ItemType Directory -Path $targetSample -Force | Out-Null
    Copy-Item -LiteralPath $sourceManifestPath -Destination (Join-Path $targetAssets 'assets.json')
    foreach ($asset in $manifest.assets) {
        foreach ($property in $asset.contentFiles.PSObject.Properties) {
            $fileName = [string] $property.Value
            Copy-Item -LiteralPath (Join-Path $sourceAssets $fileName) -Destination (Join-Path $targetAssets $fileName)
        }
    }
    $sampleSource = Join-Path (Join-Path $RepositoryRoot 'sample') 'checkout.py'
    $stagedSample = Join-Path $targetSample 'checkout.py'
    Copy-Item -LiteralPath $sampleSource -Destination $stagedSample
    $verified = @(Get-CheckoutAsset -RepositoryRoot $DestinationPath `
        -SubscriptionId $placeholderId -ResourceGroup 'rg-sre-checkout-westus3' -WorkspaceId $placeholderId)
    if ($verified.Count -ne 3) {
        throw 'Staged checkout asset package failed post-copy verification.'
    }
    return [pscustomobject]@{
        PackagePath  = $DestinationPath
        SourceSha256 = (Get-FileHash -LiteralPath $stagedSample -Algorithm SHA256).Hash.ToLowerInvariant()
        AssetNames   = @($verified | ForEach-Object { "$($_.Kind)/$($_.Envelope.name)" })
    }
}
