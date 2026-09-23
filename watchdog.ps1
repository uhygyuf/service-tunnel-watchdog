<#
.SYNOPSIS
    Keeps a local service and its public tunnel alive on Windows.

.DESCRIPTION
    Services die. So do tunnels. And when a tunnel dies, anything that was told the
    old public URL (a webhook provider, a chat platform, an OAuth callback) silently
    stops working, because the service that has to re-register the URL is still
    running with the old one.

    This watchdog repairs exactly that, on a schedule:

      * service not running            -> does nothing by default (no surprise autostart);
                                          with `autoStart: true` it starts the service
                                          again (and the tunnel, if that is gone too)
      * tunnel process gone            -> start a new tunnel, read the new public URL,
                                          restart the service with that URL in an
                                          environment variable, log it
      * tunnel process alive but the
        public URL does not answer     -> restart tunnel + service
      * everything healthy             -> log one line and exit

    A tunnel restart usually means a NEW public URL, and anything that was told the old
    one (a webhook provider, a hosted page with the address baked into a file, an OAuth
    callback) keeps using the dead address. So the watchdog can also run a `hook`: one
    command of yours, given the current URL, run after a repair and again on any scan
    where the URL differs from the last one the hook succeeded with. Failed or timed-out
    hook runs are retried on the next scan.

    It is deliberately boring: no daemon, no registry, no background loop - one scan
    per scheduled-task run, every decision written to a log, a file-based off switch,
    and an anti-flapping guard so a broken network cannot cause restart storms.

    `autoStart` is about crash recovery, not about starting at Windows boot: the script
    only runs when the scheduled task runs, which is exactly why it can be enabled
    without turning the machine into a service host.

    Alerts are sent by this script itself, straight to the Telegram Bot API - never
    through the service it watches, because a dead service cannot report its own death.
    The bot token lives in a separate secrets file (not in the shareable config) and is
    never written to the log.

.PARAMETER Config
    JSON config file. Defaults to watchdog-config.json next to this script; any key
    you omit falls back to the built-in defaults shown in config.example.json.

