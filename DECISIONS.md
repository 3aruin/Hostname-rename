# Hostname-Rename — Decisions Log

**Project:** Hostname-Rename  
**License:** MIT © 2026 Simms  
**Target:** v3 — clean, open GitHub release  
**Latest release:** v3.8.0 (2026-07-12) — see CHANGELOG.md  
**Log started:** 2026-04-28  

---

## Purpose of This Document

Records every architectural choice, known issue, and open question shaping v3.
Each entry includes the decision made (or the open question), the reasoning, and any action required.

---

## Current State — v2 Audit

Reviewed files: `launcher.ps1`, `network.ps1`, `device.ps1`, `naming.ps1`, `rename.ps1`, `tools/Get-Hashes.ps1`, `README.md`

### What is solid and should be kept

| Area | Verdict |
|---|---|
| Parallel module fetching via `Start-Job` in launcher | ✅ Keep — meaningfully cuts load time |
| SHA-256 manifest integrity check | ✅ Keep — core security model |
| Self-elevation with UAC-hop + parameter forwarding | ✅ Keep — well-implemented |
| Parallel CIM queries in `Get-DeviceType` | ❌ **Retracted (v3.8 review)** — `Get-CimInstance` has no `-AsJob` parameter on any edition; the "parallel" calls threw on line one and every device silently detected as `DT`. The claimed speedup never existed. Replaced with sequential queries (BUG-015) |
| 15-character name truncation logic in `New-DeviceName` | ✅ Keep — Windows NetBIOS limit compliance |
| 8-second timed mode prompt with `[Console]::KeyAvailable` | ✅ Keep — correct approach for console sessions; the non-console throw this wording glossed over was fixed in v3.8 (BUG-018) |
| Serial cleaning (`-replace '[^A-Za-z0-9]'`) | ✅ Keep |
| Entra UPN stripping in `Get-UserName` (`@` and `_` separators) | ✅ Keep |

---

## Decisions — Architecture

### ADR-001 · Module loading model: remote fetch + dot-source

**Status:** Accepted (carry forward to v3)  
**Decision:** Modules are fetched over HTTPS at runtime, hash-verified, then dot-sourced into the launcher's scope. No local install step is required.  
**Rationale:** Enables the one-liner `irm | iex` deployment pattern that is the primary use case. Hash pinning to a commit SHA compensates for the lack of a local file.  
**Constraint:** Every published change requires regenerating the manifest via `Get-Hashes.ps1` and committing before the URL is safe for production.

---

### ADR-002 · Pin to full commit SHA, never `main`

**Status:** Accepted (carry forward to v3)  
**Action:** ✅ CI lint step added in `.github/workflows/ci.yml` (job: `placeholder`) — fails any branch that pushes `launcher.ps1` with `REPLACE_WITH_COMMIT_SHA` still present. The check uses `continue-on-error: true` on `main` only, so the canonical repo can keep the default template state without breaking CI; all other branches get hard enforcement.  
**Decision:** The README and inline comments require deployments to pin to a full 40-character commit SHA in the `iwr` URL.  
**Rationale:** `main` is a moving target. A branch ref can be force-pushed. Commit SHAs are immutable; they are the only ref that makes the manifest hash check meaningful.

---

### ADR-003 · Naming modes: Gateway vs User

**Status:** Accepted (carry forward to v3)  
**Decision:** Two naming modes exist:
- **Gateway** — `{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}`
- **User** — `{WH}{LOC}-{Name}`

**Rationale:** Gateway mode is the standard, automation-friendly path. User mode handles edge cases (hot-desks, unassigned devices given to a specific person) without requiring a full naming schema.  
**Note:** The `-Folder` switch triggers User mode. README now correctly documents that it reads from `C:\Users` profile directories.

---

### ADR-004 · Organisation data lives in `network.ps1`, not a config file

**Status:** Accepted — implemented in v3  
**Decision (v2):** Gateway-to-site mappings and ORG codes are hardcoded in `$GATEWAY_MAP` inside `network.ps1`.  
**Problem for open source:** The file shipped with real internal IP ranges and the `RB` organisation code.  
**Decision for v3:** Replace real entries with clearly labelled example data using RFC 5737 documentation-range IPs. Add a `# -- CONFIGURE YOUR SITES HERE --` comment block. Add a configurable `$FALLBACK_CONTEXT` variable so fallback behaviour is also forkable without touching function code.  
**Implemented:** All six `10.72.x.x` entries replaced with `192.0.2.x`, `198.51.100.x`, and `203.0.113.x` ranges. Example ORG code is now `AC`. `$FALLBACK_CONTEXT` added as a named, commented variable.  
**Externalisation pattern:** ✅ Documented in `CONTRIBUTING.md` under "Externalising `$GATEWAY_MAP` to a separate file" — covers the `config.ps1` pattern, load order in `$MODULES`, and manifest implications.

---

### ADR-005 · No external dependencies

**Status:** Accepted (carry forward to v3)  
**Decision:** The tool uses only built-in PowerShell cmdlets and .NET types. No third-party modules.  
**Rationale:** Target machines may be freshly imaged; module availability cannot be assumed. The deployment model (MDM, `irm | iex`) makes dependency installation impractical.

---

### ADR-006 · ORG code must be exactly two characters

**Status:** Accepted — documented in v3  
**Decision:** The `ORG` segment in the Gateway naming scheme is constrained to exactly two characters.  
**Rationale:** Windows enforces a 15-character NetBIOS limit on hostnames. The full Gateway name `{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}` with minimum-length segments is `AA00A-AABB-0000` = exactly 15 characters when ORG is two characters. A three-character ORG pushes the full name to 16 characters, which `Rename-Computer` will reject.  
**Implication for naming:** Organisations should derive a two-character code from their full name (e.g. ACME Corporation → `AC`, Riverside Brick → `RB`). The fallback context ORG should also be two characters and visually distinct from any real site code (e.g. `XX`).  
**Documented in:** README Name Format section.

---

### ADR-007 · Logging lives in its own module and never blocks a rename

