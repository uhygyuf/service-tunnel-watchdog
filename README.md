# service-tunnel-watchdog

**Keeps a local service and its public tunnel alive on Windows — and re-launches the service with
the fresh public URL when the tunnel comes back.**

Services die. Tunnels die more often. And the nasty case is not the crash, it is what comes after:
a webhook provider (Telegram, Slack, Stripe, GitHub, an OAuth callback…) was told your public URL,
the tunnel restarts with a *new* hostname, and the service that could re-register it is still
happily running with the old one. Everything looks fine locally and nothing arrives from outside.

This watchdog closes that gap on a schedule: one scan, one decision, one log line.

```
  PASS  off switch stops the watchdog                          no repair attempted
  PASS  service down -> no autostart                           nothing was started
  PASS  tunnel gone -> repaired                                log says repaired
  PASS  new tunnel URL recorded                                public-url.txt = http://127.0.0.1:45870
  PASS  service restarted with the new public URL              launcher saw SERVICE_PUBLIC_URL = http://127.0.0.1:45870
  PASS  flapping guard blocks a second restart                 no restart storm within the cooldown
  PASS  unreachable tunnel -> repaired                         connection-level failure detected
  PASS  repair replaced the stale URL file                     URL file rewritten
  PASS  healthy scan (an HTTP 404 still counts as reachable)   no restart for a booting service
  PASS  repeat scan is idempotent                              nothing restarted again
  PASS  -DryRun reports but does not repair                    nothing was started or written
  PASS  no URL yet -> wait instead of restarting               a connecting tunnel is not a broken tunnel
  PASS  edge 5xx + healthy service -> tunnel is broken, repaired stale URL behind a connected-looking tunnel is detected
  PASS  control-char path is caught and falls back             loud warning instead of silent write failures
  PASS  autoStart off: a dead service stays dead               crash recovery stays opt-in
  PASS  autoStart on: a dead service is started again          launcher runs: 1
  PASS  the restarted service gets the public URL              SERVICE_PUBLIC_URL = https://t13-tunnel.test
  PASS  repair sends an out-of-band alert                      posted straight to the bot API, not through the watched service
  PASS  the bot token never reaches the log                    token read from the secrets file only
  PASS  repeated alerts are rate limited                       alerts delivered: 1
  PASS  notify without credentials degrades loudly             logged instead of throwing
  PASS  a replacement that does not answer is tried once more in the same scan one bad round does not burn a whole interval
  PASS  the unreachable address is still not recorded          public-url.txt = https://t26-dead.test
  PASS  and the service is still not restarted onto it         no restart onto a hostname that does not exist
  PASS  a round that repaired nothing does not spend the cooldown the next scan is free to try again
  PASS  the next scan tries again rather than waiting out a cooldown two scans, two rounds of work
  PASS  and no cooldown message claims otherwise               no false cooldown
RESULT: ALL PASS (47/47 passed)
```

## Crash recovery and alerting (opt-in)

Two switches, both off by default, both about the case where **nothing local can report the failure**:

```json
{
  "autoStart": true,
  "notify": { "enabled": true, "secretsFile": "watchdog-secrets.json" }
}
```

* **`autoStart`** — a dead service is started again on the next scan (with the tunnel restarted first
  if that died too, so the service comes back with the right public URL). This is crash recovery,
  not a Windows-boot autostart: the watchdog only ever acts when its scheduled task runs.
* **`notify`** — alerts go from the script itself to the Telegram Bot API, **never through the watched
  service**, because a service that is down cannot report its own death. Alerts fire on every repair
  and while a service stays down; repeats are rate-limited by `remindMinutes`.

The bot token lives in `watchdog-secrets.json`, not in the shareable config, and it is never written
to the log — both of which are asserted by tests:

```json
{ "botToken": "123456:ABC-DEF...", "chatId": "123456789" }
```

---

## Republishing a URL that changed (opt-in `hook`)

A repaired tunnel usually comes back on a **new** hostname, and whatever was told the old one keeps
using the dead address: a hosted page with the URL baked into a JSON file, a webhook subscription, an
OAuth callback. The watchdog cannot know how you re-register those, so it runs one command of yours:

```json
{
  "hook": {
    "enabled": true,
    "command": "powershell.exe",
    "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\demo\\publish-url.ps1"],
    "stateFile": "hook-state.txt",
    "timeoutSeconds": 120
  }
}
```

* `{url}` in `args` is replaced with the current public URL (`{port}` and `{logfile}` work as well).
* The hook runs **after a repair**, and on any scan where the URL differs from the one the last
  successful run was given — so a tunnel you restarted by hand is republished on the next scan, at
  most five minutes later.
* `stateFile` records a URL **only after a run that exited 0**. A hook that fails or hangs (it is
  killed at `timeoutSeconds`) is retried inside the same scan (`hook.attempts`, default 3, spaced by
  `hook.retrySeconds`) and the failure is logged. Before the first attempt the watchdog waits up to
  `hook.waitForServiceSeconds` for the service to answer through the tunnel, because a publish that
  fails only because the service is still booting would otherwise cost a whole scan interval.
* A **replacement tunnel address is verified before it is used**: the old client is stopped and waited
  for, then the address it announces must be answered by the edge within `tunnelAnswerWaitSeconds`
  (default 90). An address the edge does not answer for is not recorded and the service is left
  alone — a second client started next to a live one announces an address and then dies.
* Design the hook to be idempotent and fast: it may run on every URL change, and the watchdog waits
  for it before it exits.

---

## What it does

| Situation | Action |
|---|---|
| The service is not listening on its port | **nothing** — no surprise autostart; start it yourself when you want it |
| Tunnel process is gone | start the tunnel, read the new public URL, restart the service with that URL in an environment variable, write the URL to a file |
| Tunnel process is alive but has not announced a URL yet | **wait** — it is still connecting, not broken |
| The public URL does not answer at all | restart tunnel + service |
| The public URL answers 5xx while the local service answers fine | restart tunnel + service (a stale hostname behind a connected-looking tunnel looks exactly like this) |
| Everything healthy | log one line and exit |
| `hook.enabled` and the URL differs from the last published one | run the hook with `{url}` filled in (after the repair, or on this scan) |
| A repair happened less than `minMinutesBetweenRestarts` ago | log and wait (anti-flapping). A round that produced no working address is not counted as a repair, so it starts no cooldown |
| The off-switch file exists | exit immediately |

Design promises: no daemon, no registry keys, no background loop — one scan per scheduled-task run.
Every decision is appended to a log **with its reason**, and `-DryRun` shows what it *would* do.

## Quick start

```powershell
# 1. see what it thinks, change nothing
.\watchdog.ps1 -DryRun -Verbose

# 2. configure your service + tunnel
Copy-Item config.example.json watchdog-config.json
notepad watchdog-config.json

# 3. real run
.\watchdog.ps1 -Verbose

# 4. install the background task (every 5 minutes)
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Config .\watchdog-config.json

# 5. remove it any time
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

**The scheduled task runs completely invisibly.** `install.ps1` launches it through
`hidden-runner.vbs`, because on Windows 11 (where Windows Terminal is the default terminal host)
a task using `powershell -WindowStyle Hidden` still flashes a terminal window on every run — one
window per interval, forever.

## Configuration

`watchdog-config.json` — all keys optional, see `config.example.json`:

| Key | Default | Meaning |
|---|---|---|
| `service.port` | `5678` | The port whose listener means "the service is up" |
| `service.launcher` | — | The `.bat`/`.exe` used to (re)start the service |
| `service.args` | `[]` | Arguments for the launcher; `{url}` and `{port}` are substituted |
| `service.urlEnvVar` | `SERVICE_PUBLIC_URL` | Environment variable that receives the public URL (empty = don't set one) |
| `service.healthPath` | `/` | Path probed on the public URL, e.g. `/health` |
| `tunnel.exe` | `cloudflared.exe` | The tunnel program (cloudflared, ngrok, cpolar, …) |
| `tunnel.args` | cloudflared quick tunnel | Its arguments; `{port}`, `{logfile}`, `{url}` are substituted |
| `tunnel.processName` | `cloudflared` | Process name that means "the tunnel is running" |
| `tunnel.urlPattern` | `https://…trycloudflare.com` | Regex that finds the public URL in the tunnel's log |
| `tunnel.logFile` | `tunnel.log` | Tunnel log to read the URL from (truncated before each start) |
| `minMinutesBetweenRestarts` | `8` | Anti-flapping cooldown |
| `urlWaitSeconds` / `bootWaitSeconds` | `60` / `90` | How long to wait for the URL / for the service to listen |
| `healthTimeoutSeconds` | `20` | Timeout for the local and public health probes |
| `hook.enabled` / `hook.command` / `hook.args` | off / — | Optional command run when the public URL changes; `{url}`, `{port}`, `{logfile}` are substituted |
| `hook.stateFile` / `hook.timeoutSeconds` | `hook-state.txt` / `120` | File recording the last successfully published URL, and how long the hook may run |
| `hook.attempts` / `hook.retrySeconds` | `3` / `20` | Attempts inside one scan before leaving it to the next scan, and the pause between them |
| `hook.waitForServiceSeconds` | `bootWaitSeconds` | How long to wait for the service to answer through the tunnel before the first attempt |
| `tunnelAnswerWaitSeconds` | `90` | How long a replacement tunnel's address may take to be answered by the edge before it is discarded |
| `logFile` / `urlFile` / `offSwitch` | next to the script | Decision log, current-URL file, kill switch |

