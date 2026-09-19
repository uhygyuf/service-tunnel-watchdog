# Changelog

## 1.0.0
First release.

- Scans one service + one tunnel and repairs what is broken: restarts the tunnel, reads its new
  public URL, restarts the service with that URL in an environment variable so webhook
  registrations follow the change.
- Never autostarts a service that is not running; file-based off switch; anti-flapping cooldown;
  `-DryRun`; every decision written to a log with its reason.
- Config-driven (JSON): service port/launcher/args/url env var/health path, tunnel exe/args/
  process name/URL pattern/log, cooldowns and waits.
- `install.ps1` registers or removes a scheduled task (no admin rights needed to run).
- 11 self-tests that exercise every branch against real processes in a sandbox.