.PARAMETER DryRun
    Report what would be done without touching any process (and without sending alerts).

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
    autoStart                 = $false
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
    notify                    = [ordered]@{
        enabled       = $false
        apiBase       = 'https://api.telegram.org'
        botToken      = ''
        chatId        = ''
        secretsFile   = (Join-Path $scriptDir 'watchdog-secrets.json')
        remindMinutes = 60
    }
    hook                      = [ordered]@{
        enabled        = $false
        command        = ''
        args           = @()
        stateFile      = 'hook-state.txt'
        timeoutSeconds = 120
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
$notifyCfg  = $cfg['notify']
$logPath    = Repair-Path $cfg['logFile']  (Join-Path $scriptDir 'watchdog.log')    'logFile'
$cfg['urlFile'] = Repair-Path $cfg['urlFile'] (Join-Path $scriptDir 'public-url.txt') 'urlFile'
$offPath    = Repair-Path $cfg['offSwitch'] (Join-Path $scriptDir 'watchdog-off.txt') 'offSwitch'
if (-not [System.IO.Path]::IsPathRooted($offPath)) { $offPath = Join-Path $scriptDir $offPath }
$tunnelLog  = Repair-Path $tunnelCfg['logFile'] (Join-Path $scriptDir 'tunnel.log')  'tunnel.logFile'
if (-not [System.IO.Path]::IsPathRooted($tunnelLog)) { $tunnelLog = Join-Path $scriptDir $tunnelLog }
$tunnelCfg['logFile'] = $tunnelLog
$notifyCfg['secretsFile'] = Repair-Path $notifyCfg['secretsFile'] (Join-Path $scriptDir 'watchdog-secrets.json') 'notify.secretsFile'
if (-not [System.IO.Path]::IsPathRooted([string]$notifyCfg['secretsFile'])) {
    $notifyCfg['secretsFile'] = Join-Path $scriptDir ([string]$notifyCfg['secretsFile'])
}
$hookCfg = $cfg['hook']
if (-not $hookCfg['waitForServiceSeconds']) { $hookCfg['waitForServiceSeconds'] = $cfg['bootWaitSeconds'] }
if (-not $hookCfg['attempts']) { $hookCfg['attempts'] = 3 }
if (-not $hookCfg['retrySeconds']) { $hookCfg['retrySeconds'] = 20 }
if (-not $cfg['tunnelAnswerWaitSeconds']) { $cfg['tunnelAnswerWaitSeconds'] = 90 }
$hookCfg['stateFile'] = Repair-Path $hookCfg['stateFile'] (Join-Path $scriptDir 'hook-state.txt') 'hook.stateFile'
if (-not [System.IO.Path]::IsPathRooted([string]$hookCfg['stateFile'])) {
    $hookCfg['stateFile'] = Join-Path $scriptDir ([string]$hookCfg['stateFile'])
}
$hookStatePath = [string]$hookCfg['stateFile']

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
function Start-ServiceProcess([string]$url) {
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
function Restart-Service([string]$url) {
    $svcPid = Get-ServicePid
    if ($DryRun) { Write-Log "DRY-RUN would restart the service with $($serviceCfg['urlEnvVar'])=$url"; return }
    if ($svcPid) { Stop-Process -Id $svcPid -Force }
    Start-Sleep -Seconds 4
    Start-ServiceProcess $url
}
function Test-HookNeeded([string]$url) {
    # The hook exists to re-register a URL that changed, so run it when the URL differs
    # from the one the last successful run was given. State is only written after a run
    # that exited 0, which is what makes a failure retry on the next scan.
    if (-not $hookCfg['enabled'] -or -not $hookCfg['command'] -or -not $url) { return $false }
    if (Test-Path -LiteralPath $hookStatePath) {
        $last = (Get-Content -LiteralPath $hookStatePath -Raw).Trim()
        if ($last -eq $url) { return $false }
    }
    return $true
}
function Invoke-Hook([string]$url) {
    $hargs = @(Expand-Args $hookCfg['args'] $url)
    if ($DryRun) { Write-Log "DRY-RUN would run hook: $($hookCfg['command']) $($hargs -join ' ')"; return }
    try {
        if ($hargs.Count -gt 0) {
            $p = Start-Process -FilePath $hookCfg['command'] -ArgumentList $hargs -NoNewWindow -PassThru
        } else {
            $p = Start-Process -FilePath $hookCfg['command'] -NoNewWindow -PassThru
        }
        $p | Wait-Process -Timeout ([int]$hookCfg['timeoutSeconds']) -ErrorAction SilentlyContinue
        if (-not $p.HasExited) {
            Stop-Process -Id $p.Id -Force
            Write-Log "hook did not finish within $($hookCfg['timeoutSeconds'])s - killed, will retry next scan"
            return
        }
        if ($p.ExitCode -eq 0) {
            Write-Log "hook finished OK for $url"
            Set-Content -LiteralPath $hookStatePath -Value $url -Encoding ASCII
        } else {
            Write-Log "hook exited $($p.ExitCode) for $url - will retry next scan"
        }
    } catch {
        Write-Log "hook could not run: $($_.Exception.Message)"
    }
}
function Stop-TunnelProcesses {
    # A second client started while the first one still holds the connection announces a URL
    # and then dies, and that phantom address is worse than no address at all. Wait for the
    # process to really go away before starting its replacement.
    $name = [string]$tunnelCfg['processName']
    if (-not $name) { return }
    Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 10; $i++) {
        if (-not (Get-Process $name -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 1
    }
    Write-Log "the old $name process is still around after 10s - starting the replacement anyway"
}
function Publish-IfNeeded([string]$url) {
    if (-not (Test-HookNeeded $url)) { return }
    if ($DryRun) { Invoke-Hook $url; return }   # Invoke-Hook reports what it would do
    $wait = [int]$hookCfg['waitForServiceSeconds']
    if ($wait -gt 0 -and -not (Wait-ServiceThroughTunnel $url $wait)) {
        # The hook checks the address from the public side. Running it while the service is
        # still booting behind the tunnel fails for a reason that has nothing to do with the
        # address, and the next chance is a whole scan away - so wait here instead.
        Write-Log "service is not answering through $url yet - running the hook anyway (best effort)"
    }
    $attempts = [int]$hookCfg['attempts']
    if ($attempts -lt 1) { $attempts = 1 }
    for ($i = 1; $i -le $attempts; $i++) {
        Invoke-Hook $url
        # Invoke-Hook only writes the state file after a run that exited 0, so the state file
        # holding this URL is exactly "the address was published".
        $last = ''
        if (Test-Path -LiteralPath $hookStatePath) { $last = (Get-Content -LiteralPath $hookStatePath -Raw).Trim() }
        if ($last -eq $url) {
            if ($i -gt 1) { Write-Log "hook succeeded on attempt $i for $url" }
            return
        }
        if ($i -lt $attempts) {
            Write-Log "hook attempt $i for $url failed - retrying in $([int]$hookCfg['retrySeconds'])s"
            Start-Sleep -Seconds ([int]$hookCfg['retrySeconds'])
        }
    }
    Write-Log "hook did not succeed for $url after $attempts attempts - will retry next scan"
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
function Test-TunnelAnswer([string]$url) {
    # Does the Cloudflare edge answer for this address AT ALL? Any status counts: a 502/530
    # means the tunnel exists and the origin behind it is the problem, which is a different
    # fault from an address that has gone away (no response at all).
    if (-not $url) { return $false }
    return ((Get-HttpStatus $url.TrimEnd('/')) -ne 0)
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
function Wait-TunnelAnswer([string]$url, [int]$seconds) {
    for ($i = 0; $i -lt [math]::Ceiling($seconds / 3); $i++) {
        if (Test-TunnelAnswer $url) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}
function Wait-ServiceThroughTunnel([string]$url, [int]$seconds) {
    # The hook re-checks the address from the public side, so running it while the service is
    # still booting behind the tunnel only burns a whole scan interval. Wait for the service
    # first, then let the hook do its job.
    for ($i = 0; $i -lt [math]::Ceiling($seconds / 5); $i++) {
        if (Test-TunnelHealthy $url) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}
function TooSoonToRestart {
    if (-not (Test-Path -LiteralPath $logPath)) { return $false }
    $stamp = Select-String -LiteralPath $logPath -Pattern '\(restarting\)' -ErrorAction SilentlyContinue
    if (-not $stamp) { return $false }
    $last = $stamp[-1].Line -replace '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*', '$1'
    try { $when = [datetime]::ParseExact($last, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return $false }
    return (((Get-Date) - $when).TotalMinutes -lt [int]$cfg['minMinutesBetweenRestarts'])
}

# ------------------------------------------------------------------ alerting
# The alert goes out from THIS script, not through the watched service: a dead
# service cannot report its own death. Credentials are read from a separate file so
# the config stays shareable, and they are never written to the log.
function Get-NotifyCredentials {
    $token = [string]$notifyCfg['botToken']
    $chat  = [string]$notifyCfg['chatId']
    $sf = [string]$notifyCfg['secretsFile']
    if ($sf -and (Test-Path -LiteralPath $sf)) {
        try {
            $sec = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
            if ($sec.botToken) { $token = [string]$sec.botToken }
            if ($sec.chatId)   { $chat  = [string]$sec.chatId }
        } catch {
            Write-Log "could not read notify.secretsFile - alerting degraded: $($_.Exception.Message)"
        }
    }
    return [ordered]@{ token = $token; chat = $chat }
}
function TooSoonToAlert {
    if (-not (Test-Path -LiteralPath $logPath)) { return $false }
    $stamp = Select-String -LiteralPath $logPath -Pattern '\(alert sent\)' -ErrorAction SilentlyContinue
    if (-not $stamp) { return $false }
    $last = $stamp[-1].Line -replace '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*', '$1'
    try { $when = [datetime]::ParseExact($last, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return $false }
    return (((Get-Date) - $when).TotalMinutes -lt [int]$notifyCfg['remindMinutes'])
}
function Send-Alert([string]$text) {
    if (-not $notifyCfg['enabled']) { return }
    if (TooSoonToAlert) {
        Write-Log "alert suppressed (another one went out less than $($notifyCfg['remindMinutes']) min ago)"
        return
    }
    $c = Get-NotifyCredentials
    if (-not $c.token -or -not $c.chat) {
        Write-Log 'alert NOT sent - no bot token / chat id configured'
        return
    }
    if ($DryRun) { Write-Log "DRY-RUN would send alert: $text"; return }
    $base = [string]$notifyCfg['apiBase']
    if (-not $base) { $base = 'https://api.telegram.org' }
    $uri = $base.TrimEnd('/') + '/bot' + $c.token + '/sendMessage'
    try {
        $r = Invoke-RestMethod -Uri $uri -Method Post -TimeoutSec ([int]$cfg['healthTimeoutSeconds']) `
             -Body @{ chat_id = $c.chat; text = $text; disable_web_page_preview = $true }
        $mid = $null
        if ($r -and $r.result) { $mid = $r.result.message_id }
        Write-Log "alert sent (alert sent) message_id $mid"
    } catch {
        Write-Log "alert FAILED - nothing delivered: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ the scan
if (-not $serviceCfg['launcher']) {
    Write-Log 'no service.launcher configured - nothing to watch'
    exit 0
}

$svc = Get-ServicePid
if (-not $svc) {
    if (-not $cfg['autoStart']) {
        Write-Log 'service is not running - autoStart is off, nothing to watch'
        Send-Alert ("[watchdog] the service on port " + $serviceCfg['port'] + " is DOWN and autoStart is off - nothing will start it")
        exit 0
    }
    if (TooSoonToRestart) {
        Write-Log 'service is down but a restart happened recently - waiting'
        Send-Alert ("[watchdog] the service on port " + $serviceCfg['port'] + " is still DOWN - waiting before trying again")
        exit 0
    }
    Write-Log 'service is not running - starting it'
    $url = Get-TunnelUrl
    $tunnelOk = $true
    if (-not (Get-TunnelProcess)) {
        $url = Start-Tunnel
        if (-not $url) {
            Write-Log 'could not obtain a tunnel URL - giving up this round'
            Send-Alert "[watchdog] the service was DOWN and the tunnel could not be started - manual attention needed"
            exit 1
        }
        $tunnelOk = Wait-TunnelAnswer $url ([int]$cfg['tunnelAnswerWaitSeconds'])
        if (-not $tunnelOk) {
            Write-Log "new tunnel announced $url but the edge does not answer for it yet - starting the service anyway"
        }
        if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $url -Encoding ASCII }
    }
    Restart-Service $url
    if ($tunnelOk) {
        Write-Log "repaired: service started again, tunnel $url (restarting)"
    } else {
        # The service is back but the address is not usable yet. Leaving this unstamped keeps the
        # next scan free to replace the tunnel instead of waiting out the cooldown on a demo that
        # nobody can reach.
        Write-Log "service started again on $url but that address does not answer yet - the next scan keeps looking"
    }
    Send-Alert ("[watchdog] the service was DOWN - started it again. Public URL: " + $url)
    Publish-IfNeeded $url
    exit 0
}

$tunnel = Get-TunnelProcess
$url = Get-TunnelUrl

if (-not $tunnel) {
    if (TooSoonToRestart) { Write-Log 'tunnel missing but a restart happened recently - waiting'; exit 0 }
    Write-Log 'tunnel process is gone - bringing a new one up'
    $answerWait = [int]$cfg['tunnelAnswerWaitSeconds']
    $newUrl = $null
    $lastSeen = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not $DryRun) { Stop-TunnelProcesses }
        $candidate = Start-Tunnel
        if (-not $candidate) { Write-Log "attempt $attempt produced no address at all"; continue }
        $lastSeen = $candidate
        if (Wait-TunnelAnswer $candidate $answerWait) { $newUrl = $candidate; break }
        Write-Log "attempt $attempt announced $candidate but the edge does not answer for it yet"
    }
    if (-not $newUrl) {
        if (-not $lastSeen) { Write-Log 'could not obtain a tunnel URL - giving up this round'; exit 1 }
        # The service must not be left down, so it comes up on the last address seen even though
        # that address is not answering yet. No '(restarting)' stamp here on purpose: this repair
        # did not succeed, so the next scan is free to pick the work up again straight away
        # instead of sitting out the cooldown.
        Write-Log "no address answered after 2 attempts - starting the service on $lastSeen, the next scan keeps looking"
        if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $lastSeen -Encoding ASCII }
        Restart-Service $lastSeen
        Send-Alert ("[watchdog] the tunnel was down and its replacement " + $lastSeen + " does not answer yet - the service is up, still working on the address")
        exit 0
    }
    if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $newUrl -Encoding ASCII }
    Restart-Service $newUrl
    Write-Log "repaired: tunnel $newUrl, service restarted (restarting)"
    Send-Alert ("[watchdog] the tunnel had died - new public URL: " + $newUrl)
    Publish-IfNeeded $newUrl
    exit 0
}

# a tunnel that is still connecting has no URL in its log yet - that is not a fault
if (-not $url) {
    Write-Log "tunnel process is running but has not announced a URL yet - waiting"
    exit 0
}

if (-not (Test-TunnelHealthy $url)) {
    if (TooSoonToRestart) { Write-Log 'tunnel unreachable but a restart happened recently - waiting'; exit 0 }
    Write-Log "tunnel process runs but $url does not answer - replacing it"
    $answerWait = [int]$cfg['tunnelAnswerWaitSeconds']
    $newUrl = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not $DryRun) { Stop-TunnelProcesses }
        $candidate = Start-Tunnel
        if (-not $candidate) { Write-Log "attempt $attempt produced no address at all"; continue }
        if (Wait-TunnelAnswer $candidate $answerWait) { $newUrl = $candidate; break }
        # An address the edge does not answer for is not an address. Recording it would hand a
        # hostname that does not exist to the service and to the publish step.
        Write-Log "attempt $attempt announced $candidate but the edge does not answer for it"
    }
    if (-not $newUrl) {
        # Nothing was recorded and the service was left alone, so this scan changed nothing.
        # Deliberately no '(restarting)' stamp: the cooldown exists to stop restart storms after a
        # repair, not to lock the watchdog out of a repair that never happened - otherwise one bad
        # round leaves the demo dark until the cooldown runs out.
        Write-Log 'no replacement answered after 2 attempts - nothing recorded, the next scan tries again'
        Send-Alert '[watchdog] the tunnel address stopped working and two replacements did not answer - nothing was republished, trying again next scan'
        exit 0
    }
    if ($cfg['urlFile'] -and -not $DryRun) { Set-Content -LiteralPath $cfg['urlFile'] -Value $newUrl -Encoding ASCII }
    Restart-Service $newUrl
    Write-Log "repaired: tunnel $newUrl, service restarted (restarting)"
    Send-Alert ("[watchdog] the public URL stopped answering - repaired, new public URL: " + $newUrl)
    Publish-IfNeeded $newUrl
    exit 0
}

Write-Log "healthy: service pid $svc, tunnel $url"
Publish-IfNeeded $url
exit 0
