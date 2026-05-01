# Hostname-Rename — Decisions Log

**Project:** Hostname-Rename  
**License:** MIT © 2026 Simms  
**Target:** v3 — clean, open GitHub release  
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
| Parallel CIM queries in `Get-DeviceType` | ✅ Keep — ~2/3 detection time reduction |
| 15-character name truncation logic in `New-DeviceName` | ✅ Keep — Windows NetBIOS limit compliance |
| 8-second timed mode prompt with `[Console]::KeyAvailable` | ✅ Keep — correct approach for console sessions |
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

### ADR-007 · Suppress `PSAvoidUsingWriteHost` project-wide

**Status:** Accepted — implemented in v3 (2026-04-30)  
**Decision:** A project-level `PSScriptAnalyzerSettings.psd1` excludes the `PSAvoidUsingWriteHost` rule. The `lint` job in `ci.yml` passes the file to `Invoke-ScriptAnalyzer` via `-Settings`.  
**Rationale:** This tool's user surface is the PowerShell console — interactive menus (mode selection, profile picker), confirmations, and operator-visible status messages. The two PSScriptAnalyzer-recommended alternatives both break the tool:

| Alternative | Why it fails here |
|---|---|
| `Write-Output` | Writes to the success stream. PowerShell function return values *are* the success stream, so prompt and status text would be returned alongside the actual return value (e.g. `Get-Department` would return both the printed prompt text and the dept code), corrupting every caller. |
| `Write-Information` | Invisible unless the caller sets `$InformationPreference = 'Continue'` or passes `-InformationAction Continue`. End users running a one-shot `irm \| iex` will not have set this. The prompts would simply not appear. |

`Write-Host` is the intended cmdlet for interactive UI in PowerShell 5+ (the underlying issue the rule was created for — "you can't capture or redirect it" — was resolved when `Write-Host` was rewritten to write to the information stream in PS 5.0). The rule remains useful for catching cases where someone wrote a function meant to *return* data but printed it instead; that is not what is happening in this codebase.

**Scope of the suppression:** the rule is excluded for *all* `.ps1` files in the repo. `Write-Verbose` is still used for debug-level detail throughout, so the verbose/host distinction is preserved at the source-code level even though only one of them is enforced.

**Alternative considered:** per-function suppression via `[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]`. Rejected because every interactive function in the codebase would need the attribute, and any new interactive function would silently re-introduce the warning until someone added it. A single project-level decision documented here and in the settings file is clearer.

---

## Known Bugs

### BUG-001 · `-FolderPath` and `-Username` parameters documented but not implemented

**Severity:** High — README documents parameters that do not exist in code  
**Status:** ✅ Resolved in v3 (README) — Option 3 chosen  
**Location:** `README.md` (Available Parameters table) vs `launcher.ps1` (param block) vs `rename.ps1` (param block) vs `device.ps1 → Get-UserName`  

**Was:** README claimed `-FolderPath` and `-Username` as implemented parameters. Folder mode was described as "reads Desktop subfolders" — the implementation reads `C:\Users` profile directories.

**Resolution (Option 3 — Defer to v3.1):**
- `-FolderPath` and `-Username` moved to the bottom of the Available Parameters table, marked *(planned — v3.1)*
- `-Folder` description corrected: now documents `C:\Users` profile directory selection accurately
- No code changes required for this resolution; plumbing deferred to v3.1

**v3.1 action:** Implement `-FolderPath [string]` and `-Username [string]` across the full call chain — `launcher.ps1` param block → `Rename-DeviceSmart` → `Get-UserName`. Add partial-name matching to `Get-UserName`.

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
**Resolution:** README updated to mark `-Username` as planned v3.1. No code changes required at this stage.

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

### BUG-006 · PSScriptAnalyzer lint failures on first CI run

**Severity:** Medium — blocks CI, so blocks PR merges  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `device.ps1`, `naming.ps1`, `rename.ps1`, `network.ps1`, `tests/Hostname-Rename.Tests.ps1`, `.github/workflows/ci.yml`

**Was:** The first run of `Invoke-ScriptAnalyzer` against the v3 codebase (under the new CI pipeline from OQ-005) emitted 15 warnings across three rules. Until resolved, the `lint` job failed on every push, blocking merges.

