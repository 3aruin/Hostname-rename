# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned — v3.1
- `-FolderPath [string]` parameter — custom profile search path for User mode
- `-Username [string]` parameter — partial username matching in User mode
- `PB` device type — Pizza Box / low-profile rack unit via `Win32_SystemEnclosure.ChassisTypes`
- `SupportsShouldProcess` / `-WhatIf` support in `Rename-DeviceSmart` (OQ-002)
- Optional logging scaffold — `Write-Log` wrapper to UNC path or local temp (OQ-001)

---

## [3.0.0] — 2026-04-30

First public / open-source release. Audited from v2 and cleaned for GitHub.
Date updated from 2026-04-28 to 2026-04-30 to reflect pre-launch audit fixes applied before tagging.

### Added

- **`tests/Hostname-Rename.Tests.ps1`** — Pester v5 unit test suite covering all pure-logic
  functions: `New-DeviceName` (name construction and truncation), `New-UserDeviceName`,
  `Get-SerialLast4` (cleaning and padding), `Get-UserName` UPN cleaning steps,
  `Select-NamingMode` switch precedence, `Get-NetworkContext` mapping and fallback, and a
  full integration check of the 15-character NetBIOS limit across all valid
  department/type combinations. No WMI or OS dependency — runs in CI without a real device.

- **`.github/workflows/ci.yml`** — four-job CI pipeline (OQ-005, ADR-002):
  - `lint` — PSScriptAnalyzer on all `.ps1` files, PS 5.1 and 7.x matrix
  - `test` — Pester v5 unit tests with NUnit XML artifact upload
  - `manifest` — recomputes SHA-256 for each module file and asserts it matches
    the corresponding entry in `$MANIFEST` in `launcher.ps1`; catches the case where
    module files are updated but `launcher.ps1` is not
  - `placeholder` — fails any branch where `launcher.ps1` still contains
    `REPLACE_WITH_COMMIT_SHA`; `continue-on-error: true` on `main` only so the
    canonical template state does not break CI

- **`PSScriptAnalyzerSettings.psd1`** — centralised analyzer configuration
  (ADR-007). Excludes `PSAvoidUsingWriteHost` project-wide with documented
  rationale: this is an interactive console tool and `Write-Host` is correct
  for menus, prompts, and operator-visible status. `Write-Output` would corrupt
  function return values; `Write-Information` would be invisible without callers
  setting `$InformationPreference = 'Continue'`. The `lint` job in `ci.yml`
  passes the file via `Invoke-ScriptAnalyzer -Settings`.

- **`CONTRIBUTING.md`** — deployment workflow (step-by-step, fork and canonical repo),
  customisation points (gateways, departments, device types, `$GATEWAY_MAP`
  externalisation pattern), local test instructions, PR process, code style requirements,
  and a v3.1 planned work table.

### Fixed

- **BUG-006** · CI lint pipeline — first run of `Invoke-ScriptAnalyzer` against
  the v3 codebase surfaced 15 warnings across three rules. All three resolved
  before tagging:

  - **`PSAvoidUsingWriteHost`** (12 occurrences across `device.ps1`,
    `rename.ps1`, and `naming.ps1`) — suppressed project-wide via the new
    `PSScriptAnalyzerSettings.psd1` (ADR-007). Write-Host is intentional for
    interactive prompts; replacing it with `Write-Output` would corrupt
    function returns and `Write-Information` is invisible without caller-set
    `$InformationPreference`.

  - **`PSUseBOMForUnicodeEncodedFile`** (3 files: `network.ps1`, `rename.ps1`,
    `tests/Hostname-Rename.Tests.ps1`) — non-ASCII characters (em dashes `—`,
    box-drawing `─`, arrows `→`) replaced with ASCII equivalents (`--`, `-`,
    `->`). Adding a UTF-8 BOM was the alternative but would have changed the
    bytes of `network.ps1` in a way that left the Get-Content/UTF8.GetBytes
    hashing path in `launcher.ps1` and `Get-Hashes.ps1` interacting awkwardly
    with the BOM character across PS 5.1 vs 7.x. Replacing with ASCII keeps
    the integrity model unambiguous.

  - **`PSUseDeclaredVarsMoreThanAssignments`** (1 occurrence in the test file)
    — `$clean` scriptblock in the `Get-UserName name cleaning` Describe block
    was set in `BeforeAll` and used in `It` blocks, but the analyzer cannot
    trace across that boundary. Promoted to `$script:clean` (the documented
    Pester v5 pattern for cross-block state); the assignment and all eight
    call sites updated.

- **BUG-011** · `.github/workflows/ci.yml` — `placeholder` job (the only one
  running on `ubuntu-latest`) failed every run with `ParserError: Missing
  '(' after 'if' in if statement.` The workflow's top-level
  `defaults.run.shell: pwsh` was applying to every step in every job,
  including the Bash-syntax grep check on the Linux runner — pwsh was being
  asked to parse `if grep -q "..." ...; then`. Added `shell: bash` to that
  one step as a per-step override; the workflow-wide pwsh default stays
  intact for the three Windows jobs.

