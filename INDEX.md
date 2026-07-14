# Hostname-Rename — Repo Index

A map of every file in this repo, what it's for, and where to look for common tasks.

For a full project overview, start with [`README.md`](README.md).

---

## File Map

### Entry point

| File | Purpose |
|---|---|
| [`launcher.ps1`](launcher.ps1) | Fetches all modules over HTTPS, verifies SHA-256 hashes against `$MANIFEST`, self-elevates via UAC, dot-sources modules, and hands off to `Rename-DeviceSmart`. Pinned in the `iwr` deployment URL. |

### Modules (dot-sourced by `launcher.ps1`)

| File | Responsibility | Key functions / data |
|---|---|---|
| [`logging.ps1`](logging.ps1) | Run logging — loaded first; never blocks a rename. Prunes its own logs older than `$LOG_RETENTION_DAYS` from the default directory (ADR-009) | `Initialize-Log`, `Write-Log`, `Remove-OldLogFile`, `$LOG_RETENTION_DAYS` |
| [`network.ps1`](network.ps1) | Gateway detection and site context resolution | `$GATEWAY_MAP`, `$FALLBACK_CONTEXT`, `Get-DefaultGateway`, `Get-NetworkContext` |
| [`device.ps1`](device.ps1) | Department prompt, device type auto-detection, serial number, user profile selection | `$VALID_DEPARTMENTS`, `$DEVICE_TYPES`, `Get-Department`, `Get-DeviceType`, `Resolve-DeviceType`, `Get-SerialLast4`, `ConvertTo-SerialLast4`, `Get-UserName`, `ConvertTo-CleanUserName` |
| [`naming.ps1`](naming.ps1) | Naming-mode selection (timed prompt, `-PromptTimeoutSeconds`) and name construction (15-char NetBIOS enforcement) | `Select-NamingMode`, `New-DeviceName`, `New-UserDeviceName` |
| [`gui.ps1`](gui.ps1) | Optional WPF window for `-Gui` — collects the same inputs as the console prompts, never renames; any failure falls back to the console | `Show-RenameGui`, `Resolve-GatewayPreview`, `Get-RenameGuiXaml`, `Update-RenameGuiPreview`, `$GUI_UNAVAILABLE` |
| [`rename.ps1`](rename.ps1) | Orchestrator — wires the modules above together (and owns all logging); dispatches to `Show-RenameGui` under `-Gui` | `Rename-DeviceSmart` |

### Tests

| File | Purpose |
|---|---|
| [`tests/Hostname-Rename.Tests.ps1`](tests/Hostname-Rename.Tests.ps1) | Pester v5 unit tests for all pure-logic functions. No WMI / OS dependency — runs in CI without a real device. |
| [`tests/Hostname-Rename.Gui.Tests.ps1`](tests/Hostname-Rename.Gui.Tests.ps1) | Pester v5 tests for the `-Gui` feature: `Resolve-GatewayPreview` logic, an XAML smoke test (skips cleanly where WPF is absent), and mock-based `Rename-DeviceSmart -Gui` parameter contracts. Same no-WMI/OS/GUI conventions. |

### CI

| File | Purpose |
|---|---|
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | Four-job pipeline: `lint` (PSScriptAnalyzer, PS 5.1 + 7.x matrix), `test` (Pester), `manifest` (recomputes module hashes and compares against `$MANIFEST` in `launcher.ps1`), `placeholder` (fails on un-replaced `REPLACE_WITH_COMMIT_SHA`). |

### Tools

| File | Purpose |
|---|---|
| [`tools/Get-Hashes.ps1`](tools/Get-Hashes.ps1) | Local helper — regenerates the `$MANIFEST` block for paste into `launcher.ps1` after any module change. |

### Documentation

| File | Purpose |
|---|---|
| [`README.md`](README.md) | User-facing overview — name format, requirements, first-time setup, parameters, valid codes. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Deployment workflow, customisation points, local test instructions, PR process, code style. |
| [`CHANGELOG.md`](CHANGELOG.md) | Versioned record of what changed, why, and what's planned. Keep-a-Changelog format. |
| [`DECISIONS.md`](DECISIONS.md) | Architectural decision records (ADRs), bug history, open questions, file-by-file audit notes. The "why" behind the code. |
| [`INDEX.md`](INDEX.md) | This file. |

---

## Where do I find…?

### Operator / deploying the tool

