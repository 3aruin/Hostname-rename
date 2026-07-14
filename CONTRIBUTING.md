# Contributing to Hostname-Rename

This document covers two things:

1. **Deploying the tool** — the exact steps to go from a code change to a safe production URL
2. **Contributing code** — how to submit bug fixes, new features, or documentation improvements

---

## Deployment Workflow

> This applies to anyone deploying from a fork, or to the canonical repo maintainer after any change to module files.

The integrity model depends on pinning your deployment URL to a specific commit SHA and keeping `$MANIFEST` hashes in sync.

### After any change to module files (`logging.ps1`, `network.ps1`, `device.ps1`, `naming.ps1`, `gui.ps1`, `rename.ps1`)

```
1.  Edit the module file(s)
2.  From the repo root, run:
        .\tools\Get-Hashes.ps1
3.  Copy the output block and paste it over the $MANIFEST in launcher.ps1
4.  Commit ALL changed files in one commit (modules + launcher.ps1)
5.  Push to GitHub
6.  Copy the resulting full 40-character commit SHA -- the MODULE commit
7.  In launcher.ps1, set $COMMIT_SHA to the module-commit SHA
8.  Commit and push again; copy this second SHA -- the LAUNCHER commit
9.  Update every deployment script / MDM command with:
        ...Hostname-rename/<LAUNCHER_SHA>/launcher.ps1
```

Two commits are unavoidable: `launcher.ps1` cannot contain the SHA of the
commit it is part of, so `$COMMIT_SHA` pins the *previous* commit — the one
that already holds the modules and the hashes in `$MANIFEST`. The deployment
URL fetches the launcher from the launcher commit; the launcher fetches the
modules from the module commit.

> ⚠️ **Never use `main` in a production URL.** A branch ref can be force-pushed;
> a commit SHA is immutable. Pinning to `main` makes the manifest check meaningless.

### Changing only `launcher.ps1` (e.g. updating `$MANIFEST` or `$REPO_BASE`)

Steps 1–9 above, but `Get-Hashes.ps1` output will be identical to the previous
run (module files unchanged). You still need a new SHA for the URL.

### Forking the repo

1. Fork on GitHub
2. In `launcher.ps1`, update `$REPO_BASE` to point to your fork:
```powershell
   $REPO_BASE = "https://raw.githubusercontent.com/YOUR_ORG/Hostname-rename"
```
3. In `network.ps1`, replace the RFC 5737 example IPs in `$GATEWAY_MAP` with your
   real site gateway IPs
4. Follow the full Deployment Workflow above

---

## Customisation Points

### Adding a site gateway

In `network.ps1`, add a new entry to `$GATEWAY_MAP`:

```powershell
$script:GATEWAY_MAP = @{
    "10.1.0.1"  = @{ ORG = "AC"; WH = "01"; LOC = "R" }
    "10.2.0.1"  = @{ ORG = "AC"; WH = "02"; LOC = "W" }
    # Add your entry here:
    "10.3.0.1"  = @{ ORG = "AC"; WH = "03"; LOC = "F" }
}
```

- `ORG` must be **exactly two characters** (Windows 15-char NetBIOS limit)
- `WH` should be a **two-digit string** (`"01"`, `"09"`, not `1` or `9`)
- `LOC` should be a **single letter**

After adding entries, re-run `Get-Hashes.ps1` and follow the Deployment Workflow.

### Adding a department code

In `device.ps1`, append the two-character code to `$script:VALID_DEPARTMENTS`:

```powershell
$script:VALID_DEPARTMENTS = @("CS", "SR", "OP", "HQ", "IT", "WS", "MK")
```

### Adding a device type

1. Append the code to `$script:DEVICE_TYPES` in `device.ps1`
2. Add a branch to `Resolve-DeviceType` (the pure decision function), before the
   `DT` fallback, in the correct priority position. `Get-DeviceType` only collects
   the WMI values and passes them in — keeping the chain in `Resolve-DeviceType`
   means you can unit-test the new branch without a real device. Four values are
   available: `$os` (`Win32_OperatingSystem`), `$cs` (`Win32_ComputerSystem`),
   `$cpu` (`Win32_Processor`), and `$enc` (`Win32_SystemEnclosure` → `ChassisTypes`)
3. If you need a class beyond those four, add a fifth parallel job in
   `Get-DeviceType` following the existing pattern and pass the value through
4. Add a Pester case to the `Resolve-DeviceType` block in the test file

### Externalising `$GATEWAY_MAP` to a separate file

To put the map in its own file rather than inline in `network.ps1`:

```powershell
# config.ps1  (add to $MODULES in launcher.ps1 before network.ps1)
$script:GATEWAY_MAP = @{
    "10.1.0.1" = @{ ORG = "AC"; WH = "01"; LOC = "R" }
    # ...
}
```

Then in `network.ps1`, remove the `$GATEWAY_MAP` declaration — the variable will
already be set in the script scope when `network.ps1` is dot-sourced.
Add `config.ps1` to `$MODULES` in `launcher.ps1` and to `$MANIFEST`
(run `Get-Hashes.ps1` to regenerate).

---

## Running Tests Locally

```powershell
# Install Pester (once)
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force

# Run both suites from the repo root
Invoke-Pester ./tests -Output Detailed
```

The GUI suite's XAML smoke tests need `PresentationFramework`; on machines
without WPF (e.g. Server Core) they skip cleanly and everything else still runs.

---

## Submitting Changes