**Status:** Accepted — implemented in v3.1 (resolves OQ-001)  
**Decision:** Run logging is provided by a dedicated `logging.ps1` module exposing `Initialize-Log` and `Write-Log`. It is loaded **first** in `$MODULES` so the orchestrator can log throughout. All `Write-Log` calls live in `rename.ps1` (the orchestrator) only — the pure-logic modules (`network.ps1`, `device.ps1`, `naming.ps1`) take no logging dependency, which keeps them independently unit-testable (the main Pester suite dot-sources only those three, not `logging.ps1`; the v3.2 GUI suite dot-sources all six because it tests the orchestrator's wiring, but mocks `Initialize-Log`/`Write-Log` rather than exercising them).  
**Rationale:** A separate module matches the existing dot-source pattern (ADR-001) and the no-external-dependencies rule (ADR-005 — it uses only built-in cmdlets). Keeping logging out of the leaf modules means the test suite never needs `Write-Log` in scope.  
**Never-blocks principle:** `Initialize-Log` wraps directory creation in try/catch — on failure it warns once and disables logging for the run. `Write-Log` is a no-op when uninitialised and uses `Add-Content -ErrorAction SilentlyContinue`, so a transient write failure (e.g. a UNC share dropping mid-run) degrades to "no log line" rather than aborting. A device must still be renamed even when the log destination is unreachable.  
**Default destination:** `%TEMP%\Hostname-Rename\Hostname-Rename_<OLD-NAME>_<timestamp>.log`; `-LogPath` overrides the directory (local or UNC). Old computer name + timestamp keeps per-machine files distinct on a shared share and avoids concurrent-append contention.

---

### ADR-008 · Optional GUI: WPF, additive-only, GUI failure never blocks a rename

**Status:** Accepted — implemented in v3.2  
**Decision:** `-Gui` adds a `gui.ps1` module exposing `Show-RenameGui`, a WPF window that
collects the same inputs the console prompts collect (naming mode, department, type
override, profile selection) and hands them back to `Rename-DeviceSmart` as a hashtable.
`gui.ps1` never calls `Rename-Computer` — `rename.ps1` keeps sole ownership of the
`ShouldProcess` gate (ADR unchanged from OQ-002), so the GUI is purely a presentation
layer bolted onto the existing orchestration, not a parallel code path.  
**WPF, not WinForms:** consistent with ADR-005 (no third-party modules) —
`PresentationFramework` is a built-in .NET/Windows assembly, loaded via
`Add-Type -AssemblyName PresentationFramework` rather than a module dependency.
WPF also gives declarative markup (`XamlReader` lets a test smoke-parse the
whole layout without showing a window) where WinForms would mean hand-built
control trees with no equivalent static artefact to verify.  
**Opt-in switch, not the new default:** the primary deployment surface is the
MDM one-liner and the console (ADR-001); every v3.x release has promised that
existing invocations behave exactly as before, and defaulting to a window would
break that for every interactive run. No precondition probe can distinguish
"technician who wants a window" from "technician who wants the fast keyboard
flow", so the operator says so explicitly: `-Gui` is purely additive, and the
console path without it is byte-for-byte the v3.1 call sequence.  
**The window replaces the console Y/N confirmation:** the window's entire
content *is* the proposed rename — live preview, character count, and an
explicit **Rename device** button that is disabled until the inputs are valid.
A second console Y/N after clicking it would be a double-ask that trains
operators to hit Y reflexively, which devalues the confirmation everywhere
else. Cancel and the titlebar X are therefore handled identically to answering
`N` at the console prompt, and **Dry run** rides the existing `-WhatIf` rails.  
**Precondition + sentinel pattern:** `Show-RenameGui` checks `[Environment]::UserInteractive`,
thread apartment state (WPF requires STA), and that `PresentationFramework` loads, before
ever building the window; any failure — including an unexpected exception from the WPF
call stack itself — returns a `$script:GUI_UNAVAILABLE` sentinel (distinct from `$null`,
which means "operator cancelled"). `Rename-DeviceSmart` falls back to the existing console
prompts on the sentinel. **Rationale:** a GUI failure (missing WPF on Server Core, a
non-interactive MDM context, an odd host apartment state) must never be the reason a
device fails to get renamed — same never-block principle as ADR-007's logging design.  
**`-Gui` + `-NonInteractive` is a hard, immediate throw** (checked before any other work,
including `Initialize-Log`): a GUI cannot exist in an unattended session, and silently
picking one of the two contradictory switches would hide a deployment mistake until
devices came back wrongly named — same never-guess-in-automation philosophy as BUG-002.  
**XAML is static, single-quoted, and never receives interpolated data** (`Get-RenameGuiXaml`
returns a literal here-string containing zero `$` characters). Runtime values (profile
names, hostnames, serials, WMI model strings) are set via control properties
(`.Text`, `Items.Add`, `.Tag`) after `XamlReader::Parse`, never spliced into the markup —
XAML is executable (`ObjectDataProvider` and friends can invoke arbitrary code), so
string-building it from untrusted input would be an injection vector. Verified by a
dedicated Pester assertion (`tests/Hostname-Rename.Gui.Tests.ps1`) that greps the
returned XAML for `$` and expects none.  
**Preview logic kept WPF-free:** `Resolve-GatewayPreview` (department-drop / overflow
detection) is a pure function separate from `Update-RenameGuiPreview` (which only binds
results to controls), so it is unit-testable the same way as `Resolve-DeviceType` — no
WPF assembly needs to be loaded to test the decision logic itself.  
**`ET` stays manual-only:** thin clients / endpoint terminals expose no reliable
WMI signal (their chassis and model strings are indistinguishable from small
desktops), so `Resolve-DeviceType` never returns `ET` and no auto-detection is
attempted. The GUI's type dropdown keeps it selectable but labels it
`ET  (manual only -- never auto-detected)` rather than hiding it — same policy
as the console override prompt, made visible instead of tribal knowledge.  
**Constraints:** WPF needs an interactive desktop (`[Environment]::UserInteractive`)
and an STA thread — both probed up front (see the sentinel pattern above).
Supported on Windows PowerShell 5.1 and PowerShell 7 **on Windows only**;
`PresentationFramework` does not exist elsewhere, and the precondition probe is
what turns "unsupported platform" into a clean console fallback rather than a
crash. The XAML here-string is ASCII-only like every other `.ps1` content (the
BUG-010 lesson applies inside markup too).  
**Load order:** `gui.ps1` loads after `naming.ps1` (its live preview calls `New-DeviceName`
/ `New-UserDeviceName`) and before `rename.ps1` (which calls `Show-RenameGui`) — see
`$MODULES` in `launcher.ps1`.

---

### ADR-009 · Log retention prunes only the default log directory, never `-LogPath`

**Status:** Accepted — implemented in v3.3  
**Decision:** `Initialize-Log` prunes run logs older than `$script:LOG_RETENTION_DAYS`
(30 days) via the new `Remove-OldLogFile` helper, but **only when the log directory is
the default `%TEMP%\Hostname-Rename`**. An explicit `-LogPath` — local or UNC — is never
pruned.  
**Rationale:** the documented `-LogPath` use case (ADR-007) is a shared UNC log share
holding run logs from many machines. If every elevated machine pruned that share on
every run, (a) one machine would delete other machines' history, (b) retention there is
the share owner's policy, not this tool's, and (c) an elevated process deleting files on
a remote share is exactly the kind of surprising side effect SEC-004 exists to make
visible. The default `%TEMP%` directory, by contrast, is machine-local and this tool's
own — the only writer is us, and unbounded growth there was the actual problem
(CHANGELOG v3.3 idea).  
**Never-block rule inherited from ADR-007:** `Remove-OldLogFile` wraps everything in
`try/catch` and deletes with `-ErrorAction SilentlyContinue` — any failure degrades to
"old logs stay on disk", never to a blocked rename. Only files matching this tool's own
`Hostname-Rename_*.log` pattern are candidates, so a foreign file dropped into the
directory is never touched.  
**`SupportsShouldProcess`:** deletion is gated per-file by `$PSCmdlet.ShouldProcess`, so
a `-WhatIf` run (whose preference propagates from `Rename-DeviceSmart`) prunes nothing —
a dry run makes no changes of any kind, including housekeeping. Pinned by a Pester case.

---

## Known Bugs

### BUG-001 · `-FolderPath` and `-Username` parameters documented but not implemented

**Severity:** High — README documents parameters that do not exist in code  
**Status:** ✅ Fully resolved — docs corrected in v3 (Option 3), parameters **implemented in code in v3.1**  
**Location:** `README.md` (Available Parameters table) vs `launcher.ps1` (param block) vs `rename.ps1` (param block) vs `device.ps1 → Get-UserName`  

**Was:** README claimed `-FolderPath` and `-Username` as implemented parameters. Folder mode was described as "reads Desktop subfolders" — the implementation reads `C:\Users` profile directories.

**Resolution (Option 3 — Defer to v3.1):**
- `-FolderPath` and `-Username` moved to the bottom of the Available Parameters table, marked *(planned — v3.1)*
- `-Folder` description corrected: now documents `C:\Users` profile directory selection accurately
- No code changes required for this resolution; plumbing deferred to v3.1

**v3.1 resolution (implemented):** `-FolderPath [string]` and `-Username [string]` wired across the full call chain — `launcher.ps1` param block → `Rename-DeviceSmart` → `Get-UserName`. `-FolderPath` overrides the `C:\Users` search root (validated; throws if missing). `-Username` does a case-insensitive partial match: interactive shows the filtered list, NonInteractive picks the most recently active match (per the design decision for ambiguous matches), throwing if nothing matches. Either parameter implies User mode via `Select-NamingMode`. The launcher's `Invoke-SelfElevation` now single-quotes forwarded values so a path with spaces survives the UAC relaunch.

---

### BUG-002 · Fallback ORG code `RS` in `Get-NetworkContext` is org-specific

**Severity:** Medium  
**Status:** ✅ Resolved in v3 — Option D chosen  
**Location:** `network.ps1 → Get-NetworkContext`, `rename.ps1 → Rename-DeviceSmart`

**Was:**
```powershell
return @{ ORG = "RS"; WH = "XX"; LOC = "X" }
```
The fallback silently inserted `RS` (Riverside Brick's internal signal code) regardless of who was running the tool. Meaningless to any other organisation, and the silent behaviour was equally wrong in both interactive and automated deployments.

**Resolution (Option D — configurable fallback context + throw in NonInteractive):**

`network.ps1` — two changes:
1. Hardcoded fallback replaced with a named, configurable variable:
   ```powershell
   $script:FALLBACK_CONTEXT = @{ ORG = "XX"; WH = "99"; LOC = "X" }
   ```
   `ORG = "XX"` and `WH = "99"` are deliberate sentinel values — clearly not a real site, and queryable in AD/Intune. Users set their own "signal" ORG (e.g. Riverside Brick keeps `RS` as their fallback; ACME Corporation might use `AX`).

2. `Get-NetworkContext` gains a `-NonInteractive` switch with split behaviour:
   - **NonInteractive:** throws immediately with an actionable error message. A silently incorrect device name in an MDM deployment is worse than a hard stop — the gateway must be added to `$GATEWAY_MAP` before redeploying.
   - **Interactive:** emits a four-line `Write-Warning` block (blank warning lines above and below force yellow console output that cannot be missed), then returns `$FALLBACK_CONTEXT`. The technician gets a working name with sentinel values they can identify and correct later.

`rename.ps1` — one change: `-NonInteractive:$NonInteractive` forwarded to `Get-NetworkContext` so the throw/warn split works end-to-end. Inline comment explains the reason for the passthrough.

---

### BUG-003 · CIM job objects not cleaned up on detection error

**Severity:** Low  
**Status:** ✅ Resolved — fix confirmed in pre-launch audit (2026-04-30)  
**Location:** `device.ps1 → Get-DeviceType`

**Was:** Three separate named job variables (`$osJob`, `$csJob`, `$cpuJob`) each removed inline with `Remove-Job` immediately after `Receive-Job`. If any call threw before reaching its `Remove-Job`, that job object leaked for the duration of the session.

**Resolution:** `$jobs = @()` declared before the `try` block (guaranteeing `finally` always has a valid reference, even if `Get-CimInstance` throws before the array is assigned). All three jobs collected into the array in a single assignment inside `try`. Retrieved by index (`$jobs[0]`, `$jobs[1]`, `$jobs[2]`). A single `finally` block pipes the whole array to `Remove-Job -Force -ErrorAction SilentlyContinue`, cleaning up regardless of how the `try` block exited.

**Audit note (2026-04-30):** This fix was described in DECISIONS.md and marked ✅ Done, but a pre-launch code audit revealed the fix had never been applied to the file — `device.ps1` still contained the original three named job variables with inline `Remove-Job` calls and no `finally` block. The fix was applied for real at this point. When closing a bug, always verify the change is present in the actual file, not just described here.

---

### BUG-004 · `Get-UserName` uses partial `-Username` match description in comments but has no such parameter

**Severity:** Low — internal comment inconsistency, linked to BUG-001  
**Status:** ✅ Resolved in v3 — closed alongside BUG-001  
**Location:** `device.ps1 → Get-UserName` `.SYNOPSIS` / README `-Username` description  
**Resolution:** README updated to mark `-Username` as planned v3.1 (v3). In v3.1 the parameter is implemented, so the `.SYNOPSIS` now describes a real, matching parameter — the comment/code inconsistency is fully closed.

---

### BUG-005 · Null/empty gateway produces a misleading error message

**Severity:** Low  
**Status:** ✅ Resolved in pre-launch audit (2026-04-30)  
**Location:** `network.ps1 → Get-DefaultGateway`, `network.ps1 → Get-NetworkContext`

**Was:** `Get-DefaultGateway` returns `$null` when no enabled network adapter has a default gateway. PowerShell hashtable lookups on `$null` return `$null` silently, so execution fell through to the GATEWAY_MAP error path. The resulting message read:

```
Gateway '' was not found in GATEWAY_MAP. Add it to network.ps1 and redeploy. ...
```

An empty-string gateway is not a missing map entry — it means the device has no network connection. The error was technically correct but pointed the operator at the wrong fix.

**Resolution:** `Get-NetworkContext` now opens with an `[string]::IsNullOrEmpty($Gateway)` guard that throws before the map lookup with the message:

```
No default gateway was detected on this machine. Ensure the device has a
network connection before running this tool.
```

This condition is treated as always-fatal (no interactive/NonInteractive split) since no gateway means the tool cannot determine location under either mode.

---

### BUG-006 … BUG-011 · v3.0.1 CI hardening (summary)

**Status:** ✅ All resolved in v3.0.1. Full blow-by-blow in CHANGELOG.md → [3.0.1].

These surfaced sequentially: each fix unblocked the next CI failure (the `lint → test`
job dependency hid later failures behind earlier ones). Recorded here so the audit
trail is complete; only the durable lessons are repeated:

- **BUG-006** — `placeholder` CI step inherited the global `pwsh` shell and failed to parse a bash one-liner; fixed with an explicit `shell: bash`. Masked on `main` by ADR-002's `continue-on-error`.
- **BUG-007** — `Get-Hashes.ps1` framing moved off `Write-Host` onto the success stream (lint compliance + fixes a redirection-capture bug).
- **BUG-008** — Pester v5 `-Configuration` and `-PassThru` are mutually exclusive; switched to `$cfg.Run.PassThru = $true`.
- **BUG-009** — analyzer pass: interactive `Write-Host` and the pure `New-*` builders suppressed *with justifications* (not a blanket settings file); three files given a UTF-8 BOM because PS 5.1 reads BOM-less non-ASCII as Latin-1.
- **BUG-010** — **Lesson: keep new code ASCII-only unless the file already contains non-ASCII.** A SuppressMessage justification I added contained em dashes, which pushed two ASCII files into "needs a BOM" territory. v3.1 takes this further (see below).
- **BUG-011** — once the test job finally ran, an orphan `InModuleScope` and a `$fn` discovery/run-scope helper were fixed. A `# TODO (v3.1)` was left: refactor `Get-SerialLast4` so its cleaning logic lives in a WMI-free helper the tests can call directly. **Done in v3.1.**

---

### v3.1 · Resolution of the BUG-009/010/011 threads

**Status:** ✅ Resolved in v3.1.

- **BOM thread closed.** `network.ps1`, `rename.ps1`, and the test file were converted to ASCII-only (em dashes / arrows / box-drawing → `--` / `->`) and their BOMs removed. The repo is now uniformly ASCII; **no file requires a UTF-8 BOM**, retiring the whole `PSUseBOMForUnicodeEncodedFile` concern (the natural endpoint of the BUG-010 lesson).
- **BUG-011 follow-up done.** The cleaning logic now lives in pure, WMI-free helpers — `ConvertTo-SerialLast4` (serial) and `ConvertTo-CleanUserName` (profile name) — and the type-decision chain in `Resolve-DeviceType`. The Pester suite calls these **real** functions instead of inline copies, so the prior `$script:`-scope scriptblock workaround (the `PSUseDeclaredVarsMoreThanAssignments` false positive) is gone.

---

### BUG-012 · `Write-Log` flagged by `PSAvoidOverwritingBuiltInCmdlets` — analyzer false positive

**Severity:** Low — blocks the analyzer-clean gate, no runtime effect  
**Status:** ✅ Resolved — found and fixed during the `-Gui` feature review (v3.2)  
**Location:** `logging.ps1 → Write-Log`

**Was:** `Invoke-ScriptAnalyzer` running under PowerShell 7 / `pwsh` reported
`PSAvoidOverwritingBuiltInCmdlets` against `Write-Log`, claiming it "is a cmdlet
that is included with PowerShell (version core-6.1.0-windows) whose definition
should not be overridden." The same scan run under Windows PowerShell 5.1
reports nothing.

**Investigated:** `Get-Command Write-Log -ErrorAction SilentlyContinue` returns
nothing on either PS 7.6 or Windows PowerShell 5.1 — no such cmdlet actually
exists on any edition this project targets (ADR-005: no third-party modules
means nothing could have installed one either). The rule is comparing against
PSScriptAnalyzer's own bundled `core-6.1.0-windows` compatibility-profile JSON,
which apparently lists a `Write-Log` command that was never real, or belonged
to a module not present here. Confirmed false positive, not a naming collision
worth renaming the function over.

**Resolution:** Inline `[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', ...)]`
on `Write-Log` with a justification recording the `Get-Command` verification,
per the BUG-009 approach (suppress with justification, not a blanket settings
file). Re-verified clean with `Invoke-ScriptAnalyzer` on both PS 7.6 and
Windows PowerShell 5.1 after the fix.

**Why this matters for CI:** the `lint` job's steps all hardcode `shell: pwsh`
(see BUG-013 below), so every `lint` run — regardless of which matrix leg it
claims to be — hit this warning. Without the fix, `lint` fails on every push
until the underlying matrix issue (BUG-013) is also addressed.

---

### BUG-013 · CI forecast for this branch does not match the pipeline's literal behaviour

**Severity:** Low — CI hygiene, no functional impact on the tool itself  
**Status:** ✅ Resolved in v3.8 review pass — (a) fixed per F-04 (operator chose "make the 5.1 leg real" over deleting the matrix): the lint **and** test jobs now use a `matrix.include` pairing `ps-version` with `shell` (`powershell` = real Windows PowerShell 5.1, `pwsh` = PS 7.x), so both legs genuinely run under their labelled edition; the 5.1 test leg needs `Install-Module Pester -SkipPublisherCheck` (5.1 ships Pester 3.4 under a different certificate). (b) fixed per F-08.2: the manifest job now *fails* when a pinned SHA has zero parsable hash entries (see BUG-021.2). Full suite verified green under both editions locally (95/95 each).  
**Location:** `.github/workflows/ci.yml`

Two independent issues surfaced while verifying (per the BUG-003 audit lesson —
against the actual file, not the assumption) what the four CI jobs would
actually do on an unreleased branch:

**(a) `lint` job's PS-version matrix is a no-op.** `strategy.matrix.ps-version`
is declared as `["5.1", "latest"]`, but every step in the job hardcodes
`shell: pwsh`, never referencing `${{ matrix.ps-version }}`. Both matrix legs
therefore run identically under PowerShell 7 — the "5.1" leg has never actually
executed `Invoke-ScriptAnalyzer` (or anything else) under real Windows
PowerShell 5.1. This is exactly how BUG-012 went unnoticed: it only reproduces
under `pwsh`, and the job that's labelled as covering 5.1 never touches it.

**(b) `manifest` job silently passes when `$MANIFEST` is all placeholders,
rather than failing.** The job's hash-extraction regex requires a 64-hex-char
value (`"(?<hash>[a-f0-9]{64})"`); `REPLACE_WITH_HASH` never matches it. On a
branch where every `$MANIFEST` entry is still a placeholder (the normal state
for in-progress work), the regex match count is 0, which hits the job's own
`Write-Warning "No hash entries found ... skipping check"` → `exit 0`. The job
reports success, not because anything was verified, but because nothing was
checked. Confirmed by running the exact regex against the actual `launcher.ps1`
content (0 matches) rather than assuming the documented "fails until hashes are
regenerated" behaviour was still accurate.

**Why not fixed here:** both are pre-existing `ci.yml` behaviour, unrelated to
the `-Gui` feature itself, and changing CI semantics (making 5.1 genuinely run
under Windows PowerShell, making `manifest` fail loudly on all-placeholder
input) is a deliberate call for whoever owns the pipeline, not a silent
drive-by fix bundled into a feature review.

**Suggested fix, if adopted:** (a) branch the lint job's shell selection on
`${{ matrix.ps-version == '5.1' && 'powershell' || 'pwsh' }}` (or split into
two explicit jobs); (b) have the `manifest` job fail (or at least warn loudly
in a way that's visible in the PR check, not just job logs) when every entry is
still `REPLACE_WITH_HASH` on a non-`main` branch, mirroring the `placeholder`
job's `continue-on-error` scoping in ADR-002.

---

### BUG-014 · `Invoke-SelfElevation` single-quoted forwarded values on the `-File` relaunch path, where single quotes are literal

**Severity:** Medium — parameter forwarding across the UAC relaunch was broken for the saved-script case  
**Status:** ✅ Fixed in v3.3 — `launcher.ps1`  
**Location:** `launcher.ps1` → `Invoke-SelfElevation`

**Was:** v3.1 (checklist item 18) wrapped every forwarded parameter value in single
quotes (embedded `'` doubled) and used that one token list for **both** relaunch paths.
That is correct for the `iex` path, where the tokens are spliced into a
`-Command "..."` string and parsed by PowerShell (single quotes are PowerShell syntax
there). But the `-File` path hands the tokens to the **native command line**, where
`CommandLineToArgvW` treats double quotes as grouping and single quotes as *literal
characters*. Result, verified empirically on PS 5.1 and 7:

- a `[string]` value arrived quote-wrapped (`-FolderPath 'D:\Profiles'` bound as
  `'D:\Profiles'` — literal quotes included — so `Test-Path` then failed), and a value
  **with spaces** was split into multiple tokens (`'D:\My` + `Profiles'`), breaking
  parameter binding entirely;
- a non-string value failed to bind outright (`Cannot convert value "'12'" to type
  "System.Int32"`), which would have broken the new `-PromptTimeoutSeconds` on every
  non-elevated saved-script run.

The bug was masked because the common deployment path is the `iex` one-liner (correct
quoting) or an already-elevated session (no relaunch at all).

**Resolution:** `Invoke-SelfElevation` now builds two token lists in the same loop —
`$fileArgs` (values wrapped in double quotes, which the native parser strips; embedded
double quotes are already refused by the SEC-003 guard, so this is always safe) and
`$iexArgs` (single-quoted with `''` doubling, unchanged) — and each relaunch path uses
its own list. Verified by driving both quoting shapes through a real
`powershell.exe -File` / `-Command` round-trip with a spaced path and an `[int]` value.

**Lesson (BUG-003/BUG-013 pattern again):** "quoted so it survives both relaunch paths"
was asserted in v3.1 but only ever exercised on one of the two paths. Anything that
crosses a process boundary needs to be tested on every boundary it crosses.

**Amendment (v3.8 review — BUG-016):** the "iex path quoting is correct" claim above was
itself only half-verified. The quoting of `$iexArgs` is correct, but the tokens were
spliced after an `iex (irm ...)` call, where `Invoke-Expression`'s single-`-Command`
signature makes any trailing token a binding error — no quoting could ever make them
bind. Parameter forwarding on the iex relaunch path therefore never worked; see BUG-016.

---

### BUG-015 · `Get-CimInstance -AsJob` does not exist — device type detection was dead code

**Severity:** Critical — silent wrong output on every real device in the primary MDM path  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-01)  
**Location:** `device.ps1 → Get-DeviceType`

**Was:** the four "parallel CIM queries" (v3.1, OQ-003 era) called
`Get-CimInstance ... -AsJob`. That parameter does not exist on either PowerShell
edition, so the first line of the `try` block threw a parameter-binding error, the
blanket `catch` swallowed it behind a generic "WMI query failed" warning, and **every
device detected as `DT`** — laptops, tablets, VMs, and servers alike, silently
mis-named in every Gateway/NonInteractive run since the code shipped. The pure
`Resolve-DeviceType` chain was correct and fully tested; it just never received real
data, because the tests mock `Get-DeviceType` or call `Resolve-DeviceType` directly
and PSScriptAnalyzer does not validate parameter names.

**Resolution:** four plain sequential `Get-CimInstance` calls (each is tens of
milliseconds locally — the "~2/3 detection time reduction" claimed in the v2 audit was
never real and that row is retracted above). The `catch` warning now includes
`$_.Exception.Message` so a binding error can never masquerade as a WMI failure again.
Two regression guards in `tests/Hostname-Rename.Tests.ps1`: an AST check that every
parameter passed to `Get-CimInstance` in `device.ps1` actually exists on the cmdlet,
and a real no-mock run of `Get-DeviceType -NonInteractive` asserting no warning is
emitted and the result is a valid type code.

**Lesson (BUG-014's lesson, again, harder):** the WMI-collection seam was the one
place the test suite deliberately never executed — and it was exactly where the bug
lived. A "pure logic fully tested, thin shell untested" split still needs one honest
end-to-end execution of the shell.

---

### BUG-016 · Elevation relaunch via `iex` could not forward parameters at all

**Severity:** High — broke the documented parameterized one-liner for non-admin users  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-02)  
**Location:** `launcher.ps1 → Invoke-SelfElevation`

**Was:** the iex-path relaunch built `"iex (irm '$escapedUrl') $($iexArgs -join ' ')"`.
`Invoke-Expression` takes a single `-Command` parameter, so every appended token —
switch or value — was a parameter-binding error against `Invoke-Expression` itself,
never an argument to the downloaded script. A non-admin `iex` one-liner with any
parameter (e.g. `-NonInteractive -Gateway`) hit UAC, opened the elevated window, and
died on the binding error (under `wt.exe`, closing before it could be read). The
zero-parameter one-liner worked, which is why this survived; BUG-014 fixed the
*quoting* of `$iexArgs` but never executed the constructed command.

**Resolution:** the relaunch now builds
`"& ([scriptblock]::Create((irm '$escapedUrl'))) $($iexArgs -join ' ')"` — the exact
form the launcher's own header documents for parameterized one-liners. The existing
single-quote escaping of `$iexArgs` is correct for this form, and the SEC-003
double-quote refusal applies unchanged. Regression guards in
`tests/Hostname-Rename.Tests.ps1`: a static assertion that the scriptblock form (not
the argument splice) is what `launcher.ps1` builds, plus a round-trip that executes
the same command shape through a real child `-Command` process and asserts a spaced
string, a switch, and an `[int]` all bind (verified on PS 7.6 and Windows
PowerShell 5.1).

---

### BUG-017 · Hash manifest pipeline was line-ending-sensitive, and the tree itself had mixed EOLs

**Severity:** High — deployment integrity mechanism could brick fleet-wide or silently drift  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-03)  
**Location:** `tools/Get-Hashes.ps1`, `.github/workflows/ci.yml` (manifest job), repo-wide EOL state

**Was:** three parties hash "the same" module — `Get-Hashes.ps1` (local working copy),
the CI manifest job (Actions checkout), and `launcher.ps1` at runtime (bytes served by
`raw.githubusercontent.com`). SHA-256 over text is CRLF/LF-sensitive, no
`.gitattributes` existed, and the tree itself was mixed (`device.ps1`, `logging.ps1`,
`network.ps1` CRLF; the other four modules LF). A dev with `core.autocrlf=true`
regenerating `$MANIFEST` from a CRLF working copy while GitHub raw serves LF would
fail the hash check on **every device** — fail-closed, but a fleet-wide outage of the
tool. The `Get-Hashes.ps1` comment ("read raw bytes") was also inaccurate:
`Get-Content -Raw -Encoding UTF8` decodes and re-encodes (EOL-preserving, not
byte-preserving — BOM stripped).

**Resolution:**
1. `.gitattributes` added — `* text=auto` plus `*.ps1 text eol=lf`, matching what
   GitHub raw serves from a normalized repo. All seven modules normalized to LF on
   disk. **Note:** this tree is not a git working copy; when it lands in the repo,
   run `git add --renormalize .` once (called out in `.gitattributes` itself).
2. `Get-Hashes.ps1` and the CI manifest job both hash raw on-disk bytes
   (`[IO.File]::ReadAllBytes`), making them byte-identical with each other and with
   what GitHub serves. The launcher's decoded-string hash matches those bytes as long
   as modules stay ASCII, BOM-free, and LF — `Get-Hashes.ps1` now warns explicitly if
   a file has a BOM or CRLF, instead of emitting a hash that cannot match at runtime.
3. `$MANIFEST` regeneration: not needed — every entry is still `REPLACE_WITH_HASH`
   in this tree; the next real pin will be produced by the byte-exact hasher.

---

### BUG-018 · `Select-NamingMode` crashed when console input is redirected

**Severity:** Low-Medium  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-05)  
**Location:** `naming.ps1 → Select-NamingMode`

