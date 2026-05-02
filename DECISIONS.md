# Hostname-Rename — Decisions Log

**Project:** Hostname-Rename  
**License:** MIT © 2026 Simms  
**Target:** v3 — clean, open GitHub release  
**Latest release:** v3.0.1 (2026-05-02) — CI hygiene patch (BUG-006, BUG-007, BUG-008, Node 24 action bumps)  
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

### BUG-006 · `placeholder` CI job parser error masked by `continue-on-error: true`

**Severity:** Medium — guard never actually fired; failed branches looked the same as passing ones  
**Status:** ✅ Resolved (2026-05-01) — released in v3.0.1  
**Location:** `.github/workflows/ci.yml → placeholder` job

**Was:** A workflow-level `defaults.run.shell: pwsh` was set so the three PowerShell jobs (`lint`, `test`, `manifest`) wouldn't have to specify a shell on every step. The `placeholder` job runs on `ubuntu-latest` and its only step is a bash one-liner (`if grep -q "REPLACE_WITH_COMMIT_SHA" launcher.ps1; then ... fi`), but it inherited the global `pwsh` default. pwsh tried to parse the bash `if` as a PowerShell `if` statement and died on line 2:

```
ParserError:
Line | 2 | if grep -q "REPLACE_WITH_COMMIT_SHA" launcher.ps1; then
     |    | Missing '(' after 'if' in if statement.
```

The error fired before grep ran. Every push to `main` masked this because `continue-on-error: true` is set on the step for `main` only (per ADR-002 — keep the canonical-template state from breaking CI). Result: the ADR-002 guard had never actually executed on any branch since CI was added.

**Resolution:** `shell: bash` set on the single step that needs it. The three other jobs still inherit `pwsh` from the global default since they all run PowerShell on Windows runners.

**Lesson for future CI work:** A `continue-on-error` guard around a step that errors for the *wrong* reason (parser error) looks identical to one that errors for the *right* reason (guard tripped). When introducing `continue-on-error`, run the workflow on a feature branch at least once to confirm the underlying check actually executes.

---

### BUG-007 · `Get-Hashes.ps1` framing lost on output redirection (and PSScriptAnalyzer noise)

**Severity:** Low — cosmetic CI failure, plus a latent edge case for redirection users  
**Status:** ✅ Resolved (2026-05-01) — released in v3.0.1  
**Location:** `tools/Get-Hashes.ps1`

**Was:** The script was inconsistent about output streams. Eight `Write-Host` calls printed the manifest framing (header lines, opening `$MANIFEST = [ordered]@{`, closing `}`, "Next steps"), while the actual hash entries used a bare-string expression (`'    "{0}" = "{1}"' -f $file, $hex`) that went to the success stream. Two consequences:

1. `PSScriptAnalyzer` flagged all eight `Write-Host` calls under `PSAvoidUsingWriteHost`, breaking the `lint` job in CI.
2. Output redirection silently dropped half the script's output. `.\tools\Get-Hashes.ps1 > manifest.txt` produced a file containing only the inner hash lines, with no surrounding `$MANIFEST = [ordered]@{` / `}` framing — the user would have to copy the framing back in by hand. This was never a documented use case but it's a reasonable thing to try, and the failure mode was silent.

**Resolution:** All eight `Write-Host` calls converted to bare-string expressions (`""`, `"# Paste this block ..."`, `"}"`, etc.). Everything now flows through the success stream. Interactive console output is identical (PowerShell displays the success stream by default). Redirection now captures the complete pasteable block.

**Note on the broader Write-Host situation:** `device.ps1`, `naming.ps1`, and `rename.ps1` also contain `Write-Host` calls (for interactive prompts paired with `Read-Host`), but those were *not* flagged in the same CI run that flagged `Get-Hashes.ps1`. The reason isn't fully understood — possibly an analyzer-version subtlety around `Write-Host` inside vs outside functions, possibly something else. Those usages are deliberate (the calls write to the user's terminal, not to a stream that downstream callers might capture) and the right fix if they ever do trip the linter is *not* the same as the one applied here — it would be either a per-function `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` or a project-level `PSScriptAnalyzerSettings.psd1` excluding the rule. Left as-is for now; revisit only if a real failure surfaces.

---

### BUG-008 · Pester invocation used incompatible parameter sets — `test` job had never actually run

**Severity:** Medium — the `test` job had never executed since CI was added in v3.0.0  
**Status:** ✅ Resolved (2026-05-01) — released in v3.0.1  
**Location:** `.github/workflows/ci.yml → test` job, "Run Pester" step

**Was:** The Pester invocation combined `-Configuration` and `-PassThru`:

```powershell
$result = Invoke-Pester -Configuration $cfg -PassThru
```

In Pester v5 these belong to **different parameter sets** and cannot be combined. The `Configuration` parameter set requires every runtime option (including `PassThru`) to be set on the configuration object. PowerShell rejected the call before any test ran:

```
Invoke-Pester: Parameter set cannot be resolved using the specified named
parameters. One or more parameters issued cannot be used together or an
insufficient number of parameters were provided.
```

**Why this stayed hidden:** The bug had been latent since CI was added in v3.0.0. Two earlier failures masked it:

1. BUG-006 had `placeholder` failing for the wrong reason on every branch, but `continue-on-error: true` on `main` made it look green on the canonical branch.
2. BUG-007 had `lint` failing on `PSAvoidUsingWriteHost` warnings.

