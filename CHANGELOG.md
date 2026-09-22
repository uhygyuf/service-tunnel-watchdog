# Changelog

## 1.1.0
- Opt-in `hook`: one command of yours, run with the current public URL whenever that URL changes
  (after a repair, or on any scan where it differs from the last one the hook succeeded with). The
  state file records a URL only after a hook run that exited 0, so a failure or a hang is retried on
  the next scan; the command is killed at `hook.timeoutSeconds`.
- 9 new assertions for the hook (runs once per URL, sees the current URL, skips an unchanged URL,
  re-runs on a changed URL, logs a non-zero exit, retries after a failure, does nothing under
  `-DryRun`, does nothing when disabled).

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
