# Changelog

## 1.1.1
- Publishing waits for the service to answer through the tunnel before running the hook, and retries
  the hook inside the same scan (`hook.attempts`, default 3, `hook.retrySeconds`, default 20). A
  repair used to publish while the service was still booting, fail for a reason that had nothing to
  do with the address, and wait a whole scan interval to try again.
- A replacement tunnel address must be answered by the edge before it is recorded or handed to the
  service (`tunnelAnswerWaitSeconds`, default 90). The old client is stopped and waited for first:
  a second client started next to a live one announces an address and then dies, and recording that
  address pointed the service and the publish step at a hostname that does not exist.
- 6 new assertions (T23: an address the edge cannot answer for is never recorded and the service is
  left alone; T24: a failed publish is retried inside one scan and the attempt that worked is logged;
  T25: publishing stays in one helper, which waits for the service, and every replacement address is
  verified). T5 now asserts the replacement address is one the edge answers for.

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