- **BUG-010** · `naming.ps1` — `PSUseShouldProcessForStateChangingFunctions`
  fired on `New-DeviceName` and `New-UserDeviceName`. PSScriptAnalyzer treats
  every `New-`-verb function as a candidate resource-creation function that
  should expose `-WhatIf`/`-Confirm` semantics. Both functions are pure: they
  compose a string from input parameters and return it, with no state change
  to confirm or roll back. Suppressed per-function via
  `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` with a
  `Justification` documenting why, rather than excluding the rule globally
  in `PSScriptAnalyzerSettings.psd1` — that would silence the rule for any
  *future* state-changing function added to the codebase, which is exactly
  the case the rule is designed to catch.

- **BUG-009** · `tests/Hostname-Rename.Tests.ps1` — Pester container kept
  failing after BUG-008 with a real error this time:
  `CommandNotFoundException: The term 'D:\...\tests/../naming.ps1' is not
  recognized as a name of a cmdlet, function, script file, or executable
  program.` On Windows runners, the dot-source operator's pre-resolution path
  lookup does not normalise mixed-slash relative segments — the path arrives
  as `\tests` (backslash from `$PSScriptRoot`) followed by `/..` (forward slash
  from the test source), and the command resolver gives up before .NET's
  Path normalisation gets a chance to fold the `..` segment. Replaced
  `"$PSScriptRoot/../naming.ps1"` (and the two siblings) with a `Join-Path`
  construction off `Split-Path -Parent $PSScriptRoot`. Cross-platform,
  separator-agnostic, and the established PowerShell-idiomatic pattern.

- **BUG-008** · `tests/Hostname-Rename.Tests.ps1` — first run of the Pester v5
  test job (after BUG-006/BUG-007 unblocked the lint stage and the
  `Run.PassThru` fix unblocked `Invoke-Pester`) failed the entire container:
  Discovery found 38 tests, then all 38 reported as failed with no individual
  error messages — the diagnostic signature of a container-level Run-phase
  failure. Two defects in the `Get-SerialLast4` Describe:

  - Helper scriptblock `$fn` was defined at Context body level, which Pester
    v5 evaluates during the Discovery phase. Per the Pester v5
    breaking-changes docs, variables defined during Discovery are not
    available in `It`, `BeforeAll`, or `BeforeEach` blocks at Run time, so
    every reference resolved to `$null` and `& $null` threw. Fixed by
    hoisting the helper into a Describe-level `BeforeAll` assigned to
    `$script:fn` — the same cross-block pattern used for `$script:clean` in
    BUG-006c.

  - Empty `InModuleScope -Scriptblock { }` call inside the first `It` block —
    leftover scaffolding for a mock that was never written. Missing required
    `-ModuleName` parameter, empty body. Removed.

  While there, the helper was inlined three times across the first Context's
  three `It` blocks; deduplicated against the new `BeforeAll`. No test count
  or assertion change — 38 tests in, 38 tests out.

- **BUG-007** · `launcher.ps1` — `PSUseUsingScopeModifierInNewRunspaces` false
  positive on the parallel-fetch loop. The original code used the standard
  `Start-Job ... -ArgumentList $url` pattern with a matching `param($u)` block
  inside the scriptblock — `$u` *is* declared inside the scriptblock by the
  param block, but the analyzer's static check doesn't recognise that and flags
  both the param declaration and the usage as undeclared cross-runspace
  references. Switched to `$using:url`, which is more idiomatic for `Start-Job`
  in modern PowerShell, snapshots the loop variable's current value into each
  job's runspace at `Start-Job` time (preserving per-iteration correctness),
  and silences the warning without disabling a rule that catches genuine bugs
  elsewhere.

- **`ci.yml`** — `lint` job updated to pass
  `-Settings ./PSScriptAnalyzerSettings.psd1` to `Invoke-ScriptAnalyzer` so the
  exclusion is honoured in CI. `test` job's `Invoke-Pester` call updated to
  set `$cfg.Run.PassThru = $true` on the configuration object instead of
  passing `-PassThru` as a parameter — Pester v5's Simple and Advanced parameter
  sets cannot be combined and the previous form threw "Parameter set cannot be
  resolved" on every run.

- **BUG-005** · `network.ps1` — `Get-NetworkContext` now opens with an
  `[string]::IsNullOrEmpty` guard before the map lookup. Previously, if
  `Get-DefaultGateway` returned `$null` (no enabled adapter with a default gateway),
  the error read `"Gateway '' was not found in GATEWAY_MAP"`, which pointed the
  operator at the wrong fix. The new message reads `"No default gateway was detected
  on this machine"` and is always fatal regardless of interactive mode, since location
  cannot be determined without a gateway under either naming path.