| Rule | Files | Count |
|---|---|---|
| `PSAvoidUsingWriteHost` | `device.ps1`, `rename.ps1`, `naming.ps1`* | 12 |
| `PSUseBOMForUnicodeEncodedFile` | `network.ps1`, `rename.ps1`, `tests/Hostname-Rename.Tests.ps1` | 3 |
| `PSUseDeclaredVarsMoreThanAssignments` | `tests/Hostname-Rename.Tests.ps1` | 1 |

*\*The CI output as recorded only showed `device.ps1` and `rename.ps1` for `PSAvoidUsingWriteHost`, but `naming.ps1` contains 8 functionally identical `Write-Host` calls in `Select-NamingMode`. The output appears to have been truncated. The fix covers all three files either way.*

**Resolution — three sub-fixes, one bug entry:**

**6a. `PSAvoidUsingWriteHost`** → see ADR-007. Excluded project-wide via the new `PSScriptAnalyzerSettings.psd1`. The lint job in `ci.yml` passes the file to `Invoke-ScriptAnalyzer` with `-Settings ./PSScriptAnalyzerSettings.psd1`.

**6b. `PSUseBOMForUnicodeEncodedFile`** → non-ASCII characters replaced with ASCII equivalents in three files:

| File | Characters replaced |
|---|---|
| `network.ps1` | em dash `—` → `--` (2 occurrences in comment lines) |
| `rename.ps1` | box drawing `──` → `--`, `─` → `-` (User-mode and Gateway-mode section dividers) |
| `tests/Hostname-Rename.Tests.ps1` | `─` → `-`, `→` → `->`, `—` → `--` (all section dividers and inline arrows) |

**Alternative considered:** add a UTF-8 BOM to each file. Rejected because:
- It changes the byte content of `network.ps1`, which would force a manifest rehash and a new deployed commit SHA purely for cosmetic comment characters
- The hashing path in `launcher.ps1` (`Get-Content -Raw -Encoding UTF8` then `[Text.Encoding]::UTF8.GetBytes()`) handles BOMs differently across PS 5.1 and 7.x — a BOM at the source could subtly shift hashes between environments and undermine the integrity check
- ASCII keeps the integrity model unambiguous and the diff to `$MANIFEST` is the absolute minimum

**6c. `PSUseDeclaredVarsMoreThanAssignments`** → in the `Get-UserName name cleaning` Describe block of the test file, `$clean` was set in `BeforeAll` and used inside `It` blocks. PSScriptAnalyzer cannot trace state across that boundary and flagged the assignment as unused. The variable was promoted to `$script:clean` (the documented Pester v5 pattern for cross-block state); the assignment and all eight call sites updated. No runtime behaviour change.

**Why this happened only now:** v3 is the first version with CI. v2 was internally deployed and never lint-checked. All three rules have been firing since v2 but went unobserved.

---

### BUG-007 · `PSUseUsingScopeModifierInNewRunspaces` false positive in launcher fetch loop

**Severity:** Medium — blocks the `lint` CI job  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `launcher.ps1` (parallel module-fetch loop, lines 132-141)

**Was:** The fetch loop used the standard `Start-Job ... -ArgumentList` pattern with a matching `param()` block inside the scriptblock:

```powershell
$jobs[$FileName] = Start-Job -ScriptBlock {
    param($u)
    (Invoke-WebRequest -Uri $u -UseBasicParsing).Content
} -ArgumentList $url
```

`$u` *is* declared inside the scriptblock (by the `param` block) and *is* bound at `Start-Job` time (via `-ArgumentList`). The pattern is functionally correct and well-documented for PowerShell jobs. PSScriptAnalyzer's `PSUseUsingScopeModifierInNewRunspaces` rule has a known limitation: its static check doesn't recognise `param()` blocks inside scriptblocks passed to `Start-Job` / `Invoke-Command`, so it flags both the param declaration *and* every reference to the param variable as undeclared cross-runspace references.

**Resolution:** Switched to the `$using:` scope modifier:

```powershell
$jobs[$FileName] = Start-Job -ScriptBlock {
    (Invoke-WebRequest -Uri $using:url -UseBasicParsing).Content
}
```

`$using:url` snapshots the loop variable's *current* value into each job's runspace at `Start-Job` time, which preserves the per-iteration correctness of the original pattern (each job fetches the URL for its own iteration, not a shared late-bound reference). Functionally equivalent to the original.

**Alternative considered:** suppress the rule via `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` on the function or add it to `PSScriptAnalyzerSettings.psd1`. Rejected — `PSUseUsingScopeModifierInNewRunspaces` catches genuine bugs (silently failing cross-runspace variable references) and there's no reason to disable it project-wide for a single-line idiomatic fix that resolves the false positive cleanly. The fix is the *more* idiomatic form for `Start-Job` in modern PowerShell anyway.

**Note for the manifest:** `launcher.ps1` is not in `$MANIFEST` (it cannot hash itself), so this change doesn't require regenerating module hashes. It does require a new commit SHA in deployment URLs as usual.

---

### BUG-008 · Pester v5 test container failed before any test ran

**Severity:** Medium — blocks the `test` CI job  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `tests/Hostname-Rename.Tests.ps1` (`Describe "Get-SerialLast4"`)

**Was:** First end-to-end run of the Pester job — after BUG-006/BUG-007 unblocked the lint stage and the `Run.PassThru` config fix unblocked `Invoke-Pester` itself — produced:

```
Pester v5.7.1
Starting discovery in 1 files.
Discovery found 38 tests in 234ms.
Running tests.
[-] tests\Hostname-Rename.Tests.ps1 failed with:
Message
Tests completed in 723ms
Tests Passed: 0, Failed: 38, Container failed: 1
```

All 38 tests reported failed with no individual error messages — the diagnostic signature of a container-level failure during Run phase. Two interacting defects in the `Get-SerialLast4` Describe block:

**1. Discovery-phase variable referenced at Run phase.** In the second Context, the helper scriptblock was defined at Context body level:

```powershell
Context "Serial shorter than 4 chars" {
    $fn = { param($s) ... }                # <- runs during Discovery
    It "3 chars -> left-pads to 4" {
        & $fn "ABC" | Should -Be "0ABC"    # <- runs during Run; $fn is $null
    }
}
```

Per the Pester v5 breaking-changes documentation:
> *Variables defined during Discovery, are not available in BeforeAll/-Each, AfterAll/-Each and It.*

`$fn` was assigned at Discovery, then `It` blocks invoked `& $null` at Run time, which throws.

**2. Malformed `InModuleScope` call.** The first `It` block contained:

```powershell
InModuleScope -Scriptblock {
    # Mock CIM since we only want to test the logic
}
```

— missing the required `-ModuleName` parameter, with an empty (commented-out) body. Leftover scaffolding for a mock that was never written. Throws at Run time regardless of the `$fn` issue.

**Resolution:**
- Hoisted the helper scriptblock into a Describe-level `BeforeAll` assigned to `$script:fn` — the documented Pester v5 cross-block pattern, same approach used for `$script:clean` in BUG-006c.
- Deleted the malformed `InModuleScope` block.
- Deduplicated the three inline copies of the helper that had been in the first Context's `It` blocks (assigned to local `$fn` each time, which worked but was repetitive). All seven `It` blocks across both Contexts now call the single `$script:fn`.

**Test count unchanged:** 38 tests before, 38 tests after. No assertion logic changed — the helper's body is byte-identical to the previous inline copies. The fix only changes *where* the helper lives, so it's accessible at Run time.

**Why the original error was missing.** Pester's `Detailed` verbosity renders container-level errors as `failed with:\nMessage\n` — the exception object is captured in the result, but the `.Message` property's contents aren't formatted to console at this verbosity for container failures specifically. Diagnosing required reading the test source to spot the Discovery/Run scope boundary. Bumping verbosity to `Diagnostic` in `ci.yml` would surface the underlying exception in future runs, at the cost of much noisier successful runs (every mock setup, every internal step). Left at `Detailed` since the root cause is now understood and documented; revisit if a similar opaque container failure recurs.

**Why this surfaced now:** v3 is the first version with a CI test pipeline. v2 had no tests in CI. The defects existed in the test file as written but were never exercised until the lint and `Invoke-Pester`-call issues were resolved.

---

### BUG-009 · Pester container failure: dot-source path not normalised on Windows

**Severity:** Medium — blocks the `test` CI job  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `tests/Hostname-Rename.Tests.ps1` (top-level `BeforeAll`)

**Was:** With BUG-008 resolved, the next CI run produced an actual error message (rather than the empty-message container failure):

```
CommandNotFoundException: The term
'D:\a\Hostname-rename\Hostname-rename\tests/../naming.ps1' is not recognized
as a name of a cmdlet, function, script file, or executable program.
at <ScriptBlock>, ...\Hostname-Rename.Tests.ps1:13
```

The `BeforeAll` was using:

```powershell
. "$PSScriptRoot/../naming.ps1"
```

On the GitHub Windows runner, `$PSScriptRoot` resolves with backslash separators (`D:\a\...\tests`), so the concatenated string is a mixed-slash path: `D:\...\tests/../naming.ps1`. PowerShell's dot-source operator does a command-name lookup that includes a path-resolution check, but on Windows that pre-resolution check does not fold the `/..` segment when the rest of the path uses backslashes. The lookup fails, falls through to command-name resolution (which doesn't find anything either), and throws `CommandNotFoundException`.

**Resolution:** Replaced the three string-concatenated paths with `Join-Path` calls off a `Split-Path`-derived `$repoRoot`:

```powershell
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'naming.ps1')
. (Join-Path $repoRoot 'network.ps1')
. (Join-Path $repoRoot 'device.ps1')
```

`Join-Path` uses the platform-native separator (`\` on Windows, `/` on Unix) regardless of how the inputs are written, and `Split-Path -Parent` is the documented way to walk up one directory level. The result is a clean absolute path that the dot-source operator resolves without ambiguity.

**Why the original pattern is in Pester's docs:** Pester's quick-start example uses `. $PSScriptRoot/Get-Emoji.ps1` — a single-level path, no `..` traversal. The Pester docs don't show a parent-traversal pattern. The mixed-slash issue only manifests when you cross a directory boundary with `..`, which is what our test layout (modules at repo root, tests in a subfolder) requires.

**Audit done at the same time:** A repo-wide grep for dot-source statements found no other instances of this pattern. `launcher.ps1` line 167 dot-sources scriptblock content (not a file path). `Get-Hashes.ps1` already uses `Join-Path`. No further fixes needed.

---

### BUG-010 · `PSUseShouldProcessForStateChangingFunctions` false positive on pure `New-` functions

**Severity:** Low — blocks the `lint` CI job, but the underlying functions are correct  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `naming.ps1` — `New-DeviceName`, `New-UserDeviceName`

**Was:** With the missing `naming.ps1` now committed, the lint job ran against it for the first time and fired:

```
PSUseShouldProcessForStateChangingFunctions  Warning  naming.ps1  56
  Function 'New-DeviceName' has verb that could change system state.
  Therefore, the function has to support 'ShouldProcess'.

PSUseShouldProcessForStateChangingFunctions  Warning  naming.ps1  88
  Function 'New-UserDeviceName' has verb that could change system state.
  Therefore, the function has to support 'ShouldProcess'.
```

The rule's heuristic: any function whose verb is in PowerShell's "state-changing" set (`New-`, `Set-`, `Remove-`, `Start-`, `Stop-`, `Restart-`, `Reset-`, `Update-`) should support `-WhatIf` / `-Confirm` so callers can preview or skip the side effect.

Both functions in question are pure: they take strings as parameters, compose a new string, and return it. Nothing to confirm, nothing to roll back. The `New-` verb is technically defensible for "constructs a new value" (cf. `New-Object`, `New-TimeSpan`, `New-Guid` — all pure value constructors that don't support `ShouldProcess`), but the rule can't tell the difference between value-constructing `New-` functions and resource-creating ones.

**Resolution:** Per-function suppression via `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` placed between the comment-based help and the `param` block:

```powershell
function New-DeviceName {
    <#
    .SYNOPSIS
        Assembles the Gateway-mode device name from its components.
    ...
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function: composes and returns a string from input parameters. Does not modify any state, so ShouldProcess is not applicable.'
    )]
    param (...)
    ...
}
```

Same attribute applied to `New-UserDeviceName`.

**Alternatives considered and rejected:**

| Alternative | Why rejected |
|---|---|
| Add the rule to `PSScriptAnalyzerSettings.psd1` (extending ADR-007) | ADR-007 is for rules that don't fit the codebase *at all*. This rule fits the codebase fine — it would correctly fire if someone added e.g. `Set-DeviceConfig` that wrote to disk without `ShouldProcess`. Project-wide exclusion would silence those future cases too. |
| Rename to `Format-DeviceName` / `ConvertTo-DeviceName` | `Format-` is for output layout (`Format-Table`, `Format-List`); `ConvertTo-` implies converting one representation to another. Neither matches "compose a string from multiple inputs". `New-` is closer to right; the function builds a *new value*, like `New-Guid`. Renaming would also break callers in `rename.ps1`. |
| Add `[CmdletBinding(SupportsShouldProcess)]` plus `if ($PSCmdlet.ShouldProcess(...))` | Misleading. The function would advertise `-WhatIf` semantics it doesn't actually need. A caller passing `-WhatIf` would expect the function to *not run*, but with nothing to skip, the implementation would either silently run anyway or return `$null`. Either is worse than the false-positive warning. |

**Forward-looking note:** when `Rename-DeviceSmart` gains `SupportsShouldProcess` in v3.1 (OQ-002), it will need real `if ($PSCmdlet.ShouldProcess(...))` calls around the actual `Rename-Computer` invocation — that one *is* state-changing. The `Rename-` verb is not in the rule's state-changing list, so PSScriptAnalyzer hasn't flagged it; that's a coverage gap in the rule, not a green light.

**Why this surfaced now:** earlier CI runs hit the lint job with `naming.ps1` missing from the repo entirely, so the file was never analysed. Once it was committed, the rule fired on the first run.

---

### BUG-011 · `placeholder` CI job tries to run Bash syntax under pwsh

**Severity:** Low — blocks the `placeholder` CI job only; other three jobs were green by this point  
**Status:** ✅ Resolved in v3 (2026-04-30)  
**Location:** `.github/workflows/ci.yml` — `placeholder` job

**Was:** With BUG-006 through BUG-010 resolved, the lint, test, and manifest jobs all went green. The `placeholder` job still failed:

```
ParserError: /home/runner/work/_temp/.../*.ps1:2
Line 2: if grep -q "REPLACE_WITH_COMMIT_SHA" launcher.ps1; then
        ~
        Missing '(' after 'if' in if statement.
shell: /usr/bin/pwsh -command ". '{0}'"
```

The shell line in the error is the giveaway: `/usr/bin/pwsh` was being asked to parse Bash syntax. Cause:

```yaml
defaults:
  run:
    shell: pwsh   # <-- workflow-wide default
```

…applies to every step in every job, including jobs running on `ubuntu-latest`. The `placeholder` job's grep check uses Bash syntax (it was always intended to — the rest of the workflow standardised on pwsh because three of the four jobs run PowerShell tooling on `windows-latest`). PowerShell on Linux still has pwsh installed, so the runner happily picks it up; it just can't parse `if grep ...; then`.

**Resolution:** Per-step shell override on the offending step:

```yaml
- name: Fail if REPLACE_WITH_COMMIT_SHA is present in launcher.ps1
  shell: bash
  run: |
    if grep -q "REPLACE_WITH_COMMIT_SHA" launcher.ps1; then
      ...
```

Per-step `shell:` takes priority over both `defaults.run.shell` and the runner's OS-default shell, so this is the minimal, targeted fix. The three Windows jobs continue to inherit `shell: pwsh` from `defaults`.

**Alternatives considered:**

| Alternative | Why rejected |
|---|---|
| Set `shell: bash` at job level on `placeholder` | Equivalent end result, more verbose. The Bash usage is one step; documenting at step level keeps the override visible at the point of need. |
| Rewrite the grep check in pwsh | Would work (`Select-String -Path launcher.ps1 -Pattern 'REPLACE_WITH_COMMIT_SHA' -Quiet`) and would let the job stay on Linux under the default shell. Rejected because Bash + grep is the natural form for "fail-on-string-found" CI checks; rewriting in pwsh would obscure intent for anyone scanning the workflow later. |
| Drop `defaults.run.shell: pwsh` and tag every step explicitly | Heavy diff, gains nothing — three of the four jobs run pwsh exclusively. The default is correct for them. |

**Also fixed in the same diff:** the success-message echo contained a literal em dash (`—`). Changed to `--` for consistency with the project-wide ASCII discipline established in BUG-006b. This wasn't causing failures (Linux runners handle UTF-8 fine in echoes), but kept inconsistent with the rest of the codebase.

**Why this surfaced now:** the placeholder job has been failing since CI was added — this was the same as the lint and test failures, just at the bottom of the queue. Each fix peeled back a layer; with the upstream jobs finally green, this last one became visible. The job's `continue-on-error: ${{ github.ref == 'refs/heads/main' }}` setting meant it has *also* been silently failing on `main` since CI was added; that didn't show up as a CI red because of the soft-fail, but the job wasn't actually doing anything either way.

---

## Open Questions for v3

### OQ-001 · Should logging be implemented?

**Background:** No logging code exists anywhere in the codebase. The README previously listed "Network access to log share *(optional)*" under Requirements — this entry has been removed in v3 as there is nothing to back it up. The question of whether logging should be added remains open.  
**Options:**
- A. Skip logging entirely and remove the README mention
- B. Add a lightweight `Write-Log` wrapper that writes to a UNC path if reachable, local temp otherwise
- C. Add optional `-LogPath [string]` parameter

**Recommendation:** Option B with Option C as the override. Keep it opt-in — logging should never block a rename.  
**Status:** ⬜ Open — deferred to v3.1

---

### OQ-002 · Should there be a dry-run / `-WhatIf` mode?

**Background:** `Rename-Computer` supports `-WhatIf` natively. The orchestrator does not expose it.  
**Value:** Useful for MDM testing — verify what name *would* be generated without actually renaming.  
**Recommendation:** Add `[CmdletBinding(SupportsShouldProcess)]` to `Rename-DeviceSmart` and pass `-WhatIf:$WhatIfPreference` to `Rename-Computer`.  
**Status:** ⬜ Open — deferred to v3.1

---

### OQ-003 · Should `Get-DeviceType` detect tablets / Surface / convertibles?

**Background:** The current detection chain covers VM, Server, ARM/Mobile, Laptop, Desktop. Tablet/Surface form factors (e.g., Windows tablets, Surface Go) may fall through to `DT`.  
**Detection signal:** `Win32_SystemEnclosure.ChassisTypes` includes types 30 (Tablet) and 31 (Convertible).  
**Recommendation:** Add as an optional enhancement; does not block v3.  
**Status:** ⬜ Open — deferred to v3.1 alongside `PB` device type

---

### OQ-004 · Should the naming mode timed prompt timeout be configurable?

**Background:** The 8-second timeout in `Select-NamingMode` is hardcoded.  
**Value:** Teams with slow startup environments may want more time; MDM users never need it.  
**Recommendation:** Low priority. The `-NonInteractive` flag already bypasses the prompt entirely. Leave hardcoded for now; documented as a "fork and adjust" customisation point in `CONTRIBUTING.md`.  
**Status:** ⬜ Open — accepted as-is for v3; revisit only if a real need is reported

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
| — | Fix BUG-006: PSScriptAnalyzer lint failures on first CI run (Write-Host, BOM, unused var) | Bug / Infra | Medium | ✅ Done — `PSScriptAnalyzerSettings.psd1`, `ci.yml`, plus ASCII fixes to `network.ps1`, `rename.ps1`, test file (ADR-007) |
| — | Fix BUG-007: PSUseUsingScopeModifierInNewRunspaces false positive in launcher fetch loop | Bug | Medium | ✅ Done — `launcher.ps1` switched to `$using:url` |
| — | Fix BUG-008: Pester v5 container failure from Discovery-phase `$fn` and malformed `InModuleScope` | Bug | Medium | ✅ Done — `tests/Hostname-Rename.Tests.ps1` restructured to use `$script:fn` BeforeAll |
| — | Fix BUG-009: dot-source path mixed-slash failure on Windows runners | Bug | Medium | ✅ Done — `tests/Hostname-Rename.Tests.ps1` BeforeAll switched to `Join-Path` |
| — | Fix BUG-010: `PSUseShouldProcessForStateChangingFunctions` false positive on pure `New-` functions | Bug | Low | ✅ Done — per-function `SuppressMessageAttribute` on `New-DeviceName` and `New-UserDeviceName` in `naming.ps1` |
| — | Fix BUG-011: `placeholder` CI job tried to parse Bash under pwsh | Bug | Low | ✅ Done — per-step `shell: bash` override in `ci.yml` |
| — | Bump GitHub Actions to Node 24 versions ahead of Node 20 deprecation (2026-06-02 / 2026-09-16) | Infra | Medium | ✅ Done — `actions/checkout@v5`, `actions/upload-artifact@v6` in `ci.yml` |
| 5 | Add `SupportsShouldProcess` / `-WhatIf` to `Rename-DeviceSmart` (OQ-002) | Enhancement | Medium | ⬜ Open — deferred to v3.1 |
| 7 | Add optional logging scaffold (OQ-001) | Enhancement | Low | ⬜ Open — deferred to v3.1 |

---

## File-by-File Notes

### `launcher.ps1`
- Core model is sound; carry forward as-is structurally
- Param block needs `-FolderPath` and `-Username` once BUG-001 is resolved in v3.1
- `$REPO_BASE` hardcodes the author's GitHub path — fine for the canonical repo, documented for forks in `CONTRIBUTING.md`
- ✅ Parallel fetch loop switched from `param/-ArgumentList` to `$using:url` (BUG-007). Functionally equivalent; resolves a PSScriptAnalyzer false positive without disabling the rule.

### `network.ps1`
- ✅ All six `10.72.x.x` entries replaced with RFC 5737 documentation IPs (ADR-004)
- ✅ `$FALLBACK_CONTEXT` variable added — replaces hardcoded `RS` fallback (BUG-002)
- ✅ `Get-NetworkContext` updated — throws in NonInteractive, warns prominently in interactive (BUG-002)
- ✅ Null/empty gateway guard added to `Get-NetworkContext` — throws with a clear "no gateway detected" message before the map lookup (BUG-005)
- ✅ Two em dashes (`—`) in comment lines 7 and 56 replaced with `--` (BUG-006b)

### `device.ps1`
- ✅ CIM job cleanup fixed — `$jobs` array + `finally` block (BUG-003; fix confirmed and applied in pre-launch audit 2026-04-30)
- BUG-001 (`-FolderPath` / `-Username`) deferred to v3.1 — `Get-UserName` unchanged for now
- `$script:VALID_DEPARTMENTS` and `$script:DEVICE_TYPES` documented in README as extension points

### `naming.ps1`
- No bugs found; logic verified correct by pre-launch audit
- `New-DeviceName`, `New-UserDeviceName`, and `Select-NamingMode` all covered by Pester tests
- Contains 8 `Write-Host` calls in `Select-NamingMode` for the interactive mode prompt — covered by the project-wide `PSAvoidUsingWriteHost` exclusion (BUG-006a, ADR-007); no source change required
- ✅ `New-DeviceName` and `New-UserDeviceName` annotated with `[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', ...)]` — both are pure value-constructing functions and do not need `-WhatIf`/`-Confirm` (BUG-010). Per-function suppression preserves the rule's coverage for any future state-changing function.

### `rename.ps1`
- ✅ `-NonInteractive:$NonInteractive` forwarded to `Get-NetworkContext` (BUG-002)
- ✅ Box-drawing characters in section dividers (`──`, `─`) replaced with ASCII (`--`, `-`) (BUG-006b)
- `Rename-DeviceSmart` still needs `SupportsShouldProcess` (OQ-002, checklist item 5) — deferred to v3.1
- Param additions for BUG-001 deferred to v3.1

### `tools/Get-Hashes.ps1`
- Works correctly; no changes needed
- The CI `manifest` job (OQ-005) performs equivalent verification automatically on every PR — no longer a manual-only step

### `tests/Hostname-Rename.Tests.ps1` *(new in v3)*
- Pester v5 test suite covering all pure-logic functions: `New-DeviceName`, `New-UserDeviceName`, `Get-SerialLast4` cleaning and padding, `Get-UserName` UPN cleaning steps, `Select-NamingMode` switch precedence, `Get-NetworkContext` mapping and fallback, and a full integration check of the 15-character NetBIOS limit across all valid department/type combinations
- No WMI or OS dependency — all tests run in CI without a real Windows device
- Run locally: `Invoke-Pester ./tests/Hostname-Rename.Tests.ps1 -Output Detailed`
- ✅ Section-divider chars (`─`), inline arrows (`→`), and em dashes (`—`) replaced with ASCII equivalents (BUG-006b)
- ✅ `$clean` scriptblock in `Get-UserName name cleaning` Describe block promoted to `$script:clean` so PSScriptAnalyzer recognises the cross-block use; assignment plus all eight call sites updated (BUG-006c)
- ✅ `Get-SerialLast4` Describe restructured (BUG-008): helper scriptblock moved from Context body level (Discovery phase, invisible at Run time in Pester v5) into a Describe-level `BeforeAll` using `$script:fn`. Empty `InModuleScope -Scriptblock { }` removed. Three duplicated inline helper copies in the first Context deduplicated against the new `BeforeAll`.
- ✅ Top-level `BeforeAll` dot-source switched from `"$PSScriptRoot/../module.ps1"` to `Join-Path $repoRoot 'module.ps1'` after `$repoRoot = Split-Path -Parent $PSScriptRoot` (BUG-009). The original mixed-slash pattern fails on Windows when the `..` segment crosses a separator-direction boundary.

### `.github/workflows/ci.yml` *(new in v3)*
- Four jobs: `lint`, `test`, `manifest`, `placeholder` — see OQ-005 for detail
- `lint` runs a PS 5.1 / 7.x matrix via `windows-latest`
- `placeholder` runs on `ubuntu-latest` (faster, no PS needed for a grep check)
- ✅ `lint` job updated to pass `-Settings ./PSScriptAnalyzerSettings.psd1` to `Invoke-ScriptAnalyzer` (BUG-006a, ADR-007)
- ✅ `test` job's `Invoke-Pester` call switched to set `$cfg.Run.PassThru = $true` on the configuration object — Pester v5's Simple and Advanced parameter sets are mutually exclusive and `-Configuration` cannot be combined with `-PassThru` directly
- ✅ `actions/checkout` bumped v4 → v5 (4 references, one per job) and `actions/upload-artifact` bumped v4 → v6 (1 reference) ahead of the GitHub Node 20 deprecation. Both default to Node 24 and require Actions Runner 2.327.1+; GitHub-hosted runners are kept current automatically.
- ✅ `placeholder` job's grep check tagged `shell: bash` to override the workflow-wide `defaults.run.shell: pwsh`. Without the override, the Linux runner was passing Bash syntax to pwsh, which failed parsing (BUG-011).

### `PSScriptAnalyzerSettings.psd1` *(new in v3)*
- Single-purpose lint-rule configuration consumed only by the CI `lint` job (ADR-007)
- Currently excludes `PSAvoidUsingWriteHost` only — see ADR-007 for the full rationale and rejected alternatives
- Not in `$MANIFEST` and not deployed at runtime — does not need a manifest entry
- New rule exclusions added here in future require updating ADR-007 with the rationale

### `CONTRIBUTING.md` *(new in v3)*
- Deployment Workflow (step-by-step, fork and canonical repo)
- Customisation points: adding gateways, departments, device types, `$GATEWAY_MAP` externalisation
- Local test instructions
- PR process and code style requirements
- v3.1 planned work table

### `README.md`
- ✅ `-Folder` description corrected — documents `C:\Users` profile selection accurately (BUG-001)
- ✅ `-FolderPath` and `-Username` marked as planned v3.1 (BUG-001 Option 3)
- ✅ "Network access to log share" requirement removed — no logging code exists (OQ-001)
- ✅ Gateway map example updated to RFC 5737 IPs and two-character `AC` org code (ADR-004, ADR-006)
- ✅ ORG code two-character constraint called out explicitly in Name Format section (ADR-006)
- ✅ Valid codes section added — departments and device types with WMI detection detail
- ✅ `PB` (Pizza Box) added as planned v3.1 device type
- ✅ `CONTRIBUTING.md` reference added (checklist item 8)

---

*This log should be updated whenever a v3 decision is made or a checklist item is closed.*
