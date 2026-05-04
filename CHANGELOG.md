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

## [3.0.1] — 2026-05-02

CI hygiene patch release. No runtime behaviour changes — all fixes are linter
compliance, encoding correctness, and supporting documentation. Five latent
issues in the v3.0.0 CI pipeline surfaced sequentially as each fix unblocked
the next failure (see DECISIONS.md → BUG-008 "Meta-lesson" for the chain). One
real encoding bug (BUG-009 BOM) was identified and fixed in the process. BUG-010
also captures a practical lesson about ASCII-only justifications to avoid
creating BOM cascades.

### Fixed

- **BUG-006** · `.github/workflows/ci.yml` — `placeholder` job step now sets
  `shell: bash` explicitly. The workflow has a global `defaults.run.shell: pwsh`,
  which the `placeholder` job inherited despite running on `ubuntu-latest` with a
  bash one-liner (`if grep -q ...; then ... fi`). pwsh tried to parse the bash
  `if` as a PowerShell `if` statement and failed before grep ran with
  `Missing '(' after 'if' in if statement.` The bug was masked on `main` by the
  `continue-on-error: true` guard from ADR-002 — every push to `main` looked
  green even though the placeholder check had never actually executed since CI
  was added. Fixed by overriding `shell: bash` on that single step; the global
  `pwsh` default is retained for the three Windows-based jobs that need it.

- **BUG-007** · `tools/Get-Hashes.ps1` — eight `Write-Host` calls (the manifest
  block header and "Next steps" footer) replaced with bare-string expressions to
  clear `PSAvoidUsingWriteHost` warnings from the `lint` CI job. As a side
  benefit, this fixes a latent redirection bug: the script was previously
  inconsistent — the framing went through `Write-Host` while the actual hash
  lines went to the success stream — so `.\tools\Get-Hashes.ps1 > manifest.txt`
  silently dropped the framing and captured only the hash lines. With everything
  on the success stream now, redirection captures the complete pasteable block.
  Console behaviour for interactive runs is unchanged.

- **BUG-008** · `.github/workflows/ci.yml` — `test` job's Pester invocation now
  sets `$cfg.Run.PassThru = $true` on the configuration object and calls
  `Invoke-Pester -Configuration $cfg` without `-PassThru`. In Pester v5,
  `-Configuration` and `-PassThru` belong to mutually exclusive parameter sets;
  combining them fails parameter-set resolution before any test runs
  (`Parameter set cannot be resolved using the specified named parameters`).
  The bug had been latent since CI was added in v3.0.0 — the `test` job
  declares `needs: lint`, so while `lint` was failing under BUG-007 the `test`
  job was being **skipped** rather than failing, and the CI looked
  broken-but-explained for an unrelated reason. Surfaced as soon as lint was
  fixed and `test` ran for the first time.

- **BUG-009** · Multiple files — analyzer warnings cleared without compromising
  intent. The `lint` job, finally able to scan the full codebase after BUG-007
  unblocked it, surfaced four categories of warning:
  - `PSAvoidUsingWriteHost` — flagged 9 calls in `device.ps1`, `naming.ps1`, and
    `rename.ps1`. All are interactive prompts paired with `Read-Host` and
    correctly target the host stream rather than success — capturing them
    downstream would defeat the purpose. Suppressed per-function via
    `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` with justifications
    documented inline. No project-level settings file was added (see DECISIONS.md
    BUG-009 rationale).
  - `PSUseShouldProcessForStateChangingFunctions` — flagged `New-DeviceName` and
    `New-UserDeviceName` in `naming.ps1`. False positive: both are pure
    string-builder functions that take parameters and return a string; the verb
    `New-` is correct (the function produces a new value). Suppressed per-function
    with justification. The same rule will *correctly* fire against
    `Rename-DeviceSmart` once OQ-002 (`SupportsShouldProcess`/`-WhatIf`) is
    implemented in v3.1; that suppression is deliberately *not* applied so the
    warning surfaces when relevant.
  - `PSUseBOMForUnicodeEncodedFile` — flagged `network.ps1`, `rename.ps1`, and
    `tests/Hostname-Rename.Tests.ps1`. Real fix, not suppression: all three files
    contain non-ASCII characters (em dashes, fancy quotes, box-drawing dividers)
    but lacked a UTF-8 byte-order mark. Windows PowerShell 5.1 reads BOM-less
    files as Latin-1 by default and would garble those characters. All three
    files re-saved as UTF-8 with BOM (bytes `EF BB BF` prepended).
  - `PSUseDeclaredVarsMoreThanAssignments` — flagged `$clean` in
    `tests/Hostname-Rename.Tests.ps1` line 157. False positive caused by
    cross-scope reference in Pester (variable declared in `BeforeAll`, used in
    `It` blocks). Fixed properly by promoting the variable to `$script:` scope,
    which is also semantically more correct — Pester's scope inheritance happens
    to make the original code work, but `$script:` makes the cross-scope intent
    explicit. All 8 `It` block call sites updated.

  Note for anyone who has populated `$MANIFEST` in `launcher.ps1` with real
  hashes: `network.ps1` and `rename.ps1` content changed (BOM bytes added), so
  manifest hashes for those two files need to be regenerated via
  `tools/Get-Hashes.ps1` before re-deployment. The canonical repo's `$MANIFEST`
  uses `REPLACE_WITH_HASH` placeholders, so the CI `manifest` job exits cleanly
  with no check performed.