**Was:** `[Console]::KeyAvailable` throws `InvalidOperationException` when stdin is
not a real console (piped input, some remoting hosts, some RMM agents). With the
launcher's `$ErrorActionPreference = "Stop"`, the run died instead of taking the
documented Gateway default. The v2 audit accepted the approach "for console
sessions"; the gap was that non-console sessions hit an unhandled throw.

**Resolution:** the poll loop is wrapped in `try/catch [InvalidOperationException]`
— redirected input now announces itself and falls through to the Gateway default,
the same outcome as the timeout. Regression test: a child PowerShell with piped
stdin (exactly the throwing state) runs `Select-NamingMode` and must exit 0 with
`Gateway`.

---

### BUG-019 · `Get-DefaultGateway` picked an arbitrary adapter and could return IPv6

**Severity:** Low-Medium — wrong-site mapping on multi-homed machines  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-06)  
**Location:** `network.ps1 → Get-DefaultGateway`

**Was:** "first enabled adapter with a gateway" — `Win32_NetworkAdapterConfiguration`
order is not metric-ordered, so a VPN or second NIC could win by enumeration luck,
producing an unmapped gateway (fallback/throw) or a *mapped but wrong* site.
`DefaultIPGateway` can also contain IPv6 literals that can never match the
IPv4-keyed `GATEWAY_MAP`.

