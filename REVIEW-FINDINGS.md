# Review Findings — v3.8 expert pass (2026-07-11)

Independent PowerShell review of the v3.8 tree. Baseline before the manual pass:

- **Pester: 84/84 passing** (Pester 6.0.0, PS 7.6.1 — suite targets v5 but runs clean on 6)
- **PSScriptAnalyzer 1.25.0: zero findings** at Error/Warning severity
- All findings below were **verified empirically on this machine** (PS 7.6.1 and
  Windows PowerShell 5.1) unless marked otherwise. None are caught by the existing
  test suite or the linter.

Ordered by severity. Suggested fix order: F-01, F-02, F-03, F-04, then the rest.

---

## F-01 · `Get-CimInstance -AsJob` does not exist — device type detection is dead code

**Severity:** Critical (silent wrong output on every real device)
**Location:** `device.ps1` → `Get-DeviceType` (lines 59–64)
**Contradicts:** DECISIONS.md "Parallel CIM queries in Get-DeviceType — ✅ Keep, ~2/3 detection time reduction"

`Get-CimInstance` has **no `-AsJob` parameter** on either PowerShell edition.
Verified:

```
PS7.6 > (Get-Command Get-CimInstance).Parameters.ContainsKey('AsJob')   # False
PS5.1 > (Get-Command Get-CimInstance).Parameters.ContainsKey('AsJob')   # False
```

The first line of the `try` block throws a parameter-binding error, the blanket
`catch` swallows it with a generic "WMI query failed" warning, and **every device
detects as `DT`**. Confirmed live on this machine — a ThinkPad reporting
`ChassisTypes = 10` (Notebook, should be `LT`):

```
> Get-DeviceType -NonInteractive
WARNING: WMI query failed during device type detection -- defaulting to DT.
DT
```

Impact: in the primary MDM/NonInteractive Gateway deployment path this is a
*silent* mis-name of every laptop, tablet, VM and server — precisely the failure
class the project's own "never guess in automation" rule exists to prevent.
`Resolve-DeviceType` (the pure logic) is correct and fully tested; it just never
receives real data.

Why nothing caught it: the tests mock `Get-DeviceType` or call `Resolve-DeviceType`
directly, so the WMI-collection seam is never executed; PSScriptAnalyzer does not
validate parameter names.

**Fix options:**
1. Simplest: drop the fake parallelism — four sequential `Get-CimInstance` calls
   (each is typically tens of ms locally; the "2/3 reduction" was never real).
2. If parallelism is genuinely wanted: `Get-WmiObject -AsJob` (5.1-only),
   `Start-Job`, or CIM async via `CimSession` — but measure first; option 1 is
   almost certainly fine.
3. Either way, narrow the `catch` and make the warning include
   `$_.Exception.Message` so a binding error can never masquerade as a WMI
   failure again.

**Regression guard:** add a Pester test that runs the real `Get-DeviceType
-NonInteractive` (no mocks) and asserts no warning is emitted / result matches
`Resolve-DeviceType` fed with real CIM values. A cheap static alternative: assert
`(Get-Command Get-CimInstance).Parameters.ContainsKey('AsJob')` for every bound
parameter used in the file, or just assert the function's output on the CI runner
is not produced via the catch path.

---

## F-02 · Elevation relaunch via `iex` cannot forward parameters at all

**Severity:** High (breaks the documented parameterized one-liner for non-admin users)
**Location:** `launcher.ps1` → `Invoke-SelfElevation` (line 126)
**Contradicts:** DECISIONS.md BUG-014's claim that the iex-path quoting was verified

The fallback relaunch builds:

```powershell
$command = "iex (irm '$escapedUrl') $($iexArgs -join ' ')"
```

`Invoke-Expression` takes **one** parameter (`-Command`). Any appended token —
switch or value — is a binding error, not an argument to the downloaded script.
Verified:

```
> Invoke-Expression 'Write-Output hello' -NonInteractive
FAILED: A parameter cannot be found that matches parameter name 'NonInteractive'.
> Invoke-Expression 'Write-Output hello' -Username 'jdoe'
FAILED: A parameter cannot be found that matches parameter name 'Username'.
```

Repro path: non-admin shell → `iex (iwr …launcher.ps1).Content` with any
parameter (e.g. `-NonInteractive -Gateway`) → UAC prompt → elevated window opens,
throws the binding error, and (under `wt.exe`) closes before it can be read.
The zero-parameter one-liner works, which is presumably why this survived.

