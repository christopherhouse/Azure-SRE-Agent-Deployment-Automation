#Requires -Version 5.1

function Assert-KeylessEnvironment {
    [CmdletBinding()]
    param()

    foreach ($name in @(
        'ARM_ACCESS_KEY', 'ARM_SAS_TOKEN', 'ARM_CLIENT_SECRET',
        'ARM_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE',
        'AZURE_CLIENT_SECRET', 'AZURE_STORAGE_KEY', 'AZURE_STORAGE_CONNECTION_STRING',
        'AZURE_STORAGE_SAS_TOKEN', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init',
        'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_apply'
    )) {
        if ([Environment]::GetEnvironmentVariable($name)) {
            throw "Remove $name from this process before running the keyless bootstrap."
        }
    }
}

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Command,
        [Parameter(Position = 1)]
        [string[]] $Arguments = @()
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Invoke-NativeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Command,
        [Parameter(Position = 1)]
        [string[]] $Arguments = @()
    )

    $text = Invoke-Native $Command $Arguments
    return ($text -join "`n" | ConvertFrom-Json -ErrorAction Stop)
}
