# Self-tests for watchdog.ps1
#
# Every test runs the watchdog against a SANDBOX: a temp folder with a fake tunnel
# program, a fake service launcher and a fake service listening on a spare port.
# Nothing real is touched, and every decision path can be forced deterministically.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#
# Exit code 0 = all tests passed.

$ErrorActionPreference = 'Stop'
$watchdog = Join-Path (Split-Path -Parent $PSScriptRoot) 'watchdog.ps1'
$base = Join-Path $env:TEMP ('stwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null
$results = New-Object System.Collections.ArrayList

function Record([string]$name, [bool]$ok, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ test = $name; ok = $ok; detail = $detail })
    $mark = 'FAIL'; if ($ok) { $mark = 'PASS' }
    Write-Host ("  {0}  {1,-54} {2}" -f $mark, $name, $detail)
}

function New-Sandbox([string]$name, [int]$port) {
    $root = Join-Path $base $name
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    # fake tunnel: announces a URL in its log, then keeps a process alive whose name
    # matches tunnel.processName ("ping" in these tests)
    "@echo off`r`n" +
    "echo INF url=https://$name-tunnel.test>> `"%~dp0tunnel.log`"`r`n" +
    "start `"`" /b ping -n 400 127.0.0.1 > nul`r`n" |
        Set-Content -LiteralPath (Join-Path $root 'fake-tunnel.bat') -Encoding ASCII

    # fake service: records the public URL it was handed, then listens on the test port
    "@echo off`r`n" +
    "echo %SERVICE_PUBLIC_URL%>> `"%~dp0launcher-runs.txt`"`r`n" +
    "start `"`" /min powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0listen.ps1`" -Port $port`r`n" |
        Set-Content -LiteralPath (Join-Path $root 'fake-launcher.bat') -Encoding ASCII

    'param([int]$Port) $l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port); $l.Start(); Start-Sleep -Seconds 300' |
        Set-Content -LiteralPath (Join-Path $root 'listen.ps1') -Encoding ASCII

    # raw TCP HTTP responder with a configurable status (HttpListener would need an
    # admin URL ACL; a TcpListener needs nothing)
    $responder = 'param([int]$Port,[int]$Status=200) $l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port); ' +
                 '$l.Start(); while ($true) { $c=$l.AcceptTcpClient(); $st=$c.GetStream(); ' +
                 '$b=New-Object byte[] 4096; $null=$st.Read($b,0,$b.Length); ' +
                 '$r=[System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status X`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); ' +
                 '$st.Write($r,0,$r.Length); $st.Flush(); $c.Close() }'
    $responder | Set-Content -LiteralPath (Join-Path $root 'respond.ps1') -Encoding ASCII

    $cfg = @{
        logFile                   = (Join-Path $root 'watchdog.log')
        urlFile                   = (Join-Path $root 'public-url.txt')
        offSwitch                 = (Join-Path $root 'watchdog-off.txt')
        minMinutesBetweenRestarts = 8
        urlWaitSeconds            = 15
        bootWaitSeconds           = 15
        healthTimeoutSeconds      = 4
        service                   = @{
            port      = $port
            launcher  = (Join-Path $root 'fake-launcher.bat')
            args      = @()
            urlEnvVar = 'SERVICE_PUBLIC_URL'
            healthPath = '/home'
        }
        tunnel                    = @{
            exe         = (Join-Path $root 'fake-tunnel.bat')
            args        = @()
            processName = 'ping'
            urlPattern  = 'https://[a-z0-9-]+\.test'
            logFile     = (Join-Path $root 'tunnel.log')
        }
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'watchdog-config.json') -Encoding UTF8
    return $root
}

