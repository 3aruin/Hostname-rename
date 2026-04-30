# Hostname-Rename

Renames Windows devices to a standard naming convention, delivered via a single `irm | iex` command from GitHub.

---

## Overview

Automates Windows device naming based on:

- **Location** — resolved from gateway address
- **Department** — prompted at runtime (or passed via parameter)
- **Device Type** — auto-detected
- **Serial Number** — pulled from hardware

---

## Repo Structure

```
Hostname-rename/
├── launcher.ps1                    # Entry point — fetches, verifies, and runs everything
├── network.ps1                     # Gateway map and network context resolution
├── device.ps1                      # Device type detection, department, and serial number
├── naming.ps1                      # Naming mode selection and name construction
├── rename.ps1                      # Rename-DeviceSmart orchestrator
├── PSScriptAnalyzerSettings.psd1   # Lint rule configuration (CI-only)
├── README.md                       # This file
├── CHANGELOG.md                    # Version history
├── CONTRIBUTING.md                 # Deployment workflow and contributor guide
├── DECISIONS.md                    # Architecture decisions and bug log
├── tools/
│   └── Get-Hashes.ps1              # Local helper — regenerates manifest hashes
├── tests/
│   └── Hostname-Rename.Tests.ps1   # Pester v5 unit tests
└── .github/
    └── workflows/
        └── ci.yml                  # Lint + test + manifest + placeholder CI pipeline
```

---

## Name Format

### Gateway mode (default)

```
{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}
```

**Example:** `AC01R-WSDT-A3F9`

| Segment | Description |
|---|---|
| `{ORG}` | Two-character organisation code (e.g. `AC` for ACME Corporation) |
| `{WH}` | Two-digit site/warehouse number |
| `{LOC}` | Single location letter |
| `{DEPT}` | Two-character department code |
| `{TYPE}` | Two-character device type code |
| `{SERIAL}` | Last four characters of the BIOS serial number |

> **ORG must be two characters.** Windows enforces a 15-character NetBIOS limit on hostnames.
> A full name with a two-character ORG uses all 15 characters: `AA00A-AABB-0000`.
> A three-character ORG would overflow the limit before the department segment is even considered.

> If the full name exceeds 15 characters, the department segment is automatically dropped:
> `{ORG}{WH}{LOC}-{TYPE}-{SERIAL}`

### User mode

```
{WH}{LOC}-{Name}
```

**Example:** `01R-JaneDoe`

Derives location from the gateway and the name from a selected `C:\Users` profile folder. Useful for hot-desks or devices assigned to a specific person.

---

## Requirements

- Windows with PowerShell
- Administrator privileges

---

## First-Time Setup

### 1. Set your repo URL

In `launcher.ps1`, confirm the repo base points to your fork:

```powershell
$REPO_BASE = "https://raw.githubusercontent.com/YOUR_ORG/Hostname-rename"
```

### 2. Add your sites

In `network.ps1`, replace the example entries in `$GATEWAY_MAP` with your real site gateways:

```powershell
$script:GATEWAY_MAP = @{
    # -- CONFIGURE YOUR SITES HERE --
    # Key   = default gateway IP
    # ORG   = two-character organisation code  (e.g. "AC" for ACME Corporation)
    # WH    = two-digit site number            (e.g. "01")
    # LOC   = single location letter           (e.g. "R")
    "192.0.2.1"     = @{ ORG = "AC"; WH = "01"; LOC = "R" }
    "198.51.100.1"  = @{ ORG = "AC"; WH = "02"; LOC = "W" }
}
```

### 3. Generate hashes and pin to a commit

After any change to module files, regenerate the manifest from the repo root:

```powershell
.\tools\Get-Hashes.ps1
```

Paste the output into the `$MANIFEST` block in `launcher.ps1`, commit all changes, and note the resulting commit SHA.

