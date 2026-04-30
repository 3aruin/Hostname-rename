# Contributing to Hostname-Rename

Thank you for your interest in contributing. This document covers two things:

1. **Deploying the tool** — the exact steps to go from a code change to a safe production URL
2. **Contributing code** — how to submit bug fixes, new features, or documentation improvements

---

## Deployment Workflow

> This applies to anyone deploying from a fork, or to the canonical repo maintainer after any change to module files.

The integrity model depends on pinning your deployment URL to a specific commit SHA and keeping `$MANIFEST` hashes in sync. The steps below are the minimum safe path every time.

### After any change to module files (`network.ps1`, `device.ps1`, `naming.ps1`, `rename.ps1`)

```
1.  Edit the module file(s)
2.  From the repo root, run:
        .\tools\Get-Hashes.ps1
3.  Copy the output block and paste it over the $MANIFEST in launcher.ps1
4.  Commit ALL changed files in one commit (modules + launcher.ps1)
5.  Push to GitHub
6.  Copy the resulting full 40-character commit SHA from GitHub
7.  Update every deployment script / MDM command with:
        ...Hostname-rename/<NEW_SHA>/launcher.ps1
```

> ⚠️ **Never use `main` in a production URL.** A branch ref can be force-pushed;
> a commit SHA is immutable. Pinning to `main` makes the manifest check meaningless.

### Changing only `launcher.ps1` (e.g. updating `$MANIFEST` or `$REPO_BASE`)

Steps 1–7 above, but `Get-Hashes.ps1` output will be identical to the previous
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
2. Add a detection branch inside the `try` block in `Get-DeviceType`, before the
   `DT` fallback — the three WMI objects in scope are `$os`, `$cs`, `$cpu`
3. If your detection needs a fourth WMI class, follow the existing job pattern

### Externalising `$GATEWAY_MAP` to a separate file

For teams managing many sites, you may want the map in its own file rather than
inline in `network.ps1`. One approach:

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

# Run from repo root
Invoke-Pester ./tests/Hostname-Rename.Tests.ps1 -Output Detailed
```

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

---

## Planned v3.1 Work

The following items are documented and ready for contribution:

| Item | Description | Reference |
|---|---|---|
| `-FolderPath [string]` | Custom profile search path for User mode | BUG-001, DECISIONS.md |
| `-Username [string]` | Partial username matching in User mode | BUG-001, DECISIONS.md |
| `PB` device type | Pizza Box detection via `Win32_SystemEnclosure.ChassisTypes` | README, CHANGELOG |
| `-WhatIf` / `SupportsShouldProcess` | Dry-run support in `Rename-DeviceSmart` | OQ-002 |
| Optional logging | `Write-Log` wrapper to UNC or local temp | OQ-001 |