function Start-FakeService([string]$root, [int]$port) {
    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList `
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'listen.ps1'), '-Port', $port | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Invoke-Watchdog([string]$root, [switch]$DryRun) {
    $cfg = Join-Path $root 'watchdog-config.json'
    try {
        if ($DryRun) { & $watchdog -Config $cfg -DryRun *> $null }
        else { & $watchdog -Config $cfg *> $null }
    } catch {
        Write-Host "    (watchdog raised: $($_.Exception.Message))"
    }
}

function Read-Log([string]$root) {
    $p = Join-Path $root 'watchdog.log'
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) }
    return ''
}
function LauncherRuns([string]$root) {
    $p = Join-Path $root 'launcher-runs.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p)
}
function UrlFile([string]$root) {
    $p = Join-Path $root 'public-url.txt'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return (Get-Content -LiteralPath $p -Raw).Trim()
}
function Stop-Sandbox([string]$root) {
    Get-Process ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { ([string]$_.CommandLine) -like "*$root*" } |
        ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'service-tunnel-watchdog - self tests'
Write-Host ('=' * 78)

# --- T1: off switch --------------------------------------------------------
$r1 = New-Sandbox 't1' 45801
Start-FakeService $r1 45801 | Out-Null
Set-Content -LiteralPath (Join-Path $r1 'watchdog-off.txt') -Value '' -Encoding ASCII
Invoke-Watchdog $r1
Record 'off switch stops the watchdog' (((Read-Log $r1) -match 'switched off') -and (@(LauncherRuns $r1).Count -eq 0)) `
       'no repair attempted'
Stop-Sandbox $r1

# --- T2: service down -> no autostart --------------------------------------
$r2 = New-Sandbox 't2' 45802
Invoke-Watchdog $r2
Record 'service down -> no autostart' (((Read-Log $r2) -match 'not running') -and (@(LauncherRuns $r2).Count -eq 0)) `
       'nothing was started'
Stop-Sandbox $r2

# --- T3: tunnel gone -> tunnel + service restarted with the new URL --------
$r3 = New-Sandbox 't3' 45803
Start-FakeService $r3 45803 | Out-Null
Invoke-Watchdog $r3
$log3 = Read-Log $r3
$runs3 = @(LauncherRuns $r3)
Record 'tunnel gone -> repaired' ($log3 -match 'repaired: tunnel') 'log says repaired'
Record 'new tunnel URL recorded' ((UrlFile $r3) -eq 'https://t3-tunnel.test') "public-url.txt = $(UrlFile $r3)"
Record 'service restarted with the new public URL' (($runs3.Count -ge 1) -and ($runs3[-1].Trim() -eq 'https://t3-tunnel.test')) `
       "launcher saw SERVICE_PUBLIC_URL = $($runs3[-1])"

# --- T4: flapping guard ----------------------------------------------------
$before = @(LauncherRuns $r3).Count
Get-Process ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Invoke-Watchdog $r3
Record 'flapping guard blocks a second restart' ((@(LauncherRuns $r3).Count -eq $before) -and ((Read-Log $r3) -match 'recently - waiting')) `
       'no restart storm within the cooldown'
Stop-Sandbox $r3

# --- T5: tunnel alive but unreachable -> restart both ---------------------
$r5 = New-Sandbox 't5' 45805
Start-FakeService $r5 45805 | Out-Null
"INF url=https://t5-tunnel.test" | Set-Content -LiteralPath (Join-Path $r5 'tunnel.log') -Encoding ASCII
Start-Process -FilePath 'ping' -ArgumentList '-n', '400', '127.0.0.1' -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 2
Invoke-Watchdog $r5
Record 'unreachable tunnel -> repaired' ((Read-Log $r5) -match 'does not answer - restarting') 'connection-level failure detected'
Record 'repair replaced the stale URL file' ((UrlFile $r5) -eq 'https://t5-tunnel.test') 'URL file rewritten'
Stop-Sandbox $r5

# --- T6: healthy scan, even when the service answers 404 -------------------
$r6 = New-Sandbox 't6' 45806
Start-FakeService $r6 45806 | Out-Null
Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList `
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $r6 'respond.ps1'), '-Port', '45860', '-Status', '404' | Out-Null
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Get-NetTCPConnection -LocalPort 45860 -State Listen -ErrorAction SilentlyContinue) { break } }
Start-Process -FilePath 'ping' -ArgumentList '-n', '400', '127.0.0.1' -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 2
# healthPath is /home, so the URL we announce has to carry a host that answers:
$cfg6 = Get-Content -LiteralPath (Join-Path $r6 'watchdog-config.json') -Raw | ConvertFrom-Json
$cfg6.tunnel.urlPattern = 'http://127\.0\.0\.1:[0-9]+'
$cfg6 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $r6 'watchdog-config.json') -Encoding UTF8
"INF url=http://127.0.0.1:45860" | Set-Content -LiteralPath (Join-Path $r6 'tunnel.log') -Encoding ASCII
Invoke-Watchdog $r6
Record 'healthy scan (an HTTP 404 still counts as reachable)' (((Read-Log $r6) -match 'healthy') -and (@(LauncherRuns $r6).Count -eq 0)) `
       'no restart for a booting service'

# --- T7: repeated scan is idempotent --------------------------------------
$runs7 = @(LauncherRuns $r6).Count
Invoke-Watchdog $r6
Record 'repeat scan is idempotent' (@(LauncherRuns $r6).Count -eq $runs7) 'nothing restarted again'

# --- T8: -DryRun changes nothing -----------------------------------------
$r8 = New-Sandbox 't8' 45808
Start-FakeService $r8 45808 | Out-Null
Get-Process ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue   # no tunnel process
Start-Sleep -Seconds 1
Invoke-Watchdog $r8 -DryRun
$log8 = Read-Log $r8
Record '-DryRun reports but does not repair' (($log8 -match 'DRY-RUN would start tunnel') -and (@(LauncherRuns $r8).Count -eq 0) -and ((UrlFile $r8) -eq '')) `
       'nothing was started or written'