- **BUG-010** · `launcher.ps1` + `device.ps1` + `naming.ps1` — two more analyzer
  warnings surfaced after BUG-009. (1) `PSUseUsingScopeModifierInNewRunspaces`
  flagged `$u` on lines 138–139 of `launcher.ps1`, inside a `Start-Job` script
  block. False positive: the variable IS declared inside the block via
  `param($u)` and the value is passed in via `-ArgumentList $url`, which is the
  idiomatic and preferred pattern (switching to `$using:` would be a regression).
  Resolution: file-level `[SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', ...)]`
  on `launcher.ps1`'s top param block with justification. (2)
  `PSUseBOMForUnicodeEncodedFile` flagged `device.ps1` and `naming.ps1` — both
  files were ASCII-only in v3.0.0 but the BUG-009 SuppressMessage justification
  strings I added contained em dashes (U+2014), pushing them into "non-ASCII file
  needs BOM" territory. Resolution: replaced 2 em dashes in `device.ps1` and 3 in
  `naming.ps1` with `--`, returning both files to ASCII-only and clearing the
  warning. **Practical lesson — keep new code ASCII-only unless the file already
  contains non-ASCII content.** Adding a single Unicode character to an
  otherwise-ASCII file forces the BOM rule to fire and creates avoidable churn.
  Comments and justifications should default to plain `--`, regular quotes, and
  ASCII-only punctuation. The pre-existing files that genuinely need a BOM
  (`network.ps1`, `rename.ps1`, the test file) all have non-ASCII content for
  good reasons (warning-block dividers, box-drawing in section headers); those
  stay as-is.

### Changed

- **`.github/workflows/ci.yml`** — bumped `actions/checkout@v4` → `@v6`
  (4 occurrences) and `actions/upload-artifact@v4` → `@v7` to clear the Node.js
  20 deprecation warning surfaced in workflow runs. Both `@v4` versions ran on
  Node.js 20, which GitHub is removing from the runner on September 16th, 2026
  (default flips to Node.js 24 on June 2nd, 2026). Note: `actions/upload-artifact@v5`
  is *not* sufficient — v5 had preliminary Node 24 support but still defaulted
  to Node 20 at runtime; v6 was the first release where Node 24 is the default,
  v7 is the current latest. Both new versions require Actions Runner v2.327.1+,
  which `windows-latest` and `ubuntu-latest` provide automatically.

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

- **`CONTRIBUTING.md`** — deployment workflow (step-by-step, fork and canonical repo),
  customisation points (gateways, departments, device types, `$GATEWAY_MAP`
  externalisation pattern), local test instructions, PR process, code style requirements,
  and a v3.1 planned work table.

### Fixed

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

[Unreleased]: https://github.com/3aruin/Hostname-rename/compare/v3.0.1...HEAD
[3.0.1]: https://github.com/3aruin/Hostname-rename/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/3aruin/Hostname-rename/releases/tag/v3.0.0