BUG-014 fixed the *quoting* of `$iexArgs` but the tokens are spliced after the
`iex` call, where no quoting can make them bind. The launcher's own header
comment already shows the correct pattern:

**Fix:** build the command the way the header documents it —

```powershell
$command = "& ([scriptblock]::Create((irm '$escapedUrl'))) $($iexArgs -join ' ')"
```

`$iexArgs`' existing single-quote escaping is correct for this form, and the
SEC-003 double-quote refusal still applies unchanged.

**Regression guard:** extend the BUG-014-style round-trip test to execute the
*actual constructed command string* through `pwsh -Command`, with a stub URL
serving a `param()` block that echoes its bindings.

---

## F-03 · Hash manifest pipeline is line-ending-sensitive, and the tree itself has mixed EOLs

**Severity:** High (deployment integrity mechanism can brick or silently drift)
**Location:** `tools\Get-Hashes.ps1`, `launcher.ps1` hash check, `.github/workflows/ci.yml` manifest job; no `.gitattributes` exists

Current on-disk state of this tree:

| file | EOL |
|---|---|
| device.ps1, logging.ps1, network.ps1 | CRLF |
| gui.ps1, launcher.ps1, naming.ps1, rename.ps1 | **LF** |

Three parties hash "the same" file: `Get-Hashes.ps1` (local working copy),
the CI manifest job (Actions checkout), and `launcher.ps1` at runtime
(`raw.githubusercontent.com` bytes as decoded by `iwr`). SHA-256 over text is
CRLF/LF-sensitive, and with no `.gitattributes`, `core.autocrlf` decides what
each party sees. Failure modes:

- Dev with `autocrlf=true` regenerates `$MANIFEST` from a CRLF working copy;
  GitHub raw serves LF → **every device fails the hash check** (fail-closed, but
  a fleet-wide outage of the tool).