Stop-Sandbox $r8

# --- T9: tunnel up but no URL announced yet -> wait, do not restart --------
$r9 = New-Sandbox 't9' 45809
Start-FakeService $r9 45809 | Out-Null
Start-Process -FilePath 'ping' -ArgumentList '-n', '400', '127.0.0.1' -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 2
Set-Content -LiteralPath (Join-Path $r9 'tunnel.log') -Value 'INF precheck complete' -Encoding ASCII
Invoke-Watchdog $r9
Record 'no URL yet -> wait instead of restarting' (((Read-Log $r9) -match 'has not announced a URL yet') -and (@(LauncherRuns $r9).Count -eq 0)) `
       'a connecting tunnel is not a broken tunnel'
Stop-Sandbox $r9

# --- T10: edge 5xx while the service itself answers -> the tunnel is broken
$r10 = New-Sandbox 't10' 45810
$cfg10 = Get-Content -LiteralPath (Join-Path $r10 'watchdog-config.json') -Raw | ConvertFrom-Json
"@echo off`r`necho %SERVICE_PUBLIC_URL%>> `"%~dp0launcher-runs.txt`"`r`nstart `"`" /min powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0respond.ps1`" -Port 45810 -Status 200`r`n" |
    Set-Content -LiteralPath (Join-Path $r10 'fake-launcher.bat') -Encoding ASCII
Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList `
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $r10 'respond.ps1'), '-Port', '45810', '-Status', '200' | Out-Null
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Get-NetTCPConnection -LocalPort 45810 -State Listen -ErrorAction SilentlyContinue) { break } }
Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList `
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $r10 'respond.ps1'), '-Port', '45870', '-Status', '503' | Out-Null
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Get-NetTCPConnection -LocalPort 45870 -State Listen -ErrorAction SilentlyContinue) { break } }
$cfg10.tunnel.urlPattern = 'http://127\.0\.0\.1:[0-9]+'
$cfg10 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $r10 'watchdog-config.json') -Encoding UTF8
"INF url=http://127.0.0.1:45870" | Set-Content -LiteralPath (Join-Path $r10 'tunnel.log') -Encoding ASCII
Start-Process -FilePath 'ping' -ArgumentList '-n', '400', '127.0.0.1' -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 2
Invoke-Watchdog $r10
Record 'edge 5xx + healthy service -> tunnel is broken, repaired' ((Read-Log $r10) -match 'does not answer - restarting') `
       'stale URL behind a connected-looking tunnel is detected'
Stop-Sandbox $r10

# --- T11: a config path with a control character is rejected loudly -------
# (real incident: a JSON round-trip turned "\\n" into a newline, the log path became
#  invalid, every write failed silently and the tunnel never announced its URL)
$r11 = New-Sandbox 't11' 45811
Start-FakeService $r11 45811 | Out-Null
Get-Process ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$cfg11 = Get-Content -LiteralPath (Join-Path $r11 'watchdog-config.json') -Raw | ConvertFrom-Json
$cfg11.logFile = 'D:\broken' + [char]10 + 'path\watchdog.log'
$cfg11 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $r11 'watchdog-config.json') -Encoding UTF8
$out11 = ''
# *>&1 also captures the warning stream (Write-Warning writes to stream 3)
try { $out11 = (& $watchdog -Config (Join-Path $r11 'watchdog-config.json') *>&1 | Out-String) } catch { }
Record 'control-char path is caught and falls back' ($out11 -match 'control character') `
       'loud warning instead of silent write failures'
Stop-Sandbox $r11

