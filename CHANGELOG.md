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

[Unreleased]: https://github.com/3aruin/Hostname-rename/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/3aruin/Hostname-rename/releases/tag/v3.0.0
