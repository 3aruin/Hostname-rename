# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Ideas — v3.2
- Configurable `Select-NamingMode` timeout (OQ-004 — currently hardcoded 8s)
- Log retention / rotation for the `%TEMP%\Hostname-Rename` directory
- Improve `LT` detection via `Win32_SystemEnclosure.ChassisTypes` (9/10) instead of the `Model` string heuristic

---

## [3.1.0] — 2026-06-03

Feature release. Delivers the entire v3.1 backlog and closes two threads left
open by the v3.0.1 CI work (the BUG-011 test-copy gap and the BOM/ASCII churn).
No breaking changes — every existing invocation behaves as before.

### Added

- **`-FolderPath` and `-Username` (BUG-001).** Now implemented across the full
  call chain (`launcher.ps1` → `Rename-DeviceSmart` → `Get-UserName`), no longer
  documentation-only. `-FolderPath` overrides the `C:\Users` profile search root
  (local or redirected path). `-Username` narrows candidates by case-insensitive
  partial match: interactive sessions show the filtered list to choose from,
  NonInteractive picks the most recently active match (throws if nothing matches).
  Either parameter implies User mode via `Select-NamingMode`.

- **`logging.ps1` — run logging (OQ-001).** New module (loaded first) exposing
  `Initialize-Log` and `Write-Log`. Default destination `%TEMP%\Hostname-Rename`,
  overridable with `-LogPath` (local or UNC). Logging is best-effort and **never
  blocks a rename** — init failures warn and disable; write failures are swallowed
  via `-ErrorAction SilentlyContinue`. `Rename-DeviceSmart` logs gateway, context,
  mode, name parts, the proposed name, and the rename/cancel/WhatIf outcome.

- **`-WhatIf` / `SupportsShouldProcess` (OQ-002).** `Rename-DeviceSmart` is now an
  advanced function with `[CmdletBinding(SupportsShouldProcess)]`; the rename is
  gated by `$PSCmdlet.ShouldProcess`. `launcher.ps1` declares `SupportsShouldProcess`
  and forwards `-WhatIf:$WhatIfPreference` so a dry run works through the `iex` /
  scriptblock deployment surface. Under `-WhatIf` the interactive Y/N prompt is
  skipped and the intended rename is reported instead of performed.

- **`TB` device type and `PB` detection (OQ-003).** `Get-DeviceType` adds a fourth
  parallel CIM query (`Win32_SystemEnclosure`). `TB` = Tablet/Convertible
  (`ChassisTypes` 30/31), `PB` = Pizza Box (`ChassisTypes` 5). Both added to
  `$script:DEVICE_TYPES`. Priority: `VM > SV > TB > MD > LT > PB > DT`.

- **WMI-free helper functions** (`device.ps1`): `Resolve-DeviceType` (the device-type
  priority chain), `ConvertTo-SerialLast4` (serial cleaning/padding), and
  `ConvertTo-CleanUserName` (profile-name cleaning). `Get-DeviceType`,
  `Get-SerialLast4`, and `Get-UserName` now delegate to these.

- **Expanded Pester suite.** `ConvertTo-SerialLast4` and `ConvertTo-CleanUserName`
  tests now exercise the **real** functions instead of inline copies (closes the
  BUG-011 testing gap). New `Resolve-DeviceType` block (chain + priority, incl.
  PB/TB) and new `Select-NamingMode` cases for the `-FolderPath`/`-Username`
  precedence. `PB`/`TB` added to the 15-char NetBIOS integration sweep.

### Changed

- **`launcher.ps1`** — `logging.ps1` prepended to `$MODULES` and `$MANIFEST`
  (loads first). `$MANIFEST` is now `[ordered]` to match `Get-Hashes.ps1` output
  for a clean paste. `Invoke-SelfElevation` now single-quotes forwarded parameter
  *values* (doubling embedded quotes) so a value containing spaces — e.g.
  `-FolderPath "D:\User Profiles"` — survives the UAC relaunch on both the `-File`
  and `iex`/`wt.exe` paths. New `-FolderPath`/`-Username`/`-LogPath` params and the
  `-WhatIf` passthrough wired into the final `Rename-DeviceSmart` call.

- **`tools/Get-Hashes.ps1`** — `logging.ps1` added to the hashed file list (first).

- **ASCII-only conversion completes the BUG-009/010 thread.** `network.ps1`,
  `rename.ps1`, and `tests/Hostname-Rename.Tests.ps1` were converted to ASCII
  (em dashes, arrows, and box-drawing replaced with `--`/`->`) and their BOMs
  removed. The repository is now uniformly ASCII; **no file requires a UTF-8 BOM**,
  which retires the entire `PSUseBOMForUnicodeEncodedFile` class of issues. The
  former `$script:`-scope scriptblock workarounds in the test file
  (`PSUseDeclaredVarsMoreThanAssignments` false positive) are gone — the tests call
  the real helpers, so the cross-scope dance is no longer needed.

