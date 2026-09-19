<#
.SYNOPSIS
    Keeps a local service and its public tunnel alive on Windows.

.DESCRIPTION
    Services die. So do tunnels. And when a tunnel dies, anything that was told the
    old public URL (a webhook provider, a chat platform, an OAuth callback) silently
    stops working, because the service that has to re-register the URL is still
    running with the old one.

    This watchdog repairs exactly that, on a schedule:

      * service not running            -> does nothing (no surprise autostart)
      * tunnel process gone            -> start a new tunnel, read the new public URL,
                                          restart the service with that URL in an
                                          environment variable, log it
      * tunnel process alive but the
        public URL does not answer     -> restart tunnel + service
      * everything healthy             -> log one line and exit

    It is deliberately boring: no daemon, no registry, no background loop - one scan
    per scheduled-task run, every decision written to a log, a file-based off switch,
    and an anti-flapping guard so a broken network cannot cause restart storms.

.PARAMETER Config
    JSON config file. Defaults to watchdog-config.json next to this script; any key
    you omit falls back to the built-in defaults shown in config.example.json.

.PARAMETER DryRun
    Report what would be done without touching any process.

.PARAMETER Verbose
    Also print the decisions to the console.

.EXAMPLE
    .\watchdog.ps1 -DryRun -Verbose

.EXAMPLE
    .\watchdog.ps1 -Config C:\my-service\watchdog-config.json

.NOTES
    Windows PowerShell 5.1 and PowerShell 7. No admin rights required to run;
    registering a scheduled task may need one on locked-down machines.
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'

# Reusable helper files get copied around, so never trust $PSScriptRoot inside
# param() defaults - it is not populated while they are evaluated.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Config) { $Config = Join-Path $scriptDir 'watchdog-config.json' }

# ------------------------------------------------------------------ defaults
$defaults = [ordered]@{
    logFile                   = (Join-Path $scriptDir 'watchdog.log')
    urlFile                   = (Join-Path $scriptDir 'public-url.txt')
    offSwitch                 = 'watchdog-off.txt'
    minMinutesBetweenRestarts = 8
    urlWaitSeconds            = 60
    bootWaitSeconds           = 90
    healthTimeoutSeconds      = 20
    service                   = [ordered]@{
        port      = 5678
        launcher  = ''
        args      = @()
        urlEnvVar = 'SERVICE_PUBLIC_URL'
    }
    tunnel                    = [ordered]@{
        exe         = 'cloudflared.exe'
        args        = @('tunnel', '--url', 'http://localhost:{port}', '--protocol', 'http2',
                        '--no-autoupdate', '--logfile', '{logfile}')
        processName = 'cloudflared'
        urlPattern  = 'https://[a-z0-9-]+\.trycloudflare\.com'
        logFile     = (Join-Path $scriptDir 'tunnel.log')
    }
}

# ------------------------------------------------------------------ config load
# NOTE: this function MUTATES its first argument and returns nothing on purpose.
# `return $dictionary` would be unrolled by PowerShell into an array of entries, so
# the caller would end up with an array instead of a dictionary ("Cannot index into
# a null array" further down). Dictionaries are reference types: mutate in place.
function Merge-Config($base, $override) {
    foreach ($p in @($override.PSObject.Properties)) {
        if ($null -eq $p.Value) { continue }
        $existing = $base[$p.Name]
        if ($existing -is [System.Collections.IDictionary] -and
            $p.Value -is [psobject] -and
            -not ($p.Value -is [string]) -and
            -not ($p.Value -is [array]) -and
            $p.Value.PSObject.Properties.Count -gt 0) {
            Merge-Config $existing $p.Value
        } else {
            $base[$p.Name] = $p.Value
        }
    }
}

$cfg = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($k in @($defaults.Keys)) {
    if ($defaults[$k] -is [System.Collections.IDictionary]) {
        $inner = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($ik in @($defaults[$k].Keys)) { $inner[$ik] = $defaults[$k][$ik] }
        $cfg[$k] = $inner
    } else {
        $cfg[$k] = $defaults[$k]
    }
}

if (Test-Path -LiteralPath $Config) {
    try {
        $user = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        Merge-Config $cfg $user      # mutates $cfg in place (see note above)
    } catch {
        Write-Warning "Could not read config '$Config': $($_.Exception.Message). Using defaults."
    }
} else {
    Write-Warning "Config '$Config' not found - using built-in defaults."
}