**Resolution:** the primary path is now `Get-NetRoute -DestinationPrefix 0.0.0.0/0`
sorted by effective metric (`RouteMetric + InterfaceMetric` — the sum Windows uses
for route selection; note the property is `InterfaceMetric`, the `ifMetric` column
name suggested in the review is display-only and `Sort-Object` on a nonexistent
property silently does not sort). Verified against `Find-NetRoute` on a
dual-route machine (VPN + Wi-Fi): the function now returns exactly the next-hop
Windows itself routes through. The legacy CIM query stays as a fallback, filtered
to IPv4 literals. Deterministic consequence: on a full-tunnel VPN the VPN gateway
*is* the answer — unmapped means fail-closed in NonInteractive, which beats a
silently wrong site.

---

### BUG-020 · Module fetch could hang an unattended run forever

**Severity:** Low  
**Status:** ✅ Fixed in v3.8 review pass (REVIEW-FINDINGS.md F-07)  
**Location:** `launcher.ps1` fetch loop

**Was:** `Invoke-WebRequest` defaults to *no* timeout and `Receive-Job -Wait` waits
indefinitely — a stalled connection hung an unattended MDM run forever with no error.

**Resolution:** `-TimeoutSec 60` inside the fetch job bounds the transfer, and the
collection side now uses `Wait-Job -Timeout 90` with a clear throw if the job
itself wedges. Both bounds feed the existing "Failed to fetch …" error path.

---

### BUG-021 · v3.8 minor batch (REVIEW-FINDINGS.md F-08)

**Status:** ✅ All six fixed in v3.8 review pass