> ⚠️ **Always pin to a full 40-character commit SHA in your deployment URL — never use `main` directly.**
> A branch ref can be force-pushed; a commit SHA is immutable and is what makes the integrity check meaningful.

---

## Running

### Interactive

```powershell
iex (iwr "https://raw.githubusercontent.com/YOUR_ORG/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
```

### With Parameters

```powershell
& ([scriptblock]::Create(
    (iwr "https://raw.githubusercontent.com/YOUR_ORG/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
)) -NonInteractive -Gateway
```

### Available Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Gateway` | switch | Force Gateway naming mode |
| `-Folder` | switch | Force User naming mode — selects a name from `C:\Users` profile folders |
| `-NonInteractive` | switch | Suppress all prompts; for MDM / automated deployment |
| `-FolderPath` | string | *(planned — v3.1)* Custom profile search path for User mode |
| `-Username` | string | *(planned — v3.1)* Partial username to match in User mode |

---

## Deployment Workflow

Follow these steps after any change to module files:

1. Edit module files as needed
2. Run `.\tools\Get-Hashes.ps1` and paste the output into the `$MANIFEST` block in `launcher.ps1`
3. Commit all changes
4. Copy the new commit SHA
5. Update your deployment script or MDM command with the new SHA in the URL

---

## Valid Codes

### Department codes (`$script:VALID_DEPARTMENTS` in `device.ps1`)

| Code | Description |
|---|---|
| `CS` | Customer Service |
| `SR` | Sales |
| `OP` | Operations |
| `HQ` | Head Office / Admin |
| `IT` | IT |
| `WS` | Workstation / Default (NonInteractive) |

To add a new department, append its two-character code to `$script:VALID_DEPARTMENTS` in `device.ps1`. The interactive prompt picks it up automatically.

### Device type codes (`$script:DEVICE_TYPES` in `device.ps1`)

Type is auto-detected at runtime using three parallel WMI queries. The detection chain runs in priority order — first match wins, `DT` is the fallback if nothing else matches.

| Code | Description | Detection |
|---|---|---|
| `VM` | Virtual Machine | `Win32_ComputerSystem.Model` contains `"Virtual"` |
| `SV` | Server | `Win32_OperatingSystem.ProductType` ≠ 1 (i.e. not Workstation) |
| `MD` | Mobile / ARM | `Win32_Processor.Architecture` = `5` (ARM) |
| `ET` | Thin Client / Endpoint Terminal | Manual override only — no WMI signal |
| `LT` | Laptop | `Win32_ComputerSystem.Model` contains `"Laptop"` |
| `DT` | Desktop | Default fallback |
| `PB` | Pizza Box (low-profile rack unit) | *(planned — v3.1)* `Win32_SystemEnclosure.ChassisTypes` |

In interactive mode the detected type is shown on screen and you can override it before the rename is applied.

**To add a new auto-detected type:**

1. Add its two-character code to `$script:DEVICE_TYPES` in `device.ps1`.
2. Add a detection branch inside the `try` block in `Get-DeviceType`, before the `DT` fallback. The three WMI objects already in scope are:

| Variable | WMI Class | Useful properties |
|---|---|---|
| `$os` | `Win32_OperatingSystem` | `ProductType`, `Caption` |
| `$cs` | `Win32_ComputerSystem` | `Model`, `PCSystemType` |
| `$cpu` | `Win32_Processor` | `Architecture` |

If you need a property not covered by those three classes (e.g. `Win32_SystemEnclosure.ChassisTypes` for rack/tower/tablet form factors), add a fourth parallel job following the existing pattern.

3. The interactive override prompt reads from `$script:DEVICE_TYPES`, so it will include the new code without any further changes.

---

## Usage Notes

- Run as needed to standardise device names across the network
- Silent/MDM deployment is supported via `-NonInteractive -Gateway`
- Device type is auto-detected; the interactive prompt allows an override before the rename is applied
- If the detected gateway is not in `$GATEWAY_MAP`, the tool warns and uses fallback values — add the site before deploying to that network
