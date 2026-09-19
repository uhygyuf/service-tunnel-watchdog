<#
.SYNOPSIS
    Registers or removes the scheduled task that runs the service/tunnel watchdog.

.DESCRIPTION
    Creates a Windows scheduled task that runs watchdog.ps1 in the background every
    few minutes, so a dead tunnel or a dead service is repaired without anyone
    watching. Nothing is copied and no registry keys are written: the task simply
    runs the script (and config) where they live.

.PARAMETER IntervalMinutes
    How often the watchdog should scan (default 5).

.PARAMETER TaskName
    Name of the scheduled task (default "service tunnel watchdog").

.PARAMETER Config
    Config file to pass to the watchdog (default: watchdog-config.json next to it).

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -IntervalMinutes 2 -Config .\prod.json

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 5,
    [string]$TaskName = 'service tunnel watchdog',
    [string]$Config = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$watchdog = Join-Path $scriptDir 'watchdog.ps1'

if (-not (Test-Path -LiteralPath $watchdog)) { throw "Cannot find watchdog.ps1 next to this installer: $watchdog" }

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) { Write-Host "Task '$TaskName' is not installed - nothing to remove."; return }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
    return
}

$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watchdog
if ($Config) {
    if (-not (Test-Path -LiteralPath $Config)) { throw "Config not found: $Config" }
    $arguments += ' -Config "{0}"' -f (Resolve-Path -LiteralPath $Config).Path
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                                   -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                         -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Keeps a local service and its public tunnel alive: repairs a dead tunnel, restarts the service with the fresh public URL.' `
    -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' - every $IntervalMinutes minute(s)."
Write-Host "  script : $watchdog"
if ($Config) { Write-Host "  config : $Config" }
Write-Host ''
Write-Host "Run it now   : Start-ScheduledTask -TaskName `"$TaskName`""
Write-Host 'Check results: watchdog.log next to the script'
Write-Host "Remove it    : .\install.ps1 -Uninstall"
