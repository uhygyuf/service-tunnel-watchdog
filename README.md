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
  PASS  new tunnel URL recorded                                public-url.txt = https://t3-tunnel.test
  PASS  service restarted with the new public URL              launcher saw SERVICE_PUBLIC_URL = https://t3-tunnel.test
  PASS  flapping guard blocks a second restart                 no restart storm within the cooldown
  PASS  unreachable tunnel -> repaired                         connection-level failure detected
  PASS  repair replaced the stale URL file                     URL file rewritten
  PASS  healthy scan (an HTTP 404 still counts as reachable)   no restart for a booting service
  PASS  repeat scan is idempotent                              nothing restarted again
  PASS  -DryRun reports but does not repair                    nothing was started or written
  PASS  no URL yet -> wait instead of restarting               a connecting tunnel is not a broken tunnel
  PASS  edge 5xx + healthy service -> tunnel is broken, repaired stale URL behind a connected-looking tunnel is detected
  PASS  control-char path is caught and falls back             loud warning instead of silent write failures
RESULT: ALL PASS (14/14 passed)
```

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
| A repair happened less than `minMinutesBetweenRestarts` ago | log and wait (anti-flapping) |
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