**Watch the escaping in your JSON.** `"D:\Tools\n8n\x.log"` is a path; `"D:\Tools\n8n..."` with one
lost backslash turns `\n` into a real newline and the path becomes invalid. The watchdog detects a
path containing a control character, warns loudly and falls back to a default instead of failing
silently (test T11).

Swapping tunnel providers is a config change, not a code change — that is the whole point of the
`{port}` / `{logfile}` / `{url}` placeholders.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

The suite does not mock: each test builds a **sandbox** (a temp folder with a fake tunnel program,
a fake service launcher and a fake service listening on a spare port), runs the real watchdog
against it, and asserts on real process state, real log files and the URL the fake service was
handed. The live service is never touched.

Covered: off switch, no-autostart, tunnel-gone repair, URL hand-off, flapping guard, unreachable
tunnel, healthy scan with a booting service (404 ≠ broken tunnel), idempotency, `-DryRun`.

## Design notes — PowerShell traps this project hit

Written down so the next person loses minutes instead of hours:

- **A function returning a dictionary gets unrolled.** `return $dict` hands the caller an *array of
  entries*; the symptom is a baffling `Cannot index into a null array` much later. Mutate the
  dictionary in place (reference type) and return nothing.
- **`Start-Process -ArgumentList $emptyArray` throws.** Pass `-ArgumentList` only when there is
  something to pass.
- **Never name a parameter or variable `$pid`** — it collides with the automatic variable and your
  function silently acts on the wrong process.
- **`Get-NetTCPConnection` raises a CIM error when nothing listens.** Wrap it in try/catch with
  `-ErrorAction Stop`, or a caller running with `$ErrorActionPreference='Stop'` dies on the
  "service is down" path — the one path that must never throw.
- **A single-line `Get-Content` result is a `string`, not an array** (`.Count` and `[-1]` misbehave);
  wrap calls in `@()`.
- **`ConvertTo-Json` mishandles `[ordered]` dictionaries** (they serialize as arrays) — build test
  configs from plain hashtables.
- **`HttpListener` needs an admin URL ACL**; a raw `TcpListener` serving a hand-written HTTP response
  does not.
- **`$PSScriptRoot` is empty while `param()` defaults are evaluated**, so a default config path must
  be resolved inside the body.
- **A health check that accepts "any HTTP response" is not enough.** A stale tunnel hostname answers
  `530` from the edge while the local service is perfectly healthy — that is a broken tunnel that
  looks connected. Compare the public status with the local one: a public 5xx next to a healthy local
  response means "repair"; a public 404 next to a booting service means "wait".

## Limitations

- Windows only (`Get-NetTCPConnection`, scheduled tasks).
- Repairs cost a restart: the service is relaunched so it can re-register the new URL (~1 minute for
  most services). Mitigated by the cooldown and by only acting on real failures.
- It cannot fix a machine that was rebooted — by design it does nothing until the service runs.
- Quick-tunnel hostnames are ephemeral. For a stable public URL, run a named tunnel or a VPS with a
  real domain; the watchdog keeps working either way.
- One service + one tunnel per config file. Run several configs (and several tasks) for more.

## License

MIT — see [LICENSE](LICENSE).