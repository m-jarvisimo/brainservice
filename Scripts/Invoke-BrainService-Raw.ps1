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
#base api structure called by api functions
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
        Uri = $uri
        Method = $Method
        Headers = $Headers
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
#Retrieve and store auth token for future api calls
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
#close authentication session to release NetBeans seat
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

function Get-BrainServiceResultStatus {
    param([Parameter(Mandatory)]$Body)

    if ($Body.PSObject.Properties.Name -contains 'status') { return [string]$Body.status }
    if ($Body.PSObject.Properties.Name -contains 'Status') { return [string]$Body.Status }
    return ''
}

function Get-BrainServiceResultIntents {
    param([Parameter(Mandatory)]$Body)
    if ($Body.PSObject.Properties.Name -contains 'intents' -and $Body.intents) {
        return @($Body.intents)
    }
    return @()
}

function Get-BrainServiceIntentResultId {
    param([Parameter(Mandatory)]$Intent)

    foreach ($name in 'resultId', 'resultID', 'ResultId') {
        if ($Intent.PSObject.Properties.Name -contains $name) {
            $value = $Intent.$name
            if ($value) { return [string]$value }
        }
    }

    return ''
}

function Get-BrainServiceRawResultDatas {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Intent
    )

    $resultId = Get-BrainServiceIntentResultId -Intent $Intent
    if (-not $resultId) {
        return $null
    }

    return Invoke-BrainServiceApi -BaseUrl $Config.NetBrain.BaseUrl -Method Post -Path '/ServicesAPI/API/V3/TAF/Lite/result/datas' -Headers @{ token = $Token } -Body @{
        endpoint   = $Config.NetBrain.TafEndpoint
        niResultId = $resultId
        output     = @(1)
    }
}

$config = Get-BrainServiceRawConfig -Path $ConfigPath
$token = $null
$taskId = $null
$pollHistory = @()
$finalResult = $null
$rawIntentDatas = @()

try {
    $token = Get-BrainServiceToken -Config $config

    if ($config.NetBrain.TenantId -and $config.NetBrain.DomainId) {
        Invoke-BrainServiceApi -BaseUrl $config.NetBrain.BaseUrl -Method Put -Path '/ServicesAPI/API/V1/Session/CurrentDomain' -Headers @{ token = $token } -Body @{
            tenantId = $config.NetBrain.TenantId
            domainId = $config.NetBrain.DomainId
        } | Out-Null
    }

    $runBody = @{
        endpoint = $config.NetBrain.TafEndpoint
        passKey  = $config.NetBrain.TafPasskey
        option   = @{ rawData = $true; dataSource = 0; maxExecuteNIColumn = [int]$config.NetBrain.MaxExecuteNIColumns }
    }

    if ($config.NetBrain.IntentColumns -ne $null) {
        $runBody.intentColumns = @($config.NetBrain.IntentColumns)
    }

    $run = Invoke-BrainServiceApi -BaseUrl $config.NetBrain.BaseUrl -Method Post -Path '/ServicesAPI/API/V3/TAF/Lite/run' -Headers @{ token = $token } -Body $runBody
    if ($run) {
        if ($run.taskId) { $taskId = [string]$run.taskId }
        elseif ($run.taskID) { $taskId = [string]$run.taskID }
        elseif ($run.TaskId) { $taskId = [string]$run.TaskId }
        elseif ($run.TASKID) { $taskId = [string]$run.TASKID }
    }

    if (-not $taskId) {
        throw "TAF Lite run did not return a taskId: $(ConvertTo-PrettyJson $run)"
    }

    $attempts = [int]$config.NetBrain.PollAttempts
    $seconds = [int]$config.NetBrain.PollSeconds
    $needStable = [int]$config.NetBrain.StablePolls
    $stable = 0
    $lastSignature = ''

    for ($i = 0; $i -lt $attempts; $i++) {
        $poll = Invoke-BrainServiceApi -BaseUrl $config.NetBrain.BaseUrl -Method Post -Path '/ServicesAPI/API/V3/TAF/Lite/result' -Headers @{ token = $token } -Body @{
            endpoint = $config.NetBrain.TafEndpoint
            taskId   = $taskId
        }

        $body = $poll
        $status = Get-BrainServiceResultStatus -Body $body
        $intents = @($(Get-BrainServiceResultIntents -Body $body))
        $intentCount = @($intents).Count
        $withId = @($intents | Where-Object { Get-BrainServiceIntentResultId -Intent $_ }).Count
        $signature = '{0}|{1}' -f $intentCount, $withId

        $pollHistory += [pscustomobject]@{
            Poll      = $i + 1
            Status    = $status
            Intents   = $intentCount
            WithId    = $withId
            Signature = $signature
        }

        if ($status -eq '2' -and $withId -eq $intentCount) {
            if ($signature -eq $lastSignature) {
                $stable++
            }
            else {
                $stable = 1
            }
            $lastSignature = $signature

            if ($stable -ge $needStable) {
                $finalResult = $body
                break
            }
        }
        else {
            $stable = 0
            $lastSignature = $signature
        }

        Start-Sleep -Seconds $seconds
    }

    if (-not $finalResult) {
        throw "TAF Lite did not stabilize in $($attempts * $seconds) seconds."
    }

    foreach ($intent in @($finalResult.intents)) {
        $datas = Get-BrainServiceRawResultDatas -Config $config -Token $token -Intent $intent
        $rawIntentDatas += [pscustomobject]@{
            Intent   = $intent
            RawDatas = $datas
        }
    }

    $output = [pscustomobject]@{
        TaskId        = $taskId
        Status        = (Get-BrainServiceResultStatus -Body $finalResult)
        PollHistory   = $pollHistory
        FinalResult   = $finalResult
        IntentResults = $rawIntentDatas
    }

    $json = ConvertTo-PrettyJson $output
    $json

    if ($WriteJsonFile -or ($config.Output.WriteJsonFile -eq $true)) {
        $outDir = $config.Output.Directory
        if ($outDir) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            $outFile = Join-Path $outDir ("brainservice-raw-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Set-Content -LiteralPath $outFile -Value $json -Encoding UTF8
            Write-Host "Saved raw output to $outFile"
        }
    }
}
finally {
    if ($token) {
        Stop-BrainServiceToken -BaseUrl $config.NetBrain.BaseUrl -Token $token
    }
}