1. **Open an issue first** for anything beyond a trivial fix — describe what you
   want to change and why. This avoids duplicate work.

2. **Branch naming:** `fix/<short-description>` or `feat/<short-description>`

3. **Before opening a PR:**
   - Run PSScriptAnalyzer locally and resolve any warnings:
```powershell
     Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning
```
   - Run the Pester suite and confirm it passes
   - If you changed any module file, re-run `Get-Hashes.ps1` and commit the
     updated `$MANIFEST` in the same PR

4. **PR description** should reference the relevant issue, checklist item
   (from `DECISIONS.md`), or open question (OQ-NNN / ADR-NNN).

5. The CI pipeline (`.github/workflows/ci.yml`) must pass before a PR can merge.

---

## Code Style

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"` are set
  in the launcher — all code must be clean under these settings
- Use `Write-Warning` for operator-visible issues; `Write-Verbose` for debug detail
- No third-party module dependencies (ADR-005)
- All interactive prompts must have a `-NonInteractive` bypass path
- Functions that accept `-NonInteractive` must never call `Read-Host` under that flag
- **Keep `.ps1` files ASCII-only, no BOM.** Use `--` instead of em dashes, `->`
  instead of arrows, and avoid box-drawing or fancy quotes in code and comments.
  A single non-ASCII character forces a UTF-8 BOM (Windows PowerShell 5.1 otherwise
  reads the file as Latin-1 and garbles it), which the `PSUseBOMForUnicodeEncodedFile`
  rule then flags. Markdown docs may use Unicode freely.
- Empty `catch` blocks trip `PSAvoidUsingEmptyCatchBlock`; prefer
  `-ErrorAction SilentlyContinue` on the call, or put a real statement
  (e.g. `Write-Verbose`) in the `catch`
- **GUI code (`gui.ps1`) has four extra rules (ADR-008):**
  - **The XAML is static.** The window markup is a single-quoted here-string
    returned by `Get-RenameGuiXaml`, containing zero `$` characters. Never
    interpolate runtime data (profile names, hostnames, serials, WMI strings)
    into markup — XAML is executable, and a spliced string is an injection
    vector. A Pester assertion greps the XAML for `$` and fails on any hit.
  - **Populate data via code, after parsing.** Runtime values go into control
    properties (`.Text`, `Items.Add`, `.Tag`) once `XamlReader::Parse` has
    built the tree; there they are inert data.
  - **ASCII-only applies inside the XAML too.** The markup lives in a `.ps1`
    here-string, so the repo-wide ASCII rule above covers it — no em dashes or
    fancy quotes in labels either.
  - **Precondition-and-fallback, never block.** Anything GUI-shaped must probe
    its preconditions (`[Environment]::UserInteractive`, STA thread,
    `PresentationFramework` loads) and return the `$script:GUI_UNAVAILABLE`
    sentinel — not throw — on failure or unexpected WPF error, so the caller
    falls back to the console prompts. A GUI failure must never block a
    rename. Keep decision logic in pure, WPF-free functions (the
    `Resolve-GatewayPreview` pattern) so it stays unit-testable; `gui.ps1`
    never calls `Rename-Computer` or `Write-Log`.

---

## Shipped in v3.3

See CHANGELOG.md → [3.3.0]:

| Item | Status |
|---|---|
| `-PromptTimeoutSeconds [int]` — configurable naming-mode prompt timeout (OQ-004) | ✅ Shipped |
| Log retention — 30-day pruning of the default `%TEMP%\Hostname-Rename` directory (ADR-009, `Remove-OldLogFile`) | ✅ Shipped |
| Chassis-first `LT` detection (`ChassisTypes` 9/10, `Model` heuristic kept as fallback) | ✅ Shipped |
| BUG-014 — per-path quoting in `Invoke-SelfElevation` (`-File` vs `iex` relaunch) | ✅ Shipped |

## Shipped in v3.2

See CHANGELOG.md → [3.2.0]:

| Item | Status |
|---|---|
| `-Gui` — optional WPF window with console fallback (ADR-008) | ✅ Shipped |
| `gui.ps1` module (`Show-RenameGui`, `Resolve-GatewayPreview`, `Get-RenameGuiXaml`) | ✅ Shipped |
| `tests/Hostname-Rename.Gui.Tests.ps1` — GUI logic, XAML smoke, parameter contracts | ✅ Shipped |
| Security hardening from the `-Gui` threat hunt — SEC-001 … SEC-005 (incl. the new `-AllowUnverified` guard) | ✅ Shipped |
| BUG-012 — `Write-Log` analyzer false-positive suppression | ✅ Shipped |

## Shipped in v3.1

See CHANGELOG.md → [3.1.0]:

| Item | Status |
|---|---|
| `-FolderPath [string]` — custom profile search path (User mode) | ✅ Shipped |
| `-Username [string]` — partial username matching (User mode) | ✅ Shipped |
| `PB` device type — Pizza Box (`ChassisTypes` 5) | ✅ Shipped |
| `TB` device type — Tablet/Convertible (`ChassisTypes` 30/31, OQ-003) | ✅ Shipped |
| `-WhatIf` / `SupportsShouldProcess` (OQ-002) | ✅ Shipped |
| Logging — `logging.ps1` (`Initialize-Log` / `Write-Log`, OQ-001) | ✅ Shipped |

Ideas for **v3.4** live in CHANGELOG.md → Unreleased (BUG-013 CI fixes,
GUI-fallback WMI caching).