- Worse inverse: mismatched normalization that happens to pass locally hides a
  real content difference. The comment in `Get-Hashes.ps1` ("Read raw bytes to
  match exactly what GitHub serves") is also inaccurate — `Get-Content -Raw
  -Encoding UTF8` decodes and re-encodes; it is EOL-preserving but not
  byte-preserving (BOM is stripped).

**Fix:**
1. Add `.gitattributes`: `*.ps1 text eol=lf` (matches what GitHub raw serves
   from a normalized repo), renormalize (`git add --renormalize .`), and make
   the in-tree files consistent.
2. Make all three hashers byte-identical in method, or normalize EOLs before
   hashing on all three sides.
3. Regenerate `$MANIFEST` afterwards.

---

## F-04 · CI lint matrix never actually tests Windows PowerShell 5.1

**Severity:** Medium (false coverage claim; 5.1 is a supported target)
**Location:** `.github/workflows/ci.yml` lint job

`strategy.matrix.ps-version: ["5.1", "latest"]` is defined but
`matrix.ps-version` is **never referenced** — every step runs `shell: pwsh`, so
both legs are identical PS 7 runs. Nothing in CI ever parses or lints the code
under 5.1 (relevant: F-01 class bugs, and the repo explicitly claims 5.1
support in gui.ps1 and DECISIONS.md).

**Fix:** in the `5.1` leg use `shell: powershell` for the analyzer step (and
ideally add a 5.1 Pester leg). Delete the matrix if 5.1 verification is not
wanted — a decorative matrix is worse than none.

---

## F-05 · `Select-NamingMode` crashes when console input is redirected

**Severity:** Low-Medium
**Location:** `naming.ps1` line 42 (`[Console]::KeyAvailable`)

`[Console]::KeyAvailable` throws `InvalidOperationException` ("console input has
been redirected") when stdin is not a real console — piped input, some remoting
hosts, some RMM agents. With `$ErrorActionPreference = "Stop"` inherited from the
launcher, the run dies instead of defaulting to Gateway. DECISIONS.md accepts the
approach "for console sessions"; the gap is that non-console sessions hit an
unhandled throw rather than the documented default.

**Fix:** wrap the poll loop in try/catch → on exception, log and fall through to
the Gateway default (same outcome as the timeout).

---

## F-06 · `Get-DefaultGateway` picks an arbitrary adapter (VPN wins races) and may return IPv6

**Severity:** Low-Medium (wrong-site mapping on multi-homed machines)
**Location:** `network.ps1` → `Get-DefaultGateway`

`Win32_NetworkAdapterConfiguration` order is not metric-ordered. On a machine
with an active VPN or multiple NICs, "first enabled adapter with a gateway" can
be the VPN adapter → unmapped gateway → fallback/throw, or worse, a *mapped but
wrong* site. `DefaultIPGateway` may also contain an IPv6 literal, which will
never match the IPv4-keyed `GATEWAY_MAP`.

**Fix:** prefer the lowest-metric IPv4 default route:
`Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric,ifMetric |
Select-Object -First 1 -ExpandProperty NextHop` (works on 5.1+), with the old
query as fallback. At minimum, filter to IPv4.

---

## F-07 · Module fetch can hang forever

**Severity:** Low
**Location:** `launcher.ps1` lines 190–200

`Invoke-WebRequest` defaults to no timeout (`-TimeoutSec 0`) and
`Receive-Job -Wait` waits indefinitely, so a stalled connection hangs an
unattended MDM run forever with no error. **Fix:** `-TimeoutSec 60` inside the
job and/or `Wait-Job -Timeout` with a clear throw.

---

## F-08 · Minor items (batch these opportunistically)

1. **UAC decline is an unhandled exception** — `Start-Process -Verb RunAs`
   throws "The operation was canceled by the user" if the user declines; wrap
   and exit with a friendly message (`launcher.ps1:138`).
2. **CI manifest regex is lowercase-only** — `[a-f0-9]{64}` silently *skips*
   verification of an uppercase-pasted hash (count 0 → "skipping" path). Add
   `A-F` or `(?i)`, and fail rather than warn when the SHA is pinned but no
   entries parse (partially covered by the launcher's own mixed-manifest guard).
3. **`New-UserDeviceName` negative-length substring** — if `"$WH$LOC-"` ≥ 15
   chars (malformed map values), `Substring(0, $maxName)` throws
   `ArgumentOutOfRange` instead of the intended clean error. Guard `$maxName -le 0`.
4. **`Get-Department` / `Get-UserName` infinite loop on EOF** — `Read-Host`
   returns `""` forever when stdin is exhausted/redirected; the `do/until` spins.
   Bail out after N failed attempts or detect redirected input once (ties into F-05).
5. **`wt.exe` relaunch and `;`** — Windows Terminal's command line splits panes
   on `;`; a script path containing a semicolon breaks the `-File` relaunch.
   Exotic, but cheap to note next to the SEC-003 quote guard.
6. **GUI fallback double WMI work** — already flagged in the test comments;
   after F-01 is fixed, `Get-DeviceType` becomes a real cost twice per fallback
   run. Cache the pre-GUI detection result.

---

## What was checked and found sound

- ShouldProcess/-WhatIf plumbing end to end (launcher → orchestrator → GUI dry-run rides the same rails); `Rename-Computer` unreachable under -WhatIf — confirmed by tests and reading.
- SEC-003 quote refusal + per-path quoting (BUG-014) for the **-File** relaunch: correct as shipped (the iex path is F-02).
- Static-XAML/no-interpolation rule (ADR-008) holds; the zero-`$` Pester pin is a nice touch.
- Fail-closed posture: unpinned-SHA refusal, mixed-manifest refusal, unmapped-gateway throw in NonInteractive — all correct and tested.
- `-ne` hash comparison being case-insensitive in PowerShell makes the upper/lowercase hex mismatch between launcher (uppercase) and Get-Hashes (lowercase) benign at runtime.
- Wildcard-escape of `-Username`, LiteralPath usage, system-profile exclusions, log-never-blocks-rename discipline: all sound.

## Suggested next-session sequence

1. Fix F-01 (+ its regression test) — it invalidates every Gateway-mode name currently being produced.
2. Fix F-02 (+ round-trip test through a real `pwsh -Command`).
3. F-03: add `.gitattributes`, normalize EOLs, regenerate manifest — do this *before* the next pinned deployment.
4. F-04 CI matrix, then F-05–F-08 as a cleanup batch.
5. Update DECISIONS.md: retract the "parallel CIM ✅ Keep" row and amend BUG-014 with the F-02 correction, per the project's own "test every boundary you cross" lesson.