- **BUG-003** · `device.ps1` — CIM job objects in `Get-DeviceType` now cleaned up
  reliably. Jobs collected into a `$jobs` array declared before the `try` block; a
  single `finally` clause pipes the whole array to
  `Remove-Job -Force -ErrorAction SilentlyContinue` regardless of how the `try` block
  exits. *Note: this fix was described in the initial v3 audit and incorrectly marked
  complete at that time. A pre-launch code audit on 2026-04-30 found that the fix had
  never been applied to the file — the original three named job variables with inline
  `Remove-Job` calls were still present. The fix was applied at this point.*

- **BUG-002** · `network.ps1` — hardcoded `RS` fallback ORG code replaced with a
  configurable `$script:FALLBACK_CONTEXT` variable (`ORG = "XX"`, `WH = "99"`,
  `LOC = "X"`). `Get-NetworkContext` now accepts `-NonInteractive`: throws with an
  actionable error in automated deployments; emits a prominent four-line
  `Write-Warning` block in interactive sessions so the technician cannot miss it.

- **BUG-002** · `rename.ps1` — `-NonInteractive:$NonInteractive` forwarded to
  `Get-NetworkContext` so the throw/warn split works end-to-end.

- **BUG-001 / BUG-004** · `README.md` — `-Folder` description corrected to document
  `C:\Users` profile directory selection (previously described as Desktop subfolder
  reading). `-FolderPath` and `-Username` parameters moved to the Available Parameters
  table and marked *(planned — v3.1)*; no longer documented as implemented.

### Changed

- **`.github/workflows/ci.yml`** — GitHub Actions runtime versions bumped to
  Node.js 24 ahead of the Node 20 deprecation deadline (Node 20 forced off
  default 2 June 2026, removed 16 September 2026):
  - `actions/checkout` v4 → v5 (4 references — one per job: `lint`, `test`,
    `manifest`, `placeholder`)
  - `actions/upload-artifact` v4 → v6 (1 reference in the `test` job)

  Both new versions ship with `runs.using: node24` by default and require
  Actions Runner v2.327.1 or newer. GitHub-hosted runners (`windows-latest`,
  `ubuntu-latest`) keep this current automatically; self-hosted runners would
  need to be on 2.327.1+ before merging this change.

- **`network.ps1`** — all six internal `10.72.x.x` gateway IPs replaced with RFC 5737
  documentation-range addresses (`192.0.2.x`, `198.51.100.x`, `203.0.113.x`). Example
  ORG code changed from `RB` to `AC`. A `# -- CONFIGURE YOUR SITES HERE --` comment
  block added above the map entries.

- **`README.md`** — gateway map example updated to RFC 5737 IPs and `AC` org code. ORG
  two-character constraint called out explicitly in the Name Format section. Valid Codes
  section added — full department and device type tables with WMI detection detail.
  "Network access to log share" requirement removed (no logging code exists). `PB`
  listed as a planned v3.1 device type. `CONTRIBUTING.md` reference added.

### Architecture decisions recorded

| ADR | Decision |
|---|---|
| ADR-001 | Module loading model: remote fetch + dot-source (carry forward from v2) |
| ADR-002 | Pin deployments to full 40-character commit SHA, never `main` |
| ADR-003 | Two naming modes — Gateway `{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}` and User `{WH}{LOC}-{Name}` |
| ADR-004 | Organisation data lives in `network.ps1`; example data uses RFC 5737 IPs |
| ADR-005 | No external dependencies — built-in cmdlets and .NET types only |
| ADR-006 | ORG code constrained to exactly two characters (15-char NetBIOS hostname limit) |
| ADR-007 | Suppress `PSAvoidUsingWriteHost` project-wide via `PSScriptAnalyzerSettings.psd1` (interactive console tool; alternatives break runtime behaviour) |

---

## [2.0.0] — internal, not publicly released

Functional version used in internal deployments. Carried forward the core architecture
(parallel module fetching, SHA-256 manifest check, self-elevation with UAC-hop parameter
forwarding, parallel CIM queries) with the following known issues — all resolved in v3.0.0:

- Hardcoded internal gateway IPs and org-specific `RB` fallback code
- README documented `-FolderPath` and `-Username` parameters that were not implemented
- `-Folder` mode described as reading Desktop subfolders; implementation read `C:\Users`
- CIM job objects in `Get-DeviceType` leaked if a query threw before `Remove-Job` was reached
- `Get-NetworkContext` silently returned the `RS` fallback ORG on any unrecognised gateway,
  including during non-interactive / MDM deployments where a wrong name is worse than a failure

---

[Unreleased]: https://github.com/3aruin/Hostname-rename/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/3aruin/Hostname-rename/releases/tag/v3.0.0