# --- alerts + crash recovery (T12-T16) -------------------------------------
# A local sink stands in for the Telegram Bot API so the alert path can be tested
# end to end without touching the network or a real chat.
function New-AlertSink([string]$root, [int]$port) {
    $out = Join-Path $root 'alerts.txt'
    $sink = @'
param([int]$Port,[string]$OutFile)
$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$l.Start()
while ($true) {
    $c = $l.AcceptTcpClient(); $st = $c.GetStream()
    $sb = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        if ($st.DataAvailable) {
            $buf = New-Object byte[] 4096
            $n = $st.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $n)) }
        } else { Start-Sleep -Milliseconds 50 }
    }
    Add-Content -LiteralPath $OutFile -Value ($sb.ToString() -replace "`r?`n", ' | ')
    $json = '{"ok":true,"result":{"message_id":42}}'
    $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($json.Length)`r`nConnection: close`r`n`r`n"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($head + $json)
    $st.Write($bytes, 0, $bytes.Length); $st.Flush(); $c.Close()
}
'@
    Set-Content -LiteralPath (Join-Path $root 'alert-sink.ps1') -Value $sink -Encoding ASCII
    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList `
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'alert-sink.ps1'), `
        '-Port', $port, '-OutFile', $out | Out-Null
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { break } }
    return $out
}
function Set-Notify([string]$root, [int]$port, [object]$autoStart, [string]$token) {
    $cfg = Get-Content -LiteralPath (Join-Path $root 'watchdog-config.json') -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName autoStart -NotePropertyValue $autoStart -Force
    $cfg | Add-Member -NotePropertyName notify -NotePropertyValue ([pscustomobject]@{
        enabled      = $true
        apiBase      = "http://127.0.0.1:$port"
        botToken     = ''
        chatId       = ''
        secretsFile  = (Join-Path $root 'watchdog-secrets.json')
        remindMinutes = 60
    }) -Force
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'watchdog-config.json') -Encoding UTF8
    if ($token) {
        ('{ "botToken": "' + $token + '", "chatId": "999" }') |
            Set-Content -LiteralPath (Join-Path $root 'watchdog-secrets.json') -Encoding UTF8
    }
}

# --- T12: service down with autoStart off stays down, and says so ----------
$r12 = New-Sandbox 't12' 45812
Set-Notify $r12 45912 $false ''
Invoke-Watchdog $r12
Record 'autoStart off: a dead service stays dead' (((Read-Log $r12) -match 'autoStart is off') -and (@(LauncherRuns $r12).Count -eq 0)) `
       'crash recovery stays opt-in'
Stop-Sandbox $r12

# --- T13: autoStart on -> the watchdog brings the service back -------------
$r13 = New-Sandbox 't13' 45813
Set-Notify $r13 45913 $true ''
Invoke-Watchdog $r13
$log13 = Read-Log $r13
$runs13 = @(LauncherRuns $r13)
Record 'autoStart on: a dead service is started again' (($log13 -match 'repaired: service started again') -and ($runs13.Count -ge 1)) `
       "launcher runs: $($runs13.Count)"
Record 'the restarted service gets the public URL' (($runs13.Count -ge 1) -and ($runs13[-1].Trim() -eq 'https://t13-tunnel.test')) `
       "SERVICE_PUBLIC_URL = $($runs13[-1])"
Stop-Sandbox $r13

# --- T14: repair is announced out-of-band, and never leaks the token -------
$r14 = New-Sandbox 't14' 45814
$sink14 = New-AlertSink $r14 45914
Set-Notify $r14 45914 $true 'FAKE-TOKEN-ABCDE'
Invoke-Watchdog $r14
$log14 = Read-Log $r14
$al14 = ''
if (Test-Path -LiteralPath $sink14) { $al14 = (Get-Content -LiteralPath $sink14 -Raw) }
Record 'repair sends an out-of-band alert' (($log14 -match 'alert sent') -and ($al14 -match 'DOWN') -and ($al14 -match 'sendMessage')) `
       'posted straight to the bot API, not through the watched service'
Record 'the bot token never reaches the log' (-not ($log14 -match 'FAKE-TOKEN-ABCDE')) `
       'token read from the secrets file only'
Stop-Sandbox $r14

# --- T15: repeated alerts are rate limited ---------------------------------
$r15 = New-Sandbox 't15' 45815
$sink15 = New-AlertSink $r15 45915
Set-Notify $r15 45915 $false 'FAKE-TOKEN-FGHIJ'
Invoke-Watchdog $r15
Invoke-Watchdog $r15
$log15 = Read-Log $r15
$count15 = 0
if (Test-Path -LiteralPath $sink15) { $count15 = @(Get-Content -LiteralPath $sink15 | Where-Object { $_ -match 'sendMessage' }).Count }
Record 'repeated alerts are rate limited' (($log15 -match 'alert suppressed') -and ($count15 -eq 1)) `
       "alerts delivered: $count15"
Stop-Sandbox $r15

# --- T16: notify enabled but no credentials -> degraded, not fatal ---------
$r16 = New-Sandbox 't16' 45816
Set-Notify $r16 45916 $false ''
Invoke-Watchdog $r16
Record 'notify without credentials degrades loudly' ((Read-Log $r16) -match 'no bot token / chat id configured') `
       'logged instead of throwing'
Stop-Sandbox $r16

# --- cleanup ---------------------------------------------------------------
Get-Process ping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

$failed = @($results | Where-Object { -not $_.ok })
$verdict = 'ALL PASS'; if ($failed.Count -gt 0) { $verdict = "$($failed.Count) FAILED" }
Write-Host ('=' * 78)
Write-Host ("RESULT: {0} ({1}/{2} passed)" -f $verdict, ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0