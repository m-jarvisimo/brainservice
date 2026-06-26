[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,
    [Parameter()]
    [switch]$WriteJsonFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
    $scriptPath = $MyInvocation.MyCommand.Path
}

$scriptRoot = Split-Path -Parent $scriptPath
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptRoot '..\Config\brainservice.raw.config.json'
}

function ConvertTo-PrettyJson {
    param([Parameter(Mandatory)]$InputObject)
    return ($InputObject | ConvertTo-Json -Depth 30)
}

function Get-BrainServiceRawConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-BrainServiceApi {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Get','Post','Put','Delete')][string]$Method,
        [Parameter()][hashtable]$Headers = @{},
        [Parameter()][object]$Body
    )

    $uri = $BaseUrl.TrimEnd('/') + $Path
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 30)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        throw "HTTP $Method $uri failed: $($_.Exception.Message)"
    }
}

function Get-BrainServiceToken {
    param([Parameter(Mandatory)]$Config)

    $login = Invoke-BrainServiceApi -BaseUrl $Config.NetBrain.BaseUrl -Method Post -Path '/ServicesAPI/API/V1/Session' -Body @{
        username = $Config.NetBrain.Username
        password = $Config.NetBrain.Password
    }

    if ($login.token) { return $login.token }
    if ($login.Token) { return $login.Token }

    throw "NetBrain login did not return a token: $(ConvertTo-PrettyJson $login)"
}

function Stop-BrainServiceToken {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token
    )

    try {
        Invoke-BrainServiceApi -BaseUrl $BaseUrl -Method Delete -Path '/ServicesAPI/API/V1/Session' -Headers @{ token = $Token } | Out-Null
    }
    catch {
        Write-Warning "Logout failed: $($_.Exception.Message)"
    }
}

function Get-BrainServiceAdtData {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Token
    )

    $body = @{
        endpoint = $Config.NetBrain.TafEndpoint
        passKey  = $Config.NetBrain.TafPasskey
    }

    if ($Config.NetBrain.PSObject.Properties.Name -contains 'AdtColumns' -and $null -ne $Config.NetBrain.AdtColumns) {
        $body.columns = @($Config.NetBrain.AdtColumns)
    }

    if ($Config.NetBrain.PSObject.Properties.Name -contains 'AdtFilterDevices' -and $null -ne $Config.NetBrain.AdtFilterDevices) {
        $body.filterDevices = @($Config.NetBrain.AdtFilterDevices)
    }

    if ($Config.NetBrain.PSObject.Properties.Name -contains 'AdtOptions' -and $null -ne $Config.NetBrain.AdtOptions) {
        $body.option = $Config.NetBrain.AdtOptions
    }

    return Invoke-BrainServiceApi -BaseUrl $Config.NetBrain.BaseUrl -Method Post -Path '/ServicesAPI/API/V3/TAF/Lite/adt/data' -Headers @{ token = $Token } -Body $body
}

$config = Get-BrainServiceRawConfig -Path $ConfigPath
$token = $null
$adtData = $null

try {
    $token = Get-BrainServiceToken -Config $config

    if ($config.NetBrain.TenantId -and $config.NetBrain.DomainId) {
        Invoke-BrainServiceApi -BaseUrl $config.NetBrain.BaseUrl -Method Put -Path '/ServicesAPI/API/V1/Session/CurrentDomain' -Headers @{ token = $token } -Body @{
            tenantId = $config.NetBrain.TenantId
            domainId = $config.NetBrain.DomainId
        } | Out-Null
    }

    $adtData = Get-BrainServiceAdtData -Config $config -Token $token
    $json = ConvertTo-PrettyJson $adtData
    $json

    if ($WriteJsonFile -or ($config.Output.WriteJsonFile -eq $true)) {
        $outDir = $config.Output.Directory
        if ($outDir) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            $outFile = Join-Path $outDir ("brainservice-adt-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Set-Content -LiteralPath $outFile -Value $json -Encoding UTF8
            Write-Host "Saved ADT data to $outFile"
        }
    }
}
finally {
    if ($token) {
        Stop-BrainServiceToken -BaseUrl $config.NetBrain.BaseUrl -Token $token
    }
}