| I want to… | Go here |
|---|---|
| Run the tool for the first time | [`README.md`](README.md) → Running |
| Run with the GUI instead of console prompts | [`README.md`](README.md) → Running → GUI mode |
| Understand the name format | [`README.md`](README.md) → Name Format |
| Add a new site gateway | [`network.ps1`](network.ps1) → `$GATEWAY_MAP`, then [`CONTRIBUTING.md`](CONTRIBUTING.md) → Deployment Workflow |
| Add a department code | [`device.ps1`](device.ps1) → `$VALID_DEPARTMENTS` |
| Add a device type | [`device.ps1`](device.ps1) → `$DEVICE_TYPES` + a branch in `Resolve-DeviceType` (also [`README.md`](README.md) → Valid Codes) |
| Deploy from a fork | [`CONTRIBUTING.md`](CONTRIBUTING.md) → Forking the repo |
| Regenerate `$MANIFEST` after a code change | [`tools/Get-Hashes.ps1`](tools/Get-Hashes.ps1), then paste into [`launcher.ps1`](launcher.ps1) |
| Change the naming-mode prompt timeout | Pass `-PromptTimeoutSeconds` (1–300, default 8) — see [`README.md`](README.md) → Available Parameters |
| Change how long run logs are kept | [`logging.ps1`](logging.ps1) → `$LOG_RETENTION_DAYS` (default 30 days; default log directory only, ADR-009) |
| Push out a new version safely | [`CONTRIBUTING.md`](CONTRIBUTING.md) → Deployment Workflow (steps 1–7) |

### Contributor / changing the code

| I want to… | Go here |
|---|---|
| Understand the integrity model (why pin a commit SHA?) | [`DECISIONS.md`](DECISIONS.md) → ADR-001, ADR-002 |
| See why fallback ORG is `XX`/`99`/`X` | [`DECISIONS.md`](DECISIONS.md) → BUG-002, ADR-004 |
| Understand the 15-char NetBIOS constraint | [`DECISIONS.md`](DECISIONS.md) → ADR-006; [`naming.ps1`](naming.ps1) → `New-DeviceName` |
| Run the test suite locally | [`CONTRIBUTING.md`](CONTRIBUTING.md) → Running Tests Locally |
| See what shipped in v3.2 | [`CHANGELOG.md`](CHANGELOG.md) → [3.2.0], [`CONTRIBUTING.md`](CONTRIBUTING.md) → Shipped in v3.2 |
| See what shipped in v3.1 | [`CHANGELOG.md`](CHANGELOG.md) → [3.1.0], [`CONTRIBUTING.md`](CONTRIBUTING.md) → Shipped in v3.1 |
| See known bugs and how they were resolved | [`DECISIONS.md`](DECISIONS.md) → Known Bugs |
| See the GUI window layout | [`gui.ps1`](gui.ps1) → `Get-RenameGuiXaml` (static XAML; controls are populated in `Show-RenameGui`) |
| Understand why data is never interpolated into the XAML | [`DECISIONS.md`](DECISIONS.md) → ADR-008; the SECURITY note above `Get-RenameGuiXaml` in [`gui.ps1`](gui.ps1) |
| See the security findings from the v3.2 threat hunt | [`DECISIONS.md`](DECISIONS.md) → Security Findings (SEC-001 … SEC-005) |
| Externalise `$GATEWAY_MAP` to its own file | [`CONTRIBUTING.md`](CONTRIBUTING.md) → Externalising `$GATEWAY_MAP` |
| Submit a PR | [`CONTRIBUTING.md`](CONTRIBUTING.md) → Submitting Changes |

---

## Load order at runtime

Modules are dot-sourced in this order:

```
launcher.ps1
    └── logging.ps1      Initialize-Log, Write-Log            (loaded first)
    └── network.ps1      Get-DefaultGateway, Get-NetworkContext
    └── device.ps1       Get-Department, Get-DeviceType, Resolve-DeviceType, Get-SerialLast4, Get-UserName
    └── naming.ps1       Select-NamingMode, New-DeviceName, New-UserDeviceName
    └── gui.ps1          Show-RenameGui, Resolve-GatewayPreview, Get-RenameGuiXaml   (used only with -Gui)
    └── rename.ps1       Rename-DeviceSmart  ← entry point called by launcher
```

`gui.ps1` loads after `naming.ps1` (its live preview calls the name builders)
and before `rename.ps1` (which calls `Show-RenameGui`) — the same order as
`$MODULES` in [`launcher.ps1`](launcher.ps1) and the file list in
[`tools/Get-Hashes.ps1`](tools/Get-Hashes.ps1).

---

## Current version

**v3.3.0** — maintenance release: configurable `-PromptTimeoutSeconds` (OQ-004), 30-day log retention for the default log directory (ADR-009), chassis-first `LT` detection, and the BUG-014 elevation-relaunch quoting fix. See [`CHANGELOG.md`](CHANGELOG.md) for release notes and [`DECISIONS.md`](DECISIONS.md) for the audit trail.