# A path that contains a control character is always a config mistake - the classic
# cause is a JSON round-trip where "D:\\Tools\\n8n\\x.log" lost one level of escaping
# and "\n" became a real newline. Such a path makes Add-Content (and the tunnel's own
# --logfile) fail silently, so fall back to a sane default and say so.
function Repair-Path([object]$value, [string]$fallback, [string]$name) {
    if ($null -eq $value -or [string]$value -eq '') { return $fallback }
    $v = [string]$value
    if ($v -match '[\r\n\t]') {
        Write-Warning ("config '$name' contains a control character (check JSON escaping) - using '$fallback' instead")
        return $fallback
    }
    return $v
}

$serviceCfg = $cfg['service']
$tunnelCfg  = $cfg['tunnel']
$logPath    = Repair-Path $cfg['logFile']  (Join-Path $scriptDir 'watchdog.log')    'logFile'
$cfg['urlFile'] = Repair-Path $cfg['urlFile'] (Join-Path $scriptDir 'public-url.txt') 'urlFile'
$offPath    = Repair-Path $cfg['offSwitch'] (Join-Path $scriptDir 'watchdog-off.txt') 'offSwitch'
if (-not [System.IO.Path]::IsPathRooted($offPath)) { $offPath = Join-Path $scriptDir $offPath }
$tunnelLog  = Repair-Path $tunnelCfg['logFile'] (Join-Path $scriptDir 'tunnel.log')  'tunnel.logFile'
if (-not [System.IO.Path]::IsPathRooted($tunnelLog)) { $tunnelLog = Join-Path $scriptDir $tunnelLog }
$tunnelCfg['logFile'] = $tunnelLog

function Write-Log([string]$m) {
    if ($VerbosePreference -ne 'SilentlyContinue') { Write-Verbose $m }
    $dir = Split-Path -Parent $logPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 204800)) {
        Get-Content -LiteralPath $logPath -Tail 200 | Set-Content -LiteralPath $logPath
    }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -LiteralPath $logPath -Encoding UTF8
}

if (Test-Path -LiteralPath $offPath) { Write-Log "watchdog is switched off ($offPath)"; exit 0 }