### Fixed

- **BUG-001 / BUG-004** — closed in code. `-FolderPath`/`-Username` exist and work;
  no longer "planned" in the docs.

- **`naming.ps1`** — `Select-NamingMode` `.SYNOPSIS` corrected from "15-second" to
  the actual 8-second timeout (a stale docstring edit carried in from v3.0.1).

> **Manifest note:** module file contents changed (new module, edits, BOM removal),
> so anyone running with a populated `$MANIFEST` must regenerate hashes via
> `tools/Get-Hashes.ps1` before redeploying. The canonical repo keeps
> `REPLACE_WITH_HASH` placeholders, so the CI `manifest` job still exits cleanly.

---

## [3.0.1] -- 2026-05-02

CI hygiene patch release. No runtime behaviour changes -- all fixes are linter
compliance, encoding correctness, test scaffolding, and supporting documentation.
Six latent issues in the v3.0.0 CI pipeline surfaced sequentially as each fix
unblocked the next failure (see DECISIONS.md -> BUG-008 "Meta-lesson" for the
chain). One real encoding bug (BUG-009 BOM) was identified and fixed in the
process. BUG-010 captures a practical lesson about ASCII-only justifications.
BUG-011 surfaced once the test job actually ran for the first time since CI
was added.

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
  contains non-ASCII content.**

- **BUG-011** · `tests/Hostname-Rename.Tests.ps1` — five Pester test failures
  cleared. Two distinct issues, both pre-existing in v3.0.0 but masked because
  the test job had never actually run (BUG-008 chain): an orphan `InModuleScope`
  call missing its required `-ModuleName`, and a `$fn` helper declared at
  `Context` (discovery) scope but used in `It` (run) scope. Both resolved by
  wrapping the helper in `BeforeAll { $script:fn = ... }`. A `# TODO (v3.1)` was
  added noting that `Get-SerialLast4` should be refactored so the cleaning logic
  lives in a WMI-free helper the tests can call directly — **done in v3.1 via
  `ConvertTo-SerialLast4`.**

### Changed

- **`.github/workflows/ci.yml`** — bumped `actions/checkout@v4` → `@v6`
  (4 occurrences) and `actions/upload-artifact@v4` → `@v7` to clear the Node.js
  20 deprecation warning surfaced in workflow runs.

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
  `lint` (PSScriptAnalyzer, PS 5.1 + 7.x matrix), `test` (Pester v5 + NUnit XML
  artifact), `manifest` (recomputes module SHA-256 and compares to `$MANIFEST`),
  and `placeholder` (fails branches still containing `REPLACE_WITH_COMMIT_SHA`;
  `continue-on-error: true` on `main` only).

- **`CONTRIBUTING.md`** — deployment workflow, customisation points, local test
  instructions, PR process, code style requirements, and a v3.1 planned work table.

### Fixed

- **BUG-005** · `network.ps1` — `Get-NetworkContext` now opens with an
  `[string]::IsNullOrEmpty` guard before the map lookup, with a clear "no default
  gateway was detected" message that is always fatal regardless of interactive mode.

- **BUG-003** · `device.ps1` — CIM job objects in `Get-DeviceType` cleaned up
  reliably via a `$jobs` array + single `finally`. (Described in the initial v3
  audit but found unapplied in the pre-launch code audit on 2026-04-30; applied then.)

- **BUG-002** · `network.ps1` / `rename.ps1` — hardcoded `RS` fallback ORG replaced
  with a configurable `$script:FALLBACK_CONTEXT` (`XX`/`99`/`X`); `Get-NetworkContext`
  gained `-NonInteractive` (throw in automation, warn prominently interactively),
  forwarded from `Rename-DeviceSmart`.

- **BUG-001 / BUG-004** · `README.md` — `-Folder` corrected to document `C:\Users`
  profile selection; `-FolderPath`/`-Username` marked *(planned — v3.1)*.

### Changed

- **`network.ps1`** — internal `10.72.x.x` gateways replaced with RFC 5737
  documentation ranges; example ORG changed to `AC`; `# -- CONFIGURE YOUR SITES HERE --`
  block added.

- **`README.md`** — RFC 5737 example IPs, explicit ORG two-character constraint,
  Valid Codes section, log-share requirement removed, `PB` listed as planned v3.1,
  `CONTRIBUTING.md` reference added.

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

[Unreleased]: https://github.com/3aruin/Hostname-rename/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/3aruin/Hostname-rename/compare/v3.0.1...v3.1.0
[3.0.1]: https://github.com/3aruin/Hostname-rename/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/3aruin/Hostname-rename/releases/tag/v3.0.0