1. **UAC decline** — `Start-Process -Verb RunAs` threw a raw "operation was
   canceled by the user" (invisible under `wt.exe`, whose window closes
   immediately). Now caught and rethrown with a clear instruction
   (`launcher.ps1 → Invoke-SelfElevation`).
2. **CI manifest regex** — `[a-f0-9]{64}` silently *skipped* verification of an
   uppercase-pasted hash; now `[a-fA-F0-9]`. And a pinned `$COMMIT_SHA` with zero
   parsable manifest entries now **fails** the job instead of warning — a green
   check that verified nothing was BUG-013(b)'s exact failure mode (`ci.yml`).
3. **`New-UserDeviceName` negative-length substring** — a malformed `GATEWAY_MAP`
   (oversized WH/LOC) hit `ArgumentOutOfRange` from `Substring`; now a clean
   guard throw naming the cause (`naming.ps1`). Pinned by a test.
4. **`Get-Department` / `Get-UserName` infinite loop on EOF** — `Read-Host`
   returns `""` forever on exhausted/redirected stdin and the `do/until` spun for
   eternity; both loops now throw after 10 attempts with a pointer to
   `-NonInteractive` / `-Username` (`device.ps1`). Pinned by mocked-`Read-Host` tests.
5. **`wt.exe` semicolon splitting** — Windows Terminal splits its command line
   into panes on `;`; both relaunch paths now escape `;` as `\;` (wt's own escape)
   so a path or forwarded value containing a semicolon survives (`launcher.ps1`,
   noted alongside the SEC-003 quote refusal).
6. **GUI-fallback double WMI work** — the console fallback after `GUI_UNAVAILABLE`
   re-ran `Get-DeviceType` and `Get-SerialLast4`, a real cost once BUG-015 made
   detection work. `Get-DeviceType` gains `-Detected` (skips the WMI queries,
   keeps the console override prompt; invalid values are ignored, never trusted)
   and `rename.ps1` reuses the pre-GUI probe's type and serial. The GUI contract
   test now pins the single-fetch behaviour (`device.ps1`, `rename.ps1`,
   `tests/Hostname-Rename.Gui.Tests.ps1`).

---

## Security Findings — v3.2 threat hunt

A dedicated adversarial pass over the `-Gui` branch (2026-07-10), closing the
last open pre-release item from the GUI review. Scope was the whole run path an
elevated launcher exercises — fetch, hash check, UAC relaunch, parameter
forwarding, logging, profile enumeration — not just `gui.ps1`, which is why
most findings land outside the GUI module. The GUI-specific design itself held:
the static-XAML/no-interpolation rule (ADR-008) was probed and confirmed, and
the `Get-RenameGuiXaml` zero-`$` Pester assertion now pins it against
regression. Five findings, all resolved in v3.2.0.

### SEC-001 · Unpinned launcher ran unverified code elevated, by default

**Severity:** High — remote code execution as admin with no integrity check  
**Status:** ✅ Resolved in v3.2  
**Location:** `launcher.ps1`

**Was:** with `$COMMIT_SHA` still `REPLACE_WITH_COMMIT_SHA` (the repo's shipped
state), the launcher emitted one `Write-Warning` and then fetched every module
from `main` — a mutable, force-pushable ref — with every `$MANIFEST` entry a
placeholder, so **no hash was checked**, and dot-sourced the results into a
process it had just self-elevated. Anyone who could change what `main` serves
(repo compromise, upstream of a fork that never re-pointed `$REPO_BASE`) got
arbitrary code as admin on every device that ran the unpinned one-liner. The
warning was easy to script past and invisible under `iex`.

**Resolution:** the unpinned state now **throws** with an actionable message
(pin a SHA and fill `$MANIFEST`, per README → Deployment Workflow). A new
`-AllowUnverified` switch is the explicit development-only opt-in and still
warns loudly. A correctly pinned production/MDM deployment never hits the
guard. This is v3.2.0's only behaviour change, and it is deliberate — the same
fail-closed philosophy as BUG-002: a hard stop beats a silent integrity gap.

### SEC-002 · Half-regenerated manifest loaded some modules unverified

**Severity:** Medium — silent partial bypass of the core integrity model  
**Status:** ✅ Resolved in v3.2  
**Location:** `launcher.ps1`

**Was:** the per-module hash check skips entries still holding
`REPLACE_WITH_HASH`. Correct for the all-placeholder dev state, but it also
meant a *pinned* deployment whose maintainer forgot to regenerate one line —
exactly the mistake adding a new module like `gui.ps1` invites — verified five
modules and silently dot-sourced the sixth unverified, elevated. Nothing
reported the gap; the run looked fully verified.

**Resolution:** fail closed on mixed manifests. Once `$ref` is a real pinned
SHA, any remaining placeholder entry aborts before anything is fetched, naming
the offending entries and pointing at `Get-Hashes.ps1`. The all-placeholder dev
state (with `-AllowUnverified`, per SEC-001) is unaffected. Note the CI
`manifest` job would not have caught this either — see BUG-013(b).

### SEC-003 · Double-quote in a forwarded parameter breaks out of the elevation relaunch command

**Severity:** Medium — command injection into the elevated relaunch  
**Status:** ✅ Resolved in v3.2  
**Location:** `launcher.ps1 → Invoke-SelfElevation`

**Was:** forwarded parameter *values* are single-quoted (embedded `'` doubled)
— the v3.1 fix for spaces (checklist item 18). But on the `iex` relaunch path
the entire rebuilt command line rides inside `-Command "..."`, where an
embedded **double**-quote in a value terminates the outer string; everything
after it is parsed as new arguments/commands **in the elevated process**.
Single-quoting cannot neutralise that: the `"` matters to the outer
command-line parser, not to PowerShell's string rules. Exploiting it requires
influencing a parameter value (e.g. a deployment template substituting an
untrusted value into `-FolderPath`), so this is an injection *primitive* rather
than a remotely reachable hole — but the elevated context makes it worth
closing outright.

**Resolution:** `Invoke-SelfElevation` rejects any forwarded value containing
`"` with a clear error, before building the relaunch command. Windows paths,
usernames, and the allow-listed dept/type tokens never legitimately contain a
double-quote, so refusal costs nothing; emitting a "sanitised" approximation
would be the never-guess-in-automation anti-pattern (BUG-002).

### SEC-004 · UNC `-LogPath` / `-FolderPath` silently authenticate the elevated machine to a remote host

**Severity:** Low — NTLM credential exposure requires a hostile/spoofed share  
**Status:** ✅ Resolved in v3.2 (surfaced, by design not blocked)  
**Location:** `logging.ps1 → Initialize-Log`, `rename.ps1 → Rename-DeviceSmart`

**Was:** pointing `-LogPath` (a documented feature — ADR-007's UNC log share)
or `-FolderPath` (redirected profiles) at a UNC path makes every log write /
profile enumeration perform an SMB NTLM handshake from an **elevated** session
to whatever host the value names. A hostile or spoofed share can capture or
relay that handshake. Nothing surfaced this; a mistyped or coerced UNC value
leaked silently.

**Resolution:** both paths now emit a prominent `Write-Warning` naming the
mechanism ("authenticates this machine to that host over SMB (NTLM)"), and the
`-FolderPath` case also writes a WARN log line. Warn-not-block is deliberate:
UNC log shares are a supported, documented workflow, and the operator — not
the tool — knows which shares are trusted. The `-FolderPath` warning fires
once, up front in `Rename-DeviceSmart`, so it covers the GUI pre-enumeration
and the console `Get-UserName` path alike.

### SEC-005 · `-Username` matched as a wildcard pattern instead of a literal

**Severity:** Low — wrong-profile selection needs attacker influence over the value *and* NonInteractive  
**Status:** ✅ Resolved in v3.2  
**Location:** `device.ps1 → Get-UserName`, `rename.ps1` (GUI candidate pre-enumeration)

**Was:** the profile filter was `-like "*$Username*"`, so wildcard
metacharacters (`*`, `?`, `[…]`) in the value were interpreted as a pattern.
A value like `*` matches every profile; under `-NonInteractive` the most
recently active match is auto-picked and becomes the device name with no human
in the loop. Same class of bug in the GUI's candidate list, which mirrors
`Get-UserName`'s rules.

**Resolution:** both call sites now build the pattern with
`[System.Management.Automation.WildcardPattern]::Escape($Username)`, so the
value is matched as a literal substring — GUI and console lists stay
identical by construction. Profile enumeration also moved from `-Path` to
`-LiteralPath` (here and in `Get-UserName`) so bracket characters in a
`-FolderPath` value cannot glob either.

---

## Open Questions for v3

### OQ-001 · Should logging be implemented?

**Background:** No logging code exists anywhere in the codebase. The README previously listed "Network access to log share *(optional)*" under Requirements — this entry has been removed in v3 as there is nothing to back it up. The question of whether logging should be added remains open.  
**Options:**
- A. Skip logging entirely and remove the README mention
- B. Add a lightweight `Write-Log` wrapper that writes to a UNC path if reachable, local temp otherwise
- C. Add optional `-LogPath [string]` parameter

**Recommendation (at v3):** Option B with Option C as the override.  
**Decision (v3.1):** Default **on**, writing to `%TEMP%\Hostname-Rename`, with `-LogPath` overriding the directory (local or UNC). This is Option C made default-on rather than the originally-recommended Option B (no "UNC-if-reachable-else-temp" probing — a single, predictable default that `-LogPath` redirects). Logging never blocks a rename. Implemented as the `logging.ps1` module (see ADR-007).  
**Status:** ✅ Resolved in v3.1 — `logging.ps1` (`Initialize-Log` / `Write-Log`)

---

### OQ-002 · Should there be a dry-run / `-WhatIf` mode?

**Background:** `Rename-Computer` supports `-WhatIf` natively. The orchestrator does not expose it.  
**Value:** Useful for MDM testing — verify what name *would* be generated without actually renaming.  
**Recommendation:** Add `[CmdletBinding(SupportsShouldProcess)]` to `Rename-DeviceSmart` and pass `-WhatIf:$WhatIfPreference` to `Rename-Computer`.  
**Decision (v3.1):** Implemented. `Rename-DeviceSmart` gates the rename with `$PSCmdlet.ShouldProcess`; under `-WhatIf` the interactive Y/N prompt is skipped and the intended rename is reported (logged as a `WhatIf:` line). `launcher.ps1` also declares `SupportsShouldProcess` and forwards `-WhatIf:$WhatIfPreference` so a dry run works through the `iex` / scriptblock deployment surface; a `PSShouldProcess` suppression on the launcher documents that the actual gate lives downstream.  
**Status:** ✅ Resolved in v3.1

---

### OQ-003 · Should `Get-DeviceType` detect tablets / Surface / convertibles?

**Background:** The current detection chain covers VM, Server, ARM/Mobile, Laptop, Desktop. Tablet/Surface form factors (e.g., Windows tablets, Surface Go) may fall through to `DT`.  
**Detection signal:** `Win32_SystemEnclosure.ChassisTypes` includes types 30 (Tablet) and 31 (Convertible).  
**Recommendation:** Add as an optional enhancement; does not block v3.  
**Decision (v3.1):** Implemented as a new `TB` type for both Tablet (chassis 30) and Convertible (chassis 31), added alongside `PB` (Pizza Box, chassis 5). `Get-DeviceType` now fires a fourth parallel CIM query (`Win32_SystemEnclosure`) and delegates to the pure `Resolve-DeviceType`. Priority chain: `VM > SV > TB > MD > LT > PB > DT` — `SV` before the chassis tests so a server OS always wins; `TB` before `MD` so an ARM convertible is recorded by its form factor.  
**Status:** ✅ Resolved in v3.1 — `PB` + new `TB` type

---

### OQ-004 · Should the naming mode timed prompt timeout be configurable?

**Background:** The 8-second timeout in `Select-NamingMode` is hardcoded.  
**Value:** Teams with slow startup environments may want more time; MDM users never need it.  
**Recommendation:** Low priority. The `-NonInteractive` flag already bypasses the prompt entirely. Leave hardcoded for now; documented as a "fork and adjust" customisation point in `CONTRIBUTING.md`.  
**Decision (v3.3):** Implemented as `-PromptTimeoutSeconds` (`[int]`, default 8 — unchanged behaviour when omitted, `ValidateRange(1, 300)`), forwarded `launcher.ps1` → `Rename-DeviceSmart` → `Select-NamingMode`. Console-only by design: the GUI window has no timed prompt, and `-NonInteractive` still skips the prompt entirely. Fixing BUG-014 was a prerequisite — an `[int]` could not previously survive the `-File` elevation relaunch at all.  
**Status:** ✅ Resolved in v3.3 — `-PromptTimeoutSeconds`

---

### OQ-005 · GitHub Actions CI pipeline

**Background:** No CI existed. For a public repo, some automation is expected.  
**Status:** ✅ Implemented — `.github/workflows/ci.yml` added (2026-04-30)

**Delivered — four jobs:**

| Job | What it does |
|---|---|
| `lint` | PSScriptAnalyzer on all `.ps1` files, targeting PS 5.1 and 7.x via matrix |
| `test` | Pester v5 unit tests in `./tests/`, uploads NUnit XML results as an artifact |
| `manifest` | Parses `$MANIFEST` from `launcher.ps1` and recomputes SHA-256 for each module file; fails if any hash mismatches |
| `placeholder` | Fails any branch pushing `launcher.ps1` with `REPLACE_WITH_COMMIT_SHA` present; `continue-on-error: true` on `main` only |

The `manifest` job supersedes the manual `Get-Hashes.ps1` verification step for PRs — it catches the case where module files are changed but `launcher.ps1` is not updated before merge.

---

## v3 Change Checklist

| # | Item | Type | Priority | Status |
|---|---|---|---|---|
| 1 | Replace org-specific gateway data with RFC 5737 example IPs | Open-source hygiene | **Critical** | ✅ Done — `network.ps1` |
| 2 | Fix BUG-001: implement `-FolderPath` and `-Username` params OR remove from docs | Bug / Doc | **High** | ✅ Done — Option 3, marked planned v3.1 in README |
| 3 | Fix BUG-002: replace `RS` fallback ORG code with generic sentinel | Bug | **High** | ✅ Done — `network.ps1`, `rename.ps1` |
| 4 | Fix BUG-003: CIM job cleanup in `catch` block | Bug | Medium | ✅ Done — `device.ps1` (fix confirmed in pre-launch audit 2026-04-30; was described but not applied earlier) |
| 10 | Correct README description of Folder mode (Desktop vs C:\Users) | Doc | **High** | ✅ Done — `README.md` |
| 6 | Add GitHub Actions CI with PSScriptAnalyzer + Pester (OQ-005) | Infra | Medium | ✅ Done — `.github/workflows/ci.yml` |
| 11 | Add CI lint to catch `REPLACE_WITH_COMMIT_SHA` in committed files (ADR-002) | Infra | Medium | ✅ Done — `placeholder` job in `ci.yml` |
| 8 | Add `CONTRIBUTING.md` with Deployment Workflow steps | Open-source hygiene | Medium | ✅ Done — `CONTRIBUTING.md` |
| 12 | Document `$GATEWAY_MAP` externalisation pattern for forks (ADR-004) | Doc | Medium | ✅ Done — `CONTRIBUTING.md` → Customisation Points |
| 9 | Add `CHANGELOG.md` | Open-source hygiene | Low | ✅ Done — `CHANGELOG.md` |
| — | Fix BUG-005: null/empty gateway misleading error (found in pre-launch audit) | Bug | Low | ✅ Done — `network.ps1` |
| 5 | Add `SupportsShouldProcess` / `-WhatIf` to `Rename-DeviceSmart` (OQ-002) | Enhancement | Medium | ✅ Done in v3.1 — `rename.ps1`, `launcher.ps1` |
| 7 | Add optional logging scaffold (OQ-001) | Enhancement | Low | ✅ Done in v3.1 — `logging.ps1` (ADR-007) |

### v3.1 additions

| # | Item | Type | Status |
|---|---|---|---|
| 13 | Implement `-FolderPath` / `-Username` in code (BUG-001/004) | Feature | ✅ Done — `launcher.ps1`, `rename.ps1`, `device.ps1` |
| 14 | Add `PB` detection + new `TB` type via `Win32_SystemEnclosure` (OQ-003) | Feature | ✅ Done — `device.ps1` (`Resolve-DeviceType`) |
| 15 | Refactor cleaning logic into WMI-free helpers; tests call real functions (BUG-011 TODO) | Refactor / Test | ✅ Done — `ConvertTo-SerialLast4`, `ConvertTo-CleanUserName` |
| 16 | Convert remaining non-ASCII files to ASCII; remove all BOMs | Cleanup | ✅ Done — `network.ps1`, `rename.ps1`, tests |
| 17 | Fix stale "15-second" docstring in `Select-NamingMode` | Doc | ✅ Done — `naming.ps1` |
| 18 | Quote forwarded values in `Invoke-SelfElevation` (spaces in `-FolderPath`) | Bug | ✅ Done — `launcher.ps1` |

### v3.2 additions

| # | Item | Type | Status |
|---|---|---|---|
| 19 | Add optional `-Gui` WPF presentation layer (ADR-008) | Feature | ✅ Done — `gui.ps1`, `launcher.ps1`, `rename.ps1` |
| 20 | Extract `Resolve-GatewayPreview` (pure) out of `Update-RenameGuiPreview` | Refactor / Test | ✅ Done — `gui.ps1` |
| 21 | Extract `Get-RenameGuiXaml` so the XAML can be smoke-tested without a live window | Refactor / Test | ✅ Done — `gui.ps1` |
| 22 | Add `-Gui` parameter-contract and XAML smoke tests | Test | ✅ Done — `tests/Hostname-Rename.Gui.Tests.ps1` |
| 23 | Fix BUG-012: `Write-Log` `PSAvoidOverwritingBuiltInCmdlets` false positive | Bug | ✅ Done — `logging.ps1` |
| 24 | Security threat-hunt pass — SEC-001 … SEC-005 recorded and fixed | Security | ✅ Done — `launcher.ps1`, `logging.ps1`, `device.ps1`, `rename.ps1` (see Security Findings) |
| — | Document BUG-013: CI forecast discrepancies (`lint` matrix no-op, `manifest` silent pass) | Doc | ✅ Done — documented in v3.2; both halves fixed in the v3.8 review pass (items 32 and 36 below) |

### v3.3 additions

| # | Item | Type | Status |
|---|---|---|---|
| 25 | `-PromptTimeoutSeconds` — configurable naming-mode prompt timeout (OQ-004) | Feature | ✅ Done — `launcher.ps1`, `rename.ps1`, `naming.ps1` |
| 26 | Log retention for the default `%TEMP%\Hostname-Rename` directory (ADR-009) | Feature | ✅ Done — `logging.ps1` (`Remove-OldLogFile`, `$script:LOG_RETENTION_DAYS`) |
| 27 | Chassis-first `LT` detection — `ChassisTypes` 9/10, `Model` heuristic kept as fallback | Enhancement | ✅ Done — `device.ps1` (`Resolve-DeviceType`) |
| 28 | Fix BUG-014: per-path quoting in `Invoke-SelfElevation` (`-File` vs `iex` relaunch) | Bug | ✅ Done — `launcher.ps1` |

### v3.8 review-pass fixes (REVIEW-FINDINGS.md, 2026-07-11)

| # | Item | Type | Status |
|---|---|---|---|
| 29 | Fix BUG-015 (F-01): `Get-CimInstance -AsJob` dead code — sequential CIM queries + real-execution and AST regression tests | Bug | ✅ Done — `device.ps1`, `tests/Hostname-Rename.Tests.ps1` |
| 30 | Fix BUG-016 (F-02): iex-path elevation relaunch — scriptblock invocation form + round-trip regression test | Bug | ✅ Done — `launcher.ps1`, `tests/Hostname-Rename.Tests.ps1` |
| 31 | Fix BUG-017 (F-03): `.gitattributes` + LF normalization + byte-exact hashing in `Get-Hashes.ps1` and CI manifest job | Bug | ✅ Done — `.gitattributes`, `device.ps1`/`logging.ps1`/`network.ps1` (EOL only), `tools/Get-Hashes.ps1`, `ci.yml` |
| 32 | F-04 (BUG-013a): real 5.1 legs in CI — lint **and** test matrices pair `ps-version` with `shell` | Infra | ✅ Done — `ci.yml` |
| 33 | F-05 (BUG-018): `Select-NamingMode` falls back to Gateway on redirected console input | Bug | ✅ Done — `naming.ps1` + child-process regression test |
| 34 | F-06 (BUG-019): metric-aware IPv4 `Get-DefaultGateway` via `Get-NetRoute`, legacy query as IPv4-filtered fallback | Bug | ✅ Done — `network.ps1` + regression test |
| 35 | F-07 (BUG-020): bounded module fetch — `-TimeoutSec 60` in-job, `Wait-Job -Timeout 90` outside | Bug | ✅ Done — `launcher.ps1` |
| 36 | F-08 (BUG-021): minor batch — UAC-decline message, CI manifest regex + pinned-fail (closes BUG-013b), `New-UserDeviceName` guard, bounded `Read-Host` loops, `wt.exe` `;` escape, GUI-fallback WMI reuse (`Get-DeviceType -Detected`) | Bug | ✅ Done — `launcher.ps1`, `ci.yml`, `naming.ps1`, `device.ps1`, `rename.ps1`, both test files |

---

## File-by-File Notes

### `logging.ps1` *(new in v3.1)*
- Loaded **first** so the orchestrator can log throughout (ADR-007)
- `Initialize-Log` (resolves `%TEMP%\Hostname-Rename` or `-LogPath`; warns + disables on failure) and `Write-Log` (timestamped append; no-op if uninitialised; `-ErrorAction SilentlyContinue` so writes never block)
- ASCII-only, no BOM. No `Write-Host`; uses `Write-Warning` only on init failure
- ✅ v3.2: `Write-Log` gains a justified `PSAvoidOverwritingBuiltInCmdlets` suppression (BUG-012 — confirmed false positive via `Get-Command` on both PS 7.6 and Windows PowerShell 5.1)
- ✅ v3.2 (threat hunt): `Initialize-Log` warns when the resolved log directory is a UNC path — every write is an NTLM handshake from an elevated session (SEC-004)
- ✅ v3.3: `Remove-OldLogFile` + `$script:LOG_RETENTION_DAYS` (30) — `Initialize-Log` prunes `Hostname-Rename_*.log` older than the window from the **default** directory only; explicit `-LogPath` is never pruned (ADR-009). `SupportsShouldProcess`, per-file gate, never throws

### `gui.ps1` *(new in v3.2)*
- Optional WPF presentation layer for `-Gui` — see ADR-008 for the full design rationale (sentinel pattern, never-block principle, static XAML, WPF-not-WinForms)
- Loaded after `naming.ps1` (live preview calls `New-DeviceName` / `New-UserDeviceName`) and before `rename.ps1` (which calls `Show-RenameGui`) — see `$MODULES` in `launcher.ps1`
- `Resolve-GatewayPreview` — pure, WMI/WPF-free department-drop and overflow detection; unit-tested the same way as `Resolve-DeviceType`
- `Get-RenameGuiXaml` — returns the window markup as a string; lets `tests/Hostname-Rename.Gui.Tests.ps1` parse it with `XamlReader` without an interactive/STA session. Static, single-quoted, zero `$` characters — no runtime data is ever interpolated into it
- `Update-RenameGuiPreview` — binds `Resolve-GatewayPreview`'s result (and the equivalent User-mode selection check) to controls; no decision logic of its own
- `Show-RenameGui` — checks `[Environment]::UserInteractive`, thread apartment state, and `PresentationFramework` availability before building anything; returns `$script:GUI_UNAVAILABLE` on any precondition failure or unexpected WPF exception, `$null` on Cancel/titlebar-X, or a populated hashtable on Rename/Dry run. Never calls `Write-Log` itself — all logging lives in `rename.ps1` (ADR-007) — and never calls `Rename-Computer`
- ASCII-only, no BOM

### `launcher.ps1`
- ✅ `logging.ps1` prepended to `$MODULES` and `$MANIFEST` (loads first); `$MANIFEST` switched to `[ordered]` to match `Get-Hashes.ps1` output for a clean paste
- ✅ `-FolderPath` / `-Username` / `-LogPath` params added and forwarded to `Rename-DeviceSmart`; `SupportsShouldProcess` declared so `-WhatIf` flows through (with a justified `PSShouldProcess` suppression — the gate lives in the orchestrator)
- ✅ `Invoke-SelfElevation` now single-quotes forwarded parameter *values* (doubling embedded quotes) so a value with spaces survives the UAC relaunch on both the `-File` and `iex`/`wt.exe` paths (checklist item 18) — **superseded in v3.3:** the "both paths" claim was wrong; single quotes are literal on the `-File` path (BUG-014)
- ✅ v3.2: `gui.ps1` inserted into `$MODULES` and `$MANIFEST` between `naming.ps1` and `rename.ps1` (ADR-008 load order); `-Gui` switch added to the param block and forwarded to `Rename-DeviceSmart`
- ✅ v3.2 (threat hunt): unpinned runs now refuse unless `-AllowUnverified` is passed (SEC-001); a pinned SHA with any `REPLACE_WITH_HASH` entry fails closed before fetching (SEC-002); `Invoke-SelfElevation` rejects forwarded values containing a double-quote (SEC-003)
- ✅ v3.3: `-PromptTimeoutSeconds` param added and forwarded (OQ-004). `Invoke-SelfElevation` now quotes forwarded values **per relaunch path** — double quotes for `-File` (native command line), single quotes for the `iex` `-Command` string — replacing the v3.1 single-quote-everywhere scheme that corrupted values on the `-File` path (BUG-014)
- ✅ v3.8 review pass: iex-path relaunch rebuilt as `& ([scriptblock]::Create((irm ...))) <args>` so forwarded parameters actually bind (BUG-016); module fetches bounded (`-TimeoutSec 60` in-job, `Wait-Job -Timeout 90` outside — BUG-020); UAC decline rethrown with a clear instruction and both `wt.exe` relaunch paths escape `;` as `\;` (BUG-021.1/.5)
- `$REPO_BASE` hardcodes the author's GitHub path — fine for the canonical repo, documented for forks in `CONTRIBUTING.md`

### `network.ps1`
- ✅ All six `10.72.x.x` entries replaced with RFC 5737 documentation IPs (ADR-004)
- ✅ `$FALLBACK_CONTEXT` variable added — replaces hardcoded `RS` fallback (BUG-002)
- ✅ `Get-NetworkContext` updated — throws in NonInteractive, warns prominently in interactive (BUG-002)
- ✅ Null/empty gateway guard added to `Get-NetworkContext` — throws with a clear "no gateway detected" message before the map lookup (BUG-005)
- ✅ v3.1: converted to ASCII-only (one comment em dash → `--`); BOM removed (no non-ASCII content remains)
- ✅ v3.8 review pass: `Get-DefaultGateway` is now metric-aware — primary path `Get-NetRoute 0.0.0.0/0` sorted by `RouteMetric + InterfaceMetric`, legacy CIM query kept as an IPv4-filtered fallback (BUG-019)

### `device.ps1`
- ✅ CIM job cleanup fixed — `$jobs` array + `finally` block (BUG-003; fix confirmed and applied in pre-launch audit 2026-04-30)
- ✅ v3.1: `$script:DEVICE_TYPES` gains `PB` and `TB`. `Get-DeviceType` fires a 4th parallel query (`Win32_SystemEnclosure`) and delegates the decision to the new pure `Resolve-DeviceType` (chain `VM > SV > TB > MD > LT > PB > DT`)
- ✅ v3.1: serial/username cleaning extracted into WMI-free helpers `ConvertTo-SerialLast4` and `ConvertTo-CleanUserName`; `Get-SerialLast4` / `Get-UserName` delegate to them (BUG-011 follow-up). `Get-UserName` gains `-FolderPath` / `-Username` with case-insensitive partial match (BUG-001)
- ✅ v3.2 (threat hunt): `Get-UserName` matches `-Username` as a literal substring via `[WildcardPattern]::Escape` and enumerates with `-LiteralPath` (SEC-005)
- ✅ v3.3: `Resolve-DeviceType` gains a chassis-first `LT` branch — `ChassisTypes` 9 (Laptop) / 10 (Notebook) now decide before the `Model -match "Laptop"` heuristic, which stays as a fallback for firmware reporting a generic chassis. Chain position unchanged (`VM > SV > TB > MD > LT > PB > DT`), so an ARM notebook still records `MD`
- ✅ v3.8 review pass: the "parallel" CIM queries never existed — `Get-CimInstance` has no `-AsJob`; replaced with four sequential queries and a catch warning that surfaces the real exception (BUG-015). `Get-DeviceType` gains `-Detected` so the GUI fallback skips the re-query (BUG-021.6); `Get-Department` / `Get-UserName` prompt loops bail after 10 attempts on exhausted stdin (BUG-021.4)
- `$script:VALID_DEPARTMENTS` and `$script:DEVICE_TYPES` documented in README as extension points

### `naming.ps1`
- No bugs found; logic verified correct by pre-launch audit
- `New-DeviceName`, `New-UserDeviceName`, and `Select-NamingMode` all covered by Pester tests
- ✅ v3.1: `Select-NamingMode` `.SYNOPSIS` corrected from "15-second" to the actual 8 seconds (checklist 17); gains `-FolderPath` / `-Username` params that imply User mode (explicit `-Folder`/`-Gateway` still take priority)
- ✅ v3.3: `Select-NamingMode` gains `-PromptTimeoutSeconds` (`ValidateRange(1, 300)`, default 8 — identical behaviour when omitted); the hardcoded `8` in the deadline and the prompt text both derive from it (OQ-004)
- ✅ v3.8 review pass: `Select-NamingMode` catches the `InvalidOperationException` `[Console]::KeyAvailable` throws on redirected stdin and takes the Gateway default (BUG-018); `New-UserDeviceName` guards against a zero/negative substring length when WH+LOC overflow the 15-char budget (BUG-021.3)

### `rename.ps1`
- ✅ `-NonInteractive:$NonInteractive` forwarded to `Get-NetworkContext` (BUG-002)
- ✅ v3.1: `[CmdletBinding(SupportsShouldProcess)]`; rename gated by `$PSCmdlet.ShouldProcess` (OQ-002, checklist 5). New `-FolderPath` / `-Username` / `-LogPath` params (BUG-001). Calls `Initialize-Log` then `Write-Log` throughout — all logging lives here so the leaf modules stay test-clean (ADR-007)
- ✅ v3.1: converted to ASCII-only (box-drawing / em dash → `--`); BOM removed
- ✅ v3.2: `-Gui` param added; throws immediately if combined with `-NonInteractive` (checked before `Initialize-Log`, ADR-008). When `-Gui` is set, pre-fetches device type/serial/profile candidates and calls `Show-RenameGui`; a three-way dispatch on the result (`$script:GUI_UNAVAILABLE` → console fallback, `$null` → cancelled, hashtable → `$guiInputs`) is logged via `Write-Log` in every branch. The non-`-Gui` path is otherwise byte-for-byte the same call sequence as v3.1 — the entire GUI block is additive, gated by `if ($Gui)`. Known low-severity inefficiency: `Get-DeviceType` / `Get-SerialLast4` run twice on GUI-fallback (once to pre-populate the window, again in the console fallback) — **✅ fixed in v3.8** (BUG-021.6): the console fallback now reuses the pre-GUI probe's type (via `Get-DeviceType -Detected`) and serial
- ✅ v3.2 (threat hunt): warns (console + WARN log line) when `-FolderPath` is a UNC path, up front so it covers the GUI pre-enumeration and the console path alike (SEC-004); the GUI candidate filter escapes `-Username` wildcards and uses `-LiteralPath`, mirroring `Get-UserName` (SEC-005)
- ✅ v3.3: `-PromptTimeoutSeconds` param added and forwarded to `Select-NamingMode` (OQ-004); no other change
- ✅ v3.8 review pass: the console fallback after `GUI_UNAVAILABLE` reuses the pre-GUI device type (`Get-DeviceType -Detected`) and serial instead of re-querying WMI (BUG-021.6)

### `tools/Get-Hashes.ps1`
- Works correctly; no changes needed beyond v3.1 adding `logging.ps1` to the hashed `$files` list (first)
- The CI `manifest` job (OQ-005) performs equivalent verification automatically on every PR — no longer a manual-only step
- ✅ v3.2: `gui.ps1` added to `$files`, between `naming.ps1` and `rename.ps1` (ADR-008 load order)
- ✅ v3.8 review pass: hashes raw on-disk bytes (`[IO.File]::ReadAllBytes`) instead of a decode/re-encode round-trip, and warns when a module has a BOM or CRLF line endings — either would make the emitted hash unable to match at runtime (BUG-017; see also `.gitattributes`)
- Note: this job's real-world coverage is weaker than it looks while `$MANIFEST` is all placeholders — see BUG-013(b)

### `tests/Hostname-Rename.Tests.ps1` *(new in v3)*
- Pester v5 test suite covering all pure-logic functions: `New-DeviceName`, `New-UserDeviceName`, `Get-SerialLast4` cleaning and padding, `Get-UserName` UPN cleaning steps, `Select-NamingMode` switch precedence, `Get-NetworkContext` mapping and fallback, and a full integration check of the 15-character NetBIOS limit across all valid department/type combinations
- No WMI or OS dependency — all tests run in CI without a real Windows device
- ✅ v3.1: serial/username tests now call the **real** `ConvertTo-SerialLast4` / `ConvertTo-CleanUserName` (closes the BUG-011 gap, removes the `$script:` scriptblock workaround); new `Resolve-DeviceType` block (chain + priority, incl. PB/TB) and `Select-NamingMode` FolderPath/Username cases; PB/TB added to the integration sweep. Converted to ASCII-only, BOM removed
- ✅ v3.3: now also dot-sources `logging.ps1`. New cases: chassis-9/10 `LT` + ARM-beats-laptop-chassis priority; `-PromptTimeoutSeconds` contract (accepted, range-validated, default-8 pinned via AST); `Remove-OldLogFile` retention block (expired removed, fresh kept, non-matching never touched, `-WhatIf` removes nothing, missing dir never throws, custom window respected)
- ✅ v3.8 review pass (suite now 95): the no-WMI/OS rule gains three deliberate exceptions that each run a real OS seam once — the BUG-015 block (AST parameter-validity check plus a genuine no-mock `Get-DeviceType` run; mocking that seam is exactly how the fake `-AsJob` shipped undetected), the BUG-018 block (real child process with redirected stdin), and the BUG-019 block (real route query, IPv4-only contract). Plus the BUG-016 static-shape + child-process round-trip guards, bounded-prompt-loop cases, and the `New-UserDeviceName` overflow guard
- Run locally: `Invoke-Pester ./tests/Hostname-Rename.Tests.ps1 -Output Detailed`

### `tests/Hostname-Rename.Gui.Tests.ps1` *(new in v3.2)*
- Same no-WMI/OS/GUI-dependency conventions as the main suite. Three groups:
  - `Resolve-GatewayPreview` — pure logic, same style as `Resolve-DeviceType` tests
  - `Get-RenameGuiXaml` — `XamlReader` smoke test plus a control-name coverage check, `-Skip`-guarded on a `PresentationFramework` availability probe so the suite still runs green where WPF is absent (e.g. Server Core CI images)
  - `Rename-DeviceSmart -Gui` parameter contract — Mock-based (`Get-DefaultGateway`, `Get-Department`, `Get-DeviceType`, `Get-SerialLast4`, `Get-UserName`, `Rename-Computer`, `Initialize-Log`, `Write-Log`, `Select-NamingMode`, `Show-RenameGui` all stubbed): `-Gui` + `-NonInteractive` throws before any WMI/GUI call; a GUI precondition failure (mocked `Show-RenameGui` returning the `GUI_UNAVAILABLE` sentinel) falls back to the console flow instead of throwing; `-Gui` absent forwards identical parameters to `Select-NamingMode` / `Get-UserName` as before and never invokes `Show-RenameGui`. No test ever calls the real `Rename-Computer`
- Verified under `Set-StrictMode -Version Latest` (matching the launcher's actual runtime setting) in addition to the Pester run
- Run locally: `Invoke-Pester ./tests/Hostname-Rename.Gui.Tests.ps1 -Output Detailed`

### `.github/workflows/ci.yml` *(new in v3)*
- Four jobs: `lint`, `test`, `manifest`, `placeholder` — see OQ-005 for detail
- `lint` runs a PS 5.1 / 7.x matrix via `windows-latest`
- `placeholder` runs on `ubuntu-latest` (faster, no PS needed for a grep check)
- ⚠️ v3.2 audit note (BUG-013): the `lint` matrix's `ps-version` axis was unused by its own steps (all hardcoded `shell: pwsh`), so the "5.1" leg never ran under real Windows PowerShell; and the `manifest` job passed (not failed) when `$MANIFEST` was all placeholders. **✅ Both resolved in the v3.8 review pass** — lint and test matrices now pair `ps-version` with the real `shell`, and a pinned SHA with zero parsable hashes fails the manifest job (F-04, F-08.2). The all-placeholder *unpinned* state still skips with a warning, matching the launcher's own dev-state behaviour.

### `CONTRIBUTING.md` *(new in v3)*
- Deployment Workflow (step-by-step, fork and canonical repo)
- Customisation points: adding gateways, departments, device types, `$GATEWAY_MAP` externalisation
- Local test instructions
- PR process and code style requirements (✅ v3.2: GUI rules added — static XAML, populate-after-parse, ASCII-only markup, precondition-and-fallback)
- Shipped-feature tables (v3.1, v3.2, and v3.3) and the v3.4 ideas pointer

### `README.md`
- ✅ `-FolderPath` and `-Username` documented as real parameters in v3.1 (no longer "planned"); `-LogPath` and `-WhatIf` rows added (BUG-001, OQ-001, OQ-002)
- ✅ "Network access to log share" requirement removed in v3 — logging added in v3.1 (default `%TEMP%`, optional `-LogPath`), so no network share is required
- ✅ Gateway map example updated to RFC 5737 IPs and two-character `AC` org code (ADR-004, ADR-006)
- ✅ ORG code two-character constraint called out explicitly in Name Format section (ADR-006)
- ✅ Valid codes section added — departments and device types with WMI detection detail; v3.1 made `PB` real and added `TB`, reordered to detection priority, and documented the 4th WMI object (`$enc`)
- ✅ v3.1: Dry Run (`-WhatIf`) example and a Logging section added
- ✅ `CONTRIBUTING.md` reference added (checklist item 8)

---

*This log should be updated whenever a v3.x decision is made or a checklist item is closed.*