# ------------------------------------------------------------------ helpers
function Get-ServicePid {
    # Get-NetTCPConnection raises a CIM error when nothing listens; a caller running
    # with $ErrorActionPreference='Stop' must not die on the "service is down" path.
    try {
        $conn = Get-NetTCPConnection -LocalPort ([int]$serviceCfg['port']) -State Listen -ErrorAction Stop |
                Select-Object -First 1
        if ($conn) { return [int]$conn.OwningProcess }
    } catch { }
    return $null
}
function Get-TunnelProcess {
    Get-Process $tunnelCfg['processName'] -ErrorAction SilentlyContinue | Select-Object -First 1
}
function Get-TunnelUrl {
    $m = Select-String -LiteralPath $tunnelLog -Pattern $tunnelCfg['urlPattern'] -ErrorAction SilentlyContinue
    if (-not $m) { return $null }
    return $m[-1].Matches[0].Value
}
function Expand-Args([object[]]$list, [string]$url) {
    $port = [string]$serviceCfg['port']
    $out = @()
    foreach ($a in @($list)) {
        $out += ([string]$a).Replace('{port}', $port).Replace('{logfile}', $tunnelLog).Replace('{url}', [string]$url)
    }
    return $out
}
function Start-Tunnel {
    if (Test-Path -LiteralPath $tunnelLog) { Remove-Item -LiteralPath $tunnelLog -Force }
    $tunnelArgs = @(Expand-Args $tunnelCfg['args'] $null)
    if ($DryRun) { Write-Log "DRY-RUN would start tunnel: $($tunnelCfg['exe']) $($tunnelArgs -join ' ')"; return 'dry-run-url' }
    # Start-Process rejects an empty -ArgumentList, so only pass it when there is one
    if ($tunnelArgs.Count -gt 0) {
        Start-Process -FilePath $tunnelCfg['exe'] -ArgumentList $tunnelArgs -WindowStyle Hidden | Out-Null
    } else {
        Start-Process -FilePath $tunnelCfg['exe'] -WindowStyle Hidden | Out-Null
    }
    for ($i = 0; $i -lt [math]::Ceiling([int]$cfg['urlWaitSeconds'] / 3); $i++) {
        Start-Sleep -Seconds 3
        $u = Get-TunnelUrl
        if ($u) { return $u }
    }
    return $null
}
function Restart-Service([string]$url) {
    $svcPid = Get-ServicePid
    if ($DryRun) { Write-Log "DRY-RUN would restart the service with $($serviceCfg['urlEnvVar'])=$url"; return }
    if ($svcPid) { Stop-Process -Id $svcPid -Force }
    Start-Sleep -Seconds 4
    if ($serviceCfg['urlEnvVar']) { Set-Item -Path ("env:" + $serviceCfg['urlEnvVar']) -Value $url }
    $svcArgs = @(Expand-Args $serviceCfg['args'] $url)
    if ($svcArgs.Count -gt 0) {
        Start-Process -FilePath $serviceCfg['launcher'] -ArgumentList $svcArgs -WindowStyle Minimized | Out-Null
    } else {
        Start-Process -FilePath $serviceCfg['launcher'] -WindowStyle Minimized | Out-Null
    }
    for ($i = 0; $i -lt [math]::Ceiling([int]$cfg['bootWaitSeconds'] / 5); $i++) {
        Start-Sleep -Seconds 5
        if (Get-ServicePid) { break }
    }
}
function Get-HttpStatus([string]$uri) {
    # 0 means "no HTTP response at all" (connection refused / DNS / TLS failure).
    try {
        $r = Invoke-WebRequest -Uri $uri -TimeoutSec ([int]$cfg['healthTimeoutSeconds']) -UseBasicParsing
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}
function Test-TunnelHealthy([string]$url) {
    # A tunnel is only useful if the OUTSIDE can reach the service through it:
    #   * no response at all          -> broken
    #   * an edge 5xx while the local  -> broken (the tunnel/edge is up but not
    #     service answers fine            connected; a stale URL looks like this)
    # A 404 is NOT broken: the service may still be booting.
    if (-not $url) { return $false }
    $path = [string]$serviceCfg['healthPath']
    if (-not $path) { $path = '/' }
    $local = Get-HttpStatus ("http://127.0.0.1:" + $serviceCfg['port'] + $path)
    $public = Get-HttpStatus ($url.TrimEnd('/') + $path)
    if ($public -eq 0) { return $false }
    if ($public -ge 500 -and $local -gt 0 -and $local -lt 500) { return $false }
    return $true
}
function TooSoonToRestart {
    if (-not (Test-Path -LiteralPath $logPath)) { return $false }
    $stamp = Select-String -LiteralPath $logPath -Pattern '\(restarting\)' -ErrorAction SilentlyContinue
    if (-not $stamp) { return $false }
    $last = $stamp[-1].Line -replace '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*', '$1'
    try { $when = [datetime]::ParseExact($last, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return $false }
    return (((Get-Date) - $when).TotalMinutes -lt [int]$cfg['minMinutesBetweenRestarts'])
}

# ------------------------------------------------------------------ the scan
if (-not $serviceCfg['launcher']) {
    Write-Log 'no service.launcher configured - nothing to watch'
    exit 0
}

$svc = Get-ServicePid
if (-not $svc) { Write-Log 'service is not running - nothing to watch (no autostart by design)'; exit 0 }

$tunnel = Get-TunnelProcess
$url = Get-TunnelUrl

if (-not $tunnel) {
    if (TooSoonToRestart) { Write-Log 'tunnel missing but a restart happened recently - waiting'; exit 0 }
    Write-Log 'tunnel process is gone - restarting tunnel + service (restarting)'
    $newUrl = Start-Tunnel
    if (-not $newUrl) { Write-Log 'could not obtain a tunnel URL - giving up this round'; exit 1 }
    if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $newUrl -Encoding ASCII }
    Restart-Service $newUrl
    Write-Log "repaired: tunnel $newUrl, service restarted"
    exit 0
}

# a tunnel that is still connecting has no URL in its log yet - that is not a fault
if (-not $url) {
    Write-Log "tunnel process is running but has not announced a URL yet - waiting"
    exit 0
}

if (-not (Test-TunnelHealthy $url)) {
    if (TooSoonToRestart) { Write-Log 'tunnel unreachable but a restart happened recently - waiting'; exit 0 }
    Write-Log "tunnel process runs but $url does not answer - restarting tunnel + service (restarting)"
    if (-not $DryRun) { Get-Process $tunnelCfg['processName'] -ErrorAction SilentlyContinue | Stop-Process -Force }
    $newUrl = Start-Tunnel
    if (-not $newUrl) { Write-Log 'could not obtain a tunnel URL - giving up this round'; exit 1 }
    if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $newUrl -Encoding ASCII }
    Restart-Service $newUrl
    Write-Log "repaired: tunnel $newUrl, service restarted"
    exit 0
}

Write-Log "healthy: service pid $svc, tunnel $url"
exit 0