Because the `test` job declares `needs: lint`, while lint was failing the `test` job was being **skipped**, not failing. Skipped jobs don't show as red — the workflow chain looked broken-but-explained for an unrelated reason rather than surfacing this bug. As soon as lint was fixed (BUG-007), the `test` job ran for the first time and immediately surfaced this issue.

**Resolution:** `PassThru` moved onto the configuration object:

```powershell
$cfg.Run.PassThru = $true
$result = Invoke-Pester -Configuration $cfg
```

Inline comment added next to the call documenting the parameter-set rule so the next person to touch this code doesn't reintroduce the mistake.

**Meta-lesson — `needs:` chains in CI hide downstream bugs:** Across BUG-006, BUG-007, and BUG-008, three latent bugs were chained behind two layers of "looks fine but isn't actually running" — `continue-on-error` on `main`, then `needs: lint` skipping the test job. Each fix surfaced the next failure. Takeaway: when adding or fixing CI, run each job in isolation at least once. A green check on a workflow run does not mean every job inside it actually executed; jobs can be skipped or `continue-on-error`-swallowed and look identical to a healthy run from the summary view. Worth glancing at the run's individual job statuses, not just the workflow result.

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
| 5 | Add `SupportsShouldProcess` / `-WhatIf` to `Rename-DeviceSmart` (OQ-002) | Enhancement | Medium | ⬜ Open — deferred to v3.1 |
| 7 | Add optional logging scaffold (OQ-001) | Enhancement | Low | ⬜ Open — deferred to v3.1 |

---

## File-by-File Notes

### `launcher.ps1`
- Core model is sound; carry forward as-is structurally
- Param block needs `-FolderPath` and `-Username` once BUG-001 is resolved in v3.1
- `$REPO_BASE` hardcodes the author's GitHub path — fine for the canonical repo, documented for forks in `CONTRIBUTING.md`

### `network.ps1`
- ✅ All six `10.72.x.x` entries replaced with RFC 5737 documentation IPs (ADR-004)
- ✅ `$FALLBACK_CONTEXT` variable added — replaces hardcoded `RS` fallback (BUG-002)
- ✅ `Get-NetworkContext` updated — throws in NonInteractive, warns prominently in interactive (BUG-002)
- ✅ Null/empty gateway guard added to `Get-NetworkContext` — throws with a clear "no gateway detected" message before the map lookup (BUG-005)

### `device.ps1`
- ✅ CIM job cleanup fixed — `$jobs` array + `finally` block (BUG-003; fix confirmed and applied in pre-launch audit 2026-04-30)
- BUG-001 (`-FolderPath` / `-Username`) deferred to v3.1 — `Get-UserName` unchanged for now
- `$script:VALID_DEPARTMENTS` and `$script:DEVICE_TYPES` documented in README as extension points

### `naming.ps1`
- No bugs found; logic verified correct by pre-launch audit
- `New-DeviceName`, `New-UserDeviceName`, and `Select-NamingMode` all covered by Pester tests

### `rename.ps1`
- ✅ `-NonInteractive:$NonInteractive` forwarded to `Get-NetworkContext` (BUG-002)
- `Rename-DeviceSmart` still needs `SupportsShouldProcess` (OQ-002, checklist item 5) — deferred to v3.1
- Param additions for BUG-001 deferred to v3.1

### `tools/Get-Hashes.ps1`
- The CI `manifest` job (OQ-005) performs equivalent verification automatically on every PR — no longer a manual-only step
- ✅ `Write-Host` calls replaced with bare-string expressions to clear `PSAvoidUsingWriteHost` warnings; also fixes a latent redirection bug where the framing was lost when the script was piped to a file (BUG-007, fixed 2026-05-01)

### `tests/Hostname-Rename.Tests.ps1` *(new in v3)*
- Pester v5 test suite covering all pure-logic functions: `New-DeviceName`, `New-UserDeviceName`, `Get-SerialLast4` cleaning and padding, `Get-UserName` UPN cleaning steps, `Select-NamingMode` switch precedence, `Get-NetworkContext` mapping and fallback, and a full integration check of the 15-character NetBIOS limit across all valid department/type combinations
- No WMI or OS dependency — all tests run in CI without a real Windows device
- Run locally: `Invoke-Pester ./tests/Hostname-Rename.Tests.ps1 -Output Detailed`

### `.github/workflows/ci.yml` *(new in v3)*
- Four jobs: `lint`, `test`, `manifest`, `placeholder` — see OQ-005 for detail
- `lint` runs a PS 5.1 / 7.x matrix via `windows-latest`
- `placeholder` runs on `ubuntu-latest` (faster, no PS needed for a grep check)
- ✅ `shell: bash` set on the `placeholder` grep step — required because the workflow-level `pwsh` default would otherwise be inherited (BUG-006, fixed 2026-05-01)
- ✅ `actions/checkout@v6` and `actions/upload-artifact@v7` — bumped from `@v4` to clear the Node.js 20 deprecation warning. Note that `upload-artifact@v5` was insufficient (still defaulted to Node 20 at runtime); v6 was the first release with Node 24 as the default. (2026-05-01)
- ✅ Pester invocation uses `$cfg.Run.PassThru = $true` on the config object instead of `-PassThru` as a cmdlet parameter — the two are in mutually exclusive parameter sets in Pester v5 (BUG-008, fixed 2026-05-01